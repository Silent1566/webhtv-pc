/// P1-4 视觉证据：右键菜单里新增的字幕 / 屏显样式入口。
///
/// ## 为什么单独一份
///
/// 本轮的可见改动全在右键菜单里（字幕样式多一组「文字颜色」、显示组多一项
/// 「屏显样式」）。既有 `integration_test/phase8_visual_flow_test.dart` 的截图
/// 依赖 fixture 服务，且只拍「菜单打开」这一态——看不出新增行。
///
/// **为什么放在 `test/` 而不是 `integration_test/`**：本用例不需要真机/桌面设备，
/// 只要 `flutter test` 的离屏光栅化；放 `integration_test/` 会触发原生构建
/// （实测 CMake 配置失败）。仓库既有 `test/config_source_status_capture_test.dart`
/// 也是同一做法。
///
/// ## Before/After 怎么拍
///
/// 同一份用例、同一视口、同一主题跑两遍：
/// 1. After：工作区带着实现跑；
/// 2. Before：把 `apps/desktop-flutter/lib` 暂存回改动前再跑，只跑
///    `--plain-name 'A '` 选中的那一例——「屏显样式」「文字颜色」两例在改动前的
///    树里必然找不到入口，属于预期失败，不纳入 Before。
///
/// **不加载真实媒体**：走 `test/support/player_page_harness.dart`，页面停在加载态。
/// 两张图构造完全相同，被比较的是菜单内容本身。
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/osd_config.dart';
import 'package:webhtv_pc/ui/player_context_menu.dart';

import 'support/player_page_harness.dart';
import 'support/test_fonts.dart';

void evidence(String message) => debugPrint('P1-4-VISUAL-EVIDENCE $message');

/// 只有显式要求时才写图：默认 `flutter test` 会跑 test/ 下所有用例，
/// 让它每跑一次就改一遍 `docs/` 下的证据文件是污染。
/// 与 `test/config_source_status_capture_test.dart:16` 的 `CONFIG_SOURCE_CAPTURE_PHASE`
/// 同一口径：`P1_4_CAPTURE=1 flutter test test/p1_4_*_capture_test.dart`。
final bool _captureEnabled = Platform.environment['P1_4_CAPTURE'] == '1';

Directory repoRootOf(Directory start) {
  var current = start;
  for (var hop = 0; hop < 6; hop++) {
    if (Directory('${current.path}/docs').existsSync()) return current;
    final parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }
  return start;
}

/// 把当前树拍成 PNG 写进仓库。
///
/// **必须在 `tester.runAsync` 里跑**：`toImage` / `toByteData` 的 Future 由引擎
/// 在真实 zone 完成，落在 FakeAsync 里会卡住整个用例（实测挂到 4 分钟超时，
/// 而文件其实已经写出来了——这正是「看起来成功但进程收不住」的坑）。
/// 仓库既有 `test/config_source_status_capture_test.dart:52-63` 是同一手法。
Future<void> capture(
  WidgetTester tester, {
  required String relativePath,
}) async {
  if (!_captureEnabled) {
    evidence('screenshot-skip reason=capture-disabled path=$relativePath');
    return;
  }
  final bytes = await tester.runAsync(() async {
    final boundary = find.byType(RepaintBoundary);
    if (boundary.evaluate().isEmpty) return null;
    final object = boundary.evaluate().first.renderObject;
    if (object is! RenderRepaintBoundary) return null;
    final image = await object.toImage(pixelRatio: 1.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data == null ? null : Uint8List.sublistView(data);
  });
  if (bytes == null) {
    evidence('screenshot-skip reason=no-bytes path=$relativePath');
    return;
  }
  final output = File('${repoRootOf(Directory.current).path}/$relativePath');
  output.parent.createSync(recursive: true);
  output.writeAsBytesSync(bytes);
  evidence('screenshot path=$relativePath bytes=${bytes.length}');
}

/// 收尾：把树换成一个空 `SizedBox` 再 settle，让本用例的 element/ticker 全部释放。
Future<void> teardownTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

/// 打开右键菜单。
///
/// 锚点取画面中部偏上：顶栏是浮层里的 `AppBar`，它的 `Material` 会吃掉
/// `y < kToolbarHeight` 的右键（`phase8_visual_flow_test.dart` 记录过这个坑）。
Future<void> openMenu(WidgetTester tester) async {
  await pumpPlayerPage(
    tester,
    osdFlags: {OsdFlag.title: true, OsdFlag.time: true},
  );
  await tester.tapAt(const Offset(420, 300), buttons: kSecondaryButton);
  await settlePlayerPage(tester);
  expect(find.byType(PlayerContextMenu), findsOneWidget, reason: '右键没能打开菜单');
}

/// 点 [label] 让那一行飞出下一列。
///
/// 先 `ensureVisible`：菜单列会被夹到可用高度内滚动，不滚到可见处 `tap` 会
/// 点在窗口外静默失效（那是测试的问题，不是菜单的）。
Future<void> drill(WidgetTester tester, String label) async {
  final target = find.descendant(
    of: find.byType(PlayerContextMenu),
    matching: find.text(label),
  );
  expect(target, findsWidgets, reason: '菜单里找不到「$label」');
  await tester.ensureVisible(target.first);
  await settlePlayerPage(tester, times: 2);
  await tester.tap(target.first);
  await settlePlayerPage(tester, times: 3);
}

void main() {
  // 字体：没加载时中文全是豆腐块，截图就成了「看不出标签」的假证据。
  // 主题的 fontFamilyFallback（ui/theme.dart:27-35）里含 'Noto Sans CJK SC'，
  // 把 CJK 字体注册成这个名字即可让 harness 自建的 MaterialApp 也吃到。
  setUpAll(() async {
    await loadFixtureFonts(cjkFamily: 'Noto Sans CJK SC');
  });

  // A：字幕 → 字幕样式（**Before 也跑这一例**）。
  testWidgets('A 字幕 → 字幕样式：改动前后同一路径', (tester) async {
    await openMenu(tester);
    await drill(tester, '字幕');
    await drill(tester, '字幕样式');
    await capture(
      tester,
      relativePath: 'docs/reference/evidence/p1-4/menu-subtitle-style.png',
    );
    await teardownTree(tester);
  });

  // B：显示 → 屏显样式（改动后才存在）。
  testWidgets('B 显示 → 屏显样式：字号与不透明度', (tester) async {
    await openMenu(tester);
    await drill(tester, '显示');
    await drill(tester, '屏显样式');
    await capture(
      tester,
      relativePath: 'docs/reference/evidence/p1-4/menu-osd-style.png',
    );
    await teardownTree(tester);
  });

  // C：字幕样式 → 文字颜色（改动后才存在）。
  testWidgets('C 字幕样式 → 文字颜色：6 档色板', (tester) async {
    await openMenu(tester);
    await drill(tester, '字幕');
    await drill(tester, '字幕样式');
    await drill(tester, '文字颜色');
    await capture(
      tester,
      relativePath: 'docs/reference/evidence/p1-4/menu-subtitle-color.png',
    );
    await teardownTree(tester);
  });
}
