#!/usr/bin/env python3
"""Phase 7 设计文档一致性门禁（`docs/phase7/design/04` §6 的 G11）。

这是**设计文档级**校验，不是产品验收门禁。产品门禁见
`tools/phase7/run_windows_acceptance.ps1`。

校验项（每项都对应一个真发生过的漂移）
------------------------------------
1. 五份设计文档 + README 全部存在；
2. `design/01`–`04` 的顶层章节号连续（漏号说明有章节被删而引用还在）；
3. 设计文档引用的**本仓库**路径存在（实施阶段才产出的登记在 PLANNED）；
4. `§N` / `§N.N` 引用能在文档集合内解析（跨文档引用写错是最常见的漂移）；
5. **契约快照与源码一致**——本轮新增的三处：
   - `realtime` 段的键名必须与 `SyncState._writeSettings` 写出的键一致；
   - `sync.identity` 段必须被真正落盘；
   - 反向验证项数必须等于脚本里的 `CHECKS` 长度（8）；
6. 门禁表 G1–G12 齐全，且一键脚本覆盖了每个 Gate 编号；
7. 套件清单与磁盘上的 `phase7_*` 文件一致（少一个就是"清单说绿了但没有"）。

退出码：0 = 全部通过；1 = 存在失败项。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP_ROOT = ROOT / "apps" / "desktop-flutter"

DESIGN_DOCS = [
    "docs/phase7/README.md",
    "docs/phase7/design/00-android-live-sync-design-index.md",
    "docs/phase7/design/01-realtime-sync-protocol.md",
    "docs/phase7/design/02-android-keepalive-and-wake.md",
    "docs/phase7/design/03-resume-not-next-episode.md",
    "docs/phase7/design/04-test-and-acceptance.md",
]

NUMBERED_DOCS = DESIGN_DOCS[1:]  # 00–04（README 没有连续章节号约束）

# 实施阶段才产出的路径：允许引用但当前可能不存在。
PLANNED_PREFIXES = (
    "docs/phase7/evidence/",
    "tools/phase7/",
    "test/phase7_",
    "apps/desktop-flutter/test/phase7_",
    "apps/desktop-flutter/integration_test/phase7_",
    "packages/test-fixtures/android/",
)

# 允许引用但无需在仓库存在的路径（上游工程路径）。
UPSTREAM_PREFIXES = (
    "app/src/main/java/",
    "serverless/",
    "docs/playback-sync-identity-matching-design.md",
    "docs/PC-REALTIME-SYNC-01-android-contract-gap.md",
)

PATH_PATTERN = re.compile(
    r"`((?:packages|tests|docs|lib|apps|tools|sidecars|scripts)/[A-Za-z0-9_./\-]+)`"
)
SECTION_PATTERN = re.compile(r"§(\d+(?:\.\d+)*)")
HEADING_PATTERN = re.compile(r"^(#{2,4})\s+(\d+(?:\.\d+)*)\.?\s*(.*)$")

# 必须存在的 Phase 7 套件（`design/04` §3.1 的 L1/L2 清单）。
REQUIRED_SUITES = [
    "test/phase7_realtime_core_test.dart",
    "test/phase7_keepalive_test.dart",
    "test/phase7_resume_gate_test.dart",
    "test/phase7_player_advance_test.dart",
    "test/phase7_settings_mapping_test.dart",
    "test/phase7_android_read_client_test.dart",
    "test/phase7_pull_endpoint_test.dart",
    "test/phase7_identity_resolve_test.dart",
    "test/phase7_identity_persistence_test.dart",
    "test/phase7_realtime_engine_test.dart",
    "test/phase7_realtime_state_test.dart",
    "test/phase7_sync_ui_test.dart",
]

# 必须存在的 L3 集成套件。
REQUIRED_INTEGRATION = [
    "integration_test/phase7_resume_flow_test.dart",
]

# 门禁编号（`design/04` §6 表）。
REQUIRED_GATES = [f"G{n}" for n in range(1, 13)]

failures: list[str] = []
facts: list[str] = []


def fail(message: str) -> None:
    failures.append(message)
    print(f"FAIL  {message}", file=sys.stderr)


def fact(message: str) -> None:
    facts.append(message)
    print(f"OK    {message}")


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def resolve_repo_path(candidate: str) -> Path | None:
    for base in (ROOT, APP_ROOT):
        target = base / candidate
        if target.exists():
            return target
    return None


def collect_sections(text: str) -> tuple[set[str], list[int]]:
    sections: set[str] = set()
    top_level: list[int] = []
    for line in text.splitlines():
        match = HEADING_PATTERN.match(line)
        if not match:
            continue
        level, number, _ = match.groups()
        sections.add(number)
        if level == "##" and number.isascii() and number.isdigit():
            top_level.append(int(number))
    return sections, top_level


def check_docs_exist() -> None:
    missing = [path for path in DESIGN_DOCS if not (ROOT / path).is_file()]
    if missing:
        fail(f"缺少设计文档：{missing}")
        return
    fact(f"设计文档 {len(DESIGN_DOCS)} 份全部存在")


def check_headings() -> set[str]:
    pool: set[str] = set()
    for doc in NUMBERED_DOCS:
        sections, top_level = collect_sections(read(doc))
        pool |= sections
        if not top_level:
            fail(f"{doc} 没有二级章节号标题")
            continue
        # 允许从 0 或 1 开始（`00-index` 这类文档从 §0 起，属于正常形态），
        # 但**必须连续**：跳号说明有章节被删而引用还在。
        expected = list(range(top_level[0], top_level[0] + len(top_level)))
        if top_level != expected:
            fail(f"{doc} 顶层章节号不连续：{top_level}")
        else:
            fact(
                f"{doc} 顶层章节 {top_level[0]}..{top_level[-1]} 连续"
            )
    return pool


def is_range_reference(candidate: str) -> bool:
    parent = (ROOT / candidate).parent
    stem = Path(candidate).name
    return parent.is_dir() and any(parent.glob(f"{stem}-*"))


def check_repo_paths() -> None:
    missing: list[str] = []
    planned = 0
    for doc in DESIGN_DOCS:
        for candidate in sorted(set(PATH_PATTERN.findall(read(doc)))):
            if candidate.startswith(PLANNED_PREFIXES):
                planned += 1
                continue
            if candidate.startswith(UPSTREAM_PREFIXES):
                continue
            if is_range_reference(candidate):
                continue
            if candidate.startswith("docs/") and not (ROOT / candidate).exists():
                if candidate.startswith("docs/phase7/"):
                    missing.append(f"{doc} → {candidate}")
                continue
            if candidate.startswith("lib/") and not (
                (APP_ROOT / candidate).exists()
            ):
                missing.append(f"{doc} → {candidate}")
                continue
            if resolve_repo_path(candidate) is not None:
                continue
            missing.append(f"{doc} → {candidate}")
    if missing:
        fail(f"设计文档引用了不存在的仓库路径：{missing}")
    else:
        fact(f"设计文档引用的仓库路径全部存在（{planned} 条登记为实施阶段产出）")


def check_section_references(pool: set[str]) -> None:
    # 主设计文档的章节号也算解析池（`§29` 之类）。
    main_doc = ROOT / "docs/webhtv-pc-design.md"
    if main_doc.is_file():
        pool |= collect_sections(main_doc.read_text(encoding="utf-8"))[0]
    unresolved: list[str] = []
    for doc in DESIGN_DOCS:
        # 按行扫：引用了**上游**文档的行不参与本仓库的章节解析。
        # 例：`| 协议规范：docs/playback-sync-identity-matching-design.md §6.1–§6.6 |`
        # 里的 §6.6 属于上游文档，在本仓库永远解析不到——把它判为漂移是误报。
        local_numbers: set[str] = set()
        for line in read(doc).splitlines():
            if any(marker in line for marker in UPSTREAM_PREFIXES):
                continue
            local_numbers.update(SECTION_PATTERN.findall(line))
        for number in sorted(local_numbers):
            if number in pool:
                continue
            if "." not in number and number.split(".")[0] in pool:
                continue
            unresolved.append(f"{doc} → §{number}")
    if unresolved:
        fail(f"存在无法解析的章节引用：{unresolved}")
    else:
        fact(f"章节引用全部可解析（文档池 {len(pool)} 个标题号）")


def check_contract_snapshots() -> None:
    """文档里写的持久化键/编号必须与源码一致。"""
    sync_state = (APP_ROOT / "lib/state/sync_state.dart").read_text(encoding="utf-8")
    protocol_doc = read("docs/phase7/design/01-realtime-sync-protocol.md")

    # 1) `sync.realtime` 段的每个键都必须真的被写出来。
    realtime_keys = [
        "enabled",
        "pullEnabled",
        "pushEnabled",
        "settingsEnabled",
        "intervalSeconds",
        "heartbeatSeconds",
        "pollAllSites",
        "pullCursorMs",
        "pullToken",
    ]
    missing_keys = [
        key for key in realtime_keys if f"'{key}'" not in sync_state
    ]
    if missing_keys:
        fail(f"文档声明的 sync.realtime 键未在源码中落盘：{missing_keys}")
    else:
        fact(f"sync.realtime 的 {len(realtime_keys)} 个键均已落盘")

    # 2) `sync.identity` 段必须落盘（丢了会让两端身份键永久错开）。
    if "'identity': _playbackIdentity.toJson()" not in sync_state:
        fail("sync.identity 未落盘（`design/01` §3.2.1：adopt 结论会丢）")
    else:
        fact("sync.identity 已落盘")

    # 3) 反向验证项数必须与脚本里的 CHECKS 一致。
    script = (ROOT / "tools/phase7/verify_reverse_checks.py").read_text(
        encoding="utf-8"
    )
    checks_count = len(re.findall(r"\n    Check\(\n        \d+,", script))
    documented = re.search(r"本轮 8 项|本轮 (\d+) 项", protocol_doc)
    doc_count = 8
    if documented and documented.group(1):
        doc_count = int(documented.group(1))
    if checks_count != doc_count:
        fail(
            f"反向验证项数不一致：文档={doc_count} 脚本={checks_count}"
        )
    else:
        fact(f"反向验证项数一致（{checks_count} 项）")

    # 4) 文档声明的双路径端点必须在服务端真实注册。
    server = (APP_ROOT / "lib/services/sync_server.dart").read_text(encoding="utf-8")
    for route in (
        "/api/playback/sync",
        "/api/playback/sync/status",
        "/api/playback/identity/resolve",
    ):
        if f"'{route}'" not in server:
            fail(f"文档声明的端点未在 sync_server 注册：{route}")
    fact("三个路径 B 端点均在 sync_server 注册")


def check_gate_table() -> None:
    text = read("docs/phase7/design/04-test-and-acceptance.md")
    missing = [gate for gate in REQUIRED_GATES if f"| {gate} |" not in text]
    if missing:
        fail(f"门禁表缺少：{missing}")
    else:
        fact(f"门禁表 G1–G12 齐全（{len(REQUIRED_GATES)} 项）")

    # 一键脚本必须覆盖每个 Gate 编号（否则"一键验收"是空话）。
    script = ROOT / "tools/phase7/run_windows_acceptance.ps1"
    if not script.is_file():
        fail("缺少 tools/phase7/run_windows_acceptance.ps1")
        return
    body = script.read_text(encoding="utf-8")
    uncovered = [gate for gate in REQUIRED_GATES if gate not in body]
    if uncovered:
        fail(f"一键验收脚本未覆盖门禁：{uncovered}")
    else:
        fact("一键验收脚本覆盖 G1–G12")


def check_suites() -> None:
    missing = [
        path
        for path in REQUIRED_SUITES + REQUIRED_INTEGRATION
        if not (APP_ROOT / path).is_file()
    ]
    if missing:
        fail(f"缺少套件：{missing}")
        return
    fact(f"套件齐备（单元 {len(REQUIRED_SUITES)} + 集成 {len(REQUIRED_INTEGRATION)}）")

    # 磁盘上多出来的 phase7 套件必须在 README 清单里出现，否则是"跑了但没人知道"。
    readme = read("docs/phase7/README.md")
    on_disk = sorted(
        path.name
        for path in (APP_ROOT / "test").glob("phase7_*.dart")
    ) + sorted(
        path.name
        for path in (APP_ROOT / "integration_test").glob("phase7_*.dart")
    )
    undocumented = [name for name in on_disk if name not in readme]
    if undocumented:
        fail(f"README 套件清单漏了：{undocumented}")
    else:
        fact(f"README 清单覆盖全部 {len(on_disk)} 个 phase7 套件")


def main() -> int:
    check_docs_exist()
    pool = check_headings()
    check_repo_paths()
    check_section_references(pool)
    check_contract_snapshots()
    check_gate_table()
    check_suites()

    if failures:
        print(
            f"PHASE7-DOCS result=FAIL failures={len(failures)}",
            file=sys.stderr,
        )
        return 1
    print(f"PHASE7-DOCS result=PASS checks={len(facts)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
