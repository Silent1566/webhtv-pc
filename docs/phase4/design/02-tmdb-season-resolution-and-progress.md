# 02 · TMDB 季度解析、可播放季度与季度进度设计

- 状态：设计指导，**已实施**（见 `docs/phase4/README.md` §2.2、§3）
- 日期：2026-10-06
- 上游参考：`docs/superpowers/specs/2026-08-17-tmdb-season-aware-aggregation-design.md`、`docs/tmdb-playable-episode-availability-design.md`、`docs/tmdb-season-manual-match-design.md` §7–§11、`TmdbSeasonResolver`、`TmdbSeasonMatchCache`、`TmdbSeasonProgress`、`TmdbSeasonSegment`、`TmdbSeasonScope`、`EpisodeSeasonPolicy`、`EpisodeSeasonSnapshot`
- PC 端落点：`lib/core/tmdb_season.dart`、`lib/services/tmdb_season_service.dart`
- 关联：`01`（身份与匹配）、`03`（存储）、`04`（详情页）、`05`（测试）

---

## 1. 本文件解决的问题

TMDB 匹配（`01`）回答"这是哪部作品"。本文件回答三个更难的问题：

1. **这条线路（`Flag`）对应 TMDB 的哪一季？** → §3 解析器
2. **这一季里，哪些剧集是这条线路真的能播的？** → §4 可播放季度
3. **看到第几集、看了多久，换条线路或换个站点还认得吗？** → §6 季度进度

三个问题共用一个前提：**季度必须用显式三态表达，不能用整数默认值兼表"特别篇"和"未解析"**。

---

## 2. 身份模型

### 2.1 三层身份

```text
MediaIdentity  = mediaType + tmdbId
SeasonIdentity = MediaIdentity + KnownSeasonNumber
SourceBinding  = siteKey + vodId + flagKey   →   SeasonScope + evidence
```

- `MediaIdentity` 用于详情页、TMDB 元数据、同一作品判断。
- `SeasonIdentity` 用于历史展示、续播、进度、删除边界与换源候选。
- `SourceBinding` 用于把"哪条线路是哪一季"这件事落到**线路粒度**。

### 2.2 为什么绑定必须下沉到线路

同一个来源详情经常同时挂着"第一季""第二季""全集"等多条线路。若只给整个 `Vod` 保存一个季度：

- 切到第二季线路后仍读第一季进度；
- 第一季的剧集列表被第二季元数据污染；
- 删除第一季历史会误删第二季。

因此绑定键必须包含 `flagKey`。

`flagKey` 必须是**来源内稳定标识**：若来源没有独立 ID，则使用「能在同一详情内稳定复现的线路值与序号组合」，**不得只用可变的界面显示名**。

PC 端 `flagKey` 生成规则（对齐 `04` §2.3）：

```text
flagKey = <flag 显示名>#<线路序号>       // 例： "线路一#0"
```

理由：`VodPlayLine.flag` 可能重复（同名字段），序号可消歧；两者都来自解析结果，在同一份详情数据内稳定复现。

### 2.3 `SeasonScope` 三态

```dart
sealed class SeasonScope {
  const SeasonScope();
}

/// 已确证的单季。seasonNumber == 0 只表示已明确映射到 TMDB 特别篇。
class KnownSeason extends SeasonScope {
  const KnownSeason(this.seasonNumber);
  final int seasonNumber;
}

/// 一条线路覆盖多季，且每段边界都可验证。
class MultiSeason extends SeasonScope {
  const MultiSeason(this.segments);
  final List<SeasonSegment> segments;
}

/// 证据不足，不猜测。
class UnknownSeason extends SeasonScope {
  const UnknownSeason();
}
```

**硬约束**：

- `KnownSeason(0)` ≠ "未解析"。`UnknownSeason` 与 `KnownSeason(0)` 必须可区分。
- 原始整数 `0` 不得同时承担两种含义。
- `MultiSeason.segments` 至少 2 段，且必须整体通过 §5.3 的段有效性校验。
- `UnknownSeason` 不得在渲染层被降级成"第 1 季"。

### 2.4 `SeasonSegment`

```dart
class SeasonSegment {
  const SeasonSegment({
    required this.seasonNumber,
    required this.sourceEpisodeStartIndex,   // 含
    required this.sourceEpisodeEndIndex,     // 含
    required this.tmdbEpisodeStartNumber,    // 该段首集对应的 TMDB 集号
  });
  ...
}
```

只有知道分段边界，才能把播放位置与某一季的 TMDB 剧集准确对应。

### 2.5 来源指纹

```text
SourceFingerprint = sha256(flagKey + "|" + 结构摘要)
结构摘要           = 依次写入每条剧集的 (序号, 原始剧集名, 归一化剧集名)
手动绑定指纹       = sourceTitle + "|" + flagKey + "|" + stableStructureFingerprint(episodes)
```

- **稳定指纹**（`stableStructureFingerprint`）用于手动绑定：只依赖序号与原始剧集名，**不含 URL**，避免线路换 CDN 后绑定失效。
- **结构指纹**（`structureFingerprint`，含季度集数映射）用于自动绑定校验：TMDB 季集数变化时必须重新验证，避免静默错位。
- 摘要用 SHA-256；输出十六进制小写，长度 64。

---

## 3. 季度解析器（`TmdbSeasonResolver` 等价物）

### 3.1 输入

```text
resolve(
  requestSeason,             // 请求上下文指定的季度，无则 -1
  manualBinding,             // 手动绑定记录，无则 null
  explicitSourceSeasons,     // 从线路/剧集名解析出的季度号集合（可含 -1）
  titleSeason,               // 从标题解析出的季度，无则 -1
  tmdbSeasons,               // TMDB 该作品的全部季度号
  seasonCounts,              // 季度号 → 集数
  sourceEpisodeCount,        // 当前线路剧集数
  sourceEpisodeNumbers,      // 每集解析出的集号（可空）
  explicitEpisodeSeasons,    // 每集解析出的季度号（可空）
  allowHeuristicGuessing,    // 是否允许启发式（设置项）
)
```

### 3.2 输出

```text
Resolution = {
  status  ∈ { resolved, multiSlice, flat, ambiguous }
  scope   : SeasonScope
  source  : ResolutionSource       // 用于可解释性与诊断
  reason  : String                 // 稳定的机器可读原因串
}
```

`ResolutionSource` 取值（对齐上游 `TmdbSeasonResolver.Source`）：
`request` / `manual` / `manualFlat` / `manualMultiSlice` / `explicit` / `explicitMulti` / `explicitConflict` / `title` / `singleSeason` / `episodeCount` / `flatEpisodeKeys` / `allSeasonCounts` / `none`

### 3.3 判定顺序（**严格按序，后级不得覆盖前级**）

```text
 0. 归一化 tmdbSeasons（去负、去重、保序），计算 sliceableSeasons
 1. requestSeason >= 0
      ├─ 含于 tmdbSeasons → resolved(requestSeason, REQUEST, "request_season")
      └─ 不含            → ambiguous(REQUEST, "requested_season_missing_from_tmdb")
 2. manualBinding.mode == manualFlat
                       → flat(MANUAL_FLAT, "manual_flat")
 3. tmdbSeasons 为空   → ambiguous(NONE, "tmdb_seasons_empty")
 4. manualBinding.mode == manualMultiSlice
      ├─ 已存分段有效（§5.3）且 > 1 季 → multiSlice(段内季度, MANUAL_MULTI_SLICE, "manual_multi_slice_segments")
      └─ 否则按集数/集号重算覆盖季度
            ├─ 非空 → multiSlice(覆盖季度, MANUAL_MULTI_SLICE, "manual_multi_slice")
            └─ 空   → ambiguous(MANUAL_MULTI_SLICE, "manual_multi_slice_stale")
 5. manualBinding.mode == manualSeason 且 season 含于 tmdbSeasons
                       → resolved(season, MANUAL, "manual_season")
 6. explicitSourceSeasons（去负去重）规模 > 1
      ├─ titleSeason >= 0 或 存在不属于 tmdbSeasons 的项
      │                    → ambiguous(EXPLICIT_CONFLICT, "multiple_explicit_seasons")
      └─ 按 sliceableSeasons 排序后，若集号连续且完整覆盖
            ├─ 是 → multiSlice(有序季度, EXPLICIT_MULTI, "multiple_explicit_seasons", 完整分段)
            └─ 否 → ambiguous(EXPLICIT_CONFLICT, "multiple_explicit_seasons")
 7. explicitSourceSeasons 规模 == 1
      ├─ titleSeason >= 0 且 != 该季 → ambiguous(EXPLICIT_CONFLICT, "title_and_source_season_conflict")
      ├─ 含于 tmdbSeasons           → resolved(season, EXPLICIT, "explicit_source_season")
      └─ 不含                        → ambiguous(EXPLICIT, "explicit_season_missing_from_tmdb")
 8. titleSeason >= 0
      ├─ 含于 tmdbSeasons → resolved(titleSeason, TITLE, "title_season")
      └─ 不含             → ambiguous(TITLE, "title_season_missing_from_tmdb")
 9. 普通季度（season > 0）数量 == 1 且 allowHeuristicGuessing
                       → resolved(该季, SINGLE_SEASON, "single_ordinary_season")
10. !allowHeuristicGuessing → ambiguous(NONE, "heuristic_guessing_disabled")
11. 普通季度为空 且 tmdbSeasons == [0]
                       → resolved(0, SINGLE_SEASON, "specials_only")
12. 精确集数匹配（seasonCounts[s] == sourceEpisodeCount）的季度集合
      ├─ 恰好 1 个 → resolved(该季, EPISODE_COUNT, "unique_episode_count")
      ├─ 多个      → ambiguous(EPISODE_COUNT, "duplicate_episode_counts")
      └─ 0 个      → 继续
13. canSliceBySeasonCounts(sourceEpisodeCount, sliceableSeasons, seasonCounts)
                       → multiSlice(sliceableSeasons, ALL_SEASON_COUNTS, "all_season_counts")
14. mappedSeasonsByEpisodeNumbers(sourceEpisodeNumbers, sliceableSeasons, seasonCounts) 规模 > 1
                       → multiSlice(该集合, FLAT_EPISODE_KEYS, "flat_episode_keys")
15. 其他               → ambiguous(NONE, "insufficient_season_evidence")
```

> 上游第 12 步在集合为空时不返回，继续第 13 步；在集合 > 1 时返回 `duplicate_episode_counts`。
> 第 14 步只在 `> 1` 时成立（单季覆盖由第 12 步负责）。

### 3.4 自动解析的落盘条件

**只有结果唯一时**才允许自动落盘：

| 落盘 | 条件 |
| --- | --- |
| ✅ | `status == resolved` |
| ✅ | `status == multiSlice` 且分段通过 §5.3 校验 |
| ✅ | `status == flat`（仅由手动 `manualFlat` 产生，不来自自动） |
| ❌ | `status == ambiguous`（含 `duplicate_episode_counts`、`multiple_explicit_seasons`、`insufficient_season_evidence`） |

`ambiguous` 时：

- **不写**季度绑定；
- UI 进入手动匹配提示（`04` §5）；
- 已有高置信度绑定**不被覆盖**（`00` §3.3）。

### 3.5 `allowHeuristicGuessing` 的语义

- 关闭时（第 10 步命中）：只接受请求/手动/显式/标题四类证据，**不做**单季猜测与集数切片。
- 该开关对应设置项 `tmdb.heuristicSeasonGuessing`，默认**开启**。
- 关闭时 `ambiguous` 率上升是**预期行为**，不是缺陷。

---

## 4. 可播放季度（`resolveAvailableSeasons` 等价物）

### 4.1 核心原则

> 选集区域只展示当前线路真实存在的剧集；TMDB 只负责丰富这些播放项，**不创建播放项**。

区分两个概念，二者**不得共用同一套 UI 语义**：

| 概念 | 来源 | 用途 |
| --- | --- | --- |
| 元数据季度 | TMDB `seasons[]` 全量 | 标题、剧照、播出日期、集数位置匹配 |
| 可播放季度 | 当前 `Flag` 的剧集列表能**可靠确证**的季度 | 季度导航、选集过滤 |

### 4.2 输入

```text
sourceSeasonNumbers    // 每集解析出的季度号（-1 未知，0 特别篇）
titleSeason            // 标题季度（-1 无）
firstSeason            // TMDB 第一个有效季度
tmdbSeasons            // TMDB 全部季度号
seasonCounts           // 季度号 → 集数
sourceEpisodeNumbers   // 每集集号（可空）
```

### 4.3 解析顺序（6 级）

> **函数职责边界（关键）**：本函数只决定 **季度导航上下文**，
> 不决定“哪些剧集被渲染”。选集区渲染是独立一层（§4.7），
> 它对未分类集（`-1`）永远保留。两者不能互相代替。

```text
A. 存在任意显式季度号
   A1. hasCompleteExplicitSeasonMapping(sourceSeasonNumbers, tmdbSeasons)
         → 返回 tmdbSeasons 中出现在 sourceSeasonNumbers 里的季度（保持 tmdbSeasons 顺序）
   A2. 否则（有未分类的额外集）：
         ├─ 任一已解析季度不属于 tmdbSeasons → 返回空（退化为扁平）
         ├─ 已解析季度不唯一                → 返回空（退化为扁平）
         └─ 唯一                            → 返回该单季
B. 无显式季度号，但 titleSeason >= 0
         → titleSeason 含于 tmdbSeasons ? [titleSeason] : []
C. 无显式季度号、无标题季度，tmdbSeasons 规模 == 1
         → [tmdbSeasons[0]]
D. canSliceBySeasonCounts(sourceEpisodeCount, tmdbSeasons, seasonCounts)
         → sliceableSeasons(tmdbSeasons)
E. mappedSeasonsByEpisodeNumbers(sourceEpisodeNumbers, tmdbSeasons, seasonCounts) 规模 > 1
         → 该集合
F. tmdbSeasons 含 firstSeason 且 shouldUseSingleSeasonEpisodeData(...)
         → [firstSeason]        // 既有单季兼容策略，不增删线路集数
G. 其他
         → []                   // 退化为扁平列表，隐藏季度导航
```

**返回值语义**：

| 返回值 | 含义 | UI |
| --- | --- | --- |
| `[]` | 无法可靠分季 | 隐藏季度导航，选集区按 §4.7 渲染全部线路集数 |
| `[n]` | 唯一季度 | 隐藏**切换**导航，但显示“第 n 季”上下文 |
| `[n, m, ...]` | 多季可导航 | 显示季度切换控件 |

### 4.4 UI 行为矩阵

| 当前线路 | 季度导航 | 选集内容 |
| --- | --- | --- |
| 仅 `S03E05` | 隐藏切换，显示"第 3 季"上下文 | 仅 `S03E05` |
| 第 2 季 E01–E08 | 隐藏切换，显示"第 2 季"上下文 | 8 个真实播放项 |
| 明确包含第 1、3 季 | 只显示第 1、3 季 | 每季仅对应线路集数 |
| E01、E02、E04 | 隐藏或显示所属唯一季度 | 只显示 1、2、4，**不补 E03** |
| 无季度信息的 8 集扁平列表 | 隐藏 | 原样显示 8 集 |
| 线路数量精确等于 TMDB 多季总数 | 显示可映射全部季度 | 按 TMDB 季集数精确切片 |
| 部分集有季度、部分未知且季度唯一 | 显示“第 n 季”上下文（A2 返回 `[n]`） | 按 §4.7 渲染，**未分类集保留** |
| 部分集有季度、部分未知且季度不唯一 | 隐藏 | 原样显示全部线路集数，**不丢集** |

**本阶段明确不做**：灰色禁用季度、自动换源入口。未来若需"完整作品季度感知"，应做成独立的"其他季度需换源/搜索"入口，**不得把不可播放季度放进选集导航**。

### 4.7 选集区渲染（独立于季度导航）

`resolveAvailableSeasons` 的返回值**只用于季度导航**。选集区渲染是独立一层，规则如下：

```text
导航为空（[]）→ 渲染线路全部剧集
导航为 [n]    → 渲染线路中 season == n 的剧集 **以及所有未分类（-1）剧集**
导航为多季    → 渲染线路中 season == 当前选中季的剧集 **以及所有未分类（-1）剧集**
```

硬约束：

- 未分类（`-1`）的集**永远保留**——它们无法被证明不属于当前季，丢弃即违反
  §4.1「不允许因为部分线路集数无法识别季度，就静默丢弃这些播放项」。
- 渲染结果的长度**不得大于**该线路真实剧集数（不补集）。
- `TMDB 有 S1E9` 但线路只有 8 集时，**不生成**第 9 项。

> 上游依据：`TmdbDetailActivity` 用 `availableSeasonNumbers()` 只驱动季度控件显隐
> （`binding.seasonScroll.setVisibility(...)`），选集渲染走另一条路径，两者互不替代。

### 4.5 集数切片规则

`canSliceBySeasonCounts(episodeCount, seasons, seasonCounts)` 为真当且仅当：

- `episodeCount > 0`；
- `seasons` 非空；
- 每季集数 `> 0`；
- 各季集数之和 **恰好等于** `episodeCount`。

`sliceBySeasonCounts(episodes, seasons, seasonCounts, selectedSeason)` 按顺序把扁平列表切成连续区间；越界返回空。

### 4.6 扁平集号映射

`mapFlatEpisodeNumber(sourceEpisodeNumber, seasons, seasonCounts)`：

- 从第一季开始累加各季集数，找到 `sourceEpisodeNumber` 落在的季与季内集号；
- `sourceEpisodeNumber <= 0` 或超出总和 → `null`；
- 只有**全部集都能映射**时才允许产出 `MultiSeason`（见 §5.3）。

`canMapFlatEpisodeKeys` / `canMapFlatEpisodeNumbers` 是上述能力的前置判定，语义为"存在唯一且完整的映射"。

---

## 5. 绑定与失效

### 5.1 绑定记录字段

```text
SeasonBindingRecord = {
  siteKey, vodId, sourceTitle, flagKey,
  tmdbId, mediaType,                     // 必须与当前 MediaIdentity 一致
  mode ∈ { manualSeason, manualFlat, manualMultiSlice },
  seasonNumber : int?,                   // manualSeason 时非空且 >= 0
  sourceFingerprint : String,
  sourceEpisodeCount : int,
  tmdbSeasonEpisodeCount : int,
  segments : List<SeasonSegment>,        // manualMultiSlice 时非空
  updatedAt : int,
  version : int                          // 结构版本，见 §5.4
}
```

写入前置校验（对齐上游 `put`）：

- `siteKey`/`vodId`/`sourceTitle` 非空，`tmdbId > 0`，`mediaType == tv`；
- `manualSeason` 要求 `seasonNumber != null && >= 0`；
- `manualFlat` / `manualMultiSlice` 要求 `seasonNumber == null`；
- `mode == null` 直接拒绝。

读取校验（`matches(tmdbId)`）：

```text
version == CURRENT_VERSION
&& tmdbId == expected
&& mediaType == "tv"
&& mode != null
&& (mode != manualSeason || (seasonNumber != null && seasonNumber >= 0))
&& ((mode != manualFlat && mode != manualMultiSlice) || seasonNumber == null)
```

### 5.2 旧绑定升级

上游允许 Vod 级绑定（`flagKey == ""`），但**只在调用方已证明详情只有唯一可区分线路时**才可回退读取。

PC 端规则：

```text
find(siteKey, vodId, sourceTitle, flagKey, tmdbId, allowLegacyFallback):
  if (!hasScope(siteKey, vodId, sourceTitle) || tmdbId <= 0) return null
  entry = items[key(siteKey, vodId, sourceTitle, flagKey)]
  if (entry == null && allowLegacyFallback && flagKey 非空):
      entry = items[key(siteKey, vodId, sourceTitle, "")]
  return entry != null && entry.matches(tmdbId) ? entry : null
```

- `allowLegacyFallback` 只允许在**详情线路数 == 1** 时为真。
- 升级路径：线路唯一 或 旧绑定能唯一映射到某线路 → 自动升级为线路级；否则**要求用户重新确认**，禁止把一个季度绑定错误应用到所有线路。

### 5.3 `MultiSeason` 分段有效性（`hasValidPersistedSegments`）

全部条件必须同时满足：

1. `segments.size() >= 2`；
2. `sourceEpisodeCount > 0`；
3. 每段 `seasonNumber` 含于 `tmdbSeasons`；
4. 首段 `sourceEpisodeStartIndex == 0`，且每段 `startIndex == 前段 endIndex + 1`（**连续无空洞**）；
5. 每段 `endIndex >= startIndex` 且 `endIndex < sourceEpisodeCount`；
6. 每段 `tmdbEpisodeStartNumber > 0`；
7. 段长 `len = endIndex - startIndex + 1` 满足 `tmdbEpisodeStartNumber + len - 1 <= seasonCounts[seasonNumber]`；
8. 末段 `endIndex + 1 == sourceEpisodeCount`（**完整覆盖**）。

任一条不满足 → 分段作废 → 回退到"按集数/集号重算"（§3.3 第 4 步）。

### 5.4 版本与失效

| 事件 | 处理 |
| --- | --- |
| 结构版本升级 | 旧 `version` 记录视为无效（`matches` 返回 false），但不删除；下次手动确认时覆盖 |
| 媒体重新匹配（`tmdbId` 变化） | 绑定失效（`removeIfMediaChanged` 语义） |
| 来源指纹不匹配（`pruneRouteBindings`） | 绑定失效；**旧季度进度保留** |
| TMDB 季集数变化 | 只有重新验证通过后才更新 `MultiSeason` 分段，**不静默错位** |
| 用户清除绑定 | 显式删除对应键 |

`pruneRouteBindings(siteKey, vodId, currentFingerprints)` 语义：

```text
对每个属于 (siteKey, vodId) 的绑定：
  current = currentFingerprints[binding.flagKey]
  若 current == null 或 current != binding.sourceFingerprint → 删除该绑定
```

### 5.5 线路绑定索引（换源用）

为支持"同季度换源"，需要能反查"哪些线路属于某季"：

```text
RouteBinding = { siteKey, vodId, flagKey, sourceFlag, sourceFingerprint,
                 tmdbId, mediaType, scope, updatedAt }

indexRouteBindings(tmdbId, mediaType, seasonNumber)
  → Map<"siteKey@@@vodId", List<RouteBinding>>     // 按 updatedAt 降序

findRouteBindings(siteKey, vodId, tmdbId, mediaType, seasonNumber)
  → indexRouteBindings(...)["siteKey@@@vodId"] ?? []
```

- 只记录 `scope.isKnown()`（即 `KnownSeason` 或有效 `MultiSeason`）的绑定；`UnknownSeason` 记录会被移除。
- 容量上限 **512**，超出时按 `updatedAt` 淘汰最旧（`trimRouteBindings`）。
- `routeIdentity(siteKey, vodId) = siteKey + "@@@" + vodId`。

---

## 6. 季度进度

### 6.1 数据模型

```text
TmdbSeasonProgressKey = mediaType + tmdbId + seasonNumber
TmdbSeasonProgress    = latestTmdbEpisodeNumber
                      + playbackPosition
                      + duration
                      + lastSourceHistoryKey
                      + lastSourceBindingKey
                      + sourceFlag
                      + sourceEpisodeName
                      + sourceEpisodeUrl
                      + updatedAt
```

PC 端字段（对齐上游 `TmdbSeasonProgress`，去掉 `cid`，改用 `configId`）：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `configId` | `int` | 配置记录 ID（多配置隔离） |
| `mediaType` | `String` | 归一为 `tv` |
| `tmdbId` | `int` | |
| `seasonNumber` | `int` | |
| `episodeNumber` | `int` | TMDB 集号 |
| `positionMs` | `int` | 播放位置 |
| `durationMs` | `int` | 时长 |
| `sourceFlag` | `String` | 来源线路显示名 |
| `sourceEpisodeName` | `String` | 来源剧集名 |
| `sourceEpisodeUrl` | `String` | 来源剧集**站点入口目标**（详情 `vod_play_url` 里 `$` 后的值；非解析后的可播地址） |
| `sourceHistoryKey` | `String` | 关联的 `history` 键 |
| `sourceBindingKey` | `String` | 关联的线路绑定键 |
| `updatedAt` | `int` | |

主键：`(configId, mediaType, tmdbId, seasonNumber)`。

### 6.2 写入规则

| 情况 | 行为 |
| --- | --- |
| `KnownSeason(n)` 且能定位剧集 | 写季度进度 |
| `MultiSeason` 且能定位到某段的实际剧集 | 写该段所属季度的进度 |
| `UnknownSeason` | **不写**季度进度，只更新来源 `history` |
| 电影 | 不写季度进度 |
| 播放另一季度 | **不覆盖**当前季度快照 |

### 6.3 读取规则（续播）

```text
1. 以 SeasonIdentity 查季度进度
2. 尝试恢复其 lastSourceHistoryKey 对应线路
3. 该线路失效时，在同季度兼容线路中选可播放候选（§7）
4. 原线路失效且无同季度候选 → 停留在选源界面
   ❌ 不跨季回退
```

### 6.4 与来源 `history` 的关系

- 现有 `history` 表**主键与字段不变**，继续承担来源路由与兼容记录。
- 季度进度是**新增的加法式结构**，用于解决"一个来源覆盖多季度时只有一份最近进度"。
- 新写入同时维护来源 `history` 和已确认的季度进度（双写）。
- 稳定版本运行一段时间后，**仍不删除旧字段或旧记录**。

---

## 7. 历史投影、聚合与换源

### 7.1 历史展示键

```text
Known season : mediaType:tmdbId:season:seasonNumber
Unknown      : source:<history.key>
Movie        : mediaType:tmdbId
```

推论：

- 同一 TMDB 节目的第一季与第三季生成**两张**历史卡片。
- 同一季度的多个来源投影为**同一张**季度卡片。
- 未确认季度的记录按来源键保持独立，**不得**仅按 TMDB ID 合并。
- 多季度线路的历史归属由"**实际播放剧集对应的季度**"决定，不以线路覆盖的全部季度生成重复历史。

季度卡片选择 `updatedAt` 最新的记录作为展示代表，但需保留该季度内所有可用来源，供详情页与换源使用。

### 7.2 季度来源聚合

`collect(histories, snapshots, seasonBindings, configId, mediaType, tmdbId, seasonNumber, currentRoute)`

规则：

1. 过滤出 `configId` / `tmdbId` / `mediaType` / `seasonNumber` 全部匹配、且 `episodeNumber > 0` 的记录；
2. 排除 `currentRoute`（避免把当前线路自己列为候选）；
3. 按**线路**去重，同线路取 `updatedAt` 最新；
4. 对存在季度快照的记录，用快照覆盖投影的集号/位置/时长/线路/剧集名（`seasonRoute` 投影）；
5. 结果按 `updatedAt` 降序。

`currentRoute` 的取值：`history.key`；为空则视为不排除。

### 7.3 自动换源的季度兼容判定

候选线路必须先通过季度兼容判断，再参与标题/年份/清晰度/更新时间评分：

```text
target Known(N) accepts source Known(N)
target Known(N) accepts source MultiSeason containing N
target Known(N) rejects source Known(M), M != N
target Known(N) rejects source UnknownSeason for automatic switching
target UnknownSeason only resumes its original source automatically
```

- 手动选择未知线路是**用户明确行为**，可以进入匹配流程；
- 但它**不能**被系统当作同季度可靠候选保存，直到季度得到确认。

### 7.4 删除语义

| 操作 | 行为 |
| --- | --- |
| 删除某一季度历史 | 删除该季度进度 + 解除仅属于该季度的历史投影；**不得**删除同节目其他季度进度 |
| 删除未知季度历史 | 只删除该来源记录 |
| 删除整部节目历史 | 独立、明确的二级操作；删除该 `MediaIdentity` 下**所有**季度进度与关联来源历史 |
| 多季度线路中删除第一季历史 | 只清第一季快照；第二季快照保留。来源路由记录仅在其当前快照属于被删季度**且不再被其他季度引用**时才删除 |

> 上游明确指出：现有"按 TMDB 节目身份自动级联删除"的行为**需要收窄**，不能继续作为季度卡片的默认删除语义。PC 端从一开始就按上表实现，不引入该历史包袱。

---

## 8. 手动季度绑定交互

### 8.1 两个入口

| 入口 | 位置 | 行为 |
| --- | --- | --- |
| 匹配作品后的季度步骤 | 手动匹配弹窗选定作品之后 | 展示季度候选（集数、首播年份），用户选定或选择"保持原始集列表" |
| 仅重选季度 | 详情页季度选择器 | 不改媒体身份，只改季度绑定 |

### 8.2 两步流程

```text
第 1 步：选定 TMDB 作品（01 §7）
第 2 步：选定季度
   ├─ "自动（清除手动绑定）"        → remove 绑定，重新走 §3 解析
   ├─ "按集号自动切片"              → 尝试 multiSlice（需 §5.3 通过），失败则提示"无法安全自动切分"
   ├─ "保持原始集列表"              → mode = manualFlat
   └─ "第 N 季（M 集）"             → mode = manualSeason，seasonNumber = N
```

### 8.3 候选展示要求

每个季度候选必须展示：

- 季度号与集数（`第 N 季 · M 集`，特别篇显示为 `特别篇 · M 集`）；
- 首播年份（来自 `seasons[].air_date`）；
- **风险提示**：当该季度集数与当前线路集数差异较大时标注（避免用户误选）。

### 8.4 保存、刷新与清除

| 操作 | 行为 |
| --- | --- |
| 保存作品+季度 | 写 `manualSeason` 绑定（含指纹与集数快照），刷新剧集元数据 |
| 仅重选季度 | 复用已有 `tmdbId`，只覆盖 `seasonNumber` 与 `mode` |
| 清除绑定 | 删除对应键；季度回到 §3 解析结果 |
| 媒体重新匹配 | `removeIfMediaChanged` 清除旧绑定，避免旧季度应用到新作品 |

### 8.5 状态展示

详情页必须能显示当前绑定状态：

- `手动：第 N 季`（用户明确选定）
- `自动：第 N 季`（解析器唯一确定）
- `自动：第 1–2 季（切片）`（`MultiSeason`）
- `未确定`（`UnknownSeason`，附带"选择季度"入口）

---

## 9. 分集元数据应用

### 9.1 原则

`EpisodeSeasonPolicy.episodeMetadataSeasonCandidates(sourceSeason)`：

```text
sourceSeason >= 0 → [sourceSeason]
sourceSeason <  0 → []          // PC 端不返回 [1, 0] 兜底
```

> **与上游的差异**：上游当前实现为未知季度时依次尝试 `1`、`0`。这正是
> `docs/tmdb-playable-episode-availability-design.md` 的「安全退化原则」要禁止的“未知被隐式降级为第一季”。
> PC 端**从一开始就不实现该兜底**，未知季度即不应用剧集元数据。

### 9.2 应用前校验

应用 TMDB 集数标题到来源剧集前，必须验证：

1. 当前请求代数（generation）与元数据代数仍是最新（防迟到响应）；
2. 目标季度与当前解析出的季度一致；
3. 季集数快照未变化（`hasEpisodeMetadataChanged`）。

任一条不满足 → 放弃本次应用，保留原始剧集名。

### 9.3 集号对齐

```text
shouldUseEpisodePosition(sourceEpisodes, tmdbEpisodes)
  = 来源集号存在重复、缺失或越界时按原始顺序对齐；否则按集号对齐
```

`resolveEpisodeNumber(episode, position, usePosition)`：按位或按号取 TMDB 集号。

### 9.4 多线路处理

- `KnownSeason` 绑定只作用于其对应线路；其他线路独立解析。
- `MultiSeason` 线路按分段映射（`applySegmentedEpisodeMetadata`），每段只应用该段的 TMDB 集数。
- 部分线路无法识别季度时，**保留其原始集名**，不得静默丢弃。

---

## 10. 异常与降级

| 场景 | 处理 |
| --- | --- |
| TMDB 请求失败 | 保留来源标题、来源历史、原线路；**不改变已保存绑定** |
| 季度解析冲突 | 标记 `UnknownSeason` 或进入手动匹配；**不覆盖**旧的高置信度绑定 |
| 来源线路结构变化 | 绑定校验失败后失效并重新解析；**旧季度进度保留** |
| TMDB 季集数后续变化 | 只有重新验证通过后才更新 `MultiSeason` 分段，避免静默错位 |
| 旧数据季度字段为默认 `0` | 除非有特别篇证据，否则按未知处理 |
| `history` 中季度字段缺失 | 按 `UnknownSeason` 处理，不猜测 |

**共同原则**：可以暂时重复展示，但**不能跨季度恢复错误进度**。

---

## 11. 迁移与回填（惰性、可回退）

1. 读取旧历史时，用季度解析器检查标题、已保存季度和剧集映射；
2. **只有结果唯一**时生成季度投影或季度进度快照；
3. 无法确认的记录继续以来源键展示；
4. 新写入同时维护来源 `history` 和已确认的季度进度；
5. 稳定版本运行一段时间后，**仍不删除**旧字段或旧记录。

已有 Vod 级绑定继续读取（§5.2），但只在详情唯一线路或能唯一映射到某线路时才自动升级；否则要求用户重新确认。

---

## 12. 可观测性

| 事件 | 字段 |
| --- | --- |
| 季度解析 | `source`（REQUEST/MANUAL/…）, `status`, `reason`, `tmdbSeasons`, `sourceEpisodeCount` |
| 可播放季度 | `level`（A1–G）, `availableSeasons`, `sliceable`, `flattened` |
| 绑定写入 | `mode`, `seasonNumber`, `segmentCount`, `sourceEpisodeCount` |
| 绑定失效 | `cause`（version / mediaChanged / fingerprintChanged / tmdbCountsChanged） |
| 进度写入 | `seasonNumber`, `episodeNumber`, `positionMs`, `sourceBindingKey` |
| 续播 | `hit`（seasonProgress / sourceHistory / none）, `restoredSeason` |
| 换源候选 | `candidateCount`, `accepted`, `rejectedBySeason` |

**禁止记录**：完整剧集 URL（可能含签名）、用户完整观看历史明细。

---

## 13. 与上游的差异汇总

| 项 | 上游（Android） | PC 端 | 理由 |
| --- | --- | --- | --- |
| 未知季度兜底 | `episodeMetadataSeasonCandidates` 返回 `[1, 0]` | 返回 `[]` | 禁止隐式降级为第一季（上游设计文档已列为待修） |
| 绑定存储 | Gson JSON（`Prefers`） | SQLite 表（`03` §6） | 可查询、可迁移、可索引 |
| 主键 | `cid + mediaType + tmdbId + seasonNumber` | `configId + ...`（同义） | 命名对齐 PC 端既有 `configs` 表 |
| 自动级联删除 | 现存"按 TMDB 身份级联"行为 | 不实现；按 §7.4 分级删除 | 上游已列为需要收窄的行为 |
| `MultiSeason` 上限 | 512 条线路绑定 | 512 条 | 行为对齐 |
| AI 季集识别 | 支持 | 不实现 | `00` §4.3 |
| 季度候选风险预览 | 部分支持 | 必须展示集数与首播年份 | 提升可解释性 |

---

## 14. 开放问题（实施前需确认）

| # | 问题 | 影响 | 建议 |
| --- | --- | --- | --- |
| Q1 | `flagKey` 用 `显示名#序号` 是否足够稳定？ | 决定绑定命中率 | **是**；若来源 `flag` 本身稳定则优先用 `flag`，序号仅作消歧 |
| Q2 | 季度进度是否需要 `configId` 隔离？ | 影响多配置切换体验 | **需要**，与 `history` 的 `config_id` 语义保持一致 |
| Q3 | `UnknownSeason` 的历史卡片是否合并展示？ | 影响历史页信息量 | **不合并**，按来源键独立（上游已确认） |
| Q4 | 是否需要"整部节目删除"二级确认？ | 影响误删风险 | **需要**，且必须是独立的第二级操作 |
| Q5 | 季度进度是否随"清空历史"一起清空？ | 影响数据一致性 | **是**，但需在 UI 上明确提示"将同时清除各季度进度" |

---

## 15. 验收要点（详见 `05`）

1. `SeasonScope` 三态不可混淆：`KnownSeason(0)` 与 `UnknownSeason` 可区分。
2. §3.3 判定顺序 15 步逐条用例，含"后级不得覆盖前级"。
3. `ambiguous` 时**不落盘**且不覆盖已有绑定。
4. §4.3 六级解析顺序逐条用例，含"部分集有季度 → 扁平不丢集"。
5. §5.3 分段有效性 8 条，含"连续无空洞"与"完整覆盖"。
6. §6.2 写入规则：`UnknownSeason` 不写季度进度；播放另一季不覆盖当前季。
7. §7.1 历史投影三种键；同一节目多季生成多卡片。
8. §7.3 自动换源兼容判定 5 条。
9. §7.4 删除语义 4 条，含"多季度线路删第一季不动第二季"。
10. §9.1 未知季度**不应用**剧集元数据（反向验证：若改回 `[1, 0]` 则测试失败）。
11. §11 迁移：旧数据 `seasonNumber = 0` 且无特别篇证据 → `UnknownSeason`。
