#!/usr/bin/env python3
"""猫源真实 bundle 端到端验证（§9 猫源）。

用真实 CatVod bundle（F:/temp/catpkg）验证 PC 端完整链路：
  1. CatBundle 本地目录包安装（内容指纹 + 缓存标记）；
  2. CatNodeRuntime 起本机 Node 进程、写 boot.js、轮询候选端口；
  3. 用 CatSource.isConfig 在多个候选端口里认准猫源服务；
  4. 取 /config → CatSource.normalize → 站点列表 / 搜索 / 播放。

这不是单元测试的替代：单元测试用 fixture 保证形状，本脚本用**真实 bundle**
证明协议对齐（bundle 导出 start(config)、catServerFactory/catDartServerPort 全局、
/config 形状、/spider/<key>/<type>/{init,home,search,play} 路由）。

用法：python tools/phase3/verify_cat_source.py [--package DIR] [--site KEY]
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import socket
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PACKAGE = Path(os.environ.get("CAT_PACKAGE", r"F:/temp/catpkg"))


def log(message: str) -> None:
    print(f"[cat-verify] {message}", flush=True)


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def _open(request: urllib.request.Request, timeout: float):
    """只允许 http(s)——本脚本只连本机猫源服务，显式拒绝其它 scheme。"""
    scheme = urllib.parse.urlparse(request.full_url).scheme
    if scheme not in ("http", "https"):
        raise ValueError(f"unsupported scheme: {scheme}")
    return urllib.request.urlopen(request, timeout=timeout)  # noqa: S310


def http_get(url: str, timeout: float = 5.0) -> tuple[int, str]:
    request = urllib.request.Request(url, headers={"Accept": "application/json, */*"})
    try:
        with _open(request, timeout) as response:
            return response.status, response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as error:  # type: ignore[attr-defined]
        return error.code, error.read().decode("utf-8", "replace")
    except Exception as error:  # noqa: BLE001
        return 0, f"<{error}>"


def http_post(url: str, body: dict, timeout: float = 30.0) -> tuple[int, str]:
    data = json.dumps(body, ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=data,
        headers={
            "Content-Type": "application/json; charset=utf-8",
            "Accept": "application/json, */*",
        },
    )
    try:
        with _open(request, timeout) as response:
            return response.status, response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as error:  # type: ignore[attr-defined]
        return error.code, error.read().decode("utf-8", "replace")
    except Exception as error:  # noqa: BLE001
        return 0, f"<{error}>"


def _json_field(text: str, field: str):
    """容错取字段：非 JSON 或字段缺失时返回空列表/空串（调用方按失败处理）。"""
    try:
        parsed = json.loads(text or "{}")
    except json.JSONDecodeError as error:
        log(f"WARN 响应不是 JSON：{error}")
        return []
    if not isinstance(parsed, dict):
        return []
    return parsed.get(field) or []


def is_cat_config(text: str) -> bool:
    """与 Dart `CatSource.isConfig` 同语义。"""
    if not text or not text.strip():
        return False
    try:
        root = json.loads(text)
    except json.JSONDecodeError:
        return False
    if isinstance(root, list):
        return len(root) > 0
    if not isinstance(root, dict):
        return False
    if "sites" in root:
        return True
    video = root.get("video")
    return isinstance(video, dict) and "sites" in video


def boot_source(bundle: Path, config: Path, host_port: int, port_file: Path, data_dir: Path) -> str:
    """与 Dart `CatNodeRuntime._bootSource` 逐条对齐（NodeBoot.java 的 PC 复刻）。"""
    esc = lambda value: str(value).replace("\\", "\\\\").replace("'", "\\'")  # noqa: E731
    return f"""
'use strict';
const http = require('http');
globalThis.catServerFactory = (handler) => http.createServer(handler);
globalThis.catDartServerPort = () => {host_port};
process.env.NODE_PATH = '{esc(data_dir)}';
process.on('uncaughtException', (e) => console.error('uncaught', e));
process.on('unhandledRejection', (e) => console.error('unhandled', e));
(async () => {{
  try {{
    const mod = require('{esc(bundle)}');
    const start = mod.start || (mod.default && mod.default.start);
    if (typeof start !== 'function') throw new Error('bundle has no start()');
    let conf = {{}};
    try {{
      const raw = require('{esc(config)}');
      conf = raw && raw.default ? raw.default : (raw || {{}});
      console.log('config keys: ' + Object.keys(conf).length);
    }} catch (e) {{ console.error('config load failed', e.message); }}
    await start(conf);
    setInterval(() => {{}}, 60000);
    let last = '';
    const publish = () => {{
      try {{
        const handles = process._getActiveHandles ? process._getActiveHandles() : [];
        const ports = [];
        for (const h of handles) {{
          if (h && typeof h.address === 'function' && h.constructor && h.constructor.name === 'Server') {{
            const a = h.address();
            if (a && a.port && !ports.includes(a.port)) ports.push(a.port);
          }}
        }}
        if (!ports.length) return false;
        const text = ports.join(',');
        if (text === last) return true;
        const fs = require('fs');
        fs.writeFileSync('{esc(port_file)}.tmp', text);
        fs.renameSync('{esc(port_file)}.tmp', '{esc(port_file)}');
        last = text;
        console.log('cat bundle listening on ' + text);
        return true;
      }} catch (e) {{ console.error('publish port failed', e.message); }}
      return false;
    }};
    let tries = 0;
    const timer = setInterval(() => {{ if (publish() || ++tries > 250) clearInterval(timer); }}, 200);
    console.log('cat bundle started');
  }} catch (e) {{
    console.error('cat bundle failed', e && e.stack ? e.stack : e);
  }}
}})();
"""


def read_ports(port_file: Path) -> list[int]:
    try:
        text = port_file.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return []
    ports: list[int] = []
    for part in text.split(","):
        try:
            value = int(part.strip())
        except ValueError:
            continue
        if value > 0 and value not in ports:
            ports.append(value)
    return ports


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--package", default=str(DEFAULT_PACKAGE))
    parser.add_argument("--site", default="", help="指定站点 key 做 search/play 验证")
    parser.add_argument("--keyword", default="寒战")
    parser.add_argument("--timeout", type=float, default=60.0)
    args = parser.parse_args()

    package = Path(args.package)
    entry = package / "index.js"
    config = package / "index.config.js"
    if not entry.exists():
        log(f"FAIL 找不到真实 bundle：{entry}")
        return 2
    log(f"package={package} entryBytes={entry.stat().st_size}")

    # 1) 引导脚本（与 Dart 侧同一份语义）。
    host_port = free_port()
    port_file = package / "port"
    data_dir = package / "data"
    data_dir.mkdir(exist_ok=True)
    boot = package / "boot.verify.js"
    boot.write_text(
        boot_source(entry, config, host_port, port_file, data_dir),
        encoding="utf-8",
    )
    port_file.unlink(missing_ok=True)

    node = os.environ.get("NODE_EXE") or "node"
    log(f"starting node={node} hostPort={host_port}")
    log_file = package / "verify-node.log"
    log_handle = log_file.open("w", encoding="utf-8", errors="replace")
    process = subprocess.Popen(
        [node, "--max-old-space-size=256", str(boot)],
        cwd=str(package),
        stdout=log_handle,
        stderr=subprocess.STDOUT,
    )

    failures: list[str] = []
    cat_port = 0
    config_text = ""
    try:
        # 2) 轮询候选端口，用配置形状认准猫源服务。
        deadline = time.time() + args.timeout
        reported = False
        while time.time() < deadline:
            if process.poll() is not None:
                log(f"FAIL Node 进程提前退出 code={process.returncode}")
                log(f"--- {log_file} (tail) ---")
                with contextlib.suppress(Exception):
                    lines = log_file.read_text(encoding="utf-8", errors="replace").splitlines()
                    for line in lines[-15:]:
                        log(f"  {line}")
                return 3
            candidates = read_ports(port_file)
            if not candidates:
                if not reported:
                    log("waiting for candidate ports ...")
                    reported = True
                time.sleep(0.2)
                continue
            for port in candidates:
                status, text = http_get(f"http://127.0.0.1:{port}/config")
                if status == 200 and is_cat_config(text):
                    cat_port = port
                    config_text = text
                    break
            if cat_port:
                break
            time.sleep(0.2)

        if not cat_port:
            log(f"FAIL 未在 {args.timeout}s 内认准猫源服务（候选={read_ports(port_file)}）")
            return 4

        log(f"OK 猫源服务 port={cat_port} candidates={read_ports(port_file)}")

        # 3) /config 整形。
        root = json.loads(config_text)
        if isinstance(root, list):
            sites = root
        else:
            video = root.get("video") or {}
            sites = video.get("sites") or []
        if not sites:
            log("FAIL /config 没有站点")
            return 5
        log(f"OK /config sites={len(sites)}")

        base = f"http://127.0.0.1:{cat_port}"
        searchable = 0
        for site in sites:
            if site.get("searchable", 1) != 0:
                searchable += 1
            api = site.get("api") or ""
            if api.startswith("/"):
                site["api"] = base + api
        log(f"OK 站点 api 已补基址 searchable={searchable}/{len(sites)}")

        # 4) 选站点做 home / search / play。
        target = None
        if args.site:
            target = next((s for s in sites if s.get("key") == args.site), None)
            if target is None:
                log(f"FAIL 未找到站点 key={args.site}")
                return 6
        else:
            # 优先挑一个声明可搜索、且 home 有分类的站点。
            for site in sites:
                if site.get("searchable", 1) == 0:
                    continue
                status, text = http_post(f"{site['api']}/home", {})
                if status == 200 and (json.loads(text or "{}").get("class")):
                    target = site
                    break
            if target is None:
                target = sites[0]
        log(f"target site key={target.get('key')} name={target.get('name')} api={target.get('api')}")

        status, text = http_post(f"{target['api']}/init", {})
        log(f"{'OK' if status == 200 else 'FAIL'} init HTTP={status}")
        if status != 200:
            failures.append("init")

        status, text = http_post(f"{target['api']}/home", {})
        classes = _json_field(text, "class")
        log(f"{'OK' if status == 200 else 'FAIL'} home HTTP={status} classes={len(classes)}")
        if status != 200:
            failures.append("home")

        status, text = http_post(
            f"{target['api']}/search", {"wd": args.keyword, "page": 1}
        )
        items = _json_field(text, "list")
        log(
            f"{'OK' if status == 200 and items else 'FAIL'} "
            f"search wd={args.keyword} HTTP={status} items={len(items)}"
        )
        if not items:
            failures.append("search")

        if items:
            vod_id = items[0].get("vod_id")
            status, text = http_post(f"{target['api']}/detail", {"id": vod_id})
            detail = json.loads(text or "{}")
            play_flags = (detail.get("list") or [{}])[0].get("vod_play_from") or ""
            log(
                f"{'OK' if status == 200 and play_flags else 'FAIL'} "
                f"detail id={vod_id} HTTP={status} flags={play_flags}"
            )
            if not play_flags:
                failures.append("detail")

            first_flag = play_flags.split("$$$")[0] if play_flags else ""
            status, text = http_post(
                f"{target['api']}/play", {"flag": first_flag, "id": vod_id}
            )
            play_url = _json_field(text, "url") or ""
            log(
                f"{'OK' if status == 200 and play_url else 'FAIL'} "
                f"play flag={first_flag} HTTP={status} url={(play_url or '')[:80]}"
            )
            if not play_url:
                failures.append("play")

    finally:
        with contextlib.suppress(Exception):
            log_handle.close()
        with contextlib.suppress(Exception):
            process.terminate()
            process.wait(timeout=8)
        if process.poll() is None:
            with contextlib.suppress(Exception):
                process.kill()
        log(f"node stopped code={process.returncode}")

    if failures:
        log(f"RESULT FAIL steps={','.join(failures)}")
        return 1
    log("RESULT OK 猫源导入 / 站点 / 搜索 / 播放 全链路通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
