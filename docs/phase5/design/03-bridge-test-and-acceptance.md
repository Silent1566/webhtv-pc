# 03 · 桥接测试与验收设计

- 状态：设计指导，**实施中**
- 日期：2026-10-08
- 上游参考：Phase 1–4 的门禁与证据机制（`docs/phase1/README.md` §7、`docs/phase2/README.md` §3、`docs/phase3/README.md` §3、`docs/phase4/design/05`）
- PC 端落点：`apps/desktop-flutter/test/phase5_*.dart`、`apps/desktop-flutter/integration_test/phase5_*_flow_test.dart`、`packages/test-fixtures/android/**`、`tools/phase5/**`
- 关联：`00`、`01`、`02`

---

## 1. 测试分层

沿用 Phase 3/4 的三层结构，不引入新机制：

| 层 | 位置 | 真实网络 | 真实窗口 | 运行命令 |
| --- | --- | --- | --- | --- |
| L1 纯逻辑单测 | `test/phase5_*.dart` | ❌（全内存） | ❌ | `flutter test` |
| L2 契约与服务 | `test/phase5_*_test.dart`（进程内 fake HTTP）+ `tests/test_contracts.py` | ❌ | ❌ | `flutter test` + `py -3 -m unittest` |
| L3 集成 | `integration_test/phase5_*_flow_test.dart` | ✅（本地 fixture 服务） | ✅（`-d windows`） | `flutter test integration_test/... -d windows` |

**分层原则**（对齐 Phase 3/4）：

- L1 必须能在**无网络、无窗口**下全绿，覆盖全部算法与边界（含哨兵值、主机校验、合并裁决）；
- L2 用**请求捕获**断言请求形态（方法、路径、表单字段、`Host` 头），不只断言最终结果；
- L3 只验证「真实窗口 + 真实 HTTP + 真实 SQLite」的端到端串联，**不重复 L1/L2 的边界用例**。

### 1.1 Phase 5 特有的分层约束

| 约束 | 理由 |
| --- | --- |
| L1 **不得**依赖任何真实 Android 设备 | 门禁必须能在 CI/无设备环境全绿 |
| L2 **必须**有"假 Android 服务端"，能模拟 Host 头、403、404、空站点、超时 | `01` §6 的 6 类错误必须逐一被触发 |
| L2 **必须**有"假 Android 客户端"，能 POST 到 PC 服务端 | `02` §3.1 的 4 个端点必须逐一被验证 |
| L3 **不得**要求真机 | 用 fixture 服务充当 Android 对端 |
| 真机验证 | **作为手工验证记录**写入证据文件，**不作为门禁** |

> **为什么不把真机验证做成门禁**：CI 上没有 `192.168.50.3:5559`。
> 但真机验证的价值在于"证明 fixture 没编错"，因此**必须留痕**：
> 验收脚本提供一个 `-ProbeRealDevice <host:port>` 可选开关，把实测响应摘要写入证据。

---

## 2. fixture 设计

### 2.1 目录

```text
packages/test-fixtures/android/
  gateway-config.json          # 真实 ac=config 响应脱敏快照（Host 用占位符）
  gateway-config-empty.json    # sites: [] （触发 bridgeEmptySites）
  gateway-config-mismatch.json # 站点 api 指向第三方主机（触发 bridgeHostMismatch）
  gateway-config-loopback.json # 站点 api 全部是 127.0.0.1（触发 P2 重写路径）
  gateway-config-repo.json     # 带 urls 仓库（触发"网关不返回仓库"拒绝）
  device.json                  # 真实 /device 响应脱敏快照
  history-android.json         # 真实 History[] 形态（含哨兵 opening/ending）
  keep-android.json            # Keep[] 形态
  backup-android.json          # Backup 形态（含 prefers 白名单）
  sync-options.json            # SyncOptions 形态
  vod-home.json                # 站点首页响应
```

### 2.2 快照来源

`gateway-config.json` 与 `device.json` 取自 `00` §3 的**实测响应**，只做两处脱敏：

| 原值 | 替换为 | 理由 |
| --- | --- | --- |
| `192.168.50.50:9978` / `127.0.0.1:19978` | `__HOST__` 占位符 | 地址随环境变化；占位符让 fixture 能同时服务"主机一致"与"主机不一致"两个用例 |
| 设备 `uuid` / `serial` / `wlan` | 固定假值 | 设备指纹 |

站点 `key` / `name` / `type` / 标志位**原样保留**（170 个站点），
因为站点保真断言（`01` §5.4）需要真实的中文名与方括号。

### 2.3 fixture 服务新增路由

在 `tools/fixture_server/server.py` 增加 `/android/**` 命名空间（不改既有路由）：

| 路由 | 行为 | 用途 |
| --- | --- | --- |
| `GET /android/device` | 返回 `device.json` | 设备识别 |
| `GET /android/vod/api?ac=config` | 返回 `gateway-config.json`，其中 `__HOST__` **替换为请求的 `Host` 头** | **复现真实网关的 Host 派生行为**（`00` §3.2） |
| `GET /android/vod/api?ac=site` | 同 `ac=config` | 等价性断言 |
| `GET /android/vod/api?key=<key>` | 返回 `vod-home.json` | 站点可执行性 |
| `POST /android/action?do=sync&...` | 200 `OK`，并把收到的表单字段记入 stats | 断言 PC 推送的形态 |
| `GET /android/__stats` | 各路由命中次数 + 最近一次收到的表单字段 | 请求捕获 |
| `GET /android/__reset` | 清空 stats | 用例隔离 |
| `GET /android/__mode?config=<mode>` | 故障注入开关 | 见下表 |

故障注入模式（`__mode` 的 `config` 参数）：

| 值 | 行为 | 触发的 `AppErrorKind` |
| --- | --- | --- |
| `ok`（默认） | 正常 | — |
| `404` | `/vod/api*` 返回 404 | `bridgeNoGateway` |
| `empty` | 返回 `gateway-config-empty.json` | `bridgeEmptySites` |
| `mismatch` | 返回 `gateway-config-mismatch.json` | `bridgeHostMismatch` |
| `loopback` | 返回 `gateway-config-loopback.json` | 触发 P2 重写（成功 + 诊断） |
| `repo` | 返回 `gateway-config-repo.json` | `bridgeNoGateway`（网关不该返回配置仓库） |
| `notandroid` | `/android/device` 返回 `{"hello":"world"}` | `bridgeNotAndroid` |
| `slow` | 延迟 5 s | `bridgeUnreachable`（超时） |

> `__mode` 与 `__stats` 沿用 TMDB fixture 的 `__` 前缀约定（`docs/phase4/design/05` §2.2），
> 便于识别"这是测试开关，不是被测协议"。

### 2.4 fixture 不模拟什么

| 不模拟 | 理由 |
| --- | --- |
| Android 的爬虫执行 | PC 侧不关心（P1）；L3 只需证明"请求发到了正确的地址" |
| Android 的 `cid` 重映射 | 这是 Android 内部行为；PC 只断言自己发的是 `cid=0` |
| 删除墓碑 | 上游未实现（`02` §4.5） |

---

## 3. L1 纯逻辑单测清单

### 3.1 `test/phase5_android_bridge_test.dart`

> 实测用例数 **29**（本表列 23 项验收要点；实现期按边界补全）。


| # | 用例 | 断言 |
| --- | --- | --- |
| 1 | 网关地址规范化 | `192.168.1.5` → `http://192.168.1.5:9978` |
| 2 | 规范化去路径 | `http://h:9978/vod/api?x=1` → `http://h:9978` |
| 3 | 规范化去尾斜杠 | `http://h:9978/` → `http://h:9978` |
| 4 | 保留 `localhost` | `localhost:9978` → `http://localhost:9978`（不改写） |
| 5 | 拒绝非法 scheme | `ftp://h` → `bridgeUnreachable` |
| 6 | 设备 JSON 解析 | 7 个字段全部映射正确 |
| 7 | 设备相等性只比 uuid | 同 uuid 不同地址 → 相等 |
| 8 | 非法设备 JSON | `{"hello":"world"}` → `bridgeNotAndroid` |
| 9 | `type` 字符串 `"4"` → 整数 `4` | 单站点转换 |
| 10 | 170 站点保真 | 数量/key 集合/name 集合完全一致 |
| 11 | 站点标志位保真 | `searchable`/`quickSearch`/`filterable` 一致 |
| 12 | 站点 api 的 path+query 保真 | 只有 host 可被修正 |
| 13 | 主机一致 → 不改写、无诊断 | 无 `bridgeHostRewritten` |
| 14 | 响应回环 + 请求非回环 → 重写 + 诊断 | 地址被修正为请求主机，诊断计数 = 站点数 |
| 15 | 响应第三方主机 → `bridgeHostMismatch` | 抛出且不返回配置 |
| 16 | 空 sites → `bridgeEmptySites` | 抛出 |
| 17 | 带 `urls` 仓库 → 拒绝 | 抛出 `bridgeNoGateway`（该端点不是 T4 网关配置） |
| 18 | `msg` 键 → 保留 `configMsg` | 类别不被折叠 |
| 19 | 自引用：目标 = PC 自己 | `bridgeSelfReference` |
| 20 | 自引用：单个站点指向 PC 自己 | 该站点被跳过 + 诊断，其余保留 |
| 21 | 未知字段不丢失 | `Site.extra` 含未知键 |
| 22 | `lives` / `spider` 非空 → 诊断提示忽略 | 诊断存在且站点数不变 |
| 23 | 中文名 / 方括号 / emoji 保真 | 逐字节相等 |

### 3.2 `test/phase5_android_sync_test.dart`

> 实测用例数 **43**（本表列 22 项验收要点；实现期按边界补全）。


| # | 用例 | 断言 |
| --- | --- | --- |
| 1 | `key` 切分 | `a@@@b@@@7` → `siteKey=a, vodId=b, cid=7` |
| 2 | `key` 缺段 | `a@@@b` → `cid=0`；`a` → 非法记录被跳过 |
| 3 | `position`/`duration`/`createTime` 直传（**无换算**） | 输入 123456 → 输出 123456 |
| 4 | `opening`/`ending` 哨兵值 | `Long.MIN_VALUE` → `null`，不溢出 |
| 5 | `opening` 正常值 | 60000 → 保留 |
| 6 | `vodPic` 空串 → `null` | 映射正确 |
| 7 | `vodRemarks` 空串保留 | `episodeName == ""` |
| 8 | TMDB 字段进 raw | `tmdbId`/`mediaType`/`tmdbSeasonNumber` 保留在 raw |
| 9 | 反向映射 `cid=0` | `key` 以 `@@@0` 结尾 |
| 10 | 反向映射省略 `opening`/`ending` | JSON 中不存在这两个键 |
| 11 | 反向映射 `speed=1.0` | 固定值 |
| 12 | 合并：本地无 → insert | `applied` |
| 13 | 合并：远端新 → upsert | `applied` |
| 14 | 合并：时间戳相等 → skip | `skipped`（幂等） |
| 15 | 合并：远端旧 → skip | `skipped`（旧不覆盖新） |
| 16 | 删除标记：远端旧于删除时间 → skip | 不复活（`02` §4.5） |
| 17 | 删除标记：远端新于删除时间 → insert | 用户重新观看后应恢复 |
| 18 | 统计明细 | `applied+skipped+failed == total` |
| 19 | `SyncOptions` 默认子集 | `history=true, keep=true`，其余 `false` |
| 20 | `settings` 默认关闭 | `settings=false` |
| 21 | `Backup` 解析只取白名单键 | `tmdb_config` 不在结果中（除非显式开启） |
| 22 | 脱敏 | 片名不出现在 `describe()` 输出 |

### 3.3 `test/phase5_sync_server_test.dart`

> 实测用例数 **30**（本表列 17 项验收要点；实现期按边界补全）。


| # | 用例 | 断言 |
| --- | --- | --- |
| 1 | `GET /device` | 200 + 完整 Device JSON + `type=1` |
| 2 | 端口探测 | 9978 被占 → 落到 9979 |
| 3 | 关闭时端口释放 | `stop()` 后端口可再绑定 |
| 4 | `POST /action` 缺 `type` | 400 + message |
| 5 | 未知 `type` | 400 + message |
| 5b | `mode=2` 缺 `device` | 400 + 指明需提供 `device`（对齐上游 `Manage.syncStart`） |
| 5c | `mode=0` 与 `mode=1` 都落库 | 200 + 记录已写入（Android `Action.post` 用 `mode=0`） |
| 5d | `mode=2` + `device` | 200，调用对端推送回调，且**不**写入请求体载荷 |
| 5e | `mode=0` + `device` | 200，既落库又调用对端推送回调（双向） |
| 6 | `type=history` 缺 `config` | 400 + `config 不能为空` |
| 7 | `type=history` `config` 非法 JSON | 400 + message |
| 8 | `type=history` 缺 `targets` | 400 + `targets 必须是 JSON 数组` |
| 9 | `type=history` 空数组 | 200 `OK` + `total=0` |
| 10 | 正常历史推送 | 200 `OK` + 记录落库 + 统计正确 |
| 11 | 同步未开启 | 403 + `同步未开启` |
| 12 | 对端未授权 | 403 + `对端未授权` |
| 13 | 请求体超 8 MiB | 413 |
| 14 | `type=keep` | 收藏落库 |
| 15 | `type=backup` | 设置按白名单合并 |
| 16 | 部分失败 | 返回明细，不因单条失败回滚 |
| 17 | 并发两次相同推送 | 第二次全 `skipped`（幂等） |

### 3.4 `test/phase5_sync_client_test.dart`

> 实测用例数 **18**（本表列 9 项验收要点；实现期按边界补全）。


| # | 用例 | 断言 |
| --- | --- | --- |
| 1 | 推送到 `/action?do=sync&mode=1&type=history` | 方法/路径/query 正确（`mode=1` = 对方接收） |
| 2 | 表单字段 | `config` + `targets` 均存在且为合法 JSON |
| 3 | `cid=0` | 每条记录的 `key` 以 `@@@0` 结尾 |
| 4 | 不发送 `settings` | 默认请求体不含 `settings` |
| 5 | 403 → `syncLocalWriteRejected` | 类别正确 + 文案含 Android 侧开关指引 |
| 6 | 连接被拒 → `syncPeerUnreachable` | 类别正确 |
| 7 | 超时 → `syncPeerUnreachable` | 类别正确 |
| 8 | 5xx → 不静默 | 抛出并带状态码 |
| 9 | `Host` 头 | 请求目标是可达地址，`Host` 与之一致 |

---

## 4. L2 契约与 fixture 测试

### 4.1 `tests/test_contracts.py` 新增用例

| # | 用例 | 断言 |
| --- | --- | --- |
| 1 | `packages/test-fixtures/android/**` 全部可解析为 JSON | 无语法错误 |
| 2 | `gateway-config.json` 站点数 = 170 | 快照未被意外截断 |
| 3 | 所有站点 `type == "4"` | 契约不变 |
| 4 | 站点 `api` 全部含 `__HOST__` 占位符 | 脱敏完整，无真实地址残留 |
| 5 | 无真实设备指纹 | `uuid`/`serial`/`wlan` 为固定假值 |
| 6 | `device.json` 含全部 8 个字段 | 契约完整 |
| 7 | `history-android.json` 含哨兵值用例 | 覆盖 `Long.MIN_VALUE` |
| 8 | fixture 服务 `/android/**` 路由可达 | 与 TMDB fixture 预检同机制 |


> **实测**：下表 8 项在实现中落成 **12 个 `test_*` 方法**（含 `7b`/`7c`/`7d`
> 三个补充断言与一个未知字段保留用例）。全仓契约测试共 21 个用例全绿。

### 4.2 `tools/phase5/check_android_fixture.py`

对齐 `tools/phase4/check_tmdb_fixture.py`，验证：

1. `/android/device` 返回 200 且字段完整；
2. `/android/vod/api?ac=config` 的站点 `api` **主机等于请求的 `Host`**（证明 fixture 忠实复现真实网关）；
3. `/android/vod/api?ac=site` 与 `ac=config` 字节相同；
4. `__stats` / `__reset` 可用；
5. 8 种故障注入模式逐一返回预期形态；
6. `/android/action` 能接收表单并回 200 `OK`，字段被 stats 记录。

### 4.3 反向验证 `tools/phase5/verify_reverse_checks.py`

对齐 `tools/phase4/verify_reverse_checks.py`：逐项临时破坏契约、断言对应用例**必须失败**、
再无条件还原并校验工作区干净。

| # | 破坏方式 | 必须失败的用例 |
| --- | --- | --- |
| 1 | 主机一致性校验改为无条件放行 | `phase5_android_bridge_test.dart` 主机不一致用例 |
| 2 | `position` 映射加 `/1000` 换算 | `phase5_android_sync_test.dart` 单位用例 |
| 3 | 合并裁决改为"远端总是胜" | `phase5_android_sync_test.dart` 旧不覆盖新用例 |
| 4 | 哨兵值不做过滤 | `phase5_android_sync_test.dart` 溢出用例 |
| 5 | 删除标记检查被移除 | `phase5_android_sync_test.dart` 不复活用例 |
| 6 | `SyncOptions` 的 `settings` 默认改为 `true` | `phase5_android_sync_test.dart` 默认关闭用例 |

> 6 项是本套文档最重要的"门禁真的锁住了契约"的证据。
> 尤其 #2（毫秒换算）与 #5（复活）是本阶段最容易悄悄写错的两处。

---

## 5. L3 集成测试

### 5.1 `integration_test/phase5_bridge_flow_test.dart`

真实窗口 + 真实 HTTP（fixture 服务充当 Android）：

1. 打开设置页 → 安卓设备接入；
2. 手动输入 fixture 地址 → 设备信息正确显示（名称、类型、站点数）；
3. 点"导入站点" → 导入成功，站点数 = 170；
4. 断言新配置记录产生，**当前配置未被覆盖**（Q10）；
5. 切到桥接配置 → 首页请求打到 fixture 的 `/android/vod/api?key=...`；
6. 断言请求的 `Host` 与可达地址一致（P2）；
7. 故障注入 `empty` → 明确报错 `bridgeEmptySites`，不是"0 个站点"成功；
8. 故障注入 `mismatch` → 拒绝导入 + 错误分类正确。

### 5.2 `integration_test/phase5_sync_flow_test.dart`

1. 设置页开启同步 → PC 服务端启动，端口 = 9978（或下一个可用）；
2. 用真实 HTTP 客户端 `GET /device` → 返回 PC 的 Device JSON；
3. `POST /action?do=sync&mode=1&type=history` 推 3 条 → 200 `OK`；
4. 断言历史页出现这 3 条；
5. 再推**同样的 3 条** → 全 `skipped`，历史仍 3 条（幂等）；
6. 推 1 条**更旧**的记录 → `skipped`，本地进度不变（旧不覆盖新）；
7. 推 1 条更新的 → `applied`，本地进度前进；
8. 关闭同步 → 端口释放（再次绑定成功）。

### 5.3 `integration_test/phase5_sync_push_flow_test.dart`

PC 当客户端（fixture 充当 Android 的 `/action` 接收端）：

1. 本地造 3 条历史；
2. 点"推送到设备" → fixture 收到请求；
3. 断言 `mode=1`、`type=history`、表单含 `config` 与 `targets`；
4. 断言 `targets` 中每条 `key` 以 `@@@0` 结尾；
5. 断言请求体不含 `settings`（默认关闭）；
6. fixture 注入 403 → UI 报 `syncLocalWriteRejected` 且文案含 Android 侧开关指引。

---

## 6. 门禁表

| 门禁 | 命令 | 通过判据 |
| --- | --- | --- |
| G1 安卓 fixture 预检 | `py -3 tools/phase5/check_android_fixture.py --base <url>` | 路由 8 项 + 故障注入 8 项全通过 |
| G2 Python 契约 | `py -3 -m unittest tests.test_contracts` | 12 个新增安卓用例通过（全仓 21 个） |
| G3 Schema 校验 | `py -3 scripts/validate_contracts.py` | 无错误 |
| G4 静态检查 | `dart analyze` | 无问题 |
| G5 单元测试 | `flutter test` | 全绿（含 7 个 `phase5_*` 套件，共 1338 例） |
| G6 套件存在性 | 脚本内清单核对 | 8 个套件文件均存在 |
| G7 Windows 集成 | `flutter test integration_test/phase5_*_flow_test.dart -d windows` | 3 个套件全绿 |
| G8 反向验证 | `py -3 tools/phase5/verify_reverse_checks.py` | 6 项全部"按预期失败"且还原后工作区干净 |
| G9 脱敏 | `py -3 tools/phase4/verify_tmdb_redaction.py` + `py -3 tools/phase5/verify_bridge_redaction.py` | 无凭据/指纹原文（三层：源码日志实参 / 脱敏用例在位 / 证据文件） |
| G10 发布包符号 | `py -3 tools/phase5/verify_release_symbols.py` | 12 个 ASCII 符号 + 9 个中文串存在，无测试壳污染；产物早于源码时报 `stale` |
| G11 产物可运行 | 既有 `debug-artifact-runnable` | Debug 入口是 `lib/main.dart` |

一键验收：

```powershell
pwsh -File tools/phase5/run_windows_acceptance.ps1
pwsh -File tools/phase5/run_windows_acceptance.ps1 -SkipIntegrationTests
# 可选：把真机实测摘要写入证据（不作为门禁）
pwsh -File tools/phase5/run_windows_acceptance.ps1 -ProbeRealDevice 192.168.50.3:9978
```

结果写入 `docs/phase5/evidence/windows-acceptance.txt`。

### 6.1 发布包符号门禁（G10）

对齐 Phase 4 的 P4-7 教训（"UI 入口被条件渲染挡住 → 死代码被 release AOT 剔除"）：

| 必须存在的 ASCII 符号 | 必须存在的中文串 |
| --- | --- |
| `android-bridge` | 安卓设备接入 |
| `android-scan` | 扫描局域网 |
| `android-import` | 导入站点 |
| `android-device-` | 手动输入地址 |
| `android-sync-server` | 同步设置 |
| `android-sync-push` | 推送到设备 |
| `sync-peer-` | 已授权对端 |
| `bridge-host-` | 站点地址已修正 |
| `settings-android-open` | 打开安卓接入 |

**默认只校验已存在的 release 产物**（尊重本仓库"不打正式包"约定），
`-BuildReleaseForSymbols` 才主动构建。

---

## 7. 证据落盘

| 证据 | 位置 | 内容 |
| --- | --- | --- |
| 验收日志 | `docs/phase5/evidence/windows-acceptance.txt` | 全部门禁的可复查事实行 |
| 设备探测快照 | `docs/phase5/evidence/device-probe.txt` | fixture 与（可选）真机的 `/device` 响应摘要 |
| 站点保真报告 | `docs/phase5/evidence/site-fidelity.txt` | 170 站点的数量/key/name 比对结果 |
| 同步合并矩阵 | `docs/phase5/evidence/sync-merge-matrix.txt` | 5 种合并裁决的输入输出 |
| 桥接截图 | `docs/phase5/evidence/android-bridge.png` | 设置页设备卡片与导入结果 |
| 同步截图 | `docs/phase5/evidence/android-sync.png` | 同步开关与统计明细 |

截图由 L3 集成用例落盘（对齐 `tmdb_detail_visual_flow_test` 的做法）。

### 7.1 真机验证留痕（可选，非门禁）

`-ProbeRealDevice` 打开时，脚本对真机执行只读探测并写入证据：

| 探测 | 记录 |
| --- | --- |
| `GET /device` | 字段完整性、`type` 取值（不记录 `uuid`/`serial`/`wlan` 原文） |
| `GET /vod/api?ac=config` | 站点数、`type` 直方图、`ac=site` 等价性 |
| `GET /vod/api?ac=config` 带自定义 `Host` | 站点 `api` 主机是否随之变化（**P2 的现场证据**） |

---

## 8. 风险与开放问题

| # | 风险 | 影响 | 缓解 |
| --- | --- | --- | --- |
| R1 | 真机与 fixture 行为漂移 | 上线后导入失败 | 快照取自实测；`-ProbeRealDevice` 可随时复核 |
| R2 | Android 后续版本改变 T4 契约 | 桥接失效 | 契约快照入 fixture；版本过旧/过新都给出分类错误 |
| R3 | 站点数过多（170+）导致导入慢 | 体验下降 | 导入是纯内存转换，实测 31 KB / 170 站点，无需优化 |
| R4 | LAN 监听被滥用 | 安全 | 默认关闭 + 对端 uuid 白名单 + 8 MiB 上限（`02` §5） |
| R5 | `position` 单位被误改成秒 | 进度错乱 | 反向验证 #2 必须存在并通过 |
| R6 | 删除记录被远端旧数据复活 | 用户数据错乱 | 删除标记 + 反向验证 #5 |
| R7 | 设备指纹进日志 | 隐私 | G9 脱敏门禁 |
| R8 | 导入覆盖用户当前配置 | 用户配置丢失 | L3 步骤 4 断言不覆盖（Q10） |

| # | 开放问题 | 结论 | 依据 |
| --- | --- | --- | --- |
| Q1 | 是否把真机验证做成门禁？ | **不**，作为可选留痕 | §1.1 |
| Q2 | fixture 是否复现 Host 派生？ | **必须** | P2 的可测性依赖它 |
| Q3 | 是否测试 Android 侧的真实爬虫执行？ | **不测** | P1；PC 不关心 |
| Q4 | 是否要求 100% 行覆盖？ | **不要求**，要求 6 类错误与 5 种合并裁决全覆盖 | §3 |
| Q5 | 反向验证项是否可增补？ | 可，但 6 项基线不得删除 | §4.3 |
