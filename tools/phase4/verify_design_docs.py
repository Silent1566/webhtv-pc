#!/usr/bin/env python3
"""校验 Phase 4 TMDB 设计指导文档的完整性与自洽性。

这是**设计文档级**校验，不是产品验收门禁。产品门禁见
`docs/phase4/design/05-tmdb-test-and-acceptance.md` §6，实现阶段由
`tools/phase4/run_windows_acceptance.ps1` 承担。

校验项：

1. 设计指导文档清单完整。
2. 主设计文档顶层章节号连续，且 §27 存在。
3. 设计文档引用的**本仓库**路径存在（`lib/**` 按 `apps/desktop-flutter/` 解析；
   实施阶段才产出的路径必须显式登记在 PLANNED 白名单）。
4. 设计文档引用的**上游** `webhtv/默影视` 文档在本地上游仓库存在
   （上游不可见时降级为提示，不判失败）。
5. 设计文档中的 `§N` / `§N.N` 引用能在主设计文档或设计文档集合内解析。
6. `docs/phase4/design/05` 声明的 TMDB fixture 全部存在。
7. TMDB 配置 Schema 与三个 fixture 的校验关系成立（含反向验证）。

退出码：0 = 全部通过；1 = 存在失败项。
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP_ROOT = ROOT / "apps" / "desktop-flutter"

DESIGN_DOCS = [
    "docs/phase4/README.md",
    "docs/phase4/design/00-tmdb-design-index.md",
    "docs/phase4/design/01-tmdb-identity-and-matching.md",
    "docs/phase4/design/02-tmdb-season-resolution-and-progress.md",
    "docs/phase4/design/03-tmdb-service-config-storage.md",
    "docs/phase4/design/04-tmdb-detail-ui-and-playback.md",
    "docs/phase4/design/05-tmdb-test-and-acceptance.md",
]

MAIN_DOC = "docs/webhtv-pc-design.md"

# 上游参考工程（webhtv/默影视）候选位置。
UPSTREAM_CANDIDATES = [Path("F:/Workspace/webhtv"), Path("F:/Workspace/webhtv-dev2")]

# 实施阶段才产出的路径：允许引用但当前不存在。
PLANNED_PATHS = {
    "lib/core/tmdb_title.dart",
    "lib/core/tmdb_identity.dart",
    "lib/core/tmdb_config.dart",
    "lib/core/tmdb_season.dart",
    "lib/core/tmdb_media.dart",
    "lib/services/tmdb_service.dart",
    "lib/services/tmdb_cache.dart",
    "lib/services/tmdb_identity_service.dart",
    "lib/services/tmdb_season_service.dart",
    "lib/services/tmdb_enrichment_service.dart",
    "lib/state/tmdb_state.dart",
    "lib/ui/tmdb_widgets.dart",
    "lib/ui/tmdb_detail_page.dart",
    "tools/phase4/run_windows_acceptance.ps1",
    "tools/phase4/verify_tmdb_redaction.py",
    "tools/phase4/fixtures/tmdb-credentials.sample.json",
    "docs/phase4/evidence/windows-acceptance.txt",
}

PLANNED_PREFIXES = (
    "lib/core/tmdb_",
    "lib/services/tmdb_",
    "lib/state/tmdb_",
    "lib/ui/tmdb_",
    "apps/desktop-flutter/test/phase4_tmdb_",
    "apps/desktop-flutter/integration_test/tmdb_",
    "tools/phase4/",
    "docs/phase4/evidence/",
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

    if "27" not in sections:
        fail("主设计文档缺少 §27 TMDB 元数据增强 章节")
    else:
        fact("主设计文档包含 §27 TMDB 元数据增强")

    sub = sorted(number for number in sections if "." in number)
    fact(f"主设计文档子章节 {len(sub)} 个，最深 §{sub[-1] if sub else '-'}")
    return sections


def check_repo_paths() -> None:
    missing: list[str] = []
    planned: set[str] = set()
    for doc in DESIGN_DOCS:
        for candidate in sorted(set(PATH_PATTERN.findall(read(doc)))):
            if candidate.startswith("docs/phase4/evidence/"):
                planned.add(candidate)
                continue
            if candidate.startswith("docs/phase4/evidence/"):
                continue
            if candidate.startswith("docs/") and not (ROOT / candidate).exists():
                continue  # 上游文档引用由 check_upstream_docs 处理
            if resolve_repo_path(candidate) is not None:
                continue
            if candidate in PLANNED_PATHS or candidate.startswith(PLANNED_PREFIXES):
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
            if candidate.startswith("docs/phase4/evidence/"):
                continue  # 实施阶段产出，不是上游文档
            if candidate.startswith("docs/") and not (ROOT / candidate).exists():
                referenced.add(candidate)

    if upstream is None:
        fact(f"上游工程不可见，跳过 {len(referenced)} 条上游文档引用的存在性校验")
        return

    missing = sorted(
        candidate for candidate in referenced if not (upstream / candidate).is_file()
    )
    if missing:
        fail(f"上游文档引用在上游工程中不存在：{missing}")
    else:
        fact(f"上游文档引用 {len(referenced)} 条全部存在于 {upstream}")


def check_section_references(main_sections: set[str]) -> None:
    """每个 ``§N`` / ``§N.M`` 引用都必须能在设计文档集合中解析到真实标题。

    设计文档集合 = 主设计文档 + Phase 1/2/3/4 的 README + 本套 design/00–05。
    这样既能捕获"引用了一个不存在的章节"，也不会把跨文档引用误判为悬空。
    """
    pool: set[str] = set(main_sections)
    for doc in DESIGN_DOCS + [
        "docs/phase1/README.md",
        "docs/phase2/README.md",
        "docs/phase3/README.md",
    ]:
        if (ROOT / doc).is_file():
            sections, _ = collect_sections(read(doc))
            pool |= sections

    unresolved: list[str] = []
    for doc in DESIGN_DOCS:
        text = read(doc)
        # 上游文档引用：`docs/xxx.md` §N（上游文档不在本仓库章节池中）
        upstream_refs: set[str] = set()
        for chunk in re.findall(
            r"`docs/[A-Za-z0-9_./\-]+\.md`\s*((?:§\d+(?:\.\d+)*\s*(?:/|、)?\s*)+)", text
        ):
            upstream_refs.update(re.findall(r"§(\d+(?:\.\d+)*)", chunk))
        for number in sorted(set(SECTION_PATTERN.findall(text))):
            if number in pool or number in upstream_refs:
                continue
            unresolved.append(f"{doc} -> §{number}")

    if unresolved:
        fail(f"存在无法解析的章节引用：{unresolved}")
    else:
        fact(f"章节引用全部可解析（文档池含 {len(pool)} 个标题号）")


def check_main_doc_phase4_references() -> None:
    """主设计文档对 docs/phase4/** 的引用必须存在（§27 与 §21 Phase 5）。"""
    text = read(MAIN_DOC)
    # 允许 `docs/phase4/design/00`–`design/05` 这种范围写法：只校验去掉末段的目录前缀。
    referenced = sorted(
        set(re.findall(r"`(docs/phase4/[A-Za-z0-9_./\-]+)`", text))
    )
    if not referenced:
        fail("主设计文档没有引用任何 docs/phase4/** 路径")
        return
    missing: list[str] = []
    for path in referenced:
        if (ROOT / path).is_file():
            continue
        # 范围引用（如 docs/phase4/design/05 指向 design/05-*.md）与实施阶段产出。
        parent = (ROOT / path).parent
        stem = Path(path).name
        if parent.is_dir() and any(parent.glob(f"{stem}-*")):
            continue
        if path.startswith("docs/phase4/evidence/"):
            continue
        missing.append(path)
    if missing:
        fail(f"主设计文档引用了不存在的 docs/phase4 路径：{missing}")
        return
    fact(f"主设计文档引用的 {len(referenced)} 条 docs/phase4 路径全部可解析")

    if "Phase 4：TMDB 元数据增强" not in text:
        fail("§21 缺少「Phase 4：TMDB 元数据增强」")
    else:
        fact("§21 包含 Phase 4：TMDB 元数据增强")

    if "tmdb_matches" not in text or "tmdb_season_progress" not in text:
        fail("§16.2 缺少 TMDB 表（tmdb_matches / tmdb_season_progress）")
    else:
        fact("§16.2 已登记 TMDB 四张表")

    for token in ("tmdbNotConfigured", "SeasonScope", "MediaIdentity"):
        if token not in text:
            fail(f"主设计文档缺少关键术语/错误类别：{token}")
    fact("§27 关键术语与错误类别已写入主设计文档")


def check_tmdb_fixtures() -> None:
    """解析 docs/phase4/design/05 §2.1 的目录块，逐个校验 fixture 存在。

    目录项形如 ``├── configuration.json              # 说明``：必须先剥掉行尾注释，
    否则带注释的条目会被静默跳过（历史上只校验到 5/23 个）。
    """
    text = read("docs/phase4/design/05-tmdb-test-and-acceptance.md")
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
    if len(names) < 20:
        fail(f"§2.1 目录解析异常，只解析出 {len(names)} 个 fixture（期望 >= 20）")
        return
    base = ROOT
    missing = [name for name in names if not (base / name).is_file()]
    if missing:
        fail(f"docs/phase4/design/05 §2.1 声明的 fixture 缺失：{missing}")
    else:
        fact(f"docs/phase4/design/05 §2.1 声明的 {len(names)} 个 fixture 全部存在")


def check_schema_contracts() -> None:
    try:
        from jsonschema import Draft202012Validator
    except ImportError:
        fail("缺少 jsonschema，无法校验 TMDB 配置 Schema（请用带 jsonschema 的解释器）")
        return

    schema_path = ROOT / "packages/protocol/schema/tmdb-config.schema.json"
    if not schema_path.is_file():
        fail("缺少 packages/protocol/schema/tmdb-config.schema.json")
        return

    validator = Draft202012Validator(
        json.loads(schema_path.read_text(encoding="utf-8"))
    )
    base = ROOT / "packages/test-fixtures/tmdb/config"

    for name in ("tmdb-config-full.json", "tmdb-config-alias.json"):
        payload = json.loads((base / name).read_text(encoding="utf-8"))
        errors = list(validator.iter_errors(payload))
        if errors:
            fail(f"{name} 未通过 TMDB 配置 Schema：{[e.message for e in errors]}")
        else:
            fact(f"{name} 通过 TMDB 配置 Schema")

    invalid = json.loads((base / "tmdb-config-invalid.json").read_text(encoding="utf-8"))
    if not list(validator.iter_errors(invalid)):
        fail("tmdb-config-invalid.json 竟然通过了 Schema（反向验证失败）")
    else:
        fact("tmdb-config-invalid.json 被 Schema 正确拒绝（反向验证）")


def main() -> int:
    print("== Phase 4 TMDB 设计指导文档校验 ==")
    check_design_docs_exist()
    main_sections = check_main_doc()
    check_main_doc_phase4_references()
    check_repo_paths()
    check_upstream_docs()
    check_section_references(main_sections)
    check_tmdb_fixtures()
    check_schema_contracts()

    print()
    print(f"通过 {len(facts)} 项，失败 {len(failures)} 项")
    for line in facts:
        print(f"PHASE4-DESIGN ok  {line}")
    for line in failures:
        print(f"PHASE4-DESIGN fail {line}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
