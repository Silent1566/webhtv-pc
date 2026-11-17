# P0-2 拖动进度条时暂停 —— 落地证据

> 对应 [../potplayer-checklist.md](../potplayer-checklist.md) P0-2 与
> [../potplayer-borrowings.md](../potplayer-borrowings.md) §3.2。
> 基线：`a01caeb`（本分支 HEAD）；路径相对 `apps/desktop-flutter/`。

## 1. 需求与产品决策

| 项 | 结论 | 依据 |
| --- | --- | --- |
| 形态 | **可关闭设置项**，默认**开启** | 用户确认 |
| 暂停时机 | 指针拖动（含单击轨道，Flutter 单击也走 start→end） | Flutter `Slider` 语义 |
| 恢复时机 | 松手后**仅当**拖动前在播才恢复播放 | `PlayerDragPauseGate` + 单测 |
| 不暂停的路径 | 直播（`_isLive`）与所有程序化 seek | 页面侧判据 + 页面级用例 |
| seek 频率 | **拖动期间不发 seek，松手一次**（2026-11 修订，见 §4） | 真机实测，用户确认 |
| 不改的语义 | 缓冲段隐藏、进度行高度 32 | 既有测试全绿 |

## 2. 落点

- 开关：`core/player_options.dart:137,207`（键 `dragPause`，缺键回落 `true`）
- 滑杆回调：`ui/player_overlay.dart:212-238,489-509`
- 判定器与接线：`ui/player_page.dart:161-185`（gate）、`:397-435`（`_dragSeekTarget` 与 settle）、`:4898-4965`（`onSeek` 只记录、`onSeekEnd` 提交一次 seek 再决定是否 play）
- 「定位中也算卡住」：`ui/player_controller.dart` 的 `isSeeking`（`NativePlayer.observeProperty('seeking')`，非原生平台退化为 false）+ `ui/player_overlay.dart` 的 `showBufferingIndicator(isBuffering || isSeeking) && !isLoading`
- 入口：设置 → 播放「拖动进度条时暂停」、右键「播放 → 拖动进度条时暂停」

## 3. 验证（Lead 独立执行）

环境：Flutter 3.47.5；`LIBMPV_LIBRARY_PATH`/`LD_LIBRARY_PATH` 指向仓库内 `.local/libmpv-full`；
`TMPDIR` 指到磁盘（`/tmp` 是 2.2G tmpfs，默认会 ENOSPC）。

| 命令 | 结果 |
| --- | --- |
| `flutter analyze`（改动文件） | **No issues found!** |
| 10 个套件（含 `player_drag_pause_test` 21 例、`player_seeking_buffering_test` 5 例） | **150 项全绿** |
| HEAD 基线同套件（无本次改动） | 124 项全绿 → 净增 26 例，无既有断言被改弱 |

## 4. 真机缺陷与根因（2026-11，用户实测后修订）

**现象**：拖动一次进度条后画面静止十几秒，且**没有任何加载提示**；等一会儿会自己恢复。

**取证**（真实 libmpv，`set pause yes` → 20 次 `seek` → `set pause no`）：

- `pause=no` **立刻**生效 → 不是"卡在暂停"；用户把开关关掉后同样静止 → 与暂停无关。
- `seeking=yes` 持续整个观察窗，`time-pos` 钉在目标值 → 没有新帧，画面当然静止。
- 同期 `core-idle=yes`、`paused-for-cache=no`、`cache-buffering-state=100`、
  `demuxer-cache-time=None` → media-kit 的 buffering 流全程沉默，
  所以"加载中"根本不可能出现。

**根因**：拖动时**每移动一格发一次 seek**（老行为），这条 HLS 代理单次 seek 需 1–3 秒，
几十个串行排队把 mpv 长时间按在 `seeking=yes`。

**处置**：

1. 拖动期间不落引擎 seek，松手只发一次；拇指与时间在拖动中跟手（`_dragSeekTarget`），
   且**松手后保持到引擎追上**（`_settleDragSeekTarget`，窗口 2s、保底 15s），避免读数先弹回旧值。
2. 把 `seeking` 并入缓冲提示，慢 seek 期间用户看到既有转圈而不是干等。
3. 换媒时清空拖动目标与 gate 状态，绝不把上一部片的目标 seek 到新片上。

## 5. 变异校验（证明用例不是假绿）

- 去掉 `!_isLive` 判据 → 「直播拖动」用例失败。
- 去掉 `!dragPause` 判据 → 「关掉开关」用例失败。
- 把 `onSeek` 改回直接 `_controller.seek` → 「拖动期间一格都不 seek」用例失败。

## 6. 遗留与不做的部分

- 拖动时画面不跟手（停在暂停帧），这是"只 seek 一次"的直接代价；换来的是不再排队几十个 seek。
- PotPlayer 侧「松手是否自动恢复」仍属未验证（Q-38）；这里的选择是按拖动前状态恢复，属产品决策。
- 未提供额外 OSD 提示与新快捷键。
