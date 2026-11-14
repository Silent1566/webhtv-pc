#!/usr/bin/env python3
"""Phase 9 差距矩阵门禁（G9.1–G9.5）。

校验项（对应 `docs/phase9/README.md` §8）：

- G9.1 矩阵完整性：每行 6 列且非空；ID 唯一；ID 前缀与所在小节的档位一致；
  每个 P 行至少一条 `android/...` 引用。
- G9.2 安卓引用可追溯：所有 `android/<相对路径>` 在 `--android-root` 下存在；
  仓库缺失时记录 HEAD 并**以退出码 2 结束**（不静默通过）。
- G9.3 覆盖完整性：安卓的 manifest 屏幕、对话框、设置 Fragment、顶层模块
  每个名字至少出现在 `design/05-upstream-map.md` 一次。
- G9.4 PC 引用可追溯：`apps/desktop-flutter/...` 路径存在；尚未落地的模块
  必须写 `PLANNED ` 前缀并在此登记（脚本只做形状校验，不做「应该存在」的断言）。
- G9.5 不迁移项披露：每个 N 行都有「理由 + 对外披露文案」。

退出码：0 = 全绿；1 = 有失败；2 = 安卓仓库缺失（G9.2/G9.3 跳过）。

用法：
    py -3 tools/phase9/verify_gap_matrix.py
    py -3 tools/phase9/verify_gap_matrix.py --android-root F:/Workspace/webtv2/webhtv
    py -3 tools/phase9/verify_gap_matrix.py --allow-missing-android
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
README = ROOT / "docs" / "phase9" / "README.md"
MAP_DOC = ROOT / "docs" / "phase9" / "design" / "05-upstream-map.md"
APP_DIR = ROOT / "apps" / "desktop-flutter"

DEFAULT_ANDROID_ROOT = Path("F:/Workspace/webtv2/webhtv")

PRIORITY_HEADING = re.compile(r"^###\s+4\.(\d)\s+(P[0-3])\b")
NOT_MIGRATE_HEADING = re.compile(r"^##\s+5\.\s*明确不迁移")

ANDROID_REF = re.compile(r"android/([A-Za-z0-9_./\-]+)")
PC_REF = re.compile(r"(?<!PLANNED )apps/desktop-flutter/([A-Za-z0-9_./\-]+)")
PLANNED_REF = re.compile(r"PLANNED apps/desktop-flutter/([A-Za-z0-9_./\-]+)")
DOC_REF = re.compile(r"((?:docs|tools|sidecars|packages)/[A-Za-z0-9_./\-]+)")

ROW_ID = re.compile(r"^P([0-3])-(\d+)$")
N_ID = re.compile(r"^N\d+$")

MAX_PRINT = 25


class Report:
    def __init__(self) -> None:
        self.failures: list[str] = []
        self.notes: list[str] = []

    def check(self, gate: str, ok: bool, detail: str = "") -> None:
        status = "PASS" if ok else "FAIL"
        print(f"[{status}] {gate}" + (f" · {detail}" if detail else ""))
        if not ok:
            self.failures.append(f"{gate}: {detail}")

    def note(self, text: str) -> None:
        self.notes.append(text)
        print(f"[NOTE] {text}")


def split_row(line: str) -> list[str]:
    """把 markdown 表格行拆成单元格（去掉首尾竖线）。"""
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


def is_separator(cells: list[str]) -> bool:
    return bool(cells) and all(re.fullmatch(r":?-{2,}:?", cell) for cell in cells)


def parse_matrix(report: Report) -> tuple[list[dict], list[dict]]:
    """解析 README 的 P 矩阵与 N 表。"""
    if not README.exists():
        report.check("G9.1", False, f"缺少 {README.relative_to(ROOT)}")
        return [], []

    lines = README.read_text(encoding="utf-8").splitlines()
    rows: list[dict] = []
    n_rows: list[dict] = []
    current_priority: str | None = None
    current_section: str | None = None

    for line in lines:
        heading_match = PRIORITY_HEADING.match(line)
        if heading_match:
            current_priority = heading_match.group(2)
            current_section = "matrix"
            continue
        if NOT_MIGRATE_HEADING.match(line):
            current_priority = None
            current_section = "not-migrate"
            continue
        if line.startswith("## ") or line.startswith("### "):
            if not PRIORITY_HEADING.match(line):
                current_section = None
            continue

        if not line.startswith("|"):
            continue
        cells = split_row(line)
        if is_separator(cells):
            continue
        if not cells or not cells[0]:
            continue

        if current_section == "matrix":
            if not cells[0].startswith("P"):
                continue
            rows.append({"priority": current_priority, "cells": cells, "raw": line})
        elif current_section == "not-migrate":
            if not cells[0].startswith("N"):
                continue
            n_rows.append({"cells": cells, "raw": line})

    return rows, n_rows


def gate_g91(report: Report, rows: list[dict]) -> None:
    if not rows:
        report.check("G9.1", False, "矩阵为空（未解析到任何 P 行）")
        return

    problems: list[str] = []
    seen: dict[str, int] = {}
    for row in rows:
        cells = row["cells"]
        rid = cells[0]
        if len(cells) != 6:
            problems.append(f"{rid}: 列数 {len(cells)} != 6")
            continue
        if any(not cell for cell in cells):
            problems.append(f"{rid}: 存在空单元格")
        match = ROW_ID.match(rid)
        if not match:
            problems.append(f"{rid}: ID 形状非法")
            continue
        prefix = f"P{match.group(1)}"
        if row["priority"] and prefix != row["priority"]:
            problems.append(f"{rid}: 前缀与档位 {row['priority']} 不一致")
        if rid in seen:
            problems.append(f"{rid}: ID 重复")
        seen[rid] = seen.get(rid, 0) + 1
        if not ANDROID_REF.search(" ".join(cells)):
            problems.append(f"{rid}: 缺少 android/ 引用")

    for text in problems[:MAX_PRINT]:
        print(f"        {text}")
    if len(problems) > MAX_PRINT:
        print(f"        … 另有 {len(problems) - MAX_PRINT} 条")
    report.check(
        "G9.1",
        not problems,
        f"{len(rows)} 行，{len(seen)} 个唯一 ID" if not problems else f"{len(problems)} 个问题",
    )


def gate_g92(report: Report, rows: list[dict], android_root: Path | None) -> bool:
    """返回安卓仓库是否可用。"""
    if android_root is None or not android_root.exists():
        report.note(f"安卓仓库不存在：{android_root} —— G9.2/G9.3 跳过")
        return False

    commit = "unknown"
    try:
        commit = subprocess.run(
            ["git", "-C", str(android_root), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            timeout=10,
        ).stdout.strip() or "unknown"
    except Exception:  # noqa: BLE001 - 只用于记录
        pass
    report.note(f"安卓基准：{android_root} @ {commit[:12]}")

    missing: list[str] = []
    checked = 0
    for row in rows:
        rid = row["cells"][0]
        refs = set()
        for cell in row["cells"]:
            refs.update(ANDROID_REF.findall(cell))
        if not refs:
            missing.append(f"{rid}: 无 android/ 引用")
            continue
        for ref in sorted(refs):
            checked += 1
            if not (android_root / ref).exists():
                missing.append(f"{rid}: android/{ref}")
    for text in missing[:MAX_PRINT]:
        print(f"        {text}")
    if len(missing) > MAX_PRINT:
        print(f"        … 另有 {len(missing) - MAX_PRINT} 条")
    report.check("G9.2", not missing, f"{checked} 条引用" if not missing else f"{len(missing)} 条不存在")
    return True


def inventory(android_root: Path) -> dict[str, set[str]]:
    acts: set[str] = set()
    for manifest in android_root.glob("app/src/**/AndroidManifest.xml"):
        text = manifest.read_text(encoding="utf-8", errors="replace")
        for name in re.findall(r'<activity[^>]*android:name="([^"]+)"', text):
            acts.add(name.rsplit(".", 1)[-1])

    dialogs = {
        path.stem
        for path in (android_root / "app/src/main/java/com/fongmi/android/tv/ui/dialog").glob("*.java")
    }
    frags = {
        path.stem
        for path in android_root.glob("app/src/*/java/**/ui/fragment/Setting*Fragment.java")
    }
    tv_root = android_root / "app/src/main/java/com/fongmi/android/tv"
    modules = {path.name for path in tv_root.iterdir() if path.is_dir()} if tv_root.exists() else set()
    return {"activities": acts, "dialogs": dialogs, "fragments": frags, "modules": modules}


def gate_g93(report: Report, android_root: Path | None) -> None:
    if android_root is None or not android_root.exists():
        report.note("G9.3 跳过（安卓仓库缺失）")
        return
    if not MAP_DOC.exists():
        report.check("G9.3", False, f"缺少 {MAP_DOC.relative_to(ROOT)}")
        return

    map_text = MAP_DOC.read_text(encoding="utf-8")
    inv = inventory(android_root)
    problems: list[str] = []
    summary: list[str] = []
    for kind, names in inv.items():
        unmapped = sorted(name for name in names if name and name not in map_text)
        summary.append(f"{kind}={len(names)} 未映射={len(unmapped)}")
        problems.extend(f"{kind}: {name}" for name in unmapped)
    for text in problems[:MAX_PRINT]:
        print(f"        {text}")
    if len(problems) > MAX_PRINT:
        print(f"        … 另有 {len(problems) - MAX_PRINT} 条")
    report.check("G9.3", not problems, "，".join(summary) if not problems else f"{len(problems)} 个未映射")


def gate_g94(report: Report, rows: list[dict]) -> None:
    missing: list[str] = []
    planned: set[str] = set()
    checked = 0
    for row in rows:
        rid = row["cells"][0]
        for cell in row["cells"]:
            for ref in PLANNED_REF.findall(cell):
                planned.add(ref)
                is_file = ref.endswith(".dart") and ref.startswith("lib/")
                is_dir = ref.endswith("/") and ref.startswith("lib/")
                if not (is_file or is_dir):
                    missing.append(f"{rid}: PLANNED 形状非法 apps/desktop-flutter/{ref}")
            for ref in PC_REF.findall(cell):
                checked += 1
                if not (APP_DIR / ref).exists():
                    missing.append(f"{rid}: apps/desktop-flutter/{ref}")

    # README 全文里的完整 PC 路径（含「已对齐」表）都必须存在；
    # `PLANNED ` 前缀的引用由上一步单独登记，不在此列。
    readme_text = README.read_text(encoding="utf-8")
    for ref in sorted(set(PC_REF.findall(readme_text))):
        checked += 1
        if not (APP_DIR / ref).exists():
            missing.append(f"README: apps/desktop-flutter/{ref}")

    # README 里引用的文档/工具路径同样要存在（排除待产出的 evidence 目录）。
    for ref in DOC_REF.findall(readme_text):
        if ref.startswith("docs/phase9/evidence/"):
            continue
        checked += 1
        if not (ROOT / ref).exists():
            missing.append(f"README: {ref}")

    for text in missing[:MAX_PRINT]:
        print(f"        {text}")
    if len(missing) > MAX_PRINT:
        print(f"        … 另有 {len(missing) - MAX_PRINT} 条")
    detail = f"{checked} 条引用，{len(planned)} 个 PLANNED"
    if planned:
        detail += "（" + "、".join(sorted(planned)) + "）"
    report.check("G9.4", not missing, detail if not missing else f"{len(missing)} 条不存在")


def gate_g95(report: Report, n_rows: list[dict]) -> None:
    problems: list[str] = []
    seen: set[str] = set()
    for row in n_rows:
        cells = row["cells"]
        rid = cells[0] if cells else "(空)"
        if len(cells) != 4:
            problems.append(f"{rid}: 列数 {len(cells)} != 4")
            continue
        if any(not cell for cell in cells):
            problems.append(f"{rid}: 存在空单元格（理由/披露文案必填）")
        if rid in seen:
            problems.append(f"{rid}: ID 重复")
        seen.add(rid)
        if not N_ID.match(rid):
            problems.append(f"{rid}: ID 形状非法")
    for text in problems[:MAX_PRINT]:
        print(f"        {text}")
    report.check("G9.5", not problems and bool(n_rows), f"{len(n_rows)} 项" if not problems else f"{len(problems)} 个问题")


def main() -> int:
    parser = argparse.ArgumentParser(description="Phase 9 差距矩阵门禁 G9.1–G9.5")
    parser.add_argument(
        "--android-root",
        default=str(DEFAULT_ANDROID_ROOT),
        help="安卓基准仓库路径（默认 %(default)s）",
    )
    parser.add_argument(
        "--allow-missing-android",
        action="store_true",
        help="安卓仓库缺失时仍以 0 退出（只跳过 G9.2/G9.3）",
    )
    args = parser.parse_args()

    android_root = Path(args.android_root)
    report = Report()

    rows, n_rows = parse_matrix(report)
    gate_g91(report, rows)
    android_ok = gate_g92(report, rows, android_root if android_root.exists() else None)
    gate_g93(report, android_root if android_ok else None)
    gate_g94(report, rows)
    gate_g95(report, n_rows)

    print()
    if report.failures:
        print(f"FAILED · {len(report.failures)} 项失败")
        return 1
    if not android_ok:
        if args.allow_missing_android:
            print("PASSED（G9.2/G9.3 跳过：安卓仓库缺失）")
            return 0
        print("SKIPPED-ANDROID · G9.1/G9.4/G9.5 通过，但 G9.2/G9.3 未验证")
        return 2
    print("PASSED · G9.1–G9.5 全绿")
    return 0


if __name__ == "__main__":
    sys.exit(main())
