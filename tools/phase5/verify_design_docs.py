#!/usr/bin/env python3
"""校验 Phase 5 安卓桥接设计指导文档的完整性与自洽性。

这是**设计文档级**校验，不是产品验收门禁。产品门禁见
`docs/phase5/design/03-bridge-test-and-acceptance.md` §6，实现阶段由
`tools/phase5/run_windows_acceptance.ps1` 承担。

校验项：

1. 设计指导文档清单完整。
2. 主设计文档顶层章节号连续，且 §28 存在。
3. 设计文档引用的**本仓库**路径存在（`lib/**` 按 `apps/desktop-flutter/` 解析；
   实施阶段才产出的路径必须显式登记在 PLANNED 白名单）。
4. 设计文档引用的**上游** `webhtv/默影视` 路径在本地上游仓库存在
   （上游不可见时降级为提示，不判失败）。
5. 设计文档中的 `§N` / `§N.N` 引用能在主设计文档或设计文档集合内解析。
6. `docs/phase5/design/03` §2.1 声明的安卓 fixture 全部存在。
7. `docs/phase5/design/03` §4.3 声明的反向验证项数不少于 6。
8. 主设计文档 §28 的关键术语与错误类别已写入。

退出码：0 = 全部通过；1 = 存在失败项。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP_ROOT = ROOT / "apps" / "desktop-flutter"

DESIGN_DOCS = [
    "docs/phase5/README.md",
    "docs/phase5/design/00-android-bridge-design-index.md",
    "docs/phase5/design/01-android-t4-site-bridge.md",
    "docs/phase5/design/02-android-sync-protocol.md",
    "docs/phase5/design/03-bridge-test-and-acceptance.md",
]

MAIN_DOC = "docs/webhtv-pc-design.md"

# 上游参考工程（webhtv/默影视）候选位置。
# 本机实测上游在 F:/Workspace/webtv3/webhtv（模拟器 192.168.50.3:5559）。
UPSTREAM_CANDIDATES = [
    Path("F:/Workspace/webtv3/webhtv"),
    Path("F:/Workspace/webhtv"),
    Path("F:/Workspace/webtv2/webhtv"),
    Path("F:/Workspace/webtv4/webhtv"),
]

# 实施阶段才产出的路径：允许引用但当前可能不存在。
PLANNED_PATHS = {
    "lib/core/android_bridge.dart",
    "lib/core/android_sync.dart",
    "lib/services/android_bridge_service.dart",
    "lib/services/sync_server.dart",
    "lib/services/sync_client.dart",
    "lib/state/sync_state.dart",
    "tools/phase5/run_windows_acceptance.ps1",
    "tools/phase5/check_android_fixture.py",
    "tools/phase5/verify_reverse_checks.py",
    "tools/phase5/verify_release_symbols.py",
    "tools/phase5/verify_design_docs.py",
    "docs/phase5/evidence/windows-acceptance.txt",
    "docs/phase5/evidence/device-probe.txt",
    "docs/phase5/evidence/site-fidelity.txt",
    "docs/phase5/evidence/sync-merge-matrix.txt",
    "docs/phase5/evidence/android-bridge.png",
    "docs/phase5/evidence/android-sync.png",
}

# 实施阶段才产出的目录前缀。
PLANNED_PREFIXES = (
    "docs/phase5/evidence/",
    "packages/test-fixtures/android/",
    "tools/phase5/",
    "test/phase5_",
    "apps/desktop-flutter/test/phase5_",
    "apps/desktop-flutter/integration_test/phase5_",
)

# 允许引用但无需在仓库存在的路径（上游文档 / 上游工程路径）。
UPSTREAM_PREFIXES = (
    "app/src/main/java/",
    "docs/C45-",
    "docs/playback-history-delete-sync-design.md",
)

PATH_PATTERN = re.compile(
    r"`((?:packages|tests|docs|lib|apps|tools|sidecars|scripts)/[A-Za-z0-9_./\-]+)`"
)
SECTION_PATTERN = re.compile(r"§(\d+(?:\.\d+)*)")
HEADING_PATTERN = re.compile(r"^(#{2,4})\s+(\d+(?:\.\d+)*)\.?\s*(.*)$")

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
    """把设计文档里的路径解析为仓库内真实路径。"""
    for base in (ROOT, APP_ROOT):
        target = base / candidate
        if target.exists():
            return target
    return None


def upstream_root() -> Path | None:
    for path in UPSTREAM_CANDIDATES:
        if path.is_dir():
            return path
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


def check_design_docs_exist() -> None:
    missing = [path for path in DESIGN_DOCS if not (ROOT / path).is_file()]
    if missing:
        fail(f"缺少设计指导文档：{missing}")
        return
    fact(f"设计指导文档 {len(DESIGN_DOCS)} 份全部存在")


def check_main_doc() -> set[str]:
    sections, top_level = collect_sections(read(MAIN_DOC))
    expected = list(range(1, len(top_level) + 1))
    if top_level != expected:
        fail(f"主设计文档顶层章节号不连续：{top_level}")
    else:
        fact(f"主设计文档顶层章节 1..{len(top_level)} 连续")

    if "28" not in sections:
        fail("主设计文档缺少 §28 安卓桥接 章节")
    else:
        fact("主设计文档包含 §28 安卓桥接")

    sub = sorted(number for number in sections if "." in number)
    fact(f"主设计文档子章节 {len(sub)} 个，最深 §{sub[-1] if sub else '-'}")
    return sections


def is_range_reference(candidate: str) -> bool:
    """`docs/phase4/design/05` 这种范围引用指向 `design/05-*.md`。"""
    parent = (ROOT / candidate).parent
    stem = Path(candidate).name
    return parent.is_dir() and any(parent.glob(f"{stem}-*"))


def check_repo_paths() -> None:
    missing: list[str] = []
    planned: set[str] = set()
    for doc in DESIGN_DOCS:
        for candidate in sorted(set(PATH_PATTERN.findall(read(doc)))):
            if candidate.startswith(PLANNED_PREFIXES):
                planned.add(candidate)
                continue
            if candidate.startswith(UPSTREAM_PREFIXES):
                continue
            if is_range_reference(candidate):
                continue
            if candidate.startswith("docs/") and not (ROOT / candidate).exists():
                # 上游文档引用由 check_upstream_docs 处理；phase5 自身文档必须存在。
                if candidate.startswith("docs/phase5/"):
                    missing.append(f"{doc} → {candidate}")
                continue
            if resolve_repo_path(candidate) is not None:
                continue
            if candidate in PLANNED_PATHS:
                planned.add(candidate)
                continue
            missing.append(f"{doc} → {candidate}")
    if missing:
        fail(f"设计文档引用了不存在的仓库路径：{missing}")
    else:
        fact(
            "设计文档引用的仓库路径全部存在"
            f"（另有 {len(planned)} 条登记为实施阶段产出）"
        )


def check_upstream_docs() -> None:
    upstream = upstream_root()
    referenced: set[str] = set()
    for doc in DESIGN_DOCS:
        for candidate in PATH_PATTERN.findall(read(doc)):
            if candidate.startswith(PLANNED_PREFIXES):
                continue  # 本阶段产出，不是上游文档
            if is_range_reference(candidate):
                continue  # `docs/phase4/design/05` 这类范围引用
            if candidate.startswith(UPSTREAM_PREFIXES) or (
                candidate.startswith("docs/")
                and not (ROOT / candidate).exists()
                and not candidate.startswith("docs/phase5/")
            ):
                referenced.add(candidate)
    if not referenced:
        fact("设计文档未引用上游路径（跳过上游校验）")
        return
    if upstream is None:
        print(
            f"WARN  上游仓库不可见（候选：{[str(p) for p in UPSTREAM_CANDIDATES]}），"
            f"跳过 {len(referenced)} 条上游路径校验",
            file=sys.stderr,
        )
        return
    missing = sorted(
        candidate for candidate in referenced if not (upstream / candidate).exists()
    )
    if missing:
        fail(f"上游仓库缺少被引用的路径：{missing}")
    else:
        fact(f"上游仓库 {upstream} 含全部 {len(referenced)} 条被引用路径")


def check_section_references(main_sections: set[str]) -> None:
    pool = set(main_sections)
    for doc in DESIGN_DOCS:
        pool |= collect_sections(read(doc))[0]
    unresolved: list[str] = []
    for doc in DESIGN_DOCS:
        text = read(doc)
        for number in sorted(set(SECTION_PATTERN.findall(text))):
            if number in pool:
                continue
            # `§N` 可能是主设计文档的顶层章节。
            if number.split(".")[0] in pool and "." not in number:
                continue
            unresolved.append(f"{doc} → §{number}")
    if unresolved:
        fail(f"存在无法解析的章节引用：{unresolved}")
    else:
        fact(f"章节引用全部可解析（文档池含 {len(pool)} 个标题号）")


def check_main_doc_phase5_references() -> None:
    """主设计文档对 docs/phase5/** 的引用必须存在（§28 与 §21 Phase 5）。"""
    text = read(MAIN_DOC)
    referenced = sorted(set(re.findall(r"`(docs/phase5/[A-Za-z0-9_./\-]+)`", text)))
    if not referenced:
        fail("主设计文档没有引用任何 docs/phase5/** 路径")
        return
    missing: list[str] = []
    for path in referenced:
        if (ROOT / path).is_file():
            continue
        # 范围引用（如 docs/phase5/design/00 指向 design/00-*.md）。
        parent = (ROOT / path).parent
        stem = Path(path).name
        if parent.is_dir() and any(parent.glob(f"{stem}-*")):
            continue
        if path.startswith("docs/phase5/evidence/"):
            continue
        missing.append(path)
    if missing:
        fail(f"主设计文档引用了不存在的 docs/phase5 路径：{missing}")
        return
    fact(f"主设计文档引用的 {len(referenced)} 条 docs/phase5 路径全部可解析")

    if "Phase 5：生态与同步" not in text:
        fail("§21 缺少「Phase 5：生态与同步」")
    else:
        fact("§21 包含 Phase 5：生态与同步")

    for token in (
        "安卓桥接",
        "桥接不复制",
        "bridgeUnreachable",
        "bridgeNotAndroid",
        "bridgeNoGateway",
        "bridgeEmptySites",
        "bridgeHostMismatch",
        "bridgeSelfReference",
        "syncDisabled",
        "syncPeerUnauthorized",
        "syncPeerUnreachable",
        "syncPayloadInvalid",
        "syncLocalWriteRejected",
        "syncPartialFailure",
    ):
        if token not in text:
            fail(f"主设计文档缺少关键术语/错误类别：{token}")
    fact("§28 关键术语与错误类别已写入主设计文档")

    for model in ("AndroidDevice", "SyncOptions", "PlaybackHistory", "T4 / 网关", "可达地址"):
        if model not in text:
            fail(f"§28 缺少关键模型/术语：{model}")
    fact("§28 关键模型与术语已写入主设计文档")


def check_android_fixtures() -> None:
    """解析 docs/phase5/design/03 §2.1 的目录块，逐个校验 fixture 存在。

    目录项形如 ``├── device.json                    # 说明``：必须先剥掉行尾注释，
    否则带注释的条目会被静默跳过。
    """
    text = read("docs/phase5/design/03-bridge-test-and-acceptance.md")
    block = text.split("### 2.1 目录")[1].split("```text")[1].split("```")[0]
    names: list[str] = []
    root_prefix = ""
    current_dir = ""
    for raw in block.splitlines():
        line = raw.strip()
        for prefix in ("├── ", "└── ", "│   "):
            line = line.removeprefix(prefix)
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        if line.endswith("/"):
            if not root_prefix:
                root_prefix = line
                current_dir = line
            else:
                current_dir = root_prefix + line
            continue
        if line.endswith(".json"):
            names.append(current_dir + line)
    if not names:
        fail("docs/phase5/design/03 §2.1 目录解析异常，未解析出任何 fixture")
        return
    missing = [name for name in names if not (ROOT / name).is_file()]
    if missing:
        fail(f"docs/phase5/design/03 §2.1 声明的 fixture 缺失：{missing}")
    else:
        fact(f"docs/phase5/design/03 §2.1 声明的 {len(names)} 个 fixture 全部存在")


def check_reverse_checks() -> None:
    """§4.3 的反向验证项不得少于 6 项（design/03 §4.3 的基线）。"""
    text = read("docs/phase5/design/03-bridge-test-and-acceptance.md")
    block = text.split("### 4.3 反向验证")[1].split("## 5.")[0]
    rows = [
        line
        for line in block.splitlines()
        if line.startswith("|") and not line.startswith("| ---") and not line.startswith("| # ")
    ]
    if len(rows) < 6:
        fail(f"§4.3 反向验证项只有 {len(rows)} 项（基线要求 >= 6）")
        return
    fact(f"§4.3 反向验证项 {len(rows)} 项（基线 6 项）")


def main() -> int:
    print("== Phase 5 安卓桥接设计指导文档校验 ==")
    check_design_docs_exist()
    main_sections = check_main_doc()
    check_main_doc_phase5_references()
    check_repo_paths()
    check_upstream_docs()
    check_section_references(main_sections)
    check_android_fixtures()
    check_reverse_checks()

    print()
    print(f"通过 {len(facts)} 项，失败 {len(failures)} 项")
    for line in facts:
        print(f"PHASE5-DESIGN ok  {line}")
    for line in failures:
        print(f"PHASE5-DESIGN fail {line}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
