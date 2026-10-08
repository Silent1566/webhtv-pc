# Phase 5 计划（安卓桥接：T4 站点接入 + 历史/设置同步）

- 状态：**已完成**（设计 `design/00`–`design/03` + 实现 T1–T14 全部落地；`PHASE5-ACCEPT result=PASS gates=all`）
- 日期：2026-10-08
- 对应设计文档章节：本目录 `design/00`–`design/03`、`docs/webhtv-pc-design.md` §21（Phase 5 生态与同步）、§22.1
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
| D4 | 测试与验收 | `design/03-bridge-test-and-acceptance.md` | L1/L2/L3 分层、fixture 与 8 种故障注入、4 个套件、11 项门禁、6 项反向验证 |
| D5 | 主设计文档回填 | `docs/webhtv-pc-design.md` §21 + §22.1 + §23 + §26 + §28 | 章节号连续、交叉引用可解析 |

### 2.2 实施阶段

| # | 任务 | 产出 | 验收 | 状态 |
| --- | --- | --- | --- | --- |
| T1 | 纯逻辑：桥接转换 | `lib/core/android_bridge.dart` | `phase5_android_bridge_test.dart`（29 例） | ✅ |
| T2 | 纯逻辑：同步编解码与合并 | `lib/core/android_sync.dart` | `phase5_android_sync_test.dart`（43 例） | ✅ |
| T3 | 服务：设备探测与配置拉取 | `lib/services/android_bridge_service.dart` | `phase5_android_bridge_service_test.dart`（17 例） | ✅ |
| T4 | 服务：PC 同步服务端 | `lib/services/sync_server.dart` | `phase5_sync_server_test.dart`（30 例，真实回环 HTTP） | ✅ |
| T5 | 服务：同步客户端 | `lib/services/sync_client.dart` | `phase5_sync_client_test.dart`（18 例，请求捕获） | ✅ |
| T6 | 存储：合并路径与删除标记 | `lib/services/storage.dart` | `phase5_sync_storage_test.dart`（15 例）+ `schemaVersion` 2→3 迁移 | ✅ |
| T7 | 状态层 | `lib/state/app_state.dart`、`lib/state/sync_state.dart` | `SyncStateHost` 契约 + 设置持久化 + 三项开关默认关闭 | ✅ |
| T8 | 设置页 UI | `lib/ui/config_pages.dart` | `phase5_sync_ui_test.dart`（14 例）+ G10 入口符号 | ✅ |
| T9 | fixture 与预检 | `packages/test-fixtures/android/**`、`tools/fixture_server/server.py`、`tools/phase5/check_android_fixture.py` | 路由 8 项 + 8 种故障注入逐一可触发 | ✅ |
| T10 | 反向验证 | `tools/phase5/verify_reverse_checks.py` | 6 项全部"按预期失败" | ✅ |
| T11 | 发布包符号门禁 | `tools/phase5/verify_release_symbols.py` | 12 个 ASCII 符号 + 9 个中文串存在 | ✅ |
| T12 | 一键验收脚本 | `tools/phase5/run_windows_acceptance.ps1` | 11 项门禁全绿 | ✅ |
| T13 | L3 集成 | `integration_test/phase5_bridge_flow_test.dart`、`phase5_sync_flow_test.dart`、`phase5_sync_push_flow_test.dart` | 真实窗口 + 真实 HTTP + 真实 SQLite | ✅ |
| T14 | 证据落盘 | `docs/phase5/evidence/**` | 6 份证据（含 2 张截图） | ✅ |

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
```

---

## 3. 门禁表

| # | 门禁 | 命令 | 通过判据 |
| --- | --- | --- | --- |
| G1 | 安卓 fixture 预检 | `py -3 tools/phase5/check_android_fixture.py --base <url>` | 路由 8 项 + 故障注入 8 项全通过 |
| G2 | Python 契约 | `py -3 -m unittest tests.test_contracts` | 8 个新增用例通过 |
| G3 | Schema 校验 | `py -3 scripts/validate_contracts.py` | 无错误 |
| G4 | 静态检查 | `dart analyze` | 无问题 |
| G5 | 单元测试 | `flutter test` | 全绿（含 7 个 `phase5_*` 套件，共 1338 例） |
| G6 | 套件存在性 | 脚本内清单核对 | 7 个套件文件均存在 |
| G7 | Windows 集成 | `flutter test integration_test/phase5_*_flow_test.dart -d windows` | 3 个套件全绿 |
| G8 | 反向验证 | `py -3 tools/phase5/verify_reverse_checks.py` | 6 项全部"按预期失败"且还原后工作区干净 |
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
| L2 | `test/phase5_android_bridge_service_test.dart` | 17 |
| L2 | `test/phase5_sync_storage_test.dart` | 15 |
| L2 | `test/phase5_sync_server_test.dart` | 30 |
| L2 | `test/phase5_sync_client_test.dart` | 18 |
| L2 | `test/phase5_sync_ui_test.dart` | 14 |
| L3 | `integration_test/phase5_bridge_flow_test.dart` | 4 个用例 / 8 步 |
| L3 | `integration_test/phase5_sync_flow_test.dart` | 1 个用例 / 8 步 |
| L3 | `integration_test/phase5_sync_push_flow_test.dart` | 1 个用例 / 6 步 |

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
