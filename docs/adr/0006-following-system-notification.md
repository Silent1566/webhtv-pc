# ADR-0006：追番新集的 Windows 系统通知（新增依赖与失败降级）

- 状态：已接受
- 日期：2026-11-02（2026-11-08 修订：实现库由 `flutter_local_notifications` 换成 `local_notifier`）
- 决策：引入 `local_notifier`（Windows toast 通道），用于「追番发现新集」的桌面系统通知；
  **系统通知不可用时一律自动降级为应用内提示**（侧栏徽标 + 追番页提示条），
  检查流程永不因通知失败中断。
- 相关章节：`docs/phase9/README.md` §9 第 4 条「接受新增依赖：Windows 通知/SMTC，
  须在 ADR 中登记来源、版本与失败降级」。本 ADR 占用该条目对应的 ADR 编号位
  （ADR-0006「新增依赖与降级」），ADR-0003/0004/0005 的编号保持为 WebHome、
  局域网服务、远程托管预留。

## 1. 背景

追番（P2-1，`docs/phase9/evidence/06-w3-following.md`）此前只有应用内徽标提示：
应用在后台/窗口被遮挡时，用户看不到新集。安卓侧参考实现
（`FollowingNotifier.java`）用系统通知，PC 端此前**没有任何通知实现**。

同时存在两个必须解决的约束：

1. 自动检查默认开启（应用运行期间），检查是**无人值守**路径——通知实现不允许把
   异常抛回检查流程；
2. Windows 通知依赖系统的 toast 激活机制（AppUserModelId + 快捷方式/注册表），
   在部分环境（未注册的绿色版、受限会话、非 Windows 主机）上**可能初始化失败**
   ——必须有不依赖它的兜底路径。

## 2. 为什么换库（本次修订的原因）

首次实现用的是 `flutter_local_notifications ^23.0.0`（Windows 通道
`flutter_local_notifications_windows 4.0.0`）。该通道在本机 release 构建上**编译失败**：

```text
windows\flutter\ephemeral\.plugin_symlinks\flutter_local_notifications_windows\src\plugin.cpp(5,10):
error C1083: 无法打开包括文件: "atlbase.h"
flutter build windows --release → Build process failed (82.6s)
```

原因已核实：`plugin.cpp` 第 5 行硬 `#include <atlbase.h>` 且使用 C++/WinRT，
没有关闭该依赖的编译开关；本机 VS 2022 BuildTools 只装了 MSVC 14.44.35207
（`...\VC\Tools\MSVC\14.44.35207\atlmfc\include\atlbase.h` 不存在），即 ATL 组件未安装；
Windows SDK 10.0.26100.0 已安装。

**用户决策：不安装 ATL，改为换库。** `local_notifier` 的 Windows 实现基于
WinToast（`windows/wintoastlib.cpp`），只依赖 Windows SDK / WinRT 头，无 ATL 依赖，
实测 release 构建通过（见 §5）。

## 3. 选型与登记

| 项 | 内容 |
| --- | --- |
| 包名 | `local_notifier` |
| 版本 | `^0.1.6`（解析结果 `0.1.6`，见 `pubspec.lock`） |
| 来源 | pub.dev（`https://pub.dev/packages/local_notifier`），从 pub 官方仓库获取 |
| Windows 通道 | 包内自带 `windows/local_notifier_plugin.cpp` + WinToast（`wintoastlib.cpp`），提供 toast 与点击回调 |
| SDK 约束 | 要求 Flutter ≥ 3.0；本机 Flutter 3.47.5 / Dart 3.13.4，满足 |
| 传递依赖 | `uuid`（通知标识生成）、`flutter` 插件通道（均由 pub 解析） |
| 备选（未采用） | `flutter_local_notifications ^23.0.0`：API 更全，但其 Windows 通道依赖 ATL（`atlbase.h`），本机未装 ATL 组件 → release 构建失败，见 §2；备选「装 ATL 组件」已由用户明确否决 |

初始化参数（`lib/services/notification_service.dart`）：

- `appName`：`WebHTV`。`local_notifier` 在 Windows 上把 `appName` **同时**用作
  WinToast 的 toast 归属标识（`WinToast::setAppUserModelId(appName)`），即实际 AUMID 为
  `WebHTV`。该值必须稳定：换值后已登记的归属失效。
- 不再有 `guid` 参数：点击回调由 `LocalNotification.onClick` 承担（进程内的
  `MethodChannel` 回调），不需要注册激活 GUID。

选型理由：无 ATL 依赖（本机 release 构建可通过）、API 薄（`setup` + `show`）、
原生支持点击回调，能把点击接回既有 `followingOpenRequest` 路径。

## 4. 失败降级行为（本 ADR 的硬约束）

平台能力被抽成 `SystemNotifier`（`initialize` / `show` 各自返回 `bool`），
`FollowingNotifier` 对**任何**失败做统一降级：

| 失败点 | 触发 | 表现 |
| --- | --- | --- |
| 初始化失败 | `initialize()` 返回 `false` 或抛错（插件通道缺失、非 Windows 主机、`setup` 抛异常） | `systemAvailable = false`，`degradedReason = '系统通知初始化失败'`，不再重试初始化，本次及后续均走应用内提示 |
| 发送失败 | `show()` 返回 `false`（未初始化、`LocalNotification.show()` 抛错） | `degradedReason = '系统通知发送失败'`，下一条仍会尝试系统通知 |
| 发送抛错 | `show()` 抛异常 | 同上（异常被吞掉，不向检查流程传播） |
| 通知开关关闭 | `FollowingSettings.notifyEnabled == false` | 不发通知，也不降级（用户主动选择静默） |

降级后的应用内提示由两处承载，均为此前已有的机制：

1. **侧栏徽标**：`AppState.followingUpdateCount`（`hasUpdate` 计数）不依赖通知；
2. **追番页提示条**：`AppState.followingNotice` → 追番页 `following-notice`
   （文案形如「系统通知不可用（系统通知初始化失败），已改用应用内提示：剧名（第 N 集）」）。

通知成功或降级后都会调用 `markFollowingNotified` 写回 `lastNotifiedEpisode`，
避免同一集被反复提示（与安卓 `lastNotifiedEpisode` 语义一致）。

## 5. 验证（2026-11-08 实测）

- `flutter build windows --release`：**成功，exit 0，耗时 124.1s**，
  产物 `build\windows\x64\runner\Release\webhtv_pc.exe`（同目录含
  `local_notifier_plugin.dll`）。
- `flutter analyze`（全量）：`No issues found!`
- `flutter test test/phase9_following_test.dart`：`00:18 +23: All tests passed!`
  （含「初始化失败 → 降级」「发送失败/抛错 → 降级」「系统通知可用 → 标题含剧名、
  正文含新集」三条通知用例）。

详见 `docs/phase9/evidence/07-w3-following-runtime.md`。

## 6. 已知限制

- **点击通知的跨页切换未实现**：本任务禁止修改 `lib/ui/app.dart`，所以点击通知
  只记录 `AppState.followingOpenRequest`，由追番页消费并直接打开该条目的最新集
  （`FollowingPage` 已挂载时生效；其他页面停留时不会自动跳转到追番页）。
- **toast 未做端到端弹窗验证**：本次只验证到 release 构建通过 + 单测覆盖降级路径，
  没有在运行中的桌面会话里截图确认弹窗与点击。
- **`local_notifier` 不回传 WinToast 的初始化结果**：Windows 插件 `Setup` 忽略
  `WinToast::initialize()` 的返回值并恒回 `true`，`Notify` 也忽略 `showToast` 的
  失败返回值（失败得 `-1` 但通道仍回 `true`）。因此「初始化失败降级」在生产中主要
  由通道异常（插件缺失、非 Windows）触发，静态 error 分支不会被该库自己上报。
- **首次发送会创建开始菜单快捷方式**：默认策略 `ShortcutPolicy.requireCreate`
  会让 WinToast 在用户开始菜单补一个 `WebHTV.lnk`（toast 归属所需）。这是该库的
  既定行为，未改成 `requireNoCreate`（否则绿色版可能直接弹不出）。
- **通知标识固定**：同一部剧的通知复用同一个 `LocalNotification` 标识
  （`webhtv-following-<id>`）与对象，既保证 id 稳定，也避免
  `LocalNotification` 构造时的监听器注册随发送次数累积。
- `flutter pub add/remove` 自动改写了 `windows/flutter/generated_plugins.cmake`
  （插件列表里 `flutter_local_notifications_windows` → `local_notifier`）。该文件是
  Flutter 工具产物，不手改。
