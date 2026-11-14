#!/usr/bin/env python3
"""TMDB 凭据脱敏校验（`docs/phase4/design/05` §7.3）。

发布门禁（对齐主设计文档 §22.5 第 3 项）：**日志与诊断导出中不得出现凭据原文**。

做法（不依赖真实网络与真实应用运行）：

1. 读取 `tools/phase4/fixtures/tmdb-credentials.sample.json` 中的示例凭据；
2. 扫描**会产生日志 / 诊断 / 交付产物**的路径，断言示例凭据原文不出现；
3. 扫描生产代码，断言不存在明文 `api_key=<字面量>` 的日志拼接；
4. 正向断言：脱敏实现与演示必须存在（避免「删掉脱敏」也算通过）。

**不扫** `test/` 与 `docs/phase4/design/` 的凭据原文：它们有意包含
`sk-test-…` 之类的假凭据，用来验证脱敏行为与展示脱敏结果，本身不是产物。

用法：
    py -3 tools/phase4/verify_tmdb_redaction.py

退出码：0 = 通过；1 = 有泄露（失败项打印在 stderr）。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SAMPLE = ROOT / "tools" / "phase4" / "fixtures" / "tmdb-credentials.sample.json"

# 需要扫描**凭据原文**的路径（相对仓库根）：只扫会产生产物/日志的位置。
SECRET_SCAN_PATHS = [
    "apps/desktop-flutter/lib",
    "docs/phase4/evidence",
    ".local/tmp",
]

# 生产代码中不得出现明文 `api_key=<字面量>` 的日志拼接。
API_KEY_LOG_SCAN_PATHS = [
    "apps/desktop-flutter/lib",
]

SKIP_SUFFIXES = (
    ".png", ".jpg", ".jpeg", ".gif", ".ico", ".exe",
    ".jar", ".dll", ".so", ".bin",
)


def redact(value: str) -> str:
    """与 Dart `redactCredential` 完全一致的语义：只保留末 4 位。"""
    text = (value or "").strip()
    if not text:
        return ""
    if len(text) <= 4:
        return "****"
    return "****" + text[-4:]


def scan_secrets(path: Path, secrets: list[str]) -> list[str]:
    failures: list[str] = []
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError as error:
        return [f"无法读取 {path}: {error}"]
    for secret in secrets:
        if secret and secret in text:
            failures.append(
                f"{path.relative_to(ROOT)} 出现凭据原文（前 4 位 {secret[:4]}…）"
            )
    return failures


def scan_api_key_logs(path: Path) -> list[str]:
    """生产代码里不得把 `api_key` 明文拼进日志。"""
    failures: list[str] = []
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return failures
    for match in re.finditer(r"api_key=([^\s&'\"]+)", text):
        value = match.group(1)
        # 允许脱敏/占位/插值形态。
        if value.startswith(("****", "<", "$", "{", "redacted")):
            continue
        if "$" in value:
            continue
        if value in ("''", '""'):
            continue
        failures.append(
            f"{path.relative_to(ROOT)} 出现明文 api_key=…（长度 {len(value)}）"
        )
    return failures


def assert_redaction_demonstrated(failures: list[str]) -> None:
    """正向断言：脱敏实现与演示必须存在。"""
    config_source = (
        ROOT / "apps/desktop-flutter/lib/core/tmdb_config.dart"
    ).read_text(encoding="utf-8", errors="ignore")
    if "redactCredential" not in config_source:
        failures.append("tmdb_config.dart 缺少 redactCredential 实现")

    app_state = (
        ROOT / "apps/desktop-flutter/lib/state/app_state.dart"
    ).read_text(encoding="utf-8", errors="ignore")
    if not re.search(r"redacted(ApiKey|AccessToken)", app_state):
        failures.append("app_state.dart 的 TMDB 设置日志未使用脱敏值")

    config_test = ROOT / "apps/desktop-flutter/test/phase4_tmdb_config_test.dart"
    if config_test.exists():
        text = config_test.read_text(encoding="utf-8", errors="ignore")
        if "redacted" not in text.lower():
            failures.append("phase4_tmdb_config_test.dart 未断言脱敏结果")

    design_doc = ROOT / "docs/phase4/design/05-tmdb-test-and-acceptance.md"
    if design_doc.exists():
        text = design_doc.read_text(encoding="utf-8", errors="ignore")
        if "****7890" not in text:
            failures.append("design/05 未记录脱敏后的凭据形态（****7890）")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--sample",
        default=str(SAMPLE),
        help="示例凭据文件（默认 tools/phase4/fixtures/tmdb-credentials.sample.json）",
    )
    args = parser.parse_args()

    sample_path = Path(args.sample)
    if not sample_path.exists():
        print(
            f"PHASE4-ACCEPT tmdb-redaction FAIL 缺少样本文件 {sample_path}",
            file=sys.stderr,
        )
        return 1

    sample = json.loads(sample_path.read_text(encoding="utf-8"))
    api_key = str(sample.get("apiKey", ""))
    access_token = str(sample.get("accessToken", ""))
    if not api_key and not access_token:
        print(
            "PHASE4-ACCEPT tmdb-redaction FAIL 样本文件缺少 apiKey/accessToken",
            file=sys.stderr,
        )
        return 1

    secrets = [api_key, access_token]
    failures: list[str] = []
    scanned = 0

    for relative in SECRET_SCAN_PATHS:
        target = ROOT / relative
        if not target.exists():
            continue
        paths = [target] if target.is_file() else list(target.rglob("*"))
        for path in paths:
            if not path.is_file():
                continue
            if path.suffix.lower() in SKIP_SUFFIXES:
                continue
            if "build" in path.parts or ".dart_tool" in path.parts:
                continue
            scanned += 1
            failures.extend(scan_secrets(path, secrets))

    for relative in API_KEY_LOG_SCAN_PATHS:
        target = ROOT / relative
        if not target.exists():
            continue
        for path in target.rglob("*.dart"):
            failures.extend(scan_api_key_logs(path))

    assert_redaction_demonstrated(failures)

    # 脱敏语义自检：与 Dart 侧 `redactCredential` 一致。
    expected_key = redact(api_key)
    expected_token = redact(access_token)
    if not expected_key.startswith("****") or api_key[-4:] not in expected_key:
        failures.append("脱敏函数语义自检失败（apiKey）")
    if access_token and (
        not expected_token.startswith("****")
        or access_token[-4:] not in expected_token
    ):
        failures.append("脱敏函数语义自检失败（accessToken）")

    if failures:
        print("PHASE4-ACCEPT tmdb-redaction FAIL", file=sys.stderr)
        for item in failures:
            print(f"  - {item}", file=sys.stderr)
        return 1

    print(
        "PHASE4-ACCEPT tmdb-redaction ok "
        f"scanned={scanned} apiKey={expected_key} "
        f"accessToken={expected_token or '(empty)'} plaintext-leaks=0"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
