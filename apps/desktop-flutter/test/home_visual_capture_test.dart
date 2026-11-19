/// 首页视觉证据（After）：真实光栅化，只在 `HOME_CAPTURE=1` 时写图。
///
/// 为什么要这条用例：首页是**纯视觉**改动（全幅 hero + 横向轨道），
/// `dart analyze` 与断言只能证明结构在，证明不了「好不好看」。截图落盘后可以
/// 直接看，也可以与改动前的点播页首屏对照（Before 见
/// `docs/phase11/design/00-home-hero-design-index.md` 的取证口径）。
///
/// 海报地址指向不可达主机：`PosterImage` 于是渲染占位块，这**诚实反映"图还没到"**
/// 的状态，而本次要复核的层级、间距、遮罩、2:3 比例都是真实的。
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/home_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/detail_test_seams.dart';
import 'support/test_fonts.dart';

const String _cjkFamily = 'Noto Sans CJK SC';
final bool _enabled = Platform.environment['HOME_CAPTURE'] == '1';
final GlobalKey _rootKey = GlobalKey();

String _evidenceDir() {
  var dir = Directory.current;
  for (var hop = 0; hop < 6; hop++) {
    if (Directory('${dir.path}/docs').existsSync()) {
      return '${dir.path}/.impeccable/review';
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return '.impeccable/review';
}

/// 取证专用主题：把注册的 CJK 字体设成主字族。
///
/// 只注册字体不够：`flutter test` 默认字族会把拉丁字母与数字画成实心方块，
/// 而按钮/芯片的文字样式是 `buildAppTheme` 构建时捕获的副本，不会跟着
/// `textTheme.apply` 走，必须单独补（与 `p0_6b_after_entry_capture_test.dart` 同口径）。
ThemeData _captureTheme() {
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
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: base.outlinedButtonTheme.style?.copyWith(
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

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_enabled) {
    debugPrint('HOME-CAPTURE skip reason=disabled name=$name');
    return;
  }
  final bytes = await tester.runAsync(() async {
    final object = _rootKey.currentContext?.findRenderObject();
    if (object is! RenderRepaintBoundary) return null;
    final image = await object.toImage(pixelRatio: 1.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data == null ? null : Uint8List.sublistView(data);
  });
  if (bytes == null) {
    debugPrint('HOME-CAPTURE skip reason=no-bytes name=$name');
    return;
  }
  final output = File('${_evidenceDir()}/$name');
  output.parent.createSync(recursive: true);
  output.writeAsBytesSync(bytes);
  debugPrint('HOME-CAPTURE path=${output.path} bytes=${bytes.length}');
}

void main() {
  late Directory tempDir;
  late AppState state;

  setUpAll(() async {
    await loadFixtureFonts(cjkFamily: _cjkFamily);
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-home-capture');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${tempDir.path}/webhtv-pc',
          'data': '${tempDir.path}/webhtv-pc',
          'cache': '${tempDir.path}/webhtv-pc/cache',
          'state': '${tempDir.path}/webhtv-pc/logs',
        },
      ),
      log: MemoryOnlyLogService(),
    );
    await bootstrapWithoutExternalMeta(state);
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _captureTheme(),
        home: RepaintBoundary(
          key: _rootKey,
          child: Scaffold(
            body: HomePage(
              state: state,
              onOpenBrowse: () {},
              onOpenHistory: () {},
              onOpenFollowing: () {},
              onImportConfig: () {},
              onSearch: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 卸掉页面：让页面还掉推荐租约（否则豆瓣 provider 的定时器会留在树外）。
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('After：hero + 继续观看（有历史）', (tester) async {
    state.database!.upsertHistory(
      siteKey: 'site-a',
      vodId: 'v1',
      vodName: '漫长的季节',
      vodPic: 'http://127.0.0.1:1/poster1.jpg',
      flag: '线路一',
      episodeName: '第08集',
      episodeId: 'http://x/e1',
      positionMs: 1400000,
      durationMs: 2700000,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    state.database!.upsertHistory(
      siteKey: 'site-a',
      vodId: 'v2',
      vodName: '繁花',
      vodPic: 'http://127.0.0.1:1/poster2.jpg',
      flag: '线路一',
      episodeName: '第12集',
      episodeId: 'http://x/e2',
      positionMs: 600000,
      durationMs: 2700000,
      updatedAt: DateTime.now().millisecondsSinceEpoch - 60000,
    );
    state.database!.upsertHistory(
      siteKey: 'site-a',
      vodId: 'v3',
      vodName: '三体',
      vodPic: 'http://127.0.0.1:1/poster3.jpg',
      flag: '线路二',
      episodeName: '第03集',
      episodeId: 'http://x/e3',
      positionMs: 100000,
      durationMs: 2600000,
      updatedAt: DateTime.now().millisecondsSinceEpoch - 120000,
    );

    await pumpHome(tester);
    expect(find.byKey(const ValueKey('home-hero')), findsOneWidget);
    await _capture(tester, 'home-hero.png');
    await unmount(tester);
  });

  testWidgets('After：空态（没有任何可续播内容）', (tester) async {
    await pumpHome(tester);
    expect(find.byKey(const ValueKey('home-empty-hero')), findsOneWidget);
    await _capture(tester, 'home-empty.png');
    await unmount(tester);
  });
}
