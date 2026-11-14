import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/audio_ai/model_catalog.dart';
import 'package:webhtv_pc/core/audio_ai/pcm_sync.dart';
import 'package:webhtv_pc/core/audio_ai/pitch_track.dart';
import 'package:webhtv_pc/services/audio_ai/audio_model_manager.dart';
import 'package:webhtv_pc/services/audio_ai/basic_pitch_service.dart';
import 'package:webhtv_pc/services/audio_ai/realtime_subtitle_controller.dart';
import 'package:webhtv_pc/services/audio_ai/windows_audio_capture.dart';
import 'package:webhtv_pc/ui/audio_ai/audio_ai_controls.dart';

/// 记录调用、不碰 FFI 的采集替身：widget 断言不依赖 native DLL。
class _FakeCapture extends WindowsAudioCapture {
  final _frames = StreamController<PcmFrame>.broadcast();
  final _states = StreamController<AudioCaptureState>.broadcast();
  int starts = 0, stops = 0;
  @override
  Stream<PcmFrame> get frames => _frames.stream;
  @override
  Stream<AudioCaptureState> get states => _states.stream;
  @override
  String get captureMode => '测试替身';
  @override
  Future<bool> start({
    required AudioSessionClock clock,
    Uri? mediaUri,
    Map<String, String> headers = const {},
    int? playerProcessId,
  }) async {
    starts++;
    return true;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() async {
    await _frames.close();
    await _states.close();
  }
}

class _Engine implements SpeechEngine {
  _Engine(this.utterances);
  final List<EngineUtterance> utterances;
  int calls = 0;
  @override
  Future<List<EngineUtterance>> accept(
    PcmFrame frame, {
    required int targetRate,
  }) async {
    calls++;
    return utterances;
  }

  @override
  void reset() {}

  @override
  Future<void> dispose() async {}
}

class _DelayedManager extends AudioModelManager {
  _DelayedManager(Directory root) : super(root: root);
  final verified = Completer<List<String>>();
  @override
  Future<List<String>> verify(RealtimeModelSpec spec) => verified.future;
}

class _FakePitch extends BasicPitchService {
  _FakePitch() : super(modelPath: 'unused.tflite');
  final generated = <Completer<KaraokePitchTrack>>[];
  final requests = <Uri>[];

  @override
  Future<KaraokePitchTrack> generateFromMedia({
    required Uri mediaUri,
    Map<String, String> headers = const {},
    required List<TimedLyricLine> lines,
    String keyword = '',
    String artist = '',
    dynamic cancellationToken,
    void Function(BasicPitchProgress progress)? onProgress,
  }) {
    requests.add(mediaUri);
    final completer = Completer<KaraokePitchTrack>();
    generated.add(completer);
    return completer.future;
  }
}

const _spec = RealtimeModelSpec(
  id: 'test',
  name: 'test',
  directory: 'test',
  engine: RealtimeSpeechEngine.onlineTransducer,
  minRamMb: 1,
  needsVad: false,
  files: [],
);

const _lines = [
  TimedLyricLine(index: 0, startMs: 0, endMs: 600, text: 'ab'),
  TimedLyricLine(index: 1, startMs: 600, endMs: 1200, text: 'cd'),
  TimedLyricLine(index: 2, startMs: 1200, endMs: 1800, text: 'ef'),
];

const _track = KaraokePitchTrack(
  text: '#TITLE:t\n',
  noteCount: 3,
  observed: 3,
  pitched: 3,
);

String? _cueText(WidgetTester tester) {
  final widgets = tester.widgetList<SelectableText>(
    find.byType(SelectableText),
  );
  return widgets.isEmpty ? null : widgets.first.data;
}

void main() {
  late Directory root;
  late AudioModelManager manager;

  setUp(() {
    // F8：真实 IO 建目录放在 setUp（真实 async zone），不进入 FakeAsync。
    root = Directory.systemTemp.createTempSync('audio_ai_ui_');
    manager = AudioModelManager(root: root);
  });

  tearDown(() {
    manager.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  testWidgets('模型组件有语言选择、下载/删除/本地导入/取消和默认关闭说明', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AudioModelControls(manager: manager, onSelected: (_) {}),
          ),
        ),
      ),
    );
    expect(find.text('下载模型'), findsOneWidget);
    expect(find.text('删除模型'), findsOneWidget);
    expect(find.text('本地导入'), findsOneWidget);
    expect(find.text('本地模型目录'), findsOneWidget);
    expect(find.textContaining('默认关闭'), findsOneWidget);
    await tester.tap(find.text('本地导入'));
    await tester.pumpAndSettle();
    expect(find.textContaining('目录'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('F6 取消启用后阻塞 verify 迟到返回不重新开启也不拉流', (tester) async {
    final delayed = _DelayedManager(root);
    final controller = RealtimeSubtitleController(
      models: delayed,
      engineFactory: (_, _) async => _Engine(const []),
    );
    final capture = _FakeCapture();
    final clock = AudioSessionClock(sessionId: 1, playing: true);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RealtimeSubtitleControls(
            controller: controller,
            capture: capture,
            clock: clock,
            model: _spec,
            mediaUri: Uri.file('a.mp4'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('启用实时字幕'));
    await tester.pump();
    expect(find.text('取消启用'), findsOneWidget);
    await tester.tap(find.text('取消启用'));
    await tester.pump();
    delayed.verified.complete(const []);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(controller.state, RealtimeSubtitleState.off);
    expect(capture.starts, 0, reason: '取消后不得请求额外媒体');
    expect(find.text('启用实时字幕'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await controller.dispose();
    await capture.dispose();
    await clock.dispose();
    delayed.close();
  });

  testWidgets('F3 叠加层按窗口显示，到期与 stop 立即清屏', (tester) async {
    final engine = _Engine(const [
      EngineUtterance(
        text: 'hello',
        start: Duration(seconds: 1),
        end: Duration(seconds: 2),
      ),
    ]);
    final controller = RealtimeSubtitleController(
      models: manager,
      engineFactory: (_, _) async => engine,
    );
    final pcm = StreamController<PcmFrame>();
    var now = DateTime(2026, 1, 1);
    final clock = AudioSessionClock(
      sessionId: 1,
      playing: true,
      now: () => now,
    );
    expect(
      await tester.runAsync(() => controller.start(spec: _spec, pcm: pcm.stream, clock: clock)),
      isTrue,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RealtimeSubtitleOverlay(
            controller: controller,
            clock: clock,
            onSearchText: (_) {},
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      pcm.add(
        PcmFrame(
          samples: Float32List(320),
          sampleRate: 16000,
          mediaStart: Duration.zero,
          sessionId: 1,
          generation: 0,
        ),
      );
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(_cueText(tester), isNull, reason: '尚未到 cue 起点不得上屏');
    now = now.add(const Duration(milliseconds: 1200));
    await tester.pump(const Duration(milliseconds: 40));
    expect(_cueText(tester), 'hello');
    clock.update(position: const Duration(milliseconds: 1300), playing: false, rate: 1.5);
    await tester.pump(const Duration(milliseconds: 40));
    expect(_cueText(tester), 'hello', reason: '同代际position/playing/rate更新不是seek');
    clock.update(playing: true);
    await tester.pump(const Duration(milliseconds: 40));
    expect(_cueText(tester), 'hello');
    expect(find.text('用当前字幕搜索'), findsOneWidget);
    now = now.add(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 40));
    expect(_cueText(tester), isNull, reason: '窗口到期必须清屏');
    await tester.runAsync(controller.stop);
    await tester.pump(const Duration(milliseconds: 40));
    expect(_cueText(tester), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(controller.dispose);
    await tester.runAsync(pcm.close);
    await tester.runAsync(clock.dispose);
  }, timeout: const Timeout(Duration(seconds: 20)));

  testWidgets('F7 换媒体后 A 的迟到评分轨不能应用，已完成的旧轨也清掉', (tester) async {
    final service = _FakePitch();
    final applied = <KaraokePitchTrack>[];
    Widget build(Uri uri) => MaterialApp(
      home: Scaffold(
        body: BasicPitchControls(
          service: service,
          mediaUri: uri,
          lines: _lines,
          onGenerated: applied.add,
        ),
      ),
    );

    await tester.pumpWidget(build(Uri.file('a.mp4')));
    await tester.tap(find.text('生成音高评分轨'));
    await tester.pump();
    await tester.pumpWidget(build(Uri.file('b.mp4')));
    service.generated.first.complete(_track);
    await tester.pump();
    await tester.pump();
    expect(find.text('应用评分轨'), findsNothing, reason: 'A 的迟到结果不得落到 B');
    expect(applied, isEmpty);

    // 已完成的 A 轨在换歌后同样不可应用。
    await tester.pumpWidget(build(Uri.file('c.mp4')));
    await tester.tap(find.text('生成音高评分轨'));
    await tester.pump();
    service.generated.last.complete(_track);
    await tester.pump();
    await tester.pump();
    expect(find.text('应用评分轨'), findsOneWidget);
    await tester.pumpWidget(build(Uri.file('d.mp4')));
    await tester.pump();
    expect(find.text('应用评分轨'), findsNothing);
    expect(applied, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}

