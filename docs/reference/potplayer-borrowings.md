# PotPlayer 对照与借鉴清单

- 作用：把对 **PotPlayer 最新版（261021 / 1.7.23164）** 的功能调研，落成**可执行**的借鉴清单——
  每一项都给出「PotPlayer 怎么做 → 本仓库落在哪个文件 → 优先级 → 前置条件/风险 → 验收口径」。
- 性质：以分析为主，**除 P0-2（§3.2）、P0-3（§3.3）、P1-4（§4.1）与 P1-8（§5.4）已实现外，其余未标实施状态的 P0/P1/P2 为 backlog**，是否实施由产品决策。
  P1-4 的落地推翻了本节原来的建议（用 mpv `sub-*` 属性落盘），账记在 §12。
- **要清单不要论证？** 直接看 [potplayer-checklist.md](potplayer-checklist.md)（39 条全量清单，
  按 P0/P1/P2/已具备/不做/待确认分组，带编号可逐条勾选）。本文与它是同一份结论的两种视图：
  **清单是唯一条目枚举，本文负责每条为什么成立、以及哪些结论被推翻过**。
- 调研方式：三段证据链——
  **(a) 官方更新日志**（英文版 Version History，本地副本 2,728 行）+ 镜像站版本索引页；
  **(b) 官方安装包静态解析**（`PotPlayerSetup64.exe` 51,257,600 B，
  MD5 `0a6ae3716380c2ba4e3816cd33dd7fd3`，NSIS-3 Unicode / LZMA:23，解包 205 文件 / 191 MB，
  见 §11）；
  **(c) 安装包内语言文件**（`Language/English.ini`，5,685 行 / 173 段）与菜单表（886 条）逐条核对。
  **仍未运行 PotPlayer 本体**（本机是 Linux），因此**没有任何运行时行为实测**。
- **已确认的局限（必须先读）**：PotPlayer **闭源**，无源码。本文的「做法」全部来自
  **发布说明原文 + 安装包里的字符串/资源**；能证明「有这个东西、UI 上这么叫」，
  **不能**证明「它在什么条件下生效、默认值是多少」。凡属后者，本文标注「未验证」。
  与 `win-box-borrowings.md`（可读源码）的可信度**不在一个量级**，请按此打折使用。
- 基准：本仓库 `fix/toast-hold-time` @ `e65212b`；行号以本文写作时的工作区为准，
  若源码演进请以**符号名**检索。

---

## 1. 基线：PotPlayer 是什么，能借鉴什么、不能借鉴什么

| 项 | 事实 |
| --- | --- |
| 定位 | Windows 平台的**本地影音播放器**（Daum/Kakao 出品），强项是解码器覆盖、渲染器控制、字幕与滤镜管线 |
| 最新版（**安装包实测**） | 官方 CDN 的 `Latest` 现指向 **1.7.23172**（`PotPlayer64.dll` 的 FileVersion），DLL 时间戳 2026-11-02 14:02；安装包自身的字符串仍写 `ProductVersion 1.7.23159.0` / `FileVersion 26.10.21.0`，包内 `History/English.txt` 最新条目停在 `[261021]`。**四个数字互不一致，见 §11.2** |
| 版本号体系 | 191211 起改为**日期版本**：`261021` = 26 年 10 月 21 日构建。注意 `26xxxx` 与 `1.7.23xxx` 是**两套编号**，不保证同步 |
| 分发 | 闭源免费；`PotPlayerSetup.exe` / `PotPlayerSetup64.exe` / `PotPlayerSetupARM64.exe`（260819 起有 ARM64）+ 便携版 |
| 技术栈（公开信息） | Windows 原生，自有 D3D9/D3D11 视频渲染器与 WASAPI 音频渲染器；261021 把**默认渲染器**改成 D3D11 视频 + WASAPI 音频 |
| 与本项目的关系 | 两者**不是同类产品**：PotPlayer 解决「我手上有一个文件/一条流，怎么把它放到最好」；本项目解决「我手上有一份站点配置，怎么找到内容并稳定播起来」。因此**解码器/渲染器层面的东西基本不可借鉴**，可借鉴的是**桌面播放器的交互契约与配置纪律** |

**因此**：本清单的价值集中在三类——

1. **桌面鼠标键盘的交互契约**（双击分区、拖动暂停）。
2. **播放器配置的"可调但要收敛"纪律**（样式落盘、选项白名单、字符集）。
3. **别人已经踩过的坑**（双击判定窗、搜索/过滤语义、字幕样式反复回归）。

### 1.1 一句话结论

按「对本项目是否真的有用」排序，最值得看的三件事：

1. **双击左右半屏分别配置动作**（260819）——本项目 `player_page.dart` 里已经把
   PotPlayer/VLC 写成点击语义的**参照实现**（`:87` 原文「桌面播放器（PotPlayer / VLC）里单击是
   高频的传输控制」），但只做了「单击=播放/暂停、双击=全屏」两档，**没有分区**。见 §3.1。
2. **拖动进度条时暂停**（260622）——本项目 `PlayerProgressSlider` 在拖动期间**连续 seek**，
   网络流每次 seek 都可能触发重新缓冲。见 §3.2。
3. **播放列表/队列的过滤式搜索**（261021 + 260819）——本项目的 `PlayerQueuePanel` 与
   `PlayerEpisodePanel` **没有任何搜索框**，而 TVBox 站点动辄上百集。见 §3.3。

---

## 2. 对照总表

优先级定义：**P0** = 真实缺口、改动小、收益直接；**P1** = 结构性收益但需独立设计；
**P2** = 工程纪律与体验细节；**已具备** = 本仓库已有等价实现，不重复造；**不做** = 见 §7。

| # | 主题 | PotPlayer 做法（发布说明原文/转述） | 本仓库落点 | 结论 |
| --- | --- | --- | --- | --- |
| 1 | 双击左/右半屏分别配置动作 | 260819「Added the ability to individually configure actions for the left and right areas upon double-clicking」 | `ui/player_page.dart:82-123`、`:4902-4925` | **P0 借鉴** |
| 2 | 拖动进度条时暂停 | 260622「Added pause function when navigating via the navigation bar」 | **已实现**：`ui/player_overlay.dart:212-238,489-509`、`ui/player_page.dart:161-185,4903-4919`、`core/player_options.dart:137,207`（默认开、可关） | **P0 借鉴 → 已实现**（§3.2） |
| 3 | 播放列表过滤式搜索 | 261021「customize the playlist search method」；260819「playlist search function to operate as a filter」 | `ui/player_queue_panel.dart`、`ui/player_episode_panel.dart`；回归 `test/player_episode_search_test.dart` | **P0 借鉴 → 已实现**（§3.3） |
| 4 | 字幕/OSD 样式落盘 | 240618 OSD 字体可设；250514 字幕字体处理；260401 用 libass 输出字幕 | `core/subtitle_style.dart`、`core/osd_style.dart`；落盘 `services/ui_preferences_store.dart:1216-1224`（`ui.subtitleStyle` / `ui.osdStyle`） | **P1 已实现**（§4.1：样式落在 Flutter 侧 `SubtitleViewConfiguration`，零新增 mpv 属性） |
| 5 | HDR 色调映射可调 | 250625「select HDR tone mapping type」；241211 HDR2084 显示器亮度 | `core/player_options.dart:164-170`（固定 5 个 mpv 属性） | **P1 借鉴** |
| 6 | 字幕字符集处理 | 260114「Improved subtitle character set handling」 | `core/text_codec.dart`（utf-8/utf-16/gbk/latin1，无 Big5/Shift-JIS） | **P1 借鉴** |
| 7 | 片段重复（A-B） | 210929 快速区间重复；200512 重复次数；200616 重复延迟 | `core/playback_repeat.dart:8-16`（仅 off/one/all） | **P1 借鉴** |
| 8 | 系统媒体控制 | 240618「Added system media transport control function」 | grep `smtc/MediaSession` **0 命中** | **P2 借鉴** |
| 9 | 视频截图（含 WebP） | 240827「Added WEBP to video capture」 | grep `screenshot` 只剩测试参数 `--screenshot-ready-file` | **P2 借鉴** |
| 10 | 本地 HLS/DASH 文件播放 | 261021「playing HLS/DASH streams from local files」 | `state/folder_playback_queue.dart` 扩展名白名单未排除 `m3u8/mpd` | **P2 待实测** |
| 11 | ReplayGain → 实为「响度归一」 | 261021「Added ReplayGain support」；安装包另有独立的 `Normalizer (Auto Volume Control)`（§11.4） | grep `replaygain` / `normaliz(e|er)` 播放器侧 **0 命中** | **P2 借问题不借实现**（见 §5.4）：ReplayGain 靠文件标签，站源没有；要做的是 Normalizer |
| 12 | 鼠标按键调速 | 241015「adjust playback speed when pressing the mouse button」 | `core/player_options.dart:112 longPressSpeed`、`:81 choices [2,2.5,3,4]` | 已具备 |
| 13 | 实时语音转字幕 | 250909 / 241211（Whisper）；250625 加 VAD | `services/audio_ai/realtime_subtitle_controller.dart`、`core/audio_ai/cue_window.dart` | 已具备 |
| 14 | 字幕文件格式白名单（含 ass/ssa） | 250226 / 260401 | `core/subtitle.dart:98-105` 接不接受这个文件；**绘制不走 libass**，见 §4.1「字幕渲染路径复核」 | 格式已具备；**ASS 排版不做**，见 §12.2 与 checklist Q-39 |
| 15 | 字幕在线翻译 | 230705 / 230831 | `services/audio_ai/srt_translation_service.dart`、`core/audio_ai/srt_cues.dart:86` | 已具备 |
| 16 | 播放队列/连播/循环 | — | `core/playback_queue.dart`、`core/playback_repeat.dart` | 已具备 |
| 17 | 记忆播放位置/续播 | — | `ui/playback_resume.dart:24`、`core/playback_request.dart:61-142` | 已具备 |
| 18 | 硬件解码开关 | — | `core/player_options.dart:83,165`（`hwdec`） | 已具备 |
| 19 | 倍速 | — | `ui/player_controller.dart:1161`（clamp 0.25–4.0）、`ui/player_page.dart:4595,5019` | 已具备 |
| 20 | 屏显（OSD） | — | `core/osd_config.dart`、`ui/player_osd.dart` | 已具备 |
| 21 | 右键菜单 | — | `ui/player_context_menu.dart`（701 行） | 已具备 |
| 22 | 控制栏按钮自定义 | — | `core/player_buttons.dart`（10 个按钮 id + 排序/隐藏） | 已具备 |
| 23 | 180°/VR/3D | 261021 180°；191211 360 VR CUBE/EAC | — | **不做**（§7） |
| 24 | 皮肤系统（.skn + 图层脚本） | 191211 起多套皮肤 | `ui/theme.dart` + `ui/tokens.dart` 固定设计系统 | **不做**（§7） |
| 25 | 蓝光/DVB/游戏捕获/推流/聊天 | 分散在多版本 | — | **不做**（§7） |
| 26 | ARM64 构建 | 260819「ARM64 Build Released」 | 发布目标仅 Windows x64 / Linux x86_64 | **不做**（§7） |

**安装包解析后新增的候选（未进上表，见 §11.4/§11.5）**：

| 主题 | 证据 | 为什么值得看 | 初步判断 |
| --- | --- | --- | --- |
| 音量归一 `Normalizer` | `3385`、`Shift+N` | 站源之间响度差异是日常痛点 | **P1 已实现**（mpv `af=dynaudnorm`，默认关；随包 Windows 内核已换成完整 FFmpeg 构建，两平台均生效，见 §5.4） |
| 导航栏缩略图 + 关键帧跳转 | `3066`、`3048`、`3204`、`Ctrl+Shift+←/→` | 本项目 seek 无预览、无关键帧粒度 | **P2 候选**（网络流缩略图成本高，先做关键帧跳转） |
| A-B 是**区间列表**而非单组 | `3285`、`101_0_9_10_15/17`、`3990` | 修正 §4.4 的建模 | §4.4 已注明 |
| 多实例语义三档 | `3501/3502/3503` | 本项目无任何单例/复用语义 | **P2 候选**（先解决"第二次启动会发生什么"） |
| 字幕帧率转换 | `3940` | 23.976↔25 混源场景 | **观察**（频次低，不做） |
| 命令行 `/user_agent` `/referer` `/headers` | `CmdLine64.txt` | 深链起播的语义参照 | **P2 候选**（本项目已有代理注入 header，缺对外入口） |

---

## 3. P0：真实缺口、改动小、收益直接

### 3.1 双击左右半屏分别配置动作

**PotPlayer 做法**

260819 加入：「Added the ability to individually configure actions for the left and right
areas upon double-clicking」。

**安装包实证（§11.4）**：这不是「把画面劈成左右两半」那么简单，而是**鼠标动作矩阵**——
语言文件里有一整组键（`3878-3891`）：Left/Right/X1/X2/Wheel 各自 × 单击/双击，
再加 `5000-5004` 的「按住」与 `5005/5006` 两条**专门给双击的「(left area)/(right area)」**：

```
5005=Left Button - Double Click:(left area):
5006=Left Button - Double Click:(right area):
```

即：**同一个「双击」按区域拆成两个可配项**，其余按键动作仍是全局的。
默认值仍然**未验证**（语言文件只有标签，没有取值）。

**本仓库现状（逐行核实）**

`apps/desktop-flutter/lib/ui/player_page.dart:82-123`：

```dart
/// 双击判定窗，与 Flutter 自带的 [kDoubleTapTimeout] 对齐（300ms）。
///
/// **为什么不直接用 `GestureDetector.onDoubleTap`**：一旦注册它，Flutter 会把
/// 单击挂起整整一个判定窗再落地……桌面播放器（PotPlayer / VLC）里单击是高频的传输控制，
/// 「点一下要等 0.3 秒才暂停」是明显迟滞。
const Duration kPlayerDoubleClickWindow = kDoubleTapTimeout;

enum PlayerGestureAction { togglePlayback, togglePlaybackAndFullscreen }

PlayerGestureAction resolvePlayerGesture({required bool doubleClick}) =>
    doubleClick
        ? PlayerGestureAction.togglePlaybackAndFullscreen
        : PlayerGestureAction.togglePlayback;
```

`:4902-4925` 的 `_onVideoTap()` 用 `PlayerDoubleClickGate` 判双击：单击立即翻转播放；
双击把播放状态**拨回第 1 击之前**的值再切全屏（所以双击不改播放状态）。

**缺口**：① 动作集合只有两个取值，没有「快进/快退/音量/无动作」；② **没有左右分区**，
`_onVideoTap` 里拿不到 `localPosition`；③ 没有配置项，`PlayerOptions` 里也没有对应字段
（`core/player_options.dart:84-115` 的字段表里没有 gesture 相关项）。

**建议**

1. 只扩「双击」这一格，不抄整套矩阵：`PlayerGestureAction` 增加
   `{seekBackward, seekForward, volumeUp, volumeDown, none}`。
2. `_onVideoTap` 增加 `Offset localPosition` + `Size`，按 `dx < width / 2` 选
   `doubleClickLeft` / `doubleClickRight`。
3. 两个字段落 `PlayerOptions`（经 `services/ui_preferences_store.dart:1017
   rememberPlayerOptions` 持久化），**默认值保持今天的语义**：左=右=`toggleFullscreen`
   （「双击不改播放状态、只切全屏」），否则会静默改变既有用户的手感。

**为什么不抄整套矩阵**：PotPlayer 那套覆盖 Left/Right/X1/X2/Wheel × 单击/双击/按住，
是给「本地文件播放器 + 多键鼠标」设计的；本项目的输入面窄得多（`_isLive` 下 seek 要退化、
触控板没有 X1/X2），照搬只会带来一堆永远没人配的组合。**抄交互结论，不抄配置维度。**

**前置条件 / 风险**

- **绝不能用 `GestureDetector.onDoubleTap` 实现**：`player_page.dart:84-92` 记录了仓库里
  `integration_test/live_interaction_flow_test.dart` 踩过的真坑（轮询重复点击被误判成双击，
  且单击要等满一个判定窗）。分区判定必须挂在**现有的** `PlayerDoubleClickGate` 之后。
- 直播/回看场景下 `seekBackward/seekForward` 应自动退化为 `none`（`_isLive` 已有判定）。
- 触控板双击、双屏 DPI 缩放下的 `localPosition` 要按渲染盒算，不能按窗口算。

**验收**

- 左/右半屏分别触发各自配置的动作；默认配置下现有 `test/phase8_*` 的浮层几何与手势断言**不翻转**。
- 第 3 击属于新一轮（`PlayerDoubleClickGate.registerTap` 的既有语义），左/右切换时不串。

---

### 3.2 拖动进度条时暂停

**PotPlayer 做法**

260622：「Added pause function when navigating via the navigation bar」——在进度条上拖动时
自动暂停，松手后按拖动前的状态续播。（**松手是否自动恢复播放，官方说明未展开**，推测是恢复。）

**本仓库落地（已实现）**

改造前的缺口是：`PlayerProgressSlider` 的 `_dragging` **只决定缓冲段画不画**，
拖动期间 `onSeek` 连续触发；网络流每拖一格就 seek 一次、反复丢缓冲，且用户在拖动时
看不出「松手后是继续播还是停住」。

| 落点 | 内容 |
| --- | --- |
| `core/player_options.dart:137,207` | `PlayerOptions.dragPause`（默认 `true`），经 `normalized`/`copyWith`/`toJson`/`fromJson`/`==` 全链路穿透；落盘键 `dragPause`，**旧 settings.json 缺键 → `true`** |
| `ui/player_overlay.dart:212-238` | `PlayerProgressSlider` 新增可选 `onSeekStart`/`onSeekEnd`，复用既有 `onChangeStart`/`onChangeEnd`（`:489-509`）；`onSeek` 连续语义、`_dragging` 缓冲段隐藏语义、进度行高度全部不变 |
| `ui/player_page.dart:161-185` | `PlayerDragPauseGate`：只回答「该不该 pause/play」，`begin` 记住拖动**前**的播放状态、重复 `begin` 不覆盖，`end` 无条件清状态，`reset` 丢弃进行中的拖动 |
| `ui/player_page.dart:4903-4919` | 两个回调**恒定挂载**、判据在调用当时求值：`dragPause && !_isLive`。关掉开关/切直播/换媒都不会让一次拖动丢掉 `end()` |
| `ui/player_page.dart:3066` | `_beginMediaTransition()` 复位 gate（与 `_clickGate`/`_playingBeforeFirstTap` 同处），避免换媒后按旧状态续播 |
| `ui/player_page.dart:5499` | `pause()/play()` 走 `_applyDragPausePlayback`，异常写 `log.warning`，不产生未处理的 async error |
| `ui/settings_detail_pages.dart:87`、`ui/player_page.dart:5671` | 两个入口：设置 → 播放「拖动进度条时暂停」、右键「播放 → 拖动进度条时暂停」，都经 `setPlayerOptions` 落盘 |

**为什么改成「松手才 seek」（2026-11 修订）**：初版按最小版本保留了拖动期间的连续 seek。
真机实测推翻了那个取舍：用户拖动一次进度条后**画面静止十几秒且没有任何加载提示**。
用真实 libmpv 复现后拿到判据——`set pause yes` → 20 次 `seek` → `set pause no`：
`pause=no` **立刻**生效，但 `seeking=yes` 持续整个观察窗（`time-pos` 钉在目标值），
同时 `core-idle=yes`、`paused-for-cache=no`、`cache-buffering-state=100`、
`demuxer-cache-time=None`——media-kit 的 buffering 流全程沉默，所以「加载中」根本不可能出现。
根因是这条 HLS 代理单次 seek 要 1–3 秒，逐格 seek 会串行排队几十个；用户把开关关掉后
同样静止，证明与暂停无关、只与 seek 频率有关。

因此现在：**拖动期间不发引擎 seek**（只更新拇指与时间），**松手只发一次 seek**，再按
拖前状态恢复播放；同时把引擎的 `seeking` 也并入「卡住了」的判据
（`showBufferingIndicator` 收 `isSeeking`），慢 seek 期间用户能看到既有的缓冲提示而不是干等。
这条与开关无关——即使关掉「拖动进度条时暂停」，拖动仍然只在松手时 seek 一次。

**残留限制（写清楚，别当成 bug）**

- **直播不暂停**（`_isLive`）。理由：直播没有可自由拖动的时间轴。判据在**页面**侧，
  滑杆侧仍是既有的 `duration <= 0`——有些流会报非零时长，两层互为兜底。
- **回看（`_isCatchup`）与点播同待遇**：时长可拖、seek 语义与点播一致，所以也暂停。
  这是产品确认过的范围，不为回看单独开口子。
- **单击轨道也算一次导航**：Flutter 的 `Slider` 单击会走 `start → seek → end`，因此点一下
  进度条会「暂停 → 松手 seek 一次 → 恢复」。这是既定语义（点击本来就要 seek），已用测试钉住。
- **拖动时画面不跟手**：拖动期间画面停在暂停帧、拇指与时间跟随指针，松手才跳。
  这是上面那条修订的直接后果，换的是「不再排队几十个 seek」。
- **慢 seek 有提示**：`seeking=yes` 期间显示既有缓冲提示（判据 `(isBuffering || isSeeking) && !isLoading`）。
- **拖动中途把开关关掉**：这一次拖动不强行续播（先清状态再判），下一次拖动照常生效。

**验收（`test/player_drag_pause_test.dart`，19 例）**

- 拖动中暂停、松手续播；拖动前本就暂停 → 松手仍暂停；直播零行为变化（含「引擎报了非零时长」）。
- 程序化 seek（快捷键/自动跳片头片尾/续播）不进这两个回调，不暂停。
- 关掉开关、拖动中途关掉开关、换媒、单击轨道四条边界各有用例。
- 缓冲段隐藏语义不变；浮层几何（进度行 32）不因本次改动变化。
- 拖动期间**不发 seek**、松手恰好一次 seek（新增用例断言 `io.calls` 里拖动阶段没有 seek）。

---

### 3.3 播放列表/队列的过滤式搜索

**PotPlayer 做法**

261021：「Added the ability to customize the playlist search method」；紧接着 260819 的
修订是「Modified the playlist search function to operate as a filter」——**先做搜索、再改成过滤**。
这条修订本身就是最有价值的信息：用户要的是**列表收缩**，不是「跳转并高亮」。

**已落地**

- 两种面板均有「搜索选集」输入框和清空按钮，忽略首尾空格、不区分大小写，不自动播放。
- 选集在当前预览线路的全部区间匹配原集名与可信卡片标题/集号；有查询时隐藏区间行，清空后恢复原区间。保留倒序、卡片映射与原始绝对下标；预览线路切换保留查询、不起播。
- 目录队列只按标题过滤已加载项。还有更多时显示「仅搜索已加载」及数量；不自动请求下一页、不解析播放地址，用户可手动加载，新增项继续按原查询过滤。
- 无匹配有空态；加载错误与重试不被过滤隐藏。文件 key、当前项高亮和底层队列顺序不变。

**验收入口**

- `test/player_episode_search_test.dart`：跨区间、清空、倒序、卡片标题/集号、错误元数据回退、线路预览、原始回调、队列加载/失败重试。
- 与 `player_episode_panel_test.dart`、`player_queue_test.dart`、`player_queue_history_test.dart` 组合复验；全包 `dart analyze --fatal-infos`。
- 同场景暗色截图：`EPISODE_SEARCH_CAPTURE=before/after`，输出到忽略目录 `.local/episode-search/`，覆盖 1280×800 与 640×480；不是发布包或真实站源验收。

---

## 4. P1：结构性收益，需要独立设计

### 4.1 字幕与 OSD 样式落盘（P1-4，已实现）

**PotPlayer 做法**

240618「Added the ability to set the font for OSD playback information」；
250514「Added ability to change subtitle font handling」；
260401「Added the ability to output subtitles using libass」。
三件事连起来看：**样式要可调、要能选渲染器、要能持久**。

**本仓库实现前的现状（逐行核实）**

- `ui/player_page.dart` 的 `_applySubtitleStyle` 当时注释原文就是「**不落盘**：与
  `_showSubtitleStyleSettings` 的「应用」同语义——`PlayerSubtitleStyle` 目前是页面级字段，没有持久化
  能力，这里也不假装有」。该注释已随实现删除，现值见下「本轮落地」。
- `core/subtitle_settings.dart` 只有**字幕源**：`autoMatch` / `preferredLanguages` / `httpEndpoint` /
  `httpToken` / `localDirectories`，没有任何字号/描边/位置字段。

**缺口**：每次进播放器都要重调字号与位置；OSD 字体不可配。对「一次看几十集」的场景，
这是每天都疼的点。

**本轮落地（A 级，代码实测）**

| 层 | 落点 |
| --- | --- |
| 模型 | `core/subtitle_style.dart`（`SubtitleStyle`：文字色 / 底色不透明度 / 描边 / 字号 / 底部间距，带 `normalized` / `toJson` / `fromJson` / `isDefault` / `copyWith`）、`core/osd_style.dart`（`OsdStyle`：字号 / 不透明度） |
| 落盘 | `services/ui_preferences_store.dart:1216-1224` 写 `ui.subtitleStyle` / `ui.osdStyle`；`:1181` 每轮重建整个 `ui` 段，所以「恢复默认后键消失」是结构保证，不靠删键逻辑；`state/app_state.dart:1683,1687` 读、`:2437,2446` 写 |
| 消费 | `ui/player_page.dart:159-191`（`extension SubtitleStyleView` → `SubtitleViewConfiguration`，`:3663-3664` 注入视频层；**只作用于 mpv 轨字幕**，ASR 字幕另行绘制，见下「前置条件 / 风险」）、`:5138-5239`「字幕 → 字幕样式」（字号 / 描边 / 位置 / 底色各 4 档、文字颜色 6 档、恢复默认）、`:5374-5417`「显示 → 屏显样式」（字号 / 不透明度各 4 档、恢复默认）；`ui/player_osd.dart:32-33`（正文 `14 * textScale`）、`:306`（诊断面板 `10 * textScale`）、`:162`（整层 `Opacity`，`:3826-3828` 由播放器页传入） |
| 默认外观 | 逐项等于 Phase 3–8 的写死值：字幕 32dp 基准字号 + 白字 + 全透明底 + 2px 黑描边 + 底部 24dp；OSD 100% 字号、100% 不透明 |

**字幕渲染路径复核（A 级，代码实测）**

结论先行：**本仓库从不使用 mpv 的 libass 渲染**，字幕由 Flutter 侧画。所以「把样式写成 mpv `sub-*`
属性」这条路从一开始就不通，P1-4 只能落在 `SubtitleViewConfiguration` 上。

| 环节 | 代码事实 |
| --- | --- |
| 默认值 | `PlayerConfiguration.libass` 默认 `false`：`media_kit-1.2.6/lib/src/player/platform_player.dart:526` |
| 关闭时注入 mpv | `sub-ass` / `sub-visibility` / `secondary-sub-visibility` 全写 `no`：同包 `lib/src/player/native/player/real.dart:2434-2436` |
| 谁画字幕 | `SubtitleView` 只在 `!libass` 时挂载：`media_kit_video-2.0.1/lib/src/video/video_texture.dart:450-455`（`:451` 即 `!(…configuration.libass ?? false)`）；它渲染 `player.stream.subtitle`，也就是 mpv 的 `sub-text`（`real.dart:1911` 监听、`:2477` 注册格式）——**纯文本** |
| 本仓库 | 生产代码两处 `Player()` 都没传 `libass`：`ui/player_controller.dart:132`、`services/reader/media_kit_reader_audio.dart:26` |

（上表媒体库路径相对 `~/.pub-cache/hosted/pub.dev/`，包版本即目录名：`media_kit 1.2.6`、`media_kit_video 2.0.1`。）

**`sub-*` 属性为什么不生效**（三条，逐条对应上表）

1. `sub-ass=no` + `sub-visibility=no` 之后，mpv 既不按 libass 解析 ASS 的排版指令、也不自己输出字幕；
   `sub-font-size` / `sub-border-size` / `sub-pos` / `sub-color` / `sub-back-color` / `sub-bold` 调的都是
   libass 的输出参数，没有消费者。
2. 上屏的是 Flutter widget：字号、颜色、描边、内边距全部来自 `ui/player_page.dart:178-190` 构造的
   `SubtitleViewConfiguration`。mpv 属性不跨进程影响 widget。
3. `sub-ass-override` 是「用户设置要不要夺走字幕组样式」的开关，**只在 libass 打开时有意义**。原建议
   「必须把默认值论证成 `scale`」因此是空论证——没有可覆盖的对象。

**为什么默认值必须仍然等于今天的外观**

- 今天的每个数都是既有实现的写死值：`ui/player_osd.dart:32-33` 的 14dp 正文、`:306` 的 10dp 诊断面板、
  字幕 32dp 基准 + 2px 描边 + 底部 24dp。默认值一漂移就等于「用户没碰任何设置、画面却变了」——这种
  改动没有 UI 痕迹可追，回滚成本最高。
- 默认值同时是「恢复默认」的判据：`core/subtitle_style.dart:141` / `core/osd_style.dart:66` 的 `isDefault`
  决定「不写盘」（`services/ui_preferences_store.dart:1216-1224`）。默认值与既有观感不等，恢复默认就会
  把一个「新外观」还回去。

**被作废的建议（对照 §12.1）**

原建议 2「把样式翻译成 mpv 属性并入 `mpvProperties`」作废，理由见上「`sub-*` 属性为什么不生效」。
`mpvProperties` 的「空值/默认项也写」约定（`core/player_options.dart:163`）仍然有效，但**与 P1-4 无关**：
本轮零新增 mpv 属性。

**关键约束（这是「渲染器归属」问题，不是 mpv 参数问题）**

ASS/SSA 自带样式。mpv 用 `sub-ass-override`（`no`/`scale`/`force`/`strips`）决定用户设置是否夺走字幕组
的排版——**但这条只对本仓库未启用的 libass 路径成立**。今天的事实是：libass 关闭，ASS 的定位与特效在
`sub-text` 这一步就没了，字幕组排版全部丢失。这是**既有行为**，不是本轮引入的回归；要不要改，归 §12.2
与 checklist 的 Q-39。

**安装包实证（§11.4）**：PotPlayer 把这件事做成了**四态选择器**，而不是一个开关：

```
5010=Use default engine
5011=Use default engine for default style, other use libass
5012=Use libass for ASS/SSA subtitle, other use default engine
5013=Use libass for all subtitle
```

并且**字体后端也是三选一**（`5017-5019`）：`GDI - High compatibility, reasonable speed` /
`FreeType - Medium compatibility, fast speed` / `DirectWrite`。

结论：字幕渲染在 PotPlayer 那里是「引擎 × 样式归属」的二维选择；本仓库今天是**单轨**（libass 恒关、
Flutter 恒画），所以「样式归属」在打开 libass 之前根本不是可调维度——这正是 Q-39 必须先拿 Before/After
才能立项的原因。

**前置条件 / 风险**

- 视觉回归面：样式只作用于 **mpv 轨字幕**。四路同源——外挂、在线匹配、本地挑文件都先变成外挂候选
  （`core/subtitle.dart:198-208`），再走 `ui/player_controller.dart:576-598`（`isExternal` 分支：落临时文件 →
  `setSubtitleTrack(SubtitleTrack.uri(...))`）；内嵌走 `ui/player_controller.dart:610-617`。四路最后都是一条
  mpv 轨，经 `sub-text` 回到同一个 `SubtitleView`，所以改一次样式四路同时变。
  **ASR（音频 AI）字幕是例外**：它由 `ui/player_page.dart:3678-3697` 把 `RealtimeSubtitleOverlay`
  （定义在 `lib/ui/audio_ai/audio_ai_controls.dart:429`，绘制是 `:552-554` 的普通 `SelectableText` / `Text`）
  直接叠在画面上，读的是实时字幕控制器与呈现时钟，**不经过 `SubtitleViewConfiguration`**，字幕样式改动
  不影响它（`RealtimeSubtitleControls` 里那一份 `:417` 同理）。注意 `PlayerAudioAiPanel`
  （`ui/player_page.dart:3740`，类定义在 `lib/ui/ai_integration_widgets.dart:792`）
  是控制面板，不是 ASR 字幕的绘制点。验证口径因此是「四路同源看一次 + ASR 单独确认不受影响」。
- 落盘口径：默认值不写盘由 `services/ui_preferences_store.dart:1216-1224` 的结构保证（`:1181` 整段重建）；
  新增字段写空值会把它固化进 `settings.json`。
- 写盘失败不回滚：`ui/player_page.dart:5763-5773` 先 `setState`、再 unawaited 落盘，失败只记日志——这是
  既定语义，别改成「保存失败就弹窗回滚」。

**验收**

- 改字号 / 描边 / 位置 / 底色 / 文字颜色后重进播放器仍生效。
- 「恢复默认样式」后 `settings.json` 的 `ui.subtitleStyle` / `ui.osdStyle` 键消失。
- 默认值下观感与 Phase 3–8 完全一致（没人动过设置 = 画面不该有任何变化）。
- ASS 排版丢失**不在本条验收范围**：单列为 checklist 的 Q-39。
- `dart analyze` 无告警。

---

### 4.2 mpv 属性白名单化 + HDR 色调映射

**PotPlayer 做法**

250625「Added ability to select HDR tone mapping type」；241211「HDR 2084 显示器亮度」；
250514「Improved D3D11 H/W HDR handling」。

**本仓库现状（逐行核实）**

`core/player_options.dart:164-170` 是**全部**的 mpv 注入面：

```dart
Map<String, String> get mpvProperties => <String, String>{
  'hwdec': hardwareDecoding ? 'auto-safe' : 'no',
  'cache': cache ? 'yes' : 'no',
  'demuxer-max-bytes': '${demuxerMaxBytesMiB * 1024 * 1024}',
  'demuxer-max-back-bytes': '${demuxerMaxBackBytesMiB * 1024 * 1024}',
  'audio-spdif': audioPassthrough ? 'ac3,eac3,dts' : '',
};
```

README 也把口径固定成「解码与缓冲参数通过播放设置中的 mpv 选项配置」——即**只有这 5 个**。

**缺口**：HDR→SDR 的映射在 mpv 里是 `tone-mapping`（`auto/spline/mobius/reinhard/hable/
bt.2390/clip`）+ `target-peak` + `hdr-compute-peak`，本项目一个都没暴露；HDR 片源在 SDR 屏上
只能吃默认。

**建议**

- 播放设置里加「HDR 色调映射」下拉，默认 `auto`（**不写属性**，保持今天的行为）。
- 高级项里给 `target-peak`（数值），默认留空。
- **不要**做自由文本 mpv 属性直通：`PlayerOptions` 的既有设计是「结构化选项 → 固定属性名」，
  自由直通会让「设置页说不清、诊断页查不到」，也与产品原则 2（可诊断）冲突。

**前置条件 / 风险**

- 必须先确认 media-kit 打包的 **libmpv 版本**支持哪些取值（属性名在 0.36+ 才稳定）。
- 非法值会让属性设置失败：必须 try/catch 并写进 `core/playback_diagnostics.dart` 的轨迹，
  不能静默吞掉。

**验收**

- 三档可切；切回「自动」时属性被**显式写回默认**而不是残留；诊断页能看到实际生效值。

---

### 4.3 字幕字符集扩展（Big5 / Shift-JIS / EUC-KR）

**PotPlayer 做法**

260114「Improved subtitle character set handling」（更早 230705、230831 也在改字幕文本链路）。

**本仓库现状（逐行核实）**

`core/text_codec.dart:115-146` 的顺序是 **BOM → 显式声明 charset → 严格 UTF-8 → GBK 兜底**，
`:132` 的错误文案就是支持清单：

```dart
detail: '支持 utf-8、utf-16le/be、gbk/gb2312/gb18030',
```

`services/subtitle_service.dart` 走同一套解码。

**缺口**：港台源的 `.srt` 常见 **Big5**，日韩源常见 **Shift-JIS / EUC-KR**。这些会走到
「UTF-8 失败 → 按 GBK 兜底」这条路径上，结果是**乱码但能播**——比直接报错更糟，
用户会以为字幕本身就是坏的。

**建议**

- 在 `_decodeWithCharset` 的 `switch` 里补 `big5` / `big5-hkscs` / `shift_jis` / `euc-kr`。
- **只在显式声明 charset 时启用**，不参与「未声明时猜编码」的兜底链——猜错比猜对常见。

**前置条件 / 风险**

- 需要额外的字符集实现（纯 Dart 表或 `charset_converter`），要过打包体积与许可证审查。
- Windows / Linux 必须行为一致（本项目已有跨平台断言的传统）。

**验收**

- 四种新字符集各有单测；**未声明 charset 的字节流行为与今天完全一致**（兜底顺序不改变）。

---

### 4.4 片段重复（A-B 循环）

**PotPlayer 做法**

210929「Added fast segment repeat」；200512「区间重复的重复次数」；200616「重复时的延迟」。

**本仓库现状（逐行核实）**

`core/playback_repeat.dart:8-16` 只有三档，且语义是「**这一集播完之后**做什么」：

```dart
enum PlaybackRepeat {
  off('off', '不循环'),
  one('one', '单集循环'),
  all('all', '列表循环');
```

**缺口**：想反复看一小段（台词、动作、听力练习）只能手动拖，没有 A 点/B 点概念。

**建议**

- 新增 `core/ab_loop.dart`（纯数据：`start`/`end`/`enabled`，带 `normalized()` 与序列化），
  播放器下发 mpv 的 `ab-loop-a` / `ab-loop-b`。
- 右键菜单加「设置 A 点 / 设置 B 点 / 清除」三项（`ui/player_context_menu.dart` 已有分组结构）。

**前置条件 / 风险**

- 与「自动连播 / 片头片尾跳过」交互：A-B 生效期间必须暂停自动跳集判定，否则 B 点一过就跳走。
- 直播下禁用（没有稳定时间轴）。
- 跨集时要自动清除，否则下一集会带着上一集的 A/B 点。

**验收**

- A/B 点可设可清；跨集自动失效；直播菜单项禁用；与 `skip_segments` 不打架。

---

## 5. P2：工程纪律与体验细节

### 5.1 系统媒体控制（SMTC / MPRIS）

PotPlayer 240618 加入系统媒体传输控制。本仓库 grep `smtc` / `MediaSession` **0 命中**。
最小可用集：播放/暂停、上一集/下一集、元数据（片名 · 第 N 集）。Windows 侧走
`SystemMediaTransportControls`，Linux 侧走 MPRIS。**不影响主链路**，但「桌面播放器」这四个字
有一半是这类系统集成撑起来的。

### 5.2 视频截图

PotPlayer 240827「Added WEBP to video capture」。本仓库的 `screenshot` 命中只有测试用的
`--screenshot-ready-file`（`ui/app.dart:86,121`），**不是用户功能**。
建议先只做 PNG：确认 media-kit 是否暴露 mpv 的 `screenshot-raw`，拿 RGBA 后自己编码。
WebP 需要额外编码器，可后置。注意：截图目录要让用户可配，别默默塞进应用数据目录。

### 5.3 本地 HLS/DASH 文件（待实测）

PotPlayer 261021「Added support for playing HLS/DASH streams from local files」。
本仓库 `state/folder_playback_queue.dart` 的 `_nonVideoExtensions` 没有排除 `m3u8`/`mpd`，
所以本地 `.m3u8` 会被当视频候选；**但能不能播没验证过**（manifest 里的相对路径解析、
mpv 对 `file://` 的态度都未知）。
处理方式：**先实测**。能播就补一个明确图标与说明；不能播就走 `services/proxy_server.dart`
既有的 HLS 改写能力把相对路径绝对化。

### 5.4 ReplayGain：借问题，不借实现

PotPlayer 261021 加了 ReplayGain。**安装包实证（§11.4）把这条彻底钉死了**：

- `PotPlayer64.dll` 与 `ffcodec64.dll` 里都是这组键：
  `REPLAYGAIN_TRACK_GAIN` / `REPLAYGAIN_TRACK_PEAK` / `REPLAYGAIN_ALBUM_GAIN` /
  `REPLAYGAIN_ALBUM_PEAK`，外加一个 `AVReplayGain` 类。
- 语言文件里的取值只有三项（`5055-5057`）：
  `Do not use` / `Track gain (same loudness for every track)` /
  `Album gain (keeps loudness differences within an album)`。

也就是说：**它就是读文件标签**。站源直链没有标签 → **这条对本项目完全搬不过来**。

**但同一份语言文件里还有另一件东西值得抄**（这是本次新增的候选）：

```
3385=Normalizer (Auto Volume Control)
```

——独立于 ReplayGain 的**实时响度归一**，有自己的快捷键（`Shift+N`）和开关项。
本项目真正需要的正是这个：同一部剧换线路/换源响度差异大，用户会反复调音量。
mpv 侧对应 `af=dynaudnorm`（有副作用，必须默认关且可关），或记住「该站源的音量偏好」。
**不做 ReplayGain 字面实现，做 Normalizer 那条。**

**落地（已实现）**：`core/player_options.dart:207` 的 `audioNormalization`（默认 `false`）经 `:330` 映射成 `af=dynaudnorm` / 空串，白名单 `core/mpv_properties.dart:241` 只放行这两个值并做写后回读；落盘键 `player.audioNormalization`；三个入口共用同一份偏好——设置页 `ui/settings_detail_pages.dart:162`、右键「声音 → 音量」勾选项 `ui/player_page.dart:5777`、页面局部 Shift+N `:3914`（菜单与快捷键都走 `:6386`，整表参数与 `af` 单项写入共用串行队列，失败走既有 toast/日志且仍可关闭）。**实测边界**：`audio-spdif` 命中时 `af=dynaudnorm` 虽回读成功，`audio-out-params/format` 仍是 `spdif-ac3`——滤镜只作用于已解码音频；`audioPassthrough` 偏好因此保持不变，UI 文案明确写「音频直通时不生效」。音量/静音不受归一开关影响（实测 `volume`/`mute` 前后一致），未引入任何标签读取逻辑。**平台边界（2026-11 实测 → 已修）**：原先随包的 Windows libmpv（media_kit 归档 v0.36.0-403 / FFmpeg n6.0）没有编进任何 ffmpeg 滤镜表，裸名 `af=dynaudnorm` 被内核直接拒（`rc=-9`），写后回读如实报"未生效"；`af=lavfi=[dynaudnorm]` 更糟——属性写入回 `rc=0`、回读也像成功，但建链时 `AVFilterGraph: No such filter` → `Audio filter initialized failed` → mpv 丢掉整条音轨。现已把随包内核换成 `scripts/prepare_libmpv_windows.ps1` pin 的完整 FFmpeg 构建（shinchiro 20261111 / mpv v0.42.0-38 / FFmpeg N-128766），裸名写入直接生效（回读 `dynaudnorm`，`audio-out-params/format` 由 `s16` 变 `doublep`），Dart 代码零改动；包体 103 MB → 142 MB。取证、方案对比与迁移步骤见 `docs/reference/libmpv-windows.md`。

---

## 6. 已具备：不要重复造

| 能力 | 本仓库落点 | 说明 |
| --- | --- | --- |
| 实时语音转字幕 | `services/audio_ai/realtime_subtitle_controller.dart`、`core/audio_ai/cue_window.dart` | sherpa-onnx 本地推理；`cue_window` 已处理「ASR 时间戳不能直接当显示时间」 |
| 字幕文件格式白名单（含 ass/ssa） | `core/subtitle.dart:98-105` | 接不接受这个文件已具备；**绘制不走 libass**，见 §4.1「字幕渲染路径复核」与 §12.2 |
| 字幕在线匹配/翻译 | `services/subtitle_providers.dart`、`services/subtitle_match_service.dart`、`services/audio_ai/srt_translation_service.dart` | 默认全关，不配置就不发请求 |
| 播放队列/连播/循环 | `core/playback_queue.dart`、`core/playback_repeat.dart` | 队列是懒加载的（`hasMore`/`loadMore`） |
| 续播记忆 | `ui/playback_resume.dart:24`、`core/playback_request.dart:61-142` | 跨源续播用 `resumeSeed` |
| 硬解开关 | `core/player_options.dart:83,165` | `hwdec=auto-safe` / `no` |
| 倍速 + 长按加速 | `ui/player_controller.dart:1161`（0.25–4.0）、`ui/player_page.dart:4595,5019`、`core/player_options.dart:81` | 长按档位 [2, 2.5, 3, 4] |
| 屏显 OSD | `core/osd_config.dart`、`ui/player_osd.dart` | 开关落 `settings.json` 的 `ui.osd`，id 不得改名 |
| 右键菜单 | `ui/player_context_menu.dart`（701 行） | 分组 + 叶子项结构已成型 |
| 控制栏按钮自定义 | `core/player_buttons.dart` | 10 个按钮 id + 排序/隐藏 |
| 片头片尾跳过 | `core/skip_segments.dart` | A-B 循环要与之协调（§4.4） |

---

## 7. 明确不借鉴

1. **180°/VR/3D（261021 的 180° 视频、191211 的 360 VR CUBE/EAC）**——本项目是剧集与直播，
   站源不会提供投影元数据；mpv 的 spherical 需要专门的投影参数，做出来也没有输入。
2. **皮肤系统（`.skn` + 图层脚本）**——本项目已有 `ui/theme.dart` + `ui/tokens.dart` 的设计系统，
   再开一套皮肤会让「配置提供的 wallpaper/logo 优先于应用自身品牌」（`PRODUCT.md` 硬约束）
   的优先级关系变复杂。
3. **蓝光/DVB 调谐/游戏捕获/推流/聊天/主播打赏**——产品边界外（`PRODUCT.md` §Capabilities）。
4. **ARM64 构建**——发布目标只有 Windows x64 与 Linux x86_64。
5. **Kakao TV 等韩国直播生态、多语言 UI**——中文优先已定，本站也不接这些源。
6. **自由文本 mpv 属性直通**——理由见 §4.2：会让「设置页说不清、诊断页查不到」。

---

## 8. 警示项（别人的坑，别踩第二遍）

1. **双击判定窗**：`player_page.dart:84-92` 记录了仓库里真实踩过的坑——注册
   `GestureDetector.onDoubleTap` 会把单击拖慢整整一个判定窗，而且轮询式重复点击会被误判成双击
   （`integration_test/live_interaction_flow_test.dart`）。**做 §3.1 时不要换实现方式。**
2. **「搜索」不等于「过滤」**：PotPlayer 261021 先做播放列表搜索，260819 立刻改成「过滤」。
   做 §3.3 时按「列表收缩」设计，别做「高亮跳转」。
3. **字幕样式是反复回归区**：250514 改字体处理、250312 修 ASS/SSA、260114 修字符集——
   同一家产品连着几个版本在同一个区打补丁。做 §4.1 时**没有**去调 `sub-ass-override`：本仓库 libass 恒关，
   那条开关管不到绘制路径（§12.1）；真正要做的是「样式归属」的取舍——见 §12.2 与 checklist Q-39。
4. **实时字幕在直播里的不同步**：260114 专门修了「实时流媒体播放时字幕生成与实时音频不同步」。
   本项目 `core/audio_ai/cue_window.dart` 的文件头注释已经写明「PC 不延迟播放器：ASR 在语音
   端点返回，显示窗口从可呈现的位置开始」——改 ASR 相关逻辑时别退回「拿 ASR 时间戳直接当显示时间」。
5. **拖动暂停是「新增的可选能力」而不是默认行为**（260622 是 `+` 项）。P0-2 已按此落地为
   `PlayerOptions.dragPause` 设置项；**默认值由产品定为开启**（用户可关，关掉即回到改造前手感）。
   两个入口（设置页 + 右键菜单）共用同一份落盘值，不会出现"菜单关了、设置页还开着"。

---

## 9. 建议的落地顺序

| 顺序 | 项 | 理由 |
| --- | --- | --- |
| 1 | §3.2 拖动暂停（**已实现**） | 改动最小；产品定为设置项、默认开，故引入 `player.dragPause` 一个键 |
| 2 | §3.1 双击分区 | 已有 `PlayerDoubleClickGate`，改动集中在一个文件；但要连带 `PlayerOptions` 新字段 |
| 3 | §3.3 队列过滤 | 纯 UI + 边界提示，不碰播放器 |
| 4 | §4.1 字幕样式落盘 | **已实现**：新存储模型（`core/subtitle_style.dart`、`core/osd_style.dart`）+ `ui.subtitleStyle` / `ui.osdStyle` 落盘；不走 mpv 属性，ASS 归属单列 Q-39 |
| 5 | §4.2 HDR 色调映射 | 需要先确认 libmpv 版本 |
| 6 | §4.3 字符集 / §4.4 A-B / §5.x | 按需，互不阻塞；其中 §5.4 音量归一**已实现** |

---

## 10. 验证记录（本文写作时实测）

**PotPlayer 侧（发布说明）**

- 官方 Version History 英文版（本地副本 `/tmp/official.txt`，**2,728 行**）：`[261021]` 块逐行核对，
  共 1 条 `*` + 5 条 `+` + 4 条 `-`；`[260819]`、`[260622]`、`[260401]`、`[260114]` 同法核对。
- 全量统计：36 个版本、**758 条** `+`/`*` 功能条目（脚本按 `[YYMMDD]` 分段抽取）。
- 镜像站 `potplayer.multimediaplayer.net/download` 第 1–3 页：版本号与日期交叉核对一致。
- 版本号体系与 ARM64 条目：`[260819]` 原文含 `PotPlayerSetupARM64.exe` 链接。

**PotPlayer 侧（安装包，见 §11）**

| 检查 | 结果 |
| --- | --- |
| 下载与校验 | 51,257,600 B；MD5 `0a6ae3716380c2ba4e3816cd33dd7fd3` = CDN `x-stat-md5` |
| 容器识别 | `file` → Nullsoft Installer；`7z l` → `NSIS-3 Unicode`、`LZMA:23`、`Solid=+` |
| 解包 | 205 files / 191,369,356 B |
| 引擎版本 | `PotPlayer64.dll` FileVersion **1.7.23172.0**（≠ 安装包声明的 1.7.23159.0；≠ 镜像站 1.7.23164） |
| 语言表 | `Language/English.ini` 5,685 行 / 173 段 / `MenuString` 886 条 |
| 关键字符串 | `5005`、`5006`、`3131`、`3385`、`5010-5013`、`5055-5057`、`3285`、`3310` 均实读到（见 §11.4） |
| DLL 符号 | `REPLAYGAIN_*`、`AVReplayGain`、`.?AUILibASSCallback@@`、`CreateWhisperVAD` 等实读到 |
| 截断与重试 | 首次下载因工具 60 s 默认超时截断到 20,905,984 B，改用 `curl -C -` 续传后完整 |

**本仓库侧（命令与结果）**

| 命令 | 结果 |
| --- | --- |
| `grep -rni "replaygain\|replay_gain" lib/ packages/` | **0 命中** |
| `grep -rni "abLoop\|ab-loop\|A-B"` | 0 命中（仅 `source_swap_sheet.dart:328` 的无关注释） |
| `grep -rni "frameStep\|逐帧"` | 0 命中（命中项均为弹幕/字幕的「逐帧绘制」） |
| `grep -rni "smtc\|MediaSession\|SystemMediaTransport"` | **0 命中** |
| `grep -rni "audioDelay\|subtitleDelay"` | **0 命中** |
| `grep -rni "screenshot\|截图"` | 仅测试参数 `--screenshot-ready-file`（`ui/app.dart:86,121`） |
| `grep -c "TextField" lib/ui/player_queue_panel.dart lib/ui/player_episode_panel.dart` | **0 / 0** |
| `grep -rni "hdr\|toneMapping"` | 仅标题正则（`core/tmdb_title.dart:33,67`、`core/ai_content/title_resolution.dart:266`），**播放器侧 0** |
| `wc -l` | `player_page.dart` 6401、`player_context_menu.dart` 701、`player_overlay.dart` 470、`player_options.dart` 292 |
| `grep -rn 'libass' lib test` | **0 命中**（没有任何一处打开 libass） |
| `grep -n 'this.libass' …/media_kit-1.2.6/lib/src/player/platform_player.dart` | `:526` → `this.libass = false` |
| `grep -n 'sub-ass\|sub-visibility' …/media_kit-1.2.6/…/real.dart` | `:2434-2436` 三条按 `libass` 取值写 `no` |
| `grep -n 'SubtitleView' …/media_kit_video-2.0.1/lib/src/video/video_texture.dart` | `:450-455` 只在 `!libass` 时挂 Flutter 侧 `SubtitleView` |
| `grep -rn 'Player(' lib/` | 仅两处构造：`ui/player_controller.dart:132`、`services/reader/media_kit_reader_audio.dart:26`，都没传 `libass` |

**未能验证的部分（如实列出）**

- PotPlayer 的**默认值**与**运行时行为**（闭源）：双击分区的默认动作、拖动暂停松手后是否自动恢复、
  libass 的默认档位——安装包只能给出**标签**，给不出**取值**（见 §11.6）。
- 本项目 media-kit 打包的 **libmpv 版本**（决定 `tone-mapping` 取值与 `screenshot-raw` 可用性）——
  未查，属 §4.2 / §5.2 的前置条件。
- 本地 `.m3u8` 能否直接播（§5.3）——未实测。

---

## 11. 安装包静态解析（2026-11-15 实测，Windows 64-bit 版）

> 这一节是 §1–§10 里所有「安装包实证」引用的出处。**只做静态解析，没有运行 PotPlayer**。

### 11.1 获取与完整性

| 项 | 值 |
| --- | --- |
| 来源 | `https://t1.daumcdn.net/potplayer/PotPlayer/Version/Latest/PotPlayerSetup64.exe` |
| 体积 | **51,257,600 B**（48.9 MiB） |
| MD5 | `0a6ae3716380c2ba4e3816cd33dd7fd3`（与 CDN 响应头 `x-stat-md5` 一致） |
| Last-Modified | 2026-11-02 06:05:06 GMT |
| `file` | PE32 executable (GUI), Intel i386, **Nullsoft Installer self-extracting archive**, 5 sections |
| `7z l` | `Type = Nsis`，`Method = LZMA:23`，`Solid = +`，`SubType = NSIS-3 Unicode BadCmd=13` |
| 解包结果 | **205 个文件 / 191,369,356 B**（磁盘占用 183 MB） |

解包工具链（本机无 root，故不装系统包）：

```bash
apt-get download 7zip                     # 2,119,142 B
dpkg-deb -x 7zip_*.deb root/              # 得到 root/usr/lib/7zip/7z（25.01）
./root/usr/lib/7zip/7z x -y -oextract PotPlayerSetup64.exe
```

### 11.2 版本实证：四个数字互不一致

| 来源 | 版本 | 说明 |
| --- | --- | --- |
| 安装包 PE 版本资源 | `FileVersion 26.10.21.0` / `ProductVersion 1.7.23159.0` | 注释串：`PotPlayer Setup File (2026-11-02(월) 오후 3:02:35)`，`CompanyName: Kakao` |
| **`PotPlayer64.dll`（真正的引擎）** | **`FileVersion 1.7.23172.0`** | 文件时间戳 2026-11-02 14:02 |
| 包内 `History/English.txt` | 最新条目 **`[261021]`**（共 45 个版本） | 即「新构建没有配套 changelog」 |
| 第三方镜像站 | `1.7.23164` | 与上面三个都不同 |

**结论**：`26xxxx`（构建日期）与 `1.7.23xxx`（内部构建号）是**两套编号**，不同步；
安装包自身的 `ProductVersion` 字符串还会滞后于它自带的 DLL。
**引用版本号时必须写明来源**，否则必然对不上。

### 11.3 载荷构成（205 个文件里真正决定能力的东西）

| 组件 | 体积 | 作用 |
| --- | --- | --- |
| `ffcodec64.dll` | 38,105,088 B | 自带 FFmpeg（`Lavf63.11.101`）——解码器全覆盖的来源 |
| `PotPlayer64.dll` | 35,303,968 B | 播放器主体 |
| `Module/Whisper/Vulkan/whisper64.dll` | 46,094,848 B | Whisper **Vulkan** 后端 |
| `Module/Whisper/CPU/whisper64.dll` | 6,174,720 B | Whisper **CPU** 后端 |
| `Module/Whisper/Const-me/Whisper.dll` | 590,336 B | Whisper **DirectCompute** 后端 |
| `Module/Whisper/whisper.bin` | 885,098 B | 模型/配置 |
| `Module/Bass64/` | 8 个 DLL | BASS 音频解码（ape/flac/mpc/tta/wv/ofr…） |
| `Module/MediaInfo64.dll`、`QuickSync64.dll`、`AcmVorbis64.dll` | — | 媒体信息 / QuickSync / Vorbis |
| `ATextOut64.dll` | 2,505,744 B | 文本字幕输出层 |
| `PxShader/` | 34 个 HLSL `.txt` | 像素着色器滤镜（锐化/降噪/Levels/去隔行…） |
| `AviSynth/` 10 个 `.avs` + `VapourSynth/` 2 个 `.vpy` | — | 外挂滤镜链，含 `motioninterpolation.vpy`（补帧） |
| `Skins/*.dsf` | 2 个（各约 426 KB） | 实为 **ZIP**：46 个条目 / 6 个 XML（`VideoSkin.xml` 等）+ PNG |
| `Language/` 37 个 `.ini`、`History/` 13 个 `.txt` | — | 语言包与变更日志 |
| `Extension/` | 6 搜索 + 7 翻译 + 2 YouTube `.as` | AngelScript 扩展 + `api.txt` |
| `Menus/SimpleMenu.xml`、`UrlList/`、`Html/`、`IconPack/`、`Logos/` | — | 菜单定义 / 直播源示例 / 内置页 / 图标包 |
| `CmdLine64.txt` | 50,906 B | 27 个命令行开关的说明 |

### 11.4 字符串实证：把「推测」变成「有出处」

语言文件 `Language/English.ini`（**5,685 行 / 173 段**，`MenuString` 886 条）与两个 DLL 的字符串，
逐条对应本文前面的论断：

| 能力 | 证据（原文/符号） | 对本文的修正 |
| --- | --- | --- |
| 双击分区 | `5005=Left Button - Double Click:(left area):`、`5006=…(right area):`；完整矩阵 `3878-3891`（Left/Right/X1/X2/Wheel × 单击/双击）、按住 `5000-5004` | **§3.1 已改写**：不是「劈成两半」，是「双击这一格按区域拆开」 |
| 播放列表过滤 | `3131=Process playlist search using filtering` | 印证 §3.3 的判断 |
| ReplayGain | `PotPlayer64.dll`/`ffcodec64.dll` 均含 `REPLAYGAIN_TRACK_GAIN`/`_PEAK`/`ALBUM_GAIN`/`ALBUM_PEAK`、`AVReplayGain`；取值 `5055=Do not use`/`5056=Track gain`/`5057=Album gain` | **§5.4 已改写**：确证是**读文件标签** |
| 响度归一 | `3385=Normalizer (Auto Volume Control)`、`101_0_12_18_0=Normalizer Shift+N` | **新增候选**：与本项目真正相关的是这条，不是 ReplayGain |
| libass 四态 | `5010=Use default engine` / `5011=…default style, other use libass` / `5012=Use libass for ASS/SSA…` / `5013=Use libass for all subtitle` | **§4.1 已改写**：是一维四档选择器 |
| 字体后端三选一 | `5017=GDI - High compatibility…` / `5018=FreeType…` / `5019=DirectWrite…` | **§4.1 已补**：渲染 = 引擎 × 样式归属的二维选择 |
| Whisper | `CThreadWhisperExe`/`CreateWhisperConvert`/`CreateWhisperVAD`/`whisper_full_with_state`/`CWhisperUpdateCheck`；`Module/Whisper` 三后端 | 印证 §6「已具备」对照：本项目用 sherpa-onnx，架构不同但能力同级 |
| 系统媒体键 | `3034=Turn on global media control keys` | **§5.1 加强**：是**全局媒体键接管**，不只是 SMTC 面板 |
| 多实例 | `3293=Multiple instances:`、`3339=Use non-overlapping multi instances`、`3501=Disable: Play files in existing PotPlayer instance`、`3502=Enable: Allow more than one PotPlayer instance`、`3503=Disable: Add files to playlist of existing PotPlayer instance` | **新候选**：本项目没有任何单例/复用语义（见 §11.5） |
| A-B 是**列表** | `3285=A-B Repeat Setup`、`101_0_9_10_15=Remember A-B Repeat List`、`101_0_9_10_17=A-B Repeat List Setup... Shift+\`、`3990=There are too many repeat intervals.` | **§4.4 修正**：不是单组 A/B，是可记忆的**区间列表**且带上限保护 |
| 字幕同步是**步进** | `3310=Subtitle sync steps:`、`3380=Keep subtitle sync changes over whole runtime`、`101_0_10_10_1=Increase… > or .`、`…_2=Decrease… < or ,`、`…_3=Default… /` | **强化 §4.1**：同步是「步长 + 是否跨文件保持」两件事 |
| 字号是**步进** | `1123=Subtitle font size : Increase (%d)`、`1124=…Decrease (%d)`、`1125=Select Subtitle Font`、`101_0_10_8=Subtitle Font Renderer` | **§4.1 补充**：用相对步进而非绝对像素 |
| 字幕帧率转换 | `3940=Subtitle FPS Convertor` | **新候选**（23.976↔25 类场景） |
| 导航栏缩略图 + 关键帧跳转 | `3066=Show thumbnail previews on nav. bar`、`3048=Generate thumbnails by keyframe search`、`3204=With using keyframe search, time jumping can be done very fast…`、`101_0_9_6_2=Previous keyframe Ctrl+Shift+Left` | **新候选**：本项目 seek 既无预览也无关键帧跳转 |
| 均衡器 | `3287=Equalizer`、`101_0_12_14=Use Equalizer Shift+E`、`2253/2254/2255=Save/Add/Delete equalizer preset` | **新候选**（音频侧，与 Normalizer 并列） |
| 内置 AI 翻译 | `5026=Builtin AI translation`、`5027=Builtin AI settings...` | 与 §6 对照：本项目已有 LLM 字幕翻译，方向一致 |
| 变调 | `101_0_9_7_6=Use audio pitch shifting`、`4570=Audio Pitch`、`4571-4573 Shift+H/J/K` | **§4.2 补充**：变调与变速是**两件独立的事** |
| HDR | `3381=Tone mapping type:`、`3047=HDR10+ dynamic tone mapping`、`3054=Use H/W HDR output mode`、`3042/3043=SMPTE ST 2084/2086`、`4773=[√]: Don't wait vsync\n[-]: Use D3D11 VRR` | 印证 §4.2：色调映射是**多档 + 元数据开关**，不是一个布尔 |

### 11.5 安装包给出、但发布说明没提的三件事

**1) 命令行开关表（27 个）**——`CmdLine64.txt` 原文：

```text
/filedlg /urldlg /folderdlg /simple /cap /cam /atv[:ch] /dtv[:ch[-idx]] /dvd /cd[:drive]
/add /insert /autoplay /same /sort /randomize /new /current /clipboard
/seek=hh:mm:ss.ms  /sub="file"  /aud="file"
/user_agent="ua"  /referer="ref"  /headers="hdrs"  /title="title"  /volume="n"
config="name"
```

对本项目有直接参照价值的是三组：

- **`/user_agent` `/referer` `/headers`**：本项目已有本地代理做 Header 注入，但**没有一条
  「从外部带着 header 起播」的入口**。要做深链（`webhtv-pc://play?url=…&referer=…`）时，
  这是现成的语义参照。
- **`/seek=`**：精确到毫秒的起播点，正是「续播」对外暴露的形态。
- **`config="name"`**：按名字直接以某个预设启动。本项目有「多配置并存与切换」，
  但没有「按名字以某配置启动」的入口。

**2) AngelScript 扩展的目录分层**——`Extension/` 下四类，每类「同名 `.as` + 同名 `.ico`」：

```text
Extension/Subtitle/Search/     SubtitleSearch - OpenSubtitle.as / SubDL.as / podnapisi.as / Napisy24.as / titlovi.as / ysubs.as
Extension/Subtitle/Translate/  SubtitleTranslate - google.as / bing.as / DeepL.as / Yandex.as / papagoNMT.as / Libre.as / LM Studio.as
Extension/Media/UrlList/       MediaUrlList - YouTube.as
Extension/Media/PlayParse/     MediaPlayParse - YouTube.as
```

注意 `LM Studio.as`——**本地 LLM 翻译**已经是它的一等公民。但**架构不可抄**：本项目硬约束是
「主进程永不加载不可信脚本」（`PRODUCT.md`），所以只能抄**目录分层**（搜索/翻译/媒体列表/
播放解析各自独立、带图标、可单独启停），不能抄「脚本进主进程」这条。

**3) 皮肤 = ZIP + XML + `CmdID` 绑定**——`Skins/Default.dsf` 实为 zip，46 个条目、6 个 XML：

```xml
<Skin Version='1.0' MinorVersion='1000'>
  #include<Common.txt>
  #if<SkinType==Touch>
    <MainSkinAreaOscFrame WidthLimit='380'
  #else
    <MainSkinAreaOscFrame WidthLimit='320'
  #endif
      HeightLimit='0' Image='Main.png' AlphaMode='1' UseWindowFrame='0' >
      <Control>
        <Static Align='Client' Contain='CMD_VIDEO_WINDOW' />
      </Control>
  </MainSkinAreaOscFrame>
```

要点：**控件不写死功能，只写 `CmdID`**（`CMD_VIDEO_WINDOW` 之类），皮肤只决定布局与贴图，
`#include` + `#if<SkinType==Touch>` 做条件组合。
本项目已决定不做皮肤系统（§7），但这条思路与 `core/player_buttons.dart` 的「按钮 = id 列表 +
排序/隐藏」**方向一致**，不必改；真要扩展，就继续往 id 表里加，而不是引入一套皮肤 DSL。

### 11.6 仍然不能确认的部分（安装包给不出的）

- **运行时行为**：松手后是否自动续播、双击分区的默认动作、libass 默认档位、
  Normalizer 的默认开关——语言文件只有**标签**，没有**取值**。
- **私有配置的键名与默认值**：安装包里**没有**默认的 `PotPlayerMini64.ini` 模板，
  所以拿不到「出厂默认设置」的完整快照。
- **任何性能数据**：无（未运行）。
- 本项目 media-kit 打包的 **libmpv 版本**：仍未查，是 §4.2 / §5.2 的前置条件。
- 开 libass 之后的真实观感（ASS 定位/特效是否恢复、与 Flutter 侧样式如何取舍）：需要图形环境实跑，见 §12.2 与 checklist Q-39。

### 11.7 复核命令（本次实际执行）

```bash
curl -sSIL 'https://t1.daumcdn.net/potplayer/PotPlayer/Version/Latest/PotPlayerSetup64.exe'
curl -sSL -C - -o PotPlayerSetup64.exe '<同上>'
md5sum PotPlayerSetup64.exe        # 0a6ae3716380c2ba4e3816cd33dd7fd3
file PotPlayerSetup64.exe          # NSIS self-extracting archive
apt-get download 7zip && dpkg-deb -x 7zip_*.deb root/
./root/usr/lib/7zip/7z l PotPlayerSetup64.exe | head -60      # FileVersion 26.10.21.0 / ProductVersion 1.7.23159.0
./root/usr/lib/7zip/7z x -y -oextract PotPlayerSetup64.exe    # 205 files / 191,369,356 B
./root/usr/lib/7zip/7z l extract/PotPlayer64.dll | sed -n '/^Comment/,/^}/p'   # FileVersion 1.7.23172.0
strings -a extract/PotPlayer64.dll | grep -iE 'libass|replaygain|whisper'
python3 -c "print(open('extract/Language/English.ini',encoding='utf-8-sig').read().count(chr(10)))"  # 5684
grep -n '5005=\|5006=\|3131=\|3385=\|5010=\|5013=' extract/Language/English.ini
```

**产物位置**：`/tmp/pp/PotPlayerSetup64.exe`、`/tmp/pp/extract/`（183 MB）。
未提交进仓库——体积与许可证都不适合入库，本文只保留结论与命令。

---

## 12. 被推翻过的判断（复核后的更正）

> 开头承诺本文负责「哪些结论被推翻过」，这一节就是账本。每条三段：**原判断 → 推翻它的证据（file:line）
> → 现在的口径**。证据一律 **A 级**（代码实测）；被推翻的原判断来自本文早期草稿与 `potplayer-checklist.md` 的 P1-4。

### 12.1 「P1-4 用 mpv `sub-*` 属性落盘」——推翻

**原判断**（§4.1 早期建议 2）：把字幕样式翻成 mpv 属性 `sub-font-size` / `sub-border-size` / `sub-pos` /
`sub-color` / `sub-back-color` / `sub-bold`，并入 `core/player_options.dart:164-170` 的 `mpvProperties`；
并把 `sub-ass-override` 的默认值论证成 `scale`。

**推翻它的证据**：本仓库的字幕**不经过 mpv 渲染**（链路见 §4.1「字幕渲染路径复核」）。

- `PlayerConfiguration.libass` 默认 `false`：`~/.pub-cache/hosted/pub.dev/media_kit-1.2.6/lib/src/player/platform_player.dart:526`。
- 关闭时给 mpv 写 `sub-ass=no` / `sub-visibility=no` / `secondary-sub-visibility=no`：同包 `lib/src/player/native/player/real.dart:2434-2436`。
- Flutter 侧只在 `!libass` 时挂 `SubtitleView`：`~/.pub-cache/hosted/pub.dev/media_kit_video-2.0.1/lib/src/video/video_texture.dart:450-455`（`:451` 即 `!(…configuration.libass ?? false)`）。
- 本仓库生产代码两处 `Player()` 构造都没传 `libass`：`apps/desktop-flutter/lib/ui/player_controller.dart:132`、`apps/desktop-flutter/lib/services/reader/media_kit_reader_audio.dart:26`。
- 于是 `mpvProperties` 里写任何 `sub-*` 都进不了绘制路径；`sub-ass-override` 在 libass 关闭时没有可覆盖的对象，论证它等于论证一个空操作。

**现在的口径**：样式落在 Flutter 侧——`apps/desktop-flutter/lib/core/subtitle_style.dart` +
`apps/desktop-flutter/lib/core/osd_style.dart`，渲染投影 `apps/desktop-flutter/lib/ui/player_page.dart:159-191`，
落盘 `ui.subtitleStyle` / `ui.osdStyle`（`apps/desktop-flutter/lib/services/ui_preferences_store.dart:1216-1224`）；
**零新增 mpv 属性**。

### 12.2 「mpv 默认走 libass，所以 ASS/SSA 排版是现成的」——推翻

**原判断**（`potplayer-checklist.md` D-18 的备注、§2 对照总表第 14 行）：扩展名白名单收 `ass`/`ssa`，
mpv 默认用 libass 渲染，字幕组排版天然保留。

**推翻它的证据**：白名单只决定「接不接受这个文件」（`apps/desktop-flutter/lib/core/subtitle.dart:98-105`），
不决定「谁来画」。绘制路径同 §12.1：mpv 不画（`sub-visibility=no`），Flutter 画，而 Flutter 拿的是 mpv 的
`sub-text`（`real.dart:1911` 监听、`:2477` 注册格式）——**纯文本**，ASS 的定位/特效标记在这一步已经剥掉。
像素级观感未在本机实跑（Linux，无图形环境），但「排不掉 libass」这条链是代码事实。

**现在的口径**：能力记为「字幕文件格式白名单（含 ass/ssa）」；**ASS 排版丢失单列为 checklist Q-39**，
切 libass 要 Before/After 视觉证据，且回归面包含「Flutter 侧样式整层失效」。

### 12.3 顺带纠正的一句代码注释（已改）

`apps/desktop-flutter/lib/ui/player_controller.dart:507` 原来用「写成带真实扩展名后 libass 能直接按扩展名解析」
解释外挂字幕落盘的理由。扩展名确实有用（影响 mpv 的格式识别与轨表刷新），但**与 libass 无关**——本仓库
libass 关着。该句已按 §12.1 的口径改为「mpv 能按扩展名直接识别格式」，代码行为未变。
