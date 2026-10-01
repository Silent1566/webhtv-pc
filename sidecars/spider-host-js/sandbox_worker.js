'use strict';
/**
 * TVBox / CatVod JS 站源的沙箱线程（设计文档 §9.1、§9.8）。
 *
 * # 契约分层
 *
 * - **传输层**是 `webhtv-ipc-v1`（`host.js` 负责帧、握手、错误信封）；
 * - **脚本层**是 `tvbox-js-v1`（本文件负责把 TVBox 站源期待的全局 API 与导出
 *   方法接起来）。
 *
 * 第三方 JS 站源是为 TVBox 写的，只认识 `homeContent` / `categoryContent` /
 * `detailContent` / `searchContent` / `playerContent` 与 `req` / `log` / `setItem`
 * / `getItem`。宿主不认识这些名字，脚本也看不到 stdio 帧——两层互不泄漏。
 *
 * # 为什么沙箱必须跑在 worker 线程
 *
 * TVBox 站源把 `req()` 当作**同步**函数用（`var html = req(url)`）。要在一个同步
 * 调用里拿到异步 HTTP 的结果，只能让**当前线程阻塞**（`Atomics.wait`）并让**另一个
 * 线程**完成 I/O 后唤醒它。
 *
 * 如果沙箱跑在宿主主线程，阻塞就会冻结事件循环：`$/cancelRequest` 收不到、心跳停摆、
 * 并发调用全部排队（§9.5「取消」「超时」会失效）。因此：
 *
 * - **沙箱在 worker 线程**——它被阻塞只影响自己；
 * - **HTTP 在宿主主线程**——事件循环始终活跃，取消与超时可用。
 *
 * 这正是 `Atomics.wait` 允许的用法：阻塞一个线程，另一个线程照常跑事件循环。
 *
 * # 沙箱边界（§9.8）
 *
 * - `vm.createContext` + 显式注入：站源拿不到 `require` / `process` / `fs` /
 *   `Buffer` / `setTimeout`（不注入定时器，避免站源挂住线程）；
 * - 网络只能经 `req` 走主线程的 http(s)，不接受 `file://` 等本地 scheme；
 * - `setItem` / `getItem` 是进程内内存存储（`storage: cache-only`），随 sidecar
 *   退出而消失；跨进程持久化不在本阶段范围。
 *
 * # 已知限制（诚实记录，不静默）
 *
 * - `req` 返回响应体**字符串**（对齐 TVBox 语义），需要 JSON 时站源自行 `JSON.parse`；
 * - Android/浏览器专有全局（`getWebViewUrl`、`startThunder`、`js2Proxy` 等）会抛出
 *   明确的「桌面端未实现」，而不是返回 `undefined` 让站源静默走错分支；
 * - 站源必须是**同步**的；返回 Promise 会被明确判错（异步站源需另开 ABI）。
 */

const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const { parentPort, workerData } = require('node:worker_threads');

/** 默认 req 超时（与宿主侧上限同量级）。 */
const DEFAULT_TIMEOUT_MS = 15000;

// 与宿主 host.js 一致：Atomics 只能存取 32 位整数（字符串会被截断成 0）。
const STATUS_OK = 1;
const STATUS_NETWORK_ERROR = 2;
const STATUS_TOO_LARGE = 3;

/** 脚本层方法名 → 宿主层方法名。 */
const SCRIPT_METHODS = {
  home: 'homeContent',
  category: 'categoryContent',
  detail: 'detailContent',
  search: 'searchContent',
  play: 'playerContent',
};

/** Android/浏览器专有全局：明确报错，不静默返回 undefined（§9.8）。 */
const UNSUPPORTED_GLOBALS = {
  getWebViewUrl: '需要 WebView 内核，桌面端无等价物（§5.8）',
  getWebViewUA: '需要 WebView 内核，桌面端无等价物（§5.8）',
  getWebViewTitles: '需要 WebView 内核，桌面端无等价物（§5.8）',
  startThunder: '迅雷下载是 Android 专有能力，桌面端不支持',
  js2Proxy: '本地代理会话尚未开放给 JS 站源（§9.6）',
  getPort: '本地代理会话尚未开放给 JS 站源（§9.6）',
  getProxyUrl: '本地代理会话尚未开放给 JS 站源（§9.6）',
  toast: 'UI 反馈由宿主负责，站源不得直接操作 UI（§9.8）',
  dialogs: 'UI 反馈由宿主负责，站源不得直接操作 UI（§9.8）',
  confirm: 'UI 反馈由宿主负责，站源不得直接操作 UI（§9.8）',
  refreshUI: 'UI 反馈由宿主负责，站源不得直接操作 UI（§9.8）',
  richMessage: '跨进程富文本通道尚未实现',
  setClipboard: '剪贴板权限（clipboard=false）未授予站源（§9.8）',
  getClipboard: '剪贴板权限（clipboard=false）未授予站源（§9.8）',
};

class ScriptError extends Error {
  constructor(message, details = {}) {
    super(message);
    this.name = 'ScriptError';
    this.details = details;
  }
}

class UnsupportedGlobalError extends Error {
  constructor(name, reason) {
    super(`站源调用了桌面端未实现的全局 ${name}()：${reason}`);
    this.name = 'UnsupportedGlobalError';
  }
}

/** 在途 req：id → { sab, state, metaPath, bodyPath }。 */
const pendingRequests = new Map();
let requestSequence = 0;
let shuttingDown = false;

const workDir = workerData.workDir;
const responseDir = path.join(workDir, 'responses');
fs.mkdirSync(responseDir, { recursive: true });

const log = (message) => {
  // 日志只能写 stderr（§9.3.1）；由宿主的 stderr 管道落到站点日志文件。
  process.stderr.write(`[sandbox] ${message}\n`);
};

// ---------------------------------------------------------------------------
// 同步 req：阻塞本线程，等主线程完成异步 HTTP 后唤醒
// ---------------------------------------------------------------------------

function syncRequest(url, options) {
  const opts = options || {};
  const target = typeof url === 'string' ? url : String(url);
  const timeoutMs =
    Number(opts.timeout) > 0 ? Number(opts.timeout) : DEFAULT_TIMEOUT_MS;
  const id = `r${requestSequence++}`;
  const sab = new SharedArrayBuffer(4);
  const state = new Int32Array(sab);
  const metaPath = path.join(responseDir, `${id}.json`);
  const bodyPath = path.join(responseDir, `${id}.body`);

  pendingRequests.set(id, { sab, state, metaPath, bodyPath });
  parentPort.postMessage({
    type: 'req',
    id,
    sab,
    url: target,
    metaPath,
    bodyPath,
    options: {
      method: opts.method || 'GET',
      headers: opts.headers || {},
      body: opts.body,
      timeoutMs,
    },
  });

  // 阻塞本线程；主线程的事件循环不受影响（这正是分线程的原因）。
  // 宿主侧另有进程级超时兜底，这里多加 5s 余量避免与宿主超时竞争。
  const wait = Atomics.wait(state, 0, 0, timeoutMs + 5000);
  pendingRequests.delete(id);
  if (wait === 'timed-out') {
    cleanupFiles(metaPath, bodyPath);
    throw new ScriptError(
      `req 超时（${timeoutMs}ms）：${safeUrl(target)}`,
      { stage: 'req', timeoutMs },
    );
  }

  const status = Atomics.load(state, 0);
  let meta = {};
  try {
    meta = JSON.parse(fs.readFileSync(metaPath, 'utf8'));
  } catch {
    meta = {};
  }
  const cleanup = () => cleanupFiles(metaPath, bodyPath);

  if (status === STATUS_TOO_LARGE) {
    cleanup();
    throw new ScriptError(meta.error || '响应超过大小上限', { stage: 'req' });
  }
  if (status === STATUS_NETWORK_ERROR) {
    cleanup();
    throw new ScriptError(
      `req 网络失败：${meta.error || '未知错误'} ${safeUrl(target)}`,
      { stage: 'req' },
    );
  }
  if (status !== STATUS_OK) {
    cleanup();
    throw new ScriptError(`req 未知状态：${status}`, { stage: 'req' });
  }

  let body = '';
  try {
    body = fs.readFileSync(bodyPath, 'utf8');
  } catch (error) {
    // 0 字节响应是合法的（例如 204），不算错误。
    if (error.code !== 'ENOENT') {
      cleanup();
      throw new ScriptError(`req 读取响应失败：${error.message}`, { stage: 'req' });
    }
  }
  cleanup();
  return body;
}

function cleanupFiles(...paths) {
  for (const target of paths) {
    try {
      fs.rmSync(target, { force: true });
    } catch {
      // 清理失败不影响本次结果。
    }
  }
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
// 沙箱
// ---------------------------------------------------------------------------

function createContext(sandboxName, storage) {
  const sandbox = {};
  const context = vm.createContext(sandbox, {
    name: `spider:${sandboxName}`,
    codeGeneration: { strings: true, wasm: false },
  });

  // 宿主注入的工具。
  sandbox.req = (url, options) => syncRequest(url, options);
  sandbox.log = (message) => log(String(message));
  sandbox.setItem = (key, value) => {
    storage.set(String(key), String(value));
    return true;
  };
  sandbox.getItem = (key) => (storage.has(String(key)) ? storage.get(String(key)) : null);
  sandbox.delItem = (key) => storage.delete(String(key));

  // Android/浏览器专有全局：明确报错（§9.8：不得静默返回 undefined）。
  for (const [name, reason] of Object.entries(UNSUPPORTED_GLOBALS)) {
    sandbox[name] = () => {
      throw new UnsupportedGlobalError(name, reason);
    };
  }

  // 无副作用的原生对象（站源常用做解析/编码）。
  for (const name of [
    'JSON', 'Math', 'Date', 'RegExp', 'String', 'Number', 'Boolean', 'Array',
    'Object', 'Error', 'TypeError', 'RangeError', 'Map', 'Set', 'Promise',
    'Symbol', 'WeakMap', 'WeakSet',
  ]) {
    sandbox[name] = globalThis[name];
  }
  for (const name of [
    'parseInt', 'parseFloat', 'isNaN', 'isFinite', 'encodeURIComponent',
    'decodeURIComponent', 'encodeURI', 'decodeURI', 'escape', 'unescape',
  ]) {
    sandbox[name] = globalThis[name];
  }

  // console 必须组装在 context 内，不能直接塞宿主 console 对象。
  context.__log = (message) => log(String(message));
  vm.runInContext(
    'var console = { log: __log, info: __log, warn: __log, error: __log, debug: __log };',
    context,
  );
  // 站源常见 `module.exports = {...}` / `module.exports = ...` 写法。
  vm.runInContext('var module = { exports: {} }; var exports = module.exports;', context);
  // `globalThis` 在沙箱里指向 context 自身，站源常用它挂全局。
  vm.runInContext('var globalThis = this;', context);

  return context;
}

function loadSpider({ entryPath }) {
  let source;
  try {
    source = fs.readFileSync(entryPath, 'utf8');
  } catch (error) {
    throw new ScriptError(`站源文件无法读取：${entryPath}`, { cause: error.message });
  }
  const storage = new Map();
  const context = createContext(spiderKey, storage);
  try {
    // 与 TVBox 一致：脚本在全局作用域执行，导出的函数成为 context 属性。
    new vm.Script(source, { filename: entryPath }).runInContext(context);
  } catch (error) {
    throw new ScriptError(`站源加载失败：${error.message}`, {
      stage: 'load',
      filename: entryPath,
    });
  }
  // 把 `module.exports` 上的函数提升到全局（两种导出口都支持）。
  const exported = context.module && context.module.exports;
  if (exported && typeof exported === 'object') {
    for (const [name, value] of Object.entries(exported)) {
      if (typeof value === 'function' && !(name in context)) {
        context[name] = value;
      }
    }
  }
  return { context, storage };
}

let spiderContext = null;
let spiderStorage = null;

/// 站点 key（来自 manifest），仅用于诊断名称。
let spiderKey = 'js-spider';

function scriptArgs(hostMethod, params) {
  const p = params || {};
  switch (hostMethod) {
    case 'home':
      // TVBox: homeContent(filter)
      return [Boolean(p.filter)];
    case 'category':
      // TVBox: categoryContent(tid, pg, filter, extend)
      return [
        String(p.id ?? p.tid ?? ''),
        String(p.page ?? '1'),
        Boolean(p.filter),
        p.filters && typeof p.filters === 'object' ? p.filters : {},
      ];
    case 'detail':
      // TVBox: detailContent(ids) —— 数组
      return [Array.isArray(p.ids) ? p.ids : [String(p.id ?? '')]];
    case 'search':
      // TVBox: searchContent(key, quick, pg)
      return [
        String(p.keyword ?? p.wd ?? ''),
        Boolean(p.quick),
        p.page == null ? '1' : String(p.page),
      ];
    case 'play':
      // TVBox: playerContent(flag, id, vipFlags)
      return [String(p.flag ?? ''), String(p.id ?? ''), []];
    default:
      return [];
  }
}

/** 站源返回值 → 宿主期望的 Result 形状（§8.3）。 */
function normalizeResult(result, hostMethod) {
  const scriptMethod = SCRIPT_METHODS[hostMethod];
  if (result == null) {
    // TVBox 站源常在无数据时返回 null；映射为空 Result 而不是错误。
    return { list: [] };
  }
  if (typeof result !== 'object' || Array.isArray(result)) {
    if (Array.isArray(result)) return { list: result };
    throw new ScriptError(
      `站源 ${scriptMethod}() 返回了非对象值：${typeof result}`,
      { hostMethod },
    );
  }
  const out = { list: [] };
  if (Array.isArray(result.class)) out.class = result.class;
  if (result.filters && typeof result.filters === 'object') out.filters = result.filters;
  if (Array.isArray(result.list)) out.list = result.list;
  if (result.page != null) out.page = result.page;
  if (result.pagecount != null) out.pagecount = result.pagecount;
  if (result.limit != null) out.limit = result.limit;
  if (result.total != null) out.total = result.total;
  if (hostMethod === 'play') {
    // 播放结果是扁平对象（url/header/parse/…），不是 list。
    return { ...out, ...result, list: [] };
  }
  return out;
}

function wrapError(error, hostMethod) {
  if (error instanceof UnsupportedGlobalError) {
    return new ScriptError(error.message, { hostMethod, unsupportedGlobal: true });
  }
  if (error instanceof ScriptError) return error;
  const message = error && error.message ? error.message : String(error);
  return new ScriptError(
    `站源 ${SCRIPT_METHODS[hostMethod] || hostMethod}() 抛出异常：${message}`,
    {
      hostMethod,
      scriptStack:
        error && error.stack
          ? String(error.stack).split('\n').slice(0, 6).join(' | ')
          : undefined,
    },
  );
}

function callMethod(hostMethod, params) {
  const scriptMethod = SCRIPT_METHODS[hostMethod];
  if (!scriptMethod) throw new ScriptError(`未实现的方法：${hostMethod}`);
  const fn = spiderContext[scriptMethod];
  if (typeof fn !== 'function') {
    throw new ScriptError(
      `站源未导出 ${scriptMethod}()（宿主方法 ${hostMethod}）`,
      { scriptMethod, hostMethod },
    );
  }
  let result;
  try {
    result = fn.apply(spiderContext, scriptArgs(hostMethod, params));
  } catch (error) {
    throw wrapError(error, hostMethod);
  }
  // 只支持同步站源：把 Promise 当结果序列化会得到 {}，那才是真正的静默失败。
  if (result && typeof result.then === 'function') {
    throw new ScriptError(
      `站源 ${scriptMethod}() 返回 Promise；桌面端只支持同步站源（异步站源需另开 ABI）`,
      { hostMethod },
    );
  }
  return normalizeResult(result, hostMethod);
}

// ---------------------------------------------------------------------------
// 与宿主主线程的消息循环
// ---------------------------------------------------------------------------

parentPort.on('message', (message) => {
  if (!message || typeof message !== 'object') return;
  if (message.type === 'load') {
    try {
      const manifest = message.manifest || {};
      spiderKey = String(manifest.key || 'js-spider');
      const { context, storage } = loadSpider({ entryPath: message.entryPath });
      spiderContext = context;
      spiderStorage = storage;
      if (typeof context.init === 'function') {
        context.__spiderInit = context.init;
      }
      parentPort.postMessage({ type: 'loaded', ok: true });
    } catch (error) {
      parentPort.postMessage({
        type: 'loaded',
        ok: false,
        error: error.message,
        details: error.details || {},
      });
    }
    return;
  }

  if (message.type === 'init') {
    try {
      const extend = message.extend == null ? '' : String(message.extend);
      if (typeof spiderContext.__spiderInit === 'function') {
        spiderContext.__spiderInit.call(spiderContext, extend);
      }
      parentPort.postMessage({ type: 'init-result', ok: true });
    } catch (error) {
      parentPort.postMessage({
        type: 'init-result',
        ok: false,
        error: error.message,
      });
    }
    return;
  }

  if (message.type === 'call') {
    const { id, method, params } = message;
    try {
      const result = callMethod(method, params);
      parentPort.postMessage({ type: 'call-result', id, ok: true, result });
    } catch (error) {
      parentPort.postMessage({
        type: 'call-result',
        id,
        ok: false,
        error: error.message,
        details: error.details || {},
        scriptError: error instanceof ScriptError,
      });
    }
    return;
  }

  if (message.type === 'shutdown') {
    shuttingDown = true;
    if (spiderStorage) spiderStorage.clear();
    cleanupFiles(...[...pendingRequests.values()].flatMap((p) => [p.metaPath, p.bodyPath]));
    pendingRequests.clear();
    try {
      fs.rmSync(responseDir, { recursive: true, force: true });
    } catch {
      // 忽略：工作目录由宿主清理。
    }
    parentPort.postMessage({ type: 'shutdown-done' });
    process.exit(0);
  }
});

parentPort.postMessage({ type: 'ready' });
void shuttingDown;
