# 音量归一 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按 PotPlayer 借鉴文档提供默认关闭、可随时关闭的全局实时 Normalizer。

**Architecture:** 沿用 PlayerOptions → UiPreferencesStore/AppState → PlayerController 的已有配置链路。新增 audioNormalization 布尔值，mpv af 仅输出 dynaudnorm 或空串；设置页、播放器右键菜单与 Shift+N 共用该偏好。采用 Hybrid：Lead 先冻结配置/白名单接口，再由两个独立执行者接入设置和播放交互，Lead 独立验收。

**Tech Stack:** Flutter 3.47.5 / Dart 3.13.4、media-kit 1.2.6、mpv dynaudnorm、flutter_test。

**Spec:** docs/reference/potplayer-checklist.md:64；docs/reference/potplayer-borrowings.md:539-561。

## Global Constraints

- 必须默认关且可关；关掉即恢复原响度。
- 不引入任何读文件标签的逻辑；不实现 ReplayGain。
- 区分全局归一与按站源记住音量：本任务只做前者，不改变音量滑杆、静音或站源偏好。
- 不增加依赖，不开放任意 af 文本；仅白名单空串或 dynaudnorm。
- 设置与播放中入口共用持久化配置；沿用现有 UI 组件、中文文案与键命名。
- 写后回读 af；不能把被内核拒绝误判为成功。
- 保留 audioPassthrough 偏好；对解码音频进行归一，原生验收核对直通兼容性。
- 按用户策略不发起审批，不创建额外 worktree，不提交或推送。当前工作区为 dev1，初始 working tree 干净。

## 证据与决定

- 已核对参考文档：Normalizer 用于实时响度调整，不依赖标签；默认关闭。
- 采用标准默认 dynaudnorm 参数，不加自定义强度档位或测量/预分析子系统。
- 本机 SDK 为 Flutter 3.47.5 / Dart 3.13.4；初始 54 项相关测试通过。
- sysroot libmpv 实测：af=dynaudnorm → rc=0/readback=dynaudnorm；af=空串 → rc=0/readback=空串；非法滤镜 → rc=-9。
- Session 未记录 subagent allowlist；可用目录路由为 deepseek-official/deepseek-v4.1-flash，不称其为 authorized。

### Task 1: 配置与白名单接口（Lead core；run 1）

**Files:**
- Modify: apps/desktop-flutter/lib/core/player_options.dart:132-524
- Modify: apps/desktop-flutter/lib/core/mpv_properties.dart:216-275
- Create/Test: apps/desktop-flutter/test/player_audio_normalization_test.dart

**Interfaces:**
- Produces: PlayerOptions.audioNormalization : bool，默认 false；copyWith({bool? audioNormalization})。
- Produces: JSON 键 audioNormalization；mpvProperties[af] 为开启时 dynaudnorm、关闭时空串。
- Produces: af 白名单规则（仅两个合法值，verifiable=true），仍由 applyPlayerOptions 应用。

- [x] 写失败测试，捕获默认/旧配置/脏类型处理、显式关、序列化、更新其他参数后不丢失、相等性、白名单注入限制。

```dart
final enabled = PlayerOptions.fromJson({
  "audioNormalization": true,
});
expect(enabled.mpvProperties["af"], "dynaudnorm");
expect(PlayerOptions.fromJson(null).mpvProperties["af"], "");
expect(filterMpvProperties({"af": "dynaudnorm=m=99"}).accepted, isEmpty);
```

- [x] 运行 flutter test --reporter expanded test/player_audio_normalization_test.dart，确认因为功能不存在而失败。
- [x] 增加字段到构造、normalized、copyWith、JSON、相等性、hashCode、诊断文本与 mpvProperties。
- [x] af 规则使用 value.isEmpty || value == "dynaudnorm"，保持可回读验证。
- [x] 运行新测试和初始三组回归，冻结接口。

### Task 2: 设置入口与真实持久化（delegate；run 1，Lead 已验收）

**Files:**
- Modify: apps/desktop-flutter/lib/ui/settings_detail_pages.dart:150-164
- Create/Test: apps/desktop-flutter/test/player_audio_normalization_settings_test.dart
- Create: 此任务的内部报告（由调度 brief 指定路径）

**Interfaces:**
- Consumes: Task 1 的 audioNormalization、copyWith；AppState.setPlayerOptions(PlayerOptions) → Future<bool>。
- Produces: 设置 → 播放设置的“音量归一”开关，key=settings-player-audio-normalization。

- [x] 写 widget 失败测试：默认关；点击后偏好开启；再次点击关闭；显示全球作用域和动态/延迟副作用说明。

```dart
final toggle = find.byKey(
  const ValueKey("settings-player-audio-normalization"),
);
await tester.ensureVisible(toggle);
await tester.tap(toggle);
await tester.pumpAndSettle();
expect(state.playerOptions.audioNormalization, isTrue);
```

- [x] 运行该测试，确认开关尚未接入时失败。
- [x] 在音频直通附近使用现有 _switch 接入同一 PlayerOptions；说明默认关、全局实时作用、可能改变动态并增加延迟，不承诺标签式同响度。
- [x] 用真实 UiPreferencesStore 临时 settings.json 验证保存开启、重建读取、保存关闭、再次读取仍关；确认其他偏好不被覆盖。
- [x] 运行新增测试及已有播放设置导航相关回归。无样式布局重设计，此改动为 additive，不要求视觉截图。

### Task 3: 播放中入口、快捷键和原生验收测试（delegate；run 2，Lead 已验收）

**Files:**
- Modify: apps/desktop-flutter/lib/ui/player_page.dart:3893-3950,5752,6030,6347
- Create/Test: apps/desktop-flutter/test/player_audio_normalization_ui_test.dart
- Create/Test: apps/desktop-flutter/test/player_audio_normalization_native_test.dart
- Create: 此任务的内部报告（由调度 brief 指定路径）

**Interfaces:**
- Consumes: Task 1 的 audioNormalization 与 mpvProperties。
- Consumes: PlayerController.applyMpvProperties(Map<String,String>) → Future<bool>，AppState.setPlayerOptions。
- Produces: 右键“音量”组中的“音量归一”开关和 Shift+N，均即时应用 af 且保留音量/静音。

- [x] 写失败测试：从菜单或快捷键切换应实际调用控制器应用 af，关闭传空串；偏好和勾选状态一致；重复快捷键不反复切换。

```dart
await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
await tester.pump();
expect(state.playerOptions.audioNormalization, isTrue);
```

- [x] 运行 UI 测试，确认未接入时失败。
- [x] 不修改公共 buildPlayerShortcuts 签名，在本页 map 追加 SingleActivator(keyN,shift:true,includeRepeats:false)。复用音量菜单结构，菜单与快捷键共享小型切换操作；保存偏好、即时应用，失败给出已有 toast/日志且仍可关闭。
- [x] 保持音量数值与静音状态；不改变站源选择/历史、不干扰直播快捷键。快速连按的最终内核 af 必须等于最终偏好，必要时仅对此操作串行。
- [x] 原生测试使用项目的 MediaKit/NativePlayer 和无声 ao=null 夹具，验证开启、关闭与再次打开媒体，af 回读，以及音量/静音未变；不跳过缺库失败而假称通过。
- [x] 运行新增 UI/原生测试及既有播放器菜单/快捷键回归。

### Task 4: Lead 验收与文档回填（Lead；run 1，已完成）

**Files:**
- Modify: docs/reference/potplayer-checklist.md:9,64
- Modify: docs/reference/potplayer-borrowings.md 追加实现证据
- Modify: 本计划执行记录；内部 ledger（不进用户改动）

- [x] 独立读取最终 diff，逐项核对默认关闭、关闭清除、持久化、白名单、快捷键与副作用说明。
- [x] 运行 dart analyze、归一新测试以及播放器选项/白名单/设置/菜单/快捷键相关测试。
- [x] 用实际可加载的 libmpv 执行开/关/切媒体和 AC3 直通组合验证；若发现 bug，回到负责边界修复并复验，未解决不得交付。
- [x] 文档标记 P1-8 已实现，列明路径、存储键、实时入口和测试证据，保留其他 backlog 项。
- [x] 交付无提交的工作区修改、验证结果与明确限制。
