# 证据 03 · 按钮排版与配置

对应 `design/03-button-layout-and-config.md`。本文件记录**归一化的输入/输出对照**
与**配置页的实测行为**。

---

## 1. 可配置集合：9 个（上游 32 个）

`lib/core/player_buttons.dart:95-141` 的 `kPlayerButtons`：

| # | id | 中文名 | 分组 |
| --- | --- | --- | --- |
| 1 | `prev` | 上一集 | 传输 |
| 2 | `play` | 播放/暂停 | 传输 |
| 3 | `next` | 下一集 | 传输 |
| 4 | `mute` | 静音 | 音量 |
| 5 | `volume` | 音量 | 音量 |
| 6 | `speed` | 倍速 | 速率与线路 |
| 7 | `line` | 线路 | 速率与线路 |
| 8 | `episodes` | 剧集 | 速率与线路 |
| 9 | `fullscreen` | 全屏 | 显示 |

`defaultButtonOrder()` = 定义顺序，与改造前的实际排布一致
（`player_page.dart:2144-2239`）—— 可配置性是**新能力**，不是重新设计。

## 2. 被排除的 27 个上游 id 及理由

逐条写在 `lib/core/player_buttons.dart:60-94` 的文档注释里（源码即证据）。
摘要：

| 类别 | 上游 id | 排除理由 |
| --- | --- | --- |
| 无对应能力 | `cast`、`pan_diagnostic`、`ad_feedback`、`opening`、`ending`、`quality` | PC 端没有投屏 / 网盘诊断 / 广告反馈 / 片头尾跳过 / 多清晰度 |
| 归别处 | `parse`、`multi_thread_proxy`、`scale`、`reset`、`search`、`display`、`title`、`change`、`text`、`audio`、`video` | 分别归站点配置、代理配置、顶栏菜单、右键菜单、详情页、屏显设置、顶栏 |
| **测试锁定** | `subtitle`、`danmaku` | 见下节 |

## 3. 为什么 `subtitle` / `danmaku` 不进配置集合

它们现状在**顶栏**，且被集成测试按**精确 tooltip** 直接 `tap`：

- `integration_test/subtitle_flow_test.dart:144,153`
- `integration_test/danmaku_flow_test.dart:156,175`

`find.byTooltip` 对 String 是**精确匹配**（只有 `RegExp` 才做子串，
见 flutter_test `finders.dart:407`）。用户一隐藏，测试就红。

且顶栏只有 3 个常驻控件，**没有拥挤问题**，不需要用户来裁剪。
详见 `design/03` §5.3。

## 4. 归一化的输入/输出对照（实测）

`normalizeButtonOrder` / `normalizeButtonHidden` 的契约是
「**输入任意，输出合法**」：缺失项补到末尾、未知项丢弃、重复项去重。

| 输入 | `normalizeButtonOrder` 输出 |
| --- | --- |
| `[]` | 全部 9 项（定义顺序） |
| `['fullscreen']` | `fullscreen` + 其余 8 项按定义顺序补到末尾 |
| `['speed', 'speed', 'play']` | `speed`, `play` + 其余 7 项（重复的 `speed` 只留一个） |
| `['nonsense', 'play']` | `play` + 其余 8 项（未知 id 丢弃） |
| `['  play  ', 'next']` | `play`, `next` + 其余（**前后空白被 trim**） |
| 含 `null` / 非字符串 | 跳过该项，其余照常 |

| 输入 | `normalizeButtonHidden` 输出 |
| --- | --- |
| `[]` | `{}` |
| `['speed']` | `{'speed'}` |
| `['speed', 'speed']` | `{'speed'}` |
| `['nonsense']` | `{}`（未知 id 丢弃） |
| `['  speed  ']` | `{'speed'}`（trim） |
| **传入 `Set` 而非 `List`** | **`{}`（空集）** ← 见下节 |

### 4.1 一个真实的踩坑：`Set` 会被静默吞掉

`normalizeButtonHidden` 只接受 `List` 与 `String`。传 `Set` 时它
**不报错**，直接返回**空集**。实测：

```
normalizeButtonHidden({'speed', 'line'})  →  {}
```

后果：用户的隐藏设置被静默忽略，且测试如果只断言"结果是一个集合"就全绿。

修法：`ui_preferences_store.dart:157` 的 getter 显式转换 ——

```dart
Set<String> get buttonHidden => normalizeButtonHidden(_buttonHidden?.toList());
```

**教训**（已写进 `progress.md` 的 R15）：brief 预检必须检查**参数类型**，
不只是符号名。静态读代码看不出这个——`Set` 与 `List` 都是 `Iterable`。

## 5. 落盘格式（实测）

`lib/services/ui_preferences_store.dart:511-521`：

```dart
final order = _buttonOrder;
final hidden = _buttonHidden;
if (order != null || hidden != null) {
  ui['playerButtons'] = <String, Object?>{
    'order': ?order,
    if (hidden != null) 'hidden': hidden.toList()..sort(),
  };
}
```

| 场景 | `settings.json` 的 `ui.playerButtons` |
| --- | --- |
| 全新安装 | **没有该键** |
| 只改顺序 | `{"order": [9 项]}` |
| 只隐藏 | `{"hidden": ["speed"]}` |
| 都改 | `{"order": [...], "hidden": ["speed"]}` |

两个键**各自独立**；都缺席时整个 `playerButtons` 不写。

`hidden` 落盘时**排序**（`..sort()`）—— 集合无序，排序让文件内容稳定，
便于 diff 与逐字节比较。

**兼容读**：读入时 `order` 接受 JSON 数组**或**逗号分隔字符串
（上游格式），见 `design/05` §7 第 4 条。

## 6. 配置页实测

`lib/ui/player_button_config_page.dart`：

| 行为 | 实测 |
| --- | --- |
| 拖动排序 | 用 `ReorderableListView`，`buildDefaultDragHandles: true` |
| 平台 | 桌面平台才插 `Icons.drag_handle` 手柄；`flutter_test` 默认 android，**必须显式** `debugDefaultTargetPlatformOverride = TargetPlatform.windows`，否则手柄断言恒真 |
| 开关 | `setState` **先于** `await`（store 同步改内存再返回 `_persist()`；先 await 会导致开关在假时钟下永不更新） |
| 恢复默认 | 二次确认对话框；确认后**立即**刷新页面顺序（同样先 `setState`） |
| 预览 | 复用 `resolveVisibleButtons`，不重复实现顺序+过滤逻辑 |

### 6.1 拖动方向：`onReorderItem` 与 `onReorder` 的差异

`reorderable_list.dart:1016-1030` 只在 `onReorderItem` 分支应用 `-1` 调整
（1017-1020 = `onReorder`，不调整；1022-1025 = 应用 `-1`）。
用 `onReorderItem` 时**不能再手动减一**，否则向下拖动会多减一次。

**为什么 brief 的测试测不出**：它的用例只做**向上**拖动（−60），
此时 `newIndex > oldIndex` 恒为 `false`，走不到出问题的那条分支。
现行套件补了**向下**拖动的用例。

## 7. 单行不换行（`design/03` §5.4）

`PlayerOverlayActionRow` 用：

```dart
SingleChildScrollView(
  scrollDirection: Axis.horizontal,
  child: Row(mainAxisSize: MainAxisSize.min, ...),
)
```

窄窗口实测（`docs/phase8/evidence/screenshots/player-narrow-1024x640.png`，
1024×640）：控制栏**单行、不换行、无溢出**，`倍速 1.0×` 下拉与全屏图标都在。

**为什么不是 `Wrap`**：`Wrap` 在窄窗口会把按钮换到第二行，
控制栏高度翻倍——而高度变化正是本轮要消灭的东西
（见 `evidence/01-overlay-layout.md`）。**实测**：把实现换成 `Wrap`，
`test/phase8_player_page_overlay_test.dart` 变红（反向验证第 10 项）。

## 8. 反向验证

`tools/phase8/verify_reverse_checks.py` 里与本子系统相关的三项：

| # | 破坏 | 必须变红的套件 |
| --- | --- | --- |
| 4 | 顺序归一化不再补全缺失项 | `test/phase8_player_buttons_test.dart` |
| 9 | 把 `subtitle` 加入可配置集合 | `test/phase8_player_buttons_test.dart` |
| 10 | 控制栏改回 `Wrap` | `test/phase8_player_page_overlay_test.dart` |

三项均实测「按预期失败」，且还原后工作区干净（G5 十项全过）。
