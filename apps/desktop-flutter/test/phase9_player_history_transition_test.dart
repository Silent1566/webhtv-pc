// The page binds to the original platform streams before the test replaces
// media I/O. Keep those streams and emit engine events at that boundary.
// ignore_for_file: invalid_use_of_protected_member

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/state/app_state.dart';

import 'support/player_page_harness.dart';

class _MediaIO extends PlatformPlayer {
  _MediaIO(this.original) : super(configuration: original.configuration) {
    stream = original.stream;
  }

  final PlatformPlayer original;
  Completer<void>? nextOpen;
  bool failOpen = false;
  final opened = <String>[];

  @override
  Future<int> get handle => original.handle;

  void progress(int seconds, {int duration = 1000, bool completed = false}) {
    state = state.copyWith(
      position: Duration(seconds: seconds),
      duration: Duration(seconds: duration),
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
    opened.add((playable as Media).uri);
    final pending = nextOpen;
    nextOpen = null;
    if (pending != null) await pending.future;
    if (failOpen) throw StateError('404 missing episode');
    progress(1);
  }

  @override
  Future<void> seek(Duration position) async => progress(position.inSeconds);

  @override
  Future<void> play() async => progress(state.position.inSeconds);

  @override
  Future<void> pause() async {}

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

  Completer<PlaybackDecision?>? resolveGate;

  @override
  Future<PlaybackDecision?> resolvePlayback({
    required String episodeTarget,
    String? flag,
    String? vodId,
    Site? siteOverride,
    SiteService? serviceOverride,
  }) async {
    final gate = resolveGate;
    resolveGate = null;
    if (gate != null) return gate.future;
    return PlaybackDecision(action: PlaybackAction.direct, url: episodeTarget);
  }
}

Future<({_ResolveState state, _MediaIO media})> _mount(
  WidgetTester tester, {
  Duration? startPosition,
  bool directUrl = true,
}) async {
  final temp = Directory.systemTemp.createTempSync('webhtv-history-transition');
  final state = _ResolveState(
    paths: AppPaths.resolve(
      overrides: {'roaming': temp.path, 'local': temp.path},
    ),
    log: LogService(),
  );
  addTearDown(() {
    state.dispose();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });
  await tester.runAsync(state.bootstrap);
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
  // drawFrame has built the Video, but PlayerPage's post-frame load has not run.
  tester.binding.addPersistentFrameCallback((_) {
    if (!active || media != null) return;
    final video = find.byType(Video);
    if (video.evaluate().isEmpty) return;
    final player = tester.widget<Video>(video).controller.player;
    media = _MediaIO(player.platform!);
    player.platform = media;
  });
  final episodes = [
    for (var i = 1; i <= 10; i++)
      VodEpisode(name: '第$i集', url: 'https://fixture.test/$i.m3u8'),
  ];
  await tester.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        state: state,
        request: PlaybackRequest(
          url: episodes.first.url,
          title: '测试剧',
          siteKey: 'fixture',
          vodId: 'history-transition',
          vodName: '测试剧',
          episodeName: '第1集',
          flag: '线路一',
          directUrl: directUrl,
          startPosition: startPosition,
          playLines: [VodPlayLine(flag: '线路一', episodes: episodes)],
        ),
      ),
    ),
  );
  await settlePlayerPage(tester, times: 2);
  expect(tester.takeException(), isNull);
  expect(media!.opened, ['https://fixture.test/1.m3u8']);
  await _settleMedia(tester);
  expect(
    state.log.entries.any(
      (entry) => entry.line.contains('播放结果 succeeded=true'),
    ),
    isTrue,
    reason: [
      'fixture duration=${media!.state.duration} '
          'position=${media!.state.position} playing=${media!.state.playing}',
      ...state.log.entries.reversed.take(12).map((entry) => entry.line),
    ].join('\n'),
  );
  return (state: state, media: media!);
}

Future<void> _settleMedia(WidgetTester tester) async {
  await settlePlayerPage(tester, times: 2);
  // Broadcast cancellation uses a completed Future from the real zone.
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

Future<void> _selectTenth(WidgetTester tester) async {
  await tester.tap(find.text('选集（10）'));
  await tester.pump(const Duration(milliseconds: 250));
  final card = find.byKey(const ValueKey('player-episode-card-9'));
  await tester.ensureVisible(card);
  await tester.pump(const Duration(milliseconds: 250));
  await tester.tap(card);
  await tester.pump(const Duration(milliseconds: 250));
}

void _expectOnlyFirst(AppState state, {int positionMs = 960000}) {
  final history = state.recentHistory();
  expect(
    history.map((item) => item.episodeName),
    ['第1集'],
    reason: state.log.entries.reversed
        .take(12)
        .map((entry) => entry.line)
        .join('\n'),
  );
  expect(history.single.episodeId, 'https://fixture.test/1.m3u8');
  expect(history.single.positionMs, positionMs);
}

void main() {
  testWidgets('96%切第10集：延迟加载、周期tick和退出只保存第1集', (tester) async {
    final fixture = await _mount(tester);
    fixture.media.progress(960);
    await tester.pump();
    final pending = Completer<void>();
    fixture.media.nextOpen = pending;
    await _selectTenth(tester);
    _expectOnlyFirst(fixture.state);
    await tester.pump(const Duration(seconds: 6));
    _expectOnlyFirst(fixture.state);
    await tester.pumpWidget(const SizedBox.shrink());
    _expectOnlyFirst(fixture.state);
    // Intentionally leave open pending after dispose; late completion is a separate controller bug.
    await tester.pump();
  });

  testWidgets('加载成功恢复saver，新进度归第10集而非旧96%', (tester) async {
    final fixture = await _mount(tester);
    fixture.media.progress(960);
    await tester.pump();
    final pending = Completer<void>();
    fixture.media.nextOpen = pending;
    await _selectTenth(tester);
    _expectOnlyFirst(fixture.state);
    pending.complete();
    await _settleMedia(tester);
    fixture.media.progress(30);
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    final history = fixture.state.recentHistory();
    expect(history.length, 2);
    final tenth = history.singleWhere((item) => item.episodeName == '第10集');
    expect(tenth.episodeId, 'https://fixture.test/10.m3u8');
    expect(tenth.positionMs, 30000);
    expect(tenth.durationMs, 1000000);
    expect(tenth.positionMs / tenth.durationMs, lessThan(0.95));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
    expect(tester.takeException(), isNull);
  });

  testWidgets('新集加载失败保留旧controller位置也不污染历史', (tester) async {
    final fixture = await _mount(tester);
    fixture.media.progress(960);
    await tester.pump();
    fixture.media.failOpen = true;
    await _selectTenth(tester);
    await _settleMedia(tester);
    expect(
      fixture.state.log.entries.any(
        (entry) => entry.line.contains('播放结果 succeeded=false'),
      ),
      isTrue,
    );
    await tester.pump(const Duration(seconds: 6));
    _expectOnlyFirst(fixture.state);
    await tester.pumpWidget(const SizedBox.shrink());
    _expectOnlyFirst(fixture.state);
    expect(tester.takeException(), isNull);
  });

  testWidgets('延迟解析期间暂停写入，退出也不能把新进度混入旧记录', (tester) async {
    final fixture = await _mount(tester, directUrl: false);
    fixture.media.progress(960);
    await tester.pump();
    final gate = Completer<PlaybackDecision?>();
    fixture.state.resolveGate = gate;
    await _selectTenth(tester);
    _expectOnlyFirst(fixture.state);
    fixture.media.progress(980);
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    _expectOnlyFirst(fixture.state);
    await tester.pumpWidget(const SizedBox.shrink());
    _expectOnlyFirst(fixture.state);
    gate.complete(null);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('父widget替换request：旧进度先存旧集，延迟加载中退出不写新集', (tester) async {
    final fixture = await _mount(tester);
    fixture.media.progress(960);
    await tester.pump();
    final page = tester.widget<PlayerPage>(find.byType(PlayerPage));
    final gate = Completer<void>();
    fixture.media.nextOpen = gate;
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          state: fixture.state,
          request: page.request.copyWith(
            url: 'https://fixture.test/10.m3u8',
            episodeTarget: 'https://fixture.test/10.m3u8',
            episodeName: '第10集',
            episodeIndex: 9,
          ),
        ),
      ),
    );
    _expectOnlyFirst(fixture.state);
    fixture.media.progress(980);
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    _expectOnlyFirst(fixture.state);
    expect(fixture.media.opened.last, 'https://fixture.test/10.m3u8');
    await tester.pumpWidget(const SizedBox.shrink());
    _expectOnlyFirst(fixture.state);
    // Intentionally leave open pending after dispose; late completion is a separate controller bug.
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('正常续播后周期与dispose保存真实恢复位置', (tester) async {
    final fixture = await _mount(
      tester,
      startPosition: const Duration(seconds: 120),
    );
    await tester.pump(const Duration(seconds: 6));
    _expectOnlyFirst(fixture.state, positionMs: 120000);
    fixture.media.progress(150);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    _expectOnlyFirst(fixture.state, positionMs: 150000);
    await tester.pump(Duration.zero);
    expect(tester.takeException(), isNull);
  });

  testWidgets('真正完成自动连播先保存已完成旧集，不把completed事件归新集', (tester) async {
    final fixture = await _mount(tester);
    final pending = Completer<void>();
    fixture.media.nextOpen = pending;
    fixture.media.progress(1000, completed: true);
    await settlePlayerPage(tester, times: 2);
    _expectOnlyFirst(fixture.state, positionMs: 1000000);
    expect(fixture.state.recentHistory().single.completed, isTrue);
    expect(fixture.media.opened.last, 'https://fixture.test/2.m3u8');
    fixture.media.progress(1000, completed: true);
    await tester.pump(const Duration(seconds: 6));
    _expectOnlyFirst(fixture.state, positionMs: 1000000);
    expect(fixture.media.opened.length, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    // Intentionally leave open pending after dispose; late completion is a separate controller bug.
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
