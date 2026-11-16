/// 「播放参数」明细页的视觉证据（Before / After 同一场景、同一视口、同一主题）。
///
/// 拍的是真实光栅化结果（`RepaintBoundary.toImage`），不是 widget 树的重新描述。
/// 视口固定 1000×1400、设置页暗色主题；两张图同一 fixture、同一视口、同一主题，
/// 差别只有「画面」区块（HDR 色调映射 / 峰值亮度计算）。
///
/// Before 图用 `CAPTURE_PHASE=before` 采集（临时回退 lib 改动），After 图是本轮
/// 实现后的真实渲染。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/player_context_menu.dart';
import 'package:webhtv_pc/ui/settings_detail_pages.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/player_page_harness.dart';
import 'support/test_fonts.dart';

const Key _captureKey = ValueKey('hdr-evidence-root');

/// 取证专用主题：把注册的 CJK 字体设成**主**字族。
///
/// 只注册字体不够：`flutter test` 默认字族会把拉丁字母与数字画成实心方块；
/// 菜单行的文字样式是 buildAppTheme 构建时捕获的副本，必须跟着一起换。
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
  );
}
/// 证据落在**受版本控制**的目录（`.superpowers/` 被 gitignore，PR 里会缺图）。
const String _evidenceDir = '../../docs/phase9/evidence/hdr-tone-mapping';

/// 主题的字体回退里第一个 Linux 候选（`lib/ui/theme.dart:30`），
/// 因此把 fixture 字体注册成同名族，截图里才是真实中文字形而不是方框。
const String _cjkFamily = 'Noto Sans CJK SC';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late AppState state;

  setUpAll(() async {
    // 两份注册缺一不可：
    // 1. 主题的字体回退链里有 'Noto Sans CJK SC' → 中文靠它；
    // 2. **拉丁/数字**走 Material 3 typography 的 'Roboto'，而 MaterialApp 会
    //    用 typography 覆盖 textTheme 的 fontFamily（实测 Theme.of().textTheme
    //    .bodyMedium.fontFamily 仍是 Roboto），所以把同一份字体也注册成
    //    'Roboto'，否则截图里数字与英文全是实心方框。
    await loadFixtureFonts(cjkFamily: _cjkFamily);
    await loadFixtureFonts(cjkFamily: 'Roboto');
  });

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('webhtv-hdr-visual');
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/config',
        'data': '${temp.path}/data',
        'cache': '${temp.path}/cache',
        'state': '${temp.path}/logs',
      },
    );
    state = AppState(paths: paths, log: LogService());
    await state.bootstrap();
  });

  tearDown(() {
    state.dispose();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> capture(WidgetTester tester, String name, {Key? root}) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(root ?? _captureKey),
    );
    final phase = Platform.environment['CAPTURE_PHASE'] ?? 'after';
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final dir = Directory(_evidenceDir);
      await dir.create(recursive: true);
      await File('${dir.path}/$name-$phase.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('播放参数明细页渲染快照', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 主题的首选字族在测试里是 Ahem（拉丁/数字会画成方框），所以把已加载的
    // CJK 字族同时设成首选：CJK 与拉丁都由同一份 fixture 字体渲染。
    final theme = buildAppTheme(Brightness.dark);
    final themed = theme.copyWith(
      textTheme: theme.textTheme.apply(fontFamily: _cjkFamily),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: themed,
        builder: (context, child) =>
            RepaintBoundary(key: _captureKey, child: child!),
        home: PlaybackOptionsPage(state: state),
      ),
    );
    await tester.pumpAndSettle();
    await capture(tester, 'playback-options');
  });

  testWidgets('右键菜单「画面」组渲染快照', (tester) async {
    await pumpPlayerPage(tester, theme: captureTheme());
    await tester.tapAt(const Offset(300, 260), buttons: kSecondaryButton);
    await settlePlayerPage(tester);
    expect(find.byType(PlayerContextMenu), findsOneWidget);

    Future<void> drill(String label) async {
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

    await drill('画面');
    await capture(
      tester,
      'context-menu-video-group',
      root: playerPageCaptureRootKey,
    );

    // 只在本轮新增的项存在时再深一层（Before 侧没有这两行）。
    if (find.text('HDR 色调映射').evaluate().isNotEmpty) {
      await drill('HDR 色调映射');
      await capture(
        tester,
        'context-menu-hdr-tone-mapping',
        root: playerPageCaptureRootKey,
      );
    }
  });
}
