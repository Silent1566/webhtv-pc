import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/player_options.dart';
import 'package:webhtv_pc/core/playback.dart';
import 'package:webhtv_pc/core/playback_lines.dart';
import 'package:webhtv_pc/core/playback_queue.dart';
import 'package:webhtv_pc/core/karaoke/karaoke.dart';
import 'package:webhtv_pc/ui/ai_integration_widgets.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/danmaku_service.dart';
import 'package:webhtv_pc/core/skip_plan.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/tmdb_playback.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/intro_skip_options_page.dart';
import 'package:webhtv_pc/ui/player_context_menu.dart';
import 'package:webhtv_pc/ui/player_overlay.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/settings_overview_page.dart';
import 'package:webhtv_pc/ui/settings_detail_pages.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:media_kit/media_kit.dart';

import 'live_playback_session_test.dart' as live_fixture;
import 'player_live_controls_test.dart' show flush, MediaIO, MediaJournal;
import 'support/player_page_harness.dart';

class _OutroQueue extends ChangeNotifier implements PlaybackQueue {
  final resolved = <String>[];
  @override
  PlaybackQueueSnapshot get snapshot => PlaybackQueueSnapshot(
    items: const [
      PlaybackQueueItem(key: 'A', title: 'E3'),
      PlaybackQueueItem(key: 'B', title: 'E4'),
    ],
    hasMore: false,
  );
  @override
  Future<void> loadMore() async {}
  @override
  Future<PlaybackRequest> resolve(
    String key, {
    bool Function()? isCurrent,
  }) async {
    resolved.add(key);
    return PlaybackRequest(
      url: 'https://fixture.test/queue-next.mp4',
      title: 'fixture',
      siteKey: 'fixture',
      vodId: 'next',
      vodName: 'fixture',
      episodeName: 'E4',
      flag: '线路一',
      directUrl: true,
    );
  }
}

class _MetadataSkipState extends AppState {
  _MetadataSkipState({
    required super.paths,
    required super.log,
    required this.details,
  });
  final Future<PlaybackLines> details;
  @override
  Future<PlaybackLines?> playLinesForRecord({
    required String siteKey,
    required String vodId,
    String vodName = '',
    String sourceKey = '',
    bool Function()? isCurrent,
  }) => details;
}

class _GatedDanmaku extends DanmakuLoader {
  final requested = Completer<void>();
  final ready = Completer<void>();
  int calls = 0;
  @override
  Future<DanmakuDocument> load(
    DanmakuSource source, {
    Map<String, String> headers = const {},
    bool useCache = true,
  }) async {
    calls++;
    if (!requested.isCompleted) requested.complete();
    await ready.future;
    return DanmakuDocument(
      items: const [],
      format: 'xml',
      encoding: 'utf-8',
      sourceUrl: source.url,
      byteLength: 0,
      skipped: 0,
    );
  }
}

class _SkipMedia implements NativePlayer {
  _SkipMedia(PlatformPlayer original, MediaJournal journal)
    : transport = MediaIO(original, journal);
  final MediaIO transport;
  PlatformPlayer get original => transport.original;
  @override
  bool get disposed => transport.disposed;
  @override
  PlayerConfiguration get configuration => transport.configuration;
  @override
  PlayerStream get stream => transport.stream;
  @override
  PlayerState get state => transport.state;
  @override
  set state(PlayerState value) => transport.state = value;
  @override
  Future<int> get handle => transport.handle;
  @override
  List<Future<void> Function()> get release => transport.release;
  @override
  Completer<void> get videoControllerCompleter =>
      transport.videoControllerCompleter;
  @override
  bool get isVideoControllerAttached => transport.isVideoControllerAttached;
  @override
  set isVideoControllerAttached(bool value) =>
      transport.isVideoControllerAttached = value;
  void progress(int seconds) => transport.progress(seconds);

  final nativeCalls = <String>[];
  final seeks = <Duration>[];
  final openedStarts = <Duration?>[];
  int initialPosition = 1;
  Duration? initialBuffered;
  Future<void>? subtitleReady;
  final subtitleRequested = Completer<void>();
  int stops = 0;
  Duration initialDuration = const Duration(seconds: 1000);

  void emit({
    Duration? duration,
    int? position,
    bool? playing,
    Duration? buffered,
    bool? completed,
  }) {
    state = state.copyWith(
      duration: duration,
      position: position == null ? null : Duration(seconds: position),
      playing: playing,
      buffer: buffered,
      completed: completed,
    );
    if (duration != null) original.durationController.add(duration);
    if (position != null) original.positionController.add(state.position);
    if (playing != null) original.playingController.add(playing);
    if (buffered != null) original.bufferController.add(buffered);
    if (completed != null) original.completedController.add(completed);
  }

  final unexpectedCalls = <Symbol>[];
  final released = Completer<void>();

  @override
  Future<void> open(
    Playable playable, {
    bool play = true,
    bool synchronized = true,
  }) async {
    final media = playable as Media;
    transport.journal.opened.add(media.uri);
    openedStarts.add(media.start);
    final gate = transport.journal.gates.remove(media.uri);
    if (gate != null) await gate.future;
    if (transport.journal.failed.contains(media.uri)) {
      throw StateError('fixture next failed');
    }
    emit(
      duration: initialDuration,
      position: media.start?.inSeconds ?? initialPosition,
      playing: play,
      buffered: initialBuffered,
    );
  }

  @override
  Future<void> seek(Duration position, {bool synchronized = true}) {
    seeks.add(position);
    emit(position: position.inSeconds, playing: state.playing);
    return Future<void>.value();
  }

  @override
  Future<void> play({bool synchronized = true}) async => emit(playing: true);
  @override
  Future<void> pause({bool synchronized = true}) async {
    state = state.copyWith(playing: false);
    if (!disposed) original.playingController.add(false);
  }

  @override
  Future<void> setVolume(double volume, {bool synchronized = true}) =>
      transport.setVolume(volume);
  @override
  Future<void> setRate(double rate, {bool synchronized = true}) =>
      transport.setRate(rate);
  @override
  Future<void> setSubtitleTrack(
    SubtitleTrack track, {
    bool synchronized = true,
  }) async {
    if (subtitleReady != null) {
      if (!subtitleRequested.isCompleted) subtitleRequested.complete();
      await subtitleReady;
    }
    await transport.setSubtitleTrack(track);
  }

  @override
  Future<void> stop({
    bool open = false,
    bool notify = true,
    bool synchronized = true,
  }) async {
    stops++;
    state = state.copyWith(playing: false);
    if (notify) original.playingController.add(false);
  }

  @override
  Future<void> dispose({bool synchronized = true}) async {
    if (!original.videoControllerCompleter.isCompleted) {
      original.videoControllerCompleter.complete();
    }
    try {
      await transport.dispose();
    } finally {
      if (!released.isCompleted) released.complete();
    }
  }

  @override
  Future<void> setProperty(
    String key,
    String value, {
    bool waitForInitialization = true,
  }) async {
    nativeCalls.add('set:$key=$value wait=$waitForInitialization');
    if (!waitForInitialization &&
        const {'vo': 'libmpv', 'hwdec': 'auto', 'vid': 'auto'}[key] == value) {
      return;
    }
    throw UnsupportedError(
      'skip-menu transport does not apply native property $key',
    );
  }

  @override
  Future<String> getProperty(
    String key, {
    bool waitForInitialization = true,
  }) async {
    nativeCalls.add('get:$key');
    throw UnsupportedError(
      'skip-menu transport does not read native property $key',
    );
  }

  @override
  Future<void> observeProperty(
    String property,
    Future<void> Function(String) listener, {
    bool waitForInitialization = true,
  }) async {
    nativeCalls.add('observe:$property');
    throw UnsupportedError('skip-menu transport does not observe $property');
  }

  @override
  Future<void> unobserveProperty(
    String property, {
    bool waitForInitialization = true,
  }) async {
    nativeCalls.add('unobserve:$property');
    throw UnsupportedError('skip-menu transport has no observer for $property');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    unexpectedCalls.add(invocation.memberName);
    throw UnsupportedError('Unexpected native call: ${invocation.memberName}');
  }
}

Future<_SkipMedia> _mount(
  WidgetTester tester,
  PlayerPage page, {
  Size size = const Size(1280, 720),
  void Function(_SkipMedia)? configureMedia,
}) async {
  await tester.runAsync(page.state.bootstrap);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  installMediaKitMocks(tester);
  installWindowManagerMocks(tester);
  _SkipMedia? media;
  final seen = <Player>{};
  var active = true;
  addTearDown(() => active = false);
  tester.binding.addPersistentFrameCallback((_) {
    if (!active || find.byType(Video).evaluate().isEmpty) return;
    final player = tester.widget<Video>(find.byType(Video)).controller.player;
    if (!seen.add(player)) return;
    media = _SkipMedia(player.platform!, MediaJournal());
    configureMedia?.call(media!);
    player.platform = media;
  });
  await tester.pumpWidget(MaterialApp(home: page));
  await flush(tester);
  expect(tester.takeException(), isNull);
  return media!;
}

Future<void> unmount(WidgetTester tester) async {
  final videos = find.byType(Video);
  final platform = videos.evaluate().isEmpty
      ? null
      : tester.widget<Video>(videos).controller.player.platform;
  await tester.pumpWidget(const SizedBox.shrink());
  if (platform is _SkipMedia) {
    final disposal = Stopwatch()..start();
    while (!platform.released.isCompleted &&
        disposal.elapsed < const Duration(seconds: 10)) {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    expect(platform.released.isCompleted, isTrue);
    await tester.pump(const Duration(seconds: 5));
    // ignore: avoid_print
    print(
      'skip-menu native calls: ${platform.nativeCalls}; unknown: ${platform.unexpectedCalls}',
    );
    expect(platform.unexpectedCalls, isEmpty);
  }
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

Finder row(String id) => find.byKey(ValueKey('player-menu-item-$id'));

Future<void> tapRow(WidgetTester tester, String id) async {
  await tester.ensureVisible(row(id));
  await tester.tap(row(id));
  await flush(tester);
}

Future<void> openSkipMenu(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.f10);
  await flush(tester);
  await tapRow(tester, 'section:跳过片段');
}

PlayerMenuItem item(WidgetTester tester, String id) {
  PlayerMenuItem? search(List<PlayerMenuItem> items) {
    for (final candidate in items) {
      if (candidate.id == id) return candidate;
      final child = search(candidate.children);
      if (child != null) return child;
    }
    return null;
  }

  final menu = tester.widget<PlayerContextMenu>(find.byType(PlayerContextMenu));
  return search(menu.sections.expand((section) => section.items).toList())!;
}

Future<void> altKey(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  await flush(tester);
}

Future<
  ({
    AppState state,
    _SkipMedia media,
    http.Client client,
    List<http.Request> requests,
  })
>
_mountSegments(
  WidgetTester tester, {
  Future<void>? segmentsReady,
  PlayerOptions? options,
  DanmakuLoader? danmakuLoader,
  void Function(_SkipMedia)? configureMedia,
  Duration? startPosition,
  Future<void>? subtitleReady,
  List<VodPlayLine> playLines = const [],
  Future<http.Response> Function(http.Request)? skipResponse,
  Future<PlaybackLines>? metadata,
  String flag = '线路一',
  bool directUrl = false,
  bool clearTmdb = false,
  int episodeIndex = 0,
  Future<void> Function(AppState)? seedState,
  PlaybackQueue? queue,
}) async {
  final dir = Directory.systemTemp.createTempSync('skip-menu');
  final paths = AppPaths.resolve(
    overrides: {
      'config': dir.path,
      'data': dir.path,
      'cache': '${dir.path}/cache',
      'state': '${dir.path}/logs',
    },
  );
  final log = LogService();
  final state = metadata == null
      ? AppState(paths: paths, log: log)
      : _MetadataSkipState(paths: paths, log: log, details: metadata);
  addTearDown(() async {
    state.dispose();
    // Windows 上未释放的日志文件句柄会让目录删除直接抛错；先等日志收尾。
    await log.dispose();
    // 句柄释放与删除之间存在竞态：真实见过 PathAccessException 让整条用例
    // 在 teardown 里变红（与断言无关）。重试几次后放弃——临时目录残留不该
    // 决定这条 UI 用例的成败。
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });
  await tester.runAsync(() async {
    await state.bootstrap();
    if (seedState != null) await seedState(state);
    await state.setPlayerOptions(
      options ??
          const PlayerOptions(
            skipMode: SkipMode.off,
            skipKinds: SkipKindBits.none,
            skipSources: SkipSourceBits.todb,
          ),
    );
  });
  File? subtitle;
  if (subtitleReady != null) {
    subtitle = File('${dir.path}/gated.srt');
    await tester.runAsync(
      () => subtitle!.writeAsString(
        '1\n00:00:01,000 --> 00:00:02,000\nfixture\n',
      ),
    );
  }
  final requests = <http.Request>[];
  final client = MockClient((request) async {
    requests.add(request);
    if (skipResponse != null) return skipResponse(request);
    if (segmentsReady != null) await segmentsReady;
    return http.Response(
      jsonEncode({
        'items': [
          {
            'version_id': 1,
            'version_runtime': 1000,
            'marker': [
              for (final marker in [
                ('recap', 0, 10),
                ('intro', 10, 30),
                ('advertisement', 100, 120),
                ('advertisement', 200, 220),
                ('intermission', 300, 320),
                ('intermission', 400, 420),
                ('outro', 800, 850),
                ('preview', 870, 890),
                ('post_credits', 910, 930),
              ])
                {
                  'marker_id': marker.$2,
                  'marker_type': marker.$1,
                  'time_start': marker.$2,
                  'time_end': marker.$3,
                },
            ],
          },
        ],
      }),
      200,
    );
  });
  final media = await http.runWithClient(
    () => _mount(
      tester,
      PlayerPage(
        state: state,
        queue: queue,
        queueItemKey: queue?.snapshot.items.first.key,
        danmakuLoader: danmakuLoader,
        request: PlaybackRequest(
          url: 'https://fixture.test/skip.mp4',
          title: '示例剧集',
          siteKey: 'fixture',
          vodId: 'skip',
          vodName: '示例剧集',
          episodeName: 'E3',
          flag: flag,
          directUrl: directUrl,
          episodeIndex: episodeIndex,
          startPosition: startPosition,
          playLines: playLines,
          subtitles: subtitle == null
              ? const []
              : [SubtitleInfo(url: subtitle.path, format: 'srt')],
          danmaku: danmakuLoader == null
              ? const []
              : const [DanmakuSource(url: 'https://fixture.test/gated.xml')],
          tmdb: clearTmdb
              ? null
              : const TmdbPlaybackIdentity(
                  tmdbId: 1,
                  mediaType: TmdbMediaType.tv,
                  seasonNumber: 1,
                  episodeNumber: 3,
                ),
        ),
      ),
      size: const Size(1280, 720),
      configureMedia: (media) {
        media.subtitleReady = subtitleReady;
        configureMedia?.call(media);
      },
    ),
    () => client,
  );
  await flush(tester);
  return (state: state, media: media, client: client, requests: requests);
}

Future<void> _waitForLifecycleEvent(
  WidgetTester tester,
  bool Function() completed, {
  required String stage,
  required String Function() diagnostics,
}) async {
  final elapsed = Stopwatch()..start();
  while (!completed() && elapsed.elapsed < const Duration(seconds: 15)) {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  expect(completed(), isTrue, reason: '$stage 未在15秒真实时间内完成；${diagnostics()}');
  await tester.pump();
}

Future<void> _dragProgressTo(WidgetTester tester, double fraction) async {
  debugRevealPlayerControls(
    tester.state<State<PlayerPage>>(find.byType(PlayerPage)),
  );
  await tester.pump();
  final slider = find.descendant(
    of: find.byType(PlayerProgressSlider),
    matching: find.byType(Slider),
  );
  final rect = tester.getRect(slider);
  final widget = tester.widget<Slider>(slider);
  final current = widget.value / widget.max;
  final start = Offset(
    rect.left + 24 + (rect.width - 48) * current,
    rect.center.dy,
  );
  final target = Offset(
    rect.left + 24 + (rect.width - 48) * fraction,
    rect.center.dy,
  );
  final gesture = await tester.startGesture(start);
  await tester.pump();
  await gesture.moveTo(Offset((start.dx + target.dx) / 2, target.dy));
  await tester.pump();
  await gesture.moveTo(target);
  await tester.pump();
  await gesture.up();
  await flush(tester);
}

http.Response _markers(
  List<(String, int, int)> markers, {
  int endDuration = 1000,
}) => http.Response(
  jsonEncode({
    'items': [
      {
        'version_id': 1,
        'version_runtime': endDuration,
        'marker': [
          for (final marker in markers)
            {
              'marker_id': marker.$2,
              'marker_type': marker.$1,
              'time_start': marker.$2,
              'time_end': marker.$3,
            },
        ],
      },
    ],
  }),
  200,
);

Future<void> _replaceSkipRequest(
  WidgetTester tester,
  AppState state,
  PlaybackRequest request,
  http.Client client,
) async {
  await http.runWithClient(
    () => tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(state: state, request: request),
      ),
    ),
    () => client,
  );
  await flush(tester);
}

List<VodPlayLine> _outroLines() => [
  VodPlayLine(
    flag: '线路一',
    episodes: [
      VodEpisode(name: 'E3', url: 'https://fixture.test/skip.mp4'),
      VodEpisode(name: 'E4', url: 'https://fixture.test/next.mp4'),
    ],
  ),
];

Future<void> _setRepeat(WidgetTester tester, String label) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.f10);
  await flush(tester);
  await tapRow(tester, 'section:播放');
  await tapRow(tester, 'playback_mode');
  await tester.scrollUntilVisible(
    find.text(label),
    180,
    scrollable: find.byType(Scrollable).last,
  );
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await flush(tester);
}

void main() {
  for (final advance in [false, true]) {
    testWidgets('outro历史：完成后旧集duration记完成且新集只记实际位置 advance=$advance', (
      tester,
    ) async {
      final fixture = await _mountSegments(
        tester,
        options: PlayerOptions(
          skipMode: SkipMode.auto,
          skipKinds: SkipKindBits.outro,
          skipSources: SkipSourceBits.todb,
          autoNext: advance,
        ),
        directUrl: true,
        playLines: _outroLines(),
        configureMedia: (media) => media.initialPosition = 500,
        skipResponse: (request) async => _markers([('outro', 800, 1000)]),
      );
      final nextGate = Completer<void>();
      if (advance) {
        fixture.media.transport.journal.gates['https://fixture.test/next.mp4'] =
            nextGate;
      }
      fixture.media.emit(position: 805, playing: true);
      await flush(tester);
      await tester.pump(const Duration(seconds: 6));
      final old = fixture.state.recentHistory().singleWhere(
        (row) => row.episodeId == 'https://fixture.test/skip.mp4',
      );
      expect(old.positionMs, 1000000, reason: '明确跳过至EOF必须沿writer记录旧集完成');
      expect(
        recomputeCompleted(
          durationMs: old.durationMs,
          positionMs: old.positionMs,
        ),
        isTrue,
      );
      if (advance) {
        nextGate.complete();
        await flush(tester);
        await tester.pump(const Duration(seconds: 6));
        final next = fixture.state.recentHistory().singleWhere(
          (row) => row.episodeId == 'https://fixture.test/next.mp4',
        );
        expect(next.positionMs, 500000);
        expect(
          recomputeCompleted(
            durationMs: next.durationMs,
            positionMs: next.positionMs,
          ),
          isFalse,
        );
      } else {
        fixture.media.emit(position: 805, playing: false);
        await tester.pump(const Duration(seconds: 6));
      }
      await unmount(tester);
      expect(
        fixture.state
            .recentHistory()
            .singleWhere(
              (row) => row.episodeId == 'https://fixture.test/skip.mp4',
            )
            .positionMs,
        1000000,
      );
    });
  }

  for (final mode in ['autoNext', 'repeat', 'queue', 'natural']) {
    testWidgets('outro睡眠：本集结束优先于$mode并只停止一次', (tester) async {
      final queue = mode == 'queue' ? _OutroQueue() : null;
      if (queue != null) addTearDown(queue.dispose);
      final fixture = await _mountSegments(
        tester,
        options: PlayerOptions(
          skipMode: mode == 'natural' ? SkipMode.off : SkipMode.auto,
          skipKinds: SkipKindBits.outro,
          skipSources: SkipSourceBits.todb,
          autoNext: true,
        ),
        directUrl: true,
        playLines: _outroLines(),
        queue: queue,
        configureMedia: (media) => media.initialPosition = 500,
        skipResponse: (request) async => _markers([('outro', 800, 1000)]),
      );
      if (mode == 'repeat') await _setRepeat(tester, '单集循环');
      await _setRepeat(tester, '本集结束后');
      if (mode == 'natural') {
        for (final position in [997, 998, 999]) {
          fixture.media.emit(
            position: position,
            playing: true,
            completed: false,
          );
          await tester.pump(const Duration(seconds: 1));
        }
        fixture.media.emit(position: 1000, playing: false, completed: true);
      } else {
        fixture.media.emit(position: 805, playing: true);
      }
      await flush(tester);
      expect(
        fixture.media.transport.journal.opened,
        hasLength(1),
        reason: '本集结束sleep不得被next/repeat/queue绕过',
      );
      expect(fixture.media.seeks, isEmpty);
      expect(fixture.media.state.playing, isFalse);
      expect(
        fixture.state.log.entries.where(
          (entry) => entry.message == '定时关闭生效，已暂停',
        ),
        hasLength(1),
      );
      fixture.media.emit(position: 1000, playing: false, completed: true);
      await flush(tester);
      expect(fixture.media.transport.journal.opened, hasLength(1));
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await flush(tester);
      await tapRow(tester, 'section:播放');
      await tapRow(tester, 'playback_mode');
      final cancel = find.text('取消定时（当前未开启）');
      await tester.scrollUntilVisible(
        cancel,
        180,
        scrollable: find.byType(Scrollable).last,
      );
      expect(cancel, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await flush(tester);
      await unmount(tester);
    });
  }

  testWidgets('outro队列：显式完成复用下一文件resolve且恰好打开一次', (tester) async {
    final queue = _OutroQueue();
    addTearDown(queue.dispose);
    final fixture = await _mountSegments(
      tester,
      options: const PlayerOptions(
        skipMode: SkipMode.auto,
        skipKinds: SkipKindBits.outro,
        skipSources: SkipSourceBits.todb,
        autoNext: true,
      ),
      directUrl: true,
      queue: queue,
      configureMedia: (media) {
        media.initialPosition = 500;
        media.initialBuffered = const Duration(seconds: 20);
      },
      skipResponse: (request) async => _markers([('outro', 800, 1000)]),
    );
    fixture.media.emit(position: 805, playing: true);
    await flush(tester);
    expect(queue.resolved, ['B']);
    expect(fixture.media.transport.journal.opened, [
      'https://fixture.test/skip.mp4',
      'https://fixture.test/queue-next.mp4',
    ]);
    expect(fixture.media.openedStarts, [null, null]);
    expect(fixture.media.seeks, isEmpty);
    await unmount(tester);
  });

  testWidgets('outro聚合：跳过同集多个版本而打开下一逻辑集', (tester) async {
    final fixture = await _mountSegments(
      tester,
      options: const PlayerOptions(
        skipMode: SkipMode.auto,
        skipKinds: SkipKindBits.outro,
        skipSources: SkipSourceBits.todb,
        autoNext: true,
      ),
      directUrl: true,
      playLines: [
        VodPlayLine(
          flag: '线路一',
          episodes: [
            VodEpisode(
              name: 'S01E03.1080p[1GB]',
              url: 'https://fixture.test/skip.mp4',
            ),
            VodEpisode(
              name: 'S01E03.2160p[3GB]',
              url: 'https://fixture.test/same-high.mp4',
            ),
            VodEpisode(
              name: 'S01E04.1080p[2GB]',
              url: 'https://fixture.test/logical-next.mp4',
            ),
          ],
        ),
      ],
      configureMedia: (media) => media.initialPosition = 500,
      skipResponse: (request) async => _markers([('outro', 800, 1000)]),
    );
    fixture.media.emit(position: 805, playing: true);
    await flush(tester);
    expect(fixture.media.transport.journal.opened, [
      'https://fixture.test/skip.mp4',
      'https://fixture.test/logical-next.mp4',
    ]);
    expect(fixture.media.seeks, isEmpty);
    await unmount(tester);
  });

  testWidgets('outro季边界：当前季末不得跨到下一季', (tester) async {
    final fixture = await _mountSegments(
      tester,
      options: const PlayerOptions(
        skipMode: SkipMode.auto,
        skipKinds: SkipKindBits.outro,
        skipSources: SkipSourceBits.todb,
        autoNext: true,
      ),
      directUrl: true,
      playLines: [
        VodPlayLine(
          flag: '线路一',
          episodes: [
            VodEpisode(name: 'S01E03', url: 'https://fixture.test/skip.mp4'),
            VodEpisode(name: 'S02E01', url: 'https://fixture.test/season2.mp4'),
          ],
        ),
      ],
      configureMedia: (media) => media.initialPosition = 500,
      skipResponse: (request) async => _markers([('outro', 800, 1000)]),
    );
    fixture.media.emit(position: 805, playing: true);
    await flush(tester);
    expect(fixture.media.transport.journal.opened, [
      'https://fixture.test/skip.mp4',
    ]);
    expect(fixture.media.openedStarts, [null]);
    await unmount(tester);
  });

  for (final source in ['menu', 'settings']) {
    testWidgets('outro高亮：$source入口关闭颜色不影响识别或真实自动跳段', (tester) async {
      final fixture = await _mountSegments(
        tester,
        options: const PlayerOptions(
          skipMode: SkipMode.auto,
          skipKinds: SkipKindBits.intro,
          skipSources: SkipSourceBits.todb,
        ),
        configureMedia: (media) => media.initialPosition = 500,
      );
      final colors = fixture.state.playerOptions.skipSegmentColors;
      await openSkipMenu(tester);
      if (source == 'menu') {
        await tester.runAsync(() => tester.tap(row('skip_highlight')));
        await flush(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await flush(tester);
      } else {
        await tapRow(tester, 'skip_colors');
        final toggle = find.byKey(
          const ValueKey('settings-player-skip-highlight'),
        );
        await tester.scrollUntilVisible(
          toggle,
          220,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(toggle);
        await flush(tester);
        await tester.runAsync(() => tester.tap(toggle));
        await flush(tester);
        Navigator.of(tester.element(find.byType(IntroSkipOptionsPage))).pop();
        await flush(tester);
      }
      debugRevealPlayerControls(
        tester.state<State<PlayerPage>>(find.byType(PlayerPage)),
      );
      await tester.pump();
      final progress = tester.widget<PlayerProgressSlider>(
        find.byType(PlayerProgressSlider),
      );
      expect(fixture.state.playerOptions.showSkipSegmentHighlights, isFalse);
      expect(progress.showSkipSegmentHighlights, isFalse);
      expect(progress.skipSegments, hasLength(9));
      expect(progress.skipSegmentColors, colors);
      fixture.media.emit(position: 11, playing: true);
      await flush(tester);
      expect(fixture.media.seeks, [const Duration(seconds: 30)]);
      expect(fixture.state.playerOptions.skipMode, SkipMode.auto);
      await unmount(tester);
    });
  }

  testWidgets('outro自然EOF：未启用跳过时仍按已有策略打开下一集', (tester) async {
    final fixture = await _mountSegments(
      tester,
      options: const PlayerOptions(skipMode: SkipMode.off, autoNext: true),
      directUrl: true,
      playLines: _outroLines(),
      configureMedia: (media) => media.initialPosition = 990,
    );
    for (final position in [997, 998, 999]) {
      fixture.media.emit(position: position, playing: true, completed: false);
      await tester.pump(const Duration(seconds: 1));
    }
    fixture.media.emit(position: 1000, playing: false, completed: true);
    await flush(tester);
    expect(fixture.media.transport.journal.opened, [
      'https://fixture.test/skip.mp4',
      'https://fixture.test/next.mp4',
    ]);
    await unmount(tester);
  });

  testWidgets('outro回看：完成跳段不能跨入下一集', (tester) async {
    final fixture = await _mountSegments(
      tester,
      options: const PlayerOptions(
        skipMode: SkipMode.auto,
        skipKinds: SkipKindBits.outro,
        skipSources: SkipSourceBits.todb,
        autoNext: true,
      ),
      directUrl: true,
      flag: '回看',
      playLines: [
        VodPlayLine(
          flag: '回看',
          episodes: [
            VodEpisode(name: 'E3', url: 'https://fixture.test/skip.mp4'),
            VodEpisode(name: 'E4', url: 'https://fixture.test/next.mp4'),
          ],
        ),
      ],
      configureMedia: (media) => media.initialPosition = 500,
      skipResponse: (request) async => _markers([('outro', 800, 1000)]),
    );
    fixture.media.emit(position: 805, playing: true);
    await flush(tester);
    expect(fixture.media.transport.journal.opened, hasLength(1));
    expect(fixture.media.seeks, [const Duration(seconds: 1000)]);
    await unmount(tester);
  });

  for (final scenario in [
    (
      name: 'autoNext关闭',
      autoNext: false,
      repeat: '不循环',
      index: 0,
      episodes: true,
      next: false,
      replay: false,
    ),
    (
      name: '末集不循环',
      autoNext: true,
      repeat: '不循环',
      index: 1,
      episodes: true,
      next: false,
      replay: false,
    ),
    (
      name: '无剧集',
      autoNext: true,
      repeat: '不循环',
      index: 0,
      episodes: false,
      next: false,
      replay: false,
    ),
    (
      name: '单集循环优先于关闭autoNext',
      autoNext: false,
      repeat: '单集循环',
      index: 0,
      episodes: true,
      next: false,
      replay: true,
    ),
    (
      name: '列表循环末集回首集',
      autoNext: false,
      repeat: '列表循环',
      index: 1,
      episodes: true,
      next: true,
      replay: false,
    ),
  ]) {
    testWidgets('outro策略：${scenario.name}', (tester) async {
      final fixture = await _mountSegments(
        tester,
        options: PlayerOptions(
          skipMode: SkipMode.auto,
          skipKinds: SkipKindBits.outro,
          autoNext: scenario.autoNext,
        ),
        directUrl: true,
        clearTmdb: true,
        episodeIndex: scenario.index,
        playLines: scenario.episodes ? _outroLines() : [],
        seedState: (state) async {
          await state.saveSkipSegments(
            siteKey: 'fixture',
            vodId: 'skip',
            outroStartMs: 800000,
          );
        },
        configureMedia: (media) {
          media.initialPosition = 500;
          media.initialBuffered = const Duration(seconds: 20);
        },
      );
      if (scenario.repeat != '不循环') await _setRepeat(tester, scenario.repeat);
      fixture.media.emit(position: 805, playing: true);
      await flush(tester);
      expect(
        fixture.media.transport.journal.opened,
        hasLength(scenario.next ? 2 : 1),
      );
      expect(
        fixture.media.openedStarts.every((start) => start == null),
        isTrue,
      );
      expect(fixture.media.seeks, scenario.replay ? [Duration.zero] : isEmpty);
      if (!scenario.next && !scenario.replay) {
        expect(fixture.media.state.playing, isFalse);
      }
      if (scenario.replay) {
        fixture.media.emit(position: 11, playing: true);
        await flush(tester);
        expect(fixture.media.seeks, [Duration.zero]);
      }
      await unmount(tester);
    });
  }

  for (final accept in [false, true]) {
    testWidgets('outro确认：确认=$accept只执行一次下一集动作', (tester) async {
      final fixture = await _mountSegments(
        tester,
        options: const PlayerOptions(
          skipMode: SkipMode.confirm,
          skipKinds: SkipKindBits.outro,
          skipSources: SkipSourceBits.todb,
          autoNext: true,
        ),
        directUrl: true,
        playLines: _outroLines(),
        configureMedia: (media) {
          media.initialPosition = 500;
          media.initialBuffered = const Duration(seconds: 20);
        },
        skipResponse: (request) async => _markers([('outro', 800, 1000)]),
      );
      fixture.media.emit(position: 805, playing: true);
      await flush(tester);
      expect(find.text('跳过片尾？'), findsOneWidget);
      expect(fixture.media.openedStarts, hasLength(1));
      await tester.tap(find.text(accept ? '跳过' : '不跳'));
      await flush(tester);
      expect(fixture.media.transport.journal.opened, hasLength(accept ? 2 : 1));
      expect(
        fixture.media.openedStarts.every((start) => start == null),
        isTrue,
      );
      fixture.media.emit(position: 806, playing: true);
      await flush(tester);
      expect(fixture.media.transport.journal.opened, hasLength(accept ? 2 : 1));
      await unmount(tester);
    });
  }

  testWidgets('outro有限段：后面仍有彩蛋时只安全跳段末不提前下一集', (tester) async {
    final fixture = await _mountSegments(
      tester,
      options: const PlayerOptions(
        skipMode: SkipMode.auto,
        skipKinds: SkipKindBits.outro,
        skipSources: SkipSourceBits.todb,
        autoNext: true,
      ),
      directUrl: true,
      playLines: _outroLines(),
      configureMedia: (media) {
        media.initialPosition = 500;
        media.initialBuffered = const Duration(seconds: 20);
      },
      skipResponse: (request) async => _markers([('outro', 800, 850)]),
    );
    fixture.media.emit(position: 805, playing: true);
    await flush(tester);
    expect(fixture.media.transport.journal.opened, [
      'https://fixture.test/skip.mp4',
      'https://fixture.test/skip.mp4',
    ]);
    expect(fixture.media.openedStarts, [null, const Duration(seconds: 850)]);
    expect(fixture.media.seeks, isEmpty);
    await unmount(tester);
  });

  testWidgets('outro慢下一集：超过5秒与重复事件不漏不重复连播', (tester) async {
    final fixture = await _mountSegments(
      tester,
      options: const PlayerOptions(
        skipMode: SkipMode.auto,
        skipKinds: SkipKindBits.outro,
        skipSources: SkipSourceBits.todb,
        autoNext: true,
      ),
      directUrl: true,
      playLines: _outroLines(),
      configureMedia: (media) {
        media.initialPosition = 500;
        media.initialBuffered = const Duration(seconds: 20);
      },
      skipResponse: (request) async => _markers([('outro', 800, 1000)]),
    );
    final gate = Completer<void>();
    fixture.media.transport.journal.gates['https://fixture.test/next.mp4'] =
        gate;
    fixture.media.emit(position: 805, playing: true);
    await flush(tester);
    expect(fixture.media.transport.journal.opened, hasLength(2));
    await tester.pump(const Duration(seconds: 6));
    fixture.media.emit(position: 806, playing: true, completed: true);
    await tester.pump();
    expect(fixture.media.transport.journal.opened, hasLength(2));
    gate.complete();
    await flush(tester);
    expect(fixture.media.transport.journal.opened, hasLength(2));
    expect(fixture.media.openedStarts, [null, null]);
    await unmount(tester);
  });

  testWidgets('outro下一集失败：只尝试下一集一次不重新循环片尾', (tester) async {
    final fixture = await _mountSegments(
      tester,
      options: const PlayerOptions(
        skipMode: SkipMode.auto,
        skipKinds: SkipKindBits.outro,
        skipSources: SkipSourceBits.todb,
        autoNext: true,
      ),
      directUrl: true,
      playLines: _outroLines(),
      configureMedia: (media) {
        media.initialPosition = 500;
        media.initialBuffered = const Duration(seconds: 20);
      },
      skipResponse: (request) async => _markers([('outro', 800, 1000)]),
    );
    fixture.media.transport.journal.failed.add('https://fixture.test/next.mp4');
    fixture.media.emit(position: 805, playing: true);
    await flush(tester);
    expect(fixture.media.transport.journal.opened, hasLength(2));
    expect(
      fixture.state.log.entries.any(
        (entry) => entry.message.contains('succeeded=false'),
      ),
      isTrue,
    );
    fixture.media.emit(position: 806, playing: true, completed: true);
    await flush(tester);
    expect(fixture.media.transport.journal.opened, hasLength(2));
    await unmount(tester);
  });

  testWidgets('outro完成历史：重新播放离开完成态后记录真实位置', (tester) async {
    final fixture = await _mountSegments(
      tester,
      options: const PlayerOptions(
        skipMode: SkipMode.auto,
        skipKinds: SkipKindBits.outro,
        skipSources: SkipSourceBits.todb,
        autoNext: false,
      ),
      directUrl: true,
      playLines: _outroLines(),
      configureMedia: (media) => media.initialPosition = 500,
      skipResponse: (request) async => _markers([('outro', 800, 1000)]),
    );
    fixture.media.emit(position: 805, playing: true);
    await flush(tester);
    expect(fixture.state.recentHistory().single.positionMs, 1000000);
    expect(fixture.media.state.playing, isFalse);
    debugRevealPlayerControls(
      tester.state<State<PlayerPage>>(find.byType(PlayerPage)),
    );
    await tester.pump();
    final play = find.byTooltip('播放（空格）').hitTestable();
    expect(play, findsOneWidget, reason: '播放按钮必须真实可命中');
    await tester.tap(play);
    await flush(tester);
    expect(fixture.media.state.playing, isTrue);
    final player = tester.widget<Video>(find.byType(Video)).controller.player;
    expect(player.state.playing, isTrue);
    expect(find.byTooltip('暂停（空格）'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    expect(
      fixture.state.recentHistory().single.positionMs,
      805000,
      reason: '按钮真正播放后，完成快照必须已释放到当前真实位置',
    );
    fixture.media.emit(position: 700);
    await tester.pump(const Duration(seconds: 6));
    expect(fixture.state.recentHistory().single.positionMs, 700000);
    await unmount(tester);
    await tester.pump(const Duration(seconds: 6));
    expect(fixture.state.recentHistory().single.positionMs, 700000);
  });

  testWidgets('outro普通拖末尾：用户拖动不视为明确跳过完成意图', (tester) async {
    final fixture = await _mountSegments(
      tester,
      options: const PlayerOptions(
        skipMode: SkipMode.off,
        skipKinds: SkipKindBits.all,
        skipSources: SkipSourceBits.todb,
        autoNext: true,
      ),
      directUrl: true,
      playLines: _outroLines(),
      configureMedia: (media) {
        media.initialPosition = 500;
        media.initialBuffered = const Duration(seconds: 20);
      },
    );
    await _dragProgressTo(tester, 1);
    await flush(tester);
    fixture.media.emit(position: 1000, playing: false, completed: true);
    await flush(tester);
    expect(
      fixture.media.transport.journal.opened.every(
        (url) => url == 'https://fixture.test/skip.mp4',
      ),
      isTrue,
    );
    expect(fixture.media.transport.journal.opened, hasLength(2));
    await unmount(tester);
  });

  testWidgets('outro完成：auto片尾到duration且buffer外直接打开下一集一次不等EOF', (tester) async {
    final fixture = await _mountSegments(
      tester,
      options: const PlayerOptions(
        skipMode: SkipMode.off,
        skipKinds: SkipKindBits.outro,
        skipSources: SkipSourceBits.todb,
        autoNext: true,
      ),
      directUrl: true,
      configureMedia: (media) {
        media.initialPosition = 500;
        media.initialBuffered = const Duration(seconds: 20);
      },
      playLines: [
        VodPlayLine(
          flag: '线路一',
          episodes: [
            VodEpisode(name: 'E3', url: 'https://fixture.test/skip.mp4'),
            VodEpisode(name: 'E4', url: 'https://fixture.test/next.mp4'),
          ],
        ),
      ],
      skipResponse: (request) async => _markers([('outro', 800, 1000)]),
    );
    await openSkipMenu(tester);
    await tapRow(tester, 'skip_mode');
    await tester.runAsync(() => tester.tap(row('skip_mode_auto')));
    await flush(tester);
    fixture.media.emit(position: 805, playing: true);
    await flush(tester);
    expect(fixture.media.transport.journal.opened, [
      'https://fixture.test/skip.mp4',
      'https://fixture.test/next.mp4',
    ], reason: '明确跳至本集结尾不能重开同媒体duration并等不一定存在的EOF');
    expect(fixture.media.openedStarts, [null, null]);
    expect(fixture.media.seeks, isEmpty);
    // ignore: avoid_print
    print(
      'outro actual opens=${fixture.media.transport.journal.opened}; '
      'starts=${fixture.media.openedStarts}; seeks=${fixture.media.seeks}',
    );
    await unmount(tester);
  });

  testWidgets('seek元数据：唯一集目标规范flag后pending标定仍应用且不重查', (tester) async {
    final details = Completer<PlaybackLines>();
    final skip = Completer<http.Response>();
    final fixture = await _mountSegments(
      tester,
      metadata: details.future,
      flag: '已删除线路',
      configureMedia: (media) => media.initialPosition = 500,
      skipResponse: (request) => skip.future,
    );
    expect(fixture.requests, hasLength(1));
    details.complete(
      PlaybackLines(
        lines: [
          VodPlayLine(
            flag: '规范显示线路',
            sourceFlag: 'backend',
            episodes: [
              VodEpisode(name: 'E3', url: 'https://fixture.test/skip.mp4'),
            ],
          ),
        ],
      ),
    );
    await _waitForLifecycleEvent(
      tester,
      () => fixture.state.log.entries.any(
        (entry) =>
            entry.message.startsWith('选集入口已补齐') &&
            entry.message.contains('规范显示线路'),
      ),
      stage: '真实后台详情补齐规范flag',
      diagnostics: () =>
          fixture.state.log.entries.map((e) => e.message).join('|'),
    );
    skip.complete(_markers([('intro', 10, 30), ('outro', 800, 850)]));
    await flush(tester);
    expect(
      tester
          .widget<PlayerProgressSlider>(find.byType(PlayerProgressSlider))
          .skipSegments,
      hasLength(2),
      reason: '同媒体metadata规范flag不得丢弃合法pending结果',
    );
    expect(fixture.requests, hasLength(1));
    await unmount(tester);
  });

  testWidgets('seek元数据：已处理片头经flag规范后拖动重开保留raw及handled', (tester) async {
    final details = Completer<PlaybackLines>();
    final fixture = await _mountSegments(
      tester,
      metadata: details.future,
      flag: '旧线路',
      options: const PlayerOptions(
        skipMode: SkipMode.auto,
        skipKinds: SkipKindBits.intro,
        skipSources: SkipSourceBits.todb,
      ),
      configureMedia: (media) => media.initialPosition = 11,
    );
    expect(fixture.media.seeks, [const Duration(seconds: 30)]);
    details.complete(
      PlaybackLines(
        lines: [
          VodPlayLine(
            flag: '规范线路',
            sourceFlag: 'backend',
            episodes: [
              VodEpisode(name: 'E3', url: 'https://fixture.test/skip.mp4'),
            ],
          ),
        ],
      ),
    );
    await _waitForLifecycleEvent(
      tester,
      () => fixture.state.log.entries.any(
        (entry) =>
            entry.message.startsWith('选集入口已补齐') &&
            entry.message.contains('规范线路'),
      ),
      stage: '同媒体flag规范完成',
      diagnostics: () => 'requests=${fixture.requests.length}',
    );
    fixture.media.emit(
      position: 500,
      buffered: const Duration(seconds: 20),
      playing: true,
    );
    await flush(tester);
    await _dragProgressTo(tester, 0.75);
    fixture.media.emit(buffered: const Duration(seconds: 1));
    await tester.pump();
    await _dragProgressTo(tester, 0.02);
    fixture.media.emit(position: 11, playing: true);
    await flush(tester);
    expect(
      fixture.requests,
      hasLength(1),
      reason: 'metadata-only规范不能让拖动变成新版本会话',
    );
    expect(
      tester
          .widget<PlayerProgressSlider>(find.byType(PlayerProgressSlider))
          .skipSegments,
      hasLength(9),
    );
    expect(fixture.media.seeks, [const Duration(seconds: 30)]);
    expect(
      fixture.state.log.entries.where(
        (entry) => entry.message.startsWith('跳过片头 '),
      ),
      hasLength(1),
    );
    await unmount(tester);
  });

  testWidgets('seek版本：真实flag替换仍重置会话且不复用上一flag原始段', (tester) async {
    final next = Completer<http.Response>();
    var queries = 0;
    final fixture = await _mountSegments(
      tester,
      skipResponse: (request) async {
        queries++;
        return queries == 1 ? _markers([('intro', 10, 30)]) : next.future;
      },
    );
    final original = tester.widget<PlayerPage>(find.byType(PlayerPage)).request;
    await _replaceSkipRequest(
      tester,
      fixture.state,
      original.copyWith(flag: '另一实际版本线路', tmdb: original.tmdb),
      fixture.client,
    );
    expect(queries, 2, reason: '只允许已验证的metadata补齐同步，不能全局忽略flag');
    expect(
      tester
          .widget<PlayerProgressSlider>(find.byType(PlayerProgressSlider))
          .skipSegments,
      isEmpty,
    );
    next.complete(_markers([('outro', 600, 650)]));
    await _waitForLifecycleEvent(
      tester,
      () => tester
          .widget<PlayerProgressSlider>(find.byType(PlayerProgressSlider))
          .skipSegments
          .isNotEmpty,
      stage: '真实flag新版本标定',
      diagnostics: () => 'queries=$queries',
    );
    expect(
      tester
          .widget<PlayerProgressSlider>(find.byType(PlayerProgressSlider))
          .skipSegments
          .single
          .kind,
      SkipKind.outro,
    );
    await unmount(tester);
  });

  testWidgets('seek版本：同集换URL版本不沿用旧raw，待查新结果独立归属', (tester) async {
    final next = Completer<http.Response>();
    final queries = <int>[];
    final fixture = await _mountSegments(
      tester,
      skipResponse: (request) async {
        queries.add((jsonDecode(request.body) as Map)['episode_number'] as int);
        return queries.length == 1
            ? _markers([('intro', 10, 30), ('outro', 800, 850)])
            : next.future;
      },
    );
    expect(
      tester
          .widget<PlayerProgressSlider>(find.byType(PlayerProgressSlider))
          .skipSegments,
      hasLength(2),
    );
    final original = tester.widget<PlayerPage>(find.byType(PlayerPage)).request;
    await _replaceSkipRequest(
      tester,
      fixture.state,
      original.copyWith(
        url: 'https://fixture.test/version-B.mp4',
        qualityIndex: 1,
        tmdb: original.tmdb,
      ),
      fixture.client,
    );
    expect(queries, [3, 3], reason: '不同版本不能使用上一版本cache/raw');
    expect(
      tester
          .widget<PlayerProgressSlider>(find.byType(PlayerProgressSlider))
          .skipSegments,
      isEmpty,
    );
    next.complete(_markers([('outro', 600, 650)]));
    await _waitForLifecycleEvent(
      tester,
      () => tester
          .widget<PlayerProgressSlider>(find.byType(PlayerProgressSlider))
          .skipSegments
          .isNotEmpty,
      stage: '新版本标定已应用',
      diagnostics: () => 'queries=$queries',
    );
    final segments = tester
        .widget<PlayerProgressSlider>(find.byType(PlayerProgressSlider))
        .skipSegments;
    expect(segments.single.kind, SkipKind.outro);
    expect(segments.single.endMs, 650000);
    await unmount(tester);
  });

  testWidgets('seek异步：A到B再回A时首轮A迟到不能覆盖新轮A', (tester) async {
    final oldA = Completer<http.Response>();
    final queries = <int>[];
    final fixture = await _mountSegments(
      tester,
      skipResponse: (request) async {
        final episode =
            (jsonDecode(request.body) as Map)['episode_number'] as int;
        queries.add(episode);
        if (queries.length == 1) return oldA.future;
        return episode == 4
            ? _markers([('outro', 600, 650)])
            : _markers([('intro', 40, 60)]);
      },
    );
    final original = tester.widget<PlayerPage>(find.byType(PlayerPage)).request;
    await _replaceSkipRequest(
      tester,
      fixture.state,
      original.copyWith(
        url: 'https://fixture.test/B.mp4',
        episodeTarget: 'B',
        episodeName: 'E4',
        tmdb: const TmdbPlaybackIdentity(
          tmdbId: 1,
          mediaType: TmdbMediaType.tv,
          seasonNumber: 1,
          episodeNumber: 4,
        ),
      ),
      fixture.client,
    );
    await _replaceSkipRequest(tester, fixture.state, original, fixture.client);
    expect(queries, [3, 4, 3]);
    oldA.complete(_markers([('intro', 0, 80)]));
    await flush(tester);
    expect(
      tester
          .widget<PlayerProgressSlider>(find.byType(PlayerProgressSlider))
          .skipSegments
          .single
          .endMs,
      60000,
    );
    await unmount(tester);
  });

  testWidgets('seek时长：同媒体重开复用raw但按精化时长重新折算片尾', (tester) async {
    var queries = 0;
    final fixture = await _mountSegments(
      tester,
      configureMedia: (media) {
        media.initialPosition = 500;
        media.initialBuffered = const Duration(seconds: 20);
      },
      skipResponse: (request) async {
        queries++;
        return _markers([('intro', 10, 30), ('outro', 800, 850)]);
      },
    );
    fixture.media.initialDuration = const Duration(seconds: 1100);
    await _dragProgressTo(tester, 0.7);
    await flush(tester);
    expect(queries, 1);
    final segments = tester
        .widget<PlayerProgressSlider>(find.byType(PlayerProgressSlider))
        .skipSegments;
    expect(
      segments.singleWhere((segment) => segment.kind == SkipKind.outro).endMs,
      950000,
    );
    await unmount(tester);
  });

  testWidgets('seek异步：同集pending标定跨拖动重开只查一次且迟到结果仍归当前集', (tester) async {
    final pending = Completer<http.Response>();
    final queries = <Map<String, dynamic>>[];
    final fixture = await _mountSegments(
      tester,
      options: const PlayerOptions(
        skipMode: SkipMode.off,
        skipKinds: SkipKindBits.all,
        skipSources: SkipSourceBits.todb,
      ),
      configureMedia: (media) {
        media.initialPosition = 500;
        media.initialBuffered = const Duration(seconds: 20);
      },
      skipResponse: (request) {
        queries.add(jsonDecode(request.body) as Map<String, dynamic>);
        return pending.future;
      },
    );
    expect(queries, hasLength(1));
    expect(fixture.requests, hasLength(1));
    await _dragProgressTo(tester, 0.75);
    await flush(tester);
    expect(queries, hasLength(1), reason: '相同媒体重开不另发无界标定请求');
    pending.complete(_markers([('intro', 10, 30), ('outro', 800, 850)]));
    await _waitForLifecycleEvent(
      tester,
      () =>
          tester
              .widget<PlayerProgressSlider>(find.byType(PlayerProgressSlider))
              .skipSegments
              .length ==
          2,
      stage: '同集待查结果应用重开后当前时长',
      diagnostics: () => 'queries=${queries.length}',
    );
    expect(
      tester
          .widget<PlayerProgressSlider>(find.byType(PlayerProgressSlider))
          .skipSegments
          .map((s) => s.kind),
      [SkipKind.intro, SkipKind.outro],
    );
    await unmount(tester);
  });

  testWidgets('seek异步：A待查后切B，旧A迟到不能覆盖B片段', (tester) async {
    final a = Completer<http.Response>();
    final b = Completer<http.Response>();
    final queries = <int>[];
    final fixture = await _mountSegments(
      tester,
      skipResponse: (request) {
        final episode =
            (jsonDecode(request.body) as Map)['episode_number'] as int;
        queries.add(episode);
        return episode == 3 ? a.future : b.future;
      },
    );
    final original = tester.widget<PlayerPage>(find.byType(PlayerPage)).request;
    await _replaceSkipRequest(
      tester,
      fixture.state,
      original.copyWith(
        url: 'https://fixture.test/B.mp4',
        episodeTarget: 'https://fixture.test/B.mp4',
        episodeName: 'E4',
        tmdb: const TmdbPlaybackIdentity(
          tmdbId: 1,
          mediaType: TmdbMediaType.tv,
          seasonNumber: 1,
          episodeNumber: 4,
        ),
      ),
      fixture.client,
    );
    expect(queries, [3, 4]);
    b.complete(_markers([('outro', 600, 650)]));
    await _waitForLifecycleEvent(
      tester,
      () => tester
          .widget<PlayerProgressSlider>(find.byType(PlayerProgressSlider))
          .skipSegments
          .isNotEmpty,
      stage: 'B标定已应用',
      diagnostics: () => 'queries=$queries',
    );
    a.complete(_markers([('intro', 0, 80)]));
    await flush(tester);
    final segments = tester
        .widget<PlayerProgressSlider>(find.byType(PlayerProgressSlider))
        .skipSegments;
    expect(segments.single.kind, SkipKind.outro, reason: '旧A结果不得污染当前B');
    expect(segments.single.endMs, 650000);
    await unmount(tester);
  });

  testWidgets('seek保护：已自动处理片头后拖到后段再跨buffer回拖不重复跳片头', (tester) async {
    final fixture = await _mountSegments(
      tester,
      options: const PlayerOptions(
        skipMode: SkipMode.auto,
        skipKinds: SkipKindBits.intro,
        skipSources: SkipSourceBits.todb,
      ),
      configureMedia: (media) {
        media.initialPosition = 11;
      },
    );
    expect(fixture.media.seeks, [const Duration(seconds: 30)]);
    fixture.media.emit(
      position: 500,
      buffered: const Duration(seconds: 20),
      playing: true,
    );
    await flush(tester);
    await _dragProgressTo(tester, 0.75);
    await flush(tester);
    fixture.media.emit(buffered: const Duration(seconds: 1), playing: true);
    await tester.pump();
    await _dragProgressTo(tester, 0.02);
    await flush(tester);
    fixture.media.emit(position: 11, playing: true);
    await flush(tester);
    expect(
      tester
          .widget<PlayerProgressSlider>(find.byType(PlayerProgressSlider))
          .skipSegments,
      hasLength(9),
    );
    expect(fixture.media.seeks, [const Duration(seconds: 30)]);
    expect(
      fixture.state.log.entries.where(
        (entry) => entry.message.startsWith('跳过片头 '),
      ),
      hasLength(1),
    );
    await unmount(tester);
  });

  testWidgets('seek标记：真实拖动跨buffer重开后九段仍在且片尾自然触发auto一次', (tester) async {
    final fixture = await _mountSegments(
      tester,
      options: const PlayerOptions(
        skipMode: SkipMode.auto,
        skipKinds: SkipKindBits.all,
        skipSources: SkipSourceBits.todb,
      ),
      configureMedia: (media) {
        media.initialPosition = 500;
        media.initialBuffered = const Duration(seconds: 20);
      },
    );
    PlayerProgressSlider progress() =>
        tester.widget<PlayerProgressSlider>(find.byType(PlayerProgressSlider));
    expect(progress().skipSegments, hasLength(9));
    expect(fixture.requests, hasLength(1));
    expect(
      (jsonDecode(fixture.requests.single.body) as Map)['platform_value'],
      '1',
    );
    expect(
      (jsonDecode(fixture.requests.single.body) as Map)['episode_number'],
      3,
    );
    await _dragProgressTo(tester, 0.75);
    await _waitForLifecycleEvent(
      tester,
      () => fixture.media.openedStarts.length == 2,
      stage: '拖动实际进入安全重开open',
      diagnostics: () => 'opens=${fixture.media.openedStarts}',
    );
    await flush(tester);
    expect(
      fixture.media.openedStarts.last!.inSeconds,
      inInclusiveRange(720, 780),
    );
    expect(fixture.media.seeks, isEmpty);
    debugRevealPlayerControls(
      tester.state<State<PlayerPage>>(find.byType(PlayerPage)),
    );
    await tester.pump();
    expect(progress().skipSegments, hasLength(9), reason: '同集拖动后不能清空已识别段');
    expect(
      progress().skipSegments.any((segment) => segment.kind == SkipKind.outro),
      isTrue,
    );
    fixture.media.emit(position: 805, playing: true);
    await flush(tester);
    expect(fixture.media.openedStarts, hasLength(3));
    expect(fixture.media.openedStarts.last, const Duration(seconds: 850));
    expect(fixture.media.seeks, isEmpty);
    expect(
      fixture.state.log.entries.where(
        (entry) => entry.message.startsWith('跳过片尾 '),
      ),
      hasLength(1),
    );
    fixture.media.emit(position: 806, playing: true);
    await flush(tester);
    expect(fixture.media.openedStarts, hasLength(3));
    expect(fixture.requests, hasLength(1), reason: '拖动与自动片尾均只重开当前媒体，不重复标定');
    // ignore: avoid_print
    print(
      'seek-markers evidence: opens=${fixture.media.openedStarts}; '
      'seeks=${fixture.media.seeks}; queries=${fixture.requests.length}; '
      'queryBody=${fixture.requests.single.body}; segments=${progress().skipSegments.length}',
    );
    await unmount(tester);
  });

  testWidgets('auto生命周期：旧字幕pending时跨buffer重开，旧返回不能清空新karaoke轨', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 0.65;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final oldSubtitle = Completer<void>();
    final danmaku = _GatedDanmaku();
    danmaku.ready.complete();
    addTearDown(() {
      if (!oldSubtitle.isCompleted) oldSubtitle.complete();
    });
    final fixture = await _mountSegments(
      tester,
      options: const PlayerOptions(
        skipMode: SkipMode.off,
        skipKinds: SkipKindBits.all,
        skipSources: SkipSourceBits.todb,
      ),
      subtitleReady: oldSubtitle.future,
      danmakuLoader: danmaku,
      configureMedia: (media) {
        media.initialPosition = 11;
        media.initialBuffered = const Duration(seconds: 20);
      },
    );
    String diagnostics() =>
        'oldReady=${oldSubtitle.isCompleted}; '
        'subtitleRequested=${fixture.media.subtitleRequested.isCompleted}; '
        'opens=${fixture.media.openedStarts}; danmakuCalls=${danmaku.calls}; '
        'subtitleLogs=${fixture.state.log.entries.where((entry) => entry.scope == 'subtitle').map((entry) => entry.message).join(' | ')}';
    await _waitForLifecycleEvent(
      tester,
      () => fixture.media.subtitleRequested.isCompleted,
      stage: '旧代字幕已读本地文件并进入native轨道gate',
      diagnostics: diagnostics,
    );
    expect(oldSubtitle.isCompleted, isFalse);
    debugRevealPlayerControls(
      tester.state<State<PlayerPage>>(find.byType(PlayerPage)),
    );
    await tester.pump();
    await tester.runAsync(
      () => tester.tap(find.byKey(const ValueKey('player-audio-ai'))),
    );
    await _waitForLifecycleEvent(
      tester,
      () => find.byType(PlayerAudioAiPanel).evaluate().isNotEmpty,
      stage: '真实音频AI面板session创建完成',
      diagnostics: diagnostics,
    );
    expect(find.byType(PlayerAudioAiPanel), findsOneWidget);
    final session = tester
        .widget<PlayerAudioAiPanel>(find.byType(PlayerAudioAiPanel))
        .session;
    fixture.media.subtitleReady = null;
    await openSkipMenu(tester);
    await tapRow(tester, 'skip_mode');
    await tester.runAsync(() => tester.tap(row('skip_mode_auto')));
    await flush(tester);
    expect(fixture.media.openedStarts, [null, const Duration(seconds: 30)]);
    expect(fixture.media.seeks, isEmpty);
    await _waitForLifecycleEvent(
      tester,
      () => danmaku.requested.isCompleted,
      stage: '新代本地字幕与karaoke仓库bind已完成，进入弹幕callback',
      diagnostics: diagnostics,
    );
    expect(danmaku.calls, 1);
    final selected = KaraokeTrack(
      title: '新媒体已选评分轨',
      notes: const [KaraokeNote(startMs: 30000, endMs: 31000, pitch: 60)],
    );
    session.karaoke.selectTrack(selected);
    expect(session.karaoke.track, same(selected));
    oldSubtitle.complete();
    await _waitForLifecycleEvent(
      tester,
      () =>
          fixture.state.log.entries
              .where(
                (entry) =>
                    entry.scope == 'subtitle' &&
                    entry.message.startsWith('默认字幕已启用'),
              )
              .length >=
          2,
      stage: '放行旧gate后旧代字幕装配实际返回',
      diagnostics: diagnostics,
    );
    expect(danmaku.calls, 1, reason: '旧代字幕完成不得继续下游辅助初始化');
    expect(
      session.karaoke.track,
      same(selected),
      reason: '旧_load字幕返回后不得重绑共享的新媒体karaoke并清轨',
    );
    await unmount(tester);
  });

  testWidgets('auto时序：标定先到、时长后到时从11秒自然命中片头', (tester) async {
    final fixture = await _mountSegments(
      tester,
      options: const PlayerOptions(
        skipMode: SkipMode.auto,
        skipKinds: SkipKindBits.all,
        skipSources: SkipSourceBits.todb,
      ),
      configureMedia: (media) {
        media.initialDuration = Duration.zero;
        media.initialPosition = 11;
      },
    );
    expect(fixture.media.seeks, isEmpty);
    expect(
      fixture.state.log.entries.any(
        (entry) => entry.message.startsWith('片头片尾标定 '),
      ),
      isTrue,
    );
    fixture.media.emit(
      duration: const Duration(milliseconds: 2755080),
      position: 11,
      playing: true,
    );
    await flush(tester);
    expect(fixture.media.seeks, [const Duration(seconds: 30)]);
    fixture.media.progress(12);
    await flush(tester);
    expect(fixture.media.seeks, hasLength(1));
    await unmount(tester);
  });

  testWidgets('auto字幕：默认字幕仍未完成时视频已播放也能自动跳片头', (tester) async {
    final ready = Completer<void>();
    addTearDown(() {
      if (!ready.isCompleted) ready.complete();
    });
    final fixture = await _mountSegments(
      tester,
      options: const PlayerOptions(
        skipMode: SkipMode.auto,
        skipKinds: SkipKindBits.all,
        skipSources: SkipSourceBits.todb,
      ),
      subtitleReady: ready.future,
      configureMedia: (media) => media.initialPosition = 11,
    );
    for (
      var round = 0;
      round < 10 && !fixture.media.subtitleRequested.isCompleted;
      round++
    ) {
      await flush(tester);
    }
    expect(fixture.media.subtitleRequested.isCompleted, isTrue);
    expect(ready.isCompleted, isFalse);
    expect(fixture.media.state.playing, isTrue);
    expect(fixture.media.seeks, [const Duration(seconds: 30)]);
    ready.complete();
    await flush(tester);
    expect(fixture.media.seeks, hasLength(1));
    await unmount(tester);
  });

  testWidgets('auto安全通道：片头落点超过buffer时重开并在open定位而不裸seek', (tester) async {
    final fixture = await _mountSegments(
      tester,
      options: const PlayerOptions(
        skipMode: SkipMode.auto,
        skipKinds: SkipKindBits.all,
        skipSources: SkipSourceBits.todb,
      ),
      configureMedia: (media) {
        media.initialPosition = 11;
        media.initialBuffered = const Duration(seconds: 20);
      },
    );
    await flush(tester);
    expect(fixture.media.seeks, isEmpty);
    expect(fixture.media.openedStarts, [null, const Duration(seconds: 30)]);
    expect(fixture.media.stops, 1);
    expect(
      fixture.state.log.entries.where(
        (entry) => entry.message.startsWith('跳过片头 '),
      ),
      hasLength(1),
    );
    expect(
      fixture.state.log.entries.any(
        (entry) => entry.message.startsWith('跨缓冲跳转：'),
      ),
      isTrue,
    );
    await unmount(tester);
  });

  testWidgets('auto直播：有效时长与片头标记也不能自动跳过直播', (tester) async {
    final fixture = live_fixture.fixture();
    await tester.runAsync(() async {
      await fixture.state.bootstrap();
      await fixture.state.setPlayerOptions(
        const PlayerOptions(
          skipMode: SkipMode.auto,
          skipKinds: SkipKindBits.all,
        ),
      );
      await fixture.state.saveSkipSegments(
        siteKey: fixture.session.request.siteKey,
        vodId: fixture.session.request.vodId,
        introEndMs: 30000,
      );
    });
    final media = await _mount(
      tester,
      PlayerPage(
        state: fixture.state,
        request: fixture.session.request,
        liveSession: fixture.session,
      ),
      configureMedia: (media) => media.initialPosition = 11,
    );
    media.progress(11);
    await flush(tester);
    expect(media.seeks, isEmpty);
    await unmount(tester);
  });

  testWidgets('auto保护：off全类型开启仍不自动跳过', (tester) async {
    final fixture = await _mountSegments(
      tester,
      options: const PlayerOptions(
        skipMode: SkipMode.off,
        skipKinds: SkipKindBits.all,
        skipSources: SkipSourceBits.todb,
      ),
      configureMedia: (media) => media.initialPosition = 11,
    );
    fixture.media.progress(12);
    await flush(tester);
    expect(fixture.media.seeks, isEmpty);
    expect(find.text('跳过片头？'), findsNothing);
    expect(fixture.state.playerOptions.skipMode, SkipMode.off);
    await unmount(tester);
  });

  for (final action in ['不跳', '跳过', '关闭确认']) {
    final accept = action == '跳过';
    testWidgets('auto保护：confirm先询问不静默，$action后只处理一次', (tester) async {
      final fixture = await _mountSegments(
        tester,
        options: const PlayerOptions(
          skipMode: SkipMode.confirm,
          skipKinds: SkipKindBits.intro,
          skipSources: SkipSourceBits.todb,
        ),
        configureMedia: (media) => media.initialPosition = 11,
      );
      expect(fixture.media.seeks, isEmpty);
      expect(find.text('跳过片头？'), findsOneWidget);
      await tester.tap(
        action == '关闭确认' ? find.byTooltip(action) : find.text(action),
      );
      await flush(tester);
      expect(
        fixture.media.seeks,
        accept ? [const Duration(seconds: 30)] : isEmpty,
      );
      fixture.media.progress(11);
      await flush(tester);
      expect(find.text('跳过片头？'), findsNothing);
      expect(fixture.media.seeks, accept ? hasLength(1) : isEmpty);
      expect(fixture.state.playerOptions.skipMode, SkipMode.confirm);
      await unmount(tester);
    });
  }

  testWidgets('auto保护：已处理片头回拖后不重复跳', (tester) async {
    final fixture = await _mountSegments(
      tester,
      options: const PlayerOptions(
        skipMode: SkipMode.auto,
        skipKinds: SkipKindBits.intro,
        skipSources: SkipSourceBits.todb,
      ),
      configureMedia: (media) => media.initialPosition = 11,
    );
    expect(fixture.media.seeks, [const Duration(seconds: 30)]);
    fixture.media.progress(11);
    await flush(tester);
    fixture.media.progress(12);
    await flush(tester);
    expect(fixture.media.seeks, [const Duration(seconds: 30)]);
    expect(
      fixture.state.log.entries.where(
        (entry) => entry.message.startsWith('跳过片头 '),
      ),
      hasLength(1),
    );
    await unmount(tester);
  });

  testWidgets('auto保护：续播已越过片头，之后回拖不能强拉回', (tester) async {
    final fixture = await _mountSegments(
      tester,
      options: const PlayerOptions(
        skipMode: SkipMode.auto,
        skipKinds: SkipKindBits.all,
        skipSources: SkipSourceBits.todb,
      ),
      startPosition: const Duration(seconds: 40),
    );
    expect(fixture.media.openedStarts.first, const Duration(seconds: 40));
    expect(fixture.media.seeks, isEmpty);
    fixture.media.progress(11);
    await flush(tester);
    expect(fixture.media.seeks, isEmpty);
    await unmount(tester);
  });

  testWidgets('auto保护：单集循环重播后不再次跳片头', (tester) async {
    final fixture = await _mountSegments(
      tester,
      options: const PlayerOptions(
        skipMode: SkipMode.auto,
        skipKinds: SkipKindBits.intro,
        skipSources: SkipSourceBits.todb,
      ),
      configureMedia: (media) => media.initialPosition = 11,
      playLines: [
        VodPlayLine(
          flag: '线路一',
          episodes: [
            VodEpisode(name: 'E3', url: 'https://fixture.test/skip.mp4'),
          ],
        ),
      ],
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await flush(tester);
    await tapRow(tester, 'section:播放');
    await tapRow(tester, 'playback_mode');
    final single = find.text('单集循环');
    await tester.ensureVisible(single);
    await tester.tap(single);
    await flush(tester);
    for (final position in [997, 998, 999]) {
      fixture.media.emit(position: position, playing: true, completed: false);
      await tester.pump(const Duration(seconds: 1));
    }
    fixture.media.emit(position: 1000, playing: false, completed: true);
    await flush(tester);
    expect(fixture.media.seeks, [const Duration(seconds: 30), Duration.zero]);
    fixture.media.progress(11);
    await flush(tester);
    expect(fixture.media.seeks, hasLength(2));
    await unmount(tester);
  });

  testWidgets('auto对照：标定晚到片头内也执行一次真实seek', (tester) async {
    final segmentsReady = Completer<void>();
    final fixture = await _mountSegments(
      tester,
      segmentsReady: segmentsReady.future,
      options: const PlayerOptions(
        skipMode: SkipMode.auto,
        skipKinds: SkipKindBits.all,
        skipSources: SkipSourceBits.todb,
      ),
    );
    fixture.media.progress(11);
    await flush(tester);
    expect(fixture.media.seeks, isEmpty);
    segmentsReady.complete();
    await flush(tester);
    expect(fixture.media.seeks, [const Duration(seconds: 30)]);
    expect(
      fixture.state.log.entries.where(
        (entry) => entry.message.startsWith('跳过片头 '),
      ),
      hasLength(1),
    );
    await unmount(tester);
  });

  testWidgets('auto类型：片头内开启片头类型并升auto时立即跳段', (tester) async {
    final fixture = await _mountSegments(
      tester,
      options: const PlayerOptions(
        skipMode: SkipMode.off,
        skipKinds: SkipKindBits.none,
        skipSources: SkipSourceBits.todb,
      ),
      configureMedia: (media) => media.initialPosition = 11,
    );
    await fixture.media.pause();
    await flush(tester);
    await openSkipMenu(tester);
    await tapRow(tester, 'skip_kinds');
    await tester.runAsync(() => tester.tap(row('skip_kind_intro')));
    await flush(tester);
    expect(fixture.state.playerOptions.skipMode, SkipMode.auto);
    expect(fixture.state.playerOptions.skipKinds, SkipKindBits.intro);
    expect(fixture.media.seeks, [const Duration(seconds: 30)]);
    await unmount(tester);
  });

  testWidgets('auto菜单：片头内暂停时开启auto立即判定，无需等下一位置事件', (tester) async {
    final fixture = await _mountSegments(
      tester,
      options: const PlayerOptions(
        skipMode: SkipMode.off,
        skipKinds: SkipKindBits.all,
        skipSources: SkipSourceBits.todb,
      ),
    );
    fixture.media.progress(11);
    await flush(tester);
    await fixture.media.pause();
    await flush(tester);
    expect(fixture.media.state.playing, isFalse);
    await openSkipMenu(tester);
    await tapRow(tester, 'skip_mode');
    await tester.runAsync(() => tester.tap(row('skip_mode_auto')));
    await flush(tester);
    expect(fixture.state.playerOptions.skipMode, SkipMode.auto);
    expect(fixture.media.seeks, [const Duration(seconds: 30)]);
    await unmount(tester);
  });

  testWidgets('auto症状：7类全开且片头已高亮，弹幕仍加载也应在11秒自动跳段', (tester) async {
    final danmaku = _GatedDanmaku();
    addTearDown(() {
      if (!danmaku.ready.isCompleted) danmaku.ready.complete();
    });
    final fixture = await _mountSegments(
      tester,
      options: const PlayerOptions(
        skipMode: SkipMode.auto,
        skipKinds: SkipKindBits.all,
        skipSources: SkipSourceBits.todb,
      ),
      danmakuLoader: danmaku,
      configureMedia: (media) => media.initialPosition = 11,
    );
    expect(danmaku.requested.isCompleted, isTrue);
    expect(danmaku.ready.isCompleted, isFalse);
    fixture.media.progress(11);
    await flush(tester);
    debugRevealPlayerControls(
      tester.state<State<PlayerPage>>(find.byType(PlayerPage)),
    );
    await tester.pump();
    expect(
      tester
          .widget<PlayerProgressSlider>(find.byType(PlayerProgressSlider))
          .skipSegments
          .any((segment) => segment.kind == SkipKind.intro),
      isTrue,
    );
    expect(fixture.media.state.playing, isTrue);
    expect(fixture.media.seeks, [
      const Duration(seconds: 30),
    ], reason: '视频已在片头内自然播放，不能等待弹幕加载才允许auto');
    expect(
      fixture.state.log.entries.where(
        (entry) => entry.message.startsWith('跳过片头 '),
      ),
      hasLength(1),
    );
    await unmount(tester);
  });

  testWidgets('跳过片段提供模式真实选中态与七类类型，变更保存且保持菜单', (tester) async {
    late AppState state;
    await pumpPlayerPage(tester, onStateReady: (ready) async => state = ready);
    await openSkipMenu(tester);
    expect(find.text('片头片尾'), findsNothing);
    await tapRow(tester, 'skip_mode');
    for (final mode in SkipMode.values) {
      expect(
        item(tester, 'skip_mode_${mode.name}').selected,
        mode == SkipMode.off,
      );
    }
    await tester.runAsync(() => tester.tap(row('skip_mode_confirm')));
    await flush(tester);
    expect(state.playerOptions.skipMode, SkipMode.confirm);
    expect(item(tester, 'skip_mode_confirm').selected, isTrue);
    expect(find.byType(PlayerContextMenu), findsOneWidget);
    await tapRow(tester, 'skip_kinds');
    for (final kind in SkipKind.values) {
      final candidate = item(tester, 'skip_kind_${kind.name}');
      expect(candidate.label, kind.label);
      expect(candidate.selected, (SkipKindBits.defaults & kind.bit) != 0);
    }
    await tester.runAsync(() => tester.tap(row('skip_kind_advertisement')));
    await flush(tester);
    expect(
      state.playerOptions.skipKinds,
      SkipKindBits.defaults | SkipKindBits.advertisement,
    );
    expect(state.playerOptions.skipMode, SkipMode.confirm);
    expect(item(tester, 'skip_kind_advertisement').selected, isTrue);
    await tapRow(tester, 'skip_mode');
    await tester.runAsync(() => tester.tap(row('skip_mode_off')));
    await flush(tester);
    await tapRow(tester, 'skip_kinds');
    await tester.ensureVisible(row('skip_kind_intermission'));
    await tester.runAsync(() => tester.tap(row('skip_kind_intermission')));
    await flush(tester);
    expect(state.playerOptions.skipMode, SkipMode.auto);
    expect(
      state.playerOptions.skipKinds,
      SkipKindBits.defaults |
          SkipKindBits.advertisement |
          SkipKindBits.intermission,
    );
    await tester.runAsync(() async {
      final stored = jsonDecode(
        await File(state.paths.settingsPath).readAsString(),
      ) as Map<String, dynamic>;
      final saved = PlayerOptions.fromJson(stored['player']);
      expect(saved.skipMode, state.playerOptions.skipMode);
      expect(saved.skipKinds, state.playerOptions.skipKinds);
    });
    await unmount(tester);
  });

  testWidgets('七类开关逐项翻转只改对应位并落盘，关闭模式关类型不升auto', (tester) async {
    late AppState state;
    await pumpPlayerPage(tester, onStateReady: (ready) async => state = ready);
    await openSkipMenu(tester);
    await tapRow(tester, 'skip_kinds');
    var expected = SkipKindBits.defaults;
    for (final kind in SkipKind.values) {
      final target = row('skip_kind_${kind.name}');
      await tester.ensureVisible(target);
      await tester.runAsync(() => tester.tap(target));
      await flush(tester);
      expected ^= kind.bit;
      expect(state.playerOptions.skipKinds, expected);
      expect(
        item(tester, 'skip_kind_${kind.name}').selected,
        (expected & kind.bit) != 0,
      );
      if (kind == SkipKind.recap) {
        expect(state.playerOptions.skipMode, SkipMode.off);
      }
      await tester.runAsync(() async {
        final saved = PlayerOptions.fromJson(
          (jsonDecode(await File(state.paths.settingsPath).readAsString())
              as Map)['player'],
        );
        expect(saved.skipKinds, expected);
      });
    }
    await unmount(tester);
  });

  testWidgets('无片段时七类立即跳过灰而不藏，标记入口保留，颜色进入既有设置页', (tester) async {
    await pumpPlayerPage(tester);
    await openSkipMenu(tester);
    expect(item(tester, 'mark_intro').enabled, isTrue);
    expect(item(tester, 'mark_outro').enabled, isTrue);
    expect(item(tester, 'clear_skip').enabled, isFalse);
    await tapRow(tester, 'skip_now');
    for (final kind in SkipKind.values) {
      expect(item(tester, 'skip_${kind.name}').enabled, isFalse);
      expect(tester.widget<InkWell>(row('skip_${kind.name}')).onTap, isNull);
    }
    await tapRow(tester, 'skip_colors');
    expect(find.byType(IntroSkipOptionsPage), findsOneWidget);
    expect(find.byType(PlayerContextMenu), findsNothing);
    await unmount(tester);
  });

  testWidgets('片内多段跳过当前命中或下一未结束段，结束后禁用且不倒退', (tester) async {
    final fixture = await _mountSegments(tester);
    for (final (kind, positions, targets) in [
      (SkipKind.advertisement, [105, 150, 225], [120, 220, 225]),
      (SkipKind.intermission, [305, 350, 425], [320, 420, 425]),
    ]) {
      for (var index = 0; index < positions.length; index++) {
        fixture.media.progress(positions[index]);
        await flush(tester);
        await openSkipMenu(tester);
        await tapRow(tester, 'skip_now');
        expect(item(tester, 'skip_${kind.name}').enabled, index < 2);
        if (index < 2) {
          await tapRow(tester, 'skip_${kind.name}');
        } else {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await flush(tester);
        }
        expect(fixture.media.state.position.inSeconds, targets[index]);
      }
    }
    expect(fixture.state.playerOptions.skipMode, SkipMode.off);
    expect(fixture.state.playerOptions.skipKinds, SkipKindBits.none);
    await unmount(tester);
  });

  testWidgets('片头片尾标记和清除仍写同一影片，清除后保留远端段', (tester) async {
    final fixture = await _mountSegments(tester);
    fixture.media.progress(50);
    await flush(tester);
    await openSkipMenu(tester);
    await tapRow(tester, 'mark_intro');
    await openSkipMenu(tester);
    fixture.media.progress(900);
    await flush(tester);
    await tapRow(tester, 'mark_outro');
    final manual = fixture.state.skipSegmentsFor(
      siteKey: 'fixture',
      vodId: 'skip',
    );
    expect(manual.introEndMs, 50000);
    expect(manual.outroStartMs, 900000);
    await openSkipMenu(tester);
    expect(item(tester, 'clear_skip').enabled, isTrue);
    await tapRow(tester, 'clear_skip');
    expect(
      fixture.state.skipSegmentsFor(siteKey: 'fixture', vodId: 'skip').isEmpty,
      isTrue,
    );
    debugRevealPlayerControls(
      tester.state<State<PlayerPage>>(find.byType(PlayerPage)),
    );
    await tester.pump();
    final slider = tester.widget<PlayerProgressSlider>(
      find.byType(PlayerProgressSlider),
    );
    expect(slider.skipSegments, hasLength(9));
    expect(slider.skipSegments.any((segment) => segment.isManual), isFalse);
    await unmount(tester);
  });

  testWidgets('时长未知时保留片段菜单但禁用所有立即跳过与快捷键', (tester) async {
    final fixture = await _mountSegments(tester);
    // 复用假内核的真实事件流，模拟引擎撤回时长。
    // ignore: invalid_use_of_protected_member
    fixture.media.original.durationController.add(Duration.zero);
    await flush(tester);
    await openSkipMenu(tester);
    await tapRow(tester, 'skip_now');
    for (final kind in SkipKind.values) {
      expect(item(tester, 'skip_${kind.name}').enabled, isFalse);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await flush(tester);
    await altKey(tester, LogicalKeyboardKey.bracketLeft);
    expect(fixture.media.state.position.inSeconds, 1);
    await unmount(tester);
  });

  testWidgets('七类立即跳过均到对应段末，不受关闭模式或空mask限制', (tester) async {
    final fixture = await _mountSegments(tester);
    for (final (kind, target) in [
      (SkipKind.recap, 10),
      (SkipKind.intro, 30),
      (SkipKind.outro, 850),
      (SkipKind.preview, 890),
      (SkipKind.postCredits, 930),
      (SkipKind.advertisement, 120),
      (SkipKind.intermission, 320),
    ]) {
      fixture.media.progress(1);
      await flush(tester);
      await openSkipMenu(tester);
      await tapRow(tester, 'skip_now');
      await tapRow(tester, 'skip_${kind.name}');
      expect(fixture.media.state.position.inSeconds, target);
    }
    await unmount(tester);
  });

  testWidgets('暂停时远端段到达即刷新进度条，不等待下一次播放位置或时钟', (tester) async {
    final ready = Completer<void>();
    final fixture = await _mountSegments(tester, segmentsReady: ready.future);
    await fixture.media.pause();
    expect(fixture.media.state.playing, isFalse);
    debugRevealPlayerControls(
      tester.state<State<PlayerPage>>(find.byType(PlayerPage)),
    );
    await tester.pump();
    PlayerProgressSlider slider() =>
        tester.widget<PlayerProgressSlider>(find.byType(PlayerProgressSlider));
    expect(slider().skipSegments, isEmpty);
    final player = tester.widget<Video>(find.byType(Video)).controller.player;
    expect(player.state.playing, isFalse);
    expect(find.byTooltip('播放（空格）'), findsOneWidget);
    final positionEvents = <Duration>[];
    final positionBefore = player.state.position;
    final subscription = player.stream.position.listen(positionEvents.add);
    addTearDown(subscription.cancel);
    ready.complete();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(slider().skipSegments, hasLength(9));
    expect(fixture.media.state.playing, isFalse);
    expect(player.state.playing, isFalse);
    expect(player.state.position, positionBefore);
    expect(positionEvents, isEmpty);
    expect(find.byTooltip('播放（空格）'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('七类识别段全传进度条且不按mask过滤，旧快捷键跳段末不倒退', (tester) async {
    final fixture = await _mountSegments(tester);
    debugRevealPlayerControls(
      tester.state<State<PlayerPage>>(find.byType(PlayerPage)),
    );
    await tester.pump();
    final slider = tester.widget<PlayerProgressSlider>(
      find.byType(PlayerProgressSlider),
    );
    expect(slider.skipSegments.length, 9);
    expect(
      slider.skipSegments.map((segment) => segment.kind).toSet(),
      SkipKind.values.toSet(),
    );
    expect(
      slider.skipSegmentColors,
      fixture.state.playerOptions.skipSegmentColors,
    );
    await altKey(tester, LogicalKeyboardKey.bracketLeft);
    expect(fixture.media.state.position.inSeconds, 30);
    fixture.media.progress(40);
    await flush(tester);
    await altKey(tester, LogicalKeyboardKey.bracketLeft);
    expect(fixture.media.state.position.inSeconds, 40);
    await altKey(tester, LogicalKeyboardKey.bracketRight);
    expect(fixture.media.state.position.inSeconds, 850);
    await unmount(tester);
  });

  testWidgets('片段颜色设置返回后滑杆刷新，随后改模式不覆盖新颜色', (tester) async {
    late AppState state;
    await pumpPlayerPage(tester, onStateReady: (ready) async => state = ready);
    await openSkipMenu(tester);
    await tapRow(tester, 'skip_colors');
    expect(find.byType(IntroSkipOptionsPage), findsOneWidget);
    final colors = state.playerOptions.skipSegmentColors.withColor(
      SkipKind.intro,
      0xFF123456,
    );
    final colorRow = find.byKey(
      const ValueKey('settings-player-skip-color-intro'),
    );
    await tester.scrollUntilVisible(
      colorRow,
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(colorRow);
    await flush(tester);
    await tester.tap(colorRow);
    await flush(tester);
    await tester.enterText(
      find.byKey(const ValueKey('skip-color-input')),
      '#123456',
    );
    await tester.runAsync(
      () => tester.tap(find.byKey(const ValueKey('skip-color-save'))),
    );
    await flush(tester);
    expect(state.playerOptions.skipSegmentColors, colors);
    final context = tester.element(find.byType(IntroSkipOptionsPage));
    Navigator.of(context).pop();
    await flush(tester);
    debugRevealPlayerControls(
      tester.state<State<PlayerPage>>(find.byType(PlayerPage)),
    );
    await tester.pump();
    final slider = tester.widget<PlayerProgressSlider>(
      find.byType(PlayerProgressSlider),
    );
    expect(slider.skipSegmentColors, colors);
    await openSkipMenu(tester);
    await tapRow(tester, 'skip_mode');
    await tester.runAsync(() => tester.tap(row('skip_mode_confirm')));
    await flush(tester);
    expect(state.playerOptions.skipMode, SkipMode.confirm);
    expect(state.playerOptions.skipSegmentColors, colors);
    await tester.runAsync(() async {
      final saved = PlayerOptions.fromJson(
        (jsonDecode(await File(state.paths.settingsPath).readAsString())
            as Map)['player'],
      );
      expect(saved.skipMode, SkipMode.confirm);
      expect(saved.skipSegmentColors, colors);
    });
    await unmount(tester);
  });

  testWidgets('完整设置入口逐层返回刷新颜色，再改模式不覆盖新颜色', (tester) async {
    late AppState state;
    await pumpPlayerPage(tester, onStateReady: (ready) async => state = ready);
    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await flush(tester);
    await tapRow(tester, 'section:设置');
    await tapRow(tester, 'settings_overview_page');
    expect(find.byType(SettingsOverviewPage), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-category-playback')));
    await flush(tester);
    await tester.tap(
      find.byKey(const ValueKey('settings-player-options-open')),
    );
    await flush(tester);
    expect(find.byType(PlaybackOptionsPage), findsOneWidget);
    final entry = find.byKey(const ValueKey('settings-player-skip-open'));
    await tester.scrollUntilVisible(
      entry,
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(entry);
    await flush(tester);
    await tester.tap(entry);
    await flush(tester);
    expect(find.byType(IntroSkipOptionsPage), findsOneWidget);
    final colors = state.playerOptions.skipSegmentColors.withColor(
      SkipKind.intro,
      0xFF123456,
    );
    final colorRow = find.byKey(
      const ValueKey('settings-player-skip-color-intro'),
    );
    await tester.scrollUntilVisible(
      colorRow,
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(colorRow);
    await flush(tester);
    await tester.tap(colorRow);
    await flush(tester);
    await tester.enterText(
      find.byKey(const ValueKey('skip-color-input')),
      '#123456',
    );
    await tester.runAsync(
      () => tester.tap(find.byKey(const ValueKey('skip-color-save'))),
    );
    await flush(tester);
    expect(state.playerOptions.skipSegmentColors, colors);
    final context = tester.element(find.byType(IntroSkipOptionsPage));
    Navigator.of(context).pop();
    await flush(tester);
    expect(find.byType(PlaybackOptionsPage), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await flush(tester);
    expect(find.byType(SettingsOverviewPage), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await flush(tester);
    debugRevealPlayerControls(
      tester.state<State<PlayerPage>>(find.byType(PlayerPage)),
    );
    await tester.pump();
    final slider = tester.widget<PlayerProgressSlider>(
      find.byType(PlayerProgressSlider),
    );
    expect(slider.skipSegmentColors, colors);
    await openSkipMenu(tester);
    await tapRow(tester, 'skip_mode');
    await tester.runAsync(() => tester.tap(row('skip_mode_confirm')));
    await flush(tester);
    expect(state.playerOptions.skipMode, SkipMode.confirm);
    expect(state.playerOptions.skipSegmentColors, colors);
    await tester.runAsync(() async {
      final saved = PlayerOptions.fromJson(
        (jsonDecode(await File(state.paths.settingsPath).readAsString())
            as Map)['player'],
      );
      expect(saved.skipMode, SkipMode.confirm);
      expect(saved.skipSegmentColors, colors);
    });
    await unmount(tester);
  });

  testWidgets('直播即使收到有限时长和手动段也不能跳过', (tester) async {
    final fixture = live_fixture.fixture();
    await tester.runAsync(() async {
      await fixture.state.bootstrap();
      await fixture.state.saveSkipSegments(
        siteKey: fixture.session.request.siteKey,
        vodId: fixture.session.request.vodId,
        introEndMs: 30000,
      );
    });
    final media = await _mount(
      tester,
      PlayerPage(
        state: fixture.state,
        request: fixture.session.request,
        liveSession: fixture.session,
      ),
    );
    await openSkipMenu(tester);
    await tapRow(tester, 'skip_now');
    for (final kind in SkipKind.values) {
      expect(item(tester, 'skip_${kind.name}').enabled, isFalse);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await flush(tester);
    await altKey(tester, LogicalKeyboardKey.bracketLeft);
    expect(media.state.position.inSeconds, 1);
    await unmount(tester);
  });
}
