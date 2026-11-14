#!/usr/bin/env python3
"""V4/V5 实测用的**可掐断媒体服务端**（`docs/phase7/design/03` §3.1/§3.2）。

## 为什么需要它

V4/V5 要回答的问题是：**播放接近片尾时数据源断了，客户端会不会把「提前 EOF」
当成「正常播完」，从而误触发连播**（`design/03` §3.3 的 D1/D2）。

要可靠复现，必须精确控制「在第几秒掐断」。用 `svc wifi disable` 断整机网络太粗
（会一并断掉 adb、logcat 与心跳），用防火墙规则又依赖管理员权限且难回滚。
用一个**自己的 HTTP 服务**最直接：它按字节范围响应，并在收到「掐断」指令后
立刻停止发送（对端看到的是连接被中断 / 读取超时，正是「缓存耗尽后无法回源」的形态）。

## 用法

```text
# 起服务（默认只监听回环；用 adb reverse 让设备可达）
py -3 tools/phase7/v4_cuttable_media.py --port 18090 --file <path.mp4>

# 另开一个终端：在对端播到某时刻后掐断
curl http://127.0.0.1:18090/__cut
# 恢复
curl http://127.0.0.1:18090/__restore
# 看当前状态
curl http://127.0.0.1:18090/__stats
```

## 设计约束（写错会让实验失去意义）

- **必须支持 Range 请求**：播放器普遍靠 Range 做 seek 与预读；不支持的话
  播放器会在起播阶段就失败，测不到「片尾提前 EOF」。
- **掐断要真的断在传输中**：不是返回 500（那会让播放器看到明确的错误码、
  走 `onError`），而是**停发数据并关闭连接**——这才对应「缓存耗尽后
  回源失败」的现场。
- **恢复后必须能继续**：V5 要验证「恢复后补一轮」这类行为，服务端必须能回到正常态。
"""

from __future__ import annotations

import argparse
import contextlib
import json
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

STATE = {
    "cut": False,
    "servedBytes": 0,
    "requests": 0,
    "cutCount": 0,
    "startedAt": None,
    "lastRange": None,
    "rateKbps": 0,
}
_LOCK = threading.Lock()

MEDIA: Path | None = None
RATE_KBPS = 0.0

RANGE_RE = re.compile(r"bytes=(\d*)-(\d*)")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # noqa: A002 (与基类同名)
        # 只打自己关心的事，避免刷屏（播放器会发很多 Range 请求）。
        pass

    def _json(self, value, status: int = 200) -> None:
        body = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0]
        if path == "/__cut":
            with _LOCK:
                STATE["cut"] = True
                STATE["cutCount"] += 1
            print(f"V4-EVIDENCE cut=on count={STATE['cutCount']}", flush=True)
            self._json({"cut": True, "count": STATE["cutCount"]})
            return
        if path == "/__restore":
            with _LOCK:
                STATE["cut"] = False
            print("V4-EVIDENCE cut=off", flush=True)
            self._json({"cut": False})
            return
        if path == "/__stats":
            self._json(dict(STATE))
            return
        if path in ("/media", "/", "/trailer.mp4"):
            self._serve_media()
            return
        self._json({"error": "not found"}, 404)

    def _serve_media(self) -> None:
        assert MEDIA is not None
        size = MEDIA.stat().st_size
        start, end = 0, size - 1
        status = 200
        header = self.headers.get("Range")
        with _LOCK:
            STATE["requests"] += 1
            STATE["lastRange"] = header
            if STATE["startedAt"] is None:
                STATE["startedAt"] = time.time()
        if header:
            match = RANGE_RE.search(header)
            if match:
                raw_start, raw_end = match.groups()
                if raw_start:
                    start = int(raw_start)
                if raw_end:
                    end = min(int(raw_end), size - 1)
                status = 206

        length = end - start + 1
        self.send_response(status)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()

        chunk = 32 * 1024
        sent = 0
        started = time.monotonic()
        with MEDIA.open("rb") as handle:
            handle.seek(start)
            remaining = length
            while remaining > 0:
                with _LOCK:
                    cut = STATE["cut"]
                    rate = STATE["rateKbps"]
                if cut:
                    # **停发并关连接**：这正是「缓存耗尽后回源失败」的形态。
                    # 返回 5xx 会让播放器走明确的 onError（那是另一种实验），
                    # 而这里要制造的是「流突然没了」。
                    print(
                        f"V4-EVIDENCE cut-during-transfer sent={sent}/{length}",
                        flush=True,
                    )
                    with contextlib.suppress(OSError):
                        self.connection.close()
                    return
                data = handle.read(min(chunk, remaining))
                if not data:
                    break
                try:
                    self.wfile.write(data)
                except OSError:
                    return
                sent += len(data)
                remaining -= len(data)
                with _LOCK:
                    STATE["servedBytes"] += len(data)
                # 限速（可选）：让发送速率与时长大致相当，从而「掐断」
                # 能真的饿死尚未缓冲的尾部。不限速时播放器会把整个文件
                # 一次性拉完，那时再掐断已经伤不到任何东西（实测踩过）。
                if rate and rate > 0:
                    expected = sent / (rate * 1024.0)
                    actual = time.monotonic() - started
                    if expected > actual:
                        time.sleep(min(expected - actual, 0.5))
        print(f"V4-EVIDENCE served bytes={sent}/{length}", flush=True)


def main() -> None:
    global MEDIA, RATE_KBPS
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18090)
    parser.add_argument("--file", required=True, help="要提供的 mp4 路径")
    parser.add_argument(
        "--rate-kbps",
        type=float,
        default=0,
        help=(
            "发送限速（KB/s）。**强烈建议给一个接近时长的值**："
            "4.4MB / 52s ≈ 84 KB/s，用 100 左右就能让播放器始终落后于源，"
            "从而「掐断」真能饿死尾部。0 = 不限速（播放器会一次性拉完，"
            "掐断伤不到任何东西——实测踩过这个坑）。"
        ),
    )
    args = parser.parse_args()

    media = Path(args.file)
    if not media.is_file():
        parser.error(f"媒体文件不存在：{media}")
    MEDIA = media
    with _LOCK:
        STATE["rateKbps"] = args.rate_kbps
    RATE_KBPS = args.rate_kbps

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    print(
        f"V4-EVIDENCE media server http://{args.host}:{args.port}/media "
        f"file={media.name} bytes={media.stat().st_size} "
        f"rateKbps={args.rate_kbps}",
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
