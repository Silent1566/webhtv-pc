# 01 · 实时同步协议（历史 / TMDB / AI 设置）

- 状态：设计指导，**待评审**
- 日期：2026-10-17
- 上游参考：`PlaybackRemoteSyncer`、`PlaybackRemoteSyncPayload`、`RemoteSyncConfig`、
  `RemoteSyncStore`、`PlaybackRecordApi`、`PlaybackProgressApi`、`Backup`、`SyncOptions`、
  `Setting.getTmdbConfig/getAiConfig`、`AiConfig`、`TmdbConfig`
- 关联：`00`（§3.1–§3.3、§4、§8）、`02`（心跳与唤醒）、`03`（续播）、`04`（测试与验收）
- PC 端落点：`lib/core/realtime_sync.dart`（新增）、`lib/services/realtime_sync_engine.dart`（新增）、
  `lib/services/android_read_client.dart`（新增）、`lib/services/sync_server.dart`（扩展）、
  `lib/services/sync_client.dart`（扩展）、`lib/core/android_sync.dart`（扩展白名单）、
  `lib/state/sync_state.dart`（扩展）、`lib/ui/config_pages.dart`（扩展）

---

## 1. 目标与非目标

### 1.1 目标

| # | 目标 | 验收锚点 |
| --- | --- | --- |
| G1 | 历史记录实时互通（PC↔安卓，双向，增量） | `04` §3 的 L2 用例组 |
| G2 | TMDB 设置实时互通（含凭据，需单独确认） | 同上 |
| G3 | AI 设置实时互通（含凭据，需单独确认） | 同上 |
| G4 | 实时同步可开关，粒度到"方向" | `04` §3 的开关矩阵用例 |
| G5 | 手动拉取（两种语义）与手动推送 | `04` §3 的手动用例 |
| G6 | 删除传播（不复活、不误删） | `04` §3 的删除用例 |

### 1.2 非目标

- **不做** WebSocket / SSE（安卓无对应端点，`00` §3.1）；
- **不做** 逐条实时（秒级）推送；实时 = 定时增量（默认 60 s）；
- **不做** 配置（`config`/`spider`/`webHome`）的实时同步——那会触发安卓
  `VodConfig.load()` 换源，是破坏性操作，只保留 Phase 5 的手动路径；
- **不做** 收藏（`keep`）实时同步（本轮范围外，白名单保留 Phase 5 行为）；
- **不做** `paths`/`mpvConfig`/`loginState` 归档同步（PC 无对应语义，Phase 5 已拒）。

---

## 2. 分层

```text
lib/core/realtime_sync.dart            纯逻辑：游标、增量判定、方向归一化、周期校验
lib/services/android_read_client.dart  服务：安卓读取端点（/api/playback/current、/manage/session）
lib/services/realtime_sync_engine.dart 服务：定时器 + 心跳编排 + 失败退避 + 游标推进
lib/services/sync_server.dart          服务：扩展增量拉取端点（供安卓远端同步源消费）
lib/services/sync_client.dart          服务：扩展手动推送（含 AI 设置）
lib/core/android_sync.dart             纯逻辑：设置白名单扩展到 AI 段
lib/state/sync_state.dart              状态：开关、周期、最近一次结果、错误
lib/ui/config_pages.dart               UI：开关、周期选择、手动拉取/推送、状态展示
```

**为什么把「引擎」与「状态」分开**：定时器与退避是纯时序逻辑，必须在
**无窗口、无网络**下可测（`04` §2 的 L1）。`SyncState` 只持有开关与结果快照，
不持有 `Timer`。

---

## 3. 实时同步的两条路径

### 3.1 路径 A：PC 主动轮询（PC 拉安卓）

```text
每 N 秒（默认 60 s）：
  1. 若「实时拉取」未开启 → 跳过
  2. 可达性检查（复用心跳结果，`02` §3）
  3. 探测能力（结果缓存 60 s）：
       GET /api/playback/history?siteKey=<probe>&limit=1
         → 200/400  ⇒ 支持（400 说明端点存在但参数不对）
         → 404/405  ⇒ 不支持，降级为 /api/playback/current
  4. 对每个已知 siteKey：
       GET /api/playback/history?siteKey=<key>&limit=<n>
         → 200: 解析 items 数组 → SyncHistoryItem → 合并（旧不覆盖新）
         → 404/405: 降级为 /api/playback/current（只拿播放中那一条）
         → 空数组: 该站点无记录，跳过（不是错误）
  5. 推进游标 = max(已应用记录的 updatedAt)
  6. 失败：不推进游标，按退避重试（§6.3）
```

**为什么按 `siteKey` 逐个打**：安卓**没有**"列出全部历史"的读取端点。
因此 PC 必须知道"要问哪些站点"。`siteKey` 来源有三处，取并集：

| 来源 | 说明 |
| --- | --- |
| 桥接配置的站点 key | 导入 T4 网关后 PC 已知的站点（`config_sites` 表） |
| 本地历史里的 `site_key` | 用户自己播过的站点 |
| 安卓 `/vod/api?ac=config` 的站点 | 用户点「刷新站点」后更新 |

**这批记录属于哪个源**（2026-10-28 补）：响应里**没有任何配置标识**——安卓
`/api/playback/history` 只按 `VodConfig.getCid()`（设备**当前激活**的那份配置）查库，
`siteKey` 只是站点过滤。所以归属是**设备级**的，而且只能靠 `/manage/configs` 的
`active` 项反推：

| 项 | 规则 |
| --- | --- |
| 时机 | 每轮**只解析一次**，且**只在真的拿到记录之后**（空轮不付一次设备请求）；同轮所有站点共用同一个答案 |
| 判据 | `GET /manage/configs` → `active=true` 的 `interfaceKey` → `bridge\|<deviceUuid>\|<interfaceKey>` |
| 判不出 | 设备地址对不上已登记设备 / 设备掉线 / 老安卓没有 `/manage/configs` → 落 **`source_key=''`**（不猜） |
| 落库 | `mergeHistory(items, sourceKey:)` → `_writeSyncHistory` → `upsertHistory(sourceKey:)`；非空时先 `_adoptLegacyHistoryRow` 收编同键的空来源老行 |

不猜的理由：猜错等于**串源**（进度写进别的源），比历史页多一张「来源未知」卡片严重得多。
空来源的记录只在「全部来源」视图里出现（`phase5/design/05` §6.1）。

**轮询量控制**：站点可能上百个。默认**只轮询"最近活跃"的站点**（本地历史里
有记录的 + 用户手动勾选的），上限 20 个；UI 提供「轮询全部站点」开关（默认关）
并显示"将产生 N 次请求/周期"。这条是硬要求：170 站点 × 60 s = 每分钟 170 次
请求，在移动端是电量事故。

### 3.2 路径 B：安卓反向拉取（安卓拉 PC）

安卓侧已有「远端同步源」能力（`PlaybackRemoteSyncer`），它就是**客户端定时拉
HTTP 端点**。PC 只要暴露一个兼容端点，安卓就会按它自己的周期来拉。

**但路径 B 不止一个端点**——安卓在每次同步前会**额外**请求身份解析端点：

```text
安卓每次同步的实际请求序列：
  1. POST <PC>/api/playback/identity/resolve   ← 身份解析（本设计初稿遗漏）
  2. GET  <PC>/api/playback/sync?since=<cursor>&limit=<n>
```

#### 3.2.1 身份解析端点（**PC 必须实现**）

| 端点 | 方法 | 说明 |
| --- | --- | --- |
| `/api/playback/identity/resolve`、`/playback/identity/resolve` | `POST` | 身份解析 |
| `/api/playback/sync/status`、`/playback/sync/status` | `GET` | 能力声明 |

请求头：`X-WebHTV-Token`、`X-WebHTV-Identity-Version: 2`、
`X-WebHTV-Address-Match-Version: 1`、`X-WebHTV-Request-Id`。

请求体：

```json
{
  "schema": "webhtv.playback.identity.v1",
  "operation": "resolve",
  "configType": "vod",
  "interfaceKey": "local-provisional-uuid",
  "strictAddressKeys": ["..."],
  "endpointMatchKeys": ["..."],
  "hostMatchKeys": ["..."],
  "legacyConfigKeys": ["old-url-sha256"],
  "sourceDataState": "empty",
  "client": "android",
  "appVersion": "5.6.0"
}
```

响应：

```json
{
  "ok": true,
  "action": "adopt",
  "canonicalInterfaceKey": "existing-uuid",
  "matchedBy": "endpointMatchKey",
  "matchedKeys": ["..."],
  "sourceInterfaceKey": "local-provisional-uuid",
  "migrationRequired": false,
  "identityEpoch": "20260924-000001",
  "capabilities": { "identityResolve": true, "identityAliases": true,
                    "legacyUrlHashMigration": true, "identityMerge": true }
}
```

`action` 语义与状态码：

| `action` | HTTP | 客户端行为 |
| --- | ---: | --- |
| `create` | 200 | 使用提交的 `interfaceKey` |
| `keep` | 200 | 正式身份未变，追加/刷新匹配线索 |
| `adopt` | 200 | 用 `canonicalInterfaceKey` 替换本地临时身份 |
| `migration_pending` | 200 | 采用正式身份但先完成空间迁移，暂不推进游标 |
| `confirm_required` | 200 | 弹窗展示候选，用户确认前不改身份 |
| `conflict` | 409 | 不改任何身份 |
| `unsupported` | 404/405/501 | 进入旧服务端兼容模式 |
| `invalid` | 400 | 修复请求，不重试相同非法数据 |
| `unauthorized` | 401/403 | 检查 Token |
| `unavailable` | 503 | 保留本地身份，延迟重试 |

**硬约束**：

1. resolve 必须是**幂等原子操作**——两台设备同时首次提交同一地址时，
   最多只能创建一个 canonical identity，另一个必须收到 `adopt`；
2. PC **必须复用** `PlaybackConfigIdentity` 的三层键算法（`strict`/`endpoint`/`host`），
   不能重新实现，否则与客户端算出的键不一致；
3. `/api/playback/sync/status` 必须声明 `capabilities.identityResolve = true`，
   否则安卓不会调用 resolve；
4. **不得**上传/存储完整 URL（协议明确禁止）；服务端只存哈希键。

**参考实现**：`F:/Workspace/webtv4/webhtv/serverless/webhtv-remote-go/playback_identity.go`
（完整）+ `serverless/playback-identity-fixtures/`（共享 fixture）。

##### PC 侧实现要点（T5：`lib/core/playback_identity.dart`）

代码归属：纯逻辑在 `lib/core/playback_identity.dart`，HTTP 在
`lib/services/sync_server.dart`，注册表落盘在 `lib/state/sync_state.dart`。

| 事项 | PC 的做法 | 为什么 |
| --- | --- | --- |
| 键算法 | **只校验、不复算**：字符集 `[a-z0-9._:-]`、长度 ≤128、每类 ≤32 项，规范化 = trim + 小写 | 键由安卓 `PlaybackConfigIdentity.material()` 算出；服务端复算只会算出不同的键 |
| 幂等 | **结构性幂等**：同一请求重放时 `interfaceKey` 已登记 → 命中 `keep`，`canonicalInterfaceKey` 不变 | 安卓每次用新生成的随机 `X-WebHTV-Request-Id`，请求级缓存的收益为零 |
| 原子性 | 服务端请求**串行处理**（`_queue`），注册表变更在单次事件循环内完成 | 两台设备同时首提同一地址时只会有一个 `create`，另一个必得 `adopt` |
| 数据迁移 | `migrationRequired` / `migrationDone` / `resetSince` 恒 `false`，`nextSince` 恒为空串 | PC 只有**一份全局历史库**（按 `siteKey`/`vodId` 定位，与 `interfaceKey` 无关），没有分区可迁移；Go 是按 `(token, interfaceKey)` 分区存播放数据才需要迁移 |
| 别名 | 每次成功变更都把所有键登记为别名，且**不覆盖**已指向其它身份的别名 | 同一地址在不同客户端版本里可能被判成不同层（旧版只算 `legacy` URL 哈希），跨层匹配只能靠别名 |
| 鉴权 | 服务已开启 **且**（配置了 token 就校验 token，否则校验 `uuid`/IP 白名单） | 与 §3.2.2 同一套规则；本端点**不要求**「实时推送」开启——它不返回任何播放数据，拒绝它反而让安卓写死 `unsupported` |
| `sync/status` | `capabilities.playbackSync` 反映拉取当前是否可用；`retentionDays` 报 `0` | 能力声明必须与实际行为一致；PC 历史库不做时间窗清理，报 `90` 是假话 |

**与 Go 参考实现的两处有意差异**（按协议本意，而不是照抄代码）：

1. **`matchedBy` / `matchedKeys` 返回真实值**。Go 的
   `playbackIdentityResponse` 用 `if _, exists := response[key]; !exists` 回填，
   而这两个键已在基线里，于是永远停在 `none` / 空数组——安卓的
   `addAddressMatchAliases(result.matchedKeys)` 因此一直拿到空数组。
2. **不缓存请求级响应**。幂等由注册表状态本身保证（见上表），
   缓存只是多一份需要维护、且重启即失效的状态。

**未接线时回 404**：`SyncServerHost.playbackIdentity == null` 时端点回 404。
这是**故意**的——安卓把 404/405/501 解释为 `unsupported` 并进入旧服务端兼容
模式；回 200 假成功会让它以为身份匹配可用，而实际永远是错的。

**注册表落盘**：`settings.json` 的 `sync.identity`（见 §9.1）。
不落盘的具体后果：安卓按 `adopt` 把自己的 `interfaceKey` 改成正式键，PC 却
忘了这条身份，下次解析按同一批地址键**新造**一个——两端键永久错开，
而且**不报错**。

**安卓不调用 `sync/status`**：`PlaybackIdentityResolver` 只按同步 URL 推导
`identity/resolve`，所以 `sync/status` 的实际读者是第三方客户端与
`design/04` 的 6c 门禁；即便如此它也必须如实声明能力（P5）。

#### 3.2.2 拉取端点

```text
GET /api/playback/sync?since=<cursor>&limit=<n>
  请求头（安卓会带）：
    X-WebHTV-Config-Key: <configKey>
    X-WebHTV-Config-Aliases: <alias1>,<alias2>   （可选，最多 16 个）
    X-WebHTV-Since: <cursor>
    X-WebHTV-Limit: <n>
    X-WebHTV-Token: <token>（可选）
  响应体（安卓解析器接受的形态，见 §3.3）：
    {
      "nextSince": "<新游标>",
      "items": [ <PlaybackProgressInput 兼容 JSON> ... ],
      "deleted": [ { "historyKey": "...", "deletedAt": 123 } ... ]
    }
```

**游标语义（对齐 Go 参考实现）**：

- 游标是**单调递增的 sequence 整数**（不是时间戳），空/缺省 = `0`；
- 非法游标（非数字或负数）→ **400** `Invalid X-WebHTV-Since cursor`；
- `limit` 默认 100、上限 500；非法值回落默认；
- 响应含 `hasMore: true` 表示还有未返回的变更；
- 响应含 `changes` 数组（与 `items` 同义，安卓解析器两者都接受）。

**关键兼容点**（`PlaybackRemoteSyncPayload` 源码实证）：

| 安卓接受的键 | 说明 |
| --- | --- |
| `nextSince` / `next_since` / `nextCursor` / `cursor` | 游标，任一即可 |
| `items` / `records` / `list` / `upserts` / `changes` / `operations` / `data` | upsert 数组，任一即可 |
| `deleted` / `deletions` / `tombstones` / `removed` / `deletedItems` | 删除数组，任一即可 |
| 单条记录里 `action`/`op`/`operation` = `delete`/`removed`，或 `deleted: true`，或 `event: playback.deleted` | 判为删除 |
| 字段别名：`position`/`position_ms`/`pos`、`duration`/`duration_ms`、`episode`/`vodRemarks`、`flag`/`vodFlag`/`line`、`site`/`site_key` | `PlaybackProgressInput.applyAliases` |

**PC 侧实现要点**：

- 端点**只在**「实时推送」开启时返回数据，否则 `403`（P1）；
- 必须校验 token（若用户配置了）；未配置 token 时**只允许** `uuid` 白名单内的
  对端 IP（复用 Phase 5 的 `isPeerAuthorized`）；
- 游标语义：`since` 为空 → 返回**最近 N 条**（不做全量，见 P2）；`since` 有值 →
  只返回 `updatedAt > since` 的记录；`nextSince` = 本批最大 `updatedAt`；
- 删除：从 `history_deletions` 表按 `deleted_at > since` 取出，映射为
  `{historyKey, deletedAt}`；
- **不推进**任何本地游标——游标由安卓侧保存（`RemoteSyncConfig.cursors`）。

### 3.3 两条路径的关系（必须写清，否则会重复同步）

| 路径 | 谁发起 | 周期 | 谁存游标 | 适用 |
| --- | --- | --- | --- | --- |
| A（PC 轮询） | PC | PC 侧配置（默认 60 s） | PC（`settings.json` 的 `sync.realtime` 段） | PC 常开时 |
| B（安卓拉取） | 安卓 | 安卓侧配置（默认 5 min，可改） | 安卓（`RemoteSyncConfig.cursors`） | PC 不常开、或想省 PC 侧定时器 |

**两条可同时开启**：它们都是幂等合并（`updatedAt` 相等即 skip），重复不会造成
数据错乱，只多花一次请求。UI 必须**明说**这一点，并给出"建议只开一条"的提示。

---

## 4. 路径 A 的详细协议

### 4.1 读取端点

| 方法 | 路径 | 用途 | 鉴权 | 安卓侧现状 |
| --- | --- | --- | --- | --- |
| `GET` | `/api/playback/history?siteKey=<key>&limit=<n>` | 该站点**最近 N 条**历史（从数据库读） | 无 | ✅ **已交付**（安卓 `e55f19276fb0`） |
| `GET` | `/api/playback/current?siteKey=<key>` | **仅**"当前正在播放的那一条" | 无 | ✅ 已实现 |
| `GET` | `/manage/session` | 唤醒 + 读服务状态 | 无 | ✅ 已实现 |
| `GET` | `/device` | 设备身份（心跳用） | 无 | ✅ 已实现 |

> **⚠️ 重大修正（2026-10-17）**：`/api/playback/current` **不是**"该站点最近一条历史"。
> 它的数据源是 `PlaybackRuntime.currentHistory()`——一个**内存态**字段，未播放时恒为
> `null` → 404。**息屏后必然 404**，而用户核心诉求恰恰是息屏后仍能同步。
>
> **因此路径 A 必须依赖新增的 `/api/playback/history`**（从 `HistoryDao` 读，
> 不依赖播放内存态）。安卓侧设计见
> `F:/Workspace/webtv4/webhtv/docs/PC-REALTIME-SYNC-01-android-contract-gap.md` §5.1。
>
> **降级策略（安卓侧交付前必须实现）**：
>
> | 探测结果 | PC 行为 |
> | --- | --- |
> | `/api/playback/history` 存在 | 正常轮询（路径 A 完整可用） |
> | 不存在，但 `/current` 存在 | 降级：只打 `/api/playback/current`，**UI 明示**"仅能同步正在播放的记录" |
> | 两者都不存在 | 路径 A 不可用，提示升级安卓端 |
>
> 降级探测结果必须**缓存**（60 s）并在 UI 常驻显示当前处于哪种模式（P5）。
>
> #### 🛑 第二个阻塞性发现（2026-10-17 真机实测）：端点不存在时返回 **200**，不是 404
>
> 上表初稿假设「不存在 → 404/405」。**实测推翻**：
>
> | 请求 | 真机响应 |
> | --- | --- |
> | `GET /api/playback/__nope__`（未匹配任何路由） | `200 OK` + `application/octet-stream` + `Content-Length: 0` |
> | `GET /api/playback/current?siteKey=__nope__`（端点存在、未播放） | `404` + `application/json` + `{"code":404,...}` |
>
> **根因**：`Nano.serve()` 在没有任何 `Process` 匹配时落到 `getAssets()`
> （`Nano.java:96`），而 NanoHTTPD 对缺失资产返回
> `200 + octet-stream + 空体`（`Nano.java:128-130` 的 `catch` 分支只处理
> `Asset.open()` 抛异常的情况，未覆盖此路径）。
>
> **后果（若只看状态码）**：旧版安卓上路径 A 会「探测成功」（200）
> 但每次读取都静默拿到空结果——用户看到「同步成功但 0 条」，
> 而实际是端点根本不存在。这正是 P5 禁止的「把不可用伪装成无数据」。
>
> **处置**：探测必须按 **状态码 + `Content-Type` + 体长度** 三者判定，
> 见 `EndpointProbeResult` / `classifyEndpointProbe()`：
>
> | 状态码 | Content-Type | 判定 | 端点存在？ |
> | --- | --- | --- | --- |
> | 200 | JSON | `ok` | ✅ |
> | 200 | 非 JSON（`octet-stream`/空体） | `missing` | ❌ |
> | 400 | JSON | `badRequest`（参数不对但端点存在） | ✅ |
> | 404 | JSON | `notFound`（未播放，合法形态） | ✅ |
> | 405 / 501 | — | `methodNotAllowed` | ✅ |
> | 5xx | — | `missing`（保守：假装可用会让下轮读取失败） | ❌ |
>
> 另一个必须遵守的推论：**只有降级端点**（`/current`）的 404 才允许
> 静默成空结果。`/history` 对任一 `siteKey` 都返回 200+空数组、从不 404，
> 因此它一旦缺失必须报 `realtimePullUnsupported`。

**`/api/playback/history` 的响应形态**（安卓侧设计 §5.1）：

```json
{
  "siteKey": "csp_xxx",
  "items": [ { /* PlaybackFieldPolicy.apiSafe() 字段集 */ } ],
  "total": 3
}
```

- 无记录 → **200 + 空数组**（**不是 404**）——"没有历史"与"端点不存在"必须可区分；
- `limit` 默认 20、上限 100；
- 隐身模式（`Setting.isIncognito()`）→ 空数组。

**`/api/playback/current` 的响应映射**（`PlaybackFieldPolicy.apiSafe()` 字段集）：

| 安卓字段 | PC 字段 | 处理 |
| --- | --- | --- |
| `historyKey` | — | 切分得到 `siteKey`/`vodId`/`cid`（Phase 5 `splitHistoryKey`） |
| `siteKey` | `siteKey` | 直传 |
| `vodId` | `vodId` | 直传 |
| `vodName` | `vodName` | 直传 |
| `vodPic` | `vodPic` | 空串 → `null` |
| `flag` | `flag` | 直传 |
| `episodeName` | `episodeName` | 直传 |
| `episodeId` | `episodeId` | **优先直用**（安卓已交付该字段，值 = `episodeUrl` 的 SHA-256）；缺失时见下方警告 |
| `episodeUrl` | — | **apiSafe 刻意不含此字段**（不泄露带签名的播放地址） |
| `positionMs` | `positionMs` | 毫秒直传，**不换算** |
| `durationMs` | `durationMs` | 毫秒直传 |
| `completed` | — | 用于判定；PC 侧重新按 `position>=duration-5000` 计算 |
| `tmdbId`/`mediaType`/`seasonNumber`/`tmdbEpisodeNumber` | `raw` | 保留在 `raw`，不落库（PC 无对应列） |
| `speed`/`speedOverride`/`state`/`progress` | `raw` | 保留 |
| **`updatedAt`** | **`updatedAt`** | **⚠️ 见下方「阻塞性发现」——本表初稿漏了这一行** |

> ### 🛑 阻塞性发现（2026-10-17 真机实测）：`/api/playback/history` **不返回记录更新时间**
>
> **本表初稿漏了 `updatedAt` 这一行**，而 `SyncHistoryItem.matchKey` 之外，
> 合并算法完全依赖 `updatedAt`（`design/01` §4.2 的「旧不覆盖新」、§4.3 的
> 删除墓碑比较、§4.2 第 5 步的游标推进）。
>
> #### 实测证据（设备 `192.168.50.3:5561`，2026-10-17）
>
> | 观测 | 结果 |
> | --- | --- |
> | 响应字段集 | 含 `timestamp`，**不含** `createTime` / `updatedAt` |
> | 4 条记录的 `timestamp` 分布 | 全部落在 **30 ms 内**（1792220502225–1792220502253） |
> | 同 4 条记录的库里真实 `createTime` | 跨度约 **16 小时**（1791959887462–1791975857695） |
> | 间隔 6 s 再请求一次 | 每条 `timestamp` 都**前进了 6183–6196 ms**（≈ 真实墙钟间隔） |
>
> #### 源码级根因
>
> | 事实 | 证据 |
> | --- | --- |
> | `PlaybackRecord` **没有** `createTime` 字段 | `grep createTime PlaybackRecord.java` → 0 命中 |
> | `PlaybackRecord.from()` **从不**读 `History.getCreateTime()` | `PlaybackRecord.java:110-140` |
> | 构造器把 `timestamp` 设为**序列化时刻** | `PlaybackRecord.java:78` `this.timestamp = System.currentTimeMillis();` |
> | `apiSafe()` 放行 `timestamp`（在 `PROTOCOL` 集内）但**不放行** `createTime` | `PlaybackFieldPolicy.java:9,25-30` |
>
> **结论**：`timestamp` 的语义是「这份 JSON 何时被生成」，**不是**「这条记录何时被更新」。
>
> #### 对 PC 的后果（若直接拿 `timestamp` 当 `updatedAt`）
>
> | 环节 | 后果 |
> | --- | --- |
> | `decideHistoryMerge` | `incoming.updatedAt > local.updatedAt` **恒成立** → 每轮全量 upsert，**永不幂等** |
> | 游标推进（§4.2 第 5 步） | 游标每次跳到「现在」，增量拉取退化为全量 |
> | 删除墓碑比较（§4.3） | `item.updatedAt <= deletedAt` 几乎不成立 → 已删记录可能被复活 |
> | 反向验证 #6 | 会**假绿**——它断言的是「部分失败不推进游标」，与这个缺陷正交 |
>
> **路径 B 不受影响**：`PlaybackProgressInput` 有独立的 `updatedAt` 字段
> （`PlaybackProgressInput.java:66`），且 `PlaybackProgressWriter` 用它做
> `setCreateTime`（`:227`）与冲突裁决（`:200`）。缺口**只在路径 A 的读取端点**。
>
> #### 处置（PC 侧，两层）
>
> 1. **PC 必须按能力探测处理**（与 §4.1 的端点探测同一模式）：
>    `updatedAt` 的取值优先级 = `updatedAt` → `createTime` → `timestamp`，
>    并记录来源（`raw['_updatedAtSource']`）。只有 `timestamp` 可用时，
>    置降级状态 `realtimePullTimestampUnreliable` 并在 UI 常驻披露
>    「安卓端未提供记录更新时间，『旧不覆盖新』不可用」。
> 2. **降级路径必须保住幂等**：不能只靠时间戳判等。追加**内容等价判定**
>    （`positionMs`/`durationMs`/`completed` 全等 → skip），
>    使「重复同步不产生重复记录」在无可靠时间戳时仍成立。
>
> #### 建议的安卓侧修复（待批准）
>
> 在 `PlaybackRecord` 新增 `updatedAt` 字段，由 `from()` 从
> `history.getCreateTime()` 赋值，并加入 `apiSafe()`。
>
> | 项 | 说明 |
> | --- | --- |
> | 改动量 | 小（一个字段 + `from()` 一行 + `apiSafe()` 一行 + 单测） |
> | 为什么用新字段而不是改 `timestamp` | `timestamp` 在 `PROTOCOL` 集内，事件/webhook 路径依赖它表示「事件发生时刻」；改它会影响既有语义 |
> | 命名 | `updatedAt` 与路径 B 的 `PlaybackProgressInput.updatedAt` 对齐，两端同义 |
> | 风险 | 低（纯追加字段，不影响既有断言） |
>
> ---
>
> **警告（必须处理）**：PC 的 `SyncHistoryItem.matchKey` 是
> `(siteKey, vodId, flag, episodeId)`。`episodeId` 为空会让**同一剧的所有集**
> 塌缩成同一个 `matchKey`，造成"看第 3 集把第 1 集的记录覆盖掉"。
>
> **安卓侧已交付 `episodeId`**，但仍**必须保留两层处置**——能力探测是运行时的，
> 用户可能连着未升级的安卓端（或第三方服务端）：
>
> 1. **首选（安卓已交付）**：响应里有 `episodeId` 就**直接用它**，并置
>    `raw['_episodeIdSource'] = 'field'`。**不得**再用 `episodeName` 覆盖它。
> 2. **兜底（旧安卓 / 第三方服务端）**：`episodeId` 缺失时用 `episodeName` 兜底，
>    并置 `raw['_episodeIdSource'] = 'episodeName'`；若 `episodeName` 也为空，
>    该条**只记日志不合并**（宁可不合，不可错合）。
>
> 安卓侧交付形态：`apiSafe()` 追加 `episodeId` = `episodeUrl` 的 SHA-256
> （64 位小写 hex，空地址→空串），**不**把 `episodeUrl` 加入字段集。
> 交付证据：安卓 `dev4` 提交 `e55f19276fb0a73bce3a47f9bda2c16923d318b3`
> （tag `recovery/PC-REALTIME-SYNC-01/20261017042235-e55f19276fb0`）
> 与 `docs/PC-REALTIME-SYNC-01-android-contract-gap.md` §5.3 / §10。

### 4.2 增量判定

```text
对每个 siteKey：
  record = GET /api/playback/current?siteKey=<key>
  if 404: continue                       // 无记录，不是错误
  item = mapToSyncHistoryItem(record)
  local = localByMatchKey[item.matchKey]
  deletedAt = deletedAtByMatchKey[item.matchKey]
  if deletedAt != null && item.updatedAt <= deletedAt: skip（不复活）
  if local == null: insert(applied)
  else if item.updatedAt > local.updatedAt: upsert(applied)
  else: skip（相等或更旧）
```

**与 Phase 5 完全一致**：直接复用 `buildHistoryMergePlan` 与 `applyHistoryMerge`
（`lib/core/android_sync.dart`、`lib/services/storage.dart`），**不新增合并算法**。

### 4.3 删除传播

| 方向 | 机制 |
| --- | --- |
| 安卓 → PC | 路径 B 的 `deleted` 数组；路径 A 无法感知删除（`current` 只返回存在记录）→ **路径 A 必须配合"缺失检测"**：本地有、远端连续 K 次 404 → 提示"可能已在安卓删除"，但**不自动删**（避免网络抖动误删） |
| PC → 安卓 | 复用 Phase 5 的 `pushHistory` + 新增 `pushHistoryDeletions`：把 `history_deletions` 里 `deleted_at > 上次推送游标` 的条目，按 `PlaybackProgressDeleteInput` 形态推给安卓（`/action?do=sync&mode=1&type=history` 的 `targets` 里带 `action=delete`） |

**硬约束**：PC 侧删除**必须**逐条走 `AppState.deleteHistory(id)`（写墓碑），
不得新增批量 SQL 删除路径（`docs/phase6/README.md` §4）。

### 4.4 手动拉取（三种语义，必须分开标注）

| 按钮 | 语义 | 实现 | 提示文案 |
| --- | --- | --- | --- |
| **拉取最近记录** | 逐 `siteKey` 打 `/api/playback/history`（降级时打 `/current`） | §4.1 | 「从安卓读取各站点最近记录（不改动安卓）」 |
| **请求安卓推送全量** | `POST /action?do=sync&mode=2&device=<PC>` | Phase 5 `requestPull` | 「请安卓把它当前配置下的全部历史推给本机；需安卓已授权本机」 |
| **重置游标并全量拉取** | 清本地拉取游标后立即跑一轮路径 A | 新增 | 「将重新读取全部站点的记录（不会删除本机数据）」 |

**为什么必须分开**：

- 第一种**不依赖** PC 服务端在线、不依赖安卓授权；
- 第二种需要 PC 服务端开启 + 安卓白名单；
- 第三种用于"游标错位/安卓重装后"的恢复场景（对齐 `realtimeCursorStale` 错误）。

混成一个按钮会让用户在"服务端没开"时得到一个无法解释的失败。

### 4.5 手动推送

| 按钮 | 语义 | 实现 |
| --- | --- | --- |
| **推送历史** | Phase 5 `pushHistory`（需 `config.url` 非空） | 复用 |
| **推送删除** | §4.3 的 `pushHistoryDeletions` | 新增 |
| **推送设置** | Phase 5 `pushBackup`，`options.settings=true` 时才带凭据 | 扩展白名单（§5） |
| **推送全部（历史+设置）** | 顺序执行，任一失败即停并报明细 | 新增编排 |

---

## 5. 设置同步（TMDB / AI）

### 5.1 白名单扩展

Phase 5 的白名单（`lib/core/android_sync.dart`）：

```dart
const List<String> pcSettingsWhitelist = ['tmdb_enabled', 'tmdb_config'];
const Set<String> pcSensitiveSettingsKeys = {'tmdb_config'};
```

本轮改为：

```dart
const List<String> pcSettingsWhitelist = [
  'tmdb_enabled',
  'tmdb_config',
  'tmdb_model',
  'ai_config',
  'ai_title_extraction',      // 是否启用 AI 标题提取（标量）
  'ai_ad_detection',          // 是否启用 AI 去广（标量）
];
const Set<String> pcSensitiveSettingsKeys = {'tmdb_config', 'ai_config'};
```

**为什么 `ai_config` 是含凭据项**：它内含 `apiKey`（`00` §3.3 实测）。
`tmdb_model` / `ai_title_extraction` / `ai_ad_detection` 是标量开关，不含凭据。

### 5.2 逐键映射表

| 安卓 `prefers` 键 | 值形态 | PC 目标 | 映射规则 |
| --- | --- | --- | --- |
| `tmdb_enabled` | bool | `TmdbConfig.enabled` | 直传 |
| `tmdb_config` | **JSON 字符串** | `TmdbConfig` | 先 `jsonDecode` 字符串 → Map → `TmdbConfig.fromMap`；凭据为空时**保留本地**（Phase 5 已实现） |
| `tmdb_model` | int/string | 无对应（PC 无"原生/TMDB 详情页"模式） | 存 `raw`，不落库；在 UI 标注"该设置 PC 不支持" |
| `ai_config` | **JSON 字符串** | `AiConfig` | 先 `jsonDecode` → Map → `AiConfig.fromJson`；`apiKey` 为空时保留本地 |
| `ai_title_extraction` | bool | 无对应（本轮不做 AI 标题提取） | 存 `raw`，不落库 |
| `ai_ad_detection` | bool | 无对应（本轮不做 AI 去广） | 存 `raw`，不落库 |

> **注意**：`tmdb_model` / `ai_title_extraction` / `ai_ad_detection` 属于
> "安卓有、PC 无"的键。Phase 5 的 `SyncSettings.fromBackup` 会把白名单外的键
> 记进 `skippedKeys` 并**披露**（P5）。本轮把它们**留在白名单内**但**不落库**，
> 是为了：**（a）** 推送时不丢（PC 可以把从安卓收到的值原样回推）；
> **（b）** 披露时能区分"PC 不支持"与"未授权同步"。
> 为此 `SyncSettings` 新增 `unsupportedKeys` 字段（`skippedKeys` 保持原语义）。

### 5.3 AI 配置的字段对齐（逐字段）

| 安卓 `AiConfig` 字段 | 别名 | PC `AiConfig` 字段 | 备注 |
| --- | --- | --- | --- |
| `enabled` | — | `enabled` | 直传 |
| `protocol` | `apiFormat`, `format` | `protocol` | 4 值集合一致（`openai_responses`/`openai_chat`/`anthropic_messages`/`gemini_native`） |
| `endpoint` | — | `endpoint` | 直传；PC 侧 `sanitize()` 会归一化 |
| `apiKey` | — | `apiKey` | 含凭据 |
| `model` | — | `model` | 直传 |
| `customUserAgent` | `userAgent`, `ua` | `customUserAgent` | 直传 |
| `recommendPrompt` 等 5 套提示词 × 3 字段 | — | **无对应** | 保留在 `raw`，回推时原样带回 |

**回推保真**：PC 推送 `ai_config` 时，必须**先取出本地保存的 `raw`**，
把 PC 理解的 6 个字段覆盖上去，再序列化。否则会把安卓的 5 套提示词一起抹掉。
这与 Phase 5 对 `History` 的 `raw` 保真策略同源（`design/02` §3.4）。

### 5.4 实时 vs 手动

| 项 | 实时（路径 A/B） | 手动推送 |
| --- | --- | --- |
| 历史 | ✅ | ✅ |
| 删除 | ✅（路径 B） | ✅ |
| `tmdb_enabled` / `tmdb_model` | ✅（标量，轻量） | ✅ |
| `tmdb_config` | ⚠️ **默认关**，需"设置实时同步"开启 | ✅（需 `settings=true`） |
| `ai_config` | ⚠️ **默认关**，同上 | ✅（需 `settings=true`） |

**为什么含凭据的项默认不实时**：实时 = 每 60 s 可能传输一次 API Key；即使走
局域网也是明文 HTTP。用户显式开启"设置实时同步"后才参与，且 UI 必须写明
"将以明文 HTTP 在局域网传输"。

---

## 6. 开关与周期

### 6.1 开关矩阵（全部默认关闭）

| 开关 | 键（`settings.json` 的 `sync.realtime` 段） | 默认 | 说明 |
| --- | --- | --- | --- |
| 实时同步总开关 | `enabled` | `false` | 关掉后所有子开关失效 |
| 实时拉取（PC→安卓） | `pullEnabled` | `false` | 路径 A |
| 实时推送（安卓→PC） | `pushEnabled` | `false` | 路径 B（暴露拉取端点） |
| 设置实时同步 | `settingsEnabled` | `false` | 含凭据项参与实时 |
| 轮询周期 | `intervalSeconds` | `60` | 15/30/60/300 四选一 |
| 心跳周期 | `heartbeatSeconds` | `30` | 见 `02` §3 |
| 轮询全部站点 | `pollAllSites` | `false` | 默认只轮询最近活跃的 20 个 |

### 6.2 与 Phase 5 开关的关系

Phase 5 已有三个开关（`serverEnabled` / `pushEnabled` / `settingsSyncEnabled`）。
本轮**不重命名**它们（会破坏既有测试与用户设置文件），而是：

- `sync.serverEnabled`：PC 服务端监听（路径 B 的**前提**）；
- `sync.pushEnabled`：允许向安卓推送（手动推送的前提）；
- `sync.settingsSyncEnabled`：允许推送含凭据设置；
- `sync.realtime.*`：本轮新增的实时子开关。

**联动规则（必须显式实现并测试）**：

| 条件 | 结果 |
| --- | --- |
| `realtime.pushEnabled=true` 但 `serverEnabled=false` | **自动开启服务端**并提示（否则路径 B 不可能工作） |
| `realtime.settingsEnabled=true` 但 `settingsSyncEnabled=false` | **拒绝开启**并提示先开设置同步（避免绕过凭据确认） |
| `realtime.enabled=false` | 定时器与心跳全部停止；`realtime.*` 子开关值**保留**（下次开启沿用） |

**路径 B 的唯一门禁是 `realtime.pushEnabled`**（T7 落地后固定）：不再叠加
Phase 5 的 `sync.pushEnabled`。原因：后者是「手动推送」的同意，而实时推送
是另一件事；两者叠加的结果是「用户明明开了实时推送，安卓却拿到 403」
——而 403 在 `design/01` §6.3 里是「立即停止」，用户会看到功能永久不工作。
`realtime.pushEnabled` 开启时会自动拉起服务端（上表第一行），因此攻击面
不因这个简化而变大（仍然默认关闭 + 仅白名单对端）。

**加载时恢复**：`realtime.enabled=true` 时重启后**直接恢复定时器**（路径 A 是
入站拉取，不监听端口）；但**不会**因为 `realtime.pushEnabled` 而自动拉起
服务端——那要等用户再点一次开关（与 Phase 5 的 `serverEnabled` 同口径）。

### 6.3 失败退避

| 失败类型 | 退避 |
| --- | --- |
| 连接被拒 / 超时 | 1× → 2× → 4× 周期，上限 8×；连续 5 次失败后**暂停**并置 `lastError`，等用户手动重试或心跳恢复 |
| 404（`/api/playback/current` 无记录） | **不算失败**，不参与退避 |
| 403（服务端未开启 / 未授权） | **立即停止**该方向并置错误（重试无意义） |
| 5xx | 按连接失败退避 |
| 部分条目失败（合并阶段） | 不推进游标，整批下轮重试；报 `applied/skipped/failed` 明细 |

### 6.3.1 🛑 L3 集成测试抓出的三个真实缺陷（2026-10-18）

这三个都是**只有真实 HTTP / 真实 socket 才能暴露**的问题：L1/L2 全绿时它们
依然存在。记录在此，因为它们的形态都是「看起来在工作，实际悄悄失效」。

| # | 缺陷 | 症状 | 根因 | 修法 |
| --- | --- | --- | --- | --- |
| 1 | **游标永久卡死** | 每轮都 `partial` → 游标永不推进 → 增量语义失效（每轮重拉同一批） | 「记录本身不可合并」（集名与地址双空、身份键不成段）是**永久性**失败，却被当成「整轮部分失败」；而 `partial` 按 §6.3 不推进游标 | 拆成两类：`RealtimeSiteReadResult.unmergeable`（永久，仅披露）与合并阶段 `stats.failed`（暂时，算 `partial`） |
| 2 | **`/manage/session` 的 404 被当成「端点存在」** | 降级链不触发、`running=null`，状态却是「可达」 | `endpointExists()` 把 `notFound` 归为「存在」（那是为路径 A 的 `/current` 设计的），但保活端点的 404 含义是「旧版安卓没有它」 | 保活探测里**额外判 404** → `manageMissing` → 降级到 `/device` |
| 3 | **「服务未运行」被误报成「网络不可达」** | 用户被指去查 WiFi，而实际只需打开安卓管理页 | 本机（Windows）连**未监听的回环端口**时，「连接被拒」要 ~2 s 才上报，与每步 2 s 超时正好打平 → 超时抢走拒绝 | 给决定性的 TCP 探测更宽预算（`tcpTimeout` 默认 ≥5 s）；`_isConnectionRefused` 补 errno 1225 |

**第 1 条为什么最危险**：它不会报错、不会变红，只是**每轮都在重拉同一批**。
用户看到的是「同步一直在跑」而增量从未生效——正是 P5 禁止的「把失效伪装成工作」。

**第 3 条的实测数据**（`Socket.connect` 到未监听回环端口）：

| 超时预算 | 观测到的 errno | 三态判定 |
| --- | --- | --- |
| 300 ms | 10060（超时） | `networkUnreachable`（错） |
| 2000 ms | 10060（超时） | `networkUnreachable`（错） |
| 5000 ms | **1225（拒绝）** | `serviceStopped`（对） |

### 6.4 引擎实现要点（T6：`lib/services/realtime_sync_engine.dart`）

引擎**只做编排**：所有纯裁决（退避序列、游标裁决、三态分类、唤醒阶梯）
调用 `lib/core/realtime_sync.dart` 里已有函数，本文件不重复实现。

| 设计点 | PC 的做法 | 为什么 |
| --- | --- | --- |
| 定时器 | 只用**一次性**定时器，每次触发后重新排程；退避只是换一个延迟参数 | 周期语义由重排程表达，“改周期”就不需要带状态的 API |
| 时钟与 I/O | `RealtimeScheduler`（定时器工厂）+ `RealtimeEngineHost`（I/O 回调）均**注入** | 真实定时器让「退避到第几次」「恢复后补一轮」无法确定性断言；测试也不应创建真实 `Timer` |
| 暂停语义 | `_pollPaused` 时 `pollNow()` 直接返回 `null`，不只看定时器是否已取消 | 残留回调 / 其它调用点绕入时，依然不得发请求（暂停 = 不值得再发） |
| 心跳失败 | 暂停轮询 + 按退避重排心跳；连续 5 次→停自动心跳，等用户「立即重连」 | `design/02` §3.3：不可达时轮询全是超时，用一个轻量请求做“是否值得轮询”最便宜 |
| 心跳恢复 | 清两个方向的失败计数 + **立即补一轮轮询**（`triggeredPoll`） | `design/02` §5.2：断线期间的记录仍在安卓侧，补一轮就拿到最新状态 |
| 403 | 置 `_pollStopped` 并 `cancel` 定时器；同时**不涨**退避计数 | 重试只会一直 403；计数只服务于“还会重试”的场景 |
| 单站点失败 | 不整轮放弃，继续跑其余站点；但整轮结果归为 `failure` | 部分成功仍不推游标（宁可不推，也不丢增量） |
| 降级披露 | 本轮用过 `/current` 的站点记入 `degradedSites` 并进快照 | P5：「仅能同步正在播放的记录」必须常驻可见 |

**测试注入形状**（`phase7_realtime_engine_test.dart` 的 `ManualScheduler`）：
测试只把待触发回调排队，需要时 `fireByDelay(60)` 手动触发——**按延迟值
区分轮询（60 s）与心跳（30 s）**，不依赖“第几个句柄”（每次重排程都会追加
新句柄，位置不稳定）。`design/04` G12 的“用例结束时活动定时器数 = 0”
由 `tearDown` 断言 `engine.activeTimerCount == 0`。

---

## 7. 手动拉取与手动推送的 UI

### 7.1 布局（在既有 `AndroidSettingsPage` 内新增区块）

```text
「实时同步」区块
  [ ] 开启实时同步
      ├ [ ] 实时拉取（PC → 安卓）   周期 [60 s ▾]
      ├ [ ] 实时推送（安卓 → PC）   需先开启「局域网同步服务」
      └ [ ] 设置实时同步（含凭据，明文 HTTP）
  最近一次：pull 2026-10-17 12:00:03 applied=3 skipped=1 failed=0
  下次：12:01:03  ·  心跳：12:00:33（可达）

「手动操作」区块
  [拉取最近记录]  [请求安卓推送全量]
  [推送历史]      [推送设置]
  说明：拉取最近记录不依赖本机服务端；请求全量推送需要安卓已授权本机。
```

**实际落地的符号（T8，`phase7_sync_ui_test.dart` 逐条锁定）**：

| key | 含义 |
| --- | --- |
| `realtime-enabled` / `realtime-pull` / `realtime-push` / `realtime-settings` | 四个开关 |
| `realtime-interval` / `realtime-poll-all-sites` | 周期下拉、轮询全部站点 |
| `realtime-status` / `realtime-last-pull` / `realtime-manual-result` | 状态与结果快照 |
| `realtime-attention` / `realtime-retry` | 已停止时的「立即重连」 |
| `realtime-disclosure-degraded` / `-unsupported` / `-service-stopped` / `-peer-frozen` / `-background-guide` / `-plaintext` | 六条披露 |
| `realtime-manual-pull` / `-request-push` / `-push-history` / `-push-settings` | 四个手动按钮 |

> **为什么只有 4 个按钮而没有「推送删除」**：`SyncClient` 目前**没有**推送删除墓碑的
> 接口（Phase 5 只做了历史/收藏/设置三条）。加一个点了就报「未实现」的按钮
> 比不加更糟。删除传播目前只在**路径 B**（安卓来拉）生效，PC 主动推删除待
> 安卓侧提供接收接口后再补——已在 §4.3 标为待办。
>
> **文件拆分**：状态层用例在 `test/phase7_realtime_state_test.dart`，widget 用例在
> `test/phase7_sync_ui_test.dart`。设计台账本写的是一个文件，但本仓库的结论是
> 「真实 I/O 测试与 widget 测试必须分文件」（fake-async zone 与真实回调互卡）。

### 7.2 必须披露的信息（P5）

| 场景 | 必须显示 |
| --- | --- |
| 路径 A 的 `episodeUrl` 缺失 | 「安卓的读取接口不返回单集地址，已用集名匹配（可能影响同剧多集区分）」 |
| 轮询站点数 | 「本周期将请求 N 个站点」 |
| 含凭据实时同步 | 「将以明文 HTTP 在局域网传输 API Key」 |
| 安卓侧服务未开 | 「安卓的局域网服务未运行，请在安卓打开「管理页」」（`02` §5） |
| 安卓侧电池优化未关 | 原样显示 `backgroundGuide` 文案（`02` §5） |

---

## 8. 错误分类（新增）

在 `lib/core/app_error.dart` 的 `AppErrorKind` 新增：

| 取值 | 触发 | 用户文案要点 |
| --- | --- | --- |
| `realtimeSyncDisabled` | 实时同步未开启 | 指出开关位置 |
| `realtimePullUnsupported` | 安卓版本不支持 `/api/playback/history` 且 `/api/playback/current` 也无数据 | 提示升级安卓端 |
| `realtimePullDegraded` | `/api/playback/history` 不存在，降级为 `/current` | **必须常驻显示**"仅能同步正在播放的记录，息屏后无法同步" |
| `realtimeCursorStale` | 游标比远端最新还新（安卓重装/清数据） | 提示"已重置游标"并自动重置 |
| `realtimePartialFailure` | 有记录失败 | 必须带 `applied/skipped/failed` |
| `keepAlivePeerFrozen` | 心跳连续失败但网络正常（`02` §4） | 指向安卓电池/自启动设置 |
| `keepAliveServiceStopped` | `/manage/session` 返回 `running=false` | 指向安卓「管理页」 |
| `keepAliveUnauthorized` | 拉取端点 token/白名单校验失败 | 指出 token 或白名单 |

**不得**把上述任一折叠成"同步成功"或"0 条记录"（Phase 5 P5 延续）。

---

## 9. 存储变更

### 9.1 `settings.json` 的 `sync` 段

```json
{
  "sync": {
    "version": 2,
    "deviceUuid": "...",
    "deviceName": "...",
    "serverEnabled": false,
    "pushEnabled": false,
    "settingsSyncEnabled": false,
    "peers": [],
    "devices": [],
    "lastBridge": "",
    "realtime": {
      "enabled": false,
      "pullEnabled": false,
      "pushEnabled": false,
      "settingsEnabled": false,
      "intervalSeconds": 60,
      "heartbeatSeconds": 30,
      "pollAllSites": false,
      "pullCursorMs": 0,
      "pushCursorMs": 0,
      "pullToken": "",
      "lastPullAt": 0,
      "lastPushAt": 0,
      "lastHeartbeatAt": 0,
      "consecutiveFailures": 0
    },
    "identity": {
      "vod": {
        "epoch": 0,
        "updatedAt": 0,
        "identities": {
          "<canonicalInterfaceKey>": {
            "canonicalInterfaceKey": "...",
            "strictAddressKeys": [],
            "endpointMatchKeys": [],
            "hostMatchKeys": [],
            "legacyConfigKeys": [],
            "createdAt": 0,
            "updatedAt": 0
          }
        },
        "aliases": {
          "<key>": { "canonicalInterfaceKey": "...", "kind": "strict" }
        }
      }
    }
  }
}
```

`version` 1 → 2：旧文件缺 `realtime` 段时按默认值补齐（**不写盘**，沿用
`UiPreferencesStore` 的"缺席 = 默认"模式，避免污染既有文件）。

`identity`（T5 新增）：身份解析注册表，按 `configType`（`vod`/`live`/`wall`）
分开。**必须落盘**——安卓按 `adopt` 把自己的 `interfaceKey` 换成正式键，
PC 丢了注册表就会在下次解析时新造一个身份，两端键永久错开且**不报错**。
读不出/损坏时退化为空表（最坏是重新走一次 `create`，不会错配）。
别名指向不存在的身份时**丢弃**（手改文件不会把后续解析引到空身份上）。

### 9.2 数据库

**无 schema 变更**。删除传播复用既有 `history_deletions` 表
（`schemaVersion` 保持 3）。

---

## 10. 验收要点（详见 `04`）

| # | 要点 | 层 |
| --- | --- | --- |
| 1 | 增量判定：相等 skip、更旧 skip、更新 upsert、墓碑不复活 | L1 |
| 2 | `episodeId` 兜底策略（`episodeName` 优先，双空不合并） | L1 |
| 2b | `episodeId` 优先：安卓提供 `episodeId`（哈希）时**不**走兜底 | L1 |
| 3 | 开关联动（`pushEnabled` → `serverEnabled`；`settingsEnabled` → `settingsSyncEnabled`） | L1 |
| 4 | 退避序列与"403 立即停" | L1 |
| 5 | 路径 A 请求形态（URL、`Host` 头、`siteKey` 参数） | L2 |
| 5b | 能力探测与降级（`/history` 404 → `/current`，且降级状态常驻可见） | L2 |
| 6 | 路径 B 响应形态（`nextSince`/`items`/`deleted` 三种别名） | L2 |
| 6b | 身份解析端点：`create`/`keep`/`adopt`/`conflict` 四态 + 幂等原子 | L2 |
| 6c | `sync/status` 的 `capabilities.identityResolve = true` | L2 |
| 7 | 设置逐键映射 + `raw` 保真回推 | L2 |
| 8 | 手动三种拉取语义分开 | L2 |
| 9 | 端到端：真实 HTTP + 真实 SQLite 的增量同步 | L3 |
