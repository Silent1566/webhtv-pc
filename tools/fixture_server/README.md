# Phase 0 Fixture Server

启动：

```bash
python3 tools/fixture_server/server.py
```

服务只允许监听回环地址。可用端点：

- `/health`
- `/api.php/provide/vod/`
- `/api.php/provide/vod/?ac=category`
- `/api.php/provide/vod/?ac=detail`
- `/api.php/provide/vod/?ac=play`
- `/media/sample.m3u8` 及其分片，要求 `Referer: http://127.0.0.1:18080/` 和 `User-Agent: WebHTV-PC-Phase0`

媒体 fixture 位于 `packages/protocol/fixtures/media`，仅用于 Phase 0 自动化播放验证。
