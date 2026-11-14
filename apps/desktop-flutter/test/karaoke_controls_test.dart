import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/karaoke/karaoke.dart';
import 'package:webhtv_pc/services/karaoke/karaoke_controller.dart';
import 'package:webhtv_pc/services/karaoke/track_repository.dart';
import 'package:webhtv_pc/ui/karaoke/karaoke_controls.dart';

import 'karaoke_repository_fixture.dart' show FakeTransport;

class _FakeMic implements KaraokeMicSource {
  _FakeMic({this.available = true});
  final bool available;
  final _controller = StreamController<KaraokePitchSample>.broadcast();
  @override
  bool get isAvailable => available;
  @override
  String get unavailableReason => available ? '' : 'no capture device';
  @override
  Stream<KaraokePitchSample> get samples => _controller.stream;
  @override
  Future<bool> start() async => available;
  @override
  Future<void> stop() async {}
  Future<void> close() => _controller.close();
}

class _FixtureRepository extends KaraokeTrackRepository {
  _FixtureRepository()
    : super(Directory('karaoke-widget-unused'), transport: FakeTransport(''));
  @override
  Future<KaraokeTrack?> load(KaraokeMedia media) async => null;
}

Future<void> _tapState(
  WidgetTester tester,
  KaraokeController controller,
  String label,
  KaraokeStatus status,
) async {
  await tester.runAsync(() async {
    final changed = controller.changes.firstWhere(
      (state) => state.status == status,
    );
    await tester.tap(find.text(label));
    await changed.timeout(const Duration(seconds: 3));
  });
  await tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 3),
  );
  expect(controller.state.status, status);
}

Future<void> _cleanUp(
  WidgetTester tester,
  KaraokeController controller,
  _FakeMic mic,
  AudioSessionClock clock,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(() async {
    await (() async {
      await controller.dispose();
      await mic.close();
      await clock.dispose();
    })().timeout(const Duration(seconds: 3));
  });
}

void main() {
  testWidgets(
    'KaraokeControls renders idle state and completes start/stop before rendering',
    (tester) async {
      final clock = AudioSessionClock();
      final mic = _FakeMic();
      final controller = KaraokeController(
        clock: clock,
        repository: _FixtureRepository(),
        mic: mic,
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: KaraokeControls(controller: controller)),
          ),
        );
        expect(controller.state.status, KaraokeStatus.inactive);
        expect(find.text('未启用'), findsOneWidget);
        expect(find.text('0 分 · E'), findsOneWidget);
        await _tapState(tester, controller, '开始', KaraokeStatus.freeSing);
        expect(find.text('自由唱评分'), findsOneWidget);
        expect(clock.playing, isFalse, reason: '评分开始不得替播放器开播');
        await _tapState(tester, controller, '停止', KaraokeStatus.inactive);
        expect(find.text('未启用'), findsOneWidget);
      } finally {
        await _cleanUp(tester, controller, mic, clock);
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'KaraokeControls shows real unavailable fixture reason without filesystem work in FakeAsync',
    (tester) async {
      final clock = AudioSessionClock();
      final mic = _FakeMic(available: false);
      final controller = KaraokeController(
        clock: clock,
        repository: _FixtureRepository(),
        mic: mic,
      );
      try {
        await tester.runAsync(
          () => controller.bindMedia(
            const KaraokeMedia(
              key: 'k',
              url: 'D:/a.mp4',
              title: 'T',
              artist: 'A',
              durationMs: 1000,
            ),
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: KaraokeControls(controller: controller)),
          ),
        );
        await _tapState(tester, controller, '开始', KaraokeStatus.micUnavailable);
        expect(find.text('麦克风不可用：no capture device'), findsOneWidget);
        expect(find.text('no capture device'), findsOneWidget);
        expect(controller.state.error, 'no capture device');
      } finally {
        await _cleanUp(tester, controller, mic, clock);
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'KaraokeControls tolerance slider changes real pitch hit decision',
    (tester) async {
      final clock = AudioSessionClock(playing: true, now: () => DateTime(2026));
      final mic = _FakeMic();
      final controller = KaraokeController(
        clock: clock,
        repository: _FixtureRepository(),
        mic: mic,
      );
      final pitch = KaraokePitchSample(
        timestampMs: 0,
        frequencyHz: midiToFrequency(72),
        volume: .3,
        confidence: 1,
      );
      try {
        controller.selectTrack(
          UltraStarParser.parse('#BPM:60\n#GAP:0\n: 0 60 69 la\nE'),
        );
        await tester.runAsync(() => controller.start());
        controller.pushSample(pitch);
        controller.updateClock(
          position: const Duration(milliseconds: 1),
          playing: true,
        );
        controller.updateClock(
          position: const Duration(milliseconds: 2),
          playing: true,
        );
        expect(controller.snapshot.hit, isFalse, reason: '默认2半音容差不能命中3半音偏差');
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: KaraokeControls(controller: controller)),
          ),
        );
        await tester.drag(find.byType(Slider).last, const Offset(160, 0));
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 3),
        );
        controller.pushSample(pitch);
        controller.updateClock(
          position: const Duration(milliseconds: 3),
          playing: true,
        );
        controller.updateClock(
          position: const Duration(milliseconds: 4),
          playing: true,
        );
        expect(controller.snapshot.hit, isTrue, reason: '用户放宽难度后真实音高应命中');
        expect(find.textContaining('半音'), findsOneWidget);
      } finally {
        await _cleanUp(tester, controller, mic, clock);
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
