@TestOn('windows')
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/audio_ai/pcm_sync.dart';
import 'package:webhtv_pc/services/audio_ai/windows_audio_capture.dart';

Uint8List _wav() {
  const count = 32000;
  final data = ByteData(44 + count * 2);
  void text(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  data.setUint32(4, 36 + count * 2, Endian.little);
  text(8, 'WAVEfmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, count * 2, Endian.little);
  for (var i = 0; i < count; i++) {
    data.setInt16(
      44 + i * 2,
      (sin(2 * pi * 440 * i / 16000) * 20000).round(),
      Endian.little,
    );
  }
  return data.buffer.asUint8List();
}

/// 真实采集的异步唤醒有上限等待；与原先 5s 帧超时保持一致。
Future<void> _poll(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (!DateTime.now().isBefore(deadline)) fail('等待真实采集帧超时');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('audio_ai_native_');
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });
  test('真实SourceReader WAV加载、PTS和seek', () async {
    final wav = File('${temp.path}/tone.wav');
    await wav.writeAsBytes(_wav());
    final api = NativeAudioApi(WindowsAudioCapture.resolveLibrary());
    final handle = api.openMedia(wav.path);
    expect(handle, isNot(nullptr), reason: api.error);
    final samples = calloc<Float>(1600), pts = calloc<Int64>();
    try {
      var count = api.read(handle, samples, 1600, pts);
      expect(count, greaterThan(0), reason: api.error);
      expect(pts.value, 0);
      expect(samples.asTypedList(count).any((v) => v.abs() > 0.1), isTrue);
      expect(api.seek(handle, 1000000), 0, reason: api.error);
      count = api.read(handle, samples, 1600, pts);
      expect(count, greaterThan(0));
      expect(pts.value, greaterThanOrEqualTo(1000000));
    } finally {
      api.close(handle);
      calloc.free(samples);
      calloc.free(pts);
    }
  });
  test('真实采集组件输出时钟会话帧，暂停不读取/不堆积', () async {
    final wav = File('${temp.path}/tone.wav');
    await wav.writeAsBytes(_wav());
    // 媒体时钟锚点固定：native start 的墙钟耗时不得计入首帧 PTS。
    var now = DateTime.utc(2026);
    final clock = AudioSessionClock(
      sessionId: 99,
      playing: true,
      now: () => now,
    );
    final capture = WindowsAudioCapture();
    final frames = <PcmFrame>[];
    final pcm = capture.frames.listen(frames.add);
    try {
      expect(
        await capture.start(clock: clock, mediaUri: wav.uri),
        isTrue,
        reason: capture.lastError,
      );
      await _poll(() => frames.isNotEmpty);
      final frame = frames.first;
      expect(frame.sampleRate, 16000);
      expect(frame.sessionId, 99);
      expect(frame.mediaStart, Duration.zero);
      expect(frame.mediaStart.inMilliseconds, lessThan(250));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      clock.update(playing: false);
      // 先排空暂停前已在途的帧，再冻结观察窗口。
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final playing = frames.length;
      expect(playing, greaterThan(0));
      final paused = clock.position;
      now = now.add(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(frames.length, playing, reason: '暂停后不得再输出帧');
      expect(clock.position, paused, reason: '暂停时媒体时钟冻结');
      await capture.stop();
      expect(capture.state, AudioCaptureState.off);
    } finally {
      await pcm.cancel();
      await capture.dispose();
      await clock.dispose();
    }
  });
  test('真实非法URL/native错误不回退系统混音', () {
    final api = NativeAudioApi(WindowsAudioCapture.resolveLibrary());
    expect(api.openMedia('${temp.path}/missing.wav'), nullptr);
    expect(api.error, contains('HRESULT'));
    expect(api.openLoopback(pid), nullptr);
    expect(api.error, contains('TTS'));
  });
  test('授权代理保Cookie/Referer/Range并流式响应，取消销毁上游', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<Map<String, String?>>();
    server.listen((request) async {
      received.complete({
        'cookie': request.headers.value('cookie'),
        'referer': request.headers.value('referer'),
        'range': request.headers.value('range'),
      });
      request.response.statusCode = 206;
      request.response.headers.set('Content-Range', 'bytes 2-4/5');
      request.response.add([2, 3, 4]);
      await request.response.close();
    });
    final proxy = await AuthorizedMediaProxy.open(
      Uri.parse('http://127.0.0.1:${server.port}/media'),
      {'Cookie': 'token=secret', 'Referer': 'https://example.test/'},
    );
    final client = HttpClient();
    try {
      final request = await client.getUrl(proxy.uri);
      request.headers.set('Range', 'bytes=2-');
      final response = await request.close();
      expect(response.statusCode, 206);
      expect(await response.fold<List<int>>([], (a, b) => a..addAll(b)), [
        2,
        3,
        4,
      ]);
      expect(await received.future, {
        'cookie': 'token=secret',
        'referer': 'https://example.test/',
        'range': 'bytes=2-',
      });
    } finally {
      client.close(force: true);
      await proxy.close();
      await server.close(force: true);
    }
  });
}
