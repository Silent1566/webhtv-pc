# Phase 8 · 播放器浮层改造（悬浮控制栏 + 屏显 + 右键菜单 + 按钮排版）

- 状态：**已实施并验收**（2026-10-20）
- 日期：2026-10-18（设计）／2026-10-20（验收）
- 适用工程：`apps/desktop-flutter`
- 上游参考：`F:\Workspace\webtv4\webhtv`（Android 工程「默影视」）
- 设计文档：`docs/phase8/design/00`–`05`
- 实现计划：`docs/phase8/plans/01-player-overlay.md`
- 验收证据：`docs/phase8/evidence/`

---

## 1. 一句话目标

把播放器控制栏从**挤占布局的兄弟节点**改成**叠在画面上的半透明浮层**，
并补齐**屏显（OSD）**、**右键设置菜单**、**可配置的按钮排版**。

---

## 2. 用户诉求（原文）

> 现在每次唤醒控制台都会导致画面缩放（应该是被上下的控制栏挤占了位置）能否参考安卓版/
> 默影视（F:/Workspace/webtv4/webhtv）把控制台改成半透明的悬浮显示这样应该就不会挤占了，
> 还有参考 potplayer 的那种右键设置功能这样在 PC 上应该更好交互，还有屏显等主流播放器功能
> 和播放器按钮排版优化包含控制栏。

---

## 3. 根因（一句话）

`player_page.dart:1400-1473` 把控制条放在 `Column` 的**兄弟节点**位置，
`Expanded` 分配剩余高度 → 控制条显隐改变视频容器高度 →
`BoxFit.contain` 重新按比例居中 → **整幅画面缩放并位移**。

安卓参考（`activity_video.xml:30-98`）把 `control` 与 `osd` 作为视频
`FrameLayout` 的**重叠子项**，两者都不占布局空间。本轮照此改造。

---

## 4. 四个子系统

| # | 子系统 | 性质 | 设计文档 | 可独立验收 |
| --- | --- | --- | --- | --- |
| A | 控制栏改悬浮浮层 | **布局模型变更**（根因修复） | `01` | ✅ |
| B | 屏显（OSD） | 新增子系统 | `02` | ✅ |
| C | 右键设置菜单 | 新增交互面（桌面专属） | `04` | ✅ |
| D | 按钮排版可配置 | 新增持久化配置 | `03` | ✅ |

**依赖关系**：

```
A（浮层）─┬─► B（屏显叠在浮层下）
          ├─► C（菜单是 Stack 的第 4 层）
          └─► D（按钮在浮层底栏里渲染）
```

**A 是所有其它三项的地基**：B/C/D 都需要"画面不被挤占"这个前提。
因此实现顺序必须是 A → (B, C, D)。

---

## 5. 已确认的设计决定（用户 2026-10-18 确认）

| # | 决定 | 选项 |
| --- | --- | --- |
| 1 | 右键菜单范围 | **仅播放器页**（全局扩展留待后续） |
| 2 | 按钮可配置程度 | **可隐藏 + 可重排**（对齐安卓） |
| 3 | 屏显默认值 | **标题+分辨率、播放进度、时钟**（网速/迷你条/诊断默认关） |
| 4 | 顶栏处理 | **也改成悬浮自动隐藏**（与底栏同属一个浮层） |

---

## 6. 不可退让的边界（摘要）

完整清单见 `design/00` §5。最关键的六条：

1. **控制栏与屏显一律不得参与布局**（机器验证：视频区矩形逐像素不变）。
2. **四个 tooltip 精确串不得改，也不得收进菜单**：
   `'字幕轨'`、`'弹幕（开启）'`/`'弹幕（关闭）'`、`'全屏（F11）'`、`'更多'`。
3. **`'更多'` 必须仍在 `AppBar` 内** → 顶栏改浮层时**保留 `AppBar` 类型**。
4. **不得引入阴影或非 0 elevation**（`DESIGN.md` The Flat-Field Rule）。
5. **不得改 Material 3 的字号与行高**（`DESIGN.md` The Metric-Neutral Rule）。
6. **右键菜单不得成为唯一入口**（每项都要有键盘/顶栏等价路径）。

---

## 7. 与上游的有意差异（9 条）

完整表见 `design/05` §7。摘要：

| # | 差异 | 理由 |
| --- | --- | --- |
| 1 | 时钟默认 **开**（上游关） | PC 场景需求（用户确认） |
| 2 | 网速屏显 **Phase 8 不实现；后续已实现**（双数据源：`demuxer-cache-state` 内解析 `raw-input-rate` 字段，解析不到回退 `cache-speed`；见 `design/02` §3.6） | 原判「无字节级吞吐量」已被证伪；「只覆盖代理流量会误导」也不成立。另：`raw-input-rate` **不是** mpv 属性（实测 `rc = -8`），只是 `demuxer-cache-state` 的 JSON 键 |
| 3 | 控制栏可见时**只强制时钟** | PC 顶栏已显示标题 |
| 4 | 按钮配置用 **JSON 数组**（兼容读字符串） | PC 已有 JSON 设置文件 |
| 5 | **不播种**默认隐藏项 | PC 端无默认隐藏项 |
| 6 | 可配置按钮 **9 个**（上游 32） | 只保留 PC 有真实实现的 |
| 7 | **新增右键菜单** | 桌面专属交互 |
| 8 | 屏显内边距 16px（上游 14dp） | 不引入第 17 个间距值 |
| 9 | 诊断附加列改为 PC 环境 | 上游设备信息在 PC 无对应物 |

---

## 8. 交付物清单

| 类型 | 路径 |
| --- | --- |
| 设计文档 | `docs/phase8/design/00`–`05` |
| 实现计划 | `docs/phase8/plans/01-player-overlay.md` |
| 新增源码 | `lib/ui/player_overlay.dart`、`lib/ui/player_osd.dart`、`lib/ui/player_context_menu.dart`、`lib/ui/player_button_config_page.dart`、`lib/core/osd_config.dart`、`lib/core/player_buttons.dart` |
| 修改源码 | `lib/ui/player_page.dart`、`lib/services/ui_preferences_store.dart`、`lib/state/app_state.dart`、`lib/ui/diagnostics_pages.dart` |
| 新增单测 | `test/phase8_*.dart`（11 个） |
| 新增集成测试 | `integration_test/phase8_*_flow_test.dart`（2 个） |
| 验收脚本 | `tools/phase8/run_windows_acceptance.ps1`、`tools/phase8/verify_reverse_checks.py`、`tools/phase8/verify_design_docs.py`、`tools/phase8/verify_flat_field.py`、`tools/phase8/verify_metric_neutral.py` |
| 证据 | `docs/phase8/evidence/**` |

---

## 9. 门禁（摘要）

完整表见 `design/05` §6。

| # | 门禁 | 命令 |
| --- | --- | --- |
| G1 | 静态检查 | `dart analyze` |
| G2 | 单元测试 | `flutter test` |
| G3 | 套件存在性 | 脚本内清单核对 |
| G4 | Windows 集成 | `flutter test integration_test/phase8_*_flow_test.dart -d windows` |
| G5 | 反向验证（10 项） | `py -3 tools/phase8/verify_reverse_checks.py` |
| G6 | 设计文档一致性 | `py -3 tools/phase8/verify_design_docs.py` |
| G7 | 几何不变式专项 | `flutter test integration_test/phase8_overlay_flow_test.dart -d windows` |
| G8 | 截图证据（13 张与清单逐字节一致） | `py -3 tools/phase8/verify_screenshots.py` |
| G9 | 无阴影/无 elevation | `py -3 tools/phase8/verify_flat_field.py` |
| G10 | 字号未改 | `py -3 tools/phase8/verify_metric_neutral.py` |
| G11 | 既有测试回归 | `flutter test` + 3 个受影响集成套件 |
| G12 | 定时器无泄漏 | `flutter test test/phase8_player_page_overlay_test.dart` |

一键验收：

```powershell
pwsh -File tools/phase8/run_windows_acceptance.ps1
pwsh -File tools/phase8/run_windows_acceptance.ps1 -SkipIntegrationTests
```

---

## 10. 基线（改造前实测）

| 项 | 结果 | 命令 |
| --- | --- | --- |
| 静态检查 | `No issues found!` | `puro -e webhtv -p . dart analyze` |
| 播放器显示单测 | `4 passed` | `puro -e webhtv -p . flutter test test/phase3_player_display_test.dart` |

**这两个值在改造后必须保持不劣化。**

---

## 11. 验收结果（2026-10-20）

一键验收原始输出：`docs/phase8/evidence/windows-acceptance.txt`（约 547 KB）。

| 项 | 结果 |
| --- | --- |
| 一键验收 | `PHASE8-ACCEPT result=PASS gates=all` |
| 静态检查 | `No issues found!`（7.3s） |
| 单元测试 | **2503 全绿**（196.9s） |
| 套件存在性 | `suites=13 missing=0` |
| Windows 集成 | 两套件全绿（262.0s）：V1/V2 几何不变式 + 4 张视觉证据 |
| 几何不变式 | `geometry-invariant PASS`（视频区矩形前后逐像素相同） |
| 反向验证 | `PHASE8-REVERSE result=PASS checks=10`（10/10 按预期失败且还原干净，345.0s） |
| 设计文档一致性 | `PHASE8-DESIGN-DOCS result=PASS` |
| 截图证据 | `PHASE8-SCREENSHOTS result=PASS count=13`（与 `manifest.txt` 逐字节一致） |
| 无阴影/无 elevation | PASS |
| 字号未改 | PASS（`theme.dart` 的 `_textTheme` 与基线逐字相同） |
| 定时器无泄漏 | PASS（`suite=osdTickerRunning seam=debugOsdTickerRunning`） |
| 基线不劣化 | 静态检查仍 `No issues found!`；播放器显示单测仍 4 通过 |

### 11.1 新增测试规模

| 类型 | 套件 | 用例数 |
| --- | --- | --- |
| 单元 | `phase8_osd_config_test.dart` | 9 |
| 单元 | `phase8_player_buttons_test.dart` | 16 |
| 单元 | `phase8_osd_persistence_test.dart` | 12 |
| 单元 | `phase8_app_state_config_test.dart` | 9 |
| 单元 | `phase8_osd_diagnostics_test.dart` | 28 |
| 单元 | `phase8_osd_layer_test.dart` | 19 |
| 单元 | `phase8_overlay_layout_test.dart` | 14 |
| 单元 | `phase8_context_menu_test.dart` | 19 |
| 单元 | `phase8_button_config_page_test.dart` | 17 |
| 单元 | `phase8_settings_entries_test.dart` | 8 |
| 单元 | `phase8_player_page_overlay_test.dart` | 13 |
| 集成 | `phase8_overlay_flow_test.dart` | 2 |
| 集成 | `phase8_visual_flow_test.dart` | 4 |
| **合计** | **13 套件** | **170** |

### 11.2 本轮修掉的真实缺陷（摘要）

完整记录见 `.superpowers/sdd/01-player-overlay/progress.md`（裁决 R1–R115）。

| 缺陷 | 性质 |
| --- | --- |
| 控制栏是 `Column` 兄弟节点 → 唤醒即缩放 | **用户投诉的根因**（V1 变异验证可复现） |
| 设置页新增区块把站点健康入口挤出惰性视口 | 真实产品回归（`1440×2400` 下入口**根本没被构建**） |
| 迷你进度条布局正确但落在裁剪框外 → 一个像素都没画 | 测试只断言矩形时全绿 |
| `Esc` 关闭菜单的机制描述错误（嵌套 `CallbackShortcuts` 不在冒泡路径上） | 设计稿机制错，实测按 Esc 反而退出全屏 |
| 右键菜单底部溢出窗口 156px | brief 的 9 个用例测不出来 |
| 直播状态有且只有一个渲染点，删除 `_ControlBar` 会静默丢失 | 零设计文档提及、零测试覆盖 |
| `normalizeButtonHidden` 收到 `Set` 时静默返回空集 | 用户设置被无声忽略 |
| `ReorderableListView` 用 `onReorderItem` 时手动减一会多减一次 | brief 的用例只做向上拖动，测不到 |
| 7 个屏显开关只点过 `mini` → 写死 id 的实现全绿 | 回归锁为空 |
| G12 门禁比实现更严 → 正确实现反而红 | 门禁假失败 |
| 屏显时钟每秒 `setState` → 既有套件的 `pumpAndSettle(≥1s)` 永不返回 | 3 个套件在 `10:09` 超时；**门禁从未跑过它们** |
| 控制浮层 3 秒自动隐藏后 `IgnorePointer` 吃掉点击 | `tester.tap` 只打 warning，断言以「找不到」失败，看不出真因 |
| G11 声称「含在 G2 的全量 `flutter test` 里」 | `flutter test` 不含 `integration_test/`——**空头支票** |
| 第一版悬停保持包在 `Positioned.fill` 上 → 控制条永不隐藏 | 自造缺陷，已回退（`01` §4.5 落地状态） |

### 11.3 已知的遗留与待签字

| 项 | 状态 |
| --- | --- |
| 分隔线颜色用 `colorScheme.outline` 而非 `dividerColor` | **待设计签字**。`dividerColor`（`#232C46@0.72`）压在视频上实测约 1.2:1，视觉上等于看不见；`outline`（`#3A4560`）约 1.9:1。这是对 `DESIGN.md` The Hairline Rule 的**有意例外**——该规则针对主题表面，而本浮层坐在视频帧上。改回是一行的事。 |
| 直播状态屏显 | 仅从删除中救回，**未新增**设计文档与测试覆盖 |
| 鼠标移动唤醒控制栏（`design/01` §4.5） | **已实现**（第 1 层 `MouseRegion(onHover:)`，只在隐藏态唤醒；`test/phase8_controls_hover_test.dart` 锁两侧） |
| 「指针停在浮层上不隐藏」（`design/01` §4.4 隐藏时机） | **未实现**。控制浮层是 `Positioned.fill`，`onEnter` 等于「指针在窗口内」，无条件保持会永不隐藏（第一版实现踩到并回退）。要做对需把 `MouseRegion` 收缩到顶栏/底栏两条实际条面 |
| `_formatDuration` 在 `player_osd.dart` 与 `player_page.dart` 各一份 | 两份 7 行纯函数，均有测试覆盖；`osd_diagnostics.dart` 里还有一份同体但异名的 `_duration` |
| 拖动到边缘自动滚动（按钮配置页） | 不支持（9 个两行 `ListTile` 在 600px 高窗口会溢出，但真实桌面窗口更高） |
