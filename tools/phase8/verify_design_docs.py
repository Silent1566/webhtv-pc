#!/usr/bin/env python3
"""Phase 8 设计文档一致性门禁（G6）。

校验项：
1. 六份设计文档 + README 全部存在；
2. `design/01`–`05` 的顶层章节号连续；
3. 设计文档引用的本仓库路径存在（实施阶段才产出的登记在 PLANNED）；
4. `design/NN` / `plans/NN` 的 `§N.N` 引用能在对应文档的标题里解析；
5. 契约快照与源码一致：`OsdFlag.values` 与 `kPlayerButtons` 的 id 集合
   必须与 `design/02` §5.1、`design/03` §3.2 的表格一致；
6. 门禁表 G1–G12 齐全；
7. 套件清单与磁盘上的 `phase8_*` 文件一致。

第 4、5 项是本轮新增的：计划稿的文档字符串承诺了 7 项检查，但 `main()`
只串了 5 个函数——`SECTION_PATTERN` 定义了却零引用，契约快照完全没实现。
文档与代码漂移正是本轮最高频的缺陷类，所以补上而不是删掉承诺。

退出码：0 = 全部通过；1 = 存在失败项。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP_ROOT = ROOT / "apps" / "desktop-flutter"

DESIGN_DOCS = [
    "docs/phase8/README.md",
    "docs/phase8/design/00-player-overlay-design-index.md",
    "docs/phase8/design/01-overlay-layout.md",
    "docs/phase8/design/02-osd.md",
    "docs/phase8/design/03-button-layout-and-config.md",
    "docs/phase8/design/04-context-menu.md",
    "docs/phase8/design/05-test-and-acceptance.md",
]

NUMBERED_DOCS = DESIGN_DOCS[2:]  # 01–05

PLANNED_PREFIXES = (
    "docs/phase8/evidence/",
    "tools/phase8/",
    "test/phase8_",
    "apps/desktop-flutter/test/phase8_",
    "apps/desktop-flutter/integration_test/phase8_",
)

PATH_PATTERN = re.compile(
    r"`((?:packages|tests|docs|lib|apps|tools|sidecars|scripts)/[A-Za-z0-9_./\-]+)`"
)
HEADING_PATTERN = re.compile(r"^(#{2,4})\s+(\d+(?:\.\d+)*)\.?\s*(.*)$")

# `design/02` §5.1 / `plans/01` §3 这类带前缀的引用。
PREFIXED_REF_PATTERN = re.compile(
    r"`?(design|plans)/(\d{2})[a-z0-9\-]*`?\s*§(\d+(?:\.\d+)*)"
)

REQUIRED_SUITES = [
    "test/phase8_osd_config_test.dart",
    "test/phase8_player_buttons_test.dart",
    "test/phase8_osd_persistence_test.dart",
    "test/phase8_app_state_config_test.dart",
    "test/phase8_osd_diagnostics_test.dart",
    "test/phase8_osd_layer_test.dart",
    "test/phase8_overlay_layout_test.dart",
    "test/phase8_context_menu_test.dart",
    "test/phase8_button_config_page_test.dart",
    "test/phase8_settings_entries_test.dart",
    "test/phase8_player_page_overlay_test.dart",
    "integration_test/phase8_overlay_flow_test.dart",
    "integration_test/phase8_visual_flow_test.dart",
]

GATES = [f"G{i}" for i in range(1, 13)]

OSD_SOURCE = APP_ROOT / "lib" / "core" / "osd_config.dart"
BUTTONS_SOURCE = APP_ROOT / "lib" / "core" / "player_buttons.dart"
OSD_DOC = ROOT / "docs/phase8/design/02-osd.md"
BUTTONS_DOC = ROOT / "docs/phase8/design/03-button-layout-and-config.md"

# `docs/phase8/design/02` §5.1 的表格行：| `title` | 标题 | **true** | ...
OSD_TABLE_ROW = re.compile(r"^\|\s*`([a-z_]+)`\s*\|")
# `docs/phase8/design/03` §3.2 的表格行：| `prev` | 上一集 | ... | ✅ | 传输 | ✅ |
BUTTONS_TABLE_ROW = re.compile(r"^\|\s*`([a-z_]+)`\s*\|")


def doc_path(prefix: str, number: str) -> Path | None:
    """把 `design/02` 这样的引用解析成磁盘路径。"""
    base = ROOT / "docs" / "phase8" / ("design" if prefix == "design" else "plans")
    for candidate in sorted(base.glob(f"{number}*.md")):
        return candidate
    return None


def headings_of(path: Path) -> set[str]:
    """收集一份文档里所有标题的编号（`3`、`3.2`、`10.4` …）。"""
    numbers: set[str] = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        match = HEADING_PATTERN.match(line)
        if match:
            numbers.add(match.group(2))
    return numbers


def check_docs_exist() -> list[str]:
    return [
        f"缺少设计文档：{doc}" for doc in DESIGN_DOCS if not (ROOT / doc).exists()
    ]


def check_numbering() -> list[str]:
    problems: list[str] = []
    for doc in NUMBERED_DOCS:
        path = ROOT / doc
        if not path.exists():
            continue
        numbers: list[int] = []
        for line in path.read_text(encoding="utf-8").splitlines():
            match = HEADING_PATTERN.match(line)
            if match:
                numbers.append(int(match.group(2).split(".")[0]))
        unique = sorted(set(numbers))
        if unique and unique != list(range(1, len(unique) + 1)):
            problems.append(f"{doc}: 顶层章节号不连续 → {unique}")
    return problems


def _resolves(referenced: str) -> bool:
    """路径引用是否指向真实存在的文件或目录。

    三类合法形态（都实测过，不是猜测）：
    - 仓库根相对：`docs/phase8/design/01-overlay-layout.md`；
    - **应用根相对**：`lib/ui/player_page.dart` 指的是
      `apps/desktop-flutter/lib/ui/player_page.dart`——设计文档通篇这么写；
    - **文件名前缀**：`docs/phase8/design/00` 指的是
      `00-player-overlay-design-index.md`（文档里用短名互相引用）。
    """
    for base in (ROOT, APP_ROOT):
        target = base / referenced
        if target.exists():
            return True
        parent = target.parent
        if parent.is_dir():
            name = target.name
            if any(child.name.startswith(name) for child in parent.iterdir()):
                return True
    return False


def check_paths() -> list[str]:
    problems: list[str] = []
    for doc in DESIGN_DOCS:
        path = ROOT / doc
        if not path.exists():
            continue
        for match in PATH_PATTERN.finditer(path.read_text(encoding="utf-8")):
            referenced = match.group(1)
            if referenced.startswith(PLANNED_PREFIXES):
                continue
            if not _resolves(referenced):
                problems.append(f"{doc}: 引用了不存在的路径 {referenced}")
    return problems


def check_sections() -> list[str]:
    """第 4 项：`design/NN` / `plans/NN` 的 `§N.N` 必须能在该文档的标题里找到。"""
    problems: list[str] = []
    cache: dict[str, set[str]] = {}
    for doc in DESIGN_DOCS + ["docs/phase8/plans/01-player-overlay.md"]:
        path = ROOT / doc
        if not path.exists():
            continue
        for match in PREFIXED_REF_PATTERN.finditer(path.read_text(encoding="utf-8")):
            prefix, number, section = match.groups()
            target = doc_path(prefix, number)
            if target is None:
                problems.append(
                    f"{doc}: 引用了不存在的文档 {prefix}/{number}（§{section}）"
                )
                continue
            key = target.as_posix()
            if key not in cache:
                cache[key] = headings_of(target)
            if section not in cache[key]:
                problems.append(
                    f"{doc}: {prefix}/{number} §{section} 在"
                    f" {target.relative_to(ROOT).as_posix()} 里没有对应标题"
                )
    return problems


def _table_ids(path: Path, section: str, limit: int = 40) -> list[str]:
    """读出某个 §section 标题之后的第一张表格的 id 列。"""
    lines = path.read_text(encoding="utf-8").splitlines()
    start: int | None = None
    for index, line in enumerate(lines):
        match = HEADING_PATTERN.match(line)
        if match and match.group(2) == section:
            start = index + 1
            break
    if start is None:
        return []
    ids: list[str] = []
    for line in lines[start : start + limit]:
        if line.startswith("#") and ids:
            break
        row = OSD_TABLE_ROW.match(line)
        if row and row.group(1) not in ids:
            ids.append(row.group(1))
    return ids


def check_contracts() -> list[str]:
    """第 5 项：源码里的 id 集合必须与设计文档的表格一致。"""
    problems: list[str] = []

    # --- 屏显开关：`OsdFlag.values` vs `design/02` §5.1 ---
    osd_source = OSD_SOURCE.read_text(encoding="utf-8")
    block = re.search(
        r"static const List<String> values = \[(.*?)\];", osd_source, re.DOTALL
    )
    if not block:
        problems.append("osd_config.dart: 找不到 OsdFlag.values")
    else:
        code_ids = re.findall(r"^\s*([a-z_]+),", block.group(1), re.MULTILINE)
        doc_ids = _table_ids(OSD_DOC, "5.1")
        if not doc_ids:
            problems.append("design/02 §5.1: 读不到开关表格")
        elif code_ids != doc_ids:
            problems.append(
                f"屏显开关契约漂移：osd_config.dart={code_ids} vs design/02 §5.1={doc_ids}"
            )

    # --- 可配置按钮：`kPlayerButtons` vs `design/03` §3.2 的「可配置」列 ---
    buttons_source = BUTTONS_SOURCE.read_text(encoding="utf-8")
    block = re.search(
        r"const List<PlayerButtonSpec> kPlayerButtons = \[(.*?)\n\];",
        buttons_source,
        re.DOTALL,
    )
    if not block:
        problems.append("player_buttons.dart: 找不到 kPlayerButtons")
    else:
        code_ids = re.findall(r"id:\s*'([a-z_]+)'", block.group(1))
        doc_ids = _table_ids(BUTTONS_DOC, "3.2")
        # §3.2 的表同时列了不可配置的按钮，只取「可配置」列为 ✅ 的行。
        configurable: list[str] = []
        lines = BUTTONS_DOC.read_text(encoding="utf-8").splitlines()
        start = next(
            (
                index + 1
                for index, line in enumerate(lines)
                if (m := HEADING_PATTERN.match(line)) and m.group(2) == "3.2"
            ),
            None,
        )
        if start is not None:
            for line in lines[start : start + 40]:
                if line.startswith("#") and configurable:
                    break
                row = OSD_TABLE_ROW.match(line)
                if row and line.rstrip().endswith("| ✅ |") and "❌" not in line:
                    configurable.append(row.group(1))
        if not configurable:
            problems.append("design/03 §3.2: 读不到可配置按钮表格")
        elif code_ids != configurable:
            problems.append(
                f"可配置按钮契约漂移：player_buttons.dart={code_ids} vs"
                f" design/03 §3.2={configurable}"
            )
        if doc_ids and len(doc_ids) <= len(code_ids):
            problems.append(
                f"design/03 §3.2 表格只有 {len(doc_ids)} 行，少于源码的"
                f" {len(code_ids)} 个可配置按钮"
            )

    return problems


def check_suites() -> list[str]:
    return [
        f"缺少套件：{suite}"
        for suite in REQUIRED_SUITES
        if not (APP_ROOT / suite).exists()
    ]


def check_gates() -> list[str]:
    """门禁表必须逐行存在。

    **不能只查 `gate in text`**：`G12` 在正文里被解释了两次
    （「G12 的判据为什么长这样」「这才是 G12 真正要防的东西」），
    所以删掉表格行后裸子串匹配仍然通过——实测踩到过。
    这里要求的是**表格行** `| G12 | …`。
    """
    doc = ROOT / "docs/phase8/design/05-test-and-acceptance.md"
    if not doc.exists():
        return ["缺少 design/05"]
    lines = doc.read_text(encoding="utf-8").splitlines()
    rows = {
        match.group(1)
        for line in lines
        if (match := re.match(r"^\|\s*(G\d+)\s*\|", line))
    }
    return [f"design/05 门禁表缺少 {gate}" for gate in GATES if gate not in rows]


def main() -> int:
    problems = (
        check_docs_exist()
        + check_numbering()
        + check_paths()
        + check_sections()
        + check_contracts()
        + check_suites()
        + check_gates()
    )
    if problems:
        print("PHASE8-DESIGN-DOCS result=FAIL")
        for item in problems:
            print(f"  - {item}")
        return 1
    print("PHASE8-DESIGN-DOCS result=PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
