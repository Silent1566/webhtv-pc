import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
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

  @override
  Future<EpgLoadResult> load({
    required String url,
    List<LiveChannel> liveChannels = const [],
    String sourceName = '',
    bool forceRefresh = false,
  }) async {
    if (fail) throw AppError(AppErrorKind.epgHttp, 'EPG 加载失败', statusCode: 500);
    return EpgLoadResult(
      guide: EpgGuide.empty,
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
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness),
        navigatorObservers: [observer],
        home: Scaffold(body: LivePage(state: state)),
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

  testWidgets('大量频道惰性构建，分组定位能跳到末组', (tester) async {
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
    await mount(tester);
    expect(find.text('频道 499'), findsNothing);
    await tester.tap(find.byTooltip('定位分组'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('末组').last);
    await tester.pumpAndSettle();
    expect(find.text('最后频道'), findsOneWidget);
  });
}
