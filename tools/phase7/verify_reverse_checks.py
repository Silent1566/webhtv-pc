#!/usr/bin/env python3
"""Phase 7 反向验证门禁（`docs/phase7/design/04` §5、§6 的 G8）。

八项反向验证必须**可复现**，不能只写在证据文件的说明文字里：本脚本逐项
临时破坏一个契约，断言对应用例**确实失败**，然后无条件还原并校验字节一致。

| # | 破坏方式 | 必须失败的套件 |
| --- | --- | --- |
| 1 | `isGenuineEnd` 去掉 `duration <= 0` 检查 | `phase7_resume_gate_test.dart` |
| 2 | `_advanceInFlight` 守卫改为不生效 | `phase7_player_advance_test.dart` |
| 3 | 失败路径不回滚 `_request` | `phase7_player_advance_test.dart` |
| 4 | 三态判定把「TCP 通但 HTTP 无响应」归为 `networkUnreachable` | `phase7_keepalive_test.dart` |
| 5 | 退避序列改为恒定周期 | `phase7_realtime_core_test.dart` |
| 6 | 游标在部分失败时也推进 | `phase7_realtime_engine_test.dart` |
| 7 | `ai_config` 当对象读（不解 JSON 字符串） | `phase7_settings_mapping_test.dart` |
| 8 | 含凭据项默认参与实时同步 | `phase7_realtime_core_test.dart` |

**#1 与 #2 是本轮最容易悄悄写错的两处**（直接对应 `design/03` §3.3 的 D1/D2
缺陷），必须作为机器证据存在。

与 Phase 5 版的差异（都是踩出来的）
-----------------------------------
- **`/android/...` 与 `--puro-env` 一样从仓库根跑**，但 `flutter test` 必须在
  `apps/desktop-flutter` 下执行（`pubspec.yaml` 在那里）；
- **失败行判定**用 `[E]` 结尾，不按 `C:`/`.dart:` 子串筛（单套件运行时输出
  不带文件前缀，按路径筛会永远得到 0，证据行就成摆设）；
- 支持 `--only` 逐项排障，以及 `--keep` 保留破坏（**仅排障用**，正常跑完
  一定还原）。

用法：
    py -3 tools/phase7/verify_reverse_checks.py
    py -3 tools/phase7/verify_reverse_checks.py --only 6
    py -3 tools/phase7/verify_reverse_checks.py --puro-env webhtv

退出码：0 = 全部按预期失败并已还原；1 = 有项未按预期失败或还原失败。
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
    """一项反向验证：破坏什么、期望哪个套件失败。"""

    def __init__(self, number: int, name: str, path: Path, old: str, new: str,
                 test_file: str):
        self.number = number
        self.name = name
        self.path = path
        self.old = old
        self.new = new
        self.test_file = test_file


CHECKS = [
    Check(
        1,
        "genuine-end-duration-guard",
        APP / "lib/core/playback.dart",
        # `durationMs <= 0` 是「时长未知」的哨兵：去掉它，提前 EOF（duration=0）
        # 会被当成真播完，于是缓存耗尽就跳下一集（用户实测的痛点 D2）。
        old="  if (durationMs <= 0) return false;",
        new="  // 反向验证：去掉「时长未知」保护\n  if (durationMs < 0) return false;",
        test_file="test/phase7_resume_gate_test.dart",
    ),
    Check(
        2,
        "advance-in-flight-guard",
        APP / "lib/ui/player_page.dart",
        old="    if (_advanceInFlight) return;",
        new="    if (false) return; // 反向验证：去掉连播单次守卫（D1）",
        test_file="test/phase7_player_advance_test.dart",
    ),
    Check(
        3,
        "failure-rollback-request",
        APP / "lib/ui/player_page.dart",
        # 失败时若不把 `_request` 回滚到本次加载前的意图，续播上下文
        # （原集 + 原进度）就丢了，用户看到「上一集失败 → 已切到下一集」（D3）。
        old="        _request = intent;",
        new="        _request = _request; // 反向验证：失败不回滚续播上下文",
        test_file="test/phase7_player_advance_test.dart",
    ),
    Check(
        4,
        "probe-tcp-no-http-is-frozen",
        APP / "lib/core/realtime_sync.dart",
        # TCP 握手成功但 HTTP 无响应 = 进程被冻结。归成「网络不可达」会让
        # 用户去查 WiFi，而实际该去改安卓电池设置（`design/02` §4）。
        old=(
            "      case RealtimeProbeStep.tcpConnectedNoHttp:\n"
            "        return RealtimePeerState.peerFrozen;"
        ),
        new=(
            "      case RealtimeProbeStep.tcpConnectedNoHttp:\n"
            "        // 反向验证：把「冻结」误归为「网络不可达」\n"
            "        return RealtimePeerState.networkUnreachable;"
        ),
        test_file="test/phase7_keepalive_test.dart",
    ),
    Check(
        5,
        "backoff-constant",
        APP / "lib/core/realtime_sync.dart",
        old="int realtimeBackoffMultiplier(int consecutiveFailures) {\n  if (consecutiveFailures <= 1) return 1;",
        new=(
            "int realtimeBackoffMultiplier(int consecutiveFailures) {\n"
            "  return 1; // 反向验证：退避退化为恒定周期\n"
            "  // ignore: dead_code\n"
            "  if (consecutiveFailures <= 1) return 1;"
        ),
        test_file="test/phase7_realtime_core_test.dart",
    ),
    Check(
        6,
        "cursor-advance-on-partial",
        APP / "lib/services/realtime_sync_engine.dart",
        # 游标裁决只应发生在这一处；恒传 success 会让「部分失败」也推进游标，
        # 断线期间的增量从此永久丢失（`design/04` §5 #6）。
        old=(
            "    final decision = decideCursor(\n"
            "      currentCursor: _cursor,\n"
            "      outcome: outcome,"
        ),
        new=(
            "    final decision = decideCursor(\n"
            "      currentCursor: _cursor,\n"
            "      // 反向验证：部分失败也当作成功推进游标\n"
            "      outcome: RealtimeBatchOutcome.success,"
        ),
        test_file="test/phase7_realtime_engine_test.dart",
    ),
    Check(
        7,
        "ai-config-as-object",
        APP / "lib/core/android_sync.dart",
        # 安卓把 `ai_config` 以 **JSON 字符串**存进 `prefers`。当对象读会得到
        # `null`，表现为「设置同步后什么都没变」且不报任何错（T9 的反向验证 #7）。
        old=(
            "  Object? decoded = value;\n"
            "  if (decoded is String) {\n"
            "    final text = decoded.trim();"
        ),
        new=(
            "  Object? decoded = value;\n"
            "  // 反向验证：不解 JSON 字符串（当对象读）\n"
            "  if (false) {\n"
            "    final text = (decoded as String).trim();"
        ),
        test_file="test/phase7_settings_mapping_test.dart",
    ),
    Check(
        8,
        "sensitive-settings-default-on",
        APP / "lib/core/realtime_sync.dart",
        # 含凭据项默认关闭（P1/P3）：每 60 s 明文传一次 API Key 必须由用户
        # 显式开启。默认打开会让「实时同步」变成默认就把凭据发出去。
        old="  if (realtimeSensitiveSettingsKeys.contains(key)) return settingsEnabled;",
        new=(
            "  // 反向验证：含凭据项默认参与实时同步\n"
            "  if (realtimeSensitiveSettingsKeys.contains(key)) return true;"
        ),
        test_file="test/phase7_realtime_core_test.dart",
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
        help="只跑指定编号（逗号分隔，如 1,2,6），用于排障",
    )
    parser.add_argument(
        "--keep",
        action="store_true",
        help="保留破坏不还原（**仅排障用**；正常跑完一定还原）",
    )
    args = parser.parse_args()
    selected = {item.strip() for item in args.only.split(",") if item.strip()}
    checks = [
        check
        for check in CHECKS
        if not selected or str(check.number) in selected
    ]

    failures: list[str] = []
    facts: list[str] = []

    # 启动时先清理上次中断留下的残局。
    #
    # **为什么必须要这一步**：脚本被强杀（超时/关机/Ctrl-C）时 `finally` 不会跑，
    # 破坏版代码就会留在工作区，而下一次运行会因为「找不到待破坏片段」
    # 报一个完全不相关的错（还会把破坏版提交进去）。
    # 备份文件本身就是权威原版，直接拿它覆盖即可。
    for check in CHECKS:
        leftover = check.path.with_suffix(check.path.suffix + ".reverse-check.bak")
        if leftover.exists():
            shutil.copy2(leftover, check.path)
            leftover.unlink(missing_ok=True)
            facts.append(
                f"PHASE7-ACCEPT reverse-check leftover-restored path={check.path.name}"
            )

    before_status = _status_snapshot()

    for check in checks:
        label = f"#{check.number} {check.name}"
        if not check.path.exists():
            failures.append(f"{label}: 缺少源文件 {check.path}")
            continue
        original = check.path.read_text(encoding="utf-8")
        before = digest(check.path)
        if check.old not in original:
            failures.append(
                f"{label}: 未找到待破坏的代码片段（契约可能已改名，需同步本脚本）"
            )
            continue
        if original.count(check.old) != 1:
            failures.append(
                f"{label}: 待破坏片段出现 {original.count(check.old)} 次，无法唯一定位"
            )
            continue
        if not (APP / check.test_file).exists():
            failures.append(f"{label}: 缺少套件 {check.test_file}")
            continue

        backup = check.path.with_suffix(check.path.suffix + ".reverse-check.bak")
        shutil.copy2(check.path, backup)
        try:
            check.path.write_text(
                original.replace(check.old, check.new, 1), encoding="utf-8"
            )
            exit_code, output = run_tests(args.puro_env, check.test_file)
            if exit_code == 0:
                failures.append(
                    f"{label}: 破坏契约后用例仍全部通过"
                    f"（门禁未真正锁定该契约，套件={check.test_file}）"
                )
            else:
                # 失败行以 ` [E]` 结尾（单套件运行时不带文件前缀）。
                failed = [
                    line.strip()
                    for line in output.splitlines()
                    if line.strip().endswith("[E]")
                ]
                if not failed:
                    # 退出码非 0 但没有 `[E]` 行 → 多半是编译错误而不是断言失败。
                    # 那也证明不了契约被锁定，必须报出来。
                    failures.append(
                        f"{label}: 套件失败但找不到断言失败行"
                        f"（可能是编译错误而非契约失败）"
                    )
                else:
                    facts.append(
                        f"PHASE7-ACCEPT reverse-check #{check.number} "
                        f"name={check.name} expected-failure=ok "
                        f"test={check.test_file} failing-cases={len(failed)}"
                    )
        finally:
            if args.keep:
                print(
                    f"PHASE7-ACCEPT reverse-check #{check.number} "
                    f"KEEP-BROKEN path={check.path}（--keep，需手工还原）",
                    file=sys.stderr,
                )
            else:
                shutil.copy2(backup, check.path)
                backup.unlink(missing_ok=True)
                if digest(check.path) != before:
                    failures.append(f"{label}: 还原后文件内容不一致")

    if not args.keep:
        after = _status_snapshot()
        if after != before_status:
            failures.append(
                "反向验证改变了工作区状态（运行前后 git status 不一致）："
                f"before={sorted(before_status)[:5]} after={sorted(after)[:5]}"
            )

    for line in facts:
        print(line)
    if failures:
        print("PHASE7-ACCEPT reverse-check result=FAIL", file=sys.stderr)
        for item in failures:
            print(f"  - {item}", file=sys.stderr)
        return 1
    print(
        f"PHASE7-ACCEPT reverse-check result=PASS checks={len(checks)} "
        f"restored={0 if args.keep else len(checks)} "
        f"working-tree-clean={not args.keep}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
