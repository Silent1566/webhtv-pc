# 片头/片尾远端标定：数据源与实测契约

日期：2026-11-15　实现：`lib/core/skip_plan.dart` + `lib/services/intro_skip/`

本文只记录**实测过的事实**与被实测推翻过的猜测。改动这几个源之前先读这里，
不要照抄网上文档——三家都不一样，而且两家不给你参考时长。

---

## 1. 三家一览

| 源 | 端点 | 查询键 | 参考时长 | 鉴权 |
| --- | --- | --- | --- | --- |
| IntroDB | `GET https://api.introdb.app/segments` | **IMDb** + 季集号 | 顶层 `duration_ms`/`runtime_ms`/`duration_sec`/`runtime_sec` 之一，常缺 | 无 |
| TheIntroDB | `GET https://api.theintrodb.org/v4/media` | **TMDB**（v3 亦可） | **不下发** | 无 |
| TODB PlayBack | `POST https://playback.theotherdb.org/api/metadata` | **TMDB** | 每个版本各一份 `version_runtime`（**秒**） | 文档写 Bearer key，**实测免登录可用** |

三家全部并行查询，总预算 5 s；单家失败不影响其余（`registry.dart`）。

---

## 2. IntroDB

```
GET https://api.introdb.app/segments?imdb_id=tt0944947&season=1&episode=1
```

实测响应（2026-11）：

```json
{"imdb_id":"tt0944947","media_type":"tv","season":1,"episode":1,
 "intro":null,"recap":null,
 "outro":{"start_sec":3631.5,"end_sec":3699.5,
          "start_ms":3631500,"end_ms":3699500,
          "confidence":1,"submission_count":2},
 "post_credits":null,"no_intro":false}
```

- 四个顶层字段是**对象**，不是数组：`recap` / `intro` / `outro` / `post_credits`。
- `post_credits` 是**片尾之后的彩蛋/附加内容**，映射成 `SkipKind.postCredits`，
  **不是**「下集预告」。这家实测响应键集恒为 `recap/intro/outro/post_credits`，
  根本没有预告字段——安卓版也没收这个字段，它猜的是 `preview/next_episode/trailer`，
  在这家永远命中不了。
- 同一个时间点同时给了 `*_ms` 与 `*_sec`：优先 `*_ms`，缺了才用 `*_sec × 1000`。
- 它是唯一带 `confidence` / `submission_count` 的源，去重打分时因此有优势。
- 没有 IMDb id 就**查不了**——PC 侧通过 `TmdbPlaybackIdentity.imdbId` 透传
  （来源是 TMDB `external_ids.imdb_id`）。拿不到时这一家返回空列表而不是失败，
  否则只有 TMDB 键的查询会因为这家永远不可缓存而每集重打一轮。

---

## 3. TheIntroDB

```
GET https://api.theintrodb.org/v4/media?tmdb_id=1399&season=1&episode=1[&duration_ms=...]
```

实测响应：

```json
{"tvdb_id":121361,"type":"tv","season":1,"episode":1,
 "intro":[{"start_ms":null,"end_ms":106019}],
 "credits":[{"start_ms":3253219,"end_ms":3317750}]}
```

坑（都会让实现静默出错）：

1. **v4 响应里回的是 `tvdb_id`**，不是 `tmdb_id`——别拿响应里的 id 当 TMDB id 用。
   用 `tmdb_id` 查询仍然有效（v3、v4 都实测可用）。
2. `intro[].start_ms` 经常是 **null**，语义是「从 0 开始」。不要自己填 0 就完事：
   交给 `SkipPlan.resolve`，它把「开头段的 null 起点」当 0 处理。
3. `credits[].end_ms` 经常是 **null**，语义是「一直到文件结尾」。这是**无界段**，
   seek 到结尾等于「本集看完」，必须走连播判定而不是普通 seek。
4. **不下发参考时长**。所以尾部段只能按原始时间戳理解，`referenceDurationMs = 0`。
   想按「距结尾的距离」折算，只能靠另外两家。

---

## 4. TODB PlayBack（新来源，2026-11 加入）

站点：`https://playback.theotherdb.org`（「播放资料库 TODB PlayBack」）。
它的 `/docs` 是 Vue SPA，正文在懒加载 chunk 里，`curl` 直接取只会拿到空壳。

取文档的办法（保留下来，免得下次再挖一遍）：

```bash
# 1) 主 bundle 里能找到懒加载 chunk 名
curl -s https://playback.theotherdb.org/playback_assets/index-*.js | grep -o 'DocsPage-[A-Za-z0-9]*\.js'
# 2) 文档正文就在 DocsPage chunk 里（含 Base URL、请求/响应示例、字段表）
curl -s https://playback.theotherdb.org/playback_assets/DocsPage-*.js
```

Base URL 与端点：

```
POST https://playback.theotherdb.org/api/metadata
Content-Type: application/json
Authorization: Bearer <key>   # 文档给了，但实测不填也返回真实数据
```

实测请求/响应：

```json
{"platform_type":"tmdb_id_tv","platform_value":"226045",
 "season_number":1,"episode_number":1,
 "includes":["marker"],"page":1,"page_size":3}
```

```json
{"page":1,"page_size":3,"has_more":false,"items":[
  {"version_id":1192,"version_name":"爱奇艺","version_runtime":1300,
   "version_platform":"iqiyi","video_type":"tv","todbv_id":2651,
   "marker":[{"marker_id":1588,"marker_type":"intro",
              "title":null,"time_start":0,"time_end":27}]}]}
```

要点：

1. **一个 `items` 是一路片源（一个「版本」）**，各版本时长不同（`version_runtime`，
   单位**秒**），因此它是唯一能给出「按平台版本标定」的源——对国内站点
   （爱奇艺/优酷/腾讯）尤其对得上。其余两家只给一条全局时间轴。
2. `marker[].time_start` / `time_end` 单位是**秒**（× 1000 转毫秒），`time_end` 可为 null。
3. `marker_type` 至少见过 `intro` 与 `chapter`。**`chapter` 是剧情章节标记，
   不是可跳过段**——认进来会让播放器把正片当片尾跳掉。只认 `SkipKind.fromWire`
   认识的那几个（intro/outro/credits/recap/preview/…）。
4. 电影用 `platform_type: "tmdb_id_movie"`，且**不发** `season_number`/`episode_number`。
5. 覆盖不全：实测《权力的游戏》S1E1 返回 `items: []`。它是补充源，不是主力源。

---

## 4.5 片段类型清单（用户可逐类开关）

| 类型 | `SkipKind` | 位 | 时间轴 | 出厂默认 | 谁提供 |
| --- | --- | --- | --- | --- | --- |
| 回顾/前情 | `recap` | 1 | 绝对 | ✓ | IntroDB、TheIntroDB、TODB |
| 片头/OP | `intro` | 2 | 绝对 | ✓ | 三家全部 |
| 片尾/ED | `outro` | 4 | 距结尾 | ✓ | 三家全部 |
| 下集预告 | `preview` | 8 | 距结尾 | ✗ | TheIntroDB、TODB |
| 彩蛋（片尾之后） | `postCredits` | 16 | 距结尾 | ✗ | IntroDB（`post_credits`）、TODB |
| 片内广告 | `advertisement` | 32 | 绝对 | ✗ | TODB |
| 中场休息 | `intermission` | 64 | 绝对 | ✗ | TODB |

### TODB 官方 `marker_type` 全枚举（8 类）

来源：其文档「响应字段取值」一节（`items[].marker[].marker_type`）。

| `marker_type` | 含义 | 本实现 |
| --- | --- | --- |
| `intro` | 片头 | → `intro` |
| `credits` | 片尾 | → `outro` |
| `recap` | 回顾 | → `recap` |
| `advertisement` | 广告 | → `advertisement` |
| `post_credits` | 彩蛋 | → `postCredits` |
| `intermission` | 休息 | → `intermission` |
| `preview` | 预告 | → `preview` |
| `chapter` | 章节 | **丢弃**，见下 |

### 三条刻意的取舍

1. **预告与彩蛋分成两类**：观众常常正相反——预告跳过、彩蛋留着。并成一类等于
   强迫二选一，而这个选择在播放页上根本看不见。
2. **`chapter` 丢弃**：它是剧情章节书签（TODB 自己就标「章节」），不是可跳过段。
   认进来会让播放器把正片当片尾跳掉。这条有测试锁死（`skip_plan_test.dart`）。
3. **预告/彩蛋/广告/休息默认关**：前两者排在最末尾，误跳等于切走一集；
   后两者依赖社区标注的准确度。开关都在设置页，由用户自己开。

### 广告有两种，别混

- **片内广告位**（`advertisement` 标记）：视频里真的有一段广告，播放到那里才跳——
  这才是本功能处理的东西。
- **清单里的广告分片**（站点把广告当成独立 `#EXTINF` 段插进 HLS）：在清单层就被
  过滤掉了，不经过这里（见 `ai_parity_business_integration` 相关实现）。

### 刻意不做的分类

SponsorBlock 那套（sponsor / self-promo / interaction reminder / filler / non-music
section）是 YouTube 插播位的分类法，VOD 站点没有对应数据源；加进来只会是一排永远
空的开关。

---

## 5. 缓存与「有没有查完」的三态

`IntroSkipProvider.fetch` 的返回值是**三态**，不是两态：

| 返回 | 含义 | 可缓存 |
| --- | --- | --- |
| `null` | 这家没答上来（超时 / 非 2xx / 坏 JSON） | ✗ |
| `[]` | 明确的「这集没数据」（404，或 200 但无标记） | ✓ |
| 非空 | 原始段（可能混着多源多版本） | ✓ |

只有**所有发起的源都可靠返回**才允许写缓存（`completed == providers.length && !failed`）——
把半份结果缓存下来，那家恢复正常后也再没机会补上。

缓存键**只含剧集身份、不含时长**：时长不是查询条件（IntroDB 压根不收，TheIntroDB 可选），
进了键会让同一集在「时长未知」与「时长已知」时各发一轮请求，也让预载永远命中不了。

---

## 6. 为什么尾部段要按「距结尾的距离」折算

数据源标定用的是它自己那版片源。本地线路普遍掐头、加前贴、删减，绝对值整体漂移，
但「距结尾还有多久」基本稳定。所以：

- 折算条件是 `|参考时长 − 本集时长| > 2 s`，整段平移该差值；
- 差值超过 **5 min** 视为不是同一版本，**放弃折算**保留原始时间戳——
  平移量本身就比片尾还长时，跳过去等于把正片当片尾扔掉；
- 段末落在参考结尾 5 s 内 → 判为**无界段**（一直放到文件结束）。

实现与用例见 `lib/core/skip_plan.dart` 与 `test/skip_plan_test.dart`。

---

## 7. 未决风险

1. **TODB 的鉴权**：文档要求 `Bearer <key>`，实测免登录可用。若某天开始强制鉴权，
   这一家会退化成「没答上来」（`null`，不可缓存），另外两家不受影响。
   到那时需要决定是否申请密钥——这是产品决策，不该由实现替用户定。
2. **TheIntroDB v3/v4 并存**：当前用 v4。若 v4 下线，v3 的响应形状与 v4 在本实现
   关心的字段上一致（实测），改端点即可。
3. **只按 TMDB/IMDb 键查询**：站点自身的剧集没有 TMDB 匹配就没有远端标定，
   此时只有用户手动标记可用（`SkipPlan.withManualOverride`）。
