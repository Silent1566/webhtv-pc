#!/usr/bin/env python3
"""Python Spider 宿主（`webhtv-ipc-v1` sidecar 入口）。

用法：

    py -3 host.py --manifest manifests/fixture.json --entry spiders/fixture_spider.py

宿主负责协议帧、取消、心跳与错误信封；`--entry` 指定的模块只实现 Spider 语义，
不接触 stdio。这样第三方 Python 站源只需要写业务代码，帧实现只有一份
（`webhtv_ipc.py`），避免每个站点各自实现协议从而出现行为漂移。

安全边界（设计文档 §9.8）：
- 进程由主程序以独立子进程启动，工作目录是每站点独立临时目录；
- 只继承白名单环境变量，宿主凭据不传递给站源；
- 一切异常都转为统一错误对象写回 stdout，栈信息只写 stderr。
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path
from types import ModuleType

sys.path.insert(0, str(Path(__file__).resolve().parent))

from webhtv_ipc import SidecarServer, log  # noqa: E402


def load_module(path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(f"webhtv_spider_{path.stem}", path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"无法加载站源模块：{path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def build_spider(module: ModuleType, manifest: dict):
    factory = getattr(module, "create_spider", None)
    if callable(factory):
        return factory(manifest)
    spider_class = getattr(module, "Spider", None)
    if spider_class is None:
        raise SystemExit("站源模块必须提供 create_spider(manifest) 或 Spider 类")
    return spider_class(manifest)


def main() -> int:
    parser = argparse.ArgumentParser(description="WebHTV Python Spider sidecar")
    parser.add_argument("--entry", required=True, help="站源模块路径")
    parser.add_argument("--manifest", help="manifest JSON 路径")
    parser.add_argument("--max-workers", type=int, default=4)
    args = parser.parse_args()

    manifest: dict = {}
    if args.manifest:
        manifest_path = Path(args.manifest)
        if not manifest_path.is_file():
            log(f"manifest 不存在：{manifest_path}")
            return 2
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    entry = Path(args.entry)
    if not entry.is_file():
        log(f"站源入口不存在：{entry}")
        return 2

    try:
        module = load_module(entry)
        spider = build_spider(module, manifest)
    except SystemExit:
        raise
    except Exception as error:  # noqa: BLE001
        log(f"站源初始化失败：{type(error).__name__}: {error}")
        return 3

    server = SidecarServer(spider, manifest=manifest, max_workers=args.max_workers)
    log(f"sidecar 就绪 entry={entry.name} key={server.site_key}")
    return server.serve()


if __name__ == "__main__":
    raise SystemExit(main())
