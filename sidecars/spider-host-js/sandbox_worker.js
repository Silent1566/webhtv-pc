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
 * - `req` 返回**混合对象**：既能当响应体字符串用（`String(r)`、`JSON.parse(r)`、
 *   `r.length`，对齐 `runtime: node` 的旧语义），又能读取 `r.content` / `r.status` /
 *   `r.headers` / `r.url`（对齐 TVBox 生态）；`{buffer:true}` 直接返回 Buffer；
 * - Android/浏览器专有全局（`getWebViewUrl`、`startThunder`、`js2Proxy` 等）会抛出
 *   明确的「桌面端未实现」，而不是返回 `undefined` 让站源静默走错分支；
 * - 站源必须是**同步**的；返回 Promise 会被明确判错（异步站源需另开 ABI）。
 */

const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const { parentPort, workerData } = require('node:worker_threads');
const esmShim = require('./esm_shim');

/** 默认 req 超时（与宿主侧上限同量级）。 */
const DEFAULT_TIMEOUT_MS = 15000;

/** 单个 req 的超时上限，与 host.js 的 `_deadlineOf` 上限（120s）对齐。 */
const MAX_REQUEST_TIMEOUT_MS = 120000;

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

/**
 * TVBox 生态按**秒**传 `timeout`（`{timeout: 5}` 指 5 秒），宿主内部按毫秒。
 * 判据：小于 1000 视为秒，否则视为毫秒（bili.js 传 10000 即 10 秒）。
 * 结果夹在 [1s, 120s]：既不让 0.05 被当成 50ms，也不让站点写出天文数字。
 */
function resolveTimeoutMs(raw) {
  const value = Number(raw);
  if (!Number.isFinite(value) || value <= 0) return DEFAULT_TIMEOUT_MS;
  const ms = value < 1000 ? value * 1000 : value;
  return Math.min(Math.max(Math.round(ms), 1000), MAX_REQUEST_TIMEOUT_MS);
}

/** 把 TVBox 的 `data` / `postType` 折成宿主认识的请求体字符串。 */
function buildRequestBody(opts) {
  const data = opts.data;
  if (data === undefined || data === null) return opts.body;
  if (typeof data === 'string') return data;
  const postType = String(opts.postType || 'form').toLowerCase();
  if (postType === 'json') return JSON.stringify(data);
  if (postType === 'form') {
    return Object.keys(data)
      .map((key) => `${encodeURIComponent(key)}=${encodeURIComponent(data[key] ?? '')}`)
      .join('&');
  }
  return String(data);
}

/** 按 `charset` 解码响应体；gbk 走 Node 内置 full-ICU 的 TextDecoder，不移植 gbk.js。 */
function decodeBody(buffer, charset) {
  const encoding = String(charset || '').trim().toLowerCase();
  if (!encoding || encoding === 'utf-8' || encoding === 'utf8') {
    return buffer.toString('utf8');
  }
  try {
    return new TextDecoder(encoding).decode(buffer);
  } catch {
    // 不认识的编码退化为 UTF-8，留日志便于排查，不让站源整个失败。
    log(`req 不认识的 charset=${encoding}，回退 UTF-8`);
    return buffer.toString('utf8');
  }
}

/**
 * 构造 req 的返回值：**同一个对象**既要能当字符串用（fixture_spider 的裸字符串语义），
 * 又要能当 TVBox 响应对象用（bili.js 读 `res.content`）。
 * 关键在 `Symbol.toPrimitive`：`String(r)` 与 `JSON.parse(r)` 都拿到正文字符串。
 */
function buildResponse(buffer, opts, meta, target) {
  // `buffer: true` 直接给 Buffer，站点要自己按二进制处理（TVBox 同语义）。
  if (opts.buffer === true) return buffer;
  const content = decodeBody(buffer, opts.charset);
  const statusCode = Number(meta.statusCode) || 0;
  const response = {
    content,
    body: content,
    status: statusCode,
    code: statusCode,
    ok: statusCode >= 200 && statusCode < 400,
    headers: meta.headers && typeof meta.headers === 'object' ? meta.headers : {},
    url: meta.finalUrl || target,
    length: content.length,
    toString() {
      return content;
    },
    valueOf() {
      return content;
    },
  };
  Object.defineProperty(response, Symbol.toPrimitive, {
    value(hint) {
      return hint === 'number' ? content.length : content;
    },
    enumerable: false,
  });
  return response;
}

function syncRequest(url, options) {
  const opts = options || {};
  const target = typeof url === 'string' ? url : String(url);
  const timeoutMs = resolveTimeoutMs(opts.timeout);
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
      body: buildRequestBody(opts),
      timeoutMs,
      // TVBox 的 `redirect: 0` 表示不跟随跳转，把 3xx 原样交回站源。
      followRedirect: opts.redirect !== 0 && opts.redirect !== '0',
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

  let raw = Buffer.alloc(0);
  try {
    raw = fs.readFileSync(bodyPath);
  } catch (error) {
    // 0 字节响应是合法的（例如 204），不算错误。
    if (error.code !== 'ENOENT') {
      cleanup();
      throw new ScriptError(`req 读取响应失败：${error.message}`, { stage: 'req' });
    }
  }
  cleanup();
  return buildResponse(raw, opts, meta, target);
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

function createContext(sandboxName, storage, options) {
  const tvbox = Boolean(options && options.tvbox);
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

  // TVBox 全局面只在 `node-tvbox` 运行时安装：`runtime: node` 的可见全局必须与
  // 旧版逐字一致，多注入一个全局都算行为变化。惰性 require 同时保证 node 运行时
  // 完全不加载 cheerio / crypto-js。
  if (tvbox) {
    const { installTvboxGlobals } = require('./tvbox_globals');
    installTvboxGlobals(context, { log, storage });
  }

  return context;
}

// ---------------------------------------------------------------------------
// node-tvbox 运行时：ESM 模块系统 + 站源入口发现
// ---------------------------------------------------------------------------

/** `__jsEvalReturn()` 返回的短名 → 脚本层规范名（`callMethod` 按规范名查找）。 */
const SHORT_TO_SCRIPT = {
  home: 'homeContent',
  category: 'categoryContent',
  detail: 'detailContent',
  search: 'searchContent',
  play: 'playerContent',
};

/** 合格蜘蛛至少要有一半的取数方法，否则说明入口找错了。 */
const SPIDER_METHODS = ['home', 'homeVod', 'category', 'detail', 'search', 'play'];

function isSpiderLike(value) {
  if (!value || typeof value !== 'object') return false;
  const hits = SPIDER_METHODS.filter((name) => typeof value[name] === 'function');
  return hits.length >= 3;
}

/**
 * 四级入口发现，顺序固定，前一级命中就不再看后面：
 *   1. `module.exports.__jsEvalReturn()` —— CatVod/TVBox 生态的标准出口；
 *   2. `module.exports.default` —— ESM 默认导出；
 *   3. 名字里含 `spider` 的导出 —— 常见命名习惯；
 *   4. 模块内唯一函数 —— 兜底：只有一个可调用导出时它就是入口。
 * 每一级都要过 `isSpiderLike` 判定，避免把工具函数误当站源。
 */
function pickSpider(exported) {
  const candidates = [];
  if (exported && typeof exported === 'object') {
    if (typeof exported.__jsEvalReturn === 'function') {
      candidates.push(['module.exports.__jsEvalReturn', exported.__jsEvalReturn]);
    }
    if (exported.default !== undefined) {
      candidates.push(['module.exports.default', exported.default]);
    }
    for (const [name, value] of Object.entries(exported)) {
      if (name === '__jsEvalReturn' || name === 'default') continue;
      if (/spider/i.test(name)) candidates.push([`module.exports.${name}`, value]);
    }
    const functions = Object.entries(exported).filter(
      ([, value]) => typeof value === 'function',
    );
    if (functions.length === 1) {
      candidates.push([`模块内唯一函数 ${functions[0][0]}`, functions[0][1]]);
    }
  }

  for (const [via, value] of candidates) {
    let resolved;
    try {
      resolved = typeof value === 'function' ? value() : value;
    } catch (error) {
      throw new ScriptError(`站源入口 ${via} 调用失败：${error.message}`, {
        stage: 'load',
        entry: via,
      });
    }
    if (isSpiderLike(resolved)) return { spider: resolved, via };
    // `export default { default: spider }` 这类双层包装。
    if (resolved && typeof resolved === 'object' && isSpiderLike(resolved.default)) {
      return { spider: resolved.default, via: `${via}.default` };
    }
  }

  throw new ScriptError(
    '找不到 TVBox 站源入口：module.exports.__jsEvalReturn / default / 含 spider 的导出 / 唯一函数 都没有返回含 home、category、detail 的对象',
    { stage: 'load' },
  );
}

/**
 * 站源模块加载器：ESM 源码 → `esm_shim.transform` → `vm.compileFunction`。
 * 改写后的 `__require(...)` 是**每个模块自己的**局部函数，所以相对路径按模块目录解析，
 * 而不是按站点工作目录。
 */
function createModuleLoader(context, options) {
  const assetsDir = options.assetsDir ? path.resolve(options.assetsDir) : null;
  const cache = new Map();

  function requireFrom(spec, fromDir) {
    const raw = String(spec == null ? '' : spec);
    const resolved = esmShim.resolveSpec(raw, { assetsDir, fromDir });
    if (resolved) return loadFile(resolved);
    // assets:// 缺目录、越界访问都由 resolveSpec 抛出明确错误；走到这里是裸模块名。
    throw new ScriptError(
      `站源 import 了宿主模块 "${raw}"：桌面端不向沙箱开放 require，请改用 req / pdfh / CryptoJS / cheerio 全局面`,
      { stage: 'load', spec: raw },
    );
  }

  function loadFile(filePath) {
    const absolute = path.resolve(filePath);
    const cached = cache.get(absolute);
    if (cached) return cached.exports;

    let source;
    try {
      source = fs.readFileSync(absolute, 'utf8');
    } catch (error) {
      throw new ScriptError(`站源模块无法读取：${absolute}`, {
        stage: 'load',
        filename: absolute,
      });
    }
    let code;
    try {
      code = esmShim.transform(source);
    } catch (error) {
      throw new ScriptError(`站源模块 ESM 改写失败：${absolute}：${error.message}`, {
        stage: 'load',
        filename: absolute,
      });
    }

    const module = { exports: {} };
    // 先入缓存：ESM 循环依赖会拿到半成品导出，比无限递归好。
    cache.set(absolute, module);
    const moduleDir = path.dirname(absolute);
    // 用 `__require` 作形参名，改写出来的 `__require("...")` 自然命中模块局部解析。
    let wrapper;
    try {
      wrapper = vm.compileFunction(
        code,
        ['exports', '__require', 'module', '__filename', '__dirname'],
        { filename: absolute, parsingContext: context },
      );
    } catch (error) {
      throw new ScriptError(`站源模块语法错误：${absolute}：${error.message}`, {
        stage: 'load',
        filename: absolute,
      });
    }
    try {
      wrapper(
        module.exports,
        (spec) => requireFrom(spec, moduleDir),
        module,
        absolute,
        moduleDir,
      );
    } catch (error) {
      if (error && (error.name === 'ScriptError' || error.name === 'UnsupportedGlobalError')) {
        throw error;
      }
      throw new ScriptError(
        `站源模块加载失败：${absolute}：${error && error.message ? error.message : String(error)}`,
        {
          stage: 'load',
          filename: absolute,
          scriptStack:
            error && error.stack
              ? String(error.stack).split('\n').slice(0, 6).join(' | ')
              : undefined,
        },
      );
    }
    return module.exports;
  }

  // `import d from 'x'` 的默认导入互操作（改写产物里用 `__interop`）。
  context.__interop = (value) =>
    value && typeof value === 'object' && value.default !== undefined
      ? value.default
      : value;

  return { loadEntry: (entryPath) => loadFile(path.resolve(entryPath)) };
}

function loadSpider({ entryPath, tvbox, assetsDir }) {
  const storage = new Map();
  const context = createContext(spiderKey, storage, { tvbox });

  if (tvbox) {
    const loader = createModuleLoader(context, { assetsDir });
    const exported = loader.loadEntry(entryPath);
    const { spider, via } = pickSpider(exported);
    // 把蜘蛛对象上的方法提升到全局：`callMethod` 仍按 `SCRIPT_METHODS` 找规范名，
    // 而 `__jsEvalReturn()` 返回的是短名，这里顺带做一次别名映射。
    let hoisted = 0;
    for (const [name, value] of Object.entries(spider)) {
      if (typeof value !== 'function') continue;
      context[name] = value;
      const canonical = SHORT_TO_SCRIPT[name];
      if (canonical && !(canonical in context)) context[canonical] = value;
      hoisted += 1;
    }
    log(`TVBox 站源入口：${via}（提升 ${hoisted} 个方法）`);
    return { context, storage, tvbox: true };
  }

  let source;
  try {
    source = fs.readFileSync(entryPath, 'utf8');
  } catch (error) {
    throw new ScriptError(`站源文件无法读取：${entryPath}`, { cause: error.message });
  }
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
  return { context, storage, tvbox: false };
}

let spiderContext = null;
let spiderStorage = null;

/// 站点 key（来自 manifest），仅用于诊断名称。
let spiderKey = 'js-spider';

/// 当前站源是否走 `node-tvbox` 运行时（决定返回值字符串是否按 JSON 解析）。
let spiderTvbox = false;

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

async function callMethod(hostMethod, params) {
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
    if (result && typeof result.then === 'function') {
      // `node-tvbox` 的站源几乎全是 async（bili.js 12 个方法全 async）。沙箱没有注入
      // 定时器，`await` 只依赖微任务，所以可以直接等——阻塞式 req 仍是同步的。
      // `runtime: node` 保持旧语义：Promise 明确判错，不静默吞掉。
      if (!spiderTvbox) {
        throw new ScriptError(
          `站源 ${scriptMethod}() 返回 Promise；桌面端只支持同步站源（异步站源需另开 ABI）`,
          { hostMethod },
        );
      }
      result = await result;
    }
  } catch (error) {
    throw wrapError(error, hostMethod);
  }
  // TVBox 站源习惯返回 `JSON.stringify(...)` 字符串（bili.js 每个方法都是），
  // 这里只在 node-tvbox 运行时解析：`runtime: node` 下字符串结果仍按旧语义报错。
  if (spiderTvbox && typeof result === 'string') {
    const text = result.trim();
    if (text.length === 0) {
      result = null;
    } else {
      try {
        result = JSON.parse(text);
      } catch {
        throw new ScriptError(
          `站源 ${scriptMethod}() 返回了无法解析的 JSON 字符串：${text.slice(0, 120)}`,
          { hostMethod },
        );
      }
    }
  }
  return normalizeResult(result, hostMethod);
}

// ---------------------------------------------------------------------------
// 与宿主主线程的消息循环
// ---------------------------------------------------------------------------

/**
 * 异步站源的调用串行化：同一个 context 里不允许两条调用交错执行。
 * 同步站源走同一条链（`then` 立即执行），行为与直接调用等价。
 */
let callChain = Promise.resolve();
function serialize(task) {
  const run = callChain.then(task, task);
  callChain = run.then(
    () => {},
    () => {},
  );
  return run;
}

parentPort.on('message', (message) => {
  if (!message || typeof message !== 'object') return;
  if (message.type === 'load') {
    try {
      const manifest = message.manifest || {};
      spiderKey = String(manifest.key || 'js-spider');
      // `node-tvbox` 才装 TVBox 全局面 + ESM 模块系统；`node` 走旧路径。
      const runtime = String(manifest.runtime || workerData.runtime || 'node');
      const tvbox = workerData.tvbox === true || runtime.startsWith('node-tvbox');
      const assetsRoot = message.assetsRoot || workerData.assetsRoot || null;
      const { context, storage } = loadSpider({
        entryPath: message.entryPath,
        tvbox,
        assetsDir: assetsRoot,
      });
      spiderContext = context;
      spiderStorage = storage;
      spiderTvbox = tvbox;
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
    void serialize(async () => {
      try {
        const extend = message.extend == null ? '' : String(message.extend);
        if (typeof spiderContext.__spiderInit === 'function') {
          const outcome = spiderContext.__spiderInit.call(spiderContext, extend);
          // TVBox 站源的 init 常是 async；等它完成再放行后续调用（同步 init 是 no-op）。
          if (outcome && typeof outcome.then === 'function') await outcome;
        }
        parentPort.postMessage({ type: 'init-result', ok: true });
      } catch (error) {
        parentPort.postMessage({
          type: 'init-result',
          ok: false,
          error: error.message,
        });
      }
    });
    return;
  }

  if (message.type === 'call') {
    const { id, method, params } = message;
    void serialize(async () => {
      try {
        const result = await callMethod(method, params);
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
    });
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
