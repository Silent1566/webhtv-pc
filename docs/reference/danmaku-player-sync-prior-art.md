# 弹幕 × 播放器时间轴同步：开源实现一手调研

- 作用：回答「弹幕时间轴该怎么被播放器驱动」的一组事实问题（时间轴来源 / 回调映射 / 倒退与迟到上报 / 缓冲停顿 / 成本控制），
  供决定本仓库弹幕时钟设计是否改动。**本文只做对照，不提出改动方案**，最后一节只写「一手证据 settle 了什么 / 我们哪里确实不同 / 现有规则被哪些证据支持」。
- 语言约定：本目录既有笔记均为中文，本文正文中文，引文保留原文（英文/中文）以免转述失真。
- 调研方式：只读抓取公开仓库源码与官方 README（未 clone、未构建、未运行任何项目）。抓取时间 2026-11-23。
- 「一手」口径：能拿到源码就读源码；只有 README 表述的地方标明「README 表」，不当作实现细节。
- 本仓库引用行号对应 **2026-11-23 的工作树状态**（当时 `git status` 显示 `danmaku_motion.dart`、`danmaku_overlay.dart`、`player_page.dart`、`adr/0013` 有未提交改动；本文只引用、不评价这些改动），不是 HEAD。
- 版本锚点：**commit SHA 全部 UNVERIFIED**——调研期间 GitHub REST API 对本机 IP 返回 403 rate limit，
  无法取得各仓库 HEAD SHA；因此每条引用的锚点是「分支 + 文件行号 + 抓取日期」，可复现但不是不可变版本。可精确锚定的只有包版本：
  npm `danmaku@2.0.10`、Kazumi `canvas_danmaku: ^0.3.3`、MisaTV vendored `kniephos 1.2.0+13`。
- **项目名更正（事实）**：题面写的 `bilibili/DanmakuRenderEngine` 不存在（`https://github.com/bilibili/DanmakuRenderEngine` 返回 404）。
  「DanmakuRenderEngine」的真实仓库是字节跳动的 [bytedance/DanmakuRenderEngine](https://github.com/bytedance/DanmakuRenderEngine)（Android/Kotlin，
  已归档，默认分支 `main`，唯一 release/tag 为 `v0.1.0`）。下文所有 DRE 引用均指该仓库。该仓库 README 里确实有一张
  「Play Synchronization」播放器回调→弹幕操作映射表，见 §3.1。

---

## 0. 一句话结论

样本里 **四个引擎的弹幕运动完全不读播放器位置上报**（DRE、canvas_danmaku、ns_danmaku、weizhenye）：运动由自有 ticker / RAF / per-item AnimationController 推进，
位置上报只用来决定「哪条弹幕此刻该出现」（或干脆只在事件边界注入一次）。
因此「重复上报把时钟重新锚定」与「迟到上报被当 seek」这两个缺陷在它们那里**不是被修好的，而是结构上不存在**。
唯一和我们同构（Ticker + 周期 position，每次上报都重锚）的是 MisaTV，**而它两个缺陷都没有防**。

对我们最关键的一条负向结论：**没有任何一份实现用「位置差值的幅度」去推断 seek**。
凡是能拿到显式 seek 信号的地方（`onSeekStart/onSeekComplete`、DOM `seeking` 事件、`player.seek()` 调用点、Flutter 的 `seekTo()`），
一律用信号；没有信号的只有 MisaTV，而它连阈值都没有。支撑 §6。

---

## 1. 逐项目对照表

列含义：**时间轴来源**＝弹幕位置从哪来；**停顿**＝buffer stall 时弹幕怎么处理；**seek**＝seek 前后做了什么；
**倒退防护**＝上报回退/迟到时怎么处理；**成本**＝可见集查询与文本排版/重绘方式。

| 项目 | 时间轴来源 | 停顿（buffer stall） | seek 处理 | 倒退/迟到防护 | 成本控制 |
|---|---|---|---|---|---|
| **bytedance/DanmakuRenderEngine**（Android，v0.1.0 tag） | 引擎自有单调时间轴：`queryPlayTime() = (now - mStartTimestamp) * playSpeed/100 + mStartPlayTime`（[DataManager.kt:91-96](https://github.com/bytedance/DanmakuRenderEngine/blob/main/danmaku-render-engine/src/main/java/com/bytedance/danmaku/render/engine/data/DataManager.kt#L91)）；只在 `start(playTime)` 注入一次位置 | **冻结在屏幕原位**：README 映射表 `onBufferStart→pause`，`pause()` 语义「danmakus on the screen will stop in place」；恢复 `onBufferEnd→start(mVideoView.currentPosition)`，**直接按播放器位置对表（snap），不做平滑追赶**（[TimelineSyncActivity.kt:109-110](https://github.com/bytedance/DanmakuRenderEngine/blob/main/demo/src/main/java/com/bytedance/danmaku/render/engine/demo/demo/TimelineSyncActivity.kt#L109)） | README：`onSeekStart→pause`；`onSeekComplete→clear; if (isPlaying) {start}`，注「The screen should be cleared after seek completed」；demo 里是 `clear()` + `start(currentPosition)`（[TimelineSyncActivity.kt:98-101](https://github.com/bytedance/DanmakuRenderEngine/blob/main/demo/src/main/java/com/bytedance/danmaku/render/engine/demo/demo/TimelineSyncActivity.kt#L98)） | 不需要：位置上报根本不参与运动推进。demo 的周期回调 `onProgress(position)`（同文件 81 行）**没有调用 controller**，即周期性 position 报告被完全忽略 | 可见集用**有序游标**推进而非每帧重筛：`queryDanmaku()` 以 `item.showAtTime > mCurrentPlayTime` 为界、`nextDanmakuShowAfter()` 返回下一条的相对时间；排版只对新加入的条目做 `typesetting()`（[DanmakuController.draw()](https://github.com/bytedance/DanmakuRenderEngine/blob/main/danmaku-render-engine/src/main/java/com/bytedance/danmaku/render/engine/control/DanmakuController.kt#L600)）；文本/条目对象带缓冲池复用（`render/cache/DrawCachePool.kt`、`LayerBuffer.kt`），README 明写 DrawItem「will be recycled and reused after it been moved out of the screen」 |
| **bggRGjQaUbCoE/PiliPlus**（Flutter，media_kit）+ 自维护 fork `bggRGjQaUbCoE/canvas_danmaku` | 双层：**引擎** = 自有 `Ticker` 累计毫秒计数（[danmaku_screen.dart:130-131](https://github.com/bggRGjQaUbCoE/canvas_danmaku/blob/main/lib/danmaku_screen.dart#L130)）；**宿主** = media_kit `position` 流，按 100ms 桶取「此刻该出现的弹幕」 | 未 freeze：`playerStatus` 只有 completed/playing/paused（[play_status.dart](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/main/lib/plugin/pl_player/models/play_status.dart)），buffer 是独立 `isBuffering`；stall 期间弹幕**继续按墙钟走**，位置不前进导致同一 100ms 桶被反复命中，由去重挡掉（UNVERIFIED，见 §9 第 3 条） | `seekTo()` 里**先 `danmakuController?.clear()` 再 `seek()`**（[controller.dart:1183-1190](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/main/lib/plugin/pl_player/controller.dart#L1183)）；倍速走 `updateOption(duration: danmakuDuration / speed, staticDuration: ...)`（同文件 1206-1213） | 位置只用于「取哪一批」：100ms 取整 + 相同桶直接 return（[pages/danmaku/view.dart:107-112](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/main/lib/pages/danmaku/view.dart#L107)）；paused 时 `videoPositionListen` 直接 return（同文件 103）；运动侧无任何位置输入，故迟到/回退上报不可能让画面倒退 | 可见集是**预分桶 Map 查表**而非每帧过滤：`getCurrentDanmaku(progress) → return _dmSegMap[progress ~/ 100];`（[pages/danmaku/controller.dart:93-103](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/main/lib/pages/danmaku/controller.dart#L93)）；重绘由 `CustomPaint` + ticker 驱动，不重建 widget 树 |
| **guozhigq/pilipala**（Flutter，media_kit）+ `ns_danmaku`（platform view，fork 自 guozhigq/flutter_ns_danmaku） | 三层：**引擎** `Timer.periodic(1s)` 累加 `_runTime += 1`（仅 running 时）+ 每条一个 `AnimationController`（[danmaku_view.dart:88-90](https://github.com/guozhigq/flutter_ns_danmaku/blob/master/lib/danmaku_view.dart#L88)、同文件 55 行）；**宿主**读 `playerController.position` 流 | 引擎只有 pause/resume 两态，由宿主状态驱动；`PlayerStatus` 不含 buffering，故 stall 期间**继续走**（UNVERIFIED，见 §9 第 3 条） | 切源/换集/画中画 `'show' | 'restart'` 时 `plPlayerController?.danmakuController?.clear()`（[detail/view.dart:334](https://github.com/guozhigq/pilipala/blob/main/lib/pages/video/detail/view.dart#L334)）；播放器初始化处 `danmakuController!.clear()`（[pl_player/controller.dart:409-410](https://github.com/guozhigq/pilipala/blob/main/lib/plugin/pl_player/controller.dart#L409)）；倍速改 `duration: (defaultDuration! / speed) * playbackSpeed`（同文件 665-669） | 位置 100ms 取整 + **相同桶 return**（[pages/danmaku/view.dart:93-99](https://github.com/guozhigq/pilipala/blob/main/lib/pages/danmaku/view.dart#L93)）；状态映射只有 paused→`pause()` / playing→`onResume()`（同文件 81-86），无位置容差逻辑 | 引擎按 `joinTime/outTime` 自行判断入队与出屏（danmaku_view.dart 243-258），轨道用 `_topOutTimes/_bottomOutTimes` 索引表；宿主侧按 100ms 桶 + cid 分段（`queryDanmaku(segmentIndex)`）预取 |
| **Predidit/Kazumi**（Flutter，media_kit + `canvas_danmaku: ^0.3.3`） | 双层：**引擎** = canvas_danmaku 自有 ticker；**宿主** = **1 秒一次**的 `Timer.periodic` 读播放器位置 → `danmakusForPlaybackPosition(position)`（[player_item.dart:1173-1178](https://github.com/Predidit/Kazumi/blob/main/lib/pages/player/player_item.dart#L1173)、同文件 1128-1136） | **不 freeze、不补发**：发射侧在 buffering 时丢弃这一拍（`playerController.playback.playerBuffering` 判据，player_item.dart:1155），画布继续走；恢复后只补「当前这一秒」，停顿时那几秒的弹幕被跳过 | `seekTo()` **先清屏再 seek**：`_danmaku.clearAndInvalidateScheduledDanmakus()` 在 `player.seek()` 之前（[player_seek_controller.dart:47-73](https://github.com/Predidit/Kazumi/blob/main/lib/pages/player/controller/player_seek_controller.dart#L47)）；`seekBy` 只是 `seekTo(current + offset)`（同文件 82-89） | 生成号（generation）+ `Future.delayed` 二次校验：seek 后旧排队的弹幕因 `scheduledDanmakuGeneration` 变化被丢弃（player_item.dart:1150-1161）；运动侧无位置输入 | 可见集是**按秒建 Map**：`danDanmakus[danmakuSecond]` 直查（[player_danmaku_controller.dart:120-126](https://github.com/Predidit/Kazumi/blob/main/lib/pages/player/controller/player_danmaku_controller.dart#L120)）；同秒多条用 `staggerDelayMilliseconds` 错峰（player_item.dart:1146-1152）；文本排版在引擎侧按条建 `TextPainter` |
| **MisaTV**（vendored 只读，`kniephos 1.2.0+13`；上游见 [misatv-borrowings.md](./misatv-borrowings.md) 记为 `yagami-hue/MisaTV`） | **和我们同构**：`CustomPainter` + 自有 `Ticker`，墙钟插值 `_baseSeconds + (DateTime.now()-_baseWall).inMicroseconds/1e6 * _rate`（[danmaku_overlay.dart:231-236](.probe/misatv-src/MisaTV-main/lib/ui/widgets/danmaku_overlay.dart)）；位置只由 `widget.position` 注入，**每次值变化就整体重置基准**（同文件 210-229） | **冻结**：ticker 的开关条件是 `enabled && playing && items.isNotEmpty`，而 `playing` 由调用方传 `_playing && !_buffering && !_resolving`（[player_page.dart:2812](.probe/misatv-src/MisaTV-main/lib/ui/pages/player_page.dart)）；恢复后靠下一条 position 报告重新锚定，**不平滑追赶** | **无显式 seek 概念**：任何 position 变化（含倒退、含 seek）都走同一路径 `_resetClock()` | **唯一的防护是值相等判断**：`widget.position != oldWidget.position` 才重锚（210-219），所以「同一位置重复上报」不会重锚——这一点和我们已修的缺陷 1 同形；但**没有任何容差/单调守卫**：上报一变就照抄，迟到/回退上报会让画面跟着退 | 每帧**线性扫全部条目**（`for (final entry in schedule.entries)`，488-511）；文本用预排 `TextPainter` 存在 `_DanmakuEntry`（459-479）；`RepaintBoundary` + `CustomPainter(repaint: clock)`，`shouldRepaint` 仅在 schedule 身份变化时 true（482、516-517），不重建 widget |
| **weizhenye/Danmaku**（npm `danmaku@2.0.10`，DOM/Canvas 双引擎，web 播放器一类） | **每帧重读播放器**：`ct = media ? media.currentTime : dn`，同时 `dn = RAF 时间戳/1000`；运动用墙钟 `elapsed = totalWidth * (dn - cmt._utc) * pbr / duration`（[engine/index.js](https://cdn.jsdelivr.net/npm/danmaku@2.0.10/src/engine/index.js)） | DOM 事件直接映射：`waiting→pause`、`playing→play`（[internal/events.js](https://cdn.jsdelivr.net/npm/danmaku@2.0.10/src/internal/events.js)）；`play()` 时对**每条仍在上屏的弹幕**重算 `cmt._utc = now()/1000 - (media.currentTime - cmt.time)`（[internal/play.js:11-14](https://cdn.jsdelivr.net/npm/danmaku@2.0.10/src/internal/play.js)）→ 恢复即按播放器位置**逐条重基**，不整体回跳 | `seeking` 事件 → `seek()`：`clear()`（清屏）+ `resetSpace()` + 对 `media.currentTime` 做 **binsearch** 定位 `_position = max(0, position-1)`（[internal/seek.js:8-11](https://cdn.jsdelivr.net/npm/danmaku@2.0.10/src/internal/seek.js)） | 双重：①运动不读位置，位置只决定「该不该开始/该不该移除」；②对前跳留了显式丢弃规则——`ct - cmtt > duration` 的条目 `++position; continue`，源码注释说明这是为了处理「点控制条 seek 时 `currentTime` 早于 `pause` 事件变化」 | 有序游标 + 二分：游标 `_position` 只在「下一条时间 >= ct」处停，seek 时 binsearch；文本在 canvas **预渲染成离屏图片**后每帧 `drawImage`（[engine/canvas.js:30-50、121-122](https://cdn.jsdelivr.net/npm/danmaku@2.0.10/src/engine/canvas.js)） |

> 说明：上表「成本」列只写我在源码里读到的机制。canvas_danmaku 每帧是否 O(n) 遍历全部条目、以及 `findDanmaku` 的实现成本，我**没有读到它的 paint 内部**，见 §9 UNVERIFIED 第 2 条。

---

## 2. 弹幕时间轴来源：四种形态，边界很清楚

1. **引擎自有单调时钟，位置只在事件边界注入一次**（DRE）。`start(playTime)` / `setData(data, current)` 是唯一入口，
   期间靠 `System.currentTimeMillis()` 差分推进，并按 `playSpeed` 缩放。周期性 position 回调**不消费**（demo `onProgress` 不调 controller）。
2. **引擎自有时钟 + 宿主按上报取「该出现谁」**（canvas_danmaku：PiliPlus / Kazumi；pilipala 的 ns_danmaku 同形）。
   引擎只有累计毫秒计数（canvas_danmaku `_ticker` 累加；ns_danmaku `Timer.periodic(1s)` 累加），位置上报只用于查表/建队。
3. **运动与选条都来自播放器读数，但运动用墙钟**（weizhenye/Danmaku）：`ct` 每帧读 `media.currentTime` 决定出入场，
   `dn`（RAF 时间）× `playbackRate` 决定位移；两者用一个 `_utc` 换算对接。
4. **纯插值 + 每次上报重锚**（MisaTV）：与我们当前设计同构，`_baseSeconds/_baseWall/_rate` 三元组，`didUpdateWidget` 里值一变就 `_resetClock()`。

结论：**「每帧重读播放器位置并把运动直接绑上去」这种写法在五个例子里没有一例**。最接近的是 weizhenye，但它把「选条」绑位置、
把「位移」绑墙钟，正是为了不让位置抖动传到屏幕上。

---

## 3. 回调用映射表

### 3.1 DRE 官方 README 的映射表（原文照抄，[README.MD「Play Synchronization」](https://github.com/bytedance/DanmakuRenderEngine/blob/main/README.MD)）

> According to the industry's common implementation logic, the callback of the player and methods of `DanmakuController` are corresponding as following which can be customized to meet specific needs.

| Callback of the Player | DanmakuController | Comment (原文) |
|---|---|---|
| RenderStart | start | |
| VideoPause | pause | |
| VideoResume | start | |
| VideoStop | pause | Let the rest danmakus stay in place after the video is played over |
| VideoReplay | stop | |
| VideoError | pause | |
| onSeekStart | pause | |
| onSeekComplete | clear; if (isPlaying) {start} | The screen should be cleared after seek completed |
| onBufferStart | pause | |
| onBufferEnd | start | |

配套的四个方法语义（README 原注释，实现签名见 [DanmakuController.kt:63/75/83/93](https://github.com/bytedance/DanmakuRenderEngine/blob/main/danmaku-render-engine/src/main/java/com/bytedance/danmaku/render/engine/control/DanmakuController.kt#L63)）：

```
fun start(playTime: Long)  // Play or resume from a paused state.
fun pause()                // Pause and the danmakus on the screen will stop in place.
fun stop()                 // Stop playing which will clear the danmakus on the screen and reset the timeline.
fun clear()                // Clear the danmakus that has been displayed on the screen alone.
```

demo 的实际实现与表一致，但 `onSeekComplete` 在 demo 里是**无条件** start（[TimelineSyncActivity.kt:98-114](https://github.com/bytedance/DanmakuRenderEngine/blob/main/demo/src/main/java/com/bytedance/danmaku/render/engine/demo/demo/TimelineSyncActivity.kt#L98)）：
`onSeekTo: clear() → start(currentPosition)`；`onBufferStart: pause()`；`onBufferEnd: start(currentPosition)`；`onRelease: stop()`；`onVideoCompletion/onVideoError: pause()`。

### 3.2 weizhenye/Danmaku 的映射（源码即表）

`bindEvents()`（[internal/events.js](https://cdn.jsdelivr.net/npm/danmaku@2.0.10/src/internal/events.js)）把 DOM 媒体事件直接绑到三个内部函数：

| DOM 事件 | 内部函数 | 效果 |
|---|---|---|
| `play` | `play()` | 恢复 RAF 循环，并对上屏条目逐条重算 `_utc` |
| `playing` | `play()` | 同上（缓冲结束走这条） |
| `pause` | `pause()` | `cancelAnimationFrame`，画面原地冻结 |
| `waiting` | `pause()` | 缓冲开始＝冻结 |
| `seeking` | `seek()` | `clear()` + `resetSpace()` + binsearch 重定位游标 |

倍速不单独映射事件：`pbr = media.playbackRate` 每帧读，直接乘进位移。

### 3.3 Flutter 三家的映射（各自的实际 listener）

- **PiliPlus**：状态监听 `if (status.isPlaying) controller.resume(); else controller.pause();`（[lib/pages/danmaku/view.dart:85-88](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/main/lib/pages/danmaku/view.dart#L85)）；
  位置监听 `if (!playerController.playerStatus.isPlaying) return;` → 100ms 取整 → 去重 → `getCurrentDanmaku()`（同文件 103-115）；
  seek 在播放器侧 `clear()` → `seek()`（[pl_player/controller.dart:1183-1190](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/main/lib/plugin/pl_player/controller.dart#L1183)）；倍速改 option 的 duration（同文件 1206-1213）。
- **pilipala**：`status == PlayerStatus.paused → _controller!.pause()`；`status == PlayerStatus.playing → _controller!.onResume()`（[lib/pages/danmaku/view.dart:81-86](https://github.com/guozhigq/pilipala/blob/main/lib/pages/danmaku/view.dart#L81)）；
  位置 → 100ms 取整 → 去重 → `_plDanmakuController.getCurrentDanmaku()`（同文件 89-102）；切源/PiP/初始化处 `clear()`（[detail/view.dart:334](https://github.com/guozhigq/pilipala/blob/main/lib/pages/video/detail/view.dart#L334)、[pl_player/controller.dart:409](https://github.com/guozhigq/pilipala/blob/main/lib/plugin/pl_player/controller.dart#L409)）。
- **Kazumi**：`pause()` → `danmaku.canvasController.pause()`，恢复 → `.resume()`（[player_controller.dart:350-371](https://github.com/Predidit/Kazumi/blob/main/lib/pages/player/player_controller.dart#L350)）；
  seek → `clearAndInvalidateScheduledDanmakus()` 先于 `player.seek()`（[player_seek_controller.dart:47-73](https://github.com/Predidit/Kazumi/blob/main/lib/pages/player/controller/player_seek_controller.dart#L47)）；1s tick 里发射（player_item.dart:1173-1178）。
- **MisaTV**：没有映射表，也没有事件语义。调用方只传四个值：`position`、`playing: _playing && !_buffering && !_resolving`、`rate`、`enabled`（[player_page.dart:2803-2819](.probe/misatv-src/MisaTV-main/lib/ui/pages/player_page.dart)）。

---

## 4. 上报回归/迟到：谁在结构上不可能倒退

| 项目 | 若位置上报回退 200ms 会发生什么 | 机制 |
|---|---|---|
| DRE | 屏幕无变化 | 运动 = `anchor + (now - startTimestamp) * rate`，上报根本没进入这条路径 |
| PiliPlus | 屏幕无变化；最多重复命中同一 100ms 桶被去重挡掉 | 运动由 ticker 决定；100ms 桶 + `latestAddedPosition` 去重 |
| pilipala | 同上 | 同上（`currentPosition % 100` + `latestAddedPosition`） |
| Kazumi | 屏幕无变化；下一次 1s tick 只是又查了同一个秒 | `danDanmakus[second]` 直查；已上屏条目不受影响 |
| weizhenye | 「选条游标」可能重复，但上屏条目位置不变 | `_utc` 在条目入屏时算定；位移用 `dn - _utc`，与位置上报无关 |
| **MisaTV** | **整层重锚，画面跟着退（无守卫）** | `widget.position != oldWidget.position` → `_resetClock()`；`_baseWall = DateTime.now()`，`_baseSeconds = position` |

对我们的两个缺陷逐条对齐（**结构性避免** ≠ 修好了）：

- **缺陷 1「同一位置重复上报导致重锚（可能倒退）」**
  - 完整避免：DRE / PiliPlus / pilipala / Kazumi / weizhenye —— 上报不是运动输入。
  - 同形防护（靠值相等跳过）：MisaTV `didUpdateWidget`（210-219）；我们 `danmaku_motion.dart:139` 的 `if (reported == previous) return;` 与它是同一手法。
- **缺陷 2「落后插值 >120ms 的上报被当 seek、把画面拉回」**
  - 完整避免：DRE / PiliPlus / pilipala / Kazumi / weizhenye —— 运动侧不接受「把插值拉回去」这种操作。
  - weizhenye 是唯一处理「前跳带来的陈旧条目」的：直接丢弃 `ct - cmtt > duration` 的条目而不是回放。
  - **MisaTV 完全没有这一层**：迟到上报（值不同）必然重锚，正是缺陷 2 的形态；它「不显倒退」的前提是播放器画面同时退了（互相一致，不是守卫）。

---

## 5. buffer stall：三种做法，恢复都不平滑

| 做法 | 谁 | 证据 |
|---|---|---|
| **冻结在原地，恢复即按播放器位置 snap** | DRE | README `onBufferStart→pause`（stop in place）、`onBufferEnd→start(currentPosition)`（[TimelineSyncActivity.kt:105-110](https://github.com/bytedance/DanmakuRenderEngine/blob/main/demo/src/main/java/com/bytedance/danmaku/render/engine/demo/demo/TimelineSyncActivity.kt#L105)） |
| **冻结在原地，恢复时逐条重基到播放器位置** | weizhenye/Danmaku | `waiting→pause`、`playing→play`；`play()` 对 `runningList` 每条重算 `_utc`（[internal/play.js:11-14](https://cdn.jsdelivr.net/npm/danmaku@2.0.10/src/internal/play.js)）——比整体 snap 细，但仍是一次对齐、不追赶 |
| **不冻结，继续走；恢复后只补当前这一拍** | Kazumi / PiliPlus / pilipala | Kazumi：缓冲时丢弃发射（player_item.dart:1155），画布不停；PiliPlus/pilipala：`PlayerStatus` 不含 buffering（[play_status.dart](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/main/lib/plugin/pl_player/models/play_status.dart)），stall 时仍是 playing → 引擎照走（UNVERIFIED，见 §9 第 3 条） |

**没有一例做「渐变追赶」**（把落后量按时间摊平）。它们的取舍是：要么冻结（可接受一次性对齐），要么让墙钟继续跑（可接受一段时间错位，
恢复时靠「只补当前窗口」把错位一次性收掉）。

顺带一条与「我们残留 ~600ms 永久超前」相关的事实：这些实现里**不存在「永久超前」这种状态**——DRE 与 weizhenye 在每次事件边界都把基准
钉回播放器读数（`start(currentPosition)` / `_utc` 重算），PiliPlus/pilipala/Kazumi 的位移根本不由播放器读数决定。代价则是它们对**起播时刻**
的精度受上报节奏限制：Kazumi 是 1 秒粒度、PiliPlus/pilipala 是 100ms 桶（这解释了它们为什么需要 stagger/密度控制）。

---

## 6. 显式 seek 信号 vs 阈值推断（决定我们 `backwardSeekFloorMs` 是否有先例）

| 项目 | seek 的入口 | 是否用「位置差值幅度」判断 seek |
|---|---|---|
| DRE | 播放器 `onSeekStart` / `onSeekComplete` 两个信号，弹幕侧 `pause()` + `clear()` + `start(newPos)` | **否** |
| weizhenye | DOM `seeking` 事件 | **否**（事件即真相） |
| PiliPlus | `seekTo()` 方法（`clear()` 在 `player.seek()` 之前） | **否** |
| pilipala | `seekTo()` / 切源 clear | **否** |
| Kazumi | `seekTo()` / `seekBy()`（都归一到 `seekTo`），先清屏后 seek | **否** |
| MisaTV | 无 seek 入口；靠 position 变化重锚 | **否**（连阈值都没有，全量接受） |

**这条是本轮最干净的一手结论**：六个项目里没有任何一份把「位置倒退了 N 毫秒」当作 seek 判据。
凡是能拿到显式信号的都走信号；MisaTV 拿不到信号，就干脆不做区分（一切变化都重锚）。
换句话说，`backwardSeekFloorMs = 1000` 这类**幅度阈值判定 seek** 的做法在调研样本中没有先例；
有先例的只有「显式 seek 信号 ↔ 弹幕清屏/重锚」这一对（[apps/desktop-flutter/lib/core/danmaku_motion.dart:46](apps/desktop-flutter/lib/core/danmaku_motion.dart) 是我们的实现侧，不是先例）。

同时要注意：**所有播放器侧实现都在 seek 时清屏**（DRE README 明写「The screen should be cleared after seek completed」）。
我们「seek 不清屏」是偏离主流的选择，见 §8.1。

---

## 7. 成本控制：四种可复用的模式

1. **有序游标（不再重筛）**：DRE `queryPlayTime/queryDanmaku/nextDanmakuShowAfter` 用 `mCurrentIndex` 前进；weizhenye 用 `_position` 游标 + 只在 seek 时 `binsearch`。
2. **预分桶查表（O(1)）**：PiliPlus `_dmSegMap[progress ~/ 100]`；Kazumi `danDanmakus[danmakuSecond]`；pilipala 同 PiliPlus（100ms 桶 + cid 分段）。这是「按时间轴预规划可见集」的另一种实现。
3. **文本/绘制对象缓存**：DRE 的 `DrawCachePool` + DrawItem 复用（README 明写 recycled/reused）；weizhenye 把每条弹幕**预渲染成离屏 canvas** 再 `drawImage`（engine/canvas.js:30-50、121-122）；MisaTV 预排 `TextPainter` 存进 `_DanmakuEntry`。
4. **重绘但不重建 widget 树**：MisaTV `RepaintBoundary` + `CustomPainter(repaint: clock)` + `shouldRepaint` 只在 schedule 变；canvas_danmaku 由 ticker 值驱动的 painter；DRE 直接在 `View.draw(canvas)` 里画。

反面样本也很清楚：MisaTV 每帧线性扫**全部**条目（488-511）——条目量级小时可接受，是它没有二分/游标的直接代价。

---

## 8. 我们哪里确实不同，以及现有规则被什么支持

### 8.1 处境差异（事实层）

| 维度 | 我们的情况 | 样本里的情况 |
|---|---|---|
| 平台/内核 | Flutter desktop + media-kit/libmpv（[apps/desktop-flutter/lib/core/danmaku_motion.dart](apps/desktop-flutter/lib/core/danmaku_motion.dart)） | 移动/桌面 Flutter（canvas_danmaku、ns_danmaku）、Android native（DRE）、浏览器 DOM/Canvas（weizhenye）、Flutter 桌面（MisaTV） |
| seek 时是否清屏 | **不清屏**（期望画面连续） | 除 MisaTV 外**都清屏**（DRE README、weizhenye `seek()` 首行 `clear()`、PiliPlus `clear()`→`seek()`、Kazumi `clearAndInvalidateScheduledDanmakus()`→`seek()`） |
| 位置上报可信度 | 任意 spider 源，无统一 seek 事件语义、上报可能迟到/回退 | media_kit/MediaPlayer/HTMLMediaElement 都有明确事件；MisaTV 用 video_player |
| 上报节奏 | 周期性 position stream | 1s tick（Kazumi、ns_danmaku）、100ms 桶（PiliPlus/pilipala）、每帧读（weizhenye）、事件驱动（DRE） |

### 8.2 一手证据 settle 了什么

1. **运动不该由上报驱动**：五个引擎里四个把运动交给自有时钟，只有 MisaTV 把两者绑死——而 MisaTV 正是唯一没有倒退守卫的实现。
2. **seek 用信号、不用幅度**：见 §6，无先例支持阈值判定；有先例的是「显式 seek 信号 → 清屏/重锚」。
3. **停顿恢复一定是一次性对齐**（freeze→snap、freeze→逐条重基、或 keep-run→只补当前窗口），没有渐变追赶的先例。
4. **可见集应当预规划**：游标 / 分桶 / 二分三种都在用，没有一例每帧重筛+重排。

### 8.3 现有规则分别被什么支持（只陈述支持关系，不提改法）

| 我们的规则（位置） | 先例支持情况 |
|---|---|
| 重复上报不重锚（`danmaku_motion.dart:139`） | **同形先例**：MisaTV 值相等判断（210-219）；更强的先例：另四份根本不消费上报。PiliPlus/pilipala 在发射层做同类去重（100ms 桶去重） |
| 小幅倒退不回退（`_reconcile` 的 `reported > live ? reported : live`，195-202） | **方向一致、无同形先例**：没有实现需要这条规则，因为它们不把上报喂给运动。可视为「用自己的方式达成它们免费获得的性质」 |
| 120ms 重锚容差（`reanchorToleranceMs`，38） | **无先例**（没有实现做重锚容差）。属于本仓库自有参数 |
| 600ms 外插上限（`maxExtrapolationMs`，35） | **无先例**：DRE/MisaTV 的外插无上界（DRE 靠事件纠偏，MisaTV 靠下一条上报纠偏）。这是本仓库为「上报不可靠」付的对价 |
| `backwardSeekFloorMs = 1000` 幅度判定 seek（46） | **与全部先例相反**：所有能拿到显式 seek 信号的实现都走信号（§6）。这条规则在样本中唯一的结构性功能是「在没有 seek 信号时区分抖动」——MisaTV 干脆不区分 |
| seek 不清屏 | **与主流相反**：除 MisaTV 外都清屏；唯一不靠清屏的先例是 weizhenye 的**逐条 `_utc` 重基**（play.js:11-14 在恢复时对每条上屏弹幕重算基准）——这是「不清屏也能对齐」在样本里唯一被写下来的机制 |
| 残留 ~600ms 永久超前 | **无先例可对照**：它们的位移不来自播放器读数，故不存在「超前」这个状态量；反过来它们对起播时刻的精度受上报节奏限制（1s / 100ms） |

---

## 9. UNVERIFIED 清单（未能从一手源确认的项）

1. **全部仓库的 commit SHA**：GitHub REST API 403 rate limit，取不到 HEAD；锚点只有「分支 + 行号 + 2026-11-23」。
   受影响仓库：bytedance/DanmakuRenderEngine、bggRGjQaUbCoE/{PiliPlus,canvas_danmaku}、guozhigq/pilipala、Predidit/Kazumi、weizhenye/Danmaku。
2. **canvas_danmaku 每帧的遍历成本**：`_tick` 只更新毫秒计数（130-131），但 `paint` 是否对全部条目线性扫描、`findDanmaku` 是否二分，我未读到 painter 内部 → UNVERIFIED。
3. **PiliPlus / pilipala 的 buffer stall 是否有别处补偿**：`PlayerStatus` 枚举不含 buffering（play_status.dart），`isBuffering` 是独立 `RxBool`
   （PiliPlus pl_player/controller.dart:1102-1103 订阅 `stream.buffering`）；我未找到把 `isBuffering` 接到弹幕 pause 的代码，故「stall 时继续走」
   是从「枚举不含 buffering」推出的结论，**实现层未直接读到对应 pause 调用** → 该结论标 UNVERIFIED。
4. **PiliPlus `lib/plugin/pl_player/view.dart` 未能读取**（raw 与 jsDelivr 均 404，但文件在目录列表中）：故 PiliPlus 侧「谁把 `controller.pause/resume` 与状态连接」以 `lib/pages/danmaku/view.dart` 为准，`view.dart` 内的同类代码未核对。
5. **ns_danmaku 的 `_runTime` 与播放倍速的关系**：`_runTime += 1` 是墙钟秒，未见乘 rate（danmaku_view.dart:88-90）；倍速改的是 `duration`
   （pilipala pl_player/controller.dart:665-669）。两者叠加后的实际视觉倍速我未验证 → UNVERIFIED。
6. **DRE 的「Play Synchronization 表」是规范还是建议**：README 原文写「which can be customized to meet specific needs」，即**建议**而非强制；demo 的 `onSeekComplete` 就与表中 `if (isPlaying)` 不一致（无条件 start）→ 表述为「官方建议 + demo 实现」。
7. **MisaTV 上游身份**：`yagami-hue/MisaTV` 来自本仓库既有的 [docs/reference/misatv-borrowings.md](./misatv-borrowings.md)，我未独立访问上游仓库；本文 MisaTV 引用全部以 vendored 只读副本为准（`kniephos 1.2.0+13`）。
8. **本仓库是否已有显式 seek 信号可用**：本文没有审计我们自己的 player→弹幕调用链（超出本任务边界），故 §6 只说明「先例都走信号」，不判断我们**是否拿得到**信号。

---

## 10. 来源清单（URL + 版本 + 读到的锚点）

**bytedance/DanmakuRenderEngine**（分支 `main`，唯一 tag `v0.1.0`，已归档）
- https://github.com/bytedance/DanmakuRenderEngine/blob/main/README.MD —「## Timeline Synchronization」「### Play Synchronization」表、四个方法注释、DrawItem 复用说明
- `danmaku-render-engine/.../data/DataManager.kt` — `onPlay`(70)、`onPlaySpeedChanged`(85)、`queryPlayTime`(91-96)、`onPause`(138)、`onStop`(143)、`queryDanmaku`/`nextDanmakuShowAfter`
- `danmaku-render-engine/.../control/DanmakuController.kt` — `start`(63)、`pause`(75)、`stop`(83)、`clear`(93)、`setData`(131)、`draw()`
- `demo/.../demo/TimelineSyncActivity.kt` — `onVideoStart`(71)、`onVideoPause`(76)、`onProgress`(81)、`onSeekTo`(98-101)、`onBufferStart/End`(105-110)、`onRelease`(113-114)
- `danmaku-render-engine/.../render/cache/DrawCachePool.kt`、`render/cache/LayerBuffer.kt`（存在性 + README 表述）

**bggRGjQaUbCoE/PiliPlus**（分支 `main`）
- `pubspec.yaml` — `canvas_danmaku: url: https://github.com/bggRGjQaUbCoE/canvas_danmaku.git`
- `lib/pages/danmaku/view.dart` — 状态→pause/resume(85-88)、位置监听(94-115)、100ms 去重(107-112)
- `lib/pages/danmaku/controller.dart` — `getCurrentDanmaku`(93-103)、分段预取 `queryDanmaku`(38-)
- `lib/plugin/pl_player/controller.dart` — `seekTo`+`clear()`(1183-1190)、倍速改 duration(1198-1216)、`stream.playing`→playerStatus(1032-1054)、`stream.buffering`(1102-1103)
- `lib/plugin/pl_player/models/play_status.dart` — `enum PlayerStatus {completed, playing, paused}`

**bggRGjQaUbCoE/canvas_danmaku**（分支 `main`；Kazumi 用 pub `^0.3.3`，PiliPlus 用该 fork）
- `lib/danmaku_controller.dart` — 只有 addDanmaku/updateOption/pause/resume/clear/...，**无 seek**
- `lib/danmaku_screen.dart` — `createTicker`(84)、`_tick`(130-131)、`_pause`(279-286)、`_resume`(289-296)、`_clear`(299-307)、条目到期移除(455/460)

**guozhigq/pilipala**（分支 `main`）
- `pubspec.yaml` — `ns_danmaku: url: https://github.com/guozhigq/flutter_ns_danmaku.git`
- `lib/pages/danmaku/view.dart` — 状态映射(81-86)、位置监听(89-102)、100ms 取整+去重(93-99)
- `lib/pages/video/detail/view.dart` — `danmakuController?.clear()`(334)、`PlDanmaku(...)`(524-526)
- `lib/plugin/pl_player/controller.dart` — `danmakuController!.clear()`(409-410)、`seekTo`(627)、倍速 duration(665-669)

**guozhigq/flutter_ns_danmaku**（分支 `master`）
- `lib/danmaku_controller.dart` — pause/resume/clear/addItems/updateOption 转发
- `lib/danmaku_view.dart` — `Timer.periodic(1s)` + `_runTime += 1`(88-90)、per-item `AnimationController`(55)、`joinTime/outTime`(152-159)、`pause()`→`stop()`(333-337)、`resume()`→`forward()`(342-346)、`clear()`(351-)

**Predidit/Kazumi**（分支 `main`，`canvas_danmaku: ^0.3.3`）
- `lib/pages/player/player_controller.dart` — `danmaku.canvasController.pause()`(353)、`.resume()`(371)、`updateDanmakuSpeed`(317-318)
- `lib/pages/player/controller/player_seek_controller.dart` — `seekTo`: 清屏(58) → `player.seek`(65) → `onSeekCompleted`(73)；`seekBy`(82-89)
- `lib/pages/player/controller/player_danmaku_controller.dart` — `danmakusForPlaybackPosition`(120-126)、`clearAndInvalidateScheduledDanmakus`(133-136)、`updateDanmakuSpeed`(328-334)
- `lib/pages/player/player_item.dart` — 1s tick(1173-1178)、`_emitDanmakusForCurrentPosition`(1128-1171)、stagger(1146-1152)、generation 二次校验(1150-1161)
- `lib/pages/player/controller/player_playback_controller.dart` — `playerBuffering`(187-189)

**MisaTV（vendored 只读，`kniephos 1.2.0+13`）**
- `.probe/misatv-src/MisaTV-main/lib/ui/widgets/danmaku_overlay.dart` — 性能注释(144-152)、`_clockMs/_ticker`(191-204)、`didUpdateWidget` 重锚(210-221)、`_resetClock`(223-229)、`_onTick`(231-236)、`_syncTicker`(238-246)、`_DanmakuEntry`(459-479)、`_DanmakuPainter`(481-518)
- `.probe/misatv-src/MisaTV-main/lib/ui/pages/player_page.dart` — `DanmakuOverlay(...)` 参数(2803-2819)，其中 `playing: _playing && !_buffering && !_resolving`(2812)
- `.probe/misatv-src/MisaTV-main/pubspec.yaml` — `name: kniephos` / `version: 1.2.0+13`

**weizhenye/Danmaku（npm `danmaku@2.0.10`）**
- 包内源码（jsDelivr 直取已发布 tarball，行号即该版本）：
  - https://cdn.jsdelivr.net/npm/danmaku@2.0.10/src/internal/events.js — 事件绑定表
  - https://cdn.jsdelivr.net/npm/danmaku@2.0.10/src/internal/play.js#L11-L14 — 恢复时逐条 `_utc` 重基 + RAF 循环
  - https://cdn.jsdelivr.net/npm/danmaku@2.0.10/src/internal/pause.js — `cancelAnimationFrame`
  - https://cdn.jsdelivr.net/npm/danmaku@2.0.10/src/internal/seek.js#L8-L11 — `clear()` + `resetSpace()` + binsearch
  - https://cdn.jsdelivr.net/npm/danmaku@2.0.10/src/engine/index.js — `ct = media.currentTime`、`dn = RAF`、`elapsed = ... * pbr`、陈旧条目跳过规则
  - https://cdn.jsdelivr.net/npm/danmaku@2.0.10/src/engine/canvas.js#L30-L50 — 文本预渲染离屏 canvas、`drawImage`
- 上游仓库（README 指向）：https://github.com/weizhenye/Danmaku ；在线 demo/文档：https://danmaku.js.org/

**本仓库（对照用，非改动对象）**
- `apps/desktop-flutter/lib/core/danmaku_motion.dart` — `maxExtrapolationMs`(35)、`reanchorToleranceMs`(38)、`backwardSeekFloorMs`(46)、重复上报 return(139)、`_reconcile`(190-203)、`_reconcileRelease`(150-179)
- `docs/reference/misatv-borrowings.md` — MisaTV 上游身份与既有调研基线
