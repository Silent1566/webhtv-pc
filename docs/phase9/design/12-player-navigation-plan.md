# 导航栏缩略图与关键帧跳转 Implementation Plan

> **For agentic workers:** Use subagent-driven-development. Lead owns final acceptance; implementation boundaries below are disjoint.

**Goal:** 落地 P2-12：Ctrl+Shift+←/→ 关键帧跳转及默认关闭的可选进度条缩略图。
**Architecture:** Fan-out，三块共享接口固定后并行。预览复用已打包的 media-kit/libmpv，独立、静音、低分辨率、按需创建的播放器，不 seek 主播放器，不引入 ffmpeg 运行时依赖。进度控件保留原 Slider 和缓冲段几何，通过不可交互浮层呈现预览。
**Tech Stack:** Flutter / Dart / media_kit 1.2.6 / media_kit_video 2.0.1 / libmpv。
**Spec:** docs/reference/potplayer-checklist.md:75；docs/reference/potplayer-borrowings.md:96,758；DESIGN.md:391-411。

## Global Constraints / Decision log

- Settled: 预览默认关闭；关键帧与普通十秒跳转独立；直播/未知时长禁用导航功能；失败不阻塞 seek、不抛未处理异常。
- Settled: 文档产品方向已确定，L2-Clear；不额外设计新皮肤/新页面；保留播放器恒暗色及控制栏尺寸。
- Existing-standard: 沿用 PlayerOptions、state.setPlayerOptions 和 settings.json 顶层 player 落盘；不得增加新的顶栏溢出菜单入口。
- Assumed: 关键帧预览取目标附近的关键帧，不保证任意毫秒精确截图；不预抓整部视频。
- Ruled out: 主播放器 seek 截图、外部 ffmpeg 安装要求、预览默认开、无限缓存/并发。
- Verify: mpv v0.41.0 player/command.c:5622-5644 将 relative+keyframes 转为 MPSEEK_KEYFRAME；playloop.c:321-323 为正相对偏移设置 SEEK_FORWARD。实际打包版本与双向行为必须运行验证。
- Baseline: 55 tests passed: phase8_overlay_layout_test, phase9_player_core_test, player_double_click_options_test。HEAD aac86ce，wt/dev3 linked worktree。
- Implementation-phase constraint: no commits, merges, pushes, or new dependencies. Do not modify another task's files. No child delegation. Load applicable skills; do not request approval or create a new worktree. Subsequent publishing is separately authorized by the user: commit, push, and a Chinese Draft PR targeting beta; do not merge.
- Tools: SDK /home/maple/.dsh/worktrees/webhtv-pc-d700b86c/dev3/.tools/flutter/bin/flutter，PUB_CACHE 为同根 .tools/pub-cache。Flutter cwd 必须为 apps/desktop-flutter；使用 --no-pub；输出写本任务 artifacts，再返回 tail/结论。
- Runtime tool access: OpenViking Rule/Experience search+read tools are not mounted, checks unavailable; current repository and spec govern.

## Frozen interfaces (all tasks consume verbatim)

- PlayerOptions: bool showThumbnailPreview (constructor default false; JSON key showThumbnailPreview; normalized/copy/equality preserve it).
- PlayerController: Future<bool> seekToKeyframe({required bool forward}); void setThumbnailPreviewEnabled(bool enabled); Future<Uint8List?> thumbnailAt(Duration target); int get thumbnailGeneration.
- Controller default preview disabled. applyPlayerOptions calls setThumbnailPreviewEnabled(options.showThumbnailPreview). open resets per-media cache/generation and preserves immutable headers for preview; disabling/disposal invalidates results and releases preview resources asynchronously.
- PlayerProgressSlider additive optional arguments: bool thumbnailPreviewEnabled = false; Future<Uint8List?> Function(Duration)? thumbnailProvider; Object? previewSourceKey. Existing required args unchanged. Source key changes clear old image and in-flight result; provider is called only when enabled with positive duration.
- Page passes _options.showThumbnailPreview, _controller.thumbnailAt, _controller.thumbnailGeneration. Page must additionally guard live mode even when a live stream reports duration.
- buildPlayerShortcuts additive optional VoidCallback? previousKeyframe, nextKeyframe; register Ctrl+Shift+Left/Right only when callbacks present. Existing required callbacks and unmodified arrow-key bindings remain.

### Task 1: Engine and isolated thumbnail extraction

**Goal:** 实现 Controller 冻结接口与独立缩略图引擎。
**Source pointers:** apps/desktop-flutter/lib/ui/player_controller.dart:128-161,403-465,879-924,1138-1163,1209-1224；test/phase9_player_controller_lifecycle_test.dart:1-55；.tools/pub-cache/hosted/pub.dev/media_kit-1.2.6/lib/src/player/native/player/real.dart:1165-1202,1359,2742；media_kit_video VideoControllerConfiguration 支持 width/height。
**Boundary:** 可编辑 apps/desktop-flutter/lib/ui/player_controller.dart；可新建 services/player_thumbnail_service.dart（路径相对 apps/desktop-flutter/lib）、test/player_navigation_engine_test.dart、test/player_thumbnail_service_test.dart、integration_test/player_navigation_engine_flow_test.dart、test/support/player_navigation_fixture.dart。Artifacts 只写本 SDD workspace/task-1/ 与 task-1-report.md。core/player_options.dart 由 Task 3 写，禁止编辑。
**Constraints:** keyframe 相对偏移使用正负极小值并通过实际 GOP fixture 证明双向邻近关键帧，而非十秒 seek/逐帧/精确 seek；错误/不支持返回 false，保持播放/暂停状态与 onSeek 同步语义。预览只能用独立 Player + VideoController；默认零创建/零网络；静音、禁音轨/字幕、低分辨率。最多一个抽取任务，按需缓存至多32张；单次提取有至多5秒完成预算；新媒体（包括同 URL 新 headers）、开关关闭、销毁使旧结果失效。不得在主 Player 的锁上截图/seek，不让超时旧作业并发积累。自动释放所有播放器/订阅/定时器；真实 Header 随 Media 转交，日志不得输出 token。未经测试不得声称 libmpv 特性可用。
**Limits:** brief runs at most 3, cumulative, no reset. Source files edited at most 6, cumulative across runs. Commands/test runs unlimited; no per-cycle quota. Artifact writes unlimited only inside declared task evidence paths.
**Acceptance:** 真实视频确定 GOP 的 previous/next keyframe 有位置证据；报告 mpv-version。单测覆盖默认禁用、缓存复用、Header、失效、错误/超时与资源回收；主播放器 seek 不依赖 preview 完成。格式化与所辖 analyze 无新增警告。若实际 libmpv 不支持既定机制，hand_back 具体事实，不用外部依赖绕过。
**Required Evidence:** task-1-report.md：status/summary/files/RED和GREEN命令与结果、实际版本与位置序列、缩略图字节/尺寸、主播放器位置与暂停状态前后、生命周期证据。

- [ ] 写行为测试并观察 RED。
- [ ] 最小实现冻结接口及提取器。
- [ ] 运行测试、确定 GOP 的真实引擎验证并记录证据。

### Task 2: Progress slider preview UI

**Goal:** 在现有进度条增加可选 hover/drag 缩略图浮层，默认观感与高度不变。
**Source pointers:** apps/desktop-flutter/lib/ui/player_overlay.dart:204-291；test/phase8_buffer_and_traffic_test.dart:17,224；test/phase8_overlay_layout_test.dart；ui/tokens.dart、ui/theme.dart；DESIGN.md:206-243,391-411；docs/phase8/design/01-overlay-layout.md:11-68。
**Boundary:** 可编辑 apps/desktop-flutter/lib/ui/player_overlay.dart；可新建 test/player_navigation_preview_test.dart、test/player_navigation_preview_capture_test.dart；确有必要可新建 lib/ui/player_thumbnail_preview.dart。Artifacts 只写本 SDD workspace/task-2/ 与 task-2-report.md。禁止编辑 player_page/controller/options 或其他测试。
**Constraints:** 使用冻结 optional 参数，旧构造兼容；保留 Slider onSeek 连续回调和 secondaryTrackValue；主 seek 回调同步发出，不 await 图片。hover/drag 目标匹配 Slider 实际 trackRect（含 Material 内边距），夹住值域/视口两侧；退出/拖动结束/禁用/来源变更/dispose 时去掉浮层并忽略晚到结果。至少200ms防抖，最新请求优先，不在控件内预抓；加载/失败呈现明确简短反馈，保持图片框尺寸不抖动；浮层 IgnorePointer，不能盖住拖动可操作区域或被控制栏 clip。按 theme/tokens 使用当前暗色世界、等宽时间，避免增高32px进度行。键盘操作与默认缓冲段保留。
**Limits:** brief runs at most 3, cumulative, no reset. Source files edited at most 4, cumulative across runs. Commands/test runs unlimited; no per-cycle quota. Artifact writes unlimited only inside declared task evidence paths.
**Acceptance:** widget行为测试覆盖默认不请求、hover目标、拖动seek不阻塞、失效/错误、两端/窄屏夹取、直播禁用及dispose。运行 phase8_buffer_and_traffic 与 phase8_overlay_layout 回归。改包装前拍 Before，改后同场景同主题同视口 After（1280x720、640x360），预览开启场景另拍；若可靠 Before 不可取，给 After+具体说明。加载 craft-floor 紧靠 UI 编辑；本会话 impeccable context SIGILL，不重跑，直接用 PRODUCT/DESIGN。
**Required Evidence:** task-2-report.md：status/summary/files/RED和GREEN、回归命令结果、布局数值与 Before/After 路径、预览开启/错误截图、无pending timer/异常。

- [ ] 记录基线视觉并写预览行为测试，观察 RED。
- [ ] 增加最小 preview 浮层与请求生命周期。
- [ ] widget回归、同场景截图，并记录证据。

### Task 3: Preferences, menus, shortcuts and page wiring

**Goal:** 可记住的预览开关、关键帧菜单/快捷键及真实页面接线。
**Source pointers:** apps/desktop-flutter/lib/core/player_options.dart:132-310 及 copyWith/toJson/fromJson/equality；ui/app.dart:2062-2107；ui/player_page.dart:498,1433-1434,3893-3987,4785,5442,6342-6351；services/ui_preferences_store.dart:344-348,620,1068-1071,1247；state/app_state.dart:1700-1701,2449-2452；ui/settings_detail_pages.dart 播放参数设置；test/support/player_page_harness.dart:1-155。
**Boundary:** 可编辑 apps/desktop-flutter/lib/core/player_options.dart、lib/ui/app.dart、lib/ui/player_page.dart、lib/ui/settings_detail_pages.dart；为避免复制选项丢字段可编辑 lib/ui/intro_skip_options_page.dart、lib/ui/diagnostics_pages.dart；可新建 test/player_navigation_preferences_test.dart、test/player_navigation_page_test.dart。Artifacts 只写本 SDD workspace/task-3/ 与 task-3-report.md。禁止编辑 controller/overlay、app_state/store（现有落盘链足够）。
**Constraints:** 严格冻结接口；PlayerOptions兼容旧/脏配置默认false，所有构造/normalized/copy/equality/落盘保留；改其他设置不能重置它。设置页「导航栏缩略图」开关说明默认关/可能增加网络请求；右键用现有分组（可加导航子菜单），前/后关键帧标签及 Ctrl+Shift+←/→；帮助保持同步。不要新增顶栏溢出菜单项。关键帧不支持/失败有短反馈；直播/未知时长禁用按钮、shortcut和provider，即使直播duration非0也不触发。预览开关关闭及sourceKey变化清除旧图片；页面现有普通十秒seek、长按/双击、轨道/OSD逻辑不变。Settings用AppState现有存储，不复制新全局状态。所有显式PlayerOptions重建点排查并修到边界内。
**Limits:** brief runs at most 3, cumulative, no reset. Source files edited at most 8, cumulative across runs. Commands/test runs unlimited; no per-cycle quota. Artifact writes unlimited only inside declared task evidence paths.
**Acceptance:** 新/旧/脏配置、保存重载及更改其他选项测试；真实页面widget验证开关、菜单、Ctrl+Shift双向绑定且原箭头仍10s，直播disable，provider接线。无需断言源码字符串。跑相关double_click、long_press、live_controls、player样式/持久化回归；无新增analyze告警。外部全局接口如必须改未列文件，hand_back 指出文件与理由。
**Required Evidence:** task-3-report.md：status/summary/files/RED和GREEN/持久化实际JSON/页面交互与回归结果；新增设置截图（可After-only，本任务是additive）。指出所有options重建点保留字段的证据。

- [ ] 写配置和快捷键/页面行为测试，观察 RED。
- [ ] 完成配置模型、设置/右键菜单及页面接线。
- [ ] 保存重载、播放交互回归与截图，记录证据。

## Lead acceptance

Lead读取全部最终diff，逐项核对spec、命名、生命周期与失效；统一跑新增与播放器风险回归、flutter analyze及native证据核验。所有已发现缺陷必须修正并复验后交付。更新P2-12行与一份evidence文档，交付不提交git。
