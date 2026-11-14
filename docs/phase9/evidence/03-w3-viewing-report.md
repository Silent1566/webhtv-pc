# 03 · W3 / P2-2 观影报告实施记录

- 日期：2026-10-21
- 基准：`docs/phase9/README.md` §4.3 P2-2、§12
- 上游：`android/.../viewing/ViewingReportGenerator.java`、`ViewingReportAiAnalyzer.java`

## 1. 变更清单

| 模块 | 文件 | 内容 |
| --- | --- | --- |
| 统计模型 | `lib/core/viewing_report.dart`（新） | 9 种范围与时间边界；时段/周末/深夜；完播率；片名归一化去重；最常看作品；3 类徽章；`now` 注入保证可复现 |
| AI 解读 | `lib/services/viewing_report_ai.dart`（新） | 复用 `AiCompletionClient`；未配置零请求；提示词显式声明「数据不可信」；失败返回原因；输出 2000 字上限 |
| 页面 | `lib/ui/viewing_report_page.dart`（新） | 范围下拉、统计卡、时段条、徽章、最常看、AI 区块；空态；AI 失败不隐藏基础报告 |
| 入口 | `lib/ui/library_pages.dart` | 历史页工具栏「观影报告」；空历史也可进入（报告页自己的空态） |

## 2. 对齐与差异

对齐安卓：

- 完播阈值 90%（`position > 0 && duration > 0` 才进分母）；
- 深夜 23:00–06:00；时段 凌晨/上午/下午/晚上/深夜；
- 徽章：深夜 ≥10 次、作品 ≥30 部、完播率 ≥70% 且记录 ≥20；
- 片名去重会去掉空白、间隔号、中英文标点与括号再小写；
- AI 是可选叠加：未配置时基础报告完整。

**没有做**（PC 历史表没有对应字段，不能假装有）：

- 题材/地区/演员/导演榜单，以及依赖地区数的「跨文化探索者」徽章；
  用「最常看作品（时长/条数）」替代；
- 导出/分享：本轮没有文件导出通道，不摆无行为按钮；
- 时段与周末按 `updated_at` 统计（安卓用 `create_time`），页面写明口径。

## 3. 测试

`test/phase9_viewing_report_test.dart`：16 用例全部通过。

- 黄金样本：182 分钟 / 4 部（含一条 0 进度脏记录）/ 完播率 50% / 深夜 1 次 /
  周末 40% / 最常时段=上午；
- 范围：最近 7 天、本月、上半年与边界（周一、季度首月、半年末毫秒）；
- 归一化、同分排序、徽章阈值；
- AI：未配置零请求、提示词注入防护、成功清洗、HTTP 500 降级；
- 页面：空态、统计渲染、未配置 AI、AI 成功、历史页入口可达。

运行时回归：

```text
dart analyze                          → No issues found
phase9_* 全量                          → 188 用例通过
phase3/phase8 播放器与弹幕回归          → 71 用例通过
```

已知 flaky（已修复，2026-10-22 更新）：

```text
phase6_history_page_test: play 分流（1 条）
phase6_history_folder_detail_test: folder 详情（3 条）
```

根因不是测试环境：P1-9 的出站代理在 `bootstrap()` 里无条件重建 `_httpClient`，
把测试注入的捕获客户端换成了真实 `HttpClient`（框架固定返回 400），于是续播
永远拿不到响应。修复「代理未生效时保留注入客户端」后，这 4 条与
`phase2_startup_home_test` 一起恢复全绿（见 `04-w3-backup.md` §6）。

## 4. 复现

```powershell
cd apps/desktop-flutter   # puro 的 -p 不改工作目录，必须先进工程目录
puro -e webhtv dart analyze
puro -e webhtv flutter test test/phase9_viewing_report_test.dart
```
