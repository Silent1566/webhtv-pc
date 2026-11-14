/// 直播弹幕：帧解析与重连策略（设计文档 §13.1「直播弹幕」、§21 Phase 3）。
///
/// 本层是纯逻辑，不建立 WebSocket 连接、不触碰 UI。规则**逐条对齐 Android
/// `com.fongmi.android.tv.player.danmaku` 的 `LiveDanmakuParser` 与
/// `LiveDanmakuRetryPolicy`，保证两端对同一协议源的解析结果一致。
///
/// 直播弹幕来源是 `ws://`/`wss://` 的 JSON 帧流：
///
/// ```json
/// {"type":"chat","message":"你好","color":"#FFFFFF"}
/// {"type":"superchat","message":"醒目弹幕","color":"#FFAA00"}
/// {"type":"online","data":12345}
/// ```
///
/// - `chat` → 普通弹幕；`superchat` → 醒目弹幕（用更大的字号区分）；
/// - `online` → 在线人数（不上屏，只更新人数显示）；
/// - 其余类型 / 空 message / 超上限 / 非法 JSON → `invalid`（丢弃并计数）。
library;

import 'dart:convert';
import 'dart:math' as math;

/// 直播弹幕文本类型（对齐 Android `LiveDanmakuMessage.Type`）。
enum LiveDanmakuMessageType {
  /// 普通弹幕。
  normal,

  /// 醒目弹幕（superchat）。
  superChat,
}

/// 解析产物分类（对齐 Android `LiveDanmakuParser.Result.Kind`）。
enum LiveDanmakuFrameKind {
  /// 一条可上屏的弹幕。
  message,

  /// 在线人数更新（不上屏）。
  online,

  /// 无法解析（空帧/非法 JSON/类型不支持/文本超限）→ 丢弃。
  invalid,
}

/// 一条直播弹幕帧（对齐 Android `LiveDanmakuMessage`）。
///
/// 直播弹幕是**实时流**：这里只携带收到时刻（host clock）与代次（会话第几代），
/// 渲染时直接入队上屏，不做按播放位置的过滤（实时流本来就没有“开始时刻”）。
class LiveDanmakuFrame {
  const LiveDanmakuFrame({
    required this.type,
    required this.text,
    required this.color,
    required this.receivedAtMs,
    required this.generation,
  });

  final LiveDanmakuMessageType type;
  final String text;

  /// ARGB 颜色（解析时已补不透明 alpha）。
  final int color;

  /// 宿主收到该帧的时刻（`Stopwatch` 语义，用于渲染排序）。
  final int receivedAtMs;

  /// 会话代次（换源/重连后递增，用于丢弃迟到的旧代次帧）。
  final int generation;

  /// 醒目弹幕字号是普通弹幕的 1.2 倍（普通弹幕用 16sp，与静态弹幕默认一致）。
  double get textSizeSp => 16 * (type == LiveDanmakuMessageType.superChat ? 1.2 : 1.0);

  Map<String, Object?> toJson() => {
    'type': type.name,
    'text': text,
    'color': color,
    'receivedAtMs': receivedAtMs,
    'generation': generation,
  };
}

/// 直播弹幕解析结果（对齐 Android `LiveDanmakuParser.Result`）。
class LiveDanmakuParseResult {
  const LiveDanmakuParseResult({required this.kind, this.frame, this.online = -1});

  final LiveDanmakuFrameKind kind;

  /// [kind] 为 message 时非空。
  final LiveDanmakuFrame? frame;

  /// [kind] 为 online 时的在线人数。
  final int online;

  bool get isAccepted => kind != LiveDanmakuFrameKind.invalid;

  static LiveDanmakuParseResult invalid() =>
      const LiveDanmakuParseResult(kind: LiveDanmakuFrameKind.invalid);
}

/// 单帧大小上限（对齐 Android `MAX_FRAME_BYTES = 64 * 1024`）。
const int maxLiveDanmakuFrameBytes = 64 * 1024;

/// 单条弹幕文本代码点上限（对齐 Android `MAX_MESSAGE_CODE_POINTS = 120`）。
const int maxLiveDanmakuCodePoints = 120;

/// 解析一帧直播弹幕（对齐 Android `LiveDanmakuParser.parse`）。
LiveDanmakuParseResult parseLiveDanmakuFrame(
  String frame, {
  required int receivedAtMs,
  required int generation,
}) {
  if (frame.trim().isEmpty) {
    return LiveDanmakuParseResult.invalid();
  }
  if (_utf8Length(frame) > maxLiveDanmakuFrameBytes) {
    return LiveDanmakuParseResult.invalid();
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(frame);
  } catch (_) {
    return LiveDanmakuParseResult.invalid();
  }
  if (decoded is! Map) return LiveDanmakuParseResult.invalid();
  final map = Map<String, Object?>.from(decoded);

  final typeKey = map['type'];
  if (typeKey is! String) return LiveDanmakuParseResult.invalid();
  final type = typeKey.toLowerCase();

  if (type == 'online') {
    final data = map['data'];
    if (data is num) {
      final online = data.toInt();
      if (online >= 0) {
        return LiveDanmakuParseResult(
          kind: LiveDanmakuFrameKind.online,
          online: online,
        );
      }
    }
    return LiveDanmakuParseResult.invalid();
  }

  final LiveDanmakuMessageType messageType;
  if (type == 'chat') {
    messageType = LiveDanmakuMessageType.normal;
  } else if (type == 'superchat') {
    messageType = LiveDanmakuMessageType.superChat;
  } else {
    return LiveDanmakuParseResult.invalid();
  }

  final message = map['message'];
  if (message is! String) return LiveDanmakuParseResult.invalid();
  final normalized = normalizeLiveDanmakuText(message);
  if (normalized.isEmpty) return LiveDanmakuParseResult.invalid();

  final color = _parseLiveDanmakuColor(map['color'] is String
      ? (map['color'] as String)
      : '');

  return LiveDanmakuParseResult(
    kind: LiveDanmakuFrameKind.message,
    frame: LiveDanmakuFrame(
      type: messageType,
      text: normalized,
      color: color,
      receivedAtMs: receivedAtMs,
      generation: generation,
    ),
  );
}

/// 规范化弹幕文本（对齐 Android `LiveDanmakuParser.normalizeText`）：
/// 丢弃 ISO 控制字符、折叠空白（连续多个空白 → 单个空格）、
/// 去除首尾空白、截断到 [maxLiveDanmakuCodePoints] 个代码点。
String normalizeLiveDanmakuText(String text) {
  if (text.isEmpty) return '';
  final buffer = StringBuffer();
  var previousSpace = false;
  var accepted = 0;
  for (final rune in text.runes) {
    if (accepted >= maxLiveDanmakuCodePoints) break;
    if (_isIsoControl(rune)) continue;
    if (_isWhitespace(rune)) {
      if (buffer.length == 0 || previousSpace) continue;
      buffer.write(' ');
      previousSpace = true;
      accepted++;
      continue;
    }
    buffer.writeCharCode(rune);
    previousSpace = false;
    accepted++;
  }
  // 去除尾随空白。
  var result = buffer.toString();
  var end = result.length;
  for (var index = result.length - 1; index >= 0; index--) {
    if (!_isWhitespace(result.codeUnitAt(index))) break;
    end = index;
  }
  if (end < result.length) result = result.substring(0, end);
  return result;
}

bool _isIsoControl(int rune) => rune < 0x20 || (rune >= 0x7F && rune < 0xA0);

bool _isWhitespace(int rune) {
  switch (rune) {
    case 0x09:
    case 0x0A:
    case 0x0B:
    case 0x0C:
    case 0x0D:
    case 0x20:
    case 0x85:
    case 0xA0:
    case 0x1680:
    case 0x2028:
    case 0x2029:
    case 0x202F:
    case 0x205F:
    case 0x3000:
      return true;
    default:
      return rune >= 0x2000 && rune <= 0x200A;
  }
}

/// 解析颜色（对齐 Android `LiveDanmakuParser.parseColor`）：
/// 只接受 `#RRGGBB` 十六进制，否则取默认白；解析时补不透明 alpha。
int _parseLiveDanmakuColor(String color) {
  if (!RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(color)) {
    return 0xFFFFFFFF;
  }
  final parsed = int.tryParse(color.substring(1), radix: 16);
  if (parsed == null) return 0xFFFFFFFF;
  return 0xFF000000 | parsed;
}

/// UTF-8 字节长度（对齐 Android `LiveDanmakuParser.utf8Length`）。
int _utf8Length(String value) {
  var bytes = 0;
  for (final rune in value.runes) {
    bytes += rune <= 0x7F
        ? 1
        : (rune <= 0x7FF ? 2 : (rune <= 0xFFFF ? 3 : 4));
    if (bytes > maxLiveDanmakuFrameBytes) return bytes;
  }
  return bytes;
}

/// 直播弹幕重连策略（对齐 Android `LiveDanmakuRetryPolicy`）。
///
/// - 指数退避：`min(30s, 1s << attempt)` 为上限，再加 [MIN_DELAY_MS, 上限] 的抖动；
/// - 首次失败等待 [MIN_DELAY_MS]（250ms），尝试次数越多越慢；
/// - `shouldRetry*`：客户端错误（4xx，429 除外）与 TLS/协议错误不重试，
///   服务端错误（429/5xx）、网络 IO 失败、以及特定关闭码（1001/1006/1011/1012/1013）重试。
class LiveDanmakuRetryPolicy {
  LiveDanmakuRetryPolicy._();

  static const int minDelayMs = 250;
  static const int maxDelayMs = 30000;
  static const int maxAttempts = 20;

  /// 下一次重试等待（毫秒）。[randomUnit] 取 [0,1) 的随机数，测试可注入固定值。
  static int nextDelayMs(int attempt, double randomUnit) {
    final shift = _clampInt(attempt, 0, maxAttempts);
    final cap = math.min(maxDelayMs, 1000 << shift);
    if (cap <= minDelayMs) return minDelayMs;
    final unit = _clampDouble(randomUnit, 0.0, 1.0 - 1e-9);
    return minDelayMs + (unit * (cap - minDelayMs + 1)).floor();
  }

  /// 关闭码是否应该重试（对齐 Android `shouldRetryClose`）。
  static bool shouldRetryClose(int code) =>
      code == 1001 || code == 1006 || code == 1011 || code == 1012 || code == 1013;

  /// 连接失败是否应该重试（对齐 Android `shouldRetryFailure` 的语义）：
  /// - HTTP 401/403/404/4xx（429 除外）→ 不重试；
  /// - 429/5xx → 重试；
  /// - 网络层（IO）失败 → 重试；协议/TLS 校验失败 → 不重试。
  static bool shouldRetryFailure({int? httpCode, bool networkFailure = false}) {
    if (httpCode != null) {
      if (httpCode == 401 || httpCode == 403 || httpCode == 404 ||
          (httpCode >= 400 && httpCode < 429)) {
        return false;
      }
      if (httpCode == 429 || httpCode >= 500) return true;
    }
    return networkFailure;
  }

  static int _clampInt(int value, int min, int max) =>
      value < min ? min : (value > max ? max : value);

  static double _clampDouble(double value, double min, double max) =>
      value < min ? min : (value > max ? max : value);
}