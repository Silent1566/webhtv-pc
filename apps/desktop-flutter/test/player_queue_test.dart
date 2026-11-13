// ignore_for_file: invalid_use_of_protected_member
import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/services/spider_router.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/danmaku.dart';
import 'package:webhtv_pc/core/playback_queue.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/danmaku_service.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/danmaku_overlay.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/player_page_harness.dart';

const queueItems = [
  PlaybackQueueItem(key: 'opaque-file-A', title: '第01集 星空初遇.mkv'),
  PlaybackQueueItem(key: 'opaque-file-B', title: '第02集 月下重逢.mkv'),
  PlaybackQueueItem(key: 'opaque-file-C', title: '第03集 远方来信.mp4'),
];

PlaybackRequest fileRequest(
  int index, {
  bool assets = false,
  bool altLine = false,
}) {
  final letter = ['A', 'B', 'C'][index];
  return PlaybackRequest(
    url: 'https://media.test/resolved-$letter.m3u8',
    title: '星空旅程 · ${queueItems[index].title}',
    siteKey: 'folder-site',
    vodId: 'real-vod-$letter',
    vodName: '星空旅程',
    episodeName: queueItems[index].title,
    flag: '文件线路$letter',
    playbackFlag: 'backend-$letter',
    episodeTarget: 'real-target-$letter',
    sourceKey: 'original-config',
    headers: {'Referer': 'https://origin.test/$letter'},
    subtitleHeaders: {'Cookie': 'asset=$letter'},
    qualities: [
      PlaybackQuality(
        name: '高清$letter',
        url: 'https://candidate.test/$letter/0',
      ),
      PlaybackQuality(
        name: '原画$letter',
        url: 'https://candidate.test/$letter/1',
      ),
    ],
    subtitles: assets
        ? [
            SubtitleInfo(
              url: 'https://asset.test/$letter.srt',
              name: '字幕$letter',
              format: 'srt',
            ),
          ]
        : [],
    danmaku: assets
        ? [
            DanmakuSource(
              url: 'https://asset.test/$letter.xml',
              name: '弹幕$letter',
            ),
          ]
        : [],
    playLines: [
      if (altLine)
        VodPlayLine(
          flag: '备用线路$letter',
          sourceFlag: 'alt-backend-$letter',
          episodes: [
            VodEpisode(name: queueItems[index].title, url: 'real-alt-$letter'),
          ],
        ),
      VodPlayLine(
        flag: '文件线路$letter',
        sourceFlag: 'backend-$letter',
        episodes: [
          VodEpisode(name: queueItems[index].title, url: 'real-target-$letter'),
        ],
      ),
    ],
    episodeIndex: 0,
  );
}

class QueueFixture extends ChangeNotifier implements PlaybackQueue {
  QueueFixture({this.count = 2, this.hasMore = false, this.assets = false});
  int count;
  bool hasMore;
  bool assets;
  bool loading = false;
  bool pageFails = false;
  Future<PlaybackRequest> Function(String, bool Function()?)? resolveFile;
  String? failKey;
  AppError? error;
  int pageCalls = 0;
  final resolvedKeys = <String>[];
  final guards = <String, bool Function()?>{};
  final gates = <String, Completer<PlaybackRequest>>{};
  @override
  PlaybackQueueSnapshot get snapshot => PlaybackQueueSnapshot(
    items: queueItems.take(count).toList(),
    hasMore: hasMore,
    loading: loading,
    error: error,
  );
  @override
  Future<void> loadMore() async {
    pageCalls++;
    loading = true;
    error = null;
    notifyListeners();
    await Future<void>.value();
    if (pageFails) {
      error = AppError(AppErrorKind.unknown, '分页暂时失败');
    } else {
      count = 3;
      hasMore = false;
    }
    loading = false;
    notifyListeners();
  }

  @override
  Future<PlaybackRequest> resolve(
    String itemKey, {
    bool Function()? isCurrent,
  }) async {
    resolvedKeys.add(itemKey);
    guards[itemKey] = isCurrent;
    if (failKey == itemKey) throw AppError(AppErrorKind.unknown, '文件准备失败');
    if (resolveFile != null) return resolveFile!(itemKey, isCurrent);
    final gate = gates[itemKey];
    if (gate != null) return gate.future;
    return fileRequest(
      queueItems.indexWhere((item) => item.key == itemKey),
      assets: assets,
    );
  }
}

// Preserve native video-controller type checks while recording player I/O.
class QueueMediaIO implements NativePlayer {
  QueueMediaIO(this.original);
  final PlatformPlayer original;
  @override
  PlayerState state = const PlayerState();
  @override
  PlayerStream get stream => original.stream;
  @override
  PlayerConfiguration get configuration => original.configuration;
  @override
  List<Future<void> Function()> get release => original.release;
  @override
  Completer<void> get videoControllerCompleter =>
      original.videoControllerCompleter;
  @override
  bool get isVideoControllerAttached => original.isVideoControllerAttached;
  @override
  set isVideoControllerAttached(bool value) =>
      original.isVideoControllerAttached = value;
  final opened = <Media>[];
  final subtitles = <SubtitleTrack>[];
  bool failOpen = false;
  Completer<void>? nextOpen;
  Completer<void>? nextSubtitle;
  Completer<void>? subtitleUriGate;
  final subtitleUriStarted = Completer<void>();
  @override
  Future<int> get handle => original.handle;
  final properties = <String, String>{};
  @override
  Future<void> setProperty(
    String property,
    String value, {
    bool waitForInitialization = true,
  }) async {
    properties[property] = value;
  }
  @override
  Future<String> getProperty(
    String property, {
    bool waitForInitialization = true,
  }) async => properties[property] ?? '';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  void progress(
    int seconds, {
    int duration = 1000,
    bool completed = false,
    bool playing = true,
  }) {
    state = state.copyWith(
      position: Duration(seconds: seconds),
      duration: Duration(seconds: duration),
      playing: playing && !completed,
      completed: completed,
    );
    original.durationController.add(state.duration);
    original.positionController.add(state.position);
    original.playingController.add(state.playing);
    original.completedController.add(state.completed);
  }

  @override
  Future<void> open(
    Playable playable, {
    bool play = true,
    bool synchronized = true,
  }) async {
    opened.add(playable as Media);
    final gate = nextOpen;
    nextOpen = null;
    if (gate != null) await gate.future;
    if (failOpen) throw StateError('404 missing file');
    progress(1, playing: play);
  }

  @override
  Future<void> seek(Duration position, {bool synchronized = true}) async =>
      progress(position.inSeconds, playing: state.playing);
  @override
  Future<void> play({bool synchronized = true}) async =>
      progress(state.position.inSeconds);
  @override
  Future<void> pause({bool synchronized = true}) async =>
      progress(state.position.inSeconds, playing: false);
  @override
  Future<void> setVolume(double volume, {bool synchronized = true}) async {
    state = state.copyWith(volume: volume);
    original.volumeController.add(volume);
  }

  @override
  Future<void> setRate(double rate, {bool synchronized = true}) async {
    state = state.copyWith(rate: rate);
    original.rateController.add(rate);
  }

  @override
  Future<void> setSubtitleTrack(
    SubtitleTrack track, {
    bool synchronized = true,
  }) async {
    subtitles.add(track);
    if (track.uri && subtitleUriGate != null) {
      if (!subtitleUriStarted.isCompleted) subtitleUriStarted.complete();
      await subtitleUriGate!.future;
    }
    final gate = nextSubtitle;
    nextSubtitle = null;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> dispose({bool synchronized = true}) async {
    unawaited(original.dispose());
  }
}

class QueueState extends AppState {
  QueueState({required super.paths, required super.log});
  final targets =
      <
        ({
          String target,
          String? flag,
          String? vodId,
          String source,
          int? quality,
        })
      >[];
  final writes =
      <({String vodId, String target, String? source, int position})>[];
  Completer<PlaybackDecision?>? resolveGate;
  SiteService? realService;
  Site? realSite;
  PlaybackDecision decision(String target, int? quality) => PlaybackDecision(
    action: PlaybackAction.direct,
    url: 'https://proxy.test/$target/q${quality ?? 0}.m3u8',
    qualities: const [
      PlaybackQuality(name: '高清', url: 'https://candidate.test/0'),
      PlaybackQuality(name: '原画', url: 'https://candidate.test/1'),
    ],
    qualityIndex: quality ?? 0,
  );
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
    targets.add((
      target: episodeTarget,
      flag: flag,
      vodId: vodId,
      source: '',
      quality: qualityIndex,
    ));
    if (realService != null) {
      return super.resolvePlayback(
        episodeTarget: episodeTarget,
        flag: flag,
        vodId: vodId,
        qualityIndex: qualityIndex,
        isCurrent: isCurrent,
        preferredParseName: preferredParseName,
        serviceOverride: realService,
        siteOverride: realSite,
      );
    }
    final gate = resolveGate;
    resolveGate = null;
    return gate == null ? decision(episodeTarget, qualityIndex) : gate.future;
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
  }) async {
    targets.add((
      target: episodeTarget,
      flag: flag,
      vodId: vodId,
      source: sourceKey,
      quality: qualityIndex,
    ));
    if (realService != null) {
      return super.resolvePlayback(
        episodeTarget: episodeTarget,
        flag: flag,
        vodId: vodId,
        qualityIndex: qualityIndex,
        isCurrent: isCurrent,
        preferredParseName: preferredParseName,
        serviceOverride: realService,
        siteOverride: realSite,
      );
    }
    final gate = resolveGate;
    resolveGate = null;
    return gate == null ? decision(episodeTarget, qualityIndex) : gate.future;
  }

  @override
  void recordProgress({
    required Vod vod,
    required String flag,
    required String episodeName,
    required String episodeId,
    required Duration position,
    required Duration duration,
    String? siteKey,
    String? sourceKey,
    int tmdbId = 0,
    String mediaType = '',
  }) {
    writes.add((
      vodId: vod.vodId,
      target: episodeId,
      source: sourceKey,
      position: position.inMilliseconds,
    ));
    super.recordProgress(
      vod: vod,
      flag: flag,
      episodeName: episodeName,
      episodeId: episodeId,
      position: position,
      duration: duration,
      siteKey: siteKey,
      sourceKey: sourceKey,
      tmdbId: tmdbId,
      mediaType: mediaType,
    );
  }
}

class QueueDanmaku extends DanmakuLoader {
  Completer<DanmakuDocument>? gate;
  @override
  Future<DanmakuDocument> load(
    DanmakuSource source, {
    Map<String, String> headers = const {},
    bool useCache = true,
  }) async {
    if (gate != null) return gate!.future;
    return DanmakuDocument(
      items: [DanmakuItem(timeMs: 0, text: source.name)],
      format: 'xml',
      encoding: 'utf-8',
      sourceUrl: source.url,
      byteLength: 50,
      skipped: 0,
    );
  }
}

typedef MountedQueue = ({
  QueueState state,
  QueueMediaIO media,
  QueueFixture queue,
});
Future<MountedQueue> mountQueue(
  WidgetTester tester, {
  QueueFixture? queue,
  int current = 0,
  bool before = false,
  bool autoNext = true,
  GlobalKey? capture,
  DanmakuLoader? danmaku,
  PlaybackRequest? initialRequest,
  void Function(QueueMediaIO)? onMedia,
}) async {
  final folder = queue ?? QueueFixture();
  final temp = Directory.systemTemp.createTempSync('webhtv-player-queue');
  final state = QueueState(
    paths: AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/config',
        'data': '${temp.path}/data',
        'cache': '${temp.path}/cache',
        'state': '${temp.path}/logs',
      },
    ),
    log: LogService(),
  );
  addTearDown(() {
    state.dispose();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });
  await tester.runAsync(() async {
    await state.bootstrap();
    await state.setPlayerOptions(
      state.playerOptions.copyWith(autoNext: autoNext),
    );
  });
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  installMediaKitMocks(tester);
  installWindowManagerMocks(tester);
  QueueMediaIO? media;
  final attached = <Player>{};
  var active = true;
  addTearDown(() => active = false);
  tester.binding.addPersistentFrameCallback((_) {
    if (!active || find.byType(Video).evaluate().isEmpty) return;
    final player = tester.widget<Video>(find.byType(Video)).controller.player;
    if (!attached.add(player)) return;
    final io = QueueMediaIO(player.platform!);
    media ??= io;
    onMedia?.call(io);
    player.platform = io;
  });
  final page = Function.apply(PlayerPage.new, [], {
    #state: state,
    #request: initialRequest ?? fileRequest(current, assets: folder.assets),
    #danmakuLoader: danmaku,
    if (!before) #queue: folder,
    if (!before) #queueItemKey: queueItems[current].key,
  }) as PlayerPage;
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
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            textStyle: const TextStyle(fontFamily: 'FixtureCJK'),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            textStyle: const TextStyle(fontFamily: 'FixtureCJK'),
          ),
        ),
      ),
      builder: (_, child) => RepaintBoundary(key: capture, child: child!),
      home: page,
    ),
  );
  await settleQueue(tester);
  expect(tester.takeException(), isNull);
  return (state: state, media: media!, queue: folder);
}

Future<void> settleQueue(WidgetTester tester) async {
  await settlePlayerPage(tester, times: 2);
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

Future<void> selectQueueItem(WidgetTester tester, String key) async {
  await tester.tap(find.textContaining('选集（').first);
  await tester.pump(const Duration(milliseconds: 250));
  final card = find.byKey(ValueKey('player-queue-item-$key'));
  expect(card, findsOneWidget);
  await tester.ensureVisible(card);
  await tester.tap(card);
  await settleQueue(tester);
}

Future<void> setQueueRepeat(WidgetTester tester, String label) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.f10);
  await tester.pump();
  await tester.tap(find.text('播放').last);
  await tester.pump(const Duration(milliseconds: 250));
  await tester.tap(find.text('循环与定时…'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> closeQueue(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(Duration.zero);
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump(Duration.zero);
}

void main() {
  testWidgets('late A final subtitle URI completion cannot save candidate memory under B identity', (tester) async {
    final dir = Directory.systemTemp.createTempSync('queue-subtitle-native-final-');
    final subtitle = File('${dir.path}/old-A.srt')..writeAsStringSync('1\n00:00:01,000 --> 00:00:02,000\nA字幕内容\n');
    addTearDown(() { if (dir.existsSync()) dir.deleteSync(recursive: true); });
    final queue = QueueFixture();
    final native = Completer<void>();
    final media = <QueueMediaIO>[];
    final mounted = await mountQueue(tester, queue: queue, onMedia: (io) {
      if (media.isEmpty) io.subtitleUriGate = native;
      media.add(io);
    });
    await tester.tap(find.byTooltip('字幕轨')); await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.ensureVisible(find.text('选择本地字幕文件…'));
    await tester.tap(find.text('选择本地字幕文件…')); await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.enterText(find.byType(TextField), subtitle.path);
    await tester.tap(find.text('加载')); await tester.pump();
    expect(tester.takeException(), isNull);
    for (var i = 0; i < 100 && !media.first.subtitleUriStarted.isCompleted; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(
      media.first.subtitleUriStarted.isCompleted,
      isTrue,
      reason: 'local subtitle file I/O must reach the final native URI gate',
    );
    expect(media.first.subtitles.last.uri, isTrue, reason: 'gate must be final native URI application, not download/off');
    final next = Completer<PlaybackRequest>(); queue.gates['opaque-file-B'] = next;
    await selectQueueItem(tester, 'opaque-file-B');
    next.complete(fileRequest(1)); await settleQueue(tester);
    final current = media.last;
    expect(media.length, 2);
    expect(current.opened.single.uri, 'https://media.test/resolved-B.m3u8');
    expect(mounted.state.subtitleMatchFor(siteKey: 'folder-site', vodId: 'real-vod-B', episodeName: queueItems[1].title), isNull);
    native.complete(); await settleQueue(tester);
    expect(mounted.state.subtitleMatchFor(siteKey: 'folder-site', vodId: 'real-vod-B', episodeName: queueItems[1].title), isNull, reason: 'A final native completion must not persist A candidate under B');
    expect(mounted.state.log.entries.any((entry) => entry.line.contains('字幕已启用 provider=local title=old-A.srt')), isFalse, reason: 'superseded candidate must not report successful application');
    expect(current.subtitles.every((track) => !track.uri), isTrue);
    expect(current.opened.last.uri, 'https://media.test/resolved-B.m3u8');
    await closeQueue(tester);
  });
  testWidgets(
    'manual next at true queue EOF keeps current progress saver active',
    (tester) async {
      final mounted = await mountQueue(tester, current: 1);
      mounted.media.progress(100);
      await tester.pump();
      await tester.tap(find.byTooltip('下一集（]）'));
      await settleQueue(tester);
      mounted.media.progress(140);
      await tester.pump(const Duration(seconds: 6));
      expect(mounted.state.writes.last.position, 140000);
      expect(mounted.media.opened.length, 1);
      expect(mounted.queue.pageCalls, 0);
      await closeQueue(tester);
      expect(mounted.state.writes.last.position, 140000);
    },
  );
  testWidgets(
    'null queue retry keeps original media loader without re-resolving file',
    (tester) async {
      final mounted = await mountQueue(tester, before: true);
      mounted.media.failOpen = true;
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(state: mounted.state, request: fileRequest(1)),
        ),
      );
      await settleQueue(tester);
      mounted.media.failOpen = false;
      await tester.tap(find.byKey(const ValueKey('player-error-retry')));
      await settleQueue(tester);
      expect(
        mounted.media.opened.last.uri,
        'https://media.test/resolved-B.m3u8',
      );
      expect(mounted.state.targets, isEmpty);
      await closeQueue(tester);
    },
  );
  testWidgets(
    'late file-internal line keeps current queue file real proxy token and lastDecision',
    (tester) async {
      final queue = QueueFixture();
      final mounted = await mountQueue(
        tester,
        queue: queue,
        initialRequest: fileRequest(0, altLine: true),
      );
      final started = Completer<void>();
      final old = Completer<http.Response>();
      http.Response response(String target) => http.Response(
        jsonEncode({
          'url': 'https://cdn.test/$target.m3u8',
          'header': {'Referer': 'https://origin.test/$target'},
        }),
        200,
      );
      final site = Site(
        key: 'folder-site',
        name: 'fixture',
        type: 4,
        api: 'https://site.test/api',
      );
      final router = SpiderRouter(
        globalHeaders: const [],
        client: HttpApiClient(
          client: MockClient((request) {
            final target = request.url.queryParameters['play']!;
            if (target == 'real-alt-A') {
              started.complete();
              return old.future;
            }
            return Future.value(response(target));
          }),
        ),
      );
      mounted.state.realSite = site;
      mounted.state.realService = SiteService(
        appConfig: AppConfig(sites: [site]),
        router: router,
      );
      addTearDown(router.dispose);
      await tester.runAsync(mounted.state.startProxy);
      addTearDown(() => tester.runAsync(mounted.state.stopProxy));
      queue.resolveFile = (key, guard) async {
        final result = await mounted.state.resolvePlayback(
          episodeTarget: 'real-target-B',
          flag: 'backend-B',
          vodId: 'real-vod-B',
          isCurrent: guard,
        );
        return fileRequest(1).copyWith(
          url: result!.url!,
          headers: result.headers?.asRequestHeaders ?? {},
        );
      };
      await tester.tap(find.textContaining('选集（').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('备用线路A'));
      await settleQueue(tester);
      expect(started.isCompleted, isTrue);
      await selectQueueItem(tester, 'opaque-file-B');
      final fresh = mounted.state.lastDecision!;
      final token = Uri.parse(fresh.url!).pathSegments[1];
      expect(mounted.state.proxySessions.byToken(token), isNotNull);
      old.complete(response('real-alt-A'));
      await settleQueue(tester);
      expect(mounted.state.lastDecision, same(fresh));
      expect(mounted.state.proxySessions.byToken(token), isNotNull);
      await closeQueue(tester);
    },
  );
  testWidgets(
    'late A subtitle-off completion cannot attach A subtitles to replacement B controller',
    (tester) async {
      final queue = QueueFixture(assets: true);
      final off = Completer<void>();
      final media = <QueueMediaIO>[];
      await mountQueue(
        tester,
        queue: queue,
        onMedia: (io) {
          if (media.isEmpty) io.nextSubtitle = off;
          media.add(io);
        },
        danmaku: QueueDanmaku(),
      );
      expect(media.first.subtitles.length, 1);
      queue.assets = false;
      final next = Completer<PlaybackRequest>();
      queue.gates['opaque-file-B'] = next;
      await selectQueueItem(tester, 'opaque-file-B');
      next.complete(fileRequest(1));
      await settleQueue(tester);
      expect(
        media.length,
        2,
        reason: 'busy old subtitle I/O is owned by disposed controller',
      );
      final current = media.last;
      expect(current.opened.single.uri, 'https://media.test/resolved-B.m3u8');
      off.complete();
      await settleQueue(tester);
      await tester.tap(find.byTooltip('字幕轨'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('字幕A'), findsNothing);
      expect(current.subtitles.every((track) => track.id == 'no'), isTrue);
      await closeQueue(tester);
    },
  );
  testWidgets('previous at queue start leaves paired progress saver active', (
    tester,
  ) async {
    final mounted = await mountQueue(tester);
    mounted.media.progress(100);
    await tester.pump();
    await tester.tap(find.byTooltip('上一集（[）'));
    await settleQueue(tester);
    mounted.media.progress(140);
    await tester.pump(const Duration(seconds: 6));
    expect(mounted.state.writes.last.position, 140000);
    expect(mounted.media.opened.length, 1);
    await closeQueue(tester);
  });
  testWidgets(
    'new empty-assets file clears subtitle menu and old danmaku immediately',
    (tester) async {
      final queue = QueueFixture(assets: true);
      final mounted = await mountQueue(
        tester,
        queue: queue,
        danmaku: QueueDanmaku(),
      );
      await tester.tap(find.byTooltip('字幕轨'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('字幕A'), findsWidgets);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 350));
      queue.assets = false;
      await selectQueueItem(tester, 'opaque-file-B');
      await tester.tap(find.byTooltip('字幕轨'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('字幕A'), findsNothing);
      expect(
        tester.widget<DanmakuOverlay>(find.byType(DanmakuOverlay)).items,
        isEmpty,
      );
      expect(
        mounted.media.opened.last.uri,
        'https://media.test/resolved-B.m3u8',
      );
      await closeQueue(tester);
    },
  );
  testWidgets(
    'repeat all page failure never loops and retry targets discovered next file',
    (tester) async {
      final queue = QueueFixture(count: 1, hasMore: true)..pageFails = true;
      final mounted = await mountQueue(tester, queue: queue);
      await setQueueRepeat(tester, '列表循环');
      mounted.media.progress(1000, completed: true);
      await settleQueue(tester);
      expect(queue.pageCalls, 1);
      expect(mounted.media.opened.length, 1);
      await tester.pump(const Duration(seconds: 6));
      expect(queue.pageCalls, 1);
      expect(mounted.media.opened.length, 1);
      queue.pageFails = false;
      await tester.tap(find.byKey(const ValueKey('player-error-retry')));
      await settleQueue(tester);
      expect(
        mounted.media.opened.last.uri,
        'https://media.test/resolved-B.m3u8',
      );
      await closeQueue(tester);
    },
  );
  testWidgets('queue constructor accepts frozen optional seam', (tester) async {
    final temp = Directory.systemTemp.createTempSync('queue-seam');
    final state = QueueState(
      paths: AppPaths.resolve(
        overrides: {
          'config': temp.path,
          'data': temp.path,
          'cache': temp.path,
          'state': temp.path,
        },
      ),
      log: LogService(),
    );
    addTearDown(() {
      state.dispose();
      temp.deleteSync(recursive: true);
    });
    expect(
      () => Function.apply(PlayerPage.new, [], {
        #state: state,
        #request: fileRequest(0),
        #queue: QueueFixture(),
        #queueItemKey: 'opaque-file-A',
      }),
      returnsNormally,
    );
    final fixture = await mountQueue(tester);
    expect(
      fixture.media.opened.single.uri,
      'https://media.test/resolved-A.m3u8',
    );
    await closeQueue(tester);
  });
  testWidgets(
    'next replaces whole file request rather than one-VOD episode index',
    (tester) async {
      final fixture = await mountQueue(tester);
      await tester.tap(find.byTooltip('下一集（]）'));
      await settleQueue(tester);
      expect(
        fixture.media.opened.last.uri,
        'https://media.test/resolved-B.m3u8',
      );
      expect(fixture.media.opened.last.httpHeaders, {
        'Referer': 'https://origin.test/B',
      });
      expect(find.textContaining('第02集 月下重逢'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('player-quality-button')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.text('原画B'));
      await settleQueue(tester);
      expect(fixture.state.targets.last, (
        target: 'real-target-B',
        flag: 'backend-B',
        vodId: 'real-vod-B',
        source: 'original-config',
        quality: 1,
      ));
      expect(
        fixture.media.opened.last.uri,
        'https://proxy.test/real-target-B/q1.m3u8',
      );
      await closeQueue(tester);
    },
  );
  testWidgets(
    'queue panel uses stable keys and refreshes unopened files from snapshot',
    (tester) async {
      final fixture = await mountQueue(
        tester,
        queue: QueueFixture(count: 1, hasMore: true),
      );
      await tester.tap(find.text('选集（1）'));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const ValueKey('player-queue-load-more')));
      await settleQueue(tester);
      expect(
        find.byKey(const ValueKey('player-queue-item-opaque-file-C')),
        findsOneWidget,
      );
      expect(
        fixture.queue.resolvedKeys,
        isEmpty,
        reason: 'panel pagination must not prepare media',
      );
      await tester.tap(
        find.byKey(const ValueKey('player-queue-item-opaque-file-B')),
      );
      await settleQueue(tester);
      expect(
        fixture.media.opened.last.uri,
        'https://media.test/resolved-B.m3u8',
      );
      await closeQueue(tester);
    },
  );
  testWidgets(
    'loaded tail pages before choosing next and page failure can retry without false EOF',
    (tester) async {
      final fixture = await mountQueue(
        tester,
        queue: QueueFixture(count: 1, hasMore: true)..pageFails = true,
      );
      await tester.tap(find.byTooltip('下一集（]）'));
      await settleQueue(tester);
      expect(fixture.queue.pageCalls, 1);
      expect(fixture.media.opened.length, 1);
      expect(find.byKey(const ValueKey('player-error-retry')), findsOneWidget);
      fixture.queue.pageFails = false;
      await tester.tap(find.byKey(const ValueKey('player-error-retry')));
      await settleQueue(tester);
      expect(
        fixture.media.opened.last.uri,
        'https://media.test/resolved-B.m3u8',
      );
      await closeQueue(tester);
    },
  );
  testWidgets(
    'failed pending file retry prepares failed key not previous current file',
    (tester) async {
      final queue = QueueFixture()..failKey = 'opaque-file-B';
      final fixture = await mountQueue(tester, queue: queue);
      await tester.tap(find.byTooltip('下一集（]）'));
      await settleQueue(tester);
      expect(find.byKey(const ValueKey('player-error-retry')), findsOneWidget);
      queue.failKey = null;
      await tester.tap(find.byKey(const ValueKey('player-error-retry')));
      await settleQueue(tester);
      expect(
        fixture.media.opened.last.uri,
        'https://media.test/resolved-B.m3u8',
      );
      expect(queue.resolvedKeys, ['opaque-file-B', 'opaque-file-B']);
      await closeQueue(tester);
    },
  );
  testWidgets(
    'late queue preparation is invalidated by second selection and route disposal',
    (tester) async {
      final queue = QueueFixture(count: 3);
      final first = Completer<PlaybackRequest>();
      queue.gates['opaque-file-B'] = first;
      final fixture = await mountQueue(tester, queue: queue);
      await selectQueueItem(tester, 'opaque-file-B');
      await selectQueueItem(tester, 'opaque-file-C');
      expect(queue.guards['opaque-file-B']!(), isFalse);
      first.complete(fileRequest(1));
      await settleQueue(tester);
      expect(
        fixture.media.opened.last.uri,
        'https://media.test/resolved-C.m3u8',
      );
      await closeQueue(tester);
      expect(queue.guards['opaque-file-C']!(), isFalse);
    },
  );
  testWidgets('late old danmaku cannot populate new file with empty assets', (
    tester,
  ) async {
    final queue = QueueFixture(assets: true);
    final loader = QueueDanmaku()..gate = Completer<DanmakuDocument>();
    final fixture = await mountQueue(tester, queue: queue, danmaku: loader);
    queue.assets = false;
    await selectQueueItem(tester, 'opaque-file-B');
    loader.gate!.complete(
      const DanmakuDocument(
        items: [DanmakuItem(timeMs: 0, text: '旧集弹幕')],
        format: 'xml',
        encoding: 'utf-8',
        sourceUrl: 'https://asset.test/A.xml',
        byteLength: 50,
        skipped: 0,
      ),
    );
    await settleQueue(tester);
    expect(
      tester.widget<DanmakuOverlay>(find.byType(DanmakuOverlay)).items,
      isEmpty,
    );
    expect(fixture.media.opened.last.uri, 'https://media.test/resolved-B.m3u8');
    await closeQueue(tester);
  });
  for (final row in [
    (label: '单集循环', paging: 0, uri: 'https://media.test/resolved-A.m3u8'),
    (label: '不循环', paging: 0, uri: 'https://media.test/resolved-A.m3u8'),
    (label: '列表循环', paging: 1, uri: 'https://media.test/resolved-B.m3u8'),
  ]) {
    testWidgets(
      'true EOF ${row.label} honors paging policy with autoNext disabled',
      (tester) async {
        final fixture = await mountQueue(
          tester,
          queue: QueueFixture(count: 1, hasMore: true),
          autoNext: false,
        );
        await setQueueRepeat(tester, row.label);
        fixture.media.progress(1000, completed: true);
        await settleQueue(tester);
        expect(fixture.queue.pageCalls, row.paging);
        expect(fixture.media.opened.last.uri, row.uri);
        if (row.label == '单集循环') {
          expect(fixture.media.state.position, Duration.zero);
        }
        await closeQueue(tester);
      },
    );
  }
  testWidgets('repeat all loops to first only after actual queue EOF', (
    tester,
  ) async {
    final fixture = await mountQueue(
      tester,
      queue: QueueFixture(count: 2),
      current: 1,
    );
    await setQueueRepeat(tester, '列表循环');
    fixture.media.progress(500, completed: true);
    await settleQueue(tester);
    expect(
      fixture.media.opened.length,
      1,
      reason: 'premature media EOF is not queue EOF',
    );
    fixture.media.progress(1000, completed: true);
    await settleQueue(tester);
    expect(fixture.media.opened.last.uri, 'https://media.test/resolved-A.m3u8');
    await closeQueue(tester);
  });
}
