#!/usr/bin/env python3
"""Phase 8 截图证据门禁（G8）：13 张截图必须存在、非空、且与清单逐字节一致。

为什么需要这层校验：截图是**证据**，不是断言。如果同一份代码每次跑出
不同字节的 PNG，那么「与上次截图不同」就无法说明任何事——无法区分
「代码改了」与「只是走时/滚动条状态不同」。实测踩到过两次：

1. 屏显右上角是**实时时钟**，每秒重绘。差异包围盒只有约 34×10 像素
   （`player-controls-r16x10.png` 是 `(1390, 21, 1424, 31)`），其余像素
   逐字节相同 → 修法是 `debugOsdClockOverride` 冻结时钟。
2. 菜单滚到底后**滚动条要淡出**，`jumpTo` 挂的是 300ms 的 Timer，
   而 `pumpAndSettle` 只等「有没有排队的帧」→ 它立刻返回，
   把半透明滚动条拍进图里。差异是菜单右缘一条 9px 宽的竖条
   （r16x10 是 `(949, 232, 958, 892)`，4664~5924 像素）。

修好之后连续两次跑 13/13 逐字节相同；本脚本把这件事变成机器检查，
以后任何一次「截图悄悄变得不可复现」都会红。

退出码：0 = 通过；1 = 缺失/过小/与清单不一致。
"""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SHOTS = ROOT / "docs" / "phase8" / "evidence" / "screenshots"
MANIFEST = SHOTS / "manifest.txt"

REQUIRED = [
    "player-controls-r16x10.png",
    "player-menu-r16x10.png",
    "player-menu-bottom-r16x10.png",
    "player-osd-r16x10.png",
    "player-controls-r2x1.png",
    "player-menu-r2x1.png",
    "player-menu-bottom-r2x1.png",
    "player-osd-r2x1.png",
    "player-controls-r235x1.png",
    "player-menu-r235x1.png",
    "player-menu-bottom-r235x1.png",
    "player-osd-r235x1.png",
    "player-narrow-1024x640.png",
]

# 小于这个字节数说明截图是空的或几乎全同色。
MIN_BYTES = 1000


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_manifest() -> dict[str, str]:
    entries: dict[str, str] = {}
    for line in MANIFEST.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) == 2:
            entries[parts[1]] = parts[0].lower()
    return entries


def main() -> int:
    if "--write-manifest" in sys.argv:
        lines = [
            "# Phase 8 截图证据清单（G8 用）",
            "#",
            "# 由 tools/phase8/verify_screenshots.py 逐字节校验。",
            "# 为什么需要：屏显右上角是实时时钟、菜单滚动条会淡出，两者都曾让",
            "# 同一份代码跑出不同字节的 PNG（实测）。清单把「截图可复现」变成机器检查。",
            "# 重新生成：py -3 tools/phase8/verify_screenshots.py --write-manifest",
            "",
        ]
        for name in REQUIRED:
            path = SHOTS / name
            if not path.exists():
                print(f"PHASE8-SCREENSHOTS result=FAIL 缺少 {name}")
                return 1
            lines.append(f"{digest(path)}  {name}")
        MANIFEST.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"PHASE8-SCREENSHOTS result=MANIFEST-WRITTEN count={len(REQUIRED)}")
        return 0

    failures: list[str] = []
    for name in REQUIRED:
        path = SHOTS / name
        if not path.exists():
            failures.append(f"缺少截图 {name}")
        elif path.stat().st_size < MIN_BYTES:
            failures.append(f"{name} 过小（{path.stat().st_size} 字节）")

    if not MANIFEST.exists():
        failures.append(
            "缺少 manifest.txt（用 `--write-manifest` 生成并提交）"
        )
    elif not failures:
        manifest = read_manifest()
        for name in REQUIRED:
            expected = manifest.get(name)
            if expected is None:
                failures.append(f"manifest.txt 未登记 {name}")
                continue
            actual = digest(SHOTS / name)
            if actual != expected:
                failures.append(
                    f"{name} 与清单不一致（截图不可复现或已过期）"
                    f"\n      清单 {expected[:16]}…  实际 {actual[:16]}…"
                )

    if failures:
        print("PHASE8-SCREENSHOTS result=FAIL")
        for item in failures:
            print(f"  - {item}")
        return 1
    print(f"PHASE8-SCREENSHOTS result=PASS count={len(REQUIRED)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
