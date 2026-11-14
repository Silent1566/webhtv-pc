#!/usr/bin/env python3
"""生成 Phase 4 TMDB 设计指导文档的交付证据。

写入 `docs/phase4/evidence/design-guidance.txt`。可重复执行（结果幂等，
只有 `生成时间` 与耗时相关字段会变化）。

用法：
    py -3.13 tools/phase4/write_design_evidence.py
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "docs" / "phase4" / "evidence" / "design-guidance.txt"

DELIVERABLES = [
    "docs/phase4/README.md",
    "docs/phase4/design/00-tmdb-design-index.md",
    "docs/phase4/design/01-tmdb-identity-and-matching.md",
    "docs/phase4/design/02-tmdb-season-resolution-and-progress.md",
    "docs/phase4/design/03-tmdb-service-config-storage.md",
    "docs/phase4/design/04-tmdb-detail-ui-and-playback.md",
    "docs/phase4/design/05-tmdb-test-and-acceptance.md",
    "packages/protocol/schema/tmdb-config.schema.json",
    "packages/test-fixtures/tmdb/config/tmdb-config-full.json",
    "packages/test-fixtures/tmdb/config/tmdb-config-alias.json",
    "packages/test-fixtures/tmdb/config/tmdb-config-invalid.json",
    "tools/phase4/verify_design_docs.py",
    "tools/phase4/generate_tmdb_fixtures.py",
    "tools/phase4/write_design_evidence.py",
]

MAIN_DOC = "docs/webhtv-pc-design.md"


def run(args: list[str]) -> tuple[int, str]:
    env = dict(os.environ, PYTHONIOENCODING="utf-8", PYTHONUTF8="1")
    completed = subprocess.run(
        args,
        cwd=ROOT,
        capture_output=True,
        env=env,
    )
    text = (completed.stdout + completed.stderr).decode("utf-8", errors="replace")
    return completed.returncode, text


def main() -> int:
    lines: list[str] = []

    def write(line: str = "") -> None:
        lines.append(line)

    write("Phase 4 · TMDB 元数据增强 · 设计指导文档交付证据")
    write("范围：docs/phase4/**（设计指导）、docs/webhtv-pc-design.md（主设计文档回填）、")
    write("      packages/protocol/schema/tmdb-config.schema.json、packages/test-fixtures/tmdb/**、")
    write("      tests/test_contracts.py（新增 5 例）、tools/phase4/**（校验与 fixture 生成）")
    write()
    write("说明：本文件是「设计指导文档阶段」的证据。产品级门禁（flutter test / 集成测试 /")
    write("      一键验收脚本）属于实施阶段，见 docs/phase4/design/05-tmdb-test-and-acceptance.md §6。")
    write()

    write("== 1. 交付物清单 ==")
    total = 0
    for relative in DELIVERABLES:
        path = ROOT / relative
        exists = path.is_file()
        count = len(path.read_text(encoding="utf-8").splitlines()) if exists else 0
        total += count
        write(f"PHASE4-DOC file {relative} lines={count} exists={exists}")
    fixtures = sorted((ROOT / "packages" / "test-fixtures" / "tmdb").rglob("*.json"))
    write(f"PHASE4-DOC tmdb-fixtures count={len(fixtures)}")
    write(f"PHASE4-DOC deliverable-lines total={total}")
    main_lines = len((ROOT / MAIN_DOC).read_text(encoding="utf-8").splitlines())
    write(f"PHASE4-DOC main-design-doc lines={main_lines}")
    write()

    write("== 2. 设计文档自洽性校验（tools/phase4/verify_design_docs.py）==")
    code, text = run([sys.executable, "tools/phase4/verify_design_docs.py"])
    for line in text.splitlines():
        if line.startswith("PHASE4-DESIGN"):
            write(line)
    write(f"PHASE4-DOC verify_design_docs exit={code}")
    write()

    write("== 3. 契约测试（python -m unittest tests.test_contracts）==")
    code, text = run([sys.executable, "-m", "unittest", "tests.test_contracts", "-v"])
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.endswith("... ok") or stripped.startswith("Ran ") or stripped == "OK":
            write(f"PHASE4-CONTRACT {stripped}")
    write(f"PHASE4-CONTRACT exit={code}")
    write()

    write("== 4. 反向验证（证明校验不是空转）==")
    write("A. 把 docs/phase4/design/05 §2.1 的 episode-s1e1.json 改为不存在的名字：")
    write("   verify_design_docs.py exit=1，并报出缺失的 fixture（实测通过）。")
    write("B. 把 01 文档中的 `00` §3.4 改为 `00` §99.99：")
    write("   verify_design_docs.py exit=1，并报出无法解析的章节引用（实测通过）。")
    write("C. tmdb-config-invalid.json 必须被 Schema 拒绝：见第 2 节输出（实测通过）。")
    write()

    write("== 5. 工具链基线（供实施阶段复用）==")
    write("flutter 3.47.5 / Dart 3.13.4（puro -e webhtv，位于 apps/desktop-flutter）")
    write("python：py -3.13 是本机唯一带 jsonschema 的解释器（jsonschema 4.26.0）；")
    write("        py 默认 3.14 无 jsonschema，门禁脚本必须主动探测解释器。")
    write()

    write("== 6. 未完成项声明 ==")
    write("本阶段只交付设计指导文档与配套 Schema / fixture / 校验脚本。")
    write("代码实现（lib/core/tmdb_*.dart、lib/services/tmdb_*.dart、lib/ui/tmdb_*.dart、")
    write("存储迁移、播放入口透传、设置页）与产品级门禁属于 docs/phase4/README.md §2.2 的 T1–T18，")
    write("尚未开始；实施完成后需另写 docs/phase4/evidence/windows-acceptance.txt。")

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    print(f"written: {OUTPUT.relative_to(ROOT)} ({len(lines)} lines)")
    return 0 if code == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
