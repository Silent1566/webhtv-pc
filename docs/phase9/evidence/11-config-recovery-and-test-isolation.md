# 11 · 配置恢复失败与测试目录隔离加固

- 日期：2026-11-14
- 触发：启动日志 `刷新配置失败：configNotFound: 配置文件不存在 | detail=…/tmp/webhtv-local-sourcePHGVUN/config.json`
- 相关规格：`docs/phase9/design/11-config-recovery-hardening.md`

## 1. 现场

启动行 `恢复配置：AT-不夜-T4-内网 … origin=…/linux-platform-verification/tmp/webhtv-local-sourcePHGVUN/config.json` 说明当前配置指向一个**临时验证目录里的文件**，而该文件已随验证收尾被删除。

事实核对（只读）：

- 该路径确实不存在（`stat` → No such file or directory）；启动能从数据库缓存 JSON 恢复，所以站点仍能加载，只有「刷新」需要重读来源才失败；
- 正式库 `configs` 表 17 条记录**全部写于 11-14 15:00–15:01**，其中「其它配置/坏源/好源/要刷新/别动我/示例配置」等是测试夹具命名；
- id=1 `http://192.168.50.50:4567/t4/2024/buye-0` 与 id=17 存着**同一个可用站点** `csp_labi`；实测该接口 `HTTP 200 / 0.03s`。

结论：配置协议与读取逻辑没有坏，是**一次验证运行把测试夹具写进了正式用户目录**，并把其中一条临时文件配置设为当前配置。

## 2. 数据修复（人工授权、可回滚）

- 备份：`~/.local/share/webhtv-pc/backup-before-config-repair-20261114-162654/`（内含修复前 `active=17`、`history=24` 的副本，`quick_check=ok`）；
- 修复：`is_active` 切回 id=1，删除 id=17 及其 `config_sites`；`history` 仍为 24 条；
- 复核：修复后 `quick_check=ok`，当前配置 `http://192.168.50.50:4567/t4/2024/buye-0`。

## 3. 根因加固

| 模块 | 文件 | 内容 |
| --- | --- | --- |
| 目录解析 | `lib/services/app_paths.dart` | POSIX 上按同构语义消费 `roaming/local`（config=roaming/app、data=local/app、cache=local/app/cache、logs=local/app/logs）；优先级 最终目录 > xdg* > roaming/local > XDG 环境 > HOME 默认；macOS 显式覆盖不再被默认分支抹掉 |
| 测试写入闸 | 同上 | `FLUTTER_TEST=true` 且未提供**完整**隔离目录时，`ensureDirectories` 在**第一次目录 IO 之前**抛 `StateError`；`AppState.bootstrap` 第一步就是它，因此不可能先打开真实库。`resolve()` 不抛，纯 mock 构造保持可用 |
| 来源状态 | `lib/services/config_source_status.dart`（新） | `notLocal/available/missing/unreadable`；文件系统只读探测（打开句柄读 1 字节），HTTP/inline/桥接/WSL 式 Windows 路径零 IO |
| 恢复状态 | `lib/state/app_state.dart` | 缓存恢复后异步检测当前本地来源；独立于 `lastError` 发布 `restoredConfigSourceStatus`；关闭、切换、编辑来源、刷新、导入、删除、dispose 均按 id+origin+代际失效 |
| 界面 | `lib/ui/config_source_status_view.dart`（新）、`config_pages.dart`、`app.dart` | 列表/切换器行内「来源文件已丢失（无法读取）· 使用缓存」；启动顶部横幅「刷新不可用；请恢复来源文件、编辑来源地址或切换配置」+「管理配置 / 关闭提示」；缓存配置仍可点击切换 |

设计取舍：失效来源**保留缓存与历史**，不自动删除记录、不自动换配置、不联网探测；提示只解释与指路。

## 4. 验证

独立复跑（每次均以隔离 HOME + 四个 XDG + TMPDIR 外层包装）：

```text
合并回归（A+B+C 全部相关用例，一次跑完）
  → 102 passed / 2 platform skips / exit 0
分模块：
  A: 路径隔离 + 写闸 + 配置页/切换/上次配置/本地来源身份/AppState/启动架构
  B: config_source_status_test + config_source_restore_test          → 21 passed
  C: config_source_status_ui_test + config_source_status_capture_test → 12 passed
观影报告回归（本次改动的另一部分，未受影响）                          → 86 passed
全量 dart analyze                                                     → 0 error / 0 warning / 95 issue（与基线一致）
```

正式目录未被测试触碰：`settings.json`(15:01)、`webhtv-pc.sqlite3`(16:09) 的 mtime 均早于所有加固测试运行。

视觉证据（同 fixture、profile、now=2026-11-14 12:00、字体）：

- `evidence/screenshots/config-hardening/before-list.png` / `after-list.png`
- `before-startup.png` / `after-startup.png`
- `after-list-narrow-light.png`（780×950，长路径窄屏）、`after-startup-narrow-light.png`（1024×950）

## 5. 已知边界

- 只加固了 `ensureDirectories` 这一写入闸；`probeWritable` 不在此闸内。
- 测试内 `AppState()` 默认画像现在会在 `bootstrap` 阶段直接失败（有意为之）；既有测试已全部显式隔离。
- `test/local_source_shell_test.dart` 仍失败（SitePicker 找不到站点 `c`）。已用 `git stash` 移开本次两个 UI 文件后复测，**同样失败**，属既有问题，与本次改动无关。
- Windows 运行时未执行；本机无 `libmpv`，播放器相关测试无法在此环境运行。
