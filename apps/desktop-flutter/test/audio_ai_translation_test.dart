import 'dart:convert';
import 'dart:async';

import 'package:webhtv_pc/services/ai_completion_client.dart';

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/audio_ai/srt_cues.dart';
import 'package:webhtv_pc/services/audio_ai/srt_translation_service.dart';

SrtTranslationRequest _request(String srt) => SrtTranslationRequest(
  document: SrtDocument.parse(srt),
  sourceLanguage: 'en',
);

const _srt =
    '1\n'
    '00:00:01,000 --> 00:00:02,000\n'
    'one\n\n'
    '2\n'
    '00:00:02,000 --> 00:00:03,000\n'
    'two\n\n'
    '3\n'
    '00:00:03,000 --> 00:00:04,000\n'
    'three\n\n'
    '4\n'
    '00:00:04,000 --> 00:00:05,000\n'
    'four\n';

void main() {
  late Directory cacheDir;
  test('4块仅2worker不丢块，实际并发不超过2且完整单调进度', () async {
    var active = 0, maxActive = 0;
    final progress = <double>[];
    final service = SrtTranslationService(
      chunkCount: 4,
      maxConcurrency: 2,
      runner: (prompt) async {
        active++;
        if (active > maxActive) maxActive = active;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        active--;
        return RegExp(
          r'^(\d+)\|\|',
          multiLine: true,
        ).allMatches(prompt).map((m) => '${m.group(1)}||译').join('\n');
      },
    );
    final result = await service.translate(
      _request(_srt),
      onProgress: (p) => progress.add(p.value),
    );
    expect(result.ok, isTrue);
    expect(maxActive, 2);
    expect(progress, [0.25, 0.5, 0.75, 1]);
  });
  test('token取消正在等待的请求，整包不写缓存', () async {
    final token = AiCancellationToken();
    final pending = Completer<String>();
    final service = SrtTranslationService(
      runner: (_) => pending.future,
      cacheDir: cacheDir,
    );
    final result = service.translate(_request(_srt), cancellationToken: token);
    token.cancel();
    final cancelled = await result.timeout(const Duration(seconds: 1));
    expect(cancelled.reason, 'cancelled');
    expect(cancelled.translatedSrt, isEmpty);
    expect(await cacheDir.list().toList(), isEmpty);
  });
  test('重复cue ID不可覆盖原译文', () {
    expect(
      () => parseChunkTranslations('1||a\n1||b', expected: [1]),
      throwsA(isA<SrtChunkFormatException>()),
    );
  });
  setUp(() async {
    cacheDir = await Directory.systemTemp.createTemp('audio_ai_srt_');
  });

  tearDown(() async {
    if (await cacheDir.exists()) await cacheDir.delete(recursive: true);
  });

  test('分块并发成功：时间轴与序号保持源 SRT，只替换文本', () async {
    final seen = <String>[];
    final service = SrtTranslationService(
      runner: (prompt) async {
        seen.add(prompt);
        final ids = RegExp(
          r'^(\d+)\|\|',
          multiLine: true,
        ).allMatches(prompt).map((m) => int.parse(m.group(1)!)).toSet();
        return ids.map((id) => '$id||译$id').join('\n');
      },
      maxConcurrency: 2,
      chunkCount: 2,
      cacheDir: cacheDir,
    );
    final result = await service.translate(_request(_srt));
    expect(result.status, SrtTranslationStatus.translated);
    expect(result.chunkCount, 2);
    expect(result.originalSrt, _srt);
    expect(
      result.translatedSrt,
      contains('1\n00:00:01,000 --> 00:00:02,000\n译1'),
    );
    expect(
      result.translatedSrt,
      contains('4\n00:00:04,000 --> 00:00:05,000\n译4'),
    );
    expect(seen, hasLength(2));
  });

  test('失败重试并缩块：每请求最多 3 次尝试后二分', () async {
    var attempts = 0;
    final service = SrtTranslationService(
      runner: (prompt) async {
        attempts++;
        if (attempts <= 3) throw Exception('boom');
        final ids = RegExp(
          r'^(\d+)\|\|',
          multiLine: true,
        ).allMatches(prompt).map((m) => int.parse(m.group(1)!)).toSet();
        return ids.map((id) => '$id||译$id').join('\n');
      },
      maxConcurrency: 1,
      chunkCount: 1,
      cacheDir: cacheDir,
      retryDelay: Duration.zero,
    );
    final result = await service.translate(_request(_srt));
    expect(result.ok, isTrue);
    expect(attempts, greaterThan(3));
    expect(result.attemptCount, greaterThan(3));
  });

  test('ID 校验失败且无法缩到单条时整包失败，不写缓存', () async {
    final service = SrtTranslationService(
      runner: (prompt) async => '9||越界',
      maxConcurrency: 1,
      chunkCount: 1,
      cacheDir: cacheDir,
      retryDelay: Duration.zero,
    );
    final result = await service.translate(_request(_srt));
    expect(result.status, SrtTranslationStatus.error);
    expect(result.translatedSrt, isEmpty);
    expect(await cacheDir.list().toList(), isEmpty);
  });

  test('整包成功后命中缓存', () async {
    var calls = 0;
    final service = SrtTranslationService(
      runner: (prompt) async {
        calls++;
        final ids = RegExp(
          r'^(\d+)\|\|',
          multiLine: true,
        ).allMatches(prompt).map((m) => int.parse(m.group(1)!)).toSet();
        return ids.map((id) => '$id||译$id').join('\n');
      },
      maxConcurrency: 1,
      chunkCount: 1,
      cacheDir: cacheDir,
    );
    await service.translate(_request(_srt));
    final second = await service.translate(_request(_srt));
    expect(second.status, SrtTranslationStatus.cacheHit);
    expect(calls, 1);
  });

  test('缓存内容为完整 SRT 且可再次解析（重启保真）', () async {
    final service = SrtTranslationService(
      runner: (prompt) async => RegExp(r'^(\d+)\|\|', multiLine: true)
          .allMatches(prompt)
          .map((m) => '${m.group(1)}||译${m.group(1)}')
          .join('\n'),
      maxConcurrency: 1,
      chunkCount: 1,
      cacheDir: cacheDir,
    );
    final result = await service.translate(_request(_srt));
    final files = await cacheDir.list().toList();
    expect(files, hasLength(1));
    final text = await File(files.single.path).readAsString();
    expect(text, result.translatedSrt);
    expect(SrtDocument.parse(text).cues, hasLength(4));
    expect(utf8.decode(utf8.encode(text)), text);
  });
}
