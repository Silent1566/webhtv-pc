import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/ai_config.dart';
import 'package:webhtv_pc/core/viewing_metadata.dart';
import 'package:webhtv_pc/services/ai_completion_client.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/services/viewing_report_ai.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/viewing_report_page.dart';
import 'package:webhtv_pc/ui/viewing_report_sections.dart';
import 'package:webhtv_pc/ui/glass_widgets.dart';
import 'package:webhtv_pc/ui/wallpaper_backdrop.dart';

import 'support/test_fonts.dart';

import 'viewing_report_v2_fixture.dart';

AppPaths _paths() => AppPaths.resolve(
  overrides: {
    'config': 'x/c',
    'data': 'x/d',
    'cache': 'x/cache',
    'state': 'x/log',
  },
);

class _CountingMetadataState extends AppState {
  _CountingMetadataState() : super(paths: _paths(), log: LogService());
  int metadataReads = 0;
  @override
  Map<int, ViewingMetadata> viewingReportMetadata(
    List<PlaybackHistory> records,
  ) {
    metadataReads++;
    return viewingReportFixtureMetadata;
  }
}

void main() {
  late AppState state;
  setUp(() => state = AppState(paths: _paths(), log: LogService()));
  tearDown(() => state.dispose());

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(1280, 2400),
    Brightness brightness = Brightness.dark,
    Map<int, ViewingMetadata> metadata = const {},
    List<PlaybackHistory>? records,
    AiConfig ai = const AiConfig(),
    ViewingReportAiAnalyzer? analyzer,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness),
        home: ViewingReportPage(
          state: state,
          historyOverride: records ?? viewingReportFixtureRecords,
          now: viewingReportFixtureNow,
          metadataOverride: metadata,
          aiConfigOverride: ai,
          analyzer: analyzer,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> changeRange(WidgetTester tester, String label) async {
    await tester.tap(find.byKey(const ValueKey('viewing-report-range')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  const metricLabels = ['观看时长', '作品', '记录', '完播率', '深夜观影', '周末占比', '平均每条'];
  final evidenceDir = Platform.environment['VIEWING_POLISH_CAPTURE'];
  final phase = Platform.environment['VIEWING_POLISH_PHASE'] ?? 'after';
  const boundaryKey = ValueKey('viewing-polish-capture');

  Future<void> capture(WidgetTester tester, String scenario) async {
    if (evidenceDir == null) return;
    await tester.runAsync(() async {
      final image = await tester
          .renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey))
          .toImage();
      try {
        final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('$evidenceDir/$scenario-$phase.png').writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
      } finally {
        image.dispose();
      }
    });
  }

  Future<void> pumpVisual(
    WidgetTester tester, {
    required Size size,
    required Brightness brightness,
    double scale = 1,
    bool empty = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
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
        ),
        builder: (context, child) => MediaQuery.withClampedTextScaling(
          minScaleFactor: scale,
          maxScaleFactor: scale,
          child: child!,
        ),
        home: RepaintBoundary(
          key: boundaryKey,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const DefaultGlassBackdrop(),
              ViewingReportPage(
                state: state,
                historyOverride: empty ? const [] : viewingReportFixtureRecords,
                now: viewingReportFixtureNow,
                metadataOverride: viewingReportFixtureMetadata,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void expectBodyUnframed(WidgetTester tester) {
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.body, isNot(isA<GlassPane>()));
    expect(
      find.descendant(
        of: find.byWidget(scaffold.body!),
        matching: find.byType(GlassPane),
      ),
      findsNothing,
      reason: 'Report body and its sections must share the page backdrop',
    );
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(GlassPane),
      ),
      findsOneWidget,
    );
  }

  setUpAll(loadFixtureFonts);

  testWidgets(
    'unframed report hint ink meets contrast on exposed light backdrop',
    (tester) async {
      await pumpVisual(
        tester,
        size: const Size(1280, 800),
        brightness: Brightness.light,
      );
      final summary = find.byType(ViewingReportSummaryGrid);
      final hint = tester.widget<Text>(
        find.descendant(of: summary, matching: find.text('按最后观看时间统计')),
      );
      final foreground = hint.style!.color!.computeLuminance();
      final background = const Color(0xFFB7BAC0).computeLuminance();
      final contrast = (background + .05) / (foreground + .05);
      expect(contrast, greaterThanOrEqualTo(4.5));
    },
  );

  for (final brightness in Brightness.values) {
    for (final size in [const Size(1280, 800), const Size(1024, 640)]) {
      testWidgets('unframed report balanced summary ${brightness.name} $size', (
        tester,
      ) async {
        await pumpVisual(tester, size: size, brightness: brightness);
        expect(tester.takeException(), isNull);
        await capture(
          tester,
          'top-${brightness.name}-${size.width.toInt()}x${size.height.toInt()}',
        );
        expectBodyUnframed(tester);
        final rows = <double, int>{};
        for (final label in metricLabels) {
          final rect = tester.getRect(
            find.descendant(
              of: find.byType(ViewingReportSummaryGrid),
              matching: find.text(label),
            ),
          );
          rows.update(rect.top, (value) => value + 1, ifAbsent: () => 1);
          expect(rect.right, lessThanOrEqualTo(size.width));
        }
        expect(
          rows.values.toList(),
          size.width >= 1100 ? [4, 3] : [3, 2, 2],
          reason:
              'Avoid six-plus-one and three-plus-three-plus-one summary rows',
        );
        expect(
          find.descendant(
            of: find.byType(ViewingReportSummaryGrid),
            matching: find.byType(DecoratedBox),
          ),
          findsNothing,
          reason: 'Individual metric plates must not recreate nested dashboard cards',
        );
      });
    }
  }

  for (final brightness in Brightness.values) {
    testWidgets(
      'unframed report compact large text and empty ${brightness.name}',
      (tester) async {
        await pumpVisual(
          tester,
          size: const Size(720, 600),
          brightness: brightness,
          scale: 1.6,
        );
        expect(tester.takeException(), isNull);
        await capture(tester, 'large-top-${brightness.name}');
        final list = find.byKey(const ValueKey('viewing-report-list'));
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('viewing-report-heatmap')),
          350,
          scrollable: find
              .descendant(of: list, matching: find.byType(Scrollable))
              .first,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await capture(tester, 'large-heatmap-${brightness.name}');
        final heatScroll = find.descendant(
          of: find.byKey(const ValueKey('viewing-report-heatmap')),
          matching: find.byType(SingleChildScrollView),
        );
        await tester.drag(heatScroll, const Offset(-300, 0));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await pumpVisual(
          tester,
          size: const Size(720, 600),
          brightness: brightness,
          scale: 1.6,
          empty: true,
        );
        await capture(tester, 'empty-${brightness.name}');
        expectBodyUnframed(tester);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('全未知仍展示四维偏好和各维未知口径', (tester) async {
    await pump(tester);
    for (final name in ['内容偏好', '题材', '地区', '演员', '导演']) {
      expect(find.text(name), findsOneWidget);
    }
    expect(find.textContaining('查看作品详情'), findsOneWidget);
    expect(find.text('类型未知 20 条'), findsOneWidget);
    expect(find.textContaining('覆盖 0/20 条（0%）'), findsNWidgets(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('热力图提供7×24格、轴与每格文本语义', (tester) async {
    await pump(tester);
    expect(
      find.byKey(const ValueKey('viewing-report-heatmap')),
      findsOneWidget,
    );
    for (var day = 0; day < 7; day++) {
      for (var hour = 0; hour < 24; hour++) {
        expect(find.byKey(ValueKey('viewing-hour-$day-$hour')), findsOneWidget);
      }
    }
    expect(find.text('周一'), findsOneWidget);
    expect(find.text('00'), findsOneWidget);
    expect(find.text('23'), findsOneWidget);
    expect(find.byTooltip('周一 20:00–21:00 · 2 条记录'), findsOneWidget);
    final handle = tester.ensureSemantics();
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('viewing-hour-0-20')))
          .label,
      '周一 20:00–21:00 · 2 条记录',
    );
    handle.dispose();
  });

  testWidgets('摘要包含平均每条卡，按记录条数平均且保留一位小数', (tester) async {
    await pump(tester);
    final card = find.byKey(const ValueKey('viewing-summary-average'));
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.text('平均每条')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('54.8 分钟')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('按记录条数平均')),
      findsOneWidget,
    );
  });

  testWidgets('780窄屏七项摘要均衡换行且保持纵向滚动', (tester) async {
    await pump(tester, size: const Size(780, 2600));
    final summary = find.byType(ViewingReportSummaryGrid);
    final rows = <double, int>{};
    for (final label in metricLabels) {
      final item = find.descendant(of: summary, matching: find.text(label));
      expect(item, findsOneWidget);
      final rect = tester.getRect(item);
      expect(rect.left, greaterThanOrEqualTo(16));
      expect(rect.right, lessThanOrEqualTo(764.01));
      rows.update(rect.top, (value) => value + 1, ifAbsent: () => 1);
    }
    expect(rows.values.toList(), [3, 2, 2]);
    final scroll = find
        .ancestor(of: summary, matching: find.byType(Scrollable))
        .first;
    expect(tester.widget<Scrollable>(scroll).axisDirection, AxisDirection.down);
    expect(tester.takeException(), isNull);
  });

  testWidgets('热力图零值不显示数字但保留零值语义，非零值仍可读', (tester) async {
    await pump(tester);
    final empty = find.byKey(const ValueKey('viewing-hour-0-0'));
    final occupied = find.byKey(const ValueKey('viewing-hour-0-20'));
    expect(
      tester
          .widget<Text>(find.descendant(of: empty, matching: find.byType(Text)))
          .data,
      isEmpty,
    );
    expect(
      tester
          .widget<Text>(
            find.descendant(of: occupied, matching: find.byType(Text)),
          )
          .data,
      '2',
    );
    final handle = tester.ensureSemantics();
    expect(tester.getSemantics(empty).label, '周一 00:00–01:00 · 0 条记录');
    expect(find.byTooltip('周一 00:00–01:00 · 0 条记录'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('780窄屏的24小时轴和最后一列均在可用宽度内', (tester) async {
    await pump(tester, size: const Size(780, 2400));
    expect(tester.getRect(find.text('23')).right, lessThanOrEqualTo(764));
    expect(
      tester.getRect(find.byKey(const ValueKey('viewing-hour-0-23'))).right,
      lessThanOrEqualTo(764),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('全部范围不提供环比，站源不泄露配置URL', (tester) async {
    await pump(tester);
    expect(find.textContaining('全部范围不提供上一周期对比'), findsOneWidget);
    expect(find.text('站源分布'), findsOneWidget);
    for (final key in [
      fixtureUrlSourceKey,
      fixtureCatSourceKey,
      fixtureFileSourceKey,
    ]) {
      expect(find.text(key), findsNothing);
    }
  });

  testWidgets('有元数据展示真实四维、独立覆盖与探索者', (tester) async {
    await pump(tester, metadata: viewingReportFixtureMetadata);
    expect(find.text('电影 6 条'), findsOneWidget);
    expect(find.text('剧集 11 条'), findsOneWidget);
    expect(find.text('类型未知 3 条'), findsOneWidget);
    expect(find.textContaining('覆盖 17/20 条（85%）'), findsNWidgets(2));
    expect(find.textContaining('覆盖 14/20 条（70%）'), findsOneWidget);
    expect(find.textContaining('覆盖 16/20 条（80%）'), findsOneWidget);
    expect(find.textContaining('跨文化探索者'), findsOneWidget);
    for (final text in ['剧情', '中国', '张若昀', '孙皓']) {
      expect(find.text(text), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('宽屏四维双列，窄屏单列且长文本不溢出', (tester) async {
    await pump(tester, metadata: viewingReportFixtureMetadata);
    final genre = find.byKey(const ValueKey('viewing-preference-genre'));
    final area = find.byKey(const ValueKey('viewing-preference-area'));
    expect(tester.getTopLeft(genre).dy, tester.getTopLeft(area).dy);
    expect(
      tester.getTopLeft(area).dx,
      greaterThan(tester.getTopLeft(genre).dx),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await pump(
      tester,
      metadata: viewingReportFixtureMetadata,
      size: const Size(480, 2800),
    );
    expect(tester.getTopLeft(genre).dx, tester.getTopLeft(area).dx);
    expect(
      tester.getTopLeft(area).dy,
      greaterThan(tester.getTopLeft(genre).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('亮色及空历史基础空态可用', (tester) async {
    await pump(
      tester,
      brightness: Brightness.light,
      metadata: viewingReportFixtureMetadata,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await pump(tester, records: const []);
    expect(find.textContaining('还没有观看记录'), findsOneWidget);
    expect(find.byKey(const ValueKey('viewing-report-list')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('零基数环比显示新增而不是无穷百分比', (tester) async {
    await pump(tester, records: [viewingReportFixtureRecords.last]);
    await changeRange(tester, '最近7天');
    expect(find.textContaining('观看时长 新增'), findsOneWidget);
    expect(find.textContaining('Infinity'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI旧请求不能覆盖新范围结果或解除新请求loading', (tester) async {
    final pending = <Completer<http.Response>>[];
    final analyzer = ViewingReportAiAnalyzer(
      client: AiCompletionClient(
        client: MockClient((_) {
          final c = Completer<http.Response>();
          pending.add(c);
          return c.future;
        }),
      ),
    );
    const ai = AiConfig(
      enabled: true,
      protocol: AiProtocol.openAiChat,
      endpoint: 'https://example.test/v1/chat/completions',
      apiKey: 'k',
      model: 'm',
    );
    await pump(
      tester,
      metadata: viewingReportFixtureMetadata,
      ai: ai,
      analyzer: analyzer,
    );
    expect(pending, isEmpty, reason: '打开报告不得自动请求 AI');
    final run = find.byKey(const ValueKey('viewing-report-ai-run'));
    await tester.ensureVisible(run);
    await tester.tap(run);
    await tester.pump();
    expect(pending, hasLength(1));
    await tester.tap(find.byKey(const ValueKey('viewing-report-range')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('最近7天').last);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('生成中…'), findsNothing);
    await tester.ensureVisible(run);
    await tester.tap(run);
    await tester.pump();
    expect(pending, hasLength(2));
    http.Response response(String text) => http.Response(
      jsonEncode({
        'choices': [
          {
            'message': {'content': text},
          },
        ],
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
    pending[0].complete(response('旧范围解读'));
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('旧范围解读'), findsNothing);
    expect(tester.widget<FilledButton>(run).onPressed, isNull);
    expect(find.text('生成中…'), findsOneWidget);
    pending[1].complete(response('新范围解读'));
    await tester.pumpAndSettle();
    expect(find.text('新范围解读'), findsOneWidget);
    await changeRange(tester, '本月 (10月)');
    expect(find.text('新范围解读'), findsNothing);
    expect(tester.widget<FilledButton>(run).onPressed, isNotNull);
  });

  testWidgets('本地元数据只在打开报告时读取一次，范围切换不重读', (tester) async {
    final counting = _CountingMetadataState();
    addTearDown(counting.dispose);
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: ViewingReportPage(
          state: counting,
          historyOverride: viewingReportFixtureRecords,
          now: viewingReportFixtureNow,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(counting.metadataReads, 1);
    await changeRange(tester, '最近7天');
    expect(counting.metadataReads, 1);
    await tester.pump();
    expect(counting.metadataReads, 1);
  });

  testWidgets('同源站点跨配置分组，Text Tooltip Semantics均不泄露地址', (tester) async {
    await pump(tester, metadata: viewingReportFixtureMetadata);
    expect(find.textContaining('· local'), findsOneWidget);
    expect(find.textContaining('· main'), findsNWidgets(2));
    for (final element in find.byType(Tooltip).evaluate()) {
      final tooltip = element.widget as Tooltip;
      expect(tooltip.message, isNot(contains('https://')));
      expect(tooltip.message, isNot(contains(fixtureFileSourceKey)));
    }
    for (final element in find.byType(Semantics).evaluate()) {
      final semantics = element.widget as Semantics;
      expect(semantics.properties.label ?? '', isNot(contains('https://')));
      expect(
        semantics.properties.label ?? '',
        isNot(contains(fixtureFileSourceKey)),
      );
    }
  });

  testWidgets('AI失败提示可重试且不隐藏基础报告', (tester) async {
    final analyzer = ViewingReportAiAnalyzer(
      client: AiCompletionClient(
        client: MockClient((_) async => http.Response('offline fixture', 500)),
      ),
    );
    const ai = AiConfig(
      enabled: true,
      protocol: AiProtocol.openAiChat,
      endpoint: 'https://example.test/v1/chat/completions',
      apiKey: 'k',
      model: 'm',
    );
    await pump(
      tester,
      metadata: viewingReportFixtureMetadata,
      ai: ai,
      analyzer: analyzer,
    );
    final run = find.byKey(const ValueKey('viewing-report-ai-run'));
    await tester.ensureVisible(run);
    await tester.tap(run);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('viewing-report-ai-error')),
      findsOneWidget,
    );
    expect(find.text('1095 分钟'), findsOneWidget);
    expect(tester.widget<FilledButton>(run).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切换无历史范围显示诚实空态，切回恢复本地报告', (tester) async {
    await pump(tester, metadata: viewingReportFixtureMetadata);
    await changeRange(tester, '上半年');
    expect(find.text('上半年还没有观看记录'), findsOneWidget);
    expect(find.byKey(const ValueKey('viewing-report-list')), findsNothing);
    await changeRange(tester, '全部');
    expect(find.text('1095 分钟'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('两期时长都为零显示无记录，不显示NaN', (tester) async {
    final row = viewingReportFixtureRecords.last;
    final zero = PlaybackHistory(
      id: row.id,
      siteKey: row.siteKey,
      vodId: row.vodId,
      vodName: row.vodName,
      flag: row.flag,
      episodeName: row.episodeName,
      episodeId: row.episodeId,
      positionMs: 0,
      durationMs: 0,
      updatedAt: row.updatedAt,
    );
    await pump(tester, records: [zero]);
    await changeRange(tester, '最近7天');
    expect(find.textContaining('观看时长 无记录'), findsOneWidget);
    expect(find.textContaining('NaN'), findsNothing);
  });
}
