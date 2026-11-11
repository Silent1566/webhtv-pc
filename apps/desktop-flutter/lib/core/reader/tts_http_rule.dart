import 'dart:convert';

import 'reader_models.dart';

class TtsHttpRequest {
  TtsHttpRequest(this.uri, this.method, this.body, this.headers);
  final Uri uri;
  final String method;
  final String? body;
  final Map<String, String> headers;
}

class TtsHttpRule {
  TtsHttpRule._(this.config, this.url, this.method, this.body, this.headers);
  final TtsCustomConfig config;
  final String url;
  final String method;
  final String? body;
  final Map<String, String> headers;
  factory TtsHttpRule.parse(TtsCustomConfig config) {
    final raw = config.url.trim();
    if (raw.isEmpty || raw.contains('@js:') || raw.length > 32768) {
      throw const FormatException('在线引擎规则为空、过长或含不支持的脚本');
    }
    var url = raw;
    Map<String, dynamic> options = {};
    for (
      var i = raw.lastIndexOf(',');
      i >= 0;
      i = raw.lastIndexOf(',', i - 1)
    ) {
      try {
        final decoded = jsonDecode(raw.substring(i + 1));
        if (decoded is Map<String, dynamic>) {
          options = decoded;
          url = raw.substring(0, i).trim();
          break;
        }
      } on FormatException {
        /* URL中的逗号不是选项。 */
      }
    }
    final method = '${options['method'] ?? 'GET'}'.toUpperCase();
    if (method != 'GET' && method != 'POST') {
      throw const FormatException('仅支持GET/POST');
    }
    final body = options['body'] == null
        ? null
        : options['body'] is Map
        ? jsonEncode(options['body'])
        : '${options['body']}';
    if (method == 'POST' && (body == null || body.isEmpty)) {
      throw const FormatException('POST规则缺少body');
    }
    if (options.keys.any(
      (k) => ['loginUrl', 'loginUi', 'loginCheckJs', 'jsLib'].contains(k),
    )) {
      throw const FormatException('不支持登录/JS规则');
    }
    final headers = <String, String>{};
    final header = config.header.trim();
    if (header.startsWith('{')) {
      final value = jsonDecode(header);
      if (value is! Map) throw const FormatException('Header必须是对象');
      headers.addAll(value.map((k, v) => MapEntry('$k', '$v')));
    } else {
      for (final line in header.split('\n')) {
        final i = line.indexOf(':');
        if (i > 0) {
          headers[line.substring(0, i).trim()] = line.substring(i + 1).trim();
        }
      }
    }
    if (options['headers'] is Map) {
      headers.addAll(
        (options['headers'] as Map).map((k, v) => MapEntry('$k', '$v')),
      );
    }
    final rule = TtsHttpRule._(config, url, method, body, headers);
    rule.build('验证', 5);
    return rule;
  }
  TtsHttpRequest build(String text, int speed) {
    final uri = Uri.parse(render(url, text, speed));
    if (!['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('引擎仅支持HTTP(S)地址，禁止文件/进程/内嵌凭证');
    }
    return TtsHttpRequest(
      uri,
      method,
      body == null ? null : render(body!, text, speed),
      headers,
    );
  }

  static String render(String template, String text, int speed) {
    return template.replaceAllMapped(
      RegExp(r'\{\{(.*?)\}\}', dotAll: true),
      (match) => _evaluate(match.group(1)!.trim(), text, speed),
    );
  }

  static String _evaluate(String expression, String text, int speed) {
    if (expression == 'speakText') return text;
    if (expression == 'speakSpeed') return '$speed';
    if (expression.startsWith('java.encodeURI(') && expression.endsWith(')')) {
      final value = _evaluate(
        expression.substring(15, expression.length - 1).trim(),
        text,
        speed,
      );
      return Uri.encodeFull(value);
    }
    if (expression.startsWith('String(') && expression.endsWith(')')) {
      return _evaluate(
        expression.substring(7, expression.length - 1).trim(),
        text,
        speed,
      );
    }
    final n = _Arithmetic(expression, speed).parse();
    if (!n.isFinite) throw const FormatException('算术结果无效');
    return n == n.roundToDouble()
        ? '${n.toInt()}'
        : n
              .toStringAsFixed(4)
              .replaceFirst(RegExp(r'0+$'), '')
              .replaceFirst(RegExp(r'\.$'), '');
  }
}

class _Arithmetic {
  _Arithmetic(this.text, this.speed);
  final String text;
  final int speed;
  int pos = 0;
  void space() {
    while (pos < text.length && text[pos].trim().isEmpty) {
      pos++;
    }
  }

  bool accept(String c) {
    space();
    if (pos < text.length && text[pos] == c) {
      pos++;
      return true;
    }
    return false;
  }

  double parse() {
    final n = expression();
    space();
    if (pos != text.length) throw const FormatException('不支持的模板表达式');
    return n;
  }

  double expression() {
    var n = term();
    while (true) {
      if (accept('+')) {
        n += term();
      } else if (accept('-')) {
        n -= term();
      } else {
        return n;
      }
    }
  }

  double term() {
    var n = factor();
    while (true) {
      if (accept('*')) {
        n *= factor();
      } else if (accept('/')) {
        n /= factor();
      } else {
        return n;
      }
    }
  }

  double factor() {
    if (accept('+')) return factor();
    if (accept('-')) return -factor();
    if (accept('(')) {
      final n = expression();
      if (!accept(')')) throw const FormatException('缺少右括号');
      return n;
    }
    space();
    if (text.startsWith('speakSpeed', pos)) {
      pos += 10;
      return speed.toDouble();
    }
    final match = RegExp(r'\d+(?:\.\d+)?|\.\d+').matchAsPrefix(text, pos);
    if (match == null) throw const FormatException('不支持的模板表达式（禁止脚本）');
    pos = match.end;
    return double.parse(match.group(0)!);
  }
}
