# 01 · TMDB 媒体身份与匹配设计

- 状态：设计指导，**已实施**（见 `docs/phase4/README.md` §2.2、§3）
- 日期：2026-10-06
- 上游参考：`webhtv/默影视` 的 `TmdbMatcher`、`TmdbMatchPolicy`、`TmdbMatchCache`、`TmdbItem`、`TmdbSitePolicy`、`MediaTitleParser`、`docs/tmdb-season-manual-match-design.md` §3/§7/§9/§13
- PC 端落点：`lib/core/tmdb_identity.dart`、`lib/core/tmdb_title.dart`、`lib/services/tmdb_identity_service.dart`
- 关联：`02`（季度解析与进度）、`03`（服务与存储）、`04`（详情页）、`05`（测试）

---

## 1. 本文件解决的问题

TMDB 匹配要回答一个具体问题：

> 站源里的这条 `Vod`，对应 TMDB 的哪一部作品？

答错的后果不是"显示不好看"，而是**后续所有季度、集数、续播、换源都建立在错误身份上**。
因此本文件把匹配拆成三层并逐层给出可测规则：

1. **标题层**：从站源标题里提取可搜索的规范标题、年份、季度信号（§4）。
2. **评分层**：在搜索结果里选出唯一最佳项，选不出就返回"未匹配"（§5）。
3. **缓存层**：把结论持久化，并保证手动结论不被自动猜测覆盖（§7）。

站点策略（哪些站点允许被 TMDB 富集）单列在 §6。

---

## 2. 概念与数据模型

### 2.1 媒体身份

```text
MediaIdentity = mediaType + tmdbId
mediaType     ∈ { "movie", "tv" }
tmdbId        > 0
```

用途：详情页身份、同一作品判断、季度身份的父键。**电影没有季度**；剧集的不同季度共享同一 `MediaIdentity`。

PC 端表达：

```dart
/// lib/core/tmdb_identity.dart
enum TmdbMediaType { movie, tv }

class TmdbIdentity {
  const TmdbIdentity({required this.mediaType, required this.tmdbId});
  final TmdbMediaType mediaType;
  final int tmdbId;

  String get key => '${mediaType.name}:$tmdbId';   // 稳定字符串键
  bool get isTv => mediaType == TmdbMediaType.tv;
}
```

约束：

- `tmdbId <= 0` 一律视为**无身份**，不得构造 `TmdbIdentity`。
- 上游允许 `tmdbId == -1` 作为"冲突标记"（`TmdbMatchCache.Entry.conflict`）。PC 端**不引入 -1 语义**，改用显式 `TmdbMatchConflict` 结果类型（§7.4），避免"负数 ID"这种隐性约定泄漏到季度解析。

### 2.2 `TmdbItem`（列表项 / 搜索结果项）

对齐上游 `bean/TmdbItem`，去掉 Android 专有字段：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `tmdbId` | `int` | TMDB 主键 |
| `mediaType` | `TmdbMediaType` | `movie` / `tv` |
| `title` | `String` | 已按 `language` 取回的主标题 |
| `subtitle` | `String` | 形如 `2024 · 8.2`，用于列表副标题 |
| `overview` | `String?` | 简介 |
| `posterUrl` | `String?` | 已拼接 `imageBase` 的完整地址 |
| `backdropUrl` | `String?` | 已拼接 `backdropBase` 的完整地址 |
| `credit` | `String?` | 演员/主创摘要 |
| `rating` | `double` | 上游兼容字段；PC 端只在 `tmdbRating > 0` 时使用 |
| `tmdbRating` | `double` | TMDB 评分（`vote_average`） |
| `originalLanguage` | `String` | `original_language` |
| `originCountry` | `String` | `origin_country[0]` |
| `genreIds` | `List<int>` | `genre_ids` |
| `department` | `String?` | 演职人员作品列表用 |

**PC 端不填充**：`doubanRating`、`recommendationReason`、`personal*` 相关字段（见 `00` §4.3）。

### 2.3 匹配记录（`TmdbMatchRecord`）

对齐上游 `TmdbMatchCache.Entry`，并补齐 PC 端需要的可解释字段：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `identity` | `TmdbIdentity` | 命中身份 |
| `title` | `String` | TMDB 标题（快照） |
| `subtitle` / `overview` / `posterUrl` / `backdropUrl` / `credit` | `String?` | 展示快照 |
| `rating` / `tmdbRating` | `double` | 评分快照 |
| `originalLanguage` / `originCountry` | `String` | 语言/地区快照 |
| `manual` | `bool` | 是否为用户手动选定 |
| `manualTitles` | `List<String>` | 手动选择的标题别名（已归一） |
| `matchedAt` | `int` | 毫秒时间戳 |
| `source` | `enum` | `auto` / `manual`（用于诊断展示） |

约束：

- 快照字段必须足以在 TMDB 不可用时**离线渲染详情页头部**（标题/海报/评分/简介）。这是"TMDB 请求失败不阻塞浏览"（`00` §3.3）的落地方式。
- 快照不保存 `overview` 以外的剧集数据；剧集数据按 §2.4 单独缓存。

### 2.4 匹配缓存的三层键

上游 `TmdbMatchCache` 用三层键解决"同一 `vodId` 下可能挂着多部作品"与"标题被富集改写后读不回"两个问题。PC 端保留同一结构：

```text
条目级键      : <siteKey>@@@<vodId>
条目+标题键   : <siteKey>@@@<vodId>@@@<normalizedSourceTitle>
全局标题域键  : __title__@@@<normalizedSourceTitle>
```

- 分隔符复用 `@@@`（与 `history` 表一致，见 `docs/webhtv-pc-design.md` §15）。
- `normalizedSourceTitle` = `normalize(cleanTitle(sourceTitle))`（§4.3）。
- **读取顺序**：手动条目级锚点 → 条目+标题键 → 条目级键（需标题兼容）→ 全局标题域键（需标题兼容）。
- **标题兼容**（`isCompatible`）：源标题与缓存标题归一后相等，或源标题为空。标题为空时不做兼容校验，直接读条目级键（Intent 可能不带 name）。
- **全局标题域**用于"同名作品跨站沿用"；写入时遵守：
  - 同身份 → 覆盖；
  - 手动 vs 自动 → 手动优先，自动不得覆盖手动；
  - 手动 vs 手动且身份不同 → 记 **冲突**，读取方按未匹配处理（PC 端用 `TmdbMatchConflict`，不写 `tmdbId = -1`）。

### 2.5 手动选择的排他性

`putManual(siteKey, vodId, sourceTitles, item)` 必须同时写入：

1. 条目级锚点（`manual = true`）；
2. 每个 `sourceTitles` 别名对应的条目+标题键；
3. TMDB 标题本身作为别名（因为富集会把 `vodName` 改写成 TMDB 标题，下次进场要用它读回）。

并且：**自动匹配（`put`）在发现同键存在手动条目时必须直接返回，不得覆盖。**

> 上游 `TmdbMatchCacheTest` 有一条关键用例：同一 `vodId` 下挂两部不同作品，条目级锚点只在标题确实指向同一作品时才生效。PC 端必须保留该用例（见 `05` §3.4 用例组 2）。

---

## 3. 标题模型

### 3.1 三个标题概念

```text
sourceTitle     = 站源原始标题（永不丢弃）
canonicalTitle  = TMDB 节目标题
displayTitle    = 当前界面按上下文生成的标题
```

规则：

1. `sourceTitle` 必须在应用 TMDB 元数据**之前**保存，不能被不可逆覆盖。
2. 来源标题已明确包含季度时，展示保留原始来源标题（`sourceAwareTitle`）。
3. 详情页主标题使用 `canonicalTitle`，季度通过季度选择器表达（`02` §2）。
4. 季度未知时**不伪造"第一季"标签**。
5. 电影与无季度语义内容直接使用 TMDB 标题归一化。

上游实现（`TmdbUIAdapter.sourceAwareTitle`）：

```text
if (item.isTv && resolveSourceSeason(sourceTitle) >= 0) return sourceTitle;
return tmdbTitle;
```

PC 端照抄该判定。

### 3.2 为什么标题只负责展示

标题解析结果**不得**作为已确认季度身份的替代品：它只能产出"候选季度信号"，
必须经季度解析器（`02` §3）验证后才能参与聚合与落盘。

### 3.3 标题清洗（`cleanTitle`）

对齐上游 `TmdbMatcher.cleanVideoName` 与 `MediaTitleParser.cleanTitle` 的并集。清洗步骤顺序固定，不可调换：

1. 去文件扩展名：`(?i)\.(mkv|mp4|avi|mov|wmv|flv|rmvb|ts|m2ts)$`
2. 去噪声括号段：`[...]`、`【...】`、`「...」`、`『...』`、`(...)`、`（...）` 内 1–60 字的段（`BRACKET_PATTERN`）。
   **例外**：`《...》` 内的书名标题要被**提取**而不是丢弃（`BOOK_TITLE_PATTERN`）。
3. 去季集标记：`S\d+E\d+`、`\b(S\d{1,2}|Season\s*\d{1,2})\b`、`第\d+季`、`第\d+集`、`第[一二三四五六七八九十百零〇两0-9]+[季部]`、`第[一二三四五六七八九十百零〇两0-9]+[集话話回期章节節]`、`\b(EP|E|Episode)\s*0*\d{1,5}\b`
4. 去清晰度/编码标记：`HD|4K|8K|1080P|2160P|720P|HDR|HDR10|DV|BluRay|WEB[- ]?DL|HDTV|BDRip|Remux|HEVC|H\.?265|H\.?264|x265|x264|AAC|DTS|DDP|Atmos|NF|Netflix|AMZN|DSNP`
5. 去帧率标记：`(?i)(?<!\d)(?:24|25|30|50|60|120)\s*(?:fps|帧)(?![\u4e00-\u9fffA-Za-z0-9])`
6. 去更新尾巴：`(更新至|更至|连载至|連載至)\s*$`
7. 去版本/语言尾巴：`国语版|国配版|普通话版|粤语版|台语版|闽南语版|原声版|配音版|中字版|字幕版|台版|台灣版|台湾版|港版|港澳版|大陆版|內地版|内地版|中国版|中國版|泰版|泰国版|泰國版|韩版|韩国版|韓國版|日版|日本版|美版|美国版|美國版|英版|英国版|英國版`
8. 去质量词：`真彩|臻彩|高码|高码率|无水印|无台标|国语|国配|国粤|粤语|中字|字幕|内封|简繁|双语|官中|杜比|合集|全集|完结|未删减|加长版|修复版`
9. 去 `#`/`＃`
10. 去独立出现的体裁词：`(^|\s)(动漫|动画|电视剧|剧集|电影|综艺)(\s|$)` → 空格
11. 去 `[._\-+]+` → 空格；压缩连续空白；去首尾
12. 中英混排清理：
    - `(?i)^[a-z]\s+(?=.*[\u4e00-\u9fff])` 去掉开头单字母
    - `(?i).*[\u4e00-\u9fff].*\s+[a-z]` 时去掉结尾单字母
    - 去掉中日韩字符之间的空格：`([\u4e00-\u9fff])\s+([\u4e00-\u9fff])` → `$1$2`
13. 去首尾标点：`^[\s:：,，.。·|/\\]+|[\s:：,，.。·|/\\]+$`

**兜底**：清洗结果为空时返回原始输入（不得返回空串导致搜索失败）。

### 3.4 年份提取

```text
YEAR_PATTERN   = (?<!\d)(19\d{2}|20\d{2})(?!\d)     // 归一化用
RELEASE_DATE   = (?<!\d)(?:19|20)\d{2}(?:[-./_](0?[1-9]|1[0-2])[-./_](0?[1-9]|[12]\d|3[01])|(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01]))(?!\d)
```

- 源年份优先级：`Vod.year` → `Vod.name` → 搜索关键词。
- 有效范围 1900–2099；`release_date` 形态先剥离再取年份，避免把 `20240115` 当标题。

### 3.5 季度信号提取

```text
SOURCE_SEASON = (?i)(?:第\s*([零〇一二三四五六七八九十两0-9]+)\s*[季部]
                  | season\s*([0-9]{1,2})
                  | s([0-9]{1,2})(?:[-._\s]*e[0-9]{1,3})?)
```

- 中文数字需归一为阿拉伯数字（`零〇一二三四五六七八九十两`）。
- 多个信号取**第一个 > 0** 的结果；无法解析返回 `-1`（不是 `0`）。
- 该结果只是**候选信号**，交给 `02` §3 的解析器裁决。

---

## 4. 匹配流程

```text
autoMatch(sourceTitle, vod, searchKeyword?)
   │
   ├─ 0. 前置检查：tmdbConfig.isReady() == false → 直接返回"未配置"（不发起请求）
   │                 站点策略不允许（§6）      → 直接返回"已禁用"（不发起请求）
   │
   ├─ 1. 缓存查询（§2.4 三层键）
   │      命中手动 → 直接使用
   │      命中自动 → 校验分季变体防护（§5.4）后使用
   │
   ├─ 2. 标题清洗 → cleanTitle(sourceTitle)（§3.3）
   │
   ├─ 3. 候选查询词生成
   │      主查询：cleanTitle(sourceTitle)
   │      备选：cleanTitle(searchKeyword)、cleanTitle(vod.name)、cleanTitle(vod.remarks)
   │      任一查询返回非空即停止（不并发打多组请求）
   │
   ├─ 4. 搜索结果过滤
   │      只保留 mediaType ∈ {movie, tv}（§5.1）
   │      期望媒体类型已知时按类型过滤（§5.2）
   │
   ├─ 5. 选择最佳项（§5.3 三级：strict → containedYear → smart）
   │      全部失败 → 年份拆分重试（§5.5）
   │      仍失败 → 返回"未匹配"
   │
   └─ 6. 落盘
          自动结论 → put（不覆盖手动）
          并记录 matchedAt 与 source
```

约束：

- **禁止**在未配置 Key 时发起任何 TMDB 请求（`00` §3.4）。
- **禁止**在站点被禁用时发起任何 TMDB 请求。
- 候选查询词数量上限 **3**，每个查询最多一次网络请求（失败后不做同参数重试）。
- 匹配失败**不抛异常**，返回结构化"未匹配"结果，详情页继续使用站源数据。
- `AuthException` 与取消异常必须**向上传播**，不得被"未匹配"吞掉（否则熔断与取消语义失效）。

---

## 5. 评分与选择

### 5.1 搜索结果归一化

从 TMDB `search/{movie,tv,multi}` 的 `results[]` 构造 `TmdbItem`：

- 跳过 `media_type` 不属于 `{movie, tv}` 的条目；
- `title`：`movie` 取 `title`（回退 `name`），`tv` 取 `name`（回退 `title`）；
- `date`：`movie` 取 `release_date`，`tv` 取 `first_air_date`；
- `subtitle` = `buildSubtitle(mediaType, date, vote)`，`vote` 形如 `8.2`（`vote_average <= 0` 时为空）；
- 海报/背景图地址由 `image(imageBase, poster_path)` / `image(backdropBase, backdrop_path)` 拼接（`03` §4.4）。

### 5.2 媒体类型约束

期望类型来源优先级：

1. 调用方显式传入（如从剧集上下文进入）；
2. 源标题含季度/集数信号 → `tv`；
3. 无法判断 → 不过滤。

过滤后为空则视为本次匹配失败（不回退到未过滤结果，避免"电影被当成剧集"）。

### 5.3 三级选择

| 级别 | 名称 | 条件 | 上游依据 |
| --- | --- | --- | --- |
| 1 | `strict` | `normalize(item.title) == normalize(keyword)`，且（源年份未知 或 年份相等 或 该季 `air_date` 年份相等） | `chooseStrictMatch` |
| 2 | `containedYear` | 源年份已知且相等；`normalize` 后长度均 ≥ 4；互相 `contains` | `chooseContainedYearMatch` |
| 3 | `smart` | 仅当设置项"智能匹配"开启；标题相等或去年份后相等；无年份时接受同名；有年份时接受 ±1 年 | `chooseSmartMatch` |

`strict` 命中多个时：

- 若全部候选标题相同，用**详情分季评分**裁决（§5.4）；分差 ≥ 200 才采纳，否则取候选第一个（对齐上游 `matches.get(0)`）。

`smart` 命中的优先级：年份精确 > ±1 年 > 同名。仍无法确定 → 未匹配。

### 5.4 分季变体防护

TMDB 中存在把一部剧拆成多个独立条目的形态（标题含"分季"）。必须惩罚，否则会把"第一季"匹配到"某剧 分季版"。

| 场景 | 得分 |
| --- | --- |
| 详情标题**不含**"分季"，且源文本不允许分季变体 | `+140`（`NON_SPLIT_BONUS`） |
| 详情标题**不含**"分季"，且源文本允许分季变体 | `0` |
| 详情标题**含**"分季"，且源文本显式提到"分季" | `+160`（`EXPLICIT_SPLIT_BONUS`） |
| 详情标题**含**"分季"，源文本未提"分季" | `-240`（`SPLIT_SEASON_PENALTY`） |

判定细节：

- "含分季" = `normalize(detailTitle)` 包含 `"分季"`；`detailTitle` = `name + original_name + title + original_title` 拼接后归一。
- "源文本允许分季变体" = 源文本提到"分季" **或** 含显式季度标记：
  ```text
  (?is).*(第\s*[零〇一二三四五六七八九十两0-9]+\s*[季部]|season\s*[0-9]{1,2}|s[0-9]{1,2}(?:[-._\s]*e[0-9]{1,3})?).*
  ```
- `normalize(text)` = 去掉 `[\s·•:：\-_/\\|()（）\[\]【】]+` 后 `trim` 并小写。
- `isUnwantedSplitSeasonVariant(source, detail)` = 含分季 **且** 源文本不允许 → 该候选**直接丢弃**（不是降分）。

**推送标题守卫**（`shouldAutoMatchPushTitle`）：当来源是外部推送/投屏时，只有满足以下全部条件才允许自动匹配，否则跳过：

- 非 URL（不匹配 `(?i)^(?:https?|rtsp|rtmp|mms|magnet|ed2k|thunder|video|file):\S+$`）；
- 非通用标题（不匹配 `(?i)^(?:online\s*video|network\s*video|web\s*video|video|push|cast|在线视频|网络视频|网页视频|推送|投屏|视频)(?:\s*(?:[-_#.]?\s*\d{1,4}))?$`）；
- 含中英文字符；
- 归一后长度 ≥ 2 且不是纯数字。

> PC 端是否需要推送路径取决于 `03` §7 的播放入口设计；若 Phase 4 不实现推送，则该守卫**保留在纯函数里但不接入**，由 `05` 的单元测试锁定，避免后续接入时重新设计。

### 5.5 年份拆分重试

当源标题形如 `剧名 2024` 而 TMDB 主条目标题不含年份时，`strict` 会失败。重试规则：

```text
splitYearQuery(keyword, vod, expectedYear):
  year = expectedYear > 0 ? expectedYear : sourceYear(keyword, vod)
  if year <= 0: return null
  source = (keyword 含该年份) ? keyword : (vod?.name ?? "")
  if firstYear(source) != year: return null
  query = removeYearFromTitle(source, year)
  if query 为空 或 normalize(query) == normalize(source): return null
  return (query, year)
```

- `removeYearFromTitle` 先删年份（前后非数字边界），再去空括号、`[._\-+]+` → 空格、压缩空白、去首尾标点，最后再走一次 `cleanTitle`。
- 重试**只做一次**，且只在第一次匹配完全失败时触发。

### 5.6 搜索列表排序（详情页搜索入口用）

`sortSearchResults(items, keyword, sourceYear)` 排序键（依次）：

1. 标题相似度（降序）；
2. 年份距离（升序，未知年份记 9999）；
3. 语言/地区偏好得分（降序）；
4. 评分（降序）。

标题相似度：

| 条件 | 得分 |
| --- | --- |
| 归一后完全相等 | `1000` |
| 一方包含另一方 | `800 + round(200 * min/max)` |
| 其他 | `max(0, 700 - round(700 * levenshtein / max))` |

语言/地区偏好（由 `config.language` 推导 preferredLanguage / preferredCountry）：

| 条件 | 得分 |
| --- | --- |
| `origin_country == preferredCountry` | `+40` |
| 地区属偏好语种区（zh → CN/HK/TW/MO/SG；ja → JP；ko → KR） | `+25` |
| `original_language == preferredLanguage` | `+20` |

---

## 6. 站点策略

### 6.1 三张规则表

| 配置字段 | 语义 | 判定 |
| --- | --- | --- |
| `disabledSites` | 黑名单 | 精确命中 key 或 name → **禁用**（优先级最高） |
| `allowedSites` | 白名单 | 精确命中 key 或 name → **启用** |
| `enabledSites` | 启用规则 | 精确命中 key 或 name → **启用**；子串命中 → 启用 |

判定顺序（对齐上游 `TmdbConfig.isSiteEnabled`）：

```text
1. disabledSites 精确命中 key 或 name        → false
2. allowedSites  精确命中 key 或 name        → true
3. enabledSites  精确命中 key 或 name        → true
4. disabledSites 子串命中 key 或 name        → false
5. enabledSites 为空                          → true
6. enabledSites 子串命中 key 或 name          → true
7. 否则                                        → false
```

### 6.2 默认禁用规则

未显式配置 `excludeKeywordsConfigured` 且 `disabledSites` 为空时，使用默认规则：

```text
[音] [听] [书] [漫] [短] [设] [画] [漫画] [小说] 配置 [配]
```

**括号归一**（必须实现）：同一分类标记在不同源里写作 `[音]`、`「音」`、`【音】`、`〔音〕`、`［音］`。
规则与被匹配文本都先做归一：

```text
「 」 → [ ]    【 】 → [ ]    〔 〕 → [ ]    ［ ］ → [ ]
```

上游实测依据：猫源 57 个站点全部使用全角角括号，若不做归一则**默认规则一条也匹配不上**。

**不可互换的写法**（子串包含语义）：

- `[书]` 命中 `[书]xxx`，**不**命中 `[小说]xxx`（因为 `[小说]` 里 `[书` 后面跟的是 `说` 而不是 `]`）。
- 因此 `[书]` 与 `[小说]`、`[漫]` 与 `[漫画]` 必须同时保留。
- `配置` 不带括号，是纯文本子串匹配，能命中 `「设」配置`、`[配置]xxx`。

### 6.3 站点解析（key → 真实站点）

对齐上游 `TmdbSitePolicy.isEnabled`：传入的 key/id 可能来自内联或推送来源，需要先解析为真实站点再判定：

```text
resolve(key, id):
  内联来源（若 PC 端支持）→ 取原始站点
  否则 → SiteRegistry 按 key 查站点
判定时使用站点自身的 key 与 name（而非传入值）
```

找不到站点时，退回使用传入的 key、name 视为空串。

### 6.4 站点策略的生效边界

站点被禁用时：

- 不发起 TMDB 请求；
- 详情页不展示 TMDB 区块（不显示"暂无数据"占位，直接不渲染）；
- 已有缓存**不删除**（用户可能只是临时关闭）；
- 历史与续播仍走来源身份（`02` §6 的 `Unknown` 路径）。

---

## 7. 手动匹配

### 7.1 入口

| 入口 | 位置 | 行为 |
| --- | --- | --- |
| 首次匹配失败 | 详情页 TMDB 区块空态 | 显示"匹配 TMDB"按钮 |
| 匹配结果不满意 | 详情页 TMDB 区块头部 | 显示"重新匹配"按钮 |
| 仅重选季度 | 已匹配作品的季度选择器 | 进入季度绑定流程（`02` §8），**不改媒体身份** |

### 7.2 流程

```text
打开搜索弹窗
  → 预填当前 cleanTitle 作为查询词
  → 支持 Provider ID 直达：输入 tmdb:12345 / movie:12345 / tv:12345 → 直接构造身份，跳过搜索
  → 展示结果列表（海报 + 标题 + 年份 + 类型 + 评分）
  → 用户选定
  → putManual(siteKey, vodId, [详情名, Intent 名, 当前 Vod 名], item)
  → 若为剧集且季度未确认 → 立即进入季度绑定步骤（02 §8）
  → 刷新详情页
```

**Provider ID 直达**必须支持三种写法（对齐 tinyMediaManager / Jellyfin 的可借鉴点）：

```text
tmdb:12345        → 类型未知，先查 detail 再判定
movie:12345       → 强制 movie
tv:12345          → 强制 tv
```

### 7.3 手动结论的持久性与排他性

- 手动结论写入后，**自动匹配不得覆盖**（`put` 提前返回）。
- 媒体重新匹配（用户改选另一部作品）时，旧的手动季度绑定必须失效（`02` §8.4）。
- 源内容显著变化（来源指纹不匹配）时，季度绑定失效但**媒体身份保留**。

### 7.4 冲突表达

PC 端不引入 `tmdbId = -1`。冲突用显式类型表达：

```dart
sealed class TmdbMatchResult {
  const TmdbMatchResult();
}

class TmdbMatchHit extends TmdbMatchResult { final TmdbMatchRecord record; ... }
class TmdbMatchMiss extends TmdbMatchResult { final TmdbMissReason reason; ... }
class TmdbMatchConflict extends TmdbMatchResult { final String sourceTitle; ... }
class TmdbMatchDisabled extends TmdbMatchResult { ... }   // 未配置 / 站点禁用
```

`TmdbMissReason` ∈ `notConfigured` / `siteDisabled` / `noCandidates` / `ambiguous` / `networkFailure` / `authFailure`。
其中 `networkFailure` 与 `authFailure` 需要携带 `AppError`（`03` §4），供 UI 决定"重试"或"去配置"。

---

## 8. 失败与降级

| 场景 | 处理 | 不得发生 |
| --- | --- | --- |
| 未配置 Key | 返回 `TmdbMatchDisabled(notConfigured)`，UI 提示去设置 | 发起请求；显示"无 TMDB 数据" |
| 站点被禁用 | 返回 `TmdbMatchDisabled(siteDisabled)`，UI 不渲染 TMDB 区块 | 发起请求；删除缓存 |
| 搜索无结果 | 返回 `TmdbMatchMiss(noCandidates)` | 编造身份；回退到"第一季" |
| 多个候选同等合理 | 返回 `TmdbMatchMiss(ambiguous)`，UI 提示手动匹配 | 静默取第一个 |
| 网络失败 | 返回 `TmdbMatchMiss(networkFailure)`，携带 `AppError` | 清空已有缓存；阻塞详情页渲染 |
| 401/403 | 返回 `TmdbMatchMiss(authFailure)`，触发熔断（`03` §3.4） | 连续重试打爆配额 |
| 请求被取消 | 抛出取消异常，**不落盘、不写缓存** | 把取消当成"未匹配" |
| 匹配到分季变体 | 丢弃该候选并继续 | 采纳后污染季度解析 |

**错误态与未匹配的区分（实现契约）**：`TmdbMatchMiss.reason` 决定 UI 形态：

| reason | UI 阶段 | 是否可重试 |
| --- | --- | --- |
| `notConfigured` | `disabled`（渲染「未配置 TMDB」+ **[去设置]** 入口） | — |
| `siteDisabled` | `disabled`（**整块不渲染**） | — |
| `noCandidates` / `ambiguous` | `ready`（显示“未匹配”+ 手动匹配入口） | 否 |
| `networkFailure` | `failed`（错误文案 + 重试） | **是** |
| `authFailure` | `failed`（鉴权文案 + 去设置） | 否 |

即：**只有 `networkFailure` 是可重试错误态**；无候选是正常业务结果，不得渲染成错误。

**部分失败的处理**：候选查询词最多 3 个，任一查询成功即停止；全部失败时，
只要其中至少一次是网络错误，就返回 `networkFailure`（而不是 `noCandidates`）——
否则用户会把“网络不通”误认为“TMDB 没有这部作品”。

---

## 9. 可观测性

必须产出的日志字段（脱敏后，见 `03` §8）：

| 事件 | 字段 |
| --- | --- |
| 匹配开始 | `site`, `vodId`, `sourceTitleLen`, `queryCount` |
| 缓存命中 | `layer`（entry / entry+title / title-scope）, `manual`, `ageMs` |
| 搜索 | `query`, `resultCount`, `filteredCount`, `mediaType` |
| 选择 | `level`（strict / containedYear / smart）, `score`, `secondScore`, `delta` |
| 落盘 | `tmdbId`, `mediaType`, `source`（auto / manual） |
| 失败 | `reason`, `httpStatus`, `elapsedMs` |

**禁止记录**：完整源标题（可能含站点私有命名）、API Key / Access Token、完整请求 URL 的 query（含 `api_key`）。

---

## 10. 与上游的差异汇总

| 项 | 上游（Android） | PC 端 | 理由 |
| --- | --- | --- | --- |
| 冲突表达 | `Entry.conflict` + `tmdbId = -1` | 显式 `TmdbMatchConflict` | 避免负数 ID 语义泄漏到季度解析 |
| 缓存存储 | Gson JSON 字符串（`Prefers`） | SQLite 表 + 快照字段（`03` §6） | PC 端已有 SQLite；可查询、可迁移 |
| 智能匹配开关 | `Setting.isTmdbSmartMatch()` | 设置项 `tmdb.smartMatch`（默认开） | 行为对齐 |
| AI 回退 | `MediaTitleRequest` 支持 AI 候选 | **不实现**，但保留 `TmdbMissReason` 扩展位 | `00` §4.3 |
| 标题学习 | `MediaTitleLearningExample`（AI 学习样本） | **不实现** | 依赖 AI 模块 |
| 推送守卫 | 接入推送链路 | 纯函数 + 单测锁定，暂不接入 | 视 `03` §7 播放入口结论 |
| 豆瓣评分 | 富集 | 不填充 | `00` §4.3 |

---

## 11. 开放问题（实施前需确认）

| # | 问题 | 影响 | 建议 |
| --- | --- | --- | --- |
| Q1 | 是否需要在 Phase 4 提供"跨站同名作品沿用"（全局标题域）？ | 决定缓存复杂度 | **需要**，否则同一作品在不同站点要重复手动匹配 |
| Q2 | 手动匹配弹窗是否必须支持 Provider ID 直达？ | 决定 UI 复杂度 | **需要**，成本低、收益高（用户可从 TMDB 网页复制 ID） |
| Q3 | 智能匹配默认开还是关？ | 影响误匹配率 | **默认开**（对齐上游），但设置项必须可关 |
| Q4 | 匹配缓存是否随"重置缓存"清空？ | 影响用户体验 | **清空 TMDB 元数据缓存，但保留手动匹配结论**；手动结论属于用户资产 |
| Q5 | 站点被禁用后，缓存是否仍可读取用于展示？ | 影响一致性 | **不可读**（禁用即不渲染），但**不删除** |

---

## 12. 验收要点（详见 `05`）

本文件对应的验收项：

1. 标题清洗 13 步逐条样例（含中文数字季度、`《书名》`提取、扩展名、清晰度词）。
2. 年份提取与 `release_date` 剥离。
3. 三级选择的判定用例，含"strict 命中多个 → 分季评分裁决"。
4. 分季变体四个得分档与"直接丢弃"语义。
5. 排序键顺序与相似度公式边界（相等 / 包含 / 编辑距离）。
6. 站点策略判定顺序 7 条，含括号归一与 `[书]` vs `[小说]` 不互换。
7. 缓存三层键读取顺序，含"同 `vodId` 多作品"与"手动不被自动覆盖"。
8. `TmdbMatchResult` 六种 `TmdbMissReason` 全覆盖。
9. 未配置 / 站点禁用时**零网络请求**（用请求计数器断言）。
