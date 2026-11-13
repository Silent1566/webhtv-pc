# Phase 9 · 安卓功能差距分析与迁移方案（WebHTV PC）

- 状态：**W1 完成（P0 八项 + 5 条 L3）· W2 除 P1-6 外完成 · W3 进行中（P2-1、P2-2、P2-7、P2-8 已落地）**
- 日期：2026-10-21
- 基准（安卓）：`F:/Workspace/webtv2/webhtv` @ `77e2fbefdc`（2026-10-20，「默影视」）
  - **漂移**：本地仓库已推进到 `dcf9828cba61`（2026-10-23，merge beta）。差异仅为对话框目录新增 `DialogSafeArea.java`（已补入 `design/05-upstream-map.md`），其余清点无增减；G9.1–G9.5 在该 commit 上已实测全绿。
- 基准（PC）：本仓库 @ `81c398c`
- 主设计文档：`docs/webhtv-pc-design.md` §21（Phase 9 摘要）
- 方法：`docs/phase9/design/00-gap-method.md`
- P0 设计：`docs/phase9/design/01-player-closure.md`、`docs/phase9/design/02-subtitle-danmaku.md`、`docs/phase9/design/03-live.md`
- 验收规范：`docs/phase9/design/04-acceptance.md`
- 上游映射：`docs/phase9/design/05-upstream-map.md`
- 门禁：`tools/phase9/verify_gap_matrix.py`（G9.1–G9.5）

---

## 1. 结论

PC 端已完成 Phase 0–8，**配置 → 站点 → 浏览/搜索 → 详情 → 播放 → 直播/字幕/弹幕 → TMDB/AI 集季 → 安卓桥接/实时同步 → 播放器浮层**这条主闭环是通的，且有自己的安全边界（Spider 进程隔离、回环代理、能力披露）。

与 `webtv2` 对比后，仍有 **34 项用户可见能力缺失**，分四档：

| 档 | 项数 | 主题 | 判断 |
| --- | --- | --- | --- |
| P0 | 8 | 播放闭环（轨道 / 片头片尾 / 循环定时 / 播放参数 / LUT / 字幕源 / 弹幕库 / 直播回看） | 桌面完全可行，用户日常感知最强，**先做** |
| P1 | 10 | 站点与协议生态（广告过滤 / 站点注入 / 健康排序 / 接口失败切换 / 分组规则 / CSP 预热 / 直连 js&py / 网盘检测 / 出站代理 / AI 扩展） | 决定「真实配置能用多少」，第二批 |
| P2 | 9 | 内容与同步（追番 / 观影报告 / 短剧 / 一键同步 / 登录态 / Webhook / 更新备份 / DoH 隐身恢复 / 文件浏览） | 第三批，部分依赖安卓契约 |
| P3 | 7 | 平台决策（WebHome / 听书 TTS / 小说漫画 / GitCloud / 管理页 / 远程托管 / 投屏遥控） | 需 ADR，能力大、安全边界重 |

另有 **8 类明确不迁移**（见 §5），必须对外披露，不得用「对齐安卓」含糊带过。

三个最大的结构性缺口：

1. **WebHome 生态**（自定义首页 / 扩展注入 / 主题）——PC 当前明确不支持，且主进程不加载不可信代码的边界与 WebView 天然冲突，必须先做 ADR。
2. **内容形态**（追番 / 短剧 / 听书 / 小说漫画）——PC 目前只有「影视」一种形态。
3. **局域网服务与远程托管**（管理页 `/m`、remote relay）——PC 只有回环代理，没有 LAN 面。

不可迁移的硬缺口：**Android dex/JAR 站源**（只有 ART 能执行）。缓解手段是已实现的 T4 桥接，必须持续披露。

---

## 2. 对比口径（摘要）

- 判定三档：**已对齐**（UI 入口 + 服务层实现 + 测试）、**部分对齐**（只有数据或只有 UI）、**缺失**。
- **只解析字段不算实现**：例如 `ads`/`hlsRules`/`doh` 在 `protocol.dart` 里有字段，但没有消费点，一律记为缺失。
- **只有入口没有行为也不算实现**：沿用 Phase 8 结论（`core/player_buttons.dart` 明确排除 27 个无实现的按钮）。
- 覆盖基线：安卓 43 个 manifest 屏幕、84 个对话框、9 个设置 Fragment、34 个顶层模块；PC 108 个 `lib` 源文件、18 个页面、115 个单测文件、31 个集成测试文件。
- 详细规则与反例见 `design/00-gap-method.md`。

---

## 3. 已对齐（不重复建设）

| 域 | PC 证据 |
| --- | --- |
| 配置导入（URL / 本地文件 / JSON 文本）、多配置、字段解析与校验 | `apps/desktop-flutter/lib/core/config_loader.dart`、`lib/core/config_parser.dart`、`lib/core/protocol.dart` |
| 站点执行 type 0/1/2/4 + CatSpider HTTP + JS/Node + PC Java + Python sidecar | `lib/services/spider_router.dart`、`lib/core/cat_http.dart`、`sidecars/spider-host-js`、`sidecars/spider-host-jvm`、`sidecars/spider-host-python` |
| 浏览 / 分类 / 筛选 / 分页、站点选择器、换源 | `lib/ui/browse_pages.dart`、`lib/ui/source_field.dart`、`lib/ui/app.dart` |
| 搜索并发 / 取消 / 联想 / 热搜 / 筛选 / 历史 | `lib/ui/search_page.dart`、`lib/services/search_suggest_service.dart`、`lib/state/app_state.dart` |
| 详情（hero、线路/剧集、收藏、续播、季度控件） | `lib/ui/browse_pages.dart`、`lib/ui/tmdb_detail_view.dart` |
| 播放（倍速 / 画面比例 / 全屏 / 进度恢复 / 连播 / 线路切换 / 快捷键 / 四层浮层 / OSD / 右键菜单 / 按钮排版） | `lib/ui/player_page.dart`、`lib/ui/player_controller.dart`、`lib/ui/player_overlay.dart`、`lib/ui/player_osd.dart` |
| 字幕（结果内 subs、编码兜底、轨选择、样式） | `lib/services/subtitle_service.dart`、`lib/core/subtitle.dart` |
| 弹幕（内嵌 + 直播 ws、透明度 / 字号 / 显隐） | `lib/ui/danmaku_overlay.dart`、`lib/core/live_danmaku.dart` |
| 直播（M3U/TXT/JSON、分组、多线路失败切换、EPG） | `lib/ui/live_page.dart`、`lib/services/live_service.dart`、`lib/services/epg_service.dart` |
| TMDB（匹配 / 季度 / 进度 / 详情增强 / 人物页 / 相关视频） | `lib/services/tmdb_service.dart`、`lib/services/tmdb_cache.dart`、`lib/services/tmdb_season_service.dart`、`lib/ui/tmdb_detail_view.dart` |
| AI 集季识别 | `lib/services/ai_episode_season_service.dart`、`lib/core/ai_config.dart` |
| 安卓桥接（发现 / T4 导入 / 历史与收藏同步 / 设置同步 / 实时增量 / 保活） | `lib/core/android_bridge.dart`、`lib/core/android_sync.dart`、`lib/core/realtime_sync.dart`、`lib/services/sync_server.dart` |
| 诊断 / 日志 / 缓存清理 / 站点健康页 | `lib/ui/diagnostics_pages.dart`、`lib/services/log_service.dart` |
| 品牌字段 `wallpaper` / `logo`（配置优先） | `lib/ui/app.dart` |

---

## 4. 缺失矩阵

> 机器可校验格式：每行 6 列；ID 前缀必须与所在小节的档位一致；安卓依据用 `android/<仓库相对路径>`；PC 路径用 `apps/desktop-flutter/<仓库相对路径>`；尚未落地的新模块写 `PLANNED apps/desktop-flutter/<路径>`。校验脚本见 §8。

### 4.1 P0 · 播放闭环

| ID | 能力 | 安卓依据 | PC 现状 | 迁移方案 | 验收条件 |
| --- | --- | --- | --- | --- | --- |
| P0-1 | 音轨/视频轨选择 | `android/app/src/main/java/com/fongmi/android/tv/ui/dialog/TrackDialog.java`、`android/app/src/main/java/com/fongmi/android/tv/player/track`、`android/app/src/main/java/com/fongmi/android/tv/setting/PlayerButtonSetting.java` | **已实现（W1，见 §10）**：`core/player_tracks.dart` + 控制器选择 API + 菜单入口；历史缺口是「只读诊断、无选择入口」 | `PLANNED apps/desktop-flutter/lib/core/player_tracks.dart` 定义轨道模型与选择策略；`lib/ui/player_controller.dart` 暴露 media-kit `setAudioTrack`/`setVideoTrack`；播放器顶栏「轨道」菜单（音轨/视频轨/字幕轨）；`stream.tracks` 变化时刷新；按影片记忆首选（可关） | L2：双音轨 fixture 切换后 `audioTrack.id` 改变且进度不重置；单轨时菜单置灰并说明「仅一条音轨」；L3：真实窗口切换无黑屏、无重载；引擎不支持时显式报错，不静默 |
| P0-2 | 片头片尾跳过 | `android/app/src/main/java/com/fongmi/android/tv/setting/PlayerButtonSetting.java`、`android/app/src/main/java/com/fongmi/android/tv/bean/History.java`、`android/app/src/main/java/com/fongmi/android/tv/setting/FlagSwitchPlaybackPolicy.java` | **已实现（W1，见 §10）**：`core/skip_segments.dart` + DB v4 `skip_segments`；历史缺口是「只接收不落库、无跳过入口」 | `PLANNED apps/desktop-flutter/lib/core/skip_segments.dart`（纯逻辑：解析、钳制、只跳一次、与续播叠加）；DB v4 增 `opening_ms`/`ending_ms`；播放器自动 + 手动跳过、标记片头片尾、快捷键、设置开关 | L1：90s 片头只跳一次；续播位置 > 片头不重复跳；片尾边界钳制；L2：关闭开关不跳；L3：跨集沿用且不触发连播（不破坏 Phase 7 `isGenuineEnd`） |
| P0-3 | 循环 / 定时关闭 | `android/app/src/main/java/com/fongmi/android/tv/setting/PlayerButtonSetting.java`、`android/app/src/main/java/com/fongmi/android/tv/event/ActionEvent.java` | **已实现（W1，见 §10）**：`core/playback_repeat.dart` + `core/sleep_timer.dart`；历史缺口是「连播固定、无循环与定时」 | `PLANNED apps/desktop-flutter/lib/core/playback_repeat.dart`（关/单集/列表）+ `PLANNED apps/desktop-flutter/lib/core/sleep_timer.dart`（分钟/本集结束）；播放器菜单与快捷键；OSD 提示。语义定为「退出播放器即取消，不跨进程持久化」 | L1：单集循环 EOF 不前进；列表循环回第一集；定时到点暂停并提示；L2：重进播放器定时器为空；L3：真实播放到点行为一致 |
| P0-4 | 播放参数（缓冲/预加载/硬解/失败回退/自动连播） | `android/app/src/main/java/com/fongmi/android/tv/setting/PlayerSetting.java`、`android/app/src/main/java/com/fongmi/android/tv/setting/PreloadSetting.java`、`android/app/src/main/java/com/fongmi/android/tv/setting/PlaybackPerformanceSetting.java` | **已实现（W1，见 §10）**：`core/player_options.dart` + mpv 属性注入 + 设置页；历史缺口是「无缓冲/预加载/硬解/回退开关」 | `PLANNED apps/desktop-flutter/lib/core/player_options.dart` + `PLANNED apps/desktop-flutter/lib/services/player_options_store.dart`；用 media-kit `NativePlayer.setProperty` 注入 `cache`/`demuxer-max-bytes`/`hwdec`/`audio-spdif`；预加载仅点播、限大小/超时/可取消；失败回退按「线路 → 解析 → 换源」 | L1：选项归一化、非法值拒绝；L2：设置持久化；L3：mpv property 读回一致；预加载关闭后零请求、开启不双下载；回退按序且日志可诊断 |
| P0-5 | LUT 滤镜 | `android/app/src/main/java/com/fongmi/android/tv/player/lut/LutSetting.java`、`android/app/src/main/java/com/fongmi/android/tv/ui/dialog/LutDialog.java`、`android/app/src/main/assets/lut_presets` | **已实现（W1，见 §10）**：`core/lut.dart` + 播放器 LUT 面板；历史缺口是「无 LUT 解析与应用」 | `PLANNED apps/desktop-flutter/lib/core/lut.dart` + `PLANNED apps/desktop-flutter/lib/services/lut_store.dart`；`.cube` 经 mpv `vf=lut3d` 应用；失败显式报「当前引擎不支持 LUT」；可选内置预设 | L2：应用后画面像素差 > 阈值且可还原；非法 cube 报错不崩溃；L3：重启恢复；不支持时明确文案，不静默 |
| P0-6 | 字幕源 / 自动匹配 / 手动搜索 / 本地字幕 | `android/app/src/main/java/com/fongmi/android/tv/subtitle/provider/SubtitleProviderRegistry.java`、`android/app/src/main/java/com/fongmi/android/tv/ui/dialog/SubtitleManualSearchDialog.java`、`android/app/src/mobile/java/com/fongmi/android/tv/ui/fragment/SettingSubtitleFragment.java` | **已实现（W1，见 §10）**：本地目录 + 通用 HTTP 源、自动匹配、手动搜索、本地文件、记忆；assrt 类第三方适配未内置（可用兼容 HTTP 端点） | `PLANNED apps/desktop-flutter/lib/core/subtitle_provider.dart` + `PLANNED apps/desktop-flutter/lib/services/subtitle_providers/`（assrt + 本地文件 + 目录扫描）；自动匹配（标题/季/集 + 语言优先级）；手动搜索 UI；匹配记忆；失败隔离。脚本源/订阅/实时翻译另列 P3 | L1：匹配评分与语言优先级；L2：无 subs 时自动加载、0 结果有空态；L3：真实字幕加载与切换；失败不影响播放；token 脱敏 |
| P0-7 | 弹幕库搜索 / 手动匹配 / 记忆 / 完整显示设置 | `android/app/src/main/java/com/fongmi/android/tv/ui/dialog/DanmakuSearchDialog.java`、`android/app/src/main/java/com/fongmi/android/tv/ui/dialog/DanmakuSettingPanel.java`、`android/app/src/main/java/com/fongmi/android/tv/bean/DanmakuMatchCache.java`、`android/app/src/main/java/com/fongmi/android/tv/setting/DanmakuSetting.java` | **已实现（W1，见 §10）**：库搜索、手动匹配、记忆、自动搜索；显示参数（速度/行数/区域/描边/时间偏移/透明度/字号/类型显隐）已补齐并持久化 | `apps/desktop-flutter/lib/core/danmaku_style.dart` + `apps/desktop-flutter/lib/core/danmaku_match.dart` + `apps/desktop-flutter/lib/services/danmaku_library_service.dart` + DB `danmaku_match` 表；API 地址可配；手动选择并记忆；速度、行数、区域、描边、时间偏移等参数写入顶层 `danmakuDisplay`。**屏蔽词不在本基准内**（webtv2 无该能力），不做假对齐 | L1：匹配键与记忆命中；L2：无弹幕时可搜索加载；L3：记忆跨重启；关闭后零请求；不阻塞播放 |
| P0-8 | 直播回看 + 直播设置 + 源级回退 | `android/app/src/main/java/com/fongmi/android/tv/bean/Live.java`、`android/app/src/main/java/com/fongmi/android/tv/bean/Catchup.java`、`android/app/src/main/java/com/fongmi/android/tv/api/parser/LiveParser.java`、`android/app/src/main/java/com/fongmi/android/tv/api/LiveApi.java`、`android/app/src/main/java/com/fongmi/android/tv/setting/LiveSetting.java` | **已实现（W1，见 §10）**：catchup 模板/解析/节目单入口 + 源级回退 + 直播设置；历史缺口是「无回看、无源级回退」 | `PLANNED apps/desktop-flutter/lib/core/live_catchup.dart`（`type`/`source`/`replace`/`days` 与 `${(b)fmt}`/`${(e)fmt}`/`${utc:}` 模板）；直播页回看入口（按节目单时间）；`PLANNED apps/desktop-flutter/lib/core/live_settings.dart`（源级回退、跨组切台、直播画面比例）；不迁移安卓的列表皮肤与手势 | L1：模板替换与时间生成（含 default/append 两种 type）；L2：无 catchup 不显示入口（不伪造）；L3：回看可播放并 seek；当前源全线路失败按配置切换下一源 |

### 4.2 P1 · 站点与协议生态

| ID | 能力 | 安卓依据 | PC 现状 | 迁移方案 | 验收条件 |
| --- | --- | --- | --- | --- | --- |
| P1-1 | 广告过滤（`ads` / `hlsRules`） | `android/app/src/main/java/com/fongmi/android/tv/api/config/HlsRuleConfig.java`、`android/app/src/main/java/com/fongmi/android/tv/utils/HlsAdblockPipeline.java`、`android/app/src/main/java/com/fongmi/android/tv/player/exo/ExoHlsAdblockDataSource.java`、`android/app/src/main/java/com/fongmi/android/tv/api/config/AdBlockStatsStore.java` | `apps/desktop-flutter/lib/core/protocol.dart` 解析 `ads`/`hlsRules` 但无消费点；本地代理只做 HLS 改写与 Range | `PLANNED apps/desktop-flutter/lib/core/ad_rules.dart` + `PLANNED apps/desktop-flutter/lib/services/ad_block_service.dart`；在 `lib/services/proxy_server.dart` 的 HLS 重写阶段剔除广告分片；域名规则拦截；统计与日志页 | L1：规则命中/排除/负样本；L2：设置与统计；L3：带广告分片的 HLS fixture 经代理可播且广告段消失；关闭直通、不误杀主内容 |
| P1-2 | 站点注入 + 识别 | `android/app/src/main/java/com/fongmi/android/tv/setting/CustomCspSetting.java`、`android/app/src/main/java/com/fongmi/android/tv/ui/dialog/CustomCspDialog.java` | 无；配置只读导入，`apps/desktop-flutter/lib/ui/config_pages.dart` 没有站点级 CRUD | `PLANNED apps/desktop-flutter/lib/core/site_injection.dart` + DB `injected_sites` + 合并进 `lib/core/config_parser.dart`（不改写源文件）+ CRUD UI + 粘贴松 JSON 识别 | L1：识别/去重/顺序；L2：新增站点可浏览/搜索；L3：启用禁用与重启保留；坏 JSON 不改库 |
| P1-3 | 健康排序用于搜索/换源 + 手动排序/屏蔽 | `android/app/src/main/java/com/fongmi/android/tv/setting/SiteHealthStore.java`、`android/app/src/main/java/com/fongmi/android/tv/ui/dialog/SiteHealthDialog.java`、`android/app/src/main/java/com/fongmi/android/tv/setting/SiteOrderStore.java`、`android/app/src/main/java/com/fongmi/android/tv/setting/SiteBlockSetting.java` | 健康数据只用于源场展示排序（`apps/desktop-flutter/lib/ui/source_field.dart`）；搜索按配置顺序（`lib/state/app_state.dart` 稳定排序） | `PLANNED apps/desktop-flutter/lib/core/site_order.dart`；`AppState.searchAll` 与换源排序接入；设置页开关；健康页加排序/屏蔽入口 | L1：排序稳定（同分按 key）；L2：开关持久化；L3：搜索首屏优先健康站点；关闭恢复配置顺序；屏蔽站点不参与 |
| P1-4 | 接口排序 + 失败切换 | `android/app/src/main/java/com/fongmi/android/tv/setting/InterfaceOrderStore.java`、`android/app/src/main/java/com/fongmi/android/tv/setting/InterfaceFailoverPolicy.java`、`android/app/src/main/java/com/fongmi/android/tv/setting/InterfaceFailoverState.java` | 单次选择（`apps/desktop-flutter/lib/core/parse_runtime.dart` + `lib/services/parse_service.dart`），无跨接口 failover | `PLANNED apps/desktop-flutter/lib/core/parse_order.dart` + `lib/services/parse_service.dart` 包装 failover；顺序与模式持久化；设置页 | L1：顺序/模式裁决；L2：设置 UI；L3：首选失败自动次选且结果一致；达上限如实报错；不改写配置 |
| P1-5 | 分组规则 + 站点名称规则 | `android/app/src/main/java/com/fongmi/android/tv/setting/GroupRuleConfig.java`、`android/app/src/main/java/com/fongmi/android/tv/ui/dialog/GroupRuleDialog.java`、`android/app/src/main/java/com/fongmi/android/tv/setting/SiteNameStore.java`、`android/app/src/main/java/com/fongmi/android/tv/ui/dialog/SiteNameDialog.java` | 仅内置「方括号标签」与「竖线后缀」提取（`apps/desktop-flutter/lib/core/site_group.dart`）；无规则配置、无名称别名 | 扩展 `lib/core/site_group.dart` 为可配置规则（4 条内置 + 自定义正则）+ 名称别名表；设置页 | L1：规则生效/非法正则拒绝；L2：规则 UI；L3：分组即时变化；别名只改显示不改 key |
| P1-6 | CSP 预热 | `android/app/src/main/java/com/fongmi/android/tv/api/CspWarmup.java`、`android/app/src/main/java/com/fongmi/android/tv/ui/dialog/CspWarmupDialog.java` | 无 | `PLANNED apps/desktop-flutter/lib/services/csp_warmup.dart`：启动后延迟、限并发、可关、失败静默、日志可见 | L1：并发/上限；L2：开关；L3：fixture 延迟下首次进站更快；关闭后零请求 |
| P1-7 | 直连 `.js` / `.py` 站点 | `android/app/src/main/java/com/fongmi/android/tv/api/loader/JsLoader.java`、`android/app/src/main/java/com/fongmi/android/tv/api/loader/PyLoader.java`、`android/app/src/main/java/com/fongmi/android/tv/api/loader/BaseLoader.java` | 必须走 `spider-local:` manifest（`apps/desktop-flutter/lib/services/spider_router.dart` 注释明示 `*.py` 直接形态未实现） | 自动注册：识别 `.js`/`.py` → 生成 manifest（runtime/权限/限制）→ 复用已有 sidecar；远程下载 + 哈希固定 + 大小上限；`lib/services/spider_router.dart` 接入 | L1：形态识别与 manifest 生成；L2：不可用时显式报错；L3：fixture js/py 站点可浏览；哈希变化拒绝加载 |
| P1-8 | 网盘检测 | `android/app/src/main/java/com/fongmi/android/tv/ui/dialog/PanNetworkDiagnosticDialog.java`、`android/app/src/main/java/com/fongmi/android/tv/setting/Setting.java` | 无；`apps/desktop-flutter/lib/core/cat_source.dart` 的「网盘」只是 T4 分集形态，没有可用性检测 | `PLANNED apps/desktop-flutter/lib/services/pan_check_service.dart`：HEAD/关键页 + 失效特征；可用/失效/需登录三态；并发与缓存；详情页入口 | L1：三态判定；L2：入口与结果；L3：真实分享链接验证；不阻塞播放、不记敏感链接 |
| P1-9 | 出站代理（APP 代理）+ 多线程代理 | `android/app/src/main/java/com/fongmi/android/tv/setting/ProxySetting.java`、`android/app/src/main/java/com/fongmi/android/tv/ui/dialog/ShellProxyDialog.java`、`android/app/src/main/java/com/fongmi/android/tv/ui/dialog/MultiThreadProxyDialog.java` | 仅回环本地代理（`apps/desktop-flutter/lib/services/proxy_server.dart`），无按域名的出站代理、无多线程下载 | `PLANNED apps/desktop-flutter/lib/services/outbound_proxy.dart` + HttpClient 工厂注入（站点/解析/播放请求）；按域名规则；凭据脱敏；多线程代理单列 ADR | L1：规则命中/直连；L2：设置 UI；L3：请求经 fixture 代理可见；关闭后无代理 |
| P1-10 | AI 能力扩展（标题提取 / 广告检测 / 日志诊断 / 推荐 / 分组识别） | `android/app/src/main/java/com/fongmi/android/tv/service/AiTitleExtractionService.java`、`android/app/src/main/java/com/fongmi/android/tv/service/AiAdDetectionService.java`、`android/app/src/main/java/com/fongmi/android/tv/service/AiLogDiagnosisService.java`、`android/app/src/main/java/com/fongmi/android/tv/service/AiRecommendationService.java`、`android/app/src/main/java/com/fongmi/android/tv/service/AiGroupRuleService.java` | 仅集季（`apps/desktop-flutter/lib/services/ai_episode_season_service.dart`）；`lib/core/android_sync.dart` 的 `pcUnsupportedSettingsKeys` 明示标题/广告不支持 | 每能力独立 service + 开关 + 复用 `lib/services/ai_completion_client.dart`；默认关闭；提示词注入防护；结果需用户确认才应用 | L1：开关与非法输出拒绝；L2：UI 与披露；L3：真实调用超时/失败降级；未配置零请求 |

### 4.3 P2 · 内容与同步

| ID | 能力 | 安卓依据 | PC 现状 | 迁移方案 | 验收条件 |
| --- | --- | --- | --- | --- | --- |
| P2-1 | 追番 | `android/app/src/main/java/com/fongmi/android/tv/following`、`android/app/src/main/java/com/fongmi/android/tv/ui/activity/FollowingActivity.java`、`android/app/src/main/java/com/fongmi/android/tv/following/FollowingScheduler.java` | **已实现（W3，见 §12）**：DB v6 `following`、身份/调度/更新/退避策略、详情页追番、追番页（检查/播放最新集/已读/取消）、侧栏徽标；**无**后台常驻与系统通知 | `apps/desktop-flutter/lib/core/following.dart`（身份键/调度/更新/通知策略）+ `apps/desktop-flutter/lib/services/following_service.dart`（详情集数检查、串行、失败退避）+ DB v6 `following` + `apps/desktop-flutter/lib/ui/following_page.dart`；备份随整库快照自动包含 | L1：调度与合并；L2：页面/通知开关；L3：检测到新集可播放；失败隔离；可导出恢复 |
| P2-2 | 观影报告 | `android/app/src/main/java/com/fongmi/android/tv/viewing/ViewingReportGenerator.java`、`android/app/src/main/java/com/fongmi/android/tv/viewing/ViewingReportAiAnalyzer.java`、`android/app/src/main/java/com/fongmi/android/tv/ui/activity/ViewingReportActivity.java` | **已实现（W3，见 §12）**：`core/viewing_report.dart` 本地统计 + 9 种范围 + 徽章 + 时段分布；`services/viewing_report_ai.dart` 可选 AI 解读；历史页入口；无导出 | `apps/desktop-flutter/lib/core/viewing_report.dart`（纯本地统计，`now` 注入）+ `apps/desktop-flutter/lib/ui/viewing_report_page.dart` + 可选 AI 分析；**没有导出**（不做假入口）。历史表缺少题材/地区/演员，因此不做这四类榜单，用「最常看作品」替代并写明差异 | L1：黄金样本统计一致；L2：空库空态；L3：AI 关闭基础报告完整、AI 失败降级 |
| P2-3 | 短剧 | `android/app/src/main/java/com/fongmi/android/tv/bean/ShortDramaConfig.java`、`android/app/src/main/java/com/fongmi/android/tv/ui/dialog/ShortDramaSourceDialog.java` | 无；`apps/desktop-flutter/lib/core/cat_source.dart` 明示小说/漫画/音乐/网盘分组不接入点播 | 解析 displayRules + 播放器队列 + 独立入口；复用现有播放链路，不引入新运行时 | L1：识别/排序；L2：入口；L3：连续播放与进度正确 |
| P2-4 | 一键同步扩展 | `android/app/src/main/java/com/fongmi/android/tv/ui/dialog/OneKeySyncDialog.java` | 仅历史/收藏/6 个设置键（`apps/desktop-flutter/lib/core/android_sync.dart` 的 `pcSettingsWhitelist`） | 扩展 Backup 结构（配置/站源数据/登录态/WebHome/搜索记录）+ 双向 + 默认关闭 + 能力披露；改动落在 `lib/core/android_sync.dart`/`lib/services/sync_client.dart` | L1：字段映射/脱敏/旧不覆盖新；L2：勾选项 UI；L3：真实安卓往返；失败不破坏本地 |
| P2-5 | 登录态学习 / 同步 | `android/app/src/main/java/com/fongmi/android/tv/utils/LoginStateSync.java`、`android/app/src/main/java/com/fongmi/android/tv/ui/dialog/LoginStateLearnDialog.java` | 无 | 经安卓桥接 API 读取/推送（不在 PC 解析安卓沙箱）；路径白名单 + 用户确认；落在 `PLANNED apps/desktop-flutter/lib/services/login_state_bridge.dart` | L1：白名单/脱敏；L2：待确认列表；L3：往返同步；失败可诊断 |
| P2-6 | 观影记录同步（远端拉取 + Webhook） | `android/app/src/main/java/com/fongmi/android/tv/playback/ViewingRecordSyncStore.java`、`android/app/src/main/java/com/fongmi/android/tv/ui/dialog/ViewingRecordSyncDialog.java` | 无 Webhook/远端拉取；只有与安卓的直连同步 | `PLANNED apps/desktop-flutter/lib/services/viewing_webhook.dart` + 远端拉取 + 删除墓碑；默认关闭 | L1：批次/幂等/墓碑；L2：配置 UI；L3：真实端点往返；重试不重复 |
| P2-7 | 应用更新 / 自动备份 / 数据重置 | `android/app/src/main/java/com/fongmi/android/tv/Updater.java`、`android/app/src/main/java/com/fongmi/android/tv/setting/AutoBackupPolicy.java` | **部分实现（W3，见 §12）**：手动备份 zip（设置+数据库快照+清单校验）、检查、恢复、重置；**没有**自动备份与应用更新（更新签名通道未定） | `apps/desktop-flutter/lib/core/backup_manifest.dart` + `apps/desktop-flutter/lib/services/backup_service.dart` + `apps/desktop-flutter/lib/ui/backup_page.dart`；数据库用 `VACUUM INTO` 一致性快照；恢复前逐文件 SHA-256 校验、坏备份不覆盖；重置二次确认并回到未导入配置。自动备份/更新需 ADR，暂不做 | L1：备份内容清单/校验；L2：入口；L3：恢复后配置/历史一致；重置回导入页 |
| P2-8 | DoH / 隐身 / 崩溃恢复 | `android/app/src/main/java/com/fongmi/android/tv/ui/activity/CrashActivity.java`、`android/app/src/main/java/com/fongmi/android/tv/ui/activity/PlaybackRecoveryActivity.java`、`android/app/src/main/java/com/fongmi/android/tv/setting/Setting.java` | **已实现（W3，见 §12）**：DoH（配置 `doh`/`hosts` + 自定义端点 + 磁盘缓存，RFC 8484）；隐身（不写历史/搜索/季度进度）；崩溃恢复（会话标记 + 有界崩溃日志 + 启动横幅 + 按续播路径恢复） | `apps/desktop-flutter/lib/core/doh.dart`、`apps/desktop-flutter/lib/core/doh_settings.dart`、`apps/desktop-flutter/lib/services/doh_resolver.dart`（只作用于站点/解析/字幕等出站请求，不进播放代理）；`apps/desktop-flutter/lib/core/session_recovery.dart`、`apps/desktop-flutter/lib/services/session_recovery_store.dart`、`apps/desktop-flutter/lib/ui/recovery_banner.dart`；隐身偏好写入顶层 `incognito`，DoH 写入顶层 `doh` | L1：隐身不落库；L2：设置；L3：强杀后重启提示并恢复；DoH 解析可验证 |
| P2-9 | 本地/网盘文件浏览 | `android/app/src/leanback/java/com/fongmi/android/tv/ui/activity/FileActivity.java`、`android/app/src/mobile/java/com/fongmi/android/tv/ui/activity/FolderActivity.java`、`android/app/src/mobile/java/com/fongmi/android/tv/ui/fragment/FolderFragment.java` | 无；配置导入用文本路径对话框（`apps/desktop-flutter/lib/ui/config_pages.dart` 的 `_pickFile`），没有原生文件选择器、没有媒体文件浏览 | 原生文件选择 + 目录浏览 + 类型识别 + 直接播放（只读、路径白名单）；落在 `PLANNED apps/desktop-flutter/lib/ui/file_browser_page.dart` | L1：路径与类型判定；L2：浏览页；L3：打开本地视频/音频可播放；越权路径拒绝 |

### 4.4 P3 · 平台决策（需 ADR）

| ID | 能力 | 安卓依据 | PC 现状 | 迁移方案 | 验收条件 |
| --- | --- | --- | --- | --- | --- |
| P3-1 | WebHome 自定义首页 + 扩展 + 主题 | `android/app/src/main/java/com/fongmi/android/tv/ui/web/CatWebActivity.java`、`android/app/src/main/java/com/fongmi/android/tv/web`、`android/app/src/main/assets/webhome`、`android/webhome-devkit` | 明确不支持；`apps/desktop-flutter/lib/core/parse_runtime.dart` 注明 type=0 需浏览器内核；`pubspec.yaml` 无 WebView 依赖 | **ADR-0003**：WebView2 独立进程/独立 profile + 受限 bridge（对齐 Android SDK 子集）；未通过 ADR 则保持「不迁移 + 披露」，不得用半成品占位 | L1：bridge 白名单；L2：首页加载与错误降级；L3：示例 homePage 可用；安全测试（无本地文件、无任意 IPC、无凭据外泄） |
| P3-2 | 听书 / 音频模式 / TTS | `android/app/src/main/java/com/fongmi/android/tv/ui/activity/AudioActivity.java`、`android/app/src/main/java/com/fongmi/android/tv/ui/audio`、`android/app/src/main/java/com/fongmi/android/tv/tts` | 无；播放器只有视频面 | 音频模式（最小 UI）+ Windows SAPI/Edge TTS + 系统媒体键（SMTC）；落在 `PLANNED apps/desktop-flutter/lib/ui/audio_mode_page.dart` | L1：TTS 分段/缓存；L2：音频模式；L3：系统媒体键可控；失败静音回退 |
| P3-3 | 小说/漫画阅读器 | `android/app/src/main/java/com/fongmi/android/tv/ui/web/WebReaderActivity.java`、`android/app/src/main/java/com/fongmi/android/tv/ui/novel` | 无；`apps/desktop-flutter/lib/core/cat_source.dart` 明示小说/漫画不接入 | 分页/进度/目录 + displayRules + 缓存；落在 `PLANNED apps/desktop-flutter/lib/ui/reader_page.dart` | L1：分页/进度；L2：阅读 UI；L3：fixture 源阅读并恢复 |
| P3-4 | GitCloud 云备份 | `android/app/src/main/java/com/fongmi/android/tv/gitcloud` | 无 | Git provider（GitHub/Gitee/GitLab）+ 凭据加密 + 备份/恢复；落在 `PLANNED apps/desktop-flutter/lib/services/git_cloud_service.dart` | L1：provider 协议；L2：账号 UI；L3：往返备份；冲突提示 |
| P3-5 | 管理页 `/m` | `android/app/src/main/java/com/fongmi/android/tv/server/Nano.java` | 无；本地代理只监听回环、路径空间 `/p/<token>/…`（`apps/desktop-flutter/lib/core/proxy_policy.dart`） | LAN 服务 + 鉴权 + 管理 UI；ADR 明确绑定地址/端口/权限；落在 `PLANNED apps/desktop-flutter/lib/services/manage_server.dart` | L1：鉴权/路径；L2：页面；L3：局域网访问；未授权拒绝 |
| P3-6 | 远程托管（relay） | `android/app/src/main/java/com/fongmi/android/tv/remote`、`android/serverless` | 无 | 与 serverless 协议对接（WebSocket / HTTP 轮询）+ 设备绑定 + 信任；落在 `PLANNED apps/desktop-flutter/lib/services/remote_relay.dart` | L1：协议/令牌；L2：绑定 UI；L3：远端指令往返；不可达降级 |
| P3-7 | DLNA 投屏 / 远程遥控 | `android/app/src/main/java/com/fongmi/android/tv/dlna`、`android/app/src/leanback/java/com/fongmi/android/tv/ui/activity/CastActivity.java`、`android/app/src/main/java/com/fongmi/android/tv/remote` | 无；`apps/desktop-flutter/lib/core/player_buttons.dart` 明确排除 `cast` | DLNA 发送端（SSDP + AVTransport）；遥控=LAN 控制协议；先 ADR 再实现 | L1：SSDP/描述；L2：设备列表；L3：模拟接收端可播；失败可诊断 |

---

## 5. 明确不迁移（必须披露）

> 披露口径：**如实说明「PC 端不提供 X」**；有替代路径就写替代路径（例如安卓桥接、系统终端、mpv 选项），没有就直说。不得写成「暂不支持」来暗示即将支持。

| ID | 项 | 理由 | 对外披露文案 |
| --- | --- | --- | --- |
| N1 | Android dex/JAR 站源 | 只有 ART 能执行 dex；PC JVM 只接受无 Android Context 的桌面 jar（ADR-0002） | 「含 dex 的安卓站源在 PC 端无法执行；请通过安卓桥接（T4 网关）使用安卓侧的这些站源。」 |
| N2 | Exo/IJK 内核、Codec 能力探测、MPV 配置档案 | 播放器栈不同（PC 为 media-kit/mpv），切换内核在桌面没有对应物 | 「PC 端固定使用 mpv 播放内核，不提供 Exo/IJK 切换；解码与缓冲参数在播放设置中以 mpv 选项形式提供。」 |
| N3 | TV/遥控器焦点、手势、亮度记忆、屏幕旋转 | 桌面输入模型与显示模型不同 | 「PC 端以键鼠为输入，不提供遥控器焦点、手势与屏幕方向相关设置。」 |
| N4 | Android Intent、APK 推送、前台保活、电池适配 | 系统集成专属 | 「APK 推送、后台保活与电池适配属于安卓系统能力，PC 端不提供。」 |
| N5 | Lab shell 实验室 | 桌面本身可执行命令，风险与产品边界不同，未评估前不进入默认范围 | 「Lab 实验室为安卓端能力，PC 端未提供；如需执行命令请使用系统终端。」 |
| N6 | 游戏模式 | 依赖 Android WebView 游戏容器 | 「游戏模式依赖安卓 WebView 容器，PC 端不提供。」 |
| N7 | AppBranding 品牌页 | PC 已实现配置驱动的 `wallpaper`/`logo`，且优先级高于自身身份 | 「PC 端使用配置提供的壁纸与 Logo，不提供独立的品牌设置页。」 |
| N8 | 内置影视资源 / 站点配置 / 爬虫 | 产品边界（不内置资源、不内置配置、不内置爬虫） | 「PC 端不内置任何影视资源、站点配置或爬虫，全部由用户自行导入。」 |

---

## 6. 波次计划

| 波次 | 范围 | 出口门禁 | 依赖 |
| --- | --- | --- | --- |
| W1 | P0-1…P0-8 | 每项 L1 + L2 + 至少 1 条 L3；反向验证 ≥3；真实窗口截图；`docs/phase9/evidence/` | 无（media-kit 现有 API） |
| W2 | P1-1…P1-10 | 同上 + fixture（HLS 广告、注入站点、代理、failover、js/py 站点） | W1 的代理与设置框架 |
| W3 | P2-1…P2-9 | 同上 + 真实端点/真机往返证据 | 安卓契约（P2-4/P2-5/P2-6） |
| W4 | P3-1…P3-7 | 先 ADR 再实现；ADR 未通过 → 保持不迁移 + 披露 | ADR-0003/0004/0005 |

工作量级（粗估，S≤3 人日 / M≤10 人日 / L>10 人日）：P0 合计约 **M–L**；P1 约 **L**；P2 约 **L**；P3 约 **L×2**，其中 P3-1（WebHome）单项为 L 且风险最高。

---

## 7. 契约与数据流变更（实施时按此落地）

- **DB**（`apps/desktop-flutter/lib/services/storage.dart`，当前 `schemaVersion = 5`）：v4 新增 `skip_segments`、`subtitle_match`、`danmaku_match`；v5 新增 `injected_sites`；W3 再加 `following*`、`viewing_*`。旧库幂等建表，禁止清表。
- **settings.json 新键**：`player`、`subtitles`、`danmaku`、`live`、`siteOrder`、`parseOrder`、`adRules`、`outboundProxy`。缺省值必须等价于当前行为（不得改变既有默认）。
- **同步协议**：扩展时保持 Phase 5/7 三原则（默认关闭、旧不覆盖新、能力缺口披露）；`lib/core/android_sync.dart` 的白名单与 `unsupportedKeys` 同步更新。
- **代理数据流**：广告过滤与出站代理都在代理/HttpClient 工厂层，播放器不感知；不得把回环代理扩展成开放代理（沿用 `lib/core/proxy_policy.dart`）。

---

## 8. 门禁与证据（G9.1–G9.5）

| 门禁 | 检查 | 失败即拒绝 |
| --- | --- | --- |
| G9.1 | 矩阵每行 6 列且非空；ID 唯一；前缀与档位一致 | 缺字段 / 重复 ID |
| G9.2 | 所有 `android/` 引用在 `--android-root` 存在；仓库缺失时记录 commit 并警告 | 引用不存在 |
| G9.3 | 覆盖：43 个 manifest 屏幕、84 个对话框、9 个设置 Fragment、34 个模块，每个至少在 `design/05-upstream-map.md` 出现一次 | 有未映射项 |
| G9.4 | 所有 `apps/desktop-flutter/` 引用存在；`PLANNED ` 前缀登记后可缺失 | 路径错 / 未登记 |
| G9.5 | 每个 N 项都有「理由 + 对外披露文案」 | 缺披露 |

运行：

```powershell
py -3 tools/phase9/verify_gap_matrix.py
# 或指定安卓仓库：--android-root F:/Workspace/webtv2/webhtv
```

退出码：0 全绿；1 有失败；2 安卓仓库缺失（已警告，未静默通过）。

测试与证据规范见 `docs/phase9/design/04-acceptance.md`。

---

## 9. 风险、假设与已确认决定

- **假设**：基准固定 `webtv2@77e2fbefdc`；PC 以 Windows 优先。
- **已确认（2026-10-21，用户决策）**：
  1. 顺序按 P0 → P1 → P2 → P3 推进；
  2. **WebHome 做**（P3-1/P3-2/P3-3），但必须先过 ADR-0003：独立进程/独立 profile 的 WebView2 + 受限 bridge，禁止在主进程执行页面脚本；
  3. **内容形态在范围内**：短剧（P2-3）、听书/TTS（P3-2）、小说/漫画（P3-3）；
  4. **接受新增依赖**：WebView2（`webview_windows` 或等价方案）、Windows 通知/SMTC、TTS 引擎，均需在 ADR 中登记来源、版本与失败降级。
- **风险**：真实源验证依赖用户配置（只承诺 fixture 可复现 + 真实样本脱敏记录）；WebHome 与 LAN 服务涉及安全边界，ADR 未通过前不得进入实现；P3 工作量可能超过 P0–P2 总和。
- **ADR 清单**：ADR-0003（WebHome 进程与 bridge）、ADR-0004（局域网服务/管理页）、ADR-0005（远程托管与信任）、ADR-0006（新增依赖与降级）。

---

## 10. 实施进度（W1）

| 缺口 | 状态 | 落地内容 | 证据 |
| --- | --- | --- | --- |
| P0-1 音轨/视频轨 | **已实现** | `core/player_tracks.dart`；`player_controller` 暴露 `selectAudioTrack/selectVideoTrack`；顶栏「更多」与右键菜单入口；按引擎轨道 id 选择（不用下标） | `test/phase9_player_core_test.dart` |
| P0-2 片头片尾 | **已实现** | `core/skip_segments.dart`；DB v4 `skip_segments` 表（按影片）；自动/手动跳过、标记与清除、设置开关；`Alt+[ / Alt+]` | `test/phase9_player_core_test.dart`、`test/phase9_storage_test.dart` |
| P0-3 循环/定时 | **已实现** | `core/playback_repeat.dart` + `core/sleep_timer.dart`；连播闸门改为「循环 > autoNext」；定时到点暂停、退出播放器即取消 | `test/phase9_player_core_test.dart` |
| P0-4 播放参数 | **已实现** | `core/player_options.dart`；mpv 属性注入（缓存/硬解/音频直通/回退策略/预加载开关）；设置页「播放参数」区块；顶层 `player` 段持久化 | `test/phase9_player_core_test.dart`、`test/phase9_preferences_test.dart` |
| P0-5 LUT | **已实现** | `core/lut.dart`（.cube 校验 + mpv vf 构造）；播放器菜单应用/清除；能力不支持时显式提示 | `test/phase9_player_core_test.dart` |
| P0-6 字幕源 | **已实现** | `core/subtitle_provider.dart` + `core/subtitle_settings.dart`；本地目录与通用 HTTP 源、自动匹配编排、手动搜索、本地文件、记忆；设置页「字幕源」独立页 | `test/phase9_subtitle_provider_test.dart`、`test/phase9_storage_test.dart`、`test/phase9_preferences_test.dart` |
| P0-7 弹幕库 | **已实现** | `core/danmaku_match.dart` + `core/danmaku_settings.dart`；库搜索、手动匹配、记忆、自动搜索；**显示参数已补齐**（`core/danmaku_style.dart`：速度/行数/区域/描边/时间偏移/透明度/字号/类型显隐），播放器内即改即生效并写入顶层 `danmakuDisplay` | `test/phase9_danmaku_library_test.dart`、`test/phase9_danmaku_display_test.dart`、`test/phase9_storage_test.dart` |
| P0-8 直播回看 | **已实现** | `core/live_catchup.dart`（模板/替換/时区）；M3U/JSON 解析 catchup；节目单回看入口；`core/live_settings.dart`（源级回退/自动换线）；跨源同名频道回退 | `test/phase9_live_catchup_test.dart`、`test/phase3_live_page_test.dart` |

**L3 真实窗口（2026-10-21）**：`integration_test/phase9_player_flow_test.dart`
5 个用例全过（片头落库 + 真起播、定时契约、轨道入口、菜单截图、直播回看地址）。
截图 `docs/phase9/evidence/screenshots/01-context-menu-skip-segments.png`
两次独立运行逐字节一致（`sha256=5fa05988…b02a4`）。原始输出与
**未证到的四项**（真实双音轨切换、真实 EOF 定时、真实 seek 位置、回看出画）
见 `docs/phase9/evidence/02-p0-l3.md`——不得把「契约级」写成「引擎级」。

已知偏差（与设计稿不同，已在对应设计文档注明）：

- 片头片尾存 **按影片** 的 `skip_segments` 表，而不是 `history` 两列（同一部剧各集片头片尾一致，按集存会强迫用户逐集标记）。
- 直播「切台跨分组」与「列表皮肤/手势反转」暂不迁移：桌面输入模型不同，且当前直播页没有跨分组切台 UI，避免设置项无行为。
- 预加载只做「下一集地址预解析」，不下载媒体数据（与设计稿一致，防止被误解为边下边播）。
- 站点屏蔽比安卓**多管一层**：安卓 `SiteBlockSetting.filter` 只在站点选择弹窗生效（被屏蔽站点仍参与搜索），PC 按本仓 P1-3 的验收口径把它同时排除在多站点搜索/换源候选之外——否则用户会搜到列表里根本看不到的站点。搜索范围分组同步收窄（只剩被屏蔽站点的分组不再出现）。
- 屏蔽集合的分桶口径与安卓**不同**：安卓 `SiteBlockSetting` 全局只用一个 `site_block_keys` 键（换配置照样继承），PC 按配置记录 id 分桶，与手动顺序（安卓 `site_dialog_order_ + cid`）一致。理由：同一站点 key 在不同配置里是不同站源，屏蔽不该跨配置传染。
- 「隐去」的范围限定为**站点选择器**：被屏蔽站点仍留在 `siteItems` 里（当前站点、历史恢复、诊断页与 AI 源名照常显示），否则当前正在使用的站点会悬空。手动顺序/屏蔽都是本地覆盖，不写回配置文件；屏蔽也会让「上次使用的站点」不再作为下次启动的默认站点（本次会话仍照常使用）。

---

## 11. 实施进度（W2）

| 缺口 | 状态 | 落地内容 | 证据 |
| --- | --- | --- | --- |
| P1-3 站点排序 + 屏蔽 | **已实现** | 健康排序：`core/site_order.dart`（无样本排最后、同分稳定）+ `AppState.searchAll` 重排 + 设置页开关 + 顶层 `siteOrder` 持久化。手动排序 + 屏蔽（参照安卓 `SiteOrderStore`/`SiteBlockSetting`）：站点选择器顶部「手动排序」进入单列拖拽模式（`ReorderableListView` + 拖动手柄 + 恢复默认），「眼睛」进入屏蔽管理模式（点行切换屏蔽、被屏蔽行压暗标注）；两者按配置记录 id 分桶存顶层 `siteList` 段（顺序的分桶口径与安卓一致；屏蔽安卓是全局单键，见已知偏差），被屏蔽站点从站点选择器隐去且不参与搜索/换源候选 | `test/phase9_site_order_test.dart`、`test/phase9_preferences_test.dart`、`test/site_list_manage_state_test.dart`、`test/site_picker_manage_test.dart` |
| P1-4 接口失败切换 | **已实现（失败切换；自定义排序待续）** | `core/parse_failover.dart`（只收 JSON 类、排除首选、去重、上限）；`ParseService.runWithFallback` 重试链；`SiteService.resolvePlayback/_runParser` 接线；设置页开关；顶层 `parseFailover` 持久化 | `test/phase9_parse_failover_test.dart`、`test/phase9_preferences_test.dart`、`test/phase3_parser_test.dart` |
| P1-5 分组规则 | **已实现（规则部分；站点改名待续）** | `core/site_group_rules.dart`：4 条内置规则可开关 + 自定义正则；`siteGroupsOf`/筛选/站点选择器全部接入；高级设置页可增删启停；顶层 `siteRules` 持久化 | `test/phase9_site_group_rules_test.dart`、`test/phase9_preferences_test.dart`、`test/phase8_settings_entries_test.dart` |
| P1-6 CSP 预热 | **暂缓（避免假功能）** | PC 的 `csp_*` 走按次启动的 JVM sidecar，没有常驻进程池；现有 API 只能“启动后立刻结束”，无法产生可观测预热收益。需先做 sidecar 常驻池（另立设计），否则开关无行为 | — |
| P1-10 AI 辅助 | **已实现（4 类，只建议不自动应用）** | `core/ai_assist.dart`（提示词注入防护、输入截断、受限 JSON 解析、结果提取）+ `services/ai_assist_service.dart` + 独立页；覆盖标题清洗/日志诊断/分组建议/广告分片判定；未配置时零请求 | `test/phase9_ai_assist_test.dart`、`test/phase9_ai_assist_page_test.dart` |
| P1-8 网盘检测 | **已实现（形态识别 + 可达性判定）** | `core/pan_check.dart`（6 类网盘识别、提取码抽取、归一化、五态判定、TTL 缓存）；`services/pan_check_service.dart`（有界 GET、并发 4、请求去重）；独立检测页；**不做**各网盘私有 API 逆向，判不出即 `uncertain` | `test/phase9_pan_check_test.dart`、`test/phase8_settings_entries_test.dart` |
| P1-9 出站代理 | **已实现（按域名分流）** | `core/outbound_proxy.dart`（规则/默认代理/域名匹配/`findProxy` 串）＋ `services/outbound_proxy.dart`（`IOClient` 工厂）；`AppState` 启动与设置变更时重建 HTTP 客户端；高级设置页可增删规则、设默认代理；顶层 `outboundProxy` 持久化 | `test/phase9_outbound_proxy_test.dart`、`test/phase9_preferences_test.dart`、`test/phase2_proxy_test.dart` |
| P1-7 直连 js/py | **已实现** | `services/direct_spider_registrar.dart`：识别 `type=3` 且 `.js`/`.py` → 下载（http(s)/2 MiB/20s）→ 落 `<root>/direct/<hash>/` → 生成 manifest（runtime node/python + entrySha256）→ 注册；哈希一致不重复下载；`SpiderRouter` 接入可用性判定与运行时创建；配置装配后异步注册 | `test/phase9_direct_spider_test.dart`、`test/phase3_js_spider_test.dart` |
| P1-2 站点注入 | **已实现** | `core/site_injection.dart`（宽松识别、校验、合并但不改写配置）；DB v5 `injected_sites`；AppState 合并为 `effectiveConfig`；管理页（添加/启停/删除）；设置页「高级设置」入口 | `test/phase9_site_injection_test.dart`、`test/phase9_storage_test.dart`、`test/phase8_settings_entries_test.dart` |
| P1-1 广告过滤 | **已实现（HLS 分片清洗 + ads 主机阻断）** | `core/ad_rules.dart`：`ads` 主机清单（含子域）、`hlsRules` 子集（清单范围、分片主机/URL/时长/不连续/跨域、minimumSignals）；`LocalProxyServer` 在 DNS 前拦广告主机、HLS 重写前清洗分片（保留 KEY/MAP）；设置页总开关；顶层 `adBlock` 持久化 | `test/phase9_ad_rules_test.dart`、`test/phase9_preferences_test.dart`、`test/phase2_proxy_test.dart` |

说明：

- P1-3 健康排序只影响搜索/换源顺序；手动顺序与屏蔽有独立 UI（站点选择器里的
  「手动排序 / 管理屏蔽站点」），不再是「没有界面的隐藏配置」。
  换源对话框的展示排序仍沿用 `source_field.dart` 既有的星等排序。
- P1-4 只做「解析失败后按配置顺序再试一个 JSON 类接口」，默认关闭；不做自定义接口排序
  （没有排序 UI 的配置等于假功能）。非解析错误不重试，避免掩盖调用方缺陷。
- P1-1 的 `hlsRules` 是**子集**：未实现安卓的 `segmentUrlRegex` 之外的规则版本/来源管理、
  `#EXT-X-DATERANGE` 类广告标记与统计面板；规则为空时不做任何“启发式猜测”。
  广告主机拦截只作用于经本地代理的请求；直连播放器请求不受影响（已知边界）。
- Phase 9 的设置项统一收进独立「高级设置」页：设置页继续堆新区块会把
  `settings-osd` / `settings-player-buttons` 挤出既有固定视口（`phase8_settings_entries_test`
  实测），独立页后设置页长度回到 Phase 8 水平。
- 站点注入与配置记录**分开存放**：`_config` 永不被改写，注入只在读取时合并为
  `effectiveConfig`；删除注入即恢复原配置。
- P1-10 的能力边界：只做「建议」，**不自动应用**（不改标题、不改分组、不改播放地址）；
  输入按不可信数据处理并在提示词里显式声明；输出必须是受限 JSON，否则判失败。
- P1-8 的能力边界：只做「链接形态 + 页面特征」判定，不做各家私有分享接口适配；
  页面改版时结果退化为 `uncertain`（不误报失效）；网络不可达同样是 `uncertain`。
- P1-9 只做「站点/解析/字幕等出站请求的按域名代理」，**不替代**本地回环播放代理；
  只支持 HTTP 代理（`dart:io findProxy` 限制），SOCKS 未实现；多线程下载代理（安卓
  `MultiThreadProxyDialog`）不在本项范围。
  **附带修复（2026-10-21）**：`bootstrap()` 过去会用出站代理无条件重建
  `_httpClient`，把构造时注入的客户端丢掉（`phase2_startup_home_test` 因此
  一直拿到 400）；现在代理未生效时保留注入客户端，只有生效时才重建。

---

## 12. 实施进度（W3）

| 缺口 | 状态 | 落地内容 | 证据 |
| --- | --- | --- | --- |
| P2-2 观影报告 | **已实现** | `core/viewing_report.dart`：9 种范围（全部/本年/上下半年/本季/本月/本周/近 30 天/近 7 天）、时段分布、周末与深夜、完播率、作品去重、最常看、3 类徽章；`ui/viewing_report_page.dart`：范围切换、统计卡、时段条、徽章、AI 解读；历史页工具栏入口；`services/viewing_report_ai.dart`：未配置零请求、失败只提示 | `test/phase9_viewing_report_test.dart`（16 用例） |
| P2-7 备份/恢复/重置（部分） | **已实现（手动备份；自动备份/更新未做）** | `core/backup_manifest.dart`（清单/路径安全/SHA-256 校验/库版本门禁）；`services/backup_service.dart`（zip 读写、`VACUUM INTO` 快照）；`state/app_state.dart`（恢复时关闭→校验→原子替换→重新 bootstrap，失败回滚）；`ui/backup_page.dart` + 高级设置入口；重置回到未导入配置 | `test/phase9_backup_test.dart`（9 用例） |
| P2-8 DoH / 隐身 / 崩溃恢复 | **已实现** | `core/doh.dart`（RFC 8484 编解码、端点/hosts 解析、缓存模型）；`services/doh_resolver.dart`（查询、TTL 缓存、磁盘缓存、失败回落系统 DNS、多端点切换）；`services/outbound_proxy.dart` 用 `connectionFactory` 接管 DNS（保留 SNI/证书校验）；隐身：`recordProgress`/搜索关键词/季度进度不落库；崩溃恢复：`core/session_recovery.dart` + `services/session_recovery_store.dart`（pid 标记、64KiB 有界崩溃日志）+ `ui/recovery_banner.dart`（继续上次播放/忽略/看日志），窗口关闭时删标记 | `test/phase9_doh_test.dart`（15 用例）、`test/phase9_privacy_recovery_test.dart`（12 用例） |

| P2-1 追番 | **已实现（应用运行期检查；无后台服务/系统通知）** | `core/following.dart`：身份键、6h/24h/7d 调度、首播+30m、失败退避、更新/通知水位、设置；DB v6 `following`（29 列，水位与集数）；`services/following_service.dart`：站点详情该线路集数 → 更新策略 → 串行检查；`ui/following_page.dart` + 侧栏徽标 + 详情页 ★；支持播放最新集（复用历史续播路径）与标记已读 | `test/phase9_following_test.dart`（16 用例） |
已知偏差（已在 §4.3 与本表注明）：

- PC `history` 表没有题材/地区/演员/导演字段，因此**不做**安卓那四类偏好榜单，
  也没有「跨文化探索者」徽章；用「最常看作品」替代——这是真实可得的统计，
  不是拿空数据凑数。
- 时段与周末按 `history.updated_at`（最后观看时间）统计，安卓用的是 `create_time`；
  页面文案已写明。
- **不做导出**（安卓 Activity 有分享/导出入口，PC 本轮没有文件导出通道）；
  需要时另立缺口，不先摆一个点了没反应的按钮。
- P2-7 只做**手动**备份/恢复/重置：自动备份需要后台调度与保留策略、
  应用更新需要签名通道（ADR），本轮都不做；备份不含缓存与日志。
- 恢复是「校验 → 关闭数据库 → 原子替换设置与库 → 重新 bootstrap」；
  坏备份在校验阶段就被拒绝，不会先关闭本地存储。重置会删除设置与数据库，
  回到「未导入配置」。
- P2-8 的 DoH 只接**站点/解析/字幕等出站请求**：本地回环播放代理保留自己的
  DNS 重绑定防护（每次连接前解析并复核全部地址），刻意不接 DoH；DoH 失败
  回落系统 DNS 并记一次日志。支持 RFC 8484 wire-format、配置 `doh` 服务商、
  `hosts` 静态映射与自定义端点；缓存上限 512 条、TTL 夹取 60s–24h。
- 隐身只挡**本机自动写入**（播放历史、搜索记录、季度进度）；安卓主动推送属于
  用户显式操作，仍按既有同步逻辑合并（与安卓 `userInitiated` 例外一致）。
- 崩溃恢复**不自动重启/自动起播**：标记只存站点/影片/集标识与进度（不存 URL
  与 Header），横幅的「继续上次播放」走历史续播同一条重新解析路径；崩溃日志
  上限 64 KiB，窗口正常关闭时删除标记。
- P2-1 的追番检查只在**应用运行期间**按间隔执行（含启动后补一次到期检查）；
  PC 没有 Android WorkManager 式后台常驻，关闭应用后不会检查，也没有系统级通知
  （只有侧栏徽标与追番页「N 部有新集」）。
- 更新检测口径是**站点详情里追踪线路的集数**，不是 TMDB 元数据：PC 没有接
  TMDB 季表，`trackedSeason` 固定 0（模型保留字段，不伪造季信息）。
- 安卓的 AList 订阅导入 / 片源探测（`FollowingSourceProbe`、`AlistSubscriptionImporter`）
  未迁移：PC 目前只支持从详情页手动追番。
