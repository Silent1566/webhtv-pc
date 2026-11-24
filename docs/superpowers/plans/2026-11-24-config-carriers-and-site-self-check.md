# 配置载体与主动站点体检实施计划

**Goal:** 按 `docs/reference/xiugou-tv-borrowings.md` §2.2、§2.5 独立实现有界配置载体解码和用户触发的分阶段体检。

**Architecture:** Hybrid。Lead 固定请求级取消能力接口与 SiteService 接线；配置、运行时适配、体检调度/界面三项文件互斥并行。保留既有配置校验、健康统计和 Spider 隔离，不新增执行引擎。

**Tech Stack:** Flutter/Dart；AES 使用维护中的纯 Dart 密码库而非复制参考项目算法；现有 HTTP/IPC 取消。

## 决策记录

- 已定：用户明确选择同时支持 AES／宽松 JSON；以仓库参考文档为依据，独立实现、不复制 GPL 源码。
- 假设：宽松语法仅增加注释、单引号、标识符键、尾逗号；AES 仅支持 2423 载体，不支持任意密文破解。
- 排除：JS/eval/表达式/函数、PHP/新运行时、自动导入即体检、详情/播放验证、终止共享宿主。
- 完成：安全负例、三入口与刷新回归、分阶段结果/取消/超时/并发与界面测试通过，Lead 读最终差异并独立复验。

## 固定限制与接口

- 解码前后各最多 8 MiB；最多 3 层载体；JSON 最大容器深度 64。完整消费输入，禁止接受尾随表达式；不得在异常、日志、保存/导出中泄漏凭据。
- 载体：完整单一 `<pre>` 包裹、纯/标记 Base64（保留当前 URL 的既有前缀兼容性）、2423 hex AES-128-CBC，严格 PKCS7 padding 与 UTF-8。
- AES 线格式：hex(`$#` + key + `#$`) + hex(ciphertext) + hex(iv13bytes)；UTF-8 key/IV 按参考协议右补 ASCII 0 至 16 字节/超长截断；验证分隔符、hex、块长，错误不回显载体。
- 严格 JSON 优先；宽松语法只支持 // 与 /* */ 注释、单引号、`[A-Za-z_$][A-Za-z0-9_$]*` 键、尾逗号。数字/布尔/null 仍按 JSON；拒绝非有限数、裸值、代码和不完整输入。凭据重复字段不得被归一化掩盖。
- 体检仅当前配置内用户选择站点，最多 100 站，默认并发 2，每站整个流程预算 30 秒，最多尝试 2 个非配置/登录/设置分类。每站有终态，空响应/漏结果不算通过。
- `CancellableProbeRuntime.homeCancellable(Site, {required RequestCancellation cancellation})`。
- `CancellableProbeRuntime.categoryCancellable(Site, {required String typeId, required int page, Map<String,String> filters = const {}, required RequestCancellation cancellation})`。
- `SiteService.home(Site, {RequestCancellation? cancellation})` 与 `category(..., {RequestCancellation? cancellation})`：有能力时下传，无能力时仅停止等待，取消不写失败/迟到成功统计。原有 SiteRuntime 接口不变。

## 任务书与验收

### A. Lead 核心接缝（run 1）
- [x] 先写首页/分类取消后不写迟到健康记录用例，确认缺接口失败。
- [x] 创建 `lib/services/cancellable_probe_runtime.dart`；仅增加 `site_service.dart` 可选参数与能力分派。
- [x] 运行新用例及既有 search service 取消回归：10/10。

### B. 配置载体（run 1/3）
- 边界：core/config_loader.dart、config_parser.dart，新增 decoder/cipher/lenient 文件、pubspec.yaml/lock，配置专用测试。
- [x] 先验证载体、三入口与负例失败，再实现独立数据解码；不改动 TMDB 凭据的安全语义。
- [x] 跑配置、刷新、凭据专项回归，检查格式与 analyze；提供 AES 独立已知向量和错误消费/预算证据。

### C. 运行时适配（run 1/3）
- 边界：services/spider_router.dart、sidecar_runtime.dart 和体检运行时专用测试/fixture。不改核心接缝。
- [x] HTTP API、Cat HTTP、Sidecar 实现可选能力，复用已有请求取消机制；不得关闭共享 client/host。
- [x] 以本地 HTTP 和宿主 fixture 证明按请求取消/超时、同宿主无关请求存活；旧搜索契约不退化。

### D. 体检调度与入口（run 1/3）
- 边界：新增 services/site_self_check.dart、ui/site_self_check_panel.dart，修改 ui/diagnostics_pages.dart，体检专用测试。
- [x] 先测试运行时/首页/分类、空内容、分阶段错误、有限分类、并发、超时、取消与迟到隔离。
- [x] 在现有站点健康页增加选择、主动运行、取消、进度与逐站结果；醒目说明会联网/执行用户 Spider 及不检查播放。
- [x] 页面销毁/配置服务变更取消旧任务；不覆盖当前浏览状态。沿用设计 token，不重设计既有页面。
- [x] 提供行为测试与渲染截图（优先同场景 Before/After；纯新增界面可 After 加说明），窄窗无 overflow。

### E. Lead 验收与交付（run 1）
- [x] 逐项读最终差异，发现问题回原任务修复（每任务总计最多 3 runs）。
- [x] 独立运行风险面测试、analyze、格式和 whitespace 检查；检查视觉证据。
- [x] 同步参考文档实施状态与限制；不自动提交或推送。
