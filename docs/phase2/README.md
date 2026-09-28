# Phase 2 计划(MVP-B · Windows)

- 状态:进行中
- 日期:2026-09-27
- 对应设计文档章节:§21 Phase 2、§9、§11、§14、§10.3、§17.2
- 上游:`docs/phase1/README.md`(MVP-A 已完成,11 项门禁全绿)

## 0. 本阶段目标

把 MVP-A 的「单站点垂直闭环」升级为**可日常使用**的 MVP,并建立**可验证的 Spider
兼容基础**。设计文档 §21 Phase 2 的验收原文:

- HTTP API 源可浏览、搜索、播放。
- 播放进度可恢复。
- CatSpider HTTP 有至少 3 个可重复测试样本。
- Spider 崩溃、超时、取消和资源超限被隔离。
- 代理安全测试通过。
- 主流程无阻塞式崩溃。

## 1. 现状盘点(基于代码与 Phase 1 证据)

### 1.1 已具备

| 能力 | 证据 |
| --- | --- |
| 时间轴持久化与恢复 | `lib/services/storage.dart` 的 `history` 表;Phase 1 集成测试断言 `history-persisted progress=50% completed=true`;`PlaybackRequest.startPosition` |
| 播放决策与解析优先级 | `lib/core/playback.dart`;94 个单元测试覆盖 `parse`/`jx`/`flag`/`playUrl` |
| 多线路/多剧集解析 | `parsePlayLines`;fixture `result-multi-flag.json`、`result-multi-episode.json` |
| 站点健康统计 | `storage.dart` 的 `site_health` 表 + `SettingsPage` 的 `_HealthTable` |
| 搜索(单站点 + 短缓存) | `SiteService.search`;`search_cache` 表;测试「命中缓存后不再发起请求」 |
| 多配置记录与切换 | `storage.dart` 的 `configs` 表 + `ConfigPage._SavedConfigs` |
| 倍速 | `PlayerController.setRate` + 播放器页倍速控件 |
| 自动连播 / 上下集 / 线路切换 | `player_page.dart`(§10.3 标注为「产品基础已就绪」) |
| 快捷键 | `buildPlayerShortcuts`(空格/方向键/音量/M/上下集/F11/Esc) |
| 详情、历史、收藏、设置、日志页 | `lib/ui/*_pages.dart` |
| ABI Schema(消息 + manifest) | `packages/spider-abi/schema/{message,manifest}.schema.json` + 契约测试 |

### 1.2 缺口(本阶段要补)

| # | 缺口 | 设计文档依据 | 现状 |
| --- | --- | --- | --- |
| G1 | **无搜索页** | §21 Phase 2「搜索与并发取消」、§14.1 | `ShellSection` 只有 browse/history/favorites/settings/logs;无 `SearchPage`;无多站点并发/取消 |
| G2 | **无 IPC 运行时** | §9.3、§9.3.1 | `packages/spider-abi` 只有 Schema,无 `initialize`/长度前缀帧/requestId/cancel/心跳实现 |
| G3 | **无 CatSpider HTTP 客户端** | §9.4 | `spider_router.dart` 把 `/spider/` 判为不可用并注明「MVP-A 不加载」 |
| G4 | **无进程隔离宿主** | §9.8、§18.2.1 | 无 sidecar 进程管理(内存/CPU/并发限制、崩溃隔离、工作目录清理) |
| G5 | **无本地代理** | §11、§9.6 | 无 `127.0.0.1` 代理服务、无 HLS 清单重写、无 Range、无 token 校验 |
| G6 | **无 Spider 管理页** | §17.2 | 无运行时/权限展示与启停入口 |
| G7 | **播放进度恢复未在真实 UI 闭环验证** | §15 | 存储层与 `startPosition` 已就绪,缺「进入播放器自动续播」的 UI 路径测试 |
| G8 | **真实源协议差异未确认** | §19.4、§7.5 | Phase 1 记录:真实源不带 `ac` 返回真实首页,带 `ac=videolist` 回显参数 |

## 2. 实施顺序

按「先锁契约、再打通一条最小链路、再补安全边界」推进,每步都必须有可复现测试。

### 步骤 1:搜索页与多站点并发(MVP-B 用户可见能力)

1. 新增 `SearchPage` 并加入 `ShellSection`(侧栏「搜索」)。
2. `AppState.searchAll`:并发查询所有 `searchable` 站点,受配置上限约束。
3. 结果按站点分组;单站点失败显示错误状态而**不阻塞**其他站点(§14.3)。
4. 支持取消:页面离开或新查询到达时,取消未完成请求且**不投递**已取消结果(§14.1)。
5. 复用 `search_cache` 短缓存。

验收:fixture 多站点并发搜索、单站点 502 不影响其他站点、取消后无迟到结果投递。

### 步骤 2:`webhtv-ipc-v1` 契约与最小宿主(§9.3.1)

1. 按 `message.schema.json` 实现长度前缀帧编解码(`Content-Length` + 空行 + UTF-8 JSON)。
2. `initialize` 交换 ABI major/minor、capabilities、权限与限制;major 不匹配拒绝加载。
3. requestId 非空且进程生命周期内不复用未完成 ID;统一错误对象含
   `code/category/message/retryable/userVisible/siteKey/requestId/details/diagnosticId`。
4. `cancel`(`$/cancelRequest`)、`shutdown`、心跳;超时后依次取消 → 宽限 → 终止进程树。
5. 限制单帧/单响应/累计输出大小;stdout 只承载协议帧,非协议数据判定为协议污染并终止。

验收:契约测试覆盖帧编解码、版本不匹配、未知 ID、非法帧、cancelled、超时、崩溃。

### 步骤 3:最小 sidecar 宿主 + 进程隔离(§9.8)

1. 用一个**测试用 sidecar**(不需真实站源)验证生命周期:启动 → initialize → home →
   cancel → shutdown。
2. 每站点独立临时工作目录,退出后清理;不继承宿主完整环境变量(白名单传递)。
3. 内存/CPU 时间/并发/响应大小限制;崩溃只影响该站点并指数退避,禁止无限快速重启。
4. 日志按大小轮转并脱敏(不出现 Cookie/Authorization/签名参数)。

验收:同一个 sidecar 崩溃/超时/取消/资源超限四种场景被隔离且主程序存活。

### 步骤 4:`webhtv-cat-http-v1` 客户端(§9.4)

1. 实现 `/init`、`/home`、`/category`、`/detail`、`/search`、`/play` 的 POST + JSON。
2. `api` 末尾 `/` 归一化;非 2xx → `SPIDER_HTTP_ERROR`(不返回空字符串冒充成功)。
3. `{code:0,data}` 解包;`data` 为数组包装为 `{list:[...]}`;非 0 code → 业务错误。
4. `page` 非法值按 1 处理并记录诊断。
5. 404/501 或明确业务错误 → `SPIDER_UNSUPPORTED`,**不转成空列表**。
6. `spider_router.dart` 的 `classify` 对 `/spider/` 形态在 capability 校验通过后标记可用。

验收:**至少 3 个可重复fixture样本**(成功、业务错误、非 2xx)各走完整 home/search/play。

### 步骤 5:本地代理(§11、§9.6)

1. 仅监听 `127.0.0.1`,默认随机端口。
2. 每次播放创建 `sessionId` + 高熵 token,限定站点与播放范围;停止/超时/退出即失效。
3. Range 代理返回 206 + 正确 `Content-Range`;HLS 主清单→子清单→分片保持同一会话。
4. 每次 DNS/连接/重定向后重新校验 scheme/host/port/IP;默认拒绝 loopback/链路本地/私网/
   云元数据地址。
5. `Cookie`/`Authorization` 默认仅同源传播;跨 origin 重定向移除敏感 Header。
6. 日志只记录 token 指纹、目标主机、状态、字节数、耗时。

验收:非本机拒绝、无 token 拒绝、206+Content-Range 正确、20 并发分片不崩溃、
日志不泄露敏感信息、代理关闭后端口释放。

### 步骤 6:Spider 管理页与进度恢复 UI 闭环

1. Spider 管理页:展示运行时、ABI 版本、capability、权限、健康状态,并支持启停。
2. 播放器进入时按 `history` 自动续播(§15.2「继续播放」),并加集成测试。

## 3. 验收门禁(本阶段完成判据)

在 Phase 1 的 11 步门禁基础上,新增:

| 门禁 | 判据 |
| --- | --- |
| 搜索并发与取消 | fixture 多站点;取消后无迟到结果;单站点失败不阻塞 |
| IPC 契约 | 帧编解码、版本协商、cancel、超时、崩溃、协议污染全覆盖 |
| 进程隔离 | 崩溃/超时/取消/资源超限四场景,主程序存活 |
| CatSpider HTTP | ≥3 个可重复样本(成功/业务错误/非 2xx) |
| 代理安全 | 非本机拒绝、token 校验、Range 206、并发 20 分片、日志脱敏 |
| 进度恢复 UI | 集成测试断言「进入播放器自动从历史位置续播」 |
| 无阻塞式崩溃 | 全流程(导入→浏览→搜索→详情→播放→代理)无 UI 卡死 |

`tools/` 下按 Phase 1 的方式扩展验收脚本,证据写入 `docs/phase2/evidence/`。

### 3.1 门禁落地状态(2026-09-28)

自动化测试已覆盖上表全部门禁。除 `dart analyze` 外,`apps/desktop-flutter` 的
`flutter test` 共 **203** 个用例,`integration_test/mvp_a_flow_test.dart` 在 Windows
真实窗口 + 真实 media-kit 播放器上 **8** 个用例全绿。

| 门禁 | 覆盖位置 | 关键断言 |
| --- | --- | --- |
| 搜索并发与取消 | `test/phase2_search_test.dart` | 并发峰值=2(真并发);取消/被取代批次**不投递**结果;单站点失败保留错误且不阻塞;结果按配置顺序稳定 |
| IPC 契约 | `test/phase2_ipc_test.dart` | 帧编解码任意切分、ABI 协商、cancel、超时、崩溃、协议污染、未知 ID |
| 进程隔离 | `test/phase2_ipc_test.dart` | 崩溃/超时/取消/资源超限四场景主程序存活;Job Object 连**孙进程**一并终止 |
| CatSpider HTTP | `test/phase2_cathttp_test.dart` | 成功/业务错误/非 2xx/未实现四族各走完整 home+search+play;404→`SPIDER_UNSUPPORTED`、非 2xx→`SPIDER_HTTP_ERROR`,均不空列表化 |
| 代理安全 | `test/phase2_proxy_test.dart` | 只监听回环、非本机拒绝、无/伪 token 401、Range 206+`Content-Range`、20 并发分片、日志无 token 明文与 Cookie、关闭后端口释放 |
| 进度恢复 UI | `integration_test/mvp_a_flow_test.dart` 「进入播放器自动从历史位置续播」 | 真实点击剧集按钮进入 `PlayerPage`,`request.startPosition` 等于历史位置(证据 `resume-ui ... startPosition=12s`) |
| 无阻塞式崩溃 | 同上 + `test/phase2_search_test.dart` | 全流程无卡死;单站点失败后其他站点仍可恢复 |

本轮修复的缺陷(均有测试锁定):

1. `sidecars/spider-host-python/webhtv_ipc.py`:wire 握手方法名应为 `initialize`
   (原仅注册 `init`),否则所有 sidecar 调用以 `SPIDER_UNSUPPORTED` 失败。
2. `lib/core/ipc_protocol.dart`:帧头解析静默忽略含冒号的未知行,导致真实 stdout
   协议污染被当作合法帧(§9.3.1)。现只接受 `Content-Length`/`Content-Type`,其余判污染。
3. `lib/services/spider_process.dart`:`_checkResponseSize` 重复完成同一 Future,
   把超限响应变成 `Bad state: Future already completed`(§9.3.1)。
4. `lib/services/spider_process.dart`:`_onExit` 未显式终止作业,`kill-on-close`
   因宿主仍持句柄而不生效,崩溃会留下**永久孤儿孙进程**(§18.2.1)。
5. `lib/state/app_state.dart`:`proxyDecision` 未先经策略校验就改写播放地址,
   使本机/私网等被策略拒绝的目标从「可直连」变成「永远 403」,直接导致播放失败。
   现策略拒绝时保持直连(§9.6、§11.3.1)。
6. `lib/core/cat_http.dart` 与 `lib/services/spider_router.dart`:`looksLikeCatHttp`
   与 `_classifySpider` 判定不一致,且 `/spider`(无尾斜杠)未被识别为可用(§9.4)。

> 注:门禁以 `flutter test` + `flutter test integration_test -d windows` 作为可复现入口,
> 并已封装为一键验收脚本 `tools/phase2/run_windows_acceptance.ps1`(结果写入
> `docs/phase2/evidence/windows-acceptance.txt`)。
> 单元测试自带进程内 fixture 服务(随机端口),可独立运行;集成测试需要先启动
> 外部 fixture 服务:`py -3 -m tools.fixture_server.server --port 18080`(脚本会自动启动)。

## 4. 风险与开放问题

1. **Windows 隔离强度(§18.2.1)**:独立子进程只提供崩溃隔离,**不自动**提供文件系统与
   网络沙箱。必须先实测 Restricted Token / AppContainer / Job Object / 子进程树终止的实际
   效果;若无法可靠阻止读取同一用户可访问的文件,文案必须写「尽力隔离」,默认禁用不可信
   远程 Spider。
2. **真实源协议差异(G8)**:需在步骤 4 之前用真实样本确认 `ac` 参数语义,避免把 fixture
   行为当成协议事实。若确为真实差异,应作为兼容性样本库条目记录,而不是直接改协议实现。
3. **`app.so` AOT 快照大小**:Release bundle 78.3 MB,若引入 sidecar 需评估整体体积。

## 5. 平台范围声明

本阶段仍**只交付 Windows**。Linux/macOS 的构建、打包、代理与隔离验证不在范围内;
发布文案不得声称已支持。
