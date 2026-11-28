import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/epg.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/epg_service.dart';
import 'package:webhtv_pc/services/live_service.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/live_page.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/test_fonts.dart';

final _captureDir = Platform.environment['LIVE_STATE_CAPTURE'];
final _capturePhase = Platform.environment['LIVE_STATE_PHASE'];
const _captureKey = ValueKey('live-state-capture');

Future<void> _capture(WidgetTester tester, String scenario) async {
  final dir = _captureDir;
  if (dir == null) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_captureKey),
    );
    final image = await boundary.toImage();
    try {
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      File('$dir/$scenario-$_capturePhase.png').writeAsBytesSync(
        png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      );
    } finally {
      image.dispose();
    }
  });
}

class _LiveService extends LiveService {
  final Map<String, LivePlaylist> playlists = {};

  @override
  Future<LiveLoadResult> load(
    LiveSource source, {
    bool useCache = true,
  }) async => LiveLoadResult(
    source: source,
    playlist: playlists[source.name]!,
    latency: Duration.zero,
  );
}

class _EpgService extends EpgService {
  _EpgService({required super.cacheDir});
  bool fail = false;
  EpgGuide guide = EpgGuide.empty;
  Completer<EpgLoadResult>? refresh;

  @override
  Future<EpgLoadResult> load({
    required String url,
    List<LiveChannel> liveChannels = const [],
    String sourceName = '',
    bool forceRefresh = false,
  }) async {
    if (forceRefresh && refresh != null) return refresh!.future;
    if (fail) throw AppError(AppErrorKind.epgHttp, 'EPG 加载失败', statusCode: 500);
    return EpgLoadResult(
      guide: guide,
      url: url,
      fromCache: false,
      latency: Duration.zero,
      bytes: 0,
    );
  }
}

// 检查 LivePage 真实生成的路由及请求，不挂载需要原生媒体引擎的播放器。
class _PlaybackObserver extends NavigatorObserver {
  PlayerPage? player;
  FutureOr<void> Function(PlayerPage)? onOpen;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute == null || route is! MaterialPageRoute) return;
    final page = route.builder(navigator!.context);
    if (page is! PlayerPage) return;
    player = page;
    scheduleMicrotask(() async {
      await onOpen?.call(page);
      navigator!.pop();
    });
  }
}

void main() {
  late Directory temp;
  late AppState state;
  late _LiveService service;
  late _EpgService epg;
  late _PlaybackObserver observer;

  setUpAll(() async {
    if (_captureDir != null) await loadFixtureFonts();
  });

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('live-interaction');
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/webhtv-pc',
        'data': '${temp.path}/webhtv-pc',
        'cache': '${temp.path}/webhtv-pc/cache',
        'state': '${temp.path}/webhtv-pc/logs',
      },
    );
    service = _LiveService();
    epg = _EpgService(cacheDir: paths.cacheDir);
    observer = _PlaybackObserver();
    state = AppState(
      paths: paths,
      log: LogService(),
      liveService: service,
      epgService: epg,
    );
    await state.bootstrap();
    service.playlists['源 A'] = LivePlaylist(
      sourceName: '源 A',
      epg: 'http://fixture/epg.xml',
      groups: [
        LiveGroup(
          name: '分组 A',
          channels: [
            LiveChannel(
              name: '频道 A',
              group: '分组 A',
              urls: ['http://fixture/a', 'http://fixture/b'],
              header: HeaderMap({
                'Referer': 'http://fixture/',
                'User-Agent': 'fixture-player',
              }),
            ),
            LiveChannel(name: '空频道', group: '分组 A'),
          ],
        ),
      ],
    );
    await state.importConfig(
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
  });

  tearDown(() async {
    state.dispose();
    service.close();
    epg.close();
    await temp.delete(recursive: true);
  });

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1024, 640),
    Brightness brightness = Brightness.dark,
    double textScale = 1,
    double shellRailWidth = 0,
    DateTime Function()? clock,
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
        theme: _captureDir == null
            ? theme
            : theme.copyWith(
                textTheme: theme.textTheme.apply(fontFamily: 'FixtureCJK'),
                tooltipTheme: theme.tooltipTheme.copyWith(
                  textStyle: theme.tooltipTheme.textStyle?.copyWith(
                    fontFamily: 'FixtureCJK',
                  ),
                ),
              ),
        builder: (context, child) => RepaintBoundary(
          key: _captureKey,
          child: MediaQuery.withClampedTextScaling(
            minScaleFactor: textScale,
            maxScaleFactor: textScale,
            child: child!,
          ),
        ),
        navigatorObservers: [observer],
        home: Scaffold(
          body: Padding(
            padding: EdgeInsets.only(left: shellRailWidth),
            child: LivePage(state: state, clock: clock),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> importSources(List<String> names) async {
    await state.importConfig(
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
          for (final name in names)
            {'name': name, 'type': 1, 'url': 'http://fixture/$name.m3u'},
        ],
      }),
      displayName: 'fixture',
    );
  }

  testWidgets('返回读取最终实际源频道线路，缓存节目单并滚到末组', (tester) async {
    final last = LiveChannel(
      name: '最终频道',
      group: '末组',
      urls: ['http://fixture/last-1', 'http://fixture/last-2'],
    );
    service.playlists['源 B'] = LivePlaylist(
      sourceName: '源 B',
      epg: 'http://fixture/b-epg.xml',
      groups: [
        LiveGroup(
          name: '首组',
          channels: List.generate(
            80,
            (i) => LiveChannel(name: 'B $i', urls: ['http://fixture/$i']),
          ),
        ),
        LiveGroup(name: '末组', channels: [last]),
      ],
    );
    service.playlists['候选 C'] = LivePlaylist(
      sourceName: '候选 C',
      groups: [
        LiveGroup(
          name: '候选组',
          channels: [
            LiveChannel(name: '候选频道', urls: ['http://fixture/c']),
          ],
        ),
      ],
    );
    await importSources(['源 A', '源 B', '候选 C']);
    observer.onOpen = (page) async {
      final session = page.liveSession!;
      await session.browse(state.liveSources[1]);
      expect(session.selectChannel(last, lineIndex: 1), isTrue);
      session.confirmPlayback(session.playbackRevision);
      await session.browse(state.liveSources[2]);
    };
    await mount(tester);
    await tester.tap(find.text('频道 A').first);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('live-channel-list')),
        matching: find.text('最终频道'),
      ),
      findsOneWidget,
    );
    expect(find.text('候选频道'), findsNothing);
    final sourceTile = tester.widget<ListTile>(
      find.ancestor(of: find.text('源 B'), matching: find.byType(ListTile)),
    );
    expect(sourceTile.selected, isTrue);
    final line = tester.widget<ListTile>(
      find.ancestor(of: find.text('线路 2'), matching: find.byType(ListTile)),
    );
    expect(line.selected, isTrue);
    expect(find.textContaining('节目单：'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('源 A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('源 B'));
    await tester.pumpAndSettle();
    expect(find.text('B 0'), findsOneWidget);
    expect(
      () => observer.player!.liveSession!.addListener(() {}),
      throwsFlutterError,
    );
  });

  testWidgets('未确认的新频道不能覆盖返回时的实际播放选择', (tester) async {
    final pending = LiveChannel(
      name: '待播放频道',
      urls: ['http://fixture/pending'],
    );
    service.playlists['源 B'] = LivePlaylist(
      sourceName: '源 B',
      groups: [
        LiveGroup(name: 'B', channels: [pending]),
      ],
    );
    await importSources(['源 A', '源 B']);
    observer.onOpen = (page) async {
      await page.liveSession!.browse(state.liveSources[1]);
      expect(page.liveSession!.selectChannel(pending), isTrue);
    };
    await mount(tester);
    await tester.tap(find.text('频道 A').first);
    await tester.pumpAndSettle();
    expect(find.text('待播放频道'), findsNothing);
    expect(find.text('频道 A'), findsNWidgets(2));
    final tile = tester.widget<ListTile>(
      find.ancestor(of: find.text('源 A'), matching: find.byType(ListTile)),
    );
    expect(tile.selected, isTrue);
  });

  testWidgets('详情入口只更新预览，不开播', (tester) async {
    await mount(tester);
    await tester.tap(find.byTooltip('详情与节目单 频道 A'));
    await tester.pumpAndSettle();
    expect(observer.player, isNull);
    expect(find.text('线路 1'), findsOneWidget);
    expect(find.text('线路 2'), findsOneWidget);
  });

  testWidgets('单击频道开播，并保留频道预览', (tester) async {
    await mount(tester);
    await tester.tap(find.text('频道 A').first);
    await tester.pumpAndSettle();
    expect(observer.player?.request.url, 'http://fixture/a');
    expect(observer.player?.request.siteKey, '源 A');
    expect(observer.player!.liveSession!.source.name, '源 A');
    expect(observer.player!.liveSession!.channel.name, '频道 A');
    expect(find.text('线路 2'), findsOneWidget);
  });

  testWidgets('详情中选择线路 2 传递初值与频道 Header', (tester) async {
    await mount(tester);
    await tester.tap(find.byTooltip('详情与节目单 频道 A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('线路 2'));
    await tester.pumpAndSettle();
    final request = observer.player!.request;
    expect(request.url, 'http://fixture/b');
    expect(request.episodeIndex, 1);
    expect(observer.player!.liveSession!.lineIndex, 1);
    expect(request.headers, {
      'Referer': 'http://fixture/',
      'User-Agent': 'fixture-player',
    });
  });

  testWidgets('刷新直播源使用新线路，已移除线路不再可播放', (tester) async {
    await mount(tester);
    await tester.tap(find.byTooltip('详情与节目单 频道 A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('线路 2'));
    await tester.pumpAndSettle();
    expect(observer.player?.request.url, 'http://fixture/b');
    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, '线路 2')).selected,
      isTrue,
    );
    observer.player = null;

    service.playlists['源 A'] = LivePlaylist(
      sourceName: '源 A',
      epg: 'http://fixture/epg.xml',
      groups: [
        LiveGroup(
          name: '分组 A',
          channels: [
            LiveChannel(
              name: '频道 A',
              group: '分组 A',
              urls: ['http://fixture/new'],
            ),
          ],
        ),
      ],
    );
    await tester.tap(find.byTooltip('刷新当前直播源'));
    await tester.pumpAndSettle();
    await _capture(tester, 'line-replaced');
    expect(observer.player, isNull);
    expect(find.byTooltip('http://fixture/b'), findsNothing);
    expect(find.byTooltip('http://fixture/a'), findsNothing);
    expect(find.text('线路 2'), findsNothing);
    final line = find.widgetWithText(ListTile, '线路 1');
    expect(tester.widget<ListTile>(line).selected, isFalse);
    await tester.tap(line);
    await tester.pumpAndSettle();
    expect(observer.player?.request.url, 'http://fixture/new');
  });

  testWidgets('刷新直播源移除已预览频道时清理详情', (tester) async {
    await mount(tester);
    await tester.tap(find.byTooltip('详情与节目单 频道 A'));
    await tester.pumpAndSettle();

    service.playlists['源 A'] = LivePlaylist(
      sourceName: '源 A',
      groups: [
        LiveGroup(
          name: '分组 A',
          channels: [
            LiveChannel(name: '剩余频道', urls: ['http://fixture/keep']),
          ],
        ),
      ],
    );
    await tester.tap(find.byTooltip('刷新当前直播源'));
    await tester.pumpAndSettle();
    await _capture(tester, 'channel-removed');
    expect(observer.player, isNull);
    expect(find.text('频道 A'), findsNothing);
    expect(find.byTooltip('http://fixture/a'), findsNothing);
    expect(find.textContaining('使用详情按钮'), findsOneWidget);
    await tester.tap(find.byTooltip('播放 剩余频道'));
    await tester.pumpAndSettle();
    expect(observer.player?.request.url, 'http://fixture/keep');
  });

  testWidgets('EPG 刷新时保留节目，失败时长状态可读且仍可播放', (tester) async {
    epg.guide = const EpgGuide(
      channels: {
        '频道 A': EpgChannelGuide(
          channelId: '频道 A',
          programs: [EpgProgram(title: '已有节目', startMs: 0, stopMs: 60000)],
        ),
      },
      totalPrograms: 1,
      skippedPrograms: 0,
      sourceName: '源 A',
    );
    await mount(tester, textScale: 1.7, shellRailWidth: 77);
    await tester.tap(find.byTooltip('详情与节目单 频道 A'));
    await tester.pumpAndSettle();
    const countLabel = '节目单：1 条 (1 个频道)';
    final count = find.text(countLabel);
    final program = find.text('已有节目');
    expect(count, findsOneWidget);
    expect(program, findsOneWidget);

    final pending = epg.refresh = Completer<EpgLoadResult>();
    final refresh = find.byTooltip('刷新节目单');
    await tester.tap(refresh);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final loadingVisible = find.text('节目单加载中…').evaluate().isNotEmpty;
    final countVisible = count.evaluate().isNotEmpty;
    expect(program, findsOneWidget);
    await _capture(tester, 'epg-loading');

    pending.completeError(
      AppError(AppErrorKind.epgHttp, '服务器失败', statusCode: 500),
    );
    await tester.pumpAndSettle();
    const message = 'EPG 加载失败：EPG 下载失败：服务器返回非 2xx 状态（不影响直播播放）';
    final error = find.text(message);
    expect(error, findsOneWidget);
    final clipped = tester
        .renderObject<RenderParagraph>(error)
        .didExceedMaxLines;
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(error));
    addTearDown(mouse.removePointer);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    final statusDiscoverable = error.evaluate().length == 2;
    await _capture(tester, 'epg-error');
    expect(program, findsOneWidget);
    expect(
      clipped,
      isTrue,
      reason: "The long status must exceed the inline width.",
    );
    expect(refresh, findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('播放 频道 A'));
    await tester.pumpAndSettle();
    expect(observer.player?.request.url, 'http://fixture/a');
    expect(
      (
        loadingVisible: loadingVisible,
        countVisible: countVisible,
        statusDiscoverable: statusDiscoverable,
      ),
      (loadingVisible: true, countVisible: false, statusDiscoverable: true),
    );
  });

  testWidgets('EPG 失败后单击仍可播放，空频道不可开播', (tester) async {
    epg.fail = true;
    await mount(tester);
    expect(find.textContaining('不影响直播播放'), findsOneWidget);
    await tester.tap(find.text('空频道'));
    await tester.pumpAndSettle();
    expect(observer.player, isNull);
    await tester.tap(find.text('频道 A').first);
    await tester.pumpAndSettle();
    expect(observer.player?.request.url, 'http://fixture/a');
  });

  for (final size in [
    const Size(800, 600),
    const Size(1024, 640),
    const Size(1440, 900),
  ]) {
    for (final brightness in [Brightness.dark, Brightness.light]) {
      testWidgets('长文本在 $size $brightness 三列保持可达且无溢出', (tester) async {
        final longName = List.filled(20, '长频道标题').join();
        final longUrl =
            'http://fixture/${List.filled(80, 'long-path').join('/')}';
        service.playlists['源 A'] = LivePlaylist(
          sourceName: '源 A',
          groups: [
            LiveGroup(
              name: List.filled(20, '长分组').join(),
              channels: [
                LiveChannel(name: longName, urls: [longUrl]),
              ],
            ),
          ],
        );
        await mount(tester, size: size, brightness: brightness);
        await tester.tap(find.byTooltip('详情与节目单 $longName'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byTooltip(longUrl), findsOneWidget);
        expect(find.text('线路 1'), findsOneWidget);
      });
    }
  }

  testWidgets('频道行在 2.4× 字号显示频道、节目和操作', (tester) async {
    epg.guide = const EpgGuide(
      channels: {
        '频道 A': EpgChannelGuide(
          channelId: '频道 A',
          programs: [EpgProgram(title: '直播节目', startMs: 0, stopMs: 60000)],
        ),
      },
      totalPrograms: 1,
      skippedPrograms: 0,
      sourceName: '源 A',
    );
    await mount(
      tester,
      textScale: 2.4,
      shellRailWidth: 77,
      clock: () => DateTime.fromMillisecondsSinceEpoch(30000),
    );
    await _capture(tester, 'channel-row-2.4x');
    expect(tester.takeException(), isNull);

    final title = find.text('频道 A');
    final row = find.ancestor(of: title, matching: find.byType(InkWell)).first;
    final rowBounds = tester.getRect(row);
    final count = find.text('2 线路');
    final details = find.byTooltip('详情与节目单 频道 A');
    final play = find.byTooltip('播放 频道 A');
    for (final item in [
      title,
      count,
      find.textContaining('直播节目'),
      details,
      play,
    ]) {
      expect(item, findsOneWidget);
      final bounds = tester.getRect(item);
      expect(rowBounds.intersect(bounds), bounds);
    }
    expect(
      tester.renderObject<RenderParagraph>(title).didExceedMaxLines,
      isFalse,
    );
    expect(
      tester.renderObject<RenderParagraph>(count).didExceedMaxLines,
      isFalse,
    );
    await tester.tap(details);
    await tester.pumpAndSettle();
    expect(find.text('节目单'), findsOneWidget);
    expect(observer.player, isNull);
    await tester.tap(play);
    await tester.pumpAndSettle();
    expect(observer.player?.request.url, 'http://fixture/a');
    expect(tester.takeException(), isNull);
  });

  for (final scale in [1.0, 2.4]) {
    testWidgets('大量频道惰性构建，分组定位能跳到末组（$scale×）', (tester) async {
      service.playlists['源 A'] = LivePlaylist(
        sourceName: '源 A',
        groups: [
          LiveGroup(
            name: '首组',
            channels: List.generate(
              500,
              (i) => LiveChannel(name: '频道 $i', urls: ['http://fixture/$i']),
            ),
          ),
          LiveGroup(
            name: '末组',
            channels: [
              LiveChannel(name: '最后频道', urls: ['http://fixture/last']),
            ],
          ),
        ],
      );
      await mount(tester, textScale: scale);
      if (scale == 1) {
        expect(
          tester.getTopLeft(find.text('频道 1')).dy -
              tester.getTopLeft(find.text('频道 0')).dy,
          64,
        );
      }
      expect(find.text('频道 499'), findsNothing);
      await tester.tap(find.byTooltip('定位分组'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('末组').last);
      await tester.pumpAndSettle();
      expect(find.text('最后频道').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
