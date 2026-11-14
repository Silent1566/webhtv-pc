# 04 · Phase 9 验收规范（门禁 / 分层 / 证据）

- 上游：`docs/phase9/README.md`、`design/00`–`03`
- 适用：W1（P0）先落地；W2–W4 复用同一规范，只替换套件与 fixture

---

## 0. 原则

1. **证据优先于声明**：没有跑过的命令不写「通过」；截图必须能逐字节复现。
2. **失败集合必须是已知集合**：全量测试允许存在既有 flaky，但失败项必须 ⊆ 已登记集合，且逐条单独复跑核实。
3. **破坏即红**：每个新能力至少一条反向验证（改坏关键实现必须让指定套件失败），还原后工作区干净。
4. **门禁可一键复现**：不接受「在我机器上跑过」。

---

## 1. 测试分层

| 层 | 形态 | 位置 | 用途 |
| --- | --- | --- | --- |
| L1 | 纯 Dart 单测（无窗口、无网络） | `apps/desktop-flutter/test/phase9_*_test.dart` | 纯逻辑：模板、裁决、归一化、排序、评分 |
| L2 | Widget 测试（假服务注入） | 同上 | 菜单渲染、开关持久化、空态/错误态、脱敏 |
| L3 | 集成测试（真实窗口 + 真实 HTTP + 真实 SQLite） | `apps/desktop-flutter/integration_test/phase9_*_flow_test.dart` | 真实播放、真实代理、真实往返 |

L1/L2 必须能在无显示器环境跑；L3 用 `flutter test <suite> -d windows` 单套件运行（Phase 8 的既有实践：并行会争用端口与媒体管线，必须逐套件）。

---

## 2. 工具链

```powershell
# 必须在 apps/desktop-flutter 内执行：puro 的 -p/--dir 不改 flutter 的工作目录，
# 只有 cd 会。在仓库根跑会报 `Expected to find project root in current working directory.`
cd apps/desktop-flutter

# 静态检查
puro -e webhtv dart analyze

# 单元 + Widget
puro -e webhtv flutter test

# 单个集成套件（Windows 真实窗口）
puro -e webhtv flutter test integration_test/phase9_<name>_flow_test.dart -d windows
```

- `TEMP`/`TMP` 指向仓库内临时目录（media-kit 的 NativeReferenceHolder 会占用 `%TEMP%`，Phase 8 已踩坑）。
- 所有命令输出落 `docs/phase9/evidence/`，不只看终端。

---

## 3. 每波次门禁

| 门禁 | 检查 | 通过条件 |
| --- | --- | --- |
| G-W1 | `dart analyze` | `No issues found`（新增文件单独再跑一次） |
| G-W2 | 单元 + Widget 全量 | 失败项 ⊆ 已知 flaky 集合，且逐条复跑全绿 |
| G-W3 | 套件存在性 | 每个 P0 项至少 1 个 L1/L2 套件 + 1 条 L3 路径 |
| G-W4 | L3 集成 | 逐套件通过；真实窗口截图入证据 |
| G-W5 | 反向验证 | ≥3 项，全部「破坏即红、还原即绿」 |
| G-W6 | 契约/数据迁移 | DB 从上一版本升级不丢数据；settings 缺省等价现状 |
| G-W7 | 脱敏 | token/凭据不入日志、证据、同步设置 |
| G-W8 | 文档一致性 | `tools/phase9/verify_gap_matrix.py` 退出码 0；设计文档与实现不漂移 |
| G-W9 | 性能/资源 | 弹幕上限、预加载上限、代理并发有硬上限并可观测 |

W2–W4 增加：

- G-W10 fixture 覆盖（每个新协议至少一个可复现 fixture）；
- G-W11 真实样本记录（脱敏：站点标识、验证时间、网络地区、结果四要素）；
- G-W12 能力披露（不迁移/降级项在 UI 与文档中一致）。

---

## 4. 反向验证清单（W1 最低集）

| # | 破坏 | 必须失败的套件 |
| --- | --- | --- |
| 1 | 去掉「片头只跳一次」守卫 | `phase9_player_core_test`（P0-2 组） |
| 2 | `autoNext` 默认改为 false | `phase9_player_core_test`（P0-4 组）+ `phase9_preferences_test` |
| 3 | 记忆键漏掉 `episodeName` | `phase9_storage_test`（字幕/弹幕记忆组） |
| 4 | catchup `append` 不把 `?` 换成 `&` | `phase9_live_catchup_test` |
| 5 | 轨道选择用列表下标而不是 track id | `phase9_player_core_test`（P0-1 组） |

每项流程：改坏 → 跑指定套件（必须失败）→ 用内存原文还原 → 断言工作区干净。实现参考 `tools/phase8/verify_reverse_checks.py`。

---

## 5. 证据规范

目录：`docs/phase9/evidence/`

| 证据 | 形式 | 要求 |
| --- | --- | --- |
| 验收日志 | `windows-acceptance.txt` | 每步命令、退出码、门禁结论；末尾 `PHASE9-ACCEPT result=PASS gates=all` |
| 功能说明 | `01-*.md` … | 每项：做了什么、怎么验、失败边界 |
| 截图 | `screenshots/*.png` | 真实窗口；同一场景重复跑像素一致；不得手工修饰 |
| 真实样本 | `samples.md` | 脱敏四要素；禁止提交含凭据的完整配置 |
| 测试原始输出 | `test-run.txt` / `analyze.txt` | 原样保存，不删失败行 |

截图 harness 沿用 Phase 8：`RepaintBoundary → toImage → PNG`，固定窗口尺寸与主题。

---

## 6. fixture 扩展

在 `tools/fixture_server/server.py` 与 `apps/desktop-flutter/test/support/` 增加：

| fixture | 用途 |
| --- | --- |
| 双音轨 MKV（ffmpeg 生成，脚本化） | P0-1 |
| 带片头片尾标记的历史记录（SQLite 直写） | P0-2 |
| 多音轨/多字幕/多视频轨的 HLS 或 MKV | P0-1 / P0-6 |
| 字幕 provider：2 条候选 + 401 + 超时 | P0-6 |
| 弹幕库：2 条候选 + 空结果 + 非法文件 | P0-7 |
| M3U：带 `catchup`/`catchup-source`/`catchup-replace`，两源同名频道 | P0-8 |
| HLS：主内容 + 广告分片（W2） | P1-1 |
| 代理：记录请求头/目标（W2） | P1-9 |

fixture 必须可重复启动、端口可配、失败注入可开关；不得依赖外网。

---

## 7. 文档门禁（G9.1–G9.5）

由 `tools/phase9/verify_gap_matrix.py` 执行，详见 `README.md` §8。该脚本同时用于 W2–W4 的矩阵维护：新增缺口必须带 6 列与可追溯引用，否则门禁红。

---

## 8. 退出标准（Definition of Done）

一个 P0 项完成，必须同时满足：

1. 代码落地（含失败路径与日志分类）；
2. L1 + L2 套件通过，L3 至少一条路径通过；
3. 至少一条反向验证；
4. 证据文档与截图入 `docs/phase9/evidence/`；
5. `README.md` 矩阵中该项的「PC 现状」改为已实现，并在 `design/05` 映射表标注；
6. 对外披露（若有降级）与实际一致。

W1 整体完成：G-W1…G-W9 全绿，`PHASE9-ACCEPT result=PASS gates=all`，且 `PRODUCT.md` 的能力表述同步更新。
