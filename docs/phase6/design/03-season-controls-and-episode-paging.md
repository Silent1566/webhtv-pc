# 03 · 季度按钮常驻 + 选集分页 + 切季行为

- 状态：设计指导，**待评审**
- 日期：2026-10-14
- 上游参考：`webhtv/默影视` 的 `TmdbDetailActivity`（`updateTmdbSeasonActionVisibility` /
  `detailSeasonButtonLabel` / `renderSeasonSelection` / `renderEpisodes` /
  `buildCardEpisodeRanges` / `renderEpisodeRanges` / `resolveEpisodeRangeIndex`）、
  `EpisodeRangePolicy`、`ChoiceDialog#showTmdbSeason`
- 关联：`00`（总索引 §3.4）、`04`（AI 季度识别）、`05`（测试与验收）
- PC 端落点：`lib/ui/tmdb_widgets.dart`（`TmdbSeasonSelector` / `TmdbSeasonDialog`）、
  `lib/ui/tmdb_detail_view.dart`（`TmdbDetailView` / `TmdbEpisodeHeader`）、
  `lib/core/episode_range.dart`（新增）、`lib/state/tmdb_state.dart`

---

## 1. 现状与缺口

| 项 | 现状 | 目标 |
| --- | --- | --- |
| 季度按钮 | 只在 `selectedSeason < 0` 时出现「选择季度」 | **常驻**，文案随上下文（`第 N 季` / `选择季度`），带展开箭头 |
| 改绑入口 | 选中季之后**没有**改绑入口（只能靠「重新匹配」绕） | 季度按钮常驻即解决 |
| 季度 UI | 站点页用 `ChoiceChip` 条；纯 TMDB 页用海报卡片条 | **统一成一套 chip 条**（用户确认） |
| 选集分页 | **无**，几百集只能横向滚到底 | 区间 chip 条，每页上限 50，阶梯分组 |
| 切季行为 | 只清空季度元数据 | 切季后选中该季第一集，并重置选集区间 |
| 季度过滤为空 | 保留未分类集，但结果为空时不回退 | 为空时回退全部集（不丢集） |

---

## 2. 季度按钮常驻

### 2.1 渲染条件（对齐 `updateTmdbSeasonActionVisibility`）

上游条件：`matchedTmdbItem != null && isTv() && !seasonNumbers.isEmpty() && canMatchTmdb()`。

PC 端对应：

```dart
bool get _seasonButtonVisible =>
    state.shouldRender &&      // 已有：TMDB 启用且站点允许
    state.hasMatch &&          // 已有：已匹配
    (state.item?.isTv ?? false) &&
    state.seasonEpisodeCounts.isNotEmpty;   // 已有：TMDB 返回了季集数
```

### 2.2 文案

| 条件 | 文案 |
| --- | --- |
| `selectedSeason >= 0` | `第 N 季`（N == 0 时 `特别篇`） |
| `selectedSeason < 0` 但解析出季度 | 同「第 N 季」 |
| 完全解析不出 | `选择季度` |

对齐上游 `detailSeasonButtonLabel`：先用 `currentSeasonContextNumber()`，
拿不到再退到 `tmdbSeasonChoiceResolution().getSelectedSeason()`，都没有才用
`tmdb_season_button`（=「选择季度」）。

PC 端已有 `TmdbState.selectedSeason` 与 `_resolution`，可直接对应。

### 2.3 位置与形态

**放在 `TmdbSeasonSelector` 内部**，作为该行的**首个元素**（按钮在左，chip 条在右）：

```text
[ 第 2 季 ▾ ]   (第 1 季) (第 2 季) (特别篇)     ← 多季
[ 第 1 季 ▾ ]                                    ← 单季
[ 选择季度 ▾ ]                                   ← 未确定
```

**为什么放这里而不是选集区块头**：

1. 季度选择器这一行**已经存在**（`browse_pages.dart` 第 1380 行、
   `tmdb_detail_view.dart` 的季度区块），按钮放进去**不新增行**，
   不改变页面净高度——`DESIGN.md` 的「Metric-Neutral Rule」警告过：
   任何净高度变化都会把控件挤出 800×600 测试视口，让不带 `ensureVisible`
   的 `tester.tap` 打空。
2. 塞进 `TmdbEpisodeHeader` 会让那一行变成「标题 + 3 个按钮」，
   标题（`选集 · <线路名> · N 集`）在窄窗口下会溢出。
3. 季度按钮的语义归属就是季度选择器，不是选集。

**形态**：`TextButton.icon`，文字是当前季度（`第 N 季` / `特别篇` / `选择季度`），
`Icons.expand_more` 在右，`ValueKey('tmdb-season-button')`。

**按钮常驻的额外收益**：单季剧集目前只显示一行上下文文字（`tmdb-season-context`），
**没有任何改绑入口**——用户发现 TMDB 匹配错了季度也没法手动纠正。
加按钮后单季也能改绑，这正是上游 `updateTmdbSeasonActionVisibility`
（条件里 `seasonNumbers` 非空即可见，不要求多季）的行为。

**保留既有 key**：`tmdb-season-context`（单季上下文文字）、
`tmdb-season-switcher`（多季 chip 条容器）、`tmdb-season-N`（各季 chip）、
`tmdb-choose-season`（未确定时的入口）全部保留——`phase4_tmdb_ui_test`
按它们断言。新增的 `tmdb-season-button` 与它们**并存**：
未确定季度时 `tmdb-choose-season` 与 `tmdb-season-button` 都指向同一个弹窗。

> **2026-10-16 修订：单季情形下上面两段自相矛盾，已裁定。**
> §2.3 的单季示意图只画了 `[ 第 1 季 ▾ ]`（一个元素），
> 而本段要求「保留 `tmdb-season-context` 这行上下文文字」——两者直接相加，
> 单季会渲染出**按钮「第 1 季」+ 文字「第 1 季」**，同一句话出现两次。
> 实测症状：`phase4_tmdb_ui_test` 的「单季 → 只显示季度上下文」用例报
> `Found 2 widgets with text "第 1 季"`。
>
> **裁定：取图示（用户看到什么）**，把 `tmdb-season-context` 这个 key
> **移到按钮文字上**（`TmdbSeasonSelector._seasonButton(labelKey:)`）。
> 于是 key 仍存在（两套测试都按它断言）、画面也不再重复。
> 上面那段的「单季上下文文字」应读作「单季上下文（即按钮文字）」。
>
> 若实测发现两个入口在同一行冗余，退让方案是：未确定季度时**只**保留
> `tmdb-season-button`，并把 `tmdb-choose-season` 作为它的别名 key 挂上去
> （一个 widget 只能有一个 key，因此改为在测试里断言 `tmdb-season-button`，
> 并同步更新 `phase4_tmdb_ui_test`）。这是**有意变更**，须在提交信息写明理由。

---

## 3. 季度 UI 统一

用户确认「统一成一套 chip 条」。具体：

- **保留** `TmdbSeasonSelector`（站点页用的 chip 条）作为唯一实现；
- 纯 TMDB 页的季度海报卡片条（`tmdb_detail_view.dart` 的 `_SeasonCard` +
  `tmdb-season-strip`）**改为**复用 `TmdbSeasonSelector`。

**改动范围是干净的**（已核实调用点）：

| 组件 | 调用方 | 本改动影响 |
| --- | --- | --- |
| `TmdbSeasonSelector` | `browse_pages.dart`（站点详情页）+ 4 处测试 | 站点页行为增强（按钮常驻），不换实现 |
| `TmdbDetailView` | **仅** `tmdb_detail_page.dart`（纯 TMDB 页）+ 2 处测试 | 季度区块换成 chip 条 |

站点详情页**不**使用 `TmdbDetailView`——它直接组合 `TmdbDetailHeader` /
`TmdbLineSelector` / `TmdbEpisodeHeader` / `TmdbEpisodeStrip`。因此
「纯 TMDB 页换季度 UI」不会波及站点页。

**风险与对策**：`phase4_tmdb_detail_view_test` 断言了 `tmdb-section-seasons`
与 `tmdb-season-card-*` 的存在。改动会打破它们，因此：

1. 保留 `tmdb-section-seasons` 这个 `SectionHeader` 的 key；
2. `_SeasonCard` 与 `tmdb-season-strip` 相关断言需**同步更新**为 chip 条断言；
3. 这是**有意的测试变更**，必须在提交信息里写明理由（用户要求统一 UI）。

`TmdbSeasonSelector` 需要新增可选参数以适配两处：

```dart
const TmdbSeasonSelector({
  required this.state,
  this.onChanged,
  this.onSelectManual,
  this.padding = const EdgeInsets.symmetric(horizontal: 16),  // 新增
  this.showManualEntry = true,                                 // 新增
});
```

`_SeasonCard` 若在改动后**再无调用点**，必须一并删除（不留死代码）。

---

## 4. 选集分页

### 4.1 纯逻辑（逐条移植 `EpisodeRangePolicy`）

新增 `lib/core/episode_range.dart`：

```dart
class EpisodeRange {
  final String label;   // 真实集号区间，如 "1-20"、"21-40"、"21"
  final int start;      // 列表下标（含）
  final int end;        // 列表下标（不含）
  final bool selected;
}

abstract final class EpisodeRangePolicy {
  static const int cardPageMaxSize = 50;

  static int segmentIndex(int size, int selectedIndex, int segmentSize);
  static int segmentStart(int size, int selectedIndex, int segmentSize);

  static List<EpisodeRange> build(
    int size,
    int selectedIndex,
    bool reverse, [
    int maxGroupSize = 0,
  ]);

  static List<T> slice<T>(List<T> items, EpisodeRange range);
  static int selectedPosition(List<EpisodeRange> ranges);

  static int groupSize(int size, [int maxGroupSize = 0]);
  static int defaultGroupSize(int size);
}
```

`defaultGroupSize` 阶梯（**照搬安卓**，用户确认）：

| 集数 | 每页 |
| --- | --- |
| ≤ 60 | 20 |
| > 60 且 ≤ 300 | 40 |
| > 300 且 ≤ 500 | 50 |
| > 500 且 ≤ 1000 | 100 |
| > 1000 且 ≤ 1500 | 150 |
| > 1500 且 ≤ 2500 | 200 |
| > 2500 | 300 |

再与 `cardPageMaxSize`（50）取 `min`。

**倒序的 `remainder` 逻辑**（上游 `build` 的 `if (reverse && remainder != 0)`）：
倒序时部分区间落在**最前**，使分组边界与正序一致（对齐列表尾部）。
这不是"反转区间顺序"的等价写法，必须照搬。

`build` 末尾的兜底：若没有任何区间被标记 `selected`，把**第一个**标记为
`selected`（上游 `ranges.set(0, first.withSelected(true))`）。

### 4.2 区间标签用真实集号

上游 `buildCardEpisodeRanges` 在 `EpisodeRangePolicy.build` 之后**修正标签**：
用 `episodeNumbers` 映射把列表下标换成真实集号。

PC 端的集号来源：`VodEpisode.extra['tmdb_episode_number']`（TMDB 富集写入）
或从集名解析。**两者都取不到时退回列表下标 +1**，与上游
`numbers.getOrDefault(first, range.start() + 1)` 一致。

### 4.3 UI

`TmdbEpisodeStrip` 上方渲染区间 chip 条（仅当区间数 > 1）：

```dart
if (ranges.length > 1)
  SizedBox(
    height: 40,
    child: ListView.separated(
      key: ValueKey('$keyPrefix-range-strip'),
      scrollDirection: Axis.horizontal,
      itemCount: ranges.length,
      itemBuilder: (_, i) => ChoiceChip(
        key: ValueKey('$keyPrefix-range-$i'),
        label: Text(ranges[i].label),
        selected: i == rangeIndex,
        onSelected: (_) => onRangeChanged?.call(i),
      ),
    ),
  ),
```

选中区间**自动滚入视野**（对齐上游 `smoothScrollTo`）。PC 端用
`ScrollController` + `Scrollable.ensureVisible`，在 `postFrameCallback` 里执行。

### 4.4 手动选过区间后不重置

对齐上游 `manualEpisodeRange`：用户手动点过区间 chip 后，**切集不再重置区间**；
未手动选过时，区间跟随选中集（`selectedPosition`）。

状态放在 `_DetailPageState`（页面级临时状态，与 `_episodesReversed` /
`_episodeGridMode` 同级），**不进 `AppState`**：它是纯展示状态，
跨页面保留没有意义。

### 4.5 分页只作用于渲染

**关键**：分页只切**渲染**的集，不改变播放事实源。播放时仍用
`VodPlayLine.episodes` 的**原始下标**（`_playEpisodeAt` 已有的换算逻辑不变）。

区间切片在 `_renderEpisodes` 的结果上做，即：先季度过滤 → 再倒序 → 再区间切片。
顺序必须是这个：上游 `renderEpisodes` 也是
`visibleEpisodes → reverse → buildCardEpisodeRanges → slice`。

---

## 5. 切季行为

### 5.1 选中该季第一集

`TmdbState.selectSeason` 增加一步：切季后把「该季第一集」记为待选中集。

上游 `renderSeasonSelection` 的点击回调：

```java
selectedSeasonNumber = season;
List<Episode> visibleEpisodes = visibleEpisodes(episodes);
selectedEpisode = visibleEpisodes.isEmpty() ? null : visibleEpisodes.get(0);
resetEpisodeRange();
```

PC 端对应：`selectSeason` 之后，`_DetailPageState` 需要把选集区滚动位置重置到
该季第一集所在区间。

**实现方式**：`TmdbState` 暴露一个「季度切换序号」`seasonEpoch`（每次
`selectSeason` 自增），`_DetailPageState` 在 `build` 里检测到 `seasonEpoch`
变化时重置 `_rangeIndex` 与 `_manualRange`。不用回调链，避免时序问题。

### 5.2 季度过滤为空时回退全部集

`TmdbEpisodeRenderPolicy.filter` 当前行为：`availableSeasons` 为空 → 返回全部；
否则保留 `season == selectedSeason` 与未分类的集。

新增：**过滤结果为空时返回全部集**（对齐上游 `computeVisibleEpisodes` 的
`visible.isEmpty() ? episodes : visible`）。

理由：宁可显示"可能不对季"的集，也不能显示空白——用户会以为剧集丢了。
这与 `DESIGN.md` 的「不丢集」纪律一致。

---

## 6. 验收

| # | 断言 |
| --- | --- |
| C1 | 已匹配 tv 且有 TMDB 季号 → 季度按钮常驻，文案为 `第 N 季` |
| C2 | 选中季之后按钮仍存在，点击可改绑（不再是"只能重新匹配"） |
| C3 | 无法解析季度 → 文案 `选择季度` |
| C4 | 电影 → 季度按钮不渲染 |
| C5 | 未匹配 TMDB → 季度按钮不渲染 |
| C6 | 弹窗选项带集数，当前绑定项高亮 |
| C7 | 两页季度 UI 都是 chip 条（纯 TMDB 页不再有海报卡片条） |
| C8 | 集数 ≤ 60 → 区间数 == ceil(n/20) |
| C9 | 集数 400 → 每页 50，区间数 == 8 |
| C10 | 倒序时部分区间落在最前（`remainder` 逻辑） |
| C11 | 区间标签用真实集号，不是列表下标 |
| C12 | 手动选区间后切集不重置区间 |
| C13 | 未手动选区间时，区间跟随选中集 |
| C14 | 选中区间自动滚入视野 |
| C15 | 分页只改渲染，播放仍用原始下标 |
| C16 | 切季后重置到该季第一集所在区间 |
| C17 | 季度过滤结果为空 → 回退全部集，不显示空白 |
| C18 | 区间数为 1 时不渲染区间条 |
