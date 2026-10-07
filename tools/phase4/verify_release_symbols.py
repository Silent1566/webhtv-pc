#!/usr/bin/env python
"""发布包 TMDB 符号可达性门禁（打包期）。

为什么需要这个门禁
------------------
`flutter test` 走 JIT/debug，不做 tree-shaking；集成测试更是直接写 `settings.json`
绕过 UI 入口。因此**只有 release AOT 产物**能暴露「入口不可达 → 死代码被剔除」这类缺陷。

真实事故（2026-10-07 发布包实测）：`TmdbState.shouldRender` 对「未配置」返回
`false`，`TmdbStatusBar` 直接 `SizedBox.shrink()`，而全应用唯一引用
`TmdbSettingsPage` 的就是状态条上那个从未渲染的 `onConfigure` 回调。结果
`TmdbSettingsPage` / `tmdb-api-key` / 「TMDB 设置」被 AOT 整体剔除，正式版 exe
里既没有 TMDB 设置，也没有任何 TMDB 效果——而当时所有门禁全绿。

判定方法（与 Flutter 的 AOT 字符串布局一致）
-------------------------------------------
- ASCII 符号以 latin1 存储 → 用 latin1 解码后 `in` 判定；
- 中文串以 UTF-16LE 存储 → 用 utf16le 解码后 `in` 判定。

用法：
    py -3 tools/phase4/verify_release_symbols.py
    py -3 tools/phase4/verify_release_symbols.py --app-so <path>
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

DEFAULT_APP_SO = (
    REPO_ROOT / "apps" / "desktop-flutter" / "build" / "windows" / "x64" /
    "runner" / "Release" / "data" / "app.so"
)

# 必须在 release AOT 产物中可达的 TMDB 符号。
# ASCII 符号（类名 / ValueKey）。
REQUIRED_ASCII = [
    "TmdbSettingsPage",
    "_TmdbSettingsPageState",
    "TmdbStatusBar",
    "TmdbDetailPage",
    "tmdb-api-key",
    "tmdb-enabled",
    "tmdb-save",
    "tmdb-test",
    "tmdb-status-unconfigured",
    "tmdb-configure",
    "settings-tmdb-open",
]

# 中文串（UTF-16LE）。
REQUIRED_UTF16 = [
    "TMDB 设置",
    "启用 TMDB 增强",
    "去设置",
    "打开 TMDB 设置",
]

# 绝不能出现在发布包里的标记（测试壳污染）。
FORBIDDEN_ASCII = [
    "integration_test",
]


def load(app_so: Path) -> tuple[bytes, str, str]:
    raw = app_so.read_bytes()
    return raw, raw.decode("latin1"), raw.decode("utf-16le", errors="ignore")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app-so", type=Path, default=DEFAULT_APP_SO)
    args = parser.parse_args()

    app_so: Path = args.app_so
    if not app_so.exists():
        print(f"TMDB-SYMBOLS FAIL app.so 不存在：{app_so}")
        print("  → 先执行 flutter build windows --release")
        return 1

    raw, latin, utf16 = load(app_so)

    missing_ascii = [s for s in REQUIRED_ASCII if s not in latin]
    missing_utf16 = [s for s in REQUIRED_UTF16 if s not in utf16]
    leaked = [s for s in FORBIDDEN_ASCII if s in latin]

    import time

    mtime = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(app_so.stat().st_mtime))
    print(f"TMDB-SYMBOLS app-so={app_so} mtime={mtime} bytes={len(raw)}")

    for symbol in REQUIRED_ASCII:
        print(f"TMDB-SYMBOLS symbol ascii={symbol} present={symbol not in missing_ascii}")
    for symbol in REQUIRED_UTF16:
        print(f"TMDB-SYMBOLS symbol utf16={symbol} present={symbol not in missing_utf16}")
    for marker in FORBIDDEN_ASCII:
        count = latin.count(marker)
        print(f"TMDB-SYMBOLS forbidden={marker} count={count}")

    if missing_ascii or missing_utf16 or leaked:
        print(
            "TMDB-SYMBOLS result=FAIL "
            f"missing-ascii={missing_ascii} missing-utf16={missing_utf16} leaked={leaked}"
        )
        print(
            "  → 说明 TMDB 入口在 release 里不可达（多半被 AOT 剔除），"
            "用户将看不到 TMDB 设置或效果。"
        )
        return 1

    print(
        "TMDB-SYMBOLS result=PASS "
        f"ascii={len(REQUIRED_ASCII)} utf16={len(REQUIRED_UTF16)} leaked=0"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
