# 02 · 安卓同步协议设计

- 状态：设计指导，**实施中**
- 日期：2026-10-08
- 上游参考：`webhtv/默影视`（`F:\Workspace\webtv3\webhtv`）
  - `app/src/main/java/com/fongmi/android/tv/server/process/Action.java`（`/action?do=sync`）
  - `app/src/main/java/com/fongmi/android/tv/server/process/PlaybackProgressApi.java`（本机写入）
  - `app/src/main/java/com/fongmi/android/tv/bean/Backup.java`（备份形态与恢复语义）
  - `app/src/main/java/com/fongmi/android/tv/bean/History.java`（历史模型）
  - `app/src/main/java/com/fongmi/android/tv/bean/SyncOptions.java`（同步范围）
  - `app/src/main/java/com/fongmi/android/tv/playback/ViewingRecordSyncStore.java`（开关默认值）
  - `docs/playback-history-delete-sync-design.md`（删除墓碑，上游仍「待实现」）
- PC 端落点：`lib/core/android_sync.dart`、`lib/services/sync_server.dart`、`lib/services/sync_client.dart`、`lib/services/storage.dart`
- 关联：`00` §3.5–§3.6（实测快照）、`01`（站点桥接）、`03`（测试）

---

## 1. 本模块解决什么

用户希望「在 Android 上看了一半的剧，回到 PC 上接着看」。

**难点**：Android **没有"拉取历史"的接口**（`00` §3.5，17 个 `Process` 全量枚举证实）。
它只有两种能力：

1. **被推**：别人 `POST /action?do=sync&mode=1&type=history` 把历史推给它；
2. **主动推**：它的 `/action?do=sync&mode=0&device=<目标>` 把历史推给别人。

因此 PC 要让用户能"拉"，**必须自己实现一个服务端**，让 Android 主动推过来。
这正是 Android 侧 `ScanTask` 在找的那种对端：

```text
Android 的发现流程（ScanTask.findDevice）：
    GET http://<host>:<port>/device   →  Device JSON
                    ↑
                    └── PC 必须实现这个端点，才能被 Android 发现

Android 的推送流程（Action.sendHistory）：
    POST http://<host>:<port>/action?do=sync&mode=0&type=history
         body: config=<配置JSON>&targets=<History[] JSON>
                    ↑
                    └── PC 必须实现这个端点，才能收到历史
```

于是本模块的形态与 `01` 相反：`01` 是 **PC 当客户端**，`02` 是 **PC 当服务端**。
两者都建立在同一台设备、同一个可达地址之上。

---

## 2. 分层与模块边界

| 层 | 文件 | 职责 | 禁止 |
| --- | --- | --- | --- |
| 纯逻辑 | `lib/core/android_sync.dart` | `History`/`Backup`/`SyncOptions` JSON 编解码、历史映射、新旧比较、合并决策、脱敏 | 不做网络、不写库 |
| 服务（服务端） | `lib/services/sync_server.dart` | LAN 监听、`/device`、`/action?do=sync`、请求校验、错误响应 | 不直接改 `AppState` |
| 服务（客户端） | `lib/services/sync_client.dart` | 向 Android 推送历史/备份、设备发现 | 同上 |
| 存储 | `lib/services/storage.dart` | 新增按项合并的历史写入（**不覆盖新记录**） | 不做协议解析 |
| UI | `lib/ui/config_pages.dart` | 开关、方向、状态、错误展示 | 不解析协议 |

**默认关闭**（P3）：`sync_server` 与 `sync_client` 都只在用户显式开启后才启动/发起。

---

## 3. 协议契约（PC 必须实现与必须调用）

### 3.1 PC 必须实现的端点（PC 当服务端）

| # | 方法 | 路径 | 请求 | 响应 | 用途 |
| --- | --- | --- | --- | --- | --- |
| 1 | `GET` | `/device` | — | `Device` JSON | 让 Android 能发现 PC |
| 2 | `POST` | `/action?do=sync&mode=<0\|1\|2>&type=history[&force=true]` | 表单：`config`、`targets` | `200 "OK"` / `500 <msg>` | 接收历史 |
| 3 | `POST` | `/action?do=sync&mode=<0\|1\|2>&type=keep` | 表单：`targets`、`configs` | `200 "OK"` | 接收收藏 |
| 4 | `POST` | `/action?do=sync&mode=<0\|1\|2>&type=backup` | 表单：`options`、`backup`（+ 可选 multipart 归档） | `200 "OK"` | 接收设置备份 |

**路径必须与 Android 完全一致**，因为 Android 的 `Action.isRequest` 判据是
`url.startsWith("/action")`，且 `ScanTask` 打的就是 `/device`。
PC 侧不能自创路径，否则 Android 的发现与推送都会失败。

### 3.2 PC 必须调用的端点（PC 当客户端）

| # | 方法 | 路径 | 用途 |
| --- | --- | --- | --- |
| 1 | `GET` | `/device` | 探测与识别设备（复用 `01`） |
| 2 | `POST` | `/action?do=sync&mode=1&type=history` | **推送**历史到 Android |
| 3 | `POST` | `/action?do=sync&mode=1&type=keep` | **推送**收藏到 Android |
| 4 | `POST` | `/action?do=sync&mode=1&type=backup` | **推送**设置到 Android |
| 5 | `POST` | `/action?do=sync&mode=0&device=<JSON>` | 请求 Android **主动推给** PC（可选便利路径） |

> `mode` 语义（`Action.onSync` 源码实证，**已纠正初稿**）：
> `mode` 是从**被请求方**视角定义的：
>
> | `mode` | 被请求方的行为 | 调用方的意图 |
> | --- | --- | --- |
> | `0` | 若 query 带 `device` → 把自己的数据推给该 `device`；**并且**应用请求体载荷 | 双向（带 `device`） |
> | `1` | 只应用请求体载荷（不推送） | **推送**（我把我的数据给你） |
> | `2` | 只推送（必须带 `device`），**不**应用请求体载荷 | **拉取**（我要你的数据） |
>
> 三处上游实证：`SyncDialog.onItemClick` 发 `mode=<用户选择>` 且 body 里带
> `device=<自己>`；`OneKeySyncDialog.startSync` 用 `toRemote ? "1" : "2"`；
> `Manage.syncStart` 用 `pull ? "2" : "1"` 且缺 `device` 时直接
> `400 Missing device`。
>
> **对 PC 的两条硬结论**：
> 1. PC 作为**服务端**必须把 `mode=0` 与 `mode=1` 都当作“落库”——
>    Android 自己的 `Action.post()`（投递历史/收藏/备份）用的就是 `mode=0`，
>    只认 `mode=1` 会收不到推送；
> 2. PC 作为**调用方**推送时用 `mode=1`（不是 `mode=0`）；
>    拉取时用 `mode=2` + `device=<PC 自己的 Device JSON>`。
>
> 这条语义必须在实现与测试中显式锁定，否则方向会反。

### 3.3 必须校验的请求字段（PC 当服务端时）

Android 的 `syncHistory` 逻辑（`00` §3.5）：

```java
Config config = Config.find(Config.objectFrom(params.get("config")));
List<History> targets = History.arrayFrom(params.get("targets"));
if (config.getUrl() == null) return;        // 静默返回，不报错
if (config.getUrl().equals(VodConfig.getUrl())) { … }
else VodConfig.load(config, callback);
```

实测：`config` 缺失时直接 **500 NPE**（`Config.getType()` on null）。

PC 侧因此**必须**：

| 校验 | 失败响应 |
| --- | --- |
| `type` 属于 `{history, keep, backup}` | `400` + 明确 message |
| `type=history` 时 `config` 非空且是合法 JSON 对象 | `400` + `config 不能为空` |
| `type=history` 时 `targets` 是合法 JSON 数组（可为空数组） | `400` + `targets 必须是 JSON 数组` |
| `mode` 属于 `{0,1,2}` | `400` |
| `mode=2` 时必须带 `device`（与上游 `Manage.syncStart` 一致） | `400` + 指明需提供 `device` |
| 同步功能已开启 | `403` + `同步未开启`（P3） |
| 请求来自允许的对端 | `403` + `对端未授权` |

**返回 400 而不是静默 `return`**：Android 的 `return` 会让调用方以为成功。
PC 侧必须让失败可见（P5），否则 Android 端的"同步成功"提示是假的。

### 3.4 历史记录映射

Android `History`（`00` §3.6）↔ PC `PlaybackHistory`：

| Android 字段 | 类型 | PC 字段 | 类型 | 映射规则 |
| --- | --- | --- | --- | --- |
| `key` | `site@@@vod@@@cid` | — | — | **切分**：`siteKey` / `vodId` / `cid` |
| （由 `key` 推出） | — | `siteKey` | `String` | `key.split("@@@")[0]` |
| （由 `key` 推出） | — | `vodId` | `String` | `key.split("@@@")[1]` |
| `vodName` | `String` | `vodName` | `String` | 直传 |
| `vodPic` | `String` | `vodPic` | `String?` | 空串 → `null` |
| `vodFlag` | `String` | `flag` | `String` | 直传（空串保留） |
| `vodRemarks` | `String` | `episodeName` | `String` | 直传（空串保留） |
| `episodeUrl` | `String` | `episodeId` | `String` | 直传（PC 用它做集消歧） |
| `position` | `long` **ms** | `positionMs` | `int` ms | **单位一致，直传** |
| `duration` | `long` **ms** | `durationMs` | `int` ms | **单位一致，直传** |
| `createTime` | `long` ms 时间戳 | `updatedAt` | `int` ms | **单位一致，直传** |
| `speed` | `float` | — | — | PC 暂不落库（保留在 raw） |
| `opening` / `ending` | `long`（可能 `C.TIME_UNSET = -9223372036854775808`） | — | — | **必须过滤哨兵值**，否则整数溢出 |
| `cid` | `int` | — | — | PC 无 cid 概念，**丢弃但保留在 raw** |
| `tmdbId` / `mediaType` / `tmdbSeasonNumber` / `tmdbEpisodeNumber` | — | — | — | **保留在 raw**，Phase 5 不参与 PC 的 TMDB 逻辑 |
| `sourceBindingKey` | `String` | — | — | 保留在 raw |
| `player` / `scale` / `revSort` / `revPlay` / `subtitleSource` | — | — | — | 保留在 raw |

> **`position`/`duration`/`createTime` 都是毫秒**（源码确认：`PlaybackProgressWriter`
> 里 `history.setCreateTime(input.updatedAt)`，而 `input.positionMs`/`durationMs` 字段名
> 自带 `Ms`）。**不存在秒/毫秒换算**，实现里加换算即是缺陷。

**哨兵值处理**：`opening`/`ending` 默认 `C.TIME_UNSET`（`Long.MIN_VALUE`）。
PC 的 `int` 放不下，必须显式判定：

```dart
int? normalizeAndroidMs(Object? raw) {
  final value = asInt(raw);
  if (value == null || value <= 0) return null;      // 覆盖 MIN_VALUE 与 0
  if (value > 0x7FFFFFFFFFFFFFFF) return null;        // 防御性上界
  return value;
}
```

### 3.5 反向映射（PC → Android）

PC `PlaybackHistory` → Android `History`：

| PC 字段 | Android 字段 | 规则 |
| --- | --- | --- |
| `siteKey` + `vodId` | `key` | 拼 `siteKey@@@vodId@@@0`（`cid=0`，由 Android 侧 `restoreConfig`/`cids` 重映射） |
| `vodName` | `vodName` | 直传 |
| `vodPic` | `vodPic` | `null` → `""` |
| `flag` | `vodFlag` | 直传 |
| `episodeName` | `vodRemarks` | 直传 |
| `episodeId` | `episodeUrl` | 直传 |
| `positionMs` | `position` | 直传（**ms**） |
| `durationMs` | `duration` | 直传（**ms**） |
| `updatedAt` | `createTime` | 直传（**ms**） |
| — | `speed` | 固定 `1.0` |
| — | `opening` / `ending` | **省略字段**，让 Android 用自身默认哨兵 |

> `cid` 写 `0`：`History` 的 `@PrimaryKey` 就是 `key` 字符串，而
> `History.sync()` 只把 `cid` **列**覆写为安卓当前 cid、**不改 key**
> （`Action.syncHistory` → `History.sync` 源码）。发 `@@@0` 即落在 `@@@0` 这行；
> 非聚合模式下安卓会先按 `vodName` 做 name-merge
> （`History.shouldMerge` → `item.copyTo(this).delete()`）**物理替换**同名本地行，
> 因此不会重复；但 `Setting.isHistoryAggregationEffective()` 为真时
> `shouldMerge` 直接返回 `false`，同剧可能出现两行。这是安卓侧的策略，
> PC 无法修正，因此推送是**用户显式触发**且需在文档中披露。
>
> ⚠️ **初稿勘误**：本节曾写“由安卓的 `Backup.restoreConfig()` 建立
> `source → 实际 cid` 映射并重写 history 的 `cid`”——该机制只对 **backup
> 路径**成立，对 `/action?do=sync` 路径**不成立**（后者走 `History.sync()`）。
> 结论（`cid=0`）不变，但理由应以 `History.sync` 源码为准。
>
> ⚠️ **`config` 字段是推送的隐形前提**（源码实证）：
> `Action.syncHistory` 第一行就是 `Config.find(Config.objectFrom(params.get("config")))`，
> 紧接 `if (config.getUrl() == null) return;` —— **静默无操作，HTTP 仍返回 200 OK**。
> 而且当 `config.url != VodConfig.getUrl()` 时会 `VodConfig.load(config)`，
> **切换安卓当前配置**（推送的历史随之落到另一个 cid 下）。
> 因此 PC 侧：
> 1. 推送前**必须**校验 `config` 含非空 `url`，否则拒绝发送并提示用户
>    （不能把“写入成功”报给用户，P5）；
> 2. “选哪个配置”是用户决策（须与安卓当前配置一致），由 UI 层收集，
>    `SyncClient` 只做 I/O 与校验。

### 3.6 `SyncOptions` 子集

PC 只发送/接受自己理解的子集，其余字段**显式写 `false`**（避免 Android 误判）：

| 字段 | PC 默认 | 说明 |
| --- | --- | --- |
| `config` | `false` | PC **不**向 Android 推送站点配置（`01` 的方向是反的） |
| `spider` | `false` | PC 无 Android 爬虫 |
| `search` | `false` | — |
| `history` | `true` | 主能力 |
| `keep` | `true` | 收藏 |
| `follow` | `false` | PC 无追更 |
| `webHome` | `false` | PC 无 WebHome |
| `settings` | `false` | 见下 |
| `loginState` | `false` | 与 PC 无关 |
| `remoteRelay` | `false` | — |
| `mpvConfig` | `false` | PC 播放器配置格式不同 |
| `paths` | `""` | — |

**`settings` 单独确认**：Android 的 `prefers` 白名单里有 `tmdb_config`（含 TMDB 凭据）、
`ai_config`（可能含 AI key）等敏感项（`00` §3.6）。按 P3 与 §19 安全与隐私，
**默认不同步**；用户显式勾选后才发送，且发送前必须提示"将同步包含凭据的设置项"。

### 3.7 与 `POST /api/playback/progress` 的关系

该端点默认 **403**（`本机 API 修改未开启`，实测）。它适合**单条、即时**写入，
不适合批量同步。PC 侧：

- **不作为主路径**（Q6）；
- 仅作为**诊断工具**：在设备详情页提供一个"测试写入"按钮，用于验证
  Android 侧开关是否已打开，并给出明确指引；
- 若返回 403，文案必须指出"需在 Android 的 设置 → 观影记录同步 中开启
  本机 API 修改"，而不是"同步失败"。

---

## 4. PC 服务端设计

### 4.1 监听

| 项 | 值 | 理由 |
| --- | --- | --- |
| 绑定地址 | `InternetAddress.anyIPv4` | 必须被 LAN 上的 Android 访问到 |
| 端口 | **从 9978 顺序探测到 9998**，占用第一个可用端口 | 与 Android `Server.start()` 同策略，便于用户记忆 |
| 启动时机 | 用户开启"同步"后 | P3 默认关闭 |
| 停止时机 | 用户关闭、应用退出 | 释放端口 |
| 与本地代理的关系 | **独立端口**，不共用 | 本地代理只监听回环（`01` §4.1 的 P2 边界），不能混用 |

> **不能复用 `LocalProxyServer`**：它硬性只允许回环（`proxy_server.dart` 的
> `start()` 对非回环 host 直接 `throw ArgumentError`），且路径空间是 `/p/<token>/…`。
> 同步服务需要 LAN 可达且路径必须与 Android 一致。两者安全模型不同，必须分开。

### 4.2 请求处理

```text
GET /device
  → 200 + Device JSON
     { uuid: <PC 稳定 uuid>, name: <PC 设备名>, ip: "http://<lan>:<port>",
       type: 2 /* DLNA 槽位，见下 */, serial, eth, wlan, time }

POST /action
  → 校验 do=sync、mode、type
  → 校验已开启同步 + 对端授权
  → 按 type 分派：
       history → 解析 config + targets → 逐条合并入 history 表
       keep    → 解析 targets + configs → 逐条合并入 favorites 表
       backup  → 解析 options + backup → 按 SyncOptions 子集合并设置
  → 200 "OK"  或  4xx/5xx + 明确 message
```

**`type` 的取值**：PC 的 `Device.type` 写 `2`（DLNA 槽位）还是 `1`（Mobile）？
- 写 `2` 会让 Android 的 `isApp()` 返回 `false`，于是 `ScanTask` 的
  `devices.stream().filter(device -> device.isApp())` **不会**把 PC 当作已知设备去重发探测。
- 但 `Device.equals` 只比 `uuid`，且 PC 是**新**设备，不影响发现。
- **结论：写 `1`（Mobile）**。理由：PC 是应用对端（`isApp()` 为真），
  与"可被同步"的语义一致；写 `2` 会让 Android 把它当投屏设备，语义错误。

### 4.3 并发与幂等

| 项 | 策略 |
| --- | --- |
| 并发 | 单请求串行处理（同步是低频操作，不做并发） |
| 幂等 | 按 `(siteKey, vodId, flag, episodeId)` + `updatedAt` 比较，重复推送不产生新行 |
| 部分失败 | 逐条处理，统计 `applied` / `skipped` / `failed`，返回**明细**；不因单条失败回滚全部 |
| 请求体上限 | **8 MiB**（历史列表可达数 MB；`00` §3.6 的 `Backup` 含全表） |
| 超时 | 读取 30 s |

### 4.4 合并算法（P3 的核心）

```text
for each incoming record:
    local = findHistory(siteKey, vodId, flag, episodeId)

    if local == null:
        insert(incoming)                        → applied
    else if incoming.updatedAt > local.updatedAt:
        upsert(incoming)                        → applied
    else if incoming.updatedAt == local.updatedAt:
        skip                                    → skipped (幂等)
    else:
        skip                                    → skipped (旧不覆盖新)
```

**禁止**：
- 任何形式的 `DELETE FROM history` 作为合并的前置步骤；
- 用"远端列表里没有"推断删除（`00` §3.6 引用的上游设计文档明确反对，
  因为缺失也可能由分页、过滤、故障造成）；
- 在合并失败时保留部分写入而不报告。

### 4.5 删除墓碑（本阶段边界）

上游的删除同步仍是「待实现」（`docs/playback-history-delete-sync-design.md` 状态：
待实现）。PC 侧本阶段：

| 能力 | 是否实现 |
| --- | --- |
| 接收并**应用**删除墓碑 | ❌ 不实现（对端不发） |
| **产生**删除墓碑 | ❌ 不实现（无对端可发） |
| **不复活已删除记录** | ✅ **必须**（等价于 §4.4 的"旧不覆盖新"） |

> 最后一条是实质性的：即使没有墓碑，只要严格遵守"旧不覆盖新"，
> 一条在 PC 上被删除、但在 Android 上仍存在的旧记录**不会**被重新创建——
> 因为它要么不存在（`local == null` → 会插入），要么时间戳更旧。
> **注意**：`local == null` 时会插入，这正是"复活"的路径。
> 因此 PC 需要一个**本地删除标记**（记录"我删过这条，删除时间 T"），
> 当 `incoming.updatedAt < T` 时跳过插入。这是最小可行的墓碑替代方案。

---

## 5. 默认关闭与用户授权

| 项 | 默认 | 说明 |
| --- | --- | --- |
| 站点桥接（`01`） | 可用（只读拉取） | 不涉及用户数据外发 |
| PC 同步服务端监听 | **关闭** | 打开 LAN 端口是安全敏感操作 |
| 向 Android 推送 | **关闭** | 数据外发 |
| 接收 Android 推送 | **关闭** | 数据写入 |
| 同步 `settings` | **关闭** | 含凭据 |

开启服务端时的必要提示（P3）：

1. 将监听 `0.0.0.0:<port>`，同局域网设备可访问；
2. 仅接受来自"已授权对端"的推送（按设备 `uuid` 白名单）；
3. 可随时关闭，关闭后端口立即释放。

**对端授权**：用户添加设备时确认。未授权 `uuid` 的推送一律 `403`。

---

## 6. 错误分类

| 取值 | 触发 | 用户可见文案要点 |
| --- | --- | --- |
| `syncDisabled` | 功能未开启 | 提示去设置开启 |
| `syncPeerUnauthorized` | `uuid` 不在白名单 | 提示先添加该设备 |
| `syncPeerUnreachable` | 推送时连不上 | 地址/网络检查 |
| `syncPayloadInvalid` | JSON 非法 / 缺字段 | 指出具体字段 |
| `syncPayloadTooLarge` | 超 8 MiB | 建议减少同步范围 |
| `syncLocalWriteRejected` | Android 返回 403（本机 API 修改未开启） | 指出 Android 侧开关位置 |
| `syncPeerError` | 对端返回 4xx/5xx（已连上但被拒或出错） | **必须带状态码与响应正文**；不得折叠为“连不上” |
| `syncPartialFailure` | 有记录失败 | **必须报出 applied/skipped/failed 明细** |

> `syncPeerError` 是实施期新增的第 8 类：把“已连上但对端报错”归入
> `syncPeerUnreachable` 会直接误导用户去查网络，而真实原因在安卓侧的响应里
> （对齐 `design/00` P5：能力缺口与失败原因不得折叠）。

**禁止**把 `syncPartialFailure` 折叠为"同步成功"（P5）。

---

## 7. 隐私

| 内容 | 策略 |
| --- | --- |
| 历史片名 | **不写日志**（用户隐私） |
| 历史条数 / 站点 key | 写日志（非敏感，便于排障） |
| 设备 `uuid` | 只输出前 4 位 + 掩码 |
| `config` JSON | 不写日志（可能含 URL） |
| 同步开关状态 | 写日志 |
| `tmdb_config` 等凭据 | **永不写日志**，沿用 `tools/phase4/verify_tmdb_redaction.py` 的脱敏口径 |

---

## 8. 开放问题

| # | 问题 | 当前结论 | 依据 |
| --- | --- | --- | --- |
| 1 | 是否实现自动定时同步？ | **不实现**，只手动触发 | P3；避免后台数据外发 |
| 2 | 是否支持多对端同时同步？ | 支持（按 `uuid` 分别授权） | §5 |
| 3 | `keep`（收藏）是否本阶段做？ | **做**，映射简单（`Keep` 4 字段） | `00` §3.6 |
| 4 | `backup` 的 multipart 归档（`paths`/`mpvConfig`/`loginState`）是否处理？ | **不处理**，只处理 JSON 表单 | PC 无对应文件语义 |
| 5 | PC 的 `uuid` 如何生成？ | 首次启动生成并持久化到 `settings.json` | 保证重启后 Android 仍认同一台设备 |
| 6 | 同步冲突（两端都改）如何裁决？ | **时间戳大者胜**；相等则跳过 | §4.4 |
| 7 | 是否回写 `completed`？ | PC 端按 `position >= duration - 5000` 重算 | 复用 `upsertHistory` 既有规则 |
