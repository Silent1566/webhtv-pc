#!/usr/bin/env python3
"""安卓 fixture 路由预检（`docs/phase5/design/03` §4.2）。

一键验收里的「安卓 fixture 预检」（G1）。核心价值不只是"路由通不通"，
而是证明 fixture **忠实复现了真实网关的 Host 派生行为**——这是 P2
（地址来自请求）唯一可自动验证的地方（`design/03` §8 Q2）。

用法：
    py -3 tools/phase5/check_android_fixture.py [--base http://127.0.0.1:18080]

退出码：0 = 全部通过；1 = 有失败（失败项打印在 stderr）。
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

# 故障注入模式 → 期望形态（`design/03` §2.3 表）。
# 每一项都必须能被**逐一触发**，否则"6 类错误全覆盖"就是空话。
MODE_EXPECTATIONS = {
    "404": ("status", 404),
    "empty": ("sites", 0),
    "mismatch": ("host", "third-party.example.com:9978"),
    "loopback": ("host", "127.0.0.1"),
    "repo": ("urls", True),
    "notandroid": ("notandroid", True),
}


def fetch(
    base: str,
    path: str,
    *,
    host: str | None = None,
    method: str = "GET",
    form: dict[str, str] | None = None,
) -> tuple[int, dict | list | str, dict]:
    """返回 (status, body, headers)。

    只允许访问本机回环地址：fixture 服务只监听回环，这里显式拒绝其它主机，
    避免把工具变成任意 URL 抓取器。
    """
    url = f"{base}{path}"
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise ValueError(f"拒绝非 http(s) scheme: {parsed.scheme!r}")
    if parsed.hostname not in ("127.0.0.1", "localhost", "::1"):
        raise ValueError(f"只允许回环地址: {parsed.hostname!r}")

    data = None
    headers = {"Accept": "application/json"}
    if host:
        # 只覆盖 `Host` 不改变连接目标：真实网关用**请求的 `Host` 头**现算
        # 站点地址，这条预检就是复现它。
        headers["Host"] = host
    if form is not None:
        data = urllib.parse.urlencode(form).encode("utf-8")
        headers["Content-Type"] = "application/x-www-form-urlencoded"

    request = urllib.request.Request(  # noqa: S310 (scheme 已显式校验)
        url, data=data, headers=headers, method=method
    )
    try:
        with urllib.request.urlopen(  # noqa: S310 (scheme 已显式校验)
            request, timeout=15
        ) as response:
            raw = response.read()
            return response.status, _decode(raw), {
                key.lower(): value for key, value in response.headers.items()
            }
    except urllib.error.HTTPError as error:
        raw = error.read()
        return error.code, _decode(raw), {
            key.lower(): value for key, value in error.headers.items()
        }


def _decode(raw: bytes):
    try:
        return json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return raw.decode("utf-8", errors="replace")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:18080")
    args = parser.parse_args()
    base = args.base.rstrip("/")

    failures: list[str] = []
    facts: list[str] = []

    def check(name: str, condition: bool, detail: str = "") -> None:
        if condition:
            facts.append(f"PHASE5-ACCEPT android-fixture {name} OK {detail}".strip())
        else:
            failures.append(f"{name} {detail}".strip())

    # 0. 清空统计，保证本次预检的计数可解释。
    fetch(base, "/android/__reset")
    fetch(base, "/android/__mode?config=ok")

    # 1. /device 字段完整（`design/03` §4.1 第 6 项：全 8 个字段）。
    status, device, _ = fetch(base, "/android/device")
    required = {"uuid", "name", "ip", "type", "serial", "wlan", "eth", "time"}
    check(
        "device 字段完整",
        status == 200
        and isinstance(device, dict)
        and required.issubset(device.keys()),
        f"status={status} missing={sorted(required - set(device or {}))}",
    )
    check(
        "device ip 由 Host 现算",
        isinstance(device, dict) and device.get("ip") == "http://127.0.0.1:18080",
        f"ip={device.get('ip') if isinstance(device, dict) else '-'!r}",
    )

    # 2. 站点 `api` 主机 == 请求的 Host（P2 的可测性依赖它，§8 Q2）。
    custom_host = "192.168.50.9:9978"
    status, config, _ = fetch(
        base, "/android/vod/api?ac=config", host=custom_host
    )
    sites = config.get("sites", []) if isinstance(config, dict) else []
    check(
        "config 站点数 = 170",
        status == 200 and len(sites) == 170,
        f"status={status} sites={len(sites)}",
    )
    check(
        "所有站点 type 为字符串 \"4\"",
        all(str(site.get("type")) == "4" for site in sites),
        f"types={sorted({str(site.get('type')) for site in sites})}",
    )
    hosts = set()
    for site in sites:
        api = site.get("api", "")
        if "//" in api:
            hosts.add(api.split("//", 1)[1].split("/", 1)[0])
    check(
        "站点 api 主机 = 请求 Host",
        hosts == {custom_host},
        f"hosts={sorted(hosts)}",
    )
    check(
        "无 __HOST__ 占位符残留",
        "__HOST__" not in json.dumps(config, ensure_ascii=False),
        "fixture 未做脱敏替换",
    )

    # 3. ac=site 与 ac=config 字节相同（`design/00` §3.2 第 3 条实测）。
    status_a, _, _ = fetch(base, "/android/vod/api?ac=config", host=custom_host)
    status_b, _, _ = fetch(base, "/android/vod/api?ac=site", host=custom_host)
    _, config_a, _ = fetch(base, "/android/vod/api?ac=config", host=custom_host)
    _, config_b, _ = fetch(base, "/android/vod/api?ac=site", host=custom_host)
    check(
        "ac=site 与 ac=config 等价",
        status_a == status_b == 200
        and json.dumps(config_a, sort_keys=True)
        == json.dumps(config_b, sort_keys=True),
        "两者响应不一致",
    )

    # 4. 站点可执行性（`key=` 返回首页）。
    status, home, _ = fetch(base, "/android/vod/api?key=csp_PianDan")
    check(
        "key= 返回站点首页",
        status == 200 and isinstance(home, dict) and "list" in home,
        f"status={status} keys={sorted(home) if isinstance(home, dict) else '-'}",
    )

    # 5. 8 种故障注入逐一可触发（`design/03` §2.3）。
    for mode, (kind, expected) in MODE_EXPECTATIONS.items():
        fetch(base, f"/android/__mode?config={mode}")
        if kind == "status":
            status, _, _ = fetch(base, "/android/vod/api?ac=config")
            check(f"mode={mode}", status == expected, f"status={status}")
            continue
        if kind == "notandroid":
            _, body, _ = fetch(base, "/android/device")
            check(
                f"mode={mode}",
                isinstance(body, dict) and "uuid" not in body,
                f"body={body}",
            )
            continue
        if kind == "sites":
            _, body, _ = fetch(base, "/android/vod/api?ac=config")
            check(f"mode={mode}", body.get("sites") == [], f"body={body}")
            continue
        if kind == "urls":
            _, body, _ = fetch(base, "/android/vod/api?ac=config")
            check(
                f"mode={mode}",
                isinstance(body, dict) and bool(body.get("urls")),
                f"keys={sorted(body) if isinstance(body, dict) else '-'}",
            )
            continue
        # host：断言站点指向的主机符合预期（mismatch=第三方，loopback=回环）。
        _, body, _ = fetch(base, "/android/vod/api?ac=config")
        body_hosts = {
            site["api"].split("//", 1)[1].split("/", 1)[0]
            for site in body.get("sites", [])
            if "//" in site.get("api", "")
        }
        # loopback 模式的期望是"全部回环"，其余是"精确指向某个第三方主机"。
        if expected.startswith("127.0.0.1"):
            ok = bool(body_hosts) and all(
                host.startswith("127.0.0.1") for host in body_hosts
            )
        else:
            ok = expected in body_hosts
        check(f"mode={mode}", ok, f"hosts={sorted(body_hosts)}")

    fetch(base, "/android/__mode?config=ok")

    # 5b. slow 模式：必须真的慢（供超时用例触发 bridgeUnreachable）。
    fetch(base, "/android/__mode?config=slow")
    import time

    started = time.monotonic()
    fetch(base, "/android/vod/api?ac=config")
    elapsed = time.monotonic() - started
    check("mode=slow 真的慢", elapsed >= 4.0, f"elapsed={elapsed:.1f}s")
    fetch(base, "/android/__mode?config=ok")

    # 6. /action 能接收表单并回 200 OK，字段被 stats 记录（§4.2 第 6 项）。
    fetch(base, "/android/__reset")
    fetch(base, "/android/__mode?config=ok")
    status, body, _ = fetch(
        base,
        "/android/action?do=sync&mode=1&type=history",
        method="POST",
        form={
            "config": '{"url":"http://127.0.0.1:18080/android/sub"}',
            "targets": "[]",
            "options": '{"settings":false}',
        },
    )
    check(
        "action 表单推送 200 OK",
        status == 200 and str(body).startswith("OK"),
        f"status={status} body={body!r}",
    )
    status, stats, _ = fetch(base, "/android/__stats")
    last_form = stats.get("lastForm", {}) if isinstance(stats, dict) else {}
    check(
        "action 字段被 stats 记录",
        isinstance(stats, dict)
        and stats.get("counts", {}).get("/action") == 1
        and "targets" in last_form
        and "settings" in last_form.get("options", ""),
        f"counts={stats.get('counts') if isinstance(stats, dict) else '-'} "
        f"form={sorted(last_form)}",
    )
    check(
        "action query 被 stats 记录",
        isinstance(stats, dict)
        and stats.get("lastQuery", {}).get("mode") == "1"
        and stats.get("lastQuery", {}).get("type") == "history",
        f"query={stats.get('lastQuery') if isinstance(stats, dict) else '-'}",
    )

    # 6b. mode=403 注入：模拟安卓"本机 API 修改未开启"（L3 推送用例依赖它）。
    fetch(base, "/android/__mode?config=403")
    status, body, _ = fetch(
        base,
        "/android/action?do=sync&mode=1&type=history",
        method="POST",
        form={"config": "{}", "targets": "[]"},
    )
    check(
        "mode=403 注入生效",
        status == 403 and "本机 API 修改未开启" in str(body),
        f"status={status} body={body!r}",
    )
    fetch(base, "/android/__mode?config=ok")

    # 7. 根路径别名可用：PC 的 `normalizeBase` 只保留 scheme+host+port，
    #    真正请求的是 `/device`、`/vod/api`、`/action`（`design/01` §4.2）。
    status, device, _ = fetch(base, "/device")
    check("根别名 /device 可用", status == 200 and "uuid" in device, f"status={status}")
    status, config, _ = fetch(base, "/vod/api?ac=config")
    check(
        "根别名 /vod/api?ac=config 可用",
        status == 200 and len(config.get("sites", [])) == 170,
        f"status={status}",
    )

    # 8. __reset 可清零。
    fetch(base, "/android/__stats")
    status, stats, _ = fetch(base, "/android/__reset")
    _, after, _ = fetch(base, "/android/__stats")
    check(
        "__reset 清零",
        status == 200
        and isinstance(after, dict)
        and after.get("total") == 0
        and after.get("lastForm") == {},
        f"total={after.get('total') if isinstance(after, dict) else '-'}",
    )

    for line in facts:
        print(line)
    if failures:
        print("PHASE5-ACCEPT android-fixture FAIL", file=sys.stderr)
        for item in failures:
            print(f"  - {item}", file=sys.stderr)
        return 1
    print(
        f"PHASE5-ACCEPT android-fixture routes=8 modes={len(MODE_EXPECTATIONS) + 2} "
        "failures=0"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
