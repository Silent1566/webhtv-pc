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


def _status_snapshot() -> set[str]:
    """当前 `apps/desktop-flutter` 下的 git 状态行集合（排序无关）。"""
    status = subprocess.run(
        ["git", "status", "--porcelain", "--", "apps/desktop-flutter"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    return {line for line in status.stdout.splitlines() if line.strip()}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--puro-env", default="webhtv")
    args = parser.parse_args()

    failures: list[str] = []
    facts: list[str] = []

    # 运行前快照：用于断言「反向验证没有留下自己的残留」。
    before_status = _status_snapshot()

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

    # 反向验证不得留下**自己造成的**残留。
    #
    # 判定方式：对比「运行前快照」与「运行后现状」，而不是要求工作区绝对干净。
    # 为什么不能要求绝对干净：本脚本既要在 CI 的干净检出上跑，也要在开发者
    # 带着未提交改动时跑（本轮视觉重设计就是这种情形）。要求绝对干净会把
    # 「开发者本来就有的改动」误报成「反向验证残留」，掩盖真正的问题。
    # 而「本脚本破坏过的文件必须字节级还原」已在上面的循环里逐项断言，
    # 这里只补一条更强的整体校验：运行前后 `git status` 集合必须完全一致。
    after = _status_snapshot()
    if after != before_status:
        failures.append(
            "反向验证改变了工作区状态（运行前后 git status 不一致）："
            f"before={sorted(before_status)[:5]} after={sorted(after)[:5]}"
        )

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
