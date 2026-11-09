# P2-1 增强：追剧日历（TMDB 真实播出日接入）

- 日期：2026-11-08
- 范围：`apps/desktop-flutter`（WebHTV PC）
- 上游：`following/`（`FollowingIdentity`、`FollowingSchedulePolicy`、`FollowingUpdatePolicy`、
  `FollowingStore`）、`ui/activity/FollowingActivity.java`（日历部分）
- 关联：`docs/phase9/evidence/06-w3-following.md`（追番 P2-1 基线）、
  `docs/phase9/evidence/07-w3-following-runtime.md`（运行期检查与通知）、
  `docs/phase4/design/01`（TMDB 身份匹配）、`docs/phase4/design/03`（TMDB 接口与缓存）

## 1. 状态

日历页、纯逻辑归日层与 TMDB 真实播出日接入**均已实现**：`followingCalendarByDay`
真正收到 `airTimes`，条目来源可由 TMDB `air_date` 驱动（`CalendarSource.real`）。

明确**没做**的：无端到端截图 / 真机验收（未构建 Windows 安装包、未截图）；
追番表**未新增** `tmdb_id` 列（schema 不变，每次靠 match store / 身份服务解析）；
安卓日历的「本周」聚合视图未移植。

## 2. 数据与归日

归日顺序在 `lib/core/following_calendar.dart` 的 `_collectItem`（:345-390）里，
**逐级降级、前一级命中即返回**：

| 级别 | 输入 | 来源标记 | 集号取值 | 代码 |
| --- | --- | --- | --- | --- |
| 1 | 调用方传入的 `FollowingAirTime`（本任务 = TMDB 每集 `air_date`） | `real`「真实播出」 | 该集的 `episode`（`<= 0` 时退回已发布集数） | :365-374 |
| 2 | `Following.nextAirAtMs`（站点给出的下一集时间） | `real`「真实播出」 | 已发布集数 | :376-380 |
| 3 | 本地 `lastCheckedAtMs → metadataUpdatedAtMs → updatedAtMs → nowMs` | `local`「本地推算」 | 未看区间（已看完退化为最新一集） | :382-389 |

- `CalendarSource` 定义在 :41-46，`real('真实播出')` / `local('本地推算')`；
  卡片上的徽标由 `lib/ui/following_calendar_page.dart:441`（`calendar-source-<identityKey>`）渲染，
  **用户能直接看到**这一天是真实播出还是本地推算。
- 时间可信窗口在 :29-38：真实播出最多超前 1 年、回溯 5 年（更远视为脏数据丢弃，
  `_airDay` :393-399）；本地时间只容忍 1 天时钟偏差。
- 同一部剧同一天的集由 `_EntryAccumulator`（:417-455）合并成区间，不会一天刷出十几条。

### 季号映射方向

数据层 `Following.season` 是 **0 基下标**（`followingIdentityKey` 的 `:s<season>`，默认季 `:s0`），
TMDB 的 `/tv/{id}/season/{n}` 是 **1 基**。因此：

- **请求时 +1**：`lib/services/following_air_time_service.dart:111-115`

  ```dart
  // TMDB 季号从 1 开始，数据层 `Following.season` 是 0 基下标：请求时 +1。
  final episodes = await _fetchEpisodes(
    tmdbId,
    math.max(0, item.season) + 1,
  ).timeout(requestTimeout);
  ```

- **回填时用原值**（保持 0 基，否则 `identityKey` 匹配不上，条目会整批丢失）：
  `following_air_time_service.dart:121-128` 的 `FollowingAirTime(season: item.season, ...)`。

端点本身也是 1 基：`lib/services/tmdb_service.dart:62` → `'/tv/$id/season/$season'`。

### `YYYY-MM-DD` 为什么必须用 `DateTime(y, m, d)`

`following_air_time_service.dart:160-176`：

```dart
/// 必须用 `DateTime(y, m, d)` 构造：`DateTime.parse('2019-11-20')` 会按 UTC
/// 解析，东八区会偏成前一天的 20:00，归日直接错一格。
```

- `DateTime.parse('2019-11-20')` 无时区后缀 → 按 **UTC** 解析，东八区拿到的是
  前一天 08:00，`followingCalendarDateOf` 切自然日就落到**前一天**，整套日历错一格。
- 实现取 `DateTime(year, month, day)`（:172）即本地时区自然日 0 点，
  `date.millisecondsSinceEpoch`（:173）就是本地 0 点毫秒。
- 另加**回读校验**（:173-174）：`DateTime(2019, 2, 30)` 会被 Dart 归一化成 3 月 2 日，
  回读不一致即判定为脏数据丢弃，避免把不存在的播出日画到日历上。

## 3. TMDB 接入的边界

接入层是 `lib/services/following_air_time_service.dart`（新增，全量 176 行），
**网络与匹配全部构造注入**（`FollowingTmdbIdResolver` :21、`FollowingSeasonEpisodeFetcher` :24），
单测零真实网络。

| 约束 | 实现 | 位置 |
| --- | --- | --- |
| 未配置零请求 | `if (!_safeIsConfigured()) return const [];` 在任何匹配/取集之前返回 | :71 |
| 就绪判定 | `TmdbConfig.isReady`（`enabled && (accessToken 非空 \|\| apiKey 非空)`） | `lib/core/tmdb_config.dart:242-243` |
| 配置读取入口 | `isConfigured: () => _tmdbConfigStore.config.isReady`（与 `_tmdbService` 同一份配置引用） | `lib/state/app_state.dart:2147` |
| 正缓存 6h | `successTtl = Duration(hours: 6)`；写入 :130-133 | :36 |
| 负缓存 30min | `failureTtl = Duration(minutes: 30)`；`_putFailure` :142-147 | :37 |
| 命中判定 | `cached != null && cached.expiresAtMs > nowMs` → `airTimes ?? const []`（`null` 即负缓存） | :100-103 |
| 并发上限 2 | `batchSize = max(1, maxConcurrency)`，`Future.wait` 分组串行 | :74-84；默认值 :39 |
| 单请求 10s 超时 | 匹配与取集各 `.timeout(requestTimeout)` | :106、:112-115；默认值 :38 |
| 异常不外泄 | 整段 `try/catch` 吞掉并按失败写负缓存；配置读取失败也按未配置处理 | :105-139、:88-94 |

追番记录里**没有 tmdbId**，解析顺序在 `lib/state/app_state.dart:2158-2180`：

1. **先查 match store**：`DatabaseTmdbMatchStore(database, configId).find(...)`（:2161-2167）
   —— 同步查询、**零网络请求**，命中且 `isTv` 直接返回 `tmdbId`；
2. **再走身份服务**：`_ensureTmdbIdentityService().match(TmdbMatchRequest(...))`（:2168-2179）
   —— 自动按剧名匹配，非 `tv` 或未命中返回 `null`（该剧被跳过，不发起取集请求）。

`FollowingAirTimeService` 侧对「未匹配」同样写负缓存（:107-110），
因此同一部未匹配的剧在 30 分钟内不会重复触发身份匹配。

配置切换时缓存一起失效：`_resetTmdbServices()` 里新增 `_followingAirTimeService = null`
（`app_state.dart:2193`），避免旧 `config_id` 的匹配结果污染新配置。

## 4. UI

| 位置 | 内容 | 行号 |
| --- | --- | --- |
| `lib/ui/app.dart` | `ShellSection` 枚举新增 `calendar`（插在 `following` 与 `spiders` 之间） | :391-402 |
| `lib/ui/app.dart` | 侧栏入口 `NavigationRailDestination(Icons.calendar_month, '追剧日历')` | :1366-1369 |
| `lib/ui/app.dart` | `case ShellSection.calendar: return FollowingCalendarPage(state: _state);` | :994-995 |
| `lib/ui/following_calendar_page.dart` | 月历网格、切月、今天、当日条目列表、来源徽标 | 全文 526 行 |

### 通知点击的消费归属（壳层只切页）

- `_syncFollowingOpenRequest`（`app.dart:467-478`）**只把侧栏切到「追番」页，
  不清 `followingOpenRequest`**。原因写在注释里：真正的消费方是 `FollowingPage`，
  壳层若提前清空，追番页拿不到身份键，点击通知就只跳到列表、不打开那一集。
- 真正的消费者是 `_consumeOpenRequest`（`lib/ui/following_page.dart:57-66`）：
  取 key → `clearFollowingOpenRequest()` → 在列表里找该条 → `_playLatest(item)`。

### 日历页的异步加载

`lib/ui/following_calendar_page.dart:43-91`：页面持 `List<FollowingAirTime> _airTimes`
（:44）与最近一次加载的追番身份集合快照 `_airTimesKey`（:47）；`initState`（:59）与
每次 `notifyListeners`（:71）走 `_loadAirTimes()`，**只有身份集合变化才重取**（:78），
结果 `setState` 回写后再归日（:193 `airTimes: _airTimes`）。

加载中 / 失败 / 未配置一律等价于空列表 —— 与接入前的行为完全一致，
条目退回 `nextAirAtMs` 或本地推算，不出现空白页也不阻塞 UI 线程。

## 5. 验证证据

用例数（按各文件内 `test(` / `testWidgets(` 声明统计）：

| 文件 | 用例数 | 覆盖内容 |
| --- | --- | --- |
| `test/phase9_calendar_logic_test.dart` | 13 | 月历网格、集号区间文案、归日（渐进式）三组 |
| `test/phase9_calendar_page_test.dart` | 6 | 切月、今天高亮、圆点、集号区间、空态、来源标记区分 |
| `test/phase9_calendar_air_time_test.dart`（本任务新增） | 8 | 服务 7 + 日历页注入 1 |
| `test/phase9_following_test.dart` | 23 | 身份/调度、更新通知策略、存储与服务、追番页、默认开启、系统通知降级 |

本任务实际执行的定向命令与输出：

```text
$ flutter analyze lib\services\following_air_time_service.dart lib\state\app_state.dart lib\ui\following_calendar_page.dart test\phase9_calendar_air_time_test.dart
Analyzing 4 items...
No issues found! (ran in 4.3s)
```

```text
$ flutter test test\phase9_calendar_air_time_test.dart test\phase9_calendar_page_test.dart test\phase9_following_test.dart
00:39 +37: All tests passed!
```

新增 8 个用例（`phase9_calendar_air_time_test.dart`）：

| group | 用例 | 断言摘要 |
| --- | --- | --- |
| 追番真实播出时间服务 | `匹配命中 → 集号/季 0 基/本地 0 点毫秒` | 请求 TMDB 季号为 1；回填 `season == 0`、`episode == 3`、`airAtMs == DateTime(2019,11,20).millisecondsSinceEpoch` |
| 同上 | `空/非法 date 被过滤掉` | `''`、`2019-02-30`、`not-a-date` 全部丢弃，只留合法那集 |
| 同上 | `TMDB 未配置 → 空结果且零请求` | 结果空且 `resolveCalls == 0 && fetchCalls == 0` |
| 同上 | `请求抛错 → 空结果、不抛、写负缓存` | 首次 `fetchCalls == 1`、无异常逃逸；第二次仍为 1 |
| 同上 | `请求超时 → 空结果、不抛、写负缓存` | 永不完成的 Completer + 20ms 超时；两次调用 `fetchCalls` 仍为 1 |
| 同上 | `成功结果缓存 → 第二次不重复请求` | 两次都返回 1 条；`resolveCalls == 1 && fetchCalls == 1` |
| 同上 | `无 tmdbId 匹配 → 跳过该剧，其余照常产出` | 只产出 `matched` 那部（episode 7），`missing` 被跳过 |
| 追剧日历接入真实播出时间 | `注入 airTimes 后条目落在真实播出日并显示「真实播出」` | 条目 key 存在、出现「真实播出」、不出现「本地推算」、文案 `S1E5 · 共 1 集`、当天有圆点 |

全量状态（**说明数据来源**）：

- 全量 `flutter analyze` **干净**（0 issue）—— 07 记录的 `following_calendar.dart:120`
  `return_of_invalid_type` 在逻辑层完成后已消失；本任务的定向 analyze（上文）也覆盖了
  `following_calendar_page.dart` 对 `core/following_calendar.dart` 的依赖分析，同样 0 issue。
- 全量 `flutter test` 除 `test/phase8_app_state_config_test.dart: 设置按钮顺序后立即生效`
  一条**既有失败**外通过。该失败与本任务无关，且原因已复核：
  `phase8_app_state_config_test.dart:89` 断言 `playerButtonOrder.length == 9`，
  而 `lib/core/player_buttons.dart:96-137` 的 `kPlayerButtons` 实际只定义了
  `prev/play/next/mute/volume/speed/episodes/fullscreen` **8 个**。
- 上述"全量"数字引自 07 与本轮并行任务的复跑；本次子代理受边界约束**只跑了定向命令**，
  未亲自复跑全量。这一点如实标注，不代替全量证据。

### 一条时钟边界脆弱用例（如实披露）

`phase9_calendar_page_test.dart` 的 `来源标记区分真实播出与本地推算` 用
`DateTime.now().add(const Duration(hours: 1))` 充当真实播出时刻，却断言「今天」的列表。
本地时间 23:54 首次跑回归时它失败（`+1h` 已落到次日，条目不在今天）；过零点后重跑，
三文件 37 用例全绿。即：该用例在 23:00 之后会假失败，与本改动无关。该文件在本任务禁改名单内，
未作改动，建议后续单独修（改成取今天内的固定时刻或注入可控时钟）。

## 6. 与安卓的差异

| 项 | 安卓 | PC（本任务） |
| --- | --- | --- |
| 后台刷新 | WorkManager 式周期任务，关闭应用也会检查 | **无后台常驻**：只在应用运行期间用 `Timer` 检查，日历数据也随之只在运行期刷新 |
| 季/集对齐口径 | 以 TMDB 季号（1 基）为主键，`FollowingMetadataClient` 落库 | 数据层季号是 **0 基**下标，请求 TMDB 时 +1、回填时还原（见 §2）。与安卓"季号唯一标识一季"的语义一致，差异只在**存储基址**；本任务无从对照安卓 `FollowingMetadataClient` 源码（仓库内无安卓源码），**未做逐字段比对** |
| 日历视图 | 有「本周」聚合视图 | 只有月历网格 + 单日列表；「本周」未移植 |
| TMDB 元数据落库 | 追番元数据（含季集与播出时间）写入追番表 | **不落库**：每次由 match store / 身份服务解析，结果只在内存缓存 6h/30min |
| 系统通知 | 原生通知 | 依赖 `flutter_local_notifications`，失败降级为应用内提示（见 07） |

## 7. 已知缺口 / 后续

1. **追番表未持久化 `tmdbId`**：每轮都要经 match store → 身份服务解析；命中靠 6h 内缓存，
   缓存过期后会重新解析（match store 命中时不发网络，成本主要是身份匹配兜底那一步）。
   若要彻底消掉这一步，需要给 `following` 表加 `tmdb_id` 列并做迁移 —— 本任务明确**未做**
   （不改 schema）。
2. **日历依赖本地时区**：归日、`DateTime(y,m,d)` 换算、可信窗口全部按运行机器的本地时区；
   跨时区使用（如用户改系统时区）会让已归日的条目偏移。未做跨时区一致性处理。
3. **无真机 / 截图证据**：按边界不构建 Windows 安装包，弹窗、toast、真实 TMDB 数据下的
   日历观感均未截图验证；已有证据全部来自单测与 widget 测试。
4. **`phase9_calendar_page_test.dart` 的时钟边界用例**（§5 末）未修，属既有缺陷。
5. **`docs/phase9/evidence/README.md` 索引未登记本文与 07**：本次文件配额只允许新增本文
   1 个文件，索引待后续统一补。
6. 全量 test 的一条既有失败（`phase8_app_state_config_test.dart`，断言 9 而实现只定义 8 个按钮）
   未修，属既有缺陷，与追番/日历无关。
