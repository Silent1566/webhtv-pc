import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../core/reader/reader_models.dart';
import 'tts_engines.dart';

/// Sec-MS-GEC：Windows epoch 秒数按 300 秒取整后转 100 纳秒刻度，拼 Token 求 SHA-256 大写十六进制。
String gec(DateTime now, String token) {
  var ticks = now.millisecondsSinceEpoch ~/ 1000 + 11644473600;
  ticks -= ticks % 300;
  ticks *= 10000000;
  return sha256.convert(utf8.encode('$ticks$token')).toString().toUpperCase();
}

/// Edge 协议的一帧 SSML 请求（含 header 段），音色/语速/音调按源实现映射。
String ssmlFor(String requestId, String text, TtsOptions options) {
  final timestamp = DateTime.now().toUtc().toIso8601String().replaceFirst(
    RegExp(r'\.\d+Z$'),
    'Z',
  );
  final escaped = text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll("'", '&apos;')
      .replaceAll('"', '&quot;');
  final voice = options.voice.isEmpty
      ? EdgeTtsEngine.defaultVoice
      : options.voice;
  return 'X-RequestId:$requestId\r\n'
      'Content-Type:application/ssml+xml\r\n'
      'X-Timestamp:$timestamp\r\n'
      'Path:ssml\r\n\r\n'
      "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='zh-CN'>"
      "<voice name='$voice'>"
      "<prosody pitch='${options.pitchHz}' rate='${options.ratePercent}' volume='+0%'>$escaped</prosody>"
      '</voice></speak>';
}

/// 微软 Edge「大声朗读」引擎（免 Key，Neural 音色）。
///
/// 生产传输是真实 `wss://speech.platform.bing.com` WebSocket：
/// 1) 连接时带 `ConnectionId`/`Sec-MS-GEC`/`Sec-MS-GEC-Version`/`TrustedClientToken`；
/// 2) 先发 `speech.config` 文本帧，再发 `ssml` 文本帧；
/// 3) 服务端以二进制帧返回音频（前 2 字节大端为 header 长度），以 `turn.end` 结束本轮。
///
/// 与源实现的差异：按 `X-RequestId` 匹配每个待合成片段（靠「最近一次连接」复用会在并发时串音），
/// 并复用同一条 WebSocket 顺序合成，避免每句重新握手。
///
/// 该协议非公开稳定接口，上游可能调整（`Sec-MS-GEC-Version` 需与客户端版本常量同步）；
/// 失败时如实抛错，由控制器降级/提示，不影响系统音源。
class EdgeTtsEngine implements TtsEngine {
  EdgeTtsEngine({
    Uri? endpoint,
    this.clientToken = '6A5AA1D4EAFF4E9FB37E23D68491D6F4',
    this.chromiumVersion = '143.0.3650.75',
    this.connectTimeout = const Duration(seconds: 12),
    this.turnTimeout = const Duration(seconds: 25),
  }) : endpoint =
           endpoint ??
           Uri.parse(
             'wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1',
           );

  static const String defaultVoice = 'zh-CN-XiaoxiaoNeural';
  static const String outputFormat = 'audio-24khz-48kbitrate-mono-mp3';

  /// 内置中文 Neural 音色；id 直接用于 SSML 的 voice name。
  static const List<(String, String)> voiceCatalog = [
    ('zh-CN-XiaoxiaoNeural', '晓晓 · 女声（通用）'),
    ('zh-CN-XiaoyiNeural', '晓伊 · 女声（年轻）'),
    ('zh-CN-YunxiNeural', '云希 · 男声（通用）'),
    ('zh-CN-YunjianNeural', '云健 · 男声（浑厚）'),
    ('zh-CN-YunxiaNeural', '云夏 · 童声'),
    ('zh-CN-YunyangNeural', '云扬 · 男声（播音）'),
    ('zh-CN-liaoning-XiaobeiNeural', '晓北 · 东北口音'),
    ('zh-CN-shaanxi-XiaoniNeural', '晓妮 · 陕西方言'),
  ];

  final Uri endpoint;
  final String clientToken;
  final String chromiumVersion;
  final Duration connectTimeout;
  final Duration turnTimeout;

  WebSocket? _socket;

  /// 每个 requestId 的在途合成轮：累积音频帧，`turn.end` 时才完成。
  ///
  /// 源实现（`EdgeTtsEngine.java:351-372`）同样按 X-RequestId 累积多帧到 turn.end；
  /// 首个非空帧就完成会截断真实 Edge 拆分的多帧音频。
  final Map<String, _EdgeTurn> _turns = {};

  @override
  Future<List<TtsVoice>> voices() async => [
    for (final voice in voiceCatalog) TtsVoice(voice.$1, voice.$2, 'zh-CN'),
  ];

  @override
  Future<TtsAudio> synthesize(String text, TtsOptions options) async {
    final clean = _clean(text);
    if (clean.isEmpty) throw StateError('该片段没有可朗读内容');
    final socket = await _connect();
    final requestId = _randomId();
    final completer = _turns[requestId] = _EdgeTurn();
    try {
      socket.add(ssmlFor(requestId, clean, options));
      final audio = await completer.future.timeout(
        turnTimeout,
        onTimeout: () {
          throw StateError('微软语音响应超时');
        },
      );
      return TtsAudio(audio, 'mp3');
    } finally {
      _turns.remove(requestId);
    }
  }

  Future<WebSocket> _connect() async {
    final existing = _socket;
    if (existing != null) return existing;
    final now = DateTime.now().toUtc();
    final uri = endpoint.replace(
      queryParameters: {
        'ConnectionId': _randomId(),
        'Sec-MS-GEC': gec(now, clientToken),
        'Sec-MS-GEC-Version': '1-$chromiumVersion',
        'TrustedClientToken': clientToken,
      },
    );
    final WebSocket socket;
    try {
      socket = await WebSocket.connect(
        uri.toString(),
        headers: {
          'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0',
        },
      ).timeout(connectTimeout);
    } on Object {
      _fail();
      throw StateError('无法连接微软语音服务（网络或协议变更）');
    }
    socket.listen(
      _onEvent,
      onError: (Object _) => _fail(socket),
      onDone: () => _fail(socket),
      cancelOnError: true,
    );
    socket.add(_speechConfig());
    return _socket = socket;
  }

  void _onEvent(Object? event) {
    if (event is String) {
      if (!event.contains('turn.end')) return;
      final requestId = _header(event, 'X-RequestId');
      final turn = _turns.remove(requestId);
      if (turn == null || turn.isCompleted) return;
      final bytes = turn.audio.takeBytes();
      if (bytes.isEmpty) {
        // 只有 turn.end 没有音频时如实失败，不返回空音频冒充成功。
        turn.completeError(StateError('微软语音没有返回音频'));
      } else {
        turn.complete(bytes);
      }
      return;
    }
    if (event is! List<int> || event.length < 2) return;
    final headerLength = (event[0] << 8) | event[1];
    if (headerLength + 2 > event.length) return;
    final header = utf8.decode(
      event.sublist(2, headerLength + 2),
      allowMalformed: true,
    );
    if (_header(header, 'Path') != 'audio') return;
    final turn = _turns[_header(header, 'X-RequestId')];
    if (turn == null || turn.isCompleted) return;
    // 累积多帧：真实 Edge 把一段音频拆成多个二进制帧，收到 turn.end 才算本轮完成。
    turn.audio.add(event.sublist(headerLength + 2));
  }

  String _speechConfig() {
    final timestamp = DateTime.now().toUtc().toIso8601String();
    const config =
        '{"context":{"synthesis":{"audio":{"metadataoptions":{'
        '"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},'
        '"outputFormat":"$outputFormat"}}}}';
    return 'X-Timestamp:$timestamp\r\n'
        'Content-Type:application/json; charset=utf-8\r\n'
        'Path:speech.config\r\n\r\n$config\r\n';
  }

  /// 从协议 header 段里取值（大小写不敏感，容忍首尾空白）。
  static String? _header(String raw, String name) {
    for (final line in raw.split('\r\n')) {
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      if (line.substring(0, colon).trim().toLowerCase() == name.toLowerCase()) {
        return line.substring(colon + 1).trim();
      }
    }
    return null;
  }

  void _fail([WebSocket? source]) {
    if (source != null && !identical(source, _socket)) return;
    final socket = _socket;
    _socket = null;
    if (socket != null) unawaited(socket.close());
    final pending = _turns.values.toList();
    _turns.clear();
    for (final turn in pending) {
      if (!turn.isCompleted) turn.completeError(StateError('微软语音连接已断开'));
    }
  }

  @override
  void cancel() => _fail();

  @override
  Future<void> dispose() async {
    final socket = _socket;
    _fail();
    await socket?.close();
  }

  static String _randomId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }

  /// 去掉朗读引擎不认识的装饰字符（对齐源实现 cleanText 的保留集合）。
  static String _clean(String text) {
    final pattern = RegExp(
      "[\\p{L}\\p{N}\\s，。！？；：、（）《》【】“”‘’…—,.!?;:()\\[\\]'\"\\-]",
      unicode: true,
    );
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      final character = String.fromCharCode(rune);
      if (pattern.hasMatch(character)) buffer.write(character);
    }
    return buffer.toString().trim();
  }
}

/// 一轮合成的在途状态：累积该 requestId 的全部音频帧，`turn.end` 时一次性交出。
class _EdgeTurn {
  final Completer<Uint8List> completer = Completer<Uint8List>();
  final BytesBuilder audio = BytesBuilder();

  Future<Uint8List> get future => completer.future;
  bool get isCompleted => completer.isCompleted;
  void complete(Uint8List bytes) => completer.complete(bytes);
  void completeError(Object error) => completer.completeError(error);
}
