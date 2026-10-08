# 04 · TMDB 详情页、季集 UI 与播放入口设计

- 状态：设计指导，**已实施**（见 `docs/phase4/README.md` §2.2、§3）
- 日期：2026-10-06
- 上游参考：`TmdbDetailActivity`（12667 行，**只作功能清单参考**）、`TmdbUIAdapter`（2451 行）、`TmdbHeaderView`（2509 行）、`TmdbVideo`、`TmdbVideoPlayback`、`docs/tmdb-related-video-playback-design.md`、`docs/superpowers/specs/2026-08-18-tmdb-related-video-windowed-player-design.md`
- PC 端落点：`lib/ui/tmdb_detail_page.dart`、`lib/ui/tmdb_widgets.dart`、`lib/state/tmdb_state.dart`、`lib/ui/player_page.dart`（季集身份透传）
- 关联：`01`（匹配）、`02`（季度）、`03`（服务与存储）、`05`（测试）

---

## 1. 目标与边界

### 1.1 目标

1. 站点详情页在不破坏既有浏览闭环的前提下，**增加 TMDB 元数据增强**。
2. 提供**季度导航 + 选集过滤**，且严格遵守"元数据不创建播放项"（`02` §4.1）。
3. 提供**手动匹配**与**手动季度绑定**入口（`01` §7、`02` §8）。
4. 提供**纯 TMDB 身份**的详情页（从 TMDB 搜索/相关推荐进入，没有站源 Vod）。
5. 把**季度身份**透传给播放链路，使季度进度与换源判定成立。

### 1.2 非目标

| 非目标 | 说明 |
| --- | --- |
| 应用内播放 YouTube 相关视频 | PC 端无该链路；改为浏览器打开 + 复制链接（§7） |
| 多套详情页形态（原生/融合/炫彩/直放） | 上游的 5 种 `detail_open_mode` 是 TV 遥控器场景的产物；PC 端只保留**一套**桌面形态 |
| 内嵌窗口化播放器 | 上游的 `TmdbVideoPlayerDialog` 是"相关视频窗口化"；PC 端相关视频不应用内播放，故不需要 |
| 个人推荐 / AI 推荐行 | `00` §4.3 |
| 详情页内直接选源播放 | 保持既有"详情 → 播放页"两段式（对齐 Phase 1/2/3 既有流程） |

---

## 2. 服务与状态拆分

### 2.1 为什么必须拆

上游 `TmdbUIAdapter` 是 2451 行的上帝类，同时负责：匹配、缓存、季度解析、剧集元数据应用、
推荐加载、评分格式化、UI 文案生成。`TmdbDetailActivity` 更达 12667 行，上游自己已把它列为
重构对象（`docs/refactoring/TMDB_DETAIL_ACTIVITY_REFACTORING_ROADMAP.md`）。

PC 端**不继承该技术债**，按职责拆成三层：

| 层 | 类 | 职责 | 依赖 |
| --- | --- | --- | --- |
| 纯逻辑 | `lib/core/tmdb_identity.dart` | 身份、`TmdbMatchRecord`、三层键、冲突类型 | 无 |
| 纯逻辑 | `lib/core/tmdb_title.dart` | 标题清洗、年份、季度信号、评分公式 | 无 |
| 纯逻辑 | `lib/core/tmdb_season.dart` | `SeasonScope`、解析器、可播放季度、分段校验、指纹 | 无 |
| 服务 | `lib/services/tmdb_service.dart` | 端点封装、熔断、错误映射 | `http` |
| 服务 | `lib/services/tmdb_cache.dart` | TTL、陈旧兜底、文件读写 | `dart:io` |
| 服务 | `lib/services/tmdb_identity_service.dart` | 匹配编排 + 缓存读写 | 上面三者 + `AppDatabase` |
| 服务 | `lib/services/tmdb_season_service.dart` | 季度解析编排 + 绑定读写 | `tmdb_season` + `AppDatabase` |
| 服务 | `lib/services/tmdb_enrichment_service.dart` | 把元数据应用到 `Vod` / `VodPlayLine` / `VodEpisode` | 上面 + `TmdbService` |
| 状态 | `lib/state/tmdb_state.dart` | `ChangeNotifier`，供 UI 订阅 | 上面全部 |

**约束**：`lib/core/**` 不得 `import` `flutter/material.dart`，也不得 `import` `dart:io`
（纯逻辑必须可在 `flutter test` 里无副作用地运行）。

### 2.2 `TmdbState` 的字段

```dart
class TmdbState extends ChangeNotifier {
  // 配置
  bool get configured;                     // config.isReady()
  bool get siteEnabled;                    // 01 §6

  // 匹配
  TmdbMatchResult? matchResult;            // 01 §7.4
  TmdbItem? get item;
  Map<String, Object?>? get detail;

  // 季度
  Resolution? resolution;                  // 02 §3.2
  SeasonScope get scope;
  List<int> get availableSeasons;          // 02 §4.3
  int get selectedSeason;                  // -1 表示扁平
  Map<int, int> get seasonEpisodeCounts;

  // 剧集
  List<TmdbEpisode> get episodes;          // 当前季度

  // 加载
  TmdbLoadPhase get phase;                 // idle / loading / ready / failed / disabled
  AppError? get error;
  bool get busy;

  // 代际（防迟到响应）
  int get generation;
}
```

**代际机制**（对齐 Phase 3 的详情竞态处理，见 `docs/phase3/README.md` 门禁"详情竞态与归属"）：

- 每次 `load(vod)` 递增 `generation`；
- 所有异步回调必须先校验 `generation == current`，否则**丢弃**；
- 离开详情页时调用 `dispose()`，取消在途请求并清空状态。

### 2.3 `flagKey` 生成

```dart
String flagKeyOf(VodPlayLine line, int index) => '${line.flag}#$index';
```

- 用于 `02` §2.2 的线路级绑定键。
- 若同一详情内 `line.flag` 唯一，则 `flagKey == line.flag`（不加后缀），减少绑定碎片。

---

## 3. 站点详情页的 TMDB 增强区块

### 3.0 视觉重设计（2026-10-07 用户反馈后的强化）

本轮把详情页从「文字 + 小缩略图」升级为**以图片为骨架**的形态。
背景：用户反馈「每集没有对应的海报卡片 / 没有海报、导演等信息 /
剧照·演职人员·相关推荐点击无效 / 详情页需要重新美化，用剧集海报·剧照当动态背景」。

| # | 要求 | 实现 | 门禁 |
| --- | --- | --- | --- |
| V1 | **动态背景**用剧集海报/剧照 | `TmdbBackdropSlideshow`：`backdrops` 优先、无则回退海报；5 秒一张、环形、单张不轮播；只在路由可见时计时 | `phase4_tmdb_detail_view_test.dart`（假时钟推进后换图）、`tmdb_detail_visual_flow_test.dart`（真实图片解码） |
| V2 | 头部有**海报 / 导演 / 评分 / 时长 / 季集数 / 类型 / 地区** | `TmdbDetailData` + `_HeaderContent`；时长缺失时用已加载剧集的**众数时长**回退 | 同上 + `phase4_tmdb_detail_model_test.dart` |
| V3 | **每集都有海报卡片**（剧照 + 集号 + 标题 + 日期），且**卡片是唯一选集入口** | `TmdbEpisodeStrip` + `TmdbEpisodeCards.build`：不补集、不丢集；无剧照时用本剧剧照池按序回退；**不再渲染文字版集按钮**（2026-10-08 用户反馈：二者取其一） | `tmdb_detail_flow_test.dart`（卡片数 + 文字按钮为 0）、`phase4_tmdb_detail_view_test.dart` |
| V4 | 剧照**可点击** | `_PhotoWall` → `TmdbPhotoViewerDialog`（定位到被点击那张、左右翻页、`←/→/Esc`） | `phase4_tmdb_detail_view_test.dart`、`tmdb_detail_visual_flow_test.dart` |
| V5 | 演职人员**可点击** | `_PeopleWall` → `TmdbPersonPage`（简介 / 照片 / 作品；作品可继续进入详情） | 同上 |
| V6 | 相关推荐**可点击** | `_RecommendationWall` → 该作品的 TMDB 详情页（可递归进入） | 同上 |
| V7 | 单集详情 | `TmdbEpisodeSheet`：剧照 + 标题 + 日期 + 时长 + 评分 + 简介 + 动作 | `phase4_tmdb_detail_view_test.dart` |
| V8 | **点击线路切换集数卡片** | `TmdbLineSelector`（对齐上游 `@id/flag`）+ 单线路单屏剧集区；换线路保留「季度意图」并自愈到该线路真有集的季度 | `tmdb_detail_flow_test` 步骤 7/7.5、`phase4_tmdb_detail_view_test.dart` |
| V9 | 剧集区块头：正序/倒序 + 列表/网格 | `TmdbEpisodeHeader` + `TmdbEpisodeStrip.gridMode`（对齐上游 `episodeReverse` / `episodeViewMode` / `episodeGrid`） | 同上 |
| V10 | 信息表：类型/地区/年份/时长/季集/状态/导演/演员/评分/备注/语言 | `TmdbInfoTable`（两列对齐，空值行自动跳过；对齐上游 `site/year/area/type/director/actor` 元信息行） | 同上 |
| V11 | 海报墙（与剧照区分） | `TmdbDetailSections` 的 `tmdb-section-posters`（对齐上游 `@id/tmdbPosters`） | `phase4_tmdb_detail_view_test.dart` |
| V12 | **制作团队头像卡片**（导演/编剧/制片可点击） | `_CrewWall` 复用 `_PeopleWall`（对齐上游 `@id/tmdbCrew` + `adapter_tmdb_cast.xml`：头像 + 姓名 + 职务，可进人物页） | `phase4_tmdb_detail_view_test.dart`、`tmdb_detail_visual_flow_test.dart` |
| V13 | **线路季度记忆**：切走再切回恢复该线路的季度 | `TmdbState._lineSeasonMemory`（`flag → season`，上限 64）+ `rememberedSeasonOfLine`；`selectSeason`/`selectLine`/解析完成三处写入 | `phase4_tmdb_state_test.dart`、`tmdb_detail_flow_test` 步骤 9 |
| V14 | **多线路共用同一份 TMDB 数据** | `loadForVod` 判定「同一作品」后复用 `_detail`/`_cast`/`_creators`/`_photos`/`_recommendations`/`_videos`/`_seasonEpisodeCounts`；`loadDetail(reuseDetail:)` 零请求；`TmdbService.detail` 缓存键**双向**回退 | `phase4_tmdb_state_test.dart`「多线路共用」2 例 |

**单线路单屏（V8 的关键约束）**：线路条是**切换器**，页面只渲染**当前线路**的
剧集区。早期实现把每条线路各渲染一屏卡片，多线路站点会把详情页拉成几屏长，
用户还得自己找哪一屏是当前线路；上游同样只渲染当前线路的选集区。

**换线路的两个硬约束**（都踩过）：

1. **季度意图必须传递**：新线路可能没有当前季度的集（「线路一 S1+S2」→
   「只有 S2 的线路二」）。不传意图就会回落到默认季（S1），线路二在 S1 下
   **一集都没有** → 剧集区空白。`selectLine(flag, preferredSeason:)` 承载意图，
   `loadDetail` 消费后清零（只生效一次）。
2. **重新加载必须保留当前线路**：`reloadTmdb` 早期固定取 `playLines.first`，
   于是点线路 → 触发 reload → 当前线路被悄悄改回线路一，卡片又变回线路一的集
   （用户看到的「点了线路没反应」）。`loadForVod` 现在保留 `_selectedLineFlag`。

兜底：`reconcileSeasonWithLine()` 在季度解析后检查「当前季度在该线路上是否有
集」，没有就换成 `availableSeasons` 里第一个真有集的季度；挑不到则保持原值
（UI 显示空态，**不猜**）。

**「作品维度」与「线路维度」的分界（V13/V14 的核心）**：

| 维度 | 数据 | 换线路时 |
| --- | --- | --- |
| **作品维度** | 详情响应、演职人员、推荐/相似、剧照、相关视频、季集数 | **复用**（不重发请求）——上游 `TmdbUIAdapter` 同样只在作品维度加载一次 |
| **线路维度** | 季度解析结果、可播放季度、剧集元数据、选中季度 | **重算**（季度是线路级的，`02` §2.2） |

判定「同一作品」用 `vodId` + 源标题，**不能**用 `_detail != null`：`loadMatch`
为了构造匹配记录快照会先请求一次详情（`includeRelated: false`），首次加载时
`_detail` 尚未赋值，用它会把第二次调用误判成「换了作品」。

**季度意图的优先级**：线路记忆 > 调用方给的当前季度 > 解析器默认。
`loadDetail` 必须**采纳解析器确证的季度**（`KnownSeason(n)`），早期实现无条件用
`_defaultSeasonOf(availableSeasons)` 覆盖，会把「记住的第 2 季」改回第 1 季
（用户反馈的「切回线路后又会重新转换一次」）。

**线路隔离（不得违反）**：剧集元数据只作用于**当前线路**（`04` §4.3）。
判定必须用 `TmdbState.flagKeyForLine(line)` 与 `sourceLine?.flagKey` 比较，
因为绑定键在「同 flag 重复」时会带 `#index` 后缀——用别的规则比较会让
「当前线路」永远判否，剧集剧照与 TMDB 集标题整块不生效（实测缺陷）。

**证据**：`docs/phase4/evidence/tmdb-detail-header.png`、`tmdb-photo-viewer.png`、
`tmdb-person-page.png`、`tmdb-recommendation-detail.png`
（由集成用例 `tmdb_detail_visual_flow_test.dart` 真实光栅化落盘）。

### 3.1 布局（自顶向下）

```text
┌───────────────────────────────────────────────────────────┐
│ ⓪ 动态背景（TMDB 剧集海报/剧照轮播 + 渐变遮罩）              │
│    ├─ 无背景图 → 回退海报                                    │
│    └─ 单张    → 不轮播                                       │
├───────────────────────────────────────────────────────────┤
│ ① 头部（海报 / 标题 / 原名 / 标语 / 评分·年份·时长·季集数·    │
│    类型·地区 / 导演 / 简介）                                  │
│    └─ TMDB 增强：海报缺失时补位、简介更长时替换、评分行       │
├───────────────────────────────────────────────────────────┤
│ ② TMDB 状态条                                               │
│    ├─ 未配置   → 「未配置 TMDB」+ [去设置]                  │
│    ├─ 站点禁用 → 不渲染本区块                                │
│    ├─ 未匹配   → 「未匹配 TMDB」+ [匹配 TMDB]               │
│    ├─ 匹配中   → 骨架屏                                      │
│    ├─ 已匹配   → 「TMDB · 8.2 · 2024」+ [重新匹配] [仅选季度] │
│    └─ 失败     → 错误文案 + [重试]                            │
├───────────────────────────────────────────────────────────┤
│ ③ 季度选择器（仅 tv 且可播放季度非空）                        │
│    [第 1 季] [第 2 季] …   或  「未确定季度」+ [选择季度]      │
├───────────────────────────────────────────────────────────┤
│ ④ 线路选择（点击切换；只渲染当前线路的剧集区）                  │
├───────────────────────────────────────────────────────────┤
│ ⑤ 选集区（区块头：选集·线路·集数 + 正序倒序 + 列表网格）        │
│    └─ 剧集**海报卡片**条，唯一选集入口                         │
├───────────────────────────────────────────────────────────┤
│ ⑥ 剧照墙（点击 → 大图查看器）                                 │
├───────────────────────────────────────────────────────────┤
│ ⑦ 演职人员（点击 → 人物页）                                   │
├───────────────────────────────────────────────────────────┤
│ ⑧ 相关推荐（点击 → 该作品详情）                               │
├───────────────────────────────────────────────────────────┤
│ ⑨ 相关视频（见 §7）                                          │
├───────────────────────────────────────────────────────────┤
│ ⑩ 制作团队（导演 / 编剧 / 制片列表）                          │
└───────────────────────────────────────────────────────────┘
```

### 3.2 ① 头部增强规则（严格"不覆盖来源事实"）

| 字段 | 规则 |
| --- | --- |
| `vodName` | `sourceAwareTitle`：来源标题已含明确季度 → **保留来源标题**；否则用 TMDB 标题 |
| `vodContent` | 仅当 TMDB 翻译简介**更长**时替换 |
| `vodPic` | 仅当来源海报**为空**时补位 |
| `vodYear` | 仅当来源年份**为空**时补位 |
| `vodArea` | 仅当来源地区**为空**时补位 |
| `vodTypeName` | 仅当来源类型**为空**时补位（取 TMDB 类型名拼接） |
| `vodActor` | 仅当来源演员**为空**时补位（最多 5 位） |
| `vodDirector` | 仅当来源导演**为空**时补位（最多 5 位） |

**禁止**：覆盖来源已有的非空字段。这是"来源是事实源"原则在字段级的表现。

评分行文案（`TmdbRatingFormatter` 等价物）：

```text
tmdb > 0 && douban > 0 → "TMDB 8.2 · 豆瓣 9.1"
tmdb > 0 && douban == 0 → "TMDB 8.2"
tmdb == 0 && douban > 0 → "豆瓣 9.1"
两者皆空 → "TMDB — · 豆瓣 —"（仅在已匹配时显示占位）
```

PC 端 `douban` 恒为 0（`00` §4.3），因此实际只显示 TMDB 一侧；保留该格式化函数以兼容未来扩展，并由 `05` 单测锁定四种分支。

### 3.3 加载时序与骨架屏

```text
进入详情页
  → 0. 若未配置 / 站点禁用：不发起任何请求，直接渲染状态条（§3.1 ②）
  → 1. 缓存命中：立即渲染 TMDB 区块（无骨架屏）
  → 2. 缓存未命中：
       2.1 立即渲染骨架屏（固定高度，避免布局跳动）
       2.2 并发发起：匹配（若未匹配）→ 详情
       2.3 匹配先完成：先渲染头部增强，再等详情
       2.4 详情先完成：一次性揭开（对齐上游"UI 保持单次揭开"）
  → 3. 失败：渲染错误态，**不影响**下方线路与选集
```

**布局稳定性要求**：骨架屏高度必须与最终内容高度一致（或使用固定高度容器），
避免加载完成后选集区跳动导致误点击。

### 3.4 失败隔离（强制）

| 场景 | 行为 |
| --- | --- |
| TMDB 请求失败 | 状态条显示错误 + 重试；线路与选集**照常可用** |
| 季度解析 `ambiguous` | 显示"未确定季度"+ 选择入口；选集按扁平列表渲染 |
| 剧集元数据加载失败 | 选集保留**来源集名**；不显示空标题 |
| 演职人员/剧照/推荐失败 | 对应区块**整块隐藏**（不显示空态占位） |
| 相关视频失败 | 区块隐藏 |

`isTmdbError(AppError)` 只认 `tmdb*` 前缀（`03` §4.5），
且 `AppError.userMessage` 必须含"不影响站源浏览与播放"。

---

## 4. 季度选择器与选集联动

### 4.1 季度选择器状态

| 状态 | 展示 | 交互 |
| --- | --- | --- |
| `KnownSeason(n)`，`availableSeasons.length == 1` | 文本"第 n 季"（不显示切换控件） | 无 |
| `KnownSeason(n)`，`availableSeasons.length > 1` | 分段控件，选中 n | 切换 → §4.3 |
| `MultiSeason` | 分段控件，显示全部段所属季度 | 切换 → 应用对应段 |
| `UnknownSeason` | 文本"未确定季度" + [选择季度] | 打开 `02` §8 的绑定流程 |
| 电影 | 不渲染季度选择器 | 无 |

**默认选中规则（实现契约）**：`availableSeasons` 非空且当前未选定任何季度时，
**自动选中第一项**（即 `availableSeasons.first`），使多季作品进入详情页即有内容，
无需用户先手动切换。仅当 `availableSeasons` 为空时才保持“未确定季度”。

> 这不会伪造季度：默认选中项来自 `availableSeasons`（已由 `02` §4.3 的可播放季度
> 解析器确证），不是猜测值。

### 4.2 选集区渲染规则

```text
episodesToRender =
  scope is UnknownSeason → 线路原始剧集列表（不增不减）
  scope is KnownSeason(n) → 仅该季对应的线路剧集（按 §4.3 过滤）
  scope is MultiSeason    → 当前选中季对应段内的线路剧集
```

**选集入口只有一套**（用户反馈 2026-10-08）：渲染剧集海报卡片时**不再**渲染
下方的文字版集按钮。两套控件既是重复信息，也让用户在「点哪个」上犹豫；
卡片的信息量严格更大（剧照 / 集号 / 标题 / 播出日期 / 时长 / 单集评分）。
实现上由 `_buildLine` 只渲染 `TmdbEpisodeStrip` 保证——不存在「先渲染卡片再
按条件隐藏按钮」的分支，避免将来改动又长回两套控件。

卡片宽度按集数自适应（`_episodeCardWidth`）：≤8 集一屏 5 列、≤20 集 7 列、
更多 9 列，夹在 `[150, 300]`，使长剧集不必频繁横向滚动。

每张剧集卡片（`TmdbEpisodeCardTile`）：

| 元素 | 来源 |
| --- | --- |
| 主标题 | `TmdbEpisode.displayTitle`（有元数据）否则来源 `VodEpisode.name` |
| 副标题 | 播出日期 + 单集时长（有元数据时） |
| 剧照 | `stillUrl`；该集**无剧照**时按序回退到本剧剧照池（`detailData.photoUrls`） |
| 集号徽标 | `S{季}E{集}`（季未知时 `E{集}`） |
| 评分 | 单集 `vote_average`（> 0 时） |
| 播放 | 既有 `resolvePlayback`（**不因 TMDB 改变**）；卡片下标与过滤后的 `episodes` 一一对应，播放时再映射回线路原始下标 |

**线路隔离**：卡片只在**当前线路**上套用 TMDB 元数据
（`TmdbState.flagKeyForLine(line) == sourceLine?.flagKey`）。非当前线路的卡片
仍渲染（每集都要有画面），但不套用当前季度的集标题/剧照，避免跨线路串图。

**强制断言**：`episodesToRender.length == 该季线路剧集数`，
不得出现"TMDB 有但线路没有"的卡片（`02` §4.1）。

### 4.3 切换季度

```text
onSeasonChanged(n):
  1. 校验 n 属于 availableSeasons（否则忽略）
  2. selectedSeason = n
  3. 清空 episodes（避免旧季度残留）
  4. 重新计算 episodesToRender
  5. 重新加载该季剧集元数据（带 generation 校验）
  6. 同步切换续播位置（02 §6.3）
```

切换季度**不得**切换线路（线路由用户显式选择）；切换线路**必须**重新解析该线路的可播放季度（`02` §4.3）。

### 4.4 网格与滚动

- 剧集网格：`spanCount` 按窗口宽度自适应（PC 端 ≥ 1100 px 用 5 列，≥ 600 px 用 4 列，否则 3 列）。
- 超过 3 行时启用内部滚动（避免详情页过长）。
- 键盘：方向键移动焦点，`Enter` 播放，`Home`/`End` 跳首尾。

---

## 5. 手动匹配与季度绑定 UI

### 5.1 手动匹配弹窗

```text
┌─ 匹配 TMDB 作品 ────────────────────────────────┐
│ 搜索：[预填 cleanTitle        ] [搜索]           │
│ 提示：也可直接输入 tmdb:12345 / movie:12345 / tv:12345 │
├────────────────────────────────────────────────┤
│ [海报] 标题 (2024) · 剧集 · ★8.2                │
│ [海报] 标题 (2023) · 电影 · ★7.9                │
│ …                                              │
├────────────────────────────────────────────────┤
│                              [取消]             │
└────────────────────────────────────────────────┘
```

- 打开时**自动执行一次搜索**（不要求用户点按钮）。
- 结果排序使用 `01` §5.6。
- 选定后：
  - `movie` → 直接 `putManual` 并刷新；
  - `tv` → 进入季度绑定步骤（§5.2）。

### 5.2 季度绑定弹窗

```text
┌─ 选择 TMDB 季度 ────────────────────────────────┐
│ 作品：标题 (2024)                                │
├────────────────────────────────────────────────┤
│ ○ 自动（清除手动绑定）                            │
│ ○ 按集号自动切片     ← 失败时禁用并说明原因         │
│ ○ 保持原始集列表                                  │
│ ● 第 1 季 · 12 集 · 2024                        │
│ ○ 第 2 季 · 10 集 · 2025                        │
│ ○ 特别篇 · 3 集 · 2021                          │
├────────────────────────────────────────────────┤
│ 当前线路：线路一 · 22 集                          │
│ ⚠ 该季度 12 集与线路 22 集差异较大，请确认          │
├────────────────────────────────────────────────┤
│                              [取消] [确定]       │
└────────────────────────────────────────────────┘
```

- 每个候选必须展示集数与首播年份（`02` §8.3）。
- "按集号自动切片"在 `canSliceBySeasonCounts` 为假时**禁用**，并显示原因文案
  （对齐上游 `tmdb_season_auto_by_counts_failed`）。
- 风险提示在 `|季度集数 - 线路集数| > max(2, 20%)` 时出现。

### 5.3 仅重选季度

已匹配作品的详情页提供"仅选季度"入口：复用已有 `tmdbId`，只覆盖 `seasonNumber`/`mode`，
**不重新搜索作品**。

---

## 6. 纯 TMDB 详情页

### 6.1 使用场景

| 入口 | 说明 |
| --- | --- |
| TMDB 搜索结果 | 用户主动搜索 TMDB 作品 |
| 相关推荐项 | 从已匹配作品的 `recommendations` / `similar` 进入 |
| 演职人员作品列表 | 从 `person` 的作品进入 |
| Provider ID 直达 | 输入 `tmdb:12345` |

### 6.2 与站点详情页的差异

| 项 | 站点详情页 | TMDB 详情页 |
| --- | --- | --- |
| 身份来源 | 站源 `Vod` + TMDB 增强 | 仅 `MediaIdentity` |
| 季度选择器 | 受"可播放季度"约束 | 显示 TMDB **全部**季度（无播放约束） |
| 选集区 | 线路真实剧集 | TMDB 全部剧集（**只读**，不可播） |
| 播放按钮 | 有 | **无**；改为 [搜索站源] 入口 |
| 线路选择 | 有 | 无 |

**关键约束**：TMDB 详情页的剧集卡片**不得**显示为可播放。
点击行为 = 跳转到"按标题搜索站源"（复用既有搜索页，`lib/ui/search_page.dart`），
并把 `tmdbId` 作为身份提示带入，便于搜索结果自动匹配。

### 6.3 季度在 TMDB 详情页的语义

TMDB 详情页展示的是**元数据季度**（`02` §4.1），与"可播放季度"是两个不同概念。
UI 必须在标题上区分（例如"元数据季度"提示或统一的"季"措辞 + 无播放标记），
避免用户误以为"这里能直接播"。

---

## 7. 相关视频（`TmdbVideo`）

### 7.1 数据模型

```text
TmdbVideo = {
  id, key, site, name, type, official, size,
  iso6391, iso31661, publishedAt,
  scope ∈ { movie, tv, season, episode },
  seasonNumber, episodeNumber
}
```

- 只接受 `key` 匹配 `[A-Za-z0-9_-]{1,128}` 的条目（拒绝注入）。
- 字段长度上限：`id ≤ 128`、`name ≤ 240`、`type ≤ 64`、`iso6391/iso31661 ≤ 16`。
- `mergeAndRank(videos, preferredLanguage, limit)` 排序键：
  1. `scopeRank`：`movie/episode` > `season` > `tv`；
  2. `languageRank`：`preferredLanguage` 完全匹配 > `iso6391` 为空 > 其他；
  3. `typeRank`：`Trailer` > `Teaser` > `Clip` > `Featurette` > 其他；
  4. `official == true` 优先；
  5. `size` 降序。
- 去重按 `site + "|" + key`（`identity`）。

### 7.2 打开方式（**与上游不同**）

| 动作 | 行为 |
| --- | --- |
| 点击视频卡片 | 用系统默认浏览器打开 `https://www.youtube.com/watch?v=<key>` |
| 右键/更多 | "复制链接" |

**为什么不做应用内播放**：

1. 上游通过 `PushParser` + 站源 `PUSH` key 把 YouTube 链接交给播放器；PC 端没有该站源链路，
   新增它等于引入一个隐式站源，与"不内置站点"的合规边界冲突（主设计文档 §3.1）。
2. YouTube 播放需要额外解析（签名/防盗链），稳定性与合规成本高。
3. 相关视频是**附加信息**，浏览器打开已满足需求。

**实现约束**：

- 必须使用 `url_launcher`（或等价机制）并处理"无默认浏览器"失败 → 提示 + 复制链接兜底。
- **不得**在应用内创建 WebView 播放（避免引入浏览器内核与解码路径）。

---

## 8. 播放入口契约（季度身份透传）

### 8.1 透传什么

从详情页进入播放页时，除既有参数外，**新增**以下季度身份参数：

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| `tmdbId` | `int` | 媒体身份 |
| `mediaType` | `String` | `movie` / `tv` |
| `seasonNumber` | `int` | 已确证季度；`UnknownSeason` 时不传 |
| `episodeNumber` | `int` | TMDB 集号；无法确定时不传 |
| `flagKey` | `String` | 线路绑定键（`02` §2.2） |
| `episodeUrl` | `String` | **来源剧集 URL**（`04` §8.2 的消歧关键） |
| `episodeName` | `String` | 来源剧集名 |

### 8.2 为什么必须带 `episodeUrl`

上游的教训（`docs/tmdb-season-manual-match-design.md` 与实测）：

> 同一 TMDB 集可能存在多个版本（不同 URL、名称近似）。若只用 TMDB 集号判同集，
> 多版本会映射到同一季集号，导致"点第二个版本却播第一个"。
> **URL 才是同一 TMDB 集内区分版本的唯一可靠标识。**

因此 PC 端的剧集匹配优先级固定为：

```text
1. episodeUrl 精确相等
2. episodeName 相等（忽略大小写）
3. TMDB 季集号相等（兜底）
```

并保留两条兼容语义（`05` §3.5 用测试锁定）：

- **URL 变但集名相同 → 仍视为同集**（线路换 CDN 的容错）；
- **同 TMDB 集号 + URL 与集名都不同 → 仍视为同集**（跨源续播）。

### 8.3 播放页消费

`PlayerPage` 接收上述参数后：

1. 用 `episodeUrl` 优先在 `playLines` 中定位剧集（`04` §8.2 的三段优先级）；
2. 定位失败时回退到 `episodeName`，再回退到 TMDB 集号；
3. 播放中按 `02` §6.2 写季度进度（`UnknownSeason` 时只写来源 `history`）。

**约束**：季度身份**不进入** `PlaybackDecision`；`PlaybackDecision` 的产生逻辑保持 Phase 2/3 不变（`03` §7）。

### 8.4 自动连播

自动连播时，下一集的选择必须：

1. 仍在**当前线路**内（不跨线路自动切换，除非用户开启"自动换源"）；
2. 仍在**当前季度**内；
3. 跨季度边界时**停止**自动连播（不跨季连播）。

---

## 9. 续播与换源 UI

### 9.1 续播

| 场景 | 行为 |
| --- | --- |
| 从历史进入详情页 | 定位到季度进度的季/集（`02` §6.3） |
| 季度未知 | 按来源 `history` 定位，不猜测季度 |
| 季度进度存在但对应线路失效 | 在同季度兼容线路中提示"可切换线路继续"（不自动跨季） |
| 位置小于 5 秒 | 不恢复（对齐既有 `resumeThreshold`） |

### 9.2 换源

```text
换源面板 = 当前季度内的兼容线路（02 §7.3）
         + 明确标注"其他季度线路"（需用户确认，不自动采用）
         + 未知季度线路（放在"待匹配/原始来源"区域）
```

换源后：

1. 重新解析新线路的可播放季度；
2. 用 `episodeUrl` → `episodeName` → TMDB 集号的优先级重新定位剧集；
3. 继承原进度（绝对毫秒，沿用既有语义；不引入跨片源比例换算）。

### 9.3 删除

按 `02` §7.4 分级：

- 删除季度卡片 → 删除该季度进度 + 解除该季度投影；
- 删除整部节目 → **独立二级操作**，带确认弹窗，明确列出将删除的季度数量。

---

## 10. 设置页

### 10.1 TMDB 设置区块

```text
┌─ TMDB ──────────────────────────────────────────┐
│ 启用 TMDB 增强                          [开关]   │
│ API Key / Access Token   [••••••••••]  [显示]   │
│ API 主机                 [api.tmdb.org]         │
│ 图片主机                 [images.tmdb.org]      │
│ 语言                     [zh-CN]                │
│ 智能匹配                                [开关]   │
│ 启发式季度推断                          [开关]   │
│ 站点规则                                 [管理]   │
│   ├─ 启用站点：[+ 添加]  （Chip 列表）            │
│   ├─ 白名单：  [+ 添加]  （Chip 列表）            │
│   └─ 禁用站点：[+ 添加]  （Chip 列表，含默认规则） │
│ [测试连接]  [重置为默认规则]                       │
└─────────────────────────────────────────────────┘
```

### 10.2 交互要求

| 控件 | 要求 |
| --- | --- |
| Key 输入框 | 默认掩码；"显示"切换后明文；**不写入日志** |
| 测试连接 | 调 `/configuration`，成功显示"连接正常"，失败显示结构化错误 |
| 重置默认规则 | 恢复 `01` §6.2 的默认禁用规则，**需二次确认** |
| 站点规则管理 | Chip 增删；支持从当前配置的站点列表中选择（避免手打错字） |
| 保存时机 | 点"保存"统一保存（对齐上游 `TmdbSourceDialog` 的"点确定才统一保存"） |

### 10.3 与设置页既有结构的关系

PC 端设置页当前在 `lib/ui/config_pages.dart` / `lib/ui/diagnostics_pages.dart`。
TMDB 设置作为**独立页签**加入，不改动既有页签的字段与顺序。

---

## 11. 桌面 UI 要求（对齐主设计文档 §17.4）

| 要求 | 实现 |
| --- | --- |
| 深色模式 | 使用 `Theme.of(context)` 语义色；不硬编码颜色 |
| 中文优先 | 复用 `lib/ui/theme.dart` 的字体回退链 |
| 键盘可用 | 全部交互可纯键盘完成；`Tab` 顺序符合阅读顺序；`Esc` 关闭弹窗 |
| 焦点可见 | 焦点环对比度满足可访问性要求 |
| 窗口缩放 | 最小 900×600 时布局不重叠；海报与剧照使用固定宽高比占位 |
| 无阻塞 | TMDB 请求期间 UI 可交互（线路/选集/返回均可用） |
| 长文本 | 简介默认 4 行折叠 + "展开"；标题过长省略并 `Tooltip` 显示全称 |
| 图片加载 | 统一使用既有 `PosterImage`（含占位与错误占位） |

---

## 12. 与上游的差异汇总

| 项 | 上游（Android） | PC 端 | 理由 |
| --- | --- | --- | --- |
| 详情页形态 | 5 种 `detail_open_mode`（原生/融合/炫彩/直放/原始） | 1 套桌面形态 | 遥控器场景特有；PC 端无对应需求 |
| 详情页实现 | `TmdbDetailActivity` 12667 行 | 拆为 `TmdbState` + 3 个区块组件 | 不继承技术债 |
| 适配器 | `TmdbUIAdapter` 2451 行上帝类 | 3 个纯逻辑模块 + 3 个服务 | 可单测、可复用 |
| 相关视频播放 | 应用内（`PushParser` + `PUSH` 站源） | 浏览器打开 + 复制链接 | 避免隐式内置站源 |
| 窗口化播放器 | `TmdbVideoPlayerDialog` | 不实现 | 相关视频不应用内播放 |
| 剧集卡片 | `TmdbEpisodeAdapter` + 网格策略类 | 内联网格 + 纯函数列数策略 | 减少抽象层 |
| 详情页入口 | TV 首页/历史/推送多路 | 站点详情页 + TMDB 详情页两条 | 与 PC 端既有导航一致 |
| AI 推荐行 | `TmdbRecommendationRows` + 个人推荐 | 只做 TMDB `recommendations`/`similar` | `00` §4.3 |

---

## 13. 开放问题（实施前需确认）

| # | 问题 | 影响 | 建议 |
| --- | --- | --- | --- |
| Q1 | TMDB 增强区块是否允许用户折叠/关闭？ | 影响设置项数量 | **允许按站点禁用**（`01` §6），不做全局折叠 |
| Q2 | 纯 TMDB 详情页的"搜索站源"是跳搜索页还是内联结果？ | 影响实现量 | **跳既有搜索页**并带入标题，复用既有并发搜索 |
| Q3 | 相关视频用 `url_launcher` 还是 `Process.start`？ | 影响依赖与跨平台 | `url_launcher`（需在 `pubspec.yaml` 新增依赖，属本阶段明确变更） |
| Q4 | 季度选择器用分段控件还是下拉？ | 影响多季作品的可用性 | 季度 ≤ 5 用分段控件，> 5 用下拉 |
| Q5 | 详情页是否显示"元数据季度 vs 可播放季度"的差异提示？ | 影响用户困惑 | **显示**：当 TMDB 季度数 > 可播放季度数时，提示"其他季度需换源" |

---

## 14. 验收要点（详见 `05`）

1. 头部增强 8 个字段的"仅补位不覆盖"逐条用例（含来源非空时**不变**）。
2. 骨架屏高度与最终内容一致（widget 测试断言尺寸差 ≤ 1 px）。
3. 状态条 6 种状态渲染；站点禁用时**整块不渲染**。
4. `episodesToRender.length == 该季线路剧集数`（含"TMDB 有 9 集、线路 8 集"用例）。
5. 切换季度清空旧剧集；切换线路重新解析可播放季度。
6. 手动匹配弹窗自动搜索；`tmdb:` / `movie:` / `tv:` 直达。
7. 季度绑定弹窗：候选集数/年份展示、切片失败禁用、风险提示阈值。
8. 相关视频：`key` 非法条目被拒；打开失败时复制链接兜底。
9. 播放入口透传 7 个参数；`episodeUrl` 优先级三段（含两条兼容语义）。
10. 自动连播不跨季度。
11. 删除季度卡片不删同节目其他季度；整部删除需二次确认。
12. 设置页 Key 掩码、测试连接、重置默认规则二次确认。
13. 键盘全流程可用（Tab/Esc/方向键/Enter）。
