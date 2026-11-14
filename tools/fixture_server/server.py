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
import contextlib
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
# 安卓 T4 网关 fixture 根目录（`docs/phase5/design/03` §2.1）。
ANDROID_FIXTURES = ROOT / "packages" / "test-fixtures" / "android"
# 安卓路由命中计数与**最近一次**收到的表单字段（`/android/__stats`，§2.3）。
# 为什么记表单字段：PC 推送给安卓时，断言点在"发出去的形态"
# （`mode`/`type`/表单是否含 `settings`），记下来就不用抓包。
ANDROID_STATS: dict[str, int] = {}
ANDROID_LAST_FORM: dict[str, str] = {}
ANDROID_LAST_QUERY: dict[str, str] = {}
# 每条路由最近一次请求的 `Host` 头（P2 的现场证据：站点地址由请求的 Host 现算）。
ANDROID_LAST_HOST: dict[str, str] = {}
# 安卓故障注入模式（`/android/__mode?config=<mode>`，§2.3 表）。
#   ok(默认) / 404 / empty / mismatch / loopback / repo / notandroid / slow / 403
# `403` 专用于 `/action`：模拟安卓"本机 API 修改未开启"。
# Phase 7 新增（`docs/phase7/design/04` §4）：
#   no-episode-url / empty-episode  路径 A 的集消歧兜底
#   stopped       `/manage/session` 返 `running=false`（管理页未运行）
#   no-manage     `/manage/session` 返 404（旧版安卓 → 降级到 `/device`）
#   with-deletions `/api/playback/sync` 响应带删除数组
ANDROID_MODE: dict[str, str] = {}
ANDROID_MODES = {
    "ok",
    "404",
    "empty",
    "mismatch",
    "loopback",
    "repo",
    "notandroid",
    "slow",
    "403",
    "no-episode-url",
    "empty-episode",
    "stopped",
    "no-manage",
    "with-deletions",
}
# 每条路由**最近一次**收到的请求头（路径 B 的断言点在 `X-WebHTV-*`，
# `docs/phase7/design/01` §3.2.2；记下来就不用抓包）。
ANDROID_LAST_HEADERS: dict[str, dict[str, str]] = {}
# 路径 B 拉取端点的服务端游标（模拟安卓侧保存的 cursor）。
# 每次 `/android/api/playback/sync` 成功返回后推进，供"第二轮只拿到新增"的断言用。
ANDROID_SYNC_STATE: dict[str, int] = {"sequence": 0}

# `configKey`（安卓 `interfaceKey`）→ 该源的站点清单 fixture（方案 B）。
# 两个 type=0 源的站点集合必须**不同**，否则「按源隔离 / 切换」的断言会空转。
CONFIG_KEY_FIXTURES = {
    "fixture-vod-a": "gateway-config.json",
    "fixture-vod-b": "gateway-config-source-b.json",
}

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


def _json_file(path: Path, host: str) -> bytes:
    """读取 JSON fixture 并把 `__HOST__` 占位符替换为请求的 `Host`。

    占位符机制（`docs/phase5/design/03` §2.2）：真实地址随环境变化，写死会让
    同一份 fixture 无法同时服务"主机一致"与"主机不一致"两个用例。
    """
    text = path.read_text(encoding="utf-8").replace("http://__HOST__", f"http://{host}")
    return text.encode("utf-8")


def _json_object(path: Path) -> dict:
    """读取一个 JSON **对象** fixture；缺失/损坏时抛 [FixtureDataError]。

    为什么需要它（而不是裸 `json.loads(read_text())`）：
    - 裸写在 fixture 文件缺失/写坏时会让**请求线程**抛异常，
      调用方只看到一个无头无尾的 500，不知道是哪个 fixture 坏了；
    - 集中一处也能保证编码与错误文案一致（中文路径在 Windows 上易踩坑）。
    """
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise FixtureDataError(f"fixture 缺失：{path.name}") from error
    except (OSError, ValueError) as error:
        raise FixtureDataError(f"fixture 不是合法 JSON：{path.name}（{error}）") from error
    if not isinstance(value, dict):
        raise FixtureDataError(f"fixture 不是 JSON 对象：{path.name}")
    return value


def _json_array(path: Path) -> list:
    """读取一个 JSON **数组** fixture；缺失/损坏时抛 [FixtureDataError]。"""
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise FixtureDataError(f"fixture 缺失：{path.name}") from error
    except (OSError, ValueError) as error:
        raise FixtureDataError(f"fixture 不是合法 JSON：{path.name}（{error}）") from error
    if not isinstance(value, list):
        raise FixtureDataError(f"fixture 不是 JSON 数组：{path.name}")
    return value


class FixtureDataError(RuntimeError):
    """fixture 数据不可用（缺失/损坏/形态不符）。"""


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

    # ---------------------------------------------------------------- 安卓

    def _send_android(self, path: str, parsed, *, canonical: bool) -> None:
        """安卓 T4 网关与服务端 fixture（`docs/phase5/design/03` §2.3）。

        [canonical] 为真时是 `/android/**` 规范命名空间（含 `__stats` 等测试开关）；
        为假时是根路径别名 `/device`、`/vod/api`、`/action`。
        """
        route = path.rstrip("/") or "/"
        params = {
            key: values[0]
            for key, values in parse_qs(parsed.query, keep_blank_values=True).items()
        }

        if canonical and route == "/__stats":
            self._send_json({
                "counts": dict(ANDROID_STATS),
                "total": sum(ANDROID_STATS.values()),
                "lastForm": dict(ANDROID_LAST_FORM),
                "lastQuery": dict(ANDROID_LAST_QUERY),
                "lastHost": dict(ANDROID_LAST_HOST),
                "lastHeaders": {
                    key: dict(value) for key, value in ANDROID_LAST_HEADERS.items()
                },
                "syncSequence": ANDROID_SYNC_STATE.get("sequence", 0),
                "mode": dict(ANDROID_MODE),
            })
            return
        if canonical and route == "/__reset":
            ANDROID_STATS.clear()
            ANDROID_LAST_FORM.clear()
            ANDROID_LAST_QUERY.clear()
            ANDROID_LAST_HOST.clear()
            ANDROID_LAST_HEADERS.clear()
            ANDROID_SYNC_STATE["sequence"] = 0
            ANDROID_MODE.clear()
            self._send_json({"counts": {}})
            return
        if canonical and route == "/__mode":
            key = "content" if "content" in params else "config"
            value = params.get(key, "ok")
            if value in ANDROID_MODES:
                ANDROID_MODE["config"] = value
            self._send_json({"mode": dict(ANDROID_MODE)})
            return

        mode = ANDROID_MODE.get("config", "ok")
        host = self.headers.get("Host") or "127.0.0.1:18080"

        if route == "/device":
            ANDROID_STATS["/device"] = ANDROID_STATS.get("/device", 0) + 1
            ANDROID_LAST_HOST["/device"] = host
            if mode == "notandroid":
                self._send_json({"hello": "world"})
                return
            payload = _json_object(ANDROID_FIXTURES / "device.json")
            # `ip` 按请求的 `Host` 现算：真实网关与 `/device` 都报告"对端可达地址"，
            # 写死会把 PC 引到一个不存在的地址上。
            payload["ip"] = f"http://{host}"
            self._send_json(payload)
            return

        if route == "/vod/api":
            action = params.get("ac", "")
            key = params.get("key", "")
            config_key = params.get("configKey", "")
            name = f"/vod/api?ac={action}" if action else f"/vod/api?key={key}"
            if config_key and not key:
                # 多源请求必须能被单独统计，否则"到底取没取第二个源"无法断言。
                name = f"/vod/api?ac={action}&configKey={config_key}"
            ANDROID_STATS[name] = ANDROID_STATS.get(name, 0) + 1
            ANDROID_LAST_HOST[name] = host

            if key:
                self._send_json_bytes(
                    _json_file(ANDROID_FIXTURES / "vod-home.json", host)
                )
                return
            # 故障注入**先于**按源取清单：故障是"设备级"的（404/超时/空站点），
            # 每个源都会以同样方式失败，PC 侧才能把「设备坏了」与「某个源坏了」
            # 区分开（`docs/phase5/design/04` §2.3）。
            if mode == "404":
                self._send_error_json(404, "not found")
                return
            if mode == "slow":
                time.sleep(5)
            injected = {
                "empty": "gateway-config-empty.json",
                "mismatch": "gateway-config-mismatch.json",
                "loopback": "gateway-config-loopback.json",
                "repo": "gateway-config-repo.json",
            }.get(mode)
            if injected is not None:
                self._send_json_bytes(_json_file(ANDROID_FIXTURES / injected, host))
                return
            # 方案 B（`docs/phase5/design/04` §2.2）：按 `configKey` 返回**指定源**
            # 的站点清单，而不是当前激活源。真实安卓的 `VodApi` 用
            # `VodSiteCatalog` 做无副作用解析，未命中时原样回 `{"msg": ...}`。
            if config_key:
                ANDROID_LAST_QUERY.clear()
                ANDROID_LAST_QUERY.update(params)
                fixture = CONFIG_KEY_FIXTURES.get(config_key)
                if fixture is None:
                    self._send_json({"msg": f"未知的配置标识: {config_key}"})
                    return
                self._send_json_bytes(_json_file(ANDROID_FIXTURES / fixture, host))
                return
            # 关键契约：站点 `api` 的主机由**请求的 `Host` 头**现算
            # （`docs/phase5/design/00` §3.2 实测）。
            # `ac=config` 与 `ac=site` 返回**字节相同**（§3.2 第 3 条）。
            self._send_json_bytes(
                _json_file(ANDROID_FIXTURES / "gateway-config.json", host)
            )
            return

        if route == "/action":
            ANDROID_STATS["/action"] = ANDROID_STATS.get("/action", 0) + 1
            ANDROID_LAST_HOST["/action"] = host
            ANDROID_LAST_QUERY.clear()
            ANDROID_LAST_QUERY.update(params)
            if self.command == "POST":
                ANDROID_LAST_FORM.clear()
                ANDROID_LAST_FORM.update(self._request_body())
            if mode == "403":
                self._send_bytes(
                    "本机 API 修改未开启".encode(),
                    "text/plain; charset=utf-8",
                    status=403,
                )
                return
            self._send_bytes(
                b"OK applied=3 skipped=0 failed=0 total=3",
                "text/plain; charset=utf-8",
            )
            return

        # ------------------------------------------------------------
        # Phase 7 · 路径 A 与保活（`docs/phase7/design/01` §4.1、`02` §3）
        # ------------------------------------------------------------
        if route in ("/api/playback/history", "/api/playback/current"):
            self._send_playback_read(route, params, host, mode)
            return
        if route == "/manage/configs":
            # 方案 B（`docs/phase5/design/04` §2.2）：列出**全部**配置（type 0/1/2），
            # 让 PC 能把安卓的每个点播源都变成一条本地记录。真实安卓
            # `Manage.configs` 还兼作写入口（带 `url` 参数）；fixture 只读。
            self._record_android_request("/manage/configs", host, params)
            self._send_json_bytes(_json_file(ANDROID_FIXTURES / "manage-configs.json", host))
            return
        if route == "/manage/session":
            self._send_manage_session(host, mode)
            return
        if route == "/manage/background/settings":
            # **不得**真做任何事：真实端会弹安卓系统界面（`design/02` §5.1
            # 的 L5）。fixture 只记录调用次数，让测试能断言"只在用户点击时调"。
            ANDROID_STATS["/manage/background/settings"] = (
                ANDROID_STATS.get("/manage/background/settings", 0) + 1
            )
            self._send_json({"status": "ok", "settings": "opened"})
            return
        if route == "/api/playback/sync":
            self._send_playback_pull(params, mode)
            return

        self._send_error_json(404, "android fixture route not found")

    def _record_android_request(self, name: str, host: str, params) -> None:
        """记一次命中：计数 + Host + 查询参数 + 请求头（含 `X-WebHTV-*`）。"""
        ANDROID_STATS[name] = ANDROID_STATS.get(name, 0) + 1
        ANDROID_LAST_HOST[name] = host
        ANDROID_LAST_QUERY.clear()
        ANDROID_LAST_QUERY.update(params)
        ANDROID_LAST_HEADERS[name] = {
            key.lower(): value
            for key, value in self.headers.items()
            if key.lower().startswith(("x-webhtv", "host", "accept", "content-type"))
        }

    def _send_playback_read(self, route: str, params, host: str, mode: str) -> None:
        """路径 A 的读取端点（`design/01` §4.1）。

        两条关键契约（都是真机实测出来的，写错会让 PC 静默拿空结果）：
        1. `/api/playback/history` **对任一 siteKey 都返回 200 + 数组**，
           从不 404——因此它一旦"不存在"必须是 200+octet-stream 形态；
        2. `/api/playback/current` 未播放时返回 **404 + JSON**（合法形态，
           不是失败），PC 不许把它算进退避。
        """
        name = route
        self._record_android_request(name, host, params)
        site_key = params.get("siteKey", "")
        if mode == "slow":
            time.sleep(5)
        if mode == "403":
            # 鉴权失败（`design/01` §6.3：立即停该方向，重试无意义）。
            # 与 `/action`、路径 B 的 403 同义，让 PC 侧的「403 → 停方向」
            # 能在**路径 A**上被端到端验证（L3 实测需要）。
            self._send_error_json(403, "unauthorized")
            return

        if route == "/api/playback/current":
            if mode == "404":
                self._send_error_json(404, "no playback record")
                return
            payload = _json_object(ANDROID_FIXTURES / "playback-current.json")
            payload["siteKey"] = site_key or payload["siteKey"]
            if isinstance(payload.get("historyKey"), str):
                # 身份键里的 siteKey 段要跟着回显的 siteKey 一致，
                # 否则 PC 会拿两套 siteKey 去定位同一条记录。
                parts = payload["historyKey"].split("@@@")
                if len(parts) == 3:
                    payload["historyKey"] = "@@@".join(
                        [payload["siteKey"], parts[1], parts[2]]
                    )
            for field in ("vodPic", "episodeUrl"):
                if isinstance(payload.get(field), str):
                    payload[field] = payload[field].replace(
                        "http://__HOST__", f"http://{host}"
                    )
            # 故障注入：`apiSafe()` 的 `episodeUrl` 不对外开放（它在 FULL/OPTIONAL 集），
            # 默认形态本来就没有它——真实对端靠 `episodeId` 消歧。
            # `no-episode-url` = 连 `episodeId` 也没有（旧版安卓）→ PC 用
            # `episodeName` 兜底；`empty-episode` = 集名也空 → 必须不合并。
            if mode == "no-episode-url":
                payload.pop("episodeUrl", None)
                payload.pop("episodeId", None)
            elif mode == "empty-episode":
                payload.pop("episodeUrl", None)
                payload.pop("episodeId", None)
                payload["episodeName"] = ""
            self._send_json(payload)
            return

        # `/api/playback/history`
        if mode == "empty":
            self._send_json({"siteKey": site_key, "items": [], "total": 0})
            return
        if mode == "404":
            # 真实安卓**不会**这里返 404；保留该模式仅用于测 PC 的错误分支
            # （403/404 不得折叠成"0 条"，`design/01` §4.1 的 P5）。
            self._send_error_json(404, "history endpoint missing")
            return
        items = _json_array(ANDROID_FIXTURES / "history-android.json")
        # 按 `siteKey` **过滤**（真实安卓的 `/history?siteKey=` 就是按站点查的）。
        #
        # 不过滤的后果（L3 实测）：引擎一轮会打 20 个站点，每个都拿到全部 3 条
        # （60 条），而其中 1 条的 `vodRemarks`/`episodeUrl` 双空 → PC 正确地
        # 「宁可不合」记为 failed → 整轮归为 `partial` → **游标不推进**。
        # 于是「第二轮只拉增量」永远无法成立，测试看起来像产品缺陷。
        if site_key:
            items = [
                record
                for record in items
                if str(record.get("key", "")).split("@@@")[0] == site_key
            ]
        for record in items:
            for field in ("vodPic", "episodeUrl"):
                if isinstance(record.get(field), str):
                    record[field] = record[field].replace(
                        "http://__HOST__", f"http://{host}"
                    )
            if mode == "no-episode-url":
                record.pop("episodeUrl", None)
            elif mode == "empty-episode":
                record.pop("episodeUrl", None)
                record["vodRemarks"] = ""
        self._send_json({"siteKey": site_key, "items": items, "total": len(items)})

    def _send_manage_session(self, host: str, mode: str) -> None:
        """保活会话端点（`design/02` §3.2）。"""
        self._record_android_request("/manage/session", host, {})
        if mode == "no-manage":
            # 旧版安卓没有该端点 → PC 必须降级到 `/device` 心跳。
            self._send_error_json(404, "manage session not available")
            return
        if mode == "slow":
            time.sleep(5)
        payload = _json_object(ANDROID_FIXTURES / "manage-session.json")
        payload["lastAccess"] = int(time.time() * 1000)
        if mode == "stopped":
            payload["running"] = False
        self._send_json(payload)

    def _send_playback_pull(self, params, mode: str) -> None:
        """路径 B 的拉取端点（`design/01` §3.2.2）。

        按 `X-WebHTV-Since` 返回增量：`nextSince` 是**单调递增的序号**
        （不是时间戳，`design/00` §3.1 契约 9），空游标 = 0。
        """
        host = self.headers.get("Host") or "127.0.0.1:18080"
        header_since = self.headers.get("X-WebHTV-Since", "")
        header_limit = self.headers.get("X-WebHTV-Limit", "")
        merged = {
            "since": header_since or params.get("since", ""),
            "limit": header_limit or params.get("limit", ""),
        }
        self._record_android_request("/api/playback/sync", host, merged)

        if mode == "403":
            self._send_error_json(403, "token mismatch")
            return
        if mode == "slow":
            time.sleep(5)

        raw_since = merged["since"].strip()
        try:
            since = int(raw_since) if raw_since else 0
            if since < 0:
                raise ValueError
        except ValueError:
            self._send_error_json(400, "Invalid X-WebHTV-Since cursor")
            return

        sequence = ANDROID_SYNC_STATE.get("sequence", 0)
        if mode == "empty":
            self._send_json({"nextSince": since, "items": [], "hasMore": False})
            return

        sequence += 1
        ANDROID_SYNC_STATE["sequence"] = sequence
        item = {
            "historyKey": "csp_Media@@@demo-001@@@1",
            "siteKey": "csp_Media",
            "vodId": "demo-001",
            "vodName": "示例剧集",
            "vodPic": f"http://{host}/media/poster-001.jpg",
            "flag": "线路一",
            "episodeName": "第2集",
            "episodeId": "episode-hash-001",
            "positionMs": 754000,
            "durationMs": 2700000,
            "completed": False,
            "speed": 1.0,
            # 关键：`updatedAt` 显式给（安卓 `PlaybackProgressWriter` 用它
            # 做 `setCreateTime` 与冲突裁决）。
            "updatedAt": 1791450000000 + sequence,
        }
        payload: dict[str, object] = {
            "nextSince": item["updatedAt"],
            "items": [] if since >= item["updatedAt"] else [item],
            "hasMore": False,
        }
        if mode == "with-deletions":
            payload["deleted"] = [
                {
                    "historyKey": "csp_Media@@@demo-999@@@1",
                    "deletedAt": 1791450000999,
                }
            ]
        self._send_json(payload)


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

        # `wide*` 前缀 → 16:9 横图，且**上下各有一条纯色标记带**。
        #
        # 为什么需要（2026-10-13）：详情页背景原先是单层 `BoxFit.cover`，
        # 在比素材更扁的框里会纵向裁切；而原有 fixture 全是 1:1 方图，
        # **截图里根本看不出裁没裁**。这条标记带让裁切变成肉眼可见的事实：
        # 红色顶带或蓝色底带缺了，就是被裁了。
        if relative.split("/")[-1].startswith("wide"):
            return self._send_wide_backdrop(size)

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

    def _send_wide_backdrop(self, size: int) -> None:
        """16:9 横图 + 上下标记带，用来**目视证明背景有没有被裁切**。

        红顶带 / 蓝底带各占高度 10%。`BoxFit.cover` 在更扁的框里会切掉它们；
        两层铺法（模糊垫底 + `contain` 主体）必须两条都完整可见。

        固定 640x360 而不是跟着 `size` 走：这样框比**恰好是真实素材的 16:9**
        （TMDB 后景就是 16:9），截图才有代表性；640 宽也够看清标记带与网格线。
        """
        width, height = 640, 360
        band = max(4, height // 10)
        rows = bytearray()
        for y in range(height):
            rows.append(0)  # PNG filter type 0
            if y < band:
                color = (220, 40, 40)  # 顶带：红
            elif y >= height - band:
                color = (40, 80, 220)  # 底带：蓝
            else:
                # 中段：竖向渐变 + 细网格，便于判断缩放比例
                shade = 0.55 + 0.45 * (y / max(1, height - 1))
                color = (
                    int(150 * shade),
                    int(170 * shade),
                    int(120 * shade),
                )
            grid = band <= y < height - band
            for x in range(width):
                if grid and x % 80 < 2:
                    rows.extend((240, 240, 240))  # 白色竖网格线
                else:
                    rows.extend(color)
        self._send_bytes(_encode_png(width, height, bytes(rows)), "image/png")

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
        # 安卓 T4 网关 fixture（`docs/phase5/design/03` §2.3）。
        #
        # 两种挂载点都必须有：
        # - `/android/**`：规范命名空间，供预检脚本与契约测试用；
        # - 根路径别名：**PC 客户端实际请求的路径**。
        #   PC 的 `normalizeBase` 只保留 scheme+host+port（`design/01` §4.2），
        #   会把 `/android` 前缀丢掉，所以集成测试的 base 只能用根路径形态。
        #
        # ⚠️ Phase 7 新增的 5 个路由（`/api/playback/*`、`/manage/*`）**同样**
        # 必须有根别名：否则 PC 打的是 `/api/playback/history`，fixture 只在
        # `/android/api/playback/history` 上应答，于是得到 404 → 被 PC 判成
        # 「端点不存在」→ 心跳降级、拉取报 `realtimePullUnsupported`。
        # 实测现象：`heartbeat(state=ok status=404 ... running=null)`。
        if path.startswith("/android"):
            self._send_android(path.removeprefix("/android"), parsed, canonical=True)
            return
        if path in ("/device", "/vod/api", "/action") or path.startswith(
            ("/api/playback/", "/manage/")
        ):
            self._send_android(path, parsed, canonical=False)
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
        if route in (
            "/api/type0",
            "/api/type1",
            "/api/type2",
            "/api/type4",
            # 分页/空结果样本（搜索分页门禁与会验用，§14.1）。
            # 与 type1 共用 `_send_api` 分派，仅 `wd` 分支的响应不同，
            # 保持与 Dart 侧 `test/support/test_fixture_server.dart` 一致（§19）。
            "/api/paged",
            "/api/empty",
        ):
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
        # 空结果样本：站点成功但零条目（验证「零结果站点不允许翻页」）。
        if route == "/api/empty":
            self._send_json({
                "page": 1,
                "pagecount": 1,
                "limit": 20,
                "total": 0,
                "list": [],
            })
            return
        # 分页样本（§14.1）：`pg` 决定内容，`pagecount` 声明总页数，
        # `repeatAfterFirst=true` 时第 2 页起重复第 1 页内容——上游站点在
        # 「越界页码」时常返回末页内容，分页逻辑必须靠内容重复判耗尽。
        if route == "/api/paged":
            try:
                page = max(1, int(params.get("pg") or 1))
            except ValueError:
                page = 1
            try:
                pagecount = max(0, int(params.get("pageCount") or 0))
            except ValueError:
                pagecount = 0
            repeat = params.get("repeatAfterFirst") == "true"
            effective = 1 if repeat else page
            self._send_json({
                "page": page,
                "pagecount": pagecount,
                "limit": 20,
                "total": 0,
                "list": [
                    {
                        "vod_id": f"paged-{effective}",
                        "vod_name": f"分页条目{effective}",
                        "vod_pic": "",
                        "vod_remarks": f"第 {effective} 页",
                    }
                ],
            })
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
        if candidate.suffix == ".json":
            # 直播配置文档（`lives` 清单）里的地址同样要按请求的 `Host` 现算，
            # 与 `/vod/api?ac=config` 的站点 `api` 保持同一口径。
            host = self.headers.get("Host") or "127.0.0.1:18080"
            payload = payload.replace(
                b"http://__HOST__", f"http://{host}".encode()
            )
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

    def log_message(self, format: str, *args) -> None:  # noqa: A002 (需与基类同名)
        print(f"{self.address_string()} - {format % args}")


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
    parser.add_argument(
        "--tcp-mode",
        default="off",
        choices=("off", "tcp-accept-silent", "tcp-closed"),
        help=(
            "TCP 层故障注入（`docs/phase7/design/04` §4）："
            "tcp-accept-silent 只 accept 不回响应（模拟 PEER_FROZEN）；"
            "tcp-closed 不监听该端口（模拟 SERVICE_STOPPED）"
        ),
    )
    parser.add_argument(
        "--tcp-port",
        type=int,
        default=18081,
        help="--tcp-mode 使用的端口（与 --port 分开，避免干扰正常路由）",
    )
    args = parser.parse_args()
    if args.host not in ("127.0.0.1", "localhost", "::1"):
        parser.error("fixture 服务只允许监听本机地址")

    tcp_stop = threading.Event()
    tcp_thread: threading.Thread | None = None
    if args.tcp_mode == "tcp-accept-silent":
        tcp_thread = threading.Thread(
            target=_serve_tcp_accept_silent,
            args=(args.host, args.tcp_port, tcp_stop),
            daemon=True,
        )
        tcp_thread.start()
        print(
            f"WebHTV PC fixture TCP mode: tcp-accept-silent on "
            f"{args.host}:{args.tcp_port}（accept 后永不响应 → PEER_FROZEN）"
        )
    elif args.tcp_mode == "tcp-closed":
        # 故意**不**监听：PC 那里得到 connection refused（→ SERVICE_STOPPED）。
        # 打印出来是为了让调用方知道该把 base 指向哪个“肯定没人听”的端口。
        print(
            f"WebHTV PC fixture TCP mode: tcp-closed on "
            f"{args.host}:{args.tcp_port}（端口不监听 → SERVICE_STOPPED）"
        )

    server = FixtureServer((args.host, args.port), FixtureHandler)
    print(f"WebHTV PC fixture server: http://{args.host}:{args.port}")
    try:
        server.serve_forever()
    finally:
        tcp_stop.set()
        if tcp_thread is not None:
            tcp_thread.join(timeout=2)
        server.server_close()


def _serve_tcp_accept_silent(host: str, port: int, stop: threading.Event) -> None:
    """只 `accept()`、永不回任何字节的裸 TCP 服务。

    这是 PC 侧区分「进程被冻结」与「网络不通」的**唯一**手段
    （`design/02` §4）：冻结时内核仍完成三次握手，但用户态不调度、
    HTTP 响应出不来；网络不通时握手本身就失败。

    实现约束：每个连接都留在列表里不关，否则对方会看到 FIN（那就变成了
    “连上又断开”而不是“连上但不应”）。退出时统一关闭。
    """
    import socket

    held: list[socket.socket] = []
    server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server_socket.bind((host, port))
    server_socket.listen(16)
    server_socket.settimeout(0.2)
    try:
        while not stop.is_set():
            try:
                connection, _ = server_socket.accept()
            except TimeoutError:
                continue
            except OSError:
                break
            # 收下连接但什么都不发：这正是“被冻结”的观测形态。
            held.append(connection)
    finally:
        for connection in held:
            with contextlib.suppress(OSError):
                connection.close()
        server_socket.close()


if __name__ == "__main__":
    main()
