# 03 · 按钮排版与可配置（隐藏 + 重排）

- 状态：设计指导，**待评审**
- 日期：2026-10-18
- 上游参考：`F:\Workspace\webtv4\webhtv\app\src\main\java\com\fongmi\android\tv\setting\PlayerButtonSetting.java`、
  `app\src\main\java\com\fongmi\android\tv\ui\dialog\PlayerButtonConfigDialog.java`
- 关联：`00` §4.3、`01` §4、`04`、`05`
- PC 端落点：新增 `apps/desktop-flutter/lib/core/player_buttons.dart`、
  `apps/desktop-flutter/lib/ui/player_button_config_page.dart`；
  修改 `apps/desktop-flutter/lib/ui/player_page.dart`、
  `apps/desktop-flutter/lib/services/ui_preferences_store.dart`

---

## 1. 目标

把底部控制栏从"一排写死的控件"改成**由配置驱动的有序列表**：
用户可以隐藏不需要的按钮、调整顺序，配置落盘并在下次播放生效。

---

## 2. 上游契约

| 事实 | 位置 | PC 端落点 |
| --- | --- | --- |
| 32 个按钮 id，常量字符串 | `PlayerButtonSetting.java:21-52` | §3.1（取子集） |
| 默认顺序 = `DEFAULT` 列表顺序 | `PlayerButtonSetting.java:57-89` | §3.2 |
| 默认隐藏项标记在 `Item(..., false)` | `PlayerButtonSetting.java:61` | §3.2 |
| 顺序存逗号分隔字符串 | `PlayerButtonSetting.java:54, 130` | §4.1 |
| 隐藏集存逗号分隔字符串 | `PlayerButtonSetting.java:55, 120` | §4.1 |
| 首次运行播种一次默认隐藏项 | `PlayerButtonSetting.java:220-225` | §4.2 |
| 读取时先取已存顺序（过滤非法），再补全缺失项 | `PlayerButtonSetting.java:210-215` | §4.3 |
| 重排只替换受管槽位，保留非受管子项 | `PlayerButtonSetting.java:161-177` | §5.2 |
| 有 `reset()` | `PlayerButtonSetting.java:140-144` | §4.4 |

---

## 3. PC 端可用按钮子集

### 3.1 取舍原则

**只保留 PC 端有真实实现的按钮。** `PRODUCT.md` §Product Principles 第 5 条
（"不承诺能力范围"）与 `DESIGN.md` 关于筛选按钮的教训（"一个点了什么也没有的按钮
比没有按钮更糟"）都指向同一条：**不得为了对齐上游而伪造入口**。

### 3.2 保留的按钮（13 个存在，其中 8 个可配置）

| id | 中文名 | 现状来源 | 默认 | 分组 | **可配置** |
| --- | --- | --- | --- | --- | --- |
| `prev` | 上一集 | `player_page.dart:2144-2148` | ✅ | 传输 | ✅ |
| `play` | 播放/暂停 | `2149-2155` | ✅ | 传输 | ✅ |
| `next` | 下一集 | `2156-2160` | ✅ | 传输 | ✅ |
| `mute` | 静音 | `2164-2174` | ✅ | 音量 | ✅ |
| `volume` | 音量滑杆 | `2175-2182` | ✅ | 音量 | ✅ |
| `speed` | 倍速 | `2184-2202` | ✅ | 速率/选集 | ✅ |
| `episodes` | 剧集 | `2220-2225` | ✅ | 速率/选集 | ✅ |
| `fullscreen` | 全屏 | `2235-2239` | ✅ | 显示 | ✅ |
| `subtitle` | 字幕轨 | 顶栏 `1314-1318` | ✅ | 轨道 | ❌ |
| `danmaku` | 弹幕开关 | 顶栏 `1319-1327` | ✅ | 轨道 | ❌ |
| `video_fit` | 画面比例 | 顶栏菜单 `1370-1374` | ✅ | 显示 | ❌ |
| `media_info` | 媒体信息 | 顶栏菜单 `1375-1379` | ✅ | 显示 | ❌ |
| `diagnostics` | 播放诊断 | 顶栏菜单 `1382-1390` | ✅ | 显示 | ❌ |

**这张表的读法**：13 个是"PC 端存在的按钮"，其中 5 个
（`subtitle` / `danmaku` / `video_fit` / `media_info` / `diagnostics`）**不进入
可配置集合**——它们要么在顶栏常驻（被测试锁定），要么是菜单项。

**`kPlayerButtons` 恰好 8 项**，理由见 §5.3。实现时若按 13 项去做，
`phase8_player_buttons_test.dart` 的 D1（长度 = 8）会直接失败。

**`line`（线路下拉）已删除**：动作行里那条线路下拉是重复入口——切线路并入了
选集面板（那一屏本来就要回答「哪条线路的哪一集」）。删除后 `line` 不再属于
任何集合，老配置里存过的 `line` 会被 `normalizeButtonOrder` 当非法 id 过滤掉。

### 3.3 明确排除的上游 id（27 个）

上游 32 个 id 里，PC 端**只沿用 5 个**（`speed` / `prev` / `next` / `episodes` /
`fullscreen`），其余 **27 个全部排除**：

| 上游 id | 排除理由 |
| --- | --- |
| `decode` | PC 端只有 media-kit 一个引擎（`PlaybackEngine.mediaKit`），无解码器切换 |
| `codec_capability` | PC 端无硬件解码能力探测 |
| `lut` | 未实现 |
| `karaoke` / `immersive_audio` | 未实现 |
| `cast` | 未实现（无 DLNA/投屏） |
| `timer` | 未实现（无睡眠定时） |
| `pan_diagnostic` | 未实现（无网盘专用诊断） |
| `ad_feedback` | 未实现（无广告反馈） |
| `opening` / `ending` | 未实现（无片头片尾跳过） |
| `parse` | 解析线路由站点配置决定，PC 端不暴露手动切换 |
| `player` | 无引擎切换 |
| `play_params` | 无播放参数面板 |
| `multi_thread_proxy` | 代理是站点级配置，不是播放器按钮 |
| `quality` | 无多清晰度（站点给的是线路，切线路归详情页与选集面板，`line` 也已移除） |
| `scale` | 画面比例归顶栏菜单与右键菜单（`02` §6、`04` §4.1），不占控制栏按钮位 |
| `reset` | PC 端的"重置"语义不明确（重置什么？），排除 |
| `search` | 播放中搜索是独立流程，不在播放器浮层 |
| `repeat` | 未实现（无循环模式） |
| `display` | 屏显开关归 `02` 的屏显设置，不占控制栏按钮位 |
| `title` | 标题归顶栏 |
| `change` | 换源是详情页动作 |
| `text` / `audio` / `video` | 轨道选择归顶栏（字幕轨）与右键菜单；PC 端无独立音轨/视频轨选择 UI |
| `danmaku` | 顶栏常驻（被测试锁定），不参与可配置集合（§5.3） |

**PC 端新增的 3 个 id（上游没有）**：

| id | 中文名 | 为什么上游没有 |
| --- | --- | --- |
| `play` | 播放/暂停 | 上游的播放键是**中央大按钮**（`view_control_vod.xml:219-226`），不在动作行里；PC 端把它放进动作行，因为它是最常碰的按钮 |
| `mute` | 静音 | 上游音量走手势（`PlayerGesture` 的滑动），PC 无手势 |
| `volume` | 音量滑杆 | 同上 |

**PC 端曾有第 4 个新增 id `line`（线路下拉），现已移除**：切线路并入选集面板，
动作行里不再保留重复入口（见 §3.2 末段）。

**这 27 个的排除理由必须写在代码注释里**，否则后续会有人"顺手补上"。
`kPlayerButtons` 的文档注释已逐条列出（见实现计划 Task 2）。

### 3.4 默认顺序

```
prev, play, next, │ mute, volume, │ speed, episodes, │ fullscreen
```

与现状一致（`player_page.dart:2144-2239`），**不改变用户已经熟悉的排布**。
可配置性是新能力，不是重新设计。

**分组分隔符**（`_controlBarDivider`，`player_page.dart:1901-1910`）**不是按钮**，
是渲染时按分组边界自动插入的，不可配置、不可隐藏。

---

## 4. 配置模型

### 4.1 数据结构

```dart
/// 一个可配置按钮的静态定义。
class PlayerButtonSpec {
  const PlayerButtonSpec({
    required this.id,
    required this.label,
    required this.group,
    this.defaultVisible = true,
  });
  final String id;          // 稳定标识，落盘用
  final String label;       // 中文名，配置页显示
  final PlayerButtonGroup group;
  final bool defaultVisible;
}

enum PlayerButtonGroup { transport, volume, rate, display, track }
```

**默认定义表**（`player_buttons.dart`，与 §3.2 逐行对应）：

```dart
const List<PlayerButtonSpec> kPlayerButtons = [
  PlayerButtonSpec(id: 'prev',       label: '上一集',   group: PlayerButtonGroup.transport),
  PlayerButtonSpec(id: 'play',       label: '播放/暂停', group: PlayerButtonGroup.transport),
  PlayerButtonSpec(id: 'next',       label: '下一集',   group: PlayerButtonGroup.transport),
  PlayerButtonSpec(id: 'mute',       label: '静音',     group: PlayerButtonGroup.volume),
  PlayerButtonSpec(id: 'volume',     label: '音量',     group: PlayerButtonGroup.volume),
  PlayerButtonSpec(id: 'speed',      label: '倍速',     group: PlayerButtonGroup.rate),
  PlayerButtonSpec(id: 'episodes',   label: '剧集',     group: PlayerButtonGroup.rate),
  PlayerButtonSpec(id: 'fullscreen', label: '全屏',     group: PlayerButtonGroup.display),
  PlayerButtonSpec(id: 'subtitle',   label: '字幕轨',   group: PlayerButtonGroup.track),
  PlayerButtonSpec(id: 'danmaku',    label: '弹幕',     group: PlayerButtonGroup.track),
  PlayerButtonSpec(id: 'video_fit',  label: '画面比例', group: PlayerButtonGroup.display),
  PlayerButtonSpec(id: 'media_info', label: '媒体信息', group: PlayerButtonGroup.display),
  PlayerButtonSpec(id: 'diagnostics',label: '播放诊断', group: PlayerButtonGroup.display),
];
```

### 4.2 落盘格式

`settings.json` 的 `ui` 段：

```json
{
  "ui": {
    "playerButtons": {
      "order": ["play", "prev", "next", "mute", "volume", "speed", "episodes", "fullscreen"],
      "hidden": ["media_info", "diagnostics"]
    }
  }
}
```

**与上游的差异**：上游用逗号分隔字符串（`"a,b,c"`），PC 端用 **JSON 数组**。
理由：PC 端已有 JSON 设置文件，数组可读性更好、无需处理转义；
且 id 里不含逗号（§3.2 的 8 个**可配置** id 全部是下划线/小写字母），两种格式等价。
**但必须处理上游格式的兼容**——见 §4.5。

### 4.3 读取时的归一化（纯函数）

```dart
/// 归一化顺序：过滤非法 id、去重、补全缺失项到末尾。
///
/// 对齐上游 `PlayerButtonSetting.getOrder()`（`PlayerButtonSetting.java:210-215`）：
/// 先取已存顺序里合法的项，再把 `kPlayerButtons` 中不在结果里的按默认顺序追加。
/// 这样**新增按钮会自动出现在老配置里**，不会因为用户存过顺序就永久消失。
List<String> normalizeButtonOrder(Object? raw);

/// 归一化隐藏集：过滤非法 id、去重。
Set<String> normalizeButtonHidden(Object? raw);

/// 生效的按钮列表：按 order 排、按 hidden 过滤，返回 spec 列表。
List<PlayerButtonSpec> resolveVisibleButtons({
  required List<String> order,
  required Set<String> hidden,
});
```

### 4.4 恢复默认

`resetPlayerButtons()` 清除 `order` 与 `hidden` 两个键（对齐上游 `reset()`，
`PlayerButtonSetting.java:140-144`）。

**注意**：上游还清 `HIDDEN_SEEDED`。PC 端**不需要**播种机制（§4.5），
所以只清两个键。

### 4.5 与上游的两个差异（必须写进注释）

| 差异 | 上游 | PC 端 | 理由 |
| --- | --- | --- | --- |
| 播种默认隐藏 | 首次运行把 `DEFAULT` 中 `visible=false` 的项写入 `player_button_hidden`（`PlayerButtonSetting.java:220-225`） | **不播种** | PC 端 8 个可配置按钮默认全可见（§3.2），没有默认隐藏项，播种是空操作。保留机制只会引入一个"用户删了隐藏项但它又回来"的困惑 |
| 格式 | 逗号分隔字符串 | JSON 数组 | §4.2 |

**兼容性**：如果 `order` 的值是**字符串**（用户从安卓迁移设置，或手改了文件），
按逗号切分解析。归一化函数必须同时接受 `List` 与 `String`。

---

## 5. 渲染契约

### 5.1 渲染顺序

```
for spec in resolveVisibleButtons(order, hidden):
    if spec.group != previous.group: 插入 _controlBarDivider
    渲染 spec 对应的控件
```

### 5.2 控件类型不可变

每个 id 对应的 **widget 类型与 tooltip 精确串**是既有的、被测试锁定的：

| id | widget | tooltip（精确串，不得改） |
| --- | --- | --- |
| `prev` | `IconButton` | `'上一集（[）'` |
| `play` | `IconButton` | `'暂停（空格）'` / `'播放（空格）'` |
| `next` | `IconButton` | `'下一集（]）'` |
| `mute` | `IconButton` | `'静音（M）'` / `'取消静音（M）'` |
| `fullscreen` | `IconButton` | `'全屏（F11）'` |
| `subtitle` | `IconButton` | `'字幕轨'` |
| `danmaku` | `IconButton` | `'弹幕（开启）'` / `'弹幕（关闭）'` |
| `volume` | `SizedBox(width:120, child: Slider)` | 无 |
| `speed` | `DropdownButton<double>` | 无 |
| `episodes` | `OutlinedButton.icon` | 无 |

**`'字幕轨'` 与 `'弹幕（开启）'` 的处置是本子系统的最大风险点**，见 §5.3。

### 5.3 顶栏按钮进入可配置集合的处置

**问题**：`subtitle` / `danmaku` 现状在**顶栏**（`AppBar.actions`），
且被集成测试按精确 tooltip 直接 `tap`。如果把它们做成"可隐藏"，
用户隐藏后测试会失败——但**测试不该被用户配置影响**。

**解法**：**顶栏的 `subtitle` 与 `danmaku` 保持常驻，不参与可配置集合。**

| 按钮 | 归属 | 可配置 |
| --- | --- | --- |
| `subtitle` | **顶栏常驻** | ❌ |
| `danmaku` | **顶栏常驻** | ❌ |
| `video_fit` / `media_info` / `diagnostics` | 顶栏「更多」菜单 + 右键菜单 | ❌（菜单项，不是按钮） |

**因此 `kPlayerButtons` 实际只有 8 个可配置项**：

```
prev, play, next, mute, volume, speed, episodes, fullscreen
```

§3.2 表格里的 13 个是"PC 端存在的按钮"，其中 5 个（`subtitle`/`danmaku`/
`video_fit`/`media_info`/`diagnostics`）**不进入配置集合**。

**这个修正必须同步到 §3.2 的表格与代码注释**，否则实现者会按 13 个去做。

**为什么不把顶栏按钮也做成可配置**：

1. 测试锁死了它们的 tooltip 且直接 `tap`（`subtitle_flow_test.dart:144,153`、
   `danmaku_flow_test.dart:156,175`）——用户一隐藏，测试就红。
2. 顶栏只有 3 个常驻控件（字幕轨、弹幕、更多），**没有拥挤问题**，
   不需要用户来裁剪。
3. `DESIGN.md` 已明确记录这两个控件的 tooltip 是"不要动的约束"。

### 5.4 窄窗口的降级

现状用 `Wrap`（`player_page.dart:2139-2142`），窗口窄时**换行**——
换行会让控制栏高度从 1 行变 2 行。在浮层模型下这不再挤占画面（`01`），
但会让浮层变高、遮住更多画面。

**目标**：改为**单行 + 溢出滚动**（对齐上游 `view_control_vod_action.xml` 的
`HorizontalScrollView`）：

```dart
SingleChildScrollView(
  scrollDirection: Axis.horizontal,
  child: Row(children: [...buttons]),
)
```

| 收益 | 说明 |
| --- | --- |
| 浮层高度恒定 | 不随窗口宽度变化，遮罩范围可预测 |
| 与上游同构 | `view_control_vod_action.xml:2-9` |
| 进度行不受影响 | 进度行是独立的 `Row`，始终占满宽度 |

**风险**：横向滚动条在鼠标操作下不如换行直观。
**缓解**：`scrollbars: false`（隐藏滚动条，对齐上游 `view_control_vod_action.xml:9`），
并在窗口宽度足够时**不出现滚动**（`SingleChildScrollView` 在内容不溢出时不滚动）。

**验收**：`05` §3.5 的 V5 在 1024×640（最小窗口）与 1440×900 下各出一张截图。

---

## 6. 配置页

### 6.1 入口

**两个入口**（`00` §5 第 10 条要求非右键的等价路径）：

| 入口 | 位置 |
| --- | --- |
| 设置页 | `SettingsPage` 新增「播放器按钮」区块 → `PlayerButtonConfigPage` |
| 右键菜单 | 播放器右键 → 「播放器按钮…」→ `PlayerButtonConfigPage` |

### 6.2 页面结构

对齐上游 `PlayerButtonConfigDialog`（`ui/dialog/PlayerButtonConfigDialog.java`）的
**可重排列表 + 可见性开关**：

```
┌─ 播放器按钮 ────────────────────────────────┐
│ 拖动调整顺序，开关控制是否显示                │
│                                             │
│ ≡  [✓] 上一集            传输                │
│ ≡  [✓] 播放/暂停         传输                │
│ ≡  [✓] 下一集            传输                │
│ ≡  [✓] 静音              音量                │
│ ≡  [✓] 音量              音量                │
│ ≡  [✓] 倍速              速率与选集           │
│ ≡  [✓] 剧集              速率与选集           │
│ ≡  [✓] 全屏              显示                │
│                                             │
│                        [恢复默认]  [完成]    │
└─────────────────────────────────────────────┘
```

| 元素 | 实现 | 理由 |
| --- | --- | --- |
| 拖动手柄 | `ReorderableListView` | Flutter 内置，无需新依赖 |
| 可见性 | `SwitchListTile` 或行内 `Switch` | 与设置页既有开关一致 |
| 分组标签 | 行尾 `bodySmall` + `onSurfaceVariant` | 与 `DESIGN.md` 的列表项规范一致 |
| 恢复默认 | `OutlinedButton`，二次确认 | `00` §5 第 9 条 |

**注意**：`SwitchListTile` 在本仓库被测试锁定为"同步开关"的形态
（`.impeccable/surfaces/lib-ui-app-dart.md`：`同步开关 = SwitchListTile`）。
那是**外壳设置页**的约束，本页是**独立页面**，用 `SwitchListTile` 不冲突，
但**不得**在设置页的同步区块附近引入同类结构造成混淆。

### 6.3 实时预览

配置页底部显示一行**当前顺序的按钮名**（`bodySmall`），
让用户不离开页面就能看到结果。**不**做真实的控制栏预览
（那需要把播放器状态搬进配置页，成本远超收益）。

---

## 7. 验收清单

| # | 检查项 | 方式 |
| --- | --- | --- |
| D1 | `kPlayerButtons` 恰好 8 项，id 与 §5.3 一致 | L1 单测 |
| D2 | 默认顺序 = §3.4 的 8 项顺序 | L1 单测 |
| D3 | 归一化：非法 id 过滤、去重、缺失项追加到末尾 | L1 单测 |
| D4 | 归一化：接受 `List` 与逗号分隔 `String` 两种输入 | L1 单测 |
| D5 | 隐藏集归一化：非法 id 过滤、去重 | L1 单测 |
| D6 | 持久化往返：写入后重新 load 得到同一顺序与隐藏集 | L2 单测 |
| D7 | 恢复默认：清除两个键，回到默认顺序与全可见 | L2 单测 |
| D8 | 渲染顺序：按配置顺序渲染，分组边界插入分隔线 | L2 widget 测试 |
| D9 | 隐藏生效：隐藏项不出现在控制栏 | L2 widget 测试 |
| D10 | 顶栏 `subtitle`/`danmaku` **不受**配置影响，始终存在 | L2 widget 测试 |
| D11 | 窄窗口（1024×640）不换行、不溢出 | L3 截图 + `tester.takeException() == null` |
| D12 | 配置页拖动后顺序立即反映在预览行 | L2 widget 测试 |
| D13 | 排除的上游 id 在代码里有注释说明理由 | L1 源码扫描（`05` §4） |
