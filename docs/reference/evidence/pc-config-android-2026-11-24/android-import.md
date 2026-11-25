# PC config → Android non-active import: device receipt (2026-11-24)

Task: `pc-config-copy-import` (Android executor run 2/3). Scope: implementation + device proof only; parent owns task guard, docs index and closure.

## Endpoint as implemented

`POST /manage/config/import` with `Content-Type: application/x-www-form-urlencoded` and `X-WebHTV-PC-Import: 1`, body params `url` (required), `name` (optional, capped 100), `type` (optional, 0/1/2, default 0).

Response: `{"code":0,"data":{"id":<cid>,"interfaceKey":"<T4 key>","url":"…","name":"…","created":<bool>,"active":<bool>}}`.

Guarantees: insert only when no `(url,type)` row exists (process-local critical section), no download/parse, no activation, original name preserved on reuse, `interfaceKey` returned because numeric cid is not the T4 key.

Rejections: GET 405; non-loopback peer 403; browser Origin/Referer/forwarding headers 403; `target` forwarding 403; missing PC header 403; non-form content-type 415; body without content-length 411; chunked 400; >16 KiB 413. The guard runs before generic `Manage.forward`, so a `target` argument cannot reroute or skip it. Nano emits only method/path/bodyLength/pcMark metadata for this path; params, body and header values are never logged.

## Device evidence (Android 9/API28, arm64, 5.6.0/560)

| Check | Result |
|---|---|
| GET import | 405 `Use POST` |
| POST no PC header | 403 |
| POST with Origin | 403 |
| POST with `?target=` | 403 |
| POST wrong content type | 415 |
| POST 17 KB body | 413 |
| POST valid (new URL) | `code 0`, 6 fields, `id 34`, `created true`, UUID interfaceKey |
| POST same URL again | `id 34`, `created false`, same interfaceKey |
| numeric cid as `configKey` | rejected (unknown config identifier) |
| non-active catalog by interfaceKey | 94 site entries, 40 ms |
| 代表性影视源A home | 6 classes, 1.4 s |
| first category | 12 items, 54 ms |
| detail with returned vod_id | 1 item, 3 play flags, 143 episodes, 99 ms |
| active config | 204 keys before and after, digest identical, imported rows inactive |
| logcat for import path | 0 URL/token matches; metadata line only |

Machine-readable receipt: `android-import.json` (same folder). Sanitized: no PC source URL, path, ext, jar or token is stored; interfaceKeys are represented by a 12-hex SHA-256 fingerprint.

## Limitations

Rows 32/33/34 are non-active spike artifacts whose loopback source URLs are offline; this is not a PC-product-ready feature, not account/worker isolation, and not proof that all 78 CSP sources execute. Verification covers the non-active main-app catalog path with one representative normal 影视 source. Process-local serialization does not cover the separate origin-worker process.

## Cleanup

Own `adb reverse`, own `adb forward`s, private HTTP server, and `/tmp/android-app-config-import` were removed after saving this receipt; the device app remains running on the same 5.6.0/560 build with user data preserved.
