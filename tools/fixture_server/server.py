#!/usr/bin/env python3
"""仅监听本机的 WebHTV PC fixture 服务。

覆盖设计文档 §19.2 必备 fixture 中的 HTTP API 部分：

- `/api/type0/`  XML API（type=0）
- `/api/type1/`  JSON API（type=1，追加 `f={json}`）
- `/api/type2/`  JSON API 兼容（type=2，不追加 `f`）
- `/api/type4/`  HTTP API + Base64 ext（type=4）
- `/api/echo`   请求回显，用于验证 query/form 编码，不参与任何业务

- `/api/play`           播放入口（站点 `playUrl`）
- `/api/repository-a.json`、`/api/repository-b.json` 配置仓库条目
- `/api/error-html`     HTML 错误页（必须被识别为解析失败）
- `/api/msg`            业务错误 `msg`
- `/api/filters`        分类筛选对象
- `/api/multi-flag`     多线路
- `/api/multi-episode`  多剧集
- `/api/type1` 等路由在带 `ids` 时返回详情，带 `wd` 时返回搜索结果

- `/media/...`  本地媒体 fixture，要求 `Referer` 与 `User-Agent`
- `/live/live.m3u`、`/live/live.txt`、`/live/live.json`  直播清单 fixture（§13.3）

字幕 fixture（§10.3「外挂字幕」）：

- `/media/sample.srt`  外挂字幕样本，与媒体共用同一道 Header 门禁
  （字幕与视频同源时通常需要同样的 Referer/UA/Cookie，缺 Header 必须 403）
- `/api/play-with-subs`  携带 `subs` 的播放结果（含缺地址条目，用于验证丢弃）
- `/api/play-with-danmaku`  携带 `danmaku` 的播放结果（含 ws 直播弹幕与缺失文件）
- `/danmaku/sample.xml`、`/danmaku/sample.txt`  弹幕文件样本（与媒体同一道 Header 门禁）

服务只允许监听回环地址。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import mimetypes
import struct
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "packages" / "test-fixtures" / "http"
CONFIGS = ROOT / "packages" / "test-fixtures" / "config"
MEDIA = ROOT / "packages" / "test-fixtures" / "media"
CATHTTP = ROOT / "packages" / "test-fixtures" / "cathttp"
LIVE = ROOT / "packages" / "test-fixtures" / "live"
DANMAKU = ROOT / "packages" / "test-fixtures" / "danmaku"
# TMDB fixture 根目录（`docs/phase4/design/05` §2.1）。
TMDB_FIXTURES = ROOT / "packages" / "test-fixtures" / "tmdb"
# TMDB 路由命中计数（`/tmdb/__stats`，`01` §12 第 9 项）。
TMDB_STATS: dict[str, int] = {}
# TMDB 故障注入模式（`/tmdb/__mode`）：
#   `auth=401` 使全部 `/3/**` 返回 401（验证鉴权失败隔离与熔断）；
#   `auth=off` 恢复正常。只影响后续请求，不改任何 fixture 文件。
TMDB_MODE: dict[str, str] = {}
REQUIRED_REFERER = "http://127.0.0.1:18080/"
REQUIRED_USER_AGENT = "WebHTV-PC/0.1 (Windows)"
LEGACY_USER_AGENT = "WebHTV-PC-Phase0"

MEDIA_URL = "http://127.0.0.1:18080/media/sample.m3u8"
MEDIA_MP4_URL = "http://127.0.0.1:18080/media/sample.mp4"


def _image_size_for(relative: str) -> int:
    """按图片类型选尺寸：背景图/剧照大一些，海报/头像小一些。"""
    name = relative.lower()
    if name.startswith(("w780", "h780", "original")):
        return 160
    if "backdrop" in name or name.endswith("b.jpg"):
        return 160
    return 96


def _png_chunk(kind: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + kind
        + payload
        + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
    )


def _encode_png(width: int, height: int, raw_rows: bytes) -> bytes:
    """把 `filter byte + RGB` 行数据编码为 PNG（仅用标准库）。"""
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + _png_chunk(b"IHDR", header)
        + _png_chunk(b"IDAT", zlib.compress(raw_rows, 6))
        + _png_chunk(b"IEND", b"")
    )


# ---------------------------------------------------------------------- TMDB


def _episode_url(index: int) -> str:
    """给每集一个**互不相同**的地址。

    同一 TMDB 集内区分版本的唯一可靠标识是 URL（`docs/phase4/design/04` §8.2）；
    集成测试要断言 `episodeUrl` 优先，就必须让各集地址不同。
    """
    return f"{MEDIA_MP4_URL}?ep={index}"


def _line(flag: str, count: int, offset: int = 0) -> tuple[str, str]:
    episodes = [
        f"第 {i} 集${_episode_url(offset + i)}" for i in range(1, count + 1)
    ]
    return flag, "#".join(episodes)


def _season_line(
    flag: str,
    seasons: list[tuple[int, int]],
    offset: int = 0,
) -> tuple[str, str]:
    """带**显式季度标记**的线路（`第 N 季第 M 集`）。

    季度信号显式存在时，`02` §4.3 的 A1 分支会返回 TMDB 顺序的季度子集，
    使集成测试能稳定构造「第 1 季 12 集 / 第 2 季 10 集」与
    「线路第 2 季只有 8 集」两个场景。
    """
    episodes = []
    index = offset
    for season, count in seasons:
        for number in range(1, count + 1):
            index += 1
            episodes.append(f"第 {season} 季第 {number} 集${_episode_url(index)}")
    return flag, "#".join(episodes)


# 线路一：S1 12 集 + S2 10 集（显式季度标记）。
_TMDB_LINE_1 = _season_line("线路一", [(1, 12), (2, 10)])
# 线路二：S2 只有 8 集（用于断言「TMDB 有 10 集但线路只有 8 集」不补集）。
_TMDB_LINE_2 = _season_line("线路二", [(2, 8)], offset=100)

# 与 `packages/test-fixtures/tmdb/detail-tv.json` 的 `name` 一致 → 自动匹配命中。
TMDB_DETAIL = {
    "list": [
        {
            "vod_id": "tmdb-demo",
            "vod_name": "示例剧集",
            "vod_pic": "",
            "vod_remarks": "S1 12 集 / S2 10 集",
            "vod_content": "站点简介（短）",
            "vod_play_from": "$$$".join([_TMDB_LINE_1[0], _TMDB_LINE_2[0]]),
            "vod_play_url": "$$$".join([_TMDB_LINE_1[1], _TMDB_LINE_2[1]]),
        }
    ],
}

# 集名不含季度信号（无 `第N季`/`SxxExx`），季度必须保持「未确定」。
TMDB_UNKNOWN_DETAIL = {
    "list": [
        {
            "vod_id": "tmdb-unknown",
            "vod_name": "示例剧集",
            "vod_pic": "",
            "vod_play_from": "线路一",
            "vod_play_url": "#".join(
                f"剧集{chr(64 + i)}${_episode_url(i)}" for i in range(1, 6)
            ),
        }
    ],
}

# 标题与 TMDB fixture 无关 → 自动匹配失败，用于手动匹配流程（`04` §5）。
TMDB_NOMATCH_DETAIL = {
    "list": [
        {
            "vod_id": "tmdb-nomatch",
            "vod_name": "无法自动匹配的剧集标题",
            "vod_pic": "",
            "vod_play_from": "线路一",
            "vod_play_url": "#".join(
                f"第 1 季第 {i} 集${_episode_url(i)}" for i in range(1, 7)
            ),
        }
    ],
}

XML_HOME = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0">
  <class id="1">电影</class>
  <class id="2">电视剧</class>
  <list id="demo-1" flag="xml">
    <name>XML 测试视频</name>
    <note>第 1 集</note>
    <pic></pic>
    <dt>第 1 集$http://127.0.0.1:18080/media/sample.m3u8</dt>
  </list>
</rss>
"""

XML_DETAIL = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0">
  <list id="demo-1" flag="xml">
    <name>XML 测试视频</name>
    <note>第 1 集</note>
    <pic></pic>
    <content>仅用于本地契约验证</content>
    <year>2026</year>
    <area>大陆</area>
    <dt>第 1 集$http://127.0.0.1:18080/media/sample.m3u8#第 2 集$http://127.0.0.1:18080/media/sample.mp4</dt>
  </list>
</rss>
"""

XML_CONTENT_TYPE = "application/xml; charset=utf-8"


def _json(name: str) -> bytes:
    return (FIXTURES / name).read_bytes()


def _catjson(name: str) -> bytes:
    return (CATHTTP / name).read_bytes()


def _site_payload(key: str, name: str, kind: int, path: str) -> dict:
    return {
        "key": key,
        "name": name,
        "type": kind,
        "api": f"http://127.0.0.1:18080{path}",
        "searchable": 1,
        "quickSearch": 1,
    }


REPOSITORY_A = {
    "name": "仓库条目 A",
    "notice": "来自 fixture 配置仓库 A",
    "sites": [_site_payload("repo-a", "仓库站点 A", 1, "/api/type1/")],
}

REPOSITORY_B = {
    "name": "仓库条目 B",
    "notice": "来自 fixture 配置仓库 B",
    "sites": [_site_payload("repo-b", "仓库站点 B", 0, "/api/type0/")],
}


class FixtureHandler(BaseHTTPRequestHandler):
    server_version = "WebHTVPCFixture/1.0"

    # ------------------------------------------------------------------ 输出

    def _send_bytes(
        self,
        payload: bytes,
        content_type: str,
        status: int = 200,
        extra_headers: dict | None = None,
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        for key, value in (extra_headers or {}).items():
            # Header 值不能含非 Latin-1（中文站点名等），做安全降级。
            try:
                self.send_header(key, value)
            except UnicodeEncodeError:
                self.send_header(key, value.encode("utf-8").decode("latin-1"))
        self.end_headers()
        self.wfile.write(payload)

    def _send_json_bytes(self, payload: bytes) -> None:
        self._send_bytes(payload, "application/json; charset=utf-8")

    def _send_json(self, value: object, status: int = 200) -> None:
        self._send_json_bytes(json.dumps(value, ensure_ascii=False).encode("utf-8"))
        if status != 200:
            return

    def _send_error_json(self, status: int, message: str) -> None:
        payload = json.dumps({"status": status, "msg": message}).encode("utf-8")
        self._send_bytes(payload, "application/json; charset=utf-8", status=status)

    # ------------------------------------------------------------------ TMDB

    def _send_tmdb(self, path: str, parsed) -> None:
        """TMDB fixture 路由（`docs/phase4/design/05` §2.2）。

        关键设计：把收到的 `api_key` / `Authorization` / `language` /
        `include_image_language` 写入响应头 `X-Fixture-Seen-*`，供 L2 请求捕获
        断言，而不用抓包。

        另提供 `GET /tmdb/__stats` 返回各路由命中次数（JSON），
        供「未配置 / 站点禁用时零请求」的断言使用（`01` §12 第 9 项）。
        """
        route = path.removeprefix("/tmdb").rstrip("/") or "/"
        params = {
            key: values[0]
            for key, values in parse_qs(parsed.query, keep_blank_values=True).items()
        }

        if route == "/__stats":
            self._send_json({
                "counts": dict(TMDB_STATS),
                "total": sum(TMDB_STATS.values()),
            })
            return
        if route == "/__reset":
            TMDB_STATS.clear()
            self._send_json({"counts": {}})
            return
        if route == "/__mode":
            # 故障注入开关（集成测试用）：`/tmdb/__mode?auth=401`。
            auth = params.get("auth")
            if auth in ("401", "off"):
                TMDB_MODE["auth"] = auth
            self._send_json({"mode": dict(TMDB_MODE)})
            return

        TMDB_STATS[route] = TMDB_STATS.get(route, 0) + 1

        headers = {
            "X-Fixture-Seen-ApiKey": params.get("api_key", ""),
            "X-Fixture-Seen-Authorization": self.headers.get("Authorization", ""),
            "X-Fixture-Seen-Language": params.get("language", ""),
            "X-Fixture-Seen-IncludeImageLanguage": params.get(
                "include_image_language", ""
            ),
            "X-Fixture-Seen-Route": route,
        }

        # 故障注入：模拟「所有 TMDB 请求都 401」（验证失败隔离与熔断）。
        if TMDB_MODE.get("auth") == "401" and route.startswith("/3/"):
            self._send_tmdb_error(401, "Invalid API key (injected)", headers)
            return

        if route == "/auth-fail":
            self._send_tmdb_error(401, "Invalid API key", headers)
            return
        if route == "/server-error":
            self._send_tmdb_error(500, "Internal error", headers)
            return
        if route == "/malformed":
            self._send_bytes(
                b"{not-json",
                "application/json; charset=utf-8",
                status=200,
                extra_headers=headers,
            )
            return
        if route == "/configuration":
            self._send_tmdb_fixture("configuration.json", headers)
            return
        if route == "/3/search/multi":
            query = params.get("query", "")
            if query == "empty":
                self._send_tmdb_fixture("search-empty.json", headers)
            elif query == "split":
                self._send_tmdb_fixture("search-split-season.json", headers)
            else:
                self._send_tmdb_fixture("search-multi.json", headers)
            return

        parts = [segment for segment in route.split("/") if segment]
        # /3/tv/{id}/season/{n}/episode/{e} → 7 段
        if (
            len(parts) == 7
            and parts[0] == "3"
            and parts[3] == "season"
            and parts[5] == "episode"
        ):
            self._send_tmdb_fixture("episode-s1e1.json", headers)
            return
        # /3/tv/{id}/season/{n} → 5 段
        if len(parts) == 5 and parts[0] == "3" and parts[3] == "season":
            season = parts[4]
            if season == "9":
                self._send_tmdb_fixture("season-empty.json", headers)
            else:
                self._send_tmdb_fixture(f"season-{season}.json", headers)
            return
        # /3/tv/{id}/videos 与 /3/tv/{id}/season/{n}/videos
        if parts and parts[-1] == "videos":
            self._send_tmdb_fixture("videos-tv.json", headers)
            return
        # /3/{type}/{id}/recommendations|similar?page=N
        if len(parts) == 4 and parts[0] == "3" and parts[3] in (
            "recommendations",
            "similar",
        ):
            page = params.get("page", "1")
            if page == "9":
                self._send_tmdb_fixture("recommendations-empty.json", headers)
            elif page == "2":
                self._send_tmdb_fixture("recommendations-page2.json", headers)
            else:
                self._send_tmdb_fixture("recommendations-page1.json", headers)
            return
        # /3/person/{id}
        if len(parts) == 3 and parts[0] == "3" and parts[1] == "person":
            self._send_tmdb_fixture("person.json", headers)
            return
        # /3/movie/{id}
        if len(parts) == 3 and parts[0] == "3" and parts[1] == "movie":
            self._send_tmdb_fixture("detail-movie.json", headers)
            return
        # /3/tv/{id}
        if len(parts) == 3 and parts[0] == "3" and parts[1] == "tv":
            if parts[2] == "2":
                self._send_tmdb_fixture("detail-tv-next-air.json", headers)
            else:
                self._send_tmdb_fixture("detail-tv.json", headers)
            return

        self._send_tmdb_error(404, f"tmdb fixture route not found: {route}", headers)

    def _send_tmdb_fixture(self, name: str, headers: dict) -> None:
        file = TMDB_FIXTURES / name
        if not file.exists():
            self._send_tmdb_error(404, f"missing fixture: {name}", headers)
            return
        self._send_bytes(
            file.read_bytes(),
            "application/json; charset=utf-8",
            extra_headers=headers,
        )

    def _send_tmdb_error(self, status: int, message: str, headers: dict) -> None:
        payload = json.dumps(
            {"status_code": status, "status_message": message, "success": False},
            ensure_ascii=False,
        ).encode("utf-8")
        self._send_bytes(
            payload,
            "application/json; charset=utf-8",
            status=status,
            extra_headers=headers,
        )

    # -------------------------------------------------------- TMDB 图片 fixture

    def _send_tmdb_image(self, relative: str) -> None:
        """返回一张确定性的占位图片（不依赖 PIL 等第三方库）。

        路径形如 `w342/p1.jpg` 或 `w780/b1.jpg`（对应 `TmdbConfig.imageBase` /
        `backdropBase`）。图片内容由路径哈希决定：同一路径永远得到同一张图，
        不同路径颜色不同，使截图证据能区分「海报 / 剧照 / 头像」三类图。

        为什么需要：`PosterImage` 在加载失败时显示占位图标，仅凭 widget 树
        无法区分「图片真的加载了」与「全部是占位」。集成测试需要真实图片。
        """
        digest = hashlib.sha256(relative.encode("utf-8")).digest()
        size = _image_size_for(relative)
        # 主色由哈希决定；叠加对角亮带与竖向渐变，使图片不是纯色块
        # （纯色块在截图里与占位图难以区分）。
        base = (60 + digest[0] % 120, 60 + digest[1] % 120, 60 + digest[2] % 120)
        accent = (
            min(255, base[0] + 60),
            min(255, base[1] + 60),
            min(255, base[2] + 60),
        )
        rows = bytearray()
        band = max(4, size // 6)
        for y in range(size):
            rows.append(0)  # PNG filter type 0
            shade = y / max(1, size - 1)
            row_base = tuple(
                int(channel * (0.65 + 0.5 * shade)) for channel in base
            )
            row_accent = tuple(
                int(channel * (0.65 + 0.5 * shade)) for channel in accent
            )
            for x in range(size):
                color = row_accent if (x + y) % (band * 2) < band else row_base
                rows.extend(min(255, channel) for channel in color)
        payload = _encode_png(size, size, bytes(rows))
        self._send_bytes(payload, "image/png")

    # ------------------------------------------------------------ 请求解析

    def _request_body(self) -> dict:
        """HTTP API 的 `extend` 超过 1000 字符时改用表单 body（设计文档 §7.4.7）。"""
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return {}
        raw = self.rfile.read(length).decode("utf-8")
        parsed = parse_qs(raw, keep_blank_values=True)
        return {key: values[0] for key, values in parsed.items()}

    def _parameters(self) -> dict:
        parsed = urlparse(self.path)
        params = {
            key: values[0]
            for key, values in parse_qs(parsed.query, keep_blank_values=True).items()
        }
        params.update(self._request_body())
        return params

    # ---------------------------------------------------------------- 路由

    def do_GET(self) -> None:
        self._handle()

    def do_POST(self) -> None:
        self._handle()

    def _handle(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        if path.startswith("/media/"):
            self._send_media(path.removeprefix("/media/"))
            return
        # 直播清单 fixture（§13.3、§19.2 `live.m3u`/`live.txt`）。
        # 清单本身不要求媒体 Header；清单内的播放地址仍指向受 Header 门禁
        # 保护的 `/media/`，从而能同时验证解析与“带 Header 起播”。
        # 兼容两种路径形态：`/live/live.m3u`（约定目录）与 `/live.m3u`
        # （config-full.json 历史写法）。
        # 弹幕 fixture（§21 Phase 3）：与媒体共用一道 Header 门禁，
        # 用于验证「弹幕与视频同源时需要同样的 Referer/UA」。
        if path.startswith("/danmaku/"):
            self._send_danmaku(path.removeprefix("/danmaku/"))
            return
        if path.startswith("/live/"):
            self._send_live(path.removeprefix("/live/"))
            return
        if path.startswith("/live.") and path.rsplit("/", 1)[-1].startswith("live."):
            self._send_live(path.removeprefix("/"))
            return
        if path == "/health":
            self._send_json({"status": "ok"})
            return
        # TMDB 图片 fixture（`docs/phase4/design/05` §2.2 扩展）。
        #
        # 必须在 `/tmdb` 分支**之前**：`/tmdb-img/...` 也以 `/tmdb` 开头，
        # 否则会被 TMDB API 路由吃掉并返回 404 JSON。
        # 作用：让集成测试与截图证据里的海报/剧照/头像**真的能加载**，
        # 而不是只命中 `PosterImage` 的占位图（占位图证明不了布局与背景）。
        if path.startswith("/tmdb-img/"):
            self._send_tmdb_image(path.removeprefix("/tmdb-img/"))
            return
        # TMDB fixture 路由（`docs/phase4/design/05` §2.2）。
        if path.startswith("/tmdb"):
            self._send_tmdb(path, parsed)
            return
        if path == "/api/echo":
            # 回显请求，供契约测试断言 query/form 编码与 Header 注入。
            self._send_json({
                "path": path,
                "method": self.command,
                "params": self._parameters(),
                "headers": {
                    key: value
                    for key, value in self.headers.items()
                    if key.lower().startswith("x-") or key.lower() in ("user-agent", "referer")
                },
            })
            return
        if path == "/api/play":
            self._send_json_bytes(_json("play.json"))
            return
        # 带外挂字幕的播放结果（§10.3）：用于验证 subs 解析/默认选择/丢弃。
        if path == "/api/play-with-subs":
            self._send_json_bytes(_json("play-with-subs.json"))
            return
        # 带弹幕源的播放结果（§21 Phase 3）。
        if path == "/api/play-with-danmaku":
            self._send_json_bytes(_json("play-with-danmaku.json"))
            return
        # 播放结果需要解析器（§12）：parse=1，验证走解析器。
        if path == "/api/play-parse-required":
            self._send_json_bytes(_json("play-parse-required.json"))
            return
        # 解析器端点（§12）：webUrl 拼接在路径后（对齐 Android url+webUrl）。
        if path.startswith("/api/parse/always-error"):
            self._send_bytes(
                b'{"msg": "parse service down"}',
                "application/json; charset=utf-8",
                status=500,
            )
            return
        if path.startswith("/api/parse/type1"):
            suffix = path[len("/api/parse/type1"):]
            if suffix.endswith("/error"):
                self._send_bytes(
                    b'{"msg": "parse service boom"}',
                    "application/json; charset=utf-8",
                    status=500,
                )
                return
            if suffix.endswith("/not-json"):
                self._send_bytes(b"this is not json", "application/json")
                return
            if suffix.endswith("/bad"):
                self._send_json_bytes(b'{"url": ""}')
                return
            self._send_json_bytes(_json("parse-type1.json"))
            return
        if path.startswith("/api/parse/type2"):
            self._send_json_bytes(_json("parse-type1.json"))
            return
        if path == "/api/repository-a.json":
            self._send_json(REPOSITORY_A)
            return
        if path == "/api/repository-b.json":
            self._send_json(REPOSITORY_B)
            return
        if path == "/api/error-html":
            self._send_bytes(
                _json("error-html.html"), "text/html; charset=utf-8", status=502
            )
            return
        if path == "/api/msg":
            self._send_json_bytes(_json("result-msg.json"))
            return
        if path == "/api/filters":
            self._send_json_bytes(_json("filters.json"))
            return
        if path == "/api/multi-flag":
            self._send_json_bytes(_json("result-multi-flag.json"))
            return
        if path == "/api/multi-episode":
            self._send_json_bytes(_json("result-multi-episode.json"))
            return
        if path == "/api/slow":
            # 受控延迟路由，供客户端超时/取消测试使用。
            # 使用可中断等待而非阻塞 sleep：服务关闭时事件会被置位，
            # 不会让测试进程在退出阶段卡住。
            raw_delay = self._parameters().get("delay", "3")
            try:
                delay = max(0.0, min(float(raw_delay), 30.0))
            except ValueError:
                delay = 3.0
            self.server.shutdown_event.wait(delay)  # type: ignore[attr-defined]
            self._send_json_bytes(_json("home.json"))
            return

        # TMDB 集成测试专用详情（`docs/phase4/design/05` §5）。
        #
        # 为什么需要它：既有 `/api/type1` 的详情只有 1 集且名字不含季度信号，
        # 无法构造「多季线路」「TMDB 有 10 集而线路只有 8 集」这类 L3 断言。
        # 这里提供一个**名字与 TMDB fixture 搜索结果一致**的条目，
        # 使自动匹配能命中（`detail-tv.json` 的 `name` 为「示例剧集」）。
        if path == "/api/tmdb-detail":
            self._send_json(TMDB_DETAIL)
            return
        # 季度信号缺失的详情：季度必须保持「未确定」，不得猜测（`02` §2.3）。
        if path == "/api/tmdb-unknown-detail":
            self._send_json(TMDB_UNKNOWN_DETAIL)
            return
        if path == "/api/tmdb-nomatch":
            self._send_json(TMDB_NOMATCH_DETAIL)
            return

        route = path.rstrip("/")
        if route in ("/api/type0", "/api/type1", "/api/type2", "/api/type4"):
            self._send_api(route, self._parameters())
            return

        # `webhtv-cat-http-v1` fixture 路由。
        if path.startswith("/cathttp/"):
            self._send_cathttp(path, self._parameters())
            return

        # Phase 0 兼容路由：保留旧证据的可复现性。
        if path == "/api.php/provide/vod/":
            action = parse_qs(parsed.query).get("ac", [""])[0]
            fixture_by_action = {
                "": "home.json",
                "list": "home.json",
                "category": "category.json",
                "detail": "detail.json",
                "play": "play.json",
                "play-with-subs": "play-with-subs.json",
                "play-with-danmaku": "play-with-danmaku.json",
            }
            fixture = fixture_by_action.get(action)
            if fixture is None:
                self._send_error_json(400, "unsupported fixture action")
                return
            self._send_json_bytes(_json(fixture))
            return

        self._send_error_json(404, "fixture route not found")

    def _send_api(self, route: str, params: dict) -> None:
        """四种 HTTP API 站点的固定响应。

        所有类型都返回同一份语义数据，差异只在请求编码与响应格式：
        type=0 返回 XML，其余返回 JSON。特殊 ids 返回多线路/多剧集/业务错误样本。
        """
        # `type=4` 播放入口（§8.1 分发顺序 4）：`GET <api>?play=<剧集目标>&flag=<线路>`。
        # 真实服务端契约与 Android `SiteApi.playerContent` 的 `type==4` 分支一致。
        if route == "/api/type4" and params.get("play") is not None:
            self._send_type4_play(params)
            return
        if params.get("wd"):
            self._send_json_bytes(_json("category.json"))
            return
        if params.get("ids"):
            vod_id = params["ids"]
            # 慢详情样本（用于「先发后到」的请求竞态，§8.3）：`ids=slow-<x>` 延迟
            # 返回，并把 id 回显到 `vod_id`，便于分辨返回的是哪一次请求。
            if vod_id.startswith("slow-"):
                try:
                    delay = float(params.get("delay") or 1.2)
                except (TypeError, ValueError):
                    delay = 1.2
                time.sleep(min(max(delay, 0.0), 30.0))
                self._send_json({
                    "list": [{
                        "vod_id": vod_id,
                        "vod_name": f"慢详情 {vod_id}",
                        "vod_content": "迟到的详情结果",
                        "vod_play_from": "慢线路",
                        "vod_play_url": "第1集$" + MEDIA_MP4_URL,
                    }],
                })
                return
            if route == "/api/type0":
                self._send_bytes(
                    XML_DETAIL.encode("utf-8"), XML_CONTENT_TYPE
                )
                return
            if vod_id == "multi-1":
                self._send_json_bytes(_json("result-multi-flag.json"))
                return
            if vod_id == "episodes-1":
                self._send_json_bytes(_json("result-multi-episode.json"))
                return
            if vod_id == "msg-1":
                self._send_json_bytes(_json("result-msg.json"))
                return
            if vod_id == "subs-1":
                self._send_json_bytes(_json("play-with-subs.json"))
                return
            if vod_id == "danmaku-1":
                self._send_json_bytes(_json("play-with-danmaku.json"))
                return
            self._send_json_bytes(_json("detail.json"))
            return
        if params.get("t"):
            self._send_json_bytes(_json("category.json"))
            return
        if route == "/api/type0":
            self._send_bytes(XML_HOME.encode("utf-8"), XML_CONTENT_TYPE)
            return
        self._send_json_bytes(_json("home.json"))

    def _send_type4_play(self, params: dict) -> None:
        """`type=4` 播放入口样本族（按剧集目标分派）。

        - `t4-direct` → `parse=0` 的真实媒体地址 + 媒体 Header；
        - `t4-parse`  → `parse=1`（须继续走 §12 解析器）；
        - `t4-nourl`  → 播放入口没给地址（不得回退到剧集目标，应如实报错）；
        - 其余 → 回显 `play`/`flag`/`extend`，供断言实际发出的参数。
        """
        target = params.get("play", "")
        if target == "t4-direct":
            self._send_json_bytes(_json("t4-play-direct.json"))
            return
        if target == "t4-parse":
            self._send_json_bytes(_json("t4-play-parse.json"))
            return
        if target == "t4-nourl":
            self._send_json({"parse": 0, "jx": 0})
            return
        if target == "t4-bizerr":
            self._send_json({
                "url": "1",
                "parse": 1,
                "jx": 1,
                "msg": "Request failed with status code 403",
            })
            return
        self._send_json({
            "ac": params.get("ac"),
            "play": target,
            "flag": params.get("flag"),
            "extend": params.get("extend"),
        })

    def _send_cathttp(self, path: str, params: dict) -> None:
        """`webhtv-cat-http-v1` fixture（§9.4）。

        三个可重复样本族：
        - 成功（home/category/detail/search/play，含信封与数组两种形态）；
        - 业务错误（`{code:非0,msg}`）；
        - 非 2xx 与未实现路由（404/501）。
        """
        route = path.removeprefix("/cathttp").rstrip("/") or "/home"
        mapping = {
            "/home": "home.json",
            "/home-envelope": "home-envelope.json",
            "/category": "category.json",
            "/detail": "detail.json",
            "/search": "search.json",
            "/search-array": "search-array.json",
            "/play": "play.json",
            "/error": "result-business-error.json",
        }
        if route == "/init":
            self._send_json({"status": "ok", "abi": "webhtv-cat-http-v1"})
            return
        if route == "/server-error":
            self._send_error_json(502, "上游网关错误")
            return
        if route == "/page-echo":
            self._send_json_bytes(_catjson("page-echo.json"))
            return
        fixture = mapping.get(route)
        if fixture is None:
            # 未实现的 cat http 路由必须返回 404/501，客户端映射为
            # SPIDER_UNSUPPORTED，而不是空列表（§9.4）。
            self._send_error_json(404, "cat http 路由未实现")
            return
        self._send_json_bytes(_catjson(fixture))

    def _send_live(self, relative_path: str) -> None:
        candidate = (LIVE / relative_path).resolve()
        if LIVE.resolve() not in candidate.parents or not candidate.is_file():
            self._send_error_json(404, "live fixture not found")
            return
        payload = candidate.read_bytes()
        content_type = mimetypes.guess_type(candidate.name)[0] or "application/octet-stream"
        if candidate.suffix in (".m3u", ".txt"):
            content_type = "audio/x-mpegurl; charset=utf-8"
        if candidate.suffix == ".json":
            content_type = "application/json; charset=utf-8"
        # EPG（§13.3）是 XMLTV；.xml.gz 按 gzip 分发（客户端靠魔数解压）。
        if candidate.suffix == ".xml":
            content_type = "application/xml; charset=utf-8"
        if candidate.suffix == ".gz":
            content_type = "application/gzip"
        self._send_bytes(payload, content_type)

    def _send_danmaku(self, relative_path: str) -> None:
        referer = self.headers.get("Referer")
        user_agent = self.headers.get("User-Agent")
        if referer != REQUIRED_REFERER:
            self._send_error_json(403, "required Referer header missing")
            return
        if user_agent not in (REQUIRED_USER_AGENT, LEGACY_USER_AGENT):
            self._send_error_json(403, "required User-Agent header missing")
            return
        candidate = (DANMAKU / relative_path).resolve()
        if DANMAKU.resolve() not in candidate.parents or not candidate.is_file():
            self._send_error_json(404, "danmaku fixture not found")
            return
        payload = candidate.read_bytes()
        if candidate.suffix == ".xml":
            content_type = "application/xml; charset=utf-8"
        else:
            content_type = "text/plain; charset=utf-8"
        self._send_bytes(payload, content_type)

    def _send_media(self, relative_path: str) -> None:
        referer = self.headers.get("Referer")
        user_agent = self.headers.get("User-Agent")
        if referer != REQUIRED_REFERER:
            self._send_error_json(403, "required Referer header missing")
            return
        if user_agent not in (REQUIRED_USER_AGENT, LEGACY_USER_AGENT):
            self._send_error_json(403, "required User-Agent header missing")
            return
        # 允许带 query（真实站源的签名 URL / cache buster 很常见；TMDB 集成测试
        # 用 `?ep=N` 给每集一个互不相同的地址，以验证 `episodeUrl` 优先定位）。
        # 只按**路径部分**映射到 fixture 文件，不做任何其他解释。
        relative_path = urlparse(relative_path).path
        candidate = (MEDIA / relative_path).resolve()
        if MEDIA.resolve() not in candidate.parents or not candidate.is_file():
            self._send_error_json(404, "media fixture not found")
            return
        payload = candidate.read_bytes()
        content_type = mimetypes.guess_type(candidate.name)[0] or "application/octet-stream"
        if candidate.suffix == ".srt":
            # Python 的 mimetypes 把 .srt 当 text/plain；SubRip 有自己的类型，
            # 这里显式声明，让客户端能验证 Content-Type → 格式推断这条分支。
            content_type = "application/x-subrip; charset=utf-8"
        if candidate.suffix == ".ass" or candidate.suffix == ".ssa":
            content_type = "text/x-ssa; charset=utf-8"
        self._send_bytes(payload, content_type)

    def log_message(self, format_string: str, *args) -> None:
        print(f"{self.address_string()} - {format_string % args}")


class FixtureServer(ThreadingHTTPServer):
    """带可中断等待事件的本地 fixture 服务。

    `shutdown_event` 让 `/api/slow` 这类受控延迟路由能在服务关闭时立即返回，
    避免测试进程在 teardown 阶段被阻塞等待。
    """

    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], handler: type[BaseHTTPRequestHandler]):
        super().__init__(address, handler)
        self.shutdown_event = threading.Event()

    def server_close(self) -> None:
        self.shutdown_event.set()
        super().server_close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18080)
    args = parser.parse_args()
    if args.host not in ("127.0.0.1", "localhost", "::1"):
        parser.error("fixture 服务只允许监听本机地址")
    server = FixtureServer((args.host, args.port), FixtureHandler)
    print(f"WebHTV PC fixture server: http://{args.host}:{args.port}")
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
