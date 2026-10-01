/**
 * fixture JS 站源（`tvbox-js-v1` 语义，设计文档 §9.3）。
 *
 * 它是「TVBox JS 运行时」验收里的**成功路径**样本，写法刻意贴近真实 TVBox 站源：
 *
 * - 用同步的 `req()` 拉页面（真实站源几乎都这么写）；
 * - 用 `JSON.parse` 解析响应；
 * - 在模块级缓存 base 地址（真实站源常用 `var HOST = ...`）；
 * - 通过 `module.exports` 导出方法（另一种写法是直接定义全局函数，宿主两种都支持）。
 *
 * `base` 从 extend（站点 `ext`）或 manifest config 取得，默认指向本地 fixture 服务。
 */

const DEFAULT_BASE = 'http://127.0.0.1:18080';
let base = DEFAULT_BASE;
let playMedia = '/media/sample.m3u8';

function init(extend) {
  if (extend && String(extend).length > 0) {
    let parsed = extend;
    if (typeof extend === 'string') {
      try {
        parsed = JSON.parse(extend);
      } catch {
        // extend 不是 JSON 时按纯字符串基地址处理（真实站源常见形态）。
        parsed = { base: extend };
      }
    }
    if (parsed && parsed.base) base = String(parsed.base);
    if (parsed && parsed.playMedia) playMedia = String(parsed.playMedia);
  }
  log(`fixture-js spider init base=${base}`);
  return { key: 'js-fixture', base };
}

function getJson(path) {
  const text = req(`${base}${path}`, {
    method: 'GET',
    headers: { 'User-Agent': 'WebHTV-PC/0.1 (Windows)' },
    timeout: 10000,
  });
  if (!text || text.length === 0) return {};
  return JSON.parse(text);
}

/**
 * TVBox: homeContent(filter)
 *
 * 参数名带 `_` 前缀表示「ABI 要求但本 fixture 未使用」——宿主按位置传参，
 * 真实站源会用到它们，因此不能从签名里删掉。
 */
function homeContent(_filter) {
  const result = getJson('/api/type1/');
  return {
    class: result.class || [],
    filters: result.filters || {},
    list: result.list || [],
  };
}

/** TVBox: categoryContent(tid, pg, filter, extend) */
function categoryContent(tid, pg, _filter, _extend) {
  let page = parseInt(pg, 10);
  if (!Number.isFinite(page) || page < 1) page = 1;
  const result = getJson(`/api/type1/?t=${encodeURIComponent(tid)}&pg=${page}`);
  return {
    class: result.class || [],
    filters: result.filters || {},
    list: result.list || [],
    page,
    pagecount: 2,
    total: (result.list || []).length * 2,
  };
}

/** TVBox: detailContent(ids) */
function detailContent(ids) {
  let id = '';
  if (Array.isArray(ids) && ids.length > 0) id = String(ids[0]);
  else if (ids) id = String(ids);
  const result = getJson(`/api/type1/?ac=detail&ids=${encodeURIComponent(id)}`);
  return { list: result.list || [] };
}

/** TVBox: searchContent(key, quick, pg) */
function searchContent(key, _quick, pg) {
  if (!key) throw new Error('缺少搜索关键词');
  let page = parseInt(pg, 10);
  if (!Number.isFinite(page) || page < 1) page = 1;
  const result = getJson(`/api/type1/?wd=${encodeURIComponent(key)}&pg=${page}`);
  return { list: result.list || [], page, pagecount: 1 };
}

/** TVBox: playerContent(flag, id, vipFlags) */
function playerContent(flag, id, _vipFlags) {
  let url = id;
  let playFlag = flag || 'js-fixture';
  // TVBox 常见约定：`url,flag` 形态的 id。
  if (id && String(id).includes(',')) {
    const parts = String(id).split(',');
    url = parts[0];
    if (parts[1]) playFlag = parts[1];
  }
  if (!url) throw new Error('缺少播放 id');
  // 相对路径补成 fixture 绝对地址，方便集成测试真实出画。
  if (!String(url).startsWith('http')) url = `${base}${playMedia}`;
  return {
    url,
    flag: playFlag,
    format: 'application/vnd.apple.mpegurl',
    header: {},
  };
}

/** 演示「未实现的全局会明确报错」——不静默返回 undefined。 */
function webViewProbe() {
  return getWebViewUrl('http://example.com', 3);
}

module.exports = {
  init,
  homeContent,
  categoryContent,
  detailContent,
  searchContent,
  playerContent,
  webViewProbe,
};
