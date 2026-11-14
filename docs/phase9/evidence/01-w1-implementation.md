# 01 · W1 实施记录（P0 播放闭环 + 直播回看）

- 日期：2026-10-21
- 基准：`docs/phase9/README.md`（W1）
- 状态：P0-1…P0-8 全部实现；P0-7 显示参数已补齐；W2 除 P1-6 外全部落地

## 1. 变更清单

| 模块 | 文件 | 内容 |
| --- | --- | --- |
| 连播/循环 | `lib/core/playback_repeat.dart`（新） | `PlaybackRepeat`（off/one/all）与 `decidePlaybackAdvance`；循环优先于 `autoNext`，非真播完一律停止 |
| 定时关闭 | `lib/core/sleep_timer.dart`（新） | 倒计时/本集结束两种模式；`remaining/isExpired/shouldStopOnEpisodeEnd` 纯逻辑 |
| 片头片尾 | `lib/core/skip_segments.dart`（新） | 归一化（越界/顺序/贴边丢弃）、`decide`（每集一次、续播不跳）、序列化 |
| 轨道 | `lib/core/player_tracks.dart`（新） | 中性轨道模型 + 菜单构造；过滤 `no`、保留 `auto`、按 id 选中 |
| 播放参数 | `lib/core/player_options.dart`（新） | 缓冲/硬解/音频直通/自动连播/失败回退/预加载/LUT 路径；归一化与 mpv 属性映射 |
| LUT | `lib/core/lut.dart`（新） | `.cube` 校验（3D、行数、尺寸）、mpv `vf` 参数构造与转义 |
| 直播回看 | `lib/core/live_catchup.dart`（新） | `CatchupSpec`、`formatCatchupUrl`、时区模板（`${(b)…}`/`${(e)…}`/`utc`/`timestamp`/`replace`） |
| 直播设置 | `lib/core/live_settings.dart`（新） | 源级回退、自动换线；默认等价现状 |
| 字幕匹配 | `lib/core/subtitle_provider.dart`（新） | 查询/候选/评分/语言优先级/记忆记录 |
| 字幕源 | `lib/core/subtitle_settings.dart`、`lib/services/subtitle_providers.dart`、`lib/services/subtitle_match_service.dart`、`lib/ui/subtitle_settings_page.dart`（新） | 本地目录 + 通用 HTTP 源、自动匹配编排、独立设置页 |
| 弹幕匹配 | `lib/core/danmaku_match.dart`（新） | 库条目/标题与集号评分/记忆记录 |
| 弹幕库 | `lib/core/danmaku_settings.dart`、`lib/services/danmaku_library_service.dart`（新） | 库搜索契约、自动搜索开关、设置页入口 |
| 存储 | `lib/services/storage.dart` | schema v4：`skip_segments`、`subtitle_match`、`danmaku_match`；读写/删除 API |
| 偏好 | `lib/services/ui_preferences_store.dart` | 顶层 `player` / `live` 段；缺席=默认，只写显式项 |
| 状态 | `lib/state/app_state.dart` | `playerOptions`/`liveSettings` + 片头片尾/字幕/弹幕记忆 API |
| 播放器 | `lib/ui/player_controller.dart` | `selectAudioTrack/selectVideoTrack`、`applyPlayerOptions`、`applyLut`（NativePlayer 属性） |
| 播放器页 | `lib/ui/player_page.dart` | 自动/手动跳过、标记/清除、循环与定时、轨道菜单、LUT 面板；连播改为 `decidePlaybackAdvance`；`Alt+[`/`Alt+]` |
| 设置页 | `lib/ui/diagnostics_pages.dart` | 「直播」与「播放参数」区块（开关/下拉/缓存档位） |
| 直播页 | `lib/ui/live_page.dart` | 节目单回看入口（仅已结束且有 catchup）、跨源同名频道回退、`changeLine` 接线 |
| 协议/解析 | `lib/core/protocol.dart`、`lib/core/live_playlist.dart` | `LiveSource/LiveChannel.catchup`；M3U 属性与 JSON 嵌套/扁平字段解析 |
| 快捷键帮助 | `lib/ui/app.dart` | 新增 `Alt + [ / ]` 说明 |

## 2. 测试

新增 6 个套件、74 个用例，全部通过：

| 套件 | 用例 | 结果 |
| --- | ---: | --- |
| `test/phase9_player_core_test.dart` | 33 | PASS |
| `test/phase9_storage_test.dart` | 7 | PASS |
| `test/phase9_live_catchup_test.dart` | 11 | PASS |
| `test/phase9_preferences_test.dart` | 7 | PASS |
| `test/phase9_subtitle_provider_test.dart` | 10 | PASS |
| `test/phase9_danmaku_library_test.dart` | 7 | PASS |

回归（已跑）：

- `test/phase3_live_test.dart` + `phase3_live_page_test.dart`：45 用例通过；
- `test/phase8_player_page_overlay_test.dart`、`phase8_overlay_layout_test.dart`、`phase3_player_display_test.dart`、`phase7_player_advance_test.dart`：50 用例通过；
- `test/phase8_settings_entries_test.dart`、`phase4_tmdb_entry_reachability_test.dart`、`search_thread_ui_test.dart`：17 用例通过；
- `test/phase5_sync_storage_test.dart`：schema 断言已随 v4 更新，15 用例通过；
- `dart analyze`：No issues found；
- 最终回归批：`phase2_search_test`、`phase8_app_state_config_test`、`phase5_sync_storage_test`、`phase3_live_service_test` 共 63 用例通过；
- 矩阵门禁：`py -3 tools/phase9/verify_gap_matrix.py` → PASSED（G9.1–G9.5）；
- 字幕/弹幕回归：`phase3_subtitle_test`、`phase3_danmaku_test`、`phase3_live_danmaku_test` 共 71 用例通过；
- 设置页布局回归：`phase8_settings_entries_test`、`search_thread_ui_test`、`phase4_tmdb_entry_reachability_test` 共 17 用例通过；
- W2/P1-3：`phase9_site_order_test` 6 用例 + 偏好持久化 1 用例通过；
- W2/P1-4：`phase9_parse_failover_test` 6 用例 + 偏好持久化 2 用例通过；解析/站点回归
  （`phase3_parser_test`、`config_and_site_test`）61 用例通过；
- W2/P1-1：`phase9_ad_rules_test` 8 用例 + 偏好 1 用例通过；代理回归 `phase2_proxy_test` 50 用例通过；
- W2/P1-2：`phase9_site_injection_test` 11 用例 + 存储 2 用例通过；设置页/高级设置入口
  （`phase8_settings_entries_test` 新增用例）通过；
- W2/P1-5：`phase9_site_group_rules_test` 8 用例 + 偏好 1 用例通过；高级设置入口用例扩展后通过；
- W2/P1-7：`phase9_direct_spider_test` 6 用例通过；sidecar 回归（`phase3_js_spider_test`、
  `phase3_jvm_spider_test`、`phase2_spider_page_test`）34 用例通过；
- W2/P1-9：`phase9_outbound_proxy_test` 10 用例 + 偏好 1 用例通过；设置页/代理/搜索回归
  （`phase8_settings_entries_test`、`phase2_proxy_test`、`phase2_search_test`）78 用例通过；
- W2/P1-8：`phase9_pan_check_test` 10 用例通过；高级设置入口用例扩展后通过；
- W2/P1-10：`phase9_ai_assist_test` 12 用例 + `phase9_ai_assist_page_test` 2 用例通过；
- Phase 9 全量：16 个套件 **160 用例**全部通过（W2 除 P1-6 外全部落地）。

尚未执行：全量 `flutter test`（已知 flaky 集合）。

已执行（2026-10-21 追加）：`integration_test/phase9_player_flow_test.dart -d windows`
5 个用例全部通过，截图两次运行逐字节一致；详见
[`02-p0-l3.md`](02-p0-l3.md) 与 [`player-l3-run.txt`](player-l3-run.txt)。
其中「真实双音轨切换 / 真实 EOF 定时 / 真实 seek 位置 / 回看出画」四项
仍是契约级证据，未证到引擎级，不得写成已完成。

## 3. 已知偏差

1. 片头片尾按影片存储（`skip_segments`），不落 `history` 两列；理由见 `design/01` §3.3。
2. 直播设置只保留 `sourceFallback` / `changeLine`；`acrossGroups` 与列表皮肤/手势不迁移（当前无对应 UI，避免设置项无行为）。
3. 预加载为「下一集地址预解析」，未实现媒体数据预下载。
6. 设置页长度约束：Phase 9 的设置项最终**独立成「高级设置」页**。先试过插在播放器之前
   （`settings-player-buttons` 被挤出 3400px 视口）和堆在末尾（从底部回滚时 `settings-osd`
   找不到），两次都让 `phase8_settings_entries_test` 变红；独立页后设置页回到 Phase 8 长度，
   新增能力也不再挤占既有入口。
4. P0-6 未内置 assrt 等第三方专有协议；采用「本地目录 + 通用 HTTP 源」，接口契约写在 `services/subtitle_providers.dart`。
5. P0-7 的显示参数扩展（速度/行数/区域/描边/防挡）尚未实现，弹幕库搜索/记忆已可用。

## 4. 复现

```powershell
puro -e webhtv -p . dart analyze
puro -e webhtv -p . flutter test test/phase9_player_core_test.dart test/phase9_storage_test.dart test/phase9_live_catchup_test.dart test/phase9_preferences_test.dart
```

## 5. 暂缓项说明

- **P1-6 CSP 预热暂缓**：PC 的 `csp_*` 站点经 `webhtv-ipc-v1` 按次启动 JVM sidecar，
  没有常驻进程池；现有 `SidecarProcess.start` 只能“启动后结束”，不能产生可观测的预热收益。
  先做 sidecar 常驻池（独立设计）再实现，避免交付一个无行为开关。

## 6. 下一步

1. 具备 ffmpeg 的环境补「双音轨真实切换」与「真实 EOF 定时」两条 L3。
2. 进入 W3（P2 内容与同步）：追番、观影报告、短剧、一键同步扩展等。

## 7. P0-7 显示参数（2026-10-21 追加，W1 收尾）

| 模块 | 文件 | 内容 |
| --- | --- | --- |
| 显示模型 | `lib/core/danmaku_style.dart`（新） | 从 `ui/danmaku_overlay.dart` 抽出；新增 `scrollDurationMs` / `fixedDurationMs` / `areaRatio` / `maxTracks` / `timeOffsetMs`，保留原有透明度、字号、类型显隐、描边；统一夹取与 JSON 往返 |
| 渲染 | `lib/ui/danmaku_overlay.dart` | 时长、区域、行数、时间偏移全部来自样式；`export` 旧类型保证 Phase 3–8 引用不变 |
| 轨道 | `lib/core/danmaku.dart` | `DanmakuTrackAllocator` 增加 `maxTracks` 硬上限（0=不限）；`visibleAt` 透传区域比例与上限 |
| 播放器 | `lib/ui/player_page.dart` | 弹幕面板新增「速度 / 行数 / 区域 / 描边 / 时间偏移」，即改即生效；所有变更经 `AppState.setDanmakuStyle` 落盘 |
| 偏好 | `lib/services/ui_preferences_store.dart`、`lib/state/app_state.dart` | 顶层 `danmakuDisplay` 段；缺席＝Phase 3–8 行为；显式改回默认会删除该段 |

测试：`test/phase9_danmaku_display_test.dart` 12 用例（默认等价、夹取、JSON 脏数据、
时间偏移、区域/行数/时长真正影响轨道与可见性、持久化与旧文件升级）。
回归：`phase3_danmaku_test`、`phase3_danmaku_overlay_test`、
`phase3_live_danmaku_test`、`phase8_player_page_overlay_test`、
`phase8_settings_entries_test` 共 71 用例通过。

边界：**不做**安卓的「屏蔽词 / 颜色模式 / 粗体 / 投影偏移」——`webtv2`
基线没有屏蔽词，其余项 PC 当前渲染层没有对应行为，宁可不做也不摆空开关。
