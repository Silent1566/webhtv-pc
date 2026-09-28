#!/usr/bin/env python3
"""`webhtv-ipc-v1` 传输层实现（Python 侧）。

与 Dart 侧 `apps/desktop-flutter/lib/core/ipc_protocol.dart` 一一对应，是语言无关
契约的第二份实现：测试用它验证宿主与 sidecar 对同一份契约的理解一致。

契约要点（设计文档 §9.3、§9.3.1、§9.5）：

- 帧格式为 `Content-Length` 头、空行和指定字节数的 UTF-8 JSON。禁止“一行一个 JSON”。
- stdout 只承载协议帧，运行日志必须写 stderr。
- `initialize` 交换 ABI major/minor、capabilities、权限与限制。
- 取消使用 `$/cancelRequest`（同时接受历史名 `$/cancel`）。
- 统一错误对象至少含 `code/category/message/retryable/userVisible/siteKey/`
  `requestId/details/diagnosticId`。
"""

from __future__ import annotations

import json
import sys
import threading
import traceback
from typing import Any, Callable, Iterable, Mapping

ABI_NAME = "webhtv-ipc-v1"
ABI_MAJOR = 1
ABI_MINOR = 0

DEFAULT_MAX_FRAME_BYTES = 16 * 1024 * 1024

REQUIRED_METHODS = ("init", "home", "category", "detail", "search", "play", "destroy")
OPTIONAL_METHODS = ("homeVod", "live", "proxy", "action")
KNOWN_CAPABILITIES = frozenset(
    (
        "home",
        "category",
        "detail",
        "search",
        "play",
        "homeVod",
        "live",
        "proxy",
        "action",
    )
)

CANCEL_METHODS = ("$/cancelRequest", "$/cancel")

ERROR_INIT_FAILED = "SPIDER_INIT_FAILED"
ERROR_UNSUPPORTED = "SPIDER_UNSUPPORTED"
ERROR_BAD_REQUEST = "SPIDER_BAD_REQUEST"
ERROR_HTTP_ERROR = "SPIDER_HTTP_ERROR"
ERROR_PARSE_ERROR = "SPIDER_PARSE_ERROR"
ERROR_TIMEOUT = "SPIDER_TIMEOUT"
ERROR_CANCELLED = "SPIDER_CANCELLED"
ERROR_CRASHED = "SPIDER_CRASHED"
ERROR_RESOURCE_LIMIT = "SPIDER_RESOURCE_LIMIT"
ERROR_PROTOCOL_VIOLATION = "SPIDER_PROTOCOL_VIOLATION"


class ProtocolError(Exception):
    """帧或信封非法。"""


class Cancelled(Exception):
    """调用方取消了请求。"""


def log(message: str) -> None:
    """运行日志只能写 stderr（§9.3.1）。"""
    sys.stderr.write(f"{message}\n")
    sys.stderr.flush()


# ---------------------------------------------------------------------------
# 帧编解码
# ---------------------------------------------------------------------------


def encode_frame(payload: Any) -> bytes:
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    header = (
        f"Content-Length: {len(body)}\r\n"
        "Content-Type: application/json; charset=utf-8\r\n"
        "\r\n"
    ).encode("ascii")
    return header + body


def read_frame(stream, max_bytes: int = DEFAULT_MAX_FRAME_BYTES):
    """从二进制流中读出一个长度前缀帧；流结束返回 None。"""
    header = bytearray()
    while True:
        chunk = stream.read(1)
        if not chunk:
            if not header:
                return None
            raise ProtocolError("流结束前帧头不完整")
        header += chunk
        if header.endswith(b"\r\n\r\n") or header.endswith(b"\n\n"):
            break
        if len(header) > 8192:
            raise ProtocolError("帧头超过 8 KiB，判定为协议污染")

    text = header.decode("utf-8", errors="replace")
    length: int | None = None
    for line in text.replace("\r\n", "\n").split("\n"):
        line = line.strip()
        if not line:
            continue
        if ":" not in line:
            raise ProtocolError(f"头字段缺少冒号：{line}")
        name, _, value = line.partition(":")
        if name.strip().lower() == "content-length":
            try:
                length = int(value.strip())
            except ValueError as error:
                raise ProtocolError(f"Content-Length 非法：{value.strip()}") from error
    if length is None:
        raise ProtocolError("缺少 Content-Length 头")
    if length > max_bytes:
        raise ProtocolError(f"声明 {length} 字节超过上限 {max_bytes}")

    body = bytearray()
    while len(body) < length:
        chunk = stream.read(length - len(body))
        if not chunk:
            raise ProtocolError("流在 payload 结束前关闭")
        body += chunk
    try:
        return json.loads(bytes(body).decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProtocolError(f"payload 不是 UTF-8 JSON：{error}") from error


def write_frame(stream, payload: Any) -> None:
    stream.write(encode_frame(payload))
    stream.flush()


def error_object(
    code: str,
    message: str,
    *,
    category: str | None = None,
    retryable: bool | None = None,
    user_visible: bool | None = None,
    site_key: str | None = None,
    request_id: str | None = None,
    details: Mapping[str, Any] | None = None,
    diagnostic_id: str = "diag-py",
) -> dict:
    return {
        "code": code,
        "category": category or default_category(code),
        "message": message,
        "retryable": default_retryable(code) if retryable is None else retryable,
        "userVisible": (
            default_user_visible(code) if user_visible is None else user_visible
        ),
        "siteKey": site_key,
        "requestId": request_id,
        "details": dict(details or {}),
        "diagnosticId": diagnostic_id,
    }


def default_category(code: str) -> str:
    if code in (ERROR_PROTOCOL_VIOLATION, ERROR_BAD_REQUEST):
        return "protocol"
    if code == ERROR_CRASHED:
        return "transport"
    if code == ERROR_RESOURCE_LIMIT:
        return "resource"
    if code == ERROR_CANCELLED:
        return "user"
    return "site"


def default_retryable(code: str) -> bool:
    return code in (ERROR_TIMEOUT, ERROR_HTTP_ERROR, ERROR_CRASHED, ERROR_INIT_FAILED)


def default_user_visible(code: str) -> bool:
    return code != ERROR_PROTOCOL_VIOLATION


class SpiderCapabilities:
    """未声明 capability 的方法必须返回 SPIDER_UNSUPPORTED（§9.7）。"""

    def __init__(self, values: Iterable[str]):
        self.values = frozenset(item for item in values if item)

    def supports(self, method: str) -> bool:
        if method not in KNOWN_CAPABILITIES:
            return True
        return method in self.values


class UnsupportedMethod(Exception):
    """sidecar 未声明该 capability。"""

    def __init__(self, method: str):
        super().__init__(f"未声明 capability：{method}")
        self.method = method


class CallContext:
    """传给 spider 的调用上下文：提供取消检查与超时感知。"""

    def __init__(self, request_id: str, cancel_event: threading.Event):
        self.request_id = request_id
        self._cancel_event = cancel_event

    @property
    def cancelled(self) -> bool:
        return self._cancel_event.is_set()

    def check_cancelled(self) -> None:
        if self.cancelled:
            raise Cancelled()

    def sleep(self, seconds: float) -> None:
        """可被取消打断的等待：不支持的阻塞调用必须可被进程级超时兜底。"""
        if self._cancel_event.wait(seconds):
            raise Cancelled()


class SidecarServer:
    """把 spider 对象暴露为 `webhtv-ipc-v1` stdio 服务。"""

    def __init__(
        self,
        spider: Any,
        *,
        manifest: Mapping[str, Any] | None = None,
        stdin=None,
        stdout=None,
        max_workers: int = 4,
    ):
        self.spider = spider
        self.manifest = dict(manifest or {})
        self.stdin = stdin if stdin is not None else sys.stdin.buffer
        self.stdout = stdout if stdout is not None else sys.stdout.buffer
        # manifest 是分发契约：声明了 capabilities 时以 manifest 为准，
        # sidecar 自报的能力不得超出 manifest（§9.7）。
        declared = self.manifest.get("capabilities")
        if declared:
            self.capabilities = SpiderCapabilities(declared)
        elif callable(getattr(spider, "capabilities", None)):
            self.capabilities = SpiderCapabilities(spider.capabilities())
        else:
            self.capabilities = SpiderCapabilities(())
        self.site_key = str(
            getattr(spider, "key", None) or self.manifest.get("key", "unknown")
        )
        self._write_lock = threading.Lock()
        self._cancel_events: dict[str, threading.Event] = {}
        self._state_lock = threading.Lock()
        self._stopping = False
        self._max_workers = max(1, int(max_workers))
        self._handlers: dict[str, Callable[[Mapping[str, Any], Callable], Any]] = {
            # §9.3.1：宿主启动后先执行 `initialize` 完成版本/capability 握手；
            # `init` 仅是 Spider 内部的生命周期方法名，不是 wire 方法名。
            "initialize": self._handle_init,
            "home": lambda params, ctx: self._invoke("home", params, ctx),
            "homeVod": lambda params, ctx: self._invoke("homeVod", params, ctx),
            "category": lambda params, ctx: self._invoke("category", params, ctx),
            "detail": lambda params, ctx: self._invoke("detail", params, ctx),
            "search": lambda params, ctx: self._invoke("search", params, ctx),
            "play": lambda params, ctx: self._invoke("play", params, ctx),
            "live": lambda params, ctx: self._invoke("live", params, ctx),
            "proxy": lambda params, ctx: self._invoke("proxy", params, ctx),
            "action": lambda params, ctx: self._invoke("action", params, ctx),
            "destroy": self._handle_destroy,
            "shutdown": self._handle_destroy,
            "heartbeat": lambda params, ctx: {"ok": True},
        }

    # --------------------------------------------------------------- 生命周期

    def serve(self) -> int:
        threads: list[threading.Thread] = []
        try:
            while not self._stopping:
                try:
                    message = read_frame(self.stdin)
                except ProtocolError as error:
                    log(f"协议错误，终止运行时：{error}")
                    return 2
                if message is None:
                    break
                method = message.get("method")
                if method in CANCEL_METHODS:
                    self._on_cancel(message)
                    continue
                if not isinstance(message, Mapping) or not message.get("id"):
                    log("丢弃非法消息：缺少 id/method")
                    continue
                thread = threading.Thread(
                    target=self._dispatch,
                    args=(message,),
                    daemon=True,
                )
                thread.start()
                threads.append(thread)
                # 控制并发，避免 sidecar 自身成为资源耗尽点。
                while sum(1 for item in threads if item.is_alive()) >= self._max_workers:
                    for item in list(threads):
                        if not item.is_alive():
                            threads.remove(item)
                    if sum(1 for item in threads if item.is_alive()) < self._max_workers:
                        break
                    threading.Event().wait(0.01)
        finally:
            self._call_quietly("close")
        return 0

    def _dispatch(self, message: Mapping[str, Any]) -> None:
        request_id = str(message["id"])
        method = str(message.get("method", ""))
        params = message.get("params") or {}
        cancel_event = threading.Event()
        with self._state_lock:
            self._cancel_events[request_id] = cancel_event
        context = CallContext(request_id, cancel_event)
        try:
            handler = self._handlers.get(method)
            if handler is None:
                raise UnsupportedMethod(method)
            result = handler(params, context)
            if result is _NO_RESPONSE:
                return
            self._respond_success(request_id, result)
        except Cancelled:
            self._respond_error(
                request_id, ERROR_CANCELLED, "调用方已取消该请求"
            )
        except UnsupportedMethod as error:
            self._respond_error(
                request_id,
                ERROR_UNSUPPORTED,
                str(error),
                details={"capabilities": sorted(self.capabilities.values)},
            )
        except ValueError as error:
            self._respond_error(request_id, ERROR_BAD_REQUEST, str(error))
        except Exception as error:  # noqa: BLE001 - 任何异常都必须变成统一错误对象
            log(f"方法 {method} 失败：{error}\n{traceback.format_exc()}")
            self._respond_error(
                request_id,
                ERROR_PARSE_ERROR,
                f"{type(error).__name__}: {error}",
            )
        finally:
            with self._state_lock:
                self._cancel_events.pop(request_id, None)

    def _on_cancel(self, message: Mapping[str, Any]) -> None:
        params = message.get("params") or {}
        target = params.get("id")
        if not isinstance(target, str) or not target:
            log("取消消息缺少 id，已忽略")
            return
        with self._state_lock:
            event = self._cancel_events.get(target)
        if event is None:
            log(f"取消未知请求 id={target}（可能已完成）")
            return
        event.set()

    def _handle_init(self, params: Mapping[str, Any], context: CallContext) -> dict:
        declared = params.get("abi")
        if declared and declared != ABI_NAME:
            raise ValueError(f"ABI 不兼容：宿主声明 {declared}，sidecar 为 {ABI_NAME}")
        extend = str(
            params.get("extend")
            or getattr(self.spider, "default_extend", "")
            or ""
        )
        init_result = None
        if callable(getattr(self.spider, "init", None)):
            init_result = self.spider.init(extend)
        return {
            "abi": ABI_NAME,
            "abiMinor": ABI_MINOR,
            "key": self.site_key,
            "runtime": self.manifest.get("runtime", "python-3"),
            "capabilities": sorted(self.capabilities.values),
            "permissions": self.manifest.get(
                "permissions",
                {
                    "network": True,
                    "localProxy": False,
                    "ui": False,
                    "storage": "cache-only",
                    "process": False,
                    "clipboard": False,
                    "browser": False,
                },
            ),
            "limits": self.manifest.get("limits", {}),
            "init": init_result,
        }

    def _handle_destroy(self, params: Mapping[str, Any], context: CallContext) -> dict:
        self._stopping = True
        self._call_quietly("destroy")
        return {"ok": True}

    def _invoke(self, method: str, params: Mapping[str, Any], context: CallContext):
        if not self.capabilities.supports(method):
            raise UnsupportedMethod(method)
        handler = getattr(self.spider, method, None)
        if handler is None:
            raise UnsupportedMethod(method)
        return handler(params, context)

    def _call_quietly(self, name: str) -> None:
        handler = getattr(self.spider, name, None)
        if handler is None:
            return
        try:
            handler()
        except Exception as error:  # noqa: BLE001
            log(f"{name}() 失败：{error}")

    # ---------------------------------------------------------------- 输出

    def _respond_success(self, request_id: str, result: Any) -> None:
        with self._write_lock:
            write_frame(
                self.stdout,
                {"jsonrpc": "2.0", "id": request_id, "result": result},
            )

    def _respond_error(
        self,
        request_id: str,
        code: str,
        message: str,
        *,
        details: Mapping[str, Any] | None = None,
    ) -> None:
        with self._write_lock:
            write_frame(
                self.stdout,
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": error_object(
                        code,
                        message,
                        site_key=self.site_key,
                        request_id=request_id,
                        details=details,
                    ),
                },
            )


class _NoResponse:
    pass


_NO_RESPONSE = _NoResponse()


def base_result(**overrides: Any) -> dict:
    result: dict[str, Any] = {
        "class": [],
        "filters": {},
        "list": [],
        "page": 1,
        "pagecount": 1,
        "total": 0,
    }
    result.update(overrides)
    return result


def vod(
    vod_id: str,
    vod_name: str,
    *,
    vod_pic: str = "",
    vod_remarks: str = "",
    vod_play_from: str = "",
    vod_play_url: str = "",
    vod_content: str = "",
) -> dict:
    return {
        "vod_id": vod_id,
        "vod_name": vod_name,
        "vod_pic": vod_pic,
        "vod_remarks": vod_remarks,
        "vod_content": vod_content,
        "vod_play_from": vod_play_from,
        "vod_play_url": vod_play_url,
    }
