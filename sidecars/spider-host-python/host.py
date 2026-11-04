#!/usr/bin/env python3
"""Python Spider 宿主（`webhtv-ipc-v1` sidecar 入口）。

用法：

    py -3 host.py --manifest manifests/fixture.json --entry spiders/fixture_spider.py
    py -3 host.py --manifest site.json --entry site/loader.py --catvod
    py -3 host.py --manifest site.json --entry site/spider.py --hold

宿主负责协议帧、取消、心跳与错误信封；`--entry` 指定的模块只实现 Spider 语义，
不接触 stdio。这样第三方 Python 站源只需要写业务代码，帧实现只有一份
（`webhtv_ipc.py`），避免每个站点各自实现协议从而出现行为漂移。

`--catvod`（或 manifest 的 `runtime` 为 `python-catvod`）表示入口是 CatVod 方言壳，
由 `webhtv_catvod.py` 包一层做签名与返回值映射（见该模块文件头）。

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
import traceback
from pathlib import Path
from types import ModuleType

#: stderr 必须固定成 UTF-8。
#:
#: 宿主（`spider_process.dart:330`）按 UTF-8 解码 stderr，而宿主以
#: `includeParentEnvironment: false` 启动子进程（§9.8 白名单），不会传
#: `PYTHONIOENCODING`。若不在这里钉住，Python 在 Windows 上默认按控制台代码页
#: （GBK）写 stderr，中文日志到宿主侧就是乱码——`app_state.dart:893` 那条
#: 「host.py 记一行 stderr 后 return 3」的用户提示会变成问号，诊断线索直接丢失。
for _stream in (sys.stdout, sys.stderr):
    _reconfigure = getattr(_stream, "reconfigure", None)
    if callable(_reconfigure):
        _reconfigure(encoding="utf-8", errors="replace")

sys.path.insert(0, str(Path(__file__).resolve().parent))

from webhtv_catvod import create_catvod_spider  # noqa: E402
from webhtv_ipc import SidecarServer, log  # noqa: E402

#: manifest.runtime 取该值时自动进入 CatVod 方言模式（等价于命令行 --catvod）。
CATVOD_RUNTIME = "python-catvod"


def load_module(path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(f"webhtv_spider_{path.stem}", path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"无法加载站源模块：{path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def resolve_spider_class(module: ModuleType):
    """定位站源类：优先 `Spider`，其次 manifest 指定的 `className`，最后取模块里唯一的类。

    CatVod 生态里类名并不都叫 `Spider`（历史上只认这个名字，导致类名不同的源直接
    SystemExit）。判定顺序保持「显式优先、隐式兜底」：
    1. 模块属性 `Spider`——绝大多数站源与所有 fixture 都走这条，行为与改造前一致；
    2. manifest 的 `className`（允许 `pkg.Cls` 或裸类名）——站源自己申报；
    3. 模块内**恰好一个**在站源模块本体定义、且提供了协议方法的类——无歧义的兜底。

    最后一种只在唯一时成立：模块里出现两个候选就报错，不猜。
    """
    declared = getattr(module, "Spider", None)
    if isinstance(declared, type):
        return declared

    wanted = ""
    manifest = getattr(module, "__webhtv_manifest__", None)
    if isinstance(manifest, dict):
        wanted = str(manifest.get("className") or "").strip()
    if wanted:
        candidate = getattr(module, wanted.rsplit(".", 1)[-1], None)
        if isinstance(candidate, type):
            return candidate

    methods = ("homeContent", "categoryContent", "detailContent", "searchContent", "playerContent")
    candidates = [
        value
        for name, value in vars(module).items()
        if isinstance(value, type)
        and value.__module__ == module.__name__
        and any(callable(getattr(value, item, None)) for item in methods)
    ]
    if len(candidates) == 1:
        return candidates[0]
    if len(candidates) > 1:
        names = "、".join(sorted(item.__name__ for item in candidates))
        raise SystemExit(f"站源模块包含多个候选 Spider 类（{names}），请用 manifest 的 className 指定")
    return None


def build_spider(module: ModuleType, manifest: dict):
    factory = getattr(module, "create_spider", None)
    if callable(factory):
        return factory(manifest)
    module.__webhtv_manifest__ = dict(manifest or {})
    spider_class = resolve_spider_class(module)
    if spider_class is None:
        raise SystemExit("站源模块必须提供 create_spider(manifest) 或 Spider 类")
    # Spider 类的构造签名在生态里并不统一：CatVod 蜘蛛几乎都是零参构造
    # （Atvp.py:199 `def __init__(self): super().__init__()`），宿主原生站源才吃 manifest。
    # 先按零参试，签名要求 manifest 时回退单参。TypeError 也可能来自 __init__ 内部，
    # 因此回退再失败时抛出**原始**异常（回退异常挂 __cause__），不把签名不符的
    # "takes 1 positional argument but 2 were given" 冒充成真实故障。
    try:
        return spider_class()
    except TypeError as zero_error:
        try:
            return spider_class(manifest)
        except TypeError as manifest_error:
            raise zero_error from manifest_error


def catvod_mode(args: argparse.Namespace, manifest: dict) -> bool:
    """CatVod 模式开关：命令行 --catvod 与 manifest.runtime 任一满足即启用。"""
    if bool(getattr(args, "catvod", False)):
        return True
    return str(manifest.get("runtime", "")).strip() == CATVOD_RUNTIME


def resolve_catvod_entry(entry: Path, requested: str) -> Path:
    """定位要加载的 CatVod 壳。

    `--entry` 是站点 manifest 的入口路径；`--catvod-entry` 是壳文件名，
    默认 `loader.py`，相对 `--entry` 所在目录解析（壳与入口同目录是常态）。
    壳不在入口同目录时，`--entry` 自身就是要加载的壳（manifest 的 entry 字段
    本来就指向壳），此时据实记一行日志，不静默替换。
    """
    candidate = Path(requested)
    if candidate.is_absolute():
        return candidate
    sibling = entry.parent / candidate
    if sibling.is_file():
        return sibling
    if entry.is_file():
        log(f"--catvod-entry {requested} 不存在，改用 --entry 指定的壳：{entry}")
        return entry
    return sibling


def main() -> int:
    parser = argparse.ArgumentParser(description="WebHTV Python Spider sidecar")
    parser.add_argument("--entry", required=True, help="站源模块路径")
    parser.add_argument("--manifest", help="manifest JSON 路径")
    parser.add_argument("--max-workers", type=int, default=4)
    parser.add_argument(
        "--catvod",
        action="store_true",
        help="按 CatVod/TVBox 方言加载站源（homeContent/searchContent 等映射为宿主方法）",
    )
    parser.add_argument(
        "--catvod-entry",
        default="loader.py",
        help="CatVod 壳文件名，相对 --entry 所在目录（默认 loader.py）",
    )
    parser.add_argument(
        "--hold",
        action="store_true",
        help="destroy 之后不退出，直到宿主显式 shutdown 或 stdin 关闭"
        "（站源自起本地取流服务时需要）",
    )
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
        if catvod_mode(args, manifest):
            # 站点 ext（订阅里的 base64 串）由 initialize.extend 原样透传给壳，本文件
            # **不得**把它归一化成 dict/JSON：Atvp.py:265 _decode_ext_payload 只做
            # base64 解码、:227 立刻取 payload["t4_play_type"]，归一化会让订阅里
            # 91 个站点全灭（AttributeError: 'NoneType' object has no attribute 'get'）。
            shell = resolve_catvod_entry(entry, args.catvod_entry)
            spider = create_catvod_spider(
                manifest, entry=shell.name, root=str(shell.parent)
            )
        else:
            module = load_module(entry)
            spider = build_spider(module, manifest)
    except SystemExit:
        raise
    except Exception as error:  # noqa: BLE001
        log(f"站源初始化失败：{type(error).__name__}: {error}")
        # 单行日志之外补完整栈：stdout 只承载协议帧，栈一律走 stderr。
        log(traceback.format_exc())
        return 3

    server = SidecarServer(
        spider,
        manifest=manifest,
        max_workers=args.max_workers,
        hold=args.hold,
    )
    log(f"sidecar 就绪 entry={entry.name} key={server.site_key} hold={args.hold}")
    return server.serve()


if __name__ == "__main__":
    raise SystemExit(main())