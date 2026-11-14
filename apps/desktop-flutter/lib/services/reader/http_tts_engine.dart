import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/reader/reader_models.dart';
import '../../core/reader/tts_http_rule.dart';
import 'tts_engines.dart';

/// 通用在线朗读引擎：按 legado 兼容子集的 URL 规则请求音频流。
///
/// 同时用于内置百度在线语音（[BaiduTtsEngine]）与用户自定义引擎
/// （规则来自 [ReaderPreferences.custom]）。生产是真实 HTTP 请求；
/// 测试用本地 HTTP fixture，不把它当作在线服务可用的证据。
class HttpTtsEngine implements TtsEngine {
  HttpTtsEngine(this.config);

  final TtsCustomConfig config;
  TtsHttpRule? _rule;
  final Set<HttpClient> _clients = {};

  TtsHttpRule get rule => _rule ??= TtsHttpRule.parse(config);

  @override
  Future<List<TtsVoice>> voices() async => const [];

  @override
  Future<TtsAudio> synthesize(String text, TtsOptions options) async {
    final request = rule.build(text, _speakSpeed(options.rate));
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    _clients.add(client);
    try {
      final outgoing = await client.openUrl(request.method, request.uri);
      request.headers.forEach(outgoing.headers.set);
      if (request.method == 'POST' && request.body != null) {
        outgoing.headers.contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
          charset: 'utf-8',
        );
        outgoing.write(request.body);
      }
      final response = await outgoing.close().timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw StateError('在线语音响应超时'),
      );
      if (response.statusCode != 200) {
        throw StateError('在线语音 HTTP ${response.statusCode}');
      }
      final contentType =
          response.headers.value(HttpHeaders.contentTypeHeader) ?? '';
      if (_isAudio(contentType)) {
        final bytes = await response
            .fold<BytesBuilder>(
              BytesBuilder(),
              (builder, chunk) => builder..add(chunk),
            )
            .then((builder) => builder.takeBytes());
        if (bytes.isEmpty) throw StateError('在线语音没有返回音频');
        return TtsAudio(bytes, 'mp3');
      }
      // 引擎改成返回错误文本时读一小段，便于用户诊断（对齐源实现的错误体提示）。
      final body = await response
          .fold<BytesBuilder>(
            BytesBuilder(),
            (builder, chunk) => builder..add(chunk),
          )
          .then((builder) => builder.takeBytes());
      final preview = utf8.decode(
        body.take(256).toList(),
        allowMalformed: true,
      );
      throw StateError('返回 $contentType：$preview');
    } on SocketException catch (error) {
      throw StateError('在线语音网络错误：${error.message}');
    } finally {
      _clients.remove(client);
      client.close(force: true);
    }
  }

  static bool _isAudio(String contentType) {
    final value = contentType.toLowerCase();
    return value.startsWith('audio') ||
        value.startsWith('application/octet-stream') ||
        value.startsWith('application/mpeg') ||
        value.startsWith('binary/octet-stream');
  }

  /// 朗读面板的 0.5x–2.0x → 引擎速度刻度 1..7（源实现 speakSpeed 的同一映射）。
  static int _speakSpeed(double rate) => (rate * 5).round().clamp(1, 7);

  @override
  void cancel() {
    final clients = _clients.toList();
    _clients.clear();
    for (final client in clients) {
      client.close(force: true);
    }
  }

  @override
  Future<void> dispose() async => cancel();
}

/// 内置百度在线语音（翻译发音接口，免 Key，真实 HTTP 生产路径）。
class BaiduTtsEngine extends HttpTtsEngine {
  BaiduTtsEngine()
    : super(
        const TtsCustomConfig(
          name: '百度在线语音',
          url:
              'https://fanyi.baidu.com/gettts?lan=zh&text={{java.encodeURI(speakText)}}'
              '&spd={{speakSpeed}}&source=web',
          contentType: 'audio/mpeg',
        ),
      );
}
