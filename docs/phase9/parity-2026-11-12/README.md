# Android → PC 功能迁移复核（2026-11-12）

本目录取代 `docs/phase9/README.md` §4 的历史口径，作为当前**以源码为准**的迁移状态清单。

## 基线

| 侧 | 仓库 | commit |
| --- | --- | --- |
| Android | `webhtv`（参考实现） | `2d8b9977596b` |
| PC | 本仓库 | `b3c54d7e74f6` |

旧 Phase 9 基线是 Android `webtv2 @ 77e2fbefdc`（2026-10-20），与本仓库当前安卓分支已不同，因此旧「34 项」及其 P0–P3 分档**不再用于排期**。

## 判定口径

- **已迁移**：PC 有可达入口 → 真实调用 → 实现 → 适用持久化的闭环。
- **部分迁移**：可执行子链成立，但仍缺某个真实用户动作（例如「有设置项但没有消费者」）。
- **未迁移**：Android 有当前可达能力，PC 侧范围明确的负向检索零命中。
- **平台专属**：桌面/安卓在结构上无对应物（dex 执行、投屏、遥控器焦点等），不构成缺口。
- **证据不足**：Android 侧本身找不到可达入口（例如只有私有方法互调），不计为 PC 缺口。
- 本次全部为**源码静态核查**：未运行应用、未联网、未接真机/安卓桥接往返，因此「已迁移」只表示源码层面闭环，不等于实测通过。

## 结果（108 条用户可见能力）

2026-11-13 补核：catalog 的 Vod.tmdb 与配置根 tmdb_api_key 两项由未迁移更新为已迁移，故统计相应调整；[实现与测试证据](../evidence/09-tmdb-source-payload-and-key.md)。其余条目仍保持原基线静态判定。

| 状态 | 条数 |
| --- | --- |
| 已迁移 | 45 |
| 部分迁移 | 30 |
| 未迁移 | 22 |
| 证据不足 | 7 |
| 平台专属 | 3 |
| 双方均无（不构成缺口） | 1 |

分域明细：

- [catalog.md](catalog.md) — 配置 / 站源运行时 / 站点治理 / 点播详情 / TMDB（19 条）
- [playback.md](playback.md) — 播放器 / 字幕 / 弹幕 / 直播（24 条）
- [management.md](management.md) — WebHome / 管理页 / 远程托管 / 跨设备同步（18 条）
- [content.md](content.md) — 阅读 / 听书 / AI / 音频 AI / K 歌 / GitCloud（47 条）

## 最该先做的未迁移项

1. **站源动作卡**（`spider.action`）：签到/解析类动作在 PC 完全跑不了，PC 只识别 folder。
2. **本地文件播放**：PC 无本地视频打开入口，`external_player.dart` 明示不在能力范围内。
3. **Webhook 上报与观影记录写端点**：PC 只有拉取侧，第三方无法向 PC 推进度，也不会对外上报。
4. **`/m` 管理页与远程托管 relay**：PC 无法被浏览器/远端托管管理。
5. **WebTheme v2 / 更新检查 / GitCloud / WebHome 原生桥能力面**：结构性缺失或契约不同形，需先定方案。
6. **播放器细节**：双字幕、字幕与音轨偏移、预加载与失败回退（有设置项但无消费者）、直播收藏。

## 需要修正的历史判定

- **P0-4「播放参数含预加载/硬解/失败回退」原记为已实现**：PC 只有 `core/player_options.dart` 选项与设置页，`player_page.dart:851` 仍是固定 `openWithRetry`，点播「线路 → 解析 → 换源」策略无消费者。
- **P0-3「循环 / 定时关闭」**：定时关闭是 PC 额外新增（Android 全仓无此能力），不能算迁移项。
- **P1-4「接口失败切换」**：PC 的 `parse_failover` 只重试播放解析器，不是安卓的「配置/接口地址失败切下一份配置」。
- **P1-3「健康排序」**：PC 只有健康度排序，没有手动排序与屏蔽。
- **P2「一键同步」**：`SyncOptions` 仅 history/keep/backup/settings，配置/爬虫/登录态/WebHome/搜索并不参与。
- **P3「WebHome」**：PC 已有可达 WebHome 页面与 3 个原生方法，属于「部分迁移」，不是「完全不支持」。
- **反向澄清**：人声分离 / RVC / 伴奏生成 / 歌后结算弹窗在 Android 当前基线上也没有可达闭环，不应报为 PC 缺口。

## 复核方式

```bash
# 静态检查（SDK 路径按本机实际）
<flutter-sdk>/bin/dart analyze
<flutter-sdk>/bin/flutter test test/phase5_history_cross_source_test.dart
```

四份笔记内的每条判定都带两边 `file:line`，可直接定位复核。
