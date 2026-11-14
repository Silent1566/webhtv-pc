# Phase 7 计划（安卓实时同步 + 保活心跳 + 续播修复）

- 状态：**实施中**（T1–T17 全部完成；下一步为真机验证 V1–V5）
- 日期：2026-10-17
- 对应设计文档章节：本目录 `design/00`–`design/04`、`docs/webhtv-pc-design.md` §29（Phase 7）
- 上游：`docs/phase5/README.md`（Phase 5：T4 站点桥接 + 历史/设置同步，已完成）、
  `docs/phase6/README.md`（Phase 6：历史页 / 详情页续播 / 季度选集 / AI 集季识别，已完成）
- 上游参考工程：`webhtv/默影视`（Android，`F:\Workspace\webtv3\webhtv`）

## 0.1 实施进度

| 任务 | 产出 | 状态 | 提交 |
| --- | --- | --- | --- |
| T1 | `lib/core/realtime_sync.dart`（游标/增量/方向/周期/退避） | ✅ 完成 | `dd0a45e` |
| T2 | 同上（三态判定 + 唤醒阶梯） | ✅ 完成 | `dd0a45e` |
| T3 | `lib/core/playback.dart`（`isGenuineEnd` + `completed` 跨端语义） | ✅ 完成 | `dd0a45e` |
| T15 | 连播改事件驱动 + `_advanceInFlight` 守卫 | ✅ 完成 | `1175ba0` |
| T16 | `_isGenuineEnd` 接入连播闸门 | ✅ 完成 | `1175ba0` |
| T17 | 失败回滚 `_request` + `clearCompleted()` + 三出口 | ✅ 完成 | `1175ba0` |
| T9 | 设置白名单扩展到 AI 段 + `unsupportedKeys` + `raw` 保真 | ✅ 完成 | `68e1c79` |
| T4 | 安卓读取客户端 + 降级链（`/history` → `/current`） | ✅ 完成 | `70e2cb4` |
| T5 | PC 拉取端点 + 身份解析 + 能力声明 | ✅ 完成 | `1063697` + `d85836f` |
| T6 | 实时引擎（定时器 / 心跳编排 / 退避 / 游标推进） | ✅ 完成 | `209c456` |
| T7 | 状态层：开关矩阵 / 联动 / 周期 / 引擎装配 / 快照 | ✅ 完成 | `8d0f05f` |
| T8 | UI：实时同步区块 + 手动四按钮 + 六条披露 | ✅ 完成 | `1b188d4` |
| T10 | fixture 扩展（5 路由 + 9 故障注入 + 2 TCP 模式） | ✅ 完成 | `5b8caf7` |
| T11 | 反向验证 8 项 | ✅ 完成 | `e62cc3e` |
| T12 | 发布包符号 + 设计文档一致性门禁 | ✅ 完成 | `c918f15` |
| T13 | 一键验收脚本（G1–G12 全绿） | ✅ 完成 | `cb7fbde` |
| T14 | L3 集成（实时同步 / 保活三态，真实 HTTP + 真实 socket） | ✅ 完成 | 本提交 |
| T19 | 安卓侧契约补齐（A + C） | ✅ 已交付 | 安卓 `e55f19276fb0` |

已绿的套件（`design/04` §3.1 清单，L1/L2 全部就位；L3 目前只有续播一条）：

| 套件 | 层 | 用例 |
| --- | --- | --- |
| `test/phase7_realtime_core_test.dart` | L1 | S1–S33 |
| `test/phase7_keepalive_test.dart` | L1 | K1–K11 |
| `test/phase7_resume_gate_test.dart` | L1 | R1–R6 |
| `test/phase7_player_advance_test.dart` | L2 | R7–R15 |
| `test/phase7_settings_mapping_test.dart` | L2 | S23–S29 |
| `test/phase7_android_read_client_test.dart` | L2 | T4：路径 A 读取 + 降级 |
| `test/phase7_pull_endpoint_test.dart` | L2 | T5：S17–S20 + 6（游标/limit/hasMore） |
| `test/phase7_identity_resolve_test.dart` | L2 | T5：6b/6c（四态 + 幂等 + 能力声明） |
| `test/phase7_identity_persistence_test.dart` | L2 | T5：注册表跨重启存活 |
| `test/phase7_realtime_engine_test.dart` | L2 | T6：E1–E36（假时钟编排 / 联动 / 退避 / 游标 / G12） |
| `test/phase7_sync_ui_test.dart` | L2 | T8：14 项（符号/默认值/联动/六条披露/手动四按钮） |
| `test/phase7_realtime_state_test.dart` | L2 | T7：15 项（开关矩阵 / 联动 / 持久化 / 引擎装配 / 路径 B 门禁） |
| `integration_test/phase7_resume_flow_test.dart` | L3 | 真实窗口续播 + 闸门 |
| `integration_test/phase7_realtime_flow_test.dart` | L3 | 真实 HTTP 增量（第二轮只拉增量 / 幂等 / 403 不推进游标 / 路径 B / 身份解析） |
| `integration_test/phase7_keepalive_flow_test.dart` | L3 | 真实 socket 四态（可达 / 降级 / 服务未运行 / 进程冻结） |

已实测的反向验证：`design/04` §3.2 的 **8 项全部完成**——
`#1` `duration<=0`、`#2` `_advanceInFlight` 守卫、`#3` 失败回滚、
`#4` 三态误归类、`#5` 退避恒定、`#6` 游标过早推进、
`#7` `ai_config` 当对象读、`#8` 凭据项默认参与。
（`#1`–`#6`、`#8` 见 `dd0a45e`/`1175ba0`，`#7` 见 `68e1c79`。）

T5 另做两项现场反向验证（本次提交前实测，均「破坏即转红、还原即转绿」）：

- **注册表不登记键别名** → 「同一把键从不同层提交也能命中」用例落到 `create`（红）；
- **`resolve` 成功变更后不落盘**（去掉 `onChanged`）→ 「`adopt` 结论跨重启存活」
  用例等不到 `settings.json` 的 `sync.identity`（红）。

T6 把 `design/04` §5 的**反向验证 #6**（游标在部分失败时也推进）真正跑了：
把引擎里 `decideCursor(outcome: outcome)` 改成恒传 `success` →
E25（部分条目失败）/ E26（合并阶段 failed）**立即转红**；还原即转绿。

---

## 0. 本阶段目标

Phase 5 把「桥接 + 同步」做成了**手动、一次性、快照式**；Phase 7 把它升级为
**可选的实时、增量、双向**，并解决两个用户实测痛点（息屏失联、缓存耗尽后跳集）。

五项能力：

| # | 能力 | 说明 | 设计文档 |
| --- | --- | --- | --- |
| 1 | **实时同步** | 历史 / TMDB / AI 设置按周期增量互通（默认 60 s，可关） | `design/01` |
| 2 | **双向路径** | PC 轮询（A）+ PC 暴露增量端点供安卓远端同步源消费（B） | `design/01` §3 |
| 3 | **保活与唤醒** | 心跳（保活 + 可达性 + 状态采集）、三态判定、唤醒阶梯 | `design/02` |
| 4 | **手动拉取/推送** | 两种拉取语义分开 + 三种推送 + 编排 | `design/01` §4.4/§4.5 |
| 5 | **续播修复** | 提前 EOF 不再触发连播；失败保留续播上下文；恢复路径不连播 | `design/03` |

**不可退让的边界**（详见 `design/00` §4，五条原则）：

- **P1 实时同步默认关闭**，开关粒度到"方向"；
- **P2 增量优先**，全量必须显式，禁止 `force` 清表；
- **P3 失败不破坏本地**，游标只在整批成功后推进；
- **P4 保活不得越界**（不静默改安卓系统设置，只探测/唤醒/引导）；
- **P5 续播判定基于"未完成"**，且与"播完"可区分。

---

## 1. 现状盘点

### 1.1 缺口

| 缺口 | 设计依据 | 现状 |
| --- | --- | --- |
| 无实时同步 | `design/01` §1 | Phase 5 只有按钮触发的一次性快照 |
| 无安卓读取端点调用 | `design/01` §4.1 | `sync_client.dart` 只有 `/action?do=sync` 推送 |
| 无增量拉取端点 | `design/01` §3.2 | `sync_server.dart` 只有 `/device` 与 `/action` |
| 设置白名单无 AI | `design/01` §5.1 | `pcSettingsWhitelist = ['tmdb_enabled','tmdb_config']` |
| 无心跳 | `design/02` §3 | 全仓库无心跳（`spider_process.dart` 的心跳是 Spider IPC，与安卓无关） |
| 无三态判定 | `design/02` §4 | 只有 `bridgeUnreachable` 一类 |
| 无唤醒阶梯 | `design/02` §5 | 无 `/manage/session` 调用 |
| 连播触发在 `build()` 里 | `design/03` §2.3 D1 | `player_page.dart` 每次重建都可能重排 `_onCompleted` |
| 不校验"真播完" | `design/03` §2.3 D2 | 直接采信 media_kit 的 `completed` |
| 失败不回滚 `_request` | `design/03` §2.3 D3 | `_load()` 失败只设 `_loadError` |

### 1.2 已具备（可复用的基础）

| 能力 | 位置 | 本阶段如何复用 |
| --- | --- | --- |
| 设备探测与可达地址 | `lib/services/android_bridge_service.dart` | 心跳复用 `probeDevice` 与 `normalizeBase` |
| 合并算法与删除标记 | `lib/core/android_sync.dart`、`lib/services/storage.dart` | **零改动**复用 `buildHistoryMergePlan` / `applyHistoryMerge` |
| PC 侧服务端骨架 | `lib/services/sync_server.dart` | 新增路由（复用 8 MiB 上限、串行队列、脱敏） |
| 同步客户端 | `lib/services/sync_client.dart` | 新增读取端点调用 |
| 错误分类 | `lib/core/app_error.dart` | 新增 `realtime*` / `keepAlive*` |
| 设置持久化模式 | `lib/state/sync_state.dart`（`sync` 段） | 新增 `realtime` 子段，`version` 1 → 2 |
| 周期写入进度 | `lib/ui/player_page.dart#_persistProgress` | 续播修复复用 |
| 续播查询 | `lib/state/app_state.dart#resumePositionFor` | **零改动**复用 |
| fixture 服务 | `tools/fixture_server/server.py` | 新增 4 路由 + 3 故障注入 + 2 TCP 模式 |
| 一键验收脚本 | `tools/phase5/run_windows_acceptance.ps1` | 复制结构为 `tools/phase7/run_windows_acceptance.ps1` |
| 反向验证机制 | `tools/phase5/verify_reverse_checks.py` | 复制结构为 `tools/phase7/verify_reverse_checks.py`（8 项） |

---

## 2. 实施顺序

### 2.1 文档阶段（已完成）

| # | 任务 | 产出 | 验收 |
| --- | --- | --- | --- |
| D1 | 索引与原则 | `design/00` | 5 条原则、实测契约快照（§3.1–§3.6）、10 条决策、5 个开放问题 |
| D2 | 实时同步协议 | `design/01` | 两条路径、逐键映射表、开关矩阵、退避序列、8 类新错误 |
| D3 | 保活与唤醒 | `design/02` | 心跳协议、三态判定、唤醒阶梯 L0–L5、实测脚本 |
| D4 | 续播修复 | `design/03` | 三个 PC 侧缺陷定位、判定实验、修复设计、安卓侧边界 |
| D5 | 测试与验收 | `design/04` | L1/L2/L3 分层、12 个套件、8 项反向验证、12 项门禁 |

### 2.2 实施阶段

**依赖关系**：

```text
T1 T2 T3（纯逻辑，可并行）
   ↓
T4 ← T1 T2        T5 ← T3
   ↓                    ↓
T6 ← T4 T5（引擎编排）
   ↓
T7 ← T6（状态层）→ T8（UI）
   ↓
T9（fixture）→ T10（反向验证）→ T11（符号门禁）→ T12（一键验收）
   ↓
T13（L3 集成）→ T14（证据）

T15 T16 T17（续播修复，与上面并行）
   ↓
T13 的 phase7_resume_flow_test 依赖 T15–T17
```

| # | 任务 | 依赖 | 产出 | 验收 |
| --- | --- | --- | --- | --- |
| T1 | 纯逻辑：游标 / 增量判定 / 方向归一化 / 周期校验 / 退避 | — | `lib/core/realtime_sync.dart` | `phase7_realtime_core_test.dart`（L1） |
| T2 | 纯逻辑：三态判定状态机 + 唤醒阶梯选择 | — | `lib/core/realtime_sync.dart` | `phase7_keepalive_test.dart`（L1） |
| T3 | 纯逻辑：`_isGenuineEnd` + `completed` 跨端语义 | — | `lib/core/playback.dart` 或 `player_page.dart` 的纯函数部分 | `phase7_resume_gate_test.dart`（L1） |
| T4 | 服务：安卓读取客户端（`/api/playback/history` + 降级到 `/current`、`/manage/session`） | T1 T2 | `lib/services/android_read_client.dart` | `phase7_android_read_client_test.dart`（L2） |
| T5 | 服务：拉取端点（`/api/playback/sync` + `identity/resolve` + `sync/status`） | T3 | `lib/services/sync_server.dart` 扩展 | `phase7_pull_endpoint_test.dart`（L2） |
| T6 | 服务：实时引擎（定时器 + 心跳编排 + 退避 + 游标推进） | T4 T5 | `lib/services/realtime_sync_engine.dart` | `phase7_realtime_engine_test.dart`（L2，假时钟） |
| T7 | 状态层：开关矩阵、周期、联动规则、结果快照 | T6 | `lib/state/sync_state.dart` 扩展 | 含在 L1/L2 |
| T8 | UI：实时同步区块 + 手动三按钮 + 披露文案 | T7 | `lib/ui/config_pages.dart` 扩展 | `phase7_sync_ui_test.dart`（L2） |
| T9 | 设置白名单扩展到 AI 段 + `unsupportedKeys` + `raw` 保真 | — | `lib/core/android_sync.dart` 扩展 | `phase7_settings_mapping_test.dart`（L2） |
| T10 | fixture 扩展（含身份解析与降级模拟） | — | `tools/fixture_server/server.py`、`tools/phase7/check_android_fixture.py` | G1 |
| T11 | 反向验证 8 项 | T1–T9 | `tools/phase7/verify_reverse_checks.py` | G8 |
| T12 | 发布包符号门禁 + 设计文档一致性 | T8 T9 | `tools/phase7/verify_release_symbols.py`、`verify_design_docs.py` | G10 G11 |
| T13 | 一键验收脚本 | T10–T12 | `tools/phase7/run_windows_acceptance.ps1` | G1–G12 |
| T14 | L3 集成（3 个 flow） | T13 | `integration_test/phase7_*_flow_test.dart` | G7 |
| T15 | 修复 D1：连播改事件驱动 + `_advanceInFlight` 守卫 | T3 | `lib/ui/player_page.dart` | `phase7_player_advance_test.dart`（L2） |
| T16 | 修复 D2：`_isGenuineEnd` 接入连播闸门 | T3 T15 | 同上 | 同上 |
| T17 | 修复 D3：失败回滚 `_request` + `clearCompleted()` + 三出口 | T15 T16 | `player_page.dart`、`player_controller.dart` | 同上 |
| T18 | 证据落盘 | T13 T14 | `docs/phase7/evidence/**` | `design/04` §8 |
| **T19** | **安卓侧契约补齐（外部依赖，在 webtv4）** | — | `F:/Workspace/webtv4/webhtv/docs/PC-REALTIME-SYNC-01-android-contract-gap.md` | ✅ **A + C 已交付**（安卓 `e55f19276fb0`）；D 暂缓、E 待实验 |

### 2.2.1 安卓侧依赖（T19，**部分已交付**）

T19 不在本仓库。**2026-10-17 已交付 A + C**（安卓 `dev4` 提交
`e55f19276fb0a73bce3a47f9bda2c16923d318b3`，tag
`recovery/PC-REALTIME-SYNC-01/20261017042235-e55f19276fb0`）：

| 安卓侧改动 | 状态 | 对 PC 侧的影响 |
| --- | --- | --- |
| A `GET /api/playback/history` | ✅ **已交付**（真机实测） | 路径 A 可用；降级分支仍需保留 |
| B `identity/resolve` + `sync/status` | **已勘误为 PC 侧职责** | 不是安卓改动，PC 必须自己实现（`01` §3.2.1） |
| C `apiSafe()` 补 `episodeId` | ✅ **已交付**（真机实测） | 集消歧可用；`episodeName` 兜底仍需保留 |
| D 统一 `completed` 阈值 | ⏸️ **暂缓** | PC 一律按自己公式重算 |
| E `STATE_ENDED` 加闸门 | 🔬 **待实验** | PC 侧 `_isGenuineEnd` 仍必做 |

**硬约束（不因 A/C 已交付而放宽）**：PC 侧实现必须**同时支持两种形态**
（能力探测 + 降级），不得假设对端一定是新版安卓。用户在 Settings 里填的
`RemoteSyncConfig.url` 可以是任何第三方服务端。

**已知限制（实测发现）**：`/api/playback/history` 只查**当前 `VodConfig.getCid()`**，
实测设备上历史分散在多个 `cid`（`1`/`3`/`18`/`33`…）。因此**空数组不等于
「该站点在安卓端从未播放」**——PC 的文案与状态机不得做这个推论。

### 2.3 建议的提交粒度

每个任务一个提交，提交信息用中文并带设计文档章节号：

```text
新增：实时同步纯逻辑（游标/增量/退避）（design/01 §4.2、§6.3）
新增：安卓读取客户端与降级链（design/01 §4.1）
新增：心跳与三态可达性判定（design/02 §3、§4）
修复：连播改为事件驱动并加单次守卫（design/03 §4.1）
修复：播放失败回滚续播上下文（design/03 §4.3）
测试：锁定 ai_config 的 JSON 字符串解包（design/01 §5.3）
```

---

## 3. 门禁表

完整判据见 `design/04` §6。

### 3.1 前置依赖（缺一个是**环境问题**，不是代码缺陷）

一键验收会在缺依赖时失败，且失败形态容易误判（例如 G2/G3 直接退出 2）。
先把这些装好：

| 依赖 | 用于 | 缺失时的现象 | 安装 |
| --- | --- | --- | --- |
| `jsonschema`（Python） | G2 `tests.test_contracts`、G3 `scripts/validate_contracts.py` | `ModuleNotFoundError: No module named 'jsonschema'` / `错误：缺少 jsonschema`，退出码 2 | `py -3 -m pip install jsonschema` |
| `puro` + `webhtv` 环境 | G4/G5/G6/G7/G8/G12 的 `flutter` / `dart` | `flutter: command not found`（本机不把 flutter 放进 PATH） | 已有；命令统一用 `puro -e webhtv -p .` |
| 回环端口 18080/18081 空闲 | G1 的 fixture 服务（含 TCP 模式） | fixture 启动超时 | 关闭占用进程，或用 `-FixturePort`/`-TcpPort` 换端口 |

### 3.2 门禁表

| # | 门禁 | 命令 | 通过判据 |
| --- | --- | --- | --- |
| G1 | 安卓 fixture 预检 | `py -3 tools/phase7/check_android_fixture.py --base <url> --tcp <host:port>` | 5 路由 + 9 故障注入 + TCP 模式全通过 |
| G2 | Python 契约 | `py -3 -m unittest tests.test_contracts` | 新增用例通过 |
| G3 | Schema 校验 | `py -3 scripts/validate_contracts.py` | 无错误 |
| G4 | 静态检查 | `dart analyze` | 无问题 |
| G5 | 单元测试 | `flutter test` | 全绿（含 9 个 `phase7_*` 套件） |
| G6 | 套件存在性 | 脚本内清单核对 | 9 个套件文件均存在 |
| G7 | Windows 集成 | `flutter test integration_test/phase7_*_flow_test.dart -d windows` | 3 个套件全绿（逐套件单独跑） |
| G8 | 反向验证 | `py -3 tools/phase7/verify_reverse_checks.py` | 8 项全部"按预期失败"且还原后工作区干净 |
| G9 | 凭据与指纹脱敏 | `py -3 tools/phase5/verify_bridge_redaction.py` + `py -3 tools/phase7/verify_realtime_redaction.py` | 无 API Key / token / 指纹原文 |
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

结果写入 `docs/phase7/evidence/windows-acceptance.txt`。

### 3.1 测试套件

| 层 | 套件 | 覆盖 |
| --- | --- | --- |
| L1 | `test/phase7_realtime_core_test.dart` | 游标、增量、方向、周期、退避（用例 S1–S13） |
| L1 | `test/phase7_keepalive_test.dart` | 三态、退避恢复、唤醒阶梯（K1–K11） |
| L1 | `test/phase7_resume_gate_test.dart` | `_isGenuineEnd`、`completed` 跨端（R1–R6） |
| L2 | `test/phase7_realtime_engine_test.dart` | 假时钟编排、心跳联动、403 立即停、游标不早推 |
| L2 | `test/phase7_android_read_client_test.dart` | 请求形态、`Host` 头、降级链（S14–S16） |
| L2 | `test/phase7_pull_endpoint_test.dart` | 响应形态与别名、鉴权（S17–S20） |
| L2 | `test/phase7_settings_mapping_test.dart` | 逐键映射、`raw` 保真（S23–S29） |
| L2 | `test/phase7_player_advance_test.dart` | 防重入、失败回滚、恢复不连播（R7–R15） |
| L2 | `test/phase7_sync_ui_test.dart` | 开关矩阵、周期、手动四按钮、披露（S21–S22、D1–D5） |
| L3 | `integration_test/phase7_realtime_flow_test.dart` | 真实 HTTP + SQLite 增量同步 |
| L3 | `integration_test/phase7_keepalive_flow_test.dart` | 真实 HTTP 三态 → 退避 → 恢复 |
| L3 | `integration_test/phase7_resume_flow_test.dart` | 真实窗口：提前 EOF → 不跳集 → 续播 |

### 3.2 反向验证（机器校验）

`tools/phase7/verify_reverse_checks.py` 纳入一键验收，逐项临时破坏契约、
断言对应用例确实失败、再无条件还原并校验工作区干净：

| # | 破坏方式 | 必须失败的用例 |
| --- | --- | --- |
| 1 | `_isGenuineEnd` 去掉 `duration <= 0` 检查 | `phase7_resume_gate_test.dart` |
| 2 | `_advanceInFlight` 守卫恒 `false` | `phase7_player_advance_test.dart` |
| 3 | 失败路径不回滚 `_request` | `phase7_player_advance_test.dart` |
| 4 | 三态把"TCP 通但 HTTP 超时"归为 `NETWORK_UNREACHABLE` | `phase7_keepalive_test.dart` |
| 5 | 退避序列改为恒定周期 | `phase7_realtime_core_test.dart` |
| 6 | 游标在部分失败时也推进 | `phase7_realtime_engine_test.dart` |
| 7 | `ai_config` 当对象读（不解 JSON 字符串） | `phase7_settings_mapping_test.dart` |
| 8 | 含凭据项默认参与实时同步 | `phase7_realtime_core_test.dart` |

**#1 与 #2 是本轮最容易悄悄写错的两处**（直接对应 `design/03` §2.3 的 D1/D2）。

---

## 4. 实测契约要点（详见 `design/00` §3）

| # | 事实 | 证据等级 |
| --- | --- | --- |
| 1 | 安卓**没有**推送端点（无 WebSocket / SSE / long-poll） | 源码（17 个 `Process` 全量枚举） |
| 2 | 安卓有「远端同步源」：**它自己**按 5 min 周期拉 HTTP 端点 | 源码（`PlaybackRemoteSyncer`） |
| 3 | `/api/playback/current` **不是**"该站点最近一条历史"，而是**播放内存态**（未播放恒 404） | 源码（`PlaybackRuntime.currentHistory()`、`PlaybackApi.current`） |
| 4 | 安卓**没有**"列出全部历史"或"按站点读历史"的读取端点 | 源码（17 个 `Process` 全量枚举） |
| 5 | 安卓已有完整「身份解析协议」客户端，每次同步前 `POST /api/playback/identity/resolve` | 源码（`PlaybackIdentityResolver`、`PlaybackRemoteSyncer:81`） |
| 6 | 五套服务端参考实现已存在（Cloudflare/Deno/Vercel/Go/Rust）+ 共享 fixture | 源码（`serverless/*`） |
| 7 | 拉取请求头：`X-WebHTV-Config-Key` / `X-WebHTV-Config-Aliases` / `X-WebHTV-Since` / `X-WebHTV-Limit` / `X-WebHTV-Token` | 源码 |
| 8 | 响应接受 `nextSince`/`next_since`/`nextCursor`/`cursor` 与 `items`/`records`/`list`/`upserts`/`changes`/`deletions`/`tombstones` | 源码（`PlaybackRemoteSyncPayload`） |
| 9 | 游标是**单调递增的 sequence 整数**（非时间戳）；非法游标 → 400 | 源码（`serverless/webhtv-remote-go/playback.go:812`） |
| 10 | `apiSafe()` **不含** `episodeUrl`，且 `OBJECT` 也不含 | 源码（`PlaybackFieldPolicy.java:11,25-30`） |
| 11 | `tmdb_config` / `ai_config` 的值是 **JSON 字符串**，不是对象 | 源码（`Setting.getTmdbConfig/getAiConfig`） |
| 12 | `ManageService` 空闲 **600 s** 自动 `stopSelf()`；`IDLE_TIMEOUT=600_000` | 源码 |
| 13 | `ManageService` 只在用户打开「管理页」时启动；`touch()` 在服务未运行时直接返回 | 源码（`ManagePageDialog`、`ManageService.touch`） |
| 14 | `/manage/session` 返回 `wakeLock`/`wifiLock`/`batteryOptimized`/`backgroundGuide` 等 | 源码 |
| 15 | 安卓 `onError` 路径是"重置 + 换线路/换源"，**不**切下一集 | 源码（`VideoActivity.onError`） |
| 16 | 安卓 `STATE_ENDED` 路径**也没有**"真播完"闸门（`checkEnded` 无条件 `checkNext`） | 源码（`VideoActivity:6066-6072`、`7846-7848`） |
| 17 | 安卓 `PlaybackRecord.completed` 用 `progress >= 0.95`，与 PC 的 5 s 余量**不等价** | 源码 |
| 18 | `HttpEofRecoveryDataSource` 只允许**连续** 3 次重连 | 源码 |
| 19 | 安卓已有 `History.isNearEnding()`（`min(30s, max(5s, duration/100))`），但**只**用于续播位置 | 源码（`History.java:1053-1058`、`VideoActivity:11919`） |

---

## 5. 风险与开放问题

| # | 风险 | 影响 | 缓解 |
| --- | --- | --- | --- |
| R1 | 安卓侧进程被冻结，PC 无法唤醒 | 实时同步失效 | 三态判定 + 引导（`design/02` §4/§5）；**不假装能修**（P4） |
| R2 | 轮询上百站点造成电量事故 | 移动端耗电 | 默认只轮询最近活跃 20 个 + 显式开关（`design/01` §3.1） |
| R3 | 含凭据设置走明文 HTTP | 凭据泄露 | 默认不实时 + 显式开启 + UI 警告（P1、`design/01` §5.4） |
| R4 | 游标推进过早导致数据永久丢失 | 数据丢失 | 整批成功才推进 + 反向验证 #6（P3） |
| R5 | `episodeUrl` 缺失导致同剧多集塌缩 | 历史错乱 | `episodeName` 兜底 + 双空不合并（`design/01` §4.1） |
| R6 | 提前 EOF 被当成播完 | 跳下一集 | `_isGenuineEnd` + 反向验证 #1（P5） |
| R7 | 连播重复触发 | 连跳多集 | `_advanceInFlight` + 反向验证 #2（D1） |
| R8 | 定时器泄漏 | 测试挂起 / 后台耗电 | G12 定时器计数门禁 |
| R9 | 安卓 5 套 AI 提示词被回推抹掉 | 静默数据损失 | `raw` 保真 + 反向验证 #7（`design/01` §5.3） |
| R10 | 实时同步与 Phase 5 手动同步互相覆盖 | 数据错乱 | 同一合并算法（幂等）+ UI 明示（`design/01` §3.3） |

| # | 开放问题 | 结论 | 依据 |
| --- | --- | --- | --- |
| Q1 | 实时同步默认开还是关？ | **默认关闭** | P1 |
| Q2 | 用推送还是轮询？ | **轮询 + 反向拉取端点** | `design/00` §3.1 |
| Q3 | 轮询周期？ | 默认 **60 s**，可配 15/30/60/300 s | `design/00` §8 Q3 |
| Q4 | 心跳周期？ | 默认 **30 s**，范围 10–300 s | `design/02` §3.4 |
| Q5 | 是否做 WebSocket？ | **不做** | `design/00` §3.1 |
| Q6 | 设置同步是否包含 AI？ | **包含**，与 TMDB 同列为含凭据项 | `design/01` §5.1 |
| Q7 | 删除是否传播？ | **传播**，逐条写墓碑 | `design/00` §3.6 |
| Q8 | 手动拉取是全量还是逐站点？ | **两者都提供且分开标注** | `design/01` §4.4 |
| Q9 | 息屏后连不上，PC 是否要"修"？ | **不修**，只探测/唤醒/引导 | P4 |
| Q10 | "跳下一集"改哪一侧？ | **先修 PC 侧**，安卓侧只做证据与指引 | `design/03` §5 |
| Q11 | 是否支持多设备实时同步？ | **本阶段只支持一台活跃对端**（最近使用的那台） | 简化；多设备留待后续 |
| Q12 | 实时同步是否同步收藏（`keep`）？ | **不同步**，保留 Phase 5 手动路径 | `design/01` §1.2 |

---

## 6. 待办：实施前必须完成的实测（`design/04` §7）

| # | 实测 | 回答 | 阻塞哪个任务 |
| --- | --- | --- | --- |
| V1 | 息屏后 `/api/playback/current` 是否可读 | `00` O1 | T4（决定降级策略） |
| V2 | `/manage/session` 能否唤醒 | `00` O2 | T2（决定唤醒阶梯有效性） |
| V3 | 安卓远端同步源指向 PC 是否稳定 | `00` O4 | T5（决定路径 B 是否可交付） |
| V4 | 提前 EOF 走 `onError` 还是 `STATE_ENDED` | `00` O3 | T16（决定修复重心） |
| V5 | PC 侧是否误触发连播 | `00` O3 | T15（验证 D1 假设） |

**V4/V5 的结论必须写入 `docs/phase7/evidence/03-resume-not-next.md`**，
并据此决定是否需要向安卓工程提 issue（`design/03` §5）。
