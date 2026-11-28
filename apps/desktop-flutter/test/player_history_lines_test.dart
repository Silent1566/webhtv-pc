import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webhtv_pc/core/history_view.dart';
import 'package:webhtv_pc/core/playback_lines.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/source_key.dart';
import 'package:webhtv_pc/core/source_swap.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/live_playback_session.dart';
import 'package:webhtv_pc/ui/player_episode_panel.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/player_quality_panel.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/toast.dart';

import 'player_queue_test.dart' as queue_fixture;
import 'support/player_page_harness.dart';

final historyLines = [
  VodPlayLine(
    flag: '线路一',
    sourceFlag: 'backend-a',
    episodes: [
      VodEpisode(name: '第1集 星空初遇', url: 'target-1'),
      VodEpisode(name: '第2集 月下重逢', url: 'target-2'),
      VodEpisode(name: '第3集 远方来信', url: 'target-3'),
    ],
  ),
  VodPlayLine(
    flag: '线路二',
    sourceFlag: 'backend-b',
    episodes: [
      VodEpisode(name: '第1集 另一段旅程', url: 'alt-target-1'),
      VodEpisode(name: '第2集 再次相遇', url: 'alt-target-2'),
    ],
  ),
];

/// 网盘聚合目录条目（`atvp_detail:` 前缀）展开后的线路。
///
/// 形态取自真机记录：`vod_id="atvp_detail:131957"`、`flag="丫仙女"`、
/// `episode_id="1@20465"`。两条提供方线路 = 两个目录条目；第二个条目自己有
/// 两条线路，因此合并名带 ` · `（与 `folderDetail` 的命名规则一致）。
final folderLines = [
  VodPlayLine(
    flag: '丫仙女',
    sourceFlag: '丫仙女',
    episodes: [
      VodEpisode(name: '01(696.02 MB)', url: '1@20465'),
      VodEpisode(name: '02(1.2 GB)', url: '1@20466'),
    ],
  ),
  VodPlayLine(
    flag: 'quark · 夸克',
    sourceFlag: '夸克',
    episodes: [
      VodEpisode(name: '01(696.02 MB)', url: '9@30001'),
      VodEpisode(name: '02(1.2 GB)', url: '9@30002'),
    ],
  ),
  VodPlayLine(
    flag: 'quark · 夸克原画',
    sourceFlag: '夸克原画',
    episodes: [VodEpisode(name: '01(696.02 MB)', url: '9@40001')],
  ),
];

/// 目录线路的来源路由。
///
/// 这里的 `siteKey` 故意与请求上的 `history-site` 不同：真机上目录条目与父
/// 目录同站，只有这样夹具才能证明「解析用的是路由而不是请求」。
final folderRoutes = {
  '丫仙女': const SwapLineRoute(
    siteKey: 'bridge-site',
    siteName: '桥接站',
    vodId: 'hxq-1',
  ),
  'quark · 夸克': const SwapLineRoute(
    siteKey: 'bridge-site',
    siteName: '桥接站',
    vodId: 'hxq-2',
  ),
  'quark · 夸克原画': const SwapLineRoute(
    siteKey: 'bridge-site',
    siteName: '桥接站',
    vodId: 'hxq-2',
  ),
};

PlaybackRequest historyRequest({
  String siteKey = 'history-site',
  String vodId = 'history-vod',
  String flag = '线路一',
  String target = 'target-2',
  String episodeName = '第2集 月下重逢',
  String sourceKey = 'original-config',
  List<VodPlayLine> playLines = const [],
}) => PlaybackRequest(
  url: 'https://media.test/resolved-2.m3u8',
  episodeTarget: target,
  title: '星空旅程',
  siteKey: siteKey,
  vodId: vodId,
  vodName: '星空旅程',
  episodeName: episodeName,
  flag: flag,
  playbackFlag: 'original-backend',
  sourceKey: sourceKey,
  playLines: playLines,
);

class HistoryLinesState extends queue_fixture.QueueState {
  HistoryLinesState({required super.paths, required super.log});

  bool hydrationEnabled = true;
  List<VodPlayLine>? lines = historyLines;
  Map<String, SwapLineRoute> routes = const {};
  Completer<List<VodPlayLine>?>? pendingLines;
  final lineCalls =
      <({String siteKey, String vodId, String vodName, String sourceKey})>[];
  final guards = <bool Function()?>[];

  /// 解析调用实参：换集必须用**线路自己的**站点与 `vod_id`（目录记录不是父目录 id）。
  final resolves =
      <({String? target, String? flag, String? vodId, String? siteKey})>[];

  /// 跨源解析调用实参：原来源续播必须带上记录自己的 `sourceKey` 与路由身份。
  final forSource =
      <
        ({
          String sourceKey,
          String siteKey,
          String? vodId,
          String? flag,
          String? target,
        })
      >[];

  @override
  Future<PlaybackLines?> playLinesForRecord({
    required String siteKey,
    required String vodId,
    String vodName = '',
    String sourceKey = '',
    bool Function()? isCurrent,
  }) {
    lineCalls.add((
      siteKey: siteKey,
      vodId: vodId,
      vodName: vodName,
      sourceKey: sourceKey,
    ));
    guards.add(isCurrent);
    if (!hydrationEnabled) return Future.value(null);
    return pendingLines?.future.then(_wrap) ?? _wrap(lines);
  }

  Future<PlaybackLines?> _wrap(List<VodPlayLine>? value) async =>
      value == null ? null : PlaybackLines(lines: value, routes: routes);

  @override
  Future<PlaybackDecision?> resolvePlayback({
    required String episodeTarget,
    String? flag,
    String? vodId,
    Site? siteOverride,
    SiteService? serviceOverride,
    int? qualityIndex,
    bool Function()? isCurrent,
    String? preferredParseName,
  }) {
    resolves.add((
      target: episodeTarget,
      flag: flag,
      vodId: vodId,
      siteKey: siteOverride?.key,
    ));
    return super.resolvePlayback(
      episodeTarget: episodeTarget,
      flag: flag,
      vodId: vodId,
      siteOverride: siteOverride,
      serviceOverride: serviceOverride,
      qualityIndex: qualityIndex,
      isCurrent: isCurrent,
      preferredParseName: preferredParseName,
    );
  }

  @override
  Future<PlaybackDecision?> resolvePlaybackForSource({
    required String sourceKey,
    required String siteKey,
    required String episodeTarget,
    String? flag,
    String? vodId,
    int? qualityIndex,
    bool Function()? isCurrent,
    String? preferredParseName,
  }) {
    forSource.add((
      sourceKey: sourceKey,
      siteKey: siteKey,
      vodId: vodId,
      flag: flag,
      target: episodeTarget,
    ));
    return super.resolvePlaybackForSource(
      sourceKey: sourceKey,
      siteKey: siteKey,
      episodeTarget: episodeTarget,
      flag: flag,
      vodId: vodId,
      qualityIndex: qualityIndex,
      isCurrent: isCurrent,
      preferredParseName: preferredParseName,
    );
  }
}

typedef MountedHistory = ({
  HistoryLinesState state,
  queue_fixture.QueueMediaIO media,
  ValueNotifier<PlaybackRequest> requests,
});

Future<MountedHistory> mountHistory(
  WidgetTester tester, {
  PlaybackRequest? request,
  bool hydrationEnabled = true,
  List<VodPlayLine>? lines,
  Map<String, SwapLineRoute> routes = const {},
  Completer<List<VodPlayLine>?>? pendingLines,
  // 需要 `siteByKey` 真的解析出站点（路由解析断言走 `siteOverride`）时导入。
  String? config,
  GlobalKey? capture,
  queue_fixture.QueueFixture? queue,
  bool live = false,
  void Function(HistoryLinesState)? configureState,
  void Function(queue_fixture.QueueMediaIO)? onMedia,
}) async {
  final temp = Directory.systemTemp.createTempSync('webhtv-history-lines-');
  final state =
      HistoryLinesState(
          paths: AppPaths.resolve(
            overrides: {
              'config': '${temp.path}/config',
              'data': '${temp.path}/data',
              'cache': '${temp.path}/cache',
              'state': '${temp.path}/logs',
            },
          ),
          log: LogService(),
        )
        ..hydrationEnabled = hydrationEnabled
        ..lines = lines ?? historyLines
        ..routes = routes
        ..pendingLines = pendingLines;
  configureState?.call(state);
  addTearDown(() {
    state.dispose();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });
  await tester.runAsync(() async {
    await state.bootstrap();
    if (config != null) await state.importConfig(config);
    await state.setPlayerOptions(state.playerOptions.copyWith(autoNext: false));
  });
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  installMediaKitMocks(tester);
  installWindowManagerMocks(tester);
  queue_fixture.QueueMediaIO? media;
  final attached = <Player>{};
  var active = true;
  addTearDown(() => active = false);
  tester.binding.addPersistentFrameCallback((_) {
    if (!active || find.byType(Video).evaluate().isEmpty) return;
    final player = tester.widget<Video>(find.byType(Video)).controller.player;
    if (!attached.add(player)) return;
    final io = queue_fixture.QueueMediaIO(player.platform!);
    media ??= io;
    onMedia?.call(io);
    player.platform = io;
  });
  final requests = ValueNotifier(request ?? historyRequest());
  addTearDown(requests.dispose);
  LivePlaybackSession? liveSession;
  if (live) {
    final channel = LiveChannel(
      name: '直播频道',
      urls: ['https://live.test/stream'],
    );
    liveSession = LivePlaybackSession(
      state: state,
      source: LiveSource(name: '直播源', type: 0),
      playlist: LivePlaylist(
        sourceName: '直播源',
        groups: [
          LiveGroup(name: channel.group, channels: [channel]),
        ],
      ),
      channel: channel,
    );
    addTearDown(liveSession.dispose);
  }
  final theme = buildAppTheme(Brightness.dark);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: 'FixtureCJK'),
        appBarTheme: theme.appBarTheme.copyWith(
          titleTextStyle: theme.textTheme.titleMedium?.copyWith(
            fontFamily: 'FixtureCJK',
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            textStyle: const TextStyle(fontFamily: 'FixtureCJK'),
          ),
        ),
      ),
      builder: (_, child) => RepaintBoundary(key: capture, child: child!),
      home: ValueListenableBuilder<PlaybackRequest>(
        valueListenable: requests,
        builder: (_, value, _) => PlayerPage(
          state: state,
          request: value,
          queue: queue,
          queueItemKey: queue?.snapshot.items.firstOrNull?.key,
          liveSession: liveSession,
        ),
      ),
    ),
  );
  await settleHistory(tester);
  expect(tester.takeException(), isNull);
  return (state: state, media: media!, requests: requests);
}

Future<void> settleHistory(WidgetTester tester) =>
    queue_fixture.settleQueue(tester);

Future<void> closeHistory(WidgetTester tester) =>
    queue_fixture.closeQueue(tester);

Future<PlayerEpisodePanel> openHistoryEpisodes(WidgetTester tester) async {
  await tester.tap(find.textContaining('选集（').first);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  expect(find.byKey(const ValueKey('player-episode-panel')), findsOneWidget);
  return tester.widget<PlayerEpisodePanel>(find.byType(PlayerEpisodePanel));
}

Map<String, Object?> _recordConfig(String side) => {
  'name': '$side 配置',
  'headers': [
    {
      'host': 'site.test',
      'header': {'Authorization': '$side-secret'},
    },
  ],
  'sites': [
    {
      'key': 'history-site',
      'name': '站点',
      'type': 1,
      'api': 'https://site.test/$side',
    },
  ],
};

http.Response _detailResponse({bool empty = false}) => http.Response(
  jsonEncode({
    'list': empty
        ? []
        : [
            {
              // 缺身份的单条详情必须用 VodIdentityHint 补齐，不能被当成无效条目丢掉。
              'vod_play_from': '详情线路',
              'vod_play_url': r'第1集$detail-1#第2集$detail-2',
            },
          ],
  }),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// 网盘聚合目录条目的 `vod_id`（真机记录：`atvp_detail:131957`）。
const folderVodId = 'atvp_detail:131957';

http.Response _jsonResponse(Map<String, Object?> body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// 目录展开的两条提供方线路：`丫仙女` 单线路，`夸克` 自带两条线路。
Future<http.Response> _folderRespond(http.Request request) async {
  final query = request.url.queryParameters;
  if (query['t'] == folderVodId) {
    return _jsonResponse({
      'list': [
        {'vod_id': 'hxq-1', 'vod_name': '丫仙女', 'vod_tag': 'folder'},
        {'vod_id': 'hxq-2', 'vod_name': '夸克', 'vod_tag': 'folder'},
      ],
    });
  }
  if (query['ids'] == 'hxq-1') {
    return _jsonResponse({
      'list': [
        {
          'vod_id': 'hxq-1',
          'vod_name': '丫仙女',
          'vod_play_from': '丫仙女',
          'vod_play_url': r'01(696.02 MB)$1@20465#02(1.2 GB)$1@20466',
        },
      ],
    });
  }
  if (query['ids'] == 'hxq-2') {
    return _jsonResponse({
      'list': [
        {
          'vod_id': 'hxq-2',
          'vod_name': '夸克',
          'vod_play_from': r'夸克$$$夸克原画',
          'vod_play_url': r'01(696.02 MB)$9@30001#02(1.2 GB)$9@30002$$$01(696.02 MB)$9@40001',
        },
      ],
    });
  }
  return _jsonResponse({'list': []});
}

/// 播放器夹具需要 `siteByKey` 真能解析出路由指向的站点。
Map<String, Object?> _bridgeSitesConfig() => {
  'name': '桥接配置',
  'sites': [
    {
      'key': 'history-site',
      'name': '站点',
      'type': 1,
      'api': 'https://site.test/active',
    },
    {
      'key': 'bridge-site',
      'name': '桥接站',
      'type': 1,
      'api': 'https://site.test/bridge',
    },
  ],
};

Future<AppState> _mountRecordState(
  WidgetTester tester,
  Future<http.Response> Function(http.Request) respond,
) async {
  final temp = Directory.systemTemp.createTempSync('webhtv-record-detail-');
  final state = AppState(
    paths: AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/config',
        'data': '${temp.path}/data',
        'cache': '${temp.path}/cache',
        'state': '${temp.path}/logs',
      },
    ),
    log: LogService(),
    httpClient: MockClient(respond),
  );
  addTearDown(() {
    state.dispose();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });
  await tester.runAsync(() async {
    await state.bootstrap();
    await state.importConfig(jsonEncode(_recordConfig('active')));
  });
  return state;
}

void main() {
  tearDown(dismissAllToasts);

  testWidgets('外部请求 A→B→同一 A 对象：旧详情不能抢先填满新会话', (tester) async {
    final oldA = Completer<List<VodPlayLine>?>();
    final b = Completer<List<VodPlayLine>?>();
    final freshA = Completer<List<VodPlayLine>?>();
    final mounted = await mountHistory(tester, pendingLines: oldA);
    final original = mounted.requests.value;
    mounted.state.pendingLines = b;
    mounted.requests.value = historyRequest(
      vodId: 'b-vod',
      target: 'alt-target-2',
    );
    await settleHistory(tester);
    mounted.state.pendingLines = freshA;
    mounted.requests.value = original;
    await settleHistory(tester);
    expect(mounted.state.lineCalls, hasLength(3));
    expect(mounted.state.guards.first!(), isFalse);
    oldA.complete(historyLines);
    b.complete(historyLines);
    await settleHistory(tester);
    expect(find.textContaining('选集（'), findsNothing);
    freshA.complete([
      VodPlayLine(
        flag: '线路一',
        sourceFlag: 'fresh-a',
        episodes: [
          ...historyLines.first.episodes,
          VodEpisode(name: '第4集 最新详情', url: 'target-4'),
        ],
      ),
    ]);
    await settleHistory(tester);
    expect(find.text('选集（4）'), findsOneWidget);
    await closeHistory(tester);
  });

  testWidgets('补齐后上一集下一集与切线路：解析仍用原来源和剧集入口', (tester) async {
    final mounted = await mountHistory(tester);
    await tester.tap(find.byTooltip('上一集（[）'));
    await settleHistory(tester);
    expect(mounted.state.targets.last.target, 'target-1');
    expect(mounted.state.targets.last.flag, 'backend-a');
    expect(mounted.state.targets.last.source, 'original-config');
    await tester.tap(find.byTooltip('下一集（]）'));
    await settleHistory(tester);
    expect(mounted.state.targets.last.target, 'target-2');
    expect(mounted.state.targets.last.flag, 'backend-a');
    await openHistoryEpisodes(tester);
    final resolveCount = mounted.state.targets.length;
    final openCount = mounted.media.opened.length;
    await tester.tap(find.byKey(const ValueKey('player-episode-line-1')));
    await settleHistory(tester);
    expect(find.byKey(const ValueKey('player-episode-panel')), findsOneWidget);
    expect(mounted.state.targets, hasLength(resolveCount));
    expect(mounted.media.opened, hasLength(openCount));
    expect(find.textContaining('线路二 · 共 2 集'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('player-episode-card-0')),
        matching: find.text('第1集 另一段旅程'),
      ),
      findsOneWidget,
    );
    final secondEpisode = find.byKey(const ValueKey('player-episode-card-1'));
    expect(
      find.descendant(of: secondEpisode, matching: find.text('第2集 再次相遇')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('player-episode-card-2')), findsNothing);
    await tester.tap(secondEpisode);
    await settleHistory(tester);
    expect(find.byKey(const ValueKey('player-episode-panel')), findsNothing);
    expect(mounted.state.targets, hasLength(resolveCount + 1));
    expect(mounted.state.targets.last.target, 'alt-target-2');
    expect(mounted.state.targets.last.flag, 'backend-b');
    expect(mounted.state.targets.last.source, 'original-config');
    expect(mounted.state.forSource.last, (
      sourceKey: 'original-config',
      siteKey: 'history-site',
      vodId: 'history-vod',
      flag: 'backend-b',
      target: 'alt-target-2',
    ));
    expect(mounted.media.opened, hasLength(openCount + 1));
    expect(
      mounted.media.opened.last.uri,
      'https://proxy.test/alt-target-2/q0.m3u8',
    );
    expect(mounted.state.lineCalls, hasLength(1));
    await closeHistory(tester);
  });

  for (final change in ['换片', '换集']) {
    testWidgets('旧媒体失败迟到后$change：不把旧线路和下标合并进新请求', (tester) async {
      final oldOpen = Completer<void>();
      final mounted = await mountHistory(
        tester,
        onMedia: (media) {
          media.nextOpen = oldOpen;
          media.failOpen = true;
        },
      );
      final newLines = [
        VodPlayLine(
          flag: '新线路',
          sourceFlag: 'new-backend',
          episodes: [VodEpisode(name: '新集', url: 'new-target')],
        ),
      ];
      mounted.state.lines = newLines;
      mounted.media.failOpen = false;
      mounted.requests.value = historyRequest(
        vodId: change == '换片' ? 'new-vod' : 'history-vod',
        target: 'new-target',
        episodeName: '新集',
        flag: '新线路',
      );
      await settleHistory(tester);
      expect(find.text('选集（1）'), findsOneWidget);
      mounted.media.failOpen = true;
      oldOpen.complete();
      await settleHistory(tester);
      expect(find.text('重试本集'), findsNothing);
      final panel = await openHistoryEpisodes(tester);
      expect(panel.lineFlag, '新线路');
      expect(panel.episodeIndex, 0);
      expect(panel.playLines, same(newLines));
      mounted.media.progress(120);
      await tester.pump(const Duration(seconds: 5));
      expect(mounted.state.writes.last.target, 'new-target');
      expect(
        mounted.state.writes.last.vodId,
        change == '换片' ? 'new-vod' : 'history-vod',
      );
      expect(mounted.state.lineCalls, hasLength(2));
      await closeHistory(tester);
    });
  }

  testWidgets('详情等待期间已起播：首帧不阻塞，重复重建只请求一次', (tester) async {
    final gate = Completer<List<VodPlayLine>?>();
    final mounted = await mountHistory(tester, pendingLines: gate);
    expect(mounted.media.opened, hasLength(1));
    expect(mounted.media.state.playing, isTrue);
    expect(find.textContaining('选集（'), findsNothing);
    mounted.media.progress(120);
    await settleHistory(tester);
    expect(mounted.state.lineCalls, hasLength(1));
    gate.complete(historyLines);
    await settleHistory(tester);
    expect(find.text('选集（3）'), findsOneWidget);
    expect(mounted.media.opened, hasLength(1));
    expect(mounted.media.state.position, const Duration(seconds: 120));
    await closeHistory(tester);
  });

  testWidgets('详情等待期间起播清理种子：同集 copyWith 后仍补齐', (tester) async {
    final gate = Completer<List<VodPlayLine>?>();
    final mounted = await mountHistory(
      tester,
      pendingLines: gate,
      request: historyRequest().copyWith(
        startPosition: Duration.zero,
        resumeSeed: const ResumeSeed(
          flag: '线路一',
          episodeId: 'target-2',
          episodeName: '第2集 月下重逢',
          positionMs: 0,
          durationMs: 1000000,
        ),
      ),
    );
    expect(mounted.media.state.playing, isTrue);
    expect(mounted.state.guards.single!(), isTrue);
    gate.complete(historyLines);
    await settleHistory(tester);
    expect(find.text('选集（3）'), findsOneWidget);
    expect(mounted.state.lineCalls, hasLength(1));
    await closeHistory(tester);
  });

  testWidgets('详情等待期间同集重试：加载代次改变不能误丢详情', (tester) async {
    final gate = Completer<List<VodPlayLine>?>();
    final mounted = await mountHistory(
      tester,
      pendingLines: gate,
      onMedia: (media) => media.failOpen = true,
    );
    expect(find.text('重试本集'), findsOneWidget);
    mounted.media.failOpen = false;
    await tester.tap(find.text('重试本集'));
    await settleHistory(tester);
    expect(mounted.media.state.playing, isTrue);
    expect(mounted.media.opened, hasLength(2));
    gate.complete(historyLines);
    await settleHistory(tester);
    expect(find.text('选集（3）'), findsOneWidget);
    expect(mounted.state.lineCalls, hasLength(1));
    await closeHistory(tester);
  });

  testWidgets('详情先于起播失败完成：失败回滚不得丢掉已补线路', (tester) async {
    final open = Completer<void>();
    final mounted = await mountHistory(
      tester,
      onMedia: (media) {
        media.nextOpen = open;
        media.failOpen = true;
      },
    );
    expect(find.text('选集（3）'), findsOneWidget);
    open.complete();
    await settleHistory(tester);
    expect(find.text('重试本集'), findsOneWidget);
    expect(find.text('选集（3）'), findsOneWidget);
    mounted.media.failOpen = false;
    await tester.tap(find.text('重试本集'));
    await settleHistory(tester);
    expect(find.text('选集（3）'), findsOneWidget);
    expect(mounted.state.lineCalls, hasLength(1));
    await closeHistory(tester);
  });

  testWidgets('详情等待期间切画质：合并到当前请求，不覆盖新画质及进度', (tester) async {
    final gate = Completer<List<VodPlayLine>?>();
    final mounted = await mountHistory(
      tester,
      pendingLines: gate,
      request: historyRequest().copyWith(
        qualities: const [
          PlaybackQuality(name: '高清', url: 'https://candidate.test/0'),
          PlaybackQuality(name: '原画', url: 'https://candidate.test/1'),
        ],
      ),
    );
    mounted.media.progress(120);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('player-quality-button')));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.byKey(playerQualityOptionKey(1)));
    await settleHistory(tester);
    expect(find.text('画质：原画'), findsOneWidget);
    expect(mounted.media.state.position, const Duration(seconds: 120));
    gate.complete(historyLines);
    await settleHistory(tester);
    expect(find.text('选集（3）'), findsOneWidget);
    expect(find.text('画质：原画'), findsOneWidget);
    expect(mounted.media.state.position, const Duration(seconds: 120));
    expect(
      mounted.media.opened.last.uri,
      'https://proxy.test/target-2/q1.m3u8',
    );
    expect(mounted.state.lineCalls, hasLength(1));
    await closeHistory(tester);
  });

  testWidgets('外部换片后旧详情迟到：只采纳新请求自己的线路', (tester) async {
    final old = Completer<List<VodPlayLine>?>();
    final next = Completer<List<VodPlayLine>?>();
    final mounted = await mountHistory(tester, pendingLines: old);
    mounted.state.pendingLines = next;
    mounted.requests.value = historyRequest(
      vodId: 'next-vod',
      target: 'alt-target-2',
      episodeName: '第2集 再次相遇',
      flag: '过期线路',
    );
    await settleHistory(tester);
    expect(mounted.state.lineCalls.map((call) => call.vodId), [
      'history-vod',
      'next-vod',
    ]);
    expect(mounted.state.guards.first!(), isFalse);
    old.complete(historyLines);
    await settleHistory(tester);
    expect(find.textContaining('选集（'), findsNothing);
    next.complete(historyLines);
    await settleHistory(tester);
    expect(find.text('选集（2）'), findsOneWidget);
    final panel = await openHistoryEpisodes(tester);
    expect(panel.lineFlag, '线路二');
    await closeHistory(tester);
  });

  testWidgets('同一作品外部换集后旧详情迟到：不得把新集标回旧集', (tester) async {
    final old = Completer<List<VodPlayLine>?>();
    final next = Completer<List<VodPlayLine>?>();
    final mounted = await mountHistory(tester, pendingLines: old);
    mounted.state.pendingLines = next;
    mounted.requests.value = historyRequest(
      target: 'target-3',
      episodeName: '第3集 远方来信',
    );
    await settleHistory(tester);
    old.complete(historyLines);
    await settleHistory(tester);
    expect(find.textContaining('选集（'), findsNothing);
    next.complete(historyLines);
    await settleHistory(tester);
    final panel = await openHistoryEpisodes(tester);
    expect(panel.episodeIndex, 2);
    await closeHistory(tester);
  });

  testWidgets('离页后详情迟到：丢弃结果，不异常或 toast', (tester) async {
    final gate = Completer<List<VodPlayLine>?>();
    final mounted = await mountHistory(tester, pendingLines: gate);
    await closeHistory(tester);
    expect(mounted.state.guards.single!(), isFalse);
    gate.complete(historyLines);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(toastCenter.toasts, isEmpty);
  });

  testWidgets('跨线路重复入口且历史 flag 过期：歧义不采纳', (tester) async {
    final duplicate = [
      VodPlayLine(
        flag: 'A',
        episodes: [VodEpisode(name: '一', url: 'duplicate')],
      ),
      VodPlayLine(
        flag: 'B',
        episodes: [VodEpisode(name: '二', url: 'duplicate')],
      ),
    ];
    final mounted = await mountHistory(
      tester,
      lines: duplicate,
      request: historyRequest(
        flag: '旧线路',
        target: 'duplicate',
        episodeName: '旧名字',
      ),
    );
    expect(mounted.state.lineCalls, hasLength(1));
    expect(find.textContaining('选集（'), findsNothing);
    expect(toastCenter.toasts, isEmpty);
    await closeHistory(tester);
  });

  for (final noLines in [null, <VodPlayLine>[]]) {
    testWidgets('详情返回 ${noLines == null ? 'null' : '空线路'}：静默降级且不重试', (
      tester,
    ) async {
      final mounted = await mountHistory(
        tester,
        configureState: (state) => state.lines = noLines,
      );
      mounted.media.progress(120);
      await settleHistory(tester);
      expect(mounted.state.lineCalls, hasLength(1));
      expect(find.textContaining('选集（'), findsNothing);
      expect(tester.takeException(), isNull);
      expect(toastCenter.toasts, isEmpty);
      await closeHistory(tester);
    });
  }

  for (final scenario in [
    '直播',
    '目录队列',
    'siteKey 空',
    'siteKey 空白',
    'vodId 空',
    'vodId 空白',
    '已有线路',
  ]) {
    testWidgets('$scenario：不发起线路补齐调用', (tester) async {
      final mounted = await mountHistory(
        tester,
        live: scenario == '直播',
        queue: scenario == '目录队列' ? queue_fixture.QueueFixture() : null,
        request: historyRequest(
          siteKey: scenario == 'siteKey 空'
              ? ''
              : scenario == 'siteKey 空白'
              ? '  '
              : 'history-site',
          vodId: scenario == 'vodId 空'
              ? ''
              : scenario == 'vodId 空白'
              ? '  '
              : 'history-vod',
          playLines: scenario == '已有线路' ? historyLines : const [],
        ),
      );
      mounted.media.progress(120);
      await settleHistory(tester);
      expect(mounted.state.lineCalls, isEmpty);
      await closeHistory(tester);
    });
  }

  testWidgets('已有线路：面板字段不被覆盖，进度仍写原 episodeTarget', (tester) async {
    final mounted = await mountHistory(
      tester,
      request:
          historyRequest(
            flag: '线路二',
            target: 'alt-target-2',
            episodeName: '原始集名',
            playLines: historyLines,
          ).copyWith(
            episodeIndex: 1,
            headers: {'Referer': 'https://origin.test/keep'},
            qualities: const [
              PlaybackQuality(
                name: '原高清',
                url: 'https://candidate.test/keep-0',
              ),
              PlaybackQuality(
                name: '原原画',
                url: 'https://candidate.test/keep-1',
              ),
            ],
            qualityIndex: 1,
          ),
    );
    expect(mounted.state.lineCalls, isEmpty);
    expect(find.text('画质：原原画'), findsOneWidget);
    expect(mounted.media.opened.single.httpHeaders, {
      'Referer': 'https://origin.test/keep',
    });
    final panel = await openHistoryEpisodes(tester);
    expect(panel.lineFlag, '线路二');
    expect(panel.episodeIndex, 1);
    expect(panel.playLines, same(historyLines));
    mounted.media.progress(120);
    await tester.pump(const Duration(seconds: 5));
    expect(mounted.state.writes.last.target, 'alt-target-2');
    expect(mounted.state.writes.last.source, 'original-config');
    expect(mounted.state.writes.last.position, 120000);
    await closeHistory(tester);
  });

  testWidgets('补齐只改线路定位：保留旧集名和入口，进度不写解析后 URL', (tester) async {
    final mounted = await mountHistory(
      tester,
      request: historyRequest(
        flag: '旧线路',
        target: 'alt-target-2',
        episodeName: '原始历史集名',
      ),
    );
    expect(find.text('星空旅程 · 原始历史集名'), findsOneWidget);
    mounted.media.progress(120);
    await tester.pump(const Duration(seconds: 5));
    expect(mounted.state.writes.last.target, 'alt-target-2');
    expect(mounted.state.writes.last.source, 'original-config');
    await closeHistory(tester);
  });

  testWidgets('当前源只读线路：身份提示补齐缺字段，不写详情或切站', (tester) async {
    final calls = <http.Request>[];
    final state = await _mountRecordState(tester, (request) async {
      if (request.url.queryParameters['ids'] != null) {
        calls.add(request);
        return _detailResponse();
      }
      return http.Response('{"list":[]}', 200);
    });
    final selected = state.selectedSite;
    final active = state.activeSourceKey;
    final detail = state.detailResult;
    await tester.runAsync(() async {
      final result = await state.playLinesForRecord(
        siteKey: 'history-site',
        vodId: 'record-id',
        vodName: '历史剧名',
      );
      final lines = result!.lines;
      expect(lines, hasLength(1));
      expect(lines.single.flag, '详情线路');
      expect(lines.single.episodes.map((episode) => episode.url), [
        'detail-1',
        'detail-2',
      ]);
      // 普通记录没有额外路由：换集继续用记录自己的 siteKey/vodId。
      expect(result.routes, isEmpty);
    });
    expect(calls, hasLength(1));
    expect(calls.single.url.path, '/active');
    expect(calls.single.url.queryParameters['ids'], 'record-id');
    expect(state.selectedSite, same(selected));
    expect(state.activeSourceKey, active);
    expect(state.detailResult, same(detail));
  });

  testWidgets('原来源只读线路：同名 siteKey 用原配置 API/Header，不切生效源', (tester) async {
    final calls = <http.Request>[];
    final state = await _mountRecordState(tester, (request) async {
      if (request.url.queryParameters['ids'] != null) {
        calls.add(request);
        return _detailResponse();
      }
      return http.Response('{"list":[]}', 200);
    });
    final sourceKey = LocalSourceKey.of(
      'https://site.test/original-config.json',
    );
    state.database!.saveConfig(
      name: '原配置',
      origin: 'https://site.test/original-config.json',
      json: _recordConfig('original'),
      makeActive: false,
      sourceKey: sourceKey,
    );
    final selected = state.selectedSite;
    final active = state.activeSourceKey;
    await tester.runAsync(() async {
      final result = await state.playLinesForRecord(
        siteKey: 'history-site',
        vodId: 'record-id',
        vodName: '历史剧名',
        sourceKey: sourceKey,
      );
      expect(result!.lines, hasLength(1));
      expect(result.routes, isEmpty);
    });
    expect(calls, hasLength(1));
    expect(calls.single.url.path, '/original');
    expect(calls.single.headers['Authorization'], 'original-secret');
    expect(state.selectedSite, same(selected));
    expect(state.activeSourceKey, active);
    expect(state.detailResult, isNull);
  });

  testWidgets('原来源或站点不存在：返回 null，不回退请求当前源', (tester) async {
    var detailCalls = 0;
    final state = await _mountRecordState(tester, (request) async {
      if (request.url.queryParameters['ids'] != null) detailCalls++;
      return http.Response('{"list":[]}', 200);
    });
    await tester.runAsync(() async {
      expect(
        await state.playLinesForRecord(
          siteKey: 'history-site',
          vodId: 'record-id',
          sourceKey: 'missing-config',
        ),
        isNull,
      );
      expect(
        await state.playLinesForRecord(
          siteKey: 'missing-site',
          vodId: 'record-id',
        ),
        isNull,
      );
    });
    expect(detailCalls, 0);
    final withoutService = AppState(log: LogService());
    addTearDown(withoutService.dispose);
    expect(
      await withoutService.playLinesForRecord(
        siteKey: 'history-site',
        vodId: 'record-id',
      ),
      isNull,
    );
  });

  testWidgets('只读详情响应列表为空：返回 null', (tester) async {
    final state = await _mountRecordState(
      tester,
      (_) async => _detailResponse(empty: true),
    );
    await tester.runAsync(() async {
      expect(
        await state.playLinesForRecord(
          siteKey: 'history-site',
          vodId: 'record-id',
        ),
        isNull,
      );
    });
  });

  testWidgets('只读详情过期：等待前不发请求，等待后丢弃响应', (tester) async {
    late Completer<http.Response> response;
    var details = 0;
    final state = await _mountRecordState(tester, (request) async {
      if (request.url.queryParameters['ids'] != null) {
        details++;
        return response.future;
      }
      return http.Response('{"list":[]}', 200);
    });
    await tester.runAsync(() async {
      // 真实 I/O 区里创建门闩：假时钟区的 Future 不能在 runAsync 里等待其微任务。
      response = Completer<http.Response>();
      expect(
        await state.playLinesForRecord(
          siteKey: 'history-site',
          vodId: 'record-id',
          isCurrent: () => false,
        ),
        isNull,
      );
      expect(details, 0);
      var current = true;
      final pending = state.playLinesForRecord(
        siteKey: 'history-site',
        vodId: 'record-id',
        vodName: '历史剧名',
        isCurrent: () => current,
      );
      await Future<void>.delayed(Duration.zero);
      expect(details, 1);
      current = false;
      response.complete(_detailResponse());
      expect(await pending, isNull);
    });
  });

  testWidgets('只读详情异常：返回 null、只记脱敏 warning，无全局错误或 toast', (tester) async {
    final state = await _mountRecordState(tester, (request) async {
      if (request.url.queryParameters['ids'] != null) {
        throw StateError(
          'https://site.test/private?token=secret Header: Authorization=secret',
        );
      }
      return http.Response('{"list":[]}', 200);
    });
    final error = state.lastError;
    await tester.runAsync(() async {
      expect(
        await state.playLinesForRecord(
          siteKey: 'history-site',
          vodId: 'record-id',
        ),
        isNull,
      );
    });
    final warning = state.log.entries
        .where(
          (entry) => entry.scope == 'player' && entry.level == LogLevel.warning,
        )
        .single;
    expect(warning.message, contains('record-id'));
    expect(warning.message, isNot(contains('https://site.test')));
    expect(warning.message, isNot(contains('Authorization')));
    expect(warning.message, isNot(contains('secret')));
    expect(state.lastError, same(error));
    expect(state.detailError, isNull);
    expect(toastCenter.toasts, isEmpty);
  });

  testWidgets('历史无线路：补齐后出现选集并标记原入口目标', (tester) async {
    final mounted = await mountHistory(tester);
    expect(find.text('选集（3）'), findsOneWidget);
    expect(mounted.state.lineCalls, [
      (
        siteKey: 'history-site',
        vodId: 'history-vod',
        vodName: '星空旅程',
        sourceKey: 'original-config',
      ),
    ]);
    final panel = await openHistoryEpisodes(tester);
    expect(panel.lineFlag, '线路一');
    expect(panel.episodeIndex, 1);
    expect(panel.episodes.map((episode) => episode.name), [
      '第1集 星空初遇',
      '第2集 月下重逢',
      '第3集 远方来信',
    ]);
    final currentCard = tester.widget<Container>(
      find.byKey(const ValueKey('player-episode-card-1')),
    );
    final otherCard = tester.widget<Container>(
      find.byKey(const ValueKey('player-episode-card-0')),
    );
    final scheme = Theme.of(tester.element(find.byType(PlayerEpisodePanel)))
        .colorScheme;
    expect(
      (currentCard.decoration as BoxDecoration).color,
      scheme.primaryContainer,
    );
    expect(
      (otherCard.decoration as BoxDecoration).color,
      scheme.surfaceContainerHigh,
    );
    expect((currentCard.decoration as BoxDecoration).border, isNull);
    expect((otherCard.decoration as BoxDecoration).border, isNull);
    await closeHistory(tester);
  });

  testWidgets('历史 flag 过期：唯一入口目标定位到另一条线路', (tester) async {
    await mountHistory(
      tester,
      request: historyRequest(
        flag: '已经删除的线路',
        target: 'alt-target-2',
        episodeName: '旧集名',
      ),
    );
    expect(find.text('选集（2）'), findsOneWidget);
    final panel = await openHistoryEpisodes(tester);
    expect(panel.lineFlag, '线路二');
    expect(panel.lineLabel, '线路二');
    expect(panel.episodeIndex, 1);
    expect(panel.episodes.map((episode) => episode.url), [
      'alt-target-1',
      'alt-target-2',
    ]);
    await closeHistory(tester);
  });

  testWidgets('历史入口与集名都无法命中：不猜集、不显示按钮或 toast', (tester) async {
    final mounted = await mountHistory(
      tester,
      request: historyRequest(target: 'removed-target', episodeName: '已删除的集'),
    );
    expect(mounted.state.lineCalls, hasLength(1));
    expect(find.textContaining('选集（'), findsNothing);
    expect(tester.takeException(), isNull);
    expect(toastCenter.toasts, isEmpty);
    await closeHistory(tester);
  });

  testWidgets('目录记录：线路与 folderDetail 一致，播放器出现选集并高亮当前文件', (tester) async {
    final state = await _mountRecordState(tester, _folderRespond);
    final site = state.siteByKey('history-site')!;
    late PlaybackLines adopted;
    late List<VodPlayLine> detailLines;
    await tester.runAsync(() async {
      // 详情页走的就是这条：目录 id 走 `t=` 展开，而不是 `ids=`。
      final folder = await state.siteService!.folderDetail(
        site,
        Vod(vodId: folderVodId, vodName: '目录'),
      );
      detailLines = state.playLinesOf(folder.value.list.single);
      adopted = (await state.playLinesForRecord(
        siteKey: 'history-site',
        vodId: folderVodId,
        vodName: '目录',
      ))!;
    });
    // 1) 线路名 / 分集数量 / 集入口都与详情页逐项一致。
    expect(
      adopted.lines.map((line) => line.flag),
      detailLines.map((line) => line.flag),
    );
    expect(
      adopted.lines.map((line) => line.episodes.length),
      detailLines.map((line) => line.episodes.length),
    );
    expect(
      adopted.lines.map((line) => line.episodes.map((episode) => episode.url)),
      detailLines.map((line) => line.episodes.map((episode) => episode.url)),
    );
    expect(adopted.lines.map((line) => line.flag), [
      '丫仙女',
      'quark · 夸克',
      'quark · 夸克原画',
    ]);
    // 2) 每条线路带回**条目自己**的 vod_id，父目录 id 一个都不能留。
    expect(adopted.routes.map((key, route) => MapEntry(key, route.vodId)), {
      '丫仙女': 'hxq-1',
      'quark · 夸克': 'hxq-2',
      'quark · 夸克原画': 'hxq-2',
    });
    expect(adopted.routes['丫仙女']!.siteKey, 'history-site');
    expect(
      adopted.routes.values.map((route) => route.vodId),
      isNot(contains(folderVodId)),
    );

    // 3) 播放器采纳同一份线路：按钮、面板线路名与分集、当前文件高亮。
    final mounted = await mountHistory(
      tester,
      lines: adopted.lines,
      routes: adopted.routes,
      request: historyRequest(
        vodId: folderVodId,
        flag: '丫仙女',
        target: '1@20465',
        episodeName: '01(696.02 MB)',
        sourceKey: '',
        playLines: adopted.lines,
      ),
    );
    expect(find.text('选集（2）'), findsOneWidget);
    // 已带线路的请求不再补一次：目录展开可能几十条 detail 请求。
    expect(mounted.state.lineCalls, isEmpty);
    final panel = await openHistoryEpisodes(tester);
    expect(panel.lineFlag, '丫仙女');
    expect(panel.episodes.map((episode) => episode.name), [
      '01(696.02 MB)',
      '02(1.2 GB)',
    ]);
    expect(panel.playLines.map((line) => line.flag), [
      '丫仙女',
      'quark · 夸克',
      'quark · 夸克原画',
    ]);
    final card = tester.widget<Container>(
      find.byKey(const ValueKey('player-episode-card-0')),
    );
    expect(
      (card.decoration as BoxDecoration).color,
      Theme.of(tester.element(find.byType(PlayerEpisodePanel)))
          .colorScheme
          .primaryContainer,
      reason: '当前目录文件仍以选中底色标识',
    );
    expect((card.decoration as BoxDecoration).border, isNull);
    await closeHistory(tester);
  });

  testWidgets('目录线路换集：解析用该条目自己的站点与 vodId，不是父目录 id', (tester) async {
    final mounted = await mountHistory(
      tester,
      config: jsonEncode(_bridgeSitesConfig()),
      lines: folderLines,
      routes: folderRoutes,
      request: historyRequest(
        vodId: folderVodId,
        flag: '丫仙女',
        target: '1@20465',
        episodeName: '01(696.02 MB)',
        sourceKey: '',
      ),
    );
    expect(find.text('选集（2）'), findsOneWidget);
    await tester.tap(find.byTooltip('下一集（]）'));
    await settleHistory(tester);
    expect(mounted.state.resolves.last.target, '1@20466');
    expect(mounted.state.resolves.last.vodId, 'hxq-1');
    expect(mounted.state.resolves.last.siteKey, 'bridge-site');
    expect(mounted.state.resolves.last.vodId, isNot(folderVodId));
    await closeHistory(tester);
  });

  testWidgets('跨源目录记录换集：走原配置解析并带路由身份，进度写回原来源', (tester) async {
    final mounted = await mountHistory(
      tester,
      config: jsonEncode(_bridgeSitesConfig()),
      lines: folderLines,
      routes: folderRoutes,
      request: historyRequest(
        vodId: folderVodId,
        flag: '丫仙女',
        target: '1@20465',
        episodeName: '01(696.02 MB)',
      ),
    );
    expect(mounted.state.resolves, isEmpty);
    await tester.tap(find.byTooltip('下一集（]）'));
    await settleHistory(tester);
    expect(mounted.state.forSource.last.sourceKey, 'original-config');
    expect(mounted.state.forSource.last.siteKey, 'bridge-site');
    expect(mounted.state.forSource.last.vodId, 'hxq-1');
    expect(mounted.state.forSource.last.target, '1@20466');
    // 没有退回当前配置的同名站点。
    expect(mounted.state.resolves, isEmpty);
    mounted.media.progress(120);
    await tester.pump(const Duration(seconds: 5));
    expect(mounted.state.writes.last.source, 'original-config');
    await closeHistory(tester);
  });

  testWidgets('普通记录不展开目录：只发 ids 详情请求且不带路由', (tester) async {
    final calls = <Uri>[];
    final state = await _mountRecordState(tester, (request) async {
      calls.add(request.url);
      return _detailResponse();
    });
    late PlaybackLines result;
    await tester.runAsync(() async {
      result = (await state.playLinesForRecord(
        siteKey: 'history-site',
        vodId: 'record-id',
        vodName: '历史剧名',
      ))!;
    });
    expect(result.lines.single.flag, '详情线路');
    expect(result.routes, isEmpty);
    // 目录展开（`t=`）一次都不能发：普通记录只有一次 `ids=` 详情。
    expect(calls.map((url) => url.queryParameters['t']), everyElement(isNull));
    expect(
      calls.where((url) => url.queryParameters['ids'] == 'record-id'),
      hasLength(1),
    );
  });

  testWidgets('补齐结果过期：留一条指出不一致字段的 debug，不采纳不弹 toast', (tester) async {
    final first = Completer<List<VodPlayLine>?>();
    final mounted = await mountHistory(tester, pendingLines: first);
    // 第二次补齐永不完成：只让**第一次**（已过期的那次）收口。
    final never = Completer<List<VodPlayLine>?>();
    mounted.state.pendingLines = never;
    mounted.requests.value = historyRequest(vodId: 'other-vod');
    await settleHistory(tester);
    expect(mounted.state.lineCalls, hasLength(2));
    first.complete(historyLines);
    await settleHistory(tester);
    // 不采纳：换片后那条请求始终没有线路，因此没有选集按钮。
    expect(find.textContaining('选集（'), findsNothing);
    expect(tester.takeException(), isNull);
    expect(toastCenter.toasts, isEmpty);
    final stale = mounted.state.log.entries.where(
      (entry) =>
          entry.scope == 'player' &&
          entry.level == LogLevel.debug &&
          entry.message.contains('补齐结果已过期'),
    );
    expect(stale, hasLength(1));
    // 要能看出是哪个字段不一致，否则「没补上」无从归因。
    expect(stale.single.message, contains('field=vodId'));
    await closeHistory(tester);
  });

  testWidgets('目录补齐被取消（siteCancelled）：留一条 debug、不返回线路、不弹 toast', (
    tester,
  ) async {
    var current = true;
    final state = await _mountRecordState(tester, (request) async {
      // 分类请求一回来就模拟「用户已离开」：目录展开随后的 checkCurrent 会抛
      // siteCancelled，走的正是补齐的取消出口。
      if (request.url.queryParameters['t'] == folderVodId) current = false;
      return _jsonResponse({
        'list': [
          {'vod_id': 'hxq-1', 'vod_name': '丫仙女', 'vod_tag': 'folder'},
        ],
      });
    });
    PlaybackLines? result;
    await tester.runAsync(() async {
      result = await state.playLinesForRecord(
        siteKey: 'history-site',
        vodId: folderVodId,
        vodName: '目录',
        isCurrent: () => current,
      );
    });
    // 取消不是失败：调用方拿到 null（= 不采纳），也不会弹错误。
    expect(result, isNull);
    final cancelled = state.log.entries.where(
      (entry) =>
          entry.scope == 'player' &&
          entry.level == LogLevel.debug &&
          entry.message.contains('siteCancelled'),
    );
    expect(cancelled, hasLength(1));
    expect(cancelled.single.message, contains(folderVodId));
    expect(toastCenter.toasts, isEmpty);
  });
}
