---
version: 1
slug: "lib-ui-app-dart"
primary_target: "lib/ui/app.dart"
related_targets: ["lib/ui/browse_pages.dart","lib/ui/tmdb_detail_view.dart","lib/ui/player_page.dart","lib/ui/theme.dart","lib/ui/tokens.dart"]
---

# Surface: WebHTV PC 应用外壳与核心页面

模式：**Operate** —— 访客要完成一件事：把自己已有的配置跑通到能播。
平台：桌面（Windows 优先）。输入：鼠标 + 键盘。

## 受众与任务

已经拥有 TVBox / 猫源配置的进阶用户，坐在电脑前。他们要判断**哪个站源现在能用**，然后播放。
核心焦虑不是"看什么"，而是"这个源还活着吗"——因为对外口径只承诺"单个站源能否使用以实际测试为准"。

## 范围

- 主目标：`lib/ui/app.dart`（`AppShell`：顶栏 + NavigationRail + 内容区）
- 关联：`lib/ui/browse_pages.dart`、`lib/ui/tmdb_detail_view.dart`、`lib/ui/player_page.dart`
- 基础：`lib/ui/tokens.dart`、`lib/ui/theme.dart`

## 不可动的约束（测试锁死，来自 94 个测试文件的盘点）

<!-- 更正：本文件初稿写「96 个测试文件」，那是审计文档里的数字。磁盘实测为
     94 个 `*_test.dart`（69 单测 + 24 集成 + 1 driver），其中 44 个含 `.tap(`、
     仅 2 个含 `ensureVisible`。DESIGN.md 记录的是实测值。 -->

- `find.byKey` **211 处**：key 的字面值**和它挂着的 widget 类型**都不能改。
- 剧集卡 = `OutlinedButton`；线路 chip = `ChoiceChip`；同步开关 = `SwitchListTile`；
  外壳导航 = **`NavigationRail`**（`tmdb_shell_entry_flow_test.dart:72` 断言 `findsOneWidget`）。
- `tmdbStatusBarHeight = 72` 是精确值；禁用态 `TmdbStatusBar` 内**零 `Row`**；
  季未解析时**零 `ChoiceChip`**。
- 文本必须保持 `Text`/`SelectableText` 且 `.data` 非空
  （`phase5_sync_ui_test.dart:789` 遍历 `allWidgets` 取 `.data`，`Text.rich` 会静默消失）。
- 海报 2:3 ±0.05、剧照 16:9 ±0.1；`PosterImage` 占位首个 `Container` 保持
  `colorScheme.surfaceContainerLow`；`Icons.image_not_supported_outlined` 保留。
- 无 golden 文件：截图是证据，不是断言。

## Direction contract

**THESIS** 每一个站源都是天上一颗星，星等就是它到底能不能用。本表面拒绝的类别默认排布是
"深色海报墙 + 顶部主视觉横幅"——那会把"哪个源能用"沉到二级页面里去。

**OWN-WORLD** 深靛夜空底（`#0B0E1A`）按色相偏移出三级表面阶梯（`#141A2E` / `#1B2238` / `#232C46`）；
星等琥珀（`#F0B429`）是唯一强调色，只用在真正是星等的地方（基准星、当前剧集、选中态）；
四个状态色（可用 / 降级 / 失效 / 未知）承担真实工作。发丝边代替阴影，保持场的平坦。
字体是中文优先的系统无衬线；字重只用雅黑真实存在的 400 / 700，层级靠字号与颜色拉开。

**STORY** 访客一眼看到"163 个站源里 128 可用、21 降级、9 失效"，然后顺着基准星进入内容；
换源是一次决定性翻转，并当场给出该线路的总时长预算。

**FIRST VIEWPORT** 左侧 76px 标准 `NavigationRail`（世界只把选中态染成星等琥珀）；
顶栏 64px 承载配置名与导入 / 选站；主区是**分类条 + 固定 2:3 比例的内容网格**。

**源场的位置（实测修正，2026-10-12）**：初版把源场放在内容区第一块，理由是
「先回答哪个源能用，再谈看什么」。真实配置推翻了这个前提——实测 170 个站源里
**160 个没有采样记录**，整片场基本是灰点，占掉首屏近三分之一高度却没有信息量，
还把海报挤下去。因此源场移到独立页面 `SiteHealthPage`（设置 → 打开站点健康），
首页回到纯粹的内容职责。

**位置翻译（已命名）**：契约原文写「右侧 348px 是当前线路的时长预算与按真实时长成比例的
剧集索引」。实测发现整页右侧栏会打破详情页 hero 的几何断言——背景必须铺满整窗宽
（1200 视口下 `rect.width == 1200`，见 `phase4_tmdb_detail_hero_test.dart`）。
因此这条纪律**落在内容区、紧贴剧集区上方**（`EpisodeDurationStrip`），而不是右栏：
它给出该线路的总时长预算与按 `TmdbEpisodeCard.runtime` 成比例的剧集条。
**`runtime == 0` 的集如实显示为「时长未知」的窄暗条，不按平均值假装。**
条用中性数据墨色而非星等琥珀——琥珀只表示"星等 / 选中"（唯一强调色规则）。

**FORM** 星等星表（星表与星等标度）。它在我按共鸣排序的 7 个 grounded 候选里位于**第 4 位**，
由骰子指定；seed key `707d94ea`。四条借来的纪律已写成可见的 raise：
数据密度勇气（源场画真实密度，不是三个装饰点）、长度编码时长（剧集条按真实时长成比例）、
固定比例可比（同一比例与尺度）、一次决定性翻转 + 时长预算。

**FINISH** unreviewed and undocumented is unfinished; this build ends with the finish review,
the verdict, DESIGN.md, and every shipping raster carrying its provenance.

## 未决

- 是否内置一套中文字体。当前用系统字体回退链（雅黑 → Noto CJK → 苹方）；
  内置 Noto Sans CJK SC 每个字重约 10–16MB，会显著改变安装包体积。
- 亮色主题的观感需要在真实截图里复核（用户确认要"认真设计的亮色"，但主身份是暗色）。
