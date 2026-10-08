#!/usr/bin/env python3
"""Phase 5 证据落盘（`docs/phase5/design/03` §7）。

生成三份**机器可校验**的证据（不写说明文字，只写事实行）：

- `device-probe.txt`      fixture 的 `/device` 与 `ac=config` 探测摘要
- `site-fidelity.txt`     170 站点的数量 / key 集合 / name 集合 / Host 派生比对
- `sync-merge-matrix.txt` 5 种合并裁决的**真实 Dart 用例输出**（不是复述）

为什么合并矩阵要抓 Dart 输出而不是在 Python 里再实现一遍裁决：
第二份实现会各自漂移，而且它通过也不证明 Dart 侧正确。这里抓的是**被测实现
自己的输出**，因此这份证据不可能比测试更宽松。

用法：
    py -3 tools/phase5/write_evidence.py [--base http://127.0.0.1:18080]
                                         [--puro-env webhtv]
                                         [--skip-merge-matrix]
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "desktop-flutter"
EVIDENCE = ROOT / "docs" / "phase5" / "evidence"

# 合并裁决用例所在的组名（`test/phase5_android_sync_test.dart`）。
MERGE_GROUPS = ("合并裁决", "删除标记", "统计明细", "字段映射与单位")


def fetch(base: str, path: str, *, host: str | None = None) -> tuple[int, object]:
    request = urllib.request.Request(  # noqa: S310 (仅用于回环 fixture)
        f"{base}{path}",
        headers={"Accept": "application/json", **({"Host": host} if host else {})},
    )
    with urllib.request.urlopen(request, timeout=20) as response:  # noqa: S310
        return response.status, json.loads(response.read().decode("utf-8"))


def write_device_probe(base: str) -> list[str]:
    lines = ["PHASE5-EVIDENCE device-probe fixture=android（design/03 §7.1）"]
    status, device = fetch(base, "/android/device")
    lines.append(
        "PHASE5-EVIDENCE device-probe /device "
        f"status={status} fields={sorted(device)} type={device.get('type')} "
        # 连**占位值**都不写进证据：证据文件要交给用户看，而读者无法分辨
        # 一个 uuid 是真是假。这条规则由 `verify_bridge_redaction.py` 守着
        # （本行早先写过占位值，被门禁抓了出来）。
        "uuid=（不记录，仅记录字段完整性）"
    )
    status, config = fetch(base, "/android/vod/api?ac=config")
    sites = config.get("sites", [])
    lines.append(
        "PHASE5-EVIDENCE device-probe /vod/api?ac=config "
        f"status={status} sites={len(sites)}"
    )
    status, home = fetch(base, "/android/vod/api?key=csp_PianDan")
    lines.append(
        "PHASE5-EVIDENCE device-probe /vod/api?key=<key> "
        f"status={status} keys={sorted(home)}"
    )
    # P2 的现场证据：改 Host 后站点 api 的主机随之变化。
    custom = "webhtv-probe.invalid:9978"
    _, config_custom = fetch(base, "/android/vod/api?ac=config", host=custom)
    hosts = {
        site["api"].split("//", 1)[1].split("/", 1)[0]
        for site in config_custom.get("sites", [])
        if "//" in site.get("api", "")
    }
    lines.append(
        "PHASE5-EVIDENCE device-probe host-derivation "
        f"custom-host={custom} derived-hosts={sorted(hosts)} "
        f"derived-by-host={hosts == {custom}}"
    )
    path = EVIDENCE / "device-probe.txt"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return lines


def write_site_fidelity(base: str) -> list[str]:
    custom = "webhtv-fidelity.invalid:9978"
    # 用同一个可达 Host 取两次，避免把"Host 派生"与"保真"混在一起。
    status, config = fetch(base, "/android/vod/api?ac=config", host=custom)
    sites = config.get("sites", [])
    keys = [site.get("key", "") for site in sites]
    names = [site.get("name", "") for site in sites]
    api_paths = {
        site.get("api", "").split("/", 3)[-1] for site in sites
    }
    hosts = {
        site["api"].split("//", 1)[1].split("/", 1)[0]
        for site in sites
        if "//" in site.get("api", "")
    }
    lines = [
        "PHASE5-EVIDENCE site-fidelity 170 站点保真（design/01 §5.4）",
        f"PHASE5-EVIDENCE site-fidelity status={status} sites={len(sites)}",
        f"PHASE5-EVIDENCE site-fidelity keys-unique={len(set(keys)) == len(keys)} "
        f"key-count={len(set(keys))}",
        # 站点**重名是合法的**（实测 170 个站点只有 161 个不同名字）：
        # 保真断言比的是多重集（`SiteFidelityReport._sameSet`），
        # 所以这里只如实报告重复数，不把它当成失败。
        f"PHASE5-EVIDENCE site-fidelity name-count={len(set(names))} "
        f"duplicate-names={len(names) - len(set(names))} "
        "note=比的是多重集，重名合法",
        f"PHASE5-EVIDENCE site-fidelity api-hosts={sorted(hosts)} "
        f"host-consistent={hosts == {custom}}",
        "PHASE5-EVIDENCE site-fidelity api-path-query-distinct="
        f"{len(api_paths)}",
        f"PHASE5-EVIDENCE site-fidelity first-keys={keys[:5]}",
        f"PHASE5-EVIDENCE site-fidelity first-names={names[:5]}",
        # 中文名与方括号必须逐字节保留（保真断言的前提）。
        "PHASE5-EVIDENCE site-fidelity bracket-names="
        f"{[name for name in names if '[' in name or '【' in name][:5]}",
    ]
    path = EVIDENCE / "site-fidelity.txt"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return lines


def write_merge_matrix(puro_env: str) -> list[str]:
    """抓取真实 Dart 用例输出作为合并矩阵证据。"""
    completed = subprocess.run(
        [
            "puro", "-e", puro_env, "-p", ".",
            "flutter", "test",
            "test/phase5_android_sync_test.dart",
            "--reporter", "expanded",
        ],
        cwd=APP,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    output = (completed.stdout or "") + (completed.stderr or "")
    lines = [
        "PHASE5-EVIDENCE sync-merge-matrix 合并裁决实测（design/02 §4.4/§4.5）",
        f"PHASE5-EVIDENCE sync-merge-matrix exit={completed.returncode} "
        f"suite=test/phase5_android_sync_test.dart",
    ]
    pattern = re.compile(
        r"^\s*\d{2}:\d{2}\s*\+(\d+)(?: -(\d+))?:\s*(.+?)\s*$"
    )
    seen = 0
    for raw in output.splitlines():
        match = pattern.match(raw)
        if not match:
            continue
        name = match.group(3)
        if not any(group in name for group in MERGE_GROUPS):
            continue
        seen += 1
        lines.append(
            "PHASE5-EVIDENCE sync-merge-matrix case "
            f"index={seen} status={'fail' if match.group(2) else 'pass'} name={name}"
        )
    lines.append(
        f"PHASE5-EVIDENCE sync-merge-matrix cases={seen} "
        f"all-pass={completed.returncode == 0}"
    )
    path = EVIDENCE / "sync-merge-matrix.txt"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return lines


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:18080")
    parser.add_argument("--puro-env", default="webhtv")
    parser.add_argument("--skip-merge-matrix", action="store_true")
    args = parser.parse_args()
    base = args.base.rstrip("/")

    EVIDENCE.mkdir(parents=True, exist_ok=True)
    for line in write_device_probe(base):
        print(line)
    for line in write_site_fidelity(base):
        print(line)
    if not args.skip_merge_matrix:
        for line in write_merge_matrix(args.puro_env):
            print(line)
    print(f"PHASE5-EVIDENCE evidence-dir={EVIDENCE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
