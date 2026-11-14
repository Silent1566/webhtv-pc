#!/usr/bin/env python3
"""Phase 8 平坦场门禁（G9）：本轮新增/修改的 UI 文件不得有盒子阴影或非 0 elevation。

为什么需要：浮层天然诱使人加 `BoxShadow` 来「浮起来」，而 `DESIGN.md` 的
The Flat-Field Rule 明确禁止——星等星表是一片平坦的场，阴影堆叠会破坏它。
机器扫描是唯一能防住「顺手加个阴影」的手段。

**文字描边不算违规**：屏显的纯白字在亮画面上不可读，上游
（`view_player_osd.xml:26-29`）用文字阴影做描边，PC 端同样需要。
所以 `Shadow(` 只在 `shadows:` 列表内部才放行，`BoxShadow` 一律违规。

退出码：0 = 通过；1 = 存在违规。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UI_ROOT = ROOT / "apps" / "desktop-flutter" / "lib" / "ui"

# 本轮新增/修改的文件。
TARGETS = [
    "player_page.dart",
    "player_overlay.dart",
    "player_osd.dart",
    "player_context_menu.dart",
    "player_button_config_page.dart",
]

BOX_SHADOW_PATTERN = re.compile(r"\bBoxShadow\b")
TEXT_SHADOW_PATTERN = re.compile(r"\bShadow\s*\(")
# `elevation: 6` / `elevation: 6.0` / `scrolledUnderElevation: 3`
ELEVATION_PATTERN = re.compile(
    r"\b(elevation|scrolledUnderElevation)\s*:\s*([0-9]+(?:\.[0-9]+)?)\b"
)


def strip_line_comment(line: str) -> str:
    """去掉行尾 `//` 注释，避免注释里的 `elevation: 6` 被误判。

    只处理最简单的形态：`//` 之前没有引号。本仓库这几份文件里
    没有把 `//` 写进字符串的情况。
    """
    index = line.find("//")
    if index == -1:
        return line
    return line[:index]


def text_shadow_regions(lines: list[str]) -> list[tuple[int, int]]:
    """找出所有 `shadows` 列表的括号区间（行号，1 起，闭区间）。

    文字描边必须写在 `TextStyle(shadows: [...])` 里，因此落在这些区间内的
    `Shadow(` 是合法的；落在区间外的一律按违规报出。

    触发词是裸的 `shadows` 标识符，**不只是 `shadows:`**——
    `player_page.dart:223` 是个 `List<Shadow> get shadows { ... }` 取值器，
    只认冒号形态会漏掉它，把合法的文字描边误报成盒子阴影（实测踩到过）。
    """
    regions: list[tuple[int, int]] = []
    depth = 0
    start: int | None = None
    for lineno, raw in enumerate(lines, start=1):
        line = strip_line_comment(raw)
        if start is None and re.search(r"\bshadows\b", line):
            start = lineno
            depth = 0
        if start is not None:
            depth += line.count("[") + line.count("(") + line.count("{")
            depth -= line.count("]") + line.count(")") + line.count("}")
            if depth <= 0:
                regions.append((start, lineno))
                start = None
    if start is not None:
        regions.append((start, len(lines)))
    return regions


def in_regions(lineno: int, regions: list[tuple[int, int]]) -> bool:
    return any(low <= lineno <= high for low, high in regions)


def main() -> int:
    failures: list[str] = []
    for name in TARGETS:
        path = UI_ROOT / name
        if not path.exists():
            failures.append(f"{name}: 文件不存在")
            continue
        lines = path.read_text(encoding="utf-8").splitlines()
        regions = text_shadow_regions(lines)
        for lineno, raw in enumerate(lines, start=1):
            stripped = raw.strip()
            if stripped.startswith("//"):
                continue
            code = strip_line_comment(raw)
            if BOX_SHADOW_PATTERN.search(code):
                failures.append(f"{name}:{lineno}: 出现盒子阴影 → {stripped}")
            elif TEXT_SHADOW_PATTERN.search(code) and not in_regions(lineno, regions):
                failures.append(
                    f"{name}:{lineno}: `Shadow(` 不在 `shadows:` 列表内"
                    f"（文字描边是允许项，盒子阴影不是）→ {stripped}"
                )
            match = ELEVATION_PATTERN.search(code)
            if match and float(match.group(2)) != 0:
                failures.append(
                    f"{name}:{lineno}: 非 0 {match.group(1)} → {stripped}"
                )
    if failures:
        print("PHASE8-FLAT-FIELD result=FAIL")
        for item in failures:
            print(f"  - {item}")
        return 1
    print(f"PHASE8-FLAT-FIELD result=PASS files={len(TARGETS)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
