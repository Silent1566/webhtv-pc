# WebHTV PC 全项目评估（2026-11-20）

> 本报告第一部分是一次**只读静态审计**的产出：未改动任何代码、未运行构建与测试、未联网。
> 文末新增「迭代 0 执行记录」——那一节是审计之后**真实落地并跑过分析器/测试**的改动，两部分不要混读。
> 结论按「影响面 × 修复成本」分级，S = 一两天内可完成，M = 一个迭代，L = 需跨模块或需产品决策。

## 0. 基线与口径

| 侧 | 仓库 | commit |
| --- | --- | --- |
| PC（本仓库） | `webhtv-pc`（`dev1`） | `5177531` |
| 安卓（对照参考） | `/home/maple/Workspace/webhtv/dev1/webhtv` | `73b56b2cd` |

判定口径：

- **已实现**：有可达入口 → 真实调用 → 消费点闭环（只存在选项字段或注释不算）。
- **假开关**：设置项能被用户修改，但代码里没有消费者。
- **文档滞后**：设计文档/代码注释声称未实现，但源码已有实现且有提交记录。
- 全部证据为静态源码核查（`grep`/`read`），因此「已实现」只表示源码层面闭环，不等于实测通过。

## 1. 结论摘要

主链路（配置 → 站点 → 浏览/搜索 → 详情 → 播放/直播 → TMDB·AI 集季 → 同步 → 诊断）源码层面完整，测试密度合格（测试 ≈ 16.5 万行 / 产品 ≈ 16.8 万行 ≈ 1:1）。

问题不在「缺功能」，而在四类结构性债：

1. **巨型文件**：`state/app_state.dart` 7913 行是单类神对象；`ui/player_page.dart` 7605 行里是**单类 7110 行 / 177 方法**，且单方法 866 行在 build 期重跑。
2. **文档与代码脱节**：至少 6 项能力已实现，仍被设计文档与代码注释记为「未实现」；`docs/` 中「未做/遗留/待验证」标记 624 处，高信噪比部分仍需人工甄别。
3. **假开关**：`player_options` 的 `preloadNext` 在 `ui/`、`services/` 零消费点；用户改了设置没有效果。
4. **门禁形同虚设**：`dart analyze` 不带 `--fatal-infos`；契约测试脚本从未执行；`integration_test/` 39 文件 1.4 万行 CI 执行次数为 0；无覆盖率、无 format 门禁、无缓存。

另有两条单点风险需要单独对待：sidecar 「一次慢请求连坐整站被杀」、同步服务「同网段可冒充已授权设备写数据」。

## 2. 勘误：本轮推翻的旧结论

以下结论在本次审计中被证伪，**不得进入排期**：

| 旧结论 | 实测 | 处置 |
| --- | --- | --- |
| 站点手动排序/屏蔽「有实现无接线，是死代码」 | `ui/app.dart:937-938` 已接 `onReorder: setSiteManualOrder` / `onBlockedChanged: setSiteBlocked`；持久化在 `services/ui_preferences_store.dart:1084` | 整条剔除 |
| 同上，「无手动排序/屏蔽」 | 同上；`state/app_state.dart:2478/2497` 提供写入口 | 整条剔除 |
| 短剧规则「彻底消失、零命中」 | `core/tmdb_config.dart:46` 有 `[短]` 标签，`state/app_state.dart:1491` 已映射为 `isShortDrama` | 降级为 S 级小缺口（仅缺站点级启停名单） |
| 「build 期写状态」是头号正确性风险 | `ui/browse_pages.dart:3089` 的写入被 `_selectedLineFlag.isEmpty` 守卫 | 降为 P2，风险是重复触发而非崩溃 |
| `DESIGN.md:669` 称全仓无 `AppMotion` 引用 | 实测 20 处 | 属文档滞后，后者是缺陷 |
| 「4 处监听器缺 `mounted` 守卫」 | 四处守卫原本就写在 `_onStateChanged` 回调体内（`browse_pages.dart:1864`、`following_page.dart:92`、`following_calendar_page.dart:109`、`python_environment_page.dart:96`） | 整条剔除。审计里「某处缺失」的断言必须回到调用点，只 `grep` 计数会误判 |

## 3. S 级：立即可做（1–2 天，纯收益）

| # | 动作 | 位置 | 收益 |
| --- | --- | --- | --- |
| 1 | `dart analyze` → 加 `--fatal-infos` | `.github/workflows/desktop-ci.yml:129,355`、`desktop-release.yml:204,487` | 4 处门禁永远为绿，lint 违规不可见；现有仅 101 条 info，越晚开越贵 |
| 2 | 契约测试接进 CI | `desktop-ci.yml:382` 的 `-p test_*linux*.py` 永不匹配 `tests/test_contracts.py`；`scripts/validate_contracts.py` 从未执行 | 4 个 schema 的唯一守卫当前是死代码 |
| 3 | libmpv 用例加 skip 闸门 | `test/player_audio_normalization_ui_test.dart:262` 裸调 `MediaKit.ensureInitialized()` | 本地全量 `flutter test` 挂起的主嫌 |
| 4 | 真浏览器用例改显式 opt-in | `test/sniff_browser_smoke_test.dart:34-43` 会枚举并逐个探测本机所有 Chromium 候选，用例自设 3 分钟超时 | 同上，属「能力探测型挂起」，最难判断 |
| 5 | 新建 `apps/desktop-flutter/dart_test.yaml` 定义 `native/browser/external/slow` 标签 | 文件当前不存在 | 让 4000+ 纯逻辑用例可秒级跑 |
| 6 | `notifyListeners` 判活收口 `_notifyIfAlive()` | `state/app_state.dart`：150 处调用，仅 2 处有 `_disposed` 守卫 | 退出/热重启时在途写盘回调打已 dispose 的 notifier，debug 下直接抛 |
| 7 | `webHomeSources` 改走缓存 | `app_state.dart:7079` getter 直读盘且无 try/catch，调用点在 `ui/local_sources_page.dart:117` 的 `build()` 内 | 该页每次重建都重扫目录 + 解析 JSON |
| 8 | `_aiSeasonBindings` 加容量上限 | `app_state.dart:1084` 无淘汰；照抄 `state/tmdb_state.dart:248` 的 FIFO | 长会话常驻内存只增不减 |
| 9 | sidecar 停止时保留崩溃现场 | `services/spider_process.dart:923-930` 递归删工作目录，而 `stderr.log` 就在其中（`logFile` 于 `:1274` 同目录） | 现在正常停止 = 日志全丢，用户报崩溃时零现场 |
| 10 | 工作目录拼路径前净化 `siteKey` | `spider_process.dart:1268-1272` 用原始 key 拼；`services/spider_registry.dart:303` 的缓存目录却是净化的 | manifest 中 `key: ../../x` 可越界，与第 9 条叠加即越界删除 |
| 11 | UI 一致性三连：spinner 收敛 `LoadingBlock`（20 处 → 1）、7 处写死 hex 换令牌、32 处 `w500/w600` 换 `AppWeight` | `DESIGN.md:659/677/688`；样例 `ui/search_result_view.dart:754`、`ui/home_hero.dart`、`ui/browse_pages.dart:286` | 同屏两种转圈、亮色主题漏色、小字号发糊 |
| 12 | 空 `setState(() {})` 清零（65 处） | `ui/player_page.dart:4804`、`ui/browse_pages.dart:1829/1833/1866`、`ui/tmdb_detail_page.dart:169/173` | 每次都是整页重建 |
| 13 | 4 处监听器补 `mounted` 守卫 | `ui/browse_pages.dart:1866`、`ui/following_page.dart:93`、`ui/following_calendar_page.dart:110`、`ui/python_environment_page.dart:97` | 异步 notify 落在 dispose 后即 `setState() called after dispose()` |
| 14 | 文档回填 6 处已实现项 | `core/player_buttons.dart:66`（LUT/片头片尾）、`docs/adr/0006-following-system-notification.md:105`、`docs/phase8/design/03-button-layout-and-config.md:82,88`、`DESIGN.md:669` | 最便宜的返工保险：照文档会把已上线能力重做一遍 |
| 15 | `PosterImage` 与 `StartupArguments.parse` 搬出 `ui/app.dart` | `ui/app.dart:2177`（8 个文件 `import app.dart show PosterImage`）、`:108`（173 行 CLI 解析在 UI 层） | app.dart 立即 −15%，且是后续抽 `PosterTile` 的前置 |

## 4. M 级：工程债

### 4.1 运行时与 sidecar

**4.1.1 一次慢请求连坐整站（最高优先级稳定性缺陷）**

`spider_process.dart:862-867`：请求超时后发 `$/cancelRequest`，再挂一个 **500ms 匿名 Timer**，回调只判 `_stdoutPolluted` 就 `killTree()`。

- 注释写的是「确认无响应才终止」，代码没判在途请求、没判进程是否已退出；
- 该 Timer 无句柄，`dispose()` 之后仍会触发；
- 后果：上游站点慢一次 = 该站所有并发调用变 `SPIDER_CRASHED`，用户侧表现为站点突然不可用。

修法：Timer 存入字段并在 `_exitCompleter` 完成 / `dispose` 时取消；kill 前判 `_pending.isEmpty` 或等 cancel 回执。

**4.1.2 三语言宿主执行语义不一致**

| 能力 | JS | JVM | Python |
| --- | --- | --- | --- |
| deadline | 有（`host.js:649-658`） | 有（`SidecarServer.java:172-177`） | **无**（`webhtv_ipc.py:320-365`） |
| 并发上限 | 4 + 队列（`host.js:341,750`） | 固定线程池（`:88-91`） | **每请求 new 线程，无上限**（`webhtv_ipc.py:345`） |
| 沙箱 | `vm.createContext`、不注入 require/process/fs（`sandbox_worker.js:31-33`） | 无 SecurityManager，同 JVM `loadClass` | 宿主进程内 `exec_module`（`host.py:54-61`） |

后果：同一站点在 Python 宿主下表现为 OOM/卡死，换 JS 宿主正常，排查成本极高；py/jar 站源实际拥有本机全部权限，与 js 源的信任模型完全不同。

**4.1.3 其它 sidecar 项**

- `spider_process.dart:656-684` stderr 在主 isolate **同步**写盘并轮转（`existsSync`/`writeAsBytesSync`/`renameSync`），站点刷输出即卡 UI。
- `:432-441` 资源限制（`memoryMiB`/`cpuSeconds`）只在 Windows Job Object 生效，Linux/macOS 只是如实上报 `bestEffortOnly`。
- `:617-622`、`:1845-1906` 解释器/依赖探测用 `Process.runSync`，无超时 → 首启可能冻结到子进程退出。
- `:458,469` 管道 `listen` 返回值未持有，无法确定性取消（对照 `cat_runtime.dart:492-498` 的正确写法）。
- `:1404-1427` 退避无抖动、达上限即永久 `disabled`，需人工 reset。

### 4.2 安全与信任模型

**4.2.1 同步服务身份靠对端自报（需协议决策）**

证据：`services/sync_server.dart:145` 绑 `0.0.0.0`；`:275` `/device` 无校验返回 `uuid/name/ip`；`:324-337` `/action` 用请求体自报的 `device.uuid` 判权；`core/android_sync.dart:1053` 的 `validateSyncAction` 只校验 `enabled + peerAuthorized`，全路径不接受 token。

后果：同网段任意主机先 `GET /device` 拿 uuid，再冒充该 uuid 发 `POST /action` 写历史/收藏/设置（`type=backup&allowSensitive=true` 甚至可写设置）。

**归因修正**：这不是随手写漏。代码注释写明「安卓推送的 `FormBody` 只带 `config`/`targets`，不带设备标识，只认 uuid 会让该功能永远 403」。因此修复必须与安卓侧同步（`x-webhtv-token` 头或一次性配对码），需产品与协议决策。

**4.2.2 其它**

- `/action` 仅接受 `application/x-www-form-urlencoded`（`:315-322`），浏览器跨站可发该类型 —— 与 4.2.1 合并处理。
- Python/JVM 站源无沙箱（见 4.1.2）：短期至少在安装页明示「py/jar 源拥有本机权限」。
- 越界删除风险见第 3 节第 10 条。

### 4.3 状态层与通知

- **单对象 9 类关注点**：`state/app_state.dart:240` 单 `ChangeNotifier`（另实现 `SyncStateHost`），147 getter / 232 方法 / 187 私有字段 / 17 个 `late final` + 30 个可空协作者；测试 mock 依赖约 47 个。
- **通知放大**：`syncState` 1:1 转发（`:374`），8 个页面各自裸 `setState(() {})`（`app.dart:518`、`browse_pages.dart:1866`、`search_page.dart:169` 等），`MaterialApp.builder` 层还有一层 `ListenableBuilder`（`app.dart:371-374`）位于 Navigator 之上。
- **缓存失效策略五套并存**：`_effectiveConfigCache` 是「清空式」，清空点散落 5 处（`:2379/2438/3022/3331/3884`）；`_playbackContexts` 是「签名式」且**同时是 SiteService → sourceKey 的身份索引**（`:6054-6066` 注释自证不能整表清空）；`_aiSeasonBindings` 无淘汰；`webHomeSources` 绕过自己的缓存。
- **同步 IO**：`_writeFileAtomic` 与备份恢复全在 state 内、UI isolate 上执行（`:3352-3358`），全目录 `Isolate|compute(` 零命中。
- **在途请求**靠 8 个手工单调 run-id 判活 + 14 处守卫，新增任一异步路径漏改即旧响应覆盖新状态。
- **通知顺序不一致**：部分 setter 先 await 落盘再 notify（`:2541`），部分先 notify 再落盘（`:5545`）。

### 4.4 巨型文件与 UI 收敛

| 文件 | 规模 | 结构问题 |
| --- | --- | --- |
| `state/app_state.dart` | 7913 行 | 单类 9 类关注点（见 4.3） |
| `ui/player_page.dart` | 7605 行 | `_PlayerPageState` 单类 7110 行 / 177 方法（`:289-7399`）；`_contextMenuSections()` 单方法 866 行（`:5971`），在 build 内每次菜单重建都重跑 |
| `ui/browse_pages.dart` | 4916 行 | `_DetailPageState` 3563 行（`:1288`），详情主体是 1 个跨 1200 行的 `children:` 字面量（`:3240`） |
| `ui/tmdb_detail_view.dart` | 3218 行 | 文件内藏整页 `TmdbPersonPage`（`:2789`）与对话框（`:2228`） |
| `ui/app.dart` | 2317 行 | 藏 CLI 解析（`:108`）、`SitePickerDialog`（`:1574`）、`PosterImage`（`:2177`） |

UI 层的重复与一致性问题（均为可量化机械收敛）：

- 海报卡片重复实现 ≥8 处（`home_cards.dart:30`、`browse_pages.dart:1049/1155`、`search_result_view.dart:43`、`following_page.dart:539`、`following_calendar_page.dart:974` 等）；`PosterImage` 调用点 27 处散在 14 文件。
- 空态/错误态：`common.dart:74/117/231` 已有公共类，另有 10 个私有实现（`_EmptyHint`、`_LiveErrorView`、`_CalendarEmpty`…）。
- 弹窗无公共壳：`showDialog` 78 处 / 26 文件、`AlertDialog` 60 处，规范（`DESIGN.md:659`）靠各文件手抄。
- 大列表：`ListView(` 40 处 vs `ListView.builder` 23 处，`SliverList` 0 处；真正有量的两处是 `following_calendar_page.dart:582`（整月天段）与 `browse_pages.dart:3240`（详情主体）。
- 可及性：`Semantics` 15 处 / `Tooltip` 33 处，而 `IconButton` 80 处；`player_page.dart` 7605 行内 `Tooltip` 仅 2 处、`Semantics` 0 处。
- 硬编码中文 8652 行（含 CJK 的行），集中在 `player_page.dart` 1358 行、`browse_pages.dart` 1067 行。
- const 缺失：非 const `Text` 907 处、`SizedBox` 131 处 —— 但**应先抽组件，再批量加 const**，否则约四成会白改。

### 4.5 CI / 测试 / 发布

| 问题 | 证据 | 影响 |
| --- | --- | --- |
| 门禁永远为绿 | `desktop-ci.yml:129,355`、`desktop-release.yml:204,487` 均无 `--fatal-infos`；`analysis_options.yaml` 只有默认 flutter_lints，`rules` 段全注释 | 101 条 lint 只在 IDE 里可见 |
| 契约测试从未执行 | `desktop-ci.yml:382` 只 discover `test_*linux*.py`，`tests/test_contracts.py`（284 行，4 个 schema 的唯一校验者）永不运行；`scripts/validate_contracts.py` 依赖 `jsonschema` 但 CI 无 pip install | 协议/配置 schema 守卫退化为人肉脚本 |
| e2e 从未执行 | `integration_test/` 39 文件 14258 行；workflow 中 `integration_test` 仅命中 `test/linux_bundled_python_integration_test.dart` | 整层流程回归无人拦截 |
| 无缓存 | 两个 workflow `actions/cache` 命中 0 次；python runtime / 原生依赖 / libmpv / appimagetool 每次重下 | 单测 13 分钟里不可控的大头 |
| 无覆盖率 / 无 format / 无分片 | `flutter test` 调用点无 `--coverage`/`--total-shards`；全仓无 `dart format` 步骤 | 改动是否被测到、格式是否漂移都不可见 |
| 测试无标签体系 | `test/` 仅 `test/` 与 `test/support/` 两层，无 `dart_test.yaml` | 慢用例（真内核/真浏览器/真进程）无法与纯逻辑用例分开跑，这是本地只能「全量或全不跑」的根因 |
| 版本号三处解析 | `desktop-ci.yml:106-113`（PowerShell 正则）、`desktop-release.yml:94`（Python 正则）、`state/app_state.dart:163` 硬编码默认值 `0.1.0`（pubspec 为 `0.1.0+1`） | 改版本要改 3 处，漏改即包名版本 ≠ 界面版本 |
| CI 与 Release 重复约 200 行 | `desktop-ci.yml:46-245` 与 `desktop-release.yml:142-401` 逐段同构 | 两处漂移只在发版当天暴露 |
| 固定端口 fixture | `test/fixture_support.dart:34` 默认 `http://127.0.0.1:18080`，15 个文件依赖 | 服务未起时不是编译错误而是运行期超时；端口冲突即整组假红 |
| 真实时间轮询 | `test/support/widget_settle.dart:20-30` 30 秒真实时间循环（8 个文件使用）；`test/phase6_ai_completion_test.dart:334-340` 留 30s pending timer | 单文件先烧 30s 才失败 |
| 同步子进程无超时 | `test/phase3_jvm_spider_test.dart:345-349`、`test/phase9_catvod_spider_test.dart:340` 直接 `await process.exitCode` | 缺 JDK 时错误指向超时而非环境缺失 |
| sidecar 三份运行时零自有测试 | `sidecars/spider-host-js/package.json` 无 `scripts`；`find sidecars -name *.test.*` = 0；JVM 50 个 `.java` 无 `*Test*` | `sandbox_worker.js` 承载的沙箱边界没有任何直接测试 |

## 5. 状态层拆分次序（不要一次性重写）

| 次序 | 边界（现状行号） | 迁移量 | 理由 |
| --- | --- | --- | --- |
| 1 | 搜索/联想/历史 `:5527-6048` | ~520 行 | `state/search_state.dart:176` 已有骨架，仅 3 个 UI 调用点 |
| 2 | Spider 运行时 / 本地源 / 代理 `:6930-7482` | ~553 行 | 自成闭环，仅经 `local_sources_page`、`spider_page` 交互 |
| 3 | 追番 `:7483-7913` | ~431 行 | 自带 `Timer.periodic`（`:7869`）与 notifier，已有独立 `FollowingSettings` |
| 4 | 配置记录 CRUD + 注入站点 `:3882-4771` | ~890 行 | 是「清空式缓存」根因；先定 `effectiveConfig` 版本号契约 |
| 5 | 播放上下文 `:6049-6427` | ~379 行 | 依赖 4；迁完把「缓存兼身份索引」语义封进独立 store |
| 6 | TMDB 桥接 `:737-2222` | ~1486 行 | 收益最大也最难，需同时消掉 `browse_pages.dart:1514` 的双通道监听 |

播放器侧建议前置顺序：先抽字幕菜单（`player_page.dart:2107-2212`）→ 菜单构造 `_contextMenuSections`（`:5971`）→ 播放参数面板（`:6590`），再谈第 7 节的功能项。

## 6. 文档治理

- `docs/` 146 篇 md，命中「未做/遗留/待验证/降级/风险」等标记 624 处；代码内 `TODO/FIXME/HACK` 仅 2 条且都在 Flutter 脚手架生成物里 —— **待办实际由文档承载**，而文档状态无人回填。
- 已知文档滞后 6 项：LUT、片头片尾跳过、通知点击跨页切换、`WheelScroll` 提升、AI 片名/去广受支持键、直连 `.py` 源（均已有实现）。
- 建议：给每份设计文档顶部加一行 `状态: 已实现 / 部分实现 / 未实现（日期）`；新能力合入时同步改该行，比事后全仓校对便宜。
- 本轮已证伪的结论见第 2 节，排期前必须读。

## 7. 用户可见能力缺口（按「桌面用户真的会用」排序）

| 缺口 | 现状证据 | 成本 | 说明 |
| --- | --- | --- | --- |
| 字幕/音轨偏移 + 双字幕 | `secondary-sid` / `sub-delay` 全 `lib` 零命中；安卓有 `OffsetDialog.java`、`TrackDialog.java:134,155` | S/M | 外语片刚需；属性只需进 `core/mpv_properties.dart` 白名单 |
| 预加载 / 解码失败回退是假开关 | `player_options.dart:236 preloadNext` 在 `ui/`、`services/` 零消费点；开播链 `player_page.dart:1560 → player_controller.dart:1403` 签名无 preload | M | 改了设置没效果，比没有更伤 |
| 本地视频文件播放 | `services/external_player.dart:240` 只接受 http(s)；`StartupArguments` 无文件参数；全仓无拖放入口 | M | 桌面端最自然的期待，当前零入口 |
| 直播收藏 | `core/android_sync.dart:830` 注释自证「PC 没有直播收藏页面」，同步时降级为 site 级 | S/M | 常看频道无法沉淀；改动 `type=1` 语义需兼容既有同步包 |
| 更新提示（最小形态） | `checkForUpdate` 零命中，界面只有 `v$version` | S | 只做「版本对比 + 打开 Releases」，不做静默下载 |
| 站源动作卡（签到/解析/登录） | `spiderAction` 零命中；安卓 `ActionCardHelper.java:41,73` | L | 大量 CSP 源的必要动作；解析必须留在 sidecar 进程内 |
| 短剧站点级规则 | 只有 `[短]` 标签映射，无启停名单 | S | 修正后的真实缺口（见第 2 节） |
| 观影记录写端点 / Webhook | `sync_server.dart:249-263` 只有读侧；`webhook` 零命中 | M | 目前 PC 只是订阅者，第三方脚本无法推进度 |
| MKV/AVI 关键帧跳转未闭环 | `docs/phase9/evidence/14-player-navigation.md:4`，门禁用 `skip` 保留缺陷（`integration_test/player_navigation_engine_flow_test.dart:377`） | 决策 | 三个选项见该文档 `:49`，选一个比修更值钱 |
| 画面比例 / 音轨选项字段 | `core/player_options.dart` 无 `aspect`/`audioTrack` | S/M | 与字幕偏移同批做最省 |

## 8. 新功能建议

**A. 高性价比（都是补桌面场景的基础缺陷，不是「加功能」）**

1. **本地文件播放 + 拖放**：`core/playback_request.dart:8` 增加本地源类型 → `ui/app.dart:1086` 加拖放入口 → 明确本地路径不走回环代理/鉴权。成本 M。风险：不能进历史聚合的跨源续播。
2. **字幕/音轨偏移 + 双字幕轨**：`core/player_tracks.dart` 扩次轨模型 → `player_page.dart:2107-2212` 加 ±ms 与次轨选择 → `mpv_properties.dart` 白名单。成本 S/M。
3. **播放前预取 + 失败自动回退**：`player_controller.dart:1403` 的 `openWithRetry` 前置预取与失败分类。成本 M。风险：双 mpv 实例内存、把网络问题误判为解码问题。
4. **直播收藏 + 回看统一入口**：`ui/live_page.dart` + `core/live_playlist.dart` + `android_sync.dart:830` 的 `type=1` 打通。成本 S/M。
5. **更新提示**：最小形态仅「版本对比 + 打开 Releases 页」。成本 S。

**B. 中价值（生态面，决定真实配置能用多少）**

6. 站源动作卡（`core/action_card.dart` + `services/spider_router.dart` action 通道 + sidecar 内解析）。成本 L。
7. 同步写端点 `/api/playback/progress{,/batch,/delete}`，复用 `core/realtime_sync.dart` 的墓碑与 since 游标。成本 M。
8. 同步鉴权协议升级（见 4.2.1，需与安卓同步发版）。
9. 短剧站点级规则（默认 `[短]`/`短剧` + 启停名单，落 `ui_preferences_store`）。成本 S。

**C. 明确不做（YAGNI / 已是产品决策）**

- 全量 i18n：只收口「公共状态文案 + 共享控件文案」即可（第 3 节第 11、15 条抽出的那批）。
- 静默自动更新、Windows MSI、Linux 包签名升级：已在 `desktop-release.yml:13-17`、`docs/linux-packaging.md:7` 显式声明为产品决策。
- DLNA 投屏、APK 推送、遥控器焦点、小说漫画阅读、GitCloud：平台差异或已被 `docs/phase9/README.md` §5 记录为不移植。
- macOS/ARM64 正式支持：现状是「有 `isMacOS` 分支但无 runner、用例无条件 skip」的半状态 —— 要么承诺要么删分支，不要维持现状。

## 9. 执行路线

| 迭代 | 内容 | 出口标准 |
| --- | --- | --- |
| **迭代 0（1–2 天）** | 第 3 节 15 项 | `flutter analyze --fatal-infos` 绿、契约测试进 CI、本地可只跑快子集、sidecar 日志保留 |
| **迭代 1（1 周）** | 测试可信度（标签化 + 覆盖率 + cache + e2e 三条最短流程）；sidecar 加固（超时 kill 策略、`siteKey` 净化、Python deadline 与并发上限） | 全量 `flutter test` 本机不再挂起；CI 有覆盖率与缓存 |
| **迭代 2（2–3 周）** | 播放器域拆分 → 字幕偏移 + 双字幕 → 预加载接线 → 本地文件播放 | 每个功能独立可测，`player_page.dart` 降至 5000 行以内 |
| **迭代 3（视决策）** | 同步鉴权协议、站源动作卡、直播收藏、更新提示、MKV 跳转方案、短剧规则 | 产品决策落定后再排期 |

## 10. 需产品决策的事项（不是技术选择）

1. **同步身份模型**：接受「同网段可冒充」，还是加 token/配对码（需安卓端配合发版）？
2. **MKV/AVI 跳转**：接受格式矩阵、投原生原子 seek、还是全格式只留缩略图？
3. **本地文件播放的边界**：只播不记录，还是纳入历史/续播管线？
4. **发布目标**：是否正式承诺 macOS/ARM64？现在是无 runner 的半状态。

## 11. 可信度边界

- 全部为静态取证，本机 PATH 无 flutter/dart，未跑 analyze/test/build；「哪一处先挂」是嫌疑排序，需一次 `flutter test --reporter expanded` 实测确认。
- 安全项只做代码级确认，未做实际攻击验证（未构造冒充包、未验证 Python 站源逃逸路径）。
- 子代理结论中 3 条已在第 2 节证伪；其余关键结论由主审回查源码确认。
- 未覆盖：`jar_intake.dart` 的中央目录预算核算、JVM 手写 JSON 解析器、`scripts/package_windows.ps1`（717 行）与 `package_linux.py`（556 行）的逐段重复度、`docs/phase9/parity-2026-11-12/` 四份清单的逐条复核。

## 附录 A：关键证据索引

| 主题 | 位置 |
| --- | --- |
| 超时杀进程 | `apps/desktop-flutter/lib/services/spider_process.dart:849-867` |
| 删除工作目录 | 同上 `:910-931` |
| 工作目录拼接 | 同上 `:1268-1272` |
| 管道订阅未持有 | 同上 `:458,469` |
| 同步服务绑定与鉴权 | `lib/services/sync_server.dart:140-148,186-192,272-342` |
| `validateSyncAction` | `lib/core/android_sync.dart:1043-1066` |
| 站点排序/屏蔽（已实现） | `lib/core/site_order.dart:1-60`、`lib/state/app_state.dart:2478-2513`、`lib/ui/app.dart:935-938` |
| 通知判活缺口 | `lib/state/app_state.dart` 全文件 150 处 vs 2 处 `_disposed` |
| 播放上下文缓存兼索引 | `lib/state/app_state.dart:6054-6113` |
| `preloadNext` 假开关 | `lib/core/player_options.dart:147,236` vs `lib/ui/player_page.dart:1560` |
| 本地文件播放缺席 | `lib/services/external_player.dart:232-241`、`lib/ui/app.dart:87-134` |
| CI 门禁 | `.github/workflows/desktop-ci.yml:106-113,129,355,367,374,382` |
| 文档滞后样本 | `docs/adr/0006-following-system-notification.md:105`、`docs/phase8/design/03-button-layout-and-config.md:82,88`、`DESIGN.md:669` |

## 附录 B：实测规模

| 项 | 数值 |
| --- | --- |
| `lib/` | 380 文件 / 约 168,500 行（ui 58,268、services 51,610、core 45,639、state 12,957） |
| `test/` | 435 文件 / 165,498 行 / 约 4,462 `test()` + 1,431 `testWidgets()` |
| `integration_test/` | 39 文件 / 14,258 行（CI 执行 0 次） |
| `sidecars/` | 三语言宿主约 12,400 行，自有用例 0 |
| `docs/` | 146 篇 md，「未做/遗留/待验证」类标记 624 处 |
| 代码 TODO | 2 条，均为 Flutter 脚手架 `CMakeLists.txt:9` |

## 迭代 0 执行记录（2026-11-20）

本节记录第 3 节 15 项的实际落地。**所有改动均未提交**，留在工作区。

### 环境事实（本轮才发现）

- Flutter SDK 不在 PATH：`/home/maple/.dsh/worktrees/webhtv-pc-d700b86c/dev3/.local/linux-build/flutter`（3.47.5 / Dart 3.13.4），本轮 analyze 与测试都是真跑的。
- 跑测试必须 `TMPDIR=/var/tmp`；播放器用例需 `LD_LIBRARY_PATH=/home/maple/orca/webhtv-pc/.local/distro-libs/usr/lib/x86_64-linux-gnu`。
- 「本机没有工具链」这个前提是错的：分析器可用意味着这类改造能做闭环验收，不必只靠静态阅读。

### 已完成

| 项 | 结果 | 关键证据 |
| --- | --- | --- |
| 分析器基线清零 | `dart fix --apply` 99 处（20 文件）+ 手改 7 处花括号 + 3 个探针脚本 `ignore_for_file: avoid_print` | `dart analyze --fatal-infos` 全包 0 issue |
| 1 CI `--fatal-infos` | 4 处命中（`desktop-ci.yml:129,355`、`desktop-release.yml:204,487`） | 见下「验证」 |
| 2 契约测试进 CI | discover 改 `test_*.py` + `pip install jsonschema==4.23.0` + `validate_contracts.py`；ci/release 三步逐字节一致 | `test_contracts.py` 21 passed、`validate_contracts.py` exit 0、`test_linux_workflows.py` 11 passed |
| 3 libmpv 跳过闸门 | 新建 `test/support/libmpv_guard.dart`；3 个用例文件按能力探测跳过（`WEBHTV_TEST_LIBMPV` 仍可强制跑） | 无内核 10s 内 `All tests skipped`；给内核同一批 `+8 passed`（证明不是靠跳过掩盖） |
| 4 浏览器用例 opt-in | `sniff_browser_smoke_test` / `parse_sniff_chromium_test` 改为 `WEBHTV_SNIFF_BROWSER` 才跑，并打 `browser` 标签 | 同上 |
| 5 测试分层 | 新建 `apps/desktop-flutter/dart_test.yaml`（native/browser/external/slow，不默认排除）；7 个慢用例打标签 | `dart analyze --fatal-infos test` 0 |
| 6 通知判活 | `_notifyIfAlive()`；86 处 await 之后的 `notifyListeners()` 改为判活，63 处同步路径/乐观通知未动 | 见下「验证」 |
| 7 webHome 缓存 | `webHomeSources` 改走缓存；顺带修掉它的语义漏洞（见「契约变更」） | `local_sources_test` / `local_source_enable_test` 全绿 |
| 8 AI 季绑定上限 | `_aiSeasonBindingCapacity = 128` + FIFO（照 `tmdb_state.dart` 写法），两张表同 key 同步淘汰 | `app_state.dart` analyze 0 |
| 9 sidecar 现场日志 | `dispose` 删除工作目录前把 `stderr.log` 与轮转文件合并复制到日志目录，按站点保留 10 份（≈1MB/份） | 真实 python sidecar：`spider_debug_log_test` 17 passed、`sidecar_idle_recycle_test` 12 passed（仍断言停止后工作目录清零） |
| 10 路径净化 | 提取 `sanitizePathSegment`（registry 与 sidecar 共用），工作目录 `p.isWithin` 断言越界即抛 `SPIDER_INIT_FAILED` | 同上 |
| 13 mounted 守卫 | **无需改动**（见勘误） | 源码复核 |
| 14 文档回填 | 8 处（原计划 6 处 + `timer`/`repeat` + `DESIGN.md:345`），保留原句删除线 + 「2026-11-20 更正」 | `verify_gap_matrix.py` PASS |
| 15 巨型文件搬运 | `PosterImage` → `lib/ui/poster_image.dart`、`StartupArguments` → `lib/ui/startup_arguments.dart`；`app.dart` 2317 → 2096 行 | 全包 analyze 0；`source_swap_sheet`/`image_headers`/`image_decode_budget`/`phase4_tmdb_detail_hero` 共 51 passed |

### 范围调整（本轮未做，已顺延）

- **第 11 项视觉令牌**（spinner 20 处、硬编码 hex 7 处、`w500/w600` 32 处）：属可见样式变更，需要 Before/After 截图；仓库没有可用的 headless 截图 harness，本轮无法按 UI 取证规则交付。
- **第 12 项空 `setState(() {})` 65 处**：这是「强制重建」惯用法，逐处替换会改变重建语义，必须一处处判断，不能机械批量。

### 本轮引入的契约变更（后续改动必须知道）

1. **`AppState.webHomeSources` 不再抛异常**：读取失败时降级为空表，并通过新增的 `webHomeLoadErrorDetail`（原文）与既有 `webHomeLoadError`（带前缀）回报原因。理由：它在 `LocalSourcesPage.build()` 里被调用，抛异常会炸整页。
2. 为保住「失败可见」，`_allWebHomeSources()` 现在与 `_safeWebHomeSources()` 共用 `_recordWebHomeLoadError()`；页面按「先读一次、再取失败原因」的顺序渲染，否则首帧会把「读取失败」显示成「没有本地源」。
3. `_import()` 在整批失败时给出「导入失败：<首条原因>」，并把登记表读取失败另记到候选区横幅——失败不再只埋在结果报表里。
4. 两条旧断言（`local_source_sites_test.dart:463/499`）随之改为「返回空表 + 原因可读」，属契约变更而非放宽断言。

### 验证

- `dart analyze --fatal-infos .`（lib + test + integration_test）→ **No issues found!**
- `python3 -m unittest discover -s tests -p 'test_*.py'` → 102 passed / 1 skipped；`scripts/validate_contracts.py` → 通过。
- 定向回归：本地源 4 个文件全绿、sidecar 2 个文件 29 passed、UI 搬运相关 4 个文件 51 passed。

### 遗留与观察

- **全量 `flutter test` 结论**：`--concurrency=2` + `TMPDIR=/var/tmp` 跑完 16:22，**6299 passed / 36 skipped / 7 failed**。7 条失败全部集中在 `test/playback_entry_feedback_test.dart`。用 `git worktree` 检出 `5177531`（本次改动之前的干净树）跑同一文件，结果**完全相同（+2 -7，报错文本逐字一致）**，因此是既有失败，不是迭代 0 引入的。加 `xvfb-run` 复跑仍失败，排除显示环境因素。**迭代 1 已定位并修复**：不是生产缺陷，是测试 harness 只覆盖了 `config` 取值器，而入口查的是 `effectiveConfig`（合并私有 `_config`，不读公开取值器），站点守卫在建反馈前就 return —— 修 harness 后 9/9 绿，生产代码零改动。
- **一次并发抖动**：本地源页面用例与本地源站点用例并行跑时，搜索用例出现过 1 次失败（`+64 -1`，单跑与复跑均全绿）。该用例在 `enterText` 后只 `pump()` 一次，机器负载高时对时序敏感 —— 属既有测试写法问题，不是本轮改动引入；已登记，暂不改。
- **集成测试的 import 迁移**：`integration_test/` 8 个文件因 `StartupArguments` 搬迁需要补 import，本轮已补（子代理边界只覆盖 `test/`，这是边界交接的漏项）。
- **`jsonschema==4.23.0` 未离线校验**：本机无网络，钉版按「cp312 有预编译 wheel」选取；若 CI 解析失败，改钉 runner 内可用版本即可，逻辑不变。
- `_allWebHomeSources()` 与 `_safeWebHomeSources()` 各自缓存、各自失效（都挂在 `_invalidateLocalSites`），后续新增读取路径要同步置空两处。
- 文档侧仍有已知滞后未处理：`pan_diagnostic`（待复核：`pan_check_service` 是分享链接检测，未必等同网盘诊断）、`docs/phase9/README.md` §4.1 的 PLANNED 列（迁移方案口径，未动）。

## 迭代 1 执行记录（2026-11-20）

### 计划校正（实测否掉了原方案）

- **不加 `dart format` 门禁**：`dart format --set-exit-if-changed lib test` 会改 **443/844** 个文件——仓库不是 `dart format` 风格，加门禁等于逼一次全仓重排并丢掉 blame。
- **e2e 不进阻塞链路**：本地 `flutter test integration_test/mvp_a_flow_test.dart` 失败在 `Could NOT find PkgConfig`（缺 GTK dev 头）。改为独立 job `e2e-linux-trial` + `continue-on-error: true`，注释写明「连续两次绿后去掉」，本机无法验证的部分不假装已验证。

### 已落地

| 项 | 结果 | 证据 |
| --- | --- | --- |
| CI 缓存 | ci/release 各 2 处 `actions/cache@v4`，key = 两份 lock 的 hash + libmpv/native-deps 脚本 hash + OS，无时间戳、无 restore-keys | `test_linux_workflows.py` 11 passed；yaml 解析 jbos 含 `e2e-linux-trial` |
| 覆盖率 | Windows `:230` / Linux `:404` 的 `flutter test --coverage` + artifact（分 OS 命名） | 本地实测生成 36 万行 `lcov.info`（验证后已删目录） |
| 试用 e2e job | 独立 job，`continue-on-error: true`，不在 `needs` 链上 | yaml 解析 + 注释留痕 |
| sidecar 超时守卫 | `_onTimeout` 的匿名 500ms Timer 改为字段 `_killGuard` + `_timedOutIds`；撤销点接 `_onExit`/`dispose`/**按 id 匹配的迟到回帧**；到期要求「该请求无帧 + `_pending` 为空 + 进程存活未污染」才 kill | 4 条新用例（真实 python 宿主，双连接 gate）；**反向对照**：临时还原旧实现后 4 条新用例全红 |
| Python 宿主 deadline | 有界工作池（并发取 manifest，缺省 4）+ 宿主侧 deadline（search 25s / play 20s / detail 20s / 其余 30s，帧内 `deadlineMs` 优先，>120s 截断）+ 队列满回 `SPIDER_RESOURCE_LIMIT`；帧格式零改动 | 自测 28/28 PASS；`phase2_ipc_test` 31 passed；`verify_sidecar_contracts.py` 4/4 PASS |
| 7 条既有失败的根因 | **测试 harness 喂错路径**，不是生产缺陷：harness 只覆盖 `config`，而入口查 `effectiveConfig`（合并私有 `_config`，不读 `config` 取值器）→ 站点守卫在建反馈前就 return | 修 harness 后 9/9 绿；生产代码零改动 |

### 测试分层与时序

| 项 | 结果 |
| --- | --- |
| 慢用例标签 | 新增 8 个 `@Tags(['external'])`（`phase2_ipc`、`phase3_js_spider`、`phase9_python_runtime`、`linux_bundled_python_integration`、`sidecar_idle_recycle`、`spider_debug_log`、`python_environment`、`browser_component_store`），累计 13 个文件可被 tag 排除；`phase9_external_player_test` **拒绝**打标签（全是注入的假进程，打了就是骗人） |
| 真实时间收紧 | `test/support/widget_settle.dart` 30s → 5s（deadline、失败文案、文档三处同步）；`phase6_ai_completion_test` 的 `Future.delayed(30s)` 换成受控 `Completer`，用例显式放行 |
| 子进程超时兜底 | `phase3_jvm_spider` / `phase9_catvod_spider` 的 `await process.exitCode` 包 20s 超时，报错文案区分「缺 JDK」与「缺 Python 运行时」 |

**快子集实测（收敛后的诚实结论）**：`flutter test --exclude-tags external,native,browser --concurrency=2` → **6169 passed / 12 skipped / 0 failed**，耗时 **17:58**。对比全量 6299 passed / 7 failed / **16:22** —— **打标签没有缩短墙钟时间**（被排除的 13 个文件并不是拖慢主因，长尾在 UI 用例）。所以标签的价值是**可分层、可选跑、可给 CI 分片**，不是「本地更快」；原计划的「快子集明显更快」这条验收口径不成立，已按实测改写，不保留虚假结论。
若要真正缩短本地反馈环，方向是「按改动面选文件」或 CI 侧 `--total-shards/--shard-index` 分片，而不是 tag 排除。

**代价（已知并接受）**：`spider_debug_log_test` 与 `python_environment_test` 只有个别用例起真进程，但整文件打标签，于是纯逻辑用例也被移出快子集。要两全需要把真进程用例拆成独立文件——记为后续项，不在本轮做。

### 固定端口 18080 的复核结论（只诊断，未改动）

结论与审计时的假设**不一致**，记录以免后人重复排查：

- `test/fixture_support.dart` 的 `fixtureBaseUrl`/`fixtureMediaUrl`/`fixtureMp4Url` 三个 getter **零消费者**（全仓只有定义）。
- 真正出现 18080 的地方是**字面量期望串**，分布在 11 个文件约 78 处；**没有任何用例真的连 18080**——需要服务端的都已用进程内 `TestFixtureServer`（随机端口，22 个文件），`test_fixture_server.dart:713-719` 会把响应体里的 18080 重写成实际 baseUrl。
- 因此「必须先手工起 `tools/fixture_server`」这个隐性前提**当前不成立**；彻底去字面量化的成本约 3–5 小时（9 个测试文件 + 2 个 support 文件），收益仅是消除误导，优先级低于功能与稳定性项。

### 跨语言分工决策（必须记住）

超时回收现在有两层，职责必须分清，否则会互相抵消：

1. **宿主是主执行者**：JS / JVM / Python 三份宿主各自在 deadline 到期时**主动回 `SPIDER_TIMEOUT`**，用户立刻拿到错误帧。
2. **Dart 是兜底**：`SidecarProcess._killGuard` 只处理「宿主根本没回帧」的情况；守卫到期还要求「该请求无帧 + `_pending` 为空 + 进程存活」，因此**永不连坐**同站其它在途请求（有用例钉住）。
3. **Python 的最后手段**：worker 线程卡在 `requests.get` 时 Python 无法杀线程，回帧后再给 `TIMEOUT_ABANDON_GRACE_SECONDS=1.0` 宽限，仍不返回则 `os._exit(4)`。这是唯一会「连坐」的路径，且只发生在 worker 真的不可回收时；若后续要让 Dart 承担这一层，需要先去掉 `_onStdout` 对「超时请求迟到回帧」的撤销，否则守卫永远不触发。
4. **判定要点**：Dart 侧曾因「收到任何响应帧就撤销守卫」导致挂死 worker 永不回收（`phase2` 超时隔离用例当场变红）。守卫撤销必须**按请求 id 匹配**，不能按「来了任意帧」。

### 验证

- `dart analyze --fatal-infos` 全包 0（迭代 1 新增代码并入后复跑）。
- 四份 sidecar 相关 Dart 用例同时跑（两层改动共存）：**72 passed**。
- `python3 selftest_deadline.py`：28/28；`verify_sidecar_contracts.py`：4/4。

## 迭代 2 执行记录（2026-11-20）

分两波：三件事都要落在同一个 7605 行文件上，所以 Wave 1 先腾地方 + 备 core 能力，Wave 2 才接线。

### Wave 1（4 路并行，文件互斥）

| 子代理 | 结果 | 证据 |
| --- | --- | --- |
| `player-split` | `player_page.dart` **7605 → 6324 行**；三块用 `part` + extension 搬出：菜单构造 793、字幕菜单 345、播放参数 207；自带逐字节校验脚本比对 13 个块 | `dart analyze --fatal-infos lib/ui` 0；4 个菜单/OSD/shell 用例 97 passed |
| `core-tracks` | 次字幕轨选项、`TrackOffset`（毫秒 ±60s 夹取、输出秒）、白名单三条规则 + 回读容差（1ms） | 24 个新用例；3 个既有相关文件 81 passed |
| `preload-core` | 新建 `core/playback_open_policy.dart`（失败分类搬出 controller + `recoverable/nonRecoverable` + 可注入预取探测）；`openWithRetry` 加可选 `policy`（不传＝历史行为） | 10 个新用例；23 passed 旁证 |
| `local-file-core` | `PlaybackRequest.localFile`（不走代理/不加 Header/不参与跨源续播）；外部播放器放开本地路径；顶栏入口 + 命令行裸路径 | 32 + 12 用例（我给 2 条 widget 用例补了 libmpv 闸门） |

### Wave 2（2 路并行，同 library 不同文件）

| 子代理 | 结果 | 证据 |
| --- | --- | --- |
| `wave2-player-page` | 预取接通（`:1564` 传 `policy`）——设置里的「预加载」不再是假开关；本地文件 **14 处守卫**：不写历史、不问站点、不复用 `directUrl` 直播判据、音频 AI 与网速采样短路、选集/切线路/解析源/画质四类入口「UI 摘按钮 + 函数守卫」双保险 | `analyze lib/ui` 0；4 文件 88 passed ×2 轮 |
| `wave2-offsets` | `PlayerOptions` 增 `subtitleOffsetMs`/`audioOffsetMs`（向后兼容、越界夹取）；控制器 `writeTrackOffsetProperty` 走白名单 → 写入 → 回读，**全程不抛**；字幕菜单新增两组「±0.1s / 重置」 | 16 个纯逻辑用例 + 1 个**真实 libmpv** 用例（回读在 1ms 内、无 rejection）；48 + 43 passed 零回归 |

### 本轮学到的两条硬约束（下次改播放器前必读）

1. **`part` + extension 的边界**：extension 里不能用 `State.setState`（protected），也不能用被扩展类型的 static 成员（必须写 `_PlayerPageState.xxx`）。这就是 `_livePatchOptions`、`_buildActionButtons`（直接调 `setState`）留在 `player_page.dart` 的原因。
2. **`PlayerTrackSlot` 是穷举 `switch`**：加次字幕槽会同时动到 core 的枚举与 `player_page.dart` 的槽位分派，跨两个 owner 的文件——所以次字幕推迟到 Wave 3 单独做。

### 验证

- `dart analyze --fatal-infos` 全包 0（Wave 1 后与 Wave 2 后各跑一次）。
- Wave 1 回归组合 9 文件 **178 passed**；Wave 2 回归组合 12 文件 **259 passed**（均含真实 libmpv）。

### 顺延项（不是漏掉）

- **次字幕（`secondary-sid`）**：缺 6 件事——`PlayerTrackSlot` 无次字幕槽、控制器无 `selectSecondarySubtitle`、引擎原始字幕轨列表未暴露（`buildSecondarySubtitleOptions` 至今零调用点）、无次字幕 UI 分组、无默认值/记忆落盘、缺「写进真实内核 + 回读」取证。
- **自动换线/换源**：`PlaybackOpenPolicy.allowsFallback` 已就位，但这是可见行为变更，要与产品决策和截图证据一起做。
- **拖放播放**：需新依赖，本环境无法 `pub get`。
- **本地播放语义尾巴**：右键「上一集/下一集」仍在列（靠空数据 no-op）、本地 `vodId=<路径>` 仍参与轨道记忆/弹幕/字幕匹配 key、OSD 标题略重复。
- **偏移是全局一份**，不按站点/影片/集记忆；mpv 的 delay 按文件重置，靠每次注入恢复（真实内核用例已证明该路径不误报）。
- **产品措辞待定**：本地播放点音频 AI 时的提示「本地文件播放不支持实时字幕 / 卡拉OK」。

## 迭代 3 执行记录（2026-11-20）

### 交付

| 子代理 | 结果 | 证据 |
| --- | --- | --- |
| `wave3-secondary-core` | `PlayerTrackSlot.secondarySubtitle` + `normalizeSecondarySubtitleId`（主次同轨→`no`）+ `canOfferSecondarySubtitle`（≥2 真实轨）+ `secondarySubtitleId` 落盘 + 控制器 `rawSubtitleTrackInfos`/`selectSecondarySubtitle`；写入通道泛化为 `writeMpvPropertyValue`（白名单→写→回读，永不抛） | 全包 analyze 0；40 passed（主审复核） |
| `wave3-local-tail` | 本地摘「上一集/下一集」：播放组 11→9 项，站点/直播菜单树 **0 变化**；新建偏移菜单 widget 用例 3 条（±0.1 落盘、重置、±60s 边界只提示） | 反向对照：守卫改 `if (true)` 后用例立刻红；菜单树 25 passed |
| `wave3-fallback` | `core/playback_fallback.dart` 纯策略（上限 3 步：原地重试/换线路/换解析源，不可回退项不换线）；`failureFallback` 默认 `line`→`off`（显式值仍生效）；失败路径接上阶梯，复用既有切换入口 | 29 新用例 + 126 passed 回归 |
| `wave3-secondary-ui` | 字幕弹层「次字幕」分组（单轨/0 轨不出现、候选剔除主字幕、同轨回落）；真实内核取证到「无字幕轨」这一半 | 4 + 1 用例；`secondary-sid=1 applied=true` 的日志证据 |

### 主审在验收时改掉的两处（都比子代理的交付更重要）

1. **原地重试与回退解耦**。`failureFallback` 默认改 `off` 的同时，`shouldRetryInPlace` 也被回退档位门控 → **超时/网络连「重试一次」都没了**，而这是接线前的既有行为（§10.4）。改为重试只看 `retryLimit` 与失败性质，回退档位只管「换不换地址」。连带修正 3 处断言（`off` 下 `shouldRetryInPlace(timeout)=true`、超时用例 `io.opens` 回到 2）。
2. **控制栏按钮与分组收成单一来源**。本地隐藏「上一集/下一集」时先只过滤按钮，`PlayerOverlayActionRow` 的「按钮与分组一一对应（8 != 10）」断言当场炸。抽 `_visibleButtonSpecs()` 供两者共用，并补一条「本地不出现 skip_previous/skip_next 图标」的回归断言。
3. 附带修：偏移越界提示按下标符号取边界（原先下界 −60s 也印「已到 **+60.0 秒** 上限」）。

### 验证

- `dart analyze --fatal-infos .` 全包 **0 issue**。
- Wave 3 回归组合 17 文件 **285 passed**（含真实 libmpv 用例）。

### 顺延项

- **真实内核双字幕轨取证缺失**：仓库 fixture 只有 `sample.mp4`（0 条字幕轨）+ srt/ts，且本环境 `flutter test` 里 `player.open` 无回调。需要「带 2 条内嵌字幕轨的容器 + 能跑 open 的环境」，**没有伪造通过**。
- 右键菜单（`player_menu_sections.dart`）没有次字幕入口；`_primarySubtitleTrackId` 里的 `embedded:` 前缀与 core 重复一份（建议由 core 收口「菜单 id → 引擎轨道 id」）。
- 同轨回落只覆盖「从本字幕菜单切主字幕」；若主字幕在别处被切到次字幕那条轨，菜单显示正确但落盘/内核会保留旧轨道，直到用户在本菜单再切一次。
- 解析失败（`播放决策没有返回可用地址`）没有引擎失败分类，不进回退阶梯，只提示。
- 页面级回退没有 widget 用例（只有策略单测 + 全包 analyze）。

## 首次 CI 实测（PR #79，2026-11-20）

推送后连跑四轮，逐轮定位：

| 轮次 | Linux | Windows | 试用 e2e | 处置 |
| --- | --- | --- | --- | --- |
| 1 | Unit tests 红 | Unit tests 红 | Build 红 | 复现出「失败收尾多一次 await」的时序回归（`player_history_lines_test`），修 |
| 2 | 同上 | 同上 + POSIX 路径用例红 | Build 红 | 修时序；Windows 用例改为按平台取可执行文件 |
| 3 | **success** | 红：teardown `OS Error 32` | Build 红 | 既有用例在 Windows 上删临时目录的句柄竞态，改用仓库既有 `deleteTempWhenReleased` |
| 4 | **success** | **success** | Run 红：`homeResult` 为 null | e2e job 补 Python 运行时准备后构建通过；失败下移到用例本身 |

### 从 CI 学到、本地学不到的三件事

1. **「关掉功能」也必须零异步开销**：回退默认 off 时若仍 `await` 一次，失败收尾就晚一帧，失败态三出口在首帧看不到。本地组合测试没覆盖到，是 CI 抓的。
2. **Windows 的可执行文件判定是平台相关的**：`isExecutablePath` 在 Windows 要求「盘符 + `.exe`」，所以拿 `/usr/bin/mpv` 当播放器路径的用例在 Windows 上根本走不到媒体路径断言。
3. **Windows 的 `dispose()` ≠ 句柄已归还**：删临时目录要重试（仓库早有 `deleteTempWhenReleased`，只是没被所有用例采用）。

### 试用 e2e 的现状（非阻塞）

- 构建已通过（缺的是 `prepare_python_runtime_linux.py`：CMake 要求 `runtime/python` 正好是 bundle.json + python-runtime.zip）。
- 用例仍红：`mvp_a_flow_test.dart:157` 的 `state.homeResult!` 为 null，4 个用例失败。**这层此前在 CI 里从未执行过**，属新暴露的既有问题，需要真实 Linux 桌面环境定位；在修好前保持 `continue-on-error`，不要转阻塞。

### 本地全量口径（同一棵树）

`flutter test --concurrency=2` → **6434 passed / 37 skipped / 0 failed**（12:41）。

---

本文档为 2026-11-20 评估快照。后续请新建日期文件，并在「勘误」节记录旧结论何时失效，不要原地改写已过期的判断。

