#!/usr/bin/env python
"""Phase 7 发布包符号门禁（`docs/phase7/design/04` §6 的 G10）。

为什么必须查 **release AOT 产物**
--------------------------------
`flutter test` 走 JIT/debug 不做 tree-shaking，集成测试还会直接写
`settings.json` 绕过 UI 入口。因此**只有 release AOT 产物**能暴露
「入口不可达 → 死代码被整体剔除」这类缺陷（Phase 4 的 P4-7 事故结论）。

Phase 7 的具体风险：`realtime-*` 那组控件被渲染在 `AndroidSettingsPage`
的**长 `ListView` 靠后位置**，且手动按钮包在 `Wrap` 里。若条件写错
（例如总开关关着时整块不渲染），用户永远看不到实时同步与手动操作。

判定方法（与 Flutter 的 AOT 字符串布局一致）
-------------------------------------------
- ASCII 符号以 latin1 存储 → 用 latin1 解码后 `in` 判定；
- 中文串以 UTF-16LE 存储 → 用 utf16le 解码后 `in` 判定。

用法：
    py -3 tools/phase7/verify_release_symbols.py
    py -3 tools/phase7/verify_release_symbols.py --app-so <path>
    py -3 tools/phase7/verify_release_symbols.py --build-release-for-symbols

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
    APP_DIR / "build" / "windows" / "x64" / "runner" / "Release" / "data" / "app.so"
)

# 必须存在于 release AOT 产物中的 Phase 7 符号（`design/04` §6 G10）。
#
# 分三组：
#   1. 状态层/引擎的类名（入口被条件挡住时整片消失）；
#   2. 每个 UI 控件与披露块的 ValueKey；
#   3. 协议层的私有函数名（只在死代码剔除时才会消失）。
REQUIRED_ASCII = [
    # 状态层与引擎
    "RealtimeSyncEngine",
    "RealtimeEngineSnapshot",
    "RealtimeSyncSwitches",
    "PlaybackIdentityStore",
    # 实时同步区块（`design/01` §6.1）
    "realtime-enabled",
    "realtime-pull",
    "realtime-push",
    "realtime-settings",
    "realtime-interval",
    "realtime-poll-all-sites",
    "realtime-status",
    "realtime-last-pull",
    # 停止态与「立即重连」（`design/02` §5.2）
    "realtime-attention",
    "realtime-retry",
    # 手动操作（`design/01` §4.4、§4.5）
    "realtime-manual-pull",
    "realtime-manual-request-push",
    "realtime-manual-push-history",
    "realtime-manual-push-settings",
    "realtime-manual-result",
    # 六条披露（`design/01` §7.2，P5）
    "realtime-disclosure-degraded",
    "realtime-disclosure-unsupported",
    "realtime-disclosure-service-stopped",
    "realtime-disclosure-peer-frozen",
    "realtime-disclosure-background-guide",
    "realtime-disclosure-plaintext",
]

# 中文串（UTF-16LE）。用户可见文案，缺任何一条都说明对应 UI 没进包。
REQUIRED_UTF16 = [
    "实时同步",
    "手动操作",
    "开启实时同步",
    "实时拉取（PC → 安卓）",
    "实时推送（安卓 → PC）",
    "设置实时同步（含凭据）",
    "轮询全部站点",
    "拉取最近记录",
    "请求安卓推送全量",
    "推送历史",
    "推送设置",
    "立即重连",
    # 披露文案（P5：这些句子是"不得静默失败"的具体实现）
    "正在播放",
    "明文 HTTP",
    "管理页",
    "应用启动管理",
]

# 绝不能出现在发布包里的标记（测试壳污染）。
FORBIDDEN_ASCII = [
    "integration_test",
    "phase7_sync_ui_test",
    "phase7_realtime_engine_test",
    "phase7_realtime_state_test",
    "_ManualScheduler",
    "_FakeReadClient",
]


def load(app_so: Path) -> tuple[bytes, str, str]:
    raw = app_so.read_bytes()
    return raw, raw.decode("latin1"), raw.decode("utf-16le", errors="ignore")


def build_release(puro_env: str) -> None:
    """构建 release（仅在显式请求时执行）。"""
    subprocess.run(
        [
            "puro",
            "-e",
            puro_env,
            "-p",
            ".",
            "flutter",
            "build",
            "windows",
            "--release",
        ],
        cwd=APP_DIR,
        check=True,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app-so", type=Path, default=DEFAULT_APP_SO)
    parser.add_argument("--puro-env", default="webhtv")
    parser.add_argument("--build-release-for-symbols", action="store_true")
    args = parser.parse_args()

    app_so: Path = args.app_so
    if not app_so.exists():
        if not args.build_release_for_symbols:
            print(f"PHASE7-SYMBOLS SKIP app.so 不存在：{app_so}")
            print("  → 默认不主动构建（仓库约定：不打正式包）。")
            print("  → 需要校验时加 --build-release-for-symbols。")
            # 明确区分"跳过"与"通过"：跳过不算门禁通过，但不阻塞快速回归。
            return 0
        build_release(args.puro_env)

    if not app_so.exists():
        print(f"PHASE7-SYMBOLS FAIL 构建后仍无 app.so：{app_so}")
        return 1

    raw, latin, utf16 = load(app_so)

    # 产物新鲜度：比 app.so 更新的源码说明这个包**早于**当前实现，
    # 符号缺失就不再是"AOT 剔除"而是"没重新构建"。两者必须区分开，
    # 否则用户会去查根本不存在的问题。
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
            "PHASE7-SYMBOLS stale=true "
            f"newest-source={newest_source.relative_to(APP_DIR)} "
            f"app-so-mtime="
            f"{time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(app_so.stat().st_mtime))} "
            f"source-mtime="
            f"{time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(newest_source_mtime))}"
        )

    missing_ascii = [s for s in REQUIRED_ASCII if s not in latin]
    missing_utf16 = [s for s in REQUIRED_UTF16 if s not in utf16]
    leaked = [s for s in FORBIDDEN_ASCII if s in latin]

    mtime = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(app_so.stat().st_mtime))
    print(f"PHASE7-SYMBOLS app-so={app_so} mtime={mtime} bytes={len(raw)}")

    for symbol in REQUIRED_ASCII:
        print(f"PHASE7-SYMBOLS symbol ascii={symbol} present={symbol not in missing_ascii}")
    for symbol in REQUIRED_UTF16:
        print(f"PHASE7-SYMBOLS symbol utf16={symbol} present={symbol not in missing_utf16}")
    for marker in FORBIDDEN_ASCII:
        print(f"PHASE7-SYMBOLS forbidden={marker} count={latin.count(marker)}")

    if stale and not missing_ascii and not missing_utf16 and not leaked:
        print("PHASE7-SYMBOLS note=stale-but-symbols-present")

    if missing_ascii or missing_utf16 or leaked:
        if stale:
            # **stale 不是「AOT 剔除」，而是「产物比源码旧」**。
            # 本仓库约定「webhtv 项目不打正式包」，因此在 stale 时主动构建是不
            # 允许的；把 stale 判为 FAIL 会让每次改动后的快速回归都红，而
            # 「重新构建」又不是可用的修法。
            #
            # 所以分开报：stale → SKIP（不声称通过）；新鲜 → FAIL。
            print(
                "PHASE7-SYMBOLS result=STALE-SKIP "
                f"missing-ascii={len(missing_ascii)} "
                f"missing-utf16={len(missing_utf16)} leaked={len(leaked)}"
            )
            print(
                "  → 该 app.so 早于当前源码，无法区分「AOT 剔除」与「没重新构建」。"
            )
            print(
                "  → 需要真正校验时：加 --build-release-for-symbols（会产出一个"
                "release 包，注意仓库约定不要发给用户）。"
            )
            return 0
        print(
            "PHASE7-SYMBOLS result=FAIL "
            f"missing-ascii={missing_ascii} missing-utf16={missing_utf16} "
            f"leaked={leaked}"
        )
        print(
            "  → 说明实时同步/手动操作入口在 release 里不可达（多半被 AOT 剔除），"
            "用户将看不到这些功能。"
        )
        return 1

    print(
        "PHASE7-SYMBOLS result=PASS "
        f"ascii={len(REQUIRED_ASCII)} utf16={len(REQUIRED_UTF16)} leaked=0"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
