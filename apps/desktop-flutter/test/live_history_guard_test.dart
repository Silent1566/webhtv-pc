// 页面已订阅原内核的事件流，因此替换媒体 I/O 时必须保留事件流才能驱动真实起播链。
// ignore_for_file: invalid_use_of_protected_member

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webhtv_pc/core/epg.dart';
import 'package:webhtv_pc/core/live_catchup.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/live_page.dart';
import 'package:webhtv_pc/ui/live_playback_session.dart';
import 'package:webhtv_pc/ui/player_page.dart';

import 'support/player_page_harness.dart';

class _MediaIO extends PlatformPlayer {
  _MediaIO(this.original, this.duration)
    : super(configuration: original.configuration) {
    stream = original.stream;
  }

  final PlatformPlayer original;
  final Duration duration;
  final opened = <String>[];

  @override
  Future<int> get handle => original.handle;

  void progress(Duration position) {
    state = state.copyWith(
      duration: duration,
      position: position,
      playing: true,
      completed: false,
    );
    original.durationController.add(duration);
    original.positionController.add(position);
    original.playingController.add(true);
    original.completedController.add(false);
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opened.add((playable as Media).uri);
    progress(const Duration(seconds: 3));
  }

  @override
  Future<void> seek(Duration position) async => progress(position);

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}

  @override
  Future<void> dispose() async {
    unawaited(original.dispose());
    await super.dispose();
  }
}

LiveChannel _channel() => LiveChannel(
  name: '冬天到了 该上分了！ 10040721',
  urls: ['https://fixture.test/live.m3u8'],
  catchup: const CatchupSpec(type: 'append', source: r'?start=${utc:}'),
);

PlaybackRequest _sessionRequest(AppState state, {bool catchup = false}) {
  final channel = _channel();
  final session = LivePlaybackSession(
    state: state,
    source: LiveSource(name: 'Douyu', type: 1),
    playlist: LivePlaylist(
      sourceName: 'Douyu',
      groups: [
        LiveGroup(name: '测试', channels: [channel]),
      ],
    ),
    channel: channel,
    initialProgram: catchup
        ? const EpgProgram(title: '回看节目', startMs: 0, stopMs: 3600000)
        : null,
  );
  addTearDown(session.dispose);
  return session.request;
}

Future<({AppState state, _MediaIO media, PlaybackRequest request})> _mount(
  WidgetTester tester,
  PlaybackRequest Function(AppState) requestFor, {
  Duration duration = const Duration(milliseconds: 12887),
}) async {
  final temp = Directory.systemTemp.createTempSync('webhtv-live-history');
  final state = AppState(
    paths: AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/webhtv-pc',
        'data': '${temp.path}/webhtv-pc',
        'cache': '${temp.path}/webhtv-pc/cache',
        'state': '${temp.path}/webhtv-pc/logs',
      },
    ),
    log: LogService(),
  );
  addTearDown(() {
    state.dispose();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });
  await tester.runAsync(state.bootstrap);
  expect(state.database, isNotNull);
  expect(state.database!.recentHistory(), isEmpty);
  final request = requestFor(state);

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
  // 页面构建后的首帧仍早于 post-frame 起播，避免真实解码和网络成为测试前提。
  tester.binding.addPersistentFrameCallback((_) {
    if (!active || media != null) return;
    final video = find.byType(Video);
    if (video.evaluate().isEmpty) return;
    final player = tester.widget<Video>(video).controller.player;
    media = _MediaIO(player.platform!, duration);
    player.platform = media;
  });
  await tester.pumpWidget(
    MaterialApp(
      home: PlayerPage(state: state, request: request),
    ),
  );
  for (var round = 0; round < 2; round++) {
    await settlePlayerPage(tester, times: 4);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
  expect(tester.takeException(), isNull);
  expect(media!.opened, [request.url]);
  expect(
    state.log.entries.any(
      (entry) => entry.line.contains('播放结果 succeeded=true'),
    ),
    isTrue,
    reason: '没有成功起播时进度写入尚未就绪，空历史会掩盖直播污染',
  );
  return (state: state, media: media!, request: request);
}

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  final liveRequests = <String, PlaybackRequest Function(AppState)>{
    '频道入口': (_) => LivePage.requestForChannel(_channel(), sourceName: 'Douyu'),
    '会话入口': (state) => _sessionRequest(state),
    '直播换线路后': (state) => _sessionRequest(state).copyWith(
      url: 'https://fixture.test/second.m3u8',
      episodeTarget: 'https://fixture.test/second.m3u8',
      episodeName: '线路 2',
    ),
  };
  for (final entry in liveRequests.entries) {
    testWidgets('${entry.key}：引擎报正时长也不写点播历史（周期与退出）', (tester) async {
      final fixture = await _mount(tester, entry.value);
      expect(fixture.request.isLive, isTrue);
      fixture.media.progress(const Duration(seconds: 6));
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      final periodicRows = fixture.state.database!.recentHistory();
      fixture.media.progress(const Duration(seconds: 9));
      await tester.pump();
      await _close(tester);
      expect(periodicRows, isEmpty, reason: '直播的伪时长不能进入点播续播历史');
      expect(fixture.state.database!.recentHistory(), isEmpty);
      expect(fixture.state.progressRevision.value, 0);
    });
  }

  final resumableRequests = <String, PlaybackRequest Function(AppState)>{
    '回看': (state) => _sessionRequest(state, catchup: true),
    '默认点播': (_) => const PlaybackRequest(
      url: 'https://fixture.test/vod.m3u8',
      title: '点播节目',
      siteKey: 'Douyu',
      vodId: 'vod',
      vodName: '点播节目',
      episodeName: '原画1080P30',
      flag: 'DouyuLive',
    ),
  };
  for (final entry in resumableRequests.entries) {
    testWidgets('${entry.key}：真实时间轴继续写入并在退出时更新历史', (tester) async {
      final fixture = await _mount(
        tester,
        entry.value,
        duration: const Duration(hours: 1),
      );
      expect(fixture.request.isLive, isFalse);
      fixture.media.progress(const Duration(seconds: 6));
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      final periodicRows = fixture.state.database!.recentHistory();
      fixture.media.progress(const Duration(seconds: 9));
      await tester.pump();
      await _close(tester);
      expect(periodicRows.single.positionMs, 6000);
      final row = fixture.state.database!.recentHistory().single;
      expect(row.positionMs, 9000);
      expect(row.durationMs, 3600000);
      expect(row.flag, entry.key == '回看' ? '回看' : 'DouyuLive');
      expect(row.episodeId, fixture.request.episodeTarget);
      expect(fixture.state.progressRevision.value, greaterThanOrEqualTo(2));
    });
  }
}
