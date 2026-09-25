#!/usr/bin/env python3
"""仅监听本机的 Phase 0 HTTP API fixture 服务。"""

import argparse
import json
import mimetypes
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "packages" / "protocol" / "fixtures" / "http"
MEDIA = ROOT / "packages" / "protocol" / "fixtures" / "media"
REQUIRED_REFERER = "http://127.0.0.1:18080/"
REQUIRED_USER_AGENT = "WebHTV-PC-Phase0"


class FixtureHandler(BaseHTTPRequestHandler):
    server_version = "WebHTVPhase0Fixture/1.0"

    def _send_json(self, fixture_name: str) -> None:
        payload = (FIXTURES / fixture_name).read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _send_media(self, relative_path: str) -> None:
        if self.headers.get("Referer") != REQUIRED_REFERER:
            self.send_error(403, "required Referer header missing")
            return
        if self.headers.get("User-Agent") != REQUIRED_USER_AGENT:
            self.send_error(403, "required User-Agent header missing")
            return
        candidate = (MEDIA / relative_path).resolve()
        if MEDIA.resolve() not in candidate.parents or not candidate.is_file():
            self.send_error(404, "media fixture not found")
            return
        payload = candidate.read_bytes()
        content_type = mimetypes.guess_type(candidate.name)[0] or "application/octet-stream"
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path.startswith("/media/"):
            self._send_media(parsed.path.removeprefix("/media/"))
            return
        if parsed.path == "/health":
            payload = json.dumps({"status": "ok"}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        if parsed.path != "/api.php/provide/vod/":
            self.send_error(404, "fixture route not found")
            return

        action = parse_qs(parsed.query).get("ac", [""])[0]
        fixture_by_action = {
            "": "home.json",
            "list": "home.json",
            "category": "category.json",
            "detail": "detail.json",
            "play": "play.json",
        }
        fixture = fixture_by_action.get(action)
        if fixture is None:
            self.send_error(400, "unsupported fixture action")
            return
        self._send_json(fixture)

    def log_message(self, format_string: str, *args) -> None:
        print(f"{self.address_string()} - {format_string % args}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18080)
    args = parser.parse_args()
    if args.host not in ("127.0.0.1", "localhost", "::1"):
        parser.error("fixture 服务只允许监听本机地址")
    server = ThreadingHTTPServer((args.host, args.port), FixtureHandler)
    print(f"Phase 0 fixture server: http://{args.host}:{args.port}")
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
