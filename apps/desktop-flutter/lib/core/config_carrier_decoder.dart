import 'dart:convert';

import 'app_error.dart';
import 'config_cipher.dart';

/// Bounded decoding of data-only configuration carriers.
///
/// This is intentionally not an evaluator: every carrier must decode to plain
/// JSON text (strict first, then the restricted lenient grammar). Errors never
/// include plaintext or the original carrier.
class ConfigCarrierDecoder {
  static const int maxBytes = 8 * 1024 * 1024;
  static const int maxLayers = 3;

  static String decode(String input) {
    _checkSize(input);
    var current = input;
    var layers = 0;
    while (true) {
      var text = current;
      if (text.startsWith('\ufeff')) text = text.substring(1);
      final trimmed = text.trim();
      if (trimmed.isEmpty) return text;
      if (_isStrictJson(trimmed)) {
        _checkStrictDepth(trimmed);
        return trimmed;
      }
      if (layers >= maxLayers) break;
      final next =
          _unwrapPre(trimmed) ?? _tryAes(trimmed) ?? _tryBase64(trimmed);
      if (next == null) break;
      _checkSize(next);
      layers++;
      current = next;
    }
    return current;
  }

  /// Whether a pasted value is self-describing data rather than a path.
  static bool looksLikeInlineCarrier(String input) {
    var text = input;
    if (text.startsWith('\ufeff')) text = text.substring(1);
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) return true;
    if (_isPreTagStart(trimmed)) return true;
    if (trimmed.startsWith('2423')) return true;
    if (_looksLikeLenientDocument(trimmed)) return true;
    final payload = _base64Payload(trimmed, minLength: 16);
    if (payload == null) return false;
    try {
      final decoded = utf8.decode(base64.decode(base64.normalize(payload)));
      return _looksLikeJsonOrCarrier(decoded.trim());
    } on FormatException {
      return false;
    }
  }

  static bool _looksLikeJsonOrCarrier(String text) =>
      text.startsWith('{') ||
      text.startsWith('[') ||
      text.startsWith('<pre') ||
      text.startsWith('2423') ||
      _looksLikeLenientDocument(text);

  static bool _looksLikeLenientDocument(String text) {
    if (text.startsWith('//')) {
      final line = text.indexOf('\n');
      return line >= 0 && _looksLikeLenientDocument(text.substring(line + 1));
    }
    if (text.startsWith('/*')) {
      final end = text.indexOf('*/', 2);
      return end >= 0 && _looksLikeLenientDocument(text.substring(end + 2));
    }
    final trimmed = text.trimLeft();
    return trimmed.startsWith('{') || trimmed.startsWith('[');
  }

  static bool _isPreTagStart(String text) {
    if (!text.startsWith('<pre')) return false;
    if (text.length <= 4) return true;
    final next = text.codeUnitAt(4);
    return next == 0x3e || next == 0x2f || _isSpace(next);
  }

  static String? _unwrapPre(String text) {
    if (!_isPreTagStart(text)) return null;
    var index = 4;
    var quote = 0;
    while (index < text.length) {
      final unit = text.codeUnitAt(index);
      if (quote != 0) {
        if (unit == quote) quote = 0;
      } else if (unit == 0x22 || unit == 0x27) {
        quote = unit;
      } else if (unit == 0x3e) {
        break;
      } else if (unit == 0x3c) {
        return null;
      }
      index++;
    }
    if (index >= text.length) return null;
    final content = text.substring(index + 1);
    const closing = '</pre>';
    if (!content.endsWith(closing)) return null;
    return content.substring(0, content.length - closing.length);
  }

  static String? _tryAes(String text) {
    if (!text.startsWith('2423')) return null;
    return ConfigCipher.decrypt2423(text);
  }

  static String? _base64Payload(String text, {required int minLength}) {
    final separator = text.lastIndexOf('**');
    final payload = (separator < 0 ? text : text.substring(separator + 2))
        .replaceAll(RegExp(r'\s+'), '');
    if (payload.length < minLength) return null;
    if (!RegExp(r'^[A-Za-z0-9+/_-]+={0,2}$').hasMatch(payload)) return null;
    return payload;
  }

  static String? _tryBase64(String text) {
    final payload = _base64Payload(text, minLength: 4);
    if (payload == null) return null;
    try {
      final decoded = utf8.decode(base64.decode(base64.normalize(payload)));
      if (!_looksLikeJsonOrCarrier(decoded.trim())) return null;
      return decoded;
    } on FormatException {
      return null;
    }
  }

  static bool _isStrictJson(String text) {
    try {
      jsonDecode(text);
      return true;
    } on FormatException {
      return false;
    }
  }

  static void _checkStrictDepth(String text) {
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (final unit in text.codeUnits) {
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (unit == 0x5c) {
          escaped = true;
        } else if (unit == 0x22) {
          inString = false;
        }
      } else if (unit == 0x22) {
        inString = true;
      } else if (unit == 0x7b || unit == 0x5b) {
        depth++;
        if (depth > 64) {
          throw AppError(AppErrorKind.configInvalid, 'JSON 容器深度超过 64');
        }
      } else if (unit == 0x7d || unit == 0x5d) {
        depth--;
      }
    }
  }

  static void _checkSize(String text) {
    if (utf8.encode(text).length > maxBytes) {
      throw AppError(AppErrorKind.configTooLarge, '配置文本超过大小上限（8 MiB）');
    }
  }

  static bool _isSpace(int unit) =>
      unit == 0x20 || unit == 0x09 || unit == 0x0a || unit == 0x0d;
}
