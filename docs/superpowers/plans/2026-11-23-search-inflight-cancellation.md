# 搜索在途取消 Implementation Plan

> **For agentic workers:** Use subagent-driven-development for the disjoint tasks below. Each worker owns its red/green tests; Lead owns final acceptance.

**Goal:** 搜索取消、取代、清空、配置失效、dispose 和单站超时向下传递到真实 HTTP/IPC 请求，同时隔离无关请求、缓存及旧批次结果。

**Architecture:** Hybrid：Lead 先冻结请求级取消信号，再并行接入 HTTP、运行时和搜索状态。保留 SiteRuntime 的现有接口，对可取消搜索增加可选的独立能力接口，避免破坏现有自定义运行时。HTTP 使用 http 1.6 的 AbortableRequest，不关闭共享客户端；sidecar 发送现有协议的 requestId 取消通知，停止本地等待而不因取消强杀共享宿主。

**Tech Stack:** Flutter 3.47.5 / Dart 3.13.4 / package:http 1.6.0 / webhtv-ipc-v1。

**Spec:** `docs/reference/xiugou-tv-borrowings.md` §2.3、§2.4、§5；`docs/webhtv-pc-design.md` §9.5、§14.1。

## Global Constraints

- 独立实现行为，不复制上游 GPL 代码。
- 不新增搜索 UI、不更改排序、并发设置、分页耗尽检测或默认 20 秒搜索预算。
- 不关闭缓存运行时使用的共享 HTTP client，不取消同宿主的无关请求。
- 第三方阻塞代码不保证物理中断；日志不得把“停止等待/已发取消”说成“已终止”。
- 用户取消、取代、清空不计站点失败；真正超时保留 siteTimeout 语义。取消/超时后的迟到响应不得写缓存或发布旧结果。
- 不改真实配置、不请求真实影视源、不新增依赖、不提交或推送。仅在当前 wt/dev3 工作树内修改。

## Frozen Interfaces

`lib/core/request_cancellation.dart` 由 Lead 拥有：

```dart
class RequestCancellation {
  bool get isCancelled;
  AppError? get reason;
  Future<void> get whenCancelled;
  void cancel([AppError? reason]);
  void throwIfCancelled();
  Future<T> bind<T>(Future<T> operation);
}
```

第一次 cancel 保存唯一原因，默认 siteCancelled。whenCancelled 正常完成（不是 error future）。bind 观察迟到错误，不假装终止底层工作。

HTTP task 产出：

```dart
Future<SiteResult> HttpApiClient.execute(HttpApiCall call, {
  required String siteKey, VodIdentityHint? identity,
  RequestCancellation? cancellation,
});
Future<SiteResult> CatHttpClient.call(CatHttpCall call, {
  required String siteKey, VodIdentityHint? identity,
  RequestCancellation? cancellation,
});
```

Runtime task 产出：

```dart
abstract interface class CancellableSearchRuntime {
  Future<SiteResult> searchCancellable(Site site, {
    required String keyword, int page = 1, bool quick = false,
    required RequestCancellation cancellation,
  });
}
Future<SiteResult> SpiderRouter.search(Site site, {
  required String keyword, int page = 1, bool quick = false,
  HttpApiClient? client, RequestCancellation? cancellation,
});
```

State/service task 产出：`SiteService.search` 增加可选 `RequestCancellation? cancellation`，原有参数及调用方保持兼容。其他任务不得编辑这些文件；接口问题回报 Lead，不在边界外抢修。

## Task 1: Shared cancellation primitive (Lead, run 1/3)

**Files:** `lib/core/request_cancellation.dart`、`test/request_cancellation_test.dart`。

- [x] 建立 idempotence、first reason、success、prompt cancellation、late error 消费、pre-cancelled bind 测试。
- [x] 执行红测：缺少取消类型；同时既有 phase2_search_test 27 例通过。
- [x] 最小实现；4 例通过。

## Task 2: HTTP request cancellation (HTTP worker, run 1/3)

**Boundary:** `lib/core/http_api.dart`、`lib/core/cat_http.dart`；测试仅 `test/search_http_cancellation_test.dart`。

- [x] 先写行为红测：loopback 服务器收到请求后延迟响应，取消应断开对应连接，同客户端另一正常请求仍成功。覆盖 HTTP GET/POST、Cat HTTP、响应 body 在途以及预取消不发送。
- [x] 用 AbortableRequest 和已冻结信号实现 request-local abort；保留请求编码、header、诊断、proxy client 注入、错误分类和大小校验。
- [x] HTTP 内部超时也终止该请求，不关闭共享 client。取消错误保持 siteCancelled，超时 siteTimeout。
- [x] 运行新增测试与已有 HTTP/Cat HTTP 相关测试，报告命令、红绿输出、文件清单。

## Task 3: Runtime/IPC request cancellation (runtime worker, run 1/3)

**Boundary:** `lib/services/spider_router.dart`、`lib/services/sidecar_runtime.dart`、`lib/services/spider_process.dart`；测试仅 `test/search_runtime_cancellation_test.dart`、`test/search_ipc_cancellation_test.dart` 及该两测试专用 support 文件。

- [x] 先写红测：相同进程多个请求，仅目标 requestId 收到取消；无关请求跨越原 2 秒强杀宽限后仍成功。
- [x] 增加 CancellableSearchRuntime 能力接口，HTTP/Cat HTTP/sidecar 实现；不改 SiteRuntime.search 签名。SpiderRouter.search 下传信号，legacy runtime 至少停止等待且如实记录不支持中止。
- [x] 增加 SidecarProcess/SpiderHost 按请求 abandon：取消 pending/timer、通知 remote、立即结束本地等待，不升级为 killTree。保留现有整站 dispose/cancelInflight 行为。
- [x] 冷启动前后检查信号；取消启动等待不能阻止无关请求完成初始化，也不能启动结束后补发旧搜索。
- [x] 验证请求身份唯一、迟到响应安全；新测试与既有 IPC/sidecar/router 测试通过。若真实宿主协议取消会连坐，给出文件/证据 hand_back，不越界修改宿主。

## Task 4: State/service lifecycle cancellation (state worker, run 1/3)

**Boundary:** `lib/state/app_state.dart`、`lib/state/search_state.dart`、`lib/services/site_service.dart`；测试仅 `test/search_inflight_cancellation_test.dart`、`test/search_service_cancellation_test.dart`。

- [x] 先写红测：取消不再等待慢请求、取代/清空/配置失效/dispose 与分页在途都触发取消；单站 timeout 释放本请求且不阻塞队列。
- [x] 为每个在途搜索请求创建信号，将它登记到当前搜索生命周期；每站 timeout 用 siteTimeout 原因取消，finally 清理 timer 和登记。
- [x] 新搜索、clearSearch、cancelSearch、配置替换与 dispose 取消对应旧请求；已完成首轮搜索后的在途分页也可取消。保留已发布快照。
- [x] SiteService.search 在缓存读取、router 返回、健康统计及缓存写入处守卫取消；用户取消不得记录站点失败，迟到成功不得覆盖缓存。
- [x] 旧批次 finally 不得清理新批次分页登记；维持所有现有排序/缓存/并发/分页规则。
- [x] 执行新增测试与 phase2_search_test、search_thread_test，报告红绿证据。

## Task 5: Lead acceptance and docs

- [x] 审阅所有最终差异，逐条核对上述取消、隔离、分类、缓存/健康与生命周期标准。
- [x] 独立运行新测试、搜索回归、HTTP/Cat HTTP、IPC/sidecar 风险相关测试和 flutter analyze；失败必须修正并复验，不带已知缺陷交付。
- [x] 更新 reference §2.4 的实施状态、证据和“第三方阻塞无法保证终止”限制。无 UI 变化，不需要视觉截图。

## Decisions

- Settled: 文档 §2.4 的按请求取消是本次范围；核心聚合搜索已具备，不重写。
- Assumed: 不做新的运行时分档预算；只有明确新需求才重新评估。
- Ruled out: 整宿主 kill 作为搜索取消实现、复制上游代码、新 UI 或依赖。
- Completion: 真实本地 HTTP 中断、IPC 按 id 通知且无连坐、旧结果/缓存受保护、风险相关回归与静态检查通过。

## Acceptance Record (2026-11-23)

All implementation tasks accepted at run 1/3; no re-dispatch required. Lead reviewed the complete production diff and the test/fixture evidence. Final stable command ran the six new test files plus `core_protocol`, `config_and_site`, `phase2_cathttp`, `http_debug_log`, `phase2_ipc`, `sidecar_idle_recycle`, `spider_debug_log`, `phase2_spider_page`, `phase2_search`, `search_thread`, `search_paging_state`, `search_result_filter`, `phase3_search_page`, `source_swap_quick_search`, `search_thread_ui`, `phase3_js_spider`, `phase3_jvm_spider`: **460 passed**, exit 0. Full `flutter analyze --no-pub`: **No issues found**; `git diff --check` clean.

Independent read-only reviewer inspected every changed production file and all new tests/fixtures: Spec 0 findings, Standards 0 findings; separately ran 99 tests successfully in a temporary isolated copy. Tracked lib diff SHA-256 `de04eaa9d912fe80e28367a90548a03fabd9db13688e637ec4868c5407a10196`; new signal source SHA-256 `13330fa1645e05ca951d471bebed9cef97ebbd9a7a05b673a53131879b146ee1`.

Review findings routed and resolved: preserve superseded `cancelled=false`; guard synchronous listener cancellation before page send; remove test warnings while strengthening injected-client identity coverage. Environment-only missing resolved dependency fixed with `flutter pub get --enforce-lockfile`; tracked dependency declarations/lock unchanged. No unresolved defects identified.

Limitations remain per spec: arbitrary blocking third-party code is not guaranteed to stop physically; Linux/POSIX cancellation fixtures executed, Windows native execution not performed; real content sources not requested. Existing JS/JVM integration regressions passed, cancellation handlers inspected but new target-cancellation fixture only executed against controlled and actual Python children.

Delivery: keep changes uncommitted in the existing `wt/dev3` worktree; no merge, push or cleanup of host-managed workspace.
