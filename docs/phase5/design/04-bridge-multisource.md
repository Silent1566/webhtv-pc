# 04 · 安卓桥接多源化（方案 B）与历史按源隔离

- 状态：**已实现**（PC `webhtv-pc/dev1` + 安卓 `webhtv/dev5`）
- 日期：2026-10-26（落地与实测 2026-10-27）
- 上游参考：`app/src/main/java/com/fongmi/android/tv/server/process/VodApi.java`、`Manage.java`、`Action.java`、`bean/History.java`
- 关联：`00`（原则）、`01`（T4 站点桥接）、`02`（同步协议）、`03`（测试与验收）
- 用户原始诉求：桥接后应把安卓上的**所有源**都拉过来并可切换；历史默认按源隔离、另给一个开关看全局；
  推送历史要落到**对应的那个源**下面——而不是"给安卓新增了一个桥接源"。

---

## 1. 问题：一条错误的桥接记录，与三个不该发生的副作用

改造前的桥接是"当前激活源快照"模型：PC 只能看到安卓**当时激活**的那一个配置，其余源完全不可见。
更糟的是历史推送把那台设备**又写成了一个新源**。用户看到的正是这样一行伪造配置：

```text
安卓桥接（192.168.50.2）   站点 170 · 直播 19 · 来源 http://192.168.50.2:9978/
```

| # | 现象 | 根因（源码证实） |
| --- | --- | --- |
| 1 | 安卓 `Config` 表凭空多出一行网关地址配置 | PC 推历史时 `config.url` 填的是**设备网关地址**（`record.origin`）→ 安卓 `Action.syncHistory` → `Config.find(url,type)` 查不到 → `Config.create(type,url).insert()` |
| 2 | 只能看到一个源 | `VodApi.doResponse` 只用 `VodConfig.get()`（当前激活配置），没有任何端点能取非激活配置的站点 |
| 3 | 为写历史把安卓**切了源** | `Action.syncHistory` 在 `config.url != VodConfig.getUrl()` 时调 `VodConfig.load(...)` |
| 4 | 即便切了源也写不进目标源 | `History.sync` 内部写死 `target.cid(VodConfig.getCid())`，cid 永远是当前激活配置 |

第 2–4 条共同说明一件事：**安卓不是被当作容器，而是被当作"当前状态"去改**。方案 B 的核心就是
把所有跨设备读取都改成**带坐标的后台接口**，读取与写入都显式指明"哪个配置"，且全程不触碰
`VodConfig` 单例——即安卓当前激活配置在桥接的任何操作里都保持不变。

---

## 2. 方案 B：后台接口取全量源

### 2.1 决策与备选

| 备选 | 做法 | 为什么不选 |
| --- | --- | --- |
| A | PC 调 `/manage/config/use` 逐个切源再拉 | 会真实改变安卓当前激活配置（用户明确否决："安卓只是运行容器"），并发下还会互相踩 |
| **B** | 给 `/vod/api` 增加 `configKey` 参数，按标识取**指定源**；推送同理带标识 | **采纳**：读取与写入都无副作用，安卓状态不变 |
| C | 只读：不允许切换，只展示当前源 | 等于放弃用户诉求（多源可切换） |

用户选型原话（2026-10-26）："安卓端只是当作一个运行容器不应该直接改变安卓端当时的状态，应该是后台接口的方式处理。"

### 2.2 安卓端点（新增/扩展）

| 端点 | 变化 | 语义 |
| --- | --- | --- |
| `GET /manage/configs` | **已有**（`Manage.configs`），PC 开始使用 | 列出 `type` 0/1/2 的**全部**配置，每项含 `interfaceKey`、`url`、`active`、`time`。这是"设备上有哪些源"的唯一来源 |
| `GET /vod/api?ac=config&configKey=<interfaceKey>` | **新增分支** | 返回**该配置**的 T4 站点清单（站点 `api` 追加 `&configKey=<k>`），不切源 |
| `GET /vod/api?key=<siteKey>&configKey=<k>` | 扩展 | 站点执行/首页/分类/详情/搜索都带上自己的坐标 |
| `GET /proxy?siteKey=<k>&configKey=<k>` | 扩展 | 网盘与爬虫站点按**指定配置**解析 spider（否则只认激活源，会串源） |
| `POST /action?do=sync&type=history`（表单 `config`） | 扩展 | `config` 里带 `configKey` 时**直接写该配置的 cid**，不 `VodConfig.load`、不新增 `Config` 行 |

**未命中 `configKey`** 时原样返回 `{"msg":"未知的配置标识: <k>"}`（HTTP 200，与安卓其余业务错误一致），
PC 侧由 `configMsg` 分类呈现，不折叠成"空站点"。

> 兼容性：`configKey` 缺省时行为与改动前**完全一致**，因此老 PC 客户端不受影响；
> 老安卓（无 `configKey`、无 `/manage/configs`）由 PC 侧降级（见 §5）。

### 2.3 fixture 对应行为（`03` §2.3）

`tools/fixture_server/server.py` 的 `/android/**` 复现上述形态：

| fixture 路由 | 行为 |
| --- | --- |
| `GET /android/manage/configs` | 返回 `manage-configs.json`：2 个点播源（`fixture-vod-a`/`fixture-vod-b`，前者 `active:true`）+ 1 个直播源 + 1 个壁纸源 |
| `GET /android/vod/api?ac=config&configKey=fixture-vod-a` | 返回 `gateway-config.json`（170 站点） |
| `GET /android/vod/api?ac=config&configKey=fixture-vod-b` | 返回 `gateway-config-source-b.json`（3 站点，key 与 A **完全不重叠**） |
| `GET /android/vod/api?ac=config&configKey=<未知>` | `{"msg":"未知的配置标识: <k>"}` |
| `GET /live/live-config.json` | 直播配置文档（`lives[]`）；T4 网关的 `lives` 恒空，PC 单独拉这一份 |

两个源的站点集合**必须不同**，否则"按源隔离 / 切换真的生效"的断言会空转——这是 fixture 的设计约束，
不是实现细节。故障注入（`__mode`）只作用于**默认（当前激活源）** 路径：`configKey` 分支永远返回正常清单，
避免把"某个源坏了"和"设备故障"混成一类错误。

---

## 3. 安卓实现（dev5）

### 3.1 `VodSiteCatalog`：无副作用解析

`app/src/main/java/com/fongmi/android/tv/api/config/VodSiteCatalog.java`（新增）负责"按标识取站点清单"，
**禁止**走 `VodConfig.parseConfig`：那条路径会 `initLive`/`initWall` 写库、`BaseLoader.parseJar` 注册加载器、
改 `WebHomeExtensionRegistry` 与配置行上的 `logo`/`notice`——每一条都是对全局状态的污染。

| 成员 | 作用 |
| --- | --- |
| `Catalog`（sites/doh/rules/flags + `find(key)`） | 一份配置解析结果的对外形态 |
| `sitesOf(Config)` / `catalogOf(Config)` | 只"取 JSON + 建 `Site`"，不写库、不注册、不改单例 |
| `objectOf(url, depth)` | 订阅 `urls`（depot）时递归取首条，最多 3 层，**不写库** |
| `database()` | 进程级单例：`ConfigDao.findByInterfaceKey` + 60 s / 8 条缓存（解析要发网络请求，`/proxy` 会被逐段调用） |

`find(key)` 的匹配顺序与 `VodConfig.getSite` 一致（先精确、再忽略大小写，未命中返回空 `Site`），
保证"同一个 key 在激活源与非激活源上解析出同一行为"。

### 3.2 `configKey` 透传

`VodApi` 三处：`doResponse`（`ac=config` 分支）、`handle`（站点执行）、`externalize`/`remoteUrl`
（响应改写与代理地址）。`configJson(...)` 新增带 `configKey` 的重载，为每个站点 `api` 追加 `&configKey=<k>`，
于是 home/category/detail/search/play **全部自带坐标**，不再依赖"当前激活的是哪个源"。

### 3.3 `/proxy` 的坐标

`BaseLoader.proxy` 原本用 `VodConfig.get().getSite(siteKey)` —— 只认激活源。现在有 `configKey` 时
优先用 `VodSiteCatalog` 解析该配置的站点，取不到再退回原路径。缺这一步的后果很具体：
**非激活源的网盘/爬虫站点播放会失败或串到另一个源的同名站点上**。

### 3.4 推送落盘：`History.syncTo(cid, …)`

`History` 新增 `syncTo(int cid, List<History>)` 与 `findByName(int cid, String)`：复刻 `History.sync` 的
合并语义，但 cid 由调用方显式传入（含同名合并在该 cid 内查重）。`Action.syncHistory` 在 `config` 带
`configKey` 时改走 `pushScopedHistory`：`VodSiteCatalog.findConfig` → `History.delete` + `History.syncTo`
+ `RefreshEvent.history()`，**不调用 `VodConfig.load`、不 `Config.create`**。

### 3.5 已知限制（不在本次范围）

`JsLoader` / `PyLoader` 的 `computeIfAbsent` 缓存键只有 `key`（不含 jar 哈希）：两个源上**同名 siteKey 但不同 jar**
会互相复用 spider。`JarLoader` 的键是 `md5(jar)+key`，而 CSP 站点走 `JarLoader`，因此主流程安全；
jar/js/py 同名冲突是既有隐患，记为已知限制（`01` §9）。

---

## 4. PC 实现（dev1）

### 4.1 源标识 `core/source_key.dart`

| 类型 | 形态 | 说明 |
| --- | --- | --- |
| 本地源 | `local|<origin>` | 用户在 PC 导入的配置 |
| 安卓源 | `bridge|<deviceUuid>|<interfaceKey>` | 安卓某台设备上的某一个点播配置 |
| 未知 | `unknown` | 无法识别时**不猜成 local**：猜错会让两份历史合并，那是数据损坏而非显示问题 |

用 `interfaceKey` 而非设备地址或配置名：地址随 `adb forward` 端口与 DHCP 变化，配置名用户随时能改；
只有 `interfaceKey` 是安卓侧持久化、改名与换地址都不变的身份。

### 4.2 存储 v6 → v7

`lib/services/storage.dart`：`configs` 增 `source_key` / `bridge_device` / `bridge_interface_key` /
`bridge_config_url`；`history` 与 `history_deletions` 重建并带 `source_key`
（原 `UNIQUE(site_key,vod_id,flag,episode_id)` 会让两个源的同名站点互相覆盖）。迁移前先
`CREATE TABLE history_backup_v6 AS SELECT * FROM history` 留证。

**配置记录去重键**：`sourceKey` 为空时仍按 `origin`（旧语义），非空时按 `source_key`——
同一台安卓设备的多个源 `origin` 全是网关地址，按 `origin` 去重会把第二个源覆盖成第一个。

### 4.3 导入：一台设备 → 多条记录

`SyncState.importSites` 的流程：

1. `fetchSources(base)` 取 `/manage/configs`；404 → 老安卓，降级为"只导入当前激活源"；
2. 过滤 `type=0` 且 `interfaceKey` 非空（缺失说明安卓版本过旧，记诊断）；
3. 直播源**设备级只取一次**（`/manage/configs` 里 `type=1` 的 `url` → 拉取 → `lives[]`）；
4. 逐源 `fetchGatewayConfig(base, interfaceKey)` → `saveBridgeConfig(... makeActive: false)`；
5. 单源失败不中断，汇总诊断（P5）；只有一个源失败时**原样冒泡原始分类**，不折叠成 `bridgeUnreachable`。

"切换"只切 **PC 本地** 的生效记录（`activateConfigRecord`），**从不**调用任何安卓切源接口。

### 4.4 历史隔离与全局开关

| 项 | 设计 |
| --- | --- |
| 默认 | `UiHistoryScope.source`：只显示**当前源**的历史 |
| 开关 | `history-scope-switch`（当前来源 / 全部来源），持久化在 `settings.json` 的 `ui.historyScope` |
| 读历史 | `historySourceFilter`：全局模式为空串（不过滤），否则 `activeSourceKey` |
| 升级前的老记录 | `source_key=''`，**只在「全部来源」可见**；按源视图严格只认当前源，首次写入时被收编为该源（`05` §6.1，2026-10-28 修正） |
| 清空 | `clearHistory({clearAll})`：默认只清当前源 |
| 与安卓的关系 | **PC 本地偏好，不写回安卓** 的 `global_history_mode`（安卓只是容器） |

`activeSourceKey`：优先 `BridgeSourceKey.of(deviceUuid, interfaceKey)`，其次记录自带的 `source_key`，
最后回落 `LocalSourceKey.of(origin)`。

### 4.5 推送载荷

`syncConfigJson()` 对桥接记录返回
`{id, type:0, name, configKey:<interfaceKey>, url:<该源在安卓上的真实配置 url>}`；
非桥接记录返回 `null`（不参与安卓历史推送）。

两端都不允许再发网关地址：`sync_client` 在 `config.url` 等于已知设备网关基址时直接抛
`syncPayloadInvalid`（本地即拦，理由是安卓会静默忽略却回 200），安卓侧则按 `configKey` 落到目标 cid。

---

## 5. 兼容与降级

| 场景 | 处置 |
| --- | --- |
| 老安卓无 `/manage/configs` | 只导入当前激活源，并明确披露"安卓版本过旧，无法按源定位" |
| 老安卓无 `configKey` | 推送仍带该源真实 `url`，`Config.find` 能命中既有行，**不再 `insert`** |
| 某源清单取不到 | 该源记失败原因，其余源照常落库 |
| 两源同名 siteKey | `configKey` 消歧 + `source_key` 隔离历史 |
| 存量历史 | 归迁移时刻的当前源 |
| 存量伪造"桥接源"记录 | **不自动删除**（可能是用户手建的），由用户在配置页自行清理 |

---

## 6. 验收形态

| 项 | 判据 |
| --- | --- |
| 多源可切换 | fixture 设备上 2 个点播源各成一条记录（A 170 站点 / B 3 站点），逐条可激活、可浏览 |
| 历史按源隔离 | 默认视图只见当前源；切到"全部来源"后两条都在 |
| 推送落源 | 推历史后 fixture 收到的 `config` 含 `configKey`、`url` 不是网关地址 |
| 安卓状态不变 | `/manage/configs` 的 `active` 在整轮操作前后不变；PC 从不调用切源端点 |
| 反向验证 | 见 `03` §4.3：把"网关地址当 `config.url`"的拦截去掉，`phase5_sync_client_test.dart` 必须失败 |

一键命令见 `03` §6（G1 路由 11 项 + 8 种故障注入）。
