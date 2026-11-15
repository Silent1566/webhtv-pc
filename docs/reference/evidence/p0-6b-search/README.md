# P0-6b 在线字幕搜索窗口 · 视觉证据

对照计划：`docs/superpowers/plans/2026-11-15-subtitle-online-search.md` 的 **Task 5**
（验收 A9）。窗口实现在 `apps/desktop-flutter/lib/ui/subtitle_search_dialog.dart`。

这一屏要从旧的两步流程（关键词对话框 → 结果底部弹窗，`ui/player_page.dart:1337`、
`:1405`）换成 PotPlayer 式独立窗口：关键词、季集、语言筛选、结果列表、本地文件
入口都在同一屏，改词重搜不关窗。

## 场景（Before / After 共用）

| 维度 | 取值 |
| --- | --- |
| 视口 | 1280 × 720，`devicePixelRatio = 1.0` |
| 主题 | `buildAppTheme(Brightness.dark)` |
| 字体 | `test/support/test_fonts.dart` 注册 `Noto Sans CJK SC` 与 MaterialIcons |
| 数据 | 固定的假 `SubtitleSearchReport`：3 个源共 5 条候选（见下表），不联网 |
| 交互 | 打开窗口 → 点一次「搜索」→ 收起输入焦点 → 截图 |

**字体为什么要额外一步**：只注册字体是不够的。`flutter test` 的默认字体是
FlutterTest，它把拉丁字母与数字画成实心方块——副标题里恰恰是源名、语言、格式和
匹配分。所以取证用例把注册的 CJK 字体族设成**主**字体族（颜色/间距/形状仍是
`buildAppTheme(Brightness.dark)` 原样，见 `test/p0_6b_search_capture_test.dart` 的
`captureTheme()`）。不改这一步，图上的分数是方块，等于没有证据。

### 假数据

| # | 源（`providerId`） | 标题 | 语言 | 格式 | 匹配分 |
| --- | --- | --- | --- | --- | --- |
| 1 | `assrt` | 某剧 第二季 第03集 简中 ASS | zh-Hans | ass | 0.94 |
| 2 | `assrt` | 某剧 S02E03 简体中文 | zh-Hans | srt | 0.89 |
| 3 | `xunlei` | 某剧.第3集.1080p.繁体 | zh-Hant | srt | 0.83 |
| 4 | `xunlei` | 某剧 S02 第3集 中字 | zh-Hans | srt | 0.80 |
| 5 | `shooter` | 某剧.S02E03.ass | （空，显示「未知语言」） | ass | 0.64 |

## 图

| 文件 | 说明 |
| --- | --- |
| `before-keyword-dialog.png` | **改动前**：右键菜单 → 字幕 → 在线搜索字幕… 弹出的关键词对话框（只有关键词 + 取消/搜索） |
| `after-search-entry.png` | **改动后同一条点击路径**：搜索窗口初始态（关键词已预填、季/集可改、语言筛选、「选择本地文件…」、空态提示） |
| `after-search-window.png` | 改动后：点一次「搜索」的结果态——按源分组（ASSRT 2 / 迅雷字幕 2 / 射手字幕 1），每行「标题 + 源名 · 语言 · 格式 · 匹配分」 |

Before/After 入口对的差异只在窗口本身：同一视口、同一主题、同一字体口径、同一条
菜单路径（`字幕 → 在线搜索字幕…`），连播放器外框（时间轴/顶栏）都一致。

四态里只有「初始」与「结果」两态由截图证明；「加载 / 空结果」两态的文案互不相同
由 `test/subtitle_search_dialog_test.dart` 断言（含未启用源、失败原因、筛选无结果），
不靠截图。

## 生成与复现（After）

```bash
cd apps/desktop-flutter
export TMPDIR=$HOME/.tmp-webhtv && mkdir -p "$TMPDIR"
P0_6B_CAPTURE=1 flutter test test/p0_6b_search_capture_test.dart
```

不带 `P0_6B_CAPTURE=1` 时用例照常跑（同样的打开、点击、断言），只是不写文件——
`test/` 下的用例默认会被 `flutter test` 全量执行，写图会污染工作区。

## Before 与 After 入口态怎么生成

两份都走 **真实生产代码路径**（点菜单、开窗口），没有复刻页面。

**After 入口态**（本工作区）——`test/p0_6b_after_entry_capture_test.dart`：

```bash
cd apps/desktop-flutter
export TMPDIR=$HOME/.tmp-webhtv && mkdir -p "$TMPDIR"
export LIBMPV_LIBRARY_PATH=$PWD/../../.local/mpv/usr/lib/x86_64-linux-gnu/libmpv.so.2
export LD_LIBRARY_PATH=$PWD/../../.local/mpv/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH
P0_6B_CAPTURE=1 flutter test --no-pub test/p0_6b_after_entry_capture_test.dart
```

**Before**（HEAD 的独立 worktree）——不用 `git stash`：收口时工作区正被并行改造，
stash 会把别人没提交的实现一起卷进去。做法是另开一棵**只读的 HEAD 树**：

```bash
git worktree add --detach /tmp/webhtv-before HEAD
cd /tmp/webhtv-before/apps/desktop-flutter
flutter pub get --offline
# 放入 before_by_capture_test.txt（本目录），按其中说明补 harness 三处注入：
#   1) onStateReady 回调（否则「未配置源」分支直接返回，进不到旧对话框）
#   2) 根 RepaintBoundary（否则 find.byType(RepaintBoundary).first 拍到视频层，图上没有对话框）
#   3) theme 覆盖（CJK 字体设成主字族，否则按钮/数字是实心方块）
P0_6B_CAPTURE=1 P0_6B_EVIDENCE_DIR=<本目录绝对路径> \
  flutter test --no-pub test/p0_6b_before_capture_test.dart
git worktree remove --force /tmp/webhtv-before
```

两个坑记录在案（都真实发生过）：

1. **`find.byType(RepaintBoundary).first` 拍到的是视频层**，第一版 Before 图是
   一张没有对话框的播放器截图——用例还「通过」了（断言找得到对话框文本），
   但图上没有。取证必须用一个显式 key 包住整棵树再 `toImage`。
2. **只注册 CJK 字体不够**：默认字族 `FlutterTest` 会把拉丁字母/数字画成实心方块，
   第一版 After 图里「选择地□件」的方块就是这么来的。主字族要显式设置。

