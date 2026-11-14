# P2-1 增强：追番运行期（默认开启 / 间隔可设置 / 系统通知）

- 日期：2026-11-02
- 范围：`apps/desktop-flutter`（WebHTV PC）
- 关联：`docs/phase9/evidence/06-w3-following.md`（追番 P2-1 基线）、
  `docs/adr/0006-following-system-notification.md`（通知依赖登记与降级）

## 1. 改动清单

| 文件 | 说明 |
| --- | --- |
| `pubspec.yaml` / `pubspec.lock` | 通知依赖 `local_notifier: ^0.1.6`（解析到 0.1.6，Windows 侧自带 WinToast 实现）；`flutter pub add/remove` 同时改写了 `windows/flutter/generated_plugins.cmake`（工具自动生成，非手改）。此前用的 `flutter_local_notifications ^23.0.0` 因 Windows 通道依赖 ATL（`atlbase.h`）导致本机 release 构建失败，已移除，见 ADR-0006 §2 |
| `lib/core/following.dart` | `FollowingSettings.enabled` 默认改为 `true`；`fromJson` 缺键回落到 `defaults`（老偏好视为「从未设置」）；新增 `intervalLabel` / `formatInterval` 文案 |
| `lib/services/notification_service.dart`（新增） | `SystemNotifier` 平台抽象 + `LocalNotifierAdapter`（Windows 实现，`local_notifier`）+ `FollowingNotifier`（降级编排、`notifyNewEpisodes`、`degradedReason`） |
| `lib/state/app_state.dart` | 通知器懒建与注入点；检查后按新集发通知（失败只降级）；`followingNotice` / `followingSystemNotificationAvailable` / `followingAutoCheckActive` / `followingOpenRequest` / `tmdbSeasonService` 只读出口；`_restartFollowingTimer` 支持「改间隔后立即补一次」 |
| `lib/ui/following_page.dart` | 间隔设置入口（7 个预设 + 自定义分钟，夹取 15–1440）；「每 N 小时 / 每 N 分钟」文案随设置变化；通知开关副标题改为准确描述；提示条显示降级信息；消费系统通知点击请求并打开最新集 |
| `test/phase9_following_test.dart` | 新增 7 个用例（默认开启迁移 2 条、间隔持久化/夹取/文案、TMDB 访问器、通知降级 2 条、通知成功 1 条） |

未改动：`lib/ui/app.dart`、`lib/services/storage.dart`、`lib/core/following_calendar.dart`、
`lib/services/following_service.dart`、`lib/services/ui_preferences_store.dart`、数据库 schema。

## 2. 默认开启的迁移语义

| 场景 | 判定 | 结果 |
| --- | --- | --- |
| 新装 / 偏好文件里没有 `following` 键 | `UiPreferencesStore._followingSettings == null` → `FollowingSettings.defaults` | `enabled = true`，间隔 360 分钟，定时器启动 |
| 旧版本写过 `following` 但键里缺字段 | `FollowingSettings.fromJson` 逐字段回落 `defaults` | 同上 |
| 用户显式关闭 | 偏好里存 `{"enabled": false, ...}`，`!= defaults` 故不会被 `_persist` 删键 | `enabled = false`，重启后仍关闭，不建定时器 |

对应测试：

- `追番默认开启与间隔（P2-1 增强） 从未设置 → 自动检查默认开启且调度定时器生效`
  （断言 `enabled == true`、`intervalMinutes == 360`、`followingAutoCheckActive == true`）
- `追番默认开启与间隔（P2-1 增强） 显式关闭 → 重启应用后仍保持关闭`
  （关闭后 `followingAutoCheckActive == false`；重新 `bootstrap()` 仍为 `false`）

## 3. 检查间隔

- 入口：追番页 `following-interval`（`TextButton.icon`，文案「检查间隔：每 N 小时/分钟」）。
- 对话框：预设 `15/30/60/180/360/720/1440` 分钟（`ChoiceChip`）+ 自定义分钟输入框；
  保存走 `FollowingSettings.copyWith`（夹取 15–1440）。
- 保存效果：`AppState.setFollowingSettings` → 持久化 → `_restartFollowingTimer(kickDelay: Duration.zero)`
  （重建周期定时器 + 立即补一次到期检查）。
- 文案：整小时显示「每 N 小时」，否则「每 N 分钟」。

对应测试：`间隔设置：持久化、夹取 15–1440 与文案`
（30 分钟重启后仍为 30；`copyWith(5) == 15`、`copyWith(5000) == 1440`；
`formatInterval(360) == '每 6 小时'`、`formatInterval(90) == '每 90 分钟'`）。

## 4. 系统通知与降级

- 触发点：`AppState.checkAllFollowings` / `checkFollowing` 发现新集且
  `shouldNotifyFollowing(item)` 为真（`notifyEnabled` 开、且 `released > max(read, lastNotified)`），
  再受顶层 `notifyEnabled` 开关约束。
- 内容：标题「<剧名> 有新集」，正文「<最新集名>（第 N 集）」或「第 N 集已可观看」，
  payload 为追番身份键（`source:<cid>:<site>:<vod>:s<season>`）。
- 实现（`local_notifier 0.1.6`）：
  - 初始化 `LocalNotifier.instance.setup(appName: 'WebHTV')`；该库在 Windows 上把
    `appName` 同时用作 AUMID（`WinToast::setAppUserModelId`），故实际 AUMID 是 `WebHTV`，
    不再有 `guid` 参数。
  - 发送 `LocalNotification(identifier: 'webhtv-following-<id>', title: …, body: …).show()`；
    同一部剧复用同一个对象与标识，避免监听器随发送次数累积。
  - `show()` 抛错（含未初始化）即视为发送失败，返回 `false` 走降级。
- 点击：`LocalNotification.onClick`（Windows 插件在
  `windows/local_notifier_plugin.cpp` 里用 `channel->InvokeMethod("onLocalNotificationClick")`
  回传）→ `AppState._onFollowingNotificationOpen` 记录 `followingOpenRequest`，
  追番页消费者直接打开该条最新集（`_playLatest`）。payload 用闭包捕获身份键，
  不依赖通知体本身。
- 降级：`SystemNotifier.initialize/show` 返回 `false`、抛错、平台不支持任一情形 →
  `FollowingNotifier` 吞掉异常并给出 `degradedReason`；`AppState.followingNotice`
  写「系统通知不可用（原因），已改用应用内提示：剧名（第 N 集）」，追番页提示条显示；
  侧栏徽标（`followingUpdateCount`）此前不依赖通知，继续生效。

对应测试（`group 追番系统通知与降级`）：

| 用例 | 模拟失败方式 | 断言摘要 |
| --- | --- | --- |
| `初始化失败 → 降级为应用内提示，不抛错` | 注入 `_FakeSystemNotifier(initOk: false)` | `delivered == 0`、`notice` 含「系统通知不可用」与「应用内提示」、`systemAvailable == false`、`degradedReason` 含「初始化失败」、平台未被调用 `show` |
| `发送失败 / 发送抛错 → 同样降级且不中断` | `showOk: false`；`throwOnShow: true` | 两次都 `delivered == 0` 且 `hasDegraded`，抛错时 `systemAvailable == true`（初始化本身成功），异常不外泄 |
| `系统通知可用 → 标题含剧名、正文含新集信息` | 正常 fake | `delivered == 1`、`notice` 为空、标题含剧名、正文含「第 12 集」、payload 等于身份键 |

## 5. 只读访问器（为日历页预留）

```dart
/// TMDB 季服务只读入口（后续日历页使用；`null` = 数据库未就绪）。
TmdbSeasonService? get tmdbSeasonService =>
    _database == null ? null : _ensureTmdbSeasonService();
```

测试：`TMDB 季服务只读访问器：数据库就绪后非空`（非空 + 重复访问返回同一实例）。

## 6. 验证输出

```text
$ flutter analyze lib\core\following.dart lib\services\notification_service.dart lib\state\app_state.dart lib\ui\following_page.dart test\phase9_following_test.dart
Analyzing 5 items...
No issues found! (ran in 14.3s)
```

全仓 `flutter analyze`（2026-11-08 复查，含日历页代码）：无 issue。

```text
$ flutter analyze
Analyzing desktop-flutter...
No issues found! (ran in 79.9s)
```

```text
$ flutter test test\phase9_following_test.dart
00:17 +23: All tests passed!
```

```text
$ flutter test test\phase9_preferences_test.dart test\phase9_following_test.dart
00:25 +36: All tests passed!
```

全量 `flutter test`：`+3284 -2`，两条失败**均与本任务无关**：

1. `test/phase9_calendar_logic_test.dart` 无法编译——`lib/core/following_calendar.dart:120`
   （并行子代理正在写的文件，本任务禁改）：
   `A value of type 'num' can't be returned from a function with return type 'int'`。
2. `test/phase8_app_state_config_test.dart: 设置按钮顺序后立即生效`
   `Expected: <9>  Actual: <8>`——`lib/core/player_buttons.dart` 的 `kPlayerButtons`
   只定义了 8 个按钮，属既有断言与实现不符，相关文件本任务未改动。

## 7. Windows release 构建实测（`local_notifier` 换库验证）

换库的直接目的是让 release 构建通过，故本次按任务要求跑了完整构建：

```text
$ flutter build windows --release
Building Windows application...                                   124.1s
√ Built build\windows\x64\runner\Release\webhtv_pc.exe
[exit 0]
```

产物目录 `build\windows\x64\runner\Release\` 内含 `webhtv_pc.exe` 与
`local_notifier_plugin.dll`（WinToast 实现随之链接）。

对照：换库前用 `flutter_local_notifications_windows` 时同一命令失败于
`plugin.cpp(5,10): error C1083: 无法打开包括文件: "atlbase.h"`（本机未装 ATL 组件）。

## 8. 已知限制与待确认

1. **点击通知的跨页切换未实现**：`lib/ui/app.dart` 禁止修改，点击通知只能在追番页
   已挂载时直接打开最新集；停留在其他页面时不会自动跳转到追番页。
2. **有构建证据、仍无端到端弹窗证据**：release 构建已实测通过（§7），但未在桌面
   会话里截图确认 toast 真实弹出与点击跳转；降级路径已由单测覆盖。
3. **`local_notifier` 不上报 WinToast 失败**：Windows 插件 `Setup` 恒回 `true`、
   `Notify` 忽略 `showToast` 的失败返回，故「初始化/发送失败」在生产中主要由通道
   异常触发，库自己不会报告 toast 被系统拒绝的情况。
4. **首次发送会在开始菜单创建 `WebHTV.lnk`**：WinToast 默认
   `ShortcutPolicy.requireCreate` 的既定行为（toast 归属所需），未改默认策略。
5. ~~**`lib/services/ui_preferences_store.dart:180` 注释措辞过时**~~：已由日历任务一并更正为
   「null 表示从未设置过（按默认值：自动检查开启）」，与当前默认值一致。
6. 自动检查仍然只在应用运行期间生效（PC 无后台服务），与安卓的差异未变。
