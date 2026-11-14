# 02 · 安卓保活、心跳与唤醒

- 状态：设计指导，**待评审**
- 日期：2026-10-17
- 上游参考：`Server`、`ManageService`、`Manage.syncStart`、`Manage.session`、
  `ScanTask`、`App.startBackgroundServicesNow`、`PlaybackService`、`PlaybackActivity`
- 关联：`00`（§3.4、§4 P4）、`01`（轮询与拉取端点）、`04`（测试与验收）
- PC 端落点：`lib/services/android_read_client.dart`（新增）、
  `lib/services/realtime_sync_engine.dart`（新增）、`lib/core/realtime_sync.dart`（新增）、
  `lib/services/android_bridge_service.dart`（扩展）、`lib/ui/config_pages.dart`（扩展）

---

## 1. 问题陈述

用户实测：

> 现在安卓版自动息屏后就无法访问了

这句话包含**三种完全不同的故障**，必须先分开，否则会去改一个改不动的地方：

| # | 故障 | 现象 | 能否由 PC 修 |
| --- | --- | --- | --- |
| F1 | 安卓的局域网服务**没有运行** | `/device` 连接被拒 | ❌ 只能唤醒或引导 |
| F2 | 服务在运行，但**进程被系统冻结**（Doze / 厂商后台限制） | 连接超时（不是拒绝） | ❌ 只能引导用户改设置 |
| F3 | 服务在运行、进程活着，但 **WiFi 休眠** | 连接超时，唤醒屏幕后立刻恢复 | ⚠️ 部分：唤醒 + 引导 |

**PC 侧能做且必须做的三件事**：

1. **区分** F1/F2/F3（`§4` 的三态判定）；
2. **唤醒**：发一个会 `ManageService.touch()` 的请求（`§5`）；
3. **引导**：把安卓侧已有的 `backgroundGuide` 文案与开关位置呈现给用户（`§5.3`）。

**PC 侧不得做的事**（P4）：静默改安卓系统设置、绕过电池优化、伪造用户操作。

---

## 2. 上游契约（源码级）

### 2.1 服务生命周期

| 事实 | 证据 | 等级 |
| --- | --- | --- |
| `App.startBackgroundServicesNow()` 会 `Server.get().start()` | `App.java` | 源码 |
| 该调用**不带** manage 标志，也**不持有** wake/wifi lock | `Server.start()` 只 `new Nano(i)` + `Proxy.set(i)` | 源码 |
| `Server.stop()` 只在 `manage==false && service==null` 时真正停 | `Server.stop()` | 源码 |
| `ManageService` 是前台服务，`foregroundServiceType=dataSync` + `connectedDevice`，`stopWithTask=false` | `AndroidManifest.xml` | 源码 |
| `ManageService.onCreate` → `Server.get().startManage()` + `acquireLocks()` + `startForegroundCompat` | `ManageService` | 源码 |
| `acquireLocks()` 持有 `PARTIAL_WAKE_LOCK`（`<pkg>:manage`）+ `WIFI_MODE_FULL_HIGH_PERF`（`<pkg>:manage`） | `ManageService` | 源码 |
| `IDLE_TIMEOUT = 600_000L`（10 min），`CHECK_INTERVAL = 15_000L` | `ManageService` | 源码 |
| `checker` 每 15 s 检查：超 10 min 无访问 → `stopSelf()`；否则 `Server.get().startManage()` | `ManageService` | 源码 |
| `ManageService.touch()`：若 `running` 且服务没跑则 `startManage()`；更新 `lastAccess` | `ManageService.touch()` | 源码 |
| `ManageService` 只在用户打开「管理页」时启动 | `ManagePageDialog.showInternal` | 源码 |
| 退出应用时 `AppExitCoordinator` 会 `ManageService.stop(activity)` + `Server.get().shutdown()` | `AppExitCoordinator` | 源码 |
| `HomeActivity.onDestroy` 会 `Server.get().stop()` | `HomeActivity`（mobile + leanback） | 源码 |

> **结论**：`Server` 的存活**不等于** `ManageService` 的存活。
> 只有 `ManageService` 在跑时才有 wake/wifi lock；而它 10 分钟无访问就自杀。
> **PC 的心跳本身就是"访问"**——只要心跳周期 < 10 min，`ManageService` 就不会
> 因空闲超时退出。这是心跳最重要、最容易被忽略的作用。

### 2.2 唤醒端点

| 端点 | 效果 | 证据 |
| --- | --- | --- |
| `GET /manage/session` | 无参数时 `ManageService.touch()`；返回 `running`/`serverRunning`/`lanUrl`/`batteryOptimized`/`backgroundSettingsNeeded`/`backgroundGuided`/`backgroundGuide`/`wakeLock`/`wifiLock`/`lastAccess`/`idleTimeout` | `Manage.doResponse` → `session(params)` |
| `GET /manage/session?stop=1` | `ManageService.stop(App.get())` | 同上 |
| `GET /manage/session?close=1` | `ManageService.closeSoon()`（只记日志） | 同上 |
| `GET /manage/background/settings` | 打开安卓的电池/后台设置页（**会弹系统界面**） | `Manage.backgroundSettings` |

> **注意**：`/manage/session` 的 `touch()` 只在 `ManageService` 已 `running` 时
> 才会 `startManage()`。若服务根本没启动过（用户从没打开过管理页），
> `touch()` 里 `if (!running && !Server.get().isRunning()) return;` 会**直接返回**，
> **不会**拉起服务。这是 F1 无法被 PC 单方面修复的根因。
>
> **PC 侧的正确做法**：把"请打开安卓的「管理页」"作为**可操作指引**给出，
> 而不是反复重试（`§5.3`）。

### 2.3 端口与地址

| 事实 | 证据 | 等级 |
| --- | --- | --- |
| 安卓端口从 9978 顺序探测到 9998 | `Server.start()` | 源码 |
| `Server.getAddress()` 用 `Util.getIp()`（局域网 IP） | `Server.getAddress` | 源码 |
| `/manage/session` 返回 `lanUrl`（局域网）与 `localUrl`（回环） | `ManageService.getLanUrl/getLocalUrl` | 源码 |
| `ScanTask` 扫描：整个 /24 × 端口 9978–9998 × 并发 64 | `ScanTask` | 源码 |
| `ScanTask.start()` 会 `Server.get().start()`（扫描会顺手起服务） | `ScanTask` | 源码 |

> **可利用点**：`ScanTask` 与 `/manage/session` 都会**尝试**拉起服务。
> PC 侧的心跳在探测失败时，可以**顺带**打一次 `/manage/session`——
> 若 `ManageService` 还活着，这一次请求就能把它续命（`touch()`）。
> 这是"唤醒"的**唯一**合法手段。

---

## 3. 心跳设计

### 3.1 目的（三个，缺一不可）

| # | 目的 | 机制 |
| --- | --- | --- |
| H1 | **保活**：让 `ManageService` 的 `lastAccess` 持续刷新，避免 10 min 空闲自杀 | 心跳周期 < 600 s |
| H2 | **可达性判定**：给实时同步提供"现在能不能发请求"的前置结论 | 心跳失败 → 暂停轮询并退避 |
| H3 | **状态采集**：拿到 `batteryOptimized` / `wakeLock` / `wifiLock` / `backgroundSettingsNeeded`，用于诊断与引导 | `/manage/session` 响应字段 |

### 3.2 协议

```text
每 heartbeatSeconds（默认 30 s）：
  1. 若「实时同步」或「心跳」未开启 → 跳过
  2. 若对端地址为空 → 跳过
  3. GET <base>/manage/session   （超时 3 s）
       → 200: 解析 JSON
              running          = 服务是否在跑
              serverRunning    = Server 是否在跑
              wakeLock/wifiLock= 锁是否持有
              batteryOptimized = 是否仍被电池优化限制
              backgroundSettingsNeeded / backgroundGuide
              lastAccess / idleTimeout
              → 心跳成功；记录 lastHeartbeatAt；重置 consecutiveFailures
       → 连接被拒 / 超时 → 见 §4 三态判定
       → 404 → 该安卓版本无 /manage（降级为 GET /device 心跳）
```

**降级链**（必须实现，否则老版本安卓会心跳全红）：

```text
/manage/session  →  /device  →  放弃（标记 keepAliveUnsupported）
```

### 3.3 与轮询的关系

| 心跳结果 | 轮询行为 |
| --- | --- |
| 成功 | 正常按 `intervalSeconds` 轮询 |
| 失败（可恢复） | **暂停轮询**，按 §5 退避；心跳继续（用更短周期尝试唤醒） |
| 失败（403/未授权） | 停止该方向 |
| `running=false` 但 `serverRunning=true` | 仍可轮询（服务在跑），但**必须提示**"管理页未运行，息屏后可能失联" |
| `serverRunning=false` | 暂停轮询，进入唤醒流程（§5） |

**为什么心跳失败要暂停轮询**：轮询会打 N 个站点请求，在不可达时全是超时，
既慢又无意义；而心跳是**一个**轻量请求，用它做"是否值得轮询"的判据成本最低。

### 3.4 周期约束（必须校验）

| 约束 | 值 | 理由 |
| --- | --- | --- |
| 心跳周期下限 | 10 s | 低于此值在移动端是电量事故 |
| 心跳周期上限 | 300 s | 必须 < `ManageService.IDLE_TIMEOUT`（600 s）的一半，留出重试余量 |
| 轮询周期下限 | 15 s | 同上 |
| 轮询周期上限 | 3600 s | 超过 1 h 已不是"实时" |
| 心跳周期 vs 轮询周期 | 心跳 ≤ 轮询 | 否则可达性判定会滞后 |

非法值必须**归一化到最近合法档位**并在 UI 回显（不静默接受）。

---

## 4. 可达性三态判定

这是本设计**最核心**的一段：把一个"连不上"拆成可操作的三态。

```text
探测序列（每次判定最多 3 步，总超时 6 s）：
  S1: GET /manage/session  超时 2 s
        → 200                        ⇒ 状态 = OK（并顺手 touch 保活）
        → 连接被拒（Connection refused） ⇒ 状态 = SERVICE_STOPPED
        → 超时                        ⇒ 进入 S2
  S2: GET /device  超时 2 s
        → 200                        ⇒ 状态 = OK（老版本无 /manage）
        → 连接被拒                    ⇒ 状态 = SERVICE_STOPPED
        → 超时                        ⇒ 进入 S3
  S3: TCP connect 到 <host>:<port>  超时 2 s
        → 成功（但 HTTP 无响应）      ⇒ 状态 = PEER_FROZEN
        → 超时                        ⇒ 状态 = NETWORK_UNREACHABLE
        → 拒绝                        ⇒ 状态 = SERVICE_STOPPED
```

| 状态 | 含义 | 用户文案 | 自动动作 |
| --- | --- | --- | --- |
| `OK` | 可达 | — | 正常轮询 |
| `SERVICE_STOPPED` | 端口无人监听 | 「安卓的局域网服务未运行。请在安卓打开「管理页」后保持它运行」 | 重试 `/manage/session`（可能唤醒）；失败 3 次后停止自动重试 |
| `PEER_FROZEN` | TCP 通但 HTTP 无响应 | 「安卓进程被系统冻结。请在安卓设置中允许本应用后台运行（电池 → 不受限制 / 允许自启动）」+ 原样显示 `backgroundGuide` | 按退避重试；提示用户手动点亮屏幕一次 |
| `NETWORK_UNREACHABLE` | 完全不通 | 「网络不可达：请确认 PC 与安卓在同一局域网，且安卓未切换 WiFi」 | 按退避重试 |

**为什么 TCP connect 能区分 FROZEN 与 UNREACHABLE**：进程被冻结时内核仍在
监听（TCP 握手由内核完成），但用户态线程不调度，HTTP 响应不出来。
网络不通时 TCP 握手本身就失败。这是**唯一**能在 PC 侧区分两者的手段。

### 4.1 判定频率

- 只在**心跳失败**时做三态判定（成功时跳过，省成本）；
- 三态判定结果**缓存 30 s**，避免多个调用点重复探测；
- 状态变化时**记日志 + 通知 UI**（状态从 OK → 非 OK 必须可见）。

---

## 5. 唤醒流程

### 5.1 唤醒阶梯（由轻到重，禁止跳级）

| 级 | 动作 | 触发条件 | 副作用 |
| --- | --- | --- | --- |
| L0 | 什么都不做，等下一次心跳 | 首次失败 | 无 |
| L1 | `GET /manage/session`（会 `touch()`） | 连续 2 次失败 | 无（若服务活着则续命） |
| L2 | `GET /device`（老版本兼容） | L1 失败 | 无 |
| L3 | 提示用户「请在安卓打开管理页」 | L1/L2 都失败 | **仅提示** |
| L4 | 提示用户「请点亮安卓屏幕一次」 | 状态 = `PEER_FROZEN` | **仅提示** |
| L5 | 提供「打开安卓后台设置」按钮 | `backgroundSettingsNeeded=true` | 调用 `/manage/background/settings`（**会弹安卓系统界面**，必须用户点击确认） |

**L5 是唯一会改变安卓侧状态的动作**，因此：

- 必须由**用户点击**触发（不得自动调用）；
- 按钮文案必须写明"将在安卓上打开系统设置页"；
- 调用后必须重新探测并展示结果（不得假定成功）。

### 5.2 退避与恢复

```text
consecutiveFailures:
  1  → 下次心跳按原周期
  2  → 心跳周期 × 2（并执行 L1）
  3  → 心跳周期 × 4
  4  → 心跳周期 × 8（上限 300 s）
  5+ → 停止自动心跳，置 keepAlive* 错误，等用户手动「立即重连」

恢复：任一次心跳成功 → consecutiveFailures = 0，周期回到配置值，
      并立即触发一次轮询（把断线期间的增量补上）。
```

**恢复后必须补一轮**：断线期间的记录在安卓侧仍然存在（`/api/playback/current`
返回的是"最近一条"，不是"新的"），所以补一轮就能拿到最新状态。

### 5.3 用户指引（文案来源必须来自安卓，不得 PC 自造）

`/manage/session` 返回的 `backgroundGuide` 是**安卓侧品牌自适应**的文案
（`ManageService.getBackgroundPowerGuide` 按 vivo/小米/OPPO/华为/三星/魅族分支）。
PC 必须**原样显示**，不得自己写一套——否则用户按 PC 的文案找不到对应菜单。

| 字段 | PC 呈现 |
| --- | --- |
| `batteryOptimized=true` | 「安卓仍受电池优化限制」+ `backgroundGuide` 原文 |
| `backgroundSettingsNeeded=true` | 显示「打开安卓后台设置」按钮（L5） |
| `backgroundGuided=true` | 「用户已处理过后台设置」 |
| `wakeLock=false` | 「安卓未持有唤醒锁（管理页可能未运行）」 |
| `wifiLock=false` | 「安卓未持有 WiFi 锁（息屏后 WiFi 可能休眠）」 |
| `running=false` | 「管理页未运行」+ L3 指引 |
| `idleTimeout` | 「安卓管理页空闲 N 秒后会自动停止，心跳可保持它运行」 |

---

## 6. 实测脚本（实施前必须跑，回答 `00` §9 的 O1/O2/O4）

以下脚本是**设计验证**，不是门禁；结果回填到 `docs/phase7/evidence/`。

### 6.1 O1：息屏后 `/api/playback/current` 是否仍可读

```powershell
# 前置：安卓打开管理页；PC 记下 <base>
$base = 'http://192.168.50.3:9978'
$key  = '<某个已播过的 siteKey>'

# 1) 息屏前
curl.exe "$base/api/playback/current?siteKey=$key" -H "Host: 192.168.50.3:9978" -s -o - -w "`nHTTP %{http_code} time %{time_total}`n"

# 2) 让安卓息屏（adb 模拟）
adb -s 192.168.50.3:5559 shell input keyevent KEYCODE_SLEEP
Start-Sleep -Seconds 60

# 3) 息屏后
curl.exe "$base/api/playback/current?siteKey=$key" -H "Host: 192.168.50.3:9978" -s -o - -w "`nHTTP %{http_code} time %{time_total}`n"
```

**记录**：两次的 HTTP 码与耗时。若第二次超时 → 走 §6.2。

### 6.2 O2：`/manage/session` 能否唤醒

```powershell
# 息屏状态下
curl.exe "$base/manage/session" -H "Host: 192.168.50.3:9978" -s -w "`nHTTP %{http_code} time %{time_total}`n"
# 立刻再打一次 current
curl.exe "$base/api/playback/current?siteKey=$key" -H "Host: 192.168.50.3:9978" -s -o - -w "`nHTTP %{http_code}`n"
```

**判据**：若 `/manage/session` 成功且随后 `current` 成功 → 唤醒有效（L1 可用）。
若 `/manage/session` 也超时 → 进程被冻结（`PEER_FROZEN`），只能 L4。

### 6.3 O4：安卓远端同步源指向 PC

```powershell
# 1) PC 侧：开启「局域网同步服务」+「实时推送」，记下 PC 的 lanUrl
# 2) 安卓侧：观影记录同步 → 远端同步源 → 新增
#    URL = http://<PC-IP>:<PC-port>/api/playback/sync
#    Token = <PC 侧 pullToken>
#    间隔 = 5（分钟）
# 3) 等一个周期，检查 PC 侧日志是否出现 GET /api/playback/sync
# 4) 在 PC 侧制造一条新历史，等下一个周期，检查安卓历史页是否出现
```

**判据**：安卓侧 `RemoteSyncConfig.lastApplied > 0` 且 `lastError` 为空。

---

## 7. 错误分类（新增，与 `01` §8 合并）

| 取值 | 触发 | 自动动作 |
| --- | --- | --- |
| `keepAliveServiceStopped` | 三态判定 = `SERVICE_STOPPED` | L1→L3 |
| `keepAlivePeerFrozen` | 三态判定 = `PEER_FROZEN` | 退避 + L4 |
| `keepAliveNetworkUnreachable` | 三态判定 = `NETWORK_UNREACHABLE` | 退避 |
| `keepAliveUnsupported` | `/manage` 与 `/device` 都 404 | 停止心跳，提示升级安卓端 |
| `keepAliveUnauthorized` | 拉取端点鉴权失败 | 停止该方向 |

---

## 8. 验收要点（详见 `04`）

| # | 要点 | 层 |
| --- | --- | --- |
| 1 | 三态判定：拒绝→STOPPED、TCP 通但 HTTP 超时→FROZEN、TCP 超时→UNREACHABLE | L1 |
| 2 | 退避序列（1/2/4/8×，上限 300 s）与恢复清零 | L1 |
| 3 | 周期归一化（心跳 10–300 s、轮询 15–3600 s、心跳 ≤ 轮询） | L1 |
| 4 | 心跳请求形态（`/manage/session` → `/device` 降级链） | L2 |
| 5 | 心跳成功 → 立即补一轮轮询 | L2 |
| 6 | L5 必须用户点击才调 `/manage/background/settings` | L2 |
| 7 | `backgroundGuide` 原样透传（不得改写） | L2 |
| 8 | 端到端：真实 fixture 的三态模拟 + 恢复 | L3 |
