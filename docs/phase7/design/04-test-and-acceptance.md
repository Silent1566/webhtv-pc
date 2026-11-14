# 04 · 测试与验收设计

- 状态：设计指导，**待评审**
- 日期：2026-10-17
- 上游参考：Phase 1–6 的门禁与证据机制（`docs/phase1/README.md` §7、
  `docs/phase2/README.md` §3、`docs/phase3/README.md` §3、`docs/phase4/design/05`、
  `docs/phase5/design/03`、`docs/phase6/design/05`）
- 关联：`00`、`01`、`02`、`03`
- PC 端落点：`apps/desktop-flutter/test/phase7_*.dart`、
  `apps/desktop-flutter/integration_test/phase7_*_flow_test.dart`、
  `tools/phase7/**`、`docs/phase7/evidence/**`

---

## 1. 测试分层

沿用 Phase 3–6 的三层结构，**不引入新机制**：

| 层 | 位置 | 真实网络 | 真实窗口 | 运行命令 |
| --- | --- | --- | --- | --- |
| L1 纯逻辑单测 | `test/phase7_*_test.dart` | ❌（全内存） | ❌ | `flutter test` |
| L2 契约与服务 | `test/phase7_*_test.dart`（注入 fake HTTP client / fake clock） | ❌ | ❌ | `flutter test` |
| L3 集成 | `integration_test/phase7_*_flow_test.dart` | ✅（本地 fixture 服务） | ✅（`-d windows`） | `flutter test integration_test/... -d windows` |

### 1.1 本轮特有的分层约束

| 约束 | 理由 |
| --- | --- |
| **定时器必须可注入假时钟** | 实时同步与心跳是时序逻辑，真等 60 s 会让门禁不可用 |
| **三态判定必须能在 L1 覆盖** | 它是纯状态机（拒绝/TCP 通/超时），不该靠真网络 |
| **`_isGenuineEnd` 必须有 L1 覆盖** | 它是"跳下一集"的唯一闸门，纯逻辑 |
| **`_advanceInFlight` 防重入必须有 L2 覆盖** | 这是 D1 缺陷的直接回归门禁 |
| **设置逐键映射必须有 L2 覆盖** | `tmdb_config`/`ai_config` 是"JSON 字符串"，最容易写错 |
| **`raw` 保真回推必须有 L2 覆盖** | 丢掉安卓的 5 套 AI 提示词是静默数据损失 |
| **心跳/轮询一律不得发真实请求** | 门禁必须离线全绿 |
| **不得依赖真实安卓设备** | 真机验证只作可选留痕（`§7`） |

---

## 2. 新增测试文件

| 文件 | 层 | 覆盖 |
| --- | --- | --- |
| `test/phase7_realtime_core_test.dart` | L1 | 游标推进、增量判定、方向归一化、周期归一化与校验、退避序列 |
| `test/phase7_keepalive_test.dart` | L1 | 三态判定状态机、退避与恢复、唤醒阶梯选择 |
| `test/phase7_resume_gate_test.dart` | L1 | `_isGenuineEnd` 全边界、`completed` 跨端语义、END_MARGIN |
| `test/phase7_realtime_engine_test.dart` | L2 | 假时钟驱动的定时器编排、心跳→轮询联动、403 立即停、失败不推游标 |
| `test/phase7_android_read_client_test.dart` | L2 | 请求捕获：`/api/playback/current`、`/manage/session`、`Host` 头、降级链 |
| `test/phase7_pull_endpoint_test.dart` | L2 | 拉取端点响应形态（`nextSince`/`items`/`deleted` 三种别名）、鉴权、403 |
| `test/phase7_settings_mapping_test.dart` | L2 | 逐键映射、`ai_config`/`tmdb_config` 解字符串、`raw` 保真回推、`unsupportedKeys` |
| `test/phase7_player_advance_test.dart` | L2 | `_advanceInFlight` 防重入、失败回滚 `_request`、`clearCompleted`、恢复路径不连播 |
| `test/phase7_sync_ui_test.dart` | L2 | 开关矩阵与联动、周期选择、手动四个按钮、披露文案 |
| `integration_test/phase7_realtime_flow_test.dart` | L3 | 真实 HTTP + 真实 SQLite：增量同步 → 落库 → 第二轮只拉增量 |
| `integration_test/phase7_keepalive_flow_test.dart` | L3 | 真实 HTTP：fixture 模拟三态 → 退避 → 恢复补一轮 |
| `integration_test/phase7_resume_flow_test.dart` | L3 | 真实窗口：模拟提前 EOF → 不跳集 → 恢复续播 |

---

## 3. 关键用例清单（按设计文档逐条对应）

### 3.1 `01` 实时同步协议

| # | 用例 | 层 | 断言 |
| --- | --- | --- | --- |
| S1 | 增量判定：本地无记录 → insert | L1 | `SyncMergeStats.applied=1` |
| S2 | 增量判定：远端更新 → upsert | L1 | `applied=1` |
| S3 | 增量判定：时间戳相等 → skip | L1 | `skipped=1`（幂等） |
| S4 | 增量判定：远端更旧 → skip | L1 | `skipped=1` |
| S5 | 删除标记：远端旧于墓碑 → skip | L1 | 不复活 |
| S6 | `episodeId` 兜底：`episodeUrl` 缺失 → 用 `episodeName` | L1 | `matchKey` 含集名，且 `raw['_episodeIdSource']=='episodeName'` |
| S7 | `episodeId` 兜底：两者都空 → **不合并** | L1 | `failed=1`，本地不变 |
| S8 | 游标推进：整批成功才推进 | L1 | 有 `failed` 时游标不变 |
| S9 | 开关联动：`realtime.pushEnabled=true` → 自动开 `serverEnabled` | L1 | 且产生提示 |
| S10 | 开关联动：`realtime.settingsEnabled=true` 而 `settingsSyncEnabled=false` → 拒绝 | L1 | 开关保持 false + 错误 |
| S11 | 退避：连续失败 1/2/3/4 次 → 周期 ×1/2/4/8 | L1 | 序列精确 |
| S12 | 退避：403 → 立即停止该方向 | L1 | 不再排定时器 |
| S13 | 轮询站点上限：默认只轮询最近活跃 20 个 | L1 | 请求数 = 20 |
| S14 | 路径 A 请求形态 | L2 | URL = `<base>/api/playback/current?siteKey=<key>`，`Host` 头 = `<host>:<port>` |
| S15 | 路径 A：404 不算失败 | L2 | `consecutiveFailures` 不变 |
| S16 | 路径 A：`/api/playback/current` 404 而 `/device` 200 → `realtimePullUnsupported` | L2 | 分类正确 |
| **S30** | **`episodeId` 字段优先**：响应含 `episodeId` → 直用该值，`raw['_episodeIdSource']=='field'`，**不得**被 `episodeName` 覆盖 | L1 | 值与来源都精确 |
| **S31** | **`/api/playback/history` 空数组 ≠ 无站点**：`200 {"items":[],"total":0}` → 按「该站点无记录」处理，**不**降级、**不**报错 | L2 | 探测结果仍为 available |
| **S32** | **`/api/playback/history` 存在性探测**：200（含空数组）→ available；404/405 → degraded | L2 | 探测结果缓存 60 s |
| **S33** | **`cid` 语义限制**：`history` 空数组**不得**推导出「该站点在安卓端从未播放」 | L2 | 状态与文案只声明「当前配置下无记录」 |
| S17 | 路径 B 响应形态：`nextSince`/`items`/`deleted` | L2 | 三者都在响应体里 |
| S18 | 路径 B 响应形态：别名 `next_since`/`records`/`tombstones` 也被接受 | L2 | 用安卓解析器语义断言 |
| S19 | 路径 B 鉴权：token 不匹配 → 403 | L2 | 状态码 + 文案 |
| S20 | 路径 B 鉴权：未配置 token 时只允许白名单 IP | L2 | 非白名单 403 |
| S21 | 手动「拉取最近记录」不依赖服务端 | L2 | `serverEnabled=false` 时仍成功 |
| S22 | 手动「请求安卓推送全量」在服务端关闭时给出明确错误 | L2 | `syncDisabled` 而非网络错误 |
| S23 | 设置逐键映射：`tmdb_enabled` 标量 | L2 | `TmdbConfig.enabled` 更新 |
| S24 | 设置逐键映射：`tmdb_config` 是 JSON **字符串** | L2 | 解字符串后映射；凭据空时保留本地 |
| S25 | 设置逐键映射：`ai_config` 是 JSON **字符串** | L2 | `AiConfig` 6 字段更新 |
| S26 | `ai_config` 的 5 套提示词字段保留在 `raw` | L2 | `raw` 含 `recommendPrompt` 等 |
| S27 | `raw` 保真回推：推送 `ai_config` 不丢提示词 | L2 | 回推 JSON 含原提示词 |
| S28 | `unsupportedKeys`：`tmdb_model` 进 `unsupportedKeys` 而非 `skippedKeys` | L2 | 两集合互斥 |
| S29 | 含凭据项默认不实时 | L2 | `settingsEnabled=false` 时不含 `ai_config` |

### 3.2 `02` 保活与唤醒

| # | 用例 | 层 | 断言 |
| --- | --- | --- | --- |
| K1 | 三态：连接被拒 → `SERVICE_STOPPED` | L1 | 状态精确 |
| K2 | 三态：TCP 通但 HTTP 超时 → `PEER_FROZEN` | L1 | 状态精确 |
| K3 | 三态：TCP 超时 → `NETWORK_UNREACHABLE` | L1 | 状态精确 |
| K4 | 三态：`/manage/session` 200 → `OK` 且跳过后续探测 | L1 | 探测步数 = 1 |
| K5 | 三态：`/manage/session` 404 → 降级 `/device` | L1 | 探测步数 = 2 |
| K6 | 三态缓存 30 s | L1 | 30 s 内重复调用只探测 1 次 |
| K7 | 周期归一化：心跳 5 s → 10 s；700 s → 300 s | L1 | 夹取正确 |
| K8 | 周期约束：心跳 > 轮询 → 归一化 | L1 | 心跳 ≤ 轮询 |
| K9 | 唤醒阶梯：首次失败不动作（L0） | L1 | 无请求 |
| K10 | 唤醒阶梯：第 2 次失败 → L1（`/manage/session`） | L1 | 请求发出 |
| K11 | 唤醒阶梯：L1/L2 都失败 → L3（仅提示） | L1 | 无额外请求 |
| K12 | L5 必须用户点击 | L2 | 未点击时 `/manage/background/settings` 调用数 = 0 |
| K13 | 心跳成功 → 立即补一轮轮询 | L2 | 轮询调用数 +1 |
| K14 | 心跳成功 → `consecutiveFailures` 清零 | L2 | 周期回配置值 |
| K15 | `backgroundGuide` 原样透传 | L2 | 字符串逐字节相等 |
| K16 | `running=false` 但 `serverRunning=true` → 仍轮询 + 提示 | L2 | 提示存在 |

### 3.3 `03` 续播 vs 跳下一集

| # | 用例 | 层 | 断言 |
| --- | --- | --- | --- |
| R1 | `_isGenuineEnd`：`duration=0` → false | L1 | 不连播 |
| R2 | `_isGenuineEnd`：`position = duration-6s` → false | L1 | 不连播 |
| R3 | `_isGenuineEnd`：`position = duration-5s` → true | L1 | 连播 |
| R4 | `_isGenuineEnd`：`position = duration` → true | L1 | 连播 |
| R5 | `completed` 跨端：PC **不采信**同步来的 `completed` | L1 | 按公式重算 |
| R6 | `completed` 跨端：`position=0.96*duration`（安卓会判完播）→ PC 判未完播 | L1 | `completed=false` |
| R7 | 防重入：连续 10 次 `notifyListeners` → `_playNext` 只调 1 次 | L2 | 调用计数 = 1 |
| R8 | 防重入：`_playNext` 未完成时再触发 → 忽略 | L2 | 调用计数 = 1 |
| R9 | 失败回滚：`_load` 失败 → `_request.episodeIndex` 不变 | L2 | 等于意图值 |
| R10 | 失败路径调用 `clearCompleted()` | L2 | `_completed=false` |
| R11 | 失败路径不触发连播 | L2 | `_playNext` 调用数 = 0 |
| R12 | 恢复路径不触发连播 | L2 | `_playNext` 调用数 = 0 |
| R13 | 恢复路径用最新进度（重新查库） | L2 | `startPosition` = 库内最新 |
| R14 | 失败态三出口存在 | L2 | 三个 `ValueKey` 可点 |
| R15 | `next < 0`（末集）→ `_completed` 被复位 | L2 | 不再重复触发 |

### 3.4 `01`/`02` 共有的诊断与披露

| # | 用例 | 层 | 断言 |
| --- | --- | --- | --- |
| D1 | `episodeUrl` 缺失的披露文案存在 | L2 | 文案含"不返回单集地址" |
| D2 | 轮询站点数披露 | L2 | 文案含实际数字 |
| D3 | 含凭据实时同步的明文 HTTP 警告 | L2 | 文案含"明文" |
| D4 | 安卓服务未运行的指引 | L2 | 文案含"管理页" |
| D5 | 两条路径可同时开启的提示 | L2 | 文案含"建议只开一条" |

---

## 4. Fixture 扩展（`tools/fixture_server/server.py`）

在既有 `/android/**` 命名空间下新增路由（**不改**既有路由语义）：

| 路由 | 用途 | 故障注入（`/android/__mode?content=<v>`） |
| --- | --- | --- |
| `/android/api/playback/current` | 返回一条 `PlaybackRecord`（`apiSafe` 字段集） | `404`（无记录）、`slow`（超时）、`no-episode-url`（缺 `episodeUrl`）、`empty-episode`（集名也空） |
| `/android/manage/session` | 返回 `running`/`serverRunning`/`wakeLock`/`wifiLock`/`batteryOptimized`/`backgroundSettingsNeeded`/`backgroundGuide`/`lastAccess`/`idleTimeout` | `stopped`（`running=false`）、`no-manage`（404，测降级）、`slow` |
| `/android/manage/background/settings` | 记录调用次数（**不得**真做任何事） | — |
| `/android/api/playback/sync` | 拉取端点：按 `X-WebHTV-Since` 返回增量 | `403`（token 不符）、`empty`（无增量）、`with-deletions` |
| `/android/__stats` | 扩展返回：各路由计数、**最后收到的请求头**（含 `X-WebHTV-*`）、最后查询参数 | — |

**TCP 层故障注入**（三态判定必需）：fixture 新增两个**裸 TCP** 模式：

| 模式 | 行为 | 用于 |
| --- | --- | --- |
| `tcp-accept-silent` | 接受 TCP 连接但**永不回 HTTP 响应** | 模拟 `PEER_FROZEN` |
| `tcp-closed` | 端口不监听 | 模拟 `SERVICE_STOPPED` |

实现方式：`tools/fixture_server/server.py` 增加 `--tcp-mode` 参数，
在另一个端口上开一个只 `accept()` 不 `send()` 的 socket。

---

## 5. 反向验证（`tools/phase7/verify_reverse_checks.py`）

沿用 Phase 5 的机制（临时破坏 → 断言用例失败 → 无条件还原 → 校验工作区干净）。
本轮 8 项：

| # | 破坏方式 | 文件 | 必须失败的用例 |
| --- | --- | --- | --- |
| 1 | `_isGenuineEnd` 去掉 `duration <= 0` 检查 | `lib/ui/player_page.dart` | `phase7_resume_gate_test.dart` |
| 2 | `_advanceInFlight` 守卫改为恒 `false` | `lib/ui/player_page.dart` | `phase7_player_advance_test.dart` |
| 3 | 失败路径不回滚 `_request` | `lib/ui/player_page.dart` | `phase7_player_advance_test.dart` |
| 4 | 三态判定把"TCP 通但 HTTP 超时"归为 `NETWORK_UNREACHABLE` | `lib/core/realtime_sync.dart` | `phase7_keepalive_test.dart` |
| 5 | 退避序列改为恒定周期 | `lib/core/realtime_sync.dart` | `phase7_realtime_core_test.dart` |
| 6 | 游标在部分失败时也推进 | `lib/services/realtime_sync_engine.dart` | `phase7_realtime_engine_test.dart` |
| 7 | `ai_config` 当对象读（不解 JSON 字符串） | `lib/core/android_sync.dart` | `phase7_settings_mapping_test.dart` |
| 8 | 含凭据项默认参与实时同步 | `lib/core/realtime_sync.dart` | `phase7_realtime_core_test.dart` |

**#1 与 #2 是本轮最容易悄悄写错的两处**（它们直接对应 §3.3 的 D1/D2 缺陷），
必须作为机器证据存在。

---

## 6. 门禁表

| # | 门禁 | 命令 | 通过判据 |
| --- | --- | --- | --- |
| G1 | 安卓 fixture 预检 | `py -3 tools/phase7/check_android_fixture.py --base <url>` | 新增 4 路由 + 3 故障注入 + 2 TCP 模式全通过 |
| G2 | Python 契约 | `py -3 -m unittest tests.test_contracts` | 新增用例通过 |
| G3 | Schema 校验 | `py -3 scripts/validate_contracts.py` | 无错误 |
| G4 | 静态检查 | `dart analyze` | 无问题 |
| G5 | 单元测试 | `flutter test` | 全绿（含 9 个 `phase7_*` 套件） |
| G6 | 套件存在性 | 脚本内清单核对 | 9 个套件文件均存在 |
| G7 | Windows 集成 | `flutter test integration_test/phase7_*_flow_test.dart -d windows` | 3 个套件全绿（**逐套件单独跑**） |
| G8 | 反向验证 | `py -3 tools/phase7/verify_reverse_checks.py` | 8 项全部"按预期失败"且还原后工作区干净 |
| G9 | 凭据与指纹脱敏 | `py -3 tools/phase5/verify_bridge_redaction.py` + `py -3 tools/phase7/verify_realtime_redaction.py` | 无 API Key / token / 设备指纹原文 |
| G10 | 发布包符号 | `py -3 tools/phase7/verify_release_symbols.py` | 新增 UI 符号存在，无测试壳污染 |
| G11 | 设计文档一致性 | `py -3 tools/phase7/verify_design_docs.py` | 章节号连续、交叉引用可解析、契约快照与源码一致 |
| G12 | 定时器无泄漏 | `flutter test test/phase7_realtime_engine_test.dart` | 每个用例结束时活动定时器数 = 0 |

一键验收：

```powershell
pwsh -File tools/phase7/run_windows_acceptance.ps1
# 快速回归（跳过 Windows 集成测试）：
pwsh -File tools/phase7/run_windows_acceptance.ps1 -SkipIntegrationTests
# 可选：把真机实测摘要写入证据（不作为门禁）
pwsh -File tools/phase7/run_windows_acceptance.ps1 -ProbeRealDevice 192.168.50.3:9978
```

### 6.1 定时器泄漏门禁（G12）的必要性

实时同步与心跳引入**两个常驻 `Timer`**。Dart 的 `Timer` 若未取消，
`flutter test` 会在用例结束后报 "A Timer is still pending"，但**只在
`testWidgets` 里**报；纯 `test()` 不会。而引擎套件（`phase7_realtime_engine_test.dart`）
是纯 `test()`，所以那条内置告警**永远不会**触发，必须显式断言。

**实际落地的做法**（比 `FakeClock` 更彻底）：引擎不自己创建 `Timer`，
而是接受一个可注入的 `RealtimeScheduler`（一次性定时器工厂）。
测试注入 `ManualScheduler`，它**一个真实 `Timer` 都不创建**，
只把回调排进列表；这样「活动定时器数」是一个可以直接数的整数：

```dart
setUp(() {
  engine = RealtimeSyncEngine(scheduler: scheduler.call, ...);
});

tearDown(() {
  engine.stop();
  scheduler.clear();
  expect(engine.activeTimerCount, 0, reason: 'G12：引擎停止后不得残留定时器');
});
```

为什么不用 `fake_async` 的 `FakeClock.pendingTimerCount`：它是**全局**计数，
会被同进程里其它组件的定时器（如状态层的写入节流）污染，
而 `engine.activeTimerCount` 只回答「**这个引擎**有没有泄漏」。
另外 `ManualScheduler.fireByDelay(60)` 能按**周期**触发（60 s = 轮询、
30 s = 心跳），比“推进时钟”更能锁定“谁被重新排程了”。

G12 在 `run_windows_acceptance.ps1` 里还额外断言套件真的带这条断言
（搜 `activeTimerCount, 0`），因为“套件通过”本身不能区分
“断言在”与“断言被删”。

---

## 7. 真机验证（可选，不作门禁）

沿用 Phase 5 的口径：真机验证**只留痕**，不阻断门禁。

| # | 验证项 | 命令 | 记录 |
| --- | --- | --- | --- |
| V1 | 息屏后 `/api/playback/current` 是否可读 | `02` §6.1 | HTTP 码 + 耗时 |
| V2 | `/manage/session` 能否唤醒 | `02` §6.2 | 唤醒前后对比 |
| V3 | 安卓远端同步源指向 PC | `02` §6.3 | `lastApplied` / `lastError` |
| V4 | 提前 EOF 走 `onError` 还是 `STATE_ENDED` | `03` §3.2 | logcat 片段 |
| V5 | PC 侧是否误触发连播 | `03` §3.1 | PC 日志片段 |

**V1–V3 回答 `00` §9 的 O1/O2/O4；V4/V5 回答 O3。**
未跑真机验证时，`docs/phase7/evidence/` 必须写明"未验证"，
**不得**用推断冒充实测（Phase 5 §6.1 的教训）。

---

## 8. 证据落盘（`docs/phase7/evidence/`）

| 文件 | 内容 |
| --- | --- |
| `01-realtime-sync.md` | 增量同步的实测输出、开关矩阵截图、四个手动按钮截图 |
| `02-keepalive.md` | 三态判定的 fixture 输出、退避序列日志、`backgroundGuide` 透传证据 |
| `03-resume-not-next.md` | `03` §3 三个实验的结论（含 logcat / PC 日志片段） |
| `04-settings-mapping.md` | `ai_config`/`tmdb_config` 往返的请求/响应原文（**脱敏后**） |
| `windows-acceptance.txt` | 一键验收原始输出 |
| `test-run.txt` | `flutter test` 原始输出 |
| `analyze.txt` | `flutter analyze` 原始输出 |
| `reverse-checks.txt` | 反向验证原始输出 |
| `screenshots/` | 多宽高比截图（沿用 `DESIGN.md` 的 1.6:1 / 2.0:1 / 2.35:1 纪律） |

---

## 9. 回归门禁（**必须继续绿**）

本轮会改动以下既有测试锁定的结构，逐条列出**不得破坏**的断言：

| 测试文件 | 锁定的内容 | 本轮风险 |
| --- | --- | --- |
| `test/phase5_android_sync_test.dart` | `pcSettingsWhitelist` 含 `tmdb_enabled`/`tmdb_config`；`pcSensitiveSettingsKeys` 含 `tmdb_config`；`SyncOptions.settings` 默认 `false` | 白名单扩展 |
| `test/phase5_android_bridge_test.dart` | 主机一致性校验 | 复用探测逻辑 |
| `test/phase5_sync_server_test.dart` | `/device`、`/action?do=sync` 的路径与状态码 | 服务端扩展 |
| `test/phase5_sync_ui_test.dart` | `android-sync-server`/`android-sync-push`/`android-sync-settings` 三个 `ValueKey` | UI 扩展 |
| `test/phase6_history_page_test.dart` | 历史页卡片与删除模式 | 同步写入路径 |
| `test/phase6_detail_resume_test.dart` | `detail-hero-play`、续播按钮文案 | 续播逻辑 |
| `integration_test/phase5_sync_flow_test.dart` | 端到端同步 | 增量路径 |
| `integration_test/mvp_a_flow_test.dart` | `find.text('清空历史')` | 不得改文案 |

**硬约束**：`pcSettingsWhitelist` 只能**追加**，不得删除或重排既有项
（`phase5_android_sync_test.dart` 可能按顺序断言）。

---

## 10. 与 Phase 6 的衔接

Phase 6 引入的历史删除与 `history_deletions` 表与本轮的删除传播直接相关：

- 单条删除与批量删除都**必须**逐条走 `AppState.deleteHistory(id)`
  （`docs/phase6/README.md` §4）；
- 本轮的删除传播只**读** `history_deletions`，**不新增**写入路径；
- 反向验证 #6（游标推进）必须覆盖"删除批次失败时不推进游标"。
