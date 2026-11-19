#!/usr/bin/env python3
"""sidecar 宿主的「宿主侧 deadline」与「并发上限」最小自测（无外部依赖）。

锁两件事，都是本语言与其他两种宿主对齐后才成立的行为：

1. 请求超期时由**宿主**回 `SPIDER_TIMEOUT` 错误帧——即使站源自己完全不看
   `context.check_cancelled()`（模拟典型站源阻塞在 `requests.get` 的情形）；
   并且站源之后才返回的结果**不再补发第二帧**（§9.5）。
2. 并发上限生效：同时在跑的请求不超过上限；队列满时立刻回
   `SPIDER_RESOURCE_LIMIT`，且每个请求都恰好收到一帧响应（不丢帧）。

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


class RecordingServer(SidecarServer):
    """把「放弃本进程」记下来而不是真的 os._exit（自测进程不能被自己带走）。"""

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.abandoned: list = []

    def _abandon(self, call) -> None:
        self.abandoned.append((call.request_id, call.method))
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
