#!/usr/bin/env python3
"""从真实 Android 设备抓取并生成 Phase 5 安卓桥接 fixture。

用法：

    # 从真实设备抓取（需先 adb forward tcp:19978 tcp:9978）
    py -3 tools/phase5/capture_android_fixtures.py --base http://127.0.0.1:19978

    # 只做脱敏复检（不抓取，校验已提交的 fixture 是否仍然合规）
    py -3 tools/phase5/capture_android_fixtures.py --verify

设计约束（`docs/phase5/design/03` §2.2）：

1. 站点 `api` 里的主机必须替换为 `__HOST__` 占位符，让同一份 fixture 能同时
   服务「主机一致」与「主机不一致」两个用例。
2. 设备指纹（`uuid` / `serial` / `wlan` / `eth`）必须替换为固定假值。
3. 站点 `key` / `name` / `type` / 标志位**原样保留**，因为站点保真断言
   （`design/01` §5.4）依赖真实的中文名与方括号。
4. 重复执行幂等：同样的输入产生逐字节相同的输出。

只写 fixture，不参与运行时代码。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / "packages" / "test-fixtures" / "android"

HOST_PLACEHOLDER = "__HOST__"

# 固定假设备指纹（`design/03` §2.2）。真实值不得入库。
FAKE_DEVICE = {
    "eth": "",
    "serial": "fixture0",
    "uuid": "fixture-device-uuid",
    "wlan": "00:00:00:00:00:00",
}

# 站点 api 里的主机：`http://<host>:<port>` → `http://__HOST__`（端口随占位符）。
HOST_PATTERN = re.compile(r"^http://[^/]+", re.IGNORECASE)

# 脱敏复检用的真实值特征（出现即视为泄漏）。
#
# `127.0.0.1` **不**在此列：它是回环占位符，不是可识别数据，
# 而且 `gateway-config-loopback.json` 这个用例**必须**包含它
# （`design/01` §5.3 的“响应回环 + 请求非回环 → 重写”分支）。
IPV4_PATTERN = re.compile(r"\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b")


def is_loopback_literal(address: str) -> bool:
    """整个 127.0.0.0/8 都是回环字面量，不是可识别数据。"""
    return address.split(".", 1)[0] == "127"


LEAK_PATTERNS = [
    re.compile(r"e6455919f5d1497b"),
    re.compile(r"00ed47e6"),
    re.compile(r"00:DB:14:2E:9C:7C", re.IGNORECASE),
]


def leaked_ipv4(text: str) -> str | None:
    """返回第一个**非回环** IPv4 字面量（真实地址泄漏）。"""
    for match in IPV4_PATTERN.finditer(text):
        if not is_loopback_literal(match.group(1)):
            return match.group(1)
    return None


def write(name: str, payload: object) -> None:
    path = BASE / name
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with open(path, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(payload, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
    except OSError as error:
        raise SystemExit(f"写入 fixture 失败 {path}：{error}") from error


# 只允许 http/https：`--base` 来自命令行，必须显式限制 scheme，
# 否则 `file:` / 自定义 scheme 会被 urllib 接受（bandit B310）。
ALLOWED_SCHEMES = ("http", "https")


def checked_url(base: str, path: str) -> str:
    """拼接并校验 URL：只允许 http/https，且主机非空。"""
    url = base.rstrip("/") + path
    parts = urllib.parse.urlsplit(url)
    if parts.scheme not in ALLOWED_SCHEMES:
        raise ValueError(f"只支持 http/https 基址，收到：{parts.scheme!r}")
    if not parts.hostname:
        raise ValueError(f"基址缺少主机：{base!r}")
    return url


def fetch(base: str, path: str, host: str | None = None) -> dict:
    """抓取一个 JSON 对象。只接受 http/https（见 [checked_url]）。"""
    url = checked_url(base, path)
    request = urllib.request.Request(url)  # noqa: S310
    if host:
        request.add_header("Host", host)
    try:
        with urllib.request.urlopen(request, timeout=15) as response:  # noqa: S310
            payload = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise SystemExit(f"请求失败 {url}：{error}") from error
    except json.JSONDecodeError as error:
        raise SystemExit(f"响应不是合法 JSON {url}：{error}") from error
    if not isinstance(payload, dict):
        raise SystemExit(f"响应不是 JSON 对象 {url}：{type(payload).__name__}")
    return payload


def redact_host(url: str) -> str:
    """把站点 api 的主机替换为占位符，保留 path 与 query。"""
    if not isinstance(url, str):
        return url
    return HOST_PATTERN.sub(f"http://{HOST_PLACEHOLDER}", url)


def redact_device(payload: dict) -> dict:
    result = dict(payload)
    for key, value in FAKE_DEVICE.items():
        if key in result:
            result[key] = value
    result["ip"] = f"http://{HOST_PLACEHOLDER}"
    result["time"] = 0
    return result


def redact_gateway(payload: dict, host: str) -> dict:
    result = dict(payload)
    sites = []
    for site in payload.get("sites", []):
        item = dict(site)
        item["api"] = redact_host(item.get("api", ""))
        # `key` / `name` / `type` / 标志位原样保留（§2.2 第 3 条）。
        sites.append(item)
    result["sites"] = sites
    return result


# ------------------------------------------------------------------ 静态 fixture

def build_history_fixture() -> list[dict]:
    """真实 `History[]` 形态（`design/02` §3.4）。

    必须覆盖：
    - 正常记录（毫秒位置/时长/时间戳）；
    - `opening` / `ending` 为 `C.TIME_UNSET`（`Long.MIN_VALUE`）的哨兵值；
    - 中文片名与集名；
    - TMDB 身份字段（PC 不解析但必须保留在 raw）。
    """
    unset = -9223372036854775808
    return [
        {
            "key": "csp_Media@@@demo-001@@@1",
            "vodPic": "http://__HOST__/media/poster-001.jpg",
            "vodName": "示例剧集",
            "vodFlag": "线路一",
            "vodRemarks": "第2集",
            "episodeUrl": "http://__HOST__/media/ep-001-2.m3u8",
            "revSort": False,
            "revPlay": False,
            "createTime": 1791450000000,
            "opening": unset,
            "ending": unset,
            "position": 754000,
            "duration": 2700000,
            "speed": 1.0,
            "speedOverride": False,
            "scale": -1,
            "cid": 1,
            "tmdbId": 1399,
            "mediaType": "tv",
            "tmdbSeasonNumber": 2,
            "tmdbEpisodeNumber": 5,
            "sourceBindingKey": "线路一#0",
            "player": -1,
            "subtitleSource": "",
        },
        {
            "key": "csp_XiaoYa@@@demo-002@@@1",
            "vodPic": "",
            "vodName": "示例电影【加长版】",
            "vodFlag": "",
            "vodRemarks": "",
            "episodeUrl": "",
            "revSort": False,
            "revPlay": False,
            "createTime": 1791440000000,
            "opening": 60000,
            "ending": 2600000,
            "position": 0,
            "duration": 0,
            "speed": 1.0,
            "speedOverride": False,
            "scale": -1,
            "cid": 1,
            "tmdbId": 0,
            "mediaType": "",
            "tmdbSeasonNumber": 0,
            "tmdbEpisodeNumber": 0,
            "sourceBindingKey": "",
            "player": -1,
            "subtitleSource": "",
        },
        {
            # 只有两段 key：cid 缺失，PC 必须回退 cid=0。
            "key": "csp_AList@@@demo-003",
            "vodPic": "",
            "vodName": "两段键记录",
            "vodFlag": "线路二",
            "vodRemarks": "第1集",
            "episodeUrl": "http://__HOST__/media/ep-003-1.m3u8",
            "createTime": 1791430000000,
            "opening": unset,
            "ending": unset,
            "position": 1000,
            "duration": 2000,
            "speed": 1.0,
            "cid": 0,
        },
    ]


def build_keep_fixture() -> list[dict]:
    return [
        {
            "key": "csp_Media@@@demo-001@@@1",
            "siteName": "我的追剧",
            "vodName": "示例剧集",
            "vodPic": "http://__HOST__/media/poster-001.jpg",
            "createTime": 1791450000000,
            "type": 0,
            "cid": 1,
        },
        {
            "key": "csp_XiaoYa@@@demo-002@@@1",
            "siteName": "丫仙女[盘]",
            "vodName": "示例电影【加长版】",
            "vodPic": "",
            "createTime": 1791440000000,
            "type": 0,
            "cid": 1,
        },
    ]


def build_sync_options_fixture() -> dict:
    """`SyncOptions` 真实形态（`design/02` §3.6）。"""
    return {
        "config": True,
        "spider": True,
        "search": True,
        "history": True,
        "keep": True,
        "follow": False,
        "webHome": True,
        "settings": False,
        "loginState": True,
        "remoteRelay": False,
        "mpvConfig": False,
        "paths": "",
    }


def build_backup_fixture() -> dict:
    """`Backup` 真实形态（`design/00` §3.6），`prefers` 只放白名单子集。"""
    return {
        "site": [],
        "live": [],
        "keep": build_keep_fixture(),
        "config": [
            {
                "id": 1,
                "type": 0,
                "name": "",
                "url": "http://__HOST__/sub/demo",
                "interfaceKey": "fixture-interface-key",
            }
        ],
        "history": build_history_fixture(),
        "tmdbSeasonProgress": [],
        "following": [],
        "followingSource": [],
        "followingSchemaVersion": 1,
        "track": [],
        "device": [],
        "prefers": {
            "tmdb_enabled": True,
            "tmdb_config": "FIXTURE_TMDB_CONFIG_PLACEHOLDER",
            "viewing_record_sync_enabled": True,
            "viewing_record_sync_local_write": False,
            "site_mode": 0,
            "incognito": False,
        },
    }


def build_vod_home_fixture() -> dict:
    return {
        "class": [
            {"type_id": "1", "type_name": "电影"},
            {"type_id": "2", "type_name": "电视剧"},
        ],
        "list": [
            {
                "vod_id": "demo-001",
                "vod_name": "示例剧集",
                "vod_pic": "http://__HOST__/media/poster-001.jpg",
                "vod_remarks": "更新至 2 集",
                "type_name": "电视剧",
            },
            {
                "vod_id": "demo-002",
                "vod_name": "示例电影【加长版】",
                "vod_pic": "",
                "vod_remarks": "HD",
                "type_name": "电影",
            },
        ],
    }


# ------------------------------------------------------------------ 生成

def generate_from_device(base: str, host: str) -> None:
    device = fetch(base, "/device")
    gateway = fetch(base, "/vod/api?ac=config", host=host)
    gateway_site = fetch(base, "/vod/api?ac=site", host=host)

    if gateway_site != gateway:
        print(
            "WARN  ac=site 与 ac=config 响应不一致（设计文档 §3.2 断言它们等价）",
            file=sys.stderr,
        )

    write("device.json", redact_device(device))
    write("gateway-config.json", redact_gateway(gateway, host))
    write("gateway-config-empty.json", {"spider": "", "sites": [], "doh": [], "rules": [], "lives": []})
    write(
        "gateway-config-loopback.json",
        {
            "spider": "",
            "sites": [
                {
                    "key": "csp_Media",
                    "name": "我的追剧",
                    "api": "http://127.0.0.1:9978/vod/api?key=csp_Media",
                    "type": "4",
                    "searchable": 1,
                    "quickSearch": 1,
                    "filterable": 1,
                }
            ],
            "doh": [],
            "rules": [],
            "lives": [],
        },
    )
    write(
        "gateway-config-mismatch.json",
        {
            "spider": "",
            "sites": [
                {
                    "key": "csp_Media",
                    "name": "我的追剧",
                    "api": "http://third-party.example.com:9978/vod/api?key=csp_Media",
                    "type": "4",
                    "searchable": 1,
                    "quickSearch": 1,
                    "filterable": 1,
                }
            ],
            "doh": [],
            "rules": [],
            "lives": [],
        },
    )
    write(
        "gateway-config-repo.json",
        {
            "urls": [
                {"name": "仓库条目 A", "url": "http://__HOST__/sub/a"},
                {"name": "仓库条目 B", "url": "http://__HOST__/sub/b"},
            ]
        },
    )
    write("history-android.json", build_history_fixture())
    write("keep-android.json", build_keep_fixture())
    write("backup-android.json", build_backup_fixture())
    write("sync-options.json", build_sync_options_fixture())
    write("vod-home.json", build_vod_home_fixture())

    sites = gateway.get("sites", [])
    types = sorted({str(site.get("type")) for site in sites})
    print(f"已生成 fixture：站点数={len(sites)} type={types}")
    print(f"输出目录：{BASE}")


def generate_static_only() -> None:
    """无设备时的确定性生成（只写与设备无关的 fixture）。"""
    write("gateway-config-empty.json", {"spider": "", "sites": [], "doh": [], "rules": [], "lives": []})
    write(
        "gateway-config-loopback.json",
        {
            "spider": "",
            "sites": [
                {
                    "key": "csp_Media",
                    "name": "我的追剧",
                    "api": "http://127.0.0.1:9978/vod/api?key=csp_Media",
                    "type": "4",
                    "searchable": 1,
                    "quickSearch": 1,
                    "filterable": 1,
                }
            ],
            "doh": [],
            "rules": [],
            "lives": [],
        },
    )
    write(
        "gateway-config-mismatch.json",
        {
            "spider": "",
            "sites": [
                {
                    "key": "csp_Media",
                    "name": "我的追剧",
                    "api": "http://third-party.example.com:9978/vod/api?key=csp_Media",
                    "type": "4",
                    "searchable": 1,
                    "quickSearch": 1,
                    "filterable": 1,
                }
            ],
            "doh": [],
            "rules": [],
            "lives": [],
        },
    )
    write(
        "gateway-config-repo.json",
        {
            "urls": [
                {"name": "仓库条目 A", "url": "http://__HOST__/sub/a"},
                {"name": "仓库条目 B", "url": "http://__HOST__/sub/b"},
            ]
        },
    )
    write("history-android.json", build_history_fixture())
    write("keep-android.json", build_keep_fixture())
    write("backup-android.json", build_backup_fixture())
    write("sync-options.json", build_sync_options_fixture())
    write("vod-home.json", build_vod_home_fixture())
    print(f"已生成与设备无关的 fixture：{BASE}")


# ------------------------------------------------------------------ 复检

def verify() -> int:
    """脱敏复检：已提交的 fixture 不得含真实地址或设备指纹。"""
    problems: list[str] = []
    names = sorted(path.name for path in BASE.glob("*.json"))
    if not names:
        problems.append(f"{BASE} 下没有任何 fixture")
    for name in names:
        text = (BASE / name).read_text(encoding="utf-8")
        for pattern in LEAK_PATTERNS:
            match = pattern.search(text)
            if match:
                problems.append(f"{name} 含疑似真实值：{match.group(0)!r}")
        leaked = leaked_ipv4(text)
        if leaked:
            problems.append(f"{name} 含非回环 IP 字面量：{leaked!r}")
        try:
            json.loads(text)
        except json.JSONDecodeError as error:
            problems.append(f"{name} 不是合法 JSON：{error}")

    config_path = BASE / "gateway-config.json"
    if config_path.is_file():
        try:
            payload = json.loads(config_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            problems.append(f"gateway-config.json 无法读取或解析：{error}")
            payload = {}
        sites = payload.get("sites", [])
        if not sites:
            problems.append("gateway-config.json 的 sites 为空")
        bad_type = [site.get("key") for site in sites if str(site.get("type")) != "4"]
        if bad_type:
            problems.append(f"gateway-config.json 含非 type=4 站点：{bad_type[:5]}")
        missing_placeholder = [
            site.get("key")
            for site in sites
            if HOST_PLACEHOLDER not in str(site.get("api", ""))
        ]
        if missing_placeholder:
            problems.append(
                f"gateway-config.json 含未占位化的 api：{missing_placeholder[:5]}"
            )
        print(f"gateway-config.json：{len(sites)} 个站点，全部 type=4 且 api 已占位化")

    if problems:
        for problem in problems:
            print(f"FAIL  {problem}", file=sys.stderr)
        return 1
    print(f"OK    脱敏复检通过（{len(names)} 个 fixture）")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", help="Android 服务基址，如 http://127.0.0.1:19978")
    parser.add_argument(
        "--host",
        default=None,
        help="抓取时使用的 Host 头（默认取 --base 的主机）",
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help="只做脱敏复检，不抓取",
    )
    parser.add_argument(
        "--static-only",
        action="store_true",
        help="无设备时只生成与设备无关的 fixture",
    )
    args = parser.parse_args()

    if args.verify:
        return verify()
    if args.static_only or not args.base:
        generate_static_only()
        return verify()
    host = args.host or args.base.split("//", 1)[-1].rstrip("/")
    generate_from_device(args.base, host)
    return verify()


if __name__ == "__main__":
    raise SystemExit(main())
