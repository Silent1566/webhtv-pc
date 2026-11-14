# 06 · W3 / P2-1 追番

- 日期：2026-10-22
- 上游：`following/`（`FollowingIdentity`、`FollowingSchedulePolicy`、
  `FollowingUpdatePolicy`、`FollowingStore`、`FollowingScheduler`）、
  `ui/activity/FollowingActivity.java`
- 状态：**已实现（应用运行期检查）**；无后台常驻、无系统通知

## 1. 身份与数据

- 身份键与安卓同格式：`source:<cid>:<siteKey>:<vodId>:s<season>`；
  PC 没有配置记录 id 的追番上下文，`cid` 固定 0。
- DB **v6** 新增 `following`（29 列，主键 `(series_key, season)`）：
  剧集标识、追踪线路（`flag`/`source_flag`）、最新发布集数、已看集数、
  已读水位、已通知集数、状态、下次检查/首播时间、失败计数/错误、
  元数据时间、最后检查时间、开关、时间戳；最新集的展示名与入口目标
  （用于「播放最新集」直接重新解析）。
- 加法式迁移：旧库打开自动建表；`schemaVersion` 5 → 6。

## 2. 策略（与安卓对齐）

| 项 | 规则 |
| --- | --- |
| 连载中 | 6 小时检查一次（前台 15 分钟） |
| 未开播 | 24 小时 |
| 已完结/腰斩 | 7 天 |
| 首播 | 首播时间 + 30 分钟后追一次，且至少 1 小时后 |
| 失败退避 | 15m → 30m → 1h → 2h → 6h → 1d |
| 有更新 | `已发布 > max(已看, 已读水位)` |
| 通知 | `enabled && notifyEnabled && 已发布 > max(已读, 已通知)` |
| 首次元数据 | 只建立基线（水位=已发布），不制造「新集」提示 |
| 集数回退 | 取历史最大值，不被站点的偶发少集覆盖 |

## 3. 实现

| 模块 | 文件 | 内容 |
| --- | --- | --- |
| 纯策略 | `lib/core/following.dart`（新） | 身份键、调度/退避、快照→更新、通知/已读/失败、设置（夹取 15–1440 分钟、JSON） |
| 存储 | `lib/services/storage.dart` | v6 迁移 + `following` CRUD（`followings/byVod/byKey/upsert/delete/count`） |
| 检查服务 | `lib/services/following_service.dart`（新） | 详情解析回调 → 线路集数快照 → 应用策略 → 持久化；串行 `checkAll`；失败不抛、写退避 |
| 状态 | `lib/state/app_state.dart` | 追番设置/列表/徽标数、`followFromDetail`、取消/已读/已看、检查单条/全部、运行期 `Timer`（启动后补一次到期检查）、数据交换时清理 |
| UI | `lib/ui/following_page.dart`（新）、`lib/ui/app.dart`、`lib/ui/browse_pages.dart` | 追番页（空态/卡片/更新徽标/检查/自动检查/新集提示开关/菜单：播放最新集、打开详情、检查、已读、取消）、侧栏追番入口 + 徽标、详情页 ★ 追番 |
| 播放 | 复用 `lib/ui/playback_resume.dart` | 用最新集的入口目标走历史续播同一条「重新解析」路径，播完标记已看 |
| 备份 | 现有整库 `VACUUM INTO` | 追番表随数据库快照自动进入备份/恢复，无需额外编码 |

## 4. 测试

`test/phase9_following_test.dart`：16 用例全部通过。

- 身份键格式；调度（6h/24h/7d/前台 15m、首播 +30m 且 ≥1h）；退避 6 档；
- 快照按 `sourceFlag`/`flag` 选线路、集数回退不覆盖、首次不报新集；
- 更新/通知水位、标记已读/已通知、失败写错误与退避；
- 设置夹取与 JSON；Following JSON 往返；
- 真实 SQLite：添加（水位=已发布）、检查（集数增加→有新集）、失败、`onlyDue`、已读/已看；
- 追番页：空态、卡片、`2 新` 徽标、检查/自动检查入口。

回归（本轮）：

```text
dart analyze                          → No issues found
phase9_* 全量                          → 240 用例通过
phase5_sync_storage / phase9_storage  → schema v6 断言更新后通过
phase2_startup_home / phase8_settings_entries / search_thread_ui → 17 用例通过
```

## 5. 边界（明确披露）

- **只在应用运行期间检查**：没有 Android WorkManager 式后台常驻；
  关闭应用后不会检查。启动后 10 秒补一次到期检查，不阻塞首屏。
- **没有系统级通知**：只有侧栏徽标与追番页「N 部有新集」；
  系统通知需要新依赖与降级设计，未做。
- **更新口径是站点详情的线路集数**，不是 TMDB 元数据；`trackedSeason`
  固定 0（字段保留，不伪造季号）。
- **未迁移** AList 订阅导入与片源探测（`FollowingSourceProbe`、
  `AlistSubscriptionImporter`）；目前只支持从详情页手动追番。
- 追番检查失败会退避并保留最后错误，不影响其他条目（串行 + 单条 try/catch）。
