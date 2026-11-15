/// P0-6b 视觉证据的 **After** 侧（入口态）：与 Before 同一条点击路径。
///
/// Before 在 HEAD 的独立 worktree 上生成（旧的关键词对话框）；本用例在改动后的
/// 工作区上跑，点的是同一个菜单项，所以两张图的差异只可能来自实现本身。
///
/// 口径与 `p1_4_menu_visual_capture_test.dart` 一致：1280×720、devicePixelRatio 1.0、
/// dark 主题、注册 CJK 字体；只在 `P0_6B_CAPTURE=1` 时写图。
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/subtitle_settings.dart';
import 'package:webhtv_pc/ui/player_context_menu.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/player_page_harness.dart';
import 'support/test_fonts.dart';

const String _cjkFamily = 'Noto Sans CJK SC';

/// 取证专用主题：把注册的 CJK 字体设成**主**字族。
///
/// 只注册字体不够：flutter test 默认字族 FlutterTest 会把拉丁字母与数字画成
/// 实心方块，部分 CJK 兼容字形也不在它的覆盖里；按钮/芯片的文字样式是
/// buildAppTheme 构建时捕获的副本，不会跟着 textTheme.apply 走，必须单独补。
/// 颜色/间距/形状仍是 buildAppTheme(Brightness.dark)。
ThemeData captureTheme() {
  final base = buildAppTheme(Brightness.dark);
  final text = base.textTheme.apply(fontFamily: _cjkFamily);
  final label = base.textTheme.labelLarge?.copyWith(fontFamily: _cjkFamily);
  return base.copyWith(
    textTheme: text,
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: _cjkFamily),
    textButtonTheme: TextButtonThemeData(
      style: base.textButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll(label),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: base.filledButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll(label),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      labelStyle: base.chipTheme.labelStyle?.copyWith(fontFamily: _cjkFamily),
      secondaryLabelStyle: base.chipTheme.secondaryLabelStyle?.copyWith(
        fontFamily: _cjkFamily,
      ),
    ),
  );
}

final bool _captureEnabled = Platform.environment['P0_6B_CAPTURE'] == '1';
/// 默认写到仓库根的 evidence 目录。
///
/// 不能直接用相对路径：flutter test 的工作目录是 apps/desktop-flutter，
/// 相对路径会在子目录里另造一棵 docs/（第一版就这么踩过）。
String _defaultEvidenceDir() {
  var dir = Directory.current;
  for (var hop = 0; hop < 6; hop++) {
    if (Directory('${dir.path}/docs').existsSync()) {
      return '${dir.path}/docs/reference/evidence/p0-6b-search';
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return 'docs/reference/evidence/p0-6b-search';
}

final String _evidenceDir =
    Platform.environment['P0_6B_EVIDENCE_DIR'] ?? _defaultEvidenceDir();

void evidence(String message) => debugPrint('P0-6B-AFTER $message');

Future<void> capture(WidgetTester tester, String name) async {
  if (!_captureEnabled) {
    evidence('screenshot-skip reason=capture-disabled name=$name');
    return;
  }
  final bytes = await tester.runAsync(() async {
    final boundary = find.byKey(playerPageCaptureRootKey);
    if (boundary.evaluate().isEmpty) return null;
    final object = boundary.evaluate().first.renderObject;
    if (object is! RenderRepaintBoundary) return null;
    final image = await object.toImage(pixelRatio: 1.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data == null ? null : Uint8List.sublistView(data);
  });
  if (bytes == null) {
    evidence('screenshot-skip reason=no-bytes name=$name');
    return;
  }
  final output = File('$_evidenceDir/$name');
  output.parent.createSync(recursive: true);
  output.writeAsBytesSync(bytes);
  evidence('screenshot path=${output.path} bytes=${bytes.length}');
}

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
  setUpAll(() async {
    await loadFixtureFonts(cjkFamily: 'Noto Sans CJK SC');
  });

  testWidgets('After：字幕 → 在线搜索字幕… 打开搜索窗口（初始态）', (tester) async {
    await pumpPlayerPage(
      tester,
      theme: captureTheme(),
      // 与 Before 同条件：配一个本地字幕目录，让入口走到真实界面而不是「未配置」提示。
      onStateReady: (state) => state.setSubtitleSettings(
        SubtitleSettings(localDirectories: const ['/tmp/webhtv-evidence-subs']),
      ),
    );
    await tester.tapAt(const Offset(420, 300), buttons: kSecondaryButton);
    await settlePlayerPage(tester);
    expect(find.byType(PlayerContextMenu), findsOneWidget, reason: '右键没能打开菜单');

    await drill(tester, '字幕');
    await drill(tester, '在线搜索字幕…');

    expect(
      find.text('输入关键词开始搜索'),
      findsOneWidget,
      reason: '没有进到新的搜索窗口初始态',
    );
    await capture(tester, 'after-search-entry.png');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
