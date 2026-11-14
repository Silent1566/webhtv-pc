# 01 · 实时同步 —— 真机实测（V3）

> 对应 `docs/phase7/design/02-android-keepalive-and-wake.md` §6.3（O4）、
> `design/04` §7 V3。本文件是**真实设备实测**。采集于 2026-10-18。

## 设备与前置

| 项 | 值 |
| --- | --- |
| 设备 | `192.168.50.3:5561`（LDPlayer，OnePlus HD1910） |
| 应用 | `com.silent.android.webhtv` `5.6.0-202610171140`（含 T19 的 A + C） |
| PC 服务端 | `tool/v3_host.dart`（真实 `SyncServer`，与 app 内同一份代码） |
| 网络 | 模拟器在 NAT `172.16.1.0/24`，**无法直连** PC 的 `192.168.50.21` → 用 `adb reverse tcp:19990 tcp:9978` |

> **为什么用 `tool/v3_host.dart` 而不是跑整个 PC app**：V3 要回答的是
> 「安卓的远端同步源能不能真的拉到增量」。这只需要 `SyncServer` 本身——
> 它与 app 内跑的是同一份实现、同一路由、同一套鉴权；差别只是宿主 I/O。
> 跑整个 app 反而会被窗口、播放器、爬虫进程的日志干扰判读。

## 配置注入方式

安卓的远端同步源存在 `SharedPreferences`：
`shared_prefs/com.silent.android.webhtv_preferences.xml` 的
`playback_remote_sync_config`（JSON 数组，字段对齐 `RemoteSyncConfig`）。

由于 `ManageService` 未导出、UI 路径需要多级导航，本次用**直接写 preferences**
的方式注入（等价于用户在 UI 里填表保存）：

```json
[{
  "id": "v3-realtime-test",
  "name": "V3 PC test",
  "enabled": true,
  "url": "http://127.0.0.1:19990/api/playback/sync",
  "token": "v3secret",
  "siteKeys": [],
  "syncOnStartup": true,
  "intervalMinutes": 1,
  "maxItems": 100,
  "cursors": {}
}]
```

注入后 `am force-stop` 再启动 app，让它重新读配置。

## V3 实测结果

PC 侧 `SyncServer` 收到的三次拉取（`V3-EVIDENCE pull call=`）：

| # | `since` | 返回 | 说明 |
| --- | --- | --- | --- |
| 1 | `0` | `items=2 nextSince=1792289205017` | 本地自检（`curl`） |
| 2 | `0` | `items=2 nextSince=1792289205017` | **安卓首次拉取**（空游标 → 全量最近 N 条） |
| 3 | `1792289205017` | **`items=0 nextSince=1792289205017`** | **安卓第二轮 → 只拉增量，0 条** |

安卓侧的持久化结果（`playback_remote_sync_config`，从 app 自己的 prefs 读回）：

| 字段 | 值 | 含义 |
| --- | --- | --- |
| `lastApplied` | **`2`** | 两条记录被安卓落库 |
| `lastFetched` | `2` | 拉到 2 条 |
| `lastSkipped` | `0` | 无跳过 |
| `lastFailed` | `0` | 无失败 |
| `lastDeleted` | `0` | 无删除 |
| `lastError` | **`""`** | **无错误** |
| `lastSuccessAt` | `1792289982099` | 成功时间已更新 |
| `cursors` | `{"00d779a9-…": "1792289205017"}` | **游标按站点配置 id 保存** |

**结论（回答 O4）**：✅ **安卓远端同步源指向 PC 可用**，判据全部满足：

1. `lastApplied > 0`（2 条真的落库）；
2. `lastError` 为空；
3. **第二轮把游标回传（`since=1792289205017`）并拿到 `items=0`**
   —— 这是"增量"而不是"每次全量"的决定性证据。

## 附带验证的三条协议契约

在同一服务端上顺带实测（均为真实 HTTP）：

| 契约 | 请求 | 响应 | 结论 |
| --- | --- | --- | --- |
| 正常拉取 | `GET /api/playback/sync?since=0` + 正确 token | `200` + `application/json`，`items=2` | ✅ |
| token 鉴权 | 同上但 token 写错 | **`403`** | ✅ 未授权不放数据 |
| 身份解析 | `POST /api/playback/identity/resolve`（`action` 应为 `create`） | `200` + `action=create` + `capabilities.identityResolve=true` | ✅ T5 的端点在真机链路上可用 |

> 身份解析这一条尤其关键：安卓拿到 `create` 说明它**没有**把 PC 判成
> `unsupported`（`PlaybackIdentityResolver.java:65` 的 404/405/501 分支未触发）。

## 踩坑记录（对后续真机验证有用）

| 现象 | 根因 | 处理 |
| --- | --- | --- |
| `/api/playback/history` 返回 `200 + application/octet-stream` | 5555/5557/5559 上装的是 `com.fongmi.android.tv` `5.6.0`（更新于 09-27 / 10-08），**不含** T19 的端点 | 改用 5561 上的 `com.silent.android.webhtv`（`5.6.0-202610171140`） |
| `adb install -r` 报 Success 但版本不变 | 装到了**另一个包名**——webtv4 的 `applicationId` 是 `com.silent.android.webhtv`，不是 `com.fongmi.android.tv` | 认准包名再装 |
| `am startservice ... ManageService` → `Requires permission not exported` | 服务未导出（正确设计） | 通过 app 自身启动（`nav_position=3` 拉起增强设置，管理页随之启动） |
| 模拟器连不上 PC 的 `9978` | 模拟器在 NAT `172.16.1.0/24` | `adb reverse tcp:19990 tcp:9978` |
| `adb push` 报 `secure_mkdirs failed` | 本机 adb 相对路径解析到 `G:/Git/` | 用 `run-as <pkg> sh -c 'cat > <path>'` 走 stdin 写入 |

## 与门禁的关系

本文件是**实测留痕**，不作为门禁。路径 B 的协议行为由
`test/phase7_pull_endpoint_test.dart`（L2，真实 HTTP）与
`integration_test/phase7_realtime_flow_test.dart`（L3）锁定；
本文件回答的是「**安卓这只客户端**在真实设备上到底会不会来拉、拉了会不会记住游标」。
