# xiugou-tv 对照与借鉴清单

- 性质：配置/运行时、播放恢复、备份/WebDAV、更新/打包的源码对照研究。初次交付只做分析；后续用户分别选择“备份消费项完整校验、读取与解压预算”（§7）和“搜索在途取消”（§8），其余仍是建议而非兼容性承诺。
- 固定基线：本项目 `f0bf45c2c6d0aea97d850ce8abd6970cb3a7716b`；上游 [qfw66/xiugou-tv](https://github.com/qfw66/xiugou-tv/tree/d57c239d23081e4902068d2081515fa1ac85ff8e) @ `d57c239d23081e4902068d2081515fa1ac85ff8e`（提交日期 2026-11-22）。行号以这些基线为准，后续按符号检索。
- 方法：固定上游提交、按目录读取源代码，与本项目当前实现逐行对照；不以 README 宣称或旧差距文档替代证据。未启动应用、执行第三方脚本/Spider、请求真实影视源或验证随包运行时。
- 路径约定：未写仓库前缀的本地 `core/`、`state/`、`services/`、`ui/` 均相对 `apps/desktop-flutter/lib/`，`test/` 相对 `apps/desktop-flutter/`；上游链接均为固定提交 permalink。
- 静态局限：“具备”只指可核实代码路径，不代表真实站源实测可用；固定上游提交 tracked Dart `*_test.dart` 与 `.github/workflows` 均为 0，但存在 Python、Worker 和打包脚本测试，不能说上游没有任何测试。本地列出的测试只阅读、未执行。
- 边界：`PRODUCT.md:25-43、78-84` 与 `README.md:7-9、57-69` 要求不内置内容/配置/爬虫，Spider 进程隔离、失败可诊断，不承诺全部 TVBox 源可用。上游 [LICENSE:1-2][u-license] 为 GPL v3 文本；这里只标来源，不作法务判断或建议直接复制。

## 1. 总体判断与优先级

两边均为 Flutter/Dart + media_kit/mpv，参考距离比 Electron 项目短（本地 `apps/desktop-flutter/pubspec.yaml:14-19`；[上游 pubspec.yaml:18-37][u-stack]），但状态管理和宿主接口不同，不能按文件直接移植。**优先借鉴边界、状态机和负例，不替换本项目的产品架构。**

优先级：P0 = 直接复用前的门槛；P1 = 建议优先评估；P2 = 后续按需求/前置条件推进；不重复 = 保留已有能力。成本仅按改动面分小/中/大，不推算性能或工期。

| # | 主题 | 分类 | 成本 | 建议 |
| --- | --- | --- | --- | --- |
| 1 | 常规配置导入、仓库展开、失败保护 | 已等价具备（核心能力） | 小：复用已有链路 | 不重复 |
| 2 | 非标准配置载体解码 | 已实施（受限，见 §9） | 中：解码、入口识别、限额、凭据清理与负例测试 | 已完成 |
| 3 | 全局搜索增量、并发、失败与批次隔离 | 已等价具备（核心能力） | 小：保留现有实现与测试 | 不重复 |
| 4 | 搜索取消下传、超时终止与运行时分档预算 | 按请求取消已接通（§8）；分档预算未调整 | 中：跨状态/服务/HTTP/sidecar 契约 | 已实施取消部分 |
| 5 | 用户触发的分阶段站点体检 | 已实施（受限，见 §10） | 中：复用路由，新增调度与结果模型 | 已完成 |
| 6 | XPTV/NowShowTime 与 PHP 脚本适配 | 上游路径可核实，本地收益待验证 | 大：新 ABI/宿主能力或解释器 | P2 |
| 7 | 自动换线的唯一同集确认与显式进度传递 | 现有换线之上的增量 | 已实施（§3.1） | 已完成 |
| 8 | seek 失败恢复、播放错误确认 | 具体恢复出口缺口/策略增强 | 已实施（§3.2–§3.3） | 已完成 |
| 9 | 代理重解析、播放中跨站换源 | 受控恢复的增量 | 大：依赖身份、搜索与历史事务 | P2 |
| 10 | 备份消费项完整校验与解压预算 | 消费项与预算已实施（§7）；完整语义审计未纳入 | 中：有界读取/ZIP展开、负例测试 | 已验收部分 |
| 11 | 下载镜像普通失败/成功历史 | 现有更新之上的增量 | 中：路由排序、缓存、失败分类 | P2 |
| 12 | WebDAV 自有媒体目录浏览/播放 | 确认未见实现；非云备份 | 中：目录、凭据、播放请求边界 | P2 |
| 13 | 打包共享规则与敏感文件负例 | 已有白名单之上的局部增强 | 小/中：规则复用、负例测试 | P2 |

## 2. 逐项依据与取舍

### 2.1 常规导入和失败保护：不应重新开发

- **上游**：[config_repository.dart:782 `ConfigRepository.loadFromInput`][u-input]、[:1095 `_resolveContent` / :1149 `_commitSnapshot`][u-commit]，输入识别、仓库解析、解析后保存再应用快照。
- **本地**：`apps/desktop-flutter/lib/core/config_loader.dart:50 ConfigSource.parse、:533 ConfigImportService.import`；`core/config_parser.dart:48 parseConfigDocument、:83-93` 识别仓库；`state/app_state.dart:4833-4857 AppState.importConfig` 先导入/展开/校验再更新当前配置。
- **测试证据**：`apps/desktop-flutter/test/config_and_site_test.dart:56` 三入口，`:288-318` 非空 msg 拒绝且保留记录，`:320` 仓库回退；是现有测试断言而非此次运行结果。
- **收益/成本/风险/优先级**：保留既有链路，成本小；不要为“支持 URL/本地/文本、多源仓库”再造 Repository。等价不表示仓库嵌套策略相同；尤其不可照搬上游宽松解析而绕过本地 `config_parser.dart:71-78` 的 msg 拒绝语义。建议“不重复”。

### 2.2 配置载体解码：确认缺口，但只解码数据、不求值代码

- **上游**：[config_decoder.dart:25 `ConfigDecoder.decode`][u-decoder] 的真实顺序是去 `<pre>`、尝试 2423 外壳，再严格 JSON／8 位字母数字加 `**` 标记 Base64／宽松 JSON／整体 Base64；最终只接受 Map/List。[:71 `_tryMarkerBase64`][u-decoder] 并非任意前缀都可识别。
- [config_cipher.dart:21 `ConfigCipher.tryDecryptCbc`][u-cipher] 核验 hex/分隔符/块长度，再以载体携带的 key 与尾部 IV 进行 AES-128/CBC 解码；不是通用加密配置破解能力。[lenient_json.dart:13 `LenientJson.parse`][u-lenient] 是解析器，不是 JS eval。
- **本地逐行差异**：`core/config_loader.dart:581 ConfigImportService.import` 将抓取文本直接送 `core/config_parser.dart:48-68 parseConfigDocument`；后者 `:52` 严格 `jsonDecode`，非 Map 在 `:62-68` 拒绝。`core/tmdb_credential_ingress.dart:27-33 extractRootAndStrip` 同样先严格 JSON。BOM/GBK/gzip 支持是传输解码，不等于上述正文载体支持。
- **收益/成本**：允许用户已有的部分非标准数据载体进入现有配置校验，而不引入 Spider 执行；中，需同时处理粘贴入口（`ConfigSource.parse:55-77` 把非 JSON 字面量视作路径）、解码大小/深度与凭据剥离。
- **风险/优先级**：宽松解析可能掩盖错误；上游 `LenientJson.parse:13-17` 解析一个值后未检查 EOF，不宜照搬容错边界。须保留原始错误、msg 拒绝、失败不覆盖，并使用合成正/负例验证。P1，先定义允许的载体与严格失败规则。
- **实施状态（2026-11-24）**：已按受限数据载体实施，见 §9；未复制上游代码，仍不承诺真实源兼容率。

### 2.3 全局搜索核心：已经具备，不用重写一个 SearchEngine

- **上游**：[search_engine.dart:80 `SearchEngine.searchAllIncremental`][u-search] 按完成发批次，单站异常留在 `SearchBatch.error`，取消后不发新批次；[:193 `searchAll`][u-search] 复用增量路径。
- **本地**：`state/app_state.dart:6528 AppState.searchAll` 已有可调并发、范围/屏蔽/可用性筛选、健康排序；`:6608-6676 worker` 逐站投递并留失败，`:6612-6613、6664-6668` 阻止取消/旧批次继续投递；`state/search_state.dart:182 SearchPagingState` 还有分页与重复页耗尽检测。
- **测试证据**：`test/phase2_search_test.dart:97、118、144、187-208、211、348、373` 覆盖排序、失败隔离、并发、取消/取代与分页；`test/search_thread_test.dart:163、178、212` 断言默认/设置/显式并发上限。
- **收益/成本/风险/优先级**：避免以“新增聚合搜索”为题重复开发，成本小；现有分页、缓存、分组不能因移植较窄的上游接口倒退。建议“不重复”，只评估下一项差量。

### 2.4 搜索取消与预算：可核实的增量，不是“取消按钮缺失”

- **上游**：[search_engine.dart:150 `_searchSiteOutcome`][u-search-budget] 为每站创建子令牌，取消联动并在超时 `child.cancel()`；[:50-59、101-128][u-search-budget] 区分普通请求与 Companion 预算、限制 Companion 在途数。
- [cms_json_api.dart:473 `_search` / :488-489 取消桥接][u-cms-cancel] 令牌触发 Dio 取消；[companion_spider_api.dart:502-529 `_callSpiderOnce`][u-rpc-cancel] 生成 rpcId，取消本地连接并发 `_cancelRemote(rpcId)`。此处可借鉴“跨层取消身份”，不能承诺任意第三方阻塞代码可中断。
- **本地逐行差异（研究基线，后续取消实施见 §8）**：`state/app_state.dart:6616-6618 AppState.searchAll` 仅包 `Future.timeout`，未传专属 client；`:6712-6722 cancelSearch` 只标记批次。`services/site_service.dart:360-370` **已有** `HttpApiClient? client` 并下传路由（`:403`），不能说 HTTP 完全不能取消；缺的是聚合搜索链路接线及 sidecar 统一的按请求取消契约。
- **收益/成本**：让取消不仅“不显示结果”，还能对支持取消的网络/宿主请求发出真实终止信号；分档预算能表达冷启动与普通 HTTP 的不同阶段。中，必须跨状态、缓存、路由、HTTP/IPC 一起设计；无需照搬上游 20/110 秒和并发 6。
- **风险/优先级**：不得取消同一宿主中的无关请求；非 HTTP 阻塞需如实标“已停止等待、宿主仍运行”，不能假报终止。P1；验收用本地慢响应 fixture 检查断连/取消 RPC 和旧结果不污染，不以真实源测试为前提。

### 2.5 主动体检：缺的是用户触发的检查闭环，不是健康记录

- **上游**：[settings_page.dart:869 `_openSelfCheck`][u-check-entry] 只选择 `usesCompanion` 站点；[SiteSelfCheck.java:156 `probeSite`][u-check] 加载 Spider、调用 home，跳过“配置/登录”分类，再试有限分类，实际内容条数决定可用/降级；[:79-110 `run`][u-check] 按站限时、取消标记、汇总失败/超时。
- [site_self_check_dialog.dart:67 `_run`][u-check-ui] 分批执行，整批无结果或漏站逐条补失败，避免“没回包=通过”。但 [SiteSelfCheck.java:211-213][u-check] 吞单分类异常；[companion_spider_api.dart:175-198 `runSelfCheck`][u-check-api] RPC 异常返回空报告，不宜照搬其错误信息收敛方式。
- **本地**：`services/site_service.dart:70-125 SiteService._record/_call/home` 是真实调用后的被动统计；`ui/diagnostics_pages.dart:904-912 _healthSummary` 明确浏览/搜索/播放后开始累计。`services/csp_jar_probe.dart:410 CspJarProbe.materialize` 是导入材料化/静态兼容预检，不是对每站主动跑首页与分类的体检。
- **收益/成本**：用户可主动发现“有分类却无内容”、启动/加载失败，且得到每站结构化结果；中，可复用 `SiteService` 与现有进程隔离路由，新增调度和报告，不要再建另一套执行引擎。
- **风险/优先级**：体检会执行用户 Spider 并联网，不能默认导入即跑；需用户主动触发，具备范围/预算、取消和原始分阶段错误。上游只证明首页/分类，未检查详情/播放，不能标签为“已验证能播”。P1；本次没有执行任何体检。
- **实施状态（2026-11-24）**：已按用户主动、分阶段、可取消范围实施，见 §10；仍不检查详情/播放，不能据此宣称“已验证能播”。

### 2.6 新格式：有实现路径，不等于生态全面兼容

- **XPTV/NowShowTime 上游链路**：[vod_config.dart:499 `VodConfig.fromJson` / :559 `_websitesAsSites`][u-formats] 将无 sites 的 `websites[{id,name,jsUrl}]` 映射为 type 3、csp 占位 api、脚本 ext；[:536 `_withUniqueKeys`][u-formats] 补无 key 站点标识。[DexSpiderLoader.java:206-207 `registerBuiltinFactories`][u-factories] 路由到 [XptvSpider.java:116 `isSupportedScript` / :142 `create`][u-xptv]：ext 必须 HTTP(S) .js，api 不含 .js，正文需命中特定函数名且排除 drpy rule；不是“所有 JS 都可运行”。
- **契约而非名称**：[XptvSpider.java:25-33][u-xptv] 及 [:216、280 `homeContent/searchContent`][u-xptv] 实现 XPTV `getConfig/getCards/getTracks/getPlayinfo/search` 与 NowShowTime `getCategories/getVideosByCategory/getVideoDetail/getPlayUrl/search` 映射；后者搜索仅第一页。
- **PHP 上游链路**：[DexSpiderLoader.java:198-199][u-factories] → [PhpSource.java:14 `matches` / :20 `prepare` / :74-76][u-php-source]：去查询串后 .php，读取原始代码且需 `<?php`；[PhpRuntime.java:23 `call`][u-php-runtime] 每次起受预算约束的 PHP 子进程；[php/bridge.php:12-31][u-php-bridge] 强制 PHP 8.3+、实例化 `Spider` 并调用白名单方法。type 4 在 [vod_config.dart:56-58 `Site.usesCompanion`][u-route] 明确走 HTTP，.php 远程 JSON 接口不等于本地执行 PHP 源码。
- **本地对照**：`core/config_parser.dart:83-100 parseConfigDocument` 仅 sites/urls，websites-only 被拒绝；`sidecars/spider-host-js/sandbox_worker.js:369-384 SHORT_TO_SCRIPT/isSpiderLike` 与 `:595-618 scriptArgs` 是 TVBox 契约，未映射上述 XPTV/NST 函数；`services/spider_registry.dart:359-487 LocalSpiderCommand.resolve` 只分发 Python/Node/JVM，末尾明确拒绝其它 runtime，没有 PHP 解释器路径。
- **收益/成本/风险/优先级**：潜在扩展用户已有配置生态，但增益取决于可信样本和实际需求，待验证；大，配置映射之外还要提供宿主 API/ABI、安全权限与本地运行时管理。P2，先做不联网的合成契约测试与需求取证；不照搬上游内置别名/爬虫、不把脚本放主进程、不默认下载解释器，不能宣称本地现有 JS 支持已等价支持 XPTV。

## 3. 播放链路：借鉴失败边界，不重做播放器

### 3.1 已有能力与真正的换线增量

- **不重复**：本地 `core/playback_fallback.dart:137-180 decidePlaybackFallback` 已有线路→解析源→原地重试与累计上限；`ui/player_controller.dart:1594-1664 openWithRetry` 已有网络/超时重试。相关测试为 `test/playback_fallback_test.dart:102、160`；回退默认 off 的契约见 `test/player_options_fallback_default_test.dart:15`。不是“本地没有自动换线”。
- **上游增量**：[line_switch_planner.dart:75-98 `matchEpisodeOnLine`][u-line-match] 只接受唯一同名/归一化同名匹配，歧义跳过；[app.dart:1496-1554 `_autoSwitchToLine`][u-line-open] 显式传当前位置并保留倍速。
- **本地差异**：`ui/player_episode_panel.dart:70-86 locateEpisodeInLine` 取首个同名或同集号，未命中返回 0；`ui/player_page.dart:1972` 自动回退调用 `_switchLineResumingEpisode`，`:5636-5644` 复用该匹配；`:3938-3957` 又按换集语义清除 startPosition/resumeSeed，没有显式传换线前真实 playhead。不能据此断言一定从头播，目标线路历史仍可能介入。
- **建议/成本/风险**：P1，中。为自动恢复单独定义“唯一同集＋显式位置”的语义，避免找不到同集却自动播第 1 集；不能一刀切修改手动选集回落行为。严格匹配可能少接受命名不规范的线路，必须可解释地跳过。
- **实施状态（2026-11-25）**：已实施，且只改自动恢复这一条路径。`core/playback_line_match.dart` 的 `locateUniqueEpisodeInLine` 要求**恰好一处**命中（集名优先、其次集号，集号口径复用 `core/tmdb_title.dart#sourceEpisodeNumber`），未命中或歧义都返回原因并跳过该线路；`player_page.dart` 的自动回退换线改走 `_switchLineResumingEpisodeStrict`，找不到唯一同集就放弃这一档并回到失败收尾。换线时把引擎真实位置（`enginePosition`，不是跳转占位值）与当前倍速显式传给 `_openTarget`/`_load`，不再依赖目标线路自己的历史。手动选集/面板预览的回落行为**未**改动。

### 3.2 seek 失败的两个可恢复出口

- **上游**：[seek_recovery_controller.dart:33-113][u-seek] 保存原位置/目标位置、generation 和 seeking/failed 状态；非暂停时须目标附近真实继续推进才成功。[mpv_player_engine.dart:927-977][u-seek-engine] 接入 `retrySeek` 与 `returnToPreSeekPosition`。
- **本地**：`ui/player_page.dart:1536-1586 _seekFromUser` 已有缓冲内 seek、缓冲外串行重开及仅保留最后目标；`ui/player_controller.dart:282-336` 区分真实位置与占位；`player_page.dart:995-1012` 有到位与超时撤遮罩。缺的是保存原位置的 failed 状态和“重试目标/返回原位置”出口，不是没有 seek 防护。
- **建议/成本/风险**：P1，中。保留本地成熟的缓冲外重开策略，只补恢复状态机；暂停/缓冲/预览跳跃不能伪装真实到位，旧媒体的失败不可污染新媒体。本地 `test/player_seeking_buffering_test.dart:109、140` 与 `player_seek_pseudo_end_test.dart:84、96` 仅覆盖部分属性/源码契约，不等于这些新行为已验证。
- **实施状态（2026-11-25）**：已实施。`core/seek_recovery.dart` 排除暂停/缓冲/引擎定位，成功必须在目标 ±3s 内出现真实连续推进；20s 后仍未到位或卡在目标值时给出失败。`_seekFromUser` 即使在默认拖动暂停时也登记原位置；跨缓冲仍串行重开，只保留最后目标，每次显式移交恢复记录与代际。普通换媒体取消旧跳转所有者，不再靠全局重开标记继承。失败保留记录，后续真的播到目标会撤销「重试跳转 / 回到原位置」横幅；遮罩超时只撤遮罩，不绕过暂停/缓冲判据。未做真实站源拖动实测；当前真实 `PlayerPage` + 受控引擎/时钟的行为测试覆盖默认拖动、迟到自愈、持续缓冲、换线落点/倍速和自然片尾计时器释放。5 个门控 open 场景因时序不稳定已从 CI 移除，连续目标与跨媒体所有权时序仍缺少稳定的页面级自动验收，不能把纯策略测试视为等价覆盖。

### 3.3 播放错误确认：先形成可信诊断，再触发自动动作

- **上游**：[playback_error_gate.dart:63-92][u-error-gate] 待定期新错误更新文本但不延长计时；位置继续推进可拒绝提交致命错误、或解除已提交错误。[mpv_player_engine.dart:407-471][u-error-engine] 已接错误/位置流与会话代际。
- **本地**：`ui/player_controller.dart:1174-1178` 仅记录引擎告警，不直接将普通 error 判为失败；`ui/player_page.dart:1914 _tryPlaybackFallback` 消费的是 `PlayerLoadOutcome`。不能声称“第一条告警会锁死本地播放”。
- **建议/成本/风险**：P1，中。借鉴错误风暴去重、运行中真正停止推进的确认、恢复事件；先做纯策略测试。暂停、seek 或网络缓冲时不推进不等于致命错误，需结合用户意图和媒体代际，不直接复制阈值。
- **实施状态（2026-11-25）**：已实施。`core/playback_error_gate.dart` 只累计连续可观察的 8s 窗口：暂停/缓冲/定位时清除计时基线，恢复后重计；向后跳转重置位置基线，位置推进 ≥1s 撤销待定或已提交错误。错误风暴只更新文本、不延长活跃窗口。`PlayerController.playbackErrorRevision` 为每个实际引擎 error 事件递增，页面按事件编号消费（不按文本封禁），同文错误自愈后再次发生仍可确认，操作失败不会冒充引擎 error。页面由位置通知及有界生命周期定时器驱动，仅撤销闸门自己写入的失败提示。未对真实断流源验证；已用纯策略序列、真实控制器事件流和真实页面确认→自愈→同文再失败、暂停恢复、向后 seek 行为验收。

### 3.4 代理恢复与跨站换源：保留更强的本地身份边界

- **代理**：[companion_proxy_recovery.dart:55-88][u-proxy-recovery] 对部分本地代理失败做单飞和跨重播预算（默认 15 分钟最多 3 次、间隔至少 1 分钟），[app.dart:1933-2038][u-proxy-refresh] 重解析并带原位置。本地 `services/spider_proxy_session.dart:36-40、132-158、174-195` 已校验 token/host 代际/owner，失效则安全终止；`test/spider_proxy_session_test.dart:212-225` 明确不在 renew 失败时自动重建。增量是已知身份的有预算重解析，不是放松租约；HTTP 403 或任意 loopback 不足以授权重启运行时。P2，中，依赖可信错误状态。
- **跨站**：[cross_site_search_service.dart:51-79][u-cross-search] 是用户请求的受控检索；[cross_site_failover_planner.dart:406-446][u-cross-plan] 拒绝年份/类型冲突；[playback_source_actions.dart:415-552][u-cross-action] 对歧义交用户确认、切换前取最新进度、失败恢复快照。本地 `ui/browse_pages.dart:3281-3306、3463-3483` 已有换源搜索与续同集，`core/history_cross_site.dart:229-246` 已有唯一集映射；增量是播放中受控操作与事务回退。P2，大，不做无感自动替换。
- **避免误读**：上游 `AutoLineSwitchController` 虽有 `onSameSiteExhausted`，但 [app.dart:422-446][u-auto-wiring] 未传该回调。固定提交可核实的是手动跨站换源，不能宣称同站耗尽自动跨站接管已实现。

## 4. 数据、更新与工程：只补差量

### 4.1 备份已有校验/回滚；值得借鉴的是校验覆盖闭环

- **已有能力**：`services/backup_service.dart:70 createBackup`、`services/storage.dart:1219 AppDatabase.backupTo` 已用 VACUUM INTO 快照；`core/backup_manifest.dart:231 validateBackup` 已校验版本、路径、大小和 SHA-256；`state/app_state.dart:3858 restoreBackup` 已有逐域回滚。`test/phase9_backup_test.dart:207、238` 和 `ai_parity_business_integration_test.dart:620` 有闭环/回滚测试。不是只有导出；异常回滚也不等于断电原子事务。
- **静态确认的缝隙**：`core/backup_manifest.dart:253-270` 只验证清单列出的文件，`:271-274` 仅要求 ZIP 集合存在数据库；`services/backup_service.dart:263-269` 仍直接消费 ZIP 里的数据库和设置。**清单漏列但 ZIP 携带的 DB/settings 可能被消费而未过该循环的哈希检查。**辅助 AI 文件已有清单成员检查（`:239-246`），不能泛称所有条目都如此。
- **上游机制**：[data_backup_service.dart:179-234][u-backup-validate] 对随后恢复的全部条目逐个校验白名单/大小/哈希/单项及总量预算，[`:436-466 _validateEntry`][u-backup-schema] 预检各数据域。可借鉴“实际消费集合必须完全受校验集合覆盖”，不搬它的 JSON 备份格式或 20 MiB 限额。
- **另一边界**：本地 `services/backup_service.dart:199-216` 先完整读文件再判 512 MiB，逐项物化解压内容，未见展开总量预算。应在读取/展开前与过程中限制压缩体、单项、数量、累计展开量，并预检 SQLite/设置语义。
- **前提与处置**：上述描述为研究基线，风险针对外部构造、修改或损坏备份，不代表正常自建备份必然漏项。后续已按用户选择补齐消费项覆盖和读取/展开预算，并运行合成恶意 ZIP fixture（§7）；没有新增 SQLite/设置完整语义审计，SHA-256 仍只证明完整性、不能认证发布者。

### 4.2 WebDAV 是用户自有媒体入口，不是云备份

- **上游**：[webdav_repository.dart:18-73][u-webdav-root] 限制同协议/主机/端口与根目录，[`:107-155`][u-webdav-list] 用 PROPFIND Depth:1，目录请求不跟随重定向并限制响应大小，条目转播放参数。
- **本地**：对 tracked 应用/脚本源码检索 `webdav|propfind` 未匹配，未见媒体目录适配；`services/backup_service.dart:164-194` 和 `ui/backup_page.dart:203-228` 是本地文件备份，不是该功能。
- **凭据**：[webdav_profile_store.dart:186-206][u-webdav-secret] 使用平台 protect/unprotect，不可用就拒绝保存；[app_data_files.dart:68-82][u-backup-secret] 排除连接凭据。未核实 Windows 原生实现，不能声称 DPAPI 已验证。目录禁止重定向不代表后续媒体/字幕不会跨域带凭据；HTTP Basic 也需 TLS 边界审查。
- **建议/成本/风险**：P2，中，需求成立时作为独立目录适配器接入既有播放队列；需跨平台秘密存储、重定向/路径越界负例。不能用这段实现承诺 WebDAV 云同步或云端备份。

### 4.3 下载镜像健康记忆，不重复已有摘要校验与 API 冷却

- **上游**：[update_mirror_health.dart:82-164][u-mirror-health] 保存成功/失败时间、失败次数、lastGood（30 分钟失败冷却）；[update_mirrors.dart:159-190][u-mirror-order] 让上次成功源优先、近期失败源排到直连后，[update_controller.dart:230-250][u-mirror-wire] 已在下载链路接线。
- **本地**：`core/app_update_network.dart:46-53 routesFor` 已有代理→直连，`services/app_update_service.dart:586-625` 已流式校验 SHA-256；`:275-282、322-325` 和 `services/app_update_cache.dart:48-53` 已有持久化 GitHub API 限流冷却。缺的只是按下载镜像普通成功/失败历史调序，不是“完全没有冷却”。
- **建议/成本/风险**：P2，中。缓存只影响顺序、不成为信任凭据；保留直连/手动重试，将取消、网络失败、限流、校验失败分开。未测量收益，不承诺下载更快或可达率更高。

### 4.4 打包与模块化：精确借鉴，而非整体重写

- **上游**：[package_tree.ps1:45-113][u-package] 共用 Include/Exclude/Unknown 路径选择与链接拒绝；[test_package_tree.ps1:102-118][u-package-test] 有嵌套 .env、未知文件、缺运行时、junction 负例；[verify_release.ps1:200-210][u-package-verify] 复用选择契约比集合/哈希。
- **本地**：`scripts/package_windows.ps1:91-122` 已有白名单、拒绝链接、sidecar 哈希；`scripts/python-runtime.lock.json:4-12` 和 `prepare_python_runtime.ps1:181-246` 已有来源/摘要/许可证与展开预算；`.github/workflows/desktop-ci.yml:143-180` 已声明门禁。P2，小/中，补敏感标记负例与共享选择规则，不搬完整打包体系，也不误禁 cacert.pem。
- **架构取舍**：可借鉴独立纯策略（换线 planner、seek/error 状态机），但不为此迁移 Riverpod/重写 AppState。上游同样有大文件：固定源代码统计 `lib/app.dart` 7326 行、`settings_page.dart` 5512 行；本地 `app_state.dart` 10100 行、`player_page.dart` 6551 行。行数不是质量分，不支持“上游整体架构/测试更成熟”的判断。

## 5. 建议任务书（仅研究结论，不代表获批实施）

| 顺序 | 有界任务与主要落点 | 核心验收标准 | 前置条件 |
| --- | --- | --- | --- |
| 0 | 明确源码/组件复用许可与范围 | 保留署名/通知，确认许可兼容、对应源码与发行义务；未明确前不复制 | 任何直接复用前 |
| 1 | 备份消费集合与预算（§7 已实施部分） | 漏列恢复载荷、超预算及矛盾 ZIP 在写入前拒绝，旧 v1/闭环不退化；新 SQLite/设置语义审计另行评估 | 本次未扩展语义审计 |
| 2 | 搜索按请求取消（§8 已实施）：AppState → SiteService/Router → HTTP/sidecar | 取消/超时能终止支持的在途工作，不影响无关请求，不投递旧结果；不能终止者如实报告 | 冻结分层取消契约 |
| 3 | 自动换线专用同集与位置：episode matcher / player_page | 重名/重集号/未命中不自动播首集；确定同集保留当前真实位置和倍速；手动选集保持既有语义 | 明确恢复与换集边界 |
| 4 | seek/error 纯策略及最小接线 | 旧代际失效；暂停/预览不假装推进；失败可重试/回原位置，错误风暴不无限延后确认 | 合成时钟/位置 fixture |
| 5 | 纯数据载体解码与主动体检，分别成任务 | 载体大小/深度/完整消费受限，保留 msg/凭据/失败保护；体检按阶段显示有限结论 | 明确允许格式/检查范围 |
| 6 | 镜像历史、WebDAV、格式适配/代理恢复分开评估 | 分别验证失败分类、凭据不外泄、ABI 负例、身份/重试预算 | 按实际需求启动，不捆绑落地 |

建议先处理外部输入与恢复正确性，再扩展媒体入口/运行时；不以“功能看起来更多”决定优先级。没有可信样本或具体需求时，不新增 PHP 解释器、不扩展完整安卓运行环境。

## 6. 许可、证据与最终审查结论

- **许可门槛（P0）**：上游为 [GPL v3][u-license]，其 [THIRD_PARTY_LICENSES.md:3-9、26-29][u-third-party] 明确组件保留各自许可并列有待核实项。本地固定树未找到 tracked LICENSE/COPYING/NOTICE 文件，这不等于本地没有权利人或自动 GPL 兼容。直接复制/修改分发需具体核对本项目许可、授权、派生/组合关系、对应源码和构建材料；进程隔离不自动免除义务。借鉴行为与独立实现不是无条件复制的借口，也不能说看过源码就自动使本项目受 GPL 约束。
- **不建议照搬**：内置别名/站源/爬虫、多播放内核（本地固定 mpv）、Windows 专属分发假设、整套状态管理、所有兼容兜底与阈值。保留本项目 Windows/Linux、进程隔离、失败如实可诊断的已确定边界。
- **证据核验口径**：3 路任务均 run 1/3 返回 ready；主审独立读取关键实现与接线，再检查文档引用/行号、变更范围。路径统计使用固定 Git 树，源码规模仅用对应文件行数；没有执行上游或本地功能测试，因此不作“测试通过/更稳定/更兼容”的结论。
- **审查发现与路由**：初次备份风险按用户选择保留分析，后续用户明确选择消费项/预算并完成 §7；搜索取消后续已接通（§8）；自动恢复同集回落/位置、seek/error 仍是未实施建议。上游宽松解析 EOF、跨站回调未接线、loopback/403 身份不足、WebDAV 凭据链未验证均排除直接照搬，不把研究建议误记为已修复。
- **未核实**：真实站源/第三方脚本兼容率、原生 mpv 错误序列、真实 WebDAV/媒体重定向、秘密保护原生实现、镜像当前可达性、发布产物与源码一致性、完整第三方许可证合规。无性能或稳定性比较结论。
- **交付/接手**：初次研究只新增本文件；后续备份修复额外修改/新增四个代码测试文件（§7），未改 UI、AppState、依赖或锁文件。其余按 §5 分拆任务，不默认扩展实施范围。

## 7. 后续实施：备份消费项完整校验、读取与解压预算

**状态：已验收。** 用户在研究交付后单独选择本项；不是对其他研究建议的实施授权。提交与 PR 状态以 Git 记录为准。实现独立使用本仓代码与 archive 依赖，未复制上游 GPL 实现。

- **修改文件**：`apps/desktop-flutter/lib/core/backup_manifest.dart`、`lib/services/backup_service.dart`；新增 `lib/services/backup_archive_reader.dart` 和 `test/backup_input_validation_test.dart`（后三项相对 `apps/desktop-flutter/`）。
- **消费项闭环**：数据库必须存在并入清单；ZIP 中存在的 settings/AI/reader/karaoke 等可恢复项都必须经过清单大小与 SHA-256 校验，不再静默忽略漏列辅助数据。可选设置确实缺失时仍返回空字节；未知安全文件可兼容存在但不扩大恢复路径。
- **默认预算**：压缩体 512 MiB（原上限保留）、原始 ZIP 条目最多 64 个（含目录）、单项展开 512 MiB、累计展开 1 GiB、manifest 1 MiB。可注入小限额作边界测试，没有新增 UI 设置。
- **读取**：同一个已打开句柄先查长度再分块读；读到限额时至多多读一个探测字节，增长超限拒绝；finally 关闭句柄。
- **解压**：先检查中央/本地元数据、原始路径/重名、特殊类型、范围/重叠与数据描述符，再展开。用增量 inflater 与自有受限 OutputStream，在字节、块、流及 LZ77 回引用的扩容/复制前检查单项和累计预算；声明大小与实际输出分别受约束。
- **兼容与拒绝边界**：正常 ZipEncoder、自有旧 v1、缺失可选设置、未知安全文件、普通数据描述符有回归；ZIP64、分卷、加密及非 STORE/DEFLATE 明确拒绝。本项不改格式版本、恢复写入/回滚事务或 UI。
- **测试可信度补强**：初版 DB 漏列 fixture 用空清单，会被旧规则提前拒绝；主审退回后改成非空 metadata 清单、实际携带但漏列 DB。临时移除新覆盖检查时两条测试均失败（validator 实际通过、readForRestore 实际返回内容），恢复检查后通过，生产文件已按字节恢复。
- **独立验收**：主审执行 `flutter test --no-pub --reporter expanded test/backup_input_validation_test.dart test/phase9_backup_test.dart test/ai_parity_business_integration_test.dart`，**70/70 通过**（新增 49，既有 21）。修改的四个文件 `dart analyze` **No issues found**，格式检查 0 改动、diff whitespace 检查通过。
- **证据位置**：`.local/backup-hardening/lead-tests-final.log`、`lead-analyze.log`；TDD/反证见 `red-initial.log`、`red-budgets.log`、`run2-red-db-coverage.log`。这里只做合成输入与真实 SQLite 闭环回归，未进行 512 MiB/1 GiB 实际内存压力测试。
- **仍不承诺**：SQLite/设置的新增完整语义审计、来源认证、断电原子恢复不在本次范围；原有辅助数据语义检查保留。预算限制解码内容量，不是整个进程的峰值内存保证。

## 8. 后续实施：搜索按请求取消

**状态：已验收。** 用户单独选择本项；独立实现取消行为，未复制上游源码。没有新增 UI、依赖或运行时分档预算，默认单站搜索预算仍为 20 秒。

- **链路与接口**：`core/request_cancellation.dart` 提供请求级信号，第一次取消保留原因并观察迟到错误；`SiteService.search` / `SpiderRouter.search` 下传信号。运行时增加可选 `CancellableSearchRuntime` 能力，保留原 `SiteRuntime.search`，兼容既有自定义运行时。
- **HTTP/Cat HTTP**：通过注入的客户端发送 `http.AbortableRequest`；取消与客户端内部超时中断对应请求（含响应正文在途），不关闭共享 client。保留 GET、form POST、Cat JSON POST、headers、代理/DoH、诊断及解析限制。超时仍归类 `siteTimeout`。不支持 abort 的自定义传输只保证停止本地等待。
- **sidecar**：`SidecarProcess.abandon(id)` / `SpiderHost.abandon(id)` 移除目标 pending/timer，发送现有 `$/cancelRequest` 并立即结束本地等待，不走原有取消后的整进程强杀兜底。请求 ID 跨运行时实例唯一；冷启动等待取消后不补发过期搜索，也不终止共享初始化。任意第三方阻塞代码不保证物理终止，日志如实报告“已停止等待、已发取消、宿主仍运行”。
- **生命周期**：取消、清空、新查询取代、配置/服务替换、数据交换和 dispose 均取消旧请求；初始搜索完成后的在途分页也能取消。保留已发布快照，旧批次不得清理新批次分页登记；同步 listener 内取消后不再发起分页。被新查询取代的旧批次保留 `cancelled=false`，与用户取消区分。
- **发布保护**：取消前检查缓存，返回后检查健康统计/缓存写入；取消后的迟到成功/失败不写缓存、不覆盖新缓存、不增加站点失败。真正超时仍记录一次 `siteTimeout` 失败，并释放 worker 继续搜索其他站点。
- **测试入口**：新增 `request_cancellation_test.dart`、`search_http_cancellation_test.dart`、`search_runtime_cancellation_test.dart`、`search_ipc_cancellation_test.dart`、`search_inflight_cancellation_test.dart`、`search_service_cancellation_test.dart`（相对 `apps/desktop-flutter/test/`）。HTTP 使用 loopback 真实断连 fixture；IPC 同时使用受控子进程及实际 Python 宿主。
- **独立验证**：主审执行 23 个风险相关测试文件，**460/460 通过**，其中新增取消行为测试 61 项（信号 4、HTTP 27、运行时/IPC 8、状态/服务 22）；覆盖既有协议、站点、缓存、分页、并发、搜索 UI、空闲回收、日志和 JS/JVM 集成回归。全量 `flutter analyze --no-pub` 为 **No issues found**，`git diff --check` 通过。独立只读复审的 Spec / Standards 均为 0 项发现，另行复跑 99 项通过，核对冻结源码摘要一致。命令输出见 `/tmp/search-lead-final-regression.log`、`/tmp/search-lead-final-analyze.log`；任务与验收记录见 `docs/superpowers/plans/2026-11-23-search-inflight-cancellation.md`。
- **审查发现与修正**：同步 listener 内取消后仍发送分页、取代批次被误标为用户取消均补行为红测后修正；最终回归基于冻结后的源码重新运行，不使用并行编辑中间态通过记录。测试环境原有依赖解析缺少已声明的 canvas_danmaku，以 `flutter pub get --enforce-lockfile` 恢复，未变更依赖或锁文件。
- **验证边界**：实际 Python 宿主证明仅目标收到取消标记、另一请求跨越 2200ms 后成功且无 killTree/kill guard；JS/JVM 取消处理器只读核对为按 id 标记，其既有集成测试已回归，但新增取消 fixture 未逐宿主重复。新增 Python fixture 在 Windows 跳过，本轮原生执行环境为 Linux；没有请求真实影视源或验证任意第三方脚本可中断。

## 9. 后续实施：有界配置载体解码

**状态：已实施并独立验收（2026-11-24）。** 用户明确选择同时加入 AES 与受限宽松 JSON；独立实现，未复制上游 GPL 代码。仍不承诺真实源兼容率。

- **单点入口**：`core/config_parser.dart` 的 `parseConfigDocument` 统一解码，URL/文件/粘贴三入口共用；`core/config_loader.dart` 不再预解包，避免 loader+parser 双层绕过预算。`ConfigSource.parse` 识别显式载体（包括残缺的 `2423`／`<pre`，据此报告载体错误而不是“文件不存在”），正常路径/URL 仍按原方式处理。
- **允许载体**：严格 JSON；完整单一 `<pre ...>...</pre>`；2423 AES-128-CBC（hex(`$#key#$`) + hex(ciphertext) + hex(13-byte IV)，key/IV UTF-8 右补 ASCII `0` 至 16 字节）；Base64 标准/url-safe/缺 padding/任意 `**` 前缀；受限宽松 JSON 的 `//`、`/* */`、单引号、identifier 键、尾逗号。
- **预算与失败**：每层/输入 UTF-8 8 MiB、最多 3 层、JSON 容器深度 64；完整消费 EOF；无 eval/JS/表达式；坏 hex/分隔符/块长/PKCS7/UTF-8、超限、超深/尾随内容均拒绝。错误不含明文或原始载体。
- **保留语义**：严格 JSON 优先，不把合法 JSON 字段中的 Base64/`**` 当包裹；`msg` 仍拒绝；TMDB 根凭据在解码后剥离，重复/转义根键仍视为多值而不产生候选；解析失败/`msg` 不覆盖原配置；仓库展开与手动/后台刷新兼容。
- **依赖**：`pointycastle ^4.0.0`（MIT，纯 Dart）提供 AES 原语；新增 `convert` 传递依赖。未复制上游 AES 实现。
- **证据**：新增 `apps/desktop-flutter/test/config_carrier_decoder_test.dart`、`config_carrier_import_test.dart`（48 项）；主审独立复跑配置/凭据/刷新 8 文件 **138/138**，最终跨模块统一回归 21 文件 **280/280**；`flutter analyze` 无问题，格式与 whitespace 检查通过。日志 `.local/config-carriers-lead-review.log`、`.local/final-consolidated-tests.log`、`.local/final-analyze.log`。
- **边界**：粘贴纯 Base64 需解码后像 JSON/载体且长度 ≥16 才识别为内联；`<pre>` 支持引号属性，不承诺无引号属性值内含 `>`；AES 只解声明格式，不是任意密文破解。未请求真实影视源验证。

## 10. 后续实施：手动分阶段站点体检

**状态：已实施并独立验收（2026-11-24）。** 用户主动触发；复用现有运行时/隔离路由，不新建执行引擎；不检查详情、搜索或播放。

- **入口与范围**：站点健康页顶栏固定「手动体检」入口，点击打开独立检查页，无需翻过长表格；仅当前配置站点，显式选择（单站/全选/清空），每批最多 100 站、同站去重；默认并发 2、每站总预算 30 秒；最多检查 2 个非“配置/设置/登录”分类。
- **阶段**：运行时可用性 → 首页 → 分类（最多 2 个，首个有内容即停止）；每站/每阶段保留成功、空内容、失败、超时、取消、条目数/分类数与耗时。
- **结论口径**：首页和分类都有内容才算“内容检查通过”；部分阶段有内容为“有限可用”；有分类无内容不算成功；空内容与失败分开；文案明确不验证播放。结果不等于已添加站点，也不改变当前浏览/播放站。
- **取消与隔离**：用户取消停止排队与在途等待；每个未完成站进入取消终态；旧批次 generation 作废，迟到结果不写入；页面销毁/服务身份变更取消旧批次。HTTP/Cat HTTP 按请求 abort，sidecar 只对目标 rpcId 发 `$/cancelRequest`，不杀共享宿主；第三方阻塞代码仍可能继续，UI 如实显示。
- **统计**：体检调用真实写入被动健康统计；返回健康页立即重新读取统计。健康页/面板文案已标明“手动体检”也是累计来源，并说明批次结果与历史统计口径不同。
- **布局修正（2026-11-24）**：健康诊断取消 900px 表单限宽，以 24px 边距使用窗口空间；逐站明细按列宽分配，宽窗显示全部七列，窄窗顶部常显横向滚动条并支持鼠标拖拽。站点显示名称，完整标识/名称与错误可悬停查看。98 站场景有 1280×806 暗色、640×720 亮色 Before/After 对照，位于 `.local/health-layout-{before,after}-{dark-wide,light-narrow}.png`。新增 `site_health_layout_test.dart` 验证入口始终可达、列宽/滚动、真实 SQLite 统计刷新。
- **筛选（2026-11-24）**：逐站明细支持名称/站点标识模糊搜索（忽略大小写）与首页、分类、详情、播放四个环节的组合筛选；累计记录按“有成功 / 有失败 / 全部成功 / 全部失败 / 暂无数据”区分，混合成败不会被误判为纯成功或纯失败。手动体检结果支持名称、总体结论与运行时/首页/分类阶段状态组合筛选（成功、失败、空内容、超时、取消、进行中、未检查），不虚构详情/播放结果。两处显示匹配数并在筛选生效时提供一键重置；筛选只作用于结果行，源场仍为全局概览，不改变选站、进度、重跑/重试范围或健康统计。
- **证据**：新增 `apps/desktop-flutter/lib/services/site_self_check.dart`、`lib/ui/site_self_check_panel.dart`、`lib/ui/health_filter_controls.dart` 与 `site_health_layout_test.dart`、`health_filters_test.dart`；健康页/体检专项主审独立复跑 **40/40**，最终跨模块统一回归 22 文件 **290/290**，`flutter analyze` 无问题。截图 `.local/site-self-check-after-dark-results.png`（1024×900 dark）、`.local/site-self-check-after-narrow-long-error.png`（420×860 dark）、`.local/health-layout-after-{dark-wide,light-narrow}.png` 均已包含筛选条；首轮失效截图与重拍口径见布局修正条目。
- **边界**：截图来自 Flutter 测试渲染而非真实桌面窗口；未做真实站点端到端联网；未扩展详情/搜索/播放探测。旧运行时不支持请求级取消时只能停止等待。

[u-license]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/LICENSE#L1-L2
[u-input]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/core/config/config_repository.dart#L782-L827
[u-commit]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/core/config/config_repository.dart#L1095-L1168
[u-decoder]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/core/config/config_decoder.dart#L25-L95
[u-cipher]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/core/config/config_cipher.dart#L21-L51
[u-lenient]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/core/config/lenient_json.dart#L13-L25
[u-search]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/core/api/search_engine.dart#L80-L206
[u-search-budget]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/core/api/search_engine.dart#L50-L184
[u-cms-cancel]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/core/api/cms_json_api.dart#L473-L522
[u-rpc-cancel]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/core/companion/companion_spider_api.dart#L498-L529
[u-check-entry]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/ui/desktop/settings/settings_page.dart#L861-L896
[u-check]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/android-bridge/src/com/fongmi/companion/selfcheck/SiteSelfCheck.java#L79-L215
[u-check-ui]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/ui/desktop/settings/site_self_check_dialog.dart#L67-L103
[u-check-api]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/core/companion/companion_spider_api.dart#L149-L198
[u-formats]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/core/config/models/vod_config.dart#L499-L576
[u-factories]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/android-bridge/src/com/fongmi/companion/DexSpiderLoader.java#L192-L207
[u-xptv]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/android-bridge/src/com/fongmi/companion/XptvSpider.java#L25-L297
[u-php-source]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/android-bridge/src/com/fongmi/companion/PhpSource.java#L14-L83
[u-php-runtime]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/android-bridge/src/com/fongmi/companion/PhpRuntime.java#L23-L74
[u-php-bridge]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/android-bridge/resources/php/bridge.php#L12-L31
[u-route]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/core/config/models/vod_config.dart#L46-L58

[u-stack]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/pubspec.yaml#L18-L37
[u-line-match]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/core/player/line_switch_planner.dart#L75-L98
[u-line-open]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/app.dart#L1496-L1554
[u-seek]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/core/player/seek_recovery_controller.dart#L33-L113
[u-seek-engine]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/core/player/mpv_player_engine.dart#L927-L977
[u-error-gate]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/core/player/playback_error_gate.dart#L63-L92
[u-error-engine]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/core/player/mpv_player_engine.dart#L407-L471
[u-proxy-recovery]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/core/player/companion_proxy_recovery.dart#L55-L88
[u-proxy-refresh]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/app.dart#L1933-L2038
[u-cross-search]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/core/player/cross_site_search_service.dart#L51-L79
[u-cross-plan]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/core/player/cross_site_failover_planner.dart#L406-L446
[u-cross-action]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/playback_source_actions.dart#L415-L552
[u-auto-wiring]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/app.dart#L422-L446
[u-backup-validate]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/core/storage/data_backup_service.dart#L179-L234
[u-backup-schema]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/core/storage/data_backup_service.dart#L436-L466
[u-webdav-root]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/core/push/webdav_repository.dart#L18-L73
[u-webdav-list]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/core/push/webdav_repository.dart#L107-L155
[u-webdav-secret]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/core/push/webdav_profile_store.dart#L186-L206
[u-backup-secret]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/core/storage/app_data_files.dart#L68-L82
[u-mirror-health]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/core/update/update_mirror_health.dart#L82-L164
[u-mirror-order]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/core/update/update_mirrors.dart#L159-L190
[u-mirror-wire]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/lib/core/update/update_controller.dart#L230-L250
[u-package]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/scripts/package_tree.ps1#L45-L113
[u-package-test]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/scripts/test_package_tree.ps1#L102-L118
[u-package-verify]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/scripts/verify_release.ps1#L200-L210
[u-third-party]: https://github.com/qfw66/xiugou-tv/blob/d57c239d23081e4902068d2081515fa1ac85ff8e/THIRD_PARTY_LICENSES.md#L3-L29
