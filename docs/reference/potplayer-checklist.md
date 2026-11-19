# PotPlayer → WebHTV PC 借鉴全量清单

> 这是**可勾选的完整清单**，一次读完即可决策。逐条的论证、代码引用与反驳过程在
> [potplayer-borrowings.md](potplayer-borrowings.md)；本文只保留**结论 + 依据 + 落点 + 验收**。
>
> - PotPlayer 基线：**261021** 构建（`PotPlayer64.dll` 实为 **1.7.23172**），Windows 64-bit 官方安装包。
> - 本仓库基线：`fix/toast-hold-time` @ `e65212b`，路径相对 `apps/desktop-flutter/`。
> - 证据等级：**A** = 安装包实测（字符串/符号/文件）；**B** = 官方更新日志原文；**C** = 推断（标「未验证」）。
> - **状态**：**P0-2（拖动进度条时暂停）、P1-4（字幕与 OSD 样式落盘）、P1-8（音量归一）已实现**——它们的「落点」列写的是真实文件与落盘键；
>   其余条目仍全部为 backlog。P1-4 的实现推翻了旧的「用 mpv `sub-*` 属性落盘」建议
>   （登记在 [potplayer-borrowings.md](potplayer-borrowings.md) §12）；P0-2 的落地与残留限制见 §2 表格与
>   [evidence/p0-2-drag-pause.md](evidence/p0-2-drag-pause.md)。

---

## 0. 三十秒版本

**只做三件事**，收益/成本比最高：

1. **拖动进度条时暂停**（P0-2）——改动最小，网络流收益最大。
2. **双击左/右区域分别配置动作**（P0-1）——已有 `PlayerDoubleClickGate`，改动集中。
3. **队列/选集过滤式搜索**（P0-3）——纯 UI，TVBox 站点动辄上百集。

**最该被替换掉的一条**：ReplayGain（标签式，站源没有标签）→ 换成 **Normalizer 音量归一**。

**最容易被误抄的一条**：libass 不是开关，是**四档选择器**；默认档决定 ASS 字幕会不会被夺样式。
但在本仓库要换个读法：libass **恒关**、字幕由 Flutter 侧绘制，所以这里的「默认档」只有打开之后
才有意义——见 §8 Q-39。

---

## 1. 统计

| 分类 | 条数 | 含义 |
| --- | --- | --- |
| P0 | 3 | 真实缺口、改动小、收益直接（其中 P0-2 已实现） |
| P1 | 5 | 结构性收益，需独立设计（其中 P1-4 已实现） |
| P2 | 6 | 工程纪律与体验细节 |
| 观察 | 2 | 记录在案，暂不做 |
| 已具备 | 12 | 不要重复造 |
| 不做 | 7 | 明确排除，附理由 |
| 待确认 | 4 | 前置事实未查清，阻塞上面某些条目 |
| **合计** | **39** | |

---

## 2. P0（3 条）

| # | 主题 | PotPlayer 依据 | 本仓库落点 | 前置条件 / 风险 | 验收口径 |
| --- | --- | --- | --- | --- | --- |
| P0-1 | **双击左/右区域分别配置动作** | 260819「individually configure actions for the left and right areas upon double-clicking」（B）；`5005=Left Button - Double Click:(left area):`、`5006=…(right area):`（A） | `ui/player_page.dart:82-123`（`kPlayerDoubleClickWindow` / `PlayerGestureAction` / `resolvePlayerGesture` / `PlayerDoubleClickGate`）、`:4902-4925 _onVideoTap`；新增字段落 `core/player_options.dart`，经 `services/ui_preferences_store.dart:1017 rememberPlayerOptions` 持久化 | **禁止改用 `GestureDetector.onDoubleTap`**（`:84-92` 记录过 300 ms 迟滞与轮询误判，见 `integration_test/live_interaction_flow_test.dart`）；直播下 `seek*` 退化为 `none`；坐标按渲染盒算，不按窗口 | 左右各自触发配置动作；**默认配置 = 今天的行为**（双击只切全屏、不改播放状态）；第 3 击属于新一轮；直播菜单项禁用对应动作 |
| P0-2 | **拖动进度条时暂停**（状态：**已实现**） | 260622「pause function when navigating via the navigation bar」（B） | 开关 `core/player_options.dart:137,207`（`dragPause`，默认 `true`，落盘键 `dragPause`，缺键回落 `true`）；滑杆回调 `ui/player_overlay.dart:212-238,489-509`（`onSeekStart`/`onSeekEnd`，`onSeek` 连续语义不变）；判定器 `ui/player_page.dart:161-185`（`PlayerDragPauseGate`，含 `reset()`）；**拖动期间不落引擎 seek、松手一次 seek** `ui/player_page.dart:397-435`（`_dragSeekTarget`/`_settleDragSeekTarget`）、`:4898-4965`（`onSeek` 只记预览、`onSeekEnd` 提交一次）；`seeking` 并入缓冲提示 `ui/player_controller.dart:226-289,876-915`、`ui/player_overlay.dart` 的 `showBufferingIndicator`；入口 `ui/settings_detail_pages.dart:87`、右键「播放 → 拖动进度条时暂停」 | 直播 `duration<=0` 时回调本就是 `null`，**不要动直播路径**；恢复播放严格依赖拖动前状态；程序 seek（`core/skip_segments.dart`）不得暂停 | 拖动中暂停、松手续播；拖前本就暂停 → 松手仍暂停；直播零行为变化；缓冲段隐藏语义不变；**拖动期间不发 seek、松手恰好一次 seek**（已由 `test/player_drag_pause_test.dart` 的 `io.calls` 断言锁住）；慢 seek 期间有缓冲提示 |
| P0-3 | **队列/选集过滤式搜索** | 261021「customize the playlist search method」（B）+ 260819「playlist search function to operate as a filter」（B） | `ui/player_queue_panel.dart`（`TextField` **0 命中**）、`ui/player_episode_panel.dart`（**0**）、`core/playback_queue.dart`（`PlaybackQueueSnapshot{items,hasMore,loading,error}` + `loadMore()`） | 懒加载队列**只能过滤已加载项**，必须如实标注边界；自动 `loadMore()` 要限页且可取消；过滤不得改动 `itemKey`；不做「跳转高亮」式搜索 | 输入即收缩、清空即恢复；`hasMore` 时边界提示可见；`onSelect` 传出的 key 与过滤前一致 |

---

## 3. P1（5 条）

| # | 主题 | PotPlayer 依据 | 本仓库落点 | 前置条件 / 风险 | 验收口径 |
| --- | --- | --- | --- | --- | --- |
| P1-4 | **字幕与 OSD 样式落盘**（状态：**已实现**） | 240618 OSD 字体可设；250514 字幕字体处理；260401 用 libass 输出（B）；四档渲染器 `5010-5013`、三字体后端 `5017-5019`、字号步进 `1123/1124`、同步步进 `3310/3380`（A） | 模型 `core/subtitle_style.dart`（`SubtitleStyle`：文字色/底色不透明度/描边/字号/底部间距，带 `normalized`/`toJson`/`fromJson`/`isDefault`）、`core/osd_style.dart`（`OsdStyle`：字号/不透明度）；落盘 `services/ui_preferences_store.dart:1216-1224`（`ui.subtitleStyle` / `ui.osdStyle`；`:1181` 每轮重建整个 `ui` 段，故恢复默认后键自然消失）+ `state/app_state.dart:1683,1687,2437,2446`；消费 `ui/player_page.dart:159-191`（`SubtitleStyleView` → `SubtitleViewConfiguration`）、`:5138-5239`「字幕样式」菜单（字号/描边/位置/底色各 4 档 + 文字颜色 6 档 + 恢复默认）、`:5374-5417`「屏显样式」菜单（字号/不透明度各 4 档 + 恢复默认）、`ui/player_osd.dart:32-33,162,306` | **不走 mpv**：生产代码两处 `Player()` 都用 media-kit 默认 `libass=false`（`ui/player_controller.dart:132`、`services/reader/media_kit_reader_audio.dart:26`），mpv 被写 `sub-ass=no`/`sub-visibility=no`，`sub-font-size` 一类属性与 `sub-ass-override` 都管不到实际绘制路径；ASS/SSA 自带排版因此被拉平成纯文本，单列为 **Q-39**，本轮不改；`mpvProperties` 的「空值也写」（`core/player_options.dart:163`）与本条无关——本轮零新增 mpv 属性；默认值必须逐项等于今天外观，否则等于静默改手感 | 改字号/描边/位置/底色/文字颜色后重进播放器仍生效（只作用于外挂/在线/本地/内嵌四路 mpv 轨字幕；ASR 字幕在播放器页单独绘制、不受样式影响，见 borrowings §4.1）；「恢复默认样式」后 `settings.json` 的 `ui.subtitleStyle` / `ui.osdStyle` 键消失；默认值下观感与实现前逐项一致；ASS 排版问题单列 Q-39、不在本条验收内；`dart analyze` 无告警 |
| P1-5 | **mpv 属性白名单化 + HDR 色调映射** | 250625「select HDR tone mapping type」；241211 HDR2084 显示器亮度（B）；`3381=Tone mapping type:`、`3047=HDR10+ dynamic tone mapping`、`3054`、`3042/3043`（A） | `core/player_options.dart:164-170`（**固定 5 键**：hwdec/cache/demuxer-max-bytes/demuxer-max-back-bytes/audio-spdif） | 先确认 media-kit 打包的 **libmpv 版本**（`tone-mapping` 取值随版本变）；非法值必须 try/catch 并写进 `core/playback_diagnostics.dart`；**不做自由文本直通** | 三档可切；切回「自动」时属性被**显式写回默认**而非残留；诊断页可见实际生效值 |
| P1-6 | **字幕字符集扩展（Big5 / Shift-JIS / EUC-KR）** | 260114「Improved subtitle character set handling」（B） | `core/text_codec.dart:115-146`（BOM → 声明 → 严格 UTF-8 → GBK；`:132` 支持清单只有 `utf-8 / utf-16le·be / gbk·gb2312·gb18030 / latin1`）、`services/subtitle_service.dart` | 需要额外字符集实现，要过体积与许可证；**只在显式声明 charset 时启用**，不参与"未声明时猜编码"的兜底链（猜错比猜对常见）；Windows/Linux 行为要一致 | 四种新字符集各有单测；**未声明 charset 的字节流行为与今天完全一致** |
| P1-7 | **A-B 循环（区间列表）** | 210929 快速区间重复；200512 重复次数；200616 重复延迟（B）；`3285=A-B Repeat Setup`、`101_0_9_10_15=Remember A-B Repeat List`、`3990=There are too many repeat intervals.`（A） | `core/playback_repeat.dart:8-16`（只有 `off`/`one`/`all`，语义是"这一集播完之后"） | 与「自动连播 / 片头片尾跳过」冲突：A-B 生效期间必须暂停自动跳集；直播禁用；跨集自动清除；列表要有上限保护 | A/B 点可设可清；跨集自动失效；直播菜单项禁用；与 `core/skip_segments.dart` 不打架 |
| P1-8 | **音量归一（Normalizer）**（状态：**已实现**） | `3385=Normalizer (Auto Volume Control)`、`101_0_12_18_0=Normalizer Shift+N`（A）；对照 ReplayGain 是标签式 `REPLAYGAIN_TRACK_GAIN`…、取值 `5055-5057`（A） | 模型 `core/player_options.dart:207`（`audioNormalization`，默认 `false`，走 `normalized`/`copyWith`/`toJson`/`fromJson`/`==`）；属性 `core/player_options.dart:330`（`af` 为 `dynaudnorm` 或空串，随整份 `mpvProperties` 显式写回）+ 白名单 `core/mpv_properties.dart:241`（只收空串/`dynaudnorm`，可回读验证；随包 Windows libmpv 无 ffmpeg 滤镜表，裸名写入被内核拒、回读如实报未生效且音轨不受影响——**不可**改成 `lavfi=[dynaudnorm]`，那会丢音轨；换成带完整 FFmpeg 的内核后可原样生效，评估与实测见 `docs/reference/libmpv-windows.md`）；落盘 `services/ui_preferences_store.dart:1068`（`player.audioNormalization`）；入口 `ui/settings_detail_pages.dart:162`（设置 → 播放）、`ui/player_page.dart:5777`（右键「声音 → 音量」勾选项）、`:3914`（页面局部 Shift+N，`includeRepeats: false`）、`:6386`（菜单与快捷键共用的切换，整表参数与 `af` 单项写入共用串行队列，并复用 `applyMpvProperties` 的回读判定） | `af=dynaudnorm` 有副作用，**必须默认关且可关**；要区分「按站源记住音量」与「全局归一」；**不要**顺手把 ReplayGain 也实现（站源无标签，属无效功能）；**音频直通绕过滤镜**：`audio-spdif` 命中时输出仍是 `spdif-ac3`，故只对已解码音频生效，直通偏好本身不变（实测见 borrowings §5.4） | 开关可切；关掉即恢复原响度；不引入任何"读文件标签"的逻辑 |

---

## 4. P2（6 条）

| # | 主题 | PotPlayer 依据 | 本仓库落点 | 前置条件 / 风险 | 验收口径 |
| --- | --- | --- | --- | --- | --- |
| P2-9 | **系统媒体控制（SMTC / MPRIS）** | 240618「system media transport control function」（B）；`3034=Turn on global media control keys`（A） | grep `smtc` / `MediaSession` **0 命中** | Windows 走 SMTC、Linux 走 MPRIS；macOS 不在打包目标，**不要为它设计**；窗口最小化后仍要响应 | 播放/暂停、上一集/下一集、元数据（片名·第 N 集）在系统面板可见可控 |
| P2-10 | **视频截图（PNG 起步）** | 240827「Added WEBP to video capture」（B）；`4776=Save images in WEBP format`（A） | grep `screenshot` 只剩测试参数 `--screenshot-ready-file`（`ui/app.dart:86,121`），**非用户功能** | 先确认 media-kit 是否暴露 mpv `screenshot-raw`；WebP 需额外编码器，可后置；截图目录必须用户可配（别默默塞进应用数据目录）；受保护内容应拒绝 | 截图落盘且用户找得到；快捷键可用；格式正确 |
| P2-11 | **本地 HLS/DASH 文件播放** | 261021「playing HLS/DASH streams from local files」（B） | `state/folder_playback_queue.dart` 的 `_nonVideoExtensions` **未排除** `m3u8`/`mpd`，因此本地方案会被当视频候选 | **先实测**：manifest 内相对路径能否解析、mpv 对 `file://` 的态度；播不了就复用 `services/proxy_server.dart` 既有的 HLS 改写能力 | 实测结论写进文档；能播则补图标与说明，不能播则走代理改写 |
| P2-12 | **导航栏缩略图 + 关键帧跳转**（状态：**部分实现**） | `3066=Show thumbnail previews on nav. bar`、`3048=Generate thumbnails by keyframe search`、`101_0_9_6_2=Previous keyframe Ctrl+Shift+Left`（A） | 预览：`ui/player_overlay.dart`（`PlayerProgressSlider` 可选预览卡）+ `services/player_thumbnail_service.dart`（独立静音 320×180 media-kit 实例）；关键帧：`ui/player_controller.dart:1213 seekToKeyframe`；落盘 `core/player_options.dart` `showThumbnailPreview` → `settings.json` 顶层 `player`；入口 `ui/player_page.dart`（右键播放分组 + 设置页「导航栏缩略图」）、`ui/app.dart`（`Ctrl+Shift+←/→` 帮助文案） | 网络流抓缩略图成本高，预览做成可选开关（默认关）；关键帧用 `relative+keyframes` 的 `±0.0001s` 偏移，**MKV/AVI 未缓存路径会被 mpv v0.40.0 的 5ms 方向容差量成 no-op**，静态放大偏移会跳过高帧率全关键帧视频的紧邻帧，现有 `NativePlayer` 无原子 seek 策略接口，未获产品确认前不扩大偏移/缩小支持范围 | 预览默认关、开启后不拖慢 seek（已验证）；关键帧在 **MP4** 上逐个相邻关键帧且保持播放/暂停（已验证）；MKV/AVI 当前 fail-closed 给「关键帧跳转不可用」，缺陷与复现登记在 `docs/phase9/evidence/14-player-navigation.md` § 已知限制 |
| P2-13 | **多实例语义** | `3293=Multiple instances:`、`3339=Use non-overlapping multi instances`、`3501-3503` 三档（A） | `windows/` 无 `CreateMutex`；`lib/main.dart` 无单例逻辑（grep 0 命中） | 目前"第二次启动会发生什么"未定义；两个实例同时占 SQLite 与本地代理端口有风险；先定语义再写代码 | 明确三档之一并写进文档；并发启动不损坏数据、端口冲突有明确报错 |
| P2-14 | **深链/外部起播（含 header）** | `CmdLine64.txt`：`/user_agent=` `/referer=` `/headers=` `/seek=` `/sub=` `config="name"`（A） | `services/proxy_server.dart` 已有 header 注入能力；**但没有"从外部带着 header 起播"的入口** | 安全优先：允许注入 header 等于开放 SSRF 面，必须限定来源（localhost / 用户显式粘贴），且不得读本地文件 | 深链可带 header 起播；非法/越权输入被拒绝并有明确错误 |

---

## 5. 观察（2 条，记录在案暂不做）

| # | 主题 | 依据 | 判断 |
| --- | --- | --- | --- |
| O-15 | 均衡器（EQ + 预设 + 保存/删除） | `3287=Equalizer`、`101_0_12_14=Use Equalizer Shift+E`、`2253/2254/2255`（A） | 站源音频已经是二次压制，EQ 收益远低于本地音乐播放器；**除非有用户明确提出，否则不做** |
| O-16 | 字幕帧率转换（23.976↔25） | `3940=Subtitle FPS Convertor`（A） | 触发场景极少（混源外挂字幕），**不做**，留作排障时的手工手段 |

---

## 6. 已具备（12 条，不要重复造）

| # | 能力 | 本仓库落点 | 备注 |
| --- | --- | --- | --- |
| D-17 | 实时语音转字幕 | `services/audio_ai/realtime_subtitle_controller.dart`、`core/audio_ai/cue_window.dart` | sherpa-onnx 本地推理；`cue_window` 已处理"ASR 时间戳不能直接当显示时间" |
| D-18 | 字幕文件格式白名单（含 ass/ssa） | `core/subtitle.dart:98-105` | 接不接受这个文件已具备；但本仓库 `libass=false`，mpv 不渲染字幕，ASS 排版被拉平成纯文本——见 §8 Q-39 |
| D-19 | 字幕在线匹配 / 翻译 | `services/subtitle_providers.dart`、`services/subtitle_match_service.dart`、`services/audio_ai/srt_translation_service.dart` | 默认全关，不配置就不发请求 |
| D-20 | 播放队列 / 连播 / 循环 | `core/playback_queue.dart`、`core/playback_repeat.dart` | 队列懒加载（`hasMore`/`loadMore`） |
| D-21 | 续播记忆 | `ui/playback_resume.dart:24`、`core/playback_request.dart:61-142` | 跨源续播用 `resumeSeed` |
| D-22 | 硬件解码开关 | `core/player_options.dart:83,165` | `hwdec=auto-safe` / `no` |
| D-23 | 倍速 + 长按加速 | `ui/player_controller.dart:1161`（clamp 0.25–4.0）、`ui/player_page.dart:4595,5019`、`core/player_options.dart:81` | 长按档位 `[2, 2.5, 3, 4]` |
| D-24 | 屏显 OSD | `core/osd_config.dart`、`ui/player_osd.dart` | 开关落 `settings.json` 的 `ui.osd`，id 不得改名 |
| D-25 | 右键菜单 | `ui/player_context_menu.dart`（701 行） | 分组 + 叶子项结构已成型 |
| D-26 | 控制栏按钮自定义 | `core/player_buttons.dart` | 10 个按钮 id + 排序/隐藏 |
| D-27 | 片头片尾跳过 | `core/skip_segments.dart` | A-B 循环要与之协调（P1-7） |
| D-28 | 主题 / 壁纸 / Logo | `ui/theme.dart`、`ui/tokens.dart`、`ui/app.dart` | 配置提供的品牌优先于应用自身身份 |

---

## 7. 明确不做（7 条，附理由）

| # | 项 | 理由 |
| --- | --- | --- |
| N-29 | 180° / VR / 3D | 本项目是剧集与直播，站源不提供投影元数据；mpv 的 spherical 需要专门参数，做出来没有输入 |
| N-30 | 皮肤系统（`.dsf` = ZIP+XML+`CmdID`） | 已有 `ui/theme.dart` + `ui/tokens.dart` 设计系统；再开一套会让"配置提供的 wallpaper/logo 优先"（`PRODUCT.md` 硬约束）的优先级关系变复杂 |
| N-31 | 蓝光 / DVB 调谐 / 游戏捕获 / 推流 / 聊天 / 打赏 | 产品边界外（`PRODUCT.md` §Capabilities） |
| N-32 | ARM64 构建 | 发布目标只有 Windows x64 与 Linux x86_64 |
| N-33 | 韩国直播生态（Kakao TV 等）、多语言 UI | 中文优先已定；也不接这些源 |
| N-34 | 自由文本 mpv 属性直通 | 会让"设置页说不清、诊断页查不到"，与产品原则 2（可诊断）冲突；只做白名单 |
| N-35 | ReplayGain 字面实现 | 依赖文件标签（`REPLAYGAIN_*`），站源直链没有标签；应做的是 P1-8 的 Normalizer |

---

## 8. 待确认（4 条，阻塞上面某些条目）

| # | 待确认事项 | 阻塞 | 怎么确认 |
| --- | --- | --- | --- |
| Q-36 | media-kit 打包的 **libmpv 版本**与可用属性集 | P1-5（`tone-mapping` 取值）、P2-10（`screenshot-raw`）、P2-12（关键帧） | 查 `media_kit_libs_*` 的构建脚本/发行说明，或在运行实例上读 `mpv-version` 属性 |
| Q-37 | 本地 `.m3u8`/`.mpd` 能否被 mpv 直接播 | P2-11 | 拿一个本地 HLS 目录做一次播放实测，记录 manifest 相对路径是否解析 |
| Q-38 | PotPlayer 的**默认值**（双击分区默认动作、松手是否续播、libass 默认档、Normalizer 默认开关） | P0-1/P0-2 的「对齐参考」；P1-4 已按「默认外观不变」落地，不再依赖此项 | **安装包给不出**（语言文件只有标签，无默认 ini 模板）；只能在 Windows 上实跑对照，本机做不到——**不要把猜测写进实现** |
| Q-39 | **字幕渲染器：是否切到 libass**。今天 libass 恒关，ASS/SSA 自带排版被拉平成纯文本（A：生产代码两处 `Player()` 未传 `libass`；media-kit 默认 `false`；关闭时给 mpv 写 `sub-ass=no`，字幕由 Flutter 侧绘制） | 不阻塞已实现的 P1-4；阻塞「ASS/SSA 保留字幕组排版」这一能力，也阻塞任何将来想扩到 `sub-*` 的 mpv 白名单项 | 在**开 libass 的分支**上抓同场景 Before/After（同一文件、同一时间点、同一窗口与主题）：① ASS 外挂/内嵌字幕的定位、描边、特效是否恢复；② 打开后 Flutter 侧 `SubtitleView` 整层不再渲染，P1-4 的字号/颜色/位置/底色**全部失效**，得重新定「样式归属」（PotPlayer 四态 `5010-5013` 可作参照）；③ 回归面：`ui/player_page.dart:3663-3664` 的样式投影、`ui/player_osd.dart` 屏显层、字幕开关与轨选择语义、`ui/player_controller.dart:507` 那句按 libass 写的旧注释 |

---

## 9. 依赖关系（按此顺序推进）

```text
Q-36 (libmpv 版本)
   ├─→ P1-5  mpv 白名单 + HDR
   ├─→ P2-10 截图
   └─→ P2-12 关键帧跳转

P0-2  拖动暂停        ← **已实现**（无依赖）
P0-1  双击分区        ← 依赖 PlayerOptions 新字段（落盘可直接复用 P1-4 的模式）
P0-3  队列过滤        ← 无依赖
P1-4  字幕样式落盘    ← **已实现**；P0-1 可直接复用它的落盘模式（ui_preferences_store）
Q-39  字幕渲染器      ← 阻塞 ASS 排版；要先拿 Before/After 视觉证据，独立立项
P1-6  字符集          ← 独立
P1-7  A-B 列表        ← 与 D-27 片头片尾协调
P1-8  Normalizer      ← 独立
P2-13 多实例          ← 独立（但要先定语义）
P2-14 深链            ← 与 services/proxy_server.dart 安全边界耦合
```

---

## 10. 使用方式

- 每次只勾一条，**不要批量开工**：P0/P1 的验收口径都是"改变既有手感"的高危项。
- 动 P0-1 之前先读 `ui/player_page.dart:78-110` 那段注释——它记录了**为什么不能改用 `onDoubleTap`**。
- 动 **Q-39（切 libass）** 之前先读 borrowings §4.1「字幕渲染路径复核」与 §12：本仓库 libass 恒关，
  `sub-ass-override` 管不到实际绘制路径；打开它等于把样式来源从 Flutter 换成 mpv，这才是唯一
  「抄错就把用户字幕毁掉」的条目。
- 任何一条在实现时若发现与 `PRODUCT.md` 的硬约束冲突（进程隔离 / 可诊断 / 不承诺能力范围），**以 `PRODUCT.md` 为准，回头改这份清单**。