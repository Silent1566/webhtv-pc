# Phase 10 交付总结 · 上次配置自动恢复 + 线路级轨道记忆

日期：2026-10-31　分支：dev1　基线提交：5c0fe62

## 一、用户需求（m00002 / m00100 / m00136）

1. 重新打开应用应自动加载用户**最后一次使用的配置**；若上次来自安卓桥接，先尝试桥接，连不上后给提示并帮助快速切换。
2. 重试某功能时默认采用用户**上次的相关设置**——播放同一剧集时记住用户选的视轨、字幕、音轨。
3. 记忆粒度锚定到**集数下的线路**（m00100），不跨线路共享。
4. 机制参考安卓版（m00136）。

## 二、访谈已定口径（两轮 5 个决策，全部按推荐项确认）

| 编号 | 决策 | 结论 |
| --- | --- | --- |
| Q1 | 「最后一次配置」的身份粒度 | 记住具体源：`sourceKey` + 记录 id（不用 origin，也不用设备最近地址） |
| Q2 | 桥接连不上的提示形态 | 非阻塞横幅 + 一键切换播放源（不弹模态框） |
| Q3 | 轨道/字幕记忆粒度 | 集数下的线路：`siteKey+vodId+flag+集+槽`，不跨线路共享 |
| Q4 | 记住的轨本次不存在时 | id 精确 → language 唯一 → title → auto，全程静默 |
| Q5 | 桥接失败后的重试 | 只给手动「重试」按钮，不自动轮询/延时重试 |

补充假设（已记录，未被推翻）：桥接源被删/重装导致 sourceKey 失效时，按「记录丢失」静默回落默认配置 + 写日志，不弹窗。

## 三、实现（7 个改造文件 + 1 新建 + 2 新建测试）

### 3.1 上次配置恢复与桥接横幅（任务 A）

- 新建 `apps/desktop-flutter/lib/services/last_config_store.dart`：`<dataDir>/last-config.json`，只存身份（sourceKey / recordId / kind / deviceUuid / interfaceKey / savedAt）。同步小文件 IO + tmp→rename 原子写，损坏即当没记录。刻意不塞进 `settings.json`——那里已有 `ui` 与 `sync` 两个写盘者。
- `apps/desktop-flutter/lib/state/app_state.dart`：
  - `bootstrap()` 读取记忆，命中且与 `is_active` 不同则 `activateConfig` 切换；
  - `activateConfigRecord` 成功路径与 `importConfig` 成功路径写记忆（自动接入等后台动作不写）；
  - 新增 `sourceKeyOfRecord`（与 `activeSourceKey` 同源，避免恢复判定与当前源定义漂移）；
  - 新增 `deviceAddressForUuid` / `deviceNameForUuid` / `activateConfigBySourceKey` / `lastConfigRecordAliveFor`。
- `apps/desktop-flutter/lib/state/sync_state.dart`：新增 `probeAutoConnectTarget(address)`（失败会写 `lastError` 供横幅原样分类），与 `tryAutoConnect` 共用抽出的 `_probeAndRemember`。
- `apps/desktop-flutter/lib/ui/app.dart`：`_maybeAutoConnect` → `_restoreLastConfig` 状态机，新增 `BridgeRestoreBanner`（重试 / 切换播放源 / 关闭）。

启动分支（四条，全部只探测一次）：

1. 无记忆 + 当前配置是本地源 → 零探测，直接加载首页（与升级前一致）。
2. **无记忆 + `is_active` 是桥接源**（旧版本升级上来的真实场景）→ 按 deviceUuid 兜底推断一条不落盘的记忆，照常探一次；不可达则出横幅。
3. 记忆是本地源 → 按记忆恢复，零探测。
4. 记忆是桥接源 → 探一次 → 成功则按 `interfaceKey` 只重拉该源并精确激活该 `sourceKey`；失败则出横幅，文案含设备名、地址与失败分类（`bridgeUnreachable` / `bridgeNoGateway` / `bridgeHostMismatch` 不折叠）。

### 3.2 线路级轨道记忆（任务 B）

- `apps/desktop-flutter/lib/core/player_tracks.dart`：新增纯逻辑 `PlayerTrackSlot`（audio/video/subtitle）、`TrackChoice{engineId,language,title}`、`trackChoiceKey`、`matchTrackChoice`（三级回落）、`applyTrackChoice`、`shouldAttemptTrackChoice`。
- 记忆键：`siteKey\0vodId\0flag\0(episodeId‖episodeName)\0slot`。用 NUL 分隔，因为集名/线路名可能含 `|`、`-`、空格。
- `apps/desktop-flutter/lib/services/ui_preferences_store.dart`：`ui.trackChoices` 段，上限 500 条按插入顺序 LRU 裁剪，重选同一条挪队尾。
- `apps/desktop-flutter/lib/ui/player_controller.dart`：抽出 `audioTrackInfos` / `videoTrackInfos` / `embeddedSubtitleTrackInfos`（引擎原文，菜单标签拼过语言与序号，不能用于 title 回落）。
- `apps/desktop-flutter/lib/ui/player_page.dart`：`_load()` 时重读本集记忆；轨道表就绪后应用一次；只在用户**显式选择**时写入（自动回落的结果绝不写回）；字幕只记内嵌轨（外挂/本地/网络字幕仍由 `SubtitleMatchRecord` 另管）；`_configureSubtitles` 增加「本集记过内嵌字幕且可命中」守卫，避免外挂默认字幕按后到的时序顶掉用户选择。

## 四、复核发现并已修复的 2 个缺陷（各重派一轮，run 2/3）

| 缺陷 | 证据 | 修法 |
| --- | --- | --- |
| 首轮删除旧 `_maybeAutoConnect` 后，无 `last-config.json` 且 `is_active` 是桥接源的升级用户失去自动探测——首页加载失败且连横幅都不出现 | `ui/app.dart` 首轮 `memory == null → _loadInitialHome()` 直接返回 | 新增 `_inferBridgeMemoryFromActive()` 兜底分支（只对桥接源推断，不落盘），测试拆成验收 1a（本地源零探测）/ 1b（桥接源探一次并出横幅） |
| `_appliedTrackChoices.add(slot)` 发生在匹配之前；引擎轨道表分次上报（`player_controller.dart:686`），首帧只报 `auto` 时槽被标记已应用，三级回落过滤伪轨返回 null → 该槽永久失配 | 首轮 `player_page.dart` 的 `if (infos.isNotEmpty) { _appliedTrackChoices.add(slot); ... }` | 抽出 `shouldAttemptTrackChoice`（按轨道 id 列表去重），只在真正命中后才标记已应用 |

## 五、验收证据（全部我自己复跑，非子代理自报）

- `flutter test --concurrency=1 test/phase10_last_config_test.dart` → **+10 All tests passed**
- `flutter test --concurrency=1 test/phase10_track_memory_test.dart` → **+33 All tests passed**
- `flutter analyze lib test` → **No issues found!**（全树）
- 串行回归 14 个相邻测试文件（启动 / 配置 / 同步 / 播放器 / 字幕 / 偏好 / 历史 / 实时）→ **+236 All tests passed**
- **全量 `flutter test` → +3082 All tests passed**（干净全绿基线）
- `git status`：仅 7 个改造文件 + 3 个新增文件；无 debug print、无 TODO、无新增依赖、未做 git 写操作。

工作区改动（未提交）：

```
 M apps/desktop-flutter/lib/core/player_tracks.dart
 M apps/desktop-flutter/lib/services/ui_preferences_store.dart
 M apps/desktop-flutter/lib/state/app_state.dart
 M apps/desktop-flutter/lib/state/sync_state.dart
 M apps/desktop-flutter/lib/ui/app.dart
 M apps/desktop-flutter/lib/ui/player_controller.dart
 M apps/desktop-flutter/lib/ui/player_page.dart
?? apps/desktop-flutter/lib/services/last_config_store.dart
?? apps/desktop-flutter/test/phase10_last_config_test.dart
?? apps/desktop-flutter/test/phase10_track_memory_test.dart
```

## 六、已识别并已路由的风险（无遗留未处理项）

1. **升级退化**（无记忆但 is_active 是桥接源）→ 已带证据重派修复 + 新增回归锁，见第四节。
2. **伪轨首帧永久失配** → 已重派修复 + 新增 5 条纯函数单测，见第四节。
3. **全量测试假失败**（`flutter test` 报 `failed to delete ... sqlite3.dll`）→ 已定为环境问题（并行 `flutter_tester.exe` 持有 DLL），处理办法：跑前 `Stop-Process flutter_tester`。已在全量复跑中验证消除，无代码改动需求。
4. **`tryAutoConnect` 现仅测试调用**（旧「历史最近地址自动接入」路径被新的按记忆恢复取代）→ 有意保留方法以不破坏 phase5 既有用例；生产路径改由 `probeAutoConnectTarget` 承担，语义更精确（按 deviceUuid 而非「最近接入地址」）。

## 七、调试注意

- `importConfig` 现在也会写 `last-config.json`。模拟「从旧版本升级上来」的用例必须在 `importConfig` **之后**主动删除该文件再断言。
- `usage-boundary-accepted` 标记文件必须在 `AppState.bootstrap()` **之后**写（configDir 由 bootstrap 创建）。
- flutter 不在 PATH：`C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat`（Flutter 3.47.5 / Dart 3.13.4）。
