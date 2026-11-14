# 播放器浮层改造：悬浮控制栏 + 屏显 + 右键菜单 + 按钮排版（设计指导 · 总索引）

- 状态：设计指导（Design Guidance），**待评审**
- 日期：2026-10-18
- 适用工程：`apps/desktop-flutter`（WebHTV PC，Flutter + media-kit 主线）
- 上游参考：`webhtv/默影视`（Android 工程，`F:\Workspace\webtv4\webhtv`）
- 主设计文档：`docs/webhtv-pc-design.md`（本文档是它的 Phase 8 展开）
- 阶段计划：`docs/phase8/README.md`

---

## 0. 一句话目标

把播放器的控制栏从**挤占布局的兄弟节点**改成**叠在画面上的半透明浮层**，
并补齐主流桌面播放器（PotPlayer / mpv / VLC）已经具备的三件事：
**屏显（OSD）**、**右键设置菜单**、**可配置的按钮排版**。

---

## 1. 用户诉求（原文）

> 现在每次唤醒控制台都会导致画面缩放（应该是被上下的控制栏挤占了位置）能否参考安卓版/
> 默影视（F:/Workspace/webtv4/webhtv）把控制台改成半透明的悬浮显示这样应该就不会挤占了，
> 还有参考 potplayer 的那种右键设置功能这样在 PC 上应该更好交互，还有屏显等主流播放器功能
> 和播放器按钮排版优化包含控制栏。

拆成四件事，对应本文档的四个子系统。

---

## 2. 为什么需要独立设计文档

本轮不是一处样式调整，而是**播放器页的布局模型变更**：

| # | 子系统 | 性质 | 上游依据 |
| --- | --- | --- | --- |
| A | 控制栏改悬浮浮层（消除画面缩放） | **布局模型变更**（`Column` 兄弟 → `Stack` 浮层） | `activity_video.xml` 的 `FrameLayout` 重叠结构 |
| B | 屏显（OSD） | 新增子系统（四角信息层 + 诊断面板 + 迷你进度条） | `PlayerOsdController` / `view_player_osd.xml` |
| C | 右键设置菜单 | 新增交互面（桌面专属，上游无对应物） | PotPlayer 惯例；上游 `ControlDialog` 作为**内容**依据 |
| D | 按钮排版可配置（隐藏 + 重排） | 新增持久化配置 + 渲染顺序契约 | `PlayerButtonSetting` |

**A 是根因修复，B/C/D 是能力补齐。** A 单独就能解决用户投诉的"画面缩放"；
但只做 A 会让"控制栏浮起来之后，那些原本靠顶栏承载的信息去哪了"变成新的空洞——
这正是 B 存在的理由。C 与 D 是桌面交互质量，与 A/B 无依赖关系，可独立验收。

---

## 3. 根因（源码级证据）

### 3.1 画面缩放的确切原因

`apps/desktop-flutter/lib/ui/player_page.dart:1400-1473`：

```dart
body: Column(
  children: [
    Expanded(                                  // ← 视频区
      child: GestureDetector(child: Stack([Video, DanmakuOverlay, ...])),
    ),
    if (_controlsVisible)                      // ← 控制条是**兄弟节点**
      Listener(child: _ControlBar(...)),
  ],
),
```

| 事实 | 位置 | 后果 |
| --- | --- | --- |
| 控制条是 `Column` 的兄弟节点 | `player_page.dart:1458-1472` | `_controlsVisible` 一变，`Expanded` 可用高度少/多约 90px |
| 视频用 `BoxFit.contain` | `player_page.dart:1413-1417`（`PlayerVideoFitMode.contain`） | 容器高度变化 → 按比例重新居中 → **整幅画面缩放并位移** |
| 顶栏是 `Scaffold.appBar`，非全屏时常驻 | `player_page.dart:1304-1399` | 唤醒控制条时顶栏不参与变化，所以只有底部在跳 |
| 全屏时顶栏置 `null` | `player_page.dart:1304` | 进出全屏又是一次同样的跳变（额外 56px） |
| 控制条 4 秒后自动隐藏 | `player_page.dart:1513-1516` | 每次唤醒/隐藏都触发一次上述跳变，形成"闪一下"的观感 |

**结论：不是"控制栏太宽"，是"控制栏参与了布局"。**

### 3.2 安卓参考给出的答案

`F:\Workspace\webtv4\webhtv\app\src\mobile\res\layout\activity_video.xml:30-98`：

```xml
<FrameLayout android:id="@+id/video" ...>
    <androidx.media3.ui.PlayerView android:id="@+id/exo" ... />
    <include android:id="@+id/widget"   layout="@layout/view_widget_vod" ... />
    <include android:id="@+id/control"  layout="@layout/view_control_vod"  ... />
    <include android:id="@+id/progress" layout="@layout/view_progress"     ... />
    <include android:id="@+id/osd"      layout="@layout/view_player_osd"   ... />
</FrameLayout>
```

四个子项全部 `match_parent`，**并列重叠**。控制栏与屏显都不占布局空间。
控制栏底色 `@color/black_20` = `#33000000`（20% 黑，半透明悬浮）。

### 3.3 现状与目标的差异表

| 维度 | 现状（PC） | 目标 | 上游 |
| --- | --- | --- | --- |
| 控制栏定位 | `Column` 兄弟，挤占高度 | `Stack` 浮层，不占布局 | ✅ 同构 |
| 控制栏底色 | `surface @ 0.88`（主题相关） | 固定深色纱（亮画面对比度可控） | `#33000000` |
| 顶栏 | 常驻 `AppBar`（全屏时消失） | 与底栏同属一个自动隐藏浮层 | 控制栏自带 `top` 行 |
| 屏显 | **无** | 四角 + 诊断面板 + 迷你进度条 | ✅ 同构 |
| 右键菜单 | **无** | 播放器页右键菜单 | 上游无（桌面专属） |
| 按钮可配置 | **无** | 隐藏 + 重排 + 落盘 | ✅ 同构 |

---

## 4. 上游实测契约（源码级证据）

上游工程根：`F:\Workspace\webtv4\webhtv`。

### 4.1 屏显（OSD）—— `ui/custom/PlayerOsdController.java`

| 事实 | 位置 | 含义 |
| --- | --- | --- |
| 屏显是**独立于控制栏的一层** | `view_player_osd.xml` 与 `view_control_vod.xml` 平级 include | 两者互不包含，各自可独立显隐 |
| 布局是**四角 + 诊断面板 + 迷你进度条** | `view_player_osd.xml:12-151` | 上左标题/分辨率、上右时钟、下左进度、下右网速、顶部诊断面板、底部 2dp 进度条 |
| 内边距 `14dp` | `view_player_osd.xml:15` | 四角文本距屏幕边缘的取值 |
| 文本 14sp、`tnum` 表格数字、`shadowRadius=2` 描边 | `view_player_osd.xml:24-30` | 亮画面上可读的做法是**阴影描边**，不是底色块 |
| 刷新周期 **1000ms** | `PlayerOsdController.java:193`（`App.post(update, 1000)`） | 时钟与网速按秒刷新 |
| **控制栏可见时**强制显示 标题/分辨率/时钟，隐藏 进度/网速/诊断/迷你条 | `PlayerOsdController.java:208-220` | 控制栏自己**没有** title/size（`view_control_vod.xml:47-59` 注释说明 mobile 有、leanback 没有），所以屏显要补位 |
| **控制栏隐藏时**按用户开关显示 | `PlayerOsdController.java:222-244` | 开关全关则整层隐藏并停止刷新 |
| 屏显全关但控制栏可见时**仍需启动刷新循环** | `PlayerOsdController.java:119-124, 152-158` | 注释明说：控制栏显示时需要强制显示时间 |
| 诊断面板宽度 = 视口 `0.98`，高度上限 = 视口 `0.84`（横屏） | `PlayerOsdController.java:324, 335` | 诊断是**大面板**，不是小角标 |
| 诊断字号 9sp / 横屏 10.2sp，等宽字体，`textScaleX 0.92` | `view_player_osd.xml:118-119`、`PlayerOsdController.java:343-347` | 密集信息用小字号 + 压缩字宽 |
| 直播时隐藏进度与迷你条 | `PlayerOsdController.java:280, 356`（`player.isLive()`） | 直播没有总时长，进度无意义 |
| 7 个开关 | `setting/PlayerSetting.java:562-563` | `time/traffic/size/progress/mini/title` + `player_osd_diagnostics` |
| 默认值：`size`/`progress`/`title` = **true**，其余 false | `PlayerSetting.java:508-560` | 默认只开三项 |
| 旧键 `player_osd_*` → 新键 `display_*` 有一次迁移 | `PlayerSetting.java:934-945` | 迁移只在旧键存在且新键全缺时发生 |

### 4.2 控制栏 —— `view_control_vod.xml`

| 事实 | 位置 | 含义 |
| --- | --- | --- |
| 根容器 `match_parent` + `black_20` 半透明底 | `view_control_vod.xml:7-8` | 浮层底色 |
| 三段结构：`top` / `center` / `bottom` | `view_control_vod.xml:12, 202, 249` | 顶栏、中央传输键、底部进度+动作行 |
| 顶栏高 `?attr/actionBarSize` | `view_control_vod.xml:15` | 与系统 ActionBar 同高 |
| 顶栏：返回 + 标题/分辨率 + 右侧 48dp 图标 dock | `view_control_vod.xml:21-199` | 右侧是**图标 dock**（投屏/护眼/收藏/信息/屏显/设置） |
| 中央：上一集 40dp / 播放 48dp / 下一集 40dp，间距 40dp | `view_control_vod.xml:210-235` | 播放键最大、两侧对称留白 |
| 底部：进度条 + 全屏（同行），下面是**横向滚动的动作行** | `view_control_vod.xml:270-298` | 动作行溢出时横向滚动，不换行 |
| 动作行是 32 个文字按钮的横向列表 | `view_control_vod_action.xml:11-166` | 全部同一样式 `@style/Control` |

### 4.3 按钮排版可配置 —— `setting/PlayerButtonSetting.java`

| 事实 | 位置 | 含义 |
| --- | --- | --- |
| **32 个按钮 id** | `PlayerButtonSetting.java:21-52` | 见 §4.4 清单 |
| 默认顺序是 `DEFAULT` 列表顺序 | `PlayerButtonSetting.java:57-89` | 见 §4.4 清单 |
| 其中 `MULTI_THREAD_PROXY` 默认不可见 | `PlayerButtonSetting.java:61`（`new Item(..., false)`） | 默认隐藏项 |
| 顺序存 `player_button_order`（逗号分隔） | `PlayerButtonSetting.java:54, 130, 137` | 落盘格式 |
| 隐藏集存 `player_button_hidden`（逗号分隔） | `PlayerButtonSetting.java:55, 120` | 落盘格式 |
| 首次运行**播种一次**默认隐藏项到 `player_button_hidden` | `PlayerButtonSetting.java:220-225`（`HIDDEN_SEEDED`） | 之后完全以用户选择为准 |
| 读取顺序时：先取已存顺序（过滤非法 id），再补全 `DEFAULT` 中缺失项 | `PlayerButtonSetting.java:210-215` | **新增按钮自动追加**，不会因为老配置而消失 |
| 重排时**只替换受管槽位**，保留固定占位与特性按钮 | `PlayerButtonSetting.java:161-177` | 动作行里有非受管子项 |
| 重排后重建焦点链 | `PlayerButtonSetting.java:179-200` | 键盘可达性 |

### 4.4 32 个按钮 id 与默认顺序（逐字抄录）

```
player, decode, play_params, multi_thread_proxy(默认隐藏), codec_capability,
speed, scale, quality, lut, pan_diagnostic, karaoke, immersive_audio, reset,
search, repeat, parse, display, text, audio, video, opening, ending, danmaku,
ad_feedback, title, prev, next, episodes, fullscreen, change, cast, timer
```

**PC 端只取其中可用子集**（见 `03-button-layout-and-config.md` §3）——
`decode`/`codec_capability`/`lut`/`karaoke`/`immersive_audio`/`cast`/`timer`/
`pan_diagnostic`/`ad_feedback`/`opening`/`ending`/`parse` 在 PC 端**没有对应能力**，
不得为了对齐而伪造入口（`PRODUCT.md` §Product Principles 第 5 条）。

### 4.5 右键菜单（上游无对应物，依据来自桌面惯例 + 上游 `ControlDialog`）

| 事实 | 位置 | 含义 |
| --- | --- | --- |
| 上游 `ControlDialog` 是**底部抽屉**，不是右键菜单 | `ui/dialog/ControlDialog.java` | 移动端没有右键，PC 端要自己定形态 |
| 抽屉内容分组：速度滑杆 + 10 档预设、画面比例、显示开关 7 项、音轨/字幕/视频轨、重置、剧集列数 | `ControlDialog.java:279-343` | 这是**内容**的可信依据 |
| 抽屉无遮罩（`setDimAmount(0f)`） | `ControlDialog.java:264-265` | 设置面板不压暗画面 |
| 上游手势无右键语义 | `ui/custom/PlayerGesture.java`（只有单击/双击/长按/滑动/缩放） | PC 右键语义需新定义 |

---

## 5. 不可退让的边界

1. **控制栏与屏显一律不得参与布局。** 两者必须是 `Stack` 的 `Positioned` 子项；
   任何"用 `Column`/`Row` 给它们留位置"的写法都直接违反本轮的根因修复。
   **可机器验证**：视频区尺寸在控制栏显隐前后必须逐像素相同（见 `04` §3.1 的 V1）。
2. **四个 tooltip 的精确串不得改，也不得收进菜单**：
   `'字幕轨'`、`'弹幕（开启）'` / `'弹幕（关闭）'`、`'全屏（F11）'`、`'更多'`。
   证据：`integration_test/ui_redesign_visual_flow_test.dart:671-693`、
   `integration_test/subtitle_flow_test.dart:144,153`、
   `integration_test/danmaku_flow_test.dart:156,175`。
   `find.byTooltip` 对 `String` 是**精确匹配**（只有 `RegExp` 才子串匹配）。
3. **`'更多'` 必须仍在 `AppBar` 内**（`ui_redesign_visual_flow_test.dart:677-681`
   用 `find.descendant(of: find.byType(AppBar), ...)` 断言）。
   因此"顶栏改浮层"**不得**把 `AppBar` 换成自绘容器——
   要么保留 `AppBar`（放在浮层里），要么同步改这条断言（见 `04` §5 的决策）。
4. **不得引入阴影或非 0 elevation**（`DESIGN.md` The Flat-Field Rule）。
   浮层的层级靠**半透明纱 + 发丝边**表达，不靠投影。
5. **不得改 Material 3 的字号与行高**（`DESIGN.md` The Metric-Neutral Rule）。
   本轮新增的屏显文本字号必须**显式指定**，不得通过改 `textTheme` 实现。
6. **字重只用 400 / 700**（`DESIGN.md` The Real-Weight Rule）。
7. **屏显的"未知"必须如实。** 拿不到的分辨率、码率、网速显示为「未知」或直接隐藏，
   **不得**填 0 或用平均值假装（`PRODUCT.md` §Product Principles 第 2 条）。
8. **按钮配置只允许追加，不得删除既有 id 的语义。** 老配置里的 id 必须继续被识别；
   新增 id 自动追加到顺序末尾（对齐上游 `PlayerButtonSetting.java:210-215`）。
9. **按钮配置必须可恢复默认。** 一个"改乱了回不去"的配置是不可接受的
   （对齐上游 `reset()`，`PlayerButtonSetting.java:140-144`）。
10. **右键菜单不得成为唯一入口。** 菜单里的每一项都必须存在非右键的等价路径
    （顶栏菜单 / 底部控制栏 / 快捷键），否则纯键盘用户不可达
    （`PRODUCT.md` §Accessibility 的"键盘可达"）。
11. **屏显与右键菜单都不得阻断播放。** 与字幕/弹幕同一口径（`docs/webhtv-pc-design.md` §10.4）。
12. **不得改动测试锁死的结构**：`Video`、`DanmakuOverlay`、`PlayerPage` 的类型与
    `find.byType` 可达性；`phase3_player_display_test.dart` 锁定的
    `PlayerVideoFitMode` 五个枚举值与 label 字面值、`resolvePlayerGesture` 的
    **两个分支**（桌面语义，见 `01` §4.6）、`PlayerSubtitleStyle` 的默认值。

---

## 6. 与主设计文档的关系

| 主文档章节 | 本轮影响 |
| --- | --- |
| §10.3 播放器 | 布局模型改写（`Column` → `Stack`）；新增屏显层 |
| §17.3 播放器页 | 顶栏与底栏合并为一个自动隐藏浮层；新增右键菜单 |
| §17.4 键盘导航 | 新增右键菜单的键盘等价路径；快捷键表可能扩展 |
| §17.5 弹幕可调项 | 弹幕设置从底部抽屉迁入右键菜单（保留顶栏入口） |
| §21 Phase 3 | 不涉及 |
| §23 播放诊断 | 诊断面板从对话框升级为屏显面板（对话框保留） |

---

## 7. 子文档

| 文档 | 内容 |
| --- | --- |
| `01-overlay-layout.md` | 子系统 A：`Stack` 浮层布局、自动隐藏、进出全屏、视频区尺寸不变式 |
| `02-osd.md` | 子系统 B：屏显四角、诊断面板、迷你进度条、开关与默认值、与控制栏的联动 |
| `03-button-layout-and-config.md` | 子系统 D：PC 端可用按钮子集、默认分组与顺序、隐藏/重排、持久化 |
| `04-context-menu.md` | 子系统 C：右键菜单形态、分组、键盘等价路径、与既有入口的去重 |
| `05-test-and-acceptance.md` | 测试矩阵、反向验证、门禁表、证据落盘 |
