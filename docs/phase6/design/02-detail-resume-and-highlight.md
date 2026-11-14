# 02 · 详情页：首屏按钮读历史续播 + 线路/选集高亮

- 状态：设计指导，**待评审**
- 日期：2026-10-14
- 上游参考：`webhtv/默影视` 的 `TmdbDetailActivity`（`updatePlayLabel` / `onPlay` /
  `initHistory` / `findInitialFlag` / `renderEpisodes`）、`TmdbUIAdapter#selectPlaybackFlag`、
  `InlineEpisodeAdapter`
- 关联：`00`（总索引 §3.2、§3.3）、`01`（历史页）、`03`（季度与选集分页）
- PC 端落点：`lib/ui/browse_pages.dart`（`DetailPage`）、`lib/ui/tmdb_detail_view.dart`
  （`TmdbLineSelector` / `TmdbEpisodeCardTile`）、`lib/core/history_view.dart`（新增）

---

## 1. 现状与缺口

| 项 | 现状 | 目标 |
| --- | --- | --- |
| 首屏按钮 | 硬编码 `播放第一集`，固定播 `_activeLine(lines)` 的第 0 集 | 读历史：命中 → `继续播放 · <集名>` 并播那一集 |
| 打开时的线路 | 恒为第一条（`_selectedLineFlag` 空串 → `lines.first`） | 自动切到历史线路 |
| 线路 chip 高亮 | 只有「当前选中」态 | 额外标出「最近播放」那条 |
| 选集卡片高亮 | **无任何历史标记** | 标出「上次看到这里」那一集 |

---

## 2. 历史解析（纯逻辑）

新增 `lib/core/history_view.dart` 中的解析函数，**不依赖 Flutter**：

```dart
/// 详情页从历史恢复播放的目标。
class HistoryResumeTarget {
  final String flag;          // 命中的线路 flag（空串表示未命中任何线路）
  final int episodeIndex;     // 该线路内的剧集下标（0 = 未命中时的第一条线路第 0 集）
  final String episodeName;
  final bool matched;         // 是否**完整**命中（线路与集都对上）
}

/// 收标量而不是 `PlaybackHistory`：后者定义在 `services/storage.dart`，
/// 而本模块属于纯逻辑层（`lib/core/` 不得依赖 `services/`，全仓无先例）。
HistoryResumeTarget resolveHistoryTarget({
  required String historyFlag,
  required String historyEpisodeId,
  required String historyEpisodeName,
  required List<VodPlayLine> lines,
});
```

**续播位置不在本函数内**：`position` 由调用方用既有的
`AppState.resumePositionFor(...)` 取（见 §2.3），因此 `HistoryResumeTarget`
**不含** `position` 字段——两处判断会漂移。

### 2.1 线路匹配（对齐 `TmdbUIAdapter#selectPlaybackFlag`）

三级顺序，**任一级命中即返回**：

1. **精确 flag 命中**：`line.playbackFlag == history.flag`（`playbackFlag` 为
   `sourceFlag ?? flag`，桥接合并时两者可能不同，故 `line.flag` 也试），
   且该线路**包含** `history.episodeId`（作为某集的 `url`）。若 flag 命中但该线路
   不含这一集 → **降级到第 2 级**。
2. **集 URL 唯一命中**：在所有线路里找包含 `history.episodeId` 的线路；
   **恰好一条**才算命中（对齐上游 `uniqueFlagForEpisodeUrl`：多条命中 = 歧义 = 不猜）。
3. **线路名命中**：`line.flag == history.flag`，**仅当历史没有集入口目标**
   （`historyEpisodeId` 为空，即旧数据）。

**为什么第 3 级必须带那个前提**（2026-10-14 修订，实现时发现计划自相矛盾）：
历史带着集入口却一条线路都找不到它时，说明那一集已从所有线路里消失。
此时按线路名"猜"第 0 集会把用户送到**错误的集**上；按「歧义就不猜」退回第一条
线路更诚实。只有历史**没有**集入口时，线路名命中才是可信的**线路级**命中。

> 这条前提是**实现阶段的裁定**，与 §2.1 第 1 条的「降级」措辞一致：
> 第 1 级降级 → 第 2 级（URL 唯一）→ 若 URL 非空且第 2 级也没命中，
> 就直接退回第一条线路，**不再**走第 3 级。

全部未命中 → `flag` 取第一条线路、`episodeIndex = 0`、`matched = false`。

**`matched` 的语义（Task 3 依赖它）**：只有**线路与集都对上**才是 `true`。
`matched == false` 时详情页首屏按钮必须是「播放第一集」，**不得**显示「继续播放」；
`_selectedLineFlag` 也**不得**因此改变（见 §4）。

### 2.2 集匹配

在命中线路内按顺序尝试：

1. `episode.url == history.episodeId`（**精确**，这是主路径：历史存的就是站点入口目标）
2. `episode.name == history.episodeName`（集名兜底）
3. 都未命中 → 第 0 集，`matched = false`

**不按集号下标猜**：历史里没有集号字段（`PlaybackHistory` 只有 `episodeName` /
`episodeId`），按下标猜会把"第 5 集"记到"第 5 个位置"，而集号可能不连续。

### 2.3 续播位置

`position` 由调用方用既有的 `AppState.resumePositionFor(...)` 取（它已处理
`completed` 与位置过短两种情形）。解析函数**不重复实现**这段判定。

---

## 3. 首屏按钮

### 3.1 文案

| 条件 | 文案 | `ValueKey` |
| --- | --- | --- |
| `matched == true` 且未看完且有进度 | `继续播放 · <集名>` | `detail-hero-play` |
| 其余 | `播放第一集` | `detail-hero-play` |

`detail-hero-play` 这个 key **必须保留**：`phase3_detail_page_test` 按它断言
`findsOneWidget`。

「未看完且有进度」的判定复用 `resumePositionFor` 的结果（非 null 即可）。
不用 `history.completed` 单独判断——`resumePositionFor` 已经把 `completed`
与"位置过短"一起处理了，两处判断会漂移。

### 3.2 点击目标

```dart
onPressed: () => _play(
  vod,
  _activeLine(lines),
  target.episodeIndex,          // 命中的集，而不是硬编码 0
),
```

`_play(vod, line, episodeIndex)` 内部已经会调 `resumePositionFor` 带上起始位置
（`browse_pages.dart` 第 1110 行），所以**续播位置不需要额外传参**。

### 3.3 集下标必须换算

`target.episodeIndex` 是**线路原始下标**（`VodPlayLine.episodes` 的下标），
而渲染下标经过 TMDB 季度过滤与倒序。首屏按钮直接用原始下标调 `_play`，
**不经过** `_playEpisodeAt` 的换算——因为 `_play` 要的就是原始下标。
这一点容易搞反，实现时必须确认。

---

## 4. 打开详情页时自动选线路

`DetailPage` 新增可选参数，由历史页传入：

```dart
const DetailPage({
  super.key,
  required this.state,
  required this.vod,
  this.historyFlag = '',        // 历史命中的线路 flag
  this.historyEpisodeId = '',   // 历史命中的集入口目标
});
```

`initState` 里在 `loadDetail` 之前（或详情到达之后）应用：

- 详情到达后，用 `historyFlag` / `historyEpisodeId` 走 §2 的解析，
  把命中的线路写进 `_selectedLineFlag`；
- 同时调 `tmdb.selectLine(flag)`，让 TMDB 季度解析跟着走历史线路；
- 解析不出（历史线路已不存在）→ 保持第一条线路，**不报错**（历史可能来自
  旧配置或安卓推送，站点线路变了是正常情形）。

**为什么在详情到达之后**：`_activeLine(lines)` 依赖 `lines`，而 `lines` 在
详情请求返回前可能是列表页传入的残缺数据。在残缺数据上解析会得出错误线路。

### 4.1 何时**不**自动切线路（B7 的精确语义）

**只有 `target.matched == true` 才自动切线路。** `matched == false` 时
`_selectedLineFlag` 保持空串（即第一条线路），**不**采用 `target.flag`。

理由：`matched == false` 涵盖三种情形，它们都**不该**改变用户的线路选择——

| 情形 | `target.flag` | 为什么不切 |
| --- | --- | --- |
| 完全没有历史 | 第一条线路 | 无历史可循 |
| 历史线路存在但那一集已消失（§2.1 第 1 级降级 + URL 非空） | 第一条线路 | 解析已按「歧义就不猜」退回，切过去也没有那集 |
| 历史线路存在、集也对上，但**集名兜底**命中（§2.2 第 2 条） | 该线路 | **这一种是 `matched == true`**，会切 |

**B7 的断言因此要写成**：`matched == true` 时 `_selectedLineFlag == target.flag`；
`matched == false` 时 `_selectedLineFlag` 为空串（渲染上等价于第一条线路）。

**同样地，`recentFlag`（§5）与 `recentIndex`（§6）也只在 `matched == true` 时给出**——
否则会给一条"其实没命中"的线路/集打上「最近播放」标记，用户点进去发现不是那一集。

---

## 5. 线路 chip 的「最近播放」标记

`TmdbLineSelector` 新增 `recentFlag`：

```dart
const TmdbLineSelector({
  ...
  this.recentFlag = '',    // 历史命中的线路 flag；空串 = 无标记
});
```

命中的 chip **在标签前**加一个 14px 的 `Icons.history` 图标 + tooltip
「最近播放」。**不改变** `selected` 语义（选中态仍是 `ChoiceChip` 的琥珀底，
`phase4_tmdb_ui_test` 与 `tmdb_detail_flow_test` 按 `tmdb-season-*` /
`tmdb-line-*` 的 key 与 `ChoiceChip` 类型断言，不可替换）。

自动选线路（§4）生效后，`recentFlag` 与 `selectedFlag` 通常相同——
标记仍有价值：用户手动切走后，标记还在，能切回来。

---

## 6. 选集卡片的「最近播放」标记

`TmdbEpisodeCardTile` 新增 `isRecent`：

```dart
const TmdbEpisodeCardTile({
  ...
  this.isRecent = false,
});
```

命中时的视觉：

- 卡片外壳（`OutlinedButton`）的 `side` 换成 `primary` 2px 描边；
- 剧照**左下角**加一个「上次看到这里」角标
  （`Icons.history` + 文字，底 `primaryContainer`）。

> **位置修订（2026-10-14，实现时发现）**：本节原写「剧照左上角原有的 `E<n>`
> 角标**旁边**」，实现改为**左下角**。理由：左上角已有 `E<n>`、右下角已有评分角标，
> **左下是唯一空角**；若按原文把新角标挤到 `E<n>` 旁边，两个角标并排的宽度
> 在窄卡片（约 150px）下会溢出。三个角标因此各占一角，互不重叠。
>
> 角标的具体尺寸**跟随相邻两个角标的既有写法**（`left/right: 6`、
> `top/bottom: 6`、`EdgeInsets.symmetric(horizontal: 6, vertical: 2)`、
> `BorderRadius.circular(4)`），**不用** `AppSpace`/`AppRadius` token——
> 那会让同一个 `Stack` 里三个角标的圆角明显不同步。
> （既有两角标本就用字面量，属**先于本轮**的 `DESIGN.md` 偏差，已记入
> Phase 6 ledger 交最终审查，不在本任务修。）

**外壳必须仍是 `OutlinedButton`**：既有集成门禁按
`widget is OutlinedButton && widget.key is ValueKey<String> && key.startsWith('episode-<flag>-')`
计数来断言「不补集」。换成裸 `InkWell` 会让那条门禁失效。

**角标的 key 挂在 `Container` 上，不是 `OutlinedButton` 上**：
`ValueKey('tmdb-episode-card-<flag>-recent-<渲染下标>')`。
它同样 `startsWith('tmdb-episode-card-<flag>-')`，但门禁谓词要求
`widget is OutlinedButton`，故不误匹配。**这是必须核实的点**。

> **剧照比例（修订）**：本节原写「剧照必须仍是 16:9」。实测
> `TmdbEpisodeCardTile` 的剧照是 `SizedBox(height: 110)`，**宽度随列宽变化**
> （150–300），因此**本来就不是** 16:9——这是 `DESIGN.md` 固定比例纪律的
> 一处**既有偏差**，与本轮标记无关。
> 修它要同时改卡片高度与网格 `mainAxisExtent`，否则溢出；
> 而 `DESIGN.md` 的 Metric-Neutral Rule 明确警告净高度变化会把控件挤出
> 800×600 测试视口。**本轮不修**，记入 ledger 交最终审查。

---

## 7. 数据从哪来

### 7.1 两个来源，显式优先

`DetailPage` 的历史有两个来源：

| 来源 | 何时有 | 优先级 |
| --- | --- | --- |
| **构造参数** `historyFlag` / `historyEpisodeId` | 从历史页点卡片进入时 | **高** |
| **自己查** `state.findHistory(siteKey, vodId)` | 从列表页 / 搜索页进入时 | 低 |

```dart
final history = (widget.historyFlag.isNotEmpty || widget.historyEpisodeId.isNotEmpty)
    ? _historyFromParams()
    : state.findHistory(
        siteKey: state.selectedSite?.key ?? '',
        vodId: vod.vodId,
      );
```

**为什么参数优先**：历史页已经拿到了**用户点的那一条**。若让它去
`findHistory`，会命中 `ORDER BY updated_at DESC LIMIT 1` 的**另一条**
（同一部剧有多条记录时，点旧记录却续了新记录）。

`_historyFromParams()` 用一个最小 `PlaybackHistory` 承载传入的两个字段，
其余字段（`positionMs` 等）留默认——续播位置由 `resumePositionFor` 单独取，
不依赖这个对象。**不传 `positionMs`** 是有意的：历史页传入的是"哪条记录"，
不是"从哪一秒续"，后者由 `resumePositionFor` 按 `(siteKey, vodId, flag, episodeId)`
精确查询，避免两处位置判断漂移。

`findHistory` 已存在（`app_state.dart` 第 2303 行），按
`(siteKey, vodId)` 取最近一条（`ORDER BY updated_at DESC LIMIT 1`），
`flag` / `episodeId` 传 null 表示不限。

**注意**：`findHistory` 取的是该剧**最近一条**记录，可能是另一条线路的。
这正是 §2 三级匹配要处理的情形——历史线路可能不是当前线路。

**站点 key 的时序问题**：`state.selectedSite` 在详情页挂载时可能还没切到
正确站点（从历史页进入时已先切过，从搜索页进入时也已先切过）。若为 null，
`findHistory` 返回 null → 退化为「播放第一集」，**不报错**。

---

## 8. 验收

| # | 断言 | 状态 |
| --- | --- | --- |
| B1 | 无历史 → 按钮文案「播放第一集」，点击播第一条线路第 0 集 | ✅ Task 4 |
| B2 | 有历史且命中 → 按钮文案「继续播放 · <集名>」，点击播**那一集** | ✅ Task 4（含变异钉子） |
| B3 | 有历史但已看完 → 按钮文案回到「播放第一集」（`resumePositionFor` 返回 null） | ✅ Task 4 |
| B4 | 有历史但位置过短 → 同上 | ✅ 组合覆盖（见下注） |
| B5 | 历史线路已不存在 → 退回第一条线路，不报错 | ✅ Task 3 |
| B6 | 历史集入口目标在多条线路里都出现 → 判定歧义，退回第一条线路 | ✅ Task 1 |
| B7 | 打开详情页时自动切到历史线路（`_selectedLineFlag == history.flag`） | ✅ Task 3（§4.1 已精确化） |
| B8 | 线路 chip 上出现「最近播放」标记，且该 chip 仍可点击切换 | ✅ Task 5（含变异钉子） |
| B9 | 选集卡片上出现「上次看到这里」标记，外壳仍是 `OutlinedButton` | ✅ Task 6（含两颗变异钉子） |
| B10 | 剧照仍是 16:9 | ❌ **未达成**（见下） |
| B11 | `detail-hero-play` key 仍存在 | ✅ Task 4 + `phase3_detail_page_test` |
| B12 | 从历史页点卡片进详情页时，站点已先切换（不串站） | ⏸ 由 **plans/01 Task 8** 交付 |

### 8.1 B4 是组合覆盖，不是缺口

B4 的链条由三段既有测试拼成，**没有**一条端到端用例：

1. `resumePositionFor(positionMs: 4999)` → `null` ——
   已由 `test/phase2_resume_test.dart:94` 覆盖（短位置分支）；
2. `historyPlayLabel(target, resumePosition: null)` → `'播放第一集'` ——
   已由 plans/02 Task 2 的用例 2 覆盖；
3. `_heroPlayLabel` 把两者接起来 —— 已由 Task 4 的用例 3（`completed` 路径）
   覆盖**同一段**接线代码。

`historyPlayLabel` 对 `resumePosition == null` 一视同仁，**不关心它为何为 null**，
所以 `completed` 与「位置过短」在标签层走的是同一条路径。
因此 B4 判定为**已覆盖**，但记录在案：若将来要给 B4 加端到端钉子，
只需把 Task 4 用例 3 的 `completed: true` 换成 `positionMs: 4999`。

### 8.2 B10 未达成 —— 既有偏差，不在本轮修

**实测**：`TmdbEpisodeCardTile` 的剧照是 `SizedBox(height: 110)`，
**宽度随列宽变化**（实测 143–266px），因此它**从来就不是** 16:9。
本节原文写「剧照**仍是** 16:9」——「仍是」这个前提**不成立**，
这处偏差**先于 Phase 6**。

**为什么不在本轮修**：改成 `AspectRatio(16/9)` 会让剧照高度随宽度在 80–149px 之间变化，
而卡片高度是固定 `196`（`mainAxisExtent`）——
宽度大的列（如集数少时 266px → 剧照 149px）会**溢出**。
要修就必须同时改卡片高度与网格 `mainAxisExtent` 的计算，
而 `DESIGN.md` 的 Metric-Neutral Rule 明确警告净高度变化会把控件挤出
800×600 测试视口。这是一个**独立的重构任务**，需要自己的计划与审查。

**追踪**：记入 Phase 6 ledger 的 deferred 列表，交最终验收裁定。
不得在本阶段以「改测试」的方式让它通过。
