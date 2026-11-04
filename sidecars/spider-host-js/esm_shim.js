'use strict';
/**
 * TVBox JS 站源的 ESM 垫片（`import` / `export` → `vm.compileFunction` 可吃的脚本）。
 *
 * # 为什么需要它
 *
 * 真实 TVBox 站源（含海阔/影视仓生态的 `js_lib`）全部写成 **纯 ESM**：站源首行就是
 * `import { load, _ } from 'assets://js/lib/cat.js';`，而共享库（`cat.js`、
 * `cheerio.min.js`）尾部是 `export{X as Y, ...}`。沙箱用 `new vm.Script(src)` 执行，
 * 遇到 `import` 直接 `SyntaxError: Cannot use import statement outside a module`。
 *
 * 这里把 ESM 表面语法改写成等价的 CJS 表面语法，**不引入任何依赖**：
 *
 * - `import {a, b as c} from 'x'` → `const {a, b: c} = __require("x");`
 * - `import * as ns from 'x'`     → `const ns = __require("x");`
 * - `import d from 'x'`           → `const d = __interop(__require("x"));`
 * - `import d, {a} from 'x'`      → `const {default: d, a} = __require("x");`
 * - `import 'x'`                  → `__require("x");`
 * - `export{X as Y, Z}`           → `Object.assign(module.exports, {Y: X, Z: Z});`
 * - `export function f(){}`       → `function f(){}` + 末尾统一登记
 * - `export [async] function/class/const/let/var NAME` → 去掉 `export` + 末尾登记
 * - `export default <expr>`       → `module.exports.default = <expr>;`
 * - `export * from 'x'`           → `Object.assign(module.exports, __require("x"));`
 *
 * **别名方向**是这里最容易写反的地方：`export{Ch as Crypto}` 的局部名在前、导出名在
 * 后，正确产物是 `{Crypto: Ch}`。反过来写会在加载期炸 `ReferenceError: Crypto is not
 * defined`（已实测）。
 *
 * # 行号语义
 *
 * 所有改写都**不改变换行数量**：单行替换按原地覆盖，跨行语句（例如多行 import 列表）
 * 保留原有的换行；万一某条改写吃掉了换行，用行注释 `//` + 等量空行补齐。这样站源里的
 * 行号与堆栈行号仍然对得上原始文件，便于定位。
 *
 * # 已知不支持（诚实记录）
 *
 * - 扫描器用「上一个有效记号」的上下文启发式识别正则字面量（`= /re/` 是正则，`a / b`
 *   是除号）。它不是完整 parser：极端构造（例如正则里出现未闭合的 `[`）仍可能判错；
 *   实测 cat.js / cheerio.min.js / bili.js 三个文件都改写正确（`/[&"'<>]/g` 这类
 *   带引号的正则必须被正确识别，否则遮罩会整体错位、文件尾部的 export 改写不到）；
 * - `export {a as b} from 'x'` 的重命名导出会退化为整模块展开（导出名不保留）；
 * - 动态 `import()` 不改写（返回 Promise，TVBox 站源不用）；
 * - `import.meta` 不改写（三个实测 bundle 里 0 次）。
 */

const path = require('node:path');

const ASSETS_SCHEME = 'assets://';

// ---------------------------------------------------------------------------
// 字符串 / 注释遮罩：只在「代码」位置做改写，避免把字符串里的 export 当真
// ---------------------------------------------------------------------------

// 正则字面量只在「此处允许出现表达式」时才成立（`= /re/` 是正则，`a / b` 是除号）。
// 这是经典的上下文启发式：不追求覆盖全部语法，只要求它对紧凑打包产物不掉链子。
const REGEX_PRECEDING_CHARS = '(,=:[!&|?{};+-*%~^<>';
const REGEX_PRECEDING_WORDS = new Set([
  'return', 'typeof', 'instanceof', 'in', 'of', 'new', 'delete', 'void',
  'case', 'do', 'else', 'yield', 'await',
]);

function codeMask(source) {
  const mask = new Uint8Array(source.length);
  let i = 0;
  let state = 'code';
  let regexClass = false;
  let prevSigChar = '';
  let prevWord = '';
  let word = '';
  const track = (ch) => {
    if (ch === undefined) return;
    if (/[\w$]/.test(ch)) {
      word += ch;
      // 标识符也算「上一个有效字符」，否则 `d[a/n]` 里的 `/` 会因为前一个
      // 有效字符还停在 `[` 而被误判成正则起点，整个遮罩从这里错位。
      prevSigChar = ch;
      return;
    }
    if (word) {
      prevWord = word;
      word = '';
    }
    if (!/\s/.test(ch)) prevSigChar = ch;
  };
  const regexAllowed = () =>
    prevSigChar === '' ||
    REGEX_PRECEDING_CHARS.includes(prevSigChar) ||
    REGEX_PRECEDING_WORDS.has(prevWord);

  while (i < source.length) {
    const ch = source[i];
    const next = source[i + 1];
    if (state === 'code') {
      mask[i] = 1;
      if (ch === '/' && next === '/') {
        state = 'line';
        i += 2;
        continue;
      }
      if (ch === '/' && next === '*') {
        state = 'block';
        i += 2;
        continue;
      }
      if (ch === '/' && regexAllowed()) {
        // 正则字面量：内部可以有引号（`/[&"'<>]/g` 实测就出现在两个 bundle 里），
        // 若不识别它，遮罩会从这里开始整体错位，文件尾部的 export 就改写不到。
        state = 'regex';
        regexClass = false;
        i += 1;
        continue;
      }
      if (ch === "'") {
        state = 'single';
        i += 1;
        continue;
      }
      if (ch === '"') {
        state = 'double';
        i += 1;
        continue;
      }
      if (ch === '`') {
        state = 'template';
        i += 1;
        continue;
      }
      track(ch);
      i += 1;
      continue;
    }
    if (state === 'line') {
      if (ch === '\n') {
        state = 'code';
        mask[i] = 1;
        prevSigChar = '';
        word = '';
      }
      i += 1;
      continue;
    }
    if (state === 'block') {
      if (ch === '*' && next === '/') {
        state = 'code';
        i += 2;
        continue;
      }
      i += 1;
      continue;
    }
    if (state === 'regex') {
      if (ch === '\\') {
        i += 2;
        continue;
      }
      if (ch === '\n') {
        // 未闭合就换行，说明判错了：退回代码态，宁可多判也不整体错位。
        state = 'code';
        prevSigChar = '';
        word = '';
        i += 1;
        continue;
      }
      if (ch === '[') regexClass = true;
      else if (ch === ']') regexClass = false;
      else if (ch === '/' && !regexClass) {
        state = 'code';
        prevSigChar = '/';
        prevWord = '';
        word = '';
      }
      i += 1;
      continue;
    }
    // single / double / template
    if (ch === '\\') {
      i += 2;
      continue;
    }
    if (
      (state === 'single' && ch === "'") ||
      (state === 'double' && ch === '"') ||
      (state === 'template' && ch === '`')
    ) {
      state = 'code';
      // 字符串整体当作一个「值」，防止 `"..." / 2` 被误判成正则起点。
      prevSigChar = ')';
      prevWord = '';
      word = '';
    }
    i += 1;
  }
  return mask;
}

/**
 * 该位置是否可以安全改写。
 *
 * 遮罩（`codeMask`）是尽力而为的：紧凑打包产物里若有一处构造超出扫描器判断，遮罩会从
 * 那里开始整体错位，文件尾部的 `export{...}` 就会被漏掉（实测 cheerio.min.js 会踩到）。
 * 因此这里再给一条**确定性**的独立判据：模块级 import/export 语句必然出现在语句边界上
 * （行首，或紧跟在 `;` / `}` 之后）。两条判据满足其一即改写 —— 遮罩负责挡住字符串里的
 * 假关键字，语句边界负责兜住遮罩错位。
 */
function isCodeAt(text, mask, index) {
  if (mask[index]) return true;
  let i = index - 1;
  while (i >= 0) {
    const ch = text[i];
    if (ch === ' ' || ch === '\t' || ch === '\r' || ch === '\n' || ch === '\f' || ch === '\v') {
      i -= 1;
      continue;
    }
    return ch === ';' || ch === '}' || ch === '{';
  }
  return true;
}

function countNewlines(text) {
  let total = 0;
  for (let i = 0; i < text.length; i += 1) {
    if (text.charCodeAt(i) === 10) total += 1;
  }
  return total;
}

/** 用行注释 + 等量空行补回被吃掉的换行，保证报错行号不漂移。 */
function padNewlines(original, replacement) {
  const deficit = countNewlines(original) - countNewlines(replacement);
  if (deficit <= 0) return replacement;
  return `${replacement}//${'\n'.repeat(deficit)}`;
}

/** `export{a as b}` 的子句 → `{b: a}`；`{a, b as c}` → `{a, b: c}`。 */
function convertExportClause(clause) {
  const pairs = [];
  for (const rawPart of clause.split(',')) {
    const part = rawPart.trim();
    if (!part) continue;
    const alias = /^([A-Za-z_$][\w$]*)\s+as\s+([A-Za-z_$][\w$]*)$/.exec(part);
    if (alias) {
      // 局部名在前、导出名在后：{导出名: 局部名}
      pairs.push(`${alias[2]}: ${alias[1]}`);
      continue;
    }
    if (/^[A-Za-z_$][\w$]*$/.test(part)) {
      pairs.push(part);
      continue;
    }
    throw new Error(`无法解析的 export 子句：${part}`);
  }
  return pairs.join(', ');
}

/** `{a, b as c}` 的 import 子句 → `{a, b: c}`（保留原有换行与空白）。 */
function convertImportClause(clause) {
  return clause.replace(
    /([A-Za-z_$][\w$]*)(\s+)as(\s+)([A-Za-z_$][\w$]*)/g,
    '$1$2:$3$4',
  );
}

// ---------------------------------------------------------------------------
// 改写
// ---------------------------------------------------------------------------

/**
 * 把一段纯 ESM 源码改写成 CJS 表面语法。
 *
 * @param {string} source 原始源码
 * @returns {string} 改写后的源码（换行数量与原文一致）
 */
function transform(source) {
  const text = String(source ?? '');
  const mask = codeMask(text);
  const edits = [];
  const exportedNames = [];
  let order = 0;

  const edit = (start, end, replacement) => {
    edits.push({ start, end, replacement, order: order++ });
  };

  // 1) export * from 'x'（必须排在 export{} 之前，两者都以 export 开头）
  for (const match of text.matchAll(
    /(^|[;}\s])export\s*\*\s*from\s*(['"])([^'"]+)\2/g,
  )) {
    const start = match.index + match[1].length;
    if (!isCodeAt(text, mask, start)) continue;
    edit(
      start,
      match.index + match[0].length,
      padNewlines(
        text.slice(start, match.index + match[0].length),
        `Object.assign(module.exports, __require(${JSON.stringify(match[3])}));`,
      ),
    );
  }

  // 2) export{X as Y, Z}[ from 'x']
  for (const match of text.matchAll(
    /(^|[;}\s])export\s*\{([^}]*)\}(?:\s*from\s*(['"])([^'"]+)\3)?\s*;?/g,
  )) {
    const start = match.index + match[1].length;
    if (!isCodeAt(text, mask, start)) continue;
    const clause = convertExportClause(match[2]);
    const replacement = match[4]
      ? `Object.assign(module.exports, __require(${JSON.stringify(match[4])}));`
      : `Object.assign(module.exports, {${clause}});`;
    edit(start, match.index + match[0].length, padNewlines(text.slice(start, match.index + match[0].length), replacement));
  }

  // 3) export default <expr>
  for (const match of text.matchAll(/(^|[;}\s])export\s+default\s+/g)) {
    const start = match.index + match[1].length;
    if (!isCodeAt(text, mask, start)) continue;
    edit(start, match.index + match[0].length, 'module.exports.default = ');
  }

  // 4) export [async] function / class NAME
  for (const match of text.matchAll(
    /(^|[;}\s])export\s+((?:async\s+)?function\s*\*?|class)\s+([A-Za-z_$][\w$]*)/g,
  )) {
    const start = match.index + match[1].length;
    if (!isCodeAt(text, mask, start)) continue;
    // `export` 与原文本等长替换成空格，其余原样保留。
    edit(start, start + 'export'.length, '      ');
    exportedNames.push(match[3]);
  }

  // 5) export const / let / var NAME
  for (const match of text.matchAll(
    /(^|[;}\s])export\s+(const|let|var)\s+([A-Za-z_$][\w$]*)/g,
  )) {
    const start = match.index + match[1].length;
    if (!isCodeAt(text, mask, start)) continue;
    edit(start, start + 'export'.length, '      ');
    exportedNames.push(match[3]);
  }

  // 6) import 家族
  const importPatterns = [
    // import {a, b as c} from 'x'
    {
      regex: /(^|[;}\s])import\s*\{([^}]*)\}\s*from\s*(['"])([^'"]+)\3\s*;?/g,
      build: (match) =>
        `const {${convertImportClause(match[2])}} = __require(${JSON.stringify(match[4])});`,
    },
    // import * as ns from 'x'
    {
      regex: /(^|[;}\s])import\s*\*\s*as\s+([A-Za-z_$][\w$]*)\s*from\s*(['"])([^'"]+)\3\s*;?/g,
      build: (match) => `const ${match[2]} = __require(${JSON.stringify(match[4])});`,
    },
    // import d, {a} from 'x'
    {
      regex: /(^|[;}\s])import\s+([A-Za-z_$][\w$]*)\s*,\s*\{([^}]*)\}\s*from\s*(['"])([^'"]+)\4\s*;?/g,
      build: (match) =>
        `const {default: ${match[2]}, ${convertImportClause(match[3])}} = __require(${JSON.stringify(match[5])});`,
    },
    // import d from 'x'
    {
      regex: /(^|[;}\s])import\s+([A-Za-z_$][\w$]*)\s*from\s*(['"])([^'"]+)\3\s*;?/g,
      build: (match) => `const ${match[2]} = __interop(__require(${JSON.stringify(match[4])}));`,
    },
    // import 'x'
    {
      regex: /(^|[;}\s])import\s*(['"])([^'"]+)\2\s*;?/g,
      build: (match) => `__require(${JSON.stringify(match[3])});`,
    },
  ];
  for (const pattern of importPatterns) {
    for (const match of text.matchAll(pattern.regex)) {
      const start = match.index + match[1].length;
      if (!isCodeAt(text, mask, start)) continue;
      const end = match.index + match[0].length;
      edit(start, end, padNewlines(text.slice(start, end), pattern.build(match)));
    }
  }

  // 7) 被去掉 `export` 关键字的声明，在文件末尾统一登记（声明在模块作用域，可见）。
  if (exportedNames.length > 0) {
    const unique = [...new Set(exportedNames)];
    const pairs = unique.map((name) => `${name}: ${name}`).join(', ');
    edits.push({
      start: text.length,
      end: text.length,
      replacement: `\n;Object.assign(module.exports, {${pairs}});`,
      order: order++,
    });
  }

  // 从后往前应用，前面的偏移量不受影响；同位置按登记的逆序。
  edits.sort((a, b) => b.start - a.start || b.order - a.order);
  let output = text;
  let cursor = text.length + 1;
  for (const item of edits) {
    if (item.end > cursor) continue; // 与更靠后的改写重叠，跳过（安全优先）
    output = output.slice(0, item.start) + item.replacement + output.slice(item.end);
    cursor = item.start;
  }
  return output;
}

// ---------------------------------------------------------------------------
// 模块标识符 → 文件路径
// ---------------------------------------------------------------------------

function withScriptExtension(target) {
  if (/\.(c|m)?js$/i.test(target) || path.extname(target)) return target;
  return `${target}.js`;
}

/**
 * 把站源里的模块标识符解析成磁盘路径。
 *
 * - `assets://js/lib/cat.js` → `<assetsDir>/js/lib/cat.js`（越界视为非法，抛错）
 * - `./x.js` / `../x.js` / `/x.js` → 相对 `options.fromDir`
 * - 其它协议（`http://` 等）与裸模块名 → 返回 `null`，交给调用方决定
 *
 * @param {string} spec 模块标识符
 * @param {{assetsDir?: string, fromDir?: string}} [options]
 * @returns {string|null} 绝对路径，或 null 表示「非本地资源」
 */
function resolveSpec(spec, options) {
  const opts = options || {};
  const raw = String(spec ?? '').trim();
  if (!raw) return null;

  if (raw.startsWith(ASSETS_SCHEME)) {
    if (!opts.assetsDir) {
      throw new Error(
        `站源引用了 ${ASSETS_SCHEME} 资源（${raw}），但宿主没有配置资源目录（--tvbox-assets）`,
      );
    }
    const base = path.resolve(opts.assetsDir);
    const target = path.resolve(base, raw.slice(ASSETS_SCHEME.length).replace(/^\/+/, ''));
    if (target !== base && !target.startsWith(`${base}${path.sep}`)) {
      throw new Error(`站源试图越界访问资源目录：${raw}`);
    }
    return withScriptExtension(target);
  }

  if (/^[a-zA-Z][\w+.-]*:\/\//.test(raw)) return null;

  if (raw.startsWith('./') || raw.startsWith('../') || raw.startsWith('/')) {
    if (!opts.fromDir) return null;
    return withScriptExtension(path.resolve(opts.fromDir, raw));
  }

  return null;
}

module.exports = { transform, resolveSpec, ASSETS_SCHEME };
