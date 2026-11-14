# 05 · 历史同名聚合与跨源续播（方案 A）

- 状态：**已实现**（PC `webhtv-pc/dev1`，安卓侧无需改动）
- 日期：2026-10-27 设计 / 2026-10-28 落地
- 适用工程：`apps/desktop-flutter`
- 上游参考：`docs/global-history-resume-design.md` §7–§18（安卓 `HistoryResumeCoordinator`、`VodSourceResolver`、`ResumePositionPolicy`、`GlobalHistoryEntry`）；
  `HistoryActivity` / `HistoryAdapter`；`Setting.getGlobalHistoryMode`、`history_aggregation_by_tmdb`
- 关联：`00`（原则 P1–P5）、`04`（多源化与历史按源隔离）、`docs/phase6/design/01`（历史页与删除模式 §4.1）、`docs/phase6/design/02`（详情页续播 §7.1）
- 用户原始诉求（2026-10-27）：`m00132`「默认只显示当前线路的历史记录，支持用户手动切换显示全部。显示全部的时候参考安卓版的相关实现，比如：标注当前线路和非当前线路，点击播放的时候按设置采用自动匹配还是全局搜索等方式并确保进度能完美同步过去」
- 追加诉求（2026-10-27）：`m00325`「历史记录需要支持同名聚合，优先 tmdb，没有配置等情况再基于名称等信息，具体可以参考安卓版，最好是默认这种模式同时保留现在没集独立的历史记录格式允许用户手动切换」
- 用户逐条选型（`m00325`）：① 方案 **A**（本地解析 + 可选联网）；② **允许**给历史表加 TMDB 列；③ **不切源**——只在当前源内找可替代站点，找不到就提示用户手动切源

---

## 1. 问题：按源隔离修好了串源，却带来了三处新裂口

`04` 把历史按 `source_key` 隔离之后，用户看到的是这样一个页面（2026-10-27 实测截图）：

| # | 现象 | 根因 |
| --- | --- | --- |
| 1 | 同一部剧在历史页散成好几张卡（一集一张、一个源一张） | 历史是**每集一条记录**（`UNIQUE(source_key, site_key, vod_id, flag, episode_id)`），只有「范围筛选」没有「同名聚合」 |
| 2 | 卡片上分不清哪条属于当前线路、哪条属于别的源 | 缺少来源标注（`04` 只保证**数据**按源隔离，没有**视觉**区分） |
| 3 | 点别的源的卡片直接弹「该记录所属站点已不在当前配置中：dfcc83…」 | `_openDetail` 里 `config.sites` 查不到 `item.siteKey` 就 SnackBar 结束；跨源的 `siteKey` 是另一份配置的命名空间 |
| 4 | 即使能进详情页，也是**从头播** | 详情页的进度来自 `AppState.resumePositionFor(siteKey: 当前站点, …)`，它带 `historySourceFilter`；跨源时那条查询必然落空 |

第 3、4 条合起来说明：**「看全部」这个开关只解决了"看得见"，没解决"点得动"**。
本轮把「同名聚合（看得清）」「来源标注（分得清）」「跨源续播 + 进度迁移（点得动）」三件事一起补齐。

---

## 2. 三条取舍（用户已定，不再讨论）

| 备选 | 做法 | 结论 |
| --- | --- | --- |
| **A** | PC 本地用已有的配置 JSON + TMDB 缓存解析；必要时在当前源内搜索 | **采纳**。不依赖安卓新接口，离线可用 |
| B | 只允许「切到那个源再播」 | 否决：用户明确要求「不切源」（选型 ③） |
| C | 把历史表整体重构为「作品身份表」（一张卡一行） | 否决：破坏性迁移，且 `04` 的按源隔离刚落地 |

两条与之配套的硬约束：

- **聚合是读视图，不是写模型。** 写入仍是一集一条记录；切回 `none` 立刻恢复 v7 形态。理由：`04` 的 `UNIQUE` 键与安卓推送的合并语义都建立在「一条记录 = 一集」上，改写入模型等于重做同步协议。
- **宁可不续播，不可错续播。** 跨源时若无法高置信判定「这是同一部作品的同一集」，一律不迁移进度、不自动播放，改为把选择权交回用户（`docs/phase6/design/01` §4.1 的既有原则）。

---

## 3. 聚合（读视图）

### 3.1 三档模式 `core/history_aggregation.dart`

| 字面值 | 名称 | 语义 |
| --- | --- | --- |
| `tmdb` | 聚合（默认） | 有 TMDB 身份按 `(media_type, tmdb_id)` 合并；没有的按片名 |
| `none` | 逐集 | 每条记录自成一组，等于 v7 既有形态 |
| `title` | 按片名 | 完全不看 TMDB，只按片名（+年份消歧） |

`normalize()` 对脏值（`null` / 空白 / 不认识的字符串）回落到 `tmdb` 而**不是** `none`：
手改坏 `settings.json` 时不该把用户静默降级回逐集形态。持久化键为 `settings.json` 的 `ui.historyAggregation`（缺席 = 默认 `tmdb`，见 §5）。

> 与安卓的差异：安卓是 `history_aggregation_by_tmdb` 布尔开关，PC 侧多一档 `title`
> 是因为 PC 的 TMDB 绑定覆盖率低于安卓（大量来源从未匹配过 TMDB），
> 需要一条「只按片名」的中间路径。

### 3.2 聚合键 `core/history_grouping.dart`

| 模式 | 有 TMDB 身份 | 没有 TMDB 身份 |
| --- | --- | --- |
| `tmdb` | `tmdb\|{mediaType}\|{tmdbId}` | `title\|{normalizeSourceTitle(vodName)}` |
| `title` | 同右（忽略 TMDB） | 同右 |
| `none` | 不聚合，`record\|{id}` | 同左 |

三条判定细节：

1. **媒体类型只认 `movie` / `tv`**（`normalizeMediaType`）。其余值回空串、视为「无 TMDB 身份」。
   理由：TMDB 的电影与剧集是两套命名空间，同一个数字 ID 在两边都存在，
   不区分会把无关的两部作品合并成一张卡（安卓 `normalizeMediaType` 同）。
2. **片名归一化后为空 → 单独成组**（`raw\|{vodName}`），**不猜**。空片名归一化后互相相等，
   合并等于把所有无标题记录糊成一张卡。
3. **年份只做组内消歧，不拼进键**。历史表里年份可能为空（安卓同步来的记录没有年份字段，
   只有 PC 本地播放才写）。若把年份拼进键，同一部剧「安卓推来的无年份记录」与
   「PC 本地播放的有年份记录」会分裂成两张卡——这正是用户抱怨的散卡。
   因此：先按片名分桶，**只有桶内出现 ≥2 个不同的非空年份**时才按年份拆开，
   无年份的记录归入 `year-unknown` 桶（不猜它属于哪一年）。

### 3.3 代表记录与顺序

- **代表记录 = 组内 `updatedAt` 最新的一条**，不是「进度最大」的那条（安卓 §8.1 同）。
  理由：用户主动回看前一集时，最新行为应当优先；按进度取会把他弹回上次中断的那一集。
- 组内成员按 `updatedAt` 降序；整个列表按各组代表记录的 `updatedAt` 降序
  （与既有 `recentHistory` 一致，「最近看的在最前」）。
- 搜索关键词命中组内**任一成员**即保留该组（否则「搜某集搜不到」）。
  `AppState.historyGroups({keyword})` 按此实现：先 `recentHistory()` / `searchHistory(keyword)`，
  再 `groupHistory`。

### 3.4 删除必须逐条落到真实记录

聚合卡是读视图，**删除仍按记录级 id**：`_deleteOne` / `_confirmDeleteSelected` 作用于
`group.members` 的真实记录，不是「删掉一张卡」的抽象。多选态的 `selectedIds` 同理
（`history-checkbox-{recordId}`）。原因：卡片与记录不是一一对应，若按组删，
用户看不到「这张卡背后有几条」就把安卓推来的历史也删了。

---

## 4. 存储 v7 → v8：只加三列

`lib/services/storage.dart`：`schemaVersion = 8`，`history` 增

| 列 | 声明 | 语义 |
| --- | --- | --- |
| `vod_year` | `TEXT NOT NULL DEFAULT ''` | 作品年份（空串 = 未知） |
| `tmdb_id` | `INTEGER NOT NULL DEFAULT 0` | TMDB 数字 ID（0 = 未绑定） |
| `media_type` | `TEXT NOT NULL DEFAULT ''` | `movie` / `tv` / 空串 |

配套：`CREATE INDEX IF NOT EXISTS idx_history_tmdb ON history(media_type, tmdb_id)`。

**纯加法式迁移**（`ALTER TABLE ADD COLUMN`），不需要像 v7 那样重建表：这三列不参与唯一键。
**旧行不回填**：按片名猜 TMDB 违反安卓 §18（「不回填猜测的 TMDB 身份」），
猜错的后果是两部不同作品被永久合并，比「暂不聚合」糟得多。旧行升级后一律
「身份未知」，聚合时自然回退到按片名分组。

**写入侧的身份保护**：`upsertHistory` 的 `ON CONFLICT` 用**条件覆盖**——

```sql
vod_year   = CASE WHEN excluded.vod_year   = '' THEN history.vod_year   ELSE excluded.vod_year   END
tmdb_id    = CASE WHEN excluded.tmdb_id    = 0  THEN history.tmdb_id    ELSE excluded.tmdb_id    END
media_type = CASE WHEN excluded.media_type = '' THEN history.media_type ELSE excluded.media_type END
```

否则「安卓推来一条没有年份的记录」会抹掉 PC 侧已绑定的身份，聚合随之退化。
身份来源：`player_page.dart` 的 `_persistProgress` 传
`tmdbId: _request.tmdb?.tmdbId ?? 0, mediaType: _request.tmdb?.mediaType.name ?? ''`。

---

## 5. 偏好存储

`ui_preferences_store.dart` 新增：

| 成员 | 语义 |
| --- | --- |
| `String get historyAggregation` | `UiHistoryAggregation.normalize(_historyAggregation)` |
| `bool get hasExplicitHistoryAggregation` | 用户是否显式选过（`null` = 从未选，走默认） |
| `Future<bool> rememberHistoryAggregation(String)` | 写入 + 落盘 |

`loadFromMap` 只接受三档合法值（脏值直接丢弃，回落默认）；`persist` 里
`if (aggregation != null) ui['historyAggregation'] = aggregation;`——
**缺席即默认**，因此老 `settings.json` 不需要迁移，也不会被强行写入一个用户没选过的值。

### 5.1 与 `historyScope` 的关系：两个正交维度

| 维度 | 键 | 取值 | 回答的问题 |
| --- | --- | --- | --- |
| 范围 | `ui.historyScope` | `source`（默认）/ `global` | 「看**哪些源**的历史」 |
| 聚合 | `ui.historyAggregation` | `tmdb`（默认）/ `none` / `title` | 「同一部作品**合不合并**」 |

两者在 UI 上是工具栏里的两个并排开关（`history-scope-switch` /
`history-aggregation-switch`），互不影响：聚合只在当前可见集合内做。

---

## 6. 来源标注（`library_pages.dart`）

组内**只要有一个 `sourceKey` 不是当前源**，就显示来源 chip：

| 情形 | 文案 |
| --- | --- |
| 一个其他源 | 该源的配置名（`historySourceLabel`） |
| 多个其他源 | `{n} 个其他来源` |
| 名字都解析不出 | `其他来源` |
| 组内混有 `source_key = ''` 且无其他源 | `来源未知`（迁移前的老记录，**只在「全部来源」里出现**，见 §6.1） |

`AppState.historySourceLabel(sourceKey)` 的解析顺序：空串 → `null`（不是「别的源」，
是「不知道来源」）；`== activeSourceKey` → `null`；配置表中命中 → 配置名 → `origin`；
配置已删除 → `parseSourceKey(...).shortLabel` → `其他来源`。

chip 用主题色（`tertiaryContainer`）而不是固定半透明白/黑：chip 落在海报上，
海报画面色彩不可控，固定色在某些封面上不可读（与 `_HistoryBadge` 同因）。

聚合数量角标 `{n} 条`（`history-group-count-{id}`）只在 `group.aggregated` 时显示，
让用户一眼看出这张卡是合并过的。删除态下两个角标都不渲染（删除态是「另一个模式」，对齐安卓）。

### 6.1 按源视图严格过滤（2026-10-28 修复）

用户反馈（`m00004`）：「最近观看筛选过滤有问题，我选的当前来源结果还是看到了其他未知来源的」——
截图里「当前来源」下有一整屏 `来源未知` 卡片。

根因有两层，**都不在 UI 层**，只改 `library_pages.dart` 治不好：

| 层 | 缺陷 | 修法 |
| --- | --- | --- |
| 读 | 四处按源 SQL 写成 `(? = '' OR source_key = ? OR source_key = '')`，**故意**放空来源行进来（旧理由是"未归属 ≠ 别源"，怕升级后历史凭空清空） | 改成 `(? = '' OR source_key = ?)`：`recentHistory` / `searchHistory` / `findHistory`（精确 + 按集名兜底） |
| 写 | 实时拉取的历史合并时不带来源，**每一行都落成 `source_key = ''`** | 拉取循环按设备当前激活源解析归属（`phase7/design/01` §3.1） |

严格过滤的代价与兜底：

- 老记录（升级前的 `source_key = ''`）**暂时从按源视图消失**，「全部来源」里仍然可见；
- 它一旦被播放（`recordProgress` 带 `activeSourceKey`）或被实时同步写入，
  `_adoptLegacyHistoryRow` 就地把 `source_key = ''` 的行改成当前源，此后进入按源视图；
- **宁可不显示，不可猜源**：猜错等于串源，比一张「来源未知」卡片严重得多。

`来源未知` 这个文案因此只保留在「全部来源」视图里——那里它说的是真话（确实不知道来源）。

**空态必须跟着改**（同一处修复的另一半）：严格过滤之后，
`recentHistory()` 为空再也不等于"没历史"。此时若仍写「暂无播放记录 / 播放任意
剧集后会自动记录进度」，用户会反复播放却始终看不到新记录——所以按源视图的空态
（`library_pages.dart` 的 `_emptyHistory()`）分流成三种：

| 条件 | 空态 |
| --- | --- |
| 当前源有记录 | 不出现空态 |
| 全部来源也是 0 条 | 「暂无播放记录 / 播放任意剧集后会自动记录进度。」（原文案，此时是真话） |
| 全部来源有记录 | 「当前来源暂无记录」+「全部来源里还有 N 条记录……」+ 一个「查看全部来源」按钮（直接切视图，用户不必自己去工具栏找开关） |

N 里还单独点出归属不到源的那部分（`source_key = ''` 的行数），因为那正是
用户以为"数据丢了"的那一屏。搜索态（有关键词）一律用原文案：搜索结果为空时
"当前来源没有匹配"和"根本没历史"是两回事，混在一起只会更糊涂。

---

## 7. 跨源续播：两条路径（`lib/ui/history_cross_source.dart`）

入口：`_openBySetting` 判定 `state.isHistoryFromOtherSource(item)` 为真时走
`openHistoryFromOtherSource`。**逐集模式下 group 恒为单条，行为与改造前一致。**

| 路径 | 条件 | 行为 |
| --- | --- | --- |
| 一 | 原 `siteKey` **仍在**当前配置里 | `selectSite` → `DetailPage`（带原记录的 flag/episodeId/进度） |
| 二 | 原 `siteKey` 已不在当前配置 | 在当前源的可搜索站点上 `searchAll(片名, timeout: 12s)` → 评级 → 高置信则播放，否则让用户选 |

路径二的细节：

- **只在当前配置的站点里搜**（`!site.hide && site.searchable`）。这是用户选型 ③ 的落地：
  绝不 `activateConfigRecord`——那会把整个 App 弹到另一个源上。
- 每站只取前 4 条搜索结果（`take(4)`），构造 `ResumeCandidate`。**列表阶段不写
  `hasTargetEpisode`**——那时还没加载详情，预置 `true` 等于赌一把。
- **两阶段解析**（安卓 §11 同）：`_enrichCandidates` 对排好序的候选逐个 `detail()`，
  用返回的线路摊平后回填 `episodeCount` 与 `hasTargetEpisode`
  （`candidateHasResumeEpisode` 与播放阶段共用 `resumeEpisodeMatches`，判定永不分叉）。
  探测预算 `maxDetailProbes = 12`；预算用尽或详情失败都**保持 `false`**，
  宁可让用户手选，不可赌一把播错集。
- 搜索期间必须给可见反馈（SnackBar「该记录不在当前播放源，正在当前源中匹配…」），
  否则 12s 的搜索期间界面像卡死（安卓 §7.3 的同一条要求：加载态不可静默）。
- 有高置信候选但**都没有那一集**时，不弹「未找到播放源」，而是提示
  「已找到同名作品，但没有对应的集，请在详情页手动选择」。
- 无高置信候选时**不自动播放**，弹 `history-cross-source-dialog`：
  「未找到可可靠续播的播放源」+ 按钮「打开全局搜索」（`history-cross-source-open-search`）
  → `SearchPage(initialKeyword: 片名, resumeSeed: 原记录进度)`。
  种子必须一起带过去：用户从全局搜索里挑中一条结果后，`_openResult` 把它再传给
  `DetailPage`，进度仍然按同一集迁移；否则「搜索 → 选片」这条最常用的兜底路径
  会静默回到从头播。

### 7.1 候选评级 `core/resume_matching.dart`

对齐安卓 §10.4 的等级表，但**只保留能可靠判定的三级**——PC 侧没有 `SiteHealthStore`
的健康评分参与自动决策，也不在列表阶段发网络请求，因此安卓的
`UNIQUE_TITLE_CONFIRMED`（全站唯一同名）在 PC 侧降级为歧义：

| 等级 | 条件 | 自动播放 |
| --- | --- | --- |
| `tmdb` | 双方 `(mediaType, tmdbId)` 一致 | 是 |
| `titleYear` | 归一化片名完全一致 **且** 年份一致 | 是 |
| `ambiguous` | 其余（含仅包含匹配、年份缺失、多候选同分） | 否 |
| `rejected` | TMDB 冲突 / 年份明确冲突 | 否 |

- 一方有 TMDB、另一方没有 → **退回标题级**，不让 TMDB 单方面否决。
- **年份缺失不算一致**（安卓 §10.4 同）：两条都没年份只能说「无法排除」，不升格。
- 片名的「仅包含」关系不认（`庆余年` ⊄ `庆余年外传`）：另一部作品常见。

排序（稳定，便于断言）：等级 → 找到了目标集的优先 → 保持输入顺序。
`pickAutoPlayable` 只取第一个「等级够高 **且** `hasTargetEpisode`」的候选；
多个高置信候选取第一个，**不引入新的质量评分**（安卓 §12 同）。

### 7.2 进度迁移 `core/resume_migration.dart`

对齐安卓 §13.3。规则**顺序固定**：

1. 不是同一集 → `null`（绝不错续播）；
2. 源记录已看完 → `null`；
3. 位置 < 5s → `null`（与 `AppState.resumeThreshold` 同值）；
4. 源时长 (\le 0)（未取到）→ 沿用绝对位置；
5. 位置贴着源片尾（距结尾 5s 内）→ `null`（视为看完）；
6. 目标时长 (\le 0) → 沿用绝对位置；
7. 时长差异 (\le \max(10\text{ 分钟}, 20\%)\）→ **绝对毫秒**；
8. 否则按 `position / duration` **比例换算**；
9. 结果夹取到 `[0, targetDuration - 5s]`；落到结尾保护区 → `null`（从头开始，而不是停在结尾几秒）。

常量：`durationToleranceFloor = 10min`、`durationToleranceRatio = 0.2`、`endingGuard = 5s`、
`resumeThreshold = 5s`。

### 7.3 接线：谁负责判定「同一集」

```
历史卡（聚合/逐集）
  └─ _openBySetting
       ├─ 当前源 → _openDetail(item)                        ┐
       └─ 其他源 → openHistoryFromOtherSource               │ 三条路径都传
                     ├─ _playOnSite(...) → DetailPage(...)  │ resumeSeed: resumeSeedOf(item)
                     └─ 全局搜索兜底 → SearchPage(resumeSeed:) ┘
SearchPage
  └─ _openResult → DetailPage(..., resumeSeed: widget.resumeSeed)
DetailPage
  ├─ _history：resumeSeed 非空则**用它合成**一条 PlaybackHistory（带 positionMs/durationMs）
  ├─ _resumeStartFor(vod, lines, line, episodeIndex)
  │     = resolveResumeStart(seed:, targetLine:, targetEpisodeIndex:, targetEpisodeName:, targetDurationMs: 0, fallback: resumePositionFor(...))
  ├─ 首屏按钮文案 _heroPlayLabel → 与 _play 共用 _resumeStartFor（文案与行为不会漂移）
  └─ _play(...) → PlaybackRequest(startPosition: resume, resumeSeed: widget.resumeSeed)
PlayerPage
  ├─ _load() 恢复段前：_effectiveStartPosition()
  │     = resolveResumeStart(seed:, targetDurationMs: _controller.duration.inMilliseconds, fallback: null) ?? startPosition
  └─ 一次性交接：算完即 copyWith(startPosition:, clearResumeSeed: true)
```

三个关键设计点：

1. **`fallback` 优先**：`resolveResumeStart` 第一行就是 `if (fallback != null) return fallback;`。
   同源同站点时 `resumePositionFor` 给出的是**精确**答案（它知道 completed、线路、集名三路匹配），
   行为与改造前逐字节一致；种子只在它落空时生效。
2. **同一集的判定收在 `core/history_view.dart`**（`locateResumeEpisode` / `resumeEpisodeMatches`）：
   ① 两边都只有一集 → 同一集（电影、单集剧）；② 集号相同（`sourceEpisodeNumber` 解析
   `S01E03`/`第3集`/`EP03`/纯数字）；③ 集名完全相同；④ 同一线路 + 同一原始下标。
   定位不到原记录那一集时**只比集号**，比不出就 `false`（不猜）。
   集号排在集名前面：跨源换站后集名常带站点自己的前后缀（`第03集` vs `03`），
   但集号是作品本身的身份。
3. **比例换算发生在播放器里，且只发生一次**：详情页拿不到目标集的真实时长
   （要 open 视频才有），所以 `_resumeStartFor` 的 `targetDurationMs` 仍传 `0`
   （走绝对毫秒，先给首屏文案一个确定的答案）。真正的重算在
   `PlayerPage._load()`：open 成功后 `_controller.duration` 已知，
   `_effectiveStartPosition()` 用真实时长调一次 `resolveResumeStart`，
   然后立刻 `copyWith(startPosition: 新值, clearResumeSeed: true)` 把种子摘掉
   ——「一次性交接」保证换集、失败重试、直播换线都不会把旧种子再迁移一遍
   （后三者都走 `clearStartPosition: true`）。
   同源路径不受影响：`startPosition` 由 `resumePositionFor` 精确给出，
   `resumeSeed` 为 `null` 时 `_effectiveStartPosition` 原样返回 `startPosition`。

---

## 8. 边界：本轮**不**做什么

| 不做 | 理由 |
| --- | --- |
| 切到历史所属的源去播放 | 用户选型 ③；切配置会把整个 App 弹到另一个源 |
| 把猜测的 TMDB 身份回填到旧记录 | 安卓 §18；猜错会让两部作品永久合并 |
| 改写入模型（一张卡一行） | 会破坏 `04` 的唯一键与安卓推送的合并语义，见 §2 方案 C |
| 回写安卓的 `global_history_mode` / 聚合开关 | `04` Q15 已定：PC 本地偏好，安卓只是容器 |
| 跨配置聚合 TMDB 缓存 | 跨源 TMDB 绑定属于另一个 `config_id`，取它会串缓存 |
| 在**列表阶段**发网络请求判候选 | 会让「看全部」变成 N 次请求。探测只发生在**用户点了某一条跨源记录之后**，且预算封顶 `maxDetailProbes = 12` |
| 把探测失败当成「能续播」 | 详情失败/预算用尽一律保持 `hasTargetEpisode: false`，宁可让用户手选 |

---

## 9. 验收

### 9.1 新增测试

| 文件 | 覆盖 |
| --- | --- |
| `test/phase5_history_grouping_test.dart` | 三档归一化、`none` 逐条、同 TMDB 跨源跨集合并、TMDB 不同不合并、movie/tv 同 ID 不合并、无 TMDB 按片名回退、一方有身份不误合、代表取最新非最大进度、`updatedAt` 降序、年份消歧（单年份不拆 / 多年份拆出 `year-unknown`）、`title` 模式忽略 TMDB、空输入 |
| `test/phase5_resume_migration_test.dart` | `rateCandidate` 九型（TMDB 一致/冲突、movie 与 tv 同 ID、片名+年份、年份缺失、年份冲突、仅包含关系、季度标记归一、一方有 TMDB）、`rankCandidates`/`pickAutoPlayable` 排序与自动播放闸门、`ResumePositionPolicy.migrate` 十条规则 |
| `test/phase5_history_aggregation_ui_test.dart` | 默认聚合 1 张卡 + `{n} 条` 角标；切逐集变 2 张；全局范围带来源名；按源范围只当前源 |
| `test/phase6_resume_playback_test.dart` | `locateResumeEpisode`（flag 命中 / 集入口全库唯一 / 不唯一返回 null / 空列表）、`resumeEpisodeMatches`（同集、换站集名带前后缀仍算同集、集号不同、定位不到且集号解析不出、单集作品）、`resolveResumeStart`（fallback 优先、跨源同集迁移、不同集不迁移、无种子、`positionMs=0`、已播完、贴片尾）、`resumeSeedOf` 字段搬运 |
| `test/phase6_detail_resume_test.dart`（追加 group） | 跨源种子接进播放链路：本机无历史仍显示「继续播放 · 第2集」、不同集回落「播放第一集」、已播完不迁移 |
| `test/phase5_history_cross_source_test.dart` | 跨源路径二的**两阶段探测**（端到端，注入 `http.BaseClient`）：只有「有第 2 集」的站点被自动选中（站A 在前，硬编码 `true` 就会选错）、两站都没有那一集时弹 `history-cross-source-dialog` 且不自动播、全局搜索兜底把 `resumeSeed` 带进 `SearchPage` |
| `test/phase6_resume_playback_test.dart`（追加两个 group） | `resolveResumeStart` 用目标集真实时长做比例换算（2h 目标 → 540000ms；差 60s 仍在容差内走绝对；`targetDurationMs=0` 退化绝对；比例落片尾 → `null`）+ 源码级接线锁（`PlayerPage` 的 `resumeSeed` 字段、`clearResumeSeed`、`_effectiveStartPosition()`、`targetDurationMs: _controller.duration.inMilliseconds`，`DetailPage` 的 `resumeSeed: widget.resumeSeed`） |

### 9.2 回归

| 项 | 结果 |
| --- | --- |
| 既有断言随 v8 更新 | `phase5_sync_storage_test.dart`（`schemaVersion` → 8）、`phase9_storage_test.dart` |
| `flutter analyze lib test integration_test` | `No issues found!` |
| PC 全量单测 | 151 个测试文件分 3 批 × `-j 4` 全绿（1217 + 1047 + 684 例） |

### 9.3 反向验证（防回归靶子）

每一条都**实跑过**：改坏实现 → 跑对应套件确认失败 → 还原 → 复跑确认全绿。

| 靶子（改坏哪里） | 实际失败的断言（实测输出） |
| --- | --- |
| `_splitByYear` 把 `years.length <= 1` 放宽成 `years.isEmpty` | `phase5_history_grouping_test`「桶内只有一个年份、其余记录无年份时也不拆」→ `Expected: <1> Actual: <2>`（`+15 -1`） |
| `ResumePositionPolicy.migrate` 删掉 `if (!sameEpisode) return null;` | `phase5_resume_migration_test` `+23 -1` 与 `phase6_resume_playback_test` `+16 -1` 同时失败 |
| `resolveResumeStart` 删掉 `if (fallback != null) return fallback;` | `phase6_resume_playback_test`「同源 fallback 命中时原样返回」+ `phase6_detail_resume_test`「有历史且有进度 → 文案『继续播放 · <集名>』」「桥接线路（显示名 ≠ 源线路名）→ 仍能续播」，共 `+55 -3` |
| `upsertHistory` 的 `ON CONFLICT` 改回无条件覆盖 | `phase5_sync_storage_test`「后续写入不带身份时，已有的身份不被抹掉」→ `Expected: '2024' Actual: ''` 与 `Expected: 'tv' Actual: ''`（`+16 -2`） |
| `_enrichCandidates` 把 `hasTargetEpisode` 回填改回硬编码 `true` | `phase5_history_cross_source_test`「第二阶段探测：只有『有第 2 集』的那个站点会被自动选中」→ `Expected: 'csp_b' Actual: 'csp_a'`（`+0 -1`） |
| `_offerGlobalSearch` 不再给 `SearchPage` 传 `resumeSeed` | `phase5_history_cross_source_test`「全局搜索兜底把续播上下文带进搜索页」→ `Expected: not null Actual: <null>`（`+2 -1`） |
| `PlayerPage._effectiveStartPosition` 的 `targetDurationMs` 改回常量 `0` | `phase6_resume_playback_test`「接线锁 · 播放器用 open 之后的真实时长重算」→ `Expected: true Actual: <false>`（`+28 -1`） |

第 1 条靶子第一次尝试时**没能失败**（`+15` 全绿）：当时的用例只有「桶内两个记录
同一年份」，放宽实现后它们仍然同桶。补了「一个记录有年份 + 两条无年份」这一形态
才抓住差异——那正是实际数据里最常见的形态（安卓推来的记录无年份、PC 本地播放的
有年份）。这条教训写在这里：**反向验证本身也要被验证**。

---

## 10. 已知限制

以下三条是**这一轮补齐**的（前两条曾是缺口，现在已有实现与用例）：

| 项 | 状态 |
| --- | --- |
| 比例换算 | **已补齐**。详情页仍传 `targetDurationMs: 0`（拿不到目标集时长），`PlayerPage._load` 用 `_controller.duration` 重算一次并摘掉种子 |
| 候选 `hasTargetEpisode` | **已补齐**。`_enrichCandidates` 逐条 `detail()` 后由 `candidateHasResumeEpisode` 回填；预算 12、失败保持 `false` |
| 候选 `episodeCount` | **已补齐**。同一次探测顺带回填（当前不参与自动判定，仅用于展示与后续扩展） |
| 全局搜索兜底 | **已补齐**。`SearchPage` 收 `resumeSeed` 并在 `_openResult` 传给 `DetailPage` |

仍然存在的限制：

| 限制 | 影响 | 后续 |
| --- | --- | --- |
| 探测预算封顶 12 | 搜索结果极多且目标集只在第 13 个候选上时，会退化成让用户手选 | 可按站点健康评分排序后再截断（安卓有 `SiteHealthStore`，PC 暂无） |
| 比例换算只发生在「open 成功之后」 | open 失败重试走 `_resumeFromLatestProgress`，那条路径用的是本机精确历史，不受影响；但若用户手动换集，种子已摘掉、不会重新按比例迁移（正确行为：换集就该从头） | 无 |
| 搜索关键词只用原生片名 | 未用 TMDB 缓存标题；理由见 `_searchKeywordOf` 注释：跨源 TMDB 绑定属另一 `config_id` | 可选：接入跨配置的标题缓存 |
| `historySourceLabel` 对已删除配置只能给短标识 | 显示为 `bridge:ac2d474b` 形式而不是名字 | 保留配置墓碑 |
