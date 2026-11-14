#!/usr/bin/env python3
"""Phase 7 实时同步/身份解析脱敏门禁（`docs/phase7/design/01` §8、G9）。

三层检查（与 Phase 5 的 `verify_bridge_redaction.py` 同构）：

1. **静态**：实时同步与身份解析的实现文件里，日志不得带出
   token 原文、完整局域网地址、片名、拉取载荷；
2. **用例在位**：脱敏断言用例必须存在，否则"实现了"没有证据；
3. **产物**：`docs/phase7/evidence/**` 里不得出现 fixture token 原文、
   设备指纹或 API Key 值——证据文件是最容易泄漏的地方（要贴给用户看）。

为什么 Phase 7 需要单独一道
--------------------------
本阶段新增了三个高风险面（Phase 5 都没有）：
- **`pullToken`**：路径 B 的鉴权凭据，一旦进日志就等于把端点公开；
- **对端地址**：心跳/轮询日志天然想写完整 `http://ip:port`，
  而 `design/02` §7 要求只留前两段；
- **身份键**：`interfaceKey` / `strictAddressKeys` 是 URL 的哈希，
  虽不可逆，但它是"同一个站源"的稳定指纹，不该在日志里成串出现。

用法：
    py -3 tools/phase7/verify_realtime_redaction.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "desktop-flutter"
EVIDENCE = ROOT / "docs" / "phase7" / "evidence"

# 实时同步/身份解析的实现文件：这里的日志语句要逐条检查。
SOURCE_FILES = [
    APP / "lib" / "core" / "realtime_sync.dart",
    APP / "lib" / "core" / "playback_identity.dart",
    APP / "lib" / "services" / "realtime_sync_engine.dart",
    APP / "lib" / "services" / "android_read_client.dart",
    APP / "lib" / "services" / "sync_server.dart",
    APP / "lib" / "state" / "sync_state.dart",
]

# 禁止出现在日志调用实参里的敏感标识符。
FORBIDDEN_LOG_ARGUMENTS = [
    "vodName",
    "episodeName",
    "episodeUrl",
    "pullToken",
    "_realtimePullToken",
    "strictAddressKeys",
    "endpointMatchKeys",
    "hostMatchKeys",
    "legacyConfigKeys",
    "configJson",
    "deviceJson",
]

# 日志调用的形态：`log.info(...)` / `_logWarning(...)` 等。
LOG_CALL = re.compile(r"(?:log|_log)?\.?(?:info|warning|error|debug)\s*\(", re.I)

# 必须存在的脱敏断言用例（字符串出现即视为存在）。
REQUIRED_ASSERTIONS = [
    (APP / "test" / "phase5_sync_server_test.dart", "脱敏"),
    (APP / "test" / "phase7_pull_endpoint_test.dart", "token"),
    (APP / "test" / "phase7_identity_resolve_test.dart", "invalid"),
]

# 证据文件里绝不能出现的内容（token/凭据的**值**，不是键名）。
EVIDENCE_FORBIDDEN = [
    ("pc-pull-token-secret", "pull token 值"),
    ("fixture-device-uuid", "设备 uuid 原文"),
    ("fixture0", "设备 serial 原文"),
    ("00:00:00:00:00:00", "设备 wlan 原文"),
    ("sk-live-", "API Key 值"),
]

# 允许出现在日志里的脱敏形态（出现即说明用了脱敏 helper）。
MASK_HELPERS = ("redactUrl", "_maskAddress", "_maskUuid", "maskedUuid")


def check_static() -> list[str]:
    failures: list[str] = []
    for path in SOURCE_FILES:
        if not path.exists():
            failures.append(f"缺少源文件：{path.relative_to(ROOT)}")
            continue
        text = path.read_text(encoding="utf-8")
        lines = text.splitlines()
        for number, line in enumerate(lines, 1):
            stripped = line.strip()
            if stripped.startswith(("//", "///")):
                continue
            if not LOG_CALL.search(line):
                continue
            for identifier in FORBIDDEN_LOG_ARGUMENTS:
                # `_maskAddress(pullToken)` 这类"先脱敏再输出"不算泄漏，
                # 只要标识符出现在某个脱敏 helper 的括号里就放行。
                if not re.search(rf"\b{identifier}\b", line):
                    continue
                masked = any(
                    f"({identifier}" not in line
                    and re.search(rf"{helper}\s*\([^)]*\b{identifier}\b", line)
                    for helper in MASK_HELPERS
                )
                if masked:
                    continue
                failures.append(
                    f"{path.relative_to(ROOT)}:{number} 日志实参含敏感标识符 "
                    f"{identifier}（需经脱敏 helper）"
                )
    return failures


def check_assertions() -> list[str]:
    failures: list[str] = []
    for path, token in REQUIRED_ASSERTIONS:
        if not path.exists():
            failures.append(f"缺少脱敏断言套件：{path.relative_to(ROOT)}")
            continue
        if token not in path.read_text(encoding="utf-8"):
            failures.append(
                f"{path.relative_to(ROOT)} 缺少含「{token}」的脱敏断言"
            )
    return failures


def check_evidence() -> list[str]:
    if not EVIDENCE.is_dir():
        # 证据目录还没生成时不算失败（由 T14 产出）。
        print("PHASE7-REDACTION note=evidence-dir-missing（尚无证据文件）")
        return []
    failures: list[str] = []
    for path in sorted(EVIDENCE.rglob("*")):
        if not path.is_file():
            continue
        if path.suffix.lower() in {".png", ".jpg", ".jpeg", ".webp"}:
            continue  # 截图由人工审阅，不做文本扫描
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError as error:
            failures.append(f"无法读取证据文件 {path.name}: {error}")
            continue
        for needle, label in EVIDENCE_FORBIDDEN:
            if needle in text:
                failures.append(
                    f"证据文件 {path.relative_to(ROOT)} 含{label}（{needle}）"
                )
    return failures


def main() -> int:
    failures: list[str] = []
    failures += check_static()
    failures += check_assertions()
    failures += check_evidence()

    if failures:
        print("PHASE7-REDACTION result=FAIL", file=sys.stderr)
        for item in failures:
            print(f"  - {item}", file=sys.stderr)
        return 1
    print(
        "PHASE7-REDACTION result=PASS "
        f"sources={len(SOURCE_FILES)} assertions={len(REQUIRED_ASSERTIONS)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
