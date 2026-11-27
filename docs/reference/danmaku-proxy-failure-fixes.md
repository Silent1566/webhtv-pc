# 弹幕失败的三条根因与修复（PC）

2026-11-27。用户报告播放时日志出现「弹幕加载失败」，要求定位并解决。结论：三处 PC 侧缺陷可修，一处是站源自身没有弹幕（不可修）。

## 1. 本机代理端杀掉复用连接（已修）

同一弹幕地址连续请求，唯一变量是「是否复用 socket」：

| 方式 | 结果 |
| --- | --- |
| 复用连接（默认 keep-alive） | 5 次里 3 次 200、**2 次 ECONNRESET / 连接被挂断** |
| 每次新开连接 | 4 次全 200 |

根因：`SpiderProxyHttpServer` 在每次响应后 `Transfer.close()` → `exchange.close()` 关掉 TCP，但响应头按 HTTP/1.1 默认 keep-alive 下发，没告诉对端不可复用；Dart `HttpClient` 连接池复用这条已死的连接就报错，最终显示成「网络不可达或 DNS 失败」。

修法：`Connection: close` 显式下发（正常响应与 `simple()` 错误响应都加）。
证据：`ProxyHttpContractTest` 新增 raw socket 断言（先红：`proxy advertises Connection: close so clients never reuse`；后绿：`PASS ... assertions=996`），探针从 3/5 变为 **5/5 干净 200**。

## 2. 拿运行时异常当「形态不符」的判据（已修）

`CatVodSpiderAdapter.proxy` 原以 `catch (IllegalStateException)` 兜底切到实例调用，于是**路由自己抛错**也被当成「不是静态形态」，同一个请求又往实例打一次（`routerContract` 的 `fallbackCalls` 变 1，错误被吞成一次静默重试）。

修法：改成**形态先判**（`DexNative.proxyMethod` 存在 → 走路由并让异常上抛；否则走实例），不再用异常做分派。
证据：该契约断言先红（`router invocation error never falls back`）后绿，同一轮 `PASS ... assertions=996`。

## 3. 超时预算比站源真实耗时短 + 文案丢失真因（已修）

实测 `AppRJ` 的 `do=danmu` 单次 9.5–27 秒（内部两路搜索 + 上游匹配 + 抓取），而弹幕请求预算是 15 秒；超时被归到 `danmakuNetwork`，再由 `describeDanmakuFailure` 按类别取文案，于是「超时」与「DNS 失败」显示成同一句。

修法：

- `danmakuRequestTimeout(uri)`：本机数据面 `/s/<token>/proxy` 用 45 秒，弹幕库仍用 15 秒（`DanmakuService.siteSourceTimeout`）；
- 超时文案带上实际预算（`弹幕下载超时（45s 无响应）`）；
- `describeDanmakuFailure` 优先用 `AppError.message`，再补「不影响视频播放」，不再一律播报类别文案。

证据：`test/danmaku_timeout_policy_test.dart` **7 条**（慢站源在长预算下能成功、库地址仍在短预算内超时、三种失败文案各带真因）；连同 8 个相关套件 **171 条全绿**；`dart analyze lib test` 无问题。

## 4. 不可修：站源本身没有弹幕

同一参数在 Android（5554 实测）与 PC 真实 `AppRJ` 上都返回 `200`、45 字节空 XML、0 条，正文 SHA-256 一致 `dc22626a…`，匹配该 jar 的固定空回退。所以修完上面三条，站源最多从「非 2xx」变成「文件为空」，**弹幕仍由弹幕库提供**（实测 42,301 条）。详见 `android-danmu-source-comparison.md` 与 `apprj-danmu-artifact-findings.md`。

## 交付边界

- `host.jar` 已重编（234 KiB），随仓库分发，运行时直接读取；Dart 侧改动需重编 Windows 包才生效。
- 未做：多集连续播放的稳定性压测；`AppRJ` 上游（360 影视 / 金蝉 / 弹幕匹配服务）为何取不到数据只能到「固定空回退」为止，未继续追。
## 5. 第五处：本机代理数据面被缩成单通道（HTTP 503，已修）

用户第二次实测的日志：

```
弹幕加载失败 source=http://127.0.0.1:2297/s/…/proxy?… 弹幕加载失败：弹幕下载返回 HTTP 503
```

503 不是站源给的，是本机代理自己的闸门：`SidecarServer` 用 manifest 的 `limits.concurrency`（该站点为 **1**）同时作为代理 HTTP 的 worker 数与信号量。任何两个重叠的请求必有一个被 `simple(exchange,503,"代理并发已达上限")` 拒掉。

修法：把「IPC 并发」与「数据面并发」分开——新增 `SidecarServer.proxyPlaneConcurrency(declared)`（`clamp(4, 32)`），只供 `SpiderProxyHttpServer` 使用；manifest 的 concurrency 仍只限制站源方法并发。

证据：新增 `planeConcurrencyContract`，用 declared=1 的 IPC 并发发起 **3 条并行代理请求**——修复前 **RED**（`concurrent plane request 2 served, not rejected`），修复后 **GREEN**（`PASS … assertions=1005`）。同轮契约里依赖旧单通道语义的 `status(entry2,503)` 改为 200，并把「有界」交给 clamp 断言。

取舍：数据面上限 32 条并发，仍受作业对象内存/CPU 硬限制约；比「单通道必然 503」更接近安卓 NanoHTTPD 的并发语义。
## 6. 「起播定位未生效」的误报（已修）

日志里 `wanted=153181ms actual=170061ms` 重复出现（20.6 → 37.4 → 63.0 → 81.1 → 135.9 → 153.2 秒），偏差随续播位置变大。根因不是 seek 落错：引擎在开播那一刻上报的位置与 wanted **完全一致**（`引擎时长 … position=153181ms`）。

问题在**取数时机**：`_load()` 先 `await _configureSubtitles()`、`await _configureDanmaku()`（本次实测弹幕库装配约 17 秒），之后才读 `_controller.position` 做漂移校验——读到的已经是播放进度。于是正常续播被判成失败，并对用户弹出假的「未能跳到该位置，已从头播放」。

修法：开播结果一返回就记下落点 `landingPosition`，校验只用它。

证据：新增用例「弹幕装载耗时期间播放推进，不得把续播误报成起播定位失败」（用一个挂起的弹幕源把时序做确定性），修复前 **RED**（`Expected: false Actual: true`，即警告照旧触发），修复后 GREEN；原有「定位真的没吃上要提示」的用例保持绿灯（两条方向都锁住）。`player_quality_ui_test.dart` 16 条全绿。

## 7. 同一集重复装配弹幕（已加诊断，待确认）

同一集出现两次相同的 `弹幕文件没有可用条目`（11:53:33.4 与 11:53:37.9），中间弹幕库已成功加载 42,299 条。`_load()` 是唯一装配弹幕的地方（`player_page.dart:1984`），因此这段时间里执行了两次装载；可疑入口是 `didUpdateWidget`（`widget.request` 变化即 `_load()`）与会话更新路径（会清空 `_danmakuItems` 再装载）。

本次**没有**盲目加去重：如果真凶是「清空后不再装载」，去重反而会让弹幕整集消失。先加一条 `弹幕装配 generation=… 源=N` 的日志，下次日志里出现两次相同 generation 即可定性，再决定是防重复装载还是别在会话更新时清空。
### 12:16 实测：重复 `_load()` 被排除

新日志只有一条 `[danmaku] 弹幕装配 generation=1 源=1`（12:17:01.95），因此**不是**装载跑了两次。但站源失败仍有两次（12:17:34.89、12:17:43.50），中间夹着弹幕库成功（12:17:36.66，42,298 条）。说明第二次请求来自 `_loadDanmakuSource` 的另一条调用路径，而不是 `_configureDanmaku`。

处置：给该函数的每个调用点加 `origin` 标签并写进日志（`configure` / `auto:memory` / `auto:candidate` / `search:selected` / `sheet:switch`）。下次日志里失败行的 `origin=` 会直接指出是哪条路径，再决定修哪。**仍然没有加去重**——在不知道来源之前去重可能让整集弹幕消失。

同一份日志的正面结果：`[player] 恢复播放进度 episode=1 position=182781ms`（12:17:36.65）——**不再出现「起播定位未生效」，也没有假的「已从头播放」提示**，说明 §6 的修法在真实机上生效。
### 12:48 实测：第二次请求来自面板选源（假设正式排除）

```
12:48:09  弹幕加载失败 origin=configure        ← 自动装配试站源，0 条
12:48:11  弹幕已加载 items=42299 origin=auto:memory  ← 内存匹配命中，库成功
12:48:14  弹幕加载失败 origin=sheet:switch     ← 面板里手动选了站源那一行
```

`sheet:switch` 的唯一入口是 `showDanmakuSettingsSheet(onSelectSource: _selectDanmakuSourceForSheet)`（`player_page.dart:2956`）。所以“同一集出现两次站源请求”= 自动装配一次 + 面板选源一次，**不是装载跑了两次**。`origin` 标签保留（每集一行 debug，成本可忽略，排障时直接指出路径）。

顺带查清一处行为：`_loadDanmakuSource` 失败分支会清空已加载弹幕（`player_page.dart:2896`），因此在面板里选中这个 0 条站源，会把刚加载好的 42,299 条清掉。**已向用户说明并给出三种修法，用户选择「先不动」**——本文件只记录决定，不再改代码。

仍是未解/不在范围内的独立问题：每次启动都报「上次未正常退出」；`[realtime] 心跳失败`；换线路瞬间的 `401 token 无效`（属预期会话吊销）。
