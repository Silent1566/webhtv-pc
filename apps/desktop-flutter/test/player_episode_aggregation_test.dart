// ignore_for_file: invalid_use_of_protected_member

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/history_view.dart';
import 'package:webhtv_pc/core/source_swap.dart';
import 'package:webhtv_pc/core/tmdb_playback.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/player_page.dart';

import 'support/player_page_harness.dart';

class _MediaIO extends PlatformPlayer {
  _MediaIO(this.original) : super(configuration: original.configuration) {
    stream = original.stream;
  }

  final PlatformPlayer original;
  final opened = <Media>[];
  final transport = <({String action, String url})>[];
  Completer<void>? pauseGate;

  @override
  Future<int> get handle => original.handle;

  void progress(int seconds, {bool completed = false}) {
    state = state.copyWith(
      position: Duration(seconds: seconds),
      duration: const Duration(seconds: 1000),
      playing: !completed,
      completed: completed,
    );
    original.durationController.add(state.duration);
    original.positionController.add(state.position);
    original.playingController.add(state.playing);
    original.completedController.add(completed);
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    final media = playable as Media;
    opened.add(media);
    progress(media.start?.inSeconds ?? 1);
  }

  @override
  Future<void> seek(Duration position) async => progress(position.inSeconds);

  @override
  Future<void> play() async {
    transport.add((action: 'play', url: opened.last.uri));
    state = state.copyWith(playing: true);
    original.playingController.add(true);
  }

  @override
  Future<void> pause() async {
    transport.add((action: 'pause', url: opened.last.uri));
    final pending = pauseGate;
    pauseGate = null;
    if (pending != null) await pending.future;
    state = state.copyWith(playing: false);
    original.playingController.add(false);
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}

  @override
  Future<void> dispose() async {
    unawaited(original.dispose());
    await super.dispose();
  }
}

class _ResolveState extends AppState {
  _ResolveState({required super.paths, required super.log});

  final resolved = <({String target, String? flag, String? vodId})>[];
  final externalSite = Site(
    key: 'external',
    name: '外部站点',
    type: 1,
    api: 'https://external.test/api',
  );
  final resolvedSites = <Site?>[];

  @override
  Site? siteByKey(String key) =>
      key == externalSite.key ? externalSite : super.siteByKey(key);

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
  }) async {
    resolved.add((target: episodeTarget, flag: flag, vodId: vodId));
    resolvedSites.add(siteOverride);
    return PlaybackDecision(action: PlaybackAction.direct, url: episodeTarget);
  }
}

List<VodEpisode> _versions() => [
  VodEpisode(name: 'S01E01.1080p[1GB]', url: 'https://fixture.test/1-low'),
  VodEpisode(name: 'S01E01.2160p[3GB]', url: 'https://fixture.test/1-high'),
  VodEpisode(name: 'S01E02.2160p[4GB]', url: 'https://fixture.test/2-high'),
  VodEpisode(name: 'S01E02.1080p[2GB]', url: 'https://fixture.test/2-low'),
  VodEpisode(name: 'S01E03.1080p[2GB]', url: 'https://fixture.test/3-low'),
];

Future<void> _settle(WidgetTester tester) async {
  await settlePlayerPage(tester, times: 2);
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

Future<({_ResolveState state, _MediaIO media, PlaybackRequest request})> _mount(
  WidgetTester tester, {
  List<VodEpisode>? episodes,
  int current = 0,
  TmdbPlaybackIdentity? tmdb,
  bool enabled = true,
  Duration? startPosition,
  ResumeSeed? resumeSeed,
  Map<String, SwapLineRoute> lineRoutes = const {},
}) async {
  final scratch = Directory('../../.local/episode-aggregation/player').absolute;
  scratch.createSync(recursive: true);
  final temp = scratch.createTempSync('fixture-');
  final state = _ResolveState(
    paths: AppPaths.resolve(
      overrides: {
        'config': temp.path,
        'data': temp.path,
        'cache': '${temp.path}/cache',
        'state': '${temp.path}/logs',
      },
    ),
    log: LogService(),
  );
  addTearDown(state.dispose);
  await tester.runAsync(() async {
    await state.bootstrap();
    await state.setEpisodeAggregateVersions(enabled);
  });
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  installMediaKitMocks(tester);
  installWindowManagerMocks(tester);
  _MediaIO? media;
  var active = true;
  addTearDown(() => active = false);
  tester.binding.addPersistentFrameCallback((_) {
    if (!active || media != null) return;
    final video = find.byType(Video);
    if (video.evaluate().isEmpty) return;
    final player = tester.widget<Video>(video).controller.player;
    media = _MediaIO(player.platform!);
    player.platform = media;
  });
  final line = episodes ?? _versions();
  final request = PlaybackRequest(
    url: line[current].url,
    title: '测试剧',
    siteKey: 'fixture',
    vodId: 'episode-aggregation',
    vodName: '测试剧',
    episodeName: line[current].name,
    episodeTarget: line[current].url,
    episodeIndex: current,
    flag: '展示线路',
    playbackFlag: '原始flag',
    startPosition: startPosition,
    resumeSeed: resumeSeed,
    lineRoutes: lineRoutes,
    tmdb: tmdb,
    playLines: [
      VodPlayLine(flag: '展示线路', sourceFlag: '原始flag', episodes: line),
    ],
  );
  await tester.pumpWidget(
    MaterialApp(
      home: PlayerPage(state: state, request: request),
    ),
  );
  await _settle(tester);
  expect(tester.takeException(), isNull);
  expect(media!.opened.single.uri, line[current].url);
  return (state: state, media: media!, request: request);
}

Future<void> _step(WidgetTester tester, {bool previous = false}) async {
  debugRevealPlayerControls(
    tester.state<State<PlayerPage>>(find.byType(PlayerPage)),
  );
  await tester.pump();
  await tester.tap(find.byTooltip(previous ? '上一集（[）' : '下一集（]）'));
  await _settle(tester);
}

void _testPlayer(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (tester) async {
    try {
      await body(tester);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
    }
  });
}

List<VodEpisode> _ambiguous() => [
  ..._versions().take(2),
  VodEpisode(name: 'S01E02.1080p[2GB]', url: 'https://fixture.test/2-a'),
  VodEpisode(name: 'S01E02.1080p[3GB]', url: 'https://fixture.test/2-b'),
];

Future<void> _finish(WidgetTester tester, _MediaIO media) async {
  media.progress(999);
  await tester.pump();
  media.progress(1000, completed: true);
  await _settle(tester);
}

void main() {
  _testPlayer(
    'next skips same-episode variants and preserves unique selected profile',
    (tester) async {
      final f = await _mount(tester);
      await _step(tester);
      expect(f.media.opened.map((m) => m.uri), [
        f.request.url,
        _versions()[3].url,
      ]);
      expect(f.state.resolved.single, (
        target: _versions()[3].url,
        flag: '原始flag',
        vodId: 'episode-aggregation',
      ));
      f.media.progress(120);
      await tester.pump(const Duration(seconds: 6));
      expect(f.state.recentHistory().first.episodeId, _versions()[3].url);
      await _step(tester);
      expect(f.media.opened.last.uri, _versions()[4].url);
    },
  );

  _testPlayer(
    'previous goes to the previous logical group with selected profile',
    (tester) async {
      final f = await _mount(tester, current: 3);
      await _step(tester, previous: true);
      expect(f.media.opened.last.uri, _versions()[0].url);
    },
  );

  _testPlayer('aggregation off preserves original adjacent resource behavior', (
    tester,
  ) async {
    final f = await _mount(tester, enabled: false);
    await _step(tester);
    expect(f.media.opened.last.uri, _versions()[1].url);
    await _step(tester, previous: true);
    expect(f.media.opened.last.uri, _versions()[0].url);
  });

  _testPlayer(
    'manual ambiguous next uses shared selector and preserves original selection URL',
    (tester) async {
      final f = await _mount(tester, episodes: _ambiguous());
      await _step(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(f.media.state.playing, isFalse);
      expect(f.media.transport, [(action: 'pause', url: f.request.url)]);
      expect(f.media.opened, hasLength(1));
      expect(f.state.resolved, isEmpty);
      await tester.tap(find.byKey(const ValueKey('episode-version-option-3')));
      await tester.tap(find.byKey(const ValueKey('episode-version-confirm')));
      await _settle(tester);
      expect(f.media.opened.last.uri, _ambiguous()[3].url);
      expect(f.state.resolved.single.flag, '原始flag');
      expect(f.media.transport, [(action: 'pause', url: f.request.url)]);
      expect(f.media.state.playing, isTrue);
    },
  );

  _testPlayer(
    'cancel selector leaves media and progress on the current concrete file',
    (tester) async {
      final f = await _mount(tester, episodes: _ambiguous());
      f.media.progress(120);
      await tester.pump();
      await _step(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(f.media.state.playing, isFalse);
      expect(f.media.transport, [(action: 'pause', url: f.request.url)]);
      await tester.tap(find.text('取消'));
      await _settle(tester);
      expect(f.media.opened, hasLength(1));
      expect(f.state.resolved, isEmpty);
      expect(f.media.state.playing, isTrue);
      expect(f.media.transport, [
        (action: 'pause', url: f.request.url),
        (action: 'play', url: f.request.url),
      ]);
      f.media.progress(150);
      await tester.pump(const Duration(seconds: 6));
      expect(f.state.recentHistory().single.episodeId, f.request.episodeTarget);
      expect(f.state.recentHistory().single.positionMs, 150000);
    },
  );

  _testPlayer('autoplay skips versions using the same unique profile path', (
    tester,
  ) async {
    final f = await _mount(tester);
    await _finish(tester, f.media);
    expect(f.media.opened.last.uri, _versions()[3].url);
    expect(f.state.recentHistory().single.episodeId, f.request.episodeTarget);
    expect(f.state.recentHistory().single.completed, isTrue);
  });

  _testPlayer(
    'autoplay ambiguous selection can cancel without opening or misattributing completed progress',
    (tester) async {
      final f = await _mount(tester, episodes: _ambiguous());
      await _finish(tester, f.media);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('取消'));
      await _settle(tester);
      await tester.pump(const Duration(seconds: 6));
      expect(f.media.opened, hasLength(1));
      expect(f.state.resolved, isEmpty);
      expect(f.media.transport, isEmpty);
      expect(f.media.state.playing, isFalse);
      expect(f.state.recentHistory().single.episodeId, f.request.episodeTarget);
      expect(f.state.recentHistory().single.completed, isTrue);
    },
  );

  _testPlayer(
    'explicit season boundary stops grouped next and previous without a TMDB identity',
    (tester) async {
      final episodes = [
        ..._versions().take(2),
        VodEpisode(name: 'S02E01.1080p', url: 'https://fixture.test/season2'),
      ];
      final f = await _mount(tester, episodes: episodes, current: 2);
      await _step(tester, previous: true);
      expect(f.media.opened, hasLength(1));
    },
  );

  _testPlayer(
    'explicit season boundary stops grouped manual and automatic next',
    (tester) async {
      final episodes = [
        ..._versions().take(2),
        VodEpisode(name: 'S02E01.1080p', url: 'https://fixture.test/season2'),
      ];
      final f = await _mount(tester, episodes: episodes);
      await _step(tester);
      expect(f.media.opened, hasLength(1));
      await _finish(tester, f.media);
      expect(f.media.opened, hasLength(1));
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  _testPlayer(
    'existing TMDB enriched season boundary still applies to adjacent logical group',
    (tester) async {
      final episodes = [
        ..._versions().take(2),
        for (final e in _versions().skip(2))
          VodEpisode(
            name: e.name,
            url: e.url,
            extra: {'tmdb_season_number': 2},
          ),
      ];
      final f = await _mount(
        tester,
        episodes: episodes,
        tmdb: const TmdbPlaybackIdentity(
          tmdbId: 1,
          mediaType: TmdbMediaType.tv,
          seasonNumber: 1,
        ),
      );
      await _step(tester);
      expect(f.media.opened, hasLength(1));
    },
  );

  _testPlayer(
    'selector is single-flight even when navigation is invoked again',
    (tester) async {
      final f = await _mount(tester, episodes: _ambiguous());
      final next = tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.skip_next))
          .onPressed!;
      next();
      next();
      await _settle(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('取消'));
      await _settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(f.media.opened, hasLength(1));
    },
  );

  _testPlayer(
    'stale line selection cannot open the previously selected candidate',
    (tester) async {
      final f = await _mount(tester, episodes: _ambiguous());
      await _step(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      final other = VodEpisode(
        name: 'S03E01.1080p',
        url: 'https://fixture.test/new-line',
      );
      final updated = f.request.copyWith(
        flag: '其他线路',
        episodeTarget: other.url,
        episodeName: other.name,
        url: other.url,
        playLines: [
          VodPlayLine(flag: '其他线路', episodes: [other]),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(state: f.state, request: updated),
        ),
      );
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('episode-version-confirm')));
      await _settle(tester);
      expect(f.state.resolved, isEmpty);
      expect(f.media.opened.map((m) => m.uri), [f.request.url, other.url]);
      expect(f.media.transport, [(action: 'pause', url: f.request.url)]);
    },
  );

  _testPlayer(
    'disabling aggregation during selection invalidates the pending candidate',
    (tester) async {
      final f = await _mount(tester, episodes: _ambiguous());
      await _step(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.runAsync(() => f.state.setEpisodeAggregateVersions(false));
      await tester.tap(find.byKey(const ValueKey('episode-version-confirm')));
      await _settle(tester);
      expect(f.media.opened, hasLength(1));
      expect(f.state.resolved, isEmpty);
      expect(f.media.state.playing, isTrue);
      expect(f.media.transport, [
        (action: 'pause', url: f.request.url),
        (action: 'play', url: f.request.url),
      ]);
      await _step(tester);
      expect(f.media.opened.last.uri, _versions()[1].url);
    },
  );

  _testPlayer(
    'unmount while selector is open never resolves a different episode',
    (tester) async {
      final f = await _mount(tester, episodes: _ambiguous());
      await _step(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      expect(f.media.opened, hasLength(1));
      expect(f.state.resolved, isEmpty);
      expect(f.media.transport, [(action: 'pause', url: f.request.url)]);
    },
  );

  _testPlayer(
    'missing selected-version profile prompts instead of guessing the only matching-looking file',
    (tester) async {
      final episodes = [
        VodEpisode(name: 'S01E01[1GB]', url: 'https://fixture.test/unknown-a'),
        VodEpisode(name: 'S01E01[2GB]', url: 'https://fixture.test/unknown-b'),
        ..._versions().skip(2).take(2),
      ];
      final f = await _mount(tester, episodes: episodes);
      await _step(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(f.state.resolved, isEmpty);
      await tester.tap(find.byKey(const ValueKey('episode-version-cancel')));
      await _settle(tester);
      expect(f.media.opened, hasLength(1));
    },
  );

  _testPlayer(
    'unavailable selected profile prompts rather than silently downgrading',
    (tester) async {
      final episodes = [
        ..._versions().take(2),
        VodEpisode(name: 'S01E02.720p', url: 'https://fixture.test/720'),
        VodEpisode(name: 'S01E02.2160p', url: 'https://fixture.test/2160'),
      ];
      final f = await _mount(tester, episodes: episodes);
      await _step(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(f.state.resolved, isEmpty);
      await tester.tap(find.byKey(const ValueKey('episode-version-confirm')));
      await _settle(tester);
      expect(f.media.opened.last.uri, episodes[2].url);
    },
  );

  _testPlayer(
    'selected version continuation clears old resume position and seed',
    (tester) async {
      final first = _versions().first;
      final f = await _mount(
        tester,
        startPosition: const Duration(seconds: 120),
        resumeSeed: ResumeSeed(
          flag: '原始flag',
          episodeId: first.url,
          episodeName: first.name,
          positionMs: 120000,
          durationMs: 1000000,
        ),
      );
      await _step(tester);
      expect(f.media.opened.last.uri, _versions()[3].url);
      expect(f.media.opened.last.start ?? Duration.zero, Duration.zero);
      expect(f.media.state.position, const Duration(seconds: 1));
    },
  );

  _testPlayer(
    'no duplicates keeps original next behavior even across explicit seasons',
    (tester) async {
      final episodes = [
        VodEpisode(name: 'S01E01.1080p', url: 'https://fixture.test/single1'),
        VodEpisode(name: 'S02E01.1080p', url: 'https://fixture.test/single2'),
      ];
      final f = await _mount(tester, episodes: episodes);
      await _step(tester);
      expect(f.media.opened.last.uri, episodes[1].url);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  _testPlayer(
    'confirmed request markers group unnamed files without accepting ordinary TMDB guesses',
    (tester) async {
      final episodes = [
        for (final (index, episode) in _versions().take(4).indexed)
          VodEpisode(
            name: 'file-$index.${index.isEven ? '1080p' : '2160p'}',
            url: episode.url,
            extra: {
              'tmdb_season_number': 1,
              'tmdb_episode_number': index < 2 ? 1 : 2,
              'episode_identity_confirmed': true,
            },
          ),
      ];
      final f = await _mount(tester, episodes: episodes);
      await _step(tester);
      expect(f.media.opened.last.uri, episodes[2].url);
    },
  );

  _testPlayer('ordinary TMDB guesses do not activate grouped navigation', (
    tester,
  ) async {
    final episodes = [
      for (final (index, episode) in _versions().take(4).indexed)
        VodEpisode(
          name: 'file-$index.1080p',
          url: episode.url,
          extra: {
            'tmdb_season_number': 1,
            'tmdb_episode_number': index < 2 ? 1 : 2,
          },
        ),
    ];
    final f = await _mount(tester, episodes: episodes);
    await _step(tester);
    expect(f.media.opened.last.uri, episodes[1].url);
  });

  _testPlayer(
    'list repeat at the last logical episode wraps without replaying an alternate version',
    (tester) async {
      final f = await _mount(tester, current: 4);
      await tester.tapAt(const Offset(300, 260), buttons: kSecondaryButton);
      await _settle(tester);
      await tester.tap(
        find.byKey(const ValueKey('player-menu-item-section:播放')),
      );
      await _settle(tester);
      await tester.tap(find.text('循环与定时…'));
      await _settle(tester);
      await tester.tap(find.text('列表循环'));
      await _settle(tester);
      await _finish(tester, f.media);
      expect(f.media.opened.last.uri, _versions()[0].url);
    },
  );

  _testPlayer(
    'autoplay selector confirmation opens the selected original file exactly once',
    (tester) async {
      final f = await _mount(tester, episodes: _ambiguous());
      await _finish(tester, f.media);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('episode-version-option-3')));
      await tester.tap(find.byKey(const ValueKey('episode-version-confirm')));
      await _settle(tester);
      expect(f.media.opened.map((m) => m.uri), [
        f.request.url,
        _ambiguous()[3].url,
      ]);
      expect(f.state.resolved.single.target, _ambiguous()[3].url);
      expect(f.media.transport, isEmpty);
      expect(f.media.state.playing, isTrue);
    },
  );

  _testPlayer(
    'grouped continuation retains external site routing and original playback flag',
    (tester) async {
      final f = await _mount(
        tester,
        lineRoutes: {
          '展示线路': const SwapLineRoute(
            siteKey: 'external',
            siteName: '外部站点',
            vodId: 'external-vod',
          ),
        },
      );
      await _step(tester);
      expect(f.state.resolved.single, (
        target: _versions()[3].url,
        flag: '原始flag',
        vodId: 'external-vod',
      ));
      expect(f.state.resolvedSites.single, same(f.state.externalSite));
      expect(f.media.opened.last.uri, _versions()[3].url);
    },
  );

  _testPlayer(
    'autoplay advances logical order when the selected variant is the final raw entry',
    (tester) async {
      final episodes = [
        _versions()[1],
        _versions()[2],
        _versions()[3],
        _versions()[0],
      ];
      final f = await _mount(tester, episodes: episodes, current: 3);
      await _finish(tester, f.media);
      expect(f.media.opened.last.uri, episodes[2].url);
    },
  );

  _testPlayer(
    'ambiguous previous pauses and cancellation restores the same current file',
    (tester) async {
      final episodes = [
        VodEpisode(
          name: 'S01E01.1080p[1GB]',
          url: 'https://fixture.test/first-a',
        ),
        VodEpisode(
          name: 'S01E01.1080p[2GB]',
          url: 'https://fixture.test/first-b',
        ),
        ..._versions().skip(2),
      ];
      final f = await _mount(tester, episodes: episodes, current: 3);
      await _step(tester, previous: true);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(f.media.state.playing, isFalse);
      expect(f.media.transport, [(action: 'pause', url: f.request.url)]);
      await tester.tap(find.text('取消'));
      await _settle(tester);
      expect(f.media.opened.single.uri, f.request.url);
      expect(f.media.state.playing, isTrue);
      expect(f.media.transport.last, (action: 'play', url: f.request.url));
    },
  );

  _testPlayer(
    'previously paused manual selection stays paused when cancelled',
    (tester) async {
      final f = await _mount(tester, episodes: _ambiguous());
      await f.media.pause();
      await tester.pump();
      f.media.transport.clear();
      await _step(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(f.media.state.playing, isFalse);
      await tester.tap(find.text('取消'));
      await _settle(tester);
      expect(f.media.opened.single.uri, f.request.url);
      expect(f.media.state.playing, isFalse);
      expect(f.media.transport, isEmpty);
    },
  );

  _testPlayer(
    'manual selector pauses before opening and guards repeated navigation during pause',
    (tester) async {
      final f = await _mount(tester, episodes: _ambiguous());
      final paused = Completer<void>();
      f.media.pauseGate = paused;
      final next = tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.skip_next))
          .onPressed!;
      next();
      next();
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(f.media.transport, [(action: 'pause', url: f.request.url)]);
      paused.complete();
      await _settle(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(f.media.state.playing, isFalse);
      await tester.tap(find.text('取消'));
      await _settle(tester);
      expect(f.media.transport, [
        (action: 'pause', url: f.request.url),
        (action: 'play', url: f.request.url),
      ]);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  _testPlayer(
    'preference invalidation during pause restores current playback without opening selector',
    (tester) async {
      final f = await _mount(tester, episodes: _ambiguous());
      final paused = Completer<void>();
      f.media.pauseGate = paused;
      final next = tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.skip_next))
          .onPressed!;
      next();
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.runAsync(() => f.state.setEpisodeAggregateVersions(false));
      paused.complete();
      await _settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(f.media.opened.single.uri, f.request.url);
      expect(f.media.state.playing, isTrue);
      expect(f.media.transport, [
        (action: 'pause', url: f.request.url),
        (action: 'play', url: f.request.url),
      ]);
    },
  );
}
