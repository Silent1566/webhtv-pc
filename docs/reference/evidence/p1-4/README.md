# P1-4 字幕与 OSD 样式落盘 · 视觉证据

对照清单条目：[../../potplayer-checklist.md](../../potplayer-checklist.md) 的 **P1-4**
（论证视图：[../../potplayer-borrowings.md](../../potplayer-borrowings.md) §4.1）。

## 场景（两组图共用同一条件）

| 维度 | 取值 |
| --- | --- |
| 视口 | 1280 × 720，devicePixelRatio = 1.0 |
| 主题 | `buildAppTheme(Brightness.dark)` |
| 字体 | 注册 `Noto Sans CJK SC`（`test/support/test_fonts.dart`），否则中文全是方块 |
| 媒体 | **不加载真实视频**：播放器停在加载态，两张图构造完全相同 |
| 锚点 | 画面 (420, 300) 处右键 |

## 图与生成方式

| 文件 | 说明 |
| --- | --- |
| `menu-subtitle-style-before.png` | 改动**前**的「字幕 → 字幕样式」飞出列：字号 / 描边 / 位置 / 底色 / 恢复默认（5 项） |
| `menu-subtitle-style-after.png` | 改动**后**同一路径：多出「文字颜色」（6 项） |
| `menu-subtitle-color.png` | 改动后新增的「文字颜色」6 档色板 |
| `menu-osd-style.png` | 改动后新增的「显示 → 屏显样式」：字号 / 不透明度 / 恢复默认 |
| `osd-style-default.png` | 屏显默认样式：字号 100%、不透明 100%（= 改动前的写死观感） |
| `osd-style-scaled.png` | 屏显调过样式：字号 150%、不透明 60% |

**Before 是怎么来的**：Before 与 After 是**同一份用例**跑两次的结果——
`git stash push -u -- apps/desktop-flutter/lib` 把实现暂存回改动前，只跑
`test/p1_4_menu_visual_capture_test.dart --plain-name 'A 字幕'`（另外两例依赖改动后
才存在的菜单项，不纳入 Before），随后 `git stash pop` 恢复。
所以两张图的差异只可能来自实现本身。

屏显那一对不是「改动前后」而是「**设置前后**」：默认值等于改动前的写死观感
（14dp、100% 不透明），改动前后逐像素相同，拿它当对照证明不了功能存在。

## 复现

```bash
cd apps/desktop-flutter
export TMPDIR=$HOME/.tmp-webhtv && mkdir -p "$TMPDIR"      # /tmp 是 tmpfs，容易写满
export LIBMPV_LIBRARY_PATH=/home/maple/orca/webhtv-pc/.local/mpv/usr/lib/x86_64-linux-gnu/libmpv.so.2
export LD_LIBRARY_PATH=/home/maple/orca/webhtv-pc/.local/mpv/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH
P1_4_CAPTURE=1 flutter test test/p1_4_menu_visual_capture_test.dart test/p1_4_osd_style_visual_capture_test.dart
```

不带 `P1_4_CAPTURE=1` 时这两个用例照常跑（同样的加载、右键、钻菜单），只是不写图——
`test/` 下的用例默认会被 `flutter test` 全量执行，写图会污染工作区。
