import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/epg.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/epg_service.dart';
import 'package:webhtv_pc/services/live_service.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/glass_widgets.dart';
import 'package:webhtv_pc/ui/live_page.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tmdb_widgets.dart';

import 'support/test_fonts.dart';

const _root = ValueKey('live-unframed-capture');
final _captureDir = Platform.environment['LIVE_UNFRAMED_CAPTURE'];
final _phase = Platform.environment['LIVE_UNFRAMED_PHASE'] ?? 'after';

// Same in-memory service seams as live_page_interaction_test.dart.
class _LiveService extends LiveService {
  Completer<LiveLoadResult>? pending;
  int loads = 0;

  @override
  Future<LiveLoadResult> load(LiveSource source, {bool useCache = true}) async {
    loads++;
    if (pending != null) return pending!.future;
    return LiveLoadResult(
      source: source,
      playlist: LivePlaylist(
        sourceName: source.name,
        epg: 'http://fixture/epg.xml',
        groups: [
          LiveGroup(
            name: '分组 A',
            channels: [
              LiveChannel(
                name: '频道 A',
                group: '分组 A',
                urls: ['http://fixture/a', 'http://fixture/b'],
              ),
            ],
          ),
        ],
      ),
      latency: Duration.zero,
    );
  }
}

class _EpgService extends EpgService {
  _EpgService({required super.cacheDir});
  Completer<EpgLoadResult>? pending;

  @override
  Future<EpgLoadResult> load({
    required String url,
    List<LiveChannel> liveChannels = const [],
    String sourceName = '',
    bool forceRefresh = false,
  }) async {
    if (pending != null) return pending!.future;
    return EpgLoadResult(
      guide: const EpgGuide(
        channels: {
          '频道 A': EpgChannelGuide(
            channelId: '频道 A',
            programs: [EpgProgram(title: '已有节目', startMs: 0, stopMs: 60000)],
          ),
        },
        totalPrograms: 1,
        skippedPrograms: 0,
        sourceName: '源 A',
      ),
      url: url,
      fromCache: true,
      latency: Duration.zero,
      bytes: 0,
    );
  }
}

void _expectUnframed() {
  expect(find.byType(ContentGlassViewport), findsNothing);
  expect(find.byType(GlassPane), findsNothing);
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (_captureDir == null) return;
  final geometry = [
    for (final element in find.byType(Text).evaluate())
      {
        'text': (element.widget as Text).data,
        'bounds': (() {
          final rect = tester.getRect(
            find.byElementPredicate(
              (candidate) => identical(candidate, element),
            ),
          );
          return [rect.left, rect.top, rect.width, rect.height];
        })(),
      },
  ];
  await tester.runAsync(() async {
    final geometryFile = File('$_captureDir/geometry-$_phase.json');
    final records = geometryFile.existsSync()
        ? jsonDecode(geometryFile.readAsStringSync()) as Map<String, dynamic>
        : <String, dynamic>{};
    records[name] = geometry;
    geometryFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(records),
    );
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_root),
    );
    final image = await boundary.toImage();
    try {
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      File('$_captureDir/$name-$_phase.png').writeAsBytesSync(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
    } finally {
      image.dispose();
    }
  });
}

void main() {
  late Directory temp;
  late AppState state;
  late _LiveService live;
  late _EpgService epg;

  setUpAll(() async {
    await loadFixtureFonts();
  });

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('live-unframed');
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/webhtv-pc',
        'data': '${temp.path}/webhtv-pc',
        'cache': '${temp.path}/webhtv-pc/cache',
        'state': '${temp.path}/webhtv-pc/logs',
      },
    );
    live = _LiveService();
    epg = _EpgService(cacheDir: paths.cacheDir);
    state = AppState(
      paths: paths,
      log: LogService(),
      liveService: live,
      epgService: epg,
    );
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    live.close();
    epg.close();
    await temp.delete(recursive: true);
  });

  Future<void> importSource() => state.importConfig(
    jsonEncode({
      'sites': [
        {
          'key': 'fixture',
          'name': 'fixture',
          'type': 1,
          'api': 'http://fixture/api',
        },
      ],
      'lives': [
        {'name': '源 A', 'type': 1, 'url': 'http://fixture/a.m3u'},
      ],
    }),
    displayName: 'fixture',
  );

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1024, 640),
    Brightness brightness = Brightness.dark,
    double scale = 1,
    bool settle = true,
    bool underlap = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final theme = buildAppTheme(brightness);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme.copyWith(
          textTheme: theme.textTheme.apply(fontFamily: 'FixtureCJK'),
          listTileTheme: theme.listTileTheme.copyWith(
            titleTextStyle: theme.listTileTheme.titleTextStyle?.copyWith(
              fontFamily: 'FixtureCJK',
            ),
            subtitleTextStyle: theme.listTileTheme.subtitleTextStyle?.copyWith(
              fontFamily: 'FixtureCJK',
            ),
          ),
        ),
        builder: (context, child) => RepaintBoundary(
          key: _root,
          child: MediaQuery.withClampedTextScaling(
            minScaleFactor: scale,
            maxScaleFactor: scale,
            child: child!,
          ),
        ),
        home: Scaffold(
          backgroundColor: theme.colorScheme.surface,
          body: LivePage(
            state: state,
            shellUnderlap: underlap,
            clock: () => DateTime.fromMillisecondsSinceEpoch(30000),
          ),
        ),
      ),
    );
    if (settle) await tester.pumpAndSettle();
  }

  testWidgets('empty guidance has no page-level surface', (tester) async {
    await mount(tester);
    expect(find.text('当前配置没有直播源'), findsOneWidget);
    _expectUnframed();
  });

  for (final underlap in [false, true]) {
    testWidgets('loaded source and EPG stay unframed underlap=$underlap', (
      tester,
    ) async {
      await importSource();
      await mount(tester, underlap: underlap);
      expect(find.text('频道 A'), findsOneWidget);
      expect(find.text('节目单：1 条 (1 个频道)'), findsOneWidget);
      _expectUnframed();
    });
  }

  testWidgets('loading and failed source retain unframed retry', (
    tester,
  ) async {
    await importSource();
    final pending = live.pending = Completer<LiveLoadResult>();
    await mount(tester, settle: false);
    await tester.pump();
    expect(find.text('加载中…'), findsOneWidget);
    _expectUnframed();
    pending.completeError(AppError(AppErrorKind.liveHttp, 'fixture failure'));
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
    _expectUnframed();
    live.pending = null;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('频道 A'), findsOneWidget);
    expect(live.loads, 2);
    _expectUnframed();
  });

  testWidgets('EPG refresh preserves cached preview and exposes retry', (
    tester,
  ) async {
    await importSource();
    await mount(tester);
    await tester.tap(find.byTooltip('详情与节目单 频道 A'));
    await tester.pumpAndSettle();
    expect(find.text('已有节目'), findsOneWidget);
    final pending = epg.pending = Completer<EpgLoadResult>();
    await tester.tap(find.byTooltip('刷新节目单'));
    await tester.pump();
    expect(find.text('节目单加载中…'), findsOneWidget);
    expect(find.text('已有节目'), findsOneWidget);
    _expectUnframed();
    pending.completeError(
      AppError(AppErrorKind.epgHttp, 'fixture failure', statusCode: 500),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('EPG 加载失败'), findsOneWidget);
    expect(find.text('已有节目'), findsOneWidget);
    _expectUnframed();
    epg.pending = null;
    await tester.tap(find.byTooltip('刷新节目单'));
    await tester.pumpAndSettle();
    expect(find.text('节目单：1 条 (1 个频道)'), findsOneWidget);
    expect(find.text('已有节目'), findsOneWidget);
    _expectUnframed();
  });

  testWidgets('transparent materials preserve keyboard group and refresh', (
    tester,
  ) async {
    await importSource();
    await mount(tester);
    final toggle = find.byKey(const ValueKey('live-group-toggle'));
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(toggle));
    addTearDown(mouse.removePointer);
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
    final focus = Focus.of(
      tester.element(find.descendant(of: toggle, matching: find.byType(Text))),
    );
    focus.requestFocus();
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('分组 A'), findsOneWidget);
    await tester.tap(find.text('分组 A'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('详情与节目单 频道 A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('线路'));
    await tester.pumpAndSettle();
    expect(find.text('线路 2'), findsOneWidget);
    await tester.tap(find.byTooltip('刷新当前直播源'));
    await tester.pumpAndSettle();
    expect(live.loads, 2);
    expect(find.text('线路 2'), findsOneWidget);
    expect(
      tester
          .widget<ListTile>(
            find.ancestor(
              of: find.text('源 A'),
              matching: find.byType(ListTile),
            ),
          )
          .selected,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  for (final brightness in [Brightness.dark, Brightness.light]) {
    for (final loaded in [false, true]) {
      for (final compact in [false, true]) {
        final name =
            '${loaded ? 'loaded' : 'empty'}-${brightness.name}-'
            '${compact ? '720x600-2x' : '1024x640-1x'}';
        testWidgets('renders $name without overflow', (tester) async {
          if (loaded) await importSource();
          await mount(
            tester,
            brightness: brightness,
            size: compact ? const Size(720, 600) : const Size(1024, 640),
            scale: compact ? 2 : 1,
          );
          if (loaded) {
            await tester.tap(find.byTooltip('详情与节目单 频道 A'));
            await tester.pumpAndSettle();
            expect(find.text('已有节目'), findsOneWidget);
          } else {
            expect(find.text('当前配置没有直播源'), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
          await _capture(tester, name);
        });
      }
    }
  }
}
