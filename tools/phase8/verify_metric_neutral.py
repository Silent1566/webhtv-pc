#!/usr/bin/env python3
"""Phase 8 度量中性门禁（G10）：`theme.dart` 的 `_textTheme` 必须逐字不变。

为什么需要：屏显需要 14px 字号，最省事的做法是改 `textTheme`——
但那会移动所有页面里不带 `ensureVisible` 的 `tap`。
`DESIGN.md` 的 The Metric-Neutral Rule 记录了实测：
`bodySmall` 行高 1.33→1.65 会让 `phase5_sync_ui_test.dart` 挂 3 个用例。

做法：比对 `_textTheme` 函数的**规范化文本**与基线快照
（`tools/phase8/text_theme_baseline.txt`）。

**基线缺失 = 失败**，不是「自动创建后通过」：自动创建会让门禁在第一次
运行时无条件变绿，而那时恰恰最需要它。基线是**入库产物**，由
`--write-baseline` 显式生成，生成动作必须出现在提交里。

退出码：0 = 通过；1 = 有变化或基线缺失。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
THEME = ROOT / "apps" / "desktop-flutter" / "lib" / "ui" / "theme.dart"
BASELINE = Path(__file__).resolve().parent / "text_theme_baseline.txt"

FUNCTION_PATTERN = re.compile(
    r"TextTheme\s+_textTheme\([^)]*\)\s*\{(.*?)\n\}",
    re.DOTALL,
)


def extract() -> str:
    text = THEME.read_text(encoding="utf-8")
    match = FUNCTION_PATTERN.search(text)
    if not match:
        raise SystemExit("无法在 theme.dart 里定位 _textTheme 函数")
    body = match.group(1)
    # 规范化：去掉空行与行尾空白，保留语义内容。
    lines = [line.rstrip() for line in body.splitlines() if line.strip()]
    return "\n".join(lines)


def main() -> int:
    current = extract()
    if "--write-baseline" in sys.argv:
        BASELINE.write_text(current, encoding="utf-8")
        print(f"PHASE8-METRIC-NEUTRAL result=BASELINE-WRITTEN path={BASELINE}")
        return 0
    if not BASELINE.exists():
        print("PHASE8-METRIC-NEUTRAL result=FAIL")
        print(f"  基线缺失：{BASELINE}")
        print("  用 `py -3 tools/phase8/verify_metric_neutral.py --write-baseline` 生成，")
        print("  并把生成结果一并提交（不要让它成为运行时副作用）。")
        return 1
    baseline = BASELINE.read_text(encoding="utf-8")
    if current != baseline:
        print("PHASE8-METRIC-NEUTRAL result=FAIL")
        print("  _textTheme 已改变。DESIGN.md 的 The Metric-Neutral Rule 禁止改字号与行高。")
        print("  需要新字号时，就地显式指定（不要改 textTheme）。")
        current_lines = current.splitlines()
        baseline_lines = baseline.splitlines()
        for index in range(max(len(current_lines), len(baseline_lines))):
            was = baseline_lines[index] if index < len(baseline_lines) else "<缺失>"
            now = current_lines[index] if index < len(current_lines) else "<缺失>"
            if was != now:
                print(f"  第 {index + 1} 行：")
                print(f"    基线：{was}")
                print(f"    现在：{now}")
        return 1
    print("PHASE8-METRIC-NEUTRAL result=PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
