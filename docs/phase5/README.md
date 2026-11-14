# Phase 5 计划（安卓桥接：T4 站点接入 + 历史/设置同步）

- 状态：**已完成**（设计 `design/00`–`design/06` + 实现 T1–T14 全部落地；`PHASE5-ACCEPT result=PASS gates=all`）
- 日期：2026-10-08（多源化改造 2026-10-26，见 §7；历史聚合与跨源续播 2026-10-27，见 §8；详情身份兜底 2026-10-28，见 §9）
- 后续验证：[T4 网盘分集与播放代理（2026-10-10）](evidence/t4-folder-playback.md)
- 后续验证：[桥接线路标准化为普通线路（2026-10-11）](evidence/t4-standard-bridge-lines.md)
- 后续验证：[站点选择器打开卡顿修复（2026-10-12）](evidence/site-picker-latency.md)
- 后续改造：[安卓桥接多源化与历史按源隔离（2026-10-26）](design/04-bridge-multisource.md)
- 后续改造：[历史同名聚合与跨源续播（2026-10-27）](design/05-history-aggregation-and-cross-source-resume.md)
- 缺陷修复：[详情身份兜底（2026-10-28）](design/06-detail-identity-fallback.md)
- 对应设计文档章节：本目录 `design/00`–`design/06`、`docs/webhtv-pc-design.md` §21（Phase 5 生态与同步）、§22.1、§28（安卓桥接）
- 上游：`docs/phase4/README.md`（Phase 4 已完成：TMDB 元数据增强）
- 上游参考工程：`webhtv/默影视`（Android，`F:\Workspace\webtv3\webhtv`，实测设备 `192.168.50.3:5559`）

---

## 0. 本阶段目标

Android 侧已经暴露出 **T4 本机网关**（`c388619629`：`feat(server): add local T3-to-T4 gateway`），
它把 Android 当前加载的全部站源统一包装成 `type="4"` 的 HTTP API 站点。
本阶段让 PC：

1. **接入**该网关，**间接访问** Android 上的全部站源（含 T3 爬虫、网盘、猫源）；
2. 与 Android **双向共用播放历史**；
3. 与 Android **共用相关设置**（白名单子集）。

四项能力：

| # | 能力 | 说明 |
| --- | --- | --- |
| 1 | **设备发现** | `/device` 探测、局域网扫描、手动地址 |
| 2 | **站点桥接** | `/vod/api?ac=config` → PC 配置记录（`type=4`），不复制爬虫 |
| 3 | **历史同步** | PC 实现 `/device` + `/action?do=sync` 服务端，接收 Android 推送；也可反向推送 |
| 4 | **设置同步** | `SyncOptions` 白名单子集（默认不含含凭据项） |

**不可退让的边界**（详见 `design/00` §4，五条原则）：

- **P1 桥接不复制**：Android 的站源由 Android 自己执行，PC 只做 HTTP 客户端。
- **P2 地址来自请求**：站点地址以 PC 可达地址为基准，且必须校验响应主机一致性。
- **P3 默认关闭、失败不破坏本地**：同步默认关闭；禁止 `force` 清表；旧不覆盖新。
- **P4 不引入自引用**：拒绝把本机自己当作来源。
- **P5 能力缺口必须披露**：403/404/超时不得折叠成"空结果"。

---

## 1. 现状盘点

### 1.1 缺口

| 缺口 | 设计文档依据 | 现状 |
| --- | --- | --- |
| 无设备发现 | `design/01` §4 | 无任何局域网探测；`discover` 全仓库零命中 |
| 无 T4 桥接 | `design/01` §3/§5 | `type=4` **站点执行**已完整（`SiteType.jsonApiBase64Ext`），但**没有**拉取/导入网关配置的路径 |
| 无 LAN 服务端 | `design/02` §4 | 唯一的本地服务 `LocalProxyServer` **硬性只允许回环**，且路径空间是 `/p/<token>/…`，不能复用于 `/device` 与 `/action` |
| 无历史合并 | `design/02` §4.4 | `storage.dart` 只有 `upsertHistory`（无条件覆盖）与 `clearHistory`，**没有**"旧不覆盖新"的合并路径 |
| 无删除标记 | `design/02` §4.5 | 删除后远端旧记录会复活 |
| 无同步 UI | `design/02` §5 | 设置页无安卓接入与同步入口 |
| 无桥接错误分类 | `design/01` §6、`design/02` §6 | `AppErrorKind` 无 `bridge*` / `sync*` 类别 |

### 1.2 已具备（可复用的基础）

| 能力 | 位置 | 本阶段如何复用 |
| --- | --- | --- |
| `type=4` 播放入口契约 | `lib/services/site_service.dart` | 桥接站点**零改动**即可播放（已实现无条件 `play=&flag=` 调用） |
| 配置文本 → `AppConfig` | `lib/core/config_parser.dart` | 网关响应走同一套解析（`asInt` 已支持字符串 `"4"`） |
| 配置记录落盘 | `lib/services/storage.dart` | 桥接配置作为**新记录**导入（不覆盖当前配置） |
| HTTP 与错误模型 | `lib/core/http_api.dart`、`lib/core/app_error.dart` | 新增 `bridge*` / `sync*` 类别，沿用同一归一化与脱敏 |
| SQLite 与迁移 | `lib/services/storage.dart` | 新增删除标记表；`schemaVersion` 2 → 3 |
| 日志脱敏 | `lib/services/log_service.dart` | 设备指纹掩码、历史片名不落日志 |
| fixture 服务 | `tools/fixture_server/server.py` | 新增 `/android/**` 命名空间与 `__stats` / `__mode` |
| 一键验收脚本 | `tools/phase4/run_windows_acceptance.ps1` | 复制结构为 `tools/phase5/run_windows_acceptance.ps1` |
| 反向验证机制 | `tools/phase4/verify_reverse_checks.py` | 复制结构为 `tools/phase5/verify_reverse_checks.py`（6 项） |
| 发布包符号门禁 | `tools/phase4/verify_release_symbols.py` | 扩展为 `tools/phase5/verify_release_symbols.py` |

---

## 2. 实施顺序

### 2.1 文档阶段（已完成）

| # | 任务 | 产出 | 验收 |
| --- | --- | --- | --- |
| D1 | 索引与原则 | `design/00-android-bridge-design-index.md` | 5 条原则、实测契约快照、上游取舍表、10 条决策齐备 |
| D2 | T4 站点桥接 | `design/01-android-t4-site-bridge.md` | 端点清单、可达地址两形态、配置转换 6 步、主机不一致三态、站点保真 6 项、6 类错误 |
| D3 | 同步协议 | `design/02-android-sync-protocol.md` | PC 必实现 4 端点、必调用 5 端点、字段映射表、合并算法、删除标记、7 类错误 |
| D4 | 测试与验收 | `design/03-bridge-test-and-acceptance.md` | L1/L2/L3 分层、fixture 与 8 种故障注入、4 个套件、11 项门禁、7 项反向验证 |
| D5 | 多源化（后续，2026-10-26） | `design/04-bridge-multisource.md` | 方案 B 取舍、`configKey` 端点、按源隔离历史、推送落源、降级矩阵 |
| D6 | 历史聚合与跨源续播（后续，2026-10-27） | `design/05-history-aggregation-and-cross-source-resume.md` | 三档聚合读视图、存储 v8 身份列、来源标注、跨源两路径、进度迁移 9 条规则 |
| D7 | 详情身份兜底（缺陷修复，2026-10-28） | `design/06-detail-identity-fallback.md` | 根因双证据、`VodIdentityHint` 穿透链、只在「详情 + 恰好一条」回填、四条边界、7+1 用例 |
| D8 | 主设计文档回填 | `docs/webhtv-pc-design.md` §21 + §22.1 + §23 + §26 + §28 | 章节号连续、交叉引用可解析 |

### 2.2 实施阶段

| # | 任务 | 产出 | 验收 | 状态 |
| --- | --- | --- | --- | --- |
| T1 | 纯逻辑：桥接转换 | `lib/core/android_bridge.dart` | `phase5_android_bridge_test.dart`（29 例） | ✅ |
| T2 | 纯逻辑：同步编解码与合并 | `lib/core/android_sync.dart` | `phase5_android_sync_test.dart`（43 例） | ✅ |
| T3 | 服务：设备探测与配置拉取 | `lib/services/android_bridge_service.dart` | `phase5_android_bridge_service_test.dart`（27 例） | ✅ |
| T4 | 服务：PC 同步服务端 | `lib/services/sync_server.dart` | `phase5_sync_server_test.dart`（30 例，真实回环 HTTP） | ✅ |
| T5 | 服务：同步客户端 | `lib/services/sync_client.dart` | `phase5_sync_client_test.dart`（21 例，请求捕获） | ✅ |
| T6 | 存储：合并路径与删除标记 | `lib/services/storage.dart` | `phase5_sync_storage_test.dart`（15 例）+ `schemaVersion` 2→3 迁移 | ✅ |
| T7 | 状态层 | `lib/state/app_state.dart`、`lib/state/sync_state.dart` | `SyncStateHost` 契约 + 设置持久化 + 三项开关默认关闭 | ✅ |
| T8 | 设置页 UI | `lib/ui/config_pages.dart` | `phase5_sync_ui_test.dart`（26 例）+ G10 入口符号 | ✅ |
| T9 | fixture 与预检 | `packages/test-fixtures/android/**`、`tools/fixture_server/server.py`、`tools/phase5/check_android_fixture.py` | 路由 **11 项**（多源化后含 `/manage/configs` 与 `ac=config&configKey=`）+ 8 种故障注入逐一可触发 | ✅ |
| T10 | 反向验证 | `tools/phase5/verify_reverse_checks.py` | **7 项**全部"按预期失败"（含多源化新增的网关地址拦截项） | ✅ |
| T11 | 发布包符号门禁 | `tools/phase5/verify_release_symbols.py` | 12 个 ASCII 符号 + 9 个中文串存在 | ✅ |
| T12 | 一键验收脚本 | `tools/phase5/run_windows_acceptance.ps1` | 11 项门禁全绿 | ✅ |
| T13 | L3 集成 | `integration_test/phase5_bridge_flow_test.dart`、`phase5_sync_flow_test.dart`、`phase5_sync_push_flow_test.dart` | 真实窗口 + 真实 HTTP + 真实 SQLite | ✅ |
| T14 | 证据落盘 | `docs/phase5/evidence/**` | 6 份证据（含 2 张截图） | ✅ |
| T15 | 多源化改造 | `lib/core/source_key.dart`、`lib/core/android_sources.dart`、`lib/core/history_scope.dart`、`lib/services/{storage,android_bridge_service,sync_client,sync_server}.dart`、`lib/state/{app_state,sync_state}.dart`、`lib/ui/{config_pages,library_pages}.dart` | 多源各成记录 / 历史按源隔离 + 全局开关 / 推送带 `configKey` 落目标源 / 安卓 `active` 全程不变 | ✅ |
| T16 | 多源化测试 | 新增 `phase5_bridge_multisource`(12)、`phase5_bridge_picker_ui`(3)、`phase6_history_scope_ui`(4)、`source_key_and_history_scope`(16) 四个套件 | 全绿 + `dart analyze` 干净 + fixture 预检 11 路由 | ✅ |

依赖关系：

```text
D1–D5（文档）
   ↓
T1 T2（纯逻辑，可并行）
   ↓
T3 ← T1        T4 T5 ← T2
   ↓                    ↓
T6 ← T2（合并与删除标记）
   ↓
T7 ← T3 T4 T5 T6
   ↓
T8 ← T7
   ↓
T9 → T10 T11 → T12 → T13 → T14
后置（后续改造）
   多源化：T15（PC 产品代码）→ T16（测试与预检扩写）
```

---

## 3. 门禁表

| # | 门禁 | 命令 | 通过判据 |
| --- | --- | --- | --- |
| G1 | 安卓 fixture 预检 | `py -3 tools/phase5/check_android_fixture.py --base <url>` | 路由 **11** 项（含多源端点）+ 故障注入 8 项全通过 |
| G2 | Python 契约 | `py -3 -m unittest tests.test_contracts` | 8 个新增用例通过 |
| G3 | Schema 校验 | `py -3 scripts/validate_contracts.py` | 无错误 |
| G4 | 静态检查 | `dart analyze` | 无问题 |
| G5 | 单元测试 | `flutter test` | 全绿（本机实测 147 个测试文件 2867 例） |
| G6 | 套件存在性 | 脚本内清单核对 | 12 个套件文件均存在 |
| G7 | Windows 集成 | `flutter test integration_test/phase5_*_flow_test.dart -d windows` | 3 个套件全绿 |
| G8 | 反向验证 | `py -3 tools/phase5/verify_reverse_checks.py` | **7 项**全部"按预期失败"且还原后工作区干净 |
| G9 | 凭据与指纹脱敏 | `py -3 tools/phase4/verify_tmdb_redaction.py` + `py -3 tools/phase5/verify_bridge_redaction.py` | 无凭据/设备指纹原文 |
| G10 | 发布包符号 | `py -3 tools/phase5/verify_release_symbols.py` | 12 个 ASCII 符号 + 9 个中文串存在，无测试壳污染；产物早于源码时明确报 `stale` |
| G11 | 产物可运行 | 既有 `debug-artifact-runnable` | Debug 入口是 `lib/main.dart` |

一键验收（需先启动 fixture 服务，脚本会自行确保）：

```powershell
pwsh -File tools/phase5/run_windows_acceptance.ps1
# 快速回归（跳过 Windows 集成测试）：
pwsh -File tools/phase5/run_windows_acceptance.ps1 -SkipIntegrationTests
# 可选：把真机实测摘要写入证据（不作为门禁）
pwsh -File tools/phase5/run_windows_acceptance.ps1 -ProbeRealDevice 192.168.50.3:9978
```

### 3.1 测试套件

| 层 | 套件 | 用例数（实测） |
| --- | --- | --- |
| L1 | `test/phase5_android_bridge_test.dart` | 29 |
| L1 | `test/phase5_android_sync_test.dart` | 43 |
| L2 | `test/phase5_android_bridge_service_test.dart` | 27 |
| L2 | `test/phase5_sync_storage_test.dart` | 15 |
| L2 | `test/phase5_sync_server_test.dart` | 30 |
| L2 | `test/phase5_sync_client_test.dart` | 21 |
| L2 | `test/phase5_sync_ui_test.dart` | 26 |
| L3 | `integration_test/phase5_bridge_flow_test.dart` | 4 个用例 / 8 步 |
| L3 | `integration_test/phase5_sync_flow_test.dart` | 1 个用例 / 8 步 |
| L3 | `integration_test/phase5_sync_push_flow_test.dart` | 1 个用例 / 6 步 |

后续修复的回归套件（不属于 Phase 5 本体，列此备查）：

| 层 | 套件 | 用例数（实测） |
| --- | --- | --- |
| L1 | `test/log_service_test.dart`（站点选择器卡顿修复，§16.4） | 8 |

多源化改造（T15/T16，2026-10-26）新增与扩展的套件：

| 层 | 套件 | 用例数（实测） |
| --- | --- | --- |
| L1 | `test/source_key_and_history_scope_test.dart` | 16 |
| L1 | `test/phase5_bridge_multisource_test.dart` | 12 |
| L2 | `test/phase6_history_scope_ui_test.dart` | 4 |
| L2 | `test/phase5_bridge_picker_ui_test.dart` | 3 |

### 3.2 反向验证（机器校验）

`tools/phase5/verify_reverse_checks.py` 纳入一键验收，逐项临时破坏契约、
断言对应用例确实失败、再无条件还原并校验工作区干净：

| # | 破坏方式 | 必须失败的用例 |
| --- | --- | --- |
| 1 | 主机一致性校验改为无条件放行 | `phase5_android_bridge_test.dart` |
| 2 | `position` 映射加 `/1000` 换算 | `phase5_android_sync_test.dart` |
| 3 | 合并裁决改为"远端总是胜" | `phase5_android_sync_test.dart` |
| 4 | 哨兵值不做过滤 | `phase5_android_sync_test.dart` |
| 5 | 删除标记检查被移除 | `phase5_android_sync_test.dart` |
| 6 | `SyncOptions` 的 `settings` 默认改为 `true` | `phase5_android_sync_test.dart` |
| 7 | 网关地址拦截改为无条件放行（回退到"给安卓新增桥接源"的缺陷） | `phase5_sync_client_test.dart` |

---

## 4. 实测契约要点（详见 `design/00` §3）

| # | 事实 | 证据等级 |
| --- | --- | --- |
| 1 | 站点 `api` 由**请求的 `Host` 头**现算（同请求改 Host → 地址随之变化） | 实测 |
| 2 | 实测 `ac=config` = **170 个站点，`type` 全为字符串 `"4"`**，31 KB | 实测 |
| 3 | `ac=site` 与 `ac=config` 返回**字节相同** | 实测 |
| 4 | `/device` 无鉴权，`type`：`0`=TV `1`=Mobile `2`=DLNA，相等性只比 `uuid` | 源码 + 实测 |
| 5 | 服务端口从 `9978` 顺序探测到 `9998` | 源码 |
| 6 | `/action?do=sync` 的 `mode`：`0`=发送 `1`=接收 `2`=都做 | 源码 |
| 7 | `type=history` 缺 `config` → **500 NPE** | 实测 |
| 8 | **Android 没有历史"拉取"接口**（17 个 `Process` 全量枚举） | 源码 |
| 9 | `POST /api/playback/progress` 默认 **403**（本机 API 修改未开启） | 源码 + 实测 |
| 10 | `History` 主键 = `siteKey@@@vodId@@@cid`；`position`/`duration`/`createTime` **均为毫秒** | 源码 |
| 11 | `Backup.restore()` 默认 **`clearAllTables()`**（破坏性） | 源码 |
| 12 | 设备 `172.16.1.4:9978` 在模拟器场景 PC **不可达**，须 `adb forward` | 实测 |

---

## 5. 风险与开放问题

| # | 风险 | 影响 | 缓解 |
| --- | --- | --- | --- |
| R1 | 真机与 fixture 行为漂移 | 导入失败 | 快照取自实测；`-ProbeRealDevice` 可复核（`design/03` §7.1） |
| R2 | Android 后续版本改变 T4 契约 | 桥接失效 | 契约入 fixture；版本不符给分类错误 |
| R3 | LAN 监听被滥用 | 安全 | 默认关闭 + 对端 uuid 白名单 + 8 MiB 上限 |
| R4 | `position` 单位被误改成秒 | 进度错乱 | 反向验证 #2 必须存在 |
| R5 | 删除记录被远端旧数据复活 | 数据错乱 | 删除标记 + 反向验证 #5 |
| R6 | 设备指纹/凭据进日志 | 隐私 | G9 脱敏门禁 |
| R7 | 导入覆盖用户当前配置 | 配置丢失 | 导入产生新记录；L3 断言不覆盖 |
| R8 | 与 Android 侧"导入即切换"语义混淆 | 用户困惑 | 文档显式区分：PC 不覆盖当前配置（`design/00` Q10） |

| # | 开放问题 | 结论 | 依据 |
| --- | --- | --- | --- |
| Q1 | PC 是否复制 Android 爬虫？ | **不复制** | `design/00` P1 |
| Q2 | 同步默认开还是关？ | **默认关闭** | `design/00` P3；§21 验收原文 |
| Q3 | 是否用 `force` 清表？ | **不用** | `design/00` P3 |
| Q4 | 能否直接拉取 Android 历史？ | **不能**；PC 必须实现服务端 | `design/00` P5；§4 第 8 条 |
| Q5 | 是否依赖 `POST /api/playback/progress`？ | **不作为主路径** | §4 第 9 条 |
| Q6 | 真机验证是否做门禁？ | **不**，可选留痕 | `design/03` §1.1 |
| Q7 | 是否支持多设备？ | **支持**，按 `uuid` 区分 | `design/01` §9 Q1 |
| Q8 | `doh` 是否启用？ | **只保存不启用** | `design/01` §9 Q3 |
| Q9 | 删除是否传播到 Android？ | **本阶段不传播**，只保证不复活 | `design/02` §4.5 |
| Q10 | 是否做定时自动同步？ | **不做**，只手动触发 | `design/02` §8 Q1 |

---

## 6. 实测结论（2026-10-08）

| 项 | 事实 |
| --- | --- |
| 一键验收 | `PHASE5-ACCEPT result=PASS gates=all`（11 项全绿，含 `-BuildReleaseForSymbols`） |
| L1/L2 | `flutter test` 1338 例全绿；`dart analyze` 无问题 |
| L3 | 桥接 8 步 / 同步 8 步 / 推送 6 步全部通过，均带 `PHASE5-EVIDENCE` 事实行 |
| 反向验证 | 6 项全部"按预期失败"，还原后 `working-tree-clean=true` |
| 发布包符号 | `ANDROID-SYMBOLS result=PASS ascii=12 utf16=9 leaked=0` |
| 脱敏 | `sources=6 assertions=3 evidence=4`，无指纹/凭据原文 |
| 站点保真 | 170 站点、170 个唯一 key；**161 个唯一名字（重名合法：比的是多重集）** |
| 站点地址派生 | 改 `Host` 头后站点 `api` 主机随之变化（P2 的现场证据） |
| 证据文件 | `docs/phase5/evidence/**` 共 6 份（4 文本 + 2 截图） |

### 6.1 门禁抓到的真实问题（本阶段记录）

1. **证据生成器泄漏指纹占位值**：`device-probe.txt` 曾原样写出 fixture 的 uuid
   占位值。证据文件要交给用户看，而读者无法分辨 uuid 真假——G9 抓出后改为只写
   "字段完整性"。
2. **脱敏门禁的失败信息造成自指循环**：失败信息回显敏感字面量，字面量被写进
   验收日志，下一次扫描又抓到它（日志因此反复失败，而真正的泄漏早已修掉）。
   现在失败信息只报文件名与类别，不回显值。
3. **发布包符号门禁的产品发现**：设计文档 §3.2 初稿把 `mode` 语义写反
   （0/2 对调），按上游 `Action.onSync` 源码更正；`type=history` 的 `config.url`
   隐形前提也是实现期才暴露（见 `design/02` §3.2/§3.5 的勘误块）。

### 6.2 已知工具限制（非产品缺陷）

一次 `flutter test` 传多个集成套件时，Windows 桌面设备只能承载一个应用实例，
第二个套件会报 `Unable to start the app on the device`。验收脚本因此逐套件单独运行
（与 Phase 1–4 一致）。

---

## 7. 多源化改造（2026-10-26，后续）

设计：`design/04-bridge-multisource.md`。用户诉求原话：
「桥接后应该是把安卓版的所有源都拉取过来并支持切换，然后历史记录默认按源来隔离默认只显示当前源的
并参考安卓源新增开关可以开启全局历史记录，历史记录推送时也是推送到对应播放源的下面
现在反而是给安卓版新增了一个桥接源这是不对的」。

### 7.1 改了什么

| 项 | 之前 | 之后 |
| --- | --- | --- |
| 取站点 | 只取安卓**当前激活源** | `GET /manage/configs` 列出全部源，逐源 `ac=config&configKey=<k>` 取站点（`04` §2.2） |
| 切换 | 无 | 「启用」只切 **PC 本地**记录；**从不**调用安卓切源端点 |
| 历史 | 一份全局列表 | 默认按源隔离（`source`），新增 `history-scope-switch` 可切 `global`（`04` §4.4） |
| 推送 | `config.url` = 设备网关地址 → 安卓 `Config.create().insert()` | 载荷带 `configKey`，安卓按 cid 直写（`History.syncTo`），**不切源、不新增行**（`04` §3.4/§4.5） |
| 存储 | `schemaVersion 6` | `7`：`configs` 加 `source_key`/`bridge_*`；`history` 与 `history_deletions` 带 `source_key` 重建（`04` §4.2） |

### 7.2 跨仓库交付

| 仓库 | 提交 | 内容 |
| --- | --- | --- |
| 安卓 `webhtv/dev5` | `d4b965db96` | `VodSiteCatalog` 无副作用解析 + `ac=config&configKey=` + `handle`/`externalize`/`remoteUrl`/`/proxy` 透传（4 文件 +365/−21，`VodApiTest` 34 例全绿） |
| 安卓 `webhtv/dev5` | `b501538b77` | `History.syncTo(cid,…)` + `Action.syncHistory` 按 `configKey` 写入且不 `load`（4 文件 +146/−11，`HistoryScopeSyncTest` 5 例全绿） |

### 7.3 与原有边界的相容性

| 原则 | 多源化后如何保持 |
| --- | --- |
| P1 桥接不复制 | 站点仍由安卓执行，PC 只做 HTTP 客户端；`configKey` 只是坐标，不搬运爬虫 |
| P2 地址来自请求 | `configKey` 响应的站点 `api` 同样按 `Host` 现算（G1 预检第 9 条断言） |
| P3 默认关闭、失败不破坏本地 | 导入只新增记录（`makeActive:false`）；单源失败不中断且原样披露分类 |
| P4 不引入自引用 | 不变 |
| P5 能力缺口必须披露 | 老安卓缺 `/manage/configs` 时明确降级说明；全部源以**同一分类**失败时冒泡原始分类而非折叠成 `bridgeUnreachable` |
| Q10 导入不覆盖当前配置 | 不变；多源导入后也不切换 |

### 7.4 已知限制

| 限制 | 处置 |
| --- | --- |
| `JsLoader`/`PyLoader` 缓存键只有 `key`（不含 jar 哈希），两源同名 `siteKey` 但不同 jar 会串 | 记为已知限制；CSP 走 `JarLoader`（键含 `md5(jar)`）故主流程安全（`04` §3.5） |
| 存量伪造的「桥接源」记录 | **不自动删除**（可能是用户手建），由用户在配置页自行清理 |
| 历史范围开关 | PC 本地偏好，**不写回**安卓 `global_history_mode`（`04` §4.4） |

### 7.5 验证

| 项 | 结果 |
| --- | --- |
| fixture 预检 G1 | `PHASE5-ACCEPT android-fixture routes=11 modes=8 failures=0`（`/manage/configs`、两个 `configKey` 源、未知 key 原样回 `msg`、直播配置文档） |
| 新增 L1/L2 套件 | `source_key_and_history_scope`(16) + `phase5_bridge_multisource`(12) + `phase6_history_scope_ui`(4) + `phase5_bridge_picker_ui`(3) 全绿 |
| PC 全量单测 | 147 个测试文件分批全绿（2867 例）；`dart analyze lib test integration_test` 干净 |
| 安卓定向单测 | `VodApiTest` 34 例、`HistoryScopeSyncTest` 5 例全绿（全仓 4597 例中 8 个既有失败与本次改动无命中） |
| 反向验证 #7 | 放行网关地址拦截后 `phase5_sync_client_test.dart` 必须失败（防回归靶子） |
---

## 8. 历史同名聚合与跨源续播（2026-10-27，后续）

设计：`design/05-history-aggregation-and-cross-source-resume.md`。用户诉求原话（m00132）：
「默认只显示当前线路的历史记录，支持用户手动切换显示全部。显示全部的时候参考安卓版的相关实现，
比如：标注当前线路和非当前线路，点击播放的时候按设置采用自动匹配还是全局搜索等方式
并确保进度能完美同步过去」；追加（m00325）：
「历史记录需要支持同名聚合，优先 tmdb，没有配置等情况再基于名称等信息，具体可以参考安卓版，
最好是默认这种模式同时保留现在没集独立的历史记录格式允许用户手动切换」。

`04` 解决了"串源"，但也暴露出三处新裂口：同一部剧散成多张卡、看不出哪条属于别的源、
点别的源的卡片只能弹「该记录所属站点已不在当前配置中」。

### 8.1 改了什么

| 项 | 之前 | 之后 |
| --- | --- | --- |
| 历史列表 | 一集一张卡 | 三档聚合（默认 `tmdb` / `none` 逐集 / `title` 按片名），工具栏开关 `history-aggregation-switch`（`05` §3） |
| 作品身份 | 历史行只有片名 | 加 `vod_year`/`tmdb_id`/`media_type`，纯加法迁移；**旧行不回填**（`05` §4） |
| 存储 | `schemaVersion 7` | `8`；`upsertHistory` 用条件覆盖，空值不抹掉已绑定身份 |
| 来源标注 | 无 | 组内含其他源时显示来源 chip；多源显示「{n} 个其他来源」；老记录「来源未知」（`05` §6）——按源视图严格过滤后，空来源行**只在「全部来源」里出现**，空态也随之分流成「当前来源暂无记录 + 查看全部来源」（`05` §6.1） |
| 跨源播放 | 直接 SnackBar 结束 | 两条路径：原站点仍在 → 直接进详情页；否则在**当前源内**搜索匹配，无高置信候选则交给用户（`05` §7） |
| 续播进度 | 跨源一律从头 | `ResumeSeed` 随历史卡带入详情页，`resolveResumeStart` 判定同一集后按 `ResumePositionPolicy.migrate` 换算；`PlayerPage._load` 再用目标集真实时长重算一次并摘掉种子（`05` §7.2/§7.3） |
| 跨源候选 | 列表阶段一律当作「有目标集」 | **两阶段**：详情探测后回填 `hasTargetEpisode`/`episodeCount`，预算 12、失败保持 false（`05` §7） |
| 全局搜索兜底 | 只带片名，选完片从头播 | `SearchPage(resumeSeed:)` → `_openResult` 透传给 `DetailPage`，进度仍按同一集迁移（`05` §7） |

### 8.2 三条硬边界

| 边界 | 理由 |
| --- | --- |
| 聚合是**读视图**，写入仍一集一条 | `04` 的 `UNIQUE(source_key, site_key, vod_id, flag, episode_id)` 与安卓推送的合并语义都建立在「一条=一集」上；改写入模型等于重做同步协议（`05` §2） |
| **不切源** | 切配置会把整个 App 弹到另一个源；用户选型 ③ 明确要求只在当前源内找替代站点（`05` §7） |
| 宁可少续播，不可错续播 | 只认「TMDB 一致」或「片名+年份全等」两级；片名包含关系、年份缺失都不升格（`05` §7.1） |

### 8.3 已知限制

| 限制 | 处置 |
| --- | --- |
| 详情探测预算封顶 12 条 | 目标集只在更靠后的候选上时退化为让用户手选；PC 侧暂无 `SiteHealthStore` 可参与排序（`05` §10） |
| 搜索关键词只用原生片名 | 跨源 TMDB 绑定属另一 `config_id`，取它会串缓存（`_searchKeywordOf` 注释） |
| 已删除配置只能给短标识 | 显示为 `bridge:ac2d474b` 而非名字；保留配置墓碑可解 |

### 8.4 验证

| 项 | 结果 |
| --- | --- |
| 新增套件 | `phase5_history_grouping_test`、`phase5_resume_migration_test`、`phase5_history_aggregation_ui_test`、`phase5_history_cross_source_test`、`phase6_resume_playback_test`（含比例换算与接线锁）、`phase6_detail_resume_test` 追加组全绿 |
| PC 全量单测 | 151 个测试文件分 3 批 × `-j 4` 全绿（1217 + 1047 + 684 例） |
| 静态分析 | `flutter analyze lib test integration_test` → `No issues found!` |
| 反向验证靶子 | 去掉「≥2 个不同年份才拆」/「`!sameEpisode` → null」/「`fallback` 优先」/「`upsert` 条件覆盖」/「候选回填 `hasTargetEpisode`」/「兜底传 `resumeSeed`」/「播放器用真实时长重算」任一项，对应用例必须失败（`05` §9.3） |

---

## 9. 详情身份兜底（2026-10-28，缺陷修复）

设计：`design/06-detail-identity-fallback.md`。触发是用户真机日志：
「嗷呜」配置下 `Hxq`（上游 `type=3` 网盘聚合 spider `csp_HxqAmns`）的详情页空白，
日志 `siteParse: 列表条目缺少 vod_id/vod_name`，而同站点首页与搜索都正常。

### 9.1 根因（实测闭合）

| 环节 | 事实 |
| --- | --- |
| 现场抓包 | `GET /vod/api?ac=detail&ids=Bkp_OaNRYo16PHUsPQWv5&key=Hxq&configKey=425e3994…` → HTTP 200，`list[0]` 的 `vod_id`/`vod_name` 是**空串**，而 `vod_remarks`/`vod_actor`/`vod_content`/`vod_play_from`/`vod_play_url` 齐全 |
| 上游定义 | 配置源里 `{"key":"Hxq","type":3,"api":"csp_HxqAmns"}`，spider 返回的 `Vod` 没写 id/name；网关 `vodJson()` 用 `prop(item,"vod_id", vod.getId())` 把 `null` 写成空串 |
| PC 侧 | `Vod.fromJson` 要求 id 与 name 都非空，否则返回 `null`；`_parseVodList` 因此抛 `siteParse` |

信息并不缺——`ids=` 就是请求方给出的身份，只是没被用上。

### 9.2 改了什么

| 项 | 之前 | 之后 |
| --- | --- | --- |
| 解析入口 | `parse(body, {siteKey})` | 多一个可选 `VodIdentityHint? identity`（`06` §4.1） |
| 回填条件 | — | **详情 + 恰好一条**：`identity != null && !identity.isEmpty && items.length == 1`（`06` §4.2） |
| 穿透链 | — | `SiteService.detail` → `SiteRuntime` 4 个实现 → `HttpApiClient.execute` / `CatHttpClient.call` → `_parseJsonObject`/`_parseXml` → `_parseVodList`（`06` §4.3） |
| 调用点 | — | `AppState.loadDetail`、`AppState._resolveFollowingLines`、`library_pages`（历史补海报）、`history_cross_source`（候选探测）；`folderDetail` 不传 |

### 9.3 三条硬边界

| 边界 | 理由 |
| --- | --- |
| 列表/分类/搜索**绝不**回填 | 那是推断不是已知；多条写成同一 `vod_id` 会让整页崩掉（`06` §4.2） |
| 已填值永不覆盖 | 站点自己给的 id 才是权威 |
| 不改安卓 `formatContent` | 安卓是运行容器，改它还得再走一次发版；信息本来就在请求里（`06` §3） |

### 9.4 已知限制

| 限制 | 处置 |
| --- | --- |
| 只补 id/name，不补 `vod_pic` | 这类站点详情页仍无海报；补图需先确认「用搜索结果的图」不会错配 |
| 兜底依赖调用方传对 `vodName` | id 一定对、能播；名字传错只会显示错名 |
| 可选参数漏传在编译期无声 | 必须靠「调用点 grep + 端到端回归锁」两道锁（`06` §6.3 第 4 条靶子） |

### 9.5 验证

| 项 | 结果 |
| --- | --- |
| 新增用例 | `core_protocol_test` 新 group 7 例（含 XML 与 `{code:0,data:{list}}` 信封）、`config_and_site_test` Hxq 回归锁 1 例、fixture 新增 `ids=blank-1` 路由 |
| PC 全量单测 | 151 个测试文件分 3 批 × `-j 4` 全绿（1218 + 1054 + 684 例） |
| 静态分析 | `flutter analyze lib test integration_test` → `No issues found!` |
| 反向验证靶子 | 去掉 `withVodIdentity` → `+74 -3`；去掉「恰好一条」守卫 → `+76 -1`；`HttpApiRuntime.detail` 不传 identity → `config_and_site_test` `+40 -1` |


