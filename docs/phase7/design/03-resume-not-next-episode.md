# 03 · 缓存耗尽与「续播 vs 跳下一集」

- 状态：设计指导，**待评审**
- 日期：2026-10-17
- 上游参考：`PlaybackService.listener.onPlaybackStateChanged`、`VideoActivity.onStateChanged/onError/checkEnded`、
  `PlayerManager.onPlayerError`、`HttpEofRecoveryDataSource`、`PlaybackRecord.completed`、
  `History.save`、`PlaybackEventCollector`
- PC 参考：`lib/ui/player_page.dart`（`_onCompleted` / `_playNext` / `_persistProgress`）、
  `lib/ui/player_controller.dart`（`_completed` / `open`）、
  `lib/services/storage.dart`（`upsertHistory`）、`lib/state/app_state.dart`（`resumePositionFor`）
- 关联：`00`（§3.5、§4 P5）、`01`（历史同步）、`02`（唤醒）、`04`（测试与验收）

---

## 1. 问题陈述

用户实测：

> 在播放的视频缓存用完后也会播放失败，这个时候再唤醒安卓版点击继续播放不会续播
> 而是直接跳到下一集播放了

拆成三个独立现象：

| # | 现象 | 可能的成因 |
| --- | --- | --- |
| S1 | 缓存用完后**播放失败** | 缓存耗尽 + 源站限速/断流 + `HttpEofRecoveryDataSource` 重连上限 3 次 |
| S2 | 唤醒后**不续播** | 进度未写 / 进度被判完播 / 请求被换成了另一集 |
| S3 | **直接跳到下一集** | 播放器报 `completed`（含提前 EOF）→ 自动连播触发 |

**关键判断**：S3 是 S2 的**因**，不是并列现象。只要自动连播被误触发，
`episodeIndex` 与 `episodeTarget` 就被换成下一集、`startPosition` 被清空，
"续播"在物理上已不可能。因此本设计**先修 S3**。

---

## 2. 上游契约（源码级）

### 2.1 安卓侧的"播完 → 下一集"链路

| 事实 | 证据 | 等级 |
| --- | --- | --- |
| `PlaybackService.listener.onPlaybackStateChanged(STATE_ENDED)`：若无人接管导航则 `navigateItem(1)` | `PlaybackService` | 源码 |
| `VideoActivity.onStateChanged(STATE_ENDED)` → `checkEnded(true)` → `checkNext` → `onNext` → `onItemClick(item)` | `VideoActivity:6066-6072` | 源码 |
| **`checkEnded` 只转发到 `checkNext`，不校验 position/duration** | `VideoActivity:7846-7848` | 源码 |
| `resolveInitialPlaybackPosition()` **有** `isNearEnding()` 保护（重置位置） | `VideoActivity:11919-11928` | 源码 |
| 但 `isNearEnding()` **只**保护"续播位置"，**不**保护"是否切下一集" | 上两行对比 | 源码 |
| `PlayerManager.onPlayerError` **不设置** `STATE_ENDED`；它走 `fallbackPlayback` → `callback.onError` | `PlayerManager` | 源码 |
| `VideoActivity.onError` 会 `player().reset(); player().stop();` 然后 `startFlow()`（自动换线路/换源），**不**切下一集 | `VideoActivity.onError` | 源码 |
| `PlaybackRecord.completed = position >= duration \|\| progress >= 0.95` | `PlaybackRecord:403-407` | 源码 |
| `PlaybackEventCollector` 在 `STATE_ENDED` 时 `sendFinalThen(record, ENDED)` 并 `resetStarted()` | `PlaybackEventCollector` | 源码 |
| `HttpEofRecoveryDataSource` 只允许**连续** 3 次重连，超过则抛 `IOException` | `HttpEofRecoveryDataSource:24` | 源码 |
| 缓存用 `CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR`（缓存读失败直接回源，不报错） | `MediaSourceFactory.getCacheDataSource` | 源码 |

> **安卓侧的结论（已修正）**：**播放错误**不会变成"跳下一集"（`onError` 路径是
> "重置 + 自动换线路/换源"）。**但** `STATE_ENDED` 路径**也没有**"真播完"闸门——
> `checkEnded` 无条件 `checkNext`。
>
> 因此若**提前 EOF** 让 media3 报出 `STATE_ENDED`（服务端声明长度 == 实际可读长度时
> media3 认为是正常结束），安卓会**直接切下一集**。
>
> **两个嫌疑同时存在**（PC 侧 D1/D2 与安卓侧无闸门），必须用 §3 的实验区分。

### 2.2 提前 EOF 是否会导致 `STATE_ENDED`

| 事实 | 证据 | 等级 |
| --- | --- | --- |
| 固定长度 HTTP 响应被截断时，`HttpEofRecoveryDataSource` 会**在未读偏移重开**，最多连续 3 次 | `HttpEofRecoveryDataSource` | 源码 |
| 超过 3 次后抛 `IOException` → media3 报 `ERROR_CODE_IO_UNSPECIFIED` → `retryFormat` → 最终 `onError` | `ExoPlayerEngine.handleError` | 源码 |
| 但若截断发生在**已知总长度之外**（服务端声明长度 = 实际可读长度），media3 会认为**正常结束** → `STATE_ENDED` | media3 语义（非本项目源码） | 推断 |

> **必须实测确认**（`§3` 的判定实验）：提前 EOF 到底走 `onError` 还是 `STATE_ENDED`。
> 这决定了修复重心在 PC 侧（若 PC 侧误触发）还是安卓侧（若安卓侧误报 ENDED）。

### 2.3 PC 侧的"播完 → 下一集"链路（**已定位缺陷**）

| 事实 | 证据 | 等级 |
| --- | --- | --- |
| `_controller.isCompleted` 直接来自 media_kit 的 `stream.completed` | `player_controller.dart` `_bind()` | 源码（PC） |
| `build()` 里：`if (_controller.isCompleted) { addPostFrameCallback((_) { if (mounted) _onCompleted(); }); }` | `player_page.dart` | 源码（PC） |
| `_onCompleted()` → `_playNext()` | `player_page.dart` | 源码（PC） |
| `_playNext()` → `_openTarget(..., clearStartPosition: true)` | `player_page.dart` | 源码（PC） |
| `_openTarget` 写入 `_request.copyWith(episodeIndex: next, episodeTarget: ..., clearStartPosition: true)` | `player_page.dart` | 源码（PC） |
| `_persistProgress()` 用 `_request.episodeTarget` 作为 `episodeId` 落库 | `player_page.dart` | 源码（PC） |
| `upsertHistory` 的 `completed = positionMs >= durationMs - 5000`（`durationMs>0` 时） | `storage.dart` | 源码（PC） |
| `resumePositionFor` 在 `record.completed` 为真时返回 `null` | `app_state.dart` | 源码（PC） |

**三个具体缺陷**：

#### D1 · 触发点在 `build()` 里，是**重建驱动**而不是**事件驱动**

```dart
// player_page.dart（现状）
if (_controller.isCompleted) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) _onCompleted();
  });
}
```

`_controller` 是 `ChangeNotifier`，`_onControllerChanged` 会 `setState`。
因此**任何一次通知**（position/duration/buffer/volume/... 每秒多次）只要
`isCompleted` 仍为 `true`，就会再排一个 `_onCompleted()`。

后果：

- 若 `_playNext()` 因任何原因**没有**把 `_completed` 复位（例如 `next < 0`、
  `_openTarget` 提前返回、下一集加载失败），`_completed` 保持 `true`，
  后续每次重建都会**再跳一次**；
- 用户"唤醒后点继续播放"这个动作本身就会触发重建 → 立即跳下一集。

**这就是用户现象 S3 的**最可能**成因。**

#### D2 · 把 media_kit 的 `completed` 当成"真的播完了"

media_kit 的 `completed` 表示"播放到达流末尾"，**不区分**：

- 正常播到片尾；
- 提前 EOF（缓存耗尽、源站断流、CDN 截断）。

PC 侧没有任何位置/时长校验就据此连播。

#### D3 · 失败路径不复位 `_completed`，也不保留续播上下文

`_load()` 失败时只 `setState(() => _loadError = ...)`，**不**复位 `_completed`。
而 `_request` 已经被 `_openTarget` 改成下一集（`episodeIndex` 已 +1、
`clearStartPosition: true`）。于是：

- 续播上下文（原集 + 原进度）**已丢失**；
- `_completed` 仍为 `true` → 继续触发连播。

---

## 3. 判定实验（实施前必须跑，回答 `00` §9 的 O3）

目标：确定"跳下一集"发生在**哪一侧**。三个实验独立，结果回填 `docs/phase7/evidence/`。

### 3.1 实验 A：PC 侧是否误触发（**优先级最高**）

```powershell
# 1) 用 PC 播放一集，把进度拖到接近片尾（例如 duration-10s）
# 2) 断开该集的数据源（防火墙屏蔽 CDN 域，或把 PC 网卡禁用 5 s 再恢复）
# 3) 观察日志
```

**看什么**：

| 观察 | 结论 |
| --- | --- |
| 日志出现 `播放结果 ... succeeded=false` 且**没有**切集 | 失败路径正常（D3 未触发） |
| 日志出现 `播放结果 ... succeeded=true` 且随后切到下一集 | **D1/D2 确认**：提前 EOF 被当成播完 |
| `_loadError` 出现但 `_request.episodeIndex` 已 +1 | **D3 确认** |

**PC 侧已有的可观测点**（无需新增埋点）：

- `state.log.info('播放结果 ${outcome.summary}', scope: 'player')`（`player_page.dart`）
- `state.log.info('播放诊断 ${diagnostics.logLine}', scope: 'diagnostics')`
- `state.log.info('恢复播放进度 episode=... position=...ms', scope: 'player')`
- `state.log.error('切换剧集失败 ${failure.logLine}', scope: 'player')`

### 3.2 实验 B：安卓侧是否误报 `STATE_ENDED`

```powershell
# 1) 安卓播放一集，拖到接近片尾
# 2) 用 adb 断网（模拟缓存耗尽后无法回源）
adb -s 192.168.50.3:5559 shell svc wifi disable
Start-Sleep -Seconds 20
adb -s 192.168.50.3:5559 shell svc wifi enable
# 3) 抓日志
adb -s 192.168.50.3:5559 logcat -d -s playback-flow playback-lifecycle player exo-cache playback-remote-sync
```

**看什么**：

| 日志 | 结论 |
| --- | --- |
| `playback-flow ... ENDED` 或 `audio-auto-next ... action=browse-next` | 安卓侧报 `STATE_ENDED`（§2.2 的推断成立） |
| `player error code=... http=... action=...` 且随后 `startFlow` 相关日志 | 安卓侧走 `onError`（正常） |

### 3.3 实验 C：历史记录里的 `completed` 是哪一侧写的

```sql
-- PC 侧（SQLite）
SELECT site_key, vod_id, episode_name, position_ms, duration_ms, completed, updated_at
FROM history ORDER BY updated_at DESC LIMIT 10;
```

```powershell
# 安卓侧：读一条记录
curl.exe "http://192.168.50.3:9978/api/playback/current?siteKey=<key>" -H "Host: 192.168.50.3:9978" -s
```

**看什么**：若 PC 侧 `completed=1` 但 `position_ms < duration_ms - 5000`，
说明 `completed` 不是由 `upsertHistory` 的公式写的（公式不会这样），
而是**从安卓同步过来的**（`SyncHistoryItem.completed` 用的是同一个公式，
所以也只能是安卓侧 `PlaybackRecord.completed` 的 `progress >= 0.95` 分支）。

---

## 4. PC 侧修复设计

### 4.1 修复 D1：事件驱动 + 单次守卫

**现状**（`player_page.dart`）：

```dart
if (_controller.isCompleted) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) _onCompleted();
  });
}
```

**改为**：

```dart
// 1) 连播改由控制器事件驱动（在 initState 里订阅一次）
_controller.addListener(_onControllerChanged);

void _onControllerChanged() {
  if (!mounted) return;
  setState(() {});
  _maybeAdvanceOnGenuineEnd();   // 只在"真播完"时推进
}

// 2) 单次守卫 + 真播完判定
bool _advanceInFlight = false;

void _maybeAdvanceOnGenuineEnd() {
  if (_advanceInFlight) return;                 // 防重入（D1）
  if (!_controller.isCompleted) return;
  if (!_isGenuineEnd()) return;                 // 防提前 EOF（D2）
  _advanceInFlight = true;
  unawaited(_playNext().whenComplete(() {
    _advanceInFlight = false;
  }));
}

/// "真播完"判定：位置与时长的双重校验，不信任 media_kit 的 completed 单独结论。
///
/// 与 `SyncHistoryItem.completed` / 安卓 `PlaybackRecord.completed` 的语义对齐
/// （`00` §4 P5）：`duration > 0 && position >= duration - END_MARGIN`。
bool _isGenuineEnd() {
  final duration = _controller.duration;
  final position = _controller.position;
  if (duration <= Duration.zero) return false;    // 时长未知 → 不是播完
  return position >= duration - endMargin;        // endMargin = 5 s
}

static const Duration endMargin = Duration(seconds: 5);
```

**为什么 `duration <= 0` 必须返回 `false`**：缓存耗尽时 `duration` 可能尚未
取到（或为 0），此时 `completed` 若为 `true` 一定是误报。

### 4.2 修复 D2：`completed` 的跨端统一语义

| 侧 | 判定 | 现状 | 本轮 |
| --- | --- | --- | --- |
| PC `upsertHistory` | `durationMs > 0 && positionMs >= durationMs - 5000` | ✅ 已正确 | 不变 |
| PC `SyncHistoryItem.completed` | 同上 | ✅ 已正确 | 不变 |
| PC `resumePositionFor` | `record.completed` 为真 → `null` | ✅ 已正确 | 不变 |
| PC `player_page._isGenuineEnd` | **不存在** | ❌ | **新增**（§4.1） |
| 安卓 `PlaybackRecord.completed` | `position >= duration \|\| progress >= 0.95` | 0.95 与 5 s **不等价** | 记录差异，PC 侧不依赖它 |

**0.95 vs 5 s 的差异**：对 45 min 的剧集，0.95 = 剩余 135 s 就算完播；
PC 的 5 s 余量要严格得多。这会造成"安卓认为播完、PC 认为没播完"。

**处置（PC 侧，不改安卓）**：

- PC **不采信**同步过来的 `completed` 字段，一律**按自己的公式重算**
  （`SyncHistoryItem.fromAndroid` 已经这么做——确认并加测试锁定）；
- 反向推送时，PC 推给安卓的 `completed` 用**自己的公式**结果，
  让安卓侧至少在这一条上得到更严格的判定；
- 在 UI 诊断里披露这条差异（`01` §7.2）。

### 4.3 修复 D3：失败路径必须保留续播上下文

**原则**：**播放失败绝不改变"我在看哪一集、看到哪"**。

```dart
Future<void> _load() async {
  // 记录本次加载的"意图"，失败时用它回滚 _request
  final intent = _request;
  setState(() => _loadError = null);
  final outcome = await _controller.openWithRetry(...);
  ...
  if (!outcome.succeeded) {
    if (_request.directUrl && await _fallbackLiveLine()) return;
    setState(() {
      // 关键：失败时把 _request 恢复成本次加载前的意图，
      // 避免"上一集失败 → 已经切到下一集 → 续播上下文丢失"（D3）
      _request = intent;
      _loadError = ...;
    });
    // 失败不得保留 completed=true，否则重建会再次触发连播（D1）
    _controller.clearCompleted();
    return;
  }
  ...
}
```

需要在 `PlayerController` 新增：

```dart
/// 显式清除 completed（失败/回滚路径用）。
///
/// 为什么必须显式：media_kit 的 completed 只在下次 open 时复位，
/// 而失败路径不会再 open（否则就是死循环重试）。
void clearCompleted() {
  if (!_completed) return;
  _completed = false;
  notifyListeners();
}
```

### 4.4 新增：可续播的失败态

失败后 UI 不得只显示一行错误，必须提供**三个明确出口**：

| 出口 | 行为 |
| --- | --- |
| **重试本集** | 用**原** `_request`（原集、原 `startPosition`）重新 `_load()` |
| **从最近进度续播** | 重新查 `resumePositionFor(...)`，用最新进度重建 `_request` 后 `_load()` |
| **播放下一集** | 显式用户动作（不是自动） |

**为什么"从最近进度续播"要重新查库**：失败期间进度仍在周期写入
（`_persistProgress`），最新值可能比 `_request.startPosition` 更靠后。

### 4.5 唤醒后的恢复路径

用户"唤醒安卓 → 点继续播放"时，PC 侧必须走**恢复**而不是**新建**：

```text
恢复路径（必须实现）：
  1. 页面重建时，若 _loadError != null 或播放未开始：
       position = state.resumePositionFor(
         siteKey: _request.siteKey,
         vodId:   _request.vodId,
         flag:    _request.flag,
         episodeId: _request.episodeTarget,
       )
  2. 若 position != null → _request.copyWith(startPosition: position)
  3. _load()（此时 _controller.open 会复位 _completed）
  4. 播放成功后 seek 到 position（既有逻辑，`player_page.dart` 已实现）
  5. **不得**调用 _onCompleted()（P5：恢复路径不触发连播）
```

**必须加断言/测试**：恢复路径上 `_playNext()` 的调用次数为 **0**。

### 4.6 缓存耗尽的可观测性（新增诊断）

缓存耗尽当前在 PC 侧**不可见**。新增：

| 观测点 | 内容 |
| --- | --- |
| `PlayerLoadOutcome.failureKind` | 新增 `bufferingStall` / `ioEofExhausted`（若 media_kit 能区分） |
| 诊断日志 | `buffered` 位置、`position`、`duration`、连续 EOF 次数（若可得） |
| `recordPlaybackDiagnostics` | 落库时带上 `completed` 判定结果与 `isGenuineEnd` 结论 |

**若 media_kit 无法区分**（很可能），则退化为：

- 记录"失败时的 `position`/`duration`/`buffered`"；
- 若 `position >= duration - 5 s` 则标 `nearEnd=true`，否则 `nearEnd=false`；
- `nearEnd=false` 的失败**永远**不触发连播（这一条已由 §4.1 保证）。

---

## 5. 安卓侧的修复（已提出，待批准）

| 项 | 能否由 PC 修 | 说明 |
| --- | --- | --- |
| 提前 EOF 是否报 `STATE_ENDED` | ❌ | 需改 `MediaSourceFactory`/`ExoPlayerEngine`，属安卓工程 |
| `STATE_ENDED` 无"真播完"闸门 | ❌ | `VideoActivity.checkEnded` 属安卓工程 |
| `PlaybackRecord.completed` 的 0.95 阈值 | ❌ | 安卓侧策略；PC 只能不采信 |
| 缓存容量与 `HttpEofRecoveryDataSource` 重连上限 | ❌ | 安卓侧策略 |
| `PlayerSetting.isBackgroundOff()` 导致后台暂停 | ❌ | 安卓侧设置；PC 只能提示 |

**已在 webtv4 提出两项安卓侧改动**（`F:/Workspace/webtv4/webhtv/docs/PC-REALTIME-SYNC-01-android-contract-gap.md`）：

| # | 改动 | 风险 | 建议 |
| --- | --- | --- | --- |
| E | `VideoActivity.checkEnded` 加"真播完"闸门（复用 `History.isNearEnding()`） | 中（改播放行为） | **先做 §3.2 实验再定** |
| D | 统一 `PlaybackRecord.completed` 阈值（抽共享判定） | 中高（影响 webhook 与既有同步） | **建议暂缓**，由 PC 侧重算 |

**PC 侧仍然要做的**：

1. 把 §3 的实验结论**记录成证据**（`docs/phase7/evidence/`）；
2. 在诊断页展示"安卓侧疑似提前 EOF 判完播"的**提示**（不自动改任何东西）；
3. 若实验证明安卓侧误报 ENDED，**输出一份给安卓工程的问题描述**
   （含 logcat 片段与复现步骤）。

---

## 6. 验收要点（详见 `04`）

| # | 要点 | 层 |
| --- | --- | --- |
| 1 | `_isGenuineEnd`：`duration<=0` → false；`position<duration-5s` → false；`position>=duration-5s` → true | L1 |
| 2 | `_advanceInFlight` 防重入：连续 10 次 `notifyListeners` 只触发 1 次 `_playNext` | L2 |
| 3 | 失败路径 `_request` 回滚到意图值（`episodeIndex` 不变） | L2 |
| 4 | 失败路径 `clearCompleted()` 被调用，且不触发连播 | L2 |
| 5 | 恢复路径 `_playNext` 调用次数 = 0 | L2 |
| 6 | `completed` 跨端语义：PC 不采信同步来的 `completed`，按公式重算 | L1 |
| 7 | 失败态三个出口都存在且可用 | L2 |
| 8 | 端到端：模拟提前 EOF → 不跳集 → 恢复后续播到原进度 | L3 |
