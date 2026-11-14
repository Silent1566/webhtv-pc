import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/reader/reader_models.dart';
import 'package:webhtv_pc/services/reader/media_kit_reader_audio.dart';

/// 本地 fixture 播放器：模拟 media_kit 的 completed/error 事件与 stop 行为。
class FakePlayer implements ReaderMediaPlayer {
  final _completed = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final opened = <String>[];
  int stops = 0;
  int disposals = 0;
  bool completesOnOpen = true;
  bool failsOnOpen = false;
  final openedSignal = Completer<void>();

  @override
  Stream<bool> get completed => _completed.stream;
  @override
  Stream<String> get error => _error.stream;
  @override
  Future<void> openFile(String path) async {
    opened.add(path);
    if (!openedSignal.isCompleted) openedSignal.complete();
    if (failsOnOpen) throw StateError('打开文件失败');
    if (completesOnOpen) _completed.add(true);
  }

  @override
  Future<void> stop() async {
    stops++;
    // 真实播放器 stop 后也会给出 completed 事件，用来复现重复收尾。
    _completed.add(true);
  }

  @override
  Future<void> dispose() async {
    disposals++;
    await _completed.close();
    await _error.close();
  }

  void emitCompleted() => _completed.add(true);
  void emitError(String message) => _error.add(message);
}

TtsAudio audioBytes() => TtsAudio(Uint8List.fromList([1, 2, 3]), 'mp3');

void main() {
  test('正常播完只收尾一次，且停止后不抛 Future already completed', () async {
    final player = FakePlayer();
    final output = MediaKitReaderAudio(player: player);
    await output.play(audioBytes());
    expect(player.opened, hasLength(1));
    expect(File(player.opened.single).existsSync(), isFalse);
    // 播完后再 stop：源实现会先 complete 已完成的 Future 并抛异常。
    await output.stop();
    await output.stop();
    expect(player.stops, 2);
    await output.dispose();
    expect(player.disposals, 1);
  });
  test('停止打断播放后等待方被收尾，再次播放正常工作', () async {
    final player = FakePlayer()..completesOnOpen = false;
    final output = MediaKitReaderAudio(player: player);
    final first = output.play(audioBytes());
    await player.openedSignal.future;
    expect(player.opened, hasLength(1));
    await output.stop();
    await first.timeout(const Duration(seconds: 2));
    player.completesOnOpen = true;
    await output.play(audioBytes()).timeout(const Duration(seconds: 2));
    expect(player.opened, hasLength(2));
    await output.dispose();
  });
  test('打开音频失败也删除临时文件并取消监听', () async {
    final player = FakePlayer()..failsOnOpen = true;
    final output = MediaKitReaderAudio(player: player);
    try {
      await expectLater(output.play(audioBytes()), throwsStateError);
      expect(File(player.opened.single).existsSync(), isFalse);
      expect(player._completed.hasListener, isFalse);
      expect(player._error.hasListener, isFalse);
      await output.stop();
    } finally {
      await output.dispose();
    }
  });
  test('播放错误如实抛出，且错误后停止不再重复收尾', () async {
    final player = FakePlayer()..completesOnOpen = false;
    final output = MediaKitReaderAudio(player: player);
    final playing = output.play(audioBytes());
    await player.openedSignal.future;
    player.emitError('解码失败');
    await expectLater(playing, throwsStateError);
    expect(File(player.opened.single).existsSync(), isFalse);
    expect(player._completed.hasListener, isFalse);
    expect(player._error.hasListener, isFalse);
    await output.stop();
    await output.dispose();
  });
}
