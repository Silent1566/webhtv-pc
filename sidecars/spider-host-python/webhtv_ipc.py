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

宿主侧 deadline 与并发上限（与 JS `host.js:649-658`、JVM `SidecarServer.java:172-177`
同语义，见 `SidecarServer._monitor_deadlines`）：

- **为什么 Python 必须有宿主侧 deadline**：站源的典型写法是 `requests.get(url)` 或
  `time.sleep(...)`，线程阻塞在内核/C 层，宿主无法抢占；这类站源永远走不到
  `CallContext.check_cancelled()`（:221）。只靠站源自查取消，等于把「不响应取消」的
  站点变成永久挂起——宿主最后只能杀进程，用户看到的是「闪退」而不是超时。所以
  宿主自己记 deadline，到期由**宿主**回 `SPIDER_TIMEOUT` 错误帧，站源之后才返回的
  结果按 §9.5 丢弃。
- **宽限之后宿主退出**：错误帧只是「告诉调用方」，并不能把卡住的线程解出来。
  到期后再给站源 `TIMEOUT_ABANDON_GRACE_SECONDS` 的宽限，仍不返回说明它确实
  阻塞在无法中断的调用里——这个并发名额永久收不回，本进程主动退出（退出码
  `EXIT_PROCESS_ABANDONED`），由上层重建。与改造前「超时后杀进程」同一兜底，
  区别是先给出 `SPIDER_TIMEOUT`，用户看到的是超时而不是闪退。
- **为什么并发必须有上限**：每个请求起一条线程，等于把站源的阻塞转成宿主的资源
  耗尽（线程数无界、栈内存跟着涨）。这里用有界工作池：并发 = manifest
  `limits.concurrency`（默认 4，与 JS `maxWorkers` 一致），队列同样有界，满则立刻回
  `SPIDER_RESOURCE_LIMIT`——不排队、也不静默丢帧（§9.3.1 每个请求必须有应答）。
"""

from __future__ import annotations

import json
import os
import queue
import sys
import time
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

#: 并发上限默认值（manifest 未声明 `limits.concurrency` 时），与 JS 宿主
#: `host.js:341` 的 `maxWorkers = 4` 保持一致。
DEFAULT_MAX_WORKERS = 4

#: 排队名额：并发已满时最多再挂起这么多个请求，超出立刻回 SPIDER_RESOURCE_LIMIT。
#: 队列必须**有界**，否则「限制并发」只是把资源耗尽从线程数挪到队列长度。
DEFAULT_QUEUE_CAPACITY = 8

#: 按方法给出 deadline 默认值（毫秒），与 JS `host.js:650 _deadlineOf` 同一张表
#: （§9.3.1：超时按方法配置）。请求帧带了 `deadlineMs` 时以帧为准。
METHOD_DEADLINE_MS = {"play": 20000, "search": 25000, "detail": 20000}
DEFAULT_DEADLINE_MS = 30000
#: 宿主给出的容忍上限：再长就等于允许一次调用挂满整个会话。
MAX_DEADLINE_MS = 120000

#: deadline 到期后再给站源的宽限（秒）：协作型站源收到取消后会解绕，阻塞在
#: requests.get 里的站源则永远解不开。宽限一过就判定 worker 不可回收，本进程退出
#: （见 SidecarServer._abandon）。量级与宿主侧的 500ms 终止宽限一致。
TIMEOUT_ABANDON_GRACE_SECONDS = 1.0

#: 站源在 deadline 之后仍不返回时本进程的退出码（host.py 文档里登记）。
EXIT_PROCESS_ABANDONED = 4

#: 需要宿主 deadline 兜底的站源方法——只有这些方法会阻塞在网络 I/O 上。
#: 控制类方法（initialize/destroy/shutdown/heartbeat）不设宿主 deadline：它们是本地
#: 簿记，加超时只会与 `_stopping` 抢答，制造「已回超时但进程其实已停」的假象
#: （JS `dispatch` 同样在这几个方法上提前返回，不进入 deadline 路径）。
DEADLINE_METHODS = frozenset(
    ("home", "homeVod", "category", "detail", "search", "play", "live", "proxy", "action")
)


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
    """sidecar 未声明该 capability，或站源根本没实现这个方法。"""

    def __init__(self, method: str, message: str | None = None):
        # message 可选：CatVod 站源用它说明「方法存在但没实现」的具体原因。
        super().__init__(message or f"未声明 capability：{method}")
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


def resolve_max_workers(explicit: int | None, manifest: Mapping[str, Any]) -> int:
    """并发上限：显式参数 > manifest `limits.concurrency` > 默认 4。

    manifest 是分发契约（与 capabilities 同源），站点自己申报的并发必须被执行层
    尊重，否则同一份 manifest 在 JS/JVM/Python 三种宿主下的行为不一致。
    """
    if explicit is not None:
        return max(1, int(explicit))
    limits = manifest.get("limits")
    if isinstance(limits, Mapping):
        declared = limits.get("concurrency")
        if isinstance(declared, int) and not isinstance(declared, bool) and declared > 0:
            return declared
    return DEFAULT_MAX_WORKERS


class _Call:
    """一条在途请求：取消信号、deadline 与「谁负责写这一帧」的仲裁位。

    `answered` 是 deadline 监视线程与 worker 线程之间的仲裁位：两者可能同时认为
    自己该写帧（到期瞬间站源恰好返回），谁先置位谁写，另一方丢弃结果（§9.5）。
    """

    __slots__ = (
        "request_id",
        "method",
        "cancel_event",
        "deadline_ms",
        "deadline_at",
        "answered",
        "abandoned_at",
    )

    def __init__(self, request_id: str, method: str, deadline_ms: float | None):
        self.request_id = request_id
        self.method = method
        self.cancel_event = threading.Event()
        self.deadline_ms = deadline_ms
        self.deadline_at = (
            None if deadline_ms is None else time.monotonic() + deadline_ms / 1000.0
        )
        self.answered = False
        # 监视线程判定的「已超时、worker 还没回来」时刻；None 表示未超时。
        self.abandoned_at: float | None = None


class _BoundedWorkerPool:
    """daemon 线程 + 有界队列组成的工作池：并发有上限、队列有上限、满了要报错。

    与 `concurrent.futures.ThreadPoolExecutor` 的差别只有一处，但它是硬要求：
    ThreadPoolExecutor 的 worker 是**非 daemon** 线程，解释器退出时
    `concurrent.futures` 的 atexit 钩子会 `join` 它们。站源阻塞在 `requests.get`
    （正是本文件要兜底的场景）时这个 join 永不返回——stdin 关闭后进程迟迟不退，
    宿主只能当挂死杀掉。daemon 线程让进程能按时退出，同时保留「并发有上限」。

    队列满时 submit() 返回 False，由调用方回 `SPIDER_RESOURCE_LIMIT`；这里既不用
    阻塞投递（会把读循环堵住、连取消帧都读不到），也不静默丢帧。
    """

    _STOP = object()

    def __init__(
        self,
        max_workers: int,
        queue_capacity: int,
        name_prefix: str = "webhtv-sidecar",
    ) -> None:
        self._queue: "queue.Queue" = queue.Queue(maxsize=max(1, int(queue_capacity)))
        self._lock = threading.Lock()
        self._pending = 0
        self._threads = [
            threading.Thread(
                target=self._loop, name=f"{name_prefix}-{index}", daemon=True
            )
            for index in range(max(1, int(max_workers)))
        ]
        for thread in self._threads:
            thread.start()

    def submit(self, fn: Callable[..., Any], *args: Any) -> bool:
        """投递任务；队列已满返回 False（调用方据此回错误帧）。"""
        with self._lock:
            self._pending += 1
        try:
            self._queue.put_nowait((fn, args))
        except queue.Full:
            with self._lock:
                self._pending -= 1
            return False
        return True

    def _loop(self) -> None:
        while True:
            item = self._queue.get()
            if item is self._STOP:
                self._queue.task_done()
                return
            fn, args = item
            try:
                fn(*args)
            except Exception as error:  # noqa: BLE001 - worker 异常不能带走线程
                log(f"工作线程异常：{type(error).__name__}: {error}")
            finally:
                with self._lock:
                    self._pending -= 1
                self._queue.task_done()

    def wait_idle(self, timeout: float) -> bool:
        """等在途任务全部结束（上限 timeout 秒）；返回是否已全部结束。"""
        deadline = time.monotonic() + max(0.0, timeout)
        while True:
            with self._lock:
                if self._pending <= 0:
                    return True
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            time.sleep(min(0.01, remaining))

    def shutdown(self, timeout: float = 10.0) -> None:
        """等响应写完（上限 timeout 秒）再停下 worker。

        读循环结束 ≠ 可以立刻退出：可能还有已派发、还没写回响应的请求，不等就会
        丢响应——宿主看到的是「发出去没有回音」。worker 是 daemon，超时未停的
        线程随进程一起结束。
        """
        self.wait_idle(timeout)
        for _ in self._threads:
            try:
                self._queue.put_nowait(self._STOP)
            except queue.Full:
                break


class SidecarServer:
    """把 spider 对象暴露为 `webhtv-ipc-v1` stdio 服务。"""

    def __init__(
        self,
        spider: Any,
        *,
        manifest: Mapping[str, Any] | None = None,
        stdin=None,
        stdout=None,
        max_workers: int | None = None,
        queue_capacity: int = DEFAULT_QUEUE_CAPACITY,
        abandon_grace: float = TIMEOUT_ABANDON_GRACE_SECONDS,
        hold: bool = False,
    ):
        self.spider = spider
        # `hold=True`：`destroy` 只释放站源，不结束服务循环（`--hold`）。
        # 蜘蛛自起本地 HTTP 取流服务时，进程一退端口就没了，靠这个开关把侧车
        # 留在原地，由宿主显式 `shutdown` 或 stdin EOF 收尾。
        self.hold = bool(hold)
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
        # max_workers=None 表示「不显式指定」：并发上限取 manifest 的
        # limits.concurrency，再没有才是默认 4（见 resolve_max_workers）。
        self._max_workers = resolve_max_workers(max_workers, self.manifest)
        self._queue_capacity = max(1, int(queue_capacity))
        self._abandon_grace = max(0.0, float(abandon_grace))
        # 在途请求表：取消信号与 deadline 一起登记，键都是 request id。
        self._calls: dict[str, _Call] = {}
        self._state_lock = threading.Lock()
        # _state_lock 同时充当在途表的互斥锁与 deadline 监视线程的唤醒条件：
        # 登记新请求（可能带来更早的到期点）与监视线程的等待必须是同一把锁，
        # 否则两者之间的窗口会让监视线程睡过刚刚登记的 deadline。
        self._state_changed = threading.Condition(self._state_lock)
        self._monitor_stop = False
        self._pool: _BoundedWorkerPool | None = None
        self._stopping = False
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
            "shutdown": self._handle_shutdown,
            "heartbeat": lambda params, ctx: {"ok": True},
        }

    # --------------------------------------------------------------- 生命周期

    @property
    def max_workers(self) -> int:
        """并发上限：manifest 的 limits.concurrency，默认 4（与 JS maxWorkers 一致）。"""
        return self._max_workers

    def _drain_in_flight(self, context: CallContext, timeout: float = 5.0) -> None:
        """等其它在途请求把响应写完（最多 timeout 秒）。

        destroy 与同一批 stdin 里的 home/category 是并发线程：先停服务循环会让
        已经派发的请求来不及写回响应，宿主看到的是「派发了却没收响应」。
        """
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self._state_lock:
                pending = [
                    request_id for request_id in self._calls
                    if request_id != context.request_id
                ]
            if not pending:
                return
            time.sleep(0.005)

    def serve(self) -> int:
        self._pool = _BoundedWorkerPool(self._max_workers, self._queue_capacity)
        monitor = threading.Thread(
            target=self._monitor_deadlines,
            name="webhtv-deadline",
            daemon=True,
        )
        monitor.start()
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
                    # 取消在**读循环里**处理，不能排进工作池：池被 hung 站源占满时，
                    # 排在队列里的取消帧永远送不到在途请求手里（§9.5）。
                    self._on_cancel(message)
                    continue
                if not isinstance(message, Mapping) or not message.get("id"):
                    log("丢弃非法消息：缺少 id/method")
                    continue
                self._accept(message)
        finally:
            # 读循环结束（destroy/shutdown/EOF）≠ 可以立刻退出：池里可能还有已派发
            # 但未写回响应的请求，不等就会丢响应（_BoundedWorkerPool.shutdown 负责）。
            # 顺序不能反：监视线程必须活到在途请求收尾为止——EOF 之后仍在运行的
            # 请求同样受 deadline 约束，先停监视线程等于把最后一批请求放回「永不
            # 应答」的老路上。
            if self._pool is not None:
                self._pool.shutdown(timeout=10.0)
            with self._state_changed:
                self._monitor_stop = True
                self._state_changed.notify_all()
            self._call_quietly("close")
        return 0

    def _accept(self, message: Mapping[str, Any]) -> None:
        """登记在途请求并投递到工作池；队列已满时立刻回错误帧。"""
        request_id = str(message["id"])
        method = str(message.get("method", ""))
        # 在**读循环**里登记在途请求，而不是在 worker 线程里：drain 依赖的顺序
        # 必须与 stdin 顺序一致，否则 destroy 可能先看到「没有在途」而抢在 home
        # 之前登记/开跑，照样把响应截断。
        call = _Call(request_id, method, self._deadline_of(message))
        with self._state_changed:
            self._calls[request_id] = call
            # 新登记可能带来更早的到期点，叫醒监视线程重算下次醒来时间。
            self._state_changed.notify_all()
        pool = self._pool
        if pool is not None and pool.submit(self._dispatch, message, call):
            return
        # 拒绝路径：不留半登记状态，也不静默丢帧（§9.3.1 每个请求必须有应答）。
        with self._state_changed:
            self._calls.pop(request_id, None)
        if self._claim(call):
            log(f"并发已满，拒绝请求 id={request_id} method={method}")
            self._respond_error(
                request_id,
                ERROR_RESOURCE_LIMIT,
                f"sidecar 并发已满（并发上限 {self._max_workers}，队列 {self._queue_capacity}），请求被拒绝",
                details={"maxWorkers": self._max_workers, "queueCapacity": self._queue_capacity},
            )

    def _deadline_of(self, message: Mapping[str, Any]) -> float | None:
        """请求的 deadline（毫秒）：帧里的 deadlineMs 优先，其次按方法默认值。

        与 JS host.js 的 _deadlineOf 同语义，包括 120s 上限：宿主容忍度超过它，
        就等于允许一次调用挂满整个会话。控制类方法返回 None（不设宿主 deadline，
        见 DEADLINE_METHODS 的说明）。
        """
        method = str(message.get("method", ""))
        if method not in DEADLINE_METHODS:
            return None
        declared = message.get("deadlineMs")
        if (
            isinstance(declared, (int, float))
            and not isinstance(declared, bool)
            and declared > 0
        ):
            return min(float(declared), float(MAX_DEADLINE_MS))
        return float(METHOD_DEADLINE_MS.get(method, DEFAULT_DEADLINE_MS))

    def _claim(self, call: _Call) -> bool:
        """仲裁「谁写这一帧」，返回 True 的一方才写。

        deadline 到期与站源返回可能同时发生：监视线程与 worker 线程都以为自己该
        应答，谁先置 answered 谁写，另一方丢弃结果（§9.5：取消/超时后不得再投递）。
        """
        with self._state_changed:
            if call.answered:
                return False
            call.answered = True
            return True

    def _monitor_deadlines(self) -> None:
        """唯一的 deadline 监视线程：到期由宿主回错误帧，不等站源自查取消。

        每请求一个 threading.Timer 也能做到，但那又是「每请求一条线程」，与本文件
        刚拆掉的无限起线程是同一个病；这里一条线程扫全部在途请求。站源阻塞在
        requests.get 里无法抢占，所以「回错误帧」是本宿主唯一能兑现的承诺：结果
        写不写回由 _claim 决定，站源后来才返回的结果一律丢弃。
        """
        while True:
            with self._state_changed:
                if self._monitor_stop:
                    return
                now = time.monotonic()
                expired = [
                    call
                    for call in self._calls.values()
                    if call.deadline_at is not None
                    and not call.answered
                    and call.deadline_at <= now
                ]
                abandoned = [
                    call
                    for call in self._calls.values()
                    if call.abandoned_at is not None
                    and now - call.abandoned_at >= self._abandon_grace
                ]
                if not expired and not abandoned:
                    upcoming = [
                        call.deadline_at - now
                        for call in self._calls.values()
                        if call.deadline_at is not None and not call.answered
                    ]
                    upcoming += [
                        call.abandoned_at + self._abandon_grace - now
                        for call in self._calls.values()
                        if call.abandoned_at is not None
                    ]
                    # 睡到最早到期点（每轮重算，登记/完成都会 notify）；没有在途
                    # deadline 时 0.5s 醒一次。「睡到点」而不是轮询，是为了让错误帧
                    # 尽量贴近 deadline 发出，而不是晚一个轮询周期。
                    self._state_changed.wait(
                        min(0.5, max(0.005, min(upcoming))) if upcoming else 0.5
                    )
                    continue
                for call in expired:
                    call.answered = True
                    call.abandoned_at = now
                    # 同时置取消位：站源若能协作退出就尽快释放并发名额。
                    call.cancel_event.set()
            for call in expired:
                log(
                    f"请求超过 deadline，由宿主回错误帧 id={call.request_id} "
                    f"method={call.method} deadline={call.deadline_ms:.0f}ms"
                )
                try:
                    self._respond_error(
                        call.request_id,
                        ERROR_TIMEOUT,
                        f"请求超过 deadline（{call.deadline_ms:.0f}ms）",
                        details={"method": call.method},
                    )
                except Exception as error:  # noqa: BLE001 - 管道断了由下游收尾
                    log(f"回写超时错误帧失败：{error}")
                    return
            for call in abandoned:
                # 宽限已过、worker 仍未回来：这个并发名额再也收不回来（见 _abandon）。
                self._abandon(call)
                return

    def _abandon(self, call: _Call) -> None:
        """站源在 deadline 后仍未返回：本进程已收不回这个 worker，主动退出。

        为什么必须退出，而不是留一个卡住的线程：停在 requests.get 里的线程无法
        从外部打断，它会永久占住一个并发名额，可用容量越用越少，sidecar 最后
        「活着但不干活」。退出让上层按「sidecar 退出」重建进程——这也正是改造前
        宿主侧的唯一兜底（超时后杀进程），区别在于我们现在先给出了 SPIDER_TIMEOUT
        错误帧，用户看到的是超时，而不是莫名闪退。

        os._exit 前必须持有 _write_lock：否则可能把另一条正在写的帧截成半截，
        宿主会判成协议污染，真实死因（站源挂死）就被掩盖了。
        """
        with self._write_lock:
            log(
                f"站源在 deadline 后 {self._abandon_grace:.1f}s 仍未返回，放弃本进程 "
                f"id={call.request_id} method={call.method} "
                f"（已回 {ERROR_TIMEOUT}，exit={EXIT_PROCESS_ABANDONED}）"
            )
            os._exit(EXIT_PROCESS_ABANDONED)

    def _dispatch(self, message: Mapping[str, Any], call: _Call) -> None:
        request_id = call.request_id
        method = call.method
        if call.answered:
            # 排队期间就已到期/被拒：不再执行站源方法，把并发名额留给有效请求。
            with self._state_changed:
                self._calls.pop(request_id, None)
            log(f"请求已应答（超时或被拒），跳过执行 id={request_id} method={method}")
            return
        params = message.get("params") or {}
        context = CallContext(request_id, call.cancel_event)
        try:
            handler = self._handlers.get(method)
            if handler is None:
                raise UnsupportedMethod(method)
            result = handler(params, context)
            if result is _NO_RESPONSE:
                return
            # 已超时（或已取消）的请求不得再投递结果（§9.5）。
            if self._claim(call):
                self._respond_success(request_id, result)
        except Cancelled:
            if self._claim(call):
                self._respond_error(
                    request_id, ERROR_CANCELLED, "调用方已取消该请求"
                )
        except UnsupportedMethod as error:
            if self._claim(call):
                self._respond_error(
                    request_id,
                    ERROR_UNSUPPORTED,
                    str(error),
                    details={"capabilities": sorted(self.capabilities.values)},
                )
        except ValueError as error:
            if self._claim(call):
                self._respond_error(request_id, ERROR_BAD_REQUEST, str(error))
        except Exception as error:  # noqa: BLE001 - 任何异常都必须变成统一错误对象
            log(f"方法 {method} 失败：{error}\n{traceback.format_exc()}")
            if self._claim(call):
                self._respond_error(
                    request_id,
                    ERROR_PARSE_ERROR,
                    f"{type(error).__name__}: {error}",
                )
        finally:
            with self._state_changed:
                self._calls.pop(request_id, None)

    def _on_cancel(self, message: Mapping[str, Any]) -> None:
        params = message.get("params") or {}
        target = params.get("id")
        if not isinstance(target, str) or not target:
            log("取消消息缺少 id，已忽略")
            return
        with self._state_changed:
            call = self._calls.get(target)
        if call is None:
            log(f"取消未知请求 id={target}（可能已完成）")
            return
        # 站源可能正阻塞在 requests.get 里，取消只能「置位 + 丢弃结果」，
        # 不能指望它立刻返回（与 JS _onCancel 的标记语义相同）。
        call.cancel_event.set()

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
        # destroy 与同一批 stdin 里的 home/category 是并发线程。必须**先**等它们
        # 把响应写完，再拆 spider、再停服务循环：顺序反了的话，正在执行的 home
        # 会在 spider 已被 destroy 之后才去取数据，于是「派发了却没有响应」，
        # 宿主把它误判成崩溃。
        self._drain_in_flight(context)
        self._call_quietly("destroy")
        if not self.hold:
            self._stopping = True
        return {"ok": True}

    def _handle_shutdown(self, params: Mapping[str, Any], context: CallContext) -> dict:
        """显式停机：无论 hold 与否都结束服务循环。"""
        self._drain_in_flight(context)
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
