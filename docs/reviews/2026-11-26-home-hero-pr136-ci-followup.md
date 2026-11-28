# 首页大推荐会话缓存（PR #136）CI 后续修复记录（2026-11-26）

## 范围与基线

- 记录对象：PR [#136](https://github.com/Silent1566/webhtv-pc/pull/136)（\`dev1\` → \`beta\`），把首页「大推荐」的完整展示状态从页面迁到应用会话，换取跨页返回不重等。
- 分支提交：\`f2bb4d3\`（功能）→ \`f6407a8\`（首次合并 \`origin/beta\`）→ \`771c842\`（阅读保护收敛）→ \`3338658\`（路径覆盖契约）→ \`f743f17\`（再次合并 \`origin/beta\` @ \`f09df2a\`）。
- 本文件只记录**本次交付中实际发生**的 CI 事实与非本 PR 的遗留抖动；不改写历史文档。

## 已证实的 CI 结果

运行 [45815345209](https://github.com/Silent1566/webhtv-pc/actions/runs/45815345209)，head \`3338658\`（最新一次 \`beta\` 合并前）：

| Job | 结果 |
| --- | --- |
| Analyze, test, build and package (Linux x64) | success |
| Analyze, test, build and package (Windows x64) | success |
| Windows x64 shard 0 / 1 / 2 / 3 | success |
| Trial e2e (Linux x64, non-blocking) | success |

同提交的 push 运行 [45826497750](https://github.com/Silent1566/webhtv-pc/actions/runs/45826497750) 首次失败于 Linux「Unit tests」（`sidecar_idle_recycle_test`，见下第 3 条），重跑失败作业后 **completed success**。

同一次运行在成功前有过两次失败尝试，失败项分类如下（用于区分"我的改动"与"既有抖动"）。

## 本 PR 修掉的真实失败

1. **\`home_metadata_detail_return_test.dart\`「详情返回后首页保留元数据要重新投影」**
   - 原因：新增的"正在读的这一张不被后台改写"规则作用于所有投影，把用户主动从详情页返回时的文案更新也挡住了。
   - 修复（\`771c842\`）：\`_deferReadingText\` 只由**后台复核（6 小时窗口）**置位，\`invalidateMetadata()\`（详情/播放返回）立即清零。阅读保护仍然生效，但不越界。
2. **\`tests/test_linux_path_isolation.py\`「AppPaths 覆盖必须逐字声明四个目录」**
   - 原因：两个新测试夹具用 \`for (final name in ['config','data','cache','state'])\` 生成覆盖映射；仓库契约禁止计算出来的映射（漏一个键会把缓存悄悄写到默认目录）。
   - 修复（\`3338658\`）：改为显式 \`'config'/'data'/'cache'/'state'\` 四个键。

两条修复都在本地复验：\`flutter analyze lib test\` 零问题；合并 \`beta\` 后首页相关 208 项全绿；\`python -m unittest discover -s tests -p 'test_linux_path_isolation.py'\` 11/11 OK（Windows 上需 \`PYTHONUTF8=1\`，见下）。

## 既有抖动（非本 PR 引入）

### 1. Android 配置执行用例的固定端口 —— 已由 beta 修掉

- 现象：Linux 单测 \`9193 passed, 1 failed\`，失败为 \`android_config_execution_service_test.dart\`「disable as the only user releases the lease and removes the publication」，报 \`SocketException ... address = 127.0.0.1, port = 39001\`。
- 根因：该文件的测试替身用写死端口 \`39001\` 真绑 \`ServerSocket\`（\`_nextPort = 39001\`），与 runner 上其它进程/临时端口撞车。本地 3 次重复中复现 1 次。
- 处置：本 PR **未**带出这个改动。尝试过"改为系统分配端口"，但会让 3 个「late … profile B」用例失效——它们刻意依赖同端口重绑失败来注入冲突，因此该修复需要设计，不能顺手改。
- 现状：\`beta\` 的 \`a98c811\`（测试：修复续播接线门禁与 Android 并发端口隔离）已经改掉该文件，\`39001\` 字面量不再存在；本次把 \`beta\` 合入后该文件 91 项相关测试全绿。**无需再单独开 PR。**

### 2. Windows 分片"每次 1 个测试失败、重跑即绿"

- 现象：同一 head 上跑两次，失败位置在分片之间漂移（先 shard 1、后 shard 0），每次都是 \`1 failed\`；诊断日志里对应 \`flutter_tester process ... exited with code=-1\`，测试报 \`did not complete\`。
- 判定依据：把失败作业重跑（\`gh run rerun <id> --failed\`）后同一分片转绿；\`beta\` 自身的运行里 Windows 分片是全绿，说明不是分支内容问题。
- 尚未定位：诊断 artifact 的 \`stdout.log\` 只保留汇总行（\`2371 tests passed, 1 failed\`），没有失败用例名，因此**无法指认具体测试**。

#### 建议的后续动作（单独任务，不并入功能 PR）

1. **让失败用例名可取证**：分片诊断脚本在汇总行之前额外输出失败用例名（\`flutter test --reporter json\` 里取 \`testDone.result == "error"\` 的 \`test.name\`），并写进 \`summary.json\`。验收：一次失败运行里能从 artifact 直接读到失败的 \`test.name\`。
2. **判定是资源还是用例问题**：拿到用例名后，先在本机把该用例重复跑 20 次（\`--concurrency=1\` 与默认并发各一轮）。若只在并发下复现，按"共享资源/时序"处理；若稳定复现，按产品缺陷处理。验收：给出复现率与结论。
3. **收紧分片并发**：若确认是 runner 资源（内存/进程数）导致 tester 被 -1 终止，把该分片的 \`--concurrency\` 降一档并观察两次全绿后再改回。验收：连续两次运行无 \`did not complete\`。

### 3. `sidecar_idle_recycle_test` 的协作取消用例依赖真实 2 秒宽限赛跑

- 现象：push 运行 [45826497750](https://github.com/Silent1566/webhtv-pc/actions/runs/45826497750) 的 Linux 单测失败：`9203 tests passed, 1 failed`，失败为 `test/sidecar_idle_recycle_test.dart:285`「cooperative cancellation remains busy until its response and is not a crash」——`Expected: throws SpiderError with code SPIDER_CANCELLED`，`Actual: emitted {'list': []}`。**同一提交**的 pull_request 运行通过，重跑该作业后也通过。
- 根因（代码与用例对照）：该用例跑**真实 Python sidecar**，`cancel()` 起的是真实 2 秒宽限定时器（`spider_process.dart:1132-1153`），而响应到达的处理路径（`spider_process.dart:813-861`）**不看 `pending.cancelSent`**：sidecar 在宽限期内回复，调用方就拿到结果；只有超期未回才伪造 `SPIDER_CANCELLED` 并杀进程。用例却在 `cancel` 之后按“一定会拿到取消错误”断言，于是机器快（回复 < 2s）就失败、机器慢（> 2s）才通过。
- 这说明**实现与文档注释一致**（取消是 best effort，宽限是兜底），需要修的是用例的确定性，不是产品行为。
- 建议的后续动作（单独任务）：
  1. 拆成两条确定性用例：①「sidecar 在宽限期内回复 → 返回结果，且槽位保持占用、`failureCount` 不涨」；②「sidecar 不回复 → 超过宽限后得到 `SPIDER_CANCELLED` 且进程被终止」。验收：两条各自重复跑 20 次全绿，且不依赖机器快慢。
  2. 若希望保留单条用例，把宽限时长做成可注入参数（`cancel(id, grace: Duration.zero)`），别让断言赌真实时钟。
  3. 顺带确认是否需要给 `cancelSent` 补一条"取消后即使响应到达也按取消结束"的产品决策——那会改变现有语义，需要单独评审，不能顺手改。

### 4. 本地跑测试会改写证据图片

- 现象：本地执行 \`flutter test\` 会重新生成 \`docs/phase9/evidence/hdr-tone-mapping/*.png\`，使工作区出现二进制改动（与代码无关）。
- 处置：提交前用 \`git checkout -- docs/phase9/evidence\` 还原；本次交付未把这类改动带进提交。
- 建议：截图类用例默认写临时目录，只在显式环境变量（如 \`HOME_CAPTURE=1\`）下写回 \`docs/\`。验收：一次全量 \`flutter test\` 后 \`git status\` 为空。

## 交付边界

- 本 PR 只含首页会话缓存与其回归、两份文档（\`docs/superpowers/specs\`、\`docs/superpowers/plans\`）与 \`docs/phase11/design/02-home-feed-contract.md\` §4.1 的契约更新。
- 上述三条遗留问题均未在本 PR 内改动生产或他人测试代码。
