# 01 · P0 播放闭环设计（轨道 / 片头片尾 / 循环定时 / 播放参数 / LUT）

- 覆盖缺口：P0-1 … P0-5（`docs/phase9/README.md` §4.1）
- 上游依据：安卓 `webtv2@77e2fbefdc`
- 涉及 PC 模块：`lib/ui/player_page.dart`、`lib/ui/player_controller.dart`、`lib/core/player_buttons.dart`、`lib/services/storage.dart`、`lib/services/ui_preferences_store.dart`

---

## 0. 不变量（先于功能）

1. **播放器不因设置面板而改变几何**：Phase 8 已把控制栏改为浮层（四层 Stack）。本阶段新增的菜单/提示一律走浮层或右键菜单，不得回到 `Column` 兄弟节点。
2. **不伪造入口**：某个能力在引擎侧不可用（例如 LUT 滤镜缺失）时，入口置灰 + 说明原因，而不是隐藏或假成功。
3. **不打断播放**：切换轨道、应用 LUT、片头跳过、定时提示都不得重建播放器实例；`player_controller` 只调用属性/轨道 API。
4. **失败隔离**：以上任何一项失败只记日志 + 一次性提示，视频继续播（与字幕/弹幕同一语义）。
5. **测试锁定的字面量不改**：`subtitle_flow_test.dart`、`danmaku_flow_test.dart` 依赖顶栏 tooltip 精确串；新增菜单不得移动它们。

---

## 1. 现状与可用 API

- `player_controller.dart` 已封装 `Player`（media-kit 1.2.6），已有 `setSubtitleTrack`、`stream.tracks.listen`、外挂字幕装配，并已暴露**只读**的 `tracks` / `selectedAudioTrack` / `selectedVideoTrack`（供媒体信息与诊断）；缺的是**选择入口**与 `setAudioTrack/setVideoTrack` 调用。
- media-kit 1.2.6 已确认提供：
  - `Player.setVideoTrack(VideoTrack)` / `setAudioTrack(AudioTrack)` / `setSubtitleTrack(SubtitleTrack)`；
  - `Player.state.tracks` / `Player.stream.tracks`（`Tracks.video/audio/subtitle`）；
  - 桌面端 `Player.platform` 为 `NativePlayer`，提供 `setProperty(String, String)`（mpv 属性）。
- 因此 P0-1/P0-4/P0-5 都不需要新依赖，只需要把 API 暴露到 UI 并锁定行为。

---

## 2. P0-1 音轨 / 视频轨选择

### 2.1 模型

```dart
enum PlayerTrackKind { audio, video, subtitle }

class PlayerTrackOption {
  final PlayerTrackKind kind;
  final String id;        // media-kit track.id（稳定标识）
  final String label;     // "音轨 2 · 国语" / "视频轨 1 · 1080p"
  final String? language; // 可能为空
  final bool isDefault;
  final bool isExternal;  // 仅字幕
}
```

`player_controller.dart` 新增：

```dart
List<PlayerTrackOption> tracksOf(PlayerTrackKind kind);
Future<void> selectTrack(PlayerTrackKind kind, String id);
```

- 内部把 `Track` 映射成 `PlayerTrackOption`，`id` 一律用 media-kit 的 `id`，**不用列表下标**（列表顺序会变）。
- `selectTrack` 对 `audio`/`video` 调 `_player.setAudioTrack/setVideoTrack`；`subtitle` 复用既有逻辑（含 `SubtitleTrack.no()`）。

### 2.2 交互

- 顶栏「轨道」按钮（`Icons.graphic_eq`）+ 右键菜单「轨道」子菜单，两处都可到达（Phase 8 规则：右键不得成为唯一入口）。
- 菜单按 kind 分组：音轨 / 视频轨 / 字幕轨；当前项打勾；「自动」与「关闭」作为固定项。
- 单条音轨时：不置灰整组，而是显示「仅一条音轨」并禁用切换项——用户需要知道「为什么没有选择」。
- 持久化：默认不记忆（每次用播放器/站点默认）；可选设置「记住本片音轨」写入 `ui_preferences_store`（键 `trackPrefs`），默认关闭。

### 2.3 失败与边界

| 情况 | 行为 |
| --- | --- |
| 引擎未上报任何音轨 | 菜单项显示「无可用音轨」，不调用 API |
| 切换 API 抛错 | 捕获 → 提示「切换失败」+ 日志 `scope=track`；保持原轨道 |
| 切换时正在 seek | 允许；不重建 player；若引擎自动暂停，恢复播放态 |
| 直播流 | 音轨切换可用；视频轨通常只有一条，按实际上报渲染 |

### 2.4 测试

- L1：`Track`→`PlayerTrackOption` 映射（含无语言、重复 label、`auto`/`no` 过滤）。
- L2：菜单在 0/1/2 条音轨下的渲染与禁用；切换调用参数正确（用假 Player 记录调用）。
- L3：双音轨 MKV fixture（ffmpeg 生成）真实窗口切换，断言 `state.audioTrack.id` 变化、`position` 不回零、无 loading 重建。

---

## 3. P0-2 片头片尾跳过

### 3.1 语义（必须先定死）

1. **每集只自动跳一次**：同一 `(siteKey, vodId, episodeId)` 在一次播放会话内只自动 seek 一次；用户手动拖回片头不再触发。
2. **续播优先**：`startPosition > 片头终点` 时不跳（否则会把用户拉回开头）。
3. **片尾边界钳制**：`endingMs` 必须 `< durationMs - 5s`，否则忽略（防止配置错误导致「一开播就结束」）。
4. **不触发连播**：跳片尾是 seek，不是 EOF；不得让 Phase 7 的 `isGenuineEnd` 误判。
5. **手动优先**：用户点「跳过片头/片尾」立即生效；开关只控制「自动」。

### 3.2 纯逻辑 API

`lib/core/skip_segments.dart`：

```dart
enum SkipActionKind { none, intro, outro }

class SkipPlan {
  final int? introEndMs;   // null = 未标记
  final int? outroStartMs; // null = 未标记
  SkipActionKind decide({
    required int positionMs,
    required int durationMs,
    required bool autoIntro,
    required bool autoOutro,
    required bool alreadyIntroSkipped,
    required bool alreadyOutroSkipped,
  });
}
```

- 所有输入做钳制（负数、超过 duration、intro >= outro 一律视为无效）。
- 纯函数，无 Flutter 依赖，便于穷举测试。

### 3.3 存储

- DB `schemaVersion 3 → 4`：新增 `skip_segments(site_key, vod_id, opening_ms, ending_ms, updated_at)`，**按影片**保存。
  - 为什么不加在 `history` 上：`history` 是「按集」的，同一部剧每集都要标一次；片头片尾通常整部剧一致，按影片存才符合用户操作。
  - 同步路径不改：安卓推来的 `opening/ending` 仍按 `normalizeAndroidMs` 过滤哨兵值，落库时可覆盖本片标记（后续 W2 再补）。
- 读取时按 `(site_key, vod_id)`；没有记录返回 `SkipSegments.none()`。

### 3.4 交互

- 播放器右键「跳过片头」「跳过片尾」（始终可用，即使未标记——点击后提示「本集未标记」）。
- 标记：右键 →「标记片头/片尾」记录当前进度；再次点击可清除；设置页有「清除本片标记」。
- 设置页「播放」区块：「自动跳过片头」「自动跳过片尾」两个开关（默认关）。
- 快捷键：`Alt + [` 跳片头、`Alt + ]` 跳片尾（`[`/`]` 已被上一集/下一集占用，见 `playerShortcuts`）。

### 3.5 测试

| 层 | 用例 |
| --- | --- |
| L1 | 无标记 → none；position < introEnd → intro；position >= introEnd → none；续播 > introEnd 不跳；outro 边界非法被忽略；只跳一次 |
| L2 | 开关关闭不调用 seek；标记后按钮文案变化 |
| L3 | 真实播放：进入 90s 片头自动 seek 到 90s；拖回 30s 不再自动跳；跳片尾不触发连播 |

---

## 4. P0-3 循环 / 定时关闭

### 4.1 循环

```dart
enum PlaybackRepeat { off, one, all }
```

- `one`：EOF 时不前进，seek 到 0 并继续播放（用 Phase 7 的 `isGenuineEnd` 判定，避免把「缓存耗尽」当 EOF）。
- `all`：最后一集播完回到第一集；顺序取当前线路的剧集列表（不跨季度，沿用 `tmdb_playback.dart` 的季度边界规则）。
- `off`：保持现状（自动连播下一集）。
- **与 `autoNext` 的优先级**：`one`/`all` 优先；`off` 时若 `autoNext=false` 则在 EOF 停止（不连播），若 `autoNext=true` 则连播。两个开关的交互必须在设置页文案里写明，避免「关了自动连播却还在循环」的歧义。

### 4.2 定时关闭

```dart
class SleepTimer {
  SleepTimer({required this.deadline, required this.mode});
  final DateTime? deadline;      // 绝对时间
  final SleepTimerMode mode;     // duration | endOfEpisode
}
```

- 预设：15 / 30 / 60 / 90 分钟 / 本集结束 / 关闭。
- 到点行为：暂停 + OSD 提示「定时关闭已生效」；不退出播放器（用户可能在片尾）。
- **不持久化**：退出播放器即取消；进程重启后为空（避免「重启后突然暂停」）。
- 计时基于 `Timer` + 单调时钟校正（系统时间被改时不至于立即触发或永不触发）。

### 4.3 测试

- L1：重复模式在 EOF 的裁决；`all` 的末集回绕；定时器到点回调只触发一次。
- L2：菜单选中态、重进播放器定时器为空。
- L3：真实播放到点暂停并显示 OSD。

---

## 5. P0-4 播放参数

### 5.1 选项模型

`lib/core/player_options.dart`（纯数据 + 校验）：

| 键 | 取值 | 默认 | mpv 属性 |
| --- | --- | --- | --- |
| `hwdec` | `auto-safe` / `no` | `auto-safe` | `hwdec` |
| `cache` | `yes` / `no` | `yes` | `cache` |
| `demuxerMaxBytes` | 16–2048 MiB | 256 | `demuxer-max-bytes` |
| `demuxerMaxBackBytes` | 8–512 MiB | 64 | `demuxer-max-back-bytes` |
| `audioSpdif` | `off` / `ac3,eac3,dts` | `off` | `audio-spdif` |
| `autoNext` | bool | true | 应用层 |
| `failureFallback` | `off` / `line` / `line+parse` / `line+parse+source` | `line` | 应用层 |
| `preloadNext` | bool | false | 应用层 |
| `longPressSpeed` | 2.0–4.0（常用档 2/2.5/3/4） | `3.0` | 应用层（长按画面手势） |

- 非法值在 `normalize()` 阶段回落默认并记日志，**不抛异常**（设置页不应因历史脏数据打不开）。
- 缺省值必须等价于当前行为；`autoNext=true` 与现状一致。
- **例外**：`longPressSpeed` 默认 3×（此前在 `_beginGestureSpeed` 里写死 2×）。这是
  2026-11 需求方明确要的默认值变更，不是漏改；区间内但不在常用档位表里的值（如
  3.5）保留，不静默改写。

### 5.2 应用方式

- 播放开始前（`player_controller.open` 之后、play 之前）调用 `NativePlayer.setProperty`；失败只记日志。
- 设置项变更在下一次播放生效（不做运行中热改，避免 mpv 状态错乱）；设置页文案写明。

### 5.3 预加载（限定范围）

**只做**：下一集播放地址的预解析（站点 `play` 调用 + 解析器选择），在距本集结束 90s 内触发；可取消；并发 1。
**不做**：分片下载/边下边播（列 P1/P3 评估，需独立 ADR）。

- 预解析结果进入 30s TTL 缓存，连播时直接复用；失败丢弃，不影响当前播放。
- 关掉 `preloadNext` 后不得发起任何站点请求（用 fixture 计数断言）。

### 5.4 失败回退

按 `failureFallback` 逐级尝试，每级记录原因：

1. 当前线路内下一地址；
2. 下一条解析入口（仅当 P1-4 已实现顺序表；未实现时跳过）；
3. 下一站点（换源，沿用现有 `source_field` 换源逻辑）。

达上限后如实报错，不得静默回到列表。

### 5.5 测试

- L1：`normalize` 的边界与非法值；回退阶梯裁决。
- L2：设置页渲染/持久化；mpv 属性名映射表。
- L3：真实播放读回 `hwdec`/`cache`；预加载关闭后 fixture 请求计数为 0；回退触发的日志顺序正确。

---

## 6. P0-5 LUT

### 6.1 模型

```dart
class LutPreset {
  final String id;
  final String name;
  final String? path;    // 本地 .cube
  final double intensity; // 0..1
}
```

- 只接受 `.cube`（1D/3D）；大小上限 8 MiB；解析失败给出「文件不是有效 .cube」。
- 应用方式：mpv `vf` 属性追加 `lavfi=[lut3d=file='<path>'<:interp=...>]`；关闭时恢复空 `vf`。
- 失败（mpv 未编译 lut3d）→ 显式报「当前播放内核不支持 LUT」并禁用入口。

### 6.2 验收

- L2：用棋盘 PNG 经播放器截图，应用前后像素差 > 阈值；关闭后回落。
- L3：真实视频窗口截图；切换 LUT 不重建 player；重启后恢复。

---

## 7. 设置与数据键

`settings.json` 增 `player` 区块（缺省即现状）：

```json
{
  "player": {
    "hwdec": "auto-safe",
    "cache": true,
    "demuxerMaxBytes": 268435456,
    "demuxerMaxBackBytes": 67108864,
    "audioSpdif": "off",
    "autoNext": true,
    "failureFallback": "line",
    "preloadNext": false,
    "longPressSpeed": 3.0,
    "autoSkipIntro": false,
    "autoSkipOutro": false,
    "repeat": "off",
    "lutPresetId": null
  }
}
```

DB v4：`history.opening_ms`、`history.ending_ms`。

---

## 8. 测试矩阵（汇总）

| ID | L1 | L2 | L3 |
| --- | --- | --- | --- |
| P0-1 | 轨道映射/过滤 | 菜单渲染与禁用 | 双音轨真实切换 |
| P0-2 | 跳过裁决穷举 | 开关/标记文案 | 自动跳片头不重复、跳片尾不连播 |
| P0-3 | 重复模式与定时器 | 菜单选中态 | 到点暂停 |
| P0-4 | 选项归一化/回退阶梯 | 设置持久化 | mpv 属性读回、预加载零请求 |
| P0-5 | cube 解析 | 截图像素差 | 真实窗口应用/还原 |

反向验证（至少 3 项）：删掉「只跳一次」守卫应红；把 `autoNext` 默认改成 false 应红；把 `demuxerMaxBytes` 单位写成 KB 应红。

---

## 9. 风险

| 风险 | 缓解 |
| --- | --- |
| media-kit 版本升级改变 track/property API | 先写适配层 `player_tracks.dart`/`player_options.dart`，只在适配层调用第三方 API |
| LUT 依赖 mpv 编译选项 | 能力探测 + 明确报错；不把不可用入口伪装成可用 |
| 预加载被误当「边下边播」 | 文档与 UI 都写「预解析下一集地址」，不做数据下载 |
| 片头片尾数据来自安卓同步的哨兵值 | 沿用 `normalizeAndroidMs`；非法值一律忽略 |
