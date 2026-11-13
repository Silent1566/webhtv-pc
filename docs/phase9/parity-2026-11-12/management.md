# 管理页 · 远程托管 · 跨设备同步 — Android → PC 迁移对照

基线：Android `/home/maple/Workspace/webhtv/dev1/webhtv` HEAD 2d8b9977；PC `/home/maple/.dsh/worktrees/webhtv-pc-d700b86c/dev3` HEAD b3c54d7e。PC 路径省略前缀 `apps/desktop-flutter/`。

| 能力 | 状态 | Android 证据 | PC 证据 | 缺失的用户动作 |
| --- | --- | --- | --- | --- |
| WebHome 原生桥 facade | 部分 | `HomeWebController.java:2081-2130` 暴露 `window.fongmi` + `fm.req/play/ctrl/stat` | `lib/services/web_home_bridge.dart:208-217` 仅 `fongmiNative/request/info/playUrl` | 用 `request`+`playUrl` 重写页面里的 `fm.ctrl/stat` 调用；无 v2 脚本时手动降级 |
| `Site.homePage` 作为首页入口 | 部分 | 配置侧 `homePage` 直生效 | `lib/core/protocol.dart:520-540` 仅存进 extra；实际路由只认 registry 的 web-home 条目（`lib/state/app_state.dart:2049-2052`） | 在 PC「Web 主页」里手填该 URL，或在 registry 中补一条 web-home 条目 |
| WebTheme v2（web/ 整套主题） | 未迁移 | `ui/web/WebThemePage.java:4-5`、`WebThemeDetailActivity.java`、`WebThemeManifestLoader.java`；PC 全库 `webtheme|web_theme` 零命中 | 无 | 手动导入主题包不可行；先在配置里用自定义 CSS/壁纸替代 |
| 网盘检测 | 部分 | `service/DriveCheckService.java:48,203-214` 115/迅雷/移动等专用实现 | `lib/core/pan_check.dart` PanDiskType 6 类 + `lib/services/pan_check_service.dart:123-132` 通用 GET/HTML 特征 | 115/迅雷/移动分享链接可能误判「未知」，需人工开链接确认 |
| 备份覆盖面 | 部分 | `bean/AppBackup.java:108-149` 含 WebHome registry/资源、spiders/local、登录态 | `lib/services/backup_service.dart:89-133` 均未含 | 换机后手动重建 WebHome 条目、重放本地爬虫、重新登录 |
| 隐身闸门（本机历史/搜索） | 已迁移 | `PlaybackProgressApi.java:45`、`PlaybackApi.java:60` 隐身即拒 | `lib/state/app_state.dart:1877-1882`（写入闸门）、`5755-5769`（搜索） | 无 |
| 隐身闸门（同步导出/导入） | 部分 | 同上两处阻断 | `lib/state/app_state.dart:1877-1882,5755-5769` 只挡本机；`lib/core/sync_state.dart:1711-1730` 导出/导入无闸门 | 隐身期间不要点「导出同步包」；导出即外泄 |
| 一键同步白名单 | 部分 | `PlaybackRemoteSyncer.java` 覆盖 history+deletions | `lib/core/android_sync.dart:40,566-591` SyncOptions 仅 history/keep/backup/settings；`lib/services/sync_server.dart:315-320` 明确拒收归档 | 配置/爬虫/登录态/WebHome/搜索仍需手工搬；一键同步后自行补登录与站点 |
| `/m` 管理页 + 远程托管 relay | 未迁移 | 安卓 Nano 管理页 | PC `lib/services`+`lib/packages`+`sidecars` 负向搜索零命中；`lib/services/sync_server.dart:245-261` 分发不含 manage | 无 Web 管理页；只能用桌面 UI 或安卓桥接 |
| 观影记录 HTTP 写入/批量/删除 | 部分 | `server/process/PlaybackProgressApi.java:27-36`（`/n/progress`、`/batch`、`/delete`）、`:50-51`、`:103-104` | `lib/services/sync_server.dart:245-261` 无任何 progress 写端点；PC 侧持为客户端（`lib/services/android_playback_bridge.dart`） | 无法由第三方脚本 POST 进度到 PC；只能走 `/action?do=sync` |
| 删除墓碑 + 远端增量（since 游标） | 部分 | `PlaybackProgressDeleteTombstoneStore.java`、`PlaybackRemoteSyncer.java:114` 应用 deletions、`PlaybackRemoteSyncPayload.java` 接受 deleted/deletions/tombstones | `lib/core/realtime_sync.dart:1359,1445-1508` 生成 `{historyKey,deletedAt}`+nextSince 且不回退；`lib/core/android_sync.dart:520-539` deletedAtByMatchKey 防复活 | 无；但墓碑只经 PC 拉取端点输出，安卓主动推删除的路径未覆盖 |
| Webhook（观影记录上报） | 未迁移 | `playback/PlaybackWebhookStore.java:11-93`、`PlaybackWebhookSender.java`、`ui/dialog/PlaybackWebhookDialog.java`；`PlaybackWebhookSender` 仅认 progress/ended/deleted | `lib/services/` 无 `viewing_webhook.dart`（`docs/phase9/README.md:114` 仍记为 PLANNED） | Webhook 只能由安卓端发；PC 播放不触发外部上报 |
| DoH | 已迁移 | `catvod/net/OkDns.java:26,34,62`（DnsOverHttps）、`bean/Doh.java:32`、`ui/dialog/DohDialog.java:32` | `lib/services/doh_resolver.dart:26,210-211`（`application/dns-message`）、`lib/core/doh.dart`、`lib/core/doh_settings.dart` | 无 |
| 出站代理（按域名） | 已迁移 | `setting/ProxySetting.java:26-50`（shell proxy 规则）、`ShellProxyDialog.java`、`MultiThreadProxyDialog.java` | `lib/services/outbound_proxy.dart:1-40`（`findProxy` 逐请求裁决 + DoH connectionFactory）、`lib/core/proxy_policy.dart`、`lib/services/proxy_server.dart`（回环） | 多线程下载代理 PC 无对应物；其余无 |
| 隐身持久化 + 崩溃会话恢复 | 已迁移 | `setting/Setting.java:399-404`（隐身落 Prefers）、`utils/CrashLogSession.java:23-33`（仅崩溃日志，不恢复播放上下文） | `lib/services/ui_preferences_store.dart:386,894` + `lib/state/app_state.dart:1877-1880`；`lib/core/session_recovery.dart:1-8`（只存标识与进度）、`lib/services/session_recovery_store.dart:14,29,46`（session.json + crash.log） | 无；PC 反而多出崩溃后续播横幅 |
| 日志诊断 | 已迁移 | `server/process/DebugLogs.java:28`、`ui/dialog/DebugLogDialog.java`、`MpvDiagnosticCollector.java` | `lib/services/log_service.dart:65,280-324`（export/exportJson/exportToDirectory+轮转）、`lib/core/playback_diagnostics.dart`、`lib/core/osd_diagnostics.dart`、`lib/ui/diagnostics_pages.dart` | 无 |
| 更新检查（含 OCI/GitHub 源） | 未迁移 | `update/` 12 文件（`UpdateSource.java:3`、`UpdateRoutePlanner.java:8`、`OciUpdateTransfer.java`）、`ui/dialog/UpdateSettingsDialog.java:19-20,58-59` | `lib/` 无 update 模块，grep `checkForUpdate|UpdateSource` 零命中；只在 `lib/ui/app.dart` 显示 `v$version` | 升级须手动替换安装包；无版本提示 |
| 已真实存在的底座（须如实计为已迁移） | 已迁移 | — | `lib/services/android_bridge_service.dart`、`lib/services/sync_client.dart`、`lib/services/sync_server.dart`、`lib/core/realtime_sync.dart`、`lib/services/backup_service.dart`（手动 ZIP） | 无 |

## 检索范围与结论口径
- 只读：两仓源码/测试/文档（PC 含 `docs/phase9`、`docs/phase7`）；未读 Android `.scratch-goal/`。
- 模式：`rg`/`grep -n` 定点取证（file:line），负向结论用目录列举 + 全库 grep 零命中双重确认（`webtheme|web_theme`、`viewing_webhook.dart`、PC update 模块、`/n/` 出站调用、`lib/packages/sidecars` 的 `/m` 与 relay）。
- 状态口径：已迁移=PC 有等效实现；部分=能力在但覆盖面/入口/契约不同；未迁移=PC 零命中；平台专属=结构上无对应物（本域内未用）。
- 未验证项：未运行 PC 应用、未联网、未接真机/安卓桥接做往返；HTTP 端点行为仅由源码分发表推断，未实测请求；Webhook 与 DoH 的真实端点往返未测。
- tracked diff：两仓 `git status --porcelain` 均无 tracked 改动（Android 仅 `?? .scratch-goal/`，未触碰）。
