#!/usr/bin/env python3
"""sidecar 宿主的「宿主侧 deadline」与「并发上限」最小自测（无外部依赖）。

锁两件事，都是本语言与其他两种宿主对齐后才成立的行为：

1. 请求超期时由**宿主**回 `SPIDER_TIMEOUT` 错误帧——即使站源自己完全不看
   `context.check_cancelled()`（模拟典型站源阻塞在 `requests.get` 的情形）；
   并且站源之后才返回的结果**不再补发第二帧**（§9.5）。
2. 并发上限生效：同时在跑的请求不超过上限；队列满时立刻回
   `SPIDER_RESOURCE_LIMIT`，且每个请求都恰好收到一帧响应（不丢帧）。
3. 超时 worker 的回收不得连坐仍可服务的在途请求（包括排队与正在回帧）；
   健康请求完成或到期后，真正挂死的 worker 仍必须回收。

用法：python3 selftest_deadline.py（退出码 0 = 全绿）
"""

from __future__ import annotations

import io
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from webhtv_ipc import (  # noqa: E402
    DEFAULT_MAX_WORKERS,
    ERROR_RESOURCE_LIMIT,
    ERROR_TIMEOUT,
    SidecarServer,
    _BoundedWorkerPool,
    _Call,
    encode_frame,
    read_frame,
)

CHECKS: list[str] = []
FAILURES: list[str] = []


def check(condition: bool, label: str, detail: str = "") -> None:
    if condition:
        CHECKS.append(label)
        print(f"PASS {label}")
    else:
        FAILURES.append(label)
        print(f"FAIL {label}" + (f"：{detail}" if detail else ""))


class Capture:
    """线程安全的 stdout 替身：与 write_frame 一样「写一帧 flush 一次」。"""

    def __init__(self) -> None:
        self._buffer = io.BytesIO()
        self._lock = threading.Lock()

    def write(self, data: bytes) -> int:
        with self._lock:
            return self._buffer.write(data)

    def flush(self) -> None:
        pass

    def frames(self) -> list:
        """解出已落盘的完整帧；末尾没写完的半帧忽略。"""
        with self._lock:
            raw = self._buffer.getvalue()
        stream = io.BytesIO(raw)
        out = []
        while True:
            try:
                frame = read_frame(stream)
            except Exception:  # noqa: BLE001 - 半帧就是「还没写完」
                break
            if frame is None:
                break
            out.append(frame)
        return out


def request(request_id: str, method: str, *, deadline_ms: int | None = None) -> bytes:
    payload = {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": method,
        "params": {},
    }
    if deadline_ms is not None:
        payload["deadlineMs"] = deadline_ms
    return encode_frame(payload)


def start_server(spider, manifest=None, *, queue_capacity: int = 8, frames=()):
    stdout = Capture()
    server = SidecarServer(
        spider,
        manifest=manifest,
        stdin=io.BytesIO(b"".join(frames)),
        stdout=stdout,
        queue_capacity=queue_capacity,
    )
    thread = threading.Thread(target=server.serve, daemon=True)
    thread.start()
    return server, stdout, thread


class BlockingSpider:
    """模拟阻塞在 requests.get 的站源：从不 check_cancelled，也不会提前返回。"""

    key = "selftest-blocking"

    def __init__(self, seconds: float) -> None:
        self.seconds = seconds
        self.returned = False

    def capabilities(self) -> list:
        return ["home"]

    def init(self, extend: str) -> dict:
        return {"ok": True}

    def home(self, params, context) -> dict:
        time.sleep(self.seconds)
        self.returned = True
        return {"list": [], "class": []}

    def destroy(self) -> None:
        pass


def case_deadline() -> None:
    print("== 用例 1：超期请求由宿主回错误帧 ==")
    # 站源阻塞 0.5s、deadline 100ms：宿主必须在站源返回之前就把错误帧写出去，
    # 同时 0.5s 短于放弃宽限 1.0s，进程不该退出（那是用例 4 的事）。
    spider = BlockingSpider(seconds=0.5)
    started = time.monotonic()
    _server, stdout, thread = start_server(
        spider,
        {"limits": {"concurrency": 4}},
        frames=[request("d-1", "home", deadline_ms=100)],
    )

    frame = None
    while time.monotonic() - started < 0.8:
        for item in stdout.frames():
            if item.get("id") == "d-1":
                frame = item
        if frame is not None:
            break
        time.sleep(0.01)
    elapsed = time.monotonic() - started
    returned_at_answer = spider.returned

    check(frame is not None, "超期请求收到错误帧", "0.8s 内没有任何响应帧")
    if frame is None:
        return
    error = frame.get("error") or {}
    check(error.get("code") == ERROR_TIMEOUT, f"错误码为 {ERROR_TIMEOUT}", str(error.get("code")))
    check(error.get("category") == "site", "错误 category 与其它宿主一致（site）", str(error.get("category")))
    check(error.get("retryable") is True, "超时错误可重试（retryable=true）", str(error.get("retryable")))
    check(error.get("requestId") == "d-1", "错误对象带 requestId", str(error.get("requestId")))
    check(
        returned_at_answer is False,
        "错误帧在站源返回之前就发出（宿主主动回帧，不是等站源）",
        f"站源当时已返回={returned_at_answer}",
    )
    check(elapsed < 0.4, "回帧耗时不随站源阻塞时长增长", f"{elapsed:.2f}s（站源阻塞 0.5s）")

    thread.join(6.0)
    total = [item for item in stdout.frames() if item.get("id") == "d-1"]
    check(len(total) == 1, "站源后来返回的结果被丢弃，不补发第二帧", f"共 {len(total)} 帧")


class GateSpider:
    """所有 home 都卡在闸门上：用来观察「同时在跑几个」。"""

    key = "selftest-gate"

    def __init__(self) -> None:
        self.gate = threading.Event()
        self.lock = threading.Lock()
        self.running = 0
        self.peak = 0

    def capabilities(self) -> list:
        return ["home"]

    def init(self, extend: str) -> dict:
        return {"ok": True}

    def home(self, params, context) -> dict:
        with self.lock:
            self.running += 1
            self.peak = max(self.peak, self.running)
        try:
            self.gate.wait(10.0)
        finally:
            with self.lock:
                self.running -= 1
        return {"list": [], "class": []}

    def destroy(self) -> None:
        pass


def case_concurrency() -> None:
    print("== 用例 2：并发上限 + 队列满回资源错误 ==")
    spider = GateSpider()
    frames = [request(f"c-{index}", "home", deadline_ms=10000) for index in range(6)]
    server, stdout, thread = start_server(
        spider,
        {"limits": {"concurrency": 2}},
        queue_capacity=2,
        frames=frames,
    )
    check(
        server.max_workers == 2,
        "并发上限取自 manifest 的 limits.concurrency",
        f"max_workers={server.max_workers}",
    )

    waited = 0.0
    while waited < 3.0 and spider.running < 2:
        time.sleep(0.01)
        waited += 0.01
    # 让读循环把剩下的帧走完（接受或拒绝），拒绝路径会立刻写错误帧。
    time.sleep(0.3)
    peak = spider.peak
    spider.gate.set()
    thread.join(6.0)

    received = stdout.frames()
    codes = [(item.get("error") or {}).get("code") for item in received]
    limits = [item for item in received if (item.get("error") or {}).get("code") == ERROR_RESOURCE_LIMIT]
    successes = [item for item in received if "result" in item]

    check(peak == 2, "同时在跑的请求不超过并发上限", f"peak={peak}")
    check(len(received) == len(frames), "每个请求都恰好收到一帧响应（不丢帧）", f"{len(received)}/{len(frames)} 帧")
    check(len({item.get("id") for item in received}) == len(received), "没有重复 id 的响应", str(sorted(item.get("id") for item in received)))
    check(len(limits) >= 1, f"队列满时回 {ERROR_RESOURCE_LIMIT}", str(codes))
    check(len(successes) >= 1, "被接受的请求正常返回结果", str(codes))
    if limits:
        details = (limits[0].get("error") or {}).get("details") or {}
        check(details.get("maxWorkers") == 2, "拒绝帧写明并发上限", str(details))
        check(
            (limits[0].get("error") or {}).get("category") == "resource",
            "拒绝帧 category=resource（沿用既有错误码体系）",
            str((limits[0].get("error") or {}).get("category")),
        )


class HangSpider:
    """永远不返回的站源（模拟 requests.get 里彻底卡住）。"""

    key = "selftest-hang"

    def __init__(self) -> None:
        self.gate = threading.Event()

    def capabilities(self) -> list:
        return ["home"]

    def init(self, extend: str) -> dict:
        return {"ok": True}

    def home(self, params, context) -> dict:
        self.gate.wait(30.0)
        return {"list": [], "class": []}

    def release(self) -> None:
        self.gate.set()

    def destroy(self) -> None:
        pass


class RecordingCondition(threading.Condition):
    def __init__(self, lock, server) -> None:
        super().__init__(lock)
        self.server = server
        self.protected_waits: list = []
        self.notifications: list = []

    def wait(self, timeout=None):
        calls = list(self.server._calls.values())
        now = time.monotonic()
        if any(call.abandoned_at is None for call in calls) and any(
            call.abandoned_at is not None
            and now - call.abandoned_at >= self.server._abandon_grace
            for call in calls
        ):
            self.protected_waits.append(timeout)
            self.server.recycle_decision.set()
        return super().wait(timeout)

    def notify_all(self) -> None:
        self.notifications.append(tuple(self.server._calls))
        super().notify_all()


class RecordingServer(SidecarServer):
    """把「放弃本进程」记下来而不是真的 os._exit（自测进程不能被自己带走）。"""

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.abandoned: list = []
        self.abandoned_event = threading.Event()
        self.frames_at_abandon: list = []
        self.recycle_decision = threading.Event()
        self.abandon_attempted = threading.Event()
        self.guard_held_at_abandon = False
        self._state_changed = RecordingCondition(self._state_lock, self)

    def _abandon(self, call) -> None:
        self.guard_held_at_abandon = self._state_lock.locked()
        self.abandon_attempted.set()
        self.recycle_decision.set()
        with self._write_lock:
            self.frames_at_abandon = self.stdout.frames()
            self.abandoned.append((call.request_id, call.method))
            self.abandoned_event.set()
        release = getattr(self.spider, "release", None)
        if callable(release):
            release()


def case_abandon() -> None:
    print("== 用例 3：站源挂死时宿主在宽限后放弃本进程 ==")
    spider = HangSpider()
    stdout = Capture()
    server = RecordingServer(
        spider,
        manifest={"limits": {"concurrency": 2}},
        stdin=io.BytesIO(request("a-1", "home", deadline_ms=100)),
        stdout=stdout,
        abandon_grace=0.05,
    )
    thread = threading.Thread(target=server.serve, daemon=True)
    thread.start()

    waited = 0.0
    while waited < 2.0 and not server.abandoned:
        time.sleep(0.01)
        waited += 0.01
    thread.join(5.0)

    frames = [item for item in stdout.frames() if item.get("id") == "a-1"]
    codes = [((item.get("error") or {}).get("code")) for item in frames]
    check(len(server.abandoned) == 1, "宽限后判定 worker 不可回收并放弃本进程", str(server.abandoned))
    if server.abandoned:
        check(server.abandoned[0] == ("a-1", "home"), "放弃的是那条超期请求", str(server.abandoned[0]))
    check(codes == [ERROR_TIMEOUT], "放弃之前先回了错误帧（用户看到超时而不是闪退）", str(codes))


class ConcurrentHangSpider(HangSpider):
    """slow 永不主动释放；healthy 由测试决定何时完成。"""

    def __init__(self) -> None:
        super().__init__()
        self.healthy_gate = threading.Event()
        self.bridge_gate = threading.Event()
        self.started = {name: threading.Event() for name in ("slow", "healthy", "bridge")}

    def home(self, params, context) -> dict:
        self.started[context.request_id].set()
        gate = {"slow": self.gate, "healthy": self.healthy_gate, "bridge": self.bridge_gate}[context.request_id]
        gate.wait(30.0)
        return {"done": context.request_id}

    def release(self) -> None:
        super().release()
        self.healthy_gate.set()
        self.bridge_gate.set()


class ConcurrentCapture(Capture):
    def __init__(self, *, hold_reply: bool = False) -> None:
        super().__init__()
        self.responses = {name: threading.Event() for name in ("slow", "healthy")}
        self.reply_started = threading.Event()
        self.reply_gate = threading.Event()
        if not hold_reply:
            self.reply_gate.set()

    def write(self, data: bytes) -> int:
        frame = read_frame(io.BytesIO(data))
        if frame.get("id") == "healthy" and "result" in frame:
            self.reply_started.set()
            self.reply_gate.wait(5.0)
        return super().write(data)

    def flush(self) -> None:
        for frame in self.frames():
            event = self.responses.get(frame.get("id"))
            if event is not None:
                event.set()


def case_abandon_preserves_healthy(*, hold_reply: bool = False) -> None:
    phase = "已 claim、正在回帧" if hold_reply else "仍在执行"
    print(f"== 并发回收：健康请求{phase}时不得连坐 ==")
    spider = ConcurrentHangSpider()
    stdout = ConcurrentCapture(hold_reply=hold_reply)
    server = RecordingServer(
        spider,
        manifest={"limits": {"concurrency": 2}},
        stdin=io.BytesIO(
            request("slow", "home", deadline_ms=100)
            + request("healthy", "home", deadline_ms=5000)
        ),
        stdout=stdout,
        abandon_grace=0.05,
    )
    thread = threading.Thread(target=server.serve, daemon=True)
    thread.start()
    try:
        check(spider.started["slow"].wait(1.0), "超时 worker 已进入 gate")
        check(spider.started["healthy"].wait(1.0), f"健康请求{phase}：已真正并发执行")
        check(stdout.responses["slow"].wait(1.0), f"健康请求{phase}：先收到慢请求超时帧")
        if hold_reply:
            spider.healthy_gate.set()
            check(stdout.reply_started.wait(1.0), "健康请求已 claim、但响应帧尚未写完")
        check(server.recycle_decision.wait(1.0), f"健康请求{phase}：监视线程已跨过宽限并作出决策")
        premature = server.abandoned_event.wait(0.2)
        check(not premature and not server.abandon_attempted.is_set(), f"宽限后不连坐{phase}的健康请求", str(server.abandoned))
        waits = server._state_changed.protected_waits
        check(bool(waits) and all(delay >= 0.05 for delay in waits), f"健康请求{phase}：成熟回收点退避等待，不热循环", str(waits))
        with server._state_changed:
            server._state_changed.notifications.clear()
        check(not spider.gate.is_set(), f"健康请求{phase}：慢 worker 仍挂在 gate 上")
        spider.healthy_gate.set()
        stdout.reply_gate.set()
        check(stdout.responses["healthy"].wait(1.0), f"健康请求{phase}：释放 gate 后成功回帧")
        check(server.abandoned_event.wait(1.0), f"健康请求{phase}：成功后仍回收挂死 worker")
        by_id = {frame["id"]: frame for frame in server.frames_at_abandon}
        check(
            by_id.get("healthy", {}).get("result") == {"done": "healthy"},
            f"健康请求{phase}：回收之前成功帧已完整送达",
            str(server.frames_at_abandon),
        )
        check(server.abandoned == [("slow", "home")], f"健康请求{phase}：只回收慢请求", str(server.abandoned))
        check(server.guard_held_at_abandon, f"健康请求{phase}：退出决策与新接收共用状态锁")
        check(("slow",) in server._state_changed.notifications, f"健康请求{phase}：完成移除立即通知监视线程", str(server._state_changed.notifications))
    finally:
        stdout.reply_gate.set()
        spider.release()
        thread.join(2.0)
    check(not thread.is_alive(), f"健康请求{phase}：测试线程已收尾")
    frames = stdout.frames()
    check(len(frames) == 2 and len({frame["id"] for frame in frames}) == 2, f"健康请求{phase}：无迟到双帧", str(frames))


def case_abandon_preserves_queue() -> None:
    print("== 并发回收：排队健康请求也受保护，到期后仍回收 ==")
    spider = ConcurrentHangSpider()
    stdout = ConcurrentCapture()
    server = RecordingServer(
        spider,
        manifest={"limits": {"concurrency": 1}},
        stdin=io.BytesIO(
            request("slow", "home", deadline_ms=100)
            + request("healthy", "home", deadline_ms=1000)
        ),
        stdout=stdout,
        abandon_grace=0.05,
    )
    thread = threading.Thread(target=server.serve, daemon=True)
    thread.start()
    try:
        check(spider.started["slow"].wait(1.0), "排队场景：慢 worker 已进入 gate")
        check(stdout.responses["slow"].wait(1.0), "排队场景：先收到慢请求超时帧")
        check(server.recycle_decision.wait(1.0), "排队场景：监视线程已跨过宽限并作出决策")
        premature = server.abandoned_event.wait(0.2)
        check(not premature and not server.abandon_attempted.is_set(), "宽限后不连坐已接受但尚未执行的健康请求", str(server.abandoned))
        check(not spider.started["healthy"].is_set(), "健康请求确实仍在队列中")
        check(stdout.responses["healthy"].wait(1.5), "排队请求到期仍由宿主主动回帧")
        check(server.abandoned_event.wait(1.0), "最后健康请求到期后仍回收挂死 worker")
        codes = [frame.get("error", {}).get("code") for frame in server.frames_at_abandon]
        check(codes == [ERROR_TIMEOUT, ERROR_TIMEOUT], "回收之前两条超时帧均已完整送达", str(server.frames_at_abandon))
    finally:
        spider.release()
        thread.join(2.0)
    check(not thread.is_alive(), "排队场景：测试线程已收尾")
    check(not spider.started["healthy"].is_set(), "排队超时后不执行站源方法")
    check(len(stdout.frames()) == 2, "排队超时没有迟到双帧", str(stdout.frames()))


class SnapshotServer(RecordingServer):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.timeout_written = {name: threading.Event() for name in ("slow", "bridge")}
        self.continue_timeout = {name: threading.Event() for name in ("slow", "bridge")}

    def _respond_error(self, request_id, *args, **kwargs) -> None:
        super()._respond_error(request_id, *args, **kwargs)
        if request_id in self.timeout_written:
            self.timeout_written[request_id].set()
            self.continue_timeout[request_id].wait(3.0)


def case_abandon_rechecks_snapshot() -> None:
    print("== 并发回收：snapshot 后接受新请求，退出前必须重锁复核 ==")
    spider = ConcurrentHangSpider()
    stdout = ConcurrentCapture()
    server = SnapshotServer(
        spider,
        manifest={"limits": {"concurrency": 2}},
        stdin=io.BytesIO(request("slow", "home", deadline_ms=100)),
        stdout=stdout,
        abandon_grace=0.05,
    )
    thread = threading.Thread(target=server.serve, daemon=True)
    thread.start()
    try:
        check(server.timeout_written["slow"].wait(1.0), "snapshot 场景：慢请求已回超时帧，监视线程停在锁外")
        server._accept(read_frame(io.BytesIO(request("bridge", "home", deadline_ms=100))))
        # 暂停监视线程，直到 slow 的回收点和 bridge 的 deadline 均已到达。
        with server._state_changed:
            bridge_deadline = server._calls["bridge"].deadline_at
            slow_recycle = server._calls["slow"].abandoned_at + server._abandon_grace
        threading.Event().wait(max(0.0, max(bridge_deadline, slow_recycle) - time.monotonic()) + 0.01)
        server.continue_timeout["slow"].set()
        check(server.timeout_written["bridge"].wait(1.0), "snapshot 同一轮同时存在 expired bridge 与 abandoned slow")
        server._accept(read_frame(io.BytesIO(request("healthy", "home", deadline_ms=5000))))
        server.continue_timeout["bridge"].set()
        check(server.recycle_decision.wait(1.0), "snapshot 场景：监视线程已重新作出回收决策")
        check(not server.abandon_attempted.is_set(), "snapshot 后新接受的健康请求阻止旧回收决策", str(server.abandoned))
        spider.bridge_gate.set()
        spider.healthy_gate.set()
        check(stdout.responses["healthy"].wait(1.0), "snapshot 后接受的请求仍能成功")
        check(server.abandoned_event.wait(1.0), "snapshot 场景：健康请求完成后仍回收挂死 worker")
        by_id = {frame["id"]: frame for frame in server.frames_at_abandon}
        check(by_id.get("healthy", {}).get("result") == {"done": "healthy"}, "snapshot 场景：退出前成功响应已送达", str(server.frames_at_abandon))
        check(server.guard_held_at_abandon, "snapshot 场景：最终退出仍持有接收锁")
    finally:
        for event in server.continue_timeout.values():
            event.set()
        spider.release()
        thread.join(2.0)
    check(not thread.is_alive(), "snapshot 场景：测试线程已收尾")
    check(len(stdout.frames()) == 3, "snapshot 场景：三个请求各回一帧", str(stdout.frames()))


def case_state_removal_notifies() -> None:
    print("== 条件唤醒：完成、拒绝、跳过均通知在途表变化 ==")
    for path in ("complete", "reject", "skip"):
        stdout = Capture()
        server = RecordingServer(BlockingSpider(seconds=0), stdout=stdout)
        message = read_frame(io.BytesIO(request(path, "home")))
        if path == "reject":
            server._accept(message)  # 没有工作池，走真实拒绝分支。
        else:
            call = _Call(path, "home", 5000)
            call.answered = path == "skip"
            with server._state_changed:
                server._calls[path] = call
            server._dispatch(message, call)
        check(not server._calls, f"{path}：移除在途记录")
        check(
            bool(server._state_changed.notifications) and server._state_changed.notifications[-1] == (),
            f"{path}：移除后立即 notify，不依赖兜底轮询",
            str(server._state_changed.notifications),
        )


class RefusalServer(SnapshotServer):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.refusal_ready = threading.Event()
        self.refusal_gate = threading.Event()

    def _respond_error(self, request_id, *args, **kwargs) -> None:
        if request_id == "refused":
            self.refusal_ready.set()
            self.refusal_gate.wait(3.0)
        super()._respond_error(request_id, *args, **kwargs)


class RefusalCapture(ConcurrentCapture):
    def __init__(self) -> None:
        super().__init__()
        self.flush_ready = threading.Event()
        self.flush_gate = threading.Event()

    def flush(self) -> None:
        if self.frames()[-1].get("id") == "refused":
            self.flush_ready.set()
            self.flush_gate.wait(3.0)
        super().flush()


def case_abandon_preserves_refusal() -> None:
    print("== 拒绝回帧：真实满队列 + 成熟挂死 worker 不得截断拒绝帧 ==")
    spider = ConcurrentHangSpider()
    stdout = RefusalCapture()
    server = RefusalServer(
        spider,
        manifest={"limits": {"concurrency": 1}},
        stdin=io.BytesIO(request("slow", "home", deadline_ms=100)),
        stdout=stdout,
        queue_capacity=1,
        abandon_grace=0.05,
    )
    thread = threading.Thread(target=server.serve, daemon=True)
    thread.start()
    reject_thread = threading.Thread(
        target=server._accept,
        args=(read_frame(io.BytesIO(request("refused", "home", deadline_ms=5000))),),
        daemon=True,
    )
    try:
        check(spider.started["slow"].wait(1.0), "拒绝场景：唯一 worker 真实挂起")
        check(server.timeout_written["slow"].wait(1.0), "拒绝场景：慢请求超时帧已完整送达")
        server._accept(read_frame(io.BytesIO(request("healthy", "home", deadline_ms=50))))
        with server._state_changed:
            queued_deadline = server._calls["healthy"].deadline_at
            recycle_at = server._calls["slow"].abandoned_at + server._abandon_grace
        threading.Event().wait(max(0.0, max(queued_deadline, recycle_at) - time.monotonic()) + 0.01)
        reject_thread.start()
        check(server.refusal_ready.wait(1.0), "拒绝场景：真实满队列拒绝路径已 claim、停在写帧之前")
        with server._state_changed:
            refused = server._calls.get("refused")
        check(refused is not None and refused.answered, "拒绝回帧期间仍保留 answered 在途记录")
        server.continue_timeout["slow"].set()
        check(server.recycle_decision.wait(1.0), "拒绝场景：监视线程已到成熟回收点")
        check(not server.abandon_attempted.is_set(), "拒绝帧尚未 write/flush 时不得退出", str(server.abandoned))
        check(not any(frame.get("id") == "refused" for frame in stdout.frames()), "拒绝 gate 确实尚未输出错误帧")
        server.refusal_gate.set()
        check(stdout.flush_ready.wait(1.0), "拒绝帧已 write、flush gate 仍扣住")
        with server._state_changed:
            refused = server._calls.get("refused")
        check(refused is not None and refused.answered, "拒绝错误帧 flush 返回前仍保留在途记录")
        check(not server.abandon_attempted.is_set(), "拒绝错误帧 flush 尚未完成时不得退出")
        stdout.flush_gate.set()
        reject_thread.join(1.0)
        check(not reject_thread.is_alive(), "拒绝 gate 释放后完整回帧并返回")
        check(server.abandoned_event.wait(1.0), "拒绝帧 flush 后仍回收挂死 worker")
        by_id = {frame["id"]: frame for frame in server.frames_at_abandon}
        check(by_id.get("refused", {}).get("error", {}).get("code") == ERROR_RESOURCE_LIMIT, "退出前完整 SPIDER_RESOURCE_LIMIT 帧已送达", str(server.frames_at_abandon))
        check(server.guard_held_at_abandon, "拒绝场景：最终退出持状态锁")
    finally:
        stdout.flush_gate.set()
        server.refusal_gate.set()
        for event in server.continue_timeout.values():
            event.set()
        spider.release()
        if reject_thread.ident is not None:
            reject_thread.join(1.0)
        thread.join(2.0)
    check(not thread.is_alive(), "拒绝场景：服务线程已收尾")
    frames = stdout.frames()
    check(len(frames) == 3 and len({frame["id"] for frame in frames}) == 3, "拒绝场景：三请求各一帧，无迟到双发", str(frames))


class LifecycleSpider(ConcurrentHangSpider):
    def __init__(self) -> None:
        super().__init__()
        self.init_count = 0
        self.destroy_count = 0

    def init(self, extend: str) -> dict:
        self.init_count += 1
        return {"ok": True}

    def destroy(self) -> None:
        self.destroy_count += 1


def case_controls_do_not_pin_hung_pool() -> None:
    print("== 控制请求：单 worker 挂死时也必须完整应答，不能无 deadline 排队 ==")
    for method in ("heartbeat", "initialize", "destroy", "shutdown"):
        spider = LifecycleSpider()
        stdout = ConcurrentCapture()
        server = SnapshotServer(
            spider,
            manifest={"limits": {"concurrency": 1}},
            stdin=io.BytesIO(request("slow", "home", deadline_ms=100)),
            stdout=stdout,
            abandon_grace=0.05,
            hold=True,
        )
        thread = threading.Thread(target=server.serve, daemon=True)
        thread.start()
        try:
            check(spider.started["slow"].wait(1.0), f"{method}：唯一 worker 真实挂死")
            check(server.timeout_written["slow"].wait(1.0), f"{method}：慢请求已回超时帧")
            server._accept(read_frame(io.BytesIO(request("control", method))))
            controls = [frame for frame in stdout.frames() if frame.get("id") == "control"]
            check(len(controls) == 1, f"{method}：不等挂死 worker 就完整回帧", str(controls))
            expected = (
                bool(controls) and controls[0].get("result") == {"ok": True}
                if method == "heartbeat"
                else bool(controls) and controls[0].get("error", {}).get("code") == ERROR_RESOURCE_LIMIT
            )
            check(expected, f"{method}：heartbeat 成功，其它无空闲 worker 明确回资源限制", str(controls))
            check(spider.init_count == 0 and spider.destroy_count == 0 and not server._stopping, f"{method}：未执行的生命周期调用不改变站源/hold/停止状态")
            server.continue_timeout["slow"].set()
            check(server.abandoned_event.wait(1.0), f"{method}：控制应答后仍回收挂死 worker")
            by_id = {frame["id"]: frame for frame in server.frames_at_abandon}
            check("control" in by_id, f"{method}：退出前控制应答已完整送达", str(server.frames_at_abandon))
            check(server.max_workers == 1, f"{method}：未增加业务并发或线程名额")
        finally:
            for event in server.continue_timeout.values():
                event.set()
            spider.release()
            thread.join(2.0)
        check(not thread.is_alive(), f"{method}：服务线程已收尾")
        frames = stdout.frames()
        check(len(frames) == 2 and len({frame["id"] for frame in frames}) == 2, f"{method}：无丢帧或迟到双发", str(frames))


def case_controls_with_available_worker() -> None:
    print("== 控制请求：有空闲 worker 时保留 initialize/destroy/hold/shutdown 语义 ==")
    spider = LifecycleSpider()
    stdout = Capture()
    server = RecordingServer(spider, stdout=stdout, max_workers=1, hold=True)
    server._pool = _BoundedWorkerPool(1, 1)
    try:
        for method in ("initialize", "destroy", "heartbeat", "shutdown"):
            server._accept(read_frame(io.BytesIO(request(method, method))))
            check(server._pool.wait_idle(1.0), f"空闲 worker 正常完成 {method}")
            frame = next((item for item in stdout.frames() if item.get("id") == method), {})
            check("result" in frame, f"有空闲 worker 时 {method} 正常成功", str(frame))
            check(server._stopping is (method == "shutdown"), f"{method}：hold 下只有 shutdown 结束服务")
        check(spider.init_count == 1 and spider.destroy_count == 2, "initialize/destroy/shutdown 生命周期回调次数不变")
    finally:
        server._pool.shutdown(timeout=1.0)


def case_defaults() -> None:
    print("== 用例 4：并发与 deadline 默认值 ==")
    default_server = SidecarServer(BlockingSpider(seconds=0))
    check(
        default_server.max_workers == DEFAULT_MAX_WORKERS,
        f"manifest 未声明并发时用默认 {DEFAULT_MAX_WORKERS}",
        f"max_workers={default_server.max_workers}",
    )
    explicit = SidecarServer(BlockingSpider(seconds=0), max_workers=3)
    check(explicit.max_workers == 3, "显式 --max-workers 覆盖 manifest", f"max_workers={explicit.max_workers}")
    # 与 JS host.js _deadlineOf 同一张默认值表。
    check(default_server._deadline_of({"method": "search"}) == 25000.0, "search 默认 25s")
    check(default_server._deadline_of({"method": "play"}) == 20000.0, "play 默认 20s")
    check(default_server._deadline_of({"method": "detail"}) == 20000.0, "detail 默认 20s")
    check(default_server._deadline_of({"method": "home"}) == 30000.0, "其它方法默认 30s")
    check(
        default_server._deadline_of({"method": "home", "deadlineMs": 700}) == 700.0,
        "请求帧的 deadlineMs 优先",
    )
    check(
        default_server._deadline_of({"method": "home", "deadlineMs": 600000}) == 120000.0,
        "超过 120s 的 deadline 被截断（与 JS 同上限）",
    )
    check(default_server._deadline_of({"method": "heartbeat"}) is None, "控制类方法不设宿主 deadline")


def main() -> int:
    case_deadline()
    case_concurrency()
    case_abandon()
    case_abandon_preserves_healthy()
    case_abandon_preserves_healthy(hold_reply=True)
    case_abandon_preserves_queue()
    case_abandon_rechecks_snapshot()
    case_state_removal_notifies()
    case_abandon_preserves_refusal()
    case_controls_do_not_pin_hung_pool()
    case_controls_with_available_worker()
    case_defaults()
    print()
    print(f"通过 {len(CHECKS)} 项，失败 {len(FAILURES)} 项")
    if FAILURES:
        for item in FAILURES:
            print(f"  - {item}")
        return 1
    print("SELFTEST_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
