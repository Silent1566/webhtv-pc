# Win-box 对照与借鉴清单

- 作用：把对 `github.com/yagami-hue/Win-box` 的源码调研，落成**可执行**的借鉴清单——
  每一项都给出「Win-box 怎么做 → 本仓库落在哪个文件 → 优先级 → 前置条件/风险」。
- 性质：以分析为主。§1–§11 的 P0/P1/P2 是 **backlog**，是否实施由产品决策；
  文末 §12.6（方案 A）、§12.8（方案 2）、§12.9（方案 3）已**按产品决策实施**，实施记录与验收在同节内。
- 当前源码状态：**有未提交改动**（`dev1` @ `38a6439` 之上），逐文件清单见 §12.6.6、§12.8.6、§12.9.3、§12.10.3。
- 调研方式：只读 Win-box 公开源码（`raw.githubusercontent.com`）+ 本仓库源码逐行核对；
  未运行 Win-box（它不随仓库分发二进制，见 §1）。
- 基准：本仓库 `dev1` 分支；行号以本文写作时的工作区为准，若源码演进请以符号名检索。

---

## 1. 基线：Win-box 是什么，能借鉴什么、不能借鉴什么

| 项 | 事实 |
| --- | --- |
| 定位 | 把安卓 TVBox（CatVod 引擎）移植到 Windows 的桌面播放器，自述「解析规则与安卓版逐字段一致」；上游致谢 `q215613905/TVBoxOS` |
| 版本/许可 | Win-Box **v1.22.1**，**MIT** |
| 技术栈 | Electron 33 + React 19 + TypeScript 5.6 + Vite 6 + vitest 3 + esbuild；pnpm；electron-builder/NSIS 只发 Windows 安装版 |
| **项目状态** | **已停止更新**。README 明示原因是 Electron 占用高，作者转做新项目 `yagami-hue/Kniephos` |
| 仓库完整性 | **只有核心源码**：JRE、`stubs.jar`、嵌入式 CPython、shell-shim、unidbg、第三方私有蜘蛛 jar、`resources/mpv`、ffmpeg 二进制**均不入库** → 克隆后**不能直接编译运行** |
| 规模 | jsDelivr 列出 756 文件；`src/`+`tests/`+`scripts/` 共 531 个；`tests/` 约 200 个 `*.spec.ts`；无 `docs/` 入库 |

**因此**：Win-box 的价值是**工程经验与设计取舍**，不是可以直接移植的代码。它与本项目技术栈
完全不同（Electron/Node vs Flutter/Dart + 三套 sidecar），且**已停更**——任何借鉴都应当被当作
「别人踩过的坑」而不是「别人验证过的答案」。

### 1.1 一句话结论

Win-box 对本项目最有价值的三件事，按可信度排序：

1. **协议字段的生态真值**（`searchable` 缺省为 1、`type` 口径只有 0/1/3 参与搜索）——
   这是可以直接纠正本仓库行为的事实性缺口，见 §3.1。
2. **全源搜索的预算调度**——把「死源占满超时」从架构上解决，本仓库当前仍是统一 20s，见 §3.2。
3. **本地代理与安卓同端口同路由**——这是 jar 蜘蛛能跑通的前提条件，本仓库当前只有 `/p/` 一类路由，见 §3.3。

---

## 2. 对照总表

优先级定义：**P0** = 真实缺口、改动小、收益直接；**P1** = 结构性收益但需独立设计；
**P2** = 工程纪律与体验细节；**已具备** = 本仓库已有等价实现，不重复造。

| # | 主题 | Win-box 做法 | 本仓库落点 | 结论 |
| --- | --- | --- | --- | --- |
| 1 | `searchable` 缺省值 | `DEFAULT_SEARCHABLE=1` | `core/protocol.dart:452`、`:521` | **P0 借鉴** |
| 2 | 全源搜索预算调度 | `src/engine/vod/searchScheduler.ts` 三档排序 + 单源预算 | `state/app_state.dart:2785-2870` | **P0 借鉴** |
| 3 | 本地代理同安卓路由 | `127.0.0.1:9978` + `/file` `/proxy` `/play` `/img` `/bt` | `services/proxy_server.dart:87`、`:90` | **P0 借鉴** |
| 4 | Spider 常驻进程池 | `src/engine/spider/SpiderProcPool.ts` 分组复用 + LRU + pin | `services/spider_process.dart:798-905` | **P1 借鉴**（同时解锁 P1-6） |
| 5 | 主动单源诊断 | `src/main/spider/SourceDebugger.ts` 探活+解析计数+真跑 | `ui/diagnostics_pages.dart:464`（仅历史成功率） | **P1 借鉴** |
| 6 | 请求伪装阶梯 | `src/engine/util/fetchWithDisguise.ts` 五档 + 换协议 | `core/config_loader.dart:257-308` | **P1 借鉴** |
| 7 | M3U8 启发式去广告 | `src/engine/util/m3u8Purify.ts` 五级 + 三道回退，默认关 | `core/ad_rules.dart:219`（仅规则级） | **P1 借鉴** |
| 8 | 产物缓存版本化 | `CONVERTED_CACHE_VERSION` 逐版记录 | `services/direct_spider_registrar.dart` 无版本概念 | **P2 纪律** |
| 9 | 内容哈希复用索引 | `src/engine/spider/jarContentIndex.ts` 内容 md5 换键复用 | 有 SHA-256 但未做缓存键 | **P2 借鉴** |
| 10 | ext 模板库 | `src/engine/config/extHelper.ts` `EXT_TEMPLATES` | 无（grep 0 命中） | **P2 借鉴** |
| 11 | 订阅 `#line=N` 选线路 | `src/engine/config/multiRepo.ts` 对齐 `SplitLine` | `core/config_parser.dart:77` 支持多仓但无 `#line` | **P2 借鉴** |
| 12 | 特殊播放链接识别 | `src/engine/vod/playLink.ts` 解 `thunder://` 等 | `core/tmdb_title.dart:116` 只认前缀 | **P2 借鉴** |
| 13 | DoH | `src/main/net/DnsResolver.ts` + undici Agent | `core/doh.dart` + `services/doh_resolver.dart` | 已具备 |
| 14 | 出站代理 | `src/main/net/proxy.ts` 全链路一处配置 | `core/outbound_proxy.dart` + `services/outbound_proxy.dart` | 已具备 |
| 15 | 广告主机清单 | `ads` 命中即拦 | `core/ad_rules.dart` `AdRuleSet.isAdHost` | 已具备 |
| 16 | 网盘检测 | 网盘登录/诊断 | `core/pan_check.dart` 五态 + TTL | 已具备（本地更保守） |
| 17 | 片头片尾 | 跳过片头片尾 | `core/skip_segments.dart` | 已具备 |
| 18 | 站点注入 | 自定义 CSP | `core/site_injection.dart` + DB v5 | 已具备 |
| 19 | 健康排序 | 排序用于搜索 | `core/site_order.dart:47-64` | 已具备（但只重排、不预算） |
| 20 | 直连 js/py 注册 | `.js`/`.py` 蜘蛛 | `services/direct_spider_registrar.dart` | 已具备 |
| 21 | dex→jar 全链 | dex2jar + 一堆补丁 | ADR-0002 的 B 方案 | **不做**（见 §7.1） |
| 22 | native 方法检测 | `src/engine/spider/nativeClass.ts` `hasNativeMethods` | 无 | **不做**（依赖 21） |
| 23 | 插件系统 | `src/main/plugin/PluginHost.ts` 十余种 contribute | 无 | **不做**（ABI 不同） |
| 24 | 四套皮肤 / 老板键 / DLNA / BT | — | 无 | **不做**（见 §7.2） |
| 25 | T3 jar 源（含 dex） | dex2jar + 补丁链 | 见 §12 | **不做**（同 21） |

---

## 3. P0：真实缺口，改动小、收益直接

### 3.1 `searchable` 缺省值应为 1（而不是 0）

**Win-box 做法**

`src/shared/constants.ts`：

```ts
export const DEFAULT_SEARCHABLE = 1;
export const DEFAULT_QUICK_SEARCH = 1;
export const DEFAULT_CHANGEABLE = 1;
export const DEFAULT_FILTERABLE = 1;
```

`src/engine/config/SiteParser.ts` 用它做字段缺省：

```ts
searchable: safeJsonInt(o, 'searchable', DEFAULT_SEARCHABLE),
```

配套的判定函数在 `src/engine/vod/aggSearch.ts`：

```ts
export function isSearchableSource(s: Pick<SourceBean, 'type' | 'searchable'>): boolean {
  if (Number(s.searchable) === 0) return false;
  return s.type === 0 || s.type === 1 || s.type === 3;
}
```

语义是 **「非 0 即参与搜索」**，而不是「等于 1 才参与」。注释记录了一个真实的踩坑：
早期实现要求 `searchable === 1`，把生态里大量写 `searchable: 2` 的 drpy 源整体排除了
（上游 `resources/js-lib/模板.js` 里 drpy 源统一写 2，注释即「是否启用全局搜索」；
线上配置 R18.json 有 11 处、19.json/X.json 的 drpy 源普遍写 2），现象是「大部分源搜不出来」。

**本仓库现状（逐行核实）**

`apps/desktop-flutter/lib/core/protocol.dart:45-55` 的 `asFlag` 已经是「非 0 即真」：

```dart
bool asFlag(Object? value, {bool fallback = false}) {
  final number = asInt(value);
  if (number != null) return number != 0;   // 2 → true，与 Win-box 一致
  ...
  return fallback;
}
```

所以 **`searchable: 2` 在本仓库不会丢源**，这一点与 Win-box 的踩坑无关。真正的缺口只有
**字段缺失时的默认值**：

| 位置 | 代码 | 后果 |
| --- | --- | --- |
| `core/protocol.dart:452` | `this.searchable = false,` | 构造默认不可搜 |
| `core/protocol.dart:521` | `searchable: asFlag(map['searchable']),` | 缺字段 → `fallback=false` |

消费点确认影响面：`state/app_state.dart:2803`（`searchAll` 过滤）、`:1383`（`searchScopeGroups`）、
`:2826`（`skippedNotSearchable` 计数）、`state/search_state.dart:116`。

猫源侧已经打过一次补丁——`core/cat_source.dart:165-179`：

```dart
/// 猫源 bundle 的站点通常不写 `searchable` 字段，而 TVBox 生态（含参考实现
/// `Site.searchable == null ? 1 : ...`）按**可搜索**处理。本仓库标准配置路径
/// 对缺失字段默认不可搜索（§8.4），两者语义相反，因此只在猫源整形时补齐：
/// 缺失就写 `1`，站点自己声明的值（包括 `0`）一律保留。
static void _defaultSearchable(Map<String, Object?> object) { ... }
```

**这说明项目已经承认了「本仓库语义与生态相反」，只是把修补限制在猫源 bundle，
`type=3` 蜘蛛源与普通 TVBox 配置仍然走「缺失即不可搜」。**

**建议**：把缺省值统一为 1（与生态一致），或至少在 `type=3` 站点上补齐。
这是**产品语义变更**，不是纯 bug 修复——它会翻转 4 处既有断言：

- `apps/desktop-flutter/test/config_and_site_test.dart:479` `test('未声明 searchable 的站点搜索报 siteUnsupported')`
- `apps/desktop-flutter/test/phase2_search_test.dart:159` `test('未声明 searchable 与运行时不可用的站点被跳过并计数（§8.1）')`
- `apps/desktop-flutter/test/cat_source_test.dart:133-157` `group('searchable 默认值（对齐 TVBox 生态）')`
- `apps/desktop-flutter/integration_test/cat_source_flow_test.dart:95-99`

另有一个次生问题：`core/protocol.dart:552` 序列化写死 `'searchable': searchable ? 1 : 0`，
往返会把 `2` 归一成 `1`（布尔化丢掉原始值）。若要让配置**原样往返**，这个字段应改为
保留原始整数。当前不影响行为（因为 `asFlag` 只看是否为 0），但会影响「导出配置与导入一致」类需求。

### 3.2 全源搜索按源健康度分预算

**Win-box 做法**（`src/engine/vod/searchScheduler.ts`，4350 字节，纯函数 + 可注入 `now`）

三档排序（稳定）：

1. **健康源**（近期成功、无连败）→ 按平均耗时**升序**，最快的先派发；
2. **未知源**（本会话没跑过）→ 保持配置顺序；
3. **近期失败源**（有连败且失败在窗口内）→ 排最后，且只给短预算。

常量与语义（原文核实）：

```ts
export const FAILED_COOLDOWN_MS = 10 * 60 * 1000;   // 窗口外的失败不再降权（源站可能已恢复）
export const FAILED_SOURCE_BUDGET_MS = 3500;        // 死源占用从「一个满源超时」压到 3.5s
export const HIST_BUDGET_FACTOR = 2.5;              // 平时 1s 的源给 3.5s，平时 3s 的给 7.5s
export const EMPTY_SLOW_BUDGET_MS = 6000;           // 上轮空结果的源：不管多慢只给 6s
export const MIN_SOURCE_BUDGET_MS = 1500;           // 低于此值正常源来不及返回
```

`sourceBudgetMs` 的判定顺序：近期失败 → 上轮空结果 → 有平均耗时（`avg × 2.5`，下限 3.5s）→
源声明 timeout；最后夹在 `[MIN_SOURCE_BUDGET_MS, maxMs]`。

注释里记录了**真机数据支撑**：全源搜索的「尾巴」几乎全是「平时 1~3s、偶发卡到 10s」的源；
按历史耗时给预算后这类抖动约 4s 内收手，整轮完成时间从 17s 量级压到 10s 量级，
而本来就慢的源取 `avg × 2.5` 后仍接近上限，不受影响（不误伤）。

另一条关键设计：**排序只影响派发顺序，不影响展示顺序**。SpiderHost 按源索引回填结果，
展示顺序恒等于配置顺序——这与本项目「结果按配置顺序稳定排序」的既有语义完全一致
（见 `state/app_state.dart:2781` 的文档注释），可以直接沿用。

**本仓库现状**

`apps/desktop-flutter/lib/state/app_state.dart:2785-2792` 的签名：

```dart
Future<MultiSiteSearchOutcome> searchAll(
  String keyword, {
  String? siteKey,
  String? group,
  int? maxConcurrency,
  Duration timeout = const Duration(seconds: 20),
  bool quick = false,
}) async
```

- `:2795` `final concurrency = maxConcurrency ?? searchThread;`（`searchThread` 见 `app_state.dart:484`，默认 20，夹 1~100）；
- `:2802-2805` 过滤出「可用 && searchable」的站点；
- `:2807-2815` 健康排序——**只重排顺序**，不改变任何单源预算；
- `:2856-2870` worker 池逐个取站，统一 `await service.search(...).timeout(timeout)`。

结论：**一个死源仍然占满 20s 槽位**。健康排序（P1-3，`core/site_order.dart`）解决的是
「先搜谁」，没有解决「搜多久」。

**建议落点**

- 新增 `apps/desktop-flutter/lib/core/search_scheduler.dart`，纯函数、可注入 `now`，
  风格对齐 `core/site_order.dart:47-64`（同样的 `keys + enabled + scores` 形态，便于单测）。
- 输入数据本仓库已有：`state/app_state.dart:1084` 的 `siteHealthScores()`（成功率），
  `services/storage.dart:181-225` 的 `SiteHealth` 含 `avgLatencyMs`、`lastError`、`updatedAt`
  ——足够算出「平均耗时」与「近期失败」，**不需要新建表**。
- 缺的是 `failStreak` / `emptyStreak` 两个连续计数：`SiteHealth` 目前只有累计 ok/total。
  两个选项：(a) 加两列（DB 迁移）；(b) 先用「最近一次 `lastError` + `updatedAt` 在窗口内」近似。
  建议 (b) 先落地，验证收益后再决定是否加列。
- `searchAll` 接线：把统一 `timeout` 换成「按 key 取预算」，其余逻辑不变。

### 3.3 本地代理补「与安卓同端口同路由」

**Win-box 做法**（`src/main/server/LocalProxyServer.ts` 文件头注释，原文）

```
127.0.0.1:9978 本地代理 —— 与安卓同端口同路由。
路由 /proxy?do=live&type=txt&ext=<base64urlsafe> —— 解 ext 得真实订阅 URL，抓取返回原文。
路由 /play?url=<encoded>&ua=<encoded>&referer=<encoded> —— header 注入中继。
路由 /file/<path> —— 等效安卓 TVBox 的 Local 蜘蛛：按路径提供本地文件。
```

`/file` 为什么必须存在（原文）：

> 部分 jar 蜘蛛的 ext 直接写成 `http://127.0.0.1:9978/file/<子路径>`
> （如 KungFu404 的 token 文件、PushAgent 系蜘蛛推送的图片）；安卓侧由内置
> Local 蜘蛛从 assets/数据目录读出。桌面版必须实现同名路由，否则这些蜘蛛
> 拿到 404 → 初始化失败 → 分类/首页空白。

配套常量在 `src/shared/constants.ts`：`LOCAL_PROXY_HOST='127.0.0.1'`、`LOCAL_PROXY_PORT=9978`、
`LIVE_PROXY_ROUTE`、`SUPER_PARSE_URL='http://127.0.0.1:9978/jiexi?url='`。

**本仓库现状**

`apps/desktop-flutter/lib/services/proxy_server.dart`：

| 位置 | 代码 | 说明 |
| --- | --- | --- |
| `:87` | `static const String pathPrefix = '/p/';` | 唯一路由命名空间 |
| `:90` | `Future<void> start({int port = 0, String host = '127.0.0.1'})` | **端口默认随机** |
| `:124-128` | `urlFor` / `encodeTarget` | `/p/<sessionToken>/<encodedTarget>` |
| `:75` | `maxConcurrentRequests = 32` | 并发上限 |

**没有** `/file`、`/proxy`、`/play`、`/img`、`/bt` 任何一类。
端口随机这一点尤其关键：jar 蜘蛛的 ext 里硬编码 `127.0.0.1:9978` 时，本仓库的随机端口
拿不到文件。

注意本项目另有**同步服务**绑定 `0.0.0.0`、端口从 `9978` 顺序探测到 `9998`
（`services/sync_server.dart:137` `this.startPort = androidDefaultPort`、`:139` `bindAddress = '0.0.0.0'`；
`core/android_bridge.dart:26` `const int androidDefaultPort = 9978;`）。
**9978 已被同步服务占用**——所以本地代理若也要 9978，必须先解决端口归属（见风险）。

**建议落点**

- 保持 `/p/<token>/` 为**主路由**，安全边界（token 化、只监听回环）不变；
- **新增兼容路由命名空间**（`/file`、`/play`、`/proxy`、`/img`），全部复用既有 `_forward` 管道；
- `/file` 只暴露**站点工作目录下的显式白名单路径**，禁止路径穿越（`normalize` 后必须仍在根内）；
- 端口策略二选一：
  (a) 本地代理优先绑定 9978，同步服务让位；
  (b) 两者共用同一个 HTTP server（路由前缀区分）。
  (b) 更稳，但改动更大。**建议先做 (a) + 明确文档**，因为 jar 蜘蛛的硬编码无法协商。

**风险**：这是本次清单里唯一会扩大本地攻击面的改动。`/file` 必须与「进程隔离」约束
（PRODUCT.md）一致：只服务 sidecar 工作目录，不接受任意绝对路径。

---

## 4. P1：结构性收益，需要独立设计

### 4.1 Spider 常驻进程池（并顺带解锁 P1-6 CSP 预热）

**Win-box 做法**（`src/engine/spider/SpiderProcPool.ts`，v3）

- **分组复用**：按固定 argv 前缀（exe + serve 头 + classpath/env 差异段）分组，
  同组进程常驻复用；
- **单进程多并发**：`MAX_INFLIGHT_PER_PROC`，JVM 侧 24 线程池。理由是蜘蛛调用绝大多数时间在等网络
  → 一个热 JVM 能跑完整轮 33 源并发搜索，不必多开 6 个 JVM（冷启动 ×N + 内存 ×N + 杀软扫描 ×N
  正是「进源慢、搜索更慢」的根因）；
- **全局上限内存自适应**：`effectiveGlobalCap()`——空闲内存 > 1.5GB 用 4，否则 3
  （实测常驻 serve JVM ≈84MB、py 蜘蛛 ≈35MB）；
- **LRU 回收而非拒绝**：超限时回收最久空闲进程；
- **播放中 pin**：本地代理正在服务播放时钉住该 JVM，LRU 与空闲回收都跳过，否则播放中段断流；
- **失败分层**：`PoolFailReason = 'timeout'|'queue-timeout'|'exit'|'spawn-error'|'stdin'|'lru'|'idle'|'dispose'`。
  `ok=false` 仅表示进程/传输层失败；`ok=true + data=''` 是合法空结果。
  **蜘蛛自报错误（`env.ok=false`）必须与传输层失败分离**——旧实现把它当正常输出返回，
  导致「某源报出上一请求遗留的陈旧原因」。

**本仓库现状**（`apps/desktop-flutter/lib/services/spider_process.dart`）

- `:798` `ensureRunning`；`:807` `if (runtime.host != null) return runtime.host!;`
  ——**一站点一进程**，没有跨站点复用；
- `:851-854` 每次 `ensureRunning` 新建工作目录 `$siteKey-${microsecondsSinceEpoch}`；
- `:781-783` 默认 `maxFailures = 5`、`baseBackoff = 1s`、`maxBackoff = 60s`；
  超限进 `disabled`，需人工重新启用（`:809-816`）。

**关键判断**：`sidecars/spider-host-jvm/src/webhtv/spider/SidecarServer.java` 已经具备
进程内并发能力（`:44` `ExecutorService pool`、`:45` `Semaphore concurrency`、
`:87-88` `new Semaphore(concurrencyLimit)` / `Executors.newFixedThreadPool(...)`），
**缺的只是「跨请求复用同一进程」的池化层**，以及播放期 pin。

**顺带解锁 P1-6**：`docs/phase9/README.md:242` 现在把「CSP 预热」标为
**「暂缓（避免假功能）」**，理由是「PC 的 `csp_*` 走按次启动的 JVM sidecar，没有常驻进程池；
现有 API 只能『启动后立刻结束』，无法产生可观测预热收益」。**做成本项后，这条暂缓理由自然消失。**

### 4.2 主动单源诊断

**Win-box 做法**（`src/main/spider/SourceDebugger.ts`）

对单个源做三件事：**探活（HTTP）→ 解析计数 → 实际跑一遍 spider**，输出人读结论，
用于区分「源站失效 / 接口结构变化 / 缺 ext / 需要 ac 参数」——针对的是「空结果」这个
最常见也最难归因的现象。

**本仓库现状**

`apps/desktop-flutter/lib/ui/diagnostics_pages.dart:464` 的 `SiteHealthPage` 是
**历史成功率统计**（站点 / 首页 / 分类 / 详情 / 播放 / 平均耗时 / 最近错误），
**必须先被调用过才有数据**。它回答「这个源过去好不好用」，不回答「这个源现在为什么空」。

两者**互补而非重复**，建议保留 SiteHealthPage 并新增主动诊断入口。

**建议落点**：`apps/desktop-flutter/lib/services/source_debugger.dart`（新），
复用 `core/parse_failover.dart` 的解析链与 `services/spider_router.dart` 的运行时探活，
输出结构化结论（`ok` / `siteDead` / `structureChanged` / `needsExt` / `needsAc`）。

### 4.3 请求伪装阶梯

**Win-box 做法**（`src/engine/util/fetchWithDisguise.ts`，383 行）

阶梯（原文 `disguiseLadder`）：

```ts
/** 实测有效的 TVBox 客户端 UA（不要臆造其它 UA：这是唯一被验证过能过 UA 分流的） */
export const UA_OKHTTP = 'okhttp/3.12.0';
```

- 常规：`默认 UA → okhttp UA → okhttp+Referer → okhttp+Referer+Cookie → okhttp+DoH`；
- `quick`（多仓扫描）：只 `默认 UA → okhttp UA`（上千子仓不能每项跑 5 档）；
- 全失败后**自动换协议**（http↔https）同路径再试；
- 每次尝试回报响应特征（HTTP 码 / 体积 / 内容类型嗅探 / 前 80 字），用于「为什么导入不了」分档上屏。

注释记录了两类实测限制：①按 UA 分流（浏览器 UA 给落地页/广告页，okhttp UA 才给真内容）；
②DNS 污染。

**本仓库现状**（`apps/desktop-flutter/lib/core/config_loader.dart:257-308` 的 `_once`）

只有：`basicAuthHeader(uri)` 解 userinfo、`Accept: */*`、`request.followRedirects = false`、
异常映射到 `AppError(configNetwork, retryable)`。
**无 UA 回退、无 Referer、无 Cookie 预种、无 DoH 回退、无换协议重试。**

**建议落点**：`apps/desktop-flutter/lib/core/fetch_disguise.dart`（新，纯策略可单测），
由 `ConfigLoader` 与 `core/cat_http.dart` 共用。**注意**：本项目已有 DoH
（`core/doh.dart` + `services/doh_resolver.dart`），阶梯里的 DoH 档应复用而不是新写。

**风险**：伪装阶梯会显著增加导入耗时（最坏 5 档 × 超时）。必须像 Win-box 一样提供
`quick` 短路，且只在**导入/诊断**路径启用，不进入播放路径。

### 4.4 M3U8 启发式去广告（五级链）

**Win-box 做法**（`src/engine/util/m3u8Purify.ts`，34882 字符；移植 TVBox `util/M3u8.java` 的 `purify()`）

五级流程（原文编号）：

1. `removeMinorityUrl`：按「切片路径前缀」或「域名」统计主导者，删少数派；
2. `clean`：用订阅 `rules[].regex` 里带 `DISCONTINUITY`/`EXTINF` 的规则整段删；
3. `cleanCommonAdMarkers`：删 SCTE-35 / CUE-OUT~CUE-IN / DATERANGE 广告块与 URL/域名特征段；
4. `cleanDecimalPrecisionGroups` 与 `cleanFrameRateGroups`：按 `EXTINF` 小数精度/帧率特征删短不连续块；
5. `cleanDiscontinuityGroups`：删非主导短组。

**三道回退保护**（任一触发就放弃本次清洗、回原文并把计数归零）：

- 单级删除超过总段数 **30%** → 该级作废；
- 累计删除超过总段数 **50%** → 整体回退；
- 洗完不满足 `isPlayableMediaPlaylist`（须有段、不得连续两个 `EXTINF`、不得 `EXTINF` 紧跟 `ENDLIST`）→ 整体回退。

开关语义照抄 TVBox：`HawkConfig.M3U8_PURIFY` **默认 false**。调用口径：**只有 `removed > 0` 才用清洗结果**。

**本仓库现状**

`apps/desktop-flutter/lib/core/ad_rules.dart:219` 的 `cleanHlsPlaylist` 只有**规则驱动的一级**
（`HlsAdRule` 的 hosts/regex/duration/discontinuity/crossDomain 信号 + `minimumSignals`），
且四条安全约束已经就位（文件头 `:10-15`）：

1. 规则为空 → 原样返回，绝不做启发式猜测；
2. 规则不匹配清单主机 → 整条规则不生效；
3. 只删分片与其分片级标签，`#EXT-X-KEY`/`#EXT-X-MAP` 保留；
4. 删完无变化 → 返回原文。

**建议落点**：`apps/desktop-flutter/lib/core/m3u8_purify.dart`（新，独立于 `apps/desktop-flutter/lib/core/ad_rules.dart`），
**默认关闭**，与现有规则清洗**串联**（规则级优先，启发式兜底），并复用 `HlsCleanResult`
的 `changed` 语义。三道回退保护必须一并移植——这是这个功能唯一的安全阀。

**风险**：启发式清洗**天然会误删**。若不默认关闭，会把「用户没开广告过滤却少了一段正片」
变成默认体验。Win-box 的默认关是刻意设计，必须照抄。

---

## 5. P2：工程纪律与体验细节

### 5.1 产物缓存版本化（纪律，不是功能）

Win-box `src/engine/spider/JarSpiderBridge.ts` 导出 `CONVERTED_CACHE_VERSION = 5`，注释**逐版本记录产物格式变更史**
（v1 只写 dex2jar 输出丢了 assets；v2 补齐 raw jar 非 dex 资源；v3 修 super 调用被转成自递归
`invokespecial` 导致 `StackOverflowError`；v4 普通 JAR 也执行 `DexJarRepair`；v5 补 `Proxy` stub），
规则是「**改变了产物内容就必须 +1**」。

本仓库 `services/direct_spider_registrar.dart` 用 SHA-256 去重（`:76`、`:98`、`:106`），
但**没有「产物格式版本」概念**——一旦生成逻辑变化，旧产物不会失效。
**建议**：把这条纪律写进设计文档，并在任何「派生文件」缓存上加版本号。

### 5.2 内容哈希复用索引

Win-box `src/engine/spider/jarContentIndex.ts`：`doConvert()` 的缓存键是 **jar URL 的 md5**，换域名/文件名/加查询参数
即未命中 → 重下载 + 重转换（大 jar 实测 20s~3min），哪怕内容一字节未变。
做法是下载后算**内容 md5**（4MB 量级 <10ms），命中即把已有产物 link 成新键产物。
纪律：索引任何失败都不得影响转换主流程。

本仓库的 `csp_*` jar 缓存可借鉴同一思路（当前按 URL/路径缓存）。

### 5.3 ext 模板库

Win-box `src/engine/config/extHelper.ts` 的 `EXT_TEMPLATES`：通用站点配置 / 海阔多线路 XYQHiker `{url,list,group,rule}` /
采集站 XPath 规则 / 独立资源库路径 / 网盘登录配置。
本仓库 **grep 0 命中**（`EXT_TEMPLATES|extTemplates|ext模板`）。这是「降低用户配置门槛」的
纯增量功能，与 PRODUCT.md 的「不内置站点配置」不冲突——模板是**空结构**，不含任何资源。

### 5.4 订阅 `#line=N` 选线路

Win-box `src/engine/config/multiRepo.ts` 识别多仓 `{urls:[{url,name}]}` 并支持订阅地址尾部 `#line=N` 选线路
（对齐 `TvBoxSubscriptionManager.SplitLine`）。

本仓库 `core/config_parser.dart:77` `_parseRepositoryEntries(map['urls'], ...)` 已支持多仓，
`:147` 还有「urls 使用纯字符串条目已弃用」的提示，但**没有 `#line`**。

### 5.5 特殊播放链接识别

Win-box `src/engine/vod/playLink.ts` 识别 `thunder://`（`base64('AA'+内层+'ZZ')`）/ `magnet` / `ed2k` / `ftp` / `rtmp`；
能解成 http(s) 的继续走原链路，无载体的给 `unsupported` + 人话原因 + 交外部工具。

本仓库 `core/tmdb_title.dart:116` 的正则 `^(?:https?|rtsp|rtmp|mms|magnet|ed2k|thunder|video|file):\S+$`
**只认前缀**，不解析内容——`thunder://` 链接会被当作普通 URL 交给播放器，必然失败。

---

## 6. 已具备：不要重复造

| 能力 | 本仓库实现 | 与 Win-box 的差异 |
| --- | --- | --- |
| DoH | `core/doh.dart`（RFC 8484 编解码）+ `services/doh_resolver.dart`（TTL 缓存、磁盘缓存、失败回落、多端点） | 本地**只作用于出站请求，不进播放代理**；Win-box 的 `/img` 也走 DoH |
| 出站代理 | `core/outbound_proxy.dart` + `services/outbound_proxy.dart`（`IOClient` 工厂、域名规则、默认关） | Win-box 把代理注入到 JVM `-Dhttp(s).proxyHost` 与 Python `HTTP_PROXY`；本仓库需确认 sidecar 是否同样透传 |
| 广告主机清单 | `core/ad_rules.dart` `AdRuleSet.isAdHost`（相等或子域） | 等价 |
| 网盘检测 | `core/pan_check.dart`（6 类识别、五态判定、TTL） | 本地**明确不做私有 API 逆向**，判不出即 `uncertain`——比 Win-box 保守，是刻意的 |
| 片头片尾 | `core/skip_segments.dart` + DB v4 `skip_segments` 表 | 等价 |
| 站点注入 | `core/site_injection.dart` + DB v5 `injected_sites` + 管理页 | 等价（Win-box 走 `CustomCspSetting`） |
| 健康排序 | `core/site_order.dart:47-64` `orderSiteKeysByHealth` | **只重排、不预算**（见 §3.2） |
| 直连 js/py | `services/direct_spider_registrar.dart`（2 MiB 上限、20s 超时、SHA-256 去重） | 等价 |

---

## 7. 明确不借鉴

### 7.1 dex→jar 全链（最重要的一条）

Win-box 的 `csp_*` 路线 = 下载含 `classes.dex` 的 jar → `dex2jar` → JVM 反射调用。
这正是本项目 `docs/adr/0002-android-csp-jar-compat.md` 判为**不可行**的 B 方案。

但 Win-box 把它**做成了产品能力**，代价是一整套长期维护的补丁：

| 补丁 | 解决的问题 |
| --- | --- |
| `src/engine/spider/classFix.ts` | super 调用被转成自递归 `invokespecial` → `StackOverflowError` |
| `DexJarRepair`（见 `src/engine/spider/JarSpiderBridge.ts` 注释 v4） | 恢复被 dex2jar 误译的 `NEW` 类型及缺失构造器 |
| `src/engine/spider/appProxyStub.ts` | 补 `com.github.catvod.spider.Proxy.getProxyUrlDo` 否则 `NoSuchMethodError` |
| `okhttp4Compat` | 兼容 okhttp4 的调用形态 |
| `prefsShim` | 无 Android Context 的 `SharedPreferences` 垫片 |
| `shell-shim` | 影子类插到 classpath 最前 |
| `src/engine/spider/nativeClass.ts` | 检测含 `native` 方法的 class，**如实拒绝** |
| `CONVERTED_CACHE_VERSION` | 产物格式每次变化就作废重转 |

**结论**：ADR-0002 说「B 方案不可行」在**工程上被反例挑战**——可行，但需要长期维护一堆
dex 转译补丁，且含 native 方法的 jar 必须如实拒绝。本项目的选择（维持 D 方案
「桌面 JVM ABI」+ 预留 E/A1/A2 兼容层，N1「Android dex/JAR」不迁移）**依然成立**，
理由是**维护成本与用户规模不匹配**，不是「技术上做不到」。

建议把这段作为附录写进 ADR-0002（见 §8），**不改变 ADR 状态**。

### 7.2 其余不借鉴项

| 项 | 不借鉴理由 |
| --- | --- |
| `src/engine/spider/nativeClass.ts` `hasNativeMethods` | 它服务于 dex→jar 路线（判断 jar 是否必须拒绝）；本项目不做该路线，无使用场景 |
| 插件系统（`src/main/plugin/PluginHost.ts`，十余种 contribute） | Win-box 插件是 Electron/JS 生态的产物；本项目 ABI 是 `tvbox-java-v1`/`tvbox-js-v1`/`webhtv-cat-http-v1`，语义不同，且引入插件系统会扩大攻击面 |
| 四套皮肤 / 界面缩放 / 老板键 | 纯产品偏好，与协议兼容层无关 |
| DLNA 投屏 / 远程遥控 | 对应本项目 P3-7，属未迁移项，不是「借鉴 Win-box 就能做」 |
| 磁力 BT 边下边播 | 对应 P3 未迁移项；且涉及版权风险边界，PRODUCT.md 明确不做资源相关功能 |
| Electron 技术栈本身 | 作者本人因「Electron 占用高」停更并换框架——这本身就是对本项目 Flutter 路线的一次反向验证 |

---

## 8. 与 ADR-0002 的冲突澄清（建议追加为附录）

`docs/adr/0002-android-csp-jar-compat.md` 目前 §6「后果」结尾是：

> **负面**：兼容层不是零成本——主要成本在自建桥接 APK；且受 ARM 转译与冷启动限制，
> 不能承诺「全部 Android jar 可用」。

建议在其后追加 `## 7. 附录：外部实践复核（Win-Box）`，内容为 §7.1 的补丁表 + 结论：

- B 方案（dex→jar）在 Win-box 被做成了产品能力，**因此「不可行」的表述应修正为「代价高」**；
- 但 Win-box 为此维护了 8 类补丁与一个产物版本号，且**已停止更新**；
- 本项目维持不采纳，理由是维护成本/用户规模不匹配，而非技术不可行；
- 对外口径不变：**「支持 WebHTV / TVBox / 猫源配置协议和 Spider 运行时；单个站源能否使用，
  以实际测试通过为准」，不得表述为「支持全部 TVBox 或猫源」。**

---

## 9. 警示项（别人的坑，别踩第二遍）

1. **Electron 的内存代价是真实的。** Win-box README 自述「内存几百 MB 属 Chromium 四进程固有开销（~300MB）」，
   并因占用高而停更。本项目用 Flutter + media_kit，已规避该问题——这是**不要**回退到 WebView 方案的理由之一
   （`pubspec.yaml` 注释已记「P3-1 未做」）。
2. **首次进 jar/py 源可能极慢。** Win-box 自述「自动重试最长近 200 秒，约 5 分钟内出内容」。
   本项目的 spider 初始化同样有冷启动，**必须给出可见的进度/等待文案**，否则用户会判定「坏了」。
3. **弹幕要并行拉整季并限同集。** Win-box 把超时放宽到 40s 并并行拉整季、同集限定、
   识别不出集号时**明确标注**。本仓库 `core/danmaku_match.dart` 已做匹配，建议核对是否同样并行与标注。
4. **蜘蛛自报错误 ≠ 传输层失败。** 这是 `SpiderProcPool` 注释里记录的真实 bug：
   把 `env.ok=false` 当正常输出返回，导致「某源报出上一请求遗留的陈旧原因」。做池化时**必须**分层。
5. **GPU 进程崩溃后要能续播。** Win-box 的做法是「自动重载最后播放窗口并续播」；
   本项目 `core/session_recovery.dart` 已有恢复机制，建议核对是否覆盖「播放中崩溃」这一具体场景。

---

## 10. 建议的落地顺序

| 顺序 | 项 | 理由 | 预估 |
| --- | --- | --- | --- |
| 1 | §3.2 搜索预算调度 | 纯前端逻辑、无协议风险、收益立刻可见（全源搜索变快） | 小 |
| 2 | §3.1 `searchable` 缺省值 | 一行改动 + 4 处断言，但**需要产品决策** | 小（决策成本大） |
| 3 | §3.3 代理兼容路由 | 解锁 jar 蜘蛛，但要先解决 9978 端口归属 | 中 |
| 4 | §4.1 进程池 | 收益最大但改动最深；同时解锁 P1-6 CSP 预热 | 大 |
| 5 | §4.2 主动诊断 | 依赖 4 的池化才能覆盖全运行时 | 中 |
| 6 | §4.3 / §4.4 | 独立纯逻辑模块，可并行 | 中 |
| 7 | §5.x | 随时可插入 | 小 |
| 8 | §12.8 方案 2（CatVod 方言 Python 站源） | **已实施**（2026-10-24）：解锁 82 个 `csp_PyProxy` 站点；不改 ABI、不做 dex2jar | 中 |
| 9 | §12.9 方案 3（程序自动完成能自动的迁移） | **已实施**（2026-10-24）：修「列表可用但调用报不可用」的真 bug；配置声明的 jar 自动取回 + 静态检测 + 结论回显 | 中 |
| 10 | §12.10 Python 解释器解析验证 | **已实施**（2026-10-24）：方案 3 暴露的既有缺陷，`py.exe` launcher 转发失败不再被当成「sidecar 崩溃」 | 小 |

**注意**：第 2 项与第 1 项**不应合并**——前者是语义变更（需要产品拍板），后者是性能优化（可以直接做）。

---

## 11. 验证记录（本文写作时实测）

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 本文引用的本地路径存在 | 脚本遍历反引号内的路径 token 并 `fs.access` | 45 条本地引用**全部存在**（4 条为本文建议的**新增文件**，尚不存在，属预期） |
| 本文引用的 Win-box 路径存在 | 逐条 `raw.githubusercontent.com/yagami-hue/Win-box/main/<path>` | 20 条**全部命中**（`playLink.ts` 实际位于 `src/engine/vod/`，非 `src/engine/config/`） |
| 未修改源码 | `git diff --stat HEAD -- apps/desktop-flutter docs/phase9 tools` | **空**（本次只新增 `docs/reference/`） |
| 源码与既有阶段文档零改动（§12 追加后复测） | `git diff --numstat HEAD -- apps sidecars packages tools docs/phase9` | **0 行**（`git status --porcelain` 仅 `?? .superpowers/` 与 `?? docs/reference/`） |
| §12 引用的本地路径存在且行号在范围内 | 脚本提取反引号内 `apps/…`、`sidecars/…`、`packages/…`、`docs/…` token，按 `:` 后的行号校验文件总行数 | **25 条全部命中**；6 条为 §12.6 建议的**新增文件**（`jar_intake.dart` 等，尚不存在，属预期）；**0 条失效** |
| §1–§12 引用的 Win-box 路径存在（复测） | 逐条 HEAD `raw.githubusercontent.com/yagami-hue/Win-box/main/<path>` | **21 条全部 200**（含 `playLink.ts` 的 `src/engine/vod/` 正确位置） |
| 差距矩阵门禁 | `python tools/phase9/verify_gap_matrix.py` | G9.1–G9.5 **全部 PASS**（G9.3 的 `DialogSafeArea` 已补入上游映射表，见下） |
| 方案 A 落地后的静态分析（§12.6） | `flutter analyze`（`C:\dev\flutter` 3.47.5 / Dart 3.13.4） | **`No issues found!`** |
| 方案 A 的新增与受影响测试（§12.6） | `flutter test test/jar_intake_test.dart` / `test/phase3_jvm_spider_test.dart` | **17 passed** / **18 passed**，均 0 失败 |
| 方案 A 的全量回归（§12.6） | `flutter test` | 2765 passed / 10 failed，10 个失败经 `git stash` 对照确认**与本改动无关**（详见 §12.7.2） |
| 方案 2 的静态分析与定向测试（§12.8） | `dart analyze` / `flutter test test/phase9_catvod_spider_test.dart` / 四文件联合回归 | **No issues found!** / **5 passed** / **49 passed** |
| 方案 2 的全量回归（§12.8） | `flutter test` | **2774 passed / 10 failed**；失败集与方案 A 基线**完全一致**（9 个 `test/phase2_ipc_test.dart` + 1 个 `test/phase2_spider_page_test.dart`，均属本机 `py.exe` 环境问题） |
| 方案 2 的真实配置端到端（§12.8.7） | 用真实 AT 配置（82 个 `csp_PyProxy`）驱动 `sidecars/spider-host-python/host.py` | `home` 7 分类 / `category` 20 条真实 TMDB 数据 / `search` 如实报 `SPIDER_UNSUPPORTED`；退出码 **0**（20 连跑皆 0） |
| 方案 3 的静态分析（§12.9） | `dart analyze` | **`No issues found!`** |
| 方案 3 的新增与受影响测试（§12.9） | `flutter test test/csp_jar_probe_test.dart`（12 例）／再与 jar_intake / phase9_direct / phase9_catvod / phase3_jvm / phase2_spider_page / phase5_category_filter / config_and_site 联合 | **12 passed**；联合 **127 passed / 1 failed**，唯一失败是既有的 `phase2_spider_page_test.dart`「真实 sidecar 启动」用例（本机 `C:/Windows/py.exe -3` 指向已删除路径，与本文改动无关） |
| 方案 3 的全量回归（§12.9） | `flutter test`（15 分 44 秒） | **2784 passed / 11 failed**：10 个与方案 A / 方案 2 基线**完全一致**（9 个 `phase2_ipc_test.dart` + 1 个 `phase2_spider_page_test.dart`，本机 `py.exe` 环境问题）；第 11 个是 `phase9_doh_test.dart`「磁盘缓存可跨实例复用」——**该文件本次未改动**，单跑 3 次里 1 次失败 2 次通过，属既有偶发（磁盘缓存写入与读取的时序），与本次改动无关 |
| §12.10 Python 解释器解析修复 | `dart analyze` | **`No issues found!`** |
| §12.10 修复后重跑此前稳定失败的用例 | `flutter test test/phase2_ipc_test.dart test/phase2_spider_page_test.dart` | **All tests passed!（39 passed）** —— 此前 10 个稳定失败**全部转绿** |
| §12.10 新增回归用例 | `flutter test test/phase9_python_runtime_test.dart` | **6 passed** |
| §12.10 修复后的全量回归 | `flutter test`（22 分 10 秒） | **2802 passed / 0 failed**（同改动前一次运行是 2796 passed / 6 failed，那 6 个是并行负载下的偶发：`phase3_jvm_spider_test.dart` 5 个 + `windows_job_test.dart`「terminate() 立即终止作业内进程」；三个文件单独重跑 54 passed，第二次全量亦全绿） |

**关于曾出现的 G9.3 失败**：本文首版写作时该项为 FAIL——原因是**既有基线漂移**，与本文无关：
安卓基准仓库 `F:/Workspace/webtv2/webhtv` 已推进到 `dcf9828cba61`（`docs/phase9/README.md` 记录的是
`77e2fbefdc`），新增了 `ui/dialog/DialogSafeArea.java`，而 `docs/phase9/design/05-upstream-map.md` 尚未收录。

该漂移已**独立修掉**（记为一次与本文无关的小修）：在 `design/05-upstream-map.md` 的「对话框」表补入
`DialogSafeArea | N/A（平台无关）` 一行并注明 Flutter 侧由 `SafeArea`/`MediaQuery` 承担，同时在
`docs/phase9/README.md` 的基准行附加漂移备注（历史证据文件按原样保留，不回填）。
现状：`verify_gap_matrix.py` **全绿（exit=0）**。

**未执行的检查（本文首版时）**：`flutter analyze` / `flutter test` 未运行——当时环境 PATH 中无 `flutter`/`dart`
（`flutter --version` 退出码 127）。由于本文首版**零源码改动**，其结果不可能因本文变化。

> **2026-10-24 补充**：本机已安装与 CI 同版本的 Flutter 3.47.5 / Dart 3.13.4（`C:\dev\flutter`），
> 上表的 analyze / test 已实际执行。注意运行前**不要设 `PUB_HOSTED_URL`**——用镜像会让
> `pubspec.lock` 被改写并连带升级 91 个依赖（实测 131/131 行 diff）。

> §12 追加后按同口径复测：本地引用 25/25 命中、Win-box 引用 21/21 命中、源码 diff 为 0 行、
> 门禁结果与上表一致（仍为 G9.3 的 1 项既有基线漂移，与本文无关）。

---

## 12. 补充调研：T3 源兼容性结论（2026-10 追加）

本节回答「Win-box 是否实现了 TVBox 接口全兼容 / 能否直接用 T3 爬虫源」，是对 §1、§7.1 的细化。
**结论：Win-box 没有做「全兼容」，它做的是字段级 + 运行时级的高覆盖移植。**

### 12.1 「T3 源」是什么

社区把 `type=3` 的蜘蛛源叫「T3 源」，其 `api` 有三种形态：`csp_<类名>` + `jar`（Java 蜘蛛）、
直连 `*.js`（drpy 风格）、直连 `*.py`（猫源 Python）。
**「T3」指的不是 type 编号本身，而是这一族需要运行时的源。**

### 12.2 Win-box 的实际覆盖（源码核实）

| api 形态 | Win-box 行为 | 依据 |
| --- | --- | --- |
| `csp_*` + 含 dex 的 jar | **可用**：下载 → 抽出 `classes.dex` → dex2jar → JVM 反射调用；首次最长约 200 秒 | `src/engine/spider/JarSpiderBridge.ts` |
| `csp_*` + 无 dex 的 jar | 同上（普通 JAR 也过 `DexJarRepair`） | 同上（`CONVERTED_CACHE_VERSION=5` 注释 v4） |
| `api` 以 `.js` 结尾 / 含 `.js?` | **可用**：`node:vm` 沙箱，支持 drpy | `src/engine/spider/SpiderFactory.ts` |
| `api` 含 `.py` | **可用**：嵌入式 CPython | 同上 |
| `type=2` / 未知 | `SpiderNull`，不参与 | `src/engine/config/SiteParser.ts` |
| `type=-1` | `DEGRADE`（`UNSUPPORTED_PUSH`） | 同上 |
| `type=0/1/4` | 不走 `getCSP`，由 CMS 路径内联处理 | 同上 |

但 README 自列的排除项说明这不是「全兼容」：自述「少数源依赖站点专有加密，属**无解源**」；
含 ARM `.so` 的加固壳需现场下载约 39MB 的 unidbg 运行期，缺省则抛 `UnsatisfiedLinkError`；
含 `native` 方法的 class 由 `nativeClass.ts` **如实拒绝**。

### 12.3 本项目（WebHTV PC）侧的能力矩阵

| api 形态 | 本项目行为 | 依据 |
| --- | --- | --- |
| `csp_*` + 含 dex 的 Android jar | **不可用（如实拒绝）** | `apps/desktop-flutter/lib/services/spider_router.dart:455`、`services/spider_registry.dart:255` |
| `csp_*` + 用户自备的桌面 jar | 可判定（放到 `<configDir>/spiders/csp/<siteKey>/`） | `apps/desktop-flutter/lib/services/spider_router.dart:446-490` |
| `type=3` + `jar` 但 `api` 非 `csp_*` | 不可用 | `apps/desktop-flutter/lib/services/spider_router.dart:601-607` |
| `api` 直连 `.js` | **可用**（自动注册 sidecar） | `apps/desktop-flutter/lib/services/direct_spider_registrar.dart` |
| `api` 直连 `.py` | **可用**（自动注册 sidecar） | 同上 |
| `api=csp_PyProxy` + `ext.loader` 指向 `.py` | **可用**（§12.8 方案 2 新增：方言适配 + 生成壳入口） | `services/direct_spider_registrar.dart` 的 `catVodLoaderUrl` / `_materializeCatVod` |

**结论**：T3 的 js/py 源本项目已经能用（含 §12.8 的「Python 壳站点」变体）；**T3 的 jar 源不能用**，且本项目
**没有任何「下载 jar」的代码路径**（`grep downloadJar|fetchJar|jarBytes|installJar` → 0 命中），
jar 只能人工放置。

> **2026-10-24 更新**：本节写作时的另一处缺口——「设置页没有 CSP jar 的导入入口
> （`grep csp @ apps/desktop-flutter/lib/ui` → 0 命中）」——已按 §12.6 方案 A 补上，
> 见 §12.7。检索型「下载 jar」路径仍然**刻意不做**（PRODUCT.md：不代用户获取爬虫）。

### 12.4 为什么不能直接照搬 Win-box 的 jar 能力

Win-box 的 `csp_*` 路线 = 本项目 `docs/adr/0002-android-csp-jar-compat.md` 判为不可行的 **B 方案**（dex2jar），
它靠一整套长期维护的补丁把它做成了产品能力（见 §7.1 的补丁表）。
本项目不采纳的理由是**维护成本与用户规模不匹配**，不是技术上做不到——
若要真正提高 T3 jar 覆盖率，出路是 ADR-0002 的兼容层（A1/A2/E），而不是照搬 dex2jar。

### 12.5 折中方案的边界

「只接桌面 JVM 友好的 T3 jar」**不会让社区 jar 源的大多数变得可用**——生态里的 jar 绝大多数内含
`classes.dex`，属确定拒绝档。该折中方案的收益只有一条：让**本来就该能跑**的桌面 ABI jar
拥有一条完整可用的落地路径（获取 → 检测 → 落盘 → 报结论 → 可回滚），
把当前「要用户自己猜目录、还不知道为什么不行」变成产品能力。

---

### 12.6 折中方案设计：桌面 JVM 友好 T3 jar 的接入路径

> 状态：**方案 A 已实施**（2026-10-24，见 §12.7 实施与验证记录）；方案 B 仍不做。
> **另**：同日实施的 §12.8（方案 2，CatVod **Python** 方言）与本节是两条不同的路——
> §12.8 不做字节码转译、不碰 dex/jar，所以它**不构成对方案 B 的替代或背书**。
> 先读 12.5：本方案的收益边界是「把准入路径产品化 + 如实分档」，**不是**「让社区 T3 jar 变可用」。

#### 12.6.1 一个必须先说清的 ABI 事实

生态里的桌面 jar（`CatVodSpider-PC` 风格）通常继承 `com.github.catvod.spider.Spider`；
而本仓库的 JVM ABI 是 `webhtv.spider.Spider`，由 `sidecars/spider-host-jvm/src/webhtv/spider/EntryLoader.java:84-99`
强制校验（必须 `extends webhtv.spider.Spider`，或提供静态 `createSpider(Map)`）。
`grep catvod @ sidecars` → **0 命中**：仓库里**没有任何** `com.github.catvod.*` 兼容垫片。

因此「桌面 JVM 友好」在当前 ABI 下的准确含义是：**为本 ABI 编译的 jar（或有 `.java` 源码可编译的 jar）**。
CatVodSpider-PC 风格的 jar 目前会以 `ClassNotFoundException` / `IllegalArgumentException("必须继承
webhtv.spider.Spider 或提供静态 createSpider(Map)")` 收场——**这是本方案要如实上屏的那一类失败**。

#### 12.6.2 分层：方案 A（推荐）与方案 B（现在不做）

**方案 A —— 准入与检测闭环（不改 ABI，小）**

把「获取 → 静态检测 → 落盘 → 结论回显 → 可回滚」做成产品能力，全程**不启动 JVM、不执行代码**：

| 阶段 | 动作 | 依据/复用 |
| --- | --- | --- |
| 选择 | 用户在 Spider 页选一个 `.jar` / 解压后的 `.class` 目录 / `.java` 或源码目录 | `EntryLoader.java:55-75` 已支持这四种入口形态 |
| 静态检测 | ①能否按 zip 解析（损坏即失败）②是否含 `classes.dex` ③是否含 `.so` 或 native 方法标志 ④入口类是否存在 | ①`package:archive` `ZipDecoder`（已是依赖，`services/backup_service.dart:11,193` 在用）②③④纯字节解析，参考 Win-box `src/engine/spider/nativeClass.ts` 的「读 class access flags 而非猜类名」纪律 |
| 落盘 | 通过则写 `<configDir>/spiders/csp/<siteKey>/index.jar`（目录入口写同名目录） | `services/spider_registry.dart:217-240` `directoryFor`/`entryFor` 已是既定布局 |
| 回显 | 立即重算 `classifySite` 的结论并展示（available + runtimeName，或 reason 原文） | `services/spider_router.dart:435-491` |
| 回滚 | 记录来源、SHA-256、时间；提供「移除」，移除后回到「缺少桌面 JVM 站源」 | 与 `services/direct_spider_registrar.dart:76,98,106` 的 SHA-256 纪律一致 |

**必须一并修掉的既有缺陷**（否则检测会给错答案）：

1. `services/spider_registry.dart:265`（实施前为 `:252-267`）`isAndroidJar` 是**裸字节子串搜索** `classes.dex` →
   普通桌面 jar 里任何一处该字符串都会**假阳**（误判为 Android jar 并拒绝）。
   改为「先按 zip 解析目录项，再判断是否存在名为 `classes.dex` 的条目」，字符串扫描只能作为 zip 解析失败时的兜底。
2. 同一函数对**目录入口**直接返回 `false`（`if (!path.toLowerCase().endsWith('.jar')) return false;`）
   → 用户把 jar 解压成 `.class` 目录、里面仍带 `classes.dex` 时会漏判，一路走到 JVM 加载才崩。
   目录也必须在检测范围内（`entryFor` 本来就允许类目录，`spider_registry.dart:235-239`）。
3. 检测结论与 `spider_router.dart:446-462` 的用户文案必须来自**同一处**判定，避免「设置页说 A、站点页说 B」。

**方案 B —— 加 `com.github.catvod.spider.Spider` 兼容垫片（大，建议不做）**

在 `host.jar` 里加一个 `com.github.catvod.spider.Spider` 抽象基类，把 `homeContent/categoryContent/`
`detailContent/searchContent/playerContent` 转发到 `webhtv.spider.Spider`。**不建议现在做**：
一旦追求覆盖率，就会开始复制 Win-box 的补丁链（`okhttp4Compat`、`prefsShim`、`appProxyStub`、
`classFix` ……），正是 ADR-0002 判定「维护成本与用户规模不匹配」的那条路。
若将来要做，它属于 ADR-0002 的兼容层议题，应当走 ADR 流程，而不是塞进本方案。

> 注意区分：§12.8 的「CatVod 兼容层」说的是 **Python 方言**（`homeContent` 等方法的参数形态），
> 与本节说的 **Java 基类垫片**（`com.github.catvod.spider.Spider`）不是同一件事。
> 前者不做任何字节码处理，成本可控；后者一旦追求覆盖率就会滑向 Win-box 的补丁链。

#### 12.6.3 落地文件（方案 A）

| 文件 | 变更 |
| --- | --- |
| `apps/desktop-flutter/lib/services/jar_intake.dart` | **新增**：纯 Dart 静态检测（zip 解析 / dex 条目 / `.so` / 入口类存在性）+ 安装与回滚；可单测 |
| `apps/desktop-flutter/lib/services/spider_registry.dart` | 修 `isAndroidJar` 的假阳与目录漏判；新增 `inspect(entry)` 返回分级结论 |
| `apps/desktop-flutter/lib/ui/spider_page.dart` | 新增「导入桌面 JVM 站源」入口 + 检测结果卡片 + 移除 |
| `apps/desktop-flutter/lib/state/app_state.dart` | 暴露安装/移除/刷新，复用既有 `rescanSpiders`（`:3792`）与 `_cspBinding`（`:229`） |
| `apps/desktop-flutter/test/jar_intake_test.dart` | **新增**：真 dex jar / 桌面 jar / 损坏 zip / 带 dex 的类目录 / 移除回滚 |

**不改**：`sidecars/`（ABI 冻结）、`spider_router.dart` 的判定顺序。

#### 12.6.4 验收口径（方案 A）

1. 含 `classes.dex` 的 jar → 拒绝，文案指 `ADR-0002`，**不落盘**；
2. 含 `classes.dex` 的**类目录** → 同样拒绝（当前会漏判）；
3. 桌面 jar（无 dex、无 `.so`、入口类存在）→ 落盘为 `index.jar`，该站点 `classifySite` 变为 available；
4. 损坏/非 zip → 明确失败，不覆盖已有文件；
5. 移除后站点回到「缺少桌面 JVM 站源」；
6. 全过程不启动 JVM、不执行站源代码（PRODUCT.md：UI 层不得直接执行 Spider/网络逻辑）；
7. 文件里若只是**出现了** `classes.dex` 字样（非 zip 条目）→ 不得误判。

#### 12.6.5 一个诚实的预期管理

做完方案 A，**用户手上的社区 T3 jar 依然是绝大多数不可用**（它们内含 dex，或继承 Android/CatVod 基类）。
它换来的是：该能跑的那一批（本 ABI 的 jar / 可编译的源码）有了一条**走得通且说得清**的路，
以及一条**确定的、可解释的拒绝**——而不是今天的「不知道放哪、放进去也不知道为什么不行」。

#### 12.6.6 实施记录（2026-10-24）

方案 A 已落地，实际改动与 §12.6.3 的规划一致，另有一处「不新增公开 API」的调整：

| 文件 | 实际变更 |
| --- | --- |
| `apps/desktop-flutter/lib/services/jar_intake.dart` | **新增**（662 行）：`JarVerdict` 七档 + `JarInspection` + `JarInstallResult` + `InstalledJar` + `JarIntake`（`inspectPath` / `hasAndroidDex` / `install` / `remove` / `describeInstalled` / `installedSiteKeys` / `intakeRecord`） |
| `apps/desktop-flutter/lib/services/spider_registry.dart` | `CspJvmBinding.isAndroidJar` 改为 `=> JarIntake.hasAndroidDex(path)`；删掉私有 `_containsAscii`（判定收敛到一处，见 §12.6.2 缺陷③） |
| `apps/desktop-flutter/lib/state/app_state.dart` | 新增 `cspRoot` / `cspDirectoryFor` / `installedCspJars` / `inspectCspSource` / `importCspJar` / `removeCspJar` |
| `apps/desktop-flutter/lib/ui/spider_page.dart` | 新增 `_CspJarIntakeCard`（路径 + 站点 key 两个输入，「仅检测」/「检测并导入」，结论 + 已导入列表 + 移除） |
| `apps/desktop-flutter/test/jar_intake_test.dart` | **新增**：17 个用例（检测分级 10 + 导入回滚 7） |

**与规划的一处偏差**：§12.6.3 原写「`spider_registry.dart` 新增 `inspect(entry)` 返回分级结论」；
实际实现把分级结论放在 `jar_intake.dart`（`JarInspection`/`JarVerdict`），让 `spider_registry.dart` 保持
「只回答可用性」的单一职责，仅在 `isAndroidJar` 上委托一次。检测本身不需公开更细的 API。

**实现细节（与设计文本的对应）**：

- 判定只看 **zip 条目名**，不解压、不读条目内容；`base.endsWith('.dex')` / `.so` / `.class` / `.java` 四类分类，
  优先级 dex > 原生库 > 源码 > 入口类缺失 > `desktopReady`。
- 目录入口走 `listSync(recursive: true, followLinks: false)`，条目数上限 `maxEntries = 50000`。
- zip 解析用 `InputFileStream` + `ZipDecoder().decodeStream(...)`，**finally 里 `closeSync()`** 释放句柄
  （Windows 上不释放会让紧随其后的 rename/delete 失败）。
- 解析失败时的兜底**故意收窄**：只有文件确实是 zip（魔数 `50 4B 03 04`）**且**字节里出现 `classes.dex`
  才判 `androidJar`，否则一律 `malformed`——这正是验收⑦「只是出现字样不得误判」的实现方式。
- 落盘为「暂存名 → 删除旧入口 → rename → 写 `intake.json`」，与 `services/backup_service.dart` 同范式；
  `intake.json` 记 `siteKey` / `className` / `entry` / `sourcePath` / `sourceSha256` / `installedAt` / `verdict`。
- 检测不通过时**目标目录都不会被创建**（验收① 的强形式：连空目录都不留）。

---

### 12.7 方案 A 的验收与验证记录（2026-10-24）

#### 12.7.1 逐条验收（对应 §12.6.4）

| # | 验收口径 | 结论 | 证据 |
| --- | --- | --- | --- |
| 1 | 含 `classes.dex` 的 jar → 拒绝、文案指 ADR-0002、不落盘 | ✅ | `test/jar_intake_test.dart`「含 classes.dex 的 jar 判为 androidJar，且不可安装」+「Android jar 被拒绝且**不落盘**」（断言目标目录 `existsSync() == false`） |
| 2 | 含 `classes.dex` 的**类目录** → 同样拒绝 | ✅ | 同名测试「…**类目录**同样判为 androidJar（旧实现漏判）」，并断言 `CspJvmBinding.isAndroidJar(dir.path) == true` |
| 3 | 桌面 jar → 落盘 `index.jar`，`classifySite` 转为 available | ✅ | 「桌面 jar 导入后 entryFor 能定位…」；同时 `test/phase3_jvm_spider_test.dart` 既有 5 个 csp 用例全通过 |
| 4 | 损坏 / 非 zip → 明确失败且不覆盖既有文件 | ✅ | 「损坏文件被拒绝，且不覆盖已导入的桌面 jar」（逐字节比较 `index.jar` 前后内容） |
| 5 | 移除后回到「缺少桌面 JVM 站源」 | ✅ | 同上用例后半段，断言移除后 `reason` 仍含 `classes.dex` |
| 6 | 全程不启动 JVM、不执行站源代码 | ✅ | 检测只用 `ZipDecoder` 读中央目录 + `Directory.listSync`；`jar_intake.dart` 无 `Process`/`Isolate`/`eval` 引用，也不 import `spider_process.dart` |
| 7 | 只是**出现** `classes.dex` 字样 → 不得误判 | ✅ | 「只是内容里出现 classes.dex 字样（非 zip 条目）不得误判（验收⑦）」：条目 data 里放该字符串，断言 `verdict == desktopReady` 且 `isAndroidJar(path) == false` |

#### 12.7.2 命令级验证

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 静态分析 | `flutter analyze`（`C:\dev\flutter` 3.47.5 / Dart 3.13.4，与 CI `.github/workflows/windows-ci.yml` 的 `FLUTTER_VERSION: 3.47.5` 同版本） | **`No issues found!`** |
| 新增测试 | `flutter test test/jar_intake_test.dart` | **17 passed / 0 failed** |
| 受影响的既有测试 | `flutter test test/phase3_jvm_spider_test.dart` | **18 passed / 0 failed**（含 5 个 csp 映射用例） |
| 全量回归 | `flutter test` | **2765 passed / 10 failed**；10 个失败**全部**是环境性的（9 个 `test/phase2_ipc_test.dart` 的 sidecar 生命周期组 `SPIDER_CRASHED [transport] sidecar 意外退出（code=101）` + 1 个 `test/phase2_spider_page_test.dart:273` 的 `'running'` vs `'backoff'`），**与本改动无关**：用 `git stash` 摘掉本次 3 个被改文件后单跑 `test/phase2_spider_page_test.dart`，同一用例**同样失败**（同样的 `Expected: 'running' / Actual: 'backoff'`）。改动前的基线同批失败数为 10。 |
| 门禁脚本 | `python tools/phase9/verify_gap_matrix.py` | G9.1–G9.5 全部 PASS（本次不触碰该脚本的扫描面） |

> 环境性失败的判定依据：本机 Python 为 3.14.7，`sidecars/spider-host-python/host.py` 手动按 Content-Length
> 帧喂参数可正常返回 `webhtv-ipc-v1` 信封；且同 HEAD（`38a6439`）的 CI 运行
> `Windows CI dev1 push 39921560583` 为 success。IPU 侧的 `code=101` 属本机环境差异。

#### 12.7.3 未做的部分（有意）

- **不做下载**：导入只接受**本机已存在**的路径，没有 `http` 取 jar 的代码路径（PRODUCT.md：不代用户获取爬虫）。
- **不做方案 B**：`com.github.catvod.spider.Spider` 垫片仍是 ADR-0002 的议题，不在本次范围（§12.6.2）。
- **不改 ABI**：`sidecars/` 零改动（`git diff --numstat -- sidecars` 为 0），`spider_router.dart` 的判定顺序未动。
- **不改 `spider_router.dart` 文案**：站点页的「该 jar 是 Android 站源（内含 classes.dex），JVM 无法加载…」
  保持原文，只是它背后的判定改由 `JarIntake` 提供（§12.6.2 缺陷③ 的「同一处判定」）。

---

### 12.8 方案 2：CatVod 方言 Python 站源接入（2026-10-24 实施）

> 状态：**已实施**。这一节不是「照搬 Win-box」，而是**从 Win-box 的盲点里找到的第三条路**。
> 触发点是一份真实配置：某 AT 配置 163 站里有 **82 个** `api=csp_PyProxy` 的站点，本站一个都跑不起来。

#### 12.8.1 问题：两端共同的盲点

这 82 个站点的 `api` 只是一个**壳名**（`csp_PyProxy`），真正的 Python 地址写在 `ext` 里：

```text
ext（base64，解码后 1812 字节 JSON）:
  loader    = http://<host>/Atvp.py?v=preheat-v1       ← 真正的 Python 入口（82 站完全相同）
  source    = http://<host>/plugins/2024/<N>.txt?v=<V>  ← 每站不同（加密过的内层蜘蛛）
  secret / token / api / preheatUrl / local_proxy_config / playback*
```

而**两端都只按 `site.api` 的后缀决定运行时**：

| 项目 | 分流位置 | 判据 |
| --- | --- | --- |
| Win-box | `src/engine/spider/SpiderFactory.ts:72` | `api.endsWith('.py')` / `.js` |
| 本项目（改前） | `apps/desktop-flutter/lib/services/direct_spider_registrar.dart:153-159` `directSpiderKind` | 同上 |

→ `csp_PyProxy` 既不是 `.py` 也不是 `.js`，**两端都落进「不认识」**。
这是 §12.2 / §12.3 两张表都没覆盖到的一格。

#### 12.8.2 方案：不改 ABI，用「生成的壳入口」把方言接进既有 sidecar

不新增宿主、不改 `webhtv-ipc-v1`、不改 `host.py`。分三层：

| 层 | 文件 | 作用 |
| --- | --- | --- |
| 方言适配 | `sidecars/spider-host-python/webhtv_catvod.py`（**新增**） | 把宿主契约 `handler(params, context)` 与 CatVod 契约 `homeContent(filter)` 互转 |
| 垫片 | `sidecars/spider-host-python/base/spider.py`、`base/__init__.py`（**新增**） | 提供内层蜘蛛 `from base.spider import Spider` 需要的基类（`fetch`/`post`/`html`/`log`/`getProxyUrl` 等） |
| 分流与落盘 | `direct_spider_registrar.dart` / `spider_router.dart` | 认 `ext.loader`，下载 loader 并生成壳入口 `spider.py`，注册成普通 `webhtv-ipc-v1` 站源 |

**为什么用「生成的壳入口」而不是改 `host.py`**：`host.py:42-49` 的 `build_spider` 走
`create_spider(manifest)` 或 `spider_class(manifest)`；CatVod 蜘蛛是 `def __init__(self)` 零参，
且宿主不该认识第三方方言。生成一个 6 行的 `spider.py`：

```python
from webhtv_catvod import create_catvod_spider

def create_spider(manifest=None):
    return create_catvod_spider(manifest, entry='loader.py', root=str(Path(__file__).resolve().parent))
```

`host.py` 零改动，方言适配全部收敛在新模块里。

#### 12.8.3 参数映射与「如实报不支持」

`webhtv_catvod.py` 的 `positional_args(method, params)` 与 `sidecars/spider-host-js/sandbox_worker.js:308-338`
的 `scriptArgs` **同口径**（两套 sidecar 的行为必须一致，否则同一站源换语言就变行为）：

| 宿主方法 | CatVod 位置参数 |
| --- | --- |
| `home` | `(bool(filter),)` |
| `homeVod` | `()` |
| `category` | `(text(id or tid), page_text(page), bool(filter), filters if Mapping else {})` |
| `detail` | `(list(ids),)` 或 `([text(id)],)` |
| `search` | `(text(keyword or wd), bool(quick), page_text(page))` |
| `play` | `(text(flag), text(id), [])` |
| `live` / `proxy` | `(text(url),)` / `(param,)` |

`normalize_result`：`None` → `play` 给 `{}`、其余给 `{'list': []}`；`list` → `{'list': ...}`；
非 Mapping → `ValueError`（站源返回了非对象值）；`play` 原样返回 dict（`playerContent` 的 `qualities`
转平铺数组正好命中 `http_api.dart:522-558` 的 `_playUrlFrom` 两两配对分支）。

**关键约束（PRODUCT.md 口径）**：`capabilities()` 只报**实际可调用**的方法；站源没有
`searchContent` 时 `_call` 抛 `UnsupportedMethod` → 宿主回 `SPIDER_UNSUPPORTED` + capabilities 列表，
**绝不返回空列表**。实测真实 AT 插件即命中此路径（该插件本身不实现搜索）。

#### 12.8.4 三个必须知道的实现细节

1. **stdout 是协议通道**。CatVod 站源大量用 `print()`（`Atvp.py` 的 `categoryContent`/`detailContent`
   开头就有 print），直接写 stdout 会污染 JSON-RPC 帧。做法：`init` 之后把 `sys.stdout` 常驻指向
   `sys.stderr`（`SidecarServer.__init__` 已捕获真实 stdout 二进制流，改 `sys.stdout` 不影响协议），
   每个 handler 再包一层 `_stdout_to_stderr()` 上下文。
2. **常驻重定向必须在退出前撤销**（实测踩坑，见 12.8.5）。`CatVodSpider.close()` 用 try/finally
   调 `_restore_stdout()`。
3. **依赖必须惰性**。CI（`.github/workflows/windows-ci.yml`）装了 Python 3.12 但**没有任何 pip install**，
   所以垫片的 `requests` / `lxml` / `pycryptodome` 全部惰性导入：有就用，没有就给**可执行的**错误文案
   （`CatVod 站源缺少 Python 依赖：requests（<entry> 需要它）。请在运行 WebHTV 的同一个 Python 环境里安装后重试。`），
   而不是在 import 阶段直接崩。

#### 12.8.5 实测踩到并修掉的一个真 bug：0xC0000005

首版把 `sys.stdout = sys.stderr` 常驻后从不撤销，真实配置连跑出现**概率性**退出码
`3221225477`（`0xC0000005`），stderr 是：

```text
Fatal Python error: _enter_buffered_busy: could not acquire lock for
  <_io.BufferedWriter name='<stdout>'> at interpreter shutdown,
  possibly due to daemon threads
Python runtime state: finalizing
```

概率：同一份代码连跑 10 次，4 次崩；对照纯 `fixture_spider.py` 10/10 正常。
变体二分（各 12–14 次）：原版 3/12 崩 / 不常驻 0/12（但预热门 daemon 的 print 会污染协议）/
去掉上下文管理器 7/12 崩 / **close() 里撤销 0/14** / stderr 代理对象 2/14。

根因：常驻重定向让 stderr 的 `BufferedWriter` 在 finalize 时承担两份引用，而 daemon 线程仍持锁。
**修法只有一条：退出前撤销**。这是 `_restore_stdout()` + `close()` try/finally 的由来。

> 这个 bug 只有在**真实站源（带后台线程）**上才会暴露，fixture 永远跑不出来——
> 它是「端到端跑真实配置」这一步换来的，不是单测能换来的。

#### 12.8.6 落地文件清单

| 文件 | 变更 |
| --- | --- |
| `sidecars/spider-host-python/webhtv_catvod.py` | **新增** 340 行：`SHELL_TO_CATVOD` 映射 / `positional_args` / `normalize_result` / `_stdout_to_stderr` / `_keep_stdout_on_stderr` / `_restore_stdout` / `CatVodSpider` / `create_catvod_spider` / 依赖缺失文案 |
| `sidecars/spider-host-python/base/spider.py` | **新增** 342 行：CatVod `Spider` 垫片（`fetch`/`post`/`html`/`log`/`getProxyUrl`/`getCache`/`regStr`/`removeHtmlTags`/`str2json`/`json2str` + 各默认实现）；自带 `Response` 类（`.text`/`.json()`/`.content`/`.ok`）；TLS 默认开启，`WEBHTV_CATVOD_INSECURE_TLS=1` 才跳过校验 |
| `sidecars/spider-host-python/base/__init__.py` | **新增**：`from .spider import Spider` |
| `sidecars/spider-host-python/webhtv_ipc.py` | **+4/−3 行**（唯一的 ABI 内改动）：`UnsupportedMethod.__init__(method, message=None)` 增加可选文案，让 CatVod 站源能说明「方法存在但没实现」；默认文案与协议行为不变 |
| `sidecars/spider-host-python/spiders/fixture_catvod.py` | **新增**（测试 fixture，仅标准库，不入发行包） |
| `apps/desktop-flutter/lib/services/direct_spider_registrar.dart` | `enum DirectSpiderKind` 加 `catVod`；新增 `catVodLoaderUrl(Site)`（ext 支持 Map / JSON 字符串 / Base64 JSON 三种形态）；新增 `_materializeCatVod`（目录键 `sha256('<siteKey>\n<loaderUrl>')`，落 `loader.py`/`loader.json`/`spider.py`/`manifest.json`） |
| `apps/desktop-flutter/lib/services/spider_router.dart` | `_cacheKey` 加 `site.key`（**否则 82 个同 api 站点塌缩成 1 个 runtime**）；`classifySite` 把「已注册直连」判定提到 `CspJvmBinding` 之前（原先 `csp_` 分支在最前，PyProxy 永远进不去）；`_directUnavailableReason` 加 CatVod 档 |
| `apps/desktop-flutter/lib/services/spider_registry.dart` | `_locateSidecarHost` 向上查找 `6` → `10` 跳（Release 布局 `build/windows/x64/runner/Release` 到仓库根需 **7** 跳，原先返回空串 → 日志「sidecar 宿主不存在：（空）」） |
| `scripts/package_windows.ps1` | `$sidecarFiles` 5 → 8 项（补 `webhtv_catvod.py`、`base/spider.py`、`base/__init__.py`）；校验/复制/清单三处共用该数组 |
| `apps/desktop-flutter/test/phase9_direct_spider_test.dart` | +4 用例（壳形态识别 / 下载+生成+注册 / 同 api 多站点不互相覆盖 / loader 哈希一致不重下） |
| `apps/desktop-flutter/test/phase9_catvod_spider_test.dart` | **新增** 334 行 / 5 用例（壳入口生成 / 五方法签名适配 / print 落 stderr / 未实现报 UNSUPPORTED / destroy 后 0 退出） |

#### 12.8.7 验收与边界

| # | 口径 | 结论 |
| --- | --- | --- |
| 1 | `api=csp_PyProxy` + `ext.loader` 指向 `.py` → 被识别并走 Python 运行时 | ✅ 单测 + 真实配置双路径 |
| 2 | 82 个同 api 站点互不覆盖（各自目录、各自 ext） | ✅ `_cacheKey` 与目录键都纳入 `site.key` |
| 3 | 站源 `print()` 不污染协议，落到 stderr 可见 | ✅ 用例③ |
| 4 | 站源未实现某方法 → `SPIDER_UNSUPPORTED`，不返回空列表 | ✅ 用例④ + 真实 AT 插件 |
| 5 | 正常关闭以 0 退出（不出现 0xC0000005） | ✅ 用例⑤（3 轮）+ 真实配置 20 连跑 |
| 6 | 不改 `webhtv-ipc-v1` ABI、不改 `host.py`、不做 dex2jar | ✅ `host.py` diff 为 0；`webhtv_ipc.py` 仅 4/3 行（`UnsupportedMethod` 可选文案），协议帧与错误码不变 |
| 7 | 依赖缺失有可执行文案 | ✅ `_format_missing_dependency` |
| 8 | 发行包含新模块 | ✅ `$sidecarFiles` 8 项 |

**真实配置实测（AT，82 站）**：`home` 出 7 分类、`category` 出 20 条真实 TMDB 数据；
`search` 该插件本身未实现 → 如实报 `SPIDER_UNSUPPORTED`。

**边界（诚实）**：这把「82 个站点完全跑不起来」变成「能跑，前提是本机 Python 环境已装
`requests` / `pycryptodome`（`lxml` 视插件而定）」。仓库仍不捆绑任何 pip 包（`windows-release.yml`
明示不捆绑 Python 运行时），依赖缺失时给的是**能照着做的错误文案**，不是静默降级。

**为什么不走 dex2jar（方案 B）**：Win-box 走的是转译 `classes.dex` 那条路，代价是长期补丁链
（§7.1）。本方案只做**方言适配**——把 Python 站源的调用约定接上，不碰字节码转译。
两者的收益不同：方案 2 解锁的是「Python 壳站点」，方案 B 解锁的是「Java jar 站点」。

---

## 12.9 方案 3：让程序自己完成「能自动的那部分迁移」（2026-10-24 实施）

触发（用户原话）：**「亮起来了但是用不了，如果需要迁移啥的不应该程序自己做嘛？」**

这句话背后是**两个不同的缺陷**，被同一个现象串在一起：
站点列表显示「可用」，点进去却报「PC Java Spider 未安装或未支持」。

### 12.9.1 缺陷一：列表与业务读的不是同一个 Router（真 bug）

`SiteService` 每次装配时**新建一个匿名 `SpiderRouter`**，而 `setDirectSpiders` /
`classifySite` 作用于 `AppState._router` 字段：

| 路径 | 用的实例 | 结果 |
| --- | --- | --- |
| 站点列表可用性（`app_state.dart` 的 `_router.classifySite`） | 字段 `_router` | 注册结果可见 → **显示可用** |
| 实际 home/category/detail 调用（`site_service.dart` 的 `router.runtimeFor`） | 匿名 Router | `directSpiders` 永远为空 → **报不可用** |

日志里能直接看到这对矛盾（同一次启动、相隔 2 秒）：

```
17:09:57 DEBUG type=3 runtime=本地 Spider (webhtv-ipc-v1) available=true
17:10:12 ERROR 首页加载失败 site=7b7695… siteUnsupported: 站点运行时「PC Java Spider」未安装或未支持
```

**修法**：装配时不再新建 Router，改为复用字段 `_router` 并注入当前传输层：

```dart
// app_state.dart _attachSiteService()
_router.updateTransport(client: _httpClient, globalHeaders: config.headers);
_siteService = SiteService(
  appConfig: config,
  playbackBridge: _androidPlaybackBridge,
  router: _router,          // ← 同一个实例
  database: _database,
);
```

`SpiderRouter.updateTransport` 是新增方法：`client` / `globalHeaders` 由 `final` 改为可变，
赋值后**无条件 `_cache.clear()`**——因为 `_create` 会把 client 与 globalHeaders **快照**进
`HttpApiRuntime` / `CatHttpSiteRuntime`，只改字段不清缓存等于没改。旧 client 不在这里 close
（由 `_applyOutboundProxy` 的重建流程统一释放，早关会让在途请求失败）。

顺带修掉第二个缺陷：`_router` 构造时写的是 `globalHeaders: const []`，
导致 HTTP API 站点（AT 有 68 个 type=4）**请求头不带配置里的 header**。现在由
`updateTransport` 在每次装配时注入 `config.headers`。

### 12.9.2 缺陷二：能自动做的事丢给了用户

AT 这类配置把 jar 写成远端地址，而 PC 端的 `csp_*` 只认本机缓存
`<config>/spiders/csp/<siteKey>/`。此前文案是「请把**无 Android Context** 的 jar 放到 …」——
把「取回 + 检测」这两步纯机械操作推给了用户。

新增 `apps/desktop-flutter/lib/services/csp_jar_probe.dart`，把这两步自动化：

```
配置里的 jar/spider 字段
  → JarSourceSpec.parse（识别 TVBox 的 ;md5;<hash> 后缀，但**不据此判定**）
  → 同一 URL 只下载一次（AT 90+ 站点共用 spring.jar）
  → JarIntake.inspectPath（纯静态：只读 zip 目录项，不加载类）
  → 可加载 → JarIntake.install（原子落盘，站点立即变可用）
  → 不可加载 → 不落盘，只写 probe.json 结论
```

**关键设计点**

| 点 | 做法 | 理由 |
| --- | --- | --- |
| 下载去重 | 单轮内 `_downloadCache` 按 URL 缓存 | AT 有 90+ 站点共用同一份 `spring.jar`；逐站点下载会打 90 次上游 |
| 暂存文件 | `<root>/probe-cache/<sha256(url)[0:16]>.jar` | 按 URL 命名而不是按站点，避免同一份 jar 存 90 份 |
| 永久跳过 | 静态结论（androidJar / nativeLibrary / malformed）重下也是同一结论 | 不做无意义的重复下载 |
| 冷却重试 | `fetchFailed` 10 分钟内不重试 | 死链不该每次装配都打一遍 |
| **md5 不判定** | 声明 md5 与实际不符时**照常检测**，只把两份值记进 `probe.json` 并在 `summary` 里注明「已忽略」 | 用户 2026-10-25 明确要求；TVBox 生态服务端重新打包却不更新配置 md5 极常见，按它拒绝等于白丢本来能用的入口 |
| 旧结论失效 | `_shouldSkip` 见 `verdict == 'checksumMismatch'` 一律返回 false（立即重下重判） | 上一版按 md5 写下的结论已失去依据，不能让用户手动删 `probe.json` 才能恢复 |
| 不覆盖用户 | `entryFor(siteKey) != null` → `skippedInstalled` | 用户手工导入的选择优先 |
| 纪律不变 | 含 `classes.dex` / 原生库的入口**永不落盘** | PRODUCT.md + ADR-0002：JVM 加载不了 dex |

**结论回显**：`SpiderRouter._classifyCsp` 的「没有入口」分支先读 `probe.json`：

```
自动检测失败：配置声明的 jar（http://192.168.50.50:4567/spring.jar）无法在桌面 JVM 加载。
该入口是 Android 站源（内含 classes.dex），JVM 无法加载；需桌面版 jar，或按 ADR-0002 启用 Android 兼容层。
```

用户看到的从此是**程序已经试过并查明的真实原因**，而不是一句「请自己放 jar」。
没有探测结论时才回落到原文案。

### 12.9.3 落地文件

| 文件 | 改动 |
| --- | --- |
| `apps/desktop-flutter/lib/services/csp_jar_probe.dart` | **新增** `CspProbeOutcome` / `CspProbeEntry` / `CspProbeReport` / `JarSourceSpec` / `CspJarProbe` |
| `apps/desktop-flutter/lib/services/jar_intake.dart` | 新增 `probeRecord(targetDir)` / `writeProbe(targetDir, record)`（`probe.json` 只描述结论，不落可执行内容） |
| `apps/desktop-flutter/lib/services/spider_router.dart` | `client` / `globalHeaders` 改可变；新增 `updateTransport`；`_classifyCsp` 读 `probe.json` 回显 |
| `apps/desktop-flutter/lib/state/app_state.dart` | `_attachSiteService` 复用 `_router`；新增 `probeCspJars()` / `cspProbeRecordFor()` / `_probeCspJarsQuietly()`（装配后异步触发） |
| `apps/desktop-flutter/lib/ui/spider_page.dart` | 卡片改称「T3 桌面 JAR 站源」；新增「自动探测配置里的 jar」按钮（key `csp-jar-probe`）与结论列表 |
| `apps/desktop-flutter/test/csp_jar_probe_test.dart` | **新增** 13 个用例（自动装入 / dex 不落盘 / URL 去重 / 顶层 spider / 冷却 / 静态永久 / 已装跳过 / 有自己运行时的站点不参与 / 非 csp 不动 / `;md5;` 解析两例 / **md5 不符照常判定并装好** / **旧 checksumMismatch 结论立即失效重下**） |

### 12.9.4 验收

| # | 口径 | 结论 |
| --- | --- | --- |
| 1 | 列表显示可用 ⇔ 实际调用可用 | ✅ 同一个 `SpiderRouter` 实例；8 文件联合回归 127 passed（当时唯一失败的 `py.exe` 环境用例已由 §12.10 修掉） |
| 2 | 桌面 jar 自动装入，站点立即可用 | ✅ 用例「桌面 jar 自动装入缓存目录」 |
| 3 | 含 dex 的 jar 不落盘，只写结论 | ✅ 用例断言目录里只有 `probe.json` |
| 4 | 站点列表显示程序查明的真实原因 | ✅ 用例断言 `reason` 含「自动检测失败」与「ADR-0002」 |
| 5 | md5 不符不再拒绝（m04895） | ✅ 用例「md5 不匹配**不再拒绝**」断言 `installed=1`、`entryFor != null`、`actualMd5` 已记录、`summary` 含「已忽略」；用例「旧版本写下的 checksumMismatch 结论立即失效并重下」断言仍会重新取回 |
| 5 | 90+ 站点共用一份 jar 只下载一次 | ✅ 用例「多个站点共用一个 URL 时只下载一次」 |
| 6 | 死链不反复打 | ✅ 用例「冷却期内不重复请求」 |
| 7 | 不覆盖用户手工导入 | ✅ 用例「已导入的站点跳过探测」 |
| 8 | 不改 ABI、不加载类、不启 JVM | ✅ 只读 zip 目录项；`JarIntake` 全部静态 |

### 12.9.5 边界：自动迁移**救不了** AT 那 12 个具名站点

必须说清楚，否则会变成新的预期落空。实测（`C:/dev/probe_jars.py`）：

| 站点组 | jar | 实测 | 自动探测能给的结果 |
| --- | --- | --- | --- |
| 93 个（含 9 个具名） | `http://192.168.50.50:4567/spring.jar` | 200 / 450,594 字节 / zip **只有 `classes.dex` + `MANIFEST.MF`** | `androidJar` → 拒绝，回显「需桌面版 jar，或按 ADR-0002」 |
| `leo弹幕` | `http://192.168.50.50:3000/custom_spider.jar?token=…` | **HTTP 401** | `fetchFailed` → 回显「取回失败」 |

`spring.jar` 的 dex 里有 126 个 `com/github/catvod/spider/*` 类（PianDan / XiaoYa / AList /
Media / BiliBili / Emby / Live / FishPanSou / FishPanSouGroup / PyProxy 全在），
要跑就得走 dex2jar 转译（方案 B，ADR-0002 已判「代价高不采纳」），
不是「迁移一个文件」能解决的。**自动探测的价值是把这个结论摆到用户面前，
而不是制造「点了就能用」的错觉。**

（`Nostr` 与 `DanmakuSpider` 的类名不在 `spring.jar` 的 dex 里——它们指向
`custom_spider.jar`，而那个地址 401，无从判定。）

### 12.9.6 与 Win-box 的关系

Win-box 里对应的是 `src/engine/spider/JarSpiderBridge.ts` 的**自动转换**：
它同样先检查 jar 内容（`jarContentIndex.ts` 按内容 md5 复用转换产物），
再决定走哪条路。区别在于 Win-box 把「有 dex」当作**待转译**，
本项目把「有 dex」当作**不可在 JVM 加载**——这是 ADR-0002 的产品决策，
不是能力差距的掩饰。

真正可借鉴的是它的**缓存键选择**：按 jar **内容**哈希复用，而不是按站点 key。
本方案的 `probe-cache/<sha256(url)>` 与 `probe.json` 是同一思路的小号版本
（AT 就是 90 个站点指同一份 jar 的真实案例）。

---

## 12.10 方案 3 的连带修复：Python 解释器解析必须验证（2026-10-24 实施）

### 12.10.1 缺陷

Windows 上 `py.exe` 是一个 **launcher**：`py -3` 会转发到它自己记录的某个解释器路径。
若那个解释器被删除（本机就是这种情况，指向 `F:\Workspace\webtv2\webhtv\Python\pythoncore-3.15-64\python.exe`，已不存在），
`py -3` 会以退出码 **101** 结束并打印 `Unable to create process using '…'`。

旧实现（`apps/desktop-flutter/lib/services/spider_process.dart` 的 `SidecarRuntimeResolver._resolvePython`
与 `apps/desktop-flutter/lib/services/spider_registry.dart` 的 `LocalSpiderCommand._pythonCommand`）
**只判断文件是否存在**，于是在 PATH 上找到 `py.exe` 就返回 `py -3`。后果：

| 现象 | 真实原因 |
| --- | --- |
| 站点显示「本地 Spider (webhtv-ipc-v1)」可用，一调用就 `SPIDER_CRASHED [transport] sidecar 意外退出（code=101）` | 解释器根本没起来 |
| 日志只有 `sidecar 崩溃`，`stderrLines` 为空 | 进程在 Python 启动前就死了，没有任何 stderr |
| `test/phase2_ipc_test.dart` 9 个用例 + `test/phase2_spider_page_test.dart` 1 个用例长期稳定失败 | 同上 |

这是典型的**把坏的环境伪装成坏的程序**：用户会以为站源代码有问题。

### 12.10.2 修法

候选逐个用 `--version` 验证，通过才采用：

```dart
static List<SidecarCommand> pythonCandidates();   // py.exe -3 优先，再 python.exe / python3.exe
static bool pythonWorks(SidecarCommand command);  // exitCode == 0 且输出匹配 Python 3.x
static SidecarCommand? firstUsablePython(List<SidecarCommand> candidates,
    {bool Function(SidecarCommand)? probe});
```

要点：

| 点 | 做法 | 理由 |
| --- | --- | --- |
| 探测而非存在性 | `Process.runSync(exe, [...args, '--version'])`，要求 `exitCode == 0` **且**输出匹配 `Python 3.x` | launcher 会「启动成功但转发失败」；WindowsApps 的 App Execution Alias 会「启动成功但不输出」 |
| 进程级缓存 | `_pythonProbed` / `_pythonResolved` | 单次探测 60–120 ms，站点启动是热路径 |
| 单一来源 | `spider_registry.dart` 不再自己扫 PATH，改调 `SidecarRuntimeResolver` | 两处各写一套就会各坏一套 |
| 可注入 probe | `firstUsablePython(..., probe:)` | 单测不依赖本机装了哪个 Python |
| 如实报因 | 全部候选都不可用时返回 null 并 `log.warning('Python 候选全部不可用（…）')` | 交给 UI 显示「运行时未安装」，而不是静默回落 |

### 12.10.3 落地文件

| 文件 | 改动 |
| --- | --- |
| `apps/desktop-flutter/lib/services/spider_process.dart` | 新增 `pythonCandidates()` / `pythonWorks()` / `firstUsablePython()`；`_resolvePython()` 改为逐候选验证 + 进程级缓存 |
| `apps/desktop-flutter/lib/services/spider_registry.dart` | `_pythonCommand({LogService? log})` 委托给 `SidecarRuntimeResolver`，失败时给出候选清单与原因 |
| `apps/desktop-flutter/test/phase9_python_runtime_test.dart` | **新增** 6 个用例（候选顺序 / 去重 / 回退 / 全坏返回 null / 空列表 / 文件不存在不启动进程 / 真实探测） |

### 12.10.4 验收

| # | 口径 | 结论 |
| --- | --- | --- |
| 1 | 坏候选不被采用 | ✅ 用例「第一个候选不可用时回退到下一个」 |
| 2 | 全部候选都坏时如实返回 null | ✅ 用例「全部候选都不可用时返回 null」 |
| 3 | 存在但不可执行的候选不判为可用 | ✅ 用例「文件不存在的候选一律判为不可用」 |
| 4 | 此前长期失败的 10 个用例转绿 | ✅ `phase2_ipc_test.dart` + `phase2_spider_page_test.dart` → 39 passed |
| 5 | 静态分析无告警 | ✅ `dart analyze` → `No issues found!` |

这条修复与 Win-box 无关，是**做方案 3 时顺带暴露出来的既有缺陷**，记录在此以免以后重复踩。
---

## 12.11 让程序自己备好运行时：依赖感知的解释器选择 + 托管 venv（2026-10-25 实施）

### 12.11.1 缺陷：解释器「能启动」不等于「能跑这个站源」

12.10 把解释器解析从「文件存在」升级为「`--version` 能打印 Python 3.x」，
这解决了 `py.exe` 转发到已删除解释器的场景，但**仍然漏掉一整类**：

CatVod 壳站源（`apps/desktop-flutter/lib/services/direct_spider_registrar.dart`
生成的 `spider.py` + 下载的 `loader.py`）在**模块顶层**就 import 第三方库
（实测壳文件首 6 行即 `import requests` / `Crypto.Cipher.AES` / `Crypto.Hash.SHA256` /
`Crypto.Protocol.KDF.HKDF` / `Crypto.PublicKey.ECC` / `lxml.etree`）。
所以「缺依赖」不是「某个方法不可用」，而是**启动即失败**：

| 层 | 表现 |
| --- | --- |
| `sidecars/spider-host-python/host.py:77-79` | 捕获 ImportError → `log('站源初始化失败：…')`（只写 stderr）→ `return 3` |
| `apps/desktop-flutter/lib/services/spider_process.dart:370-399` | `_onExit` 生成 `SPIDER_CRASHED [transport] sidecar 意外退出（code=3）` |
| `apps/desktop-flutter/lib/services/sidecar_runtime.dart:94-102` | 只 `log.warning(error.logLine)` 后 `throw error.toAppError(detail: '方法=… site=…')`，**不读 `details['stderr']`** |
| `apps/desktop-flutter/lib/core/ipc_protocol.dart:226-239` | `toAppError` 兜底映射为 `siteUnsupported` |

用户最终看到的是「站点运行时未安装或未支持」——真实原因（缺 `requests`）被三层包住。
本机实测的候选链（`SidecarRuntimeResolver.pythonCandidates()` 同序复刻）：
`py.exe -3`（坏）、`WindowsApps\python.exe`（3.14.7，无依赖）、
`WindowsApps\python3.exe`（同上）——**三个候选全都能打印 `Python 3.x`，也全都没有依赖**。
本机唯一带齐 `requests` + `Crypto` + `lxml` 的是
`C:\Users\Maple\AppData\Local\Programs\Python\Python313\python.exe`，而它**不在 PATH 上**。

### 12.11.2 修法一：CatVod 站源按依赖探测选解释器

`apps/desktop-flutter/lib/services/spider_process.dart`：

| 新增 | 说明 |
| --- | --- |
| `catVodDependencyModules = ['requests','Crypto','lxml']` | 与 `python_runtime_provision.dart` 的安装清单同源（复制字面量，避免 services/ 反向依赖） |
| `dependencyProbeScript` | `import importlib.util as u,sys;ms=[m for m in sys.argv[1:] if u.find_spec(m) is None];print('MISSING:'+','.join(ms) if ms else 'OK')`——用 `find_spec` **不执行模块顶层代码**，因此探测本身不会触发壳的副作用 |
| `pythonWorksForCatVod(command, {modules})` | 先过 `pythonWorks`（`--version`），再跑依赖探测，`exitCode == 0` 且输出含 `OK` 才算可用 |

`apps/desktop-flutter/lib/services/spider_registry.dart`：

| 新增 | 说明 |
| --- | --- |
| `_pythonCommandForCatVod({log})` | 独立于普通站源的进程级缓存（`_pythonCatVodProbed` / `_pythonCatVodResolved`）；普通 `.js`/`.py` 站点不为用不到的依赖清单付探测成本 |
| `resolve()` 分流 | `File(p.join(spider.rootDir, 'loader.json')).existsSync()` 为真即「CatVod 壳站点」，走依赖感知路径；失败文案也独立（「未找到带 CatVod 依赖（requests/Crypto/lxml）的 Python 运行时」） |

`loader.json` 之所以可靠：`direct_spider_registrar.dart` 只在 CatVod 壳目录里写它
（内容 `{loaderUrl, loaderSha256}`），普通直连站源目录没有这个文件。

### 12.11.3 修法二：程序自己建托管 venv（用户诉求原文）

用户原话（2026-10-24）：「如果需要迁移啥的不应该程序自己做嘛？」
——本机没有任何解释器带齐依赖时，程序应当自己把运行时准备好，而不是让用户看 code=3。

新增 `apps/desktop-flutter/lib/services/python_runtime_provision.dart`：

| 函数 | 职责 |
| --- | --- |
| `prepareCatVodPythonRuntimeSync(...)` | 先对每个候选跑依赖探测，**任一候选已带齐就返回 `ready`（不建 venv、不联网）**；否则委托下面这个 |
| `provisionPythonRuntimeSync(...)` | 五步：①已有 venv 且探测通过 → `ready`；②逐个候选 `-c "import venv"` 选 base；③`-m venv <runtimeRoot>`；④`-m pip install --disable-pip-version-check --no-input --retries 1 --timeout 10 <packages>`；⑤**pip 退出码 0 仍逐模块复验**，仍缺则 `verifyFailed` |
| `ProvisionStatus` | `ready / created / noBasePython / createFailed / installFailed / verifyFailed`——每一步失败都有独立状态与末尾输出摘要，不静默降级 |
| `isManagedPythonExecutable(executable, runtimeRoot)` | 用 `p.equals(p.normalize(...))` 判断是否托管 venv 内的解释器 |

安装清单钉在 `catVodPythonPackages = ['requests', 'pycryptodome<4', 'lxml', 'beautifulsoup4']`：

- **`pycryptodome<4` 是实测结论**，不是保守选择：4.1.0 的 `Crypto.Cipher.PKCS1_OAEP`
  没有 `MGF1`（真身在 `Crypto.Signature.pss`），而 inner 插件里真实存在
  `mgfunc=lambda seed, size: PKCS1_OAEP.MGF1(seed, size, SHA256)` → 4.x 必 `AttributeError`。
  实测 `pycryptodome 3.24.1 → hasattr(PKCS1_OAEP,'MGF1') == True`，
  `4.1.0 → False`。
- `beautifulsoup4` 只进**安装**清单：本机解释器带齐前三个即视为可用，
  不为单个站源付「建 venv 30 秒」的代价。

接线在 `apps/desktop-flutter/lib/state/app_state.dart` 的 `_preparePythonRuntimeQuietly()`
（由 `_attachSiteService()` 后台发起）：

- 只在配置里确实存在 CatVod 壳站点时触发；
- `Isolate.run` 执行（venv + pip 是分钟级同步调用，绝不能跑 UI isolate）；
- 成功 → `LocalSpiderCommand.preferPythonExecutable(result.executable)`
  + `_router.invalidateRuntimes()` + `notifyListeners()`；
- `resetCache()` 会删掉整个 cacheDir（含 `<cacheDir>/python`），所以那里要重置
  `_pythonRuntimeTried` 并重新发起，否则「清一次缓存 → 所有 CatVod 站点 code=3」。

### 12.11.4 修法三：首屏不再抢跑注册

`_attachSiteService()` 先 `unawaited` 发起直连站源注册，紧接着就装配好 `_siteService`，
首页在注册落定前就发 `home`。日志实测（`C:/Users/Maple/AppData/Local/webhtv-pc/logs/webhtv-pc.log`）：
注册只要 **116 ms 也照样抢跑**——这是**顺序缺陷**，不是耗时缺陷。

修法（等待而非重试；重试要猜延迟，会先闪一次红横幅）：

```dart
Future<void>? _directReady;                       // 发起时保存
static const Duration _directReadyTimeout = Duration(seconds: 8);
void _kickDirectRegistration();                   // 幂等发起
Future<void> _waitForDirectRegistration();        // 等落定，超时只记日志
```

`loadHome` 开头只在「该站点确实依赖注册结果」时等待：

```dart
if (directSpiderKind(site) != null && _router.directSpiders[site.key] == null) {
  await _waitForDirectRegistration();
  if (_disposed) return;
}
```

真 Android jar（`directSpiderKind` 返回 null）**不等待**，仍立即如实报「桌面 JVM 不支持」——
不得把真实崩溃伪装成等待。

### 12.11.5 修法四：解释器探测加进程级缓存（这是用户报的卡死）

用户反馈（2026-10-24）：「打包了一个正式版随便点两下就卡死了，之前是不会的」。
根因不是日志落盘（`log_service.dart` 已是内存即时 + 200 ms 批量追加），而是：

```
ui/app.dart:760  state.siteItems.isEmpty        ← build 里同步求值
  → app_state.dart:1492-1505 get siteItems      ← 逐站 classifySite，无缓存
    → spider_router.dart:433-448 _classifyLocal
      → spider_registry.dart:323-340 resolve()
        → _pythonCommand()                      ← 当时没有缓存
          → firstUsablePython() → pythonWorks() → Process.runSync(exe, ['--version'])
```

163 个站点里 83 个 `runtime=python`，每次重建约 `83 × 250–350 ms ≈ 20–29 s`
串行阻塞 UI isolate。日志佐证：`22:31:05.792826 直连站源已注册 83 个` →
`22:32:06.847846 站点选择器打开`（缺口 61.05 s，且 header 是在算完 `siteItems` 之后才打的）。

修法：`_pythonCommand` 加 `_pythonProbed` / `_pythonResolved` 进程级缓存
（与 `spider_process.dart` 的 `_resolvePython` 同款），并在托管运行时就绪、
解释器集合变化时用 `preferPythonExecutable()` / `invalidatePythonCache()` 主动失效。

注意：`siteItems` 的**无缓存遍历**本身仍是结构性成本（163 次 `existsSync` + 12 个 csp 站点的
`probe.json` 读取），只是量级从秒降到毫秒；彻底消除需要给 `siteItems` 加失效缓存。

### 12.11.6 落地文件

| 文件 | 改动 |
| --- | --- |
| `apps/desktop-flutter/lib/services/python_runtime_provision.dart` | **新增**（托管 venv + pip 安装 + 依赖探测，永不抛异常、纯同步、须放 Isolate） |
| `apps/desktop-flutter/lib/services/spider_process.dart` | 新增 `catVodDependencyModules` / `dependencyProbeScript` / `pythonWorksForCatVod()` / `preferPythonExecutable()` |
| `apps/desktop-flutter/lib/services/spider_registry.dart` | 新增 `_pythonCommandForCatVod()` 与 `resolve()` 的 CatVod 分流；`_pythonCommand()` 加进程级缓存 + `invalidatePythonCache()` |
| `apps/desktop-flutter/lib/services/spider_router.dart` | 新增 `invalidateRuntimes()`（runtime 快照了构造时的执行命令，托管运行时就绪后必须重建） |
| `apps/desktop-flutter/lib/state/app_state.dart` | 新增 `_directReady` 等待闸门、`_preparePythonRuntimeQuietly()`、`resetCache()` 后重建托管运行时、`loadHome` 门控 |
| `apps/desktop-flutter/test/phase9_python_provision_test.dart` | **新增** 8 个用例 |

### 12.11.7 验收

| # | 口径 | 结论 |
| --- | --- | --- |
| 1 | 解释器已带依赖时不建 venv、不联网 | ✅ 用例「本机解释器已带依赖时不建 venv、不联网」（断言 calls 里没有 venv/pip） |
| 2 | 缺依赖时按 `pycryptodome<4` 安装并复验 | ✅ 用例「候选都缺依赖时建 venv 并安装，安装清单钉住 pycryptodome<4」 |
| 3 | pip 失败 / 复验失败的区分 | ✅ `installFailed`（回显 pip 末尾输出）与 `verifyFailed`（列出缺失模块）各一例 |
| 4 | 所有候选都建不了 venv 时不抛异常且逐个回显原因 | ✅ `noBasePython`，message 含「所有 Python 候选都不可用」+「py.exe -3」+「Unable to create process」 |
| 5 | 依赖探测不执行模块顶层代码 | ✅ 用例断言脚本含 `find_spec` 且**不含字面量** `import requests` |
| 6 | 静态分析 | ✅ `dart analyze` → `No issues found!` |
| 7 | 新用例 | ✅ `flutter test test/phase9_python_provision_test.dart` → +8 All tests passed! |

### 12.11.8 与 Win-box 的关系

Win-box 走的是**相反**的方向：它把嵌入式 CPython 3.11.6 与
`requests 2.31.0 / lxml 4.9.2 / pycryptodome 3.19.1` **随包分发**
（`resources/python/`），用户机器上是什么解释器与它无关。
本项目不随包分发 **Python** 解释器（`windows-release.yml` 明确不捆绑 Python / JDK 运行时；
Node 运行时随包内置在 `runtime/node/node.exe`，但本节的 Python 供给与它无关），
所以只能走「选本机已带依赖的解释器 → 否则自己建 venv」这条路——
这是**同一问题的两种解法**：Win-box 用体积换确定性，本项目用首启一次性的
venv 创建换包体积。可借鉴的仍是它的**参数自适应**思想
（`_invoke_variants` 用 `inspect.signature().bind()` 试探参数个数，
本项目对应的是 `webhtv_catvod.py` 的契约探测与这里的候选逐个探测）。


