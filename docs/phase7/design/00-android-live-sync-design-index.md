# 安卓实时同步与长连接保活（设计指导 · 总索引）

- 状态：设计指导（Design Guidance），**待评审**
- 日期：2026-10-17
- 适用工程：`apps/desktop-flutter`（WebHTV PC，Flutter + media-kit 主线）
- 上游参考：`webhtv/默影视`（Android 工程，`F:\Workspace\webtv3\webhtv`）
- 主设计文档：`docs/webhtv-pc-design.md`（本文档是它的 Phase 7 展开，接 §28）
- 阶段计划：`docs/phase7/README.md`
- 上游：`docs/phase5/README.md`（Phase 5：T4 站点桥接 + 历史/设置同步，已完成）

---

## 0. 一句话目标

把 Phase 5 的「**手动、一次性、快照式**」同步升级为「**可选的实时、增量、双向**」同步，
并解决两件事：**（A）** 历史 / TMDB / AI 设置能实时互通；**（B）** 安卓息屏或播放缓存
耗尽后，PC 仍能维持或恢复与安卓的通讯，且恢复后**续播而不是跳下一集**。

---

## 1. 用户诉求（原文）

> 请设计方案（能指导完整功能实现和验收）让桥接安卓版后能实现历史记录，tmdb，ai 等设置
> 备份实时通过。实时同步可以通过设置控制是否开启，然后新增手动拉取和手动推送等功能。
> 如何维持和安卓版的长时间通讯比如：心跳，现在安卓版自动息屏后就无法访问了并且在播放
> 的视频缓存用完后也会播放失败这个适合再唤醒安卓版点击继续播放不会续播而是直接跳到
> 下一集播放了

拆成五条可验收的诉求：

| # | 诉求 | 对应文档 |
| --- | --- | --- |
| R1 | 历史记录 / TMDB / AI 设置**实时**同步 | `01` §3–§5、`02` |
| R2 | 实时同步有**开关**（默认关） | `01` §6 |
| R3 | 新增**手动拉取**与**手动推送** | `01` §7 |
| R4 | **长时间通讯**：心跳、息屏后仍可达 | `02` §3–§6 |
| R5 | 缓存耗尽播放失败后唤醒，**续播**而非跳下一集 | `03` |

---

## 2. 为什么需要独立设计文档

Phase 5 已经落地了「桥接 + 同步」，但它有三处**结构性限制**，本轮必须正面处理：

| # | Phase 5 的现状 | 为什么不够 | 本轮的处置 |
| --- | --- | --- | --- |
| L1 | 同步是**用户点按钮**触发的一次性快照 | 用户诉求是"实时通过" | 新增**轮询式增量同步**（安卓没有推送端点，见 §3.1） |
| L2 | 设置同步白名单只有 `tmdb_enabled` / `tmdb_config` | AI 配置完全不在范围内 | 扩白名单到 `ai_config` 等，并**按段**映射（§3.3） |
| L3 | 安卓 `Server.stop()` 在息屏/后台后可能停服 | 用户实测"息屏后就无法访问" | 新增**可达性探测 + 唤醒 + 心跳**（`02`） |

第三处是最容易被误诊的：用户看到的"无法访问"**不是** PC 的问题，而是安卓侧的
`Server` 生命周期 + 厂商后台限制。文档必须把**哪些能修、哪些只能引导用户设置**
写清楚（`02` §2），否则实现阶段会去改一个改不动的地方。

---

## 3. 上游实测契约（源码级证据）

以下每条都给出上游文件与行为，作为 PC 端实现的**唯一事实来源**。
上游工程根：`F:\Workspace\webtv3\webhtv`。

### 3.1 安卓**没有**推送端点，只有「被拉」与「主动推」

| 事实 | 证据 | 等级 |
| --- | --- | --- |
| 安卓的 17 个 `Process` 里**没有** WebSocket / SSE / long-poll 端点 | `Nano.addProcess()` 全量枚举 | 源码 |
| 安卓**不会**在历史变化时主动通知 PC | `PlaybackWebhookSender` 只发用户配置的 webhook，且 `WebhookConfig.acceptsEvent` 只认 `progress/ended/deleted` | 源码 |
| 安卓有「**远端同步源**」：**它自己作为客户端**去拉一个 HTTP 端点 | `PlaybackRemoteSyncer` + `RemoteSyncConfig` | 源码 |
| 拉取请求头：`X-WebHTV-Config-Key` / `X-WebHTV-Since` / `X-WebHTV-Limit` / `X-WebHTV-Token`；响应解析 `nextSince` / `items` / `deleted` | `PlaybackRemoteSyncer.fetch` + `PlaybackRemoteSyncPayload` | 源码 |
| 拉取周期：`startup` 后 3 s 一次，之后**每 5 分钟**一次；`intervalMinutes<=0` 时只在启动时拉 | `PlaybackRemoteSyncer.PERIODIC` + `RemoteSyncConfig.shouldSyncNow` | 源码 |
| 增量游标按 `configKey` 分别存（`cursors` map），失败时**不推进游标** | `PlaybackRemoteSyncStore.markResult` / `PlaybackRemoteSyncer.sync` | 源码 |

> **设计后果（最重要的一条）**：PC 要实现"实时"，**不能**等安卓推。
> 可行路径有两条，本轮**两条都做**：
>
> 1. **PC 主动轮询**（`01` §4）：PC 定时打安卓的读取端点，把新记录拉回来；
> 2. **反向利用远端同步源**（`01` §5）：PC 暴露一个**增量端点**，让安卓按它自己的
>    5 分钟周期来拉——这条路径**不需要 PC 常驻在线**，是"安卓侧实时"的唯一途径。

### 3.2 安卓的**读取**端点（PC 轮询用）

| 端点 | 方法 | 鉴权 | 返回 |
| --- | --- | --- | --- |
| `/api/playback/current?siteKey=<key>` | GET/POST | **无** | 单条 `PlaybackRecord` JSON；无记录 404 `当前无可读播放记录` |
| `/api/playback/progress[...]` | POST | 需 `viewing_record_sync_enabled` **且** `viewing_record_sync_local_write` | 写入（默认 403） |

| 事实 | 证据 | 等级 |
| --- | --- | --- |
| `/api/playback/current` **不带鉴权开关**，只要服务在跑就能读 | `PlaybackRecordApi.doResponse` 无 `ViewingRecordSyncStore` 检查 | 源码 |
| `siteKey` 必填，否则 400 `siteKey不能为空` | 同上 | 源码 |
| 返回字段由 `PlaybackFieldPolicy.apiSafe()` 裁剪：**不含** `event` / `eventId` / `episodeUrl`；**含** `historyKey`/`siteKey`/`vodId`/`vodName`/`vodPic`/`flag`/`sourceBindingKey`/`episodeName`/`episodeId`（2026-10-17 追加，见 §3.2.2）/`mediaType`/`tmdbId`/`seasonNumber`/`tmdbEpisodeNumber`/`state`/`positionMs`/`durationMs`/`progress`/`speed`/`speedOverride`/`completed` | `PlaybackFieldPolicy.apiSafe()` | 源码 |
| **没有**"列出全部历史"的读取端点 | 17 个 `Process` 全量枚举 | 源码 |

> **⚠️ 勘误（2026-10-17，在 webtv4 复核后推翻原结论）**：
>
> 本文档初稿把 `/api/playback/current` 当成"该站点最近一条历史"，**这是错的**。
> 源码实证：`PlaybackApi.current(siteKey)` 的数据源是
> `PlaybackRuntime.currentHistory()` —— 一个 **static volatile 内存字段**，
> 由 `PlaybackEventCollector.updateHistory()` 在**播放中**写入，**不落库**。
>
> | 事实 | 证据 |
> | --- | --- |
> | 未在播放时该字段恒为 `null` → 端点 404 | `PlaybackRuntime.java:14`、`PlaybackApi.java:20` |
> | 全仓唯一调用方是 `PlaybackRecordApi` | `grep -rn "PlaybackApi.current"` → 1 处 |
>
> **推论：路径 A 在安卓侧当前不可用**——息屏或未播放时必然 404，
> 而用户核心诉求恰恰是"息屏后仍能同步"。
>
> **处置**：路径 A 改为依赖**新增**的 `GET /api/playback/history?siteKey=`
> （从数据库读，不依赖播放内存态）。该端点的安卓侧设计见
> `F:/Workspace/webtv4/webhtv/docs/PC-REALTIME-SYNC-01-android-contract-gap.md` §5.1。
> 在安卓侧交付前，PC 的路径 A **必须**降级为"仅能读到正在播放的那一条"，
> 并在 UI 明示（P5）。

### 3.2.1 安卓的**身份解析**端点（PC 作为服务端必须实现）

| 事实 | 证据 | 等级 |
| --- | --- | --- |
| 安卓侧 `PlaybackIdentityResolver` 已实现，且在**每次同步前**调用 | `PlaybackRemoteSyncer.sync()` 第 81 行 | 源码 |
| 它会 `POST` 到 `<远端>/api/playback/identity/resolve` | `PlaybackIdentityResolver.identityEndpoint()` | 源码 |
| 请求头含 `X-WebHTV-Identity-Version: 2`、`X-WebHTV-Address-Match-Version: 1`、`X-WebHTV-Request-Id` | `PlaybackIdentityResolver.resolve()` | 源码 |
| 响应 `404/405/501` → 标记 `unsupported`，进入旧服务端兼容模式 | 同上 | 源码 |
| 协议规范：`docs/playback-sync-identity-matching-design.md` §6.1–§6.6 | 上游设计文档 | 源码 |
| 五套服务端参考实现已存在（Cloudflare/Deno/Vercel/Go/Rust） | `serverless/webhtv-remote-*/` | 源码 |
| Go 参考实现完整：`identityResolve`、能力声明、别名路由 | `serverless/webhtv-remote-go/playback_identity.go`、`playback.go:120-138` | 源码 |
| 共享 fixture：`identity.js`、`resolve-cases.json`、`canonical-addresses.json` | `serverless/playback-identity-fixtures/` | 源码 |
| 身份键算法：`strict`/`endpoint`/`host` 三层 SHA-256 + `legacy` URL 哈希 | `PlaybackConfigIdentity.material()` | 源码 |
| `GET /api/playback/sync/status` 必须声明 `capabilities.identityResolve=true` 等 5 项 | `serverless/webhtv-remote-go/playback.go:367` | 源码 |

> **设计后果（本文档初稿完全遗漏）**：PC 的拉取端点**必须同时实现**：
>
> 1. `POST /api/playback/identity/resolve`（身份解析，幂等原子）
> 2. `GET /api/playback/sync/status`（能力声明）
>
> 否则安卓每次同步都会打一次 resolve 拿到 404，被记为 `unsupported`——
> 功能可用但**永久失去跨设备身份匹配**，用户可见状态是"服务端不支持自动身份匹配"。
>
> 服务端**必须复用** `PlaybackConfigIdentity` 的三层键算法（不能重新实现），
> 否则与客户端算出的键不一致。

### 3.2.2 `apiSafe()` 缺 `episodeUrl` 导致集消歧失效

| 事实 | 证据 | 等级 |
| --- | --- | --- |
| `apiSafe()` = `base()` − `event` − `eventId`；`OBJECT` 含 `episodeName` 但**不含** `episodeUrl` | `PlaybackFieldPolicy.java:11,25-30` | 源码 |
| `episodeUrl` 只在 `FULL`/`OPTIONAL`/`CUSTOM_SAFE`（webhook 用）里 | `PlaybackFieldPolicy.java:14-15` | 源码 |
| PC `SyncHistoryItem.matchKey` = `(siteKey, vodId, flag, episodeId)`，`episodeId` 来自 `episodeUrl` | PC `android_sync.dart:190` | 源码（PC） |

> **设计后果**：PC 从 `apiSafe` 响应里拿不到 `episodeUrl` → `episodeId` 为空 →
> **同一剧的所有集塌缩成同一个 `matchKey`**，看第 3 集会覆盖第 1 集的记录。
>
> **✅ 已交付（2026-10-17）**：安卓侧采用了两种修法中的推荐方案——
> `apiSafe()` 追加 `episodeId` 字段，值为 `episodeUrl` 的 SHA-256（**不泄露播放地址**），
> 因此**不含** `episodeUrl` 这一事实仍然成立且是刻意的。
>
> | 项 | 交付形态 |
> | --- | --- |
> | 字段名 | `episodeId` |
> | 取值 | `episodeUrl` 的 SHA-256（64 位小写 hex）；空地址 → 空串（**不是**空串的哈希） |
> | 声明位置约束 | `PlaybackFieldPolicy.API_SAFE_EXTRA` **必须**排在 `CUSTOM_SAFE` 之前（Java 静态字段按文本顺序初始化，写后面会 NPE） |
> | 回推支持 | `PlaybackProgressInput.episodeId`；有 `episodeUrl` 而无 `episodeId` 时自动补 |
>
> 交付证据：安卓 `dev4` 提交 `e55f19276fb0a73bce3a47f9bda2c16923d318b3`
> （tag `recovery/PC-REALTIME-SYNC-01/20261017042235-e55f19276fb0`）。
>
> **PC 侧仍然必须保留 §4.1 的 `episodeName` 兜底**：能力探测是运行时的，
> 用户可能连着未升级的安卓端。兜底分支在 `episodeId` 存在时**不得覆盖**它。

### 3.3 设置备份的真实形态（`Backup.prefers`）

| 事实 | 证据 | 等级 |
| --- | --- | --- |
| `prefers` 是**扁平**的 `Map<String, ?>`，键就是安卓 `Prefers` 的原始键名 | `Backup.create()` → `Prefers.getPrefers().getAll()` | 源码 |
| `tmdb_config` 的值是**一个 JSON 字符串**，不是对象 | `Setting.getTmdbConfig()` → `Prefers.getString("tmdb_config")` | 源码 |
| `ai_config` 的值同样是**一个 JSON 字符串** | `Setting.getAiConfig()` → `Prefers.getString("ai_config")` | 源码 |
| `tmdb_enabled` / `tmdb_model` 是**标量** | `Backup.APP_PREFS` | 源码 |
| `settings=true` 时 `include()` 才放行 `isAppPref(key)`；`tmdb_config`/`ai_config` 均在 `APP_PREFS` 内 | `Backup.include` + `Backup.APP_PREFS` | 源码 |
| 安卓 `AiConfig` 的字段名：`enabled` / `protocol`（别名 `apiFormat`/`format`）/ `endpoint` / `apiKey` / `model` / `customUserAgent`（别名 `userAgent`/`ua`） | `AiConfig` 的 `@SerializedName` | 源码 |
| PC `AiConfig.toJson()` 用的键名与安卓**完全一致** | `lib/core/ai_config.dart` | 源码（PC） |
| 安卓 `TmdbConfig` 的键名是 `apiBase`/`apiKey`/`accessToken`/`language`/`imageBase`/`backdropBase`/`enabledSites`/… 且**带大量 `alternate` 别名** | `TmdbConfig` 的 `@SerializedName` | 源码 |
| PC `TmdbConfig.toJson()` 只写出**自己理解的子集**，不写 `apiAuto`/`proxyBase`/`omdbApiKey` 等 | `lib/core/tmdb_config.dart` | 源码（PC） |

> **设计后果**：设置同步必须**逐键**处理，且对 `tmdb_config` / `ai_config`
> 这类"值是 JSON 字符串"的键要**先解字符串再映射**，不能当成对象直接读
> （Phase 5 的 `applySyncedSettings` 对 `tmdb_config` 已经做了这层解包，
> 本轮 AI 必须复用同一模式，否则会静默拿到空配置）。

### 3.4 服务生命周期（"息屏后无法访问"的根因）

| 事实 | 证据 | 等级 |
| --- | --- | --- |
| `Server.start()` 端口从 `9978` 顺序探测到 `9998` | `Server.start()` | 源码 |
| `Server.stop()` 只在 `manage==false && service==null` 时真正停 | `Server.stop()` | 源码 |
| `ManageService` 是前台服务（`dataSync` + `connectedDevice`），持有 `PARTIAL_WAKE_LOCK` + `WIFI_MODE_FULL_HIGH_PERF` | `ManageService.acquireLocks()` | 源码 |
| `ManageService` **600 s 无访问**自动 `stopSelf()` | `IDLE_TIMEOUT = 600_000L` + `checker` | 源码 |
| `ManageService` 只在用户打开「管理页」时启动 | `ManagePageDialog.showInternal` → `ManageService.start(activity)` | 源码 |
| `App.startBackgroundServicesNow()` 会 `Server.get().start()`（**不带** manage/wake lock） | `App.java` | 源码 |
| 播放页离开时 `onStop()` 可能 `mController.pause()`（`PlayerSetting.isBackgroundOff()`） | `PlaybackActivity.onStop` | 源码 |
| `PlaybackService` 是 `MediaLibraryService`，`stopWithTask=false`，但**没有** wifi lock | `AndroidManifest.xml` + `PlaybackService` | 源码 |
| 息屏后 `Server` 是否存活**取决于厂商后台策略**，代码层无法保证 | 无 `ACTION_SCREEN_OFF` 处理；只有 `ManageService` 的 wake/wifi lock | 源码 |

> **设计后果**：PC 侧**不可能**单方面保证"息屏后仍可达"。可行的是：
>
> 1. **探测 + 分类**：区分"服务没开" / "进程被冻结" / "网络断了"（`02` §4）；
> 2. **唤醒**：`/manage/session` 会 `ManageService.touch()`，能拉起 manage 前台服务与锁；
> 3. **引导**：把安卓的电池/自启动设置做成可操作指引（`02` §5）。
>
> 文档必须明确：**这三条之外的部分属于安卓侧/系统侧，PC 不得假装能修**。

### 3.5 播放结束与"跳下一集"的根因

| 事实 | 证据 | 等级 |
| --- | --- | --- |
| 播放器 `STATE_ENDED` → `PlaybackService` 在**无人接管导航**时 `navigateItem(1)` | `PlaybackService.listener.onPlaybackStateChanged` | 源码 |
| `VideoActivity.onStateChanged(STATE_ENDED)` → `checkEnded(true)` → `checkNext` → `onNext` | `VideoActivity` | 源码 |
| `PlayerManager.onPlayerError` 在 `fallbackPlayback(e)` 失败后 `callback.onError(...)`，**不**改 `STATE_ENDED` | `PlayerManager` | 源码 |
| `VideoActivity.onError` 会 `player().reset(); player().stop();` 然后 `startFlow()`（自动换线路/换源） | `VideoActivity.onError` | 源码 |
| `History.save()` 有 `writeSurvivesDeletion` 守卫，且写入前会 `enrichTmdbId()` | `History.save()` | 源码 |
| `PlaybackEventCollector.onPlaybackStateChanged(STATE_ENDED)` 会 `sendFinalThen(record, ENDED)` 并 `resetStarted()` | `PlaybackEventCollector` | 源码 |
| 历史进度由 `VideoActivity.updatePlaybackHistoryPosition()` 周期写入 | `VideoActivity` | 源码 |

> **关键区分（`03` §2 的核心）**：
>
> - **正常播完** → `STATE_ENDED` → 跳下一集是**正确行为**；
> - **缓存耗尽/网络中断** → `onPlayerError` → 走 `onError`（换线路）或停在错误态，
>   **不会**产生 `STATE_ENDED`。
>
> 用户描述的"缓存用完后唤醒 → 点继续播放 → 跳到下一集"，最可能是
> **（i）** 缓存耗尽时被 `HttpEofRecoveryDataSource` 重连成功、播到片尾 → 真 ENDED；
> 或 **（ii）** 进度已写满（`position >= duration - 5000` 或 `progress >= 0.95`）被判完播；
> 或 **（iii）** PC 侧把 `completed` 判成 true 后 `_playNext()`。
> 三条都必须有**可观测证据**才能定论——`03` §3 给出判定实验。

### 3.6 删除同步的真实状态

| 事实 | 证据 | 等级 |
| --- | --- | --- |
| 安卓有 `PlaybackDeleteTombstone`，删除会写墓碑 | `PlaybackProgressWriter.deleteInternal` | 源码 |
| 远端同步响应**支持** `deleted`/`deletions`/`tombstones` 数组 | `PlaybackRemoteSyncPayload.parse` | 源码 |
| `PlaybackProgressDeleteInput` 支持 `scope=all/site/season` | `PlaybackProgressDeleteInput.normalize` | 源码 |
| PC 侧 Phase 5 只保证"不复活"，**不传播**删除 | `docs/phase5/design/02` §4.5 | 源码（PC） |

> **设计后果**：本轮把删除**纳入实时同步**（`01` §4.3），但必须遵守 Phase 5 的
> 「逐条 `deleteHistory` 写墓碑」纪律（`docs/phase6/README.md` §4）。

---

## 4. 五条不可退让的原则

以下五条是**契约级**要求。任何实现只要违反其一，即视为设计缺陷，必须修复而不是放宽文档。

### P1 · 实时同步默认关闭，且开关粒度到"方向"

- 实时同步（PC 轮询、安卓拉取端点、心跳）**全部默认关闭**；
- 开关至少三个，互不隐含：`实时拉取`（PC→安卓读）、`实时推送`（安卓→PC 读）、
  `设置实时同步`（含凭据项单独再确认）；
- 关闭后必须**立即停止**定时器与心跳，并释放端口（对齐 Phase 5 §28.7）。

**理由**：Phase 5 的 P3 已经把「同步默认关闭」定为契约；实时化会放大它的后果
（后台请求、耗电、隐私），默认开启等于替用户决定。

### P2 · 增量优先，全量必须显式

- 实时路径**只**走增量（游标 / `updatedAt` / 墓碑），不得每次全表传输；
- 全量只在用户点「手动拉取（全量）」时发生，且必须**先展示将覆盖多少条**；
- 任何路径都**禁止** `force=true` 清表（Phase 5 P3 继续有效）。

**理由**：安卓远端同步源的 `cursors` 设计就是为了增量；PC 侧若每次全量，
在 5 分钟周期下会把 170 站点的历史反复搬运，且 `Backup.restore(force)` 会毁数据。

### P3 · 失败不破坏本地，且必须可分类

- 任一步失败（网络、鉴权、格式、部分条目）**保留本地全部数据**；
- 错误必须落到 `AppErrorKind` 的**新分类**（`01` §8），不得折叠成"同步成功"或"0 条"；
- 增量游标**只在整批成功后推进**（对齐 `PlaybackRemoteSyncer` 的 `complete` 判定）。

**理由**：Phase 5 P5 的延续；游标推进过早会让失败的那一批**永久丢失**。

### P4 · 保活不得越界到"替用户改系统设置"

- PC 可以：探测、唤醒（`/manage/session`）、提示、记录诊断；
- PC **不得**：静默安装/卸载、改安卓系统设置、绕过电池优化、伪造用户操作；
- 所有"需要用户在安卓侧操作"的结论必须给出**可复制的指引文案**（`02` §5）。

**理由**：`ManageService.openBackgroundPowerSettings` 是**安卓侧**的能力；
PC 侧只能把 `backgroundSettingsNeeded` / `backgroundGuide` 字段呈现出来。

### P5 · 续播判定必须基于"未完成"，且与"播完"可区分

- 续播位置只在 `position > 0 && position < duration - END_MARGIN && !completed` 时生效；
- `completed` 的判定必须**两端一致**（PC `SyncHistoryItem.completed` 用
  `position >= duration - 5000`；安卓用 `progress >= 0.95`）——不一致会导致
  "PC 认为没播完、安卓认为播完了"这类跨端错位；
- 唤醒后的续播**不得**触发自动连播（`_onCompleted` 不得在恢复路径上被调用）。

**理由**：用户实测的"跳下一集"就是这条被违反的表现。

---

## 5. 文档地图

| # | 文档 | 覆盖内容 |
| --- | --- | --- |
| 00 | 本文 | 目标、原则、契约快照、文档地图、取舍 |
| 01 | `01-realtime-sync-protocol.md` | 实时同步协议：PC 轮询、安卓拉取端点、删除传播、设置映射、开关与手动拉取/推送 |
| 02 | `02-android-keepalive-and-wake.md` | 心跳、可达性探测、唤醒、息屏/后台策略、诊断与用户指引 |
| 03 | `03-resume-not-next-episode.md` | 缓存耗尽与续播语义：根因判定实验、PC 侧修复、安卓侧边界 |
| 04 | `04-test-and-acceptance.md` | 三层测试、fixture、门禁表、反向验证、证据落盘 |
| — | `../README.md` | 阶段计划、实施顺序、门禁表 |

阅读顺序：00 → 01 → 02 → 03 → 04 → `../README.md`。
只关心"设置怎么实时同步"的读 01 §5；只关心"息屏连不上"的读 02；
只关心"跳下一集"的读 03。

---

## 6. 与 Phase 5 的关系

**复用（不改）**：

| 能力 | 位置 | 本轮如何复用 |
| --- | --- | --- |
| T4 站点桥接 | `lib/core/android_bridge.dart` | 不动 |
| 设备探测与可达地址 | `lib/services/android_bridge_service.dart` | 心跳复用 `probeDevice` |
| PC 侧同步服务端 | `lib/services/sync_server.dart` | **扩展**新增增量端点（`01` §5） |
| 同步客户端 | `lib/services/sync_client.dart` | 新增读取端点调用（`01` §4） |
| 合并算法与删除标记 | `lib/core/android_sync.dart`、`storage.dart` | 复用 `buildHistoryMergePlan` |
| 错误分类 | `lib/core/app_error.dart` | **扩展**新增 `keepAlive*` / `realtime*` |
| 设置白名单 | `lib/core/android_sync.dart` | **扩展**到 AI 段 |

**必须继续遵守的 Phase 5 约束**：

- 不复制安卓爬虫（P1）；
- 站点地址以可达地址为基准（P2）；
- 不用 `force` 清表、导入不覆盖当前配置（P3）；
- 拒绝自引用（P4）；
- 能力缺口必须披露（P5）。

---

## 7. 术语补充

| 术语 | 含义 |
| --- | --- |
| **实时同步** | 有定时器驱动的增量同步（周期可配，默认 60 s），与 Phase 5 的"点按钮同步"相对 |
| **增量游标** | 一个不透明字符串（PC 侧用 `updatedAt` 毫秒值；安卓侧用 `nextSince`），表示"我已知晓到这里" |
| **心跳** | 周期性轻量探测（默认 30 s），用于判定对端是否可达并触发唤醒 |
| **唤醒** | 一次会 `ManageService.touch()` 的请求（`/manage/session`），可拉起安卓前台服务与 wake/wifi lock |
| **拉取端点** | PC 暴露给安卓远端同步源消费的增量 HTTP 端点（`01` §5） |
| **续播** | 从历史进度继续播放；**不**等于"播下一集" |
| **END_MARGIN** | 判定"已播完"的尾部余量（两端统一为 5 s 或 0.95 进度） |

---

## 8. 决策记录（待回填主设计文档 §23 / §29）

| # | 决策 | 结论 | 依据 |
| --- | --- | --- | --- |
| Q1 | 实时同步默认开还是关？ | **默认关闭** | P1；Phase 5 P3 |
| Q2 | 实时同步用推送还是轮询？ | **轮询 + 反向拉取端点**（安卓无推送端点） | §3.1 实测 |
| Q3 | 轮询周期？ | 默认 **60 s**，可配 15/30/60/300 s；`0` = 关闭 | P1；安卓侧 5 min 为参考 |
| Q4 | 心跳周期？ | 默认 **30 s**，可配；仅在对端已接入且开关开启时运行 | `02` §3 |
| Q5 | 是否做 WebSocket？ | **不做**（安卓无对应端点，需改安卓工程） | §3.1 |
| Q6 | 设置同步是否包含 AI？ | **包含**，`ai_config` 与 `tmdb_config` **同列为含凭据项** | §3.3 |
| Q7 | 删除是否传播？ | **传播**，但逐条写墓碑，且只在不 `force` 的合并路径 | §3.6；Phase 5 §4.5 |
| Q8 | 手动拉取是"全量"还是"逐站点最近一条"？ | **两者都提供且分开标注** | §3.2 实测（无全表读取端点） |
| Q9 | 息屏后连不上，PC 是否要"修"？ | **不修**，只做探测/唤醒/引导 | P4；§3.4 |
| Q10 | "跳下一集"改哪一侧？ | **先修 PC 侧判定与恢复路径**；安卓侧只做证据采集与指引 | `03` §2 |

---

## 9. 开放问题（实施前必须回答）

| # | 问题 | 当前倾向 | 需要什么证据 |
| --- | --- | --- | --- |
| O1 | 安卓 `/api/playback/current` 是否在息屏后仍可读？ | **不可读**（播放内存态，未播放时恒 `null` → 404） | webtv4 复核：`PlaybackRuntime.currentHistory()` |
| O2 | `/manage/session` 能否在息屏后唤醒服务？ | 能 `touch()`，但若进程被冻结则不能 | `02` §6 的实测脚本 |
| O3 | "跳下一集"是 PC 侧还是安卓侧造成？ | **两侧嫌疑并存**：PC 侧 D1/D2 + 安卓侧 `checkEnded` 无闸门 | `03` §2.3、§2.2 |
| O4 | 安卓远端同步源能否指向 PC 且长期稳定？ | 需要 PC 端口稳定（9978–9998 内）**且**实现身份解析端点 | `02` §6 的实测脚本 |
| O5 | `Backup.prefers` 里 `ai_config` 的 JSON 是否与 PC `AiConfig` 字段完全对齐？ | 字段名对齐，但安卓有 5 套提示词字段 | `01` §5.3 的逐字段表 |
| O6 | 安卓是否会提供 `/api/playback/history`（按站点读历史）？ | **✅ 已交付**（安卓 `e55f19276fb0`，改动 A） | 真机实测：缺 `siteKey`→400、无记录→200 空数组、有记录→200 |
| O7 | 安卓是否会提供 `identity/resolve` 服务端契约？ | **已勘误为 PC 侧职责**（安卓是客户端，不是服务端） | 本文档 §3.2.1 |
| O8 | 安卓是否会补 `episodeId`（集消歧）？ | **✅ 已交付**（安卓 `e55f19276fb0`，改动 C） | 真机实测响应含 `episodeId`、不含 `episodeUrl` |

### 9.1 安卓侧待批准改动清单

详见 `F:/Workspace/webtv4/webhtv/docs/PC-REALTIME-SYNC-01-android-contract-gap.md`：

| # | 改动 | 阻塞 PC 的哪部分 | 状态 |
| --- | --- | --- | --- |
| A | 新增 `GET /api/playback/history?siteKey=`（从数据库读） | 路径 A **完全不可用** | ✅ **已交付** |
| B | 实现 `POST /api/playback/identity/resolve` + `GET /api/playback/sync/status` | 路径 B 的跨设备身份匹配 | **改由 PC 侧实现**（安卓是客户端职责，已勘误） |
| C | `apiSafe()` 补 `episodeId`（哈希，推荐） | 同剧多集互相覆盖 | ✅ **已交付** |
| D | 统一 `completed` 阈值 | 跨端进度错位 | ⏸️ **暂缓**（PC 侧重算） |
| E | `STATE_ENDED` 加"真播完"闸门 | 提前 EOF 后跳下一集 | 🔬 **先做实验** |

**⚠️ 即使 A 与 C 已交付，PC 侧仍必须按降级路径实现**（`01` §4.1 的能力探测与降级）：
用户可能连着未升级的安卓端，探测必须在运行时做且结果缓存 60 s。

**⚠️ 已知限制（实测发现，2026-10-17）**：`/api/playback/history` 只查**当前 `VodConfig.getCid()`**
的历史，与 `History.find` 同源。实测设备上历史分散在多个 `cid`（`1`/`3`/`18`/`33`…，
对应不同订阅配置源），因此对**非当前配置**下的站点（如设备上的 `CupFox`，全部落 `cid=1`）
该端点返回空数组。PC 侧不得把「空数组」一律当成「该站点确实没有历史」。
详见安卓侧文档 `PC-REALTIME-SYNC-01` §10.4。
