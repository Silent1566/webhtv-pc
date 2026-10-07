#!/usr/bin/env python3
"""Phase 4 反向验证门禁（`docs/phase4/design/05` §10）。

三项反向验证必须**可复现**，不能只写在证据文件的说明文字里：本脚本逐项
临时破坏一个契约，断言对应用例**确实失败**，然后无条件还原并校验工作区干净。

| # | 破坏方式 | 必须失败的用例 |
| --- | --- | --- |
| 1 | 未知季度的元数据守卫改为不拦截（等价上游 `[1, 0]` 兜底） | `phase4_tmdb_episode_metadata_test.dart` |
| 2 | 分季惩罚 `-240` 改为 `0` | `phase4_tmdb_match_policy_test.dart` |
| 3 | 去掉 `normalizeBrackets` 的全角映射 | `phase4_tmdb_site_policy_test.dart` |

用法：
    py -3 tools/phase4/verify_reverse_checks.py [--puro-env webhtv]

退出码：0 = 三项都按预期失败并已还原；1 = 有项未按预期失败或还原失败。
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "desktop-flutter"


class Check:
    def __init__(self, name: str, path: Path, old: str, new: str, test_file: str):
        self.name = name
        self.path = path
        self.old = old
        self.new = new
        self.test_file = test_file


CHECKS = [
    Check(
        name="unknown-season-guard",
        path=APP / "lib/services/tmdb_enrichment_service.dart",
        old=(
            "    // 1. 未知季度 → 不应用（`02` §9.1 硬约束）\n"
            "    if (request.seasonNumber < 0) {"
        ),
        new=(
            "    // 反向验证：临时改回上游 [1, 0] 兜底\n"
            "    if (request.seasonNumber < 0 && request.seasonNumber != -1) {"
        ),
        test_file="test/phase4_tmdb_episode_metadata_test.dart",
    ),
    Check(
        name="split-season-penalty",
        path=APP / "lib/core/tmdb_title.dart",
        old="  return allowsSplitSeasonVariant(sourceText) ? 0 : -240;",
        new="  return 0; // 反向验证：去掉分季惩罚",
        test_file="test/phase4_tmdb_match_policy_test.dart",
    ),
    Check(
        name="bracket-normalize",
        path=APP / "lib/core/tmdb_config.dart",
        old="String normalizeBrackets(String value) => value\n",
        new="String normalizeBrackets(String value) => value; // 反向验证：去掉括号归一\n",
        test_file="test/phase4_tmdb_site_policy_test.dart",
    ),
]


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_tests(puro_env: str, test_file: str) -> tuple[int, str]:
    completed = subprocess.run(
        [
            "puro",
            "-e",
            puro_env,
            "-p",
            ".",
            "flutter",
            "test",
            test_file,
        ],
        cwd=APP,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    return completed.returncode, (completed.stdout or "") + (completed.stderr or "")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--puro-env", default="webhtv")
    args = parser.parse_args()

    failures: list[str] = []
    facts: list[str] = []

    for check in CHECKS:
        if not check.path.exists():
            failures.append(f"{check.name}: 缺少源文件 {check.path}")
            continue
        original = check.path.read_text(encoding="utf-8")
        before = digest(check.path)
        if check.old not in original:
            failures.append(
                f"{check.name}: 未找到待破坏的代码片段（契约可能已改名，需同步本脚本）"
            )
            continue

        # 备份到内存与磁盘双份：磁盘备份用于异常路径下的兜底还原。
        backup = check.path.with_suffix(check.path.suffix + ".reverse-check.bak")
        shutil.copy2(check.path, backup)
        try:
            check.path.write_text(
                original.replace(check.old, check.new, 1), encoding="utf-8"
            )
            exit_code, output = run_tests(args.puro_env, check.test_file)
            if exit_code == 0:
                failures.append(
                    f"{check.name}: 破坏契约后用例仍全部通过（门禁未真正锁定该契约）"
                )
            else:
                failed = [
                    line.strip()
                    for line in output.splitlines()
                    if line.strip().startswith("C:") and ".dart:" in line
                ]
                facts.append(
                    f"PHASE4-ACCEPT reverse-check {check.name} "
                    f"expected-failure=ok test={check.test_file} "
                    f"failing-suites={len(set(failed))}"
                )
        finally:
            # 无条件还原，并校验字节级一致。
            shutil.copy2(backup, check.path)
            backup.unlink(missing_ok=True)
            if digest(check.path) != before:
                failures.append(f"{check.name}: 还原后文件内容不一致")

    # 工作区必须干净（不能把破坏后的文件留进仓库）。
    status = subprocess.run(
        ["git", "status", "--porcelain", "--", "apps/desktop-flutter"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    dirty = [line for line in status.stdout.splitlines() if line.strip()]
    if dirty:
        failures.append(f"工作区不干净（反向验证残留）：{dirty[:5]}")

    for line in facts:
        print(line)
    if failures:
        print("PHASE4-ACCEPT reverse-check result=FAIL", file=sys.stderr)
        for item in failures:
            print(f"  - {item}", file=sys.stderr)
        return 1
    print(
        f"PHASE4-ACCEPT reverse-check result=PASS checks={len(CHECKS)} "
        f"restored={len(CHECKS)} working-tree-clean=true"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
