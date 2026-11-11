import 'dart:io';

import 'package:webhtv_pc/core/karaoke/karaoke.dart';
import 'package:webhtv_pc/services/karaoke/karaoke_controller.dart';
import 'package:webhtv_pc/services/karaoke/track_repository.dart';

import 'karaoke_controller_probe.dart' show FakeMic;

void check(bool value, String name) {
  if (!value) throw StateError('FAIL: $name');
  stdout.writeln('PASS: $name');
}

Future<void> main() async {
  final root = await Directory.systemTemp.createTemp('karaoke_pause');
  try {
    for (final freeSing in [false, true]) {
      var wallTime = DateTime(2026);
      final clock = AudioSessionClock(playing: true, now: () => wallTime);
      final mic = FakeMic();
      final c = KaraokeController(
        clock: clock,
        repository: KaraokeTrackRepository(root),
        mic: mic,
      );
      const pitch = KaraokePitchSample(
        timestampMs: 0,
        frequencyHz: 440,
        volume: .3,
        confidence: 1,
      );
      try {
        c.selectTrack(
          freeSing
              ? null
              : UltraStarParser.parse('#BPM:60\n#GAP:0\n: 0 60 69 la\nE'),
        );
        c.updateLyrics(const [
          TimedLyricLine(index: 0, startMs: 0, endMs: 8000, text: 'la'),
          TimedLyricLine(index: 1, startMs: 8000, endMs: 16000, text: 'next'),
        ]);
        await c.start();
        for (var t = 0; t <= 4000; t += 100) {
          c.pushSample(pitch);
          c.updateClock(position: Duration(milliseconds: t), playing: true);
        }
        final before = c.snapshot;
        check(
          before.totalWeightMs > 0,
          '${freeSing ? 'free' : 'reference'} earns true pre-pause score',
        );
        c.pause();
        check(clock.playing, 'scoring pause does not pause player clock');
        wallTime = wallTime.add(const Duration(milliseconds: 100));
        check(
          clock.position.inMilliseconds == 4100,
          'shared media clock continues while scoring paused',
        );
        for (var t = 4100; t <= 4900; t += 100) {
          c.updateClock(
            position: Duration(milliseconds: t),
            playing: true,
            rate: 1,
          );
          c.pushSample(pitch);
          c.advance();
        }
        check(
          c.snapshot.totalWeightMs == before.totalWeightMs &&
              c.snapshot.hitWeightMs == before.hitWeightMs &&
              c.snapshot.currentComboMs == before.currentComboMs &&
              c.snapshot.currentLineScorePercent ==
                  before.currentLineScorePercent,
          'user pause gates updates, samples, direct advance and combo/line',
        );
        c.resume();
        check(
          clock.playing && clock.position.inMilliseconds == 4900,
          'resume leaves media clock unchanged',
        );
        c.advance();
        check(
          c.snapshot.totalWeightMs == before.totalWeightMs,
          'resume never backfills paused interval',
        );
        c.updateClock(
          position: const Duration(milliseconds: 5000),
          playing: true,
        );
        check(
          c.snapshot.totalWeightMs == before.totalWeightMs + 100,
          'explicit resume scores exactly next 100ms',
        );
        c.pause();
        await c.start();
        c.updateClock(
          position: const Duration(milliseconds: 5100),
          playing: true,
        );
        check(
          c.snapshot.totalWeightMs == before.totalWeightMs + 200,
          'explicit start also releases user pause',
        );
        c.updateClock(
          position: const Duration(milliseconds: 5200),
          playing: false,
        );
        final mediaPaused = c.snapshot.totalWeightMs;
        c.resume();
        c.pushSample(pitch);
        c.advance();
        check(
          !clock.playing && c.snapshot.totalWeightMs == mediaPaused,
          'media pause is a separate scoring gate',
        );
        c.updateClock(
          position: const Duration(milliseconds: 5500),
          playing: true,
        );
        check(
          c.snapshot.totalWeightMs == mediaPaused,
          'media resume reanchors without catch-up',
        );
        c.updateClock(
          position: const Duration(milliseconds: 5600),
          playing: true,
        );
        check(
          c.snapshot.totalWeightMs == mediaPaused + 100,
          'media resume scores next interval normally',
        );
        await c.stop();
        final stopped = c.snapshot.totalWeightMs;
        check(clock.playing, 'scoring stop does not stop player clock');
        c.updateClock(
          position: const Duration(milliseconds: 5800),
          playing: true,
        );
        c.pushSample(pitch);
        c.advance();
        c.resume();
        c.advance();
        check(
          c.snapshot.totalWeightMs == stopped,
          'inactive direct advance/resume cannot score',
        );
        clock.update(playing: false);
        await c.start();
        check(!clock.playing, 'scoring start cannot resume paused media');
      } finally {
        await c.dispose();
        await mic.close();
        await clock.dispose();
      }
    }
  } finally {
    await root.delete(recursive: true);
  }
  stdout.writeln('ALL PAUSE PROBES PASSED');
}
