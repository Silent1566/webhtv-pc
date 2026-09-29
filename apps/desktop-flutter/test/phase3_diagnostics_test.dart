/// 播放诊断单元测试（设计文档 §10.4、§23）。
///
/// 覆盖 Phase 3 验收「播放诊断能输出引擎、格式、网络和错误」：
/// - 引擎标识与展示名（§23）；
/// - 媒体格式识别（§12.2：m3u8/mp4/dash/flv/rtsp/rtmp/音频/本地文件）；
/// - 网络目标脱敏（§11.3.1：隐藏 query/签名）；
/// - 错误分类与用户提示（§10.4）；
/// - 阶段时序与 `report` 多行诊断文本；
/// - 诊断 JSON 往返与敏感 Header 脱敏。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/playback_diagnostics.dart';
import 'package:webhtv_pc/core/protocol.dart';

void main() {
  group('媒体格式识别（§12.2）', () {
    test('按扩展名识别常见格式', () {
      expect(
        detectMediaFormat('https://h/vod/index.m3u8'),
        MediaFormat.hls,
      );
      expect(detectMediaFormat('https://h/vod/index.m3u8?token=abc'), MediaFormat.hls);
      expect(detectMediaFormat('https://h/vod/movie.mp4'), MediaFormat.mp4);
      expect(detectMediaFormat('https://h/vod/movie.mkv'), MediaFormat.mp4);
      expect(detectMediaFormat('https://h/vod/stream.mpd'), MediaFormat.dash);
      expect(detectMediaFormat('https://h/live.flv'), MediaFormat.flv);
      expect(detectMediaFormat('rtsp://h/live'), MediaFormat.rtsp);
      expect(detectMediaFormat('rtmp://h/live'), MediaFormat.rtmp);
      expect(detectMediaFormat('https://h/song.mp3'), MediaFormat.audio);
      expect(detectMediaFormat('file:///D:/media/movie.mp4'), MediaFormat.file);
    });

    test('无法确定时不猜测，返回 unknown；空地址同样 unknown', () {
      expect(detectMediaFormat('https://h/play?id=1'), MediaFormat.unknown);
      expect(detectMediaFormat(''), MediaFormat.unknown);
      expect(detectMediaFormat(null), MediaFormat.unknown);
    });
  });

  group('网络目标脱敏（§11.3.1）', () {
    test('保留 scheme/host，隐藏 query 与签名', () {
      final target = NetworkTarget.of(
        'https://cdn.example.com/vod/a.m3u8?sign=SECRET&token=abc',
      );
      expect(target.host, 'cdn.example.com');
      expect(target.scheme, 'https');
      expect(target.isSecure, isTrue);
      expect(target.redactedUrl, 'https://cdn.example.com/vod/a.m3u8?...');
      expect(target.redactedUrl, isNot(contains('SECRET')));
      expect(target.redactedUrl, isNot(contains('abc')));
    });

    test('http 不算加密；空地址安全降级', () {
      expect(NetworkTarget.of('http://h/a.mp4').isSecure, isFalse);
      final empty = NetworkTarget.of('');
      expect(empty.host, '');
      expect(empty.redactedUrl, '');
      expect(empty.isSecure, isFalse);
    });
  });

  group('诊断构建（§23 引擎/格式/网络/错误）', () {
    test('成功快照包含引擎、格式、网络与阶段耗时', () {
      final builder = PlaybackDiagnosticsBuilder(
        siteKey: 'fixture-type1',
        flag: '线路一',
        episodeName: '第 1 集',
      );
      builder.setFinalUrl('https://cdn.example.com/vod/a.m3u8?sign=x');
      builder.setHeaders({'User-Agent': 'WebHTV-PC/0.1'});
      builder.addStage(PlaybackStage.load, const Duration(milliseconds: 420));
      builder.addStage(
        PlaybackStage.firstFrame,
        const Duration(milliseconds: 700),
      );
      builder.succeed();
      final diagnostics = builder.build();

      expect(diagnostics.engine, PlaybackEngine.mediaKit);
      expect(diagnostics.format, MediaFormat.hls);
      expect(diagnostics.target.host, 'cdn.example.com');
      expect(diagnostics.siteKey, 'fixture-type1');
      expect(diagnostics.flag, '线路一');
      expect(diagnostics.episodeName, '第 1 集');
      expect(diagnostics.succeeded, isTrue);
      expect(
        diagnostics.elapsedOf(PlaybackStage.load),
        const Duration(milliseconds: 420),
      );
      expect(
        diagnostics.elapsedOf(PlaybackStage.firstFrame),
        const Duration(milliseconds: 700),
      );
      // logLine 供日志记录，不含敏感 query。
      expect(diagnostics.logLine, contains('engine=media-kit/mpv'));
      expect(diagnostics.logLine, contains('format=hls'));
      expect(diagnostics.logLine, contains('host=cdn.example.com'));
      expect(diagnostics.logLine, isNot(contains('sign=x')));
    });

    test('失败快照记录分类、引擎错误与用户提示（§10.4）', () {
      final builder = PlaybackDiagnosticsBuilder();
      builder.setFinalUrl('https://cdn.example.com/vod/a.m3u8');
      builder.addStage(PlaybackStage.load, const Duration(seconds: 20));
      builder.fail(
        kind: 'timeout',
        message: 'load timeout after 20s',
        hint: '播放超时：请重试一次或切换线路',
      );
      final diagnostics = builder.build();

      expect(diagnostics.succeeded, isFalse);
      expect(diagnostics.failureKind, 'timeout');
      expect(diagnostics.failureMessage, 'load timeout after 20s');
      expect(diagnostics.failureHint, contains('重试'));
      final report = diagnostics.report;
      expect(report, contains('结果：失败'));
      expect(report, contains('分类：timeout'));
      expect(report, contains('提示：播放超时'));
      expect(report, contains('引擎错误：load timeout'));
    });

    test('未设置最终地址时回落到入口地址', () {
      final builder = PlaybackDiagnosticsBuilder()..enterUrl = 'https://h/a.mp4';
      final diagnostics = builder.build();
      expect(diagnostics.format, MediaFormat.mp4);
      expect(diagnostics.finalUrl, 'https://h/a.mp4');
    });

    test('超长引擎错误被截断，避免诊断膨胀', () {
      final builder = PlaybackDiagnosticsBuilder()
        ..setFinalUrl('https://h/a.m3u8');
      builder.fail(kind: 'loadFailed', message: 'x' * 500);
      final diagnostics = builder.build();
      expect(diagnostics.failureMessage!.length, lessThanOrEqualTo(301));
      expect(diagnostics.failureMessage, endsWith('…'));
    });
  });

  group('敏感 Header 脱敏（§9.3.1、§23）', () {
    test('Cookie/Authorization 等被替换为 redacted', () {
      final builder = PlaybackDiagnosticsBuilder()
        ..setFinalUrl('https://h/a.m3u8');
      builder.setHeaders({
        'Cookie': 'session=SECRET',
        'Authorization': 'Bearer SECRET',
        'User-Agent': 'WebHTV-PC/0.1',
      });
      final diagnostics = builder.build();
      final report = diagnostics.report;
      expect(report, contains('Cookie=<redacted>'));
      expect(report, contains('Authorization=<redacted>'));
      expect(report, contains('User-Agent=WebHTV-PC/0.1'));
      expect(report, isNot(contains('SECRET')));
    });

    test('isSensitiveHeaderKey 命中常见敏感键', () {
      expect(isSensitiveHeaderKey('Cookie'), isTrue);
      expect(isSensitiveHeaderKey('authorization'), isTrue);
      expect(isSensitiveHeaderKey('X-Api-Key'), isTrue);
      expect(isSensitiveHeaderKey('token'), isTrue);
      expect(isSensitiveHeaderKey('User-Agent'), isFalse);
      expect(isSensitiveHeaderKey('Referer'), isFalse);
    });
  });

  group('诊断序列化（§23）', () {
    test('toJson 含引擎/格式/网络/错误，且可 JSON 编码', () {
      final builder = PlaybackDiagnosticsBuilder(siteKey: 'k', flag: 'f');
      builder
        ..setFinalUrl('https://h/a.m3u8?sign=x')
        ..setHeaders({'Cookie': 'SECRET'});
      builder.addStage(PlaybackStage.load, const Duration(milliseconds: 100));
      builder.fail(kind: 'network', message: 'dns failed', hint: '网络不可达');
      final json = builder.build().toJson();

      expect(json['engine'], PlaybackEngine.mediaKit);
      expect(json['format'], 'hls');
      expect(json['siteKey'], 'k');
      expect(json['flag'], 'f');
      expect(json['succeeded'], isFalse);
      expect(json['failureKind'], 'network');
      expect((json['network']! as Map)['host'], 'h');
      expect((json['timings']! as List), hasLength(1));
      // 可编码且不含明文敏感值。
      final encoded = jsonEncode(json);
      expect(encoded, isNot(contains('SECRET')));
      expect(encoded, isNot(contains('sign=x')));
    });

    test('report 与 logLine 对空诊断安全', () {
      final diagnostics = PlaybackDiagnosticsBuilder().build();
      expect(diagnostics.logLine, isNotEmpty);
      expect(diagnostics.report, contains('播放诊断'));
      // 未开始/未结束：succeeded 为 null。
      expect(diagnostics.succeeded, isNull);
    });
  });
}
