#!/usr/bin/env python3
"""TMDB fixture 路由预检（`docs/phase4/design/05` §7.2 第 0 步）。

在验收脚本里作为「TMDB fixture 预检」使用：确认路由可达、`__stats` 可用、
请求捕获头可读、错误码符合预期。

用法：
    py -3 tools/phase4/check_tmdb_fixture.py [--base http://127.0.0.1:18080]

退出码：0 = 全部通过；1 = 有失败（失败项打印在 stderr）。
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request
from urllib.parse import urlparse


def fetch(base: str, path: str) -> tuple[int, dict, dict]:
    """返回 (status, json_body_or_{}, headers)。

    只允许 http(s) 且仅访问本机回环地址：fixture 服务只监听回环（`server.py`），
    这里显式拒绝其它 scheme/主机，避免把工具变成任意 URL 抓取器。
    """
    parsed = urlparse(f"{base}{path}")
    if parsed.scheme not in ("http", "https"):
        raise ValueError(f"拒绝非 http(s) scheme: {parsed.scheme!r}")
    if parsed.hostname not in ("127.0.0.1", "localhost", "::1"):
        raise ValueError(f"只允许回环地址: {parsed.hostname!r}")
    request = urllib.request.Request(  # noqa: S310 (scheme 已显式校验)
        f"{base}{path}", headers={"Accept": "application/json"}
    )
    try:
        with urllib.request.urlopen(  # noqa: S310 (scheme 已显式校验)
            request, timeout=10
        ) as response:
            raw = response.read()
            headers = {k.lower(): v for k, v in response.headers.items()}
            try:
                body = json.loads(raw.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                body = {"__raw_bytes": len(raw)}
            return response.status, body, headers
    except urllib.error.HTTPError as error:
        raw = error.read()
        headers = {k.lower(): v for k, v in error.headers.items()}
        try:
            body = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            body = {}
        return error.code, body, headers


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:18080")
    args = parser.parse_args()
    base = args.base.rstrip("/")

    failures: list[str] = []
    facts: list[str] = []

    def check(name: str, condition: bool, detail: str = "") -> None:
        if condition:
            facts.append(f"PHASE4-ACCEPT tmdb-fixture {name} OK {detail}".strip())
        else:
            failures.append(f"{name} {detail}".strip())

    # 0. 路由可达（`05` §2.2 全表）
    expected_ok = {
        "/tmdb/configuration": "configuration.json",
        "/tmdb/3/search/multi?query=x": "search-multi.json",
        "/tmdb/3/search/multi?query=empty": "search-empty.json",
        "/tmdb/3/search/multi?query=split": "search-split-season.json",
        "/tmdb/3/tv/1399": "detail-tv.json",
        "/tmdb/3/tv/2": "detail-tv-next-air.json",
        "/tmdb/3/movie/550": "detail-movie.json",
        "/tmdb/3/tv/1399/season/1": "season-1.json",
        "/tmdb/3/tv/1399/season/2": "season-2.json",
        "/tmdb/3/tv/1399/season/0": "season-0.json",
        "/tmdb/3/tv/1399/season/9": "season-empty.json",
        "/tmdb/3/tv/1399/season/1/episode/1": "episode-s1e1.json",
        "/tmdb/3/person/1": "person.json",
        "/tmdb/3/tv/1399/videos": "videos-tv.json",
        "/tmdb/3/tv/1399/recommendations?page=1": "recommendations-page1.json",
        "/tmdb/3/tv/1399/recommendations?page=2": "recommendations-page2.json",
        "/tmdb/3/tv/1399/recommendations?page=9": "recommendations-empty.json",
        "/tmdb/3/tv/1399/similar?page=1": "recommendations-page1.json",
    }
    for path in expected_ok:
        status, body, _ = fetch(base, path)
        check(f"route {path}", status == 200 and bool(body), f"status={status}")

    # 1. 错误路由
    for path, expected in (
        ("/tmdb/auth-fail", 401),
        ("/tmdb/server-error", 500),
        ("/tmdb/nope", 404),
    ):
        status, _, _ = fetch(base, path)
        check(f"error route {path}", status == expected, f"status={status}")

    # 2. malformed 返回非法 JSON（状态 200 但不可解析）
    status, body, _ = fetch(base, "/tmdb/malformed")
    check(
        "malformed 非法 JSON",
        status == 200 and "__raw_bytes" in body,
        f"status={status} body={body}",
    )

    # 3. 请求捕获头（`05` §2.2 断言支持）
    status, _, headers = fetch(
        base,
        "/tmdb/3/tv/1399?language=zh-CN&api_key=ABC123"
        "&include_image_language=zh,en",
    )
    check(
        "请求捕获 api_key",
        headers.get("x-fixture-seen-apikey") == "ABC123",
        f"seen={headers.get('x-fixture-seen-apikey')!r}",
    )
    check(
        "请求捕获 language",
        headers.get("x-fixture-seen-language") == "zh-CN",
        f"seen={headers.get('x-fixture-seen-language')!r}",
    )
    check(
        "请求捕获 include_image_language",
        headers.get("x-fixture-seen-includeimagelanguage") == "zh,en",
        f"seen={headers.get('x-fixture-seen-includeimagelanguage')!r}",
    )

    # 4. __stats 可用（`01` §12 第 9 项：零请求断言）
    status, stats, _ = fetch(base, "/tmdb/__stats")
    check(
        "__stats 可用",
        status == 200 and isinstance(stats.get("counts"), dict),
        f"total={stats.get('total')}",
    )

    # 5. __reset 可清零
    status, _, _ = fetch(base, "/tmdb/__reset")
    status2, stats2, _ = fetch(base, "/tmdb/__stats")
    check(
        "__reset 清零",
        status == 200 and status2 == 200 and stats2.get("total") == 0,
        f"total={stats2.get('total')}",
    )

    for line in facts:
        print(line)
    if failures:
        print("PHASE4-ACCEPT tmdb-fixture FAIL", file=sys.stderr)
        for item in failures:
            print(f"  - {item}", file=sys.stderr)
        return 1
    print(f"PHASE4-ACCEPT tmdb-fixture routes={len(expected_ok)} failures=0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
