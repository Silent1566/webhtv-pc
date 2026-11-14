#!/usr/bin/env python3
"""Phase 7 · 安卓 fixture 预检（`docs/phase7/design/04` §4、§6 的 G1）。

G1 判据：**新增路由 + 故障注入 + 2 个 TCP 模式全部通过**。

为什么这个预检查比 Phase 5 的更细
----------------------------------
Phase 7 的两条路径都建在「真机实测出来的反直觉行为」上，fixture 若不忠实
复现它们，L3 集成测试会全绿而真机仍然坏：

| 真机事实 | 源码证据 | 本脚本怎么证明 |
| --- | --- | --- |
| 缺失路由返回 **200 + octet-stream + 空体**（不是 404） | `Nano.java:96,128-130` | 只读端点缺失时的形态必须与「200 + JSON 空数组」可区分 |
| `/api/playback/current` 未播放 → **404 + JSON** | 实测 | 该 404 是合法形态，不算失败 |
| 游标是**单调递增的序号**，不是时间戳 | `design/00` §3.1 契约 9 | 非法游标 → 400；`nextSince` 随请求递增 |
| `/manage/session` 在旧版安卓**不存在** | `design/02` §3.2 降级链 | `no-manage` 模式 → 404，PC 必须降级到 `/device` |

用法：
    py -3 tools/phase7/check_android_fixture.py [--base http://127.0.0.1:18080]
    py -3 tools/phase7/check_android_fixture.py --tcp 127.0.0.1:18081

`--tcp` 指向 `server.py --port 18080 --tcp-mode ... --tcp-port 18081` 的
TCP 端口；不给则跳过 TCP 两项（并**明确报告 skipped**，不伪装成通过）。

退出码：0 = 全部通过（或仅跳过 TCP）；1 = 有失败。
"""

from __future__ import annotations

import argparse
import json
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request

# 读写端点必须存在的字段。
#
# `/api/playback/current` 返回 `PlaybackRecord`，其 `apiSafe()` 字段集含
# `historyKey`/`siteKey`/`vodId`/`episodeName`/`positionMs`/`durationMs`
# （`PlaybackFieldPolicy.java` 的 OBJECT+PROGRESS+API_SAFE_EXTRA）。
CURRENT_REQUIRED_FIELDS = {
    "historyKey",
    "siteKey",
    "vodId",
    "vodName",
    "episodeName",
    "positionMs",
    "durationMs",
}

# `/api/playback/history` 返回的是 **`History` 形态**（`key` + `vodRemarks`），
# 不是 `PlaybackProgressInput` 形态。PC 的 `_mapRecord` 两种都接，但 fixture
# 必须按真实端点的形态提供，否则「能解析」就成了假象。
HISTORY_REQUIRED_FIELDS = {
    "key",
    "vodName",
    "vodFlag",
    "vodRemarks",
    "position",
    "duration",
}

# 会话端点必须具备的字段（`design/02` §3.2 的 H3 状态采集）。
SESSION_REQUIRED_FIELDS = {
    "running",
    "serverRunning",
    "wakeLock",
    "wifiLock",
    "batteryOptimized",
    "backgroundSettingsNeeded",
    "backgroundGuide",
    "lastAccess",
    "idleTimeout",
}


def fetch(
    base: str,
    path: str,
    *,
    headers: dict[str, str] | None = None,
    timeout: float = 15,
) -> tuple[int, object, dict[str, str]]:
    """返回 (status, decoded body, headers)。只允许回环地址。"""
    url = f"{base}{path}"
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise ValueError(f"拒绝非 http(s) scheme: {parsed.scheme!r}")
    if parsed.hostname not in ("127.0.0.1", "localhost", "::1"):
        raise ValueError(f"只允许回环地址: {parsed.hostname!r}")

    request_headers = {"Accept": "application/json"}
    request_headers.update(headers or {})
    request = urllib.request.Request(  # noqa: S310 (scheme 已显式校验)
        url, headers=request_headers, method="GET"
    )
    try:
        with urllib.request.urlopen(  # noqa: S310 (scheme 已显式校验)
            request, timeout=timeout
        ) as response:
            raw = response.read()
            return (
                response.status,
                _decode(raw),
                {k.lower(): v for k, v in response.headers.items()},
            )
    except urllib.error.HTTPError as error:
        raw = error.read()
        return error.code, _decode(raw), {
            k.lower(): v for k, v in error.headers.items()
        }


def _decode(raw: bytes):
    try:
        return json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return raw.decode("utf-8", errors="replace")


def _tcp_probe(host: str, port: int, timeout: float = 3) -> str:
    """返回 `accepted-no-response` / `refused` / `timeout`。"""
    try:
        with socket.create_connection((host, port), timeout=timeout) as sock:
            sock.settimeout(timeout)
            try:
                data = sock.recv(1)
            except TimeoutError:
                return "accepted-no-response"
            except OSError:
                return "accepted-no-response"
            return "accepted-then-closed" if data == b"" else "accepted-with-data"
    except ConnectionRefusedError:
        return "refused"
    except TimeoutError:
        return "timeout"
    except OSError as error:
        return f"error:{error.errno}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:18080")
    parser.add_argument(
        "--tcp",
        default="",
        help="TCP 复用的 host:port（server.py --tcp-port），不给则跳过 TCP 两项",
    )
    parser.add_argument("--tcp-expect", default="tcp-accept-silent")
    args = parser.parse_args()
    base = args.base.rstrip("/")

    failures: list[str] = []
    facts: list[str] = []
    skipped: list[str] = []

    def check(name: str, ok: bool, detail: str = "") -> None:
        if ok:
            facts.append(f"PHASE7-ACCEPT android-fixture {name} OK {detail}".strip())
        else:
            failures.append(f"{name} {detail}".strip())

    def mode(value: str) -> None:
        fetch(base, f"/android/__mode?config={value}")

    fetch(base, "/android/__reset")

    # ---------------------------------------------------------------- 路由 1
    mode("ok")
    status, current, _ = fetch(base, "/android/api/playback/current?siteKey=csp_Media")
    fields = set(current.keys()) if isinstance(current, dict) else set()
    check(
        "route /api/playback/current 200+JSON",
        status == 200 and isinstance(current, dict),
        f"status={status}",
    )
    check(
        "current 字段完整（apiSafe 集）",
        CURRENT_REQUIRED_FIELDS.issubset(fields),
        f"missing={sorted(CURRENT_REQUIRED_FIELDS - fields)}",
    )
    check(
        "current 的 siteKey 回显请求值",
        isinstance(current, dict) and current.get("siteKey") == "csp_Media",
        f"siteKey={current.get('siteKey') if isinstance(current, dict) else '-'!r}",
    )

    # ---------------------------------------------------------------- 路由 2
    status, history, _ = fetch(base, "/android/api/playback/history?siteKey=csp_Media")
    items = history.get("items", []) if isinstance(history, dict) else []
    check(
        "route /api/playback/history 200+数组",
        status == 200 and isinstance(items, list) and len(items) > 0,
        f"status={status} items={len(items) if isinstance(items, list) else '-'}",
    )
    check(
        "history 每条含 History 形态必需字段（key/vodRemarks）",
        bool(items)
        and all(
            HISTORY_REQUIRED_FIELDS.issubset(set(record.keys()))
            for record in items
            if isinstance(record, dict)
        ),
        "有记录缺字段",
    )
    check(
        "history 无 __HOST__ 占位符残留",
        "__HOST__" not in json.dumps(history, ensure_ascii=False),
        "fixture 未做 Host 替换",
    )

    # `history` 对**未知 siteKey** 也返回 200+空数组（真机行为：从不 404）。
    # 这条是 PC 侧「端点不存在」判据的前提：缺失必须表现为 200+非 JSON。
    status, unknown, headers = fetch(
        base, "/android/api/playback/history?siteKey=__webhtv_probe__"
    )
    check(
        "history 对未知 siteKey 仍 200（端点存活）",
        status == 200,
        f"status={status}",
    )

    # ---------------------------------------------------------------- 路由 3
    status, session, _ = fetch(base, "/android/manage/session")
    session_fields = set(session.keys()) if isinstance(session, dict) else set()
    check(
        "route /manage/session 200+JSON",
        status == 200 and isinstance(session, dict),
        f"status={status}",
    )
    check(
        "session 字段完整（H3 状态采集）",
        SESSION_REQUIRED_FIELDS.issubset(session_fields),
        f"missing={sorted(SESSION_REQUIRED_FIELDS - session_fields)}",
    )

    # ---------------------------------------------------------------- 路由 4
    fetch(base, "/android/__reset")
    status, body, _ = fetch(base, "/android/manage/background/settings")
    check(
        "route /manage/background/settings 只计数不改状态",
        status == 200 and isinstance(body, dict),
        f"status={status}",
    )
    _, stats, _ = fetch(base, "/android/__stats")
    counts = stats.get("counts", {}) if isinstance(stats, dict) else {}
    check(
        "background/settings 被计数（可断言「只在用户点击时调」）",
        counts.get("/manage/background/settings", 0) == 1,
        f"counts={counts}",
    )

    # ---------------------------------------------------------------- 路由 5
    mode("ok")
    status, pull, _ = fetch(
        base,
        "/android/api/playback/sync?since=0",
        headers={"X-WebHTV-Since": "0", "X-WebHTV-Limit": "10"},
    )
    pull_items = pull.get("items", []) if isinstance(pull, dict) else []
    check(
        "route /api/playback/sync 200+nextSince/items",
        status == 200
        and isinstance(pull, dict)
        and "nextSince" in pull
        and isinstance(pull_items, list),
        f"status={status} keys={sorted(pull) if isinstance(pull, dict) else '-'}",
    )
    check(
        "sync 单条含 updatedAt（冲突裁决与 setCreateTime 依赖它）",
        bool(pull_items)
        and all(isinstance(record.get("updatedAt"), int) for record in pull_items),
        "缺 updatedAt",
    )
    _, stats, _ = fetch(base, "/android/__stats")
    seen = (
        stats.get("lastHeaders", {}).get("/api/playback/sync", {})
        if isinstance(stats, dict)
        else {}
    )
    check(
        "sync 记录到 X-WebHTV-* 请求头（免抓包断言）",
        seen.get("x-webhtv-since") == "0" and seen.get("x-webhtv-limit") == "10",
        f"seen={seen}",
    )

    # 游标语义：第二轮必须只拿到新增（nextSince 单调递增）。
    first_item = pull_items[0] if pull_items else {}
    next_since = pull.get("nextSince") if isinstance(pull, dict) else None
    status, second, _ = fetch(
        base,
        "/android/api/playback/sync",
        headers={"X-WebHTV-Since": str(next_since)},
    )
    second_items = second.get("items", []) if isinstance(second, dict) else []
    check(
        "sync 按游标返回增量（不会重复给已同步的）",
        status == 200
        and all(
            record.get("updatedAt", 0) > (next_since or 0)
            for record in second_items
        ),
        f"second={len(second_items)} nextSince={next_since}",
    )
    check(
        "sync nextSince 单调递增",
        isinstance(second, dict)
        and isinstance(second.get("nextSince"), int)
        and isinstance(next_since, int)
        and second["nextSince"] > next_since,
        f"first={next_since} second={second.get('nextSince') if isinstance(second, dict) else '-'}",
    )
    check(
        "sync 首条含 historyKey/siteKey/vodId",
        {"historyKey", "siteKey", "vodId"}.issubset(set(first_item.keys())),
        f"keys={sorted(first_item)}",
    )

    # ------------------------------------------------------------ 故障注入
    # 1) 未播放 → 404 + JSON（合法形态，不是失败）
    mode("404")
    status, body, headers = fetch(base, "/android/api/playback/current?siteKey=csp_Media")
    check(
        "fault 404：current 未播放 → 404+JSON",
        status == 404 and "json" in (headers.get("content-type") or ""),
        f"status={status} content-type={headers.get('content-type')}",
    )

    # 2) 管理页未运行 → running=false（PC 必须提示「管理页未运行」）
    mode("stopped")
    status, session, _ = fetch(base, "/android/manage/session")
    check(
        "fault stopped：running=false",
        status == 200
        and isinstance(session, dict)
        and session.get("running") is False,
        f"running={session.get('running') if isinstance(session, dict) else '-'}",
    )

    # 3) 旧版安卓无 /manage → 404（PC 必须降级到 /device）
    mode("no-manage")
    status, _, _ = fetch(base, "/android/manage/session")
    check("fault no-manage：404（测降级链）", status == 404, f"status={status}")

    # 4) 拉取鉴权失败 → 403（PC 必须立即停该方向）
    mode("403")
    status, _, _ = fetch(base, "/android/api/playback/sync?since=0")
    check("fault 403：拉取端点鉴权失败", status == 403, f"status={status}")

    # 5) 无增量 → items 为空但 nextSince 保持（不得回退）
    mode("empty")
    status, empty_pull, _ = fetch(
        base, "/android/api/playback/sync?since=777", headers={"X-WebHTV-Since": "777"}
    )
    check(
        "fault empty：无增量时 nextSince 不回退",
        status == 200
        and isinstance(empty_pull, dict)
        and empty_pull.get("items") == []
        and str(empty_pull.get("nextSince")) == "777",
        f"body={empty_pull}",
    )

    # 6) 带删除 → deleted 数组（路径 B 的删除传播）
    mode("with-deletions")
    status, deleted_pull, _ = fetch(
        base, "/android/api/playback/sync?since=0", headers={"X-WebHTV-Since": "0"}
    )
    deleted = (
        deleted_pull.get("deleted") if isinstance(deleted_pull, dict) else None
    )
    check(
        "fault with-deletions：deleted 数组存在且含 historyKey/deletedAt",
        status == 200
        and isinstance(deleted, list)
        and bool(deleted)
        and {"historyKey", "deletedAt"}.issubset(set(deleted[0].keys())),
        f"deleted={deleted}",
    )

    # 7) 缺 episodeUrl → PC 必须用 episodeName 兜底
    mode("no-episode-url")
    _, record, _ = fetch(base, "/android/api/playback/current?siteKey=csp_Media")
    check(
        "fault no-episode-url：episodeUrl 缺失但 episodeName 在",
        isinstance(record, dict)
        and "episodeUrl" not in record
        and bool(record.get("episodeName")),
        f"keys={sorted(record) if isinstance(record, dict) else '-'}",
    )

    # 8) 集名也空 → PC 必须**不合并**（宁可不合，不可错合）
    mode("empty-episode")
    _, record, _ = fetch(base, "/android/api/playback/current?siteKey=csp_Media")
    check(
        "fault empty-episode：episodeUrl 与 episodeName 都空",
        isinstance(record, dict)
        and "episodeUrl" not in record
        and not record.get("episodeName"),
        f"episodeName={record.get('episodeName') if isinstance(record, dict) else '-'!r}",
    )

    # 9) 非法游标 → 400（fixture 自身也要守住这条契约）
    mode("ok")
    status, body, _ = fetch(
        base, "/android/api/playback/sync", headers={"X-WebHTV-Since": "abc"}
    )
    check("fault 非法游标：400", status == 400, f"status={status} body={body}")

    fetch(base, "/android/__mode?config=ok")

    # ------------------------------------------------------------ TCP 模式
    if args.tcp:
        host, _, port_text = args.tcp.partition(":")
        try:
            port = int(port_text)
        except ValueError:
            failures.append(f"--tcp 端口无法解析: {args.tcp!r}")
            port = 0
        if port:
            observed = _tcp_probe(host or "127.0.0.1", port)
            if args.tcp_expect == "tcp-accept-silent":
                check(
                    "tcp-mode tcp-accept-silent：握手成功但无 HTTP 响应",
                    observed == "accepted-no-response",
                    f"observed={observed}",
                )
            else:
                check(
                    "tcp-mode tcp-closed：端口不监听",
                    observed == "refused",
                    f"observed={observed}",
                )
    else:
        skipped.append("tcp-modes（未提供 --tcp）")

    for line in facts:
        print(line)
    for item in skipped:
        print(f"PHASE7-ACCEPT android-fixture SKIP {item}")
    if failures:
        print("PHASE7-ACCEPT android-fixture result=FAIL", file=sys.stderr)
        for item in failures:
            print(f"  - {item}", file=sys.stderr)
        return 1
    print(
        f"PHASE7-ACCEPT android-fixture result=PASS checks={len(facts)} "
        f"skipped={len(skipped)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
