# 02 · 屏显（OSD）

- 状态：设计指导，**待评审**
- 日期：2026-10-18
- 上游参考：`F:\Workspace\webtv4\webhtv\app\src\main\java\com\fongmi\android\tv\ui\custom\PlayerOsdController.java`、
  `app\src\main\res\layout\view_player_osd.xml`
- 关联：`00` §4.1、`01` §6、`03`、`05`
- PC 端落点：新增 `apps/desktop-flutter/lib/ui/player_osd.dart`、
  `apps/desktop-flutter/lib/core/osd_config.dart`；
  修改 `apps/desktop-flutter/lib/services/ui_preferences_store.dart`

---

## 1. 目标

把"关于这次播放的事实"从**对话框**（要主动打开、会遮挡）变成**常驻可选的角标层**，
并提供一个可切换的**诊断面板**承接现有 `_showMediaInfo` / `_showDiagnostics` 的内容。

---

## 2. 上游契约（逐条对应）

| 上游事实 | 位置 | PC 端落点 |
| --- | --- | --- |
| 四角文本：上左标题/分辨率、上右时钟、下左进度、下右网速 | `view_player_osd.xml:17-85` | §3.1 |
| 顶部诊断面板（宽 0.98 视口、高上限 0.84） | `view_player_osd.xml:89-143` | §3.2 |
| 底部 2dp 迷你进度条 | `view_player_osd.xml:145-151` | §3.3 |
| 内边距 14dp | `view_player_osd.xml:15` | §3.4 |
| 文本 14sp + `tnum` + 阴影描边（无底色块） | `view_player_osd.xml:24-30` | §3.5 |
| 刷新周期 1000ms | `PlayerOsdController.java:193` | §4.1 |
| 控制栏可见 → 强制显示 标题/分辨率/时钟，隐藏其余 | `PlayerOsdController.java:208-220` | §4.2 |
| 控制栏隐藏 → 按开关显示 | `PlayerOsdController.java:222-244` | §4.2 |
| 直播时隐藏进度与迷你条 | `PlayerOsdController.java:280, 356` | §3.1、§3.3 |
| 7 个开关，默认 `size`/`progress`/`title` = true | `PlayerSetting.java:562-563`、`508-560` | §5 |
| 诊断面板在横屏时分为主列 + 附加列 | `view_player_osd.xml:104-141` | §3.2 |

---

## 3. 屏显元素

### 3.1 四角

| 角 | 内容 | 数据来源 | 缺失时 |
| --- | --- | --- | --- |
| 上左 | `片名 · 第 N 集`（换行）`3840×2160` | `_request.vodName` / `episodeName`；`controller.videoWidth/Height` | 分辨率未知 → 只显示标题一行 |
| 上右 | `HH:mm:ss` 时钟 | 系统时间 | 不会缺失 |
| 下左 | `00:12:34 / 01:58:20` | `controller.position` / `duration` | `duration <= 0` → **整项隐藏**（上游同） |
| 下右 | `12.8 MB/s` | 需要新增采样（§3.6） | 未采样 → **整项隐藏**（上游同） |

**直播时**：下左与下右的进度类信息隐藏（上游 `isLive()` 判定）。
PC 端的"直播"判据 = `_request.directUrl == true`（`player_page.dart:106` 的既有语义）。

### 3.2 诊断面板

对齐上游的**两列**结构：

| 列 | 内容 | 宽度 |
| --- | --- | --- |
| 主列 | 结论 / 视频 / 音频 / 网络 / 状态 / 播放 / 来源 | 0.98 × 视口宽 × 权重 1.25 |
| 附加列 | 设备 / 系统 / 芯片 / 屏幕 / 网络环境（**PC 端只有部分有对应**） | 权重 1 |

**PC 端主列内容**（全部来自既有 `PlaybackDiagnostics` 与 `PlayerController`，
`lib/core/playback_diagnostics.dart` 已有 `report` 字符串，但那是**面向粘贴**的文本，
面板需要**结构化**的行）：

| 行 | 内容 | 来源 |
| --- | --- | --- |
| 结论 | 正常 / 失败 + 分类 | `diagnostics.succeeded` / `failureKind` |
| 视频 | `codec WxH @fps bitrate` | `controller.selectedVideoTrack`、`videoWidth/Height` |
| 音频 | `codec Nch NHz bitrate` | `controller.selectedAudioTrack`、`audioParams` |
| 网络 | 目标主机 + 格式 | `diagnostics.target`、`diagnostics.format` |
| 状态 | 位置 / 时长 / 缓冲 / 缓冲百分比 | `controller.position/duration/buffered` |
| 播放 | 引擎 / 倍速 / 音量 / 静音 | `PlaybackEngine.mediaKit`、`controller.rate/volume/muted` |
| 来源 | 线路 / 站点 / 剧集 | `_request.flag/siteKey/episodeName` |

**PC 端附加列**：上游的设备/系统/芯片/屏幕在 PC 上没有对应物，
**不得伪造**（`00` §5 第 7 条）。改为：

| 行 | 内容 | 来源 |
| --- | --- | --- |
| 运行环境 | `Windows <version> / <arch>` | 需要新增（`Platform.operatingSystemVersion`） |
| 窗口 | `<W>×<H> @<dpr>` | `MediaQuery.sizeOf` / `devicePixelRatio` |
| 主题 | 暗色 / 亮色 / 跟随系统 | `state.themeMode` |
| 代理 | 本地代理端口 | `state` 的代理状态（若已暴露；否则**整行不显示**） |

**关键纪律**：附加列里**任何拿不到的行都不显示**，而不是显示「未知」。
理由：附加列是"环境快照"，一行「未知」不提供任何信息，只占高度。

### 3.3 迷你进度条

- 位置：画面**最底部**，`height: 2`，`Positioned(left:0, right:0, bottom:0)`。
- 颜色：已播部分 `AppPalette.magnitude`（星等琥珀），未播部分透明。
- **只在控制栏隐藏时显示**（上游同，`PlayerOsdController.java:356`）。
- 直播时隐藏。
- `duration <= 0` 时隐藏。

**为什么用星等琥珀**：`DESIGN.md` 的 The One Accent Rule 说琥珀只用在"真正是星等"的地方，
并明确列举"进度条"是合法用途之一（`DESIGN.md:206`：「选中态（NavigationRail 选中图标、
Chip 选中底、Slider 活动轨、**进度条**、光标与选区）」）。迷你进度条与底部滑杆是同一个语义。

### 3.4 内边距

上游 14dp。PC 端用 `AppSpace.lg`（16px）——**不引入新散值**
（`DESIGN.md` Do: 用 `AppSpace` 的标度值，不要引入新的散值）。
16 vs 14 的差异不影响观感，而 14 会成为全站第 17 个间距值。

**例外**：迷你进度条贴底，无内边距。

### 3.5 可读性

上游用 `shadowColor + shadowDx/Dy/Radius`（阴影描边），**没有底色块**。
PC 端同样：

```dart
TextStyle(
  fontSize: 14,                       // 显式指定，不改 textTheme
  fontFeatures: kTabularFigures,      // 数字成列（DESIGN.md The Tabular-Only-Where-Aligned Rule）
  color: Colors.white,
  shadows: [Shadow(color: Colors.black, offset: Offset(1.5, 1.5), blurRadius: 2)],
)
```

| 纪律 | 理由 |
| --- | --- |
| **字号显式指定 14**，不通过 `textTheme` | `DESIGN.md` The Metric-Neutral Rule：改 `textTheme` 会移动所有页面里不带 `ensureVisible` 的 `tap` |
| **必须 `tabular`** | 时钟与进度每秒刷新，比例字形会让整行左右抖动 |
| **必须描边** | 亮画面（实测 fixture 是高饱和彩条）上纯白字不可读 |
| 不用半透明黑底块 | 四角各一块黑底会在画面上形成四个"洞"，上游的选择是对的 |

**对比度**：白字 + 黑描边在任意底色上都能达到 4.5:1（描边提供局部对比）。
这是**唯一**允许"不依赖主题色"的文本——因为它的背景是任意视频帧，不是主题表面。

### 3.6 网速采样（下右）

**状态：已实现。** 数据源是**两个 mpv 接口的组合**，单位都是**字节/秒**：

| 顺序 | 取数方式 | 来源性质 |
| --- | --- | --- |
| **首选** | `getProperty('demuxer-cache-state')`，再从返回的 JSON 串里解析 `raw-input-rate` 字段 | JSON 串里的一个**键**（**不是**属性） |
| **回退**（仅首选解析不到时，同一拍内） | `getProperty('cache-speed')` | 独立属性，double |

**`raw-input-rate` 不是属性**：`mpv_get_property('raw-input-rate', MPV_FORMAT_DOUBLE)`
返回 `-8`（`MPV_ERROR_PROPERTY_NOT_FOUND`），`property-list` 的 827 个属性名里也没有它。
它只作为 `demuxer-cache-state` 的 JSON **键**存在。上一版文档写的「mpv 的 `raw-input-rate` 属性」
是错的，推翻它的实测数据见 §3.6.4。

本节按「当时的判断 → 更正 → 现在的实现 → 运行时验证与已知局限」四段写。
把被推翻的推理删掉，后来者会照原样再走一遍同一条弯路——本仓的惯例是留着它并标明错在哪。

#### 3.6.1 当时的判断（原文保留，结论已被 §3.6.2 更正）

> **已更正**：本节结论「本轮不实现」**已失效**——它错在认为 media-kit 没有暴露吞吐量。
> 以下原文保留，用于留住「当时为什么这么定」的推理链；**不要把它当现状引用**。

**这是本轮唯一需要新写的数据采集。**

上游用 `PlaybackSpeedMeter`（`PlayerOsdController.java:82, 398-400`）按秒采样字节数。
PC 端的 `PlayerController` 目前**没有**字节级吞吐量。

| 方案 | 可行性 | 结论 |
| --- | --- | --- |
| media-kit 暴露吞吐量 | ❌ 未暴露 | 不可用 |
| 从 `buffered` 位置差推算 | ⚠️ 只在缓冲前进时有效，且是**媒体时间**不是字节 | 不可靠 |
| 本地代理统计字节 | ⚠️ 只覆盖走代理的流量（T4 站点），直连站点统计不到 | 覆盖不全 |
| **不实现网速** | ✅ | **本轮选择** |

**决策：本轮不实现下右网速。** 理由：

1. `PRODUCT.md` §Product Principles 第 2 条要求"失败必须如实"，
   而一个只覆盖部分流量的网速读数**会误导**（用户看到 0 会以为卡了，其实只是没走代理）。
2. 上游的 `PlaybackSpeedMeter` 依赖 `PlayerManager` 的引擎级字节计数，
   PC 端没有等价物，伪造一个近似值违反第 5 条"不承诺能力范围"。
3. 下右位置**保留在设计中**，作为后续接入点；本轮该位置**不渲染**。

**这条必须在证据里如实写明**（`05` §6），不得让"屏显做完了"暗示网速也有。

#### 3.6.2 更正：那条前提错在哪

**这一节本身就是「更正」，而它自己也有一半是错的。** 按本仓惯例（留着错的、标明它错在哪），
两轮错都留着：第一轮推翻了 §3.6.1 的结论，第二轮（运行时实测之后）推翻了第一轮的后半。

> **已更正（第二轮，运行时实测之后）**：下面「漏了 `getProperty` 这道门」是对的；
> 但它把 `raw-input-rate` 当成**属性**，这是**第二个错误**。实测见 §3.6.4 的验证表：
> `mpv_get_property('raw-input-rate', MPV_FORMAT_DOUBLE)` 回 `-8`（`MPV_ERROR_PROPERTY_NOT_FOUND`），
> `property-list` 里也没有这个名字。**第一版判断错的是两层，不是一层。**

**第一轮：错在「media-kit 暴露吞吐量 ❌ 未暴露」这一条。** media-kit 的 `Player.platform` 在桌面构建里
就是 `NativePlayer`，它暴露了 `getProperty(String)`——能读 mpv 的**任意属性**。

`raw-input-rate` 不在 media-kit 的类型化 API 里，所以第一眼看过去确实像「没暴露」；
但 `getProperty` 这道逃生门一直在，当时的方案表**漏掉了它**。

`raw-input-rate` 是 mpv 在**输入流**上测得的速率，单位就是字节/秒。
按 mpv 的属性语义（手册未在本仓留档，**当时此条属推理、未实测**），它统计的是播放器自身
从输入流收到的字节，直连与经本地代理的流量都计入，不是代理层的计数。
**这条计数口径后来被实测证实**（限速 ≈136 KB/s 的本地源读到 `"raw-input-rate":132086`），
原判断第 1 条担心的「只覆盖部分流量会误导」因此不成立——它统计的正是播放器真正收到的流量。
**但同一段里「它是属性」那半句不成立**：口径对、取数口子错，这是第一轮更正留下的疤。

第 2、3 条推理本身没错（PC 端确实没有引擎级字节计数器；下右确实先留空作接入点），
只是它们支持的结论被这个数据源推翻了。下右那一格因此从「后续接入点」变成真正渲染的一格。

**当时为什么会误判**：`raw-input-rate` 作为**键名**出现在 `demuxer-cache-state` 的 JSON 里，
所以在 `libmpv-2.dll` 的字符串表里能搜到。上一版把「字符串表里有这个串」当成了
「它是可读属性」，没跑一次 `mpv_get_property` 就下了结论。
**只做静态检查就断言 API 形状**是这条弯路的根因：字符串表里有名字，只说明它是某个字符串常量
（JSON 键名、日志格式、文档串），**不等于**它是可查询的属性。

**现在的事实**（与 §3.6.3 的实现逐行对应）：

| 接口 | 类型 | 实测返回 | 在本实现里的用途 |
| --- | --- | --- | --- |
| `demuxer-cache-state` | 属性（JSON 串） | `rc = 0`，串内含 `"raw-input-rate":132086` | **首选**：从这里解析速率 |
| `raw-input-rate`（单独查） | **不是属性** | `rc = -8` = `MPV_ERROR_PROPERTY_NOT_FOUND`；字符串模式返回 NULL | 不可用，只能从上一条里取 |
| `cache-speed` | 属性（double） | `rc = 0`，逐秒 `9072 → 72963 → 130786` | **回退**：首选解析不到时同一拍读 |

#### 3.6.3 现在的实现

| 环节 | 落地位置 | 事实 |
| --- | --- | --- |
| 数据源（**双源**） | `lib/ui/player_controller.dart` 的 `sampleNetworkRate()` | **首选** `getProperty('demuxer-cache-state')`（JSON 串）→ 解析其中的 `raw-input-rate` 字段；**首选解析不到才在下一行同一拍回退** `getProperty('cache-speed')`（double）。`raw-input-rate` 本身**不是属性**，单独查回 `-8` |
| 首选解析 | 同文件的纯函数 `parseRawInputRateFromCacheState(String?)` | 定向正则 `r'"raw-input-rate"\s*:\s*([^,}\s]+)'`；**键名须完整匹配**（`"raw-input-rate-foo"` 不算命中）；不做整体 JSON 解析（mpv 字段随版本增减，整体解析会因无关字段把有用的那个一起废掉） |
| 回退合成 | 同函数的纯函数 `resolveNetworkRate(double? primary, String? fallbackRaw)` | `primary ?? parseByteRate(fallbackRaw)`；抽成纯函数是为了让「回退顺序」能在单测里断言（`getProperty` 需要真引擎，测不了） |
| 解析（值） | 同文件的纯函数 `parseByteRate(String?)` | `null` / 空串 / `nan` / `inf` / 负数 / 非有限 → `null` |
| 格式化 | 同文件的纯函数 `formatByteRate(double?)` | `null` → `—`（长破折号）；否则 `12.8 MB/s` / `860 KB/s` / `512 B/s` |
| 采样时机 | `lib/ui/player_page.dart` 的 `_osdTimer` 回调 → `_sampleNetworkRate()` | 挂在**既有**的 1 秒屏显刷新循环上，**未新增 Timer** |
| 采样条件 | 同上 `_sampleNetworkRate()` | `traffic` 关着时直接 return，**连 mpv 属性都不读** |
| 渲染 | `lib/ui/player_osd.dart` 的 `_trafficVisible` 与底部一行 | 下右，与进度同一行，`formatByteRate(bytesPerSecond)` |
| 变更通知 | `PlayerController._setBytesPerSecond` | 值没变就不 `notifyListeners`（避免每秒一次无意义重建） |
| 设置项 | `lib/ui/diagnostics_pages.dart` | 7 项统一可点；`traffic` 副标题「取自播放引擎的网络输入速率；取不到时显示 —」（**不暴露属性名**：数据源是两个接口的组合，且上一版把其中一个名字写错了） |

**三条必须写清楚的口径**（都在代码注释里，别改回去）：

| 口径 | 理由 |
| --- | --- |
| **取不到显示 `—`，不是 0** | 0 会被读成「网速为零（卡了）」，而「没有这个数」是另一件事；这也顺带守住 `PRODUCT.md` 的「失败必须如实」 |
| **1000 进制，不是 1024** | 这是**网络吞吐**：链路的 MB/s 按 10^6 说，按 1024 算会让 8 Mbps 宽带显示成 `0.95 MB/s`，与运营商口径对不上 |
| **只在 `traffic` 开关打开时采样** | 关着还每秒读一次属性纯属浪费，也会把「屏显全关 → 停止刷新」的既有优化打回半残 |

还有两条实现纪律：

- **KB/s 不带小数、MB/s 保留一位**：mpv 自己就在抖，`860.3 KB/s` 的精度是假的；
  MB/s 那个量级下一位小数才肉眼可见地有意义。
- **解析与格式化都是纯函数**：`nan` / `inf` / 空串 / 负数这些形态要在单测里全覆盖，
  而 `getProperty` 需要真引擎。抽出来之后剩下的唯一不知情点就是「引擎给的是不是这个串」——
  这一点已在 §3.6.4 的运行时验证里落定（引擎给的确实是这个串）。

**与控制栏的联动**：控制栏可见时**强制隐藏**（与其余各项一致，见 §4.2）；控制栏隐藏时按开关。
**直播不隐藏**——直播恰恰是最需要看网速的场景（缓冲/掉帧时用户要判断是网络还是源），
所以 `traffic` 的判据只有「开关 + 控制栏」，不像进度与迷你条还要排除直播和 `duration <= 0`（`player_osd.dart` 的 `_trafficVisible`）。

#### 3.6.4 运行时验证与已知局限（原「未验证」一条已被推翻）

> **原先这里写的是「`raw-input-rate` 未做运行时验证」的已知局限。现在它已经不是局限了——
> 验证做完了，而验证结果把这个选型推翻了。** 原文保留在下方「被推翻的那条」里，
> 好让后来者看到「当时以为只差一步验证」和「验证后才发现连属性名都是错的」之间的差距。

**验证方法**：用 `dart:ffi` 直接加载 `apps/desktop-flutter/build/windows/x64/libmpv/libmpv-2.dll`，
不经过 media-kit——这样量到的是 mpv 本身的行为，不是某个包装层的实现细节。
建 mpv 实例、`mpv_initialize()`，喂一个**限速到 8192 B / 60ms（≈136 KB/s）的本地 HTTP 源**
（限速是为了让「读数对不对」可判：真实吞吐被钉在一个已知量级上），逐秒轮询下面五个探测点。

| 探测 | 实测结果 | 结论 |
| --- | --- | --- |
| `mpv_get_property('raw-input-rate', MPV_FORMAT_DOUBLE)` | **`rc = -8`** = `MPV_ERROR_PROPERTY_NOT_FOUND`；字符串模式返回 NULL | **它不是独立属性** |
| `mpv_get_property('cache-speed', MPV_FORMAT_DOUBLE)` | `rc = 0`，逐秒 `9072 → 72963 → 130786` | 可用，字节/秒；收敛值 130786 与限速 ≈136 KB/s 同一量级 → 口径正确 |
| `mpv_get_property_string('demuxer-cache-state')` | `rc = 0`，返回 JSON：`{"cache-end":5.85,…,"total-bytes":589296,"fw-bytes":309808,"raw-input-rate":132086,…}` | **可读**，且内含 `raw-input-rate` |
| 同上，起播头 ~1 秒 | 返回 **NULL** | 缓存建立前没有值 |
| `property-list`（827 个属性名） | 含 `cache-speed` / `demuxer-cache-state` / `demuxer-cache-time` / `cache-buffering-state` / `paused-for-cache`，**不含 `raw-input-rate`** | 再次确认它不是属性 |

**这次验证推翻了什么**：原实现直接 `getProperty('raw-input-rate')`。它永远拿空串 → `null` →
屏显永远显示 `—`（用户实测反馈「网速还是不显示」，症状与推断一致，但那不是「缓存没建立」，
而是**取数口子根本不存在**）。验证一做，`rc = -8` 立刻把这条路堵死。

**于是改成双数据源**（§3.6.3 的表逐行对应）：首选 `demuxer-cache-state` 里解析 `raw-input-rate` 字段，
解析不到才同一拍回退 `cache-speed`。**为什么还留着首选**：JSON 里的 `raw-input-rate` 与 `cache-speed`
是两个不同口径的量（前者是 demuxer 侧原始输入速率，后者是缓存填充速率），
首选能拿到时优先用它，拿不到不至于没数——但**不做跨拍拼接**，两个来源都在同一拍内定，避免屏显跳变。

**被推翻的那条（原文保留）**：

> 2. **`raw-input-rate` 未做运行时验证。** 已验证的是：编译通过；`parseByteRate` / `formatByteRate` 的单测
>    （`apps/desktop-flutter/test/phase8_buffer_and_traffic_test.dart`）；屏显渲染链路的 widget 测试
>    （`apps/desktop-flutter/test/phase8_osd_layer_test.dart`）；以及本机 `libmpv-2.dll` 字符串表扫描
>    （`raw-input-rate`、`demuxer-cache-state`、`cache-buffering-state` 三个属性名都在）。
>    **没有**在真实 libmpv 播放中跑过 `getProperty('raw-input-rate')` 并确认拿到非空数值——
>    这一步**未实测**。若不成立，界面显示 `—`：不崩溃、不显示 0。

> **已更正**：这段里「三个属性名都在字符串表里」被当成了「它是属性」的证据，**推理无效**——
> 字符串表里有名字只说明它是某个字符串常量。运行时验证的结果是 `rc = -8`，见上表。
> 「若不成立就显示 `—`」那条兜底**是对的**，也真的发生了；错的是兜底被当成了「只是待验证」，
> 而它其实已经是**实际状态**。

**已知局限**（重写后：原来第 2 条「未验证」已经不成立，见上）：

1. **只在桌面 `NativePlayer`（libmpv）上可用。** 平台不是 `NativePlayer` 时 `sampleNetworkRate` 直接返回 `null`，
   界面显示 `—`（不崩溃、不显示 0）。移动端/Web 构建没有这条取数路径。
2. **起播首秒短暂显示 `—` 是正常行为，不是缺陷。** 缓存建立前 `demuxer-cache-state` 返回 NULL
   （实测：起播头 ~1 秒为空），`cache-speed` 也还没有值，所以第一两拍如实给 `null`。
   下一拍就有数了；**不要**为了「首秒也有数」而伪造 0 或沿用上一集的值——那会把「没有这个数」说成「网速为零」。
3. **它是「最近一次采样的速率」，不是流量计。** 每 1 秒采一次、显示最新值，
   秒级跳变是正常的；不要拿它去对账累计流量或测速。

---

## 4. 与控制栏的联动

### 4.1 刷新周期

| 项 | 周期 | 理由 |
| --- | --- | --- |
| 时钟 | 1000ms | 对齐上游 |
| 进度（下左） | 1000ms | 对齐上游 |
| 诊断面板 | 1000ms | 对齐上游 |
| 迷你进度条 | **随 `controller` 通知**（约 250ms） | 2dp 的条按秒跳会显得卡顿；它已经在重建链上，无额外成本 |

**实现**：一个 `Timer.periodic(1s)` 驱动时钟/进度/诊断；
迷你条直接读 `controller.position`（`PlayerPage` 已 `setState`）。

**注意**：`PlayerPage._onControllerChanged` 已经 `setState`（`player_page.dart:348-357`），
屏显层作为其子节点会一起重建。因此屏显**不需要**自己订阅 controller——
只需要一个 1 秒 Timer 刷新"与播放无关"的部分（时钟、诊断采样）。

### 4.2 控制栏可见时的强制显示

对齐上游 `PlayerOsdController.java:208-220`：

| 屏显项 | 控制栏可见 | 控制栏隐藏 |
| --- | --- | --- |
| 上左 标题/分辨率 | **强制显示**（无视开关） | 按开关 |
| 上右 时钟 | **强制显示**（无视开关） | 按开关 |
| 下左 进度 | **强制隐藏** | 按开关 |
| 下右 网速 | **强制隐藏** | 按开关（**直播不隐藏**：直播最需要看网速，见 §3.6.3） |
| 诊断面板 | **强制隐藏** | 按开关 |
| 迷你进度条 | **强制隐藏** | 按开关 |

**为什么控制栏可见时要强制显示标题与时钟**：
PC 端的顶栏**有**标题（`AppBar.title`），所以标题不是必需的；
但**时钟**在控制栏里没有对应物，且"现在几点"是看片时的高频需求。

**PC 端的调整**：控制栏可见时**只强制显示时钟**，不强制显示标题
（因为顶栏已经显示了 `vodName · episodeName`，重复显示是噪音）。
这是与上游的**有意差异**，理由写在 `05` §7 的证据里。

### 4.3 屏显全关时的行为

开关全关 + 控制栏隐藏 → 屏显层**完全隐藏**，1 秒 Timer **停止**（不空转）。
对齐上游 `PlayerOsdController.java:222-228`（`return false` 停止重排）。

**但**：控制栏可见时必须重新启动 Timer（为了时钟）。
上游为此专门写了 `setControlsVisible` 里的特判（`PlayerOsdController.java:152-158`），
PC 端同样需要。

---

## 5. 开关与默认值

### 5.1 七项开关

| id | 中文名 | 默认 | 上游键名 |
| --- | --- | --- | --- |
| `title` | 标题 | **true** | `display_title` |
| `size` | 分辨率 | **true** | `display_size` |
| `time` | 时钟 | **true**（PC 新增默认开） | `display_time` |
| `progress` | 播放进度 | **true** | `display_progress` |
| `traffic` | 网速 | false（**已实现**，见 §3.6） | `display_traffic` |
| `mini` | 迷你进度条 | false | `display_mini` |
| `diagnostics` | 诊断面板 | false | `player_osd_diagnostics` |

**与上游的差异（用户已确认）**：上游 `time` 默认 false，PC 端默认 **true**。
理由：PC 是"坐在电脑前"的场景（`PRODUCT.md` §Users），时钟在任务栏之外
多一个来源不构成干扰；而全屏播放时任务栏不可见，时钟是真实需求。

**`traffic` 的处置**：开关**可点**（不再置灰），副标题写明数据来源
「取自播放引擎的网络输入速率；取不到时显示 —」。

副标题**不写属性名**：数据源是 `demuxer-cache-state` 内含的字段加 `cache-speed` 回退（§3.6），
对用户没有意义；而写一个具体属性名会把实现细节钉死在一个可能再变的名字上——
**上一版就写错过**（把 JSON 键名 `raw-input-rate` 写成了属性名，见 §3.6.4）。

**更正（后续变化）**：本节最初写的是「开关**存在但置灰**，副标题写明「本版本未采集网速」」，
理由是「**不得**让开关可点却无效果——那比没有开关更糟」（`DESIGN.md` 关于筛选按钮的同类教训：
「一个点了什么也没有的按钮比没有按钮更糟」）。

那条纪律**继续有效**，只是前提变了：能力已经落地（§3.6），再置灰等于把一个能用的功能藏起来。
所以现在的做法是「先有实现，再解锁开关」；将来若要停用某项，**先删能力再置灰**，别留一个点了没反应的开关。

### 5.2 持久化

落在 `settings.json` 的 `ui` 段，新增子键：

```json
{
  "ui": {
    "osd": {
      "title": true,
      "size": true,
      "time": true,
      "progress": true,
      "traffic": false,
      "mini": false,
      "diagnostics": false
    }
  }
}
```

**纪律**（沿用 `ui_preferences_store.dart:63-68` 的既有模式）：

| 纪律 | 理由 |
| --- | --- |
| **缺席 = 默认**，不把默认值固化进文件 | 与 `_themeMode` 同一理由：让"从未选过"与"选过默认值"可区分，也不污染既有设置文件 |
| 只接受合法布尔值，非法值回落默认 | 与 `themeMode` 的 `UiThemeMode.normalize` 同语义 |
| 写盘走 `writeSettingsSectionSync` + 串行队列 | 与既有 `_persist` 同一机制（`ui_preferences_store.dart:336-354`），避免与 `SyncState` 的并发写互相踩 |
| 只改 `ui` 段 | 读回时保留 `tmdb` / `sync` 段 |

**新增 API**（`UiPreferencesStore`）：

```dart
/// 生效的屏显开关（缺席项用默认值补齐）。
Map<String, bool> get osdEnabled;

/// 用户是否显式设置过任一屏显开关（决定要不要写盘）。
bool get hasExplicitOsd;

/// 记住单项屏显开关。
Future<bool> rememberOsdFlag(String id, bool enabled);
```

**归一化函数**（纯函数，可单测）：

```dart
/// 把任意输入归一化成完整的 7 项开关表；未知键忽略，缺失键用默认值。
Map<String, bool> normalizeOsdFlags(Object? raw);
```

---

## 6. 屏显与既有对话框的关系

现状有三个对话框承载同类信息（`player_page.dart`）：

| 现状 | 方法 | 本轮处置 |
| --- | --- | --- |
| 媒体信息（12 行表格） | `_showMediaInfo`（1732-1799） | **保留**，作为"完整信息"入口；屏显诊断面板是"快速一瞥" |
| 播放诊断（可复制的文本报告） | `_showDiagnostics`（1802-1833） | **保留**，因为它的核心价值是**复制粘贴**（`Clipboard.setData`），屏显面板做不到 |
| 快捷键说明 | `_showShortcutHelp`（1835-1859） | **保留**，迁入右键菜单（`04`） |

**为什么不全删**：三个对话框都有屏显无法替代的能力——
`_showMediaInfo` 是**结构化 12 行**（屏显面板只有 7 行，且要压字宽）、
`_showDiagnostics` 是**可复制文本**、`_showShortcutHelp` 是**完整快捷键表**。
屏显是**补充**，不是**替代**。

**去重纪律**：屏显面板与 `_showMediaInfo` 显示同一批数据时，
**必须调用同一个纯函数**取数据（见 `05` §3.4 的 `buildOsdDiagnostics`），
否则两处会漂移。

---

## 7. 验收清单

| # | 检查项 | 方式 |
| --- | --- | --- |
| B1 | 7 项开关默认值精确（`title/size/time/progress` = true） | L1 单测 |
| B2 | 归一化：未知键忽略、缺失键补默认、非法类型回落 | L1 单测 |
| B3 | 持久化往返：写入后重新 load 得到同一张表 | L2 单测（临时目录） |
| B4 | 缺席不写盘：从未设置过时 `settings.json` 里没有 `ui.osd` | L2 单测 |
| B5 | 控制栏可见 → 时钟强制显示、进度/迷你/诊断强制隐藏 | L2 widget 测试 |
| B6 | 屏显全关 + 控制栏隐藏 → 层隐藏且 Timer 停止 | L2 widget 测试（`activeTimerCount == 0`） |
| B7 | 直播（`directUrl=true`）→ 进度与迷你条隐藏 | L2 widget 测试 |
| B8 | `duration <= 0` → 进度项隐藏（不显示 `00:00 / 00:00`） | L2 widget 测试 |
| B9 | 屏显层 `IgnorePointer`：点击穿透到画面 | L2 widget 测试 |
| B10 | 屏显文本字号为 14（不来自 `textTheme`） | L1 源码/样式断言 |
| B11 | 诊断面板与 `_showMediaInfo` 用同一取数函数 | L1 单测（函数级） |
| B12 | `traffic` 开关**可点**、副标题写数据来源；下右渲染且 `null` 显示 `—` | L2 widget 测试 |
