# Phase 9 证据目录

验收规范见 `docs/phase9/design/04-acceptance.md`。

| 文件/目录 | 内容 | 状态 |
| --- | --- | --- |
| `00-gap-analysis.md` | 安卓基线盘点与差距判定 | 已产出 |
| `gap-matrix-gate.txt` | `tools/phase9/verify_gap_matrix.py` 门禁输出（G9.1–G9.5） | 已产出 |
| `01-w1-implementation.md` | W1/W2 变更清单、测试、已知偏差、暂缓项 | 已产出（随每轮更新） |
| `02-p0-l3.md` | P0 真实窗口集成（5 条 L3）+ 截图可复现性 + 未证清单 | 已产出 |
| `03-w3-viewing-report.md` | W3 / P2-2 观影报告：对齐项、差异、测试与已知 flaky | 已产出 |
| `04-w3-backup.md` | W3 / P2-7 备份、恢复、重置：格式、安全边界、测试 | 已产出 |
| `05-w3-privacy-doh-recovery.md` | W3 / P2-8 DoH、隐身、崩溃恢复：实现、边界、测试 | 已产出 |
| `06-w3-following.md` | W3 / P2-1 追番：策略、存储、页面、测试与边界 | 已产出 |
| `07-w3-following-runtime.md` | W3 / P2-1 追番运行期：默认开启、间隔设置、系统通知与降级、ADR 0006 | 已产出 |
| `08-w3-following-calendar.md` | W3 / P2-1 追剧日历：归日策略、页面与导航、TMDB 真实播出日接入 | 已产出 |
| `player-l3-run.txt` | `phase9_player_flow_test.dart -d windows` 原始输出 | 已产出 |
| `screenshots/01-context-menu-skip-segments.png` | 右键菜单「片头片尾」截图（只裁菜单本体；两次运行 sha256 一致） | 已产出 |

尚未产出（按波次补充）：`windows-acceptance.txt`（一键验收日志）、
`test-run.txt` / `analyze.txt`（全量原始输出）、`samples.md`（真实源脱敏样本）。
