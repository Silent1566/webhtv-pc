# TMDB 功能设计指导文档（总索引）

- 状态：设计指导（Design Guidance），**已实施并验收**（T1–T18 全部落地；`PHASE4-ACCEPT result=PASS gates=all`）
- 日期：2026-10-06
- 适用工程：`apps/desktop-flutter`（WebHTV PC，Flutter + media-kit 主线）
- 上游参考：`webhtv/默影视`（Android 工程，仓库 `F:\Workspace\webhtv`）
- 主设计文档：`docs/webhtv-pc-design.md`（本文档是它的 Phase 4 展开）
- 阶段计划：`docs/phase4/README.md`

---

## 0. 一句话目标

让 WebHTV PC 具备与 `webhtv/默影视` 等价的 **TMDB 元数据增强能力**：
用 TMDB 作为**元数据源**，用站源线路作为**播放事实源**，在不猜测、不伪造播放项的前提下，
提供「匹配 → 详情 → 季度/选集 → 续播 → 换源」的完整闭环，并把全部边界写进可验收的设计文档。

---

## 1. 为什么先补设计文档

本仓库前三个阶段的推进方式固定为「先写设计/计划 → 再实现 → 再验收取证」：

| 阶段 | 计划文档 | 结果 |
| --- | --- | --- |
| Phase 0 | `docs/phase0/scorecard.md`、`docs/adr/0001-phase0-route.md` | 冻结 Flutter + media-kit |
| Phase 1 | `docs/phase1/README.md` | MVP-A 垂直闭环 |
| Phase 2 | `docs/phase2/README.md` | MVP-B 产品基础 + Spider ABI |
| Phase 3 | `docs/phase3/README.md`、`docs/adr/0002-android-csp-jar-compat.md` | 直播/字幕/弹幕/解析器/EPG/JS/JVM/猫源 |
| **Phase 4** | **本目录 + `docs/phase4/README.md`** | **TMDB 元数据增强** |

TMDB 是**跨模块**能力：它同时触及协议模型、HTTP 客户端、SQLite 存储、详情页 UI、
历史/续播、换源与播放入口。上游 `webhtv` 为此沉淀了 9 份设计文档与约 5.2 万行相关代码
（含 12667 行的 `TmdbDetailActivity`）。如果不先冻结语义边界，PC 端最可能的失败形态是
**"用 TMDB 的季集数据生成出没有线路 URL 的播放项"**——即把元数据当成播放事实。
本套文档的首要目的就是把这个边界写成不可退让的契约。

---

## 2. 文档清单

| # | 文档 | 覆盖内容 | 上游对应 |
| --- | --- | --- | --- |
| 00 | `00-tmdb-design-index.md`（本文） | 目标、范围、原则、文档地图、上游取舍 | — |
| 01 | `01-tmdb-identity-and-matching.md` | 媒体身份、匹配缓存、标题清洗、评分、分季变体防护、手动匹配、站点策略 | `docs/tmdb-season-manual-match-design.md` §3/§7/§9/§13、`TmdbMatcher`、`TmdbMatchPolicy`、`TmdbMatchCache`、`TmdbSitePolicy` |
| 02 | `02-tmdb-season-resolution-and-progress.md` | `SeasonScope` 三态、线路级绑定、解析优先级、可播放季度、季度进度、续播/删除 | `docs/superpowers/specs/2026-08-17-tmdb-season-aware-aggregation-design.md`、`docs/tmdb-playable-episode-availability-design.md`、`TmdbSeasonResolver`、`TmdbSeasonMatchCache`、`TmdbSeasonProgress` |
| 03 | `03-tmdb-service-config-storage.md` | 服务接口、鉴权/熔断、缓存 TTL 与陈旧兜底、错误分类、配置与凭据、SQLite 迁移、文件缓存 | `TmdbService`、`TmdbConfig`、`Setting.getTmdbConfig`、`TmdbSourceDialog` |
| 04 | `04-tmdb-detail-ui-and-playback.md` | 详情页信息架构、季度/选集联动、手动绑定入口、相关视频、播放入口契约 | `TmdbDetailActivity`、`TmdbUIAdapter`、`TmdbVideo`、`TmdbVideoPlayback`、`docs/tmdb-related-video-playback-design.md` |
| 05 | `05-tmdb-test-and-acceptance.md` | 纯逻辑单测、fixture、集成、门禁、证据落盘 | Phase 1/2/3 的门禁与证据机制 |
| — | `../README.md` | Phase 4 阶段计划与门禁表 | `docs/phase3/README.md` |

阅读顺序建议：00 → 01 → 02 → 03 → 04 → 05 → `../README.md`。
只关心"能不能播"的读者可直接读 02 §4（可播放季度）与 04 §6（播放入口）。

---

## 3. 四条不可退让的原则

以下四条是**契约级**要求。任何实现只要违反其一，即视为设计缺陷，必须修复而不是放宽文档。

### 3.1 元数据源 ≠ 播放事实源

> 选集区域只展示当前线路真实存在的剧集；TMDB 只负责丰富这些播放项，**不创建播放项**。

- TMDB 返回 S1E9，但当前线路只有 8 集 → 不生成第 9 集卡片。
- 线路集数无法识别季度 → 退化为扁平列表，**不等于第一季**，**也不等于全部季度**。
- 禁止因为"TMDB 存在某集"而生成没有线路 URL 的卡片。
- 禁止因为"部分线路集数无法识别季度"而静默丢弃这些播放项。

上游依据：`docs/tmdb-playable-episode-availability-design.md` 的「核心原则」「安全退化原则」两节。

### 3.2 不确定即未知，不默认第一季

季度必须用**显式三态**表达，不能用整数默认值兼表两种含义：

```text
SeasonScope = Known(seasonNumber)   // 已确证
            | Multi(segments)        // 一条线路覆盖多季，且分段边界可验证
            | Unknown                // 证据不足
```

- `Known(0)` 只表示已明确映射到 TMDB 特别篇。
- `Unknown` 不得退化成 `Known(1)`。
- 只有结果**唯一**时自动解析才可落盘；多个候选同样合理时进入手动匹配。

上游依据：`docs/superpowers/specs/2026-08-17-tmdb-season-aware-aggregation-design.md`「季度身份」「季度解析规则」。

### 3.3 安全退化优先于功能完整

TMDB 请求失败、季度冲突、来源结构变化时：

- 保留来源标题、来源历史、原线路，**不改变已保存绑定**；
- 允许暂时重复展示，**不允许跨季度恢复错误进度**；
- 不因 TMDB 不可用而阻塞浏览与播放。

上游依据：同上「异常与降级」。

### 3.4 主进程不加载不可信代码，凭据不外泄

- TMDB 只走主进程 HTTP 客户端，不进 sidecar，不新增 ABI。
- API Key / Access Token 属于凭据：日志脱敏（对齐 §22.3）、不入诊断导出、不进 Spider。
- 用户未配置 Key 时，TMDB 相关能力**整块禁用**且不静默请求。

上游依据：主设计文档 §18.2、§22.3；`TmdbConfig.isReady()`。

---

## 4. 上游取舍：哪些抄、哪些不抄

上游 `webhtv/默影视` 是 Android 应用，PC 端**复用语义与算法，不复用运行时**。

### 4.1 直接复用（语义/算法级）

| 上游资产 | 复用方式 |
| --- | --- |
| `TmdbConfig` 字段与归一化规则 | 逐字段对齐，含 `apiBase`/`apiKey`/`accessToken`/`language`/`imageBase`/`backdropBase`/`enabledSites`/`disabledSites`/`allowedSites`/`omdbApiKey` |
| `DEFAULT_DISABLED_RULES` 与括号归一 | 全量照抄，含 `「」【】〔〕［］` → `[]` 的归一规则 |
| `TmdbService` 的 TTL 常量与陈旧兜底 | 数值与语义对齐（见 03 §3） |
| 鉴权熔断（401/403 → 5 分钟冷却） | 语义对齐，熔断键 = `md5(apiBase|apiKey|accessToken)` |
| `TmdbMatcher` 评分公式 | 标题相似度 1000/800+/700-、年份距离、语言/地区加权，逐条对齐（见 01 §5） |
| `TmdbMatchPolicy` 分季变体惩罚 | `-240 / +140 / +160` 三个常量与判定条件对齐 |
| `TmdbSeasonResolver` 解析优先级 | 完整对齐（见 02 §3） |
| 可播放季度 6 级解析顺序 | 完整对齐（见 02 §4） |
| 标题三态模型 | `sourceTitle` / `canonicalTitle` / `displayTitle`（见 01 §4） |

### 4.2 改写（同语义、不同实现）

| 上游 | PC 端写法 |
| --- | --- |
| OkHttp + Gson | `package:http` + `dart:convert`（与 `lib/core/http_api.dart` 一致） |
| `Path.cache()` 文件缓存 | `AppPaths.cacheDir/tmdb/<type>_<md5>.json` |
| `Prefers.getString("tmdb_config")` | `<configDir>/settings.json` 的 `tmdb` 段（见 03 §5） |
| Room 表 + `TmdbSeasonProgressDao` | SQLite 新表 + `schemaVersion` 加法式迁移（见 03 §6） |
| `Activity` + `Fragment` + `Leanback` | Flutter `Page` + `ChangeNotifier`（见 04） |
| `TmdbUIAdapter`（2451 行上帝类） | 拆为 `TmdbIdentityService` / `TmdbSeasonService` / `TmdbEnrichmentService`（见 04 §2） |

### 4.3 明确不抄

| 上游能力 | 不抄原因 |
| --- | --- |
| `TmdbDetailActivity` 的 12667 行单体 | 上游自己在 `docs/refactoring/TMDB_DETAIL_ACTIVITY_REFACTORING_ROADMAP.md` 中列为重构对象；PC 端不继承该技术债 |
| AI 刮削 / AI 季集识别 / AI 推荐 | 需外部模型与用户密钥，超出本阶段；作为后续阶段候选，接口预留但不实现 |
| 豆瓣评分富集 | 需额外第三方接口，合规与稳定性风险高；`TmdbItem.doubanRating` 字段保留但不填充 |
| 个人推荐（`PersonalRecommendationService`，1768 行） | 依赖观看画像与云端推荐，PC 端不做用户画像 |
| WebHome 内联站点 / 短剧 / 小说 / 漫画路由 | PC 端不支持（Phase 3 §5.8、Phase 3 §7） |
| `youtube` 应用内播放（`TmdbVideoPlayback` → `PushParser`） | PC 端无 YouTube 播放链路；相关视频改为「浏览器打开 + 复制链接」（见 04 §7） |
| Android 特有 UI 形态（沉浸融合/炫彩/原生增强三套） | PC 端只有一套桌面 UI，不做形态切换 |

---

## 5. 与主设计文档的章节对应

| 主设计文档章节 | 本套文档的展开 |
| --- | --- |
| §4 总体架构 | 03 §2（TMDB 服务层插入位置） |
| §7 配置协议 | 03 §5（`tmdb` 配置块） |
| §8 站点与协议模型 | 01 §6（站点策略）、02 §5（线路绑定） |
| §14 搜索与站点健康 | 01 §5（TMDB 搜索评分）、04 §5（搜索入口） |
| §15 历史记录与收藏 | 02 §6（季度进度）、02 §7（续播与删除） |
| §16 存储设计 | 03 §6（表与文件） |
| §17 UI 设计 | 04 §3/§4（详情页、季度选择器） |
| §19 测试策略 | 05（测试与验收） |
| §21 实施阶段 | `../README.md`（Phase 4） |
| §22 总验收清单 | `../README.md` §3（门禁表）、05 §5 |
| §23 关键决策记录 | 本文 §6（新增决策项） |

---

## 6. 新增关键决策记录（已回填主设计文档 §23）

| 决策 | 结论 | 冻结条件 |
| --- | --- | --- |
| TMDB 是否进入 PC 端 | 进入，作为**元数据增强**，不改变播放事实源 | 本套文档评审通过 |
| TMDB 配置存放位置 | 应用设置（`settings.json` 的 `tmdb` 段），**不进配置 JSON** | 03 §5 评审通过 |
| TMDB 凭据是否随配置导出 | 不导出、不写日志、不入诊断包 | 03 §5.4 |
| 季度身份表达 | 显式三态 `SeasonScope`，禁止整数默认值兼表 | 02 §2 |
| 绑定粒度 | **线路级**（`siteKey + vodId + flagKey`），非 Vod 级 | 02 §5 |
| 自动解析落盘条件 | 仅结果唯一时落盘；多候选 → 手动匹配 | 02 §3 |
| 历史展示键 | 已确证季度按季度聚合，未确证按来源键隔离 | 02 §6 |
| 详情页是否新建独立页面 | 新建 TMDB 详情页，**不改造现有站点详情页** | 04 §3 |
| 相关视频播放入口 | 浏览器打开 + 复制链接，不做应用内 YouTube | 04 §7 |
| 缓存与陈旧兜底 | 新鲜 TTL 命中优先；网络失败时降级到陈旧缓存 | 03 §3 |
| 迁移策略 | 加法式新表 + 惰性回填，不破坏现有 `history` 主键 | 03 §6.3 |

---

## 7. 术语补充（已回填主设计文档 §26）

| 术语 | 定义 |
| --- | --- |
| 媒体身份（MediaIdentity） | `mediaType + tmdbId`；同一剧集的不同季度共享该身份 |
| 季度身份（SeasonIdentity） | `MediaIdentity + KnownSeasonNumber`；用于历史展示、续播、进度与删除边界 |
| 季度范围（SeasonScope） | 三态：`Known(n)` / `Multi(segments)` / `Unknown` |
| 来源线路绑定（SourceBinding） | `siteKey + vodId + flagKey` → `SeasonScope` |
| 元数据季度 | TMDB 返回的完整季度，仅用于标题/剧照/日期等丰富 |
| 可播放季度 | 依据当前线路剧集能**可靠确证**的季度，用于季度导航与选集过滤 |
| 季度进度快照（TmdbSeasonProgress） | 按 `mediaType + tmdbId + seasonNumber` 记录的可恢复位置 |
| 来源指纹（SourceFingerprint） | 线路剧集结构的稳定摘要，用于判断旧绑定是否失效 |
| 分季变体（SplitSeasonVariant） | TMDB 中把一部剧拆成多个独立条目的形态，需惩罚以避免误匹配 |
