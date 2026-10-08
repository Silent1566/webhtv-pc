# 01 · 安卓 T4 站点桥接设计

- 状态：设计指导，**实施中**
- 日期：2026-10-08
- 上游参考：`webhtv/默影视`（`F:\Workspace\webtv3\webhtv`）
  - `app/src/main/java/com/fongmi/android/tv/server/process/VodApi.java`（T4 网关）
  - `app/src/main/java/com/fongmi/android/tv/server/Nano.java`（路由注册）
  - `app/src/main/java/com/fongmi/android/tv/server/Server.java`（端口探测）
  - `app/src/main/java/com/fongmi/android/tv/utils/ScanTask.java`（设备发现）
  - `docs/C45-t4-api-gateway.md`（网关自身的设计记录）
- PC 端落点：`lib/core/android_bridge.dart`、`lib/services/android_bridge_service.dart`、`lib/ui/config_pages.dart`
- 关联：`00` §3.1–§3.4（实测快照）、`02`（同步）、`03`（测试）

---

## 1. 本模块解决什么

用户在 Android 上已经配好了一套点播配置（实测 170 个站源：猫源、网盘、爬虫等）。
这些站源在 Android 上**能跑**，但 PC 端要么没有、要么需要重新配一遍。

本模块让 PC 通过 Android 的 T4 网关**间接使用**这套站源：

```text
┌─────────────┐   ① GET /device            发现设备
│             │ ──────────────────────────►
│  WebHTV PC  │   ② GET /vod/api?ac=config  拉取站点清单（170 个 type=4）
│  (Flutter)  │ ──────────────────────────►  ┌──────────────────┐
│             │   ③ 导入为新配置记录         │  WebHTV Android  │
│             │   ④ 之后所有站点请求都打到网关 │  192.168.50.3    │
│             │ ──────────────────────────►  │  :9978           │
└─────────────┘   /vod/api?key=<站点key>      └──────────────────┘
                                                        │
                                               Android 自己执行
                                               T3 爬虫 / 网盘 / 猫源
```

**关键分工**：PC 负责「展示与播放」，Android 负责「站源执行」。
PC 侧对这套站点的处理与任何一份普通 `type=4` 配置**完全一致**，不新增站点类型、
不新增协议分支。这正是 P1（桥接不复制）的实现形态。

---

## 2. 分层与模块边界

| 层 | 文件 | 职责 | 禁止 |
| --- | --- | --- | --- |
| 纯逻辑 | `lib/core/android_bridge.dart` | 设备 JSON 解析、网关地址规范化、T4 配置 → `AppConfig` 转换、可达性校验、站点保真 | 不做网络、不碰 UI、不写库 |
| 服务 | `lib/services/android_bridge_service.dart` | 探测、拉取、错误分类、脱敏日志、进度回调 | 不做 UI、不直接改 `AppState` |
| 状态/UI | `lib/state/app_state.dart`、`lib/ui/config_pages.dart` | 触发导入、展示结果与错误 | 不解析协议 |

复用既有资产，**不新增**：

| 能力 | 复用对象 |
| --- | --- |
| 配置文本 → `AppConfig` | `parseConfigDocument`（`lib/core/config_parser.dart`） |
| 配置记录落盘 | `Storage.saveConfig`（`lib/services/storage.dart`） |
| `type=4` 站点执行 | `SiteService` + `SiteType.jsonApiBase64Ext`（已实现完整播放入口契约） |
| HTTP 客户端与错误 | `HttpApi`、`AppError`、`AppErrorKind` |
| 日志脱敏 | `LogService`、`redactUrl` |

> **为什么不直接调 `ConfigImportService.import(ConfigSource.parse(url))`？**
> 因为 P2 要求**校验响应主机与请求目标一致**，而 `ConfigImportService` 只做抓取+解析。
> 桥接服务在它之上加一层校验，而不是把它改造成通用能力。

---

## 3. T4 网关契约（PC 视角）

### 3.1 端点清单

| # | 方法 | 路径 | 用途 | 是否需要鉴权 |
| --- | --- | --- | --- | --- |
| 1 | `GET` | `/device` | 设备身份 | 否 |
| 2 | `GET` | `/vod/api?ac=config` | 站点清单（= `ac=site`，字节相同） | 否 |
| 3 | `GET` | `/vod/api?key=<key>` | 站点首页 | 否 |
| 4 | `GET` | `/vod/api?key=<key>&ac=detail&t=<id>&pg=<n>` | 分类 | 否 |
| 5 | `GET` | `/vod/api?key=<key>&ids=<vodId>` | 详情 | 否 |
| 6 | `GET` | `/vod/api?key=<key>&wd=<kw>&pg=<n>&quick=true` | 搜索 | 否 |
| 7 | `GET` | `/vod/api?key=<key>&play=<target>&flag=<line>` | 播放 | 否 |

只有 #1 与 #2 属于本模块；#3–#7 由既有 `SiteService` 按 `type=4` 契约发出，
**本模块不参与**。

### 3.2 站点清单响应

```json
{
  "spider": "",
  "wallpaper": "",
  "warningText": "…",
  "sites": [
    { "key": "csp_PianDan",
      "name": "片单导航[导]",
      "api": "http://<Host>/vod/api?key=csp_PianDan",
      "type": "4",
      "searchable": 0,
      "quickSearch": 0,
      "filterable": 1 }
  ],
  "doh": [ … ],
  "rules": [],
  "lives": []
}
```

字段处置：

| 字段 | 处置 | 说明 |
| --- | --- | --- |
| `sites` | **保留** | 全部导入为 `type=4` 站点 |
| `sites[].type` | **归一化为整数 `4`** | 上游是字符串 `"4"`；PC `Site.fromJson` 用 `asInt()`，字符串可解析（已确认 `asInt` 支持 `String`） |
| `sites[].api` | **校验主机一致性**（P2），**不重写** | 校验通过即原样使用 |
| `sites[].searchable` / `quickSearch` / `filterable` | 保留 | `asFlag` 支持 `0/1` |
| `doh` | **保留** | 可透传给 PC 的 DNS 策略（Phase 5 只保存不启用） |
| `rules` | 保留 | 实测为空 |
| `lives` | **忽略并提示** | 实测为空；Android 的 `lives` 由直播配置提供，T4 网关不转发（`configJson` 写死 `new JsonArray()`） |
| `spider` | **忽略并提示** | 写死 `""`；Android 的爬虫是它本地的，PC 无法也不应使用 |
| `wallpaper` / `warningText` | 忽略 | UI 字段，与站点无关 |

### 3.3 播放语义（已由既有实现覆盖，仅记录）

`type=4` 的播放入口就是站点 `api` 本身，参数固定 `play=<剧集目标>&flag=<线路>`。
PC 端 `SiteService.resolvePlayback` 对 `SiteType.jsonApiBase64Ext` **跳过直链初判**、
**无条件**先调播放入口（`site_service.dart` 已实现并注释了这段契约的来源）。
因此桥接站点无需任何播放侧改动。

---

## 4. 可达地址与设备识别

### 4.1 两种合法地址形态

| 场景 | 地址形态 | 来源 |
| --- | --- | --- |
| 真实局域网 | `http://192.168.x.y:9978` | 用户输入 / 扫描发现 |
| 模拟器 / 调试 | `http://127.0.0.1:<forwardPort>` | `adb forward tcp:<p> tcp:9978` |

**不得假设其中一种**。实测中 Android 自报 `Device.ip = http://172.16.1.4:9978`，
但 PC 直连该地址返回 `000`（模拟器 NAT），必须经 `adb forward` 才能联调（`00` §3.1）。

### 4.2 地址规范化规则

输入 → 规范化：

1. 缺 scheme → 补 `http://`。
2. 带路径 → **只取 scheme + host + port**，路径丢弃（网关路径由实现拼接）。
3. 缺端口 → 默认 `9978`（Android `Server.start()` 的起始端口）。
4. 尾随 `/` → 去掉。
5. `localhost` → **保留原样**（它是合法回环地址，与 `127.0.0.1` 等价，不强行改写）。

规范化结果用于两类用途，**必须分开**：

| 用途 | 使用的地址 |
| --- | --- |
| 发请求（探测、拉配置） | 规范化后的**可达地址** |
| 记录"这台设备是谁" | `/device` 返回的 `uuid` |

> 不能用 `Device.ip` 当请求地址：它是 Android 自报的地址，在模拟器场景下 PC 不可达。
> 也不能用请求地址当设备身份：`adb forward` 的端口每次可能不同。

### 4.3 设备身份

```dart
class AndroidDevice {
  final String uuid;        // 唯一标识，来自 /device
  final String name;        // 展示名，来自 /device
  final String reachableBase; // 实际可达地址（PC 视角），来自用户/扫描
  final String reportedIp;  // Android 自报地址，仅用于展示与诊断
  final int type;           // 0=TV 1=Mobile 2=DLNA
  final String serial;
  final String wlan;
  final String eth;
  final int time;           // 设备毫秒时间戳
}
```

相等性**只比 `uuid`**，与上游 `Device.equals` 一致（`00` §3.4）。
这样同一台设备经不同 `adb forward` 端口被添加两次时会被识别为同一台。

### 4.4 发现策略（降级采用）

上游 `ScanTask` 扫描 **9978–9998 全部 21 个端口 × 整个 /24 × 256 主机**，并发 64。
PC 侧降级为：

| 维度 | 上游 | PC 侧 |
| --- | --- | --- |
| 端口 | 9978–9998（21 个） | **9978–9998（21 个，保留）** |
| 主机 | 整个 /24（256） | **整个 /24（256，保留）** |
| 并发 | 64 | **16**（避免被当作扫描器；`00` P3 精神） |
| 超时 | 500 ms/请求 | **400 ms/请求** |
| 触发 | 进入设备页自动 | **仅用户显式点击"扫描"** |

> 之所以保留端口范围而不只扫 9978：`Server.start()` 从 9978 顺序探测，
> 若 9978 被占用会落到 9979，只扫一个端口会漏设备。

**手动地址永远可用**，且优先级高于扫描结果：扫描是便利功能，不是必需路径。

---

## 5. 配置转换（核心算法）

### 5.1 输入输出

```dart
/// 把 T4 网关的配置 JSON 转成 PC 可用的 [AppConfig]。
///
/// [reachableBase] 是 PC 视角的可达地址（如 `http://127.0.0.1:19978`），
/// 用于校验响应中站点 api 的主机一致性（P2）。
AndroidBridgeConfig convertGatewayConfig({
  required String jsonText,
  required String reachableBase,
});
```

### 5.2 步骤

```text
1. parseConfigDocument(jsonText)          → ConfigDocument
   ├─ 抛 AppErrorKind.configInvalid / configMsg → 直接上抛（分类保留）
   └─ 若 isRepository → 视为非法：T4 网关不返回配置仓库
2. 取 config.sites
3. 若 sites 为空 → AppError(bridgeEmptySites)
4. 对每个 site：
   a. 断言 site.type == 4        （不是 4 → 记为诊断并跳过）
   b. 解析 site.api 的 Uri
   c. 校验 host+port == reachableBase 的 host+port
      ├─ 一致 → 保留原 api
      └─ 不一致 → 按 P2 处理（见 §5.3）
5. 站点 key 去重（沿用 parseConfigDocument 的去重诊断）
6. 组装 AppConfig，附 bridge 元信息（设备 uuid、可达地址、拉取时间）
```

### 5.3 主机不一致的处置（P2 的落地）

三种情形，处置不同：

| 情形 | 判定 | 处置 |
| --- | --- | --- |
| 响应主机 = 请求主机 | 正常 | 保留原样 |
| 响应主机是回环，请求主机**不是**回环 | Host 头被中间层改写 | **重写为请求主机**，并记 `bridgeHostRewritten` 诊断（用户可见） |
| 响应主机既不是请求主机、也不是回环 | 网关指向了第三方 | **报错** `AppError(bridgeHostMismatch)`，**拒绝导入** |

> 为什么第二种是"重写"而不是"报错"：实测中存在反向代理/隧道把 `Host` 改写为
> `127.0.0.1` 的真实可能，而站点 `api` 的其余部分（path、`key`）**完全正确**，
> 只有主机需要修正。此时重写是**信息完备**的，报错反而让用户无法使用。
> 但必须在诊断里说明"已修正 N 个站点地址"，不能静默。
>
> 第三种必须报错：网关返回了不属于它自己、也不属于请求目标的地址，
> 说明我们理解错了协议，继续导入会产生无法解释的失败。

### 5.4 站点保真

导入后**必须**保持：

| 不变量 | 校验方式 |
| --- | --- |
| 站点数量 = 响应中合法 `type=4` 站点数 | 单测断言 |
| 站点 key 集合完全一致（不新增、不丢失、不改名） | 单测断言 |
| 站点 name 完全一致（含中文、方括号、emoji） | 单测断言 |
| `searchable` / `quickSearch` / `filterable` 标志一致 | 单测断言 |
| 每个 `api` 的 path 与 query 与响应一致（只有 host 可能被修正） | 单测断言 |
| 未知字段不丢失 | 沿用 `Site.extra` 机制 |

### 5.5 自引用防护（P4）

导入前检查，任一命中即拒绝：

1. `reachableBase` 的 host+port == PC 自己正在监听的同步服务地址 → 拒绝（导入自己）。
2. 某站点 `api` 的 host+port == PC 自己的同步服务地址 → 该站点跳过并记诊断。
3. 配置中已存在一个"桥接配置"且其设备 `uuid` 与本次相同 → 提示"已存在该设备的桥接配置"，
   由用户选择**更新**还是**新建**，不静默产生重复配置。

> 第 1 条对应 Android 侧已有的 `不能把本网关的配置作为本机源再次导入` 语义
> （`00` §3.3）。PC 侧必须同样设防，否则用户会导入一份"指向 PC 自己"的配置。

---

## 6. 错误分类

新增 `AppErrorKind` 取值（与既有类别并列，不复用模糊类别）：

| 取值 | 触发 | 用户可见文案要点 |
| --- | --- | --- |
| `bridgeUnreachable` | 连接被拒 / 超时 / DNS 失败 | 地址不可达 + 建议检查设备是否在同一局域网、应用服务是否运行 |
| `bridgeNotAndroid` | `/device` 返回 200 但不是合法设备 JSON | 该地址不是 WebHTV Android 服务 |
| `bridgeNoGateway` | `/device` 成功但 `/vod/api?ac=config` 返回 404 | 设备版本过旧，缺少 T4 网关（需 `c388619629` 或更新） |
| `bridgeEmptySites` | 配置合法但 `sites` 为空 | 设备上尚未加载任何点播配置 |
| `bridgeHostMismatch` | 站点主机既非请求主机也非回环 | 网关返回了异常地址，已拒绝导入 |
| `bridgeSelfReference` | 目标是 PC 自己 | 不能把本机当作安卓设备 |

**禁止**把上述任何一类折叠成"导入失败"或"0 个站点"（P5）。

---

## 7. 日志与隐私

| 内容 | 日志策略 |
| --- | --- |
| 设备地址 | 保留 host + port（需要它来排障） |
| 站点 `key` | 保留（非敏感，是公开标识） |
| 站点 `api` 的 query | 保留（只含 `key`） |
| 站点 `name` | 保留 |
| 设备 `uuid` / `serial` / `wlan` | **只输出前 4 位 + 掩码**（设备指纹） |
| 配置全文 | **不输出** |

沿用 `LogService` 的既有脱敏通道；`00` P5 要求错误可分类，
但**不要求**把设备指纹写进日志。

---

## 8. UI 流程

```text
设置页 →「安卓设备接入」
   ├─ [扫描局域网]         → 进度条（发现 N 台）→ 设备列表
   ├─ [手动输入地址]        → 规范化 → 校验 → 设备信息预览
   └─ 选中设备
        ├─ 显示：名称 / 类型 / 可达地址 / 上报地址 / 站点数
        ├─ [导入站点]  → 拉配置 → 校验 → 导入为新配置记录
        │                 成功：切到新配置 + 提示"N 个站点"
        │                 失败：分类错误 + 可操作建议
        └─ [更新站点]  （仅当已存在同 uuid 的桥接配置）
```

**不覆盖当前配置**：导入产生**新的配置记录**（Q10）。用户仍可在配置管理页切回旧配置。
这与 Android 侧"导入即切换"的语义一致，但不破坏用户已有的本地配置。

---

## 9. 开放问题

| # | 问题 | 当前结论 | 依据 |
| --- | --- | --- | --- |
| 1 | 是否支持多台 Android 设备同时桥接？ | **支持**（每台一个配置记录，按 `uuid` 区分） | Q10 |
| 2 | 桥接配置是否随配置导出？ | 是，它就是普通配置记录 | 无特殊处理 |
| 3 | `doh` 是否启用？ | **本阶段只保存不启用** | 避免与 PC 既有 DNS 策略冲突 |
| 4 | 站点清单多久过期？ | **不自动过期**；用户手动"更新站点" | 避免后台无感网络请求 |
| 5 | 是否缓存站点清单？ | 缓存最近一次成功结果，**仅用于离线展示设备卡片**，不用于导入 | 导入必须实时拉取 |
