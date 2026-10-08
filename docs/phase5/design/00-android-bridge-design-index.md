# 安卓桥接设计指导文档（总索引）

- 状态：设计指导（Design Guidance），**待评审 → 实施中**
- 日期：2026-10-08
- 适用工程：`apps/desktop-flutter`（WebHTV PC，Flutter + media-kit 主线）
- 上游参考：`webhtv/默影视`（Android 工程，`F:\Workspace\webtv3\webhtv`，即 `192.168.50.3:5559`）
- 主设计文档：`docs/webhtv-pc-design.md`（本文档是它的 Phase 5 展开，§21「生态与同步」）
- 阶段计划：`docs/phase5/README.md`

---

## 0. 一句话目标

把已经跑在 Android 上的 WebHTV 当作**一台局域网内的站源服务器与同步对端**：
PC 通过 Android 已经暴露的 **T4 网关**间接访问它加载的全部站源（含 T3 爬虫、网盘、猫源），
并与它**双向共用播放历史与相关设置**——不复制 Android 的爬虫实现，不要求用户重复配置一遍。

---

## 1. 为什么先补设计文档

本仓库前四个阶段的推进方式固定为「先写设计/计划 → 再实现 → 再验收取证」：

| 阶段 | 计划文档 | 结果 |
| --- | --- | --- |
| Phase 0 | `docs/phase0/scorecard.md`、`docs/adr/0001-phase0-route.md` | 冻结 Flutter + media-kit |
| Phase 1 | `docs/phase1/README.md` | MVP-A 垂直闭环 |
| Phase 2 | `docs/phase2/README.md` | MVP-B 产品基础 + Spider ABI |
| Phase 3 | `docs/phase3/README.md`、`docs/adr/0002-android-csp-jar-compat.md` | 直播/字幕/弹幕/解析器/EPG/JS/JVM/猫源 |
| Phase 4 | `docs/phase4/README.md` + `design/00`–`05` | TMDB 元数据增强 |
| **Phase 5** | **本目录 + `docs/phase5/README.md`** | **安卓桥接：T4 站点接入 + 历史/设置同步** |

Phase 5 与前面阶段的关键差别：**它的输入是一台真实运行的外部设备**。
Android 侧的接口已经存在、已经跑起来，PC 只能被动适配它的真实行为，
不能靠"读代码猜语义"。因此本套文档的第一等交付物是**实测契约快照**（§3），
所有结论都标注了「实测」或「源码」的证据等级。

最容易犯的错误是把 Android 的 `/vod/api?ac=config` 当成一份**静态配置**去下载：
实测证明它返回的每个站点 `api` 地址是**用请求的 `Host` 头现算的**
（§3.2），用 `127.0.0.1` 去拉就会得到指向 PC 自己的地址，导入后全线失败。
本套文档的首要目的就是把这个陷阱和它的正确解法写死。

---

## 2. 文档清单

| # | 文档 | 覆盖内容 | 上游对应 |
| --- | --- | --- | --- |
| 00 | `00-android-bridge-design-index.md`（本文） | 目标、范围、原则、文档地图、上游取舍 | — |
| 01 | `01-android-t4-site-bridge.md` | T4 网关契约、Host 头派生地址、设备探测、配置转换、自引用防护、站点保真 | `VodApi.java`、`docs/C45-t4-api-gateway.md`、`Server.java`、`ScanTask.java` |
| 02 | `02-android-sync-protocol.md` | `/device`、`/action?do=sync`、`Backup` 形态、历史映射、PC 侧服务端、默认关闭与失败隔离 | `Action.java`、`Backup.java`、`History.java`、`PlaybackProgressWriter.java` |
| 03 | `03-bridge-test-and-acceptance.md` | 三层测试、fixture、门禁表、一键验收、证据落盘 | Phase 1–4 的门禁与证据机制 |
| — | `../README.md` | Phase 5 阶段计划与门禁表 | `docs/phase4/README.md` |

阅读顺序建议：00 → 01 → 02 → 03 → `../README.md`。
只关心"怎么把安卓的站源接进来"的读者可直接读 01 §3–§5；
只关心"历史怎么共用"的读者可直接读 02 §3–§6。

---

## 3. 实测契约快照（2026-10-08）

以下全部在 `192.168.50.3:5559` 上对**真实运行的** `com.silent.android.webhtv`（`versionName=5.6.0`，
`lastUpdateTime=2026-10-08 16:38:44`，含 `c388619629` T4 网关提交）实测得到。
证据等级：**实测** = 真实 HTTP 响应原文；**源码** = 上游仓库静态读取。

### 3.1 服务与端口

| 事实 | 证据 | 等级 |
| --- | --- | --- |
| 应用服务端口从 `9978` 起**顺序探测**到 `9998`，占用第一个可用端口 | `Server.start()`：`for (int i = 9978; i < 9999; i++)` | 源码 |
| 实测监听在 `9978`（`:::9978 LISTEN`） | 设备 `netstat -tln` | 实测 |
| 网关与 `/device`、`/action`、`/manage/*` **同端口复用** | `Nano` 注册 17 个 `Process` | 源码 |
| 设备自身地址 `172.16.1.4:9978`（`wlan0`），PC 直连该地址**不可达**（模拟器 NAT） | `curl 172.16.1.4:9978` → `000` | 实测 |
| 因此 PC 侧联调必须经 `adb forward`，生产使用真实局域网地址 | `adb -s 192.168.50.3:5559 forward tcp:19978 tcp:9978` | 实测 |

> **设计后果**：PC 的「安卓设备地址」必须是一个**可达地址**。
> 模拟器/调试场景经 `adb forward` 得到 `127.0.0.1:<port>`；真实局域网场景是 `192.168.x.y:9978`。
> 两种都合法，文档与实现不得假设其中一种。

### 3.2 T4 配置：`GET /vod/api?ac=config`（**最关键的一条**）

实测响应（`Host: 127.0.0.1:19978`，即 adb forward 入口）：

```json
{
  "spider": "",
  "wallpaper": "",
  "warningText": "…",
  "sites": [
    {"key":"csp_PianDan","name":"片单导航[导]","api":"http://127.0.0.1:19978/vod/api?key=csp_PianDan",
     "type":"4","searchable":0,"quickSearch":0,"filterable":1}
  ],
  "doh": [ … 4 项 … ],
  "rules": [],
  "lives": []
}
```

**同一个请求**，只改 `Host` 头为 `192.168.50.50:9978`：

```json
{"key":"csp_XiaoYa","api":"http://192.168.50.50:9978/vod/api?key=csp_XiaoYa", …}
```

| 事实 | 证据 | 等级 |
| --- | --- | --- |
| 站点 `api` 由 **请求的 `Host` 头**现算：`origin + PATH + "?key=" + encode(key)` | `VodApi.origin(session)` → `origin + PATH` | 源码 + 实测 |
| `Host` 头非法（带 userinfo / path / query / fragment）直接 500 拒绝 | `origin()` 抛 `IllegalArgumentException("无效的 Host")` | 源码 |
| 实测 `ac=config` 返回 **170 个站点，`type` 全部为 `"4"`**（字符串，不是数字） | 直方图 `{ '4': 170 }` | 实测 |
| 站点数量等于 Android 当前加载的点播配置站源数 | `sources.getSites()` | 源码 |
| `ac=site` 与 `ac=config` 返回**完全相同的字节**（31104 字节） | 两次请求 `size_download` 相等 | 实测 |
| 配置体量约 31 KB / 170 站点 | `size_download=31104` | 实测 |

> **不可退让的推论**：PC 拉取配置时**必须用可达地址作为请求目标**，
> 并且**必须校验返回的站点 `api` 主机可达**；若返回 `127.0.0.1`/`localhost`
> 而请求目标不是回环地址，说明 Host 头被中间层改写，必须报错而不是静默导入。

### 3.3 站点执行：`/vod/api?key=<key>`

| 操作 | 参数 | 实测 |
| --- | --- | --- |
| 首页 | 无额外参数 | 200，返回该站点首页数据 |
| 分类 | `&ac=detail&t=<分类ID>&pg=2`（`ac` 可省） | 契约来自 `docs/C45-t4-api-gateway.md` |
| 详情 | `&ids=<视频ID>`；批量逗号分隔或 POST JSON 数组，上限 100 | 同上 |
| 搜索 | `&wd=<关键词>&pg=2&quick=true` | 同上 |
| 播放 | `&play=<播放ID>&flag=<线路>`；也接受 `id` 与显式 `ac=play` | 同上 |
| 方法 | `GET` / `POST JSON` / `HEAD`；`OPTIONS` → 204 不调爬虫；其他 → 405 | 同上 |

自引用防护：Android 侧 `isSelfGateway(site.getApi(), origin, Proxy.getPort())` 会拒绝
把本网关配置当作本机源再次导入（返回 `不能把本网关的配置作为本机源再次导入`）。

### 3.4 设备身份：`GET /device`

实测原文：

```json
{"eth":"","ip":"http://172.16.1.4:9978","name":"vivo V1923A","serial":"00ed47e6",
 "time":1791453155486,"type":0,"uuid":"e6455919f5d1497b","wlan":"00:DB:14:2E:9C:7C"}
```

| 事实 | 证据 | 等级 |
| --- | --- | --- |
| `/device` 无鉴权、无参数，返回本机 `Device` JSON | `ScanTask.findDevice` 打的就是这个路径 | 源码 + 实测 |
| `type`：`0`=Leanback(TV)、`1`=Mobile、`2`=DLNA；`isApp() = type ∈ {0,1}` | `Device.isLeanback/isMobile/isDLNA/isApp` | 源码 |
| 设备相等性**只比 `uuid`** | `Device.equals`：`Objects.equals(getUuid(), it.getUuid())` | 源码 |
| Android 的发现方式：**端口 9978→9998 × 整个 /24 网段 × 256 主机**并发 64 探测 `/device` | `ScanTask`：`getUrl(bases, 9978, 9998)` + `PARALLELISM=64` | 源码 |
| 实测 `/manage/session` 也给出 `lanUrl: http://172.16.1.4:9978/m` | 实测 | 实测 |

### 3.5 同步入口：`/action?do=sync&type=<history|keep|backup>&mode=<0|1|2>`

| 事实 | 证据 | 等级 |
| --- | --- | --- |
| `mode=0` 只做**发送**（若带 `device` 参数则先推给该设备）；`mode=1` 只做**接收**；`mode=2` 两者都做 | `Action.onSync` | 源码 |
| 接收 `history` 需要 **POST 表单**字段 `config`（配置 JSON）与 `targets`（`History[]` JSON） | `syncHistory(params, force)` | 源码 |
| `config` 为空 → 500：`Config.getType()` NPE（**实测复现**：`Attempt to invoke virtual method 'int …Config.getType()' on a null object reference`） | 实测 | 实测 |
| 带合法 `config`（取自 `/manage/configs` 的条目）→ **200 `OK`** | 实测 | 实测 |
| `force=true` 会先 `History.delete(config.getId())` 再写入（**破坏性**） | `syncHistory` | 源码 |
| 接收 `backup` 走 `Backup.restore(options, force)`，`options` 是 `SyncOptions` JSON | `syncBackup` | 源码 |
| **没有"拉取"接口**：Android 只能被推、或主动推给别人，不存在 `GET` 读取历史列表的端点 | 17 个 `Process` 的 `isRequest` 全量枚举 | 源码 |
| `POST /api/playback/progress[/batch|/delete]` 是**本机写入**接口，默认 **403**：`本机 API 修改未开启` | `ViewingRecordSyncStore.isLocalWriteEnabled()` 默认 `false`；实测 403 | 源码 + 实测 |
| `GET /api/playback/current?siteKey=` 无记录时 404：`当前无可读播放记录` | 实测 | 实测 |

### 3.6 历史与备份的数据形态

| 事实 | 证据 | 等级 |
| --- | --- | --- |
| `History` 主键 `key` = `siteKey + "@@@" + vodId + "@@@" + cid`；`getSiteKey()`/`getVodId()` 按 `@@@` 切分 | `History.getSiteKey/getVodId`、`AppDatabase.SYMBOL = "@@@"` | 源码 |
| 进度字段：`position` / `duration`（**毫秒**）、`speed`、`opening` / `ending`（默认 `C.TIME_UNSET`） | `History` 字段 | 源码 |
| 时间字段：`createTime` = 毫秒时间戳；写入时 `setCreateTime(input.updatedAt)` | `PlaybackProgressWriter` | 源码 |
| 集信息：`vodRemarks`（集名）、`episodeUrl`（集地址）、`sourceBindingKey`、`vodFlag`（线路） | `History` 字段 | 源码 |
| TMDB 身份：`tmdbId` / `mediaType` / `tmdbSeasonNumber` / `tmdbEpisodeNumber` | `History` 字段 | 源码 |
| `Backup` 顶层字段：`site` / `live` / `keep` / `config` / `history` / `tmdbSeasonProgress` / `following` / `followingSource` / `followingSchemaVersion` / `track` / `device` / `prefers` | `Backup` 字段 | 源码 |
| `Backup.restore` **默认先 `clearAllTables()`**（全量覆盖，破坏性） | `Backup.restore(boolean)` | 源码 |
| `Backup.restore(options, force)` 按 `SyncOptions` 逐项恢复，`force` 时才 `delete` 对应表 | `Backup.restore(SyncOptions, boolean)` | 源码 |
| `prefers` 白名单含 `tmdb_enabled` / `tmdb_config` / `tmdb_model` / `viewing_record_sync_*` 等 | `Backup.APP_PREFS` | 源码 |
| `SyncOptions` 默认：`config/spider/search/history/keep/webHome/loginState = true`，`follow/settings/remoteRelay/mpvConfig = false` | `SyncOptions` 字段初值 | 源码 |

---

## 4. 五条不可退让的原则

以下五条是**契约级**要求。任何实现只要违反其一，即视为设计缺陷，必须修复而不是放宽文档。

### P1 · 桥接不复制（Bridge, don't clone）

PC **不**在本地重新实现 Android 的站源执行。Android 上加载的 T3 爬虫、网盘、猫源
一律由 **Android 自己执行**，PC 只做 HTTP 客户端。

- 允许：把 T4 网关导入为一份 PC 配置（`type=4` 站点，`api` 指向网关）。
- 禁止：在 PC 侧尝试下载/加载 Android 的 `csp_*.jar`、DEX 或猫源 bundle 来实现同样的站点。
  （存量 Android JAR 的兼容层是 ADR-0002 的**独立可选**议题，默认关闭，与 Phase 5 无关。）

**理由**：PC 端已为 `type=4` 实现了完整播放入口契约（`SiteType.jsonApiBase64Ext`，
无条件 `play=<目标>&flag=<线路>`，见 `site_service.dart`），接入成本为零；
而复制爬虫实现要面对 DEX 只能由 ART 执行、Android `Context` 依赖等硬边界。

### P2 · 地址来自请求，不来自响应（Host-derived origin）

导入的站点 `api` 地址**必须**以 PC 实际可达的设备地址为基准。

- PC 拉取配置时用**可达地址**发请求（真实局域网 IP，或 `adb forward` 后的 `127.0.0.1:<port>`）。
- 拉取后**必须校验**：返回站点 `api` 的主机部分与请求目标主机一致；不一致（例如被中间层
  改写成 `127.0.0.1`）必须报错，**不得静默导入**。
- **禁止**把响应里的地址硬编码为 `127.0.0.1` 当作"通用地址"。

**理由**：实测证明 `Host` 头决定站点地址（§3.2）。违反 P2 的典型后果是导入 170 个站点后
全部指向 PC 自己，表现为"一个站点都加载不出数据"。

### P3 · 同步默认关闭，且失败不破坏本地（Opt-in & non-destructive）

- 站点桥接（只读拉取）可以默认可用；**历史/设置同步必须默认关闭**，由用户显式开启。
- 接收远端数据**禁止**使用 `force=true` 语义的清表路径作为默认行为。
- 同步任一步失败（网络、鉴权、格式、部分条目）必须**保留本地全部数据**，
  并给出可分类的错误，不得静默丢弃、不得半写。
- 收到的记录必须做**新旧比较**（`updatedAt` / `createTime`），旧记录不得覆盖新记录。

**理由**：主设计文档 §21 验收原文要求「同步失败不破坏本地数据」「所有同步默认关闭并需要
用户明确开启」；上游 `Backup.restore()` 默认 `clearAllTables()`，直接调用即数据丢失。

### P4 · 不引入自引用与循环（No self-reference）

- 导入前必须拒绝把**本机自己**的服务当作站点来源。
- 拒绝导入 Android 返回的、指向 PC 自己的站点地址。
- 拒绝 Android 侧已有的 `不能把本网关的配置作为本机源再次导入` 语义在 PC 侧被绕过。

**理由**：Android 侧已有 `isSelfGateway` 防护（§3.3）；PC 侧不设防会让用户导入后
陷入自我请求，且这种错误在 UI 上表现为"卡住"而不是明确报错。

### P5 · 能力缺口必须披露，不得伪装成功（Disclose gaps）

- Android **没有**历史"拉取"接口（§3.5）。PC 要让用户能"拉"，必须自己实现服务端，
  由 Android 主动推给 PC。
- 若某能力当前未实现（例如 Android 端尚未开启"本机 API 修改"），必须给出**明确原因**
  与**可操作指引**，不得返回空列表冒充"没有历史"。

**理由**：把 403/404/超时统一折叠成"空结果"是本类集成最常见的失败形态，
用户无法区分"真的没历史"和"没接通"。

---

## 5. 上游取舍：哪些抄、哪些不抄

| 上游能力 | 是否采用 | 理由 |
| --- | --- | --- |
| `/vod/api` T4 网关 | ✅ **完全采用** | 已实测可用，PC 已有 `type=4` 播放契约 |
| `/device` 身份端点 | ✅ **采用** | 无鉴权、字段明确，是设备识别与"推送目标"的基础 |
| `/action?do=sync&type=history` 接收语义 | ✅ **采用（PC 实现服务端）** | 这是让 Android 主动推给 PC 的唯一通道 |
| `Backup` + `SyncOptions` 形态 | ✅ **采用（受限子集）** | 字段齐全，但只取 PC 能映射的部分 |
| `ScanTask` 全网段 × 端口扫描 | ⚠️ **降级采用** | PC 侧只扫**当前网段**且端口限于 9978–9998，并允许手动地址；不做 64 并发全网段 |
| `Backup.restore()` 全量 `clearAllTables()` | ❌ **禁止** | 违反 P3；PC 只用按项合并路径 |
| `force=true` 清表 | ❌ **禁止作为默认** | 违反 P3；最多作为用户显式确认的独立操作 |
| `POST /api/playback/progress` 本机写入 | ❌ **不作为主路径** | 默认 403（需 Android 侧开启"本机 API 修改"），只作为可选增强与诊断 |
| 复制 Android 爬虫实现 | ❌ **禁止** | 违反 P1 |
| Android `prefers` 全量同步 | ⚠️ **白名单子集** | 只同步 PC 有对应语义的键；`tmdb_config` 含凭据，单独确认 |
| 删除墓碑（`PlaybackDeleteTombstone`） | ⚠️ **本阶段只读不写** | 上游删除同步仍是「待实现」（`docs/playback-history-delete-sync-design.md`），PC 侧只保证"不做复活写回" |

---

## 6. 与主设计文档的章节对应

| 本文档 | 主设计文档章节 |
| --- | --- |
| §3 契约快照 | §21 Phase 5、§7 配置与站点、§8 站点模型 |
| `01` §3 T4 网关 | §8 站点模型、§12 解析器（`type=4` 播放入口） |
| `01` §4 设备探测 | §11 代理与本地服务（端口与可达性） |
| `01` §5 配置导入 | §7.4 配置导入与仓库、§17.2 配置页 |
| `02` §3 同步协议 | §21 Phase 5（配置/历史/收藏同步）、§15 历史与续播 |
| `02` §5 默认关闭 | §22.5 发布门禁、§19 安全与隐私 |
| `03` 测试与验收 | §19 测试策略、§22 总验收清单 |

---

## 7. 术语补充

| 术语 | 含义 |
| --- | --- |
| **T4 / 网关** | Android 暴露的 `/vod/api` HTTP 站源网关；它把 Android 当前加载的站源统一包装成 `type="4"` 的 HTTP API 站点 |
| **桥接配置** | PC 侧由 T4 网关导入得到的配置记录，站点全部为 `type=4`，`api` 指向设备网关 |
| **可达地址** | PC 能真正连上的设备服务地址（局域网 IP，或 `adb forward` 后的回环地址）；与 Android 自报的 `Device.ip` **可能不同** |
| **推送 / 接收** | 同步方向：推送 = PC → Android（走 Android 的 `/action?do=sync&mode=1`）；接收 = Android → PC（走 PC 自己实现的服务端） |
| **对端** | 用户显式添加并确认的一台 Android 设备（以 `uuid` 唯一标识） |
| **快照（snapshot）** | 一次同步传输的完整数据体（历史列表或备份 JSON），不是增量流 |

---

## 8. 决策记录（已回填主设计文档 §23 / §28）

| # | 决策 | 结论 | 依据 |
| --- | --- | --- | --- |
| Q1 | PC 是否复制 Android 爬虫实现？ | **不复制**，只做 HTTP 桥接 | P1；ADR-0002 边界 |
| Q2 | 站点地址以什么为基准？ | **请求目标地址**，并校验响应主机一致 | P2；§3.2 实测 |
| Q3 | 同步默认开还是关？ | **默认关闭** | P3；§21 验收原文 |
| Q4 | 历史同步用 `force` 清表吗？ | **不用**，只做按项合并且旧不覆盖新 | P3；§3.6 源码 |
| Q5 | 能否从 Android "拉取"历史？ | **不能直接拉**；PC 必须实现服务端由 Android 推送 | P5；§3.5 全量枚举 |
| Q6 | 是否依赖 `POST /api/playback/progress` 写入？ | **不作为主路径**（默认 403） | §3.5 实测 |
| Q7 | 设备发现是否照搬全网段 64 并发扫描？ | **降级**：只扫本网段 + 允许手动地址 | §5 取舍表 |
| Q8 | `tmdb_config` 等含凭据的设置是否默认同步？ | **不默认**，需单独确认 | §5 取舍表；§19 安全与隐私 |
| Q9 | 删除历史是否向 Android 传播？ | **本阶段不写墓碑**，只保证不复活 | §5 取舍表 |
| Q10 | 桥接配置是否覆盖当前配置？ | **不覆盖**，作为新配置记录导入 | P3；§7.4.1 导入即切换语义 |
