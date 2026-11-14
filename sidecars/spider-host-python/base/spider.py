"""CatVod 站源基类垫片（T3 → Python sidecar，方案 2）。

CatVod 生态的 Python 蜘蛛几乎都以两种方式取得宿主能力：

    from base.spider import Spider
    class Spider(BaseSpider): ...

或者干脆不继承、直接调用同名方法。本模块只为第一类提供基类，
方法签名严格对齐 CatVod / TVBox 上游，使站源不改一行即可运行。

设计约束：
- **只依赖标准库**：requests / lxml / pycryptodome 全部按需惰性导入。
  CI 不执行 pip install，缺失依赖必须报可读错误，不能 import 期崩溃；
- fetch/post 返回「requests 风格」响应（站源普遍用 .status_code/.text/.json()/.content），
  因此没有 requests 时用 urllib 复刻同样接口；
- TLS 校验默认**开启**（与本项目隐私口径一致），
  确实需要放宽的站点由宿主导出 WEBHTV_CATVOD_INSECURE_TLS=1 显式开启；
- getProxyUrl 指向本机回环代理（只监听 127.0.0.1），与 PRODUCT.md 的
  「不替用户绕过认证/验证码」一致：这里只是地址拼接，不代理任何内容。
"""

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

#: 默认 User-Agent。与主流 TVBox 分发保持接近，减少「按 UA 分流」站点的拒绝。
DEFAULT_USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)

DEFAULT_TIMEOUT = 10


def _insecure_tls() -> bool:
    """站点级 TLS 放宽必须由宿主显式开启，默认关闭。"""
    value = (os.environ.get("WEBHTV_CATVOD_INSECURE_TLS") or "").strip().lower()
    return value in ("1", "true", "yes", "on")


class Response:
    """requests.Response 的最小可用替身（只在没有 requests 时使用）。"""

    def __init__(self, url, status_code, headers, content, encoding="utf-8"):
        self.url = url
        self.status_code = status_code
        self.headers = headers or {}
        self.content = content or b""
        self.encoding = encoding
        self.apparent_encoding = encoding

    @property
    def text(self):
        try:
            return self.content.decode(self.encoding or "utf-8", errors="replace")
        except (LookupError, AttributeError):
            return self.content.decode("utf-8", errors="replace")

    @property
    def ok(self):
        return 200 <= int(self.status_code or 0) < 400

    def json(self, **kwargs):
        return json.loads(self.text, **kwargs)

    def raise_for_status(self):
        if not self.ok:
            raise RuntimeError(f"HTTP {self.status_code} url={self.url}")


def _decode_body(raw, headers):
    charset = "utf-8"
    if headers:
        content_type = ""
        for key, value in headers.items():
            if str(key).lower() == "content-type":
                content_type = str(value)
                break
        match = re.search(r"charset=([\w-]+)", content_type, re.I)
        if match:
            charset = match.group(1)
    return charset


def _urllib_request(url, *, method="GET", data=None, json_body=None, headers=None, timeout=DEFAULT_TIMEOUT, allow_redirects=True):
    request_headers = dict(headers or {})
    if "User-Agent" not in request_headers and "user-agent" not in request_headers:
        request_headers["User-Agent"] = DEFAULT_USER_AGENT
    body = None
    if json_body is not None:
        body = json.dumps(json_body).encode("utf-8")
        request_headers.setdefault("Content-Type", "application/json")
    elif data is not None:
        if isinstance(data, (bytes, bytearray)):
            body = bytes(data)
        elif isinstance(data, str):
            body = data.encode("utf-8")
        else:
            body = urllib.parse.urlencode(data).encode("utf-8")
            request_headers.setdefault("Content-Type", "application/x-www-form-urlencoded")

    request = urllib.request.Request(url, data=body, headers=request_headers, method=method)
    context = None
    if url.lower().startswith("https://") and _insecure_tls():
        import ssl

        context = ssl._create_unverified_context()  # noqa: SLF001 — 显式按站点放宽
    opener = urllib.request.build_opener()
    if not allow_redirects:
        class _NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, hdrs, newurl):  # noqa: D401
                return None

        opener = urllib.request.build_opener(_NoRedirect)
    try:
        with opener.open(request, timeout=timeout, context=context) if context is not None else opener.open(request, timeout=timeout) as response:
            raw = response.read()
            response_headers = dict(response.headers.items())
            return Response(response.url, response.status, response_headers, raw, _decode_body(raw, response_headers))
    except urllib.error.HTTPError as error:
        raw = error.read() or b""
        response_headers = dict(error.headers.items()) if error.headers else {}
        return Response(url, error.code, response_headers, raw, _decode_body(raw, response_headers))


class Spider:
    """CatVod 站源基类：与上游同名方法，宿主能力由 sidecar 垫片提供。"""

    #: 站源 key 由宿主注入（sidecar 用它做诊断与隔离标识）。
    key = "catvod-python"

    def __init__(self):
        self.name = type(self).__name__
        self.extend = ""
        self._cache = {}
        self._video_list = []

    # ---------------------------------------------------------------- 生命周期

    def init(self, extend=""):
        """由宿主在握手阶段调用；站源通常在这里解析 extend。"""
        self.extend = extend or ""
        return None

    def destroy(self):
        # 站源常自己写 __init__ 而不调 super().__init__()（CatVod 生态里很常见），
        # 因此这里不能假设 _cache/_video_list 一定存在。
        cache = getattr(self, "_cache", None)
        if isinstance(cache, dict):
            cache.clear()
        video_list = getattr(self, "_video_list", None)
        if isinstance(video_list, list):
            video_list.clear()

    def getName(self):
        return getattr(self, "name", type(self).__name__)

    # ---------------------------------------------------------------- 网络

    def fetch(self, url, params=None, cookies=None, headers=None, timeout=DEFAULT_TIMEOUT, verify=True, stream=False, allow_redirects=True):
        """GET，返回 requests 风格响应。"""
        target = self._with_query(url, params)
        merged = self._merge_headers(headers, cookies)
        requests_module = self._requests()
        if requests_module is not None:
            response = requests_module.get(
                target,
                headers=merged,
                timeout=timeout,
                verify=verify and not _insecure_tls(),
                stream=stream,
                allow_redirects=allow_redirects,
            )
            response.encoding = response.encoding or "utf-8"
            return response
        return _urllib_request(
            target,
            headers=merged,
            timeout=timeout,
            allow_redirects=allow_redirects,
        )

    def post(self, url, params=None, data=None, json=None, cookies=None, headers=None, timeout=DEFAULT_TIMEOUT, verify=True, stream=False, allow_redirects=True):
        """POST，返回 requests 风格响应。"""
        target = self._with_query(url, params)
        merged = self._merge_headers(headers, cookies)
        requests_module = self._requests()
        if requests_module is not None:
            response = requests_module.post(
                target,
                data=data,
                json=json,
                headers=merged,
                timeout=timeout,
                verify=verify and not _insecure_tls(),
                stream=stream,
                allow_redirects=allow_redirects,
            )
            response.encoding = response.encoding or "utf-8"
            return response
        return _urllib_request(
            target,
            method="POST",
            data=data,
            json_body=json,
            headers=merged,
            timeout=timeout,
            allow_redirects=allow_redirects,
        )

    def html(self, content):
        """HTML 解析（与上游一致返回 lxml 树）。"""
        etree = self._lxml_etree()
        return etree.HTML(content)

    def getProxyUrl(self, local=True):
        """本机回环代理地址（只监听 127.0.0.1，不对外开放）。"""
        return (os.environ.get("WEBHTV_PY_PROXY") or "http://127.0.0.1:9978/proxy?do=py").strip()

    def log(self, message):
        """诊断日志只走 stderr：stdout 是 IPC 协议通道。"""
        try:
            text = message if isinstance(message, str) else json.dumps(message, ensure_ascii=False)
        except (TypeError, ValueError):
            text = str(message)
        print(text, file=sys.stderr, flush=True)

    # ---------------------------------------------------------------- 缓存

    def getCache(self, key):
        return self._cache_dict().get(key)

    def setCache(self, key, value):
        self._cache_dict()[key] = value

    def delCache(self, key):
        self._cache_dict().pop(key, None)

    def _cache_dict(self):
        cache = getattr(self, "_cache", None)
        if not isinstance(cache, dict):
            cache = {}
            self._cache = cache
        return cache

    # ---------------------------------------------------------------- 工具

    def regStr(self, text, pattern, index=0):
        try:
            match = re.search(pattern, text or "", re.S)
        except re.error:
            return ""
        if not match:
            return ""
        try:
            return match.group(index) or ""
        except IndexError:
            return ""

    def removeHtmlTags(self, text):
        return re.sub(r"<[^>]+>", "", text or "")

    def str2json(self, text):
        if isinstance(text, (dict, list)):
            return text
        try:
            return json.loads(text)
        except (TypeError, ValueError):
            return {}

    def json2str(self, value):
        return json.dumps(value, ensure_ascii=False)

    # ---------------------------------------------------------------- 默认实现

    def homeContent(self, filter):
        return {"class": [], "filters": {}}

    def homeVideoContent(self):
        return {"list": []}

    def categoryContent(self, tid, pg, filter, extend):
        return {"page": pg, "pagecount": 1, "total": 0, "list": []}

    def detailContent(self, ids):
        return {"list": []}

    def searchContent(self, key, quick, pg="1"):
        raise NotImplementedError("该站源未实现 searchContent")

    def playerContent(self, flag, id, vipFlags):
        return {"parse": 0, "url": id, "header": {}}

    def liveContent(self, url):
        return {"class": [], "list": []}

    def localProxy(self, param):
        raise NotImplementedError("该站源未声明 localProxy")

    # ---------------------------------------------------------------- 内部

    @staticmethod
    def _with_query(url, params):
        if not params:
            return url
        query = urllib.parse.urlencode(params, doseq=True)
        separator = "&" if urllib.parse.urlparse(url).query else "?"
        return f"{url}{separator}{query}"

    @staticmethod
    def _merge_headers(headers, cookies):
        merged = dict(headers or {})
        if cookies:
            cookie_text = cookies
            if isinstance(cookies, dict):
                cookie_text = "; ".join(f"{k}={v}" for k, v in cookies.items())
            merged.setdefault("Cookie", str(cookie_text))
        merged.setdefault("User-Agent", DEFAULT_USER_AGENT)
        return merged

    @staticmethod
    def _requests():
        try:
            import requests
        except ImportError:
            return None
        return requests

    @staticmethod
    def _lxml_etree():
        try:
            from lxml import etree
        except ImportError as error:
            raise RuntimeError(
                "站源调用了 html() 解析，但当前 Python 环境没有 lxml。"
                "请在该环境执行 pip install lxml 后重试。"
            ) from error
        return etree
