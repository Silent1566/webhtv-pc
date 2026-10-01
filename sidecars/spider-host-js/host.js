#!/usr/bin/env node
'use strict';
/**
 * `webhtv-ipc-v1` 传输层实现（Node 侧），并承载 `tvbox-js-v1` 脚本层。
 *
 * 与 Dart 侧 `apps/desktop-flutter/lib/core/ipc_protocol.dart` 以及 Python 侧
 * `sidecars/spider-host-python/webhtv_ipc.py` 是同一份契约的第三份实现——
 * 三份实现必须对帧格式、握手、错误信封给出**一致**的行为（设计文档 §9.3、
 * §9.3.1、§9.5）。
 *
 * 职责划分：
 *
 * | 层 | 文件 | 职责 |
 * | --- | --- | --- |
 * | 传输 | 本文件 | 帧编解码、握手、取消、错误信封、并发控制 |
 * | 脚本沙箱 | `sandbox_worker.js` | TVBox 全局 API 与导出方法，跑在 worker 线程 |
 *
 * # 为什么 HTTP 在宿主主线程、沙箱在 worker 线程
 *
 * TVBox 的 `req()` 是同步的，沙箱必须阻塞等待网络。若沙箱跑在主线程，阻塞会冻结
 * 事件循环：`$/cancelRequest` 收不到、心跳停摆、并发调用排队（§9.5 失效）。
 *
 * 因此沙箱放到 worker（它的阻塞只影响自己），HTTP 由宿主主线程用异步 http 完成，
 * 再通过 `Atomics.notify` 唤醒沙箱。这样：
 *
 * - 主线程事件循环**始终活跃** → 取消、并发、心跳都可用；
 * - 沙箱线程可以放心地同步阻塞 → TVBox 站源无需改写。
 *
 * # 安全边界（§9.8）
 *
 * - 站源代码只在 `vm` 沙箱里执行，拿不到 `require`/`process`/`fs`；
 * - `req` 只允许 http(s)，拒绝 `file://` 等本地 scheme；
 * - 单响应与单帧都有大小上限，超限明确报错而不是截断；
 * - stdout 只承载协议帧，一切日志走 stderr。
 */

const http = require('node:http');
const https = require('node:https');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const { Worker } = require('node:worker_threads');

const ABI_NAME = 'webhtv-ipc-v1';
const ABI_MINOR = 0;
const DEFAULT_MAX_FRAME_BYTES = 16 * 1024 * 1024;
const MAX_REDIRECTS = 5;

/** 必需 / 可选方法集（§9.3）——manifest 校验与文档一致性用。 */
const REQUIRED_METHODS = ['init', 'home', 'category', 'detail', 'search', 'play', 'destroy'];
const OPTIONAL_METHODS = ['homeVod', 'live', 'proxy', 'action'];
const KNOWN_CAPABILITIES = new Set([
  ...REQUIRED_METHODS,
  ...OPTIONAL_METHODS,
]);
const CANCEL_METHODS = new Set(['$/cancelRequest', '$/cancel']);

const ERROR_INIT_FAILED = 'SPIDER_INIT_FAILED';
const ERROR_UNSUPPORTED = 'SPIDER_UNSUPPORTED';
const ERROR_BAD_REQUEST = 'SPIDER_BAD_REQUEST';
const ERROR_HTTP_ERROR = 'SPIDER_HTTP_ERROR';
const ERROR_PARSE_ERROR = 'SPIDER_PARSE_ERROR';
const ERROR_TIMEOUT = 'SPIDER_TIMEOUT';
const ERROR_CANCELLED = 'SPIDER_CANCELLED';
const ERROR_CRASHED = 'SPIDER_CRASHED';
const ERROR_RESOURCE_LIMIT = 'SPIDER_RESOURCE_LIMIT';
const ERROR_PROTOCOL_VIOLATION = 'SPIDER_PROTOCOL_VIOLATION';

/** 运行日志只能写 stderr（§9.3.1）。stdout 被协议独占。 */
function log(message) {
  process.stderr.write(`${message}\n`);
}

// ---------------------------------------------------------------------------
// 帧编解码（与 Python/Dart 实现逐条对齐）
// ---------------------------------------------------------------------------

function encodeFrame(payload) {
  const body = Buffer.from(JSON.stringify(payload), 'utf8');
  const header = Buffer.from(
    `Content-Length: ${body.length}\r\n` +
      'Content-Type: application/json; charset=utf-8\r\n\r\n',
    'ascii',
  );
  return Buffer.concat([header, body]);
}

function writeFrame(payload) {
  process.stdout.write(encodeFrame(payload));
}

/**
 * 增量帧解码器：Node 的 stdin 不保证一次 data 事件就是一个完整帧，
 * 必须自己缓冲并切分（与 Dart 的 `IpcFrameDecoder` 同语义）。
 */
class FrameDecoder {
  constructor({ maxFrameBytes = DEFAULT_MAX_FRAME_BYTES } = {}) {
    this.maxFrameBytes = maxFrameBytes;
    this.buffer = Buffer.alloc(0);
  }

  push(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    const frames = [];
    for (;;) {
      const headerEnd = this._findHeaderEnd();
      if (headerEnd < 0) break;
      const headerText = this.buffer.slice(0, headerEnd.index).toString('utf8');
      const length = this._contentLength(headerText);
      const bodyStart = headerEnd.index + headerEnd.size;
      if (this.buffer.length - bodyStart < length) break;
      const body = this.buffer.slice(bodyStart, bodyStart + length);
      this.buffer = this.buffer.slice(bodyStart + length);
      if (length > this.maxFrameBytes) {
        throw new ProtocolError(`声明 ${length} 字节超过上限 ${this.maxFrameBytes}`);
      }
      let parsed;
      try {
        parsed = JSON.parse(body.toString('utf8'));
      } catch (error) {
        throw new ProtocolError(`payload 不是 UTF-8 JSON：${error.message}`);
      }
      frames.push(parsed);
    }
    return frames;
  }

  _findHeaderEnd() {
    const crlf = this.buffer.indexOf('\r\n\r\n');
    const lf = this.buffer.indexOf('\n\n');
    if (crlf < 0 && lf < 0) return -1;
    if (crlf >= 0 && (lf < 0 || crlf <= lf)) return { index: crlf, size: 4 };
    return { index: lf, size: 2 };
  }

  _contentLength(headerText) {
    let length = null;
    for (const line of headerText.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      const colon = trimmed.indexOf(':');
      if (colon < 0) throw new ProtocolError(`头字段缺少冒号：${trimmed}`);
      const name = trimmed.slice(0, colon).trim().toLowerCase();
      if (name === 'content-length') {
        const value = trimmed.slice(colon + 1).trim();
        const parsed = Number.parseInt(value, 10);
        if (!Number.isFinite(parsed) || parsed < 0) {
          throw new ProtocolError(`Content-Length 非法：${value}`);
        }
        length = parsed;
      }
    }
    if (length === null) throw new ProtocolError('缺少 Content-Length 头');
    return length;
  }
}

class ProtocolError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ProtocolError';
  }
}

// ---------------------------------------------------------------------------
// 错误信封（与 Python/Dart 一致）
// ---------------------------------------------------------------------------

function defaultCategory(code) {
  if (code === ERROR_PROTOCOL_VIOLATION || code === ERROR_BAD_REQUEST) return 'protocol';
  if (code === ERROR_CRASHED) return 'transport';
  if (code === ERROR_RESOURCE_LIMIT) return 'resource';
  if (code === ERROR_CANCELLED) return 'user';
  return 'site';
}

function defaultRetryable(code) {
  return [ERROR_TIMEOUT, ERROR_HTTP_ERROR, ERROR_CRASHED, ERROR_INIT_FAILED].includes(code);
}

function defaultUserVisible(code) {
  return code !== ERROR_PROTOCOL_VIOLATION;
}

function errorObject(code, message, options = {}) {
  return {
    code,
    category: options.category || defaultCategory(code),
    message,
    retryable: options.retryable === undefined ? defaultRetryable(code) : options.retryable,
    userVisible:
      options.userVisible === undefined ? defaultUserVisible(code) : options.userVisible,
    siteKey: options.siteKey || null,
    requestId: options.requestId || null,
    details: options.details || {},
    diagnosticId: 'diag-js',
  };
}

// ---------------------------------------------------------------------------
// 同步 req 的 HTTP 执行端（宿主主线程）
// ---------------------------------------------------------------------------

// Atomics 只能存取 32 位整数，因此状态码必须编码为整数（字符串会在
// 存进 Int32Array 时被 ToInt32 静默截断成 0，表现为「req 未知状态：0」）。
const STATUS_OK = 1;
const STATUS_NETWORK_ERROR = 2;
const STATUS_TOO_LARGE = 3;

/** 执行一次 HTTP 请求并跟随重定向；永不抛异常，结果通过返回值表达。 */
function fetchOnce(url, options, maxBodyBytes) {
  return new Promise((resolve) => {
    let redirects = 0;
    let current = url;

    const attempt = () => {
      let parsed;
      try {
        parsed = new URL(current);
      } catch {
        resolve({ kind: 'network-error', error: `URL 非法：${safeUrl(current)}` });
        return;
      }
      if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
        // §9.8：站源只能访问 http(s)，file:// 等本地 scheme 一律拒绝。
        resolve({
          kind: 'network-error',
          error: `不支持的协议：${parsed.protocol}`,
        });
        return;
      }

      const client = parsed.protocol === 'https:' ? https : http;
      const request = client.request(
        {
          method: options.method || 'GET',
          hostname: parsed.hostname,
          port: parsed.port || undefined,
          path: `${parsed.pathname}${parsed.search}`,
          headers: options.headers || {},
        },
        (response) => {
          const status = response.statusCode || 0;
          if (status >= 300 && status < 400 && response.headers.location) {
            response.resume();
            if (++redirects > MAX_REDIRECTS) {
              resolve({
                kind: 'network-error',
                error: `重定向超过 ${MAX_REDIRECTS} 次`,
              });
              return;
            }
            current = new URL(response.headers.location, current).toString();
            attempt();
            return;
          }

          const chunks = [];
          let total = 0;
          response.on('data', (chunk) => {
            total += chunk.length;
            if (total > maxBodyBytes) {
              response.destroy();
              resolve({
                kind: 'too-large',
                error: `响应超过上限 ${maxBodyBytes} 字节`,
              });
              return;
            }
            chunks.push(chunk);
          });
          response.on('end', () => {
            let body = Buffer.concat(chunks);
            const encoding = String(response.headers['content-encoding'] || '').toLowerCase();
            try {
              if (encoding === 'gzip') body = zlib.gunzipSync(body);
              else if (encoding === 'deflate') body = zlib.inflateSync(body);
              else if (encoding === 'br') body = zlib.brotliDecompressSync(body);
            } catch (error) {
              resolve({ kind: 'network-error', error: `解压失败：${error.message}` });
              return;
            }
            resolve({
              kind: 'ok',
              statusCode: status,
              headers: response.headers,
              body,
              finalUrl: current,
            });
          });
          response.on('error', (error) => {
            resolve({ kind: 'network-error', error: error.message });
          });
        },
      );

      request.setTimeout(options.timeoutMs, () => {
        request.destroy(new Error(`请求超时（${options.timeoutMs}ms）`));
      });
      request.on('error', (error) => {
        // 已在 timeout 里 destroy 的请求会再触发一次 error，取首次结果即可。
        resolve({ kind: 'network-error', error: error.message });
      });
      if (options.body !== undefined && options.body !== null) {
        request.write(options.body);
      }
      request.end();
    };

    attempt();
  });
}

function safeUrl(url) {
  try {
    const parsed = new URL(url);
    return `${parsed.protocol}//${parsed.host}${parsed.pathname}`;
  } catch {
    return '<非法 URL>';
  }
}

// ---------------------------------------------------------------------------
// sidecar 服务
// ---------------------------------------------------------------------------

class SidecarServer {
  /**
   * @param {object} options
   * @param {string} options.entryPath 站源 JS 路径
   * @param {object} options.manifest manifest 内容
   * @param {string} options.workDir 每站点工作目录
   * @param {number} [options.maxWorkers] 并发上限
   */
  constructor({ entryPath, manifest, workDir, maxWorkers = 4 }) {
    this.entryPath = entryPath;
    this.manifest = manifest || {};
    this.workDir = workDir;
    this.siteKey = String(this.manifest.key || path.basename(entryPath, '.js'));
    this.responseDir = path.join(workDir, 'responses');
    fs.mkdirSync(this.responseDir, { recursive: true });
    this.maxResponseBytes = Math.max(
      1024 * 1024,
      Number(this.manifest?.limits?.responseMiB || 16) * 1024 * 1024,
    );
    this.maxWorkers = Math.max(1, maxWorkers);
    this.stopping = false;
    this.initialized = false;
    this.cancelled = new Set();
    this.inflight = new Set();
    this.decodeErrors = 0;

    // manifest 是分发契约：声明了 capabilities 时以 manifest 为准，
    // sidecar 自报的能力不得超出 manifest（§9.7）。
    const declared = this.manifest.capabilities;
    this.capabilities = new Set(
      Array.isArray(declared) && declared.length
        ? declared
        : ['home', 'category', 'detail', 'search', 'play'],
    );

    this.worker = new Worker(path.join(__dirname, 'sandbox_worker.js'), {
      workerData: { workDir },
    });
    this.worker.on('error', (error) => {
      log(`沙箱线程崩溃：${error.message}`);
    });
    this.worker.on('message', (message) => this._onWorkerMessage(message));
    // 待处理请求：id → { resolve, reject }。
    this.pendingCalls = new Map();
    this.pendingLoad = null;
  }

  /** 冷启动：等沙箱加载完站源。 */
  async start() {
    const loaded = new Promise((resolve) => {
      this.pendingLoad = resolve;
    });
    this.worker.postMessage({
      type: 'load',
      entryPath: this.entryPath,
      manifest: this.manifest,
    });
    const outcome = await loaded;
    if (!outcome.ok) {
      throw new Error(outcome.error);
    }
  }

  _onWorkerMessage(message) {
    if (!message || typeof message !== 'object') return;
    switch (message.type) {
      case 'ready':
        break;
      case 'loaded':
        if (this.pendingLoad) {
          const resolve = this.pendingLoad;
          this.pendingLoad = null;
          resolve(message);
        }
        break;
      case 'init-result':
        if (this.pendingInit) {
          const resolve = this.pendingInit;
          this.pendingInit = null;
          resolve(message);
        }
        break;
      case 'call-result': {
        const entry = this.pendingCalls.get(message.id);
        if (entry) {
          this.pendingCalls.delete(message.id);
          this.inflight.delete(message.id);
          entry.resolve(message);
        }
        break;
      }
      case 'req':
        // 沙箱在等待同步 req：宿主主线程执行异步 HTTP，完成后唤醒沙箱。
        void this._handleReq(message);
        break;
      case 'shutdown-done':
        break;
      default:
        break;
    }
  }

  /** 执行沙箱请求的 HTTP，并把结果写入文件后唤醒沙箱线程。 */
  async _handleReq(message) {
    const { id, sab, url, metaPath, bodyPath, options } = message;
    const state = new Int32Array(sab);
    const timeoutMs = Number(options?.timeoutMs) > 0 ? Number(options.timeoutMs) : 15000;

    let status = STATUS_OK;
    let meta = { statusCode: 0, headers: {} };
    let body = Buffer.alloc(0);

    // 说明：取消以**调用**为单位，不按单个 req 粒度中断。沙箱线程此刻正阻塞在
    // `Atomics.wait` 里，无法安全地中止它的栈；因此请求照常完成、唤醒沙箱以避免
    // 死等，而结果在分发层按 requestId 丢弃（§9.5「不得向已取消页面投递结果」）。
    try {
      const result = await fetchOnce(
        url,
        { ...options, timeoutMs },
        this.maxResponseBytes,
      );
      if (result.kind === 'ok') {
        status = STATUS_OK;
        body = result.body;
        meta = {
          statusCode: result.statusCode,
          headers: result.headers,
          finalUrl: result.finalUrl,
          bodyBytes: body.length,
        };
      } else if (result.kind === 'too-large') {
        status = STATUS_TOO_LARGE;
        meta = { error: result.error, statusCode: 0, headers: {} };
      } else {
        status = STATUS_NETWORK_ERROR;
        meta = { error: result.error, statusCode: 0, headers: {} };
      }
    } catch (error) {
      status = STATUS_NETWORK_ERROR;
      meta = { error: error.message, statusCode: 0, headers: {} };
    }

    try {
      if (body.length > 0) fs.writeFileSync(bodyPath, body);
      fs.writeFileSync(metaPath, JSON.stringify(meta), 'utf8');
    } catch (error) {
      log(`写入响应文件失败：${error.message}`);
      status = STATUS_NETWORK_ERROR;
    }

    // 唤醒必须放在最后：先唤醒会让沙箱读到半份文件。
    Atomics.store(state, 0, status);
    Atomics.notify(state, 0);
    void id;
  }

  /** 调用沙箱方法；返回 worker 回包（含 ok/error）。 */
  _callWorker(type, payload, { timeoutMs } = {}) {
    return new Promise((resolve) => {
      const id = payload.id;
      const timer = setTimeout(() => {
        this.pendingCalls.delete(id);
        this.inflight.delete(id);
        resolve({
          ok: false,
          error: `沙箱调用超时（${timeoutMs}ms）`,
          timeout: true,
        });
      }, timeoutMs || 30000);
      this.pendingCalls.set(id, {
        resolve: (value) => {
          clearTimeout(timer);
          resolve(value);
        },
      });
      this.worker.postMessage({ type, ...payload });
    });
  }

  async initialize(params) {
    const declared = params?.abi;
    if (declared && declared !== ABI_NAME) {
      throw new ProtocolError(`ABI 不兼容：宿主声明 ${declared}，sidecar 为 ${ABI_NAME}`);
    }
    const extend = String(params?.extend ?? this.manifest?.config?.extend ?? '');
    const outcome = await new Promise((resolve) => {
      this.pendingInit = resolve;
      this.worker.postMessage({ type: 'init', extend });
    });
    if (!outcome.ok) {
      throw new Error(`站源 init 失败：${outcome.error}`);
    }
    this.initialized = true;
    return {
      abi: ABI_NAME,
      abiMinor: ABI_MINOR,
      key: this.siteKey,
      runtime: this.manifest.runtime || 'node',
      capabilities: [...this.capabilities].sort(),
      permissions: this.manifest.permissions || {
        network: true,
        localProxy: false,
        ui: false,
        storage: 'cache-only',
        process: false,
        clipboard: false,
        browser: false,
      },
      limits: this.manifest.limits || {},
      init: { key: this.siteKey, extend },
    };
  }

  supports(method) {
    if (!KNOWN_CAPABILITIES.has(method)) return true;
    return this.capabilities.has(method);
  }

  // ------------------------------------------------------------------ 分发

  async dispatch(message) {
    const requestId = String(message.id);
    const method = String(message.method || '');
    const params = message.params || {};

    try {
      if (method === 'initialize' || method === 'init') {
        const result = await this.initialize(params);
        this._respondSuccess(requestId, result);
        return;
      }
      if (method === 'destroy' || method === 'shutdown') {
        this.stopping = true;
        this.worker.postMessage({ type: 'shutdown' });
        this._respondSuccess(requestId, { ok: true });
        return;
      }
      if (method === 'heartbeat') {
        this._respondSuccess(requestId, { ok: true });
        return;
      }
      if (!this.supports(method)) {
        this._respondError(
          requestId,
          ERROR_UNSUPPORTED,
          `未声明 capability：${method}`,
          { details: { capabilities: [...this.capabilities].sort() } },
        );
        return;
      }
      if (!this.initialized) {
        this._respondError(
          requestId,
          ERROR_INIT_FAILED,
          '尚未完成 initialize 握手',
        );
        return;
      }

      const callId = `${requestId}#${Date.now().toString(36)}`;
      this.inflight.add(callId);
      const remaining = this._deadlineOf(message);
      const outcome = await this._callWorker(
        'call',
        { id: callId, method, params },
        { timeoutMs: remaining },
      );
      this.inflight.delete(callId);

      // 取消后不得再投递结果（§9.5）。
      if (this.cancelled.has(requestId)) {
        this.cancelled.delete(requestId);
        this._respondError(requestId, ERROR_CANCELLED, '调用方已取消该请求');
        return;
      }

      if (outcome.ok) {
        this._respondSuccess(requestId, outcome.result);
        return;
      }
      if (outcome.timeout) {
        this._respondError(requestId, ERROR_TIMEOUT, outcome.error);
        return;
      }
      // 站源自身的异常：判为解析/业务错误，具体原因进 details。
      this._respondError(requestId, ERROR_PARSE_ERROR, outcome.error, {
        details: outcome.details || {},
      });
    } catch (error) {
      if (error instanceof ProtocolError) {
        this._respondError(requestId, ERROR_BAD_REQUEST, error.message);
        return;
      }
      log(`方法 ${method} 失败：${error && error.stack ? error.stack : error}`);
      this._respondError(
        requestId,
        ERROR_PARSE_ERROR,
        `${error && error.name ? error.name : 'Error'}: ${error && error.message ? error.message : error}`,
      );
    }
  }

  /** deadline 优先，其次按方法给默认值（§9.3.1：超时按方法配置）。 */
  _deadlineOf(message) {
    const declared = Number(message.deadlineMs);
    if (Number.isFinite(declared) && declared > 0) {
      return Math.min(declared, 120000);
    }
    const method = String(message.method || '');
    if (method === 'play') return 20000;
    if (method === 'search') return 25000;
    if (method === 'detail') return 20000;
    return 30000;
  }

  _onCancel(message) {
    const target = message?.params?.id;
    if (typeof target !== 'string' || !target) {
      log('取消消息缺少 id，已忽略');
      return;
    }
    // 沙箱线程可能正阻塞在 req 里，无法立刻中断；标记后由分发层丢弃结果。
    this.cancelled.add(target);
    log(`已标记取消 id=${target}`);
  }

  _respondSuccess(requestId, result) {
    writeFrame({ jsonrpc: '2.0', id: requestId, result });
  }

  _respondError(requestId, code, message, options = {}) {
    writeFrame({
      jsonrpc: '2.0',
      id: requestId,
      error: errorObject(code, message, {
        ...options,
        siteKey: this.siteKey,
        requestId,
      }),
    });
  }
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const args = { entry: null, manifest: null, maxWorkers: 4 };
  for (let index = 0; index < argv.length; index++) {
    const token = argv[index];
    if (token === '--entry') args.entry = argv[++index];
    else if (token === '--manifest') args.manifest = argv[++index];
    else if (token === '--max-workers') args.maxWorkers = Number(argv[++index]) || 4;
  }
  return args;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.entry) {
    log('缺少 --entry');
    return 2;
  }
  if (!fs.existsSync(args.entry)) {
    log(`站源入口不存在：${args.entry}`);
    return 2;
  }
  let manifest = {};
  if (args.manifest) {
    if (!fs.existsSync(args.manifest)) {
      log(`manifest 不存在：${args.manifest}`);
      return 2;
    }
    try {
      manifest = JSON.parse(fs.readFileSync(args.manifest, 'utf8'));
    } catch (error) {
      log(`manifest 不是合法 JSON：${error.message}`);
      return 2;
    }
  }

  const workDir = process.cwd();
  const server = new SidecarServer({
    entryPath: path.resolve(args.entry),
    manifest,
    workDir,
    maxWorkers: args.maxWorkers,
  });
  try {
    await server.start();
  } catch (error) {
    log(`站源初始化失败：${error.message}`);
    return 3;
  }

  const decoder = new FrameDecoder();
  const queue = [];
  let running = 0;

  const drain = () => {
    while (running < server.maxWorkers && queue.length > 0) {
      const message = queue.shift();
      running++;
      server
        .dispatch(message)
        .catch((error) => log(`分发失败：${error.message}`))
        .finally(() => {
          running--;
          if (server.stopping) {
            finish();
            return;
          }
          drain();
        });
    }
  };

  let finished = false;
  const finish = () => {
    if (finished) return;
    finished = true;
    try {
      server.worker.postMessage({ type: 'shutdown' });
    } catch {
      // 线程可能已退出。
    }
    setTimeout(() => {
      server.worker.terminate().catch(() => {});
      process.exit(0);
    }, 50).unref();
  };

  process.stdin.on('data', (chunk) => {
    let frames;
    try {
      frames = decoder.push(chunk);
    } catch (error) {
      log(`协议错误，终止运行时：${error.message}`);
      process.exit(2);
    }
    for (const frame of frames) {
      const method = frame && frame.method;
      if (CANCEL_METHODS.has(method)) {
        server._onCancel(frame);
        continue;
      }
      if (!frame || !frame.id || !method) {
        log('丢弃非法消息：缺少 id/method');
        continue;
      }
      queue.push(frame);
    }
    drain();
  });

  process.stdin.on('end', () => {
    server.stopping = true;
    if (running === 0) finish();
  });

  log(`sidecar 就绪 entry=${path.basename(args.entry)} key=${server.siteKey}`);
  return null; // 保持事件循环存活
}

main().then((code) => {
  // `main()` 用返回值表达退出码（非 0 表示启动阶段致命错误）；若不套用，
  // 站源入口/ manifest 非法会以 **exit 0** 结束，被宿主误判为「正常退出」，
  // 把真实的启动失败伪装成成功（§8.4、§9.9 禁止静默失败）。
  // 返回 null 表示正常进入服务循环（事件循环自行保持存活）。
  if (typeof code === 'number' && code !== 0) {
    process.exit(code);
  }
}).catch((error) => {
  log(`sidecar 启动失败：${error && error.stack ? error.stack : error}`);
  process.exit(1);
});

module.exports = { FrameDecoder, encodeFrame, errorObject, SidecarServer, ProtocolError };
