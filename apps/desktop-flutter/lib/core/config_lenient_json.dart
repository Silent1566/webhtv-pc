import 'dart:convert';

/// Restricted lenient JSON normalizer for configuration data.
///
/// Accepted beyond strict JSON: // and /* */ comments, single-quoted strings,
/// identifier keys and trailing commas. Values remain JSON only; NaN, Infinity,
/// bare values, expressions, functions and trailing text are rejected.
///
/// Duplicate object keys are preserved when normalized back to JSON text, so the
/// credential ingress still sees repeated root fields and cannot be bypassed by
/// normalization.
class ConfigLenientJson {
  static String normalize(String input) {
    final parser = _Parser(input);
    final value = parser.parseRoot();
    final output = StringBuffer();
    _write(value, output);
    return output.toString();
  }

  static void _write(Object? value, StringBuffer output) {
    if (value is _Object) {
      output.write('{');
      for (var index = 0; index < value.entries.length; index++) {
        if (index != 0) output.write(',');
        final entry = value.entries[index];
        output
          ..write(jsonEncode(entry.key))
          ..write(':');
        _write(entry.value, output);
      }
      output.write('}');
      return;
    }
    if (value is List) {
      output.write('[');
      for (var index = 0; index < value.length; index++) {
        if (index != 0) output.write(',');
        _write(value[index], output);
      }
      output.write(']');
      return;
    }
    if (value is String) {
      output.write(jsonEncode(value));
      return;
    }
    if (value == null || value is bool) {
      output.write('$value');
      return;
    }
    if (value is int) {
      output.write(value.toString());
      return;
    }
    if (value is double) {
      if (!value.isFinite) throw const FormatException('非有限数值');
      output.write(jsonEncode(value));
      return;
    }
    throw const FormatException('不支持的 JSON 值');
  }
}

class _Object {
  final List<MapEntry<String, Object?>> entries = [];
}

class _Parser {
  _Parser(this.source);

  final String source;
  int index = 0;
  int depth = 0;

  Object? parseRoot() {
    final value = _value();
    _skipTrivia();
    if (index != source.length) throw const FormatException('JSON 尾随内容');
    return value;
  }

  Object? _value() {
    _skipTrivia();
    if (index >= source.length) throw const FormatException('JSON 不完整');
    final unit = source.codeUnitAt(index);
    if (unit == 0x7b) return _object();
    if (unit == 0x5b) return _array();
    if (unit == 0x22 || unit == 0x27) return _string();
    if (unit == 0x74) {
      _literal('true');
      return true;
    }
    if (unit == 0x66) {
      _literal('false');
      return false;
    }
    if (unit == 0x6e) {
      _literal('null');
      return null;
    }
    if (unit == 0x2d || (unit >= 0x30 && unit <= 0x39)) return _number();
    throw const FormatException('不支持的 JSON 值');
  }

  _Object _object() {
    _enter();
    index++;
    final result = _Object();
    _skipTrivia();
    if (index < source.length && source.codeUnitAt(index) == 0x7d) {
      index++;
      depth--;
      return result;
    }
    while (true) {
      _skipTrivia();
      final key = _key();
      _skipTrivia();
      if (index >= source.length || source.codeUnitAt(index) != 0x3a) {
        throw const FormatException('JSON 缺少冒号');
      }
      index++;
      result.entries.add(MapEntry(key, _value()));
      _skipTrivia();
      if (index >= source.length) throw const FormatException('JSON 不完整');
      final unit = source.codeUnitAt(index);
      if (unit == 0x7d) {
        index++;
        depth--;
        return result;
      }
      if (unit != 0x2c) throw const FormatException('JSON 缺少逗号');
      index++;
      _skipTrivia();
      if (index < source.length && source.codeUnitAt(index) == 0x7d) {
        index++;
        depth--;
        return result;
      }
    }
  }

  List<Object?> _array() {
    _enter();
    index++;
    final result = <Object?>[];
    _skipTrivia();
    if (index < source.length && source.codeUnitAt(index) == 0x5d) {
      index++;
      depth--;
      return result;
    }
    while (true) {
      result.add(_value());
      _skipTrivia();
      if (index >= source.length) throw const FormatException('JSON 不完整');
      final unit = source.codeUnitAt(index);
      if (unit == 0x5d) {
        index++;
        depth--;
        return result;
      }
      if (unit != 0x2c) throw const FormatException('JSON 缺少逗号');
      index++;
      _skipTrivia();
      if (index < source.length && source.codeUnitAt(index) == 0x5d) {
        index++;
        depth--;
        return result;
      }
    }
  }

  String _key() {
    if (index >= source.length) throw const FormatException('JSON 不完整');
    final unit = source.codeUnitAt(index);
    if (unit == 0x22 || unit == 0x27) return _string();
    final match = RegExp(r'[A-Za-z_$][A-Za-z0-9_$]*')
        .matchAsPrefix(source, index);
    if (match == null) throw const FormatException('JSON 键非法');
    index = match.end;
    return match[0]!;
  }

  String _string() {
    final quote = source.codeUnitAt(index);
    index++;
    final output = StringBuffer();
    while (index < source.length) {
      final unit = source.codeUnitAt(index);
      if (unit == quote) {
        index++;
        return output.toString();
      }
      if (unit < 0x20) throw const FormatException('字符串含控制字符');
      if (unit != 0x5c) {
        output.writeCharCode(unit);
        index++;
        continue;
      }
      index++;
      if (index >= source.length) throw const FormatException('字符串不完整');
      final escaped = source.codeUnitAt(index);
      switch (escaped) {
        case 0x22:
        case 0x27:
        case 0x5c:
        case 0x2f:
          output.writeCharCode(escaped);
          index++;
          break;
        case 0x62:
          output.writeCharCode(0x08);
          index++;
          break;
        case 0x66:
          output.writeCharCode(0x0c);
          index++;
          break;
        case 0x6e:
          output.writeCharCode(0x0a);
          index++;
          break;
        case 0x72:
          output.writeCharCode(0x0d);
          index++;
          break;
        case 0x74:
          output.writeCharCode(0x09);
          index++;
          break;
        case 0x75:
          if (index + 4 >= source.length) {
            throw const FormatException('Unicode 转义不完整');
          }
          var value = 0;
          for (var offset = 1; offset <= 4; offset++) {
            final digit = _hex(source.codeUnitAt(index + offset));
            value = (value << 4) | digit;
          }
          output.writeCharCode(value);
          index += 5;
          break;
        default:
          throw const FormatException('非法转义');
      }
    }
    throw const FormatException('字符串不完整');
  }

  Object _number() {
    final match = RegExp(
      r'-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?',
    ).matchAsPrefix(source, index);
    if (match == null) throw const FormatException('数值非法');
    index = match.end;
    final text = match[0]!;
    final integer = int.tryParse(text);
    if (integer != null) return integer;
    final value = double.tryParse(text);
    if (value == null || !value.isFinite) {
      throw const FormatException('非有限数值');
    }
    return value;
  }

  void _literal(String literal) {
    if (!source.startsWith(literal, index)) {
      throw const FormatException('不支持的 JSON 值');
    }
    index += literal.length;
  }

  void _enter() {
    depth++;
    if (depth > 64) throw const FormatException('JSON 容器深度超过 64');
  }

  void _skipTrivia() {
    while (index < source.length) {
      final unit = source.codeUnitAt(index);
      if (unit == 0x20 || unit == 0x09 || unit == 0x0a || unit == 0x0d) {
        index++;
        continue;
      }
      if (unit == 0x2f && index + 1 < source.length) {
        final next = source.codeUnitAt(index + 1);
        if (next == 0x2f) {
          index += 2;
          while (index < source.length && source.codeUnitAt(index) != 0x0a) {
            index++;
          }
          continue;
        }
        if (next == 0x2a) {
          final end = source.indexOf('*/', index + 2);
          if (end < 0) throw const FormatException('注释不完整');
          index = end + 2;
          continue;
        }
      }
      return;
    }
  }

  int _hex(int unit) {
    if (unit >= 0x30 && unit <= 0x39) return unit - 0x30;
    if (unit >= 0x61 && unit <= 0x66) return unit - 0x61 + 10;
    if (unit >= 0x41 && unit <= 0x46) return unit - 0x41 + 10;
    throw const FormatException('Unicode 转义非法');
  }
}
