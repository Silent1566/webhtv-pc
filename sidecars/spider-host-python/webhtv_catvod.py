"""CatVod / TVBox 方言站源的适配层（方案 2，见 docs/reference/win-box-borrowings.md）。

宿主契约（webhtv-ipc-v1）要求站源暴露 home/category/detail/search/play，
且签名固定为 handler(params, context)（见 webhtv_ipc.py 的 _invoke）。
CatVod 生态的蜘蛛是另一套签名：

    init(extend) / homeContent(filter) / homeVideoContent()
    categoryContent(tid, pg, filter, extend) / detailContent(ids)
    searchContent(key, quick, pg) / playerContent(flag, id, vipFlags)
    liveContent(url) / localProxy(param) / destroy() / getName()

本模块只做「参数 → 位置参数」「返回 → Result」两件事：不改 IPC 契约、不改
host.py、不改站源本身。壳（例如 Atvp.py 这类按 ext 解密内层蜘蛛的 CatVod 壳）
由 create_catvod_spider() 加载并包一层。

设计约束：
- 参数映射与 sidecars/spider-host-js/sandbox_worker.js 的 scriptArgs 同口径，
  这样 JS / Python 两条 CatVod 兼容链行为一致；
- 站源缺方法时抛 UnsupportedMethod（wire 上是 SPIDER_UNSUPPORTED），
  不返回空列表冒充「没有数据」；
- 站源自己 print() 会污染 stdio 协议帧：调用期间把 sys.stdout 指到 stderr
  （SidecarServer 构造时已捕获真实 stdout，协议通道不受影响）；
- 第三方依赖（pycryptodome / requests / lxml）缺失时给出指名报错，不静默降级。
"""

import importlib.util
import sys
import threading
from contextlib import contextmanager
from pathlib import Path
from types import ModuleType
from typing import Any, Mapping

from webhtv_ipc import UnsupportedMethod, base_result

#: 宿主方法名 → CatVod 方法名。
SHELL_TO_CATVOD = {
    "home": "homeContent",
    "homeVod": "homeVideoContent",
    "category": "categoryContent",
    "detail": "detailContent",
    "search": "searchContent",
    "play": "playerContent",
    "live": "liveContent",
    "proxy": "localProxy",
}

_stdout_lock = threading.Lock()
_stdout_redirected = False
_stdout_original = None


def _text(value: Any) -> str:
    if value is None:
        return ""
    return str(value)


def _page_text(value: Any) -> str:
    return "1" if value is None else str(value)


def _jsonable(value: Any, _depth: int = 0) -> Any:
    """把站源返回值收敛成可 JSON 序列化的结构（写帧失败会整条连接报废）。"""
    if _depth > 32:
        return str(value)
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    if isinstance(value, Mapping):
        return {str(key): _jsonable(item, _depth + 1) for key, item in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [_jsonable(item, _depth + 1) for item in value]
    if hasattr(value, "item") and callable(getattr(value, "item")):
        try:
            return _jsonable(value.item(), _depth + 1)
        except Exception:  # noqa: BLE001
            return str(value)
    return str(value)


def positional_args(method: str, params: Mapping[str, Any] | None) -> tuple:
    """宿主 params → CatVod 位置参数（与 sandbox_worker.js 的 scriptArgs 同口径）。"""
    p = params or {}
    if method == "home":
        return (bool(p.get("filter")),)
    if method == "homeVod":
        return ()
    if method == "category":
        filters = p.get("filters")
        tid = p.get("id")
        if tid is None:
            tid = p.get("tid")
        return (
            _text(tid),
            _page_text(p.get("page")),
            bool(p.get("filter")),
            filters if isinstance(filters, Mapping) else {},
        )
    if method == "detail":
        ids = p.get("ids")
        if isinstance(ids, (list, tuple)):
            return (list(ids),)
        return ([_text(p.get("id"))],)
    if method == "search":
        keyword = p.get("keyword")
        if keyword is None:
            keyword = p.get("wd")
        return (_text(keyword), bool(p.get("quick")), _page_text(p.get("page")))
    if method == "play":
        return (_text(p.get("flag")), _text(p.get("id")), [])
    if method == "live":
        return (_text(p.get("url")),)
    if method == "proxy":
        return (p.get("param"),)
    return ()


def normalize_result(method: str, result: Any) -> dict:
    """CatVod 返回值 → 宿主 Result（设计文档 §8.3）。"""
    if result is None:
        # TVBox 站源无数据时常返回 None：映射成空 Result，而不是错误。
        return {} if method == "play" else {"list": []}
    if isinstance(result, list):
        return {"list": _jsonable(result)}
    if not isinstance(result, Mapping):
        name = SHELL_TO_CATVOD.get(method, method)
        raise ValueError(f"站源 {name}() 返回了非对象值：{type(result).__name__}")
    if method == "play":
        return _jsonable(dict(result))

    out: dict[str, Any] = dict(base_result())
    out["list"] = _jsonable(list(result.get("list") or []))
    classes = result.get("class")
    if isinstance(classes, (list, tuple)):
        out["class"] = _jsonable(list(classes))
    filters = result.get("filters")
    if isinstance(filters, Mapping):
        out["filters"] = _jsonable(dict(filters))
    for key in ("page", "pagecount", "total"):
        if result.get(key) is not None:
            out[key] = _jsonable(result.get(key))
    return out


@contextmanager
def _stdout_to_stderr():
    """站源 print() 一律转 stderr：stdout 只承载协议帧。"""
    with _stdout_lock:
        previous = sys.stdout
        sys.stdout = sys.stderr
        try:
            yield
        finally:
            if not _stdout_redirected:
                sys.stdout = previous


def _keep_stdout_on_stderr() -> None:
    """后台线程（如预热门 daemon）也会 print：init 之后常驻重定向。

    SidecarServer.__init__ 已经捕获真实 stdout 的二进制流，所以这里改
    sys.stdout 不影响协议帧写出通道。

    常驻重定向必须在退出前撤销（见 _restore_stdout）：把 sys.stdout 指向
    sys.stderr 后，解释器 finalize 时 stderr 的 BufferedWriter 要同时承担
    两份引用，daemon 线程仍可能持锁 → 退出阶段 0xC0000005 访问冲突。
    """
    global _stdout_redirected, _stdout_original
    with _stdout_lock:
        if _stdout_redirected:
            return
        _stdout_original = sys.stdout
        sys.stdout = sys.stderr
        _stdout_redirected = True


def _restore_stdout() -> None:
    """撤销常驻重定向：close() 之后不再有站源代码需要写 stderr。"""
    global _stdout_redirected, _stdout_original
    with _stdout_lock:
        if not _stdout_redirected:
            return
        if _stdout_original is not None:
            sys.stdout = _stdout_original
        _stdout_redirected = False


def _shim_spider_class() -> type | None:
    """`base/spider.py` 垫片基类；站源没覆盖的方法就落在这里。"""
    try:
        from base.spider import Spider as ShimSpider  # noqa: PLC0415
    except Exception:  # noqa: BLE001 - 垫片缺失时退化为「全部按站源自报」
        return None
    return ShimSpider


def _declaring_class(cls: type, name: str) -> type | None:
    """返回 MRO 上**真正定义** name 的类；用来区分「站源自实现」与「继承默认实现」。"""
    for candidate in getattr(cls, "__mro__", (cls,)):
        if name in candidate.__dict__:
            return candidate
    return None


class CatVodSpider:
    """把 CatVod 方言蜘蛛包成 webhtv-ipc-v1 站源。"""

    def __init__(self, crawler: Any, *, key: str, name: str = "") -> None:
        self._crawler = crawler
        self.key = _text(key)
        self.name = _text(name) or _text(getattr(crawler, "name", "")) or self.key
        self.runtime = "catvod-python:" + type(crawler).__name__

    # ------------------------------------------------------------ 生命周期

    def init(self, extend: str) -> Any:
        # 纪律：站点 ext 必须以**原始字符串**透传，本模块不得把 base64 串 ext
        # 归一化成 dict / JSON。CatVod 壳自己解码（Atvp.py:265 _decode_ext_payload
        # 只做 base64 解码，Atvp.py:227 立刻 payload.get("t4_play_type")）；
        # 一旦归一化，订阅里 91 个 py 站点会全灭
        # （AttributeError: 'NoneType' object has no attribute 'get'）。
        handler = getattr(self._crawler, "init", None)
        if not callable(handler):
            return None
        with _stdout_to_stderr():
            result = handler(_text(extend))
        _keep_stdout_on_stderr()
        return _jsonable(result)

    def close(self) -> None:
        try:
            handler = getattr(self._crawler, "destroy", None)
            if callable(handler):
                with _stdout_to_stderr():
                    handler()
        finally:
            _restore_stdout()

    def capabilities(self) -> list:
        """如实自报能力：壳实现了 8 个方法，但只有底层蜘蛛真正实现的才算具备。

        判据是静态的——方法存在、可调用，且**不是**垫片基类的默认实现——绝不靠
        「调一次看是否抛异常」来猜（§9.3 反面）。声明了却没实现的能力会在运行期
        变成 SPIDER_UNSUPPORTED，比一开始就不声明更难诊断。
        """
        shim = _shim_spider_class()
        supported = []
        for method in SHELL_TO_CATVOD:
            catvod_method = SHELL_TO_CATVOD[method]
            if not callable(getattr(self._crawler, catvod_method, None)):
                continue
            owner = _declaring_class(type(self._crawler), catvod_method)
            if owner is not None and owner is shim:
                # 命中 base/spider.py 的默认实现（如 liveContent 返回空直播表、
                # localProxy 抛 NotImplementedError）：站源并没有这个能力。
                continue
            supported.append(method)
        return supported

    # ------------------------------------------------------------ 壳方法

    def home(self, params: Mapping[str, Any], context: Any) -> dict:
        return self._call("home", params, context)

    def homeVod(self, params: Mapping[str, Any], context: Any) -> dict:
        return self._call("homeVod", params, context)

    def category(self, params: Mapping[str, Any], context: Any) -> dict:
        return self._call("category", params, context)

    def detail(self, params: Mapping[str, Any], context: Any) -> dict:
        return self._call("detail", params, context)

    def search(self, params: Mapping[str, Any], context: Any) -> dict:
        return self._call("search", params, context)

    def play(self, params: Mapping[str, Any], context: Any) -> dict:
        return self._call("play", params, context)

    def live(self, params: Mapping[str, Any], context: Any) -> dict:
        return self._call("live", params, context)

    def proxy(self, params: Mapping[str, Any], context: Any) -> dict:
        return self._call("proxy", params, context)

    # ------------------------------------------------------------ 内部

    def _call(self, method: str, params: Mapping[str, Any], context: Any) -> dict:
        checker = getattr(context, "check_cancelled", None)
        if callable(checker):
            checker()
        catvod_method = SHELL_TO_CATVOD[method]
        handler = getattr(self._crawler, catvod_method, None)
        if not callable(handler):
            # 站源没实现：如实报不支持，绝不返回空列表。
            raise UnsupportedMethod(method)
        args = positional_args(method, params)
        with _stdout_to_stderr():
            try:
                result = handler(*args)
            except NotImplementedError as error:
                # CatVod 站源会在基类里把所有方法都定义成抛 NotImplementedError，
                # 「有没有这个方法」和「实现了没有」得分开判：后者要如实报不支持。
                message = str(error).strip() or "站源未实现 " + catvod_method
                raise UnsupportedMethod(method, message) from error
        if callable(checker):
            checker()
        return normalize_result(method, result)


# ---------------------------------------------------------------- 加载壳


def _format_missing_dependency(error: ModuleNotFoundError, entry: Path) -> str:
    missing = error.name or "未知模块"
    return (
        "CatVod 站源缺少 Python 依赖：" + missing + "（" + entry.name + " 需要它）。"
        "请在运行 WebHTV 的同一个 Python 环境里安装后重试。"
    )


def _load_shell_module(entry: Path) -> ModuleType:
    name = "webhtv_catvod_shell_" + entry.stem
    spec = importlib.util.spec_from_file_location(name, entry)
    if spec is None or spec.loader is None:
        raise ValueError(f"无法加载 CatVod 壳：{entry}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except ModuleNotFoundError as error:
        sys.modules.pop(name, None)
        raise ValueError(_format_missing_dependency(error, entry)) from error
    return module


def _instantiate(spider_class: Any, manifest: Mapping[str, Any]) -> Any:
    """CatVod 蜘蛛一律零参构造；极少数实现接受 manifest，作为兜底再试一次。"""
    try:
        return spider_class()
    except TypeError:
        return spider_class(dict(manifest))


def create_catvod_spider(
    manifest: Mapping[str, Any] | None = None,
    *,
    entry: str = "loader.py",
    root: str | None = None,
) -> CatVodSpider:
    """加载 CatVod 壳并包成宿主站源。

    :param manifest: manifest.json 内容（key/name 用于诊断与命名）。
    :param entry: 壳文件名，相对 root（registrar 下载的 loader.py）。
    :param root: 壳所在目录，默认当前工作目录。
    """
    data = dict(manifest or {})
    directory = Path(root) if root else Path.cwd()
    entry_path = (directory / entry).resolve()
    if not entry_path.is_file():
        raise SystemExit(f"CatVod 壳入口不存在：{entry_path}")

    # 垫片（base/spider.py）与本模块同目录：放进 sys.path 最前面，
    # 让壳里的 from base.spider import Spider 命中宿主垫片而不是 ImportError。
    sidecar_dir = str(Path(__file__).resolve().parent)
    if sidecar_dir not in sys.path:
        sys.path.insert(0, sidecar_dir)

    module = _load_shell_module(entry_path)
    spider_class = getattr(module, "Spider", None)
    if spider_class is None:
        raise ValueError(f"CatVod 壳未导出 Spider 类：{entry_path.name}")
    crawler = _instantiate(spider_class, data)
    key = _text(data.get("key")) or entry_path.stem
    name = _text(data.get("name"))
    return CatVodSpider(crawler, key=key, name=name)
