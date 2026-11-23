---
name: WebHTV PC
description: 桌面播放器的「星等星表」视觉系统 —— 每一个站源是天上一颗星，星等就是它的实测成功率。
colors:
  # ---- 暗色（主身份）：深靛夜空底 + 三级色相偏移表面阶梯 ----
  night-ground: "#0B0E1A"
  night-surface-lowest: "#070911"
  night-surface-1: "#141A2E"
  night-surface-2: "#1B2238"
  night-surface-3: "#232C46"
  night-surface-highest: "#2C3654"
  night-ink: "#E8ECF7"
  night-ink-muted: "#A8B2CC"
  night-line: "#232C46"
  night-outline: "#3A4560"
  # ---- 亮色（昼间星表）：独立设计，不是暗色的反转 ----
  day-ground: "#F4F6FB"
  day-surface-1: "#FFFFFF"
  day-surface-2: "#EAEEF7"
  day-surface-3: "#DDE3F0"
  day-surface-highest: "#CBD4E6"
  day-ink: "#101427"
  day-ink-muted: "#4E5A75"
  day-line: "#D3DAE8"
  day-outline: "#97A3BC"
  # ---- 星等：唯一强调色 ----
  magnitude: "#F0B429"
  magnitude-on-light: "#8A5B00"
  magnitude-ink-dark: "#1A1200"
  magnitude-ink-light: "#FFFFFF"
  magnitude-container-dark: "#3A2A00"
  magnitude-container-light: "#FFE7B0"
  # ---- 语义状态色：站源健康（暗色底）----
  status-ok: "#3DD68C"
  status-degraded: "#F5A623"
  status-failed: "#F0526B"
  status-unknown: "#6B7A99"
  # ---- 语义状态色（亮色底：压深到 4.5:1）----
  status-ok-on-light: "#12734A"
  status-degraded-on-light: "#8A5300"
  status-failed-on-light: "#A3122C"
  status-unknown-on-light: "#4E5A75"
typography:
  display-small:
    fontFamily: "Microsoft YaHei UI, Microsoft YaHei, Noto Sans CJK SC, Source Han Sans SC, PingFang SC, Segoe UI, Roboto"
    fontSize: "36px"
    fontWeight: 700
    lineHeight: 1.22
    letterSpacing: "0px"
  headline-medium:
    fontFamily: "Microsoft YaHei UI, Microsoft YaHei, Noto Sans CJK SC, Source Han Sans SC, PingFang SC, Segoe UI, Roboto"
    fontSize: "28px"
    fontWeight: 700
    lineHeight: 1.29
    letterSpacing: "0px"
  headline-small:
    fontFamily: "Microsoft YaHei UI, Microsoft YaHei, Noto Sans CJK SC, Source Han Sans SC, PingFang SC, Segoe UI, Roboto"
    fontSize: "24px"
    fontWeight: 700
    lineHeight: 1.33
    letterSpacing: "0px"
  title-large:
    fontFamily: "Microsoft YaHei UI, Microsoft YaHei, Noto Sans CJK SC, Source Han Sans SC, PingFang SC, Segoe UI, Roboto"
    fontSize: "22px"
    fontWeight: 700
    lineHeight: 1.27
    letterSpacing: "0px"
  title-medium:
    fontFamily: "Microsoft YaHei UI, Microsoft YaHei, Noto Sans CJK SC, Source Han Sans SC, PingFang SC, Segoe UI, Roboto"
    fontSize: "16px"
    fontWeight: 700
    lineHeight: 1.5
    letterSpacing: "0.15px"
  title-small:
    fontFamily: "Microsoft YaHei UI, Microsoft YaHei, Noto Sans CJK SC, Source Han Sans SC, PingFang SC, Segoe UI, Roboto"
    fontSize: "14px"
    fontWeight: 700
    lineHeight: 1.43
    letterSpacing: "0.1px"
  body-large:
    fontFamily: "Microsoft YaHei UI, Microsoft YaHei, Noto Sans CJK SC, Source Han Sans SC, PingFang SC, Segoe UI, Roboto"
    fontSize: "16px"
    fontWeight: 400
    lineHeight: 1.5
    letterSpacing: "0.5px"
  body-medium:
    fontFamily: "Microsoft YaHei UI, Microsoft YaHei, Noto Sans CJK SC, Source Han Sans SC, PingFang SC, Segoe UI, Roboto"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.43
    letterSpacing: "0.25px"
  body-small:
    fontFamily: "Microsoft YaHei UI, Microsoft YaHei, Noto Sans CJK SC, Source Han Sans SC, PingFang SC, Segoe UI, Roboto"
    fontSize: "12px"
    fontWeight: 400
    lineHeight: 1.33
    letterSpacing: "0.4px"
  label-large:
    fontFamily: "Microsoft YaHei UI, Microsoft YaHei, Noto Sans CJK SC, Source Han Sans SC, PingFang SC, Segoe UI, Roboto"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.43
    letterSpacing: "0.1px"
  label-medium:
    fontFamily: "Microsoft YaHei UI, Microsoft YaHei, Noto Sans CJK SC, Source Han Sans SC, PingFang SC, Segoe UI, Roboto"
    fontSize: "12px"
    fontWeight: 400
    lineHeight: 1.33
    letterSpacing: "0.5px"
  label-small:
    fontFamily: "Microsoft YaHei UI, Microsoft YaHei, Noto Sans CJK SC, Source Han Sans SC, PingFang SC, Segoe UI, Roboto"
    fontSize: "11px"
    fontWeight: 400
    lineHeight: 1.45
    letterSpacing: "0.5px"
rounded:
  sm: "6px"
  md: "10px"
  lg: "14px"
  pill: "999px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "24px"
  xxl: "32px"
  huge: "48px"
components:
  button-filled:
    backgroundColor: "{colors.magnitude}"
    textColor: "{colors.magnitude-ink-dark}"
    typography: "{typography.label-large}"
    rounded: "{rounded.md}"
    padding: "11px 18px"
    height: "42px"
  button-outlined:
    textColor: "{colors.night-ink}"
    typography: "{typography.label-large}"
    rounded: "{rounded.md}"
    padding: "10px 16px"
    height: "42px"
  button-text:
    textColor: "{colors.night-ink-muted}"
    typography: "{typography.label-large}"
    rounded: "{rounded.sm}"
  input-text:
    backgroundColor: "{colors.night-surface-2}"
    textColor: "{colors.night-ink}"
    rounded: "{rounded.md}"
    padding: "12px 14px"
  card:
    backgroundColor: "{colors.night-surface-1}"
    rounded: "{rounded.lg}"
    padding: "16px"
  chip-tag:
    backgroundColor: "{colors.night-surface-highest}"
    textColor: "{colors.night-ink}"
    typography: "{typography.body-small}"
    rounded: "{rounded.pill}"
    padding: "5px 11px"
  navigation-rail:
    backgroundColor: "{colors.night-surface-lowest}"
    textColor: "{colors.night-ink-muted}"
    width: "76px"
  dialog:
    backgroundColor: "{colors.night-surface-3}"
    textColor: "{colors.night-ink}"
    rounded: "{rounded.lg}"
    padding: "24px"
  source-field:
    backgroundColor: "{colors.night-surface-1}"
    rounded: "{rounded.lg}"
    padding: "16px"
---

# Design System: WebHTV PC

## Overview

**Creative North Star: "星等星表 (The Magnitude Catalogue)"**

星等星表把天文星表与星等标度借来做一件具体的事：让「这个站源现在还能不能用」成为**可读、可核查**的信息。每一个站源是天上一颗星，**星等就是它的实测成功率**——点越大越亮，颜色是健康状态。产品对外只承诺「单个站源能否使用以实际测试为准」，所以界面不可以用一个绿点或一排空位去暗示「全都能播」；它必须把实测结果如实画出来，**包括「没测过」这一态**。

本表面明确拒绝的类别默认排布是「深色海报墙 + 顶部主视觉横幅」：那会把「哪个源能用」沉到二级页面里去，而海报墙本身也无法表达健康度。密度是刻意的：源场画的是配置里的**真实全量站源**（实测有 163 个），不是三个装饰点。第一版把点画成 5–14px，实测截图里整片场缩成左上角一条 50px 的带子，读起来像附注而不是 signature move（正是方向卡自陈的风险：「点阵场一旦画得太小或太稀，就退化成装饰」）。现在点径 7–22px，一片场才有「场」的样子。

**源场的位置（实测修正）**：初版把源场放在**首页内容区第一块**，理由是「先回答哪个源能用，再谈看什么」。真实配置推翻了这个前提：实测 170 个站源里 **160 个没有采样记录**，整片场基本是灰点——既没有信息量，又占掉首屏近三分之一高度，把海报内容挤了下去（用户反馈 2026-10-12）。因此源场移到**独立页面** `SiteHealthPage`，从设置页进入；**点播页**回到「分类条 + 海报网格」的纯粹内容职责。（2026-11-19 追加：首屏从「点播」改成新的**首页**——hero + 续播/推荐轨道。这不是把源场搬回来：源场体检仍是独立页；变的只是第一屏回答的问题，从「挑一个分类」变成「今晚看什么」。详见 `docs/adr/0011-home-is-the-first-screen.md`。）这个世界的签名招式没有消失，它只是从「每次都撞见」变成「要看的时候就在」——**对全量站源做体检是诊断动作，不是每次打开应用都要做的动作**。

暗色是主身份；亮色是**独立设计的「昼间星表」**，不是暗色的自动反转——亮色底上的星等与四个状态色都换成压深版本，因为原色在浅底上达不到 4.5:1。

**Key Characteristics:**

- 深靛夜空底 + 三级色相偏移的表面阶梯；**没有任何中性灰**。
- 单一强调色：星等琥珀，只出现在真正是「星等」的地方。
- 四个语义状态色承担真实工作（站源健康是本产品的核心信息）。
- 平坦的场：发丝边代替阴影，全站 elevation 一律为 0。
- 中文优先：字重只用真实存在的 400 / 700，层级靠字号与颜色拉开。
- 数字用表格字形，且只在数字成列处启用。

## Colors

一片深靛的夜空，一颗琥珀色的星，四种如实的状态色。调色策略是 **Committed**：底色占满整个表面，强调色极稀有。

### Primary

- **星等琥珀 Magnitude Amber** (#F0B429)：唯一强调色。只用在真正是「星等」的地方——源场里的基准星环、当前剧集、选中态（NavigationRail 选中图标、Chip 选中底、Slider 活动轨、进度条、光标与选区）。它的稀有就是它的力量。
- **昼间星等 Magnitude on Light** (#8A5B00)：同一个角色在亮色底上的版本。亮色底上原色对比度不足，因此压深，而不是把琥珀直接搬过去。
- **星等墨 Magnitude Ink** (#1A1200 暗 / #FFFFFF 亮)：填充琥珀面上的文字色。
- **星等容器 Magnitude Container** (#3A2A00 暗 / #FFE7B0 亮)：静态强调标签的底（`TagChip` 的 `emphasized`）。

### Semantic Status

这四个颜色**承担真实工作**，不是装饰：站源健康是本产品最核心的信息，而 Material 3 的 `ColorScheme` 里没有这个角色（塞进 `tertiary` 会造成语义漂移），所以它们挂在 `AppSemanticColors` 这个 `ThemeExtension` 上。颜色只从扩展里取，**任何组件不得写死状态色**。

- **可用 Available** (#3DD68C)：成功率 ≥ 0.8。
- **降级 Degraded** (#F5A623)：有采样但成功率偏低（间歇超时一类）。
- **失效 Failed** (#F0526B)：一次都没成功，或运行时不支持——两者都是「确实用不了」。同时兼任 `ColorScheme.error`。
- **未知 Unknown** (#6B7A99)：**没有采样记录**。它单独一态，绝不并入「可用」。
- **亮色底压深版**：#12734A / #8A5300 / #A3122C / #4E5A75。亮色不是把暗色反转，这四个值是为了在浅底上达到 4.5:1 而重新取的。

### Neutral

没有中性灰——每个「灰」都从底色色相染出，灰色会从这个世界里掉出来。

- **夜空底 Night Ground** (#0B0E1A)：暗色主题的 `surface`，也是壁纸纱的染色来源。
- **表面阶梯 Night Surface Ladder** (#141A2E / #1B2238 / #232C46)：`surfaceContainerLow` / `surfaceContainer` / `surfaceContainerHigh`。三级都是**从底色按色相偏移**出来的，不是灰色梯度；卡片、输入框、对话框、列表选中态各占一级。
- **阶梯端点** (#070911 / #2C3654)：`surfaceContainerLowest` 给顶栏与侧栏（外壳比内容低一档），`surfaceContainerHighest` 给 tooltip、未选中开关轨、滑轨底色。
- **星表墨 Night Ink** (#E8ECF7)：正文与标题。
- **染色副文本 Night Ink Muted** (#A8B2CC)：次要信息靠**颜色**降级，不靠字重（因为雅黑没有可用的中间字重）。
- **发丝线 Hairline** (#232C46 暗 / #D3DAE8 亮)：`outlineVariant`，实际以 0.72 不透明度使用，是全站唯一的分隔手段。
- **轮廓 Outline** (#3A4560 暗 / #97A3BC 亮)：比发丝线更重的一档，用于输入框聚焦前的可辨边界。
- **昼间星表 Day Ladder** (#F4F6FB / #FFFFFF / #EAEEF7 / #DDE3F0 / #CBD4E6)：亮色的底与三级表面。
- **昼间墨 Day Ink** (#101427 / #4E5A75)。

### Named Rules

**The One Accent Rule.** 星等琥珀只出现在真正是「星等」的地方：基准星环、当前剧集、选中态。它不是品牌色，不可以用来「提亮」任何东西。当你想给它找第二个用途时，答案是不给。

**The Never-Grey Rule.** 禁止中性灰。副文本、发丝线、表面阶梯全部从夜空底色按色相偏移取得。需要一个新的层级时，**偏移底色**，不要加一档灰。

**The Unknown-Is-Not-Available Rule.** 「未知」有它自己的颜色、自己的图例计数、自己的星等（最小中性尺寸）。没有采样记录的源永远不可以被算进「可用」，也不可以借用「可用」的绿色。对外只承诺「以实测为准」，界面必须守同一条线。

**The Explicit-Color Rule.** 状态色只能经 `context.semanticColors` 取得。`AppSemanticColors` 在扩展缺失时**按当前亮度回落到默认值，而不是抛异常**——测试大量用裸 `MaterialApp(home: ...)`（不传 `theme:`）pump 单个页面，此时扩展根本不存在，一个用 `!` 硬断言的取色器会让所有页面级测试直接崩掉。

### Open Items

- 亮色主题里 `surfaceContainerLowest` 与 `surfaceContainerLow` **同为 #FFFFFF**（顶栏与卡片同色），所以亮色的阶梯实际上少了一级，分隔完全依赖发丝线。这是待复核项，不是已确认的设计决定（见 `lib/ui/theme.dart` 亮色分支）。

## Typography

**Display Font:** 中文优先的系统无衬线回退链 —— `Microsoft YaHei UI → Microsoft YaHei → Noto Sans CJK SC → Source Han Sans SC → PingFang SC → Segoe UI → Roboto`（Windows 用雅黑，Linux 用 Noto CJK，macOS 用苹方；缺少字体时不得出现方块字）。

**Body Font:** 同上。这是**单一字族**系统，没有第二支展示字体。

**数字字形:** 表格数字（`FontFeature.tabularFigures()`），通过 `tabular(style)` 帮助函数逐处套用。

**Character:** 层级完全靠**字号与颜色**拉开，不靠字重。星表上的数字（星等、集数、时长、站点计数）用表格字形对齐成列，读起来像一张表；中文正文保持常规字重，避免中文夹数字时的松散感。

### Hierarchy

字号与行高**全部是 Flutter Material 3 (2021) 的基线值，本仓库不自带任何字号**；`theme.dart` 只覆写字重（见 `_textTheme`）。字重映射成四档：

- **Display**（700，36/28/24px）：页面级大标题。`displaySmall` / `headlineMedium` / `headlineSmall`。
- **Title**（700，22/16/14px）：区块标题、卡片标题、侧栏选中标签。`titleLarge` / `titleMedium` / `titleSmall`。
- **Body**（400，16/14/12px）：正文、次要文本、标签文字。`bodyLarge` / `bodyMedium` / `bodySmall`。
- **Label**（400，14/12/11px）：按钮文字、图例、版本号。`labelLarge` / `labelMedium` / `labelSmall`。

例外（不在阶梯上，属实测取值）：`NavigationRail` 的标签字号是 **11.5px**，选中 700 / 未选中 400。

### Named Rules

**The Real-Weight Rule.** 字重只用 400 与 700。微软雅黑只有 Light(300) / Regular(400) / Bold(700) 三个真实字重，**没有真 Medium**：改造前全站 18 处拿 `w600`、4 处拿 `w500` 当标题字重，在雅黑上不是真实字重，会走**合成加粗**（笔画粘连、小字号发糊），在 Linux/macOS 上又落到另一支字体、观感不一致。因此标题统一映射到真实存在的 `w700`，正文与标签用 `w400`。**永远不要为了「稍微强调一点」而使用 500 或 600。**

**The Metric-Neutral Rule.** 字号与行高保持 Material 3 原值，只改字重与颜色。这是**实测出来的硬约束，不是保守**：测试大量使用 `tester.tap` **不带 `ensureVisible`**（例如 `phase5_sync_ui_test.dart:210`）——本次复核磁盘上 94 个 `*_test.dart`（69 单测 + 24 集成 + 1 driver）里有 **44 个**出现 `.tap(`，而只有 **2 个**出现 `ensureVisible`（`theme.dart` 与方向契约记录的盘点是「96 个测试文件」）。任何净高度变化都会把控件挤出 800×600 测试视口，点击打空并连锁失败。实测把 `bodySmall` 行高从 M3 的 1.33 提到 1.65，`phase5_sync_ui_test.dart` 会挂 3 个用例；还原 `theme.dart` 后该文件全绿（+26）。而**字重是度量中性的**——同一字族的 Light/Regular/Bold 字宽一致，所以 `w600 → w700` 不移动任何盒子，却修掉了合成加粗。这正是本次拿到的收益，且零布局风险。

**The Tabular-Only-Where-Aligned Rule.** 表格字形只用在**数字成列**的地方（星等图例计数、时长、集数）。不给正文全局开启——中文夹数字时等宽字形会显得松散。

### Open Items

- **中文行高改进被测试约束挡住。** 「中文需要更大行高」这一改进（例如 `bodySmall` 1.33 → 1.65）是**已知的未完成项**，需要单独一轮连同测试的 `ensureVisible` 一起改，不能夹在主题层里悄悄改。已同步记录在 `.impeccable/surfaces/lib-ui-app-dart.md` 的「未决」。

## Layout

外壳是**顶栏 + 侧栏 + 内容区**的三段结构，尺寸都由构建决定：

- **侧栏**：`NavigationRail`，`minWidth: 76px`，`labelType: all`，`groupAlignment: -0.9`，**8 项**，`scrollable: true`。背景是阶梯最低一级 (#070911)，世界只把**选中态**染成星等琥珀。
  **顺序即枚举顺序**：`ShellSection` 的值顺序与 `destinations` 一一对应（`selectedIndex` 直接取 `section.index`）。第 1 项是**首页**（首屏），第 2 项是**点播**（按站点浏览，原「首页」只改名）。
  **侧栏只放看片链路 + 设置**（2026-11-22 用户决策，11 → 8 项）：首页 / 点播 / 直播 / 搜索 / 最近观看 / 收藏 / 追剧 / 设置。Spider 运行时、日志与 AI·阅读器不是又一个「要看什么」，而是「怎么把它弄好」——一律进设置的六个分类，任何设置仍最多两级可达（设置 → 类 → 行）。Spider 运行时与日志落在「维护」（`settings-spider-open` / `settings-logs-open`），AI·阅读器落在「连接与服务」（`settings-ai-business-open` 本来就在，撤掉侧栏入口不丢功能：上下文入口实测有四处——搜索页的 AI 按钮、最近观看页「观影报告」旁的 AI 按钮（`history-ai-business`）、日志页「AI 日志诊断」、播放器右键；详情页的季集 AI 走的是「AI 助手」，两跳可达）。
  **为什么要 `scrollable`（2026-11-19 实测）**：`minimumSize` 1024×640 下顶栏吃掉 64px、内容区只剩 576px，**10 项时就已经溢出 8px**（默认窗口 1280×800 撞不到，所以一直没被发现），加到 11 项溢出 72px。8 项已放得下，但保留可滚动当兜底——导航的信息架构不该被一屏的高度决定。
- **顶栏**：`height: 64px`，水平内边距 `AppSpace.xl` (24px)。承载品牌标记、配置名与导入、选站、版本号。背景同为阶梯最低一级，靠一条 0.55 不透明度的发丝线与内容分隔——**与内容同底，不靠 elevation**。
- **窗口最小尺寸**：`Size(1024, 640)`。桌面键鼠是唯一输入假设。
- **横向条用鼠标拖**：剧集卡片、剧照/海报、演职人员、相关推荐、线路/区间/季度 chip 条，都包一层 `HorizontalMouseDrag`（`apps/desktop-flutter/lib/ui/scroll_behavior.dart`）。Flutter 默认 `dragDevices` 不含鼠标，不包的话横向条用鼠标拖不动（用户反馈 2026-10-20）。**只包横向条、不挂全局**：全局启用会抢走 `SelectableText` 的文字选中与排序手柄（实测）。
- **首页（观测台）**：hero 高度**分两档**（`homeHeroHeight`）——有 16:9 背景图时**占满内容区**（夹 360–1000，这就是「全屏大海报」，上限是为了超宽屏下让第一条轨道露出标题），没有背景图时收到 62%（夹 360–640，占满一屏的纯渐变只是一块空）。其余轨道靠滚动出现。
  **整页固定海报**（2026-11-20）：参照详情页，16:9 背景在页面底层 `Positioned.fill` 中固定铺满内容区；hero 文案与轨道在其上正常滚动，向下滚动后仍看得到海报。背景与 hero 共用轮播下标及 8 秒节奏，不另起定时器；使用共用的 `page` 遮罩保持正文可读、不把底部压成纯色。只有竖版海报时仍保留夜空 hero，不把竖图拉宽。顶栏、侧栏不变，标题与播放按钮不吸顶。
  **卡片同宽**：所有轨道统一用 `LayoutScale.cardWidth`（曾经推荐卡是 0.86 倍，那是详情页的规矩；首页一屏只有横向条，窄一档只会看起来没对齐）。
  **逐张预载**：hero 在首帧把本轮所有幻灯片的图 `precacheImage` 一遍（与 `PosterImage` 同一套 headers 规则），切换是解码而不是下载——原先切到哪张才开始加载。
  **主/次按钮分工**：主按钮 = 续播（切回记录自己的站点再起播）；次按钮「查看详情」= **进详情页**，并优先用这条记录自己的播放源（先切站点，带着线路/集/进度进去，`history_entry_detail.dart`——历史页的整卡点击与首页共用这一份实现）。按钮上写详情就不能起播。**推荐类单独分工**（2026-11-21 修订）：「查看详情」与推荐轨道卡片打开的是**与点播页推荐卡同一条规则**的详情（`core/recommendation_target.dart` + `ui/recommendation_detail_route.dart`）：先在当前选中站点按标题快搜一次，命中就进该站点的真实详情页（可直接播放），没命中或搜索失败才退成**导航源回退页**——同一部作品的 TMDB 剧集卡片 + 换源 + 状态条上的「重新匹配」。没有再单独造一个「纯 TMDB 页」入口：那种页面没有线路、没有可播身份，也没有「重新匹配」，进去只能看元数据（用户 2026-11-21 反馈「没有播放源也应该是导航站的详情页那种效果」）。没有 TMDB 身份时仍只展示已有推荐资料；没有选中站点时按标题搜索站源，不伪造可播放身份。「去找片源」进入带片名和已有身份提示的站源搜索，并自动搜索。两者都不能退回当前站点点播列表。
  **轨道内的信息**：hero 有 TMDB 身份的条目带**两行简介**（随取图那次 `detail()` 一起回来，不额外请求）；追剧轨道按最新一集的**真实播出时间**只保留近 48 小时内更新的（查不到播出时间就保留，不因第三方缺席而藏轨道）。
  **首屏 12 张**：hero 取「追剧有更新 ≤3 + 未看完续播 ≤6 + 个性推荐 ≤3」；**首次使用**（三者全空）时兜底用**热门三榜轮流**的前 12 条，于是第一次打开看到的就是一组真实海报轮播，而不是一块只会说「还没有内容」的渐变。
  **hero 的手动切张（2026-11-22）**：原先只有右下角 6px 指示点，用户反馈「很难才点到」。现在是四条路：① 贴边左右 44×44 箭头（视觉圆底 44、Material 撑到 48 命中框，垂直居中、常驻 0.55 不透明度，左右两端回卷）；② 指示点视觉仍是 6px，但命中区包到 **24×24**（WCAG 2.2 2.5.8 的下限），当前点画成 18×6 胶囊、悬停 350ms 出片名——12 张时靠等大圆点根本数不出「在第几张」；③ 整块 hero 横向拖/甩（位移 ≥60 或速度 ≥300，向左 = 下一张）；④ 键盘 ←/→（原有）。**箭头不进 Tab 序**（`ExcludeFocus`）：hero 的键盘语义已经是 ←/→，再让 Tab 落在箭头上，Enter 会被 hero 的按键处理先吃掉当主操作。指针停在箭头或指示点上也**停表**——原先只有内容块停表，8 秒一到画面在「正在瞄」的那一下被抽走，是「点不到」体感的一半来源。**不做滚轮切张**：hero 整屏高，吃掉滚轮等于用户在首屏再也滚不下去看轨道。
  **轨道构成**：本机轨道（继续观看 / 追剧更新 / 个性推荐）+ **热门轨道**（热门电影 / 热门剧集 / 热门综艺，来自 360kan 榜单，与搜索页同一份数据与缓存）。热门**总是出现**（即使用户有历史），只去掉与本机条目重名的，避免同一部片在首屏出现两次。热门卡片单击与轮播主按钮 = **查看作品详情**：点击时按标题查询 TMDB，电影榜只匹配电影，剧集／综艺榜只匹配剧集；唯一同名作品进入与推荐同一套站点解析的详情页（命中 → 站点真实详情页；未命中 → 导航源回退页），歧义候选由用户选择。长按／右键保留榜单信息，并同时提供「查看详情」「去找片源」；轮播次按钮也是「去找片源」（`SearchPage.initialKeyword` 自动搜索）。无匹配、断网或未配置时显示可恢复说明，不伪造身份；首页不新增播放解析链。
  **元数据统一走一处**：`services/home_art_service.dart`（`HomeMetaService`）按 TMDB 身份取**一次** `detail`，从中同时得到 2:3 海报 / 16:9 背景 / 简介 / **类型标签（≤3）** / 年份 / 评分，口径与详情页完全一致（`TmdbImageSelector` + `genres` + `release_date|first_air_date` + `vote_average`）。`tmdb.detail` 命中磁盘缓存时不发请求；取不到才保留站点海报与站点文案。**不按标题去 TMDB 搜一遍**——那是 N 次请求，首屏付不起。
  hero 的内容顺序：标题 → 副信息（站源优先，站源没给才用 TMDB 年份·评分）→ **类型标签（静态 `TagChip`，与详情页同一套）** → 两行简介 → 理由行 → 主/次按钮。没有数据的行整行不画，不留空占位。
  **hero 的两种形态**（不要发明第三种）：① 有 16:9 背景图（TMDB backdrop）→ 满幅 `cover` 铺开，这是唯一能当「大海报」用的素材；② 只有站点竖版海报（2:3）→ **夜空渐变底 + 左侧一张大而锐利的海报**（约 hero 高的 52%，夹 160–320，按显示尺寸 `cacheWidth` 解码）。**禁止把 2:3 海报拉成宽幅**：1271 宽从 300px 的海报放大就是糊的，加模糊「氛围底」只会让人以为在加载（用户 2026-11-19 反馈「基本看不清」）。遮罩与详情页共用 `ui/backdrop_scrim.dart`（hero 底部压到不透明、page 轻而均匀）。轨道卡宽走 `LayoutScale`（海报 195 × 档位、推荐 168 × 档位 = 0.86），高度一律「海报 2:3 + 40px 文字区」由宽度推。**hero 只放已经在你手上的（续播 / 追剧更新），推荐只在轨道**：推荐是异步后到的，驱逐会打断阅读。
- **壁纸**：配置提供的 `wallpaper` 铺在内容区（顶栏与侧栏保持实底，保证导航在任何壁纸上都清晰），之上永远压一层由底色染出的纱：暗色 `nightGround @ 0.86`、亮色 `dayGround @ 0.90`；承载正文的卡片用强纱 0.94 / 0.96 以保证 4.5:1。**纱的不透明度是设计决定，不是图片的属性**——壁纸深浅不可预知，内容必须始终可读。

**间距标度**（4 的倍数，收敛前散出 16 个间距值）：

| Token | 值 | 用途 |
|---|---|---|
| `xs` | 4px | 图标与文字之间的贴合间距 |
| `sm` | 8px | 同一组内的行间距 |
| `md` | 12px | 组内的常规间距 |
| `lg` | 16px | 卡片内边距、区块内的标准间距 |
| `xl` | 24px | 区块之间的分隔 |
| `xxl` | 32px | 页面级留白 |
| `huge` | 48px | 空状态与页面顶部的呼吸区 |

**内容网格**：海报墙按可用宽度动态定列数与列宽，再由列宽推出格子高度——这样任何窗口宽度下海报都能保持精确的 2:3（固定格子高度会在窗口变窄时把海报压成非 2:3 或被裁切）。网格内边距 16px、海报下方文字区高 40px（不随密度档缩小）、预取范围 700px。

**热门推荐的铺满方式（2026-11-18）**：上面那条是「先定列宽、再推格子高」，适合会滚动的海报墙；搜索页的热门推荐不滚动，**一屏就是它的全部**，所以反过来算——先按**可用高**数行，再把高度摊成卡高（`HotRankLayout.resolve`）。行按**最省卡高 194**（海报下限 150 + 间隙 4 + 文字区下限 40）数出「一屏最多几行」；卡高 = clamp((可用高 − (行数−1) × 12) / 行数, 0, 274)。海报高跟着卡高走，但夹在 150–210：**210 是硬上限**（140 × 210 恰好 2:3，与上面的固定比例同一条纪律），凑不出整行时因此会在底部留白——这是预期，不许把海报拉过 2:3 去「填满」。文字区 = 卡高 − 4 − 海报高，够 56 给两行片名、够 36 给一行、再窄不画（宁可少字也不溢出）。「换一批」按「屏上没摆下的条目」判断（池子比一屏多才换得出新内容）。

**先凑整行，再摊高（2026-11-18 第二版）**：候选池能排成整行时优先「精确铺满」——行数 r 取 [⌈(H + 12) / 286⌉, 按最省卡高数出的行数]，列数取 `min(按宽度能放的最大列数, 池子 ÷ r)`，要求 `列 × r ≤ 池子`（整行、不留半行）；多个解按「卡高最接近理想 254」→ 条数多 → 列数多 取舍（这些解都填满高度，卡片越接近 254 观感越统一；反过来条数优先会在超宽屏上把海报压到 160 去多摆几条）。列数可以**下探**，但视觉列缝（格子宽 − 140 + 12）必须 ≤ **48**（`maxColumnGap`），否则同一行会散成一张张孤零零的海报；凑不出整行就退回上面的「按宽度铺满 + 摊高」。实测：用户全屏 1920×1080（网格 1811×673）按 11 列排 30 条只能 2 整行 = 22 条、底部空 113px，换成 **10 列 × 3 行 = 30 条**、卡高 216.33、海报 172.33，底部一格不空；默认窗口（网格 1167×483）仍是 **7 列 × 2 行 = 14 条**、卡高 235.5（本机复刻 1164×453 → 14 条、卡高 220.5）；1280×600 无精确候选 → 8 列 × 2 行 = 16 条、卡高 274（海报 210 截顶）；2451×1072 + 池子 300 → 16 列 × 4 行 = 64 条（5 行虽能摆 80 条，但卡高会被压到 204.8、海报只剩 160.8）。**这里的坑**：行数若按理想卡高 254 数，483 只够 1 行——用户当时看到的正是 7 张 + 底部 200 多像素空白。

**密度档（`LayoutScale`）**：卡片目标宽 = 195px × 档位，列间距 = 12px × 档位。档位由**窗口短边**决定（短边 / 900，夹在 0.95–1.35，量化到 0.05）——短边近似「眼睛到屏幕的距离」，宽度只决定列数。实测：默认窗口 1280×800 → 档 0.95、目标宽 185（海报 6 列 × 198）；1920×1080 → 档 1.2、目标宽 234；2560×1440 及以上 → 档 1.35、目标宽 263。

同一条标度还管两处横向条：**选集卡 = 1.25 × 海报宽（封顶 300px）**——详情页的主操作入口要比海报重一档；**推荐卡 = 168px × 档位（2:3）**。两者都按 2:3 / 16:9 由宽度推高度，不做写死的 180 / 218。

列数由「目标宽 × 0.92」反推上限，**实际列宽不得低于目标的 92%**——原实现用 12 列硬上限，于是 1920 宽（144px）反而比 1366 宽（154px）的卡更小。

**两条反模式**：① 只放大卡片宽度、不放大高度——剧照高度必须 = 卡宽 × 9/16，否则卡越宽剧照越扁（写死 110px 时，150 宽正好 16:9，300 宽就成了 2.7:1）；② 用视口宽度做连续缩放——超宽屏会得到巨卡，小窗口会把字挤爆。字号与行高不参与任何缩放（见 Metric-Neutral Rule）。

**区块节奏**：`SectionHeader` 上方 `AppSpace.xl` (24px)、下方 10px。**标题上方的留白大于下方**，这是层级最省力的来源（原实现只有 `bottom: 8`、上方为零，整页读起来是平的）。

**区块间隔只有一个来源**（2026-11-11 收敛）：区块之间**不加**额外的 `SizedBox`，间隔全部由 `SectionHeader` 的 24px 上留白承担；边界线是 `Divider(height: 1)` 的 1px 发丝线，**不占高度**。收敛前是 `Divider(height: 32)`（上下各 16）加上推荐行尾巴的 `SizedBox(16)`，与标题的 24 叠加成 40——同一页里并存 24 与 40 两种间隔，看上去就是「有的地方很大、有的很小」（用户反馈 2026-11-11）。

### Open Items

**已落地（本轮复核后从欠账里移出）：**

- **表单页最大内容宽度** —— 已实施 `formPagePadding`（900px 居中内容列），作用于设置 / 配置 / TMDB 设置三页。落地前按 A/B 方法验证：基线 5 次 pass 分布 `26,26,26,25,26`，改动后 `26,26,25,26,25`——**分布重叠**，此前单次跑到的 `+19 -7` 是离群值，不是该改动造成的。
- **配置页层级倒置** —— 已实施：输入框从"吃掉整窗剩余空间"（1440×900 下约 270px）改为固定 180px；「选择本地文件 / 使用仓库 fixture」从「配置名称」那一行移到**导入按钮同一行**，读起来是「导入（从文件 / 从 fixture / 从上面的内容）」。
- **Spider 页区块空态** —— 已实施：两处裸 `Text` 改用新增的 `SectionEmpty`（区块级：一行说明 + 16px 图标、左对齐、不居中不占满）。与整页级的 `EmptyState` 分工写在 `common.dart`。
- **换源列表行稀疏** —— 已实施：对话框 640×480 → 760×560，列表改**两列网格**（48px 行），滚动距离砍半；行渲染抽成 `_siteRow`。

**仍未做：**

- ~~**`AppMotion` 的 `fast` / `slow` / `emphasized` 无调用点。**~~ 原记载：「只有 `base` 与 `ease` 有（源场换源时选中环的过渡）。其余三个是常规档位，留着备用……它们只是**声明**，不是既成事实」。**2026-11-20 更正**：`fast` 实测 4 处（`lib/ui/async_action_feedback.dart:104`、`lib/ui/browse_pages.dart:1034`、`lib/ui/player_page.dart:4633`、`lib/ui/app_motion.dart:58`）、`slow` 1 处（`lib/ui/app_motion.dart:54`），`base` 7 处、`ease` 10 处；`lib/ui/app_motion.dart:28` 的 `AppMotionScope` 还统一按 `reducedMotion` 门控。仅 `emphasized`（`lib/ui/tokens.dart:91`）仍无调用点。
- **`t4_sweep_flow_test` 仍红。** 已用 `git worktree` 检出干净 HEAD 证明**同一个用例在 HEAD 上也失败**（预先存在），但**根因未查**。
- **筛选面板的观感未验证。** 面板渲染在 `Navigator` 的 `Overlay` 里，本项目的截图 harness 取的是 `Scaffold` 那层的 `RepaintBoundary`，**拍不到浮层**。面板内容由断言保证（打开后 `剧情` / `地区` 必须出现），但"看起来对不对"只能靠人眼在真机上确认。
- **同类「周期定时器 + `pumpAndSettle`」写法可能还在别处。** `live_danmaku_flow_test` 已修（10 分钟超时 → 11 秒），但改的时候要按**状态条件**等待而不是等"界面安静"。
- ~~**首页 hero 超过 6 张时只有 6px 指示点。**~~ **2026-11-22 收口**：指示点命中区加到 24×24、当前点改胶囊并带片名 Tooltip，另补贴边箭头与横向拖拽（规格见上面「hero 的手动切张」）。**缩略图条仍未做**，理由写在 `docs/phase11/design/02-home-feed-contract.md` §10。取证：`.local/home-scroll/hero-chrome-{before,after}-{backdrop,poster}.png`（`HOME_HERO_CAPTURE_STAGE=… flutter test test/home_hero_chrome_visual_test.dart`）。
- **首页视觉取证只有 After。** `test/home_visual_capture_test.dart`（`HOME_CAPTURE=1`）把两张 PNG 写到 `.impeccable/review/`；改动前的点播页首屏没有同条件重拍，所以「Before/After 同视口对照」这件事还欠一次（本机无显示环境，需在能跑 integration_test 的机器上补）。
- **本机跑全量 `flutter test` 会假失败。** `/tmp` 是 2.2G tmpfs、内存 4G，默认并发 10 会因 `No space left on device` 让 tester 被杀、runner 静默挂住（不报错）。跑全量请用 `TMPDIR=/var/tmp flutter test --concurrency=3`；player 相关约 309 个用例在本机缺 `libmpv` 必红（CI 装了 `libmpv-dev`）。


## Elevation & Depth

**这套系统不用阴影。** 全站 `elevation: 0`（顶栏 `scrolledUnderElevation: 0` 亦然），`surfaceTintColor` 一律 `Colors.transparent`。

深度完全由**色调阶梯 + 发丝边**表达：外壳（顶栏、侧栏）落在阶梯最低一级，内容卡片落在 `surfaceContainerLow`，输入框与标签底落在 `surfaceContainer`，对话框、SnackBar、弹出菜单落在 `surfaceContainerHigh`。层级差来自**表面本身的明度**，加上一条 0.72 不透明度的发丝边。

这不是省略，是世界的必然：星等星表是**一片平坦的场**，阴影堆叠会把点阵场的平度破坏掉。

### Named Rules

**The Flat-Field Rule.** 不使用阴影，不使用 `surfaceTint`。需要层级时，移动到表面阶梯的下一级，或加一条发丝边。

**The Hairline Rule.** 分隔一律用 `outlineVariant @ 0.72`。发丝线是全站唯一的分隔语言——不用灰色、不用更粗的线、不用背景色块去「框住」东西。

**The Zero-Elevation Rule.** 新组件若需要「浮起来」，先问它是不是真的需要浮起来。对话框与菜单浮起来靠的是**更亮的表面**，不是投影。

## Shapes

圆角标度只有四级（收敛前散出 11 个圆角值，其中 8 是事实上的默认）：

| Token | 值 | 用途 |
|---|---|---|
| `sm` | 6px | 内联元素：标签、徽标、错误横幅、图标按钮、tooltip |
| `md` | 10px | 常规容器：卡片、输入框、按钮、列表项、弹出菜单 |
| `lg` | 14px | 大容器：海报框、面板、对话框、源场 |
| `pill` | 999px | 胶囊：标签、徽标一类「两端全圆」的形状 |

**形状语言**：几乎没有直角——`sm`/`md`/`lg` 三级圆角覆盖了所有容器，可点标签一律走胶囊。底部面板只圆上方两角（`Radius.circular(14)` 的 vertical 变体）。滚动条圆角 5px、厚 9px。

**固定比例**是这个世界的一条纪律（借自 `challenger-botanical-folio` 的「固定比例可比」）：海报 2:3、剧照 16:9，全站共用同一比例与尺度，源与源、集与集之间才可直接比较。测试断言这些比例（海报 ±0.05、剧照 ±0.1）。

## Components

整体性格是**精确、平坦、信息优先**：控件保持平台标准（Material 3），世界只借走字体、配色、密度与一个 signature move。控件不重写形状与交互模型。

### Buttons

- **Shape:** 常规容器圆角 (10px)；文字按钮用内联圆角 (6px)。
- **Primary (`FilledButton`):** 底色星等琥珀、文字星等墨，最小高度 42px，内边距 `11px 18px`，文字用 `labelLarge` 但**字重提到 700**（按钮文字是唯一被允许加重的一般文字）。
- **Secondary (`OutlinedButton`):** 无底色，前景 `onSurface`，1px 发丝边，最小高度 42px，内边距 `10px 16px`，文字 `labelLarge` (400)。剧集卡就是 `OutlinedButton`——这是测试锁死的结构，不可替换。
- **Text / Icon:** 文字按钮前景用 `onSurfaceVariant`（靠颜色降级），内边距走默认，圆角 6px。图标按钮的按下底色是 `primary @ 0.10`。
- **Hover / Focus:** 全站交互态从调色板取色，不用框架默认的黑/白叠加——`focusColor` = `primary @ 0.16`，`hoverColor` = `onSurface @ 0.045`，`splashColor` = `primary @ 0.09`，`highlightColor` = `primary @ 0.06`。这些都是非布局属性。

### Chips

两套并存，各有明确职责：

- **`TagChip`（应用自己的组件）:** 胶囊形，按 `selectable` **分两种语义**——这是本组件最容易搞错的地方：
  - **可选控件**（筛选 chip、站点分组）：未选中底**透明**，选中底 `primary @ 0.22`（暗）/ `0.12`（亮），hover 底 `primary @ 0.10`（暗）/ `0.06`（亮）。未选中用透明而非填充色——筛选条有十几个维度、上百个 chip，全部填色会糊成一片，选中项反而淹没。
    **禁用（`onTap == null`）时整体降到 0.5 透明度，但选中态必须照常渲染。** 禁用只降低强调，**不能抹掉状态**。初版把 `onTap == null` 一律当成静态标签，于是筛选请求在途时整排 chip 掉进静态分支：选中态被抹掉、`InkWell` 也没了，一排长得一模一样且点不动（用户反馈 2026-10-11「全是选中状态，点击没反应」）。
  - **静态标签**（详情页年份/时长）：底 `surfaceContainerHighest`，强调态 `primaryContainer`，不可点、无 `InkWell`。
  文字 `bodySmall`，选中时字重 `700`、颜色 `primary`。内边距 `5px 11px`，图标 14px。它替换了三套圆角写死 14、内边距 11/5、12/6、10/4 各不相同的私有实现。
- **`ChipTheme`（Material `ChoiceChip` / `FilterChip`）:** 未选中底 `surfaceContainer`，选中底 `primary @ 0.18`，1px 发丝边，胶囊形，`showCheckmark: false`，文字 `labelLarge`。线路 chip 就是 `ChoiceChip`——同样测试锁死。

### Player control bars

播放器有**三层浮层**，**职责不重叠**——这是核心规则（一个动作只有一个家）：

- **顶栏（`AppBar`，在浮层里）＝ 轨道与窗口。** 标题 + 字幕轨 + 弹幕开关 + 「更多」溢出菜单。溢出菜单的判据是**「右键之外还有没有别的入口」**（不是使用频率），现为五项：字幕样式、弹幕设置、画面比例与缩放、媒体信息、快捷键说明。音轨/视频轨/循环与定时/LUT 滤镜/播放诊断已归右键菜单分组或设置页日志页，**不得**再加回溢出菜单（集成测试有反向锁）。
- **底部控制条（同一浮层）＝ 传输与显示。** 进度行（等宽时间 + 滑块），下面按分组排布、组间用**发丝竖线**分隔：传输 │ 音量 │ 速率与选集 │ 显示。按钮的顺序与可见性**由用户配置**（设置 → 播放器按钮，或右键菜单 → 控制栏按钮…）。切线路并入选集面板，控制条上不再有独立的线路下拉。
- **屏显层（`IgnorePointer`）＝ 关于播放的事实。** 四角：上左标题/分辨率、上右时钟、下左进度、下右网速（**已实现**，双数据源：`demuxer-cache-state` 内解析 `raw-input-rate` 字段、解析不到回退 `cache-speed`，取不到显示 `—` 而不是 0）；顶部诊断面板；底部 2dp 迷你进度条。7 项开关，默认开 `标题/分辨率/时钟/播放进度`。
- **右键菜单（页内 `Stack` 层）＝ 快速访问。** 按 PotPlayer 的功能域分**十组**、支持**飞出式子列**（三层路径 7 条）：播放 / 速度 / 字幕 / 画面 / 声音 / 轨道 / 显示 / 片头片尾 / 信息 / 设置。它**不是唯一入口**——每一项都有顶栏菜单、控制栏、设置页或快捷键的等价路径。
  **它是鼠标独占的吗？不是。** `Shift+F10` / 菜单键 / `F10` 都能在画面中央打开它。这一条是**硬要求**：菜单里有一批项（音轨、视频轨、标记片头片尾）没有其它入口，没有键盘入口就等于把它们对键盘用户藏起来。
  **LUT 例外，而且是三层分工的样板**：右键 `画面 → LUT 滤镜` 是**飞出子列**（关闭 / 13 个内置 / 更多 LUT…），因为切换是即时生效的、属于「边看边调」；导入、删除与在线搜索塞不进 240px 子列，归「更多 LUT…」打开的底部面板；设置侧另有等价的**三级明细页**（设置 → 播放 → LUT 滤镜），负责同一套管理动作。三处共用 `LutPresetBrowser`，不得各写一份。
  **飞出式多列而不是就地展开**：就地展开每层要缩进一次，240px 主列到第 3 层只剩约 140px 可读宽度；而 `design/04` §4.4 的 10 组结构要求至少 4 条三层路径。子列右缘不足时翻到父列左侧，竖直越界则上移并在列内滚动——每列独立 `clamp`，整块永远落在窗口内。

**画面点击是传输控制，不是显隐控制。** 单击画面 = 暂停/播放，双击 = 全屏/退出全屏（桌面播放器惯例，PotPlayer / VLC 同）；控制栏由**指针移动**唤醒、静止 3 秒自动隐藏。上游安卓那套「单击显隐控制栏」是为触屏定的，桌面端不复用。双击判定由页面自己做（`PlayerDoubleClickGate`），**不用** `GestureDetector.onDoubleTap`——注册它会把单击拖慢一个约 300ms 的判定窗，点一下暂停会明显迟滞。

**三层都不参与布局。** 它们都是 `Stack` 的 `Positioned` 子项，与画面平级。控制栏显隐**不得**改变视频区尺寸——这是 2026-10-18 修复的缺陷（用户反馈「每次唤醒控制台都会导致画面缩放」）：改造前控制条是 `Column` 的兄弟节点，`Expanded` 分配剩余高度，控制条一出现画面就按 `BoxFit.contain` 重新居中。

**为什么顶栏与底栏必须分开：** 初版两条栏有 **5 个动作重复**（字幕轨、字幕样式、弹幕设置、画面比例、媒体信息），加上各自十几个同尺寸图标，用户扫视时找不到落点（用户反馈 2026-10-11「图标也处理吧」「接着处理底部控制条」）。分组依据是**使用时机**，不是功能相似度。

**不要动的约束：** 顶栏的字幕轨与弹幕开关的 `tooltip` 被集成测试按**精确串**查找并直接 `tap`（`subtitle_flow_test.dart:144,153`、`danmaku_flow_test.dart:156,175`）。`find.byTooltip` 对 String 是**精确匹配**（只有 `RegExp` 才做子串，见 flutter_test `finders.dart:407`），所以这两个控件**不能**被收进溢出菜单，也**不能**加入可配置按钮集合——收进去测试就点空了。

**播放器内的「弹幕设置」是四页签弹层。** 右键 `弹幕 → 弹幕设置…` 与顶栏 `更多 → 弹幕设置` 共用 `_openDanmakuQuickSettings()`，先开「显示 / 时间 / 轨道 / 弹幕源」（`lib/ui/danmaku_settings_sheet.dart`）。用户原意是**弹幕地址显示**：「弹幕源」列出本集的弹幕资源地址，标出当前项、载入条数与失败原因；顶部当前弹幕摘要可点击直达该页签。不同地址须可区分，选择状态不能冒充加载或连接成功。弹幕库的**接口地址**单独只读展示，搜索与完整设置页仍有入口；多源接口的增删改留在 `DanmakuSettingsPage`，不与本集资源地址混为一谈。原三个显示页签及 12 个显示项保留、改动即时生效，入口标签与顶栏弹幕开关不变。

**顶栏必须保留 `AppBar` widget 类型：** `ui_redesign_visual_flow_test.dart:677-681` 用 `find.descendant(of: find.byType(AppBar), matching: find.byTooltip('更多'))` 断言「更多」按钮的位置。换成自绘 `Row` 会让那条断言找不到东西。

**播放器页恒定暗色。** `PlayerPage.build` 内部包一层 `buildAppTheme(Brightness.dark)`。理由：播放器背景是**视频帧**、不是应用底色，主题给的浅色 surface 会让浮层文字对比度崩掉。用户的亮色主题作用于**应用外壳**，不作用于播放器——VLC / mpv / PotPlayer / Netflix 全屏播放器都如此。

### Player OSD（屏显）

屏显是**独立于控制栏的一层**，不占布局、不接收指针（`IgnorePointer`）。

- **四角**：上左标题/分辨率（最多 2 行）、上右时钟、下左进度、下右网速（**已实现**；经本地代理播放时按**当前会话实收上游字节 / 真实间隔**计算——mpv 的 `raw-input-rate` 在跳转缓冲期间会整段停在旧值，见 `docs/phase8/design/02-osd.md` §3.6；直连播放回退 mpv：`demuxer-cache-state` 内解析 `raw-input-rate`，解析不到回退 `cache-speed`；取不到显示 `—` 而不是 0；起播首秒短暂 `—` 是正常行为）。
- **诊断面板**：主列（视频/音频/网络/状态/播放/来源）+ 附加列（运行环境/窗口/主题/本地代理）。宽 0.98 视口、高上限 0.84 视口（上游同）。字号 10px、等宽字体。
- **迷你进度条**：底部 2dp，颜色星等琥珀（The One Accent Rule 明确把「进度条」列为琥珀的合法用途）。
- **文本**：字号**显式指定 14**（不改 `textTheme`——The Metric-Neutral Rule）、`tabular` 表格字形（每秒刷新不抖动）、**黑描边**（背景是任意视频帧，纯白字在亮画面上不可读；上游同做法）。
- **内边距**：`AppSpace.lg`（16px），不是上游的 14dp——14 会成为全站第 17 个间距值。
- **与控制栏的联动**：控制栏可见时**只强制显示时钟**，并强制隐藏进度/网速/诊断/迷你条。屏显全关且控制栏隐藏时，整层隐藏；若仍在加载/缓冲，保留共用的 1 秒刷新循环，为圈下网速采样，加载/缓冲结束后**停止**。
- **与上游的差异**：时钟默认**开**（上游关）；网速**已实现**（原文「PC 无字节级吞吐量、只覆盖代理流量会误导」的前提已被证伪）；控制栏可见时**不强制显示标题**（PC 顶栏已有）。三条都记录在 `docs/phase8/design/05-test-and-acceptance.md` §7。

### Backdrop（详情页背景图）

**单层 `cover` 铺满 + 渐变遮罩**（用户选型 2026-10-13）。Emby / Jellyfin / Netflix 同做法。

**为什么是这个**：背景图的框比几乎永远与素材不同形，几何上只有三条路——

| | 结果 |
|---|---|
| `cover` | 填满、无空隙；裁切，但裁边是照片式的自然结果 |
| `contain` + 模糊垫底 | 不裁；但锐利图与背景**缩放比不同**，交界处必然有一道**消不掉的竖直硬边** |
| `contain` + 纯底色 | 不裁；两侧是干净的"信箱框"，但图只占部分宽度 |

中间那条我试过并被否决：即使把色洗调对，那道竖直硬边也消不掉。

**裁切变小的真正原因是图片框变大了，不是换了 `fit`。** 图片框 = **整个视口高度**（`TmdbBackdropSlideshow.height`）。16:9 窗口只裁约 7%，2.35:1 窗口裁约 24%——而当初被投诉的那一版是 3.07:1 的横带，**裁掉约 42%**，把人的头顶从脸中间切掉。同一个 `cover`，框比不同，观感完全不同。

**裁切重心取顶部**（`PosterImage.alignment: Alignment.topCenter`，2026-10-23）：窗口比素材更宽时 `cover` 必然纵向裁切，居中裁＝上下各切一半，人物头顶最容易被切（用户反馈「同一个海报背景全屏的时候被截取了不好看」）。顶部对齐把裁切**全部**落在下方——下方本来就被渐变遮罩压到不透明、被标题/简介盖住，观感损失最小。注意 `alignment` 只转发给 `Image.network`，**不能**改成 `Container(alignment:)`（那会外包 `Align` 给松约束、`cover` 直接失效，见下面那条坑）。

**已知取舍：** 首屏唯一可见的是 hero（图片框 = 整屏高，正文从第二屏开始）。简介长度由内容区剩余高度决定——极长文本仍在末尾省略，但不再有「查看简介」按钮；要读全的罕见长文属于正文区块的事，不是首屏 hero 的事。

### 详情页 hero 组成（2026-10-22 细化，2026-10-23 贴底修正）

首屏是一条**整屏背景 + 左下内容块**的 hero：海报 150×225、标题/原名/标语、标签行（**平台** / 年份 / 时长 / 季集 / 类型 / 地区 / **语言** / 状态）、简介、播放入口。

- **内容块贴视口底部**：左 24 / 上 24 / 右 24 内边距，底部固定 **44**（给轮播指示点让位）。窗口与全屏走同一条规则——内容块底边距视口底边始终 ≤ 44，不会再出现「内容停在中间、下面空一条背景」。
  - 演变：2026-10-22 先把内容从 54% 下移到 80%（用户反馈「移下来会不会更好？这么大一块地方简介都显示不全」），但 80% 是**内容带**的底、不是视口底，于是下面还空着 20% 背景——用户 2026-10-23 反馈「位置不对，预期应该是靠近底部，包括全屏的时候」。**内容带这个概念已整体退场**（`TmdbDetailHeader.resolveHeight` / `TmdbBackdropSlideshow.contentBand` / `_bandOffset` 均已删除）：图片框多大，内容的落点就是它的底部，两者不再各算各的。
- **简介直接完整显示**：行数由内容区剩余高度反推（不是写死 3 行），不再有「查看简介」按钮与对话框。
- **导演不进 hero**：那一行让给简介；导演由下方「制作团队」区块承载（带头像与「导演」职务）。
- **语言进标签、信息表退场**：`备注` 按反馈移除，`语言` 成为第 8 个标签（宽屏上限 **9**、窄屏 **6**，见下条）；详情页不再渲染 `TmdbInfoTable`。
- **播放平台排第一**（2026-11-18 用户澄清后定稿）：标签行首个 chip 是「播放平台」，图标 `Icons.live_tv_outlined`、key `tmdb-detail-platform`，静态不可点。口径由 `core/playback_platform.dart` 统一（详情页 hero 与追剧日历共用）：平台**只取 TMDB `networks`**（腾讯视频 / 爱奇艺 / CCTV-8 / HBO 这类播出平台），**不是**爬虫站源或站点名——用户 2026-11-18 用日历截图指出过站源名是错的。台名不随语言本地化，因此 `networkDisplayNamesZh` 给常见平台一份显示层中文对照（`Tencent Video`→腾讯视频、`iQIYI`→爱奇艺、`Youku`→优酷、`Hunan TV`→湖南卫视…），未收录的原样显示；去重后最多两个以 ` / ` 连接，没有台名则整块不渲染。只有剧集响应带 `networks`，**电影不显示这个标签**。为此上限从宽屏 8 / 窄屏 5 提到 **宽屏 9 / 窄屏 6**：新增的 chip 不能再把「状态」挤出宽屏。
- **追剧日历的平台徽标完整显示、不省略**（2026-11-18 用户反馈：截图里被截成 `Hunan Television / …`，而卡片右侧本来就空着一大块）：徽标不再套 132 宽上限，宽度由台名本身决定；主行的剧名组用 `Flexible` 而非 `Expanded`，空间不够时先挤压剧名，不让平台被截断。只有连台名都放不下的极端窄窗口才会退化成省略号。
- **列表卡里同一个数字只出现一次**（2026-11-18 真机截图反馈：「24 集未看」pill、本线路可播 24 集、官方共 24 集、未看 24 集 四份重复）：未看集数只在标题右侧的 pill 出现；通知状态用短文案（开 / 关（本条）/ 关（全局））。
- **官方总集数永远显示，不能因为「和线路一样」就省掉**（2026-11-18 用户澄清：线路更新不及时或断更时，官方集数是唯一的真实口径）：官方已知时集数行是「官方共 N 集」，线路与之不同时是「本线路可播 X 集 · 官方共 N 集」，官方未知时退回「本线路可播 X 集」。判断在 `FollowingAirData.episodeLabelFor`（可单测）。
- **日历的「选中日没有更新」是固定条，不是浮层**（2026-11-18 真机截图反馈：浮层把列表第一条卡啃掉一半）：它渲染在日历区与列表之间，占自己的高度，测试断言 `hint.bottom <= list.top`。
- **同一个平台徽标在追剧页两个视角都出现**（2026-11-18 合并后的补丁，用户要求"两边对齐"）：抽成 `ui/following_badge.dart` 的 `FollowingBadge`（字号 11、容器色底、药丸圆角，`emphasized` 只区分"待用户注意"），日历条目与列表卡都只用这一个组件。列表卡把它放在**标签行首位**（沿用「播放平台排第一」的口径，key `following-platform-<identityKey>`），没有台名时整块不渲染、不留空位；数据来自同一个 `ui/following_air_data.dart`，因此列表视角不需要先点开日历才有平台名。

**踩过的坑（两层方案为什么会"看起来像坏了"）：** `PosterImage` 是 `Container(color: surfaceContainerLow, child: Image)`——那个 `Container` 会**撑满父级紧约束并铺一层不透明底色**。叠在 `Stack` 里时，上层会把下层**整块盖住**。实测：设计的"模糊延伸"**从来没有渲染过**，屏幕上只有一块纯色信箱边 + 硬边图片。当时全绿的测试只断言了两层各自的 `fit`，**断言不到"谁盖住了谁"**——这是"参数对 ≠ 看得见"的典型。`PosterImage.background` 就是为此加的开关。

**怎么验证的：** fixture 的 `wide*` 路径返回 **16:9 且上下带红/蓝标记带**的图（`tools/fixture_server/server.py` 的 `_send_wide_backdrop`）。原来 fixture 全是 1:1 方图，**截图里根本看不出裁没裁**；有了标记带，「顶带或底带缺了就是被裁了」变成肉眼可判的事实。

**验证纪律（这条比上面的技术结论更重要）：** 上一轮我只在 1440×900（1.6:1）出图就交付，用户窗口是 **2.35:1**，问题在那一档才暴露。**背景/铺满类改动必须在多个宽高比各出一张图**（1.6:1 / 2.0:1 / 2.35:1），不能拿一个形状交差。

### 详情页评分与外部链接（2026-11-11）

评分与外链是**两件不同的事**，位置也分开（用户决策 2026-11-11）：

**评分 = 简介正上方的一行静态标签。** 与 TMDB 分同一套 `TagChip`（强调底色
`primaryContainer`、星标 `primary`、胶囊圆角、`5px 11px` 内边距），顺序固定
**TMDB → 豆瓣 → IMDb → 烂番茄 → Metacritic**（顺序在 `core/detail_ratings.dart` 的枚举里定，
UI 不重排——安卓两处实现曾各自排过一遍，同一部片子出现两种顺序）。

- **不可点、无外链图标**：这一行的职责是「这部片子口碑如何」，不是导航。混进跳站动作会让
  一个纯信息行变成半套按钮，用户还得分辨哪几个能点。
- **有的才显示，没分不占位**：没拿到、`N/A`、或超出该来源量程的分值（如 IMDb 11.2）整条不出现。
  占位的「豆瓣 —」会让一行标签在加载完成后跳动。
- **为什么在简介上方**：评分是读完简介前最想知道的定性信息；放在简介之后就得先读文字。
  同时它**不进 hero 的元信息标签行**——那行放「本片是什么」（年份/时长/类型），
  混入可变第三方数据会让一行承担两种语义，而且多一行会把标题挤出内容带（那条坑修过两次）。
- **TMDB 分只出现一次**：它从元信息标签行移到了这一行，不两边都写。
- **品牌写法集中在 `RatingBrand`**：`TMDB` / `IMDb` 等名称在 `core/detail_ratings.dart` 定义一次，界面一律取常量。这两处在历史上出现过 `TMDb` / `Imdb` 的变体，散在多处拼接时无法保证一致。

**外链 = 页面最底部的一段描边按钮。** 五个站名同样取自 `RatingBrand`。 `外部链接` 区块在普通推荐行之后，
每站一个 `OutlinedButton.icon`（无底色、`onSurface`、1px 发丝边、`open_in_new` 图标），
**只写站名，不再重复分值**。

- **为什么不与评分同排**：同一平台名在相邻两行各出现一次时，用户无法判断该点哪一行；
  位置分开后语义也清晰——上面读口碑，下面才离开本站。
- **打不开浏览器时复制链接兜底**（桌面端没有浏览器的场景真实存在），提示「已复制链接」。
- **顺序仍与评分一致**，五个站点固定，不按有无分数重排。

**加载与失败：** 两处共用**一次**查询（`DetailRatingsScope`），页面只发一轮请求；
豆瓣那 750ms 的限速间隔在页面关闭时**主动取消**（否则 `flutter_test` 会判
「A Timer is still pending」，推荐行踩过同一个坑）。评分失败只在评分行留空，
外链照常可用——它们是静态链接，不需要等网络。

### 详情页短评与星级评分（2026-11-22）

用户反馈 2026-11-22：「评论的评分得仔细找文本，一眼看不出高低」。短评的分数从元信息里的
一段 `8.0/10` 改成**豆瓣式的五颗星**，元信息不再重复写分数。

- **每条短评三层，全部左对齐**：星级行 → 正文 → `作者 · N 有用 · 日期`。
  星级行**独占一行**：元信息是长短不一的灰字，星星挂在里面会忽左忽右；独占一行后
  每条的星星都从同一个 x 起算，纵向连起来就是一张评分表，扫一眼就能比出高低。
- **10 分制 → 半星步进**：`core/external_detail_meta.dart` 的
  `ExternalComment.ratingHalfStars` 把 `rating / maxRating × 10` 四舍五入成 `0..10`
  的半星步进（一步 = 半颗星），UI 只按这个数摆图标
  （`star_rounded` / `star_half_rounded` / `star_outline_rounded`，15px）。
  豆瓣原生是 5 分制，归一后 `4/5` 是 `★★★★☆`、`3.5/5` 是 `★★★⯨☆`。
- **实心星用星等琥珀，空心星用 `outline`**：琥珀是「已经拿到的那部分星」，半星的左半
  也是实心；空心星只是满格 5 颗的刻度，不能去抢正文的注意力。
- **分数写在星级右侧、表格字形**：`tabular()` 让 `10.0 / 8.0 / 6.0` 同宽，数字列不抖；
  中文不套表格字形（`Tabular-Only-Where-Aligned` 规则）。
- **未评分占一行、写「未评分」，不画空心星**：画满格空星会被读成「0 星 / 很差」，
  缺行又会让同页的正文起点上下错开。前者与 `Unknown-Is-Not-Available` 是同一条线。
  步进是半星，所以低于半颗星（`0.25/5` 以下）会落到 0 星、显示「未评分」；豆瓣短评给的是
  整档分值，实际取不到这一档——真接第二家评论源时要回头把「有分但不足半星」与「没有分」分开。
- **可访问性**：每条评分行只暴露一句「豆瓣评分 8.0 分（满分 10）」，星形
  `ExcludeSemantics`——否则读屏会把一行念成五声「star」。
- **渲染从 `browse_pages.dart` 搬到 `ui/detail_comments_section.dart`**：
  纯数据 → 视图的映射，不该为了改版式就得拉起整页状态；`_buildExternalComments`
  从此只把四个字段递过去。
- **门禁**：`test/detail_comments_rating_test.dart`（星型序列 / 分数文案 / 成列 / 未评分 /
  既有徽标与分页行为）与 `test/detail_comments_capture_test.dart`（同 fixture、同视口、
  同主题的 Before/After 截图；`COMMENT_CAPTURE_PHASE` 非空时才落图）。

### 详情页 AI 推荐行（2026-11-12 恢复）

底部推荐区是**一行一种来源**，AI 排最后：猜你喜欢 → 个性推荐·TMDB → 个性推荐·豆瓣 → **AI 推荐**。

- **位置**：推荐区最下方、外链之前。它和上面三行是同一类东西（横向海报条），
  所以不能另起一个小节，也不能插到评分/外链之后。
- **样式只有一套**：同一个 `SectionHeader`、130 宽海报卡、两行文字（片名 + 年份·类型·评分），
  行高取自 `detailRecommendationRowHeight`，与其它行同源。
- **交互只有一套**：点击走调用方同一个回调——有 TMDB 身份开作品详情，没有就按标题搜站源；
  长按/右键打开同样的「关闭 / 不感兴趣」弹窗，不感兴趣写入 90 天负反馈并从本行移除。
  卡面上不再单独放「不感兴趣」角标（那是 AI 行独有的第二套交互）。
- **生成策略**：进页面先只读缓存（不联网、不花 token），输入指纹不一致或过期才后台刷新一次；
  刷新失败保留旧内容并提示。未配置 AI 时整块不渲染、不请求。
- **演变**：2026-11-12 的 `51fbf9c` 以「收敛详情页入口」为由连 AI 推荐一起删掉；
  同日用户要求恢复，并明确「放在推荐区最下方、与现有推荐统一风格和点击交互」。

**长按 / 右键详情弹窗：所有推荐行共用一套（2026-11-12）。** 实现是
`ui/recommendation_info_dialog.dart` 的 `showRecommendationInfo`，四行推荐都走它，
不再各写一个 AlertDialog。

- **只展示已经拿到的数据**：海报、来源胶囊、年份/类型/评分胶囊、数据状态
  （`TMDB #1234` / `仅元数据（未匹配 TMDB）`）、简介、推荐理由、演职员（有才显示）。
  弹窗里不发起任何额外查询——没有的字段直接不显示。
- **「详情」是主按钮**（`FilledButton`）：关闭弹窗后调用与推荐卡片单击**完全相同**的
  回调（有 TMDB 身份开作品详情，否则按标题搜站源）；「关闭」是次按钮；
  「不感兴趣」只写 90 天负反馈并移除该卡。
- **版式**：720 宽上限、82% 屏高上限，正文内部滚动；海报用 `PosterImage`、
  圆角用 `AppRadius`，与详情页其它卡片同一套 token。
- **左边缘只有一条**：简介、推荐理由、底部「不感兴趣」的文字都从内容左边缘起排。
  推荐理由是普通小节（不套底色块、不加装饰图标）；「不感兴趣」是文字按钮的例外——
  去掉默认横向内边距（`padding: zero`）才能对齐，这与「文字按钮内边距走默认」的
  通用规则冲突，是有意为之（用户 2026-11-12 反馈「没和简介对齐，是因为都放了图标吗」）。

### 详情页季度入口（2026-11-11 收敛）

季度区**只有一个改绑入口**：chip 条（多季）+「选择季度」按钮（开季度对话框）。

- 原先是三个控件并存——「第 N 季 ▾」下拉按钮、chip 条，以及未确定季度时额外的「选择季度」按钮；下拉按钮与「选择季度」点下去是同一个对话框，用户要先分辨点哪个。
- **切季点 chip（一步）**，需要手动改绑才点「选择季度」。
- 单季没有 chip 条（一个 chip 的「切换」没有意义），改用一行文字说明当前季度；改绑按钮仍常驻——它是唯一入口，不能跟着按钮一起消失。
- **行高不变**（`tmdbSeasonSelectorHeight`）：换成文字后行高仍锁在 48px，避免季度区高度随季数跳动。
- **站点详情页的这一行 2026-11-12 退场**：它与状态条右侧的入口点下去是同一个对话框，却多占一整行（见下节）。纯 TMDB 详情页仍保留这一行。

### 详情页区块节奏与去分隔线（2026-11-12）

用户反馈的三件事其实是同一条毛病：**页面被画成了几段，而不是一条节奏**。

- **季度不再独占一行**：站点详情页原来在状态条下面还有一行「当前季度：第 N 季 … 选择季度」，
  它与状态条右侧的入口点下去是**同一个对话框**。现在整行退场，「第几季」写进状态条
  （`TMDB · 剧名 · 第 2 季`；季度未确定时写 `· 季度待定`，不能装作季度不存在），
  切季仍走那个按钮（文案改为「切换季度」，且**不再**要求已选中某季——未确定季度
  恰恰最需要手动改绑）。
  状态条同时**不再显示评分**：评分已经在简介上方的评分标签行里，同一屏写两遍只是噪音。
  这条约定由纯函数 `tmdbStatusSummary` 的**签名**锁住——它没有评分参数。
- **区块之间没有分隔线**：深色底上一条 `Divider` 就是一条亮线，「季度 / 线路」「选集 / 剧照」
  「推荐 / 外部链接」都被切成两段，读起来像内容被撕开。三条线全部删除。
- **区块间距只有一种**：由下一个区块的 `SectionHeader`（上 24 / 下 10）承担，
  区块自己**不再**补 `SizedBox`。改之前每段都自带一条 24，于是「内容 → 下一区块头」是 48，
  而「选集 → 剧照」是 0；漏加与重复加都发生过，这就是「间距乱七八糟」的来源。
  - 线路 → 选集也是 24：线路的内容是它自己的 chip 行，选集是下一个区块；
  - 选集 → 剧照 → 海报 → 演职人员 → 制作团队 → 相关视频 → 猜你喜欢 → 外部链接全部 24；
  - 相关视频的 `Card` 默认 `margin: 4`（会左右各缩 4px、卡片之间也没有稳定的缝），
    改成 0 并由列表显式给 8。
  - **区块头里的小按钮高度锁 24**（`_HeaderToggle`）：「正序 / 列表」默认带 48 的
    点击区，会把整行撑到 48；标题被垂直居中后上下各多出 12，于是「选集」到区间条/
    卡片的缝是 22 而不是 10——这是用户说的「这部分的间距和其他的不一样」。
    桌面端鼠标点击 24 高足够，行高一致更要紧。
  - **四个区块头切换按钮同一套语义**（2026-11-21）：标签与图标只表达**当前状态**
    （`正序` / `倒序`、`网格` / `列表`），**点下去会做什么写进 `Tooltip`**。
    改之前「视图」这一对图标画的是目标状态、文字写的是当前状态，也没有 Tooltip，
    用户只能把它当成两个不知道是什么的裸按钮（用户 2026-11-21 截图反馈）。
  - **区间条到卡片曾凭空多 56px**：垂直、无 controller 的 `GridView` 是 **primary**
    滚动视图，会把 `MediaQuery.padding` 当成自己的内边距。详情页挂在 AppBar 下，
    `padding.top = 56`，于是「1-20 / 21-40」下面多出一整块空白（实测 60 = 56 + 4）。
    修法：网格显式 `padding: EdgeInsets.zero` + `primary: false`。门禁
    `detail_section_rhythm_test` 用 `MediaQueryData(padding: top 56)` 复现并锁住。
    这类「容器自己不是滚动区、却继承了滚动区语义」的坑，看截图只知道「大了」，
    量矩形才知道那 56 从哪来。
  - **状态条高度 72 → 40**：行首图标去掉后行里只剩一行文字，文字居中于 72 会让
    它下方空出 26px，「状态条 → 线路」实测 58，而「线路 → 选集」是 32——用户问
    「是我的错觉吗」，答：不是。改成 40（= 32 高的动作按钮 + 上下 4）、动作按钮
    压到 32 高，再把这条缝补成 16（`owned` 时），两处视觉间距都是 34 / 32。
- **门禁**：`test/detail_section_rhythm_test.dart` 量的就是这些缝，以及「整页没有 `Divider`」。
  间距这类问题靠截图看只能发现「大概不对」，靠几何断言才能说清哪一条缝是几像素。

### Filter panel（筛选）

筛选**不常驻**。它在分类条右侧、刷新按钮左边是一个按钮，点击后以 `MenuAnchor` **悬浮**显示。

- **按需出现**：当前分类没有筛选维度时，按钮**根本不渲染**。一个点了什么也没有的按钮比没有按钮更糟。
- **悬浮而不是常驻**：常驻时多维度要吃掉内容区顶部 150~200px，把海报挤下去。浮层不占布局。
- **必须显示"已生效"**：面板藏起来后用户看不到自己选过什么。所以有生效筛选时按钮**染星等琥珀 + 数字角标**（`筛选 ②`）——这是隐藏式筛选最容易丢的信息。
- **「重置筛选」在面板内**，且**只在真的筛过之后才出现**（没筛过就没有可重置的东西）。
- 面板宽 520px、限高 420px 可滚动；每维度一行「等宽标签 + 横向 chip」，与对话框同一量级的桌面尺寸。

**已知的证据缺口：** 面板渲染在 `Navigator` 的 `Overlay` 里，本项目截图 harness 取的是 `Scaffold` 那层的 `RepaintBoundary`，**拍不到浮层**。面板内容由断言保证，观感只能靠真机人眼确认。

### Cards / Containers

- **Corner Style:** 大容器圆角 (14px)。
- **Background:** `surfaceContainerLow` (#141A2E)。
- **Shadow Strategy:** 无阴影，见 Elevation & Depth。
- **Border:** 需要边界时用 1px 发丝边 `outlineVariant @ 0.72`。
- **Internal Padding:** `AppSpace.lg` (16px)。
- **Margin:** `EdgeInsets.zero`——间距由父级用 `AppSpace` 控制，卡片自身不带外边距。

### Inputs / Fields

- **Style:** 填充式，底 `surfaceContainer` (#1B2238)，圆角 10px，1px 发丝边，内边距 `12px 14px`。提示与标签文字用 `bodyMedium` + `onSurfaceVariant`。
- **Focus:** 边线换成 `primary` 且加粗到 **1.5px**。没有发光、没有外扩——平坦的场上不允许光晕。
- **Error:** 边线换成 `error`；聚焦时同样是 `error` + 1.5px。
- **Selection:** 选区 `primary @ 0.28`，光标与选择手柄为 `primary`。
- **地址类字段一律「预设 + 自定义」**（2026-11-21，TMDB 的 API / 图片线路）：先给内置线路下拉，再给自由输入框——用户不知道有哪些可用域名，但一定要能填自己的。选中预设时输入框同步成**归一后的地址**（看得见最终形态），预设说明走 helperText 一行；「自定义…」只把编辑权交回输入框，不改地址。**线路名里写域名**（「官方 API（api.tmdb.org）」），用户不必点开就知道选的是谁。
- **「自动」是唯一允许自己换线的选项，而且换线必须可见**（2026-11-21）：手选线路是用户的决定，运行期不得偷偷改；只有选中「自动」时，线路才按实测延迟与失败冷却在候选间切换，并且设置页固定显示一行「当前 API / 图片」实际线路——自动不是黑盒，用户随时能确认此刻走的是哪条。

### Navigation

- **Style:** 标准 `NavigationRail`，`minWidth: 76px`，背景阶梯最低一级 (#070911)，指示器底 `surfaceContainerHigh`、圆角 10px。
- **Typography:** 标签 11.5px，选中 700 + `onSurface`，未选中 400 + `onSurfaceVariant`。图标 21px，选中为**星等琥珀**，未选中 `onSurfaceVariant`。
- **States:** 外壳导航必须是 `NavigationRail`（`tmdb_shell_entry_flow_test.dart:72` 断言 `findsOneWidget`），不可替换为自绘导航。
- **侧栏只收「看片链路 + 设置」**（2026-11-22，11 → 8 项）：Spider 运行时、日志、AI·阅读器退成设置里的行。判据是「侧栏回答*看什么*，设置回答*怎么把它弄好*」——一个入口属于后者就不该再占一栏。回归钉子：`test/shell_rail_capacity_test.dart`（入口集合与顺序）、`test/settings_maintenance_entries_test.dart`（搬家后不是死链）。
- **同一家的两项功能宁可两行，不要合并，也不要套三级**（2026-11-22）：`AI 助手`（连接/凭据/提示词，配一次）与 `AI 业务与阅读器`（推荐/阅读器/广告分析，反复用）保持两行各自可达，只补**对称入口**——业务页 AppBar 齿轮 → 配置页，配置页 AppBar 星标 → 业务页（`ai-settings-open-business`），两行摘要互相指路。先例：2026-11-18「TMDB 凭据」与「元数据来源」合并后用户找不到其中一项，已拆回两行。判据：只有当**一个入口能覆盖全部用途**、且那些用途不需要带上下文参数打开时，合并才划算。
- **入口数量按「概念」算，不按「视角」算**（2026-11-18 合并）：追番列表与追剧日历是同一张 `following` 表的两个视角，因此只占**一个**侧栏入口「追剧」（11 → 10 项），页内用「列表 / 日历」切换；日历自己的「整周 / 整月」是二级切换。自动检查、新集提示、检查间隔收进页头「⋯」菜单，不占整行。
- **列表项:** 圆角 10px，内边距 `14px 4px`，标题 `bodyLarge`、副标题 `bodyMedium` + `onSurfaceVariant`，选中底 `surfaceContainerHigh`。
- **其他框架表面也被上色**（滚动条、选区、光标、弹出菜单、底部面板、开关、滑轨、分段按钮）：这些是最便宜也最容易被跳过的一环，默认值是框架的灰，会从世界里掉出来。

### Source Field（signature move）

**源场是整个系统的签名招式，也是唯一一个世界真正"拥有"的区域。**

每一个站源是一个**点**，点的**直径就是它实测的成功率**，颜色是它的健康状态。这不是装饰——它一眼回答「哪个源现在还能用」，而这正是本产品真正的焦虑。

- **直径:** `rate == null ? 7.0 : 7.0 + rate * 15.0`，即 **7–22px**。尺度是刻意放大的：第一版 5–14px 在截图里退化成一条附注。无采样时给最小的中性尺寸 7px，让「未知」看得见但不抢眼。
- **颜色:** 四个状态色之一，只从 `context.semanticColors` 取。
- **数据是真实测量，不是估计:** `site_health` 表按动作累计的 `*_ok` / `*_total` 四个动作（home / category / detail / play）相加，由 `services/storage.dart` 的 `recordHealth` 写入（`services/site_service.dart` 在每次站点调用后调用它）。
- **基准星:** 当前选中的源加一圈 **1.5px 星等琥珀环**——这是琥珀在本产品里最正当的用途之一。
- **判级规则**（纯函数 `buildMagnitudes`，不碰数据库、不碰 widget，便于单测锁定）：
  - 运行时不支持 → **失效**（「确实用不了」与「没测过」是两件事）。
  - 无采样记录 → **未知**（`rate == null`）。
  - 成功率 ≥ **0.8** → 可用。
  - 成功率 > 0，或样本量 < **3** → 降级。**一次失败不足以判定一个源死了**——宁可显示「降级」让用户自己试，也不要把一次网络抖动说成「失效」。
  - 否则 → 失效。
- **排序:** 按成功率降序，未知（`-1`）排最后，同分按名称。源场因此读起来是「从最亮到最暗」的一片场。
- **密度与封顶:** 画的是真实全量站源。点占 34px 横向槽位，按可用宽度算每行数量，默认最多 3 行；超出部分用一行 `labelSmall` 说明「另有 N 个较暗的源未在此展开」。3 行是「有存在感但不喧宾夺主」的取值——不封顶会让首页第一屏被源场吃掉。
- **图例即计数:** 一行四个「8px 状态点 + 状态名 + 表格字形计数」，一行读完「多少源现在能用」。
- **命中区:** 每个点包在 26×26 的 `SizedBox` 里，点间 `12px` 间距，光标为 `click`，tooltip 延迟 350ms，内容含名称、状态、成功率（含样本数）、平均延迟与不可用原因。
- **容器:** 底 `surfaceContainerLow`、圆角 14px、1px 发丝边、内边距 16px。**一片「场」需要一个自己的面**——第一版把点直接画在页面底色上，读不出这是一块区域，只是几粒散点。

### Dialogs / Transient Surfaces

- **Dialog:** 底 `surfaceContainerHigh` (#232C46)，圆角 14px，**elevation 0**，标题 `titleLarge`、内容 `bodyMedium`。
- **SnackBar:** 浮动式，带关闭图标，底 `surfaceContainerHigh`，圆角 10px，elevation 0。
- **PopupMenu:** 底 `surfaceContainerHigh`，圆角 10px，1px 发丝边，elevation 0。
- **Tooltip:** 底 `surfaceContainerHighest`，圆角 6px，1px 发丝边，文字 `bodySmall`，延迟 400ms。
- **BottomSheet:** 底 `surfaceContainerHigh`，只圆上方两角 (14px)，elevation 0。
- **Loading (`LoadingBlock`):** 26×26 的 `CircularProgressIndicator`，`strokeWidth: 2.4`（收敛前有默认 / 2 / 2.4 四种没有一个是故意的风格），内边距 24px，进度条 `primary`。
- **开关 / 滑轨:** 选中轨与滑块用 `primary`，未选中用 `surfaceContainerHighest` / `onSurfaceVariant`；滑轨高 3px，overlay `primary @ 0.14`。

### Open Items

- ~~**动效标度已定义但零调用点。**~~ 原记载：「全仓（`lib/` 与 `test/`）**没有任何 `AppMotion.` 引用，也没有任何 `Curves.` 使用**……要么把它删掉」。**2026-11-20 更正：不成立，本项关闭**——`AppMotion.*` 实测 `lib/` 20 处（8 个文件，如 `lib/ui/async_action_feedback.dart:104`、`lib/ui/browse_pages.dart:238`、`lib/ui/toast.dart:343`）、`test/` 2 处，`Curves.` 1 处（`lib/ui/tmdb_detail_view.dart:1006`）。标度已是生效的动效规则；原附注「指数缓出是刻意的：从已经可见的默认状态出发」这一理由继续有效。

## Do's and Don'ts

### Do:

- **Do** 从 `context.semanticColors` 取状态色与星等琥珀，永不写死十六进制值。
- **Do** 需要层级时移动表面阶梯（`surfaceContainerLow` → `surfaceContainer` → `surfaceContainerHigh`）或加一条 `outlineVariant @ 0.72` 发丝边。
- **Do** 用 `AppSpace`（4/8/12/16/24/32/48）与 `AppRadius`（6/10/14/999）的标度值，不要引入新的散值。
- **Do** 字重只用 `AppWeight.body`/`label` (400) 与 `AppWeight.title`/`display` (700)。
- **Do** 只在数字成列处用 `tabular(style)` 套表格字形。
- **Do** 让「未知」保持独立：自己的颜色、自己的图例计数、最小中性点径。
- **Do** 保持 `SectionHeader` 上方留白大于下方（上 24px、下 10px）。
- **Do** 保持海报 2:3、剧照 16:9，与全站共用同一尺度。
- **Do** 尊重测试锁死的结构：`NavigationRail` 外壳、`OutlinedButton` 剧集卡、`ChoiceChip` 线路 chip、`SwitchListTile` 同步开关、`tmdbStatusBarHeight = 72`、`find.byKey` 的字面值与挂载 widget 类型。
- **Do** 让文本保持 `Text`/`SelectableText` 且 `.data` 非空（`Text.rich` 会在遍历 `allWidgets` 取 `.data` 的测试里静默消失）。

### Don't:

- **Don't** 使用 `ColorScheme.fromSeed`。种子算法产出的是与主题无关的中性灰阶，也就是「灰底加一个强调色」——那正是这一类产品的默认值，不是克制。星等星表的表面必须**显式给出**。
- **Don't** 使用阴影、`surfaceTint` 或任何非 0 的 elevation。星等星表是一片平坦的场。
- **Don't** 使用中性灰。所有「灰」都必须从夜空底色按色相偏移取得。
- **Don't** 使用 `w500` 或 `w600`。微软雅黑没有真 Medium，这两个字重会走合成加粗（笔画粘连、小字号发糊）。
- **Don't** 改 Material 3 的字号或行高。任何净高度变化都会把控件挤出 800×600 测试视口，让不带 `ensureVisible` 的 `tester.tap` 打空。
- **Don't** 把「未知」显示成「可用」，也不要因为没有采样就隐藏这个源。
- **Don't** 在样本量 < 3 时把源标成「失效」。一次失败不是死亡的证明。
- **Don't** 给星等琥珀找第二个用途。它不是品牌色。
- **Don't** 把源场画成几个装饰点——一片场才有「场」的样子，几个点只是装饰。
- **Don't** 把源场放回首页内容区。**这一条是实测推翻设计意图后改的**（用户反馈
  2026-10-12）：原意图是「先回答哪个源能用，再谈看什么」，于是源场占首页第一块。
  但真实配置下这个前提不成立——实测 170 个站源里 **160 个没有采样记录**，整片场
  基本是灰点，占掉首屏近三分之一高度却没有信息量，还把海报挤下去。健康度是
  **按需查看的诊断信息**，不是每次打开都要读的首页主角。现在它在
  `SiteHealthPage`（设置 → 打开站点健康）。
- **Don't** 用 `Text.rich` 替代 `Text`，也不要让 `.data` 为空。