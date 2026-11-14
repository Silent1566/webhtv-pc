/// 观影报告 v2 的 Before/After 配对截图 harness。
///
/// 真渲染：RepaintBoundary → toImage → PNG，不是对 widget 树的重描述。
/// 同一个 fixture、同一个 now、同一个主题与视口、同一个滚动场景，
/// 唯一变量是被截图的页面版本（脚本只改输出目录里的 phase 前缀）。
///
/// 运行：
///   PUB_CACHE=../../.tools/pub-cache ../../.tools/flutter/bin/flutter test --no-pub \
///     test/viewing_report_v2_capture_test.dart
/// 输出：`../../docs/phase9/evidence/screenshots/viewing-report-v2/<phase>-*.png`
/// phase 由 VIEWING_REPORT_CAPTURE_PHASE 指定（默认 after）。
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/viewing_report_page.dart';

import 'viewing_report_v2_fixture.dart';

const String _outDir =
    '../../docs/phase9/evidence/screenshots/viewing-report-v2';

/// 截图场景参数：两份截图必须完全一致，所以只在这里定义一次。
const Size _desktopSize = Size(1280, 950);
const Size _narrowSize = Size(780, 950);

String get _phase =>
    Platform.environment['VIEWING_REPORT_CAPTURE_PHASE'] ?? 'after';

Future<void> _loadFonts() async {
  final cjk = File('/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc');
  if (cjk.existsSync()) {
    await (FontLoader(
      'FixtureCJK',
    )..addFont(cjk.readAsBytes().then(ByteData.sublistView))).load();
  }
  final root = Platform.environment['FLUTTER_ROOT'] ?? '../../.tools/flutter';
  final icons = File(
    '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(icons.readAsBytes().then(ByteData.sublistView))).load();
  }
}

Future<void> _capturePng(
  WidgetTester tester,
  GlobalKey boundary,
  String fileName,
) async {
  await tester.runAsync(() async {
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$_outDir/$fileName');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
    // ignore: avoid_print
    print('captured ${file.path} (${bytes.lengthInBytes} bytes)');
  });
}

/// 滚到报告末尾：两份截图的「下半」是同一个场景（列表末端），
/// 而不是同一个像素偏移——报告长度本来就变了。
Future<double> _scrollToReportEnd(WidgetTester tester) async {
  final list = find.byKey(const ValueKey('viewing-report-list'));
  if (list.evaluate().isEmpty) return 0;
  final scrollable = find.descendant(
    of: list,
    matching: find.byType(Scrollable),
  );
  final position = tester.state<ScrollableState>(scrollable.first).position;
  position.jumpTo(position.maxScrollExtent);
  await tester.pumpAndSettle();
  // ignore: avoid_print
  print(
    'scroll: maxExtent=${position.maxScrollExtent} pixels=${position.pixels}',
  );
  return position.maxScrollExtent;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppState state;
  late GlobalKey boundary;

  setUpAll(_loadFonts);

  setUp(() {
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${Directory.systemTemp.path}/webhtv-pc-capture',
          'data': '${Directory.systemTemp.path}/webhtv-pc-capture',
          'cache': '${Directory.systemTemp.path}/webhtv-pc-capture/cache',
          'state': '${Directory.systemTemp.path}/webhtv-pc-capture/logs',
        },
      ),
      log: LogService(),
    );
    boundary = GlobalKey();
  });

  tearDown(() => state.dispose());

  Future<void> pumpReport(
    WidgetTester tester, {
    required Size size,
    required Brightness brightness,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final theme = buildAppTheme(brightness);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme.copyWith(
          textTheme: theme.textTheme.apply(fontFamily: 'FixtureCJK'),
          primaryTextTheme: theme.primaryTextTheme.apply(
            fontFamily: 'FixtureCJK',
          ),
          appBarTheme: theme.appBarTheme.copyWith(
            titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
              fontFamily: 'FixtureCJK',
            ),
          ),
          chipTheme: theme.chipTheme.copyWith(
            labelStyle: theme.chipTheme.labelStyle?.copyWith(
              fontFamily: 'FixtureCJK',
            ),
          ),
          listTileTheme: theme.listTileTheme.copyWith(
            titleTextStyle: theme.listTileTheme.titleTextStyle?.copyWith(
              fontFamily: 'FixtureCJK',
            ),
            subtitleTextStyle: theme.listTileTheme.subtitleTextStyle?.copyWith(
              fontFamily: 'FixtureCJK',
            ),
          ),
        ),
        home: RepaintBoundary(
          key: boundary,
          child: ViewingReportPage(
            state: state,
            historyOverride: viewingReportFixtureRecords,
            metadataOverride: viewingReportFixtureMetadata,
            now: viewingReportFixtureNow,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
  }

  testWidgets('1280×950 暗色：顶部与下半（列表末端）配对截图', (tester) async {
    await pumpReport(tester, size: _desktopSize, brightness: Brightness.dark);
    expect(tester.takeException(), isNull);
    await _capturePng(tester, boundary, '$_phase-top.png');

    final list = find.byKey(const ValueKey('viewing-report-list'));
    final scrollable = find
        .descendant(of: list, matching: find.byType(Scrollable))
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    position.jumpTo(360.clamp(0, position.maxScrollExtent).toDouble());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _capturePng(tester, boundary, '$_phase-middle.png');

    await _scrollToReportEnd(tester);
    expect(tester.takeException(), isNull);
    await _capturePng(tester, boundary, '$_phase-lower.png');
  });

  testWidgets('窄屏 smoke：780×950 暗色无异常', (tester) async {
    await pumpReport(tester, size: _narrowSize, brightness: Brightness.dark);
    await tester.ensureVisible(
      find.byKey(const ValueKey('viewing-report-heatmap')),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _capturePng(tester, boundary, '$_phase-narrow-heatmap.png');
    await tester.ensureVisible(
      find.byKey(const ValueKey('viewing-preference-genre')),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _capturePng(tester, boundary, '$_phase-narrow.png');
    await _scrollToReportEnd(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('亮色 smoke：1280×950 无异常', (tester) async {
    await pumpReport(tester, size: _desktopSize, brightness: Brightness.light);
    expect(tester.takeException(), isNull);
    await _capturePng(tester, boundary, '$_phase-light.png');
  });
}
