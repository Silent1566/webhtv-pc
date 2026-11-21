# 03 · TMDB 服务、配置与存储设计

- 状态：设计指导，**已实施**（见 `docs/phase4/README.md` §2.2、§3）
- 日期：2026-10-06
- 上游参考：`TmdbService`（1158 行）、`TmdbConfig`（308 行）、`Setting.getTmdbConfig`、`TmdbSourceDialog`、`TmdbImageSelector`、`docs/tmdb-related-video-playback-design.md` §3/§6
- PC 端落点：`lib/core/tmdb_config.dart`、`lib/services/tmdb_service.dart`、`lib/services/tmdb_cache.dart`、`lib/services/storage.dart`（迁移）
- 关联：`01`（匹配）、`02`（季度）、`04`（UI）、`05`（测试）

---

## 1. 本文件解决的问题

1. **接口**：调用 TMDB 的哪些端点、参数怎么拼、返回怎么解析（§4）。
2. **可靠性**：TTL、缓存陈旧兜底、鉴权熔断、取消与超时（§3）。
3. **错误**：如何映射到既有 `AppErrorKind`，如何与 UI 文案衔接（本节「错误分类映射」）。
4. **配置与凭据**：TMDB 配置放哪、怎么导入导出、怎么脱敏（§5）。
5. **存储**：SQLite 表结构、迁移策略、文件缓存布局、清理边界（§6）。

---

## 2. 服务层位置

```text
┌──────────────────────────────────────────────────────┐
│ UI（详情页 / 设置页 / 搜索页）                          │
└───────────────┬──────────────────────────────────────┘
                │
┌───────────────▼──────────────────────────────────────┐
│ TmdbIdentityService   匹配与缓存（01）                  │
│ TmdbSeasonService     季度解析与绑定（02）              │
│ TmdbEnrichmentService 把元数据应用到 Vod/剧集（04）      │
└───────────────┬──────────────────────────────────────┘
                │
┌───────────────▼──────────────────────────────────────┐
│ TmdbService           端点封装 + 解析 + 熔断 + 错误映射  │
│ TmdbCache             TTL 判定 + 陈旧兜底 + 文件读写     │
│ TmdbConfig            配置归一化 + 站点策略（01 §6）     │
└───────────────┬──────────────────────────────────────┘
                │
        package:http（与 lib/core/http_api.dart 同一栈）
```

**约束**：

- TMDB **只在主进程**调用，**不进 sidecar**，**不新增 ABI 版本**（`00` §3.4）。
- `TmdbService` **无 UI 依赖**、**无存储依赖**（缓存通过注入的 `TmdbCache`），便于纯单测。
- `TmdbService` 不持有全局状态，除鉴权熔断表外无静态可变状态；熔断表通过 `clock` 注入以便测试。

---

## 3. 缓存与可靠性

### 3.1 TTL 常量（对齐上游）

| 数据类型 | 键前缀 | TTL |
| --- | --- | --- |
| 详情 | `detail` | **7 天** |
| 搜索 | `search` | **1 天** |
| 人物 | `person` | **7 天** |
| 分季 | `season` | **3 天**（详情含 `next_episode_to_air` 等未播信息时缩短为 **1 天**） |
| 单集 | `episode` | 同分季 |
| 视频 | `videos` | **6 小时**；结果为空时 **30 分钟** |
| 中国大陆在播季 | `cnSeason` | **1 天** |
| 鉴权失败冷却 | — | **5 分钟** |

### 3.2 缓存键

```text
cacheKey = <type> + "_" + md5(<规范化 URL>) + ".json"
```

- `md5` 只用于文件名，不作为完整性校验。
- 详情缓存允许**回退键**：当 `includeRelated = false` 时，额外把 `includeRelated = true` 的 URL 作为回退键，命中后仍可用（避免同一作品重复请求）。
- 搜索键基于 `keyword + language + apiBase`，避免换语言后读旧数据。

### 3.3 读路径（三级）

```text
1. 新鲜命中：文件存在 且 age <= ttl        → 直接返回（source=cache）
2. 网络请求：成功 → 写缓存 → 返回（source=network）
3. 网络失败：回退到**任意陈旧缓存**（不看 TTL）
             ├─ 命中 → 返回（source=stale-cache，记 warning 日志）
             └─ 未命中 → 抛出原始错误
```

- `refresh = true` 时跳过第 1 步，但仍保留第 3 步的陈旧兜底。
- 详情缓存有**动态 TTL**：当详情含未播集信息（`next_episode_to_air` 非空）时用更短 TTL，避免"未播集已可播"的陈旧结论。
- 视频缓存分档：`results` 为空用 `VIDEO_EMPTY_CACHE_TTL`（30 分钟），否则用 `VIDEO_CACHE_TTL`（6 小时）。

### 3.4 鉴权熔断

```text
authCircuitKey = md5(apiBase + "|" + apiKey + "|" + accessToken)

请求前：if (blockedUntil[key] > now) throw TmdbAuthException(401, "auth temporarily blocked")
收到 401/403：blockedUntil[key] = now + 5min；抛 TmdbAuthException
冷却到期：惰性移除
```

- 熔断**按凭据隔离**：换 Key 后立即可用。
- 熔断只影响 TMDB 请求，**不影响**站点浏览与播放。
- 必须在 UI 上给出可定位提示："TMDB 鉴权失败，请在设置中检查 API Key / Access Token"。

### 3.5 超时、并发与取消

| 项 | 值 | 说明 |
| --- | --- | --- |
| 单请求超时 | 15 s | 与站点请求保持一致量级 |
| 并发上限 | 4 | 避免触发 TMDB 限流 |
| 重试 | **不重试** | 失败由调用方决定是否重发（避免放大限流） |
| 取消 | 通过 `CancellationToken` | 取消时**不写缓存**、不落盘任何结论 |

`CancellationToken` 语义（对齐 Phase 3 的取消机制）：

- 取消抛 `AppError(AppErrorKind.siteCancelled)`（复用既有取消语义）；
- 取消**不得**被 `01` §4 的"匹配失败不抛异常"吞掉；
- 详情页离开时必须取消在途请求。

### 3.6 请求头与鉴权

```text
若 accessToken 非空：
  Header: Authorization: Bearer <accessToken>
  不附加 api_key 参数
否则：
  Query: api_key=<apiKey>
```

- 上游 `TmdbConfig.sanitize` 有一条规则：当 `accessToken` 与 `apiKey` 相同且不像 JWT（点分段 < 3）时，清空 `accessToken`。PC 端**照抄**，避免把 v3 Key 误当 v4 Token。
- 语言参数：`language = config.language`（默认 `zh-CN`）。
- 图片语言：`include_image_language = language + ",null"`。

---

## 4. 端点与解析

### 4.1 端点清单

| 方法 | 路径 | 关键参数 | append_to_response |
| --- | --- | --- | --- |
| `configuration` | `/configuration` | — | — |
| `search` | `/search/multi` | `query`, `language` | — |
| `detail(movie)` | `/movie/{id}` | `language`, `include_image_language` | `images,credits,translations,external_ids,release_dates`（+ `recommendations,similar`） |
| `detail(tv)` | `/tv/{id}` | 同上 | `images,credits,aggregate_credits,translations,external_ids,content_ratings`（+ `recommendations,similar`） |
| `season` | `/tv/{id}/season/{n}` | `language`, `include_image_language` | `images,credits,aggregate_credits,translations` |
| `episode` | `/tv/{id}/season/{n}/episode/{e}` | 同上 | `images,credits,translations` |
| `person` | `/person/{id}` | `language` | `combined_credits,images,translations,external_ids` |
| `videos(movie)` | `/movie/{id}/videos` | `language` | — |
| `videos(tv)` | `/tv/{id}/videos` | `language` | — |
| `videos(season)` | `/tv/{id}/season/{n}/videos` | `language` | — |
| `videos(episode)` | `/tv/{id}/season/{n}/episode/{e}/videos` | `language` | — |
| `recommendations` | `/{type}/{id}/recommendations` | `page` | — |
| `similar` | `/{type}/{id}/similar` | `page` | — |

`apiBase` 归一化规则（对齐上游 `TmdbConfig`）：

```text
sanitize:  ensureHttpScheme(trimTrailingSlash(value)) → 若不以 /3 结尾则拼 /3
getApiHost: 去掉末尾 /3 与斜杠，供设置页展示
```

### 4.2 响应解析要点

- **搜索**：只接受 `media_type ∈ {movie, tv}`；`title` 按类型取 `title`/`name` 并互相回退；`date` 取 `release_date`/`first_air_date`。
- **详情**：`seasons[]` 必须解析为季度选项（`season_number`、`episode_count`、`air_date`、`name`、`poster_path`），过滤 `episode_count <= 0` 的季度。
- **分季**：`episodes[]` → `TmdbEpisode(number, title, date, overview, stillUrl, voteAverage, runtime, tmdbId, seasonNumber)`。
- **翻译**：`translations.translations[]` 中优先取 `iso_639_1 == language 主语言` 的 `data.overview`；无则回退 `overview`。
- **演员**：`credits.cast`（电影）与 `aggregate_credits.cast`（剧集，取 `roles[0].character`）都要支持；`creators` 取 `created_by`。
- **图片**：见本节 §4.4「图片选择」。
- **视频**：见本节「错误分类映射」之前的视频解析说明。

### 4.3 `TmdbEpisode` 与 `TmdbPerson`

```text
TmdbEpisode  = { number, title, date, overview, stillUrl, voteAverage, runtime, tmdbId, seasonNumber }
TmdbPerson   = { personId, name, subtitle, profileUrl, knownForDepartment, biography }
```

`TmdbEpisode.displayTitle` 生成规则（用于剧集卡片标题）：

```text
1. title 非空且不是 "Episode N" 之类占位 → "E{number} {title}"
2. 否则若 date 非空 → "E{number} · {date}"
3. 否则 → "第 {number} 集"
```

### 4.4 图片选择（`TmdbImageSelector` 等价物）

```text
backgrounds(detail, imageBase, backdropBase, preferLandscape, limit)
  preferred = preferLandscape ? backdrops(...) : posters(...)
  若 preferred 非空 → 返回
  否则返回另一方向
```

候选排序键（依次）：

1. `sourceRank`（`images.<kind>` 优先于根级 `poster_path`/`backdrop_path`）；
2. 像素面积（降序，`width * height`）；
3. `vote_average`（降序）；
4. `vote_count`（降序）。

去重按 URL；`limit <= 0` 表示不限制。

URL 拼接（`image(base, path)`）：

```text
base 为空 或 path 为空 → ""
path 已是 http(s) → 原样返回
否则 base + path（base 末尾斜杠去重）
```

`imageBase` 归一化：`stripImageSize` 反复剥离 `/w\d+|/h\d+|/original` 结尾，再补 `/t/p/<size>`。

### 4.5 错误分类映射

新增 `AppErrorKind`（命名与 Phase 3 的 `subtitle*`/`danmaku*`/`epg*` 风格一致）：

| Kind | 触发条件 | 用户文案（`describeErrorKind`） |
| --- | --- | --- |
| `tmdbNotConfigured` | `!config.isReady()` | `未配置 TMDB，请在设置中填写 API Key 或 Access Token（不影响站源浏览与播放）` |
| `tmdbAuth` | 401 / 403 或熔断命中 | `TMDB 鉴权失败，请检查 API Key / Access Token（不影响站源浏览与播放）` |
| `tmdbNetwork` | DNS/连接/超时 | `TMDB 请求失败：网络不可达或 DNS 失败（不影响站源浏览与播放）` |
| `tmdbHttp` | 其他非 2xx | `TMDB 请求失败：服务器返回非 2xx 状态（不影响站源浏览与播放）` |
| `tmdbDecode` | 响应非 JSON / 字段类型异常 | `TMDB 响应解析失败（不影响站源浏览与播放）` |
| `tmdbEmpty` | 成功但必需字段为空 | `TMDB 没有返回可用数据（不影响站源浏览与播放）` |
| `tmdbUnsupported` | 站点被策略禁用 | `该站点未启用 TMDB 增强（不影响站源浏览与播放）` |

**关键约束**：全部 `tmdb*` 错误都属于**非致命**类别。`AppError.retryable` 对 `tmdbNetwork` 为 `true`，其余为 `false`。
UI 必须遵循与字幕/弹幕相同的失败隔离语义：**TMDB 失败不得升级为浏览或播放失败**。

> 对齐依据：Phase 3 已建立 `isSubtitleError` / `isDanmakuError` 只认前缀的隔离模式
> （见 `docs/phase3/README.md` 门禁表"字幕失败隔离""弹幕失败隔离"）。
> PC 端新增 `isTmdbError` 沿用同一模式。

### 4.6 端点级方法签名（`TmdbService`）

```dart
class TmdbService {
  TmdbService({required TmdbConfig Function() config, TmdbCache? cache, http.Client? client, DateTime Function()? clock});

  Future<Map<String, Object?>> configuration();
  Future<List<TmdbItem>> search(String keyword);
  Future<Map<String, Object?>> detail(TmdbItem item, {bool includeRelated = true, bool refresh = false});
  Future<List<TmdbEpisode>> seasonEpisodes(TmdbItem item, int seasonNumber, {bool refresh = false});
  Future<Map<String, Object?>> episode(TmdbItem item, int seasonNumber, int episodeNumber);
  Future<Map<String, Object?>> person(int personId);
  Future<List<TmdbPerson>> cast(Map<String, Object?> detail);
  Future<List<TmdbPerson>> creators(Map<String, Object?> detail);
  Future<List<TmdbPerson>> seasonCast(Map<String, Object?> season);
  Future<List<TmdbPerson>> episodeGuests(Map<String, Object?> episode);
  Future<List<String>> photos(Map<String, Object?> detail, {bool preferLandscape = false});
  Future<List<String>> posters(Map<String, Object?> detail);
  Future<List<String>> backdrops(Map<String, Object?> detail);
  Future<List<TmdbVideo>> videos(TmdbItem item, {int? seasonNumber, int? episodeNumber});
  Future<List<TmdbItem>> recommendations(TmdbItem item, {int page = 1});
  Future<List<TmdbItem>> similar(TmdbItem item, {int page = 1});
  Future<List<TmdbItem>> personWorks(Map<String, Object?> person, {required bool cast});
  Future<String?> translatedOverview(Map<String, Object?> detail);
  String image(String base, String? path);
}
```

约束：

- 所有方法在 `!config.isReady()` 时抛 `tmdbNotConfigured`，**不发请求**。
- 所有方法支持注入 `CancellationToken`。
- 返回 `Map<String, Object?>` 而非自定义类型，保持与 TMDB 响应同构，便于 `05` 用 fixture 断言。

---

## 5. 配置与凭据

### 5.1 配置模型（`TmdbConfig`）

| 字段 | JSON 键（含兼容别名） | 默认值 | 说明 |
| --- | --- | --- | --- |
| `apiBase` | `apiBase` | `auto` | **默认自动**（§5.7）；显式值归一化为以 `/3` 结尾；设置页提供内置线路（§5.6） |
| `apiKey` | `apiKey` / `apikey` / `api_key` / `tmdbApiKey` / `key` | `""` | v3 Key |
| `accessToken` | `accessToken` / `token` / `readAccessToken` / `bearerToken` | `""` | v4 Token |
| `omdbApiKey` | `omdbApiKey` / `omdbKey` / `imdbApiKey` | `""` | 详情页 IMDb / 烂番茄 / Metacritic 评分用；**为空时 PC 端一次都不请求 OMDb**（2026-11-11 起由设置页显式配置后启用） |
| `language` | `language` | `zh-CN` | |
| `imageBase` | `imageBase` | `auto` | **默认自动**（§5.7）；显式值归一化为 `/t/p/w342`；设置页提供内置线路（§5.6） |
| `backdropBase` | `backdropBase` | `auto` | 空值跟随 `imageBase`；显式值归一化为 `/t/p/w1280` 且不随图片线路改（§5.6 规则 15） |
| `enabledSites` | `enabledSites` / `siteKeys` / `sites` / `matchSites` | `[]` | 见 `01` §6 |
| `disabledSites` | `disabledSites` + 兼容 `excludeKeywords` / `exclude` / `blockedKeywords` / `skipKeywords` | 默认规则 | 见 `01` §6.2 |
| `allowedSites` | `allowedSites` / `includeSites` / `whitelistSites` | `[]` | |
| `smartMatch` | `smartMatch` | `true` | 见 `01` §5.3 |
| `heuristicSeasonGuessing` | `heuristicSeasonGuessing` | `true` | 见 `02` §3.5 |
| `enabled` | `enabled` | `true` | 总开关；关闭后等同未配置 |

### 5.2 归一化规则（`sanitize()`，必须逐条实现）

1. `apiBase = normalizeApiBase(trimOr(apiBase, DEFAULT_API_BASE))`。
2. `apiKey = trimOr(apiKey, trimOr(apiKeyCompat, ""))`；`apiKeyCompat = apiKey`。
3. `accessToken = trimOr(accessToken, "")`；若 `accessToken == apiKey` 且不像 JWT（`.` 分段 < 3）→ `accessToken = ""`。
4. `language = trimOr(language, "zh-CN")`。
5. `imageBase = normalizeImageInput(trimOr(imageBase, DEFAULT_IMAGE_BASE))`。
6. `backdropBase = normalizeImageInput(trimOr(backdropBase, ""))`；为空且 `imageBase` 是图片主机时 → `imageBase(imageBase, "w780")`。
7. 若 `imageBase` 是图片主机 → `imageBase = imageBase(imageBase, "w342")`。
8. `backdropBase = trimOr(backdropBase, DEFAULT_BACKDROP_BASE)`；若是图片主机且不含 `/t/p/` → `imageBase(backdropBase, "w780")`。
9. `enabledSites = cleanList(enabledSites)`。
10. `disabledSites = mergeList(cleanList(excludeKeywords), cleanList(disabledSites))`；`excludeKeywords = null`。
11. `allowedSites = cleanList(allowedSites)`。
12. `excludeKeywordsConfigured == null` → `= !disabledSites.isEmpty()`。
13. `!excludeKeywordsConfigured && disabledSites.isEmpty()` → `disabledSites = DEFAULT_DISABLED_RULES`。

本地追加的两条规则（2026-10-10 / 2026-11-21），排在 13 条之后、顺序同样固定：

14. **官方 `w780` 后景升级到 `w1280`**：只针对 `images.tmdb.org/t/p/w780` 这一档（用户自选尺寸与自建图床不动）。
15. **后景跟随图片线路**：`imageBase` 不是官方图床、而 `backdropBase` 仍是官方默认地址时，后景改用 `imageBase` 的同线路 `w1280`。否则用户换了反代只有海报生效，详情页背景照样走打不开的官方图床。用户显式指定的自定义后景（含规则 14 的自选尺寸）一律不动。

辅助函数语义：

- `cleanList`：去空、`trim`、去重、保序。
- `mergeList`：先 first 后 second，去重保序。
- `isReady() = accessToken 非空 || apiKey 非空`（且 `enabled`）。
- `looksLikeHost`：含 `.` 或 `localhost` 或 IP 形态，且不含 `://`、空格，不以 `/` 开头。
- `isImageHost`：以 `/t/p` 结尾、等于默认图片主机、以 `.tmdb.org` 结尾、是 http(s) URL、或 `looksLikeHost`。

### 5.3 存储位置与格式

TMDB 配置**不进配置 JSON**（`AppConfig`），而是应用设置：

```jsonc
// <configDir>/settings.json
{
  "tmdb": {
    "enabled": true,
    "apiBase": "auto",           // 默认：自动线路（也可写 https://api.tmdb.org/3 固定）
    "apiKey": "",
    "accessToken": "",
    "language": "zh-CN",
    "imageBase": "auto",         // 默认：自动线路（也可写 …/t/p/w342 固定）
    "backdropBase": "auto",
    "enabledSites": [],
    "disabledSites": ["[音]", "[听]", "[书]", "[漫]", "[短]", "[设]", "[画]", "[漫画]", "[小说]", "配置", "[配]"],
    "allowedSites": [],
    "smartMatch": true,
    "heuristicSeasonGuessing": true
  }
}
```

理由：

1. TMDB 是**应用级**能力，与站源配置无关；放进 `AppConfig` 会被 `toJson()` 原样写回配置记录，导致配置在设备间同步时携带凭据。
2. `AppConfig.extra` 会保留未知字段，若把 `tmdb` 放进配置，用户切换配置时 TMDB 设置会跟着变——这不是期望行为。
3. `AppPaths.settingsPath` 已存在但当前未被使用（`lib/services/app_paths.dart:31`）；本设计正是它的第一个使用者。

### 5.4 凭据保护（强制要求）

| 要求 | 实现 |
| --- | --- |
| 日志脱敏 | `apiKey` / `accessToken` 在日志中只输出 `****` + 末 4 位；请求 URL 记录时剥离 `api_key` |
| 诊断导出 | 诊断包**不含** `apiKey` / `accessToken`（替换为 `<redacted>`） |
| 配置同步 | TMDB 配置**不随**站源配置同步/导出 |
| Spider 隔离 | sidecar 无法读取 settings.json（既有隔离已保证） |
| 设置页展示 | Token 输入框默认掩码，提供"显示"切换 |
| 崩溃上报 | 默认关闭；启用时上传内容预览中凭据已脱敏 |

### 5.5 导入/导出

- 提供"导出 TMDB 设置"（**不含**凭据）与"导入 TMDB 设置"（凭据留空）。
- 导入时保留本地凭据，避免覆盖。
- 兼容上游 `TmdbConfig` JSON 形态：导入时用同一 `sanitize()`，因此别名键（`apikey`/`api_key`/`token`）都能识别。

### 5.6 内置线路与自定义地址（2026-11-21，对齐安卓 `TmdbProxy`）

海报与背景全部走图片主机，而这个域名在部分网络下打不开或极慢；安卓版内置了可切换的线路，PC 版此前只能手打完整地址。现在两处地址都由「内置下拉 + 自定义输入」构成，预设定义在 `lib/core/tmdb_route.dart`（纯常量与字符串归一，不依赖 Flutter / `dart:io` / `http`）。

| 用途 | 内置线路 | 形态 |
| --- | --- | --- |
| API | **自动** | 存 `auto`，请求时按健康度选路（§5.7） |
| API | 官方 `https://api.tmdb.org` | 归一为 `…/3` |
| API | 官方备用 `https://api.themoviedb.org` | 归一为 `…/3` |
| API | 公共反代 `https://jsnzkpg4.pages.dev/https://api.tmdb.org` | 归一为 `…/3` |
| 图片 | **自动** | 存 `auto`，读取时解析成具体线路（§5.7） |
| 图片 | 官方 `https://images.tmdb.org` | 归一为 `…/t/p/w342` |
| 图片 | 官方备用 `https://image.tmdb.org` | 归一为 `…/t/p/w342` |
| 图片 | 公共反代 `https://jsnzkpg4.pages.dev/https://image.tmdb.org` | 归一为 `…/t/p/w342` |
| 图片 | wsrv.nl `https://wsrv.nl/?url=https://image.tmdb.org` | 归一为 `…?url=…/t/p/w342` |

三条拼接形态（同一份 `imageBase + path` 逻辑即可覆盖，不需要为反代写第二套代码）：

1. **官方直连**：`https://images.tmdb.org/t/p/w342/<node>`。
2. **路径式反代**：`<反代>/https://image.tmdb.org/t/p/w342/<node>`——目标地址本身就是路径。
3. **查询式代理**（wsrv.nl）：`https://wsrv.nl/?url=https://image.tmdb.org/t/p/w342/<node>`——目标地址全是查询参数的值。

约束与取舍：

- **自定义输入与预设走同一条归一化**：都进 `sanitize()`，由它补 `/3`、`/t/p/<尺寸>`，因此 `http://api.tmdb.org`、`images.tmdb.org`、带不带末尾斜杠、带不带尺寸段都能用。
- **默认就是自动**：新装或从未在设置里选过线路时，两条都是 `auto`（对齐安卓 `isApiAuto()` 的缺省语义：官方地址 + 没显式选过＝自动）；显式选了官方直连等具体线路才固定下来。自动的排序与换线见 §5.7。
- **测速只回答「这条现在通不通」**：设置页的「测试图片线路」取一张 TMDB 公共海报，报出状态码、体积与耗时（`TmdbService.probeImageRoute` → `AppState.testTmdbImageRoute`），**不鉴权、不读缓存、不参与熔断**。
- **线路判定按主机 + 目标地址，不按尺寸**：`https://images.tmdb.org/t/p/w500` 仍算官方线路（设置页不显示成「自定义」）。

---

### 5.7 自动线路（2026-11-21，对齐安卓 `TmdbProxy.RouteSelector`）

两条线路的**默认值就是自动**，也是下拉的首项。配置里存的是**语义值** `auto`（与安卓同名），不是地址：具体走哪条由运行时决定，因此换线不用改配置、也不用问用户。

**排序语义（API 与图片各自独立）**

1. 未冷却的排在冷却中的前面；
2. 同一组内按实测延迟升序，没测过的排最后；
3. 仍然并列时保持候选的原始顺序（官方优先）。

失败只影响该线路 **30 秒**（冷却），成功后立即解除；延迟数据 **10 分钟**过期。实现在 `lib/services/tmdb_route_selector.dart`（时钟可注入，时间语义由单测钉住）。

**API：请求级换线**

- 候选顺序 = 官方 → 官方备用 → 公共反代（顺序即未测速时的优先级）。
- 只有当错误「像线路问题」时才换下一条：网络失败、超时、5xx。**401/403 不换线**（同一套凭据，换到哪条都一样）、解码失败与 4xx 不换线（换线只会把真正的配置问题藏起来）。
- 延迟数据来自**真实请求**：每次成功记一次耗时，失败记一次冷却——不额外探活、不需要凭据。
- 缓存键按「官方基址 + 路径」计算，与本次实际走了哪条线路无关：换线不会为同一次请求写出多份缓存。
- 全部候选都失败时行为与单线路一致：先给陈旧缓存，再抛最后一个错误。

**图片：会话内择优 + 失败重测**

- 启动时（配置为自动才发请求）对每个候选取一张 TMDB 公共海报（`w342`，约 38 KB），把耗时与可达性记进选择器；**第一张海报之前**就已经是按延迟排好的顺序。测速发生在主界面起来之后（`ui/app.dart` 的引导回调），不在 `AppState.bootstrap()` 里抢首屏网络。
- 解析发生在读取处（`AppState.tmdbConfig`）：`imageBase` / `backdropBase` 交出去时已经是具体地址，于是服务层、详情页、首页取图、推荐等十几处消费者都不需要认识「自动」，也不会出现海报走反代、后景仍走官方的情况。
- 取图失败由 `PosterImage` 回报（`TmdbImageHealth.onFailure`）：**60 秒内同一条线路连续两张**失败才判定线路坏——单张 404（被删掉的海报）不足以换线。判定后该线路进冷却、解析结果切换、并异步重测一次；配置仍是 `auto`。

与安卓的差异（有意）：

| 项 | 安卓 | PC | 理由 |
| --- | --- | --- | --- |
| 图片失败切换粒度 | 逐图换 URL 重试（`nextAutoImageUrl`） | 线路级：连续两张失败才整条切换 | PC 的图片缓存键是 URL，逐图换主机等于把同一张图重新拉一遍；反复切换会让栅格抖动 |
| 启动测速 | 由图片加载器顺带测量 | 启动时主动测一次（4 张探针图） | PC 端 `Image.network` 不回传耗时，只靠失败信号会让「低延迟优先」永远不生效 |

`docs/phase4/design/05` §3.9 追加门禁：`tmdb_route_selector_test.dart`（排序/冷却/TTL）、`tmdb_service_auto_route_test.dart`（换线条件与缓存键）、`tmdb_auto_route_state_test.dart`（读取处解析、失败切换、重新测速）。

---

## 6. 存储设计

### 6.1 SQLite 表（新增）

```sql
-- 媒体匹配（`01` §2.3）
CREATE TABLE IF NOT EXISTS tmdb_matches (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  config_id     INTEGER NOT NULL DEFAULT 0,
  site_key      TEXT    NOT NULL,
  vod_id        TEXT    NOT NULL,
  source_title  TEXT    NOT NULL DEFAULT '',   -- 归一化后的源标题；'' 表示条目级键
  scope         TEXT    NOT NULL,              -- 'entry' | 'title'
  tmdb_id       INTEGER NOT NULL,
  media_type    TEXT    NOT NULL,
  title         TEXT    NOT NULL DEFAULT '',
  subtitle      TEXT,
  overview      TEXT,
  poster_url    TEXT,
  backdrop_url  TEXT,
  credit        TEXT,
  rating        REAL    NOT NULL DEFAULT 0,
  original_language TEXT NOT NULL DEFAULT '',
  origin_country    TEXT NOT NULL DEFAULT '',
  manual        INTEGER NOT NULL DEFAULT 0,
  manual_titles TEXT,                          -- JSON 数组
  matched_at    INTEGER NOT NULL,
  UNIQUE(config_id, site_key, vod_id, source_title, scope)
);
CREATE INDEX IF NOT EXISTS idx_tmdb_matches_identity
  ON tmdb_matches(config_id, media_type, tmdb_id);

-- 季度绑定（02 §5.1）
CREATE TABLE IF NOT EXISTS tmdb_season_bindings (
  id                      INTEGER PRIMARY KEY AUTOINCREMENT,
  config_id               INTEGER NOT NULL DEFAULT 0,
  site_key                TEXT    NOT NULL,
  vod_id                  TEXT    NOT NULL,
  source_title            TEXT    NOT NULL DEFAULT '',
  flag_key                TEXT    NOT NULL DEFAULT '',
  tmdb_id                 INTEGER NOT NULL,
  media_type              TEXT    NOT NULL DEFAULT 'tv',
  mode                    TEXT    NOT NULL,     -- 'manualSeason'|'manualFlat'|'manualMultiSlice'
  season_number           INTEGER,
  source_fingerprint      TEXT    NOT NULL DEFAULT '',
  source_episode_count    INTEGER NOT NULL DEFAULT 0,
  tmdb_season_episode_count INTEGER NOT NULL DEFAULT 0,
  segments                TEXT,                 -- JSON 数组
  version                 INTEGER NOT NULL DEFAULT 1,
  updated_at              INTEGER NOT NULL,
  UNIQUE(config_id, site_key, vod_id, source_title, flag_key)
);

-- 线路绑定索引（02 §5.5）
CREATE TABLE IF NOT EXISTS tmdb_route_bindings (
  id                 INTEGER PRIMARY KEY AUTOINCREMENT,
  config_id          INTEGER NOT NULL DEFAULT 0,
  site_key           TEXT    NOT NULL,
  vod_id             TEXT    NOT NULL,
  flag_key           TEXT    NOT NULL,
  source_flag        TEXT    NOT NULL DEFAULT '',
  source_fingerprint TEXT    NOT NULL DEFAULT '',
  tmdb_id            INTEGER NOT NULL,
  media_type         TEXT    NOT NULL DEFAULT 'tv',
  scope_kind         TEXT    NOT NULL,          -- 'known'|'multi'
  season_numbers     TEXT    NOT NULL DEFAULT '', -- JSON 数组
  segments           TEXT,                      -- JSON 数组
  updated_at         INTEGER NOT NULL,
  UNIQUE(config_id, site_key, vod_id, flag_key)
);
CREATE INDEX IF NOT EXISTS idx_tmdb_route_identity
  ON tmdb_route_bindings(config_id, tmdb_id, media_type);

-- 季度进度（02 §6.1）
CREATE TABLE IF NOT EXISTS tmdb_season_progress (
  config_id           INTEGER NOT NULL DEFAULT 0,
  media_type          TEXT    NOT NULL DEFAULT 'tv',
  tmdb_id             INTEGER NOT NULL,
  season_number       INTEGER NOT NULL,
  episode_number      INTEGER NOT NULL DEFAULT 0,
  position_ms         INTEGER NOT NULL DEFAULT 0,
  duration_ms         INTEGER NOT NULL DEFAULT 0,
  source_flag         TEXT    NOT NULL DEFAULT '',
  source_episode_name TEXT    NOT NULL DEFAULT '',
  source_episode_url  TEXT    NOT NULL DEFAULT '',
  source_history_key  TEXT    NOT NULL DEFAULT '',
  source_binding_key  TEXT    NOT NULL DEFAULT '',
  updated_at          INTEGER NOT NULL,
  PRIMARY KEY (config_id, media_type, tmdb_id, season_number)
);
CREATE INDEX IF NOT EXISTS idx_tmdb_season_progress_history
  ON tmdb_season_progress(config_id, source_history_key);
```

**约束**：

- 全部为**新增表**，不改动 `configs`/`history`/`favorites`/`search_cache`/`site_health`/`spider_logs` 的任何列或主键。
- `history` 表**不新增列**。季度字段通过 `tmdb_season_progress` 与 `tmdb_season_bindings` 表达，避免重演上游"36→37 迁移被占用"的版本号冲突问题。

### 6.2 迁移策略

```dart
static const int schemaVersion = 2;   // 1 → 2：新增 TMDB 表
```

- `_migrate()` 保持幂等（`CREATE TABLE IF NOT EXISTS`），因此**无需**分支式迁移代码。
- `schema_version` 的写入方式不变（`ON CONFLICT DO UPDATE`）。
- 旧数据库（version 1）打开后自动获得新表，**不丢任何数据**。
- 新数据库直接建到 version 2。

### 6.3 惰性回填

历史/进度数据**不做一次性回填**：

1. 读取历史时，若有可用的 `tmdb_season_progress` 与绑定 → 按季度投影；
2. 无绑定 → 走 `UnknownSeason` 路径（来源键隔离）；
3. 用户主动绑定后，后续播放自动开始写季度进度；
4. 稳定版本运行一段时间后仍不删除旧数据。

### 6.4 文件缓存

```text
<cacheDir>/tmdb/<type>_<md5>.json
```

- `<type>` ∈ `detail` / `search` / `person` / `season` / `episode` / `videos` / `configuration` / `cnSeason`。
- 目录创建失败时**降级为不缓存**（返回 `null` 路径），不抛异常、不影响主流程（对齐上游 `cacheFile` 的 `try/catch`）。
- 写缓存失败**不影响**返回值。
- 缓存文件大小上限：单文件 **8 MiB**；超限拒绝写入并记日志。

### 6.5 清理边界

| 操作 | 影响 |
| --- | --- |
| "重置缓存" | 删除 `<cacheDir>/tmdb/**`（含 EPG/字幕/弹幕等其他缓存目录，行为不变）；**保留** SQLite 中的匹配与绑定 |
| "清空历史" | 清空 `history` **与** `tmdb_season_progress`；**保留** `tmdb_matches` 与 `tmdb_season_bindings`（它们是元数据结论，不是观看记录） |
| "清除 TMDB 配置" | 清空 settings 的 `tmdb` 段；**保留**缓存与绑定（用户可能只是换 Key） |
| "重置全部数据" | 删除数据库文件与配置目录（既有行为，需二次确认） |

> 依据 `01` §11 Q4/Q5：手动匹配结论属于用户资产，不随缓存清理消失。

### 6.6 数据库异常处理

- 打开失败：返回 `StoreOpenResult(error:)`（既有机制），TMDB 功能降级为"仅内存缓存 + 不落盘"。
- 单次写失败：记录 `storage` 错误，**不影响**本次匹配/播放结果。
- 数据库损坏：启动不被阻塞（既有验收项 §16.3）。

---

## 7. 与播放入口的边界

TMDB **不参与**播放入口决策。播放入口（`type=4` 的 `play`/`flag` 参数、解析器选择、直链判定）
由既有 Phase 2/3 逻辑负责（见主设计文档 §7.4.8 与 `docs/phase3/README.md`）。

TMDB 只提供两件事给播放链路：

1. **季度/集号身份**（`SeasonIdentity` + TMDB 集号）→ 供季度进度与换源判定；
2. **剧集展示标题/剧照**（`displayTitle`、`stillUrl`）→ 供详情页与播放页展示。

因此：

- `PlaybackDecision` **不新增** TMDB 字段；季度身份通过 `resolvePlayback` 的**入参**传入（对齐 Phase 3 的 `withIntentTmdbEpisodeIdentity` 语义）。
- TMDB 请求失败**不得**影响 `PlaybackDecision` 的产生。

---

## 8. 可观测性

| 事件 | 字段 |
| --- | --- |
| 请求 | `type`, `path`（不含 query）, `cacheHit`, `refresh`, `elapsedMs` |
| 缓存 | `source`（cache / network / stale-cache）, `ageMs`, `ttlMs` |
| 熔断 | `opened` / `closed`, `cooldownMs`, `statusCode` |
| 错误 | `kind`, `statusCode`, `elapsedMs`, `retryable` |
| 写盘 | `table`, `rowsAffected`, `elapsedMs` |

**禁止记录**：`api_key`、`Authorization`、完整请求 URL、用户观看历史明细。

---

## 9. 与上游的差异汇总

| 项 | 上游（Android） | PC 端 | 理由 |
| --- | --- | --- | --- |
| 配置存储 | `Prefers.getString("tmdb_config")` | `<configDir>/settings.json` 的 `tmdb` 段 | PC 端无 SharedPreferences；且需与配置记录解耦 |
| 缓存存储 | `Path.cache()/tmdb/*.json` | 同构：`<cacheDir>/tmdb/*.json` | 行为对齐 |
| 匹配/绑定持久化 | Gson JSON 字符串 | SQLite 表 | 可查询、可索引、可迁移 |
| 季度进度持久化 | Room `TmdbSeasonProgress` | SQLite `tmdb_season_progress` | 语义对齐，去掉 `cid` → `configId` |
| OMDB 评分 | 支持 | 同构：`OmdbService` + 设置页 `omdbApiKey`（2026-11-11） | 无 Key 不请求；评分失败只降级不报错 |
| 线路选择 | `TmdbProxy` 内置线路 + `auto` 延迟择优/失败切换 | 内置线路 + 自定义地址 + 手动测速（§5.6），无 `auto` | PC 端没有逐图兜底；静默换线路会让同一张图落到不同域名。测速只给结论，不改配置 |
| 错误分类 | `IllegalStateException` + 字符串 | 结构化 `AppErrorKind.tmdb*` | 对齐 Phase 3 的字幕/弹幕/EPG 模式 |
| 取消语义 | 线程中断 + `CancellationException` | `CancellationToken` + `siteCancelled` | 对齐 PC 端既有机制 |
| 日志 | `SpiderDebug.log` | `LogService` | 对齐 PC 端既有机制 |

---

## 10. 开放问题（实施前需确认）

| # | 问题 | 影响 | 建议 |
| --- | --- | --- | --- |
| Q1 | `settings.json` 是否已存在读写实现？ | 影响工作量 | 当前仅 `AppPaths.settingsPath` 存在（`app_paths.dart:31`），需新增 `SettingsStore`；建议按本设计一次建好，供后续设置项复用 |
| Q2 | 是否需要把 TMDB 设置同步进"备份/恢复"？ | 影响用户迁移体验 | **仅同步非凭据字段** |
| Q3 | 缓存单文件 8 MiB 上限是否合理？ | 影响大作品详情 | 详情响应通常 < 500 KB；8 MiB 足够，超限只记日志 |
| Q4 | 熔断冷却 5 分钟是否需要在 UI 上倒计时？ | 影响体验 | 只显示"暂时不可用，请稍后重试"，不暴露精确倒计时 |
| Q5 | 是否支持多套 TMDB 配置（多 Key 轮换）？ | 影响配额策略 | **不支持**，保持单配置，降低复杂度 |

---

## 11. 验收要点（详见 `05`）

1. `TmdbConfig.sanitize()` 13 条归一化规则逐条用例，含别名键与 JWT 判定。
2. TTL 常量与"新鲜命中 / 网络 / 陈旧兜底"三级读路径。
3. 鉴权熔断：401 → 5 分钟冷却 → 冷却期内**零请求** → 换 Key 后立即恢复。
4. 取消时**不写缓存**、不落盘。
5. 七个 `tmdb*` 错误分类的映射与用户文案。
6. `isTmdbError` 只认 `tmdb*` 前缀；TMDB 失败**不升级**为浏览/播放失败。
7. `schemaVersion` 1 → 2 迁移幂等；旧库打开后新表存在且旧数据完好。
8. `settings.json` 读写往返；凭据在日志与诊断导出中脱敏。
9. 缓存目录不可写时**降级为不缓存**，主流程不受影响。
10. "重置缓存"保留 SQLite 结论；"清空历史"清空季度进度但保留匹配与绑定。
11. 内置线路经 `sanitize()` 后落在 `/3` 与 `/t/p/w342`；换图片线路后后景跟随（规则 15）；线路探测地址在官方/路径式反代/查询式代理三种形态下拼接正确。
