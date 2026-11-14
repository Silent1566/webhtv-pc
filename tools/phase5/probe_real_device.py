#!/usr/bin/env python3
"""真机只读探测留痕（`docs/phase5/design/03` §7.1，**不作为门禁**）。

为什么不做成门禁：CI 与验收机上没有安卓真机（`design/03` §1.1）。
但真机探测的价值在于**证明 fixture 没编错**，所以必须能留痕。

只做只读探测，且**不记录指纹原文**：
    GET /device                     → 字段完整性、type 取值
    GET /vod/api?ac=config          → 站点数、type 直方图
    GET /vod/api?ac=site            → 与 ac=config 的等价性
    带自定义 Host 再取一次 config    → 站点 api 主机是否随之变化（P2 现场证据）

用法：
    py -3 tools/phase5/probe_real_device.py --device 192.168.50.3:9978
    py -3 tools/phase5/probe_real_device.py --device 192.168.50.3:9978 \
        --out docs/phase5/evidence/device-probe.txt
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter

# 探测用的自定义 Host：只用于验证"站点地址由请求 Host 现算"（P2）。
CUSTOM_HOST = "webhtv-pc-probe.invalid"


def fetch(
    base: str, path: str, *, host: str | None = None, timeout: float = 8.0
) -> tuple[int, object, dict]:
    url = f"{base}{path}"
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise ValueError(f"拒绝非 http(s) scheme: {parsed.scheme!r}")
    headers = {"Accept": "application/json"}
    if host:
        headers["Host"] = host
    request = urllib.request.Request(url, headers=headers)  # noqa: S310
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310
            raw = response.read()
            return response.status, _decode(raw), dict(response.headers)
    except urllib.error.HTTPError as error:
        return error.code, _decode(error.read()), dict(error.headers)
    except Exception as error:  # noqa: BLE001 - 探测失败要如实记录
        return 0, {"error": f"{type(error).__name__}: {error}"}, {}


def _decode(raw: bytes):
    try:
        return json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return {"__raw_bytes": len(raw)}


def site_hosts(config: object) -> set[str]:
    hosts = set()
    if not isinstance(config, dict):
        return hosts
    for site in config.get("sites", []):
        api = site.get("api", "") if isinstance(site, dict) else ""
        if "//" in api:
            hosts.add(api.split("//", 1)[1].split("/", 1)[0])
    return hosts


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", required=True, help="例如 192.168.50.3:9978")
    parser.add_argument("--out", default="", help="证据文件路径（省略则只打印）")
    parser.add_argument("--timeout", type=float, default=8.0)
    args = parser.parse_args()

    device = args.device.strip()
    base = device if "://" in device else f"http://{device}"
    base = base.rstrip("/")

    lines: list[str] = []

    def emit(text: str) -> None:
        print(text)
        lines.append(text)

    emit("PHASE5-EVIDENCE device-probe 真机只读探测（design/03 §7.1，非门禁）")
    emit(f"PHASE5-EVIDENCE device-probe base={base}")

    # 1) /device —— 字段完整性、type 取值（不记录 uuid/serial/wlan 原文）。
    status, device_payload, _ = fetch(base, "/device", timeout=args.timeout)
    required = ["uuid", "name", "ip", "type", "serial", "wlan", "eth", "time"]
    present = (
        [key for key in required if key in device_payload]
        if isinstance(device_payload, dict)
        else []
    )
    emit(
        "PHASE5-EVIDENCE device-probe /device "
        f"status={status} fields={len(present)}/{len(required)}"
    )
    if isinstance(device_payload, dict):
        emit(
            "PHASE5-EVIDENCE device-probe /device "
            f"type={device_payload.get('type')} name-bytes="
            f"{len(str(device_payload.get('name', '')).encode('utf-8'))} "
            "uuid=已脱敏（不记录原文）"
        )
        emit(
            "PHASE5-EVIDENCE device-probe /device "
            f"ip={device_payload.get('ip')}（仅记录形态，用于判断是否可达）"
        )
    else:
        emit(f"PHASE5-EVIDENCE device-probe /device payload={device_payload}")

    # 2) ac=config —— 站点数与 type 直方图。
    status, config, _ = fetch(base, "/vod/api?ac=config", timeout=args.timeout)
    sites = config.get("sites", []) if isinstance(config, dict) else []
    histogram = Counter(str(site.get("type")) for site in sites)
    emit(
        "PHASE5-EVIDENCE device-probe /vod/api?ac=config "
        f"status={status} sites={len(sites)} "
        f"types={dict(sorted(histogram.items()))}"
    )

    # 3) ac=site 与 ac=config 等价性。
    status_site, config_site, _ = fetch(
        base, "/vod/api?ac=site", timeout=args.timeout
    )
    equivalent = isinstance(config_site, dict) and isinstance(config, dict) and (
        json.dumps(config_site, sort_keys=True) == json.dumps(config, sort_keys=True)
    )
    emit(
        "PHASE5-EVIDENCE device-probe ac=site-equivalent="
        f"{equivalent} status={status_site}"
    )

    # 4) P2 的现场证据：改 `Host` 头后站点 api 的主机是否随之变化。
    status_custom, config_custom, _ = fetch(
        base, "/vod/api?ac=config", host=CUSTOM_HOST, timeout=args.timeout
    )
    default_hosts = site_hosts(config)
    custom_hosts = site_hosts(config_custom)
    emit(
        "PHASE5-EVIDENCE device-probe host-derivation "
        f"status={status_custom} default-hosts={sorted(default_hosts)} "
        f"custom-hosts={sorted(custom_hosts)} "
        f"derived-by-host={bool(custom_hosts) and custom_hosts != default_hosts}"
    )
    emit(
        "PHASE5-EVIDENCE device-probe p2-conclusion="
        + (
            "confirmed（站点地址由请求的 Host 头现算）"
            if bool(custom_hosts) and custom_hosts != default_hosts
            else "inconclusive（本次未观测到 Host 派生，需人工复核）"
        )
    )

    if args.out:
        from pathlib import Path

        path = Path(args.out)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"PHASE5-EVIDENCE device-probe written={path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
