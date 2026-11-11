import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/tmdb_playback.dart';
import 'package:webhtv_pc/services/karaoke/track_repository.dart';
import 'package:webhtv_pc/services/karaoke/windows_mic_source.dart';

import 'package:webhtv_pc/core/ai_config.dart';
import 'package:webhtv_pc/core/audio_ai/audio_ai.dart';
import 'package:webhtv_pc/services/ai_integration.dart';
import 'package:webhtv_pc/services/app_paths.dart';

void main() {
  test('播放器AI会话默认不采集，真实clock普通更新不换代，seek明确换代', () async {
    final temp = await Directory.systemTemp.createTemp('parity-audio-');
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/config',
        'data': '${temp.path}/data',
        'cache': '${temp.path}/cache',
        'state': '${temp.path}/log',
      },
    );
    final session = PlayerAudioAiSession(
      paths: paths,
      config: const AiConfig(),
    );
    try {
      expect(session.capture.state, AudioCaptureState.off);
      expect(session.realtime.state, RealtimeSubtitleState.off);
      final generation = session.clock.generation;
      session.update(
        position: const Duration(seconds: 8),
        playing: false,
        rate: 2,
      );
      expect(session.clock.position, const Duration(seconds: 8));
      expect(session.clock.generation, generation);
      session.seek(const Duration(seconds: 30));
      expect(session.clock.generation, generation + 1);
      expect(session.clock.position, const Duration(seconds: 30));
      expect(session.clock.rate, 2);
    } finally {
      await session.dispose();
      await temp.delete(recursive: true);
    }
  });

  test('真实SRT转歌词使用原序号和时间，不捏造逐词timing', () {
    final document = SrtDocument.parse(
      '9\n00:00:01,200 --> 00:00:02,600\n真实歌词\n\n12\n00:00:03,000 --> 00:00:04,000\n第二行',
    );
    final lines = lyricLinesFromSrt(document);
    expect(lines.map((l) => l.index), [9, 12]);
    expect(lines.first.startMs, 1200);
    expect(lines.first.endMs, 2600);
    expect(lines.first.words, isEmpty);
    expect(lines.first.text, '真实歌词');
  });

  test('Q03 F 拥有的麦克风在 session.dispose 只释放一次', () async {
    final temp = await Directory.systemTemp.createTemp('parity-mic-');
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/config',
        'data': '${temp.path}/data',
        'cache': '${temp.path}/cache',
        'state': '${temp.path}/log',
      },
    );
    final session = PlayerAudioAiSession(
      paths: paths,
      config: const AiConfig(),
    );
    // 只断言所有权/类型与释放，不依赖本机是否有 native DLL/录音设备
    // （WindowsKaraokeMicSource.isAvailable 在无 DLL 环境必为 false，属环境边界）。
    expect(session.micSource, isA<WindowsKaraokeMicSource>());
    expect(
      identical(session.karaoke.mic, session.micSource),
      isTrue,
      reason: '生产必须显式使用 Windows 真实源，而不是 Silent 默认',
    );
    expect(session.micDisposed, isFalse);
    await session.dispose();
    expect(session.micDisposed, isTrue);
    // 幂等：重复释放不得再关一次流/抛异常。
    await session.dispose();
    expect(session.micDisposed, isTrue);
    await temp.delete(recursive: true);
  });

  test('Q04 真实 HLS 鉴权头只经本机代理转发，不暴露源地址', () async {
    final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    String? seenAuth;
    Object? seenReferer;
    source.listen((request) {
      seenAuth = request.headers.value('x-auth');
      seenReferer = request.headers.value('referer');
      request.response.write('media-bytes');
      request.response.close();
    });
    final proxy = await AuthorizedMediaProxy.open(
      Uri.parse('http://127.0.0.1:${source.port}/secret/play.m3u8?token=abc'),
      const {'x-auth': 'token-1', 'referer': 'https://site.test/'},
    );
    final client = HttpClient();
    try {
      expect(proxy.uri.host, '127.0.0.1');
      expect(proxy.uri.toString(), isNot(contains('source.test')));
      expect(proxy.uri.toString(), isNot(contains('secret/play')));
      final response = await (await client.getUrl(proxy.uri)).close();
      expect(await utf8.decoder.bind(response).join(), 'media-bytes');
      expect(seenAuth, 'token-1');
      expect(seenReferer, 'https://site.test/');
    } finally {
      client.close(force: true);
      await proxy.close();
      await source.close(force: true);
    }
  });

  test('Q04 译文写入独立轨且不同代际不互相覆盖', () async {
    final temp = await Directory.systemTemp.createTemp('parity-translated-');
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/config',
        'data': '${temp.path}/data',
        'cache': '${temp.path}/cache',
        'state': '${temp.path}/log',
      },
    );
    final result = SrtTranslationResult(
      status: SrtTranslationStatus.translated,
      request: SrtTranslationRequest(
        document: SrtDocument.parse('1\n00:00:01,000 --> 00:00:02,000\nhello'),
        sourceLanguage: 'en',
        targetLanguage: 'zh',
      ),
      translatedSrt: '1\n00:00:01,000 --> 00:00:02,000\n你好',
      cueCount: 1,
      chunkCount: 1,
      attemptCount: 1,
      reason: '',
      elapsed: Duration.zero,
    );
    final first = aiTranslatedSubtitle(result, paths, 1);
    final second = aiTranslatedSubtitle(result, paths, 2);
    expect(first.format, 'srt');
    expect(first.lang, 'zh');
    expect(first.name, contains('AI译文'));
    expect(first.url, isNot(second.url));
    expect(Uri.parse(first.url).toFilePath(), contains('audio_ai'));
    await temp.delete(recursive: true);
  });

  test('Q04 BasicPitch生成轨经仓库导入并成为当前评分轨', () async {
    final temp = await Directory.systemTemp.createTemp('parity-karaoke-');
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/config',
        'data': '${temp.path}/data',
        'cache': '${temp.path}/cache',
        'state': '${temp.path}/log',
      },
    );
    final session = PlayerAudioAiSession(
      paths: paths,
      config: const AiConfig(),
    );
    try {
      const media = KaraokeMedia(
        key: 's|v|e1',
        url: 'https://media.test/e1',
        title: '真实歌曲',
        artist: '真实歌手',
        durationMs: 1000,
      );
      await session.karaoke.bindMedia(media);
      const pitch = KaraokePitchTrack(
        text: '#TITLE:真实歌曲\n#ARTIST:真实歌手\n#BPM:300\n#GAP:0\n: 0 4 60 你\n: 10 4 62 好\nE',
        noteCount: 2,
        observed: 2,
        pitched: 2,
      );
      // 仓库层只负责导入缓存轨，不自动切换、不需要开麦；随后显式选为当前评分轨。
      final imported = await session.karaokeRepository.importGenerated(
        media,
        pitch,
      );
      expect(imported.success, isTrue, reason: imported.error);
      expect(imported.track, isNotNull);
      session.karaoke.selectTrack(imported.track);
      expect(session.karaoke.track, isNotNull);
      expect(session.karaoke.state.track, isNotNull);
    } finally {
      await session.dispose();
      await temp.delete(recursive: true);
    }
  });

  test('Q04 逐集播放身份取本集季集，未映射保持 -1', () {
    final base = TmdbPlaybackIdentity.of(
      identity: TmdbIdentity.of(TmdbMediaType.tv, 9),
      episode: VodEpisode(name: '第1集', url: 'u1'),
      flagKey: '线路',
      seasonNumber: 1,
      episodeNumber: 1,
    );
    final mapped = aiPlaybackIdentityForEpisode(
      base,
      VodEpisode(
        name: '第1集',
        url: 'u1',
        extra: const {'tmdb_season_number': 2, 'tmdb_episode_number': 5},
      ),
      '线路',
    );
    expect(mapped!.seasonNumber, 2);
    expect(mapped.episodeNumber, 5);
    final unmapped = aiPlaybackIdentityForEpisode(
      mapped,
      VodEpisode(name: '花絮', url: 'u2'),
      '线路',
    );
    expect(unmapped!.episodeNumber, -1);
  });
}
