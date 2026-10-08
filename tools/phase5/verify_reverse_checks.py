#!/usr/bin/env python3
"""Phase 5 反向验证门禁（`docs/phase5/design/03` §4.3）。

三项反向验证必须**可复现**，不能只写在证据文件的说明文字里：本脚本逐项
临时破坏一个契约，断言对应用例**确实失败**，然后无条件还原并校验工作区干净。

| # | 破坏方式 | 必须失败的用例 |
| --- | --- | --- |
| 1 | 主机一致性校验改为无条件放行 | `phase5_android_bridge_test.dart` |
| 2 | `position` 映射加 `/1000` 换算 | `phase5_android_sync_test.dart` |
| 3 | 合并裁决改为"远端总是胜" | `phase5_android_sync_test.dart` |
| 4 | 哨兵值不做过滤 | `phase5_android_sync_test.dart` |
| 5 | 删除标记检查被移除 | `phase5_android_sync_test.dart` |
| 6 | `SyncOptions` 的 `settings` 默认改为 `true` | `phase5_android_sync_test.dart` |

用法：
    py -3 tools/phase5/verify_reverse_checks.py [--puro-env webhtv]

退出码：0 = 六项都按预期失败并已还原；1 = 有项未按预期失败或还原失败。

其中 #2（毫秒换算）与 #5（删除不复活）是本阶段最容易**悄悄写错**的两处
（`design/03` §4.3 原话），也是最需要机器证据的两条。
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
    """一项反向验证：破坏什么、期望哪个用例失败。"""

    def __init__(self, name: str, path: Path, old: str, new: str, test_file: str):
        self.name = name
        self.path = path
        self.old = old
        self.new = new
        self.test_file = test_file


CHECKS = [
    Check(
        name="host-consistency",
        path=APP / "lib/core/android_bridge.dart",
        old="  if (siteHostPort == expectedHostPort) return site;",
        new="  return site; // 反向验证：无条件放行主机校验",
        test_file="test/phase5_android_bridge_test.dart",
    ),
    Check(
        name="millisecond-passthrough",
        path=APP / "lib/core/android_sync.dart",
        old="      positionMs: asInt(map['position']) ?? 0,",
        new="      positionMs: (asInt(map['position']) ?? 0) ~/ 1000,"
        " // 反向验证：误加秒换算",
        test_file="test/phase5_android_sync_test.dart",
    ),
    Check(
        name="legacy-wins-merge",
        path=APP / "lib/core/android_sync.dart",
        old=(
            "  return const SyncMergeDecision(SyncMergeAction.skip, "
            "'本地记录更新（旧不覆盖新）');"
        ),
        new=(
            "  return const SyncMergeDecision(SyncMergeAction.upsert, "
            "'反向验证：远端总是胜');"
        ),
        test_file="test/phase5_android_sync_test.dart",
    ),
    Check(
        name="sentinel-filter",
        path=APP / "lib/core/android_sync.dart",
        old="      openingMs: normalizeAndroidMs(map['opening']),",
        new="      openingMs: asInt(map['opening']), // 反向验证：不过滤哨兵值",
        test_file="test/phase5_android_sync_test.dart",
    ),
    Check(
        name="deletion-tombstone",
        path=APP / "lib/core/android_sync.dart",
        old="    if (localDeletedAt != null && incoming.updatedAt < localDeletedAt) {",
        new="    if (false) { // 反向验证：移除删除标记检查",
        test_file="test/phase5_android_sync_test.dart",
    ),
    Check(
        name="settings-default-off",
        path=APP / "lib/core/android_sync.dart",
        old="    this.settings = false,",
        new="    this.settings = true, // 反向验证：默认同步含凭据的设置",
        test_file="test/phase5_android_sync_test.dart",
    ),
]


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_tests(puro_env: str, test_file: str) -> tuple[int, str]:
    completed = subprocess.run(
        ["puro", "-e", puro_env, "-p", ".", "flutter", "test", test_file],
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
    parser.add_argument(
        "--only",
        default="",
        help="只跑指定名字的反向验证项（逗号分隔），用于排障",
    )
    args = parser.parse_args()
    selected = {name for name in args.only.split(",") if name}
    checks = [check for check in CHECKS if not selected or check.name in selected]

    failures: list[str] = []
    facts: list[str] = []

    # 运行前快照：用于断言「反向验证没有留下自己的残留」。
    before_status = _status_snapshot()

    for check in checks:
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
        if original.count(check.old) != 1:
            failures.append(
                f"{check.name}: 待破坏片段在源文件中出现 "
                f"{original.count(check.old)} 次，无法唯一定位"
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
                # flutter test 的失败行以 ` [E]` 结尾，形如
                # `00:04 +4 -1: 组名 用例名 [E]`（单套件运行时**不带**文件前缀，
                # 因此不能按 `C:` 行首或 `.dart:` 子串筛——那会永远得到 0，
                # 证据行就成了摆设）。
                failed = [
                    line.strip()
                    for line in output.splitlines()
                    if line.strip().endswith("[E]")
                ]
                facts.append(
                    f"PHASE5-ACCEPT reverse-check {check.name} "
                    f"expected-failure=ok test={check.test_file} "
                    f"failing-cases={len(failed)}"
                )
        finally:
            # 无条件还原，并校验字节级一致。
            shutil.copy2(backup, check.path)
            backup.unlink(missing_ok=True)
            if digest(check.path) != before:
                failures.append(f"{check.name}: 还原后文件内容不一致")

    # 反向验证不得留下**自己造成的**残留。
    #
    # 判定方式：对比「运行前快照」与「运行后现状」，而不是要求工作区绝对干净
    # ——本脚本既要在干净检出上跑，也要在开发者带着未提交改动时跑；
    # 要求绝对干净会把「本来就有的改动」误报成残留。
    # 「被破坏过的文件必须字节级还原」已在上面的循环里逐项断言。
    after = _status_snapshot()
    if after != before_status:
        failures.append(
            "反向验证改变了工作区状态（运行前后 git status 不一致）："
            f"before={sorted(before_status)[:5]} after={sorted(after)[:5]}"
        )

    for line in facts:
        print(line)
    if failures:
        print("PHASE5-ACCEPT reverse-check result=FAIL", file=sys.stderr)
        for item in failures:
            print(f"  - {item}", file=sys.stderr)
        return 1
    print(
        f"PHASE5-ACCEPT reverse-check result=PASS checks={len(checks)} "
        f"restored={len(checks)} working-tree-clean=true"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
