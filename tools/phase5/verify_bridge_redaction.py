#!/usr/bin/env python3
"""桥接/同步脱敏门禁（`docs/phase5/design/02` §7，G9）。

三层检查，缺一层这道门禁就只是摆设：

1. **静态**：桥接与同步的实现文件里不得把片名、图片地址、`config` JSON、
   完整设备 uuid 交给日志；
2. **用例在位**：对应的脱敏断言用例必须存在（否则"实现了"没有证据）；
3. **产物**：`docs/phase5/evidence/**` 里不得出现 fixture 的设备指纹原文、
   片名或 `tmdb_config` 凭据——证据文件是最容易泄漏的地方（要贴给用户看）。

用法：
    py -3 tools/phase5/verify_bridge_redaction.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "desktop-flutter"
EVIDENCE = ROOT / "docs" / "phase5" / "evidence"

# 桥接/同步的实现文件：这里的日志语句要逐条检查。
SOURCE_FILES = [
    APP / "lib" / "core" / "android_bridge.dart",
    APP / "lib" / "core" / "android_sync.dart",
    APP / "lib" / "services" / "android_bridge_service.dart",
    APP / "lib" / "services" / "sync_server.dart",
    APP / "lib" / "services" / "sync_client.dart",
    APP / "lib" / "state" / "sync_state.dart",
]

# 禁止出现在日志调用实参里的敏感标识符。
FORBIDDEN_LOG_ARGUMENTS = [
    "vodName",
    "episodeName",
    "episodeUrl",
    "reportedIp",
    "configJson",
    "items.map",
    "targets",
]

# 日志调用的形态：`log.info(...)` / `_logInfo(...)` / `_logWarning(...)`。
LOG_CALL = re.compile(r"(?:log|_log)?\.?(?:info|warning|error|debug)\s*\(", re.I)

# 必须存在的脱敏断言用例（字符串出现即视为存在）。
REQUIRED_ASSERTIONS = [
    (APP / "test" / "phase5_android_bridge_service_test.dart", "脱敏"),
    (APP / "test" / "phase5_sync_server_test.dart", "日志不含片名"),
    (APP / "test" / "phase5_android_sync_test.dart", "片名/图片/播放地址不出现在任何描述输出中"),
]

# 证据文件里绝不能出现的内容：设备指纹原文与真实凭据**值**。
#
# 为什么只列"值"不列键名（例如 `apiKey`）：键名不是秘密，而验收日志会如实
# 记录门禁输出，任何提到键名的诊断文本都会把这道门禁变成噪声源。
# 凭据本身是否泄漏由 Phase 4 的 `verify_tmdb_redaction.py` 负责（它扫的是源码）。
EVIDENCE_FORBIDDEN = [
    ("fixture-device-uuid", "设备 uuid 原文"),
    ("fixture0", "设备 serial 原文"),
    ("00:00:00:00:00:00", "设备 wlan 原文"),
    ("secret-key", "凭据值"),
]


def check_static() -> list[str]:
    """静态检查日志调用实参。"""
    failures: list[str] = []
    for path in SOURCE_FILES:
        if not path.exists():
            failures.append(f"缺少源文件：{path.relative_to(ROOT)}")
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith(("//", "///")):
                continue
            if not LOG_CALL.search(stripped):
                continue
            for argument in FORBIDDEN_LOG_ARGUMENTS:
                if argument in stripped:
                    failures.append(
                        f"{path.relative_to(ROOT)}:{number} 日志里出现敏感参数 "
                        f"{argument!r}：{stripped[:110]}"
                    )
    return failures


def check_assertions() -> list[str]:
    """脱敏断言用例必须在位。"""
    failures: list[str] = []
    for path, marker in REQUIRED_ASSERTIONS:
        if not path.exists():
            failures.append(f"缺少脱敏用例文件：{path.relative_to(ROOT)}")
            continue
        if marker not in path.read_text(encoding="utf-8"):
            failures.append(
                f"{path.relative_to(ROOT)} 缺少脱敏断言标记 {marker!r}"
            )
    return failures


def check_evidence() -> tuple[list[str], int]:
    """证据文件不得含指纹/凭据原文（存在证据时才检查）。"""
    failures: list[str] = []
    files = sorted(EVIDENCE.glob("**/*")) if EVIDENCE.exists() else []
    text_files = [
        path for path in files if path.is_file() and path.suffix.lower() in (".txt", ".json", ".md")
    ]
    for path in text_files:
        text = path.read_text(encoding="utf-8", errors="replace")
        for needle, label in EVIDENCE_FORBIDDEN:
            if needle in text:
                # 报告时**不回显**敏感字面量：验收日志会记录本门禁的输出，
                # 回显会把字面量写进日志，下一次扫描又抓到它——自指循环
                # （实测踩过：日志因此一直失败，而真正的泄漏早已修掉）。
                failures.append(
                    f"{path.relative_to(ROOT)} 出现{label}——证据文件会交给用户看，"
                    "请改为只输出计数/字段名，不要输出指纹或凭据原文"
                )
    return failures, len(text_files)


def main() -> int:
    static = check_static()
    assertions = check_assertions()
    evidence, evidence_count = check_evidence()

    for path in SOURCE_FILES:
        if path.exists():
            print(f"PHASE5-ACCEPT redact source={path.relative_to(ROOT)} checked=true")
    for path, marker in REQUIRED_ASSERTIONS:
        print(
            f"PHASE5-ACCEPT redact assertion={path.relative_to(ROOT)} "
            f"present={path.exists() and marker in path.read_text(encoding='utf-8')}"
        )
    print(f"PHASE5-ACCEPT redact evidence-files={evidence_count} checked=true")

    failures = static + assertions + evidence
    if failures:
        print("PHASE5-ACCEPT redact result=FAIL", file=sys.stderr)
        for item in failures:
            print(f"  - {item}", file=sys.stderr)
        return 1
    print(
        "PHASE5-ACCEPT redact result=PASS "
        f"sources={len(SOURCE_FILES)} assertions={len(REQUIRED_ASSERTIONS)} "
        f"evidence={evidence_count}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
