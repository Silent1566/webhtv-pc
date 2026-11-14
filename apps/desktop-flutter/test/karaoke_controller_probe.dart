import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:webhtv_pc/core/karaoke/karaoke.dart';
import 'package:webhtv_pc/services/karaoke/karaoke_controller.dart';
import 'package:webhtv_pc/services/karaoke/track_repository.dart';
import 'package:webhtv_pc/services/karaoke/windows_mic_source.dart';

void check(bool value, String name) {
  if (!value) throw StateError('FAIL: $name');
  print('PASS: $name');
}

class FakeMic implements KaraokeMicSource {
  FakeMic({this.available = true});
  final bool available;
  final _controller = StreamController<KaraokePitchSample>.broadcast();
  bool started = false;
  int stops = 0;
  @override
  bool get isAvailable => available;
  @override
  String get unavailableReason => available ? '' : 'no capture device';
  @override
  Stream<KaraokePitchSample> get samples => _controller.stream;
  void emit(KaraokePitchSample sample) => _controller.add(sample);
  @override
  Future<bool> start() async {
    if (!available) return false;
    started = true;
    return true;
  }

  @override
  Future<void> stop() async {
    stops++;
    started = false;
  }

  Future<void> close() => _controller.close();
}

class SlowRepository extends KaraokeTrackRepository {
  SlowRepository(super.dataDirectory, this.gate);
  final Completer<void> gate;
  @override
  Future<KaraokeTrack?> load(KaraokeMedia media) async {
    await gate.future;
    return UltraStarParser.parse('#BPM:60\n: 0 10 69 la\nE');
  }
}

Float32List tone(double hz, {int length = 2048, double amplitude = .3}) =>
    Float32List.fromList(
      List.generate(
        length,
        (i) => amplitude * math.sin(2 * math.pi * hz * i / 44100),
      ),
    );

Future<void> main() async {
  final root = await Directory.systemTemp.createTemp('karaoke_ctrl_probe');
  final repo = KaraokeTrackRepository(root);
  final clock = AudioSessionClock(sessionId: 1, playing: true);
  final mic = FakeMic();
  final controller = KaraokeController(
    clock: clock,
    repository: repo,
    mic: mic,
  );
  final production = KaraokeController(clock: clock, repository: repo);
  check(
    production.mic is WindowsKaraokeMicSource && !production.isActive,
    'default real Windows adapter remains inactive at construction',
  );
  await production.dispose();
  final song = const KaraokeMedia(
    key: 'k',
    url: 'D:/a.mp4',
    title: 'Probe',
    artist: 'Singer',
    durationMs: 20000,
  );
  await repo.importText(
    song,
    'probe.txt',
    '#TITLE:Probe\n#BPM:60\n#GAP:0\n: 0 60 69 la\nE',
  );
  await controller.bindMedia(song);
  check(
    controller.track != null && controller.track!.hasScoredNotes,
    'bind loads repository track',
  );
  check((await controller.start()) && mic.started, 'start opens microphone');
  check(
    controller.state.status == KaraokeStatus.scoring,
    'status scoring with track',
  );

  final detector = YinPitchDetector(44100);
  final pcm = tone(440);
  final pitch = detector.detect(pcm, timestampMs: 0);
  check(
    pitch.frequencyHz > 438 && pitch.frequencyHz < 442 && pitch.confidence > .9,
    'synthetic PCM pitch before controller',
  );

  controller.updateClock(position: Duration.zero);
  for (var t = 100; t <= 3000; t += 100) {
    controller.pushSample(pitch);
    controller.updateClock(position: Duration(milliseconds: t));
  }
  check(
    controller.snapshot.hitWeightMs > 0 && controller.snapshot.scorePercent > 0,
    'real pitch advances reference score',
  );
  check(controller.result.grade.isNotEmpty, 'result grade exposed');

  final before = controller.snapshot.hitWeightMs;
  for (var t = 3100; t <= 3500; t += 100) {
    controller.pushSample(pitch);
    controller.updateClock(position: Duration(milliseconds: t));
  }
  check(controller.snapshot.hitWeightMs > before, 'playing accumulates score');

  controller.pause();
  final paused = controller.snapshot.hitWeightMs;
  controller.pushSample(pitch);
  check(
    controller.snapshot.hitWeightMs == paused,
    'pause freezes accumulation',
  );

  controller.seek(const Duration(milliseconds: 500));
  check(
    controller.snapshot.hitWeightMs == 0 && clock.generation > 0,
    'seek resets score and bumps clock generation',
  );

  final stale = const KaraokePitchSample(
    timestampMs: 9,
    frequencyHz: 1000,
    volume: 1,
    confidence: 1,
  );
  controller.pushSample(stale, generation: clock.generation - 1);
  check(
    controller.sample.frequencyHz != stale.frequencyHz,
    'stale generation sample dropped',
  );

  await controller.stop();
  check(!mic.started && mic.stops > 0, 'stop releases microphone');
  check(
    controller.state.status == KaraokeStatus.inactive,
    'stop returns inactive',
  );

  final unavailable = FakeMic(available: false);
  final c2 = KaraokeController(
    clock: AudioSessionClock(),
    repository: repo,
    mic: unavailable,
  );
  check(
    !(await c2.start()) && c2.state.status == KaraokeStatus.micUnavailable,
    'unavailable mic surfaces reason',
  );
  check(c2.micUnavailableReason.isNotEmpty, 'mic unavailable reason exposed');
  await c2.dispose();
  await unavailable.close();

  final freeRepo = KaraokeTrackRepository(
    await Directory.systemTemp.createTemp('karaoke_ctrl_probe2'),
  );
  final freeMic = FakeMic();
  final c3 = KaraokeController(
    clock: AudioSessionClock(),
    repository: freeRepo,
    mic: freeMic,
  );
  await c3.bindMedia(
    const KaraokeMedia(
      key: 'f',
      url: 'D:/f.mp4',
      title: 'Unbound',
      artist: '',
      durationMs: 30000,
    ),
    lyrics: [
      const TimedLyricLine(index: 0, startMs: 0, endMs: 8000, text: 'la'),
    ],
  );
  await c3.start();
  for (var t = 100; t <= 5000; t += 100) {
    c3.pushSample(
      const KaraokePitchSample(
        timestampMs: 0,
        frequencyHz: 440,
        volume: .3,
        confidence: 1,
      ),
    );
    c3.updateClock(position: Duration(milliseconds: t), playing: true);
  }
  check(
    c3.state.status == KaraokeStatus.freeSing && c3.snapshot.totalWeightMs > 0,
    'unbound media falls back to free sing scoring',
  );
  await c3.dispose();
  await freeMic.close();

  final gate = Completer<void>();
  final slow = SlowRepository(
    await Directory.systemTemp.createTemp('karaoke_ctrl_probe3'),
    gate,
  );
  final c4 = KaraokeController(clock: AudioSessionClock(), repository: slow);
  final pending = c4.bindMedia(song);
  c4.selectTrack(null);
  gate.complete();
  await pending;
  check(
    c4.track == null,
    'stale repository result not applied after media change',
  );
  await c4.dispose();

  check(KaraokeMicSignal.rms(tone(440)) > .2, 'mic signal rms helper');
  final signal = KaraokeMicSignal(sampleRate: 44100);
  final quiet = Float32List(2048);
  final filtered = signal.process(Float32List.fromList(quiet));
  check(filtered == 0, 'bandpass keeps silence silent');
  final gated = signal.apply(
    const KaraokePitchSample(
      timestampMs: 0,
      frequencyHz: 440,
      volume: .001,
      confidence: .9,
    ),
    .001,
    .001,
  );
  check(gated.frequencyHz == 0, 'adaptive gate clears quiet frame');

  await mic.close();
  await root.delete(recursive: true);
  print('ALL CONTROLLER PROBES PASSED');
}
