#!/usr/bin/env python3
"""故障注入站源集合。

每个类只制造**一种**故障，便于把「崩溃/超时/取消/资源超限/协议污染」四类场景
分别定位（设计文档 §9.3.1、§9.8、§18.3）。所有站源都通过 `--entry` 单独加载，
不参与产品默认路径。

场景对照：

| 类 | 故障 | 期望宿主行为 |
| --- | --- | --- |
| `CrashSpider` | `home` 使进程立即退出 | `SPIDER_CRASHED`，主程序存活 |
| `HangSpider` | `home` 永不返回且不响应取消 | 超时 → 终止进程树 |
| `SlowCancelSpider` | `home` 慢慢返回但响应取消 | `SPIDER_CANCELLED`，进程回到空闲 |
| `HugeResponseSpider` | 响应超过 responseMiB | `SPIDER_RESOURCE_LIMIT` |
| `MemorySpider` | 持续分配内存 | 被 Job Object 内存上限终止 |
| `CpuSpider` | 死循环占用 CPU | 被 Job Object CPU 时间上限终止 |
| `PolluteSpider` | 往 stdout 直接打印非协议文本 | 判定协议污染并终止 |
| `PartialSpider` | manifest 只声明 home | 未声明方法返回 `SPIDER_UNSUPPORTED` |
| `GrandchildSpider` | 派生子进程后自身崩溃 | 进程树被一并终止，无残留 |
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from collections.abc import Mapping
from typing import Any


class CrashSpider:
    key = "test-crash"

    def __init__(self, manifest: Mapping[str, Any] | None = None):
        self.manifest = dict(manifest or {})

    def init(self, extend: str) -> dict:
        return {"ok": True}

    def capabilities(self) -> list[str]:
        return ["home", "category", "detail", "search", "play"]

    def home(self, params: Mapping[str, Any], context) -> dict:
        # 模拟站源在解析上游响应时崩溃（原生崩溃/显式退出都归为这一类）。
        os._exit(3)

    def category(self, params: Mapping[str, Any], context) -> dict:
        return {"list": []}

    def detail(self, params: Mapping[str, Any], context) -> dict:
        return {"list": []}

    def search(self, params: Mapping[str, Any], context) -> dict:
        return {"list": []}

    def play(self, params: Mapping[str, Any], context) -> dict:
        return {"url": ""}

    def destroy(self) -> None:
        pass


class HangSpider(CrashSpider):
    key = "test-hang"

    def home(self, params: Mapping[str, Any], context) -> dict:
        # 故意忽略取消：只有进程级超时能兜底（§9.5）。
        while True:
            time.sleep(3600)


class SlowCancelSpider(CrashSpider):
    key = "test-slow-cancel"

    def home(self, params: Mapping[str, Any], context) -> dict:
        # 5 秒后才返回，但每 10ms 检查一次取消，属于「可被取消的阻塞调用」。
        for _ in range(500):
            context.check_cancelled()
            time.sleep(0.01)
        return {"list": [], "class": []}


class HugeResponseSpider(CrashSpider):
    key = "test-huge"

    def home(self, params: Mapping[str, Any], context) -> dict:
        # 构造超过 responseMiB 的响应（manifest 默认 1 MiB）。
        blob = "x" * (3 * 1024 * 1024)
        return {"list": [{"vod_id": "big", "vod_name": "big", "vod_extra": blob}]}


class MemorySpider(CrashSpider):
    key = "test-memory"

    def home(self, params: Mapping[str, Any], context) -> dict:
        blocks = []
        while True:
            blocks.append(bytearray(8 * 1024 * 1024))
            time.sleep(0.01)


class CpuSpider(CrashSpider):
    key = "test-cpu"

    def home(self, params: Mapping[str, Any], context) -> dict:
        value = 0
        while True:
            value = (value * 31 + 7) % 1000003


class PolluteSpider(CrashSpider):
    key = "test-pollute"

    def home(self, params: Mapping[str, Any], context) -> dict:
        # 把日志写到 stdout 是典型协议污染：宿主必须终止运行时。
        sys.stdout.write(json.dumps({"note": "这不是协议帧"}) + "\n")
        sys.stdout.flush()
        return {"list": []}


class PartialSpider(CrashSpider):
    key = "test-partial"

    def capabilities(self) -> list[str]:
        return ["home"]


class GrandchildSpider(CrashSpider):
    key = "test-grandchild"

    def home(self, params: Mapping[str, Any], context) -> dict:
        # 派生一个长时间运行的孙进程，然后让自身崩溃。
        # 宿主的 Job Object 必须连孙进程一起终止（§9.8、§18.2.1）。
        child = subprocess.Popen(  # noqa: S603 - 测试用固定命令
            [sys.executable, "-c", "import time; time.sleep(600)"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        marker = os.environ.get("WEBHTV_TEST_GRANDCHILD_MARKER")
        if marker:
            try:
                with open(marker, "w", encoding="utf-8") as handle:
                    handle.write(str(child.pid))
            except OSError:
                pass
        time.sleep(0.3)
        os._exit(4)


def create_spider(manifest: Mapping[str, Any] | None = None):
    manifest = dict(manifest or {})
    name = manifest.get("config", {}).get("scenario", "crash")
    table = {
        "crash": CrashSpider,
        "hang": HangSpider,
        "slow-cancel": SlowCancelSpider,
        "huge": HugeResponseSpider,
        "memory": MemorySpider,
        "cpu": CpuSpider,
        "pollute": PolluteSpider,
        "partial": PartialSpider,
        "grandchild": GrandchildSpider,
    }
    spider_class = table.get(name)
    if spider_class is None:
        raise SystemExit(f"未知故障场景：{name}")
    return spider_class(manifest)
