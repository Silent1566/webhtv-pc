// ignore_for_file: invalid_use_of_protected_member
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webhtv_pc/core/epg.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/player_controller.dart';
import 'package:webhtv_pc/ui/player_osd.dart';
import 'package:webhtv_pc/ui/player_live_panel.dart';

import 'live_playback_session_test.dart' show fixture;
import 'support/player_page_harness.dart';

class MediaJournal {
  final opened = <String>[];
  final openedHeaders = <Map<String, String>>[];
  final failed = <String>{};
  final gates = <String, Completer<void>>{};
  final failureMessages = <String, String>{};
}

class MediaIO extends PlatformPlayer {
  MediaIO(this.original, this.journal)
    : super(configuration: original.configuration) {
    stream = original.stream;
  }
  final MediaJournal journal;
  bool disposed = false;
  final PlatformPlayer original;
  List<String> get opened => journal.opened;
  List<Map<String, String>> get openedHeaders => journal.openedHeaders;
  Set<String> get failed => journal.failed;
  Map<String, Completer<void>> get gates => journal.gates;
  Map<String, String> get failureMessages => journal.failureMessages;
  @override
  Future<int> get handle => original.handle;
  void progress(int seconds, {bool completed = false}) {
    state = state.copyWith(
      position: Duration(seconds: seconds),
      duration: const Duration(seconds: 1000),
      playing: !completed,
      completed: completed,
    );
    if (disposed) return;
    original.durationController.add(state.duration);
    original.positionController.add(state.position);
    original.playingController.add(state.playing);
    original.completedController.add(completed);
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    final media = playable as Media;
    opened.add(media.uri);
    openedHeaders.add(media.httpHeaders ?? {});
    final gate = gates.remove(media.uri);
    if (gate != null) await gate.future;
    if (failureMessages[media.uri] case final message?) {
      throw StateError(message);
    }
    if (failed.contains(media.uri)) throw StateError('404 missing channel');
    progress(1);
  }

  @override
  Future<void> seek(Duration position) async => progress(position.inSeconds);
  @override
  Future<void> play() async => progress(state.position.inSeconds);
  @override
  Future<void> pause() async {}
  @override
  Future<void> setVolume(double volume) async {
    state = state.copyWith(volume: volume);
    if (!disposed) original.volumeController.add(volume);
  }

  @override
  Future<void> setRate(double rate) async {
    state = state.copyWith(rate: rate);
    if (!disposed) original.rateController.add(rate);
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}
  @override
  Future<void> dispose() async {
    disposed = true;
    unawaited(original.dispose());
    await super.dispose();
  }
}

Future<MediaIO> mount(
  WidgetTester tester,
  PlayerPage page, {
  Size size = const Size(1024, 640),
  Set<String> failed = const {},
}) async {
  await tester.runAsync(page.state.bootstrap);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  installMediaKitMocks(tester);
  installWindowManagerMocks(tester);
  MediaIO? media;
  final journal = MediaJournal()..failed.addAll(failed);
  final seen = <Player>{};
  var active = true;
  addTearDown(() => active = false);
  tester.binding.addPersistentFrameCallback((_) {
    if (!active || find.byType(Video).evaluate().isEmpty) return;
    final player = tester.widget<Video>(find.byType(Video)).controller.player;
    if (!seen.add(player)) return;
    final next = MediaIO(player.platform!, journal);
    media ??= next;
    player.platform = next;
  });
  await tester.pumpWidget(MaterialApp(home: page));
  await flush(tester);
  expect(tester.takeException(), isNull);
  return media!;
}

Future<void> flush(WidgetTester tester) async {
  await settlePlayerPage(tester, times: 2);
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await settlePlayerPage(tester, times: 2);
}

Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(Duration.zero);
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump(Duration.zero);
}

void main() {
  for (final size in [
    const Size(800, 600),
    const Size(1024, 640),
    const Size(1440, 900),
  ]) {
    testWidgets('${size.width}直播线路槽和常驻抽屉不改变画面尺寸，Esc恢复焦点', (tester) async {
      final f = fixture();
      await mount(
        tester,
        PlayerPage(
          state: f.state,
          request: f.session.request,
          liveSession: f.session,
        ),
        size: size,
      );
      final title = tester.widget<AppBar>(find.byType(AppBar)).title as Text;
      expect(title.data, 'CCTV-5');
      expect(
        tester.widget<PlayerOsdLayer>(find.byType(PlayerOsdLayer)).title,
        'CCTV-5',
      );
      expect(find.text('线路（2）'), findsOneWidget);
      expect(find.textContaining('选集（'), findsNothing);
      final rect = tester.getRect(find.byType(Video));
      await tester.tap(find.byKey(const ValueKey('player-live-panel-toggle')));
      await tester.pump();
      expect(find.byType(PlayerLivePanel), findsOneWidget);
      expect(tester.getRect(find.byType(Video)), rect);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(PlayerLivePanel), findsNothing);
      await tester.tap(find.text('线路（2）'));
      await tester.pump();
      expect(find.byType(PlayerLivePanel), findsOneWidget);
      expect(
        find.byKey(const ValueKey('player-live-source-list')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('player-live-channel-list')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('live-line-1')), findsOneWidget);
      expect(tester.getRect(find.byType(Video)), rect);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(PlayerLivePanel), findsNothing);
      expect(
        windowManagerCalls.where((call) => call.method == 'setFullScreen'),
        isEmpty,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await flush(tester);
      expect(f.session.channel.name, '频道二');
      expect(tester.getRect(find.byType(Video)), rect);
      await unmount(tester);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('直播PgDown跨分组重建Header；弹窗输入时不误切台', (tester) async {
    final f = fixture();
    final media = await mount(
      tester,
      PlayerPage(
        state: f.state,
        request: f.session.request,
        liveSession: f.session,
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await flush(tester);
    expect(media.opened.last, 'https://fixture.test/c');
    expect(media.openedHeaders.last, {'User-Agent': 'second-agent'});
    expect(f.session.channel.name, '频道二');
    final context = tester.element(find.byType(PlayerPage));
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(content: TextField(autofocus: true)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pump();
    expect(media.opened.last, 'https://fixture.test/c');
    Navigator.of(context).pop();
    await tester.pump();
    await unmount(tester);
    expect(tester.takeException(), isNull);
  });
  testWidgets('直播上下台和播完不轮播线路，点播选集保持', (tester) async {
    final f = fixture();
    final media = await mount(
      tester,
      PlayerPage(
        state: f.state,
        request: f.session.request,
        liveSession: f.session,
      ),
    );
    media.progress(1000, completed: true);
    await flush(tester);
    expect(media.opened.length, 1);
    await tester.tap(find.byTooltip('下一台（PgDn）'));
    await flush(tester);
    expect(media.opened.last, 'https://fixture.test/c');
    await unmount(tester);
  });
  testWidgets('没有session的directUrl仍按点播呈现，不自动当直播', (tester) async {
    final f = fixture();
    await mount(tester, PlayerPage(state: f.state, request: f.session.request));
    expect(find.text('选集（2）'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('player-live-panel-toggle')),
      findsNothing,
    );
    expect(find.byTooltip('下一集（]）'), findsOneWidget);
    await unmount(tester);
  });
  testWidgets('回看保持seek，不自动连播，回直播恢复原线路', (tester) async {
    final f = fixture(
      initialProgram: const EpgProgram(
        title: '回看节目',
        startMs: 1700000000000,
        stopMs: 1700003600000,
      ),
    );
    final media = await mount(
      tester,
      PlayerPage(
        state: f.state,
        request: f.session.request,
        liveSession: f.session,
      ),
    );
    final title = tester.widget<AppBar>(find.byType(AppBar)).title as Text;
    expect(title.data, 'CCTV-5 · 回看节目');
    expect(
      tester.widget<PlayerOsdLayer>(find.byType(PlayerOsdLayer)).title,
      'CCTV-5 · 回看节目',
    );
    expect(find.text('回到直播'), findsOneWidget);
    expect(find.text('线路（1）'), findsNothing);
    expect(find.text('选集（1）'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(media.state.position, const Duration(seconds: 11));
    media.progress(1000, completed: true);
    await flush(tester);
    expect(media.opened.length, 1);
    await tester.tap(find.text('回到直播'));
    await flush(tester);
    expect(media.opened.last, 'https://fixture.test/b');
    expect(f.session.program, isNull);
    expect(find.text('线路（2）'), findsOneWidget);
    await unmount(tester);
  });
  testWidgets('最后单线路失败跨源与标题抽屉同步，不误匹配CCTV5+', (tester) async {
    final f = fixture();
    final source = LiveSource(name: '替代源', type: 1);
    f.state.sources = [...f.state.sources, source];
    f.service.loads[source.name] = () async => LivePlaylist(
      sourceName: source.name,
      groups: [
        LiveGroup(
          name: '体育',
          channels: [
            LiveChannel(name: 'CCTV5+', urls: ['https://fixture.test/wrong']),
            LiveChannel(
              name: 'CCTV5',
              urls: ['https://fixture.test/fallback'],
              header: HeaderMap({'User-Agent': 'fallback-agent'}),
            ),
          ],
        ),
      ],
    );
    final media = await mount(
      tester,
      PlayerPage(
        state: f.state,
        request: f.session.request,
        liveSession: f.session,
      ),
      failed: {'https://fixture.test/b'},
    );
    await flush(tester);
    expect(media.opened, [
      'https://fixture.test/b',
      'https://fixture.test/fallback',
    ]);
    expect(media.openedHeaders.last, {'User-Agent': 'fallback-agent'});
    expect(f.session.source.name, '替代源');
    await tester.tap(find.byKey(const ValueKey('player-live-panel-toggle')));
    await tester.pump();
    expect(find.text('正在播放 · 替代源'), findsOneWidget);
    await unmount(tester);
  });
  testWidgets('过期跨源失败不能回滚新手动频道请求', (tester) async {
    final f = fixture();
    final source = LiveSource(name: '慢源', type: 1);
    f.state.sources = [...f.state.sources, source];
    final gate = Completer<LivePlaylist>();
    f.service.loads[source.name] = () => gate.future;
    final media = await mount(
      tester,
      PlayerPage(
        state: f.state,
        request: f.session.request,
        liveSession: f.session,
      ),
      failed: {'https://fixture.test/b'},
    );
    f.session.stepChannel(1);
    await flush(tester);
    expect(media.opened.last, 'https://fixture.test/c');
    gate.complete(LivePlaylist(sourceName: source.name));
    await flush(tester);
    expect(f.session.channel.name, '频道二');
    expect(find.textContaining('频道二'), findsWidgets);
    expect(find.textContaining('播放失败'), findsNothing);
    expect(media.opened.last, 'https://fixture.test/c');
    await unmount(tester);
    expect(tester.takeException(), isNull);
  });
  testWidgets('媒体open在途挂起不阻塞最新频道，迟到旧引擎不能覆盖', (tester) async {
    final f = fixture();
    final media = await mount(
      tester,
      PlayerPage(
        state: f.state,
        request: f.session.request,
        liveSession: f.session,
      ),
    );
    final gate = Completer<void>();
    media.gates['https://fixture.test/a'] = gate;
    f.session.selectLine(0);
    await tester.pump(const Duration(milliseconds: 100));
    f.session.stepChannel(1);
    await flush(tester);
    final whilePending = media.opened.last;
    gate.complete();
    await flush(tester);
    expect(whilePending, 'https://fixture.test/c');
    expect(media.opened.last, 'https://fixture.test/c');
    expect(f.session.channel.name, '频道二');
    expect(media.openedHeaders.last, {'User-Agent': 'second-agent'});
    await unmount(tester);
    expect(tester.takeException(), isNull);
  });
  testWidgets('网络失败重试窗口切台取消旧URL重试，最新请求立即播放', (tester) async {
    final f = fixture();
    final media = await mount(
      tester,
      PlayerPage(
        state: f.state,
        request: f.session.request,
        liveSession: f.session,
      ),
    );
    media.failureMessages['https://fixture.test/a'] = 'failed to connect';
    f.session.selectLine(0);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 100));
    f.session.stepChannel(1);
    await flush(tester);
    await tester.pump(const Duration(seconds: 1));
    await flush(tester);
    expect(media.opened, [
      'https://fixture.test/b',
      'https://fixture.test/a',
      'https://fixture.test/c',
    ]);
    expect(f.session.channel.name, '频道二');
    await unmount(tester);
    expect(tester.takeException(), isNull);
  });
  testWidgets('控制器原生open有界超时且释放后无残留timer', (tester) async {
    installMediaKitMocks(tester);
    final player = Player();
    final journal = MediaJournal();
    final media = MediaIO(player.platform!, journal);
    player.platform = media;
    final controller = PlayerController(player: player);
    final gate = Completer<void>();
    media.gates['https://fixture.test/native-timeout'] = gate;
    PlayerLoadOutcome? result;
    unawaited(
      controller
          .open(
            'https://fixture.test/native-timeout',
            timeout: const Duration(milliseconds: 100),
            awaitFirstFrame: false,
            isCurrent: () => true,
          )
          .then((outcome) => result = outcome),
    );
    await tester.pump(const Duration(milliseconds: 150));
    await flush(tester);
    expect(result?.failureKind, PlayerFailureKind.timeout);
    expect(controller.hasPendingNativeOpen, isTrue);
    controller.dispose();
    gate.complete();
    await flush(tester);
    expect(tester.takeException(), isNull);
  });
  testWidgets('控制器isCurrent过期直接取消重试而非依赖dispose', (tester) async {
    installMediaKitMocks(tester);
    final player = Player();
    final journal = MediaJournal()
      ..failureMessages['https://fixture.test/network'] = 'failed to connect';
    final media = MediaIO(player.platform!, journal);
    player.platform = media;
    final controller = PlayerController(player: player);
    var current = true;
    PlayerLoadOutcome? result;
    unawaited(
      controller
          .openWithRetry(
            'https://fixture.test/network',
            isCurrent: () => current,
          )
          .then((outcome) => result = outcome),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    current = false;
    await tester.pump(const Duration(seconds: 1));
    await flush(tester);
    expect(result?.succeeded, isFalse);
    expect(journal.opened, ['https://fixture.test/network']);
    controller.dispose();
    await flush(tester);
    expect(tester.takeException(), isNull);
  });
  testWidgets('同一帧连续PgDn合并到最新意图，不重复打开中间频道', (tester) async {
    final f = fixture();
    final media = await mount(
      tester,
      PlayerPage(
        state: f.state,
        request: f.session.request,
        liveSession: f.session,
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await flush(tester);
    expect(media.opened, ['https://fixture.test/b', 'https://fixture.test/a']);
    expect(f.session.channel.name, 'CCTV-5');
    await unmount(tester);
    expect(tester.takeException(), isNull);
  });
  testWidgets('dispose早于native timeout且gate永不完成，旧open Future仍终止', (
    tester,
  ) async {
    installMediaKitMocks(tester);
    final player = Player();
    final journal = MediaJournal();
    final media = MediaIO(player.platform!, journal);
    player.platform = media;
    final controller = PlayerController(player: player);
    final gate = Completer<void>();
    media.gates['https://fixture.test/never-completes'] = gate;
    PlayerLoadOutcome? result;
    unawaited(
      controller
          .open(
            'https://fixture.test/never-completes',
            timeout: const Duration(seconds: 1),
            awaitFirstFrame: false,
            isCurrent: () => true,
          )
          .then((outcome) => result = outcome),
    );
    await tester.pump(const Duration(milliseconds: 50));
    controller.dispose();
    await flush(tester);
    expect(gate.isCompleted, isFalse);
    expect(result?.succeeded, isFalse, reason: '取消timer不能使外部open永久挂起');
    await tester.pump(const Duration(seconds: 2));
    await flush(tester);
    expect(tester.takeException(), isNull);
  });
  testWidgets('静音前25音量在直播引擎隔离后取消静音仍恢复25', (tester) async {
    final f = fixture();
    final media = await mount(
      tester,
      PlayerPage(
        state: f.state,
        request: f.session.request,
        liveSession: f.session,
      ),
    );
    final volumeSlider = tester
        .widgetList<Slider>(find.byType(Slider))
        .singleWhere((slider) => slider.max == 100);
    volumeSlider.onChanged!(25);
    await flush(tester);
    await tester.tap(find.byTooltip('静音（M）'));
    await tester.pump();
    final gate = Completer<void>();
    media.gates['https://fixture.test/a'] = gate;
    f.session.selectLine(0);
    await tester.pump(const Duration(milliseconds: 100));
    f.session.stepChannel(1);
    await flush(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await flush(tester);
    final restored = tester
        .widget<Video>(find.byType(Video))
        .controller
        .player
        .state
        .volume;
    gate.complete();
    await flush(tester);
    expect(restored, 25);
    await unmount(tester);
    expect(tester.takeException(), isNull);
  });
  test('直播状态与在线人数使用固定分隔符，不混入频道标题', () {
    expect(formatPlayerLiveStatus(status: '已连接', online: 100), '已连接 · 在线 100');
    expect(formatPlayerLiveStatus(online: 100), '在线 100');
    expect(formatPlayerLiveStatus(status: '连接中'), '连接中');
  });
}
