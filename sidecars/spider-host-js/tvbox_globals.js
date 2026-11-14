'use strict';
/**
 * TVBox 生态的 JavaScript 全局面（只在 `runtime: node-tvbox` 下安装）。
 *
 * # 为什么单独一个文件
 *
 * `sandbox_worker.js` 是沙箱进程的核心，必须**零第三方依赖**：它要能在最小安装里启动，
 * 且它的 require 面越小，沙箱边界越好审计。第三方库（cheerio / crypto-js）只在这里被
 * **惰性** require —— 站源不碰 `pdfh` / `CryptoJS` 时，两个库连模块文件都不会加载。
 *
 * # 注入面
 *
 * | 名字 | 说明 |
 * | --- | --- |
 * | `pdfh(html, rule, base?)` | 取**第一个**匹配值（字符串），没有匹配返回 `''` |
 * | `pdfa(html, rule, base?)` | 取**所有**匹配值（字符串数组） |
 * | `pd(html, rule, base?)` | 取对象数组，`rule` 形如 `节点;key&&链;key2&&链` |
 * | `pdfla(html, rule, base?)` | `pd` 的别名（海阔里两者等价） |
 * | `cheerio` | cheerio 模块本身（惰性 getter） |
 * | `CryptoJS` | crypto-js 模块本身（惰性 getter） |
 * | `md5/sha1/sha256` | 十六进制摘要 |
 * | `base64Encode/base64Decode/btoa/atob` | Base64 编解码（`atob` 返回 latin1 二进制串） |
 * | `joinUrl(base, url)` | 拼接 URL，处理绝对地址、`//host`、`/path`、相对路径 |
 * | `local.get/set/del` | 别名到宿主的 `getItem`/`setItem`/`delItem` |
 * | `print` | 别名到 `log` |
 *
 * # `pdfh` / `pdfa` / `pd` 的规则子集（**不可能 1:1 对齐海阔 DSL，如实记录**）
 *
 * 规则形式：`节点链[;提取规则]`，链内分段用 `&&` 或 `>>`。
 *
 * - 节点链的分段是标准 CSS 选择器（`div.item`、`.cls`、`#id`、`ul li`、`tag[attr=val]`、
 *   `:eq(n)` / `:first` / `:last` 由 cheerio 提供），逐段做**后代**查找；
 * - 分段也可以是提取指令，出现即终止链：
 *   - `Text`/`text`/`ownText` → 文本（`ownText` 只取直接文本）
 *   - `Html`/`html` → innerHTML
 *   - `outerHtml`/`OuterHtml` → outerHTML
 *   - `Tag`/`tag` → 标签名
 *   - 其它纯标识符（如 `href`、`src`、`data-original`）→ 取属性值；
 *     为了避免和标签选择器混淆，**已知 HTML 标签名一律当选择器**（`a`、`span`、`img`…），
 *     要取属性请写成属性名（`href`）而不是标签名；
 * - 属性值为相对地址且给了 `base` 时，用 `joinUrl` 补成绝对地址；
 * - 不带提取指令时，`pdfa` 返回每个匹配节点的 outerHTML 字符串，`pdfh` 返回第一个。
 *
 * ## 已知不支持
 *
 * - 海阔的**函数式规则**：`Type`/`Json`/`Regex`/`Url`/`Join`/`Select`/`Get`/`Page` 等；
 * - `{{...}}` 模板、`||` 回退、`$` 通配、多结果结构化返回（`pdfa` 只返回字符串数组，
 *   不返回 `[节点, 值, …]` 结构）；
 * - `:contains()` / `:has()` 之外的复杂伪类与 jQuery 扩展（cheerio 支持的子集以外）；
 * - 不提供 `getMubans` / `similarity` / `gbk`：GBK 解码走 `req` 的 `charset: 'gbk'` 选项
 *   （Node 内置 full-icu `TextDecoder`），不需要 gbk.js；
 * - 没有解析缓存：同一段 HTML 重复 `pdfh` 会重复解析。TVBox 站源的调用量下这不是热点。
 */

// ---------------------------------------------------------------------------
// 惰性第三方依赖
// ---------------------------------------------------------------------------

let cheerioModule = null;
let cryptoJsModule = null;

function loadCheerio() {
  if (cheerioModule) return cheerioModule;
  try {
    cheerioModule = require('cheerio');
  } catch (error) {
    throw new Error(
      `TVBox 全局面需要 cheerio，但 sidecar 目录下没有安装：${error.message}`,
    );
  }
  return cheerioModule;
}

function loadCryptoJs() {
  if (cryptoJsModule) return cryptoJsModule;
  try {
    cryptoJsModule = require('crypto-js');
  } catch (error) {
    throw new Error(
      `TVBox 全局面需要 crypto-js，但 sidecar 目录下没有安装：${error.message}`,
    );
  }
  return cryptoJsModule;
}

// ---------------------------------------------------------------------------
// pdfh / pdfa / pd 的规则子集
// ---------------------------------------------------------------------------

const CHAIN_SEPARATOR = /&&|>>/;

/** 已知 HTML 标签：这些分段一律当选择器，不当属性名。 */
const HTML_TAGS = new Set([
  'a', 'abbr', 'article', 'aside', 'audio', 'b', 'base', 'blockquote', 'body',
  'br', 'button', 'canvas', 'code', 'dd', 'div', 'dl', 'dt', 'em', 'fieldset',
  'figcaption', 'figure', 'footer', 'form', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
  'head', 'header', 'hr', 'html', 'i', 'iframe', 'img', 'input', 'label', 'li',
  'link', 'main', 'meta', 'nav', 'ol', 'option', 'p', 'path', 'pre', 'script',
  'section', 'select', 'small', 'source', 'span', 'strong', 'style', 'svg',
  'table', 'tbody', 'td', 'textarea', 'tfoot', 'th', 'thead', 'title', 'tr',
  'u', 'ul', 'video',
]);

const DIRECTIVE_TEXT = new Set(['text', 'owntext', 'thetext']);
const DIRECTIVE_HTML = new Set(['html', 'innerhtml']);
const DIRECTIVE_OUTER = new Set(['outerhtml', 'taghtml']);
const DIRECTIVE_TAG = new Set(['tag', 'tagname']);

/** 需要拼绝对地址的属性。 */
const URL_ATTRIBUTES = new Set([
  'href', 'src', 'data-original', 'data-src', 'data-url', 'poster', 'action',
]);

function isAttributeName(segment) {
  return /^[A-Za-z_][\w:.-]*$/.test(segment) && !HTML_TAGS.has(segment.toLowerCase());
}

function hasSelectorSyntax(segment) {
  return /[.#[\]:*>\s~+,()]/.test(segment);
}

/** 拼 URL：绝对地址原样返回，协议相对、根相对、相对路径分别处理。 */
function joinUrl(base, url) {
  const raw = url === undefined || url === null ? '' : String(url).trim();
  if (!raw) return '';
  if (/^[a-zA-Z][\w+.-]*:\/\//.test(raw)) return raw;
  const origin = String(base === undefined || base === null ? '' : base).trim();
  if (raw.startsWith('//')) {
    const scheme = /^([a-zA-Z][\w+.-]*):/.exec(origin);
    return `${scheme ? scheme[1] : 'http'}:${raw}`;
  }
  if (!origin) return raw;
  try {
    return new URL(raw, origin).toString();
  } catch {
    const trimmed = origin.replace(/[^/]*$/, '');
    return trimmed ? trimmed + raw.replace(/^\/+/, '') : raw;
  }
}

/**
 * 读一个节点的值。
 *
 * @param {object} $ cheerio 实例
 * @param {object} node DOM 节点
 * @param {string} directive 已归一化的指令（`text` / `html` / `outerhtml` / `tag` / 属性名）
 * @param {string} base 拼接用的基准地址
 */
function readNodeValue($, node, directive, base) {
  const holder = $(node);
  if (DIRECTIVE_TEXT.has(directive)) return holder.text().trim();
  if (DIRECTIVE_HTML.has(directive)) return holder.html() ?? '';
  if (DIRECTIVE_OUTER.has(directive)) return $.html(node);
  if (DIRECTIVE_TAG.has(directive)) return node.tagName || node.name || '';
  const value = holder.attr(directive);
  if (value === undefined || value === null) return '';
  if (base && URL_ATTRIBUTES.has(directive)) return joinUrl(base, value);
  return String(value);
}

/** 分段的指令归一化；返回 null 表示「这是个选择器」。 */
function directiveOf(segment) {
  const lower = segment.toLowerCase();
  if (DIRECTIVE_TEXT.has(lower)) return 'text';
  if (DIRECTIVE_HTML.has(lower)) return 'html';
  if (DIRECTIVE_OUTER.has(lower)) return 'outerhtml';
  if (DIRECTIVE_TAG.has(lower)) return 'tag';
  if (!hasSelectorSyntax(segment) && isAttributeName(segment)) return lower;
  return null;
}

function toSelection(html) {
  const source = html === undefined || html === null ? '' : String(html);
  // 站点常把整页 HTML 或片段直接丢进来；cheerio.load 对两者都能处理。
  return loadCheerio().load(source);
}

/**
 * 在给定节点集合上跑一条链，返回字符串数组。
 *
 * @returns {string[]} 每个命中节点的提取结果
 */
function runChain($, nodes, segments, base) {
  let current = nodes;
  for (let index = 0; index < segments.length; index += 1) {
    const segment = segments[index];
    const directive = directiveOf(segment);
    if (directive === null) {
      current = current.find(segment);
      continue;
    }
    const values = [];
    current.each((_, node) => {
      const value = readNodeValue($, node, directive, base);
      if (value !== '' && value !== undefined) values.push(String(value));
    });
    return values;
  }
  // 链里没有提取指令：返回每个命中节点的 outerHTML。
  const values = [];
  current.each((_, node) => values.push($.html(node)));
  return values;
}

function splitRule(rule) {
  return String(rule === undefined || rule === null ? '' : rule)
    .split(';')
    .map((part) => part.trim())
    .filter((part) => part.length > 0);
}

function segmentsOf(part) {
  return part.split(CHAIN_SEPARATOR).map((segment) => segment.trim()).filter((s) => s);
}

/** `pdfa` 的实现：一段规则 → 字符串数组。 */
function extractAll(html, rule, base) {
  const $ = toSelection(html);
  const parts = splitRule(rule);
  if (parts.length === 0) return [];
  const head = segmentsOf(parts[0]);
  if (head.length === 0) return [];

  // 第一段若是选择器，从文档根下降；若已经是指令（`Text`），则直接作用于根节点。
  const firstIsDirective = directiveOf(head[0]) !== null;
  const nodes = firstIsDirective ? $.root() : $.root().find(head[0]);
  const rest = firstIsDirective ? head : head.slice(1);
  const values = runChain($, nodes, rest, base);
  if (parts.length === 1 || firstIsDirective) return values;

  // 额外分段：`div.item;img&&src` 这类写法，对每个节点片段再跑一条链。
  const extra = parts.slice(1).flatMap(segmentsOf);
  if (extra.length === 0) return values;
  const nested = [];
  for (const value of values) {
    const sub = toSelection(value);
    for (const item of runChain(sub, sub.root(), extra, base)) nested.push(item);
  }
  return nested;
}

/** `pdfh`：第一个匹配值。 */
function pdfh(html, rule, base) {
  const values = extractAll(html, rule, base);
  return values.length > 0 ? values[0] : '';
}

/** `pdfa`：所有匹配值。 */
function pdfa(html, rule, base) {
  return extractAll(html, rule, base);
}

/**
 * `pd`：把 `节点;key&&链;key2&&链` 展开成对象数组。
 *
 * 与 `pdfa` 的区别只在返回结构：`pd` 对**节点**去重，每个节点产出一个对象。
 */
function pd(html, rule, base) {
  const parts = splitRule(rule);
  if (parts.length === 0) return [];
  const nodeSegments = segmentsOf(parts.shift());
  const fields = parts.map((part) => {
    const segments = segmentsOf(part);
    return { key: segments.shift(), segments };
  });
  const $ = toSelection(html);
  const roots = nodeSegments.length > 0 ? $.root().find(nodeSegments[0]) : $.root();
  const remainder = nodeSegments.slice(1);
  const list = [];
  roots.each((_, node) => {
    let scope = $(node);
    for (const segment of remainder) {
      if (directiveOf(segment) !== null) break;
      scope = scope.find(segment);
    }
    const item = {};
    for (const field of fields) {
      if (!field.key || field.segments.length === 0) continue;
      const values = runChain($, scope, field.segments, base);
      item[field.key] = values.length > 0 ? values[0] : '';
    }
    list.push(item);
  });
  return list;
}

// ---------------------------------------------------------------------------
// 安装
// ---------------------------------------------------------------------------

/**
 * 往 vm context 注入 TVBox 生态全局面。
 *
 * @param {object} context `vm.createContext` 返回的上下文
 * @param {{log?: Function, storage?: Map<string,string>}} deps 宿主注入的依赖
 */
function installTvboxGlobals(context, deps) {
  const options = deps || {};
  const log = typeof options.log === 'function' ? options.log : () => {};
  const storage = options.storage instanceof Map ? options.storage : new Map();

  const getItem = (key) => (storage.has(String(key)) ? storage.get(String(key)) : null);
  const setItem = (key, value) => {
    storage.set(String(key), String(value));
    return true;
  };
  const delItem = (key) => storage.delete(String(key));

  context.pdfh = (html, rule, base) => pdfh(html, rule, base);
  context.pdfa = (html, rule, base) => pdfa(html, rule, base);
  context.pd = (html, rule, base) => pd(html, rule, base);
  context.pdfla = (html, rule, base) => pd(html, rule, base);
  context.joinUrl = (base, url) => joinUrl(base, url);
  context.print = (message) => log(String(message));

  context.local = {
    get: (key) => getItem(key),
    set: (key, value) => setItem(key, value),
    del: (key) => delItem(key),
  };

  const crypto = () => loadCryptoJs();
  context.md5 = (text) => crypto().MD5(String(text)).toString();
  context.sha1 = (text) => crypto().SHA1(String(text)).toString();
  context.sha256 = (text) => crypto().SHA256(String(text)).toString();
  context.base64Encode = (text) => Buffer.from(String(text), 'utf8').toString('base64');
  context.base64Decode = (text) => Buffer.from(String(text), 'base64').toString('utf8');
  context.btoa = (text) => Buffer.from(String(text), 'latin1').toString('base64');
  context.atob = (text) => Buffer.from(String(text), 'base64').toString('latin1');

  // cheerio / CryptoJS 用惰性 getter：站源不碰它们就不付加载成本。
  for (const [name, loader] of [['cheerio', loadCheerio], ['CryptoJS', loadCryptoJs]]) {
    Object.defineProperty(context, name, {
      configurable: true,
      enumerable: true,
      get: loader,
    });
  }

  return context;
}

module.exports = { installTvboxGlobals, joinUrl, pdfh, pdfa, pd };
