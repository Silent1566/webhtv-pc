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
import json
import mimetypes
import threading
import time
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
REQUIRED_REFERER = "http://127.0.0.1:18080/"
REQUIRED_USER_AGENT = "WebHTV-PC/0.1 (Windows)"
LEGACY_USER_AGENT = "WebHTV-PC-Phase0"

MEDIA_URL = "http://127.0.0.1:18080/media/sample.m3u8"
MEDIA_MP4_URL = "http://127.0.0.1:18080/media/sample.mp4"

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

    def _send_bytes(self, payload: bytes, content_type: str, status: int = 200) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
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
