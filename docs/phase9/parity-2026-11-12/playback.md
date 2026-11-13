# 播放器 / 字幕 / 弹幕 / 直播 — Android → PC 迁移状态（2026-11-12，第 2 组补证）

- Android 仓 `/home/maple/Workspace/webhtv/dev1/webhtv` @ 2d8b9977596b（证据路径相对 `app/src`）
- PC 仓 `/home/maple/.dsh/worktrees/webhtv-pc-d700b86c/dev3` @ b3c54d7e74f6（证据路径相对 `apps/desktop-flutter/lib`）
- 判定：已迁移 / 部分 / 未迁移 / 平台专属 / 证据不足。只做静态读码，未跑应用、未实机播放。

| 能力 | 状态 | Android 证据 | PC 证据 | 缺失的用户动作 |
|---|---|---|---|---|
| 播放/暂停/拖动/倍速/音量/全屏 | 已迁移 | `leanback/.../ui/custom/CustomKeyDownVod.java`；`main/.../ui/custom/PlayerOsdController.java` | `ui/player_controller.dart`；`ui/player_page.dart:3175-3186` | 无 |
| 键盘快捷键 | 已迁移 | D-pad/遥控键：`CustomKeyDownVod.java`、`CustomKeyDownLive.java` | 鼠标外再补键盘：`app.dart:1372-1384`（space/←→↑↓/M/[/]/F11/F/Esc）+ 追加 `player_page.dart:3196-3213`、`3214-3226`（右键菜单、Alt+[ Alt+]） | 无（快捷键语义按平台重写） |
| 音轨 / 视频轨选择 | 已迁移 | `ui/dialog/TrackDialog.java:144-166`（refreshTrackList）、`213`（onChoose） | `player_page.dart:2229-2280`（`_showTrackMenu`）、`core/player_tracks.dart:14-117` | 无 |
| 内嵌/外挂字幕轨选择 | 已迁移 | `TrackDialog.java:166`（轨道+字幕文件列表） | `player_page.dart:1071-1115`（外挂挂载+记忆轨）、`2510`（无字幕轨提示） | 无 |
| 双字幕（次字幕轨） | 未迁移 | `TrackDialog.java:196`（onSecondary） | 全 lib 零命中 `secondary-sid`/`secondarySubtitle`/`DualSubtitle` | 需要一条次字幕轨的选择入口与并行渲染 |
| 字幕/音轨时间偏移 | 未迁移 | `TrackDialog.java:156,174,209-210`（OffsetDialog）、`sub-delay` 由 `PlayerManager` 下发 | 全 lib 零命中 `sub-delay`/`audio-delay`，无偏移菜单 | 需要字幕/音轨 ±ms 偏移的滑杆与持久化 |
| 在线字幕源（脚本源） | 部分 | `main/.../subtitle/provider` registry:53-75 装载内置 Python ASSRT/迅雷/射手 | `services/subtitle_providers.dart` + `core/subtitle_provider.dart`：仅本地目录 + 通用 HTTP | 需要把内置脚本字幕源接进 PC 的 provider 体系（Android 订阅 manager 只有 builtin、无导入 UI，非缺口） |
| 实时 AI 字幕跟随当前音轨 | 部分 | `main/.../subtitle/RealtimeSubtitleController.java:114-139` 消费当前播放器 mediaSignals | `ui/ai_integration_widgets.dart:943-950` 未传 playerProcessId/音轨；`sidecars/.../windows_audio_capture.dart:187` 默认独立解码；`audio_ai_native.cpp:74` 固定首音轨 | 切到非首音轨时实时字幕会听错轨，需要把当前音轨绑定到采集侧 |
| 片头片尾跳过 | 已迁移 | `main/.../service/IntroSkipService.java:30,81`（远端+缓存）、`player/IntroSkipPlayback.java:134`（播放中确认/跳过） | `core/skip_segments.dart:47`；`player_page.dart:567-599`（自动判定）、`630-636`（标记写入）、`3202-3213`+右键菜单（手动） | 无（PC 多出手动标记） |
| 单集循环 | 已迁移 | `leanback/.../ui/activity/VideoActivity.java:5306-5316`（onRepeat→setRepeatOne）、`PlayerManager.java:2007` | `core/playback_repeat.dart:8-53`；`player_page.dart` 循环菜单 | 无（PC 另有连播/不连播策略） |
| 定时关闭（睡眠定时） | 已迁移（PC 额外） | 全仓零命中 `定时关闭`/`sleepTimer`（Android 无此能力） | `core/sleep_timer.dart:25-90`；`player_page.dart:324,720-721,791-796` | Android 无对应功能，属 PC 新增；无需补齐 |
| LUT / 滤镜 | 已迁移 | `main/.../player/lut/MpvLutShaderFactory.java`、`DynamicLutEffect.java:27,40`、`SplitColorLutEffect.java` | `core/lut.dart:11-65`（解析/校验）；`player_page.dart:2429-2447`（应用）、`1001` | 无 |
| 外部播放器 | 平台专属（PC） | 无：`HomeActivity.java:154` 只接 `ACTION_VIEW` 入站深链，自身即播放器 | `services/external_player.dart:24,241`；`ui/external_player_picker_dialog.dart`；`player_page.dart:2898-2929` | Android 侧无此概念，非缺口 |
| EPG（节目单） | 已迁移 | `leanback/.../ui/activity/LiveActivity.java:102,204,236`；`ui/adapter/EpgDataAdapter.java` | `core/epg.dart`；`services/epg_service.dart:24,56-88`（XMLTV+6h 缓存）；`ui/live_page.dart:87,135-153` | 无 |
| 弹幕源配置 | 已迁移 | `main/.../setting/DanmakuSetting.java:40,309-339`（单地址+内置包兜底）、`ui/dialog/DanmakuApiDialog.java:58-77`、`SettingDanmakuActivity.java:43-52`（load/auto/spiderFirst） | `core/danmaku_settings.dart:6-44`（apiUrl+autoSearch）、`ui/advanced_settings_page.dart:223-245,973-1001`、`core/http_api.dart:531` | 无 |
| 弹幕搜索 / 匹配 | 已迁移 | `DanmakuSetting.isAuto/isSpiderFirst`、`player/danmaku/*`、`PlayerManager.java:30`（DanmakuConfig） | `services/danmaku_library_service.dart:27-63`、`core/danmaku_match.dart:10,75,111`、`player_page.dart:1450-1519`（自动）、`1525-1595`（手动搜索） | 无 |
| 弹幕高级显示设置 | 部分 | `ui/dialog/DanmakuSettingPanel.java:49-70,168-173`：字号/透明度/阴影/描边/投影/行数/间距/时间轴/样式模式 | `ui/player_page.dart:1935-1990`、`core/danmaku_style.dart:20-62`：透明度/字号/时长/轨道数/占比/描边/偏移/滚动顶底 | PC 缺加粗、阴影透明度、投影偏移、行距这些细项，需按需补 |
| 直播弹幕 | 部分 | `main/.../player/PlayerManager.java:78-79`；`player/danmaku/LiveDanmakuBuffer.java`、`LiveDanmakuBatcher.java:12-81` | `services/live_danmaku_session.dart:101,139,200`；`player_page.dart:344,1648-1670`（仅 `ws://`/`wss://` 源建立会话） | PC 只认 WebSocket 弹幕源，HTTP 型直播弹幕源不可用 |
| 直播收藏 | 未迁移 | `leanback/.../ui/activity/LiveActivity.java:908-934`（长按收藏落 Keep） | 全 lib 仅 `services/android_sync.dart` 注释提及，无页面/入口 | 需要直播频道收藏的列表与入口 |
| 直播源级回退 | 部分 | `LiveActivity.java:1156-1183`：播放失败仅频道内换线，节目列表拉取失败才切直播接口 | `ui/live_playback_session.dart:327-364`：线路耗尽后跨源找同名频道；`ui/live_page.dart:139-145` 列表失败只报错不换源 | PC 列表拉取失败缺“换源”动作；跨源回退语义与 Android 相反，需要产品确认口径 |
| 预加载 / 失败回退 | 未迁移 | Android 有真实预缓存与解码/内核失败回退 | `core/player_options.dart`、`ui/player_page.dart`、`ui/advanced_settings_page.dart` 三处仅有选项；`player_page.dart:851` 固定 `openWithRetry`，`873-895` 仅直播回退 | 需要在 `openWithRetry` 前接预加载，并把解码/内核失败接进回退链 |
| 本地文件播放 | 未迁移 | `leanback/.../ui/activity/VideoActivity.java:737,751`（`file://` push 播放）、`SiteApi.isLocalFileUrl` | 全 lib 无本地视频打开入口；`services/external_player.dart:240` 明确“本地文件路径不在本能力范围内” | 需要文件选择/拖放入口，并把本地路径接进播放请求 |
| 离线下载 | 未迁移（双方均无） | `utils/Download.java` 仅更新/资源用途，无视频离线入库 | 无（`services/` 下下载均指猫源 bundle / Python 环境） | 两仓都没有视频离线下载，不构成本轮缺口 |
| DLNA / 投屏 | 平台专属（Android） | `leanback/.../dlna/DLNACastManager.java:26`、`dlna/DLNACast.java`、`ui/dialog/CastDialog.java:46`、`ui/activity/PushActivity.java:21` | 仅 `core/player_buttons.dart`、`services/android_bridge.dart`、`services/sync_server.dart` 各一处注释/占位，无 DLNA 实现 | Android 投屏是平台能力；PC 是否需要投屏需产品决策，本轮不补 |

## 检索范围 / 模式 / 未验证项

- 范围：PC `apps/desktop-flutter/lib`（296 个 dart，tree 下 41 个播放相关文件）逐文件 grep；Android `app/src` 全量 `*.java` 关键词检索 + 关键文件精读。Android 的 `.scratch-goal/` 未读。
- 模式：只读静态检索（`grep`/`sed` 区间读取），未运行构建、未联网、未启动应用、未实机/实卡播放；未跑任何测试套件。
- 未验证：① 上述“部分”项的实际运行时表现（如 PC 跨源回退是否真被触发）；② 弹幕/字幕源的网络可达性；③ LUT 与预加载在 PC 上是否已有更深的未接线实现（本轮只按“无执行消费者”判定）。
