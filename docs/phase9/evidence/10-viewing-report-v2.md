# 10 · 观影报告 v2（四维偏好 + 桌面增强）

- 日期：2026-11-14
- 基线：PC `wt/dev3 @ 7b6f3f7`（tracked 干净）；Android `webhtv@2d8b9977596b`
- 设计：`docs/phase9/design/10-viewing-report-v2.md`（用户确认口径）
- 对照条目：`docs/phase9/parity-2026-11-12/catalog.md:19`（观影报告 部分 → 已迁移）

## 1. 问题

catalog 原判定为「部分」：安卓 `ViewingReportGenerator` 有题材/地区/演员/导演四维榜单与「跨文化探索者」徽章，PC `core/viewing_report.dart` 只有时段/完播/最常看，头注释明示「历史表缺字段，不能假装有」。

根因不在统计层，而在**数据链路**：站源详情本身带 `vod_area`/`vod_actor`/`vod_director`/`type_name`（`core/protocol.dart:1023-1045`），但 PC 从未落库；播放器写历史时只传 id/name/pic（`ui/player_page.dart:2609`）。

## 2. 变更

| 模块 | 文件 | 内容 |
| --- | --- | --- |
| 元数据模型 | `lib/core/viewing_metadata.dart`（新） | `ViewingMetadata`：四维标签 + `mediaType`，全默认空 |
| 元数据链路 | `lib/services/viewing_report_metadata.dart`（新） | 站点详情快照、补缺合并、离线 TMDB 兜底、幂等写、`captureWrites` 诊断 |
| 存储 | `lib/services/storage.dart` | schema **10→11 纯加法式**：`viewing_metadata` 表（source_key+site_key+vod_id+source_title）；严格源域 TMDB 绑定查询 |
| 状态 | `lib/state/app_state.dart` | `viewingReportMetadata(records)`（只读）；`loadDetail` 与 `recordProgress` 采集闸门 |
| 缓存 | `lib/services/tmdb_cache.dart`/`tmdb_service.dart` | `detailsFor(Set<TmdbIdentity>)` 只读批量扫描，**一次目录扫描**，不发网、不刷新 |
| 统计 | `lib/core/viewing_report.dart` | 四维榜单（5/5/8/5）、探索者徽章、覆盖率、电影/剧集/未知、站源分布、7×24、上一周期对比、AI 提示词扩展 |
| 界面 | `lib/ui/viewing_report_page.dart` + `viewing_report_sections.dart`（新） | 摘要（含与安卓一致的「平均每条」）/口径、周期对比、时段+热力图、内容偏好、徽章、站源、最常看、AI；AI 代际守卫（旧响应不得覆盖新范围） |

## 3. 与安卓的对齐与差异

对齐：完播阈值 90%、深夜 23:00–06:00、时段五桶、榜单上限（题材/地区/导演 5、演员 8）、探索者阈值（≥4 个地区）、深夜≥10/作品≥30/完播率≥70% 且≥20 条的徽章阈值。

**PC 额外**（安卓无对应）：站源分布、7×24 热力图、上一周期对比、各维覆盖率与未知计数、按记录去重的频数口径说明。

已知差异（如实保留，不冒充）：

- 时段/周末/热力图按 `updated_at`（安卓 `create_time`）；时长为历史 `position` 累计，**不是**实际观看会话计时，页面写明；
- 元数据只覆盖「升级后打开过详情或播放过」的作品；旧记录如实显示未知，报告展示覆盖率；打开报告零网络请求；
- 安卓有 AI 结果指纹缓存（`ViewingReportCache`），PC 为按需生成、不落盘缓存；
- 频数为「历史记录条数」而非作品级投票（安卓按记录累加，口径一致，PC 额外在页面声明）。

## 4. 验证

独立复跑（`cd apps/desktop-flutter`，`PUB_CACHE=../../.tools/pub-cache`）：

```text
flutter test --no-pub test/viewing_report_v2_test.dart \
  test/viewing_report_v2_ui_test.dart test/viewing_report_v2_capture_test.dart \
  test/viewing_report_metadata_test.dart test/viewing_report_metadata_integration_test.dart \
  test/phase9_viewing_report_test.dart test/viewing_report_ai_narrative_test.dart
                                                                  → 96/96 passed
dart analyze                                                      → 0 error / 0 warning / 95 info（与基线既有 info 数一致，新增文件无条目）
```

覆盖的边界：schema 10 旧库升级与重开、历史进度/时间戳不变、同名异源隔离、过期详情与来源切换、隐身不采集、损坏缓存/无凭据降级、TMDB 缓存零请求与一次扫描、CJK 空白拆分与英文全名、地区本地化名优先、四维去重与未知、探索者真值（不因 top5 截断误判）、7×24 边界、滑动/月/季/年/半年与未开始的半年、零基数不显示无穷、DST（`TZ=America/New_York`）、AI 旧响应不覆盖新范围。

视觉证据（同 fixture、now=2026-10-21 12:00、字体、暗色 1280×950 DPR1）：

- `evidence/screenshots/viewing-report-v2/before-top.png` / `after-top.png`（同一滚动起点）
- `before-lower.png` / `after-lower.png`（“跳到报告末尾”场景；原页在该视口无滚动余量，故与顶部同帧，已在报告中说明）
- `after-middle.png`（热力图 + 四维实际画面）、`after-narrow-heatmap.png`（780 宽 24 列不溢出）、`after-light.png`

未验证：真实 Windows 播放、真实联网 TMDB（本轮只验证离线缓存路径）、旧库大规模真实数据下的观感。

## 5. 复现

```bash
cd apps/desktop-flutter
PUB_CACHE=../../.tools/pub-cache ../../.tools/flutter/bin/flutter test --no-pub test/viewing_report_v2_test.dart
VIEWING_REPORT_CAPTURE_PHASE=after PUB_CACHE=../../.tools/pub-cache \
  ../../.tools/flutter/bin/flutter test --no-pub --concurrency=1 test/viewing_report_v2_capture_test.dart
```
