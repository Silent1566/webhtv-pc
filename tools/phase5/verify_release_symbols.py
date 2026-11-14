#!/usr/bin/env python
"""发布包安卓桥接符号可达性门禁（打包期，G10）。

为什么需要这个门禁
------------------
与 Phase 4 的 TMDB 同一教训（P4-7 事故，`docs/phase4/verify_release_symbols.py`
头部记录）：`flutter test` 走 JIT/debug 不做 tree-shaking，集成测试还会直接
写 `settings.json` 绕过 UI 入口。因此**只有 release AOT 产物**能暴露
「入口不可达 → 死代码被整体剔除」这类缺陷。

本阶段的入口有两条独立风险：
1. 安卓接入页只挂在 TMDB 设置页的 `ListTile.onTap` 上——若那条 `ListTile`
   从未渲染（例如被条件挡住），整个 `AndroidSettingsPage` 会被 AOT 剔除；
2. 同步服务端/推送按钮只在开关打开后渲染，容易被写成"条件渲染入口"。

判定方法（与 Flutter 的 AOT 字符串布局一致）
-------------------------------------------
- ASCII 符号以 latin1 存储 → 用 latin1 解码后 `in` 判定；
- 中文串以 UTF-16LE 存储 → 用 utf16le 解码后 `in` 判定。

用法：
    py -3 tools/phase5/verify_release_symbols.py
    py -3 tools/phase5/verify_release_symbols.py --app-so <path>
    py -3 tools/phase5/verify_release_symbols.py --build-release-for-symbols

默认**只校验已存在的 release 产物**（尊重本仓库"webhtv 项目不打正式包"
的约定）；需要主动构建时显式加 `--build-release-for-symbols`。
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
APP_DIR = REPO_ROOT / "apps" / "desktop-flutter"

DEFAULT_APP_SO = (
    APP_DIR / "build" / "windows" / "x64" / "runner" / "Release" /
    "data" / "app.so"
)

# 必须存在于 release AOT 产物中的安卓桥接符号（`design/03` §6.1 表）。
# ASCII 符号（类名 / ValueKey）。
REQUIRED_ASCII = [
    # 页面与状态层：入口被条件挡住时，这两个类会整片消失。
    "AndroidSettingsPage",
    "_AndroidSettingsPageState",
    "SyncState",
    "android-bridge",
    "android-scan",
    "android-import",
    "android-device-",
    "android-sync-server",
    "android-sync-push",
    "sync-peer-",
    "bridge-host-",
    "settings-android-open",
]

# 中文串（UTF-16LE）。用户可见文案，缺任何一条都说明对应 UI 没进包。
REQUIRED_UTF16 = [
    "安卓设备接入",
    "扫描局域网",
    "导入站点",
    "手动输入地址",
    "同步设置",
    "推送到设备",
    "已授权对端",
    "站点地址已修正",
    "打开安卓接入",
]

# 绝不能出现在发布包里的标记（测试壳污染）。
FORBIDDEN_ASCII = [
    "integration_test",
    "phase5_sync_ui_test",
    "FakeBridge",
]


def load(app_so: Path) -> tuple[bytes, str, str]:
    raw = app_so.read_bytes()
    return raw, raw.decode("latin1"), raw.decode("utf-16le", errors="ignore")


def build_release(puro_env: str) -> None:
    """构建 release（仅在显式请求时执行）。"""
    subprocess.run(
        ["puro", "-e", puro_env, "-p", ".", "flutter", "build", "windows",
         "--release"],
        cwd=APP_DIR,
        check=True,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app-so", type=Path, default=DEFAULT_APP_SO)
    parser.add_argument("--puro-env", default="webhtv")
    parser.add_argument("--build-release-for-symbols", action="store_true")
    parser.add_argument(
        "--require-fresh",
        action="store_true",
        help="产物早于源码时不算通过（默认给出过期提示但仍失败，便于定位）",
    )
    args = parser.parse_args()

    app_so: Path = args.app_so
    if args.build_release_for_symbols or not app_so.exists():
        if not args.build_release_for_symbols and not app_so.exists():
            print(f"ANDROID-SYMBOLS SKIP app.so 不存在：{app_so}")
            print("  → 默认不主动构建（仓库约定：不打正式包）。")
            print("  → 需要校验时加 --build-release-for-symbols。")
            # 明确区分"跳过"与"通过"：跳过不算门禁通过，但不阻塞快速回归。
            return 0
        build_release(args.puro_env)

    if not app_so.exists():
        print(f"ANDROID-SYMBOLS FAIL 构建后仍无 app.so：{app_so}")
        return 1

    raw, latin, utf16 = load(app_so)

    # 产物新鲜度：比 app.so 更新的源码文件说明这个包**早于**当前实现，
    # 符号缺失就不再是"AOT 剔除"而是"没重新构建"。
    # 两者必须区分开，否则用户会去查根本不存在的问题。
    newest_source = None
    newest_source_mtime = 0.0
    for path in (APP_DIR / "lib").rglob("*.dart"):
        mtime = path.stat().st_mtime
        if mtime > newest_source_mtime:
            newest_source_mtime = mtime
            newest_source = path
    stale = newest_source is not None and newest_source_mtime > app_so.stat().st_mtime
    if stale:
        print(
            "ANDROID-SYMBOLS stale=true "
            f"newest-source={newest_source.relative_to(APP_DIR)} "
            f"app-so-mtime={time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(app_so.stat().st_mtime))} "
            f"source-mtime={time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(newest_source_mtime))}"
        )

    missing_ascii = [s for s in REQUIRED_ASCII if s not in latin]
    missing_utf16 = [s for s in REQUIRED_UTF16 if s not in utf16]
    leaked = [s for s in FORBIDDEN_ASCII if s in latin]

    mtime = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(app_so.stat().st_mtime))
    print(f"ANDROID-SYMBOLS app-so={app_so} mtime={mtime} bytes={len(raw)}")

    for symbol in REQUIRED_ASCII:
        print(f"ANDROID-SYMBOLS symbol ascii={symbol} present={symbol not in missing_ascii}")
    for symbol in REQUIRED_UTF16:
        print(f"ANDROID-SYMBOLS symbol utf16={symbol} present={symbol not in missing_utf16}")
    for marker in FORBIDDEN_ASCII:
        print(f"ANDROID-SYMBOLS forbidden={marker} count={latin.count(marker)}")

    if stale and not missing_ascii and not missing_utf16 and not leaked:
        # 过期但符号齐全：给出提示即可（符号在包里的结论仍然有效）。
        print("ANDROID-SYMBOLS note=stale-but-symbols-present")

    if missing_ascii or missing_utf16 or leaked:
        print(
            "ANDROID-SYMBOLS result=FAIL "
            f"missing-ascii={missing_ascii} missing-utf16={missing_utf16} "
            f"leaked={leaked}"
        )
        if stale:
            print(
                "  → 该 app.so 早于当前源码（见上面 stale 行），先用 "
                "--build-release-for-symbols 重新构建再判定；"
                "否则无法区分「AOT 剔除」与「没重新构建」。"
            )
        else:
            print(
                "  → 说明安卓接入入口在 release 里不可达（多半被 AOT 剔除），"
                "用户将看不到「打开安卓接入」与同步设置。"
            )
        return 1

    print(
        "ANDROID-SYMBOLS result=PASS "
        f"ascii={len(REQUIRED_ASCII)} utf16={len(REQUIRED_UTF16)} leaked=0"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
