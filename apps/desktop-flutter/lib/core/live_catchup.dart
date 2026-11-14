/// 直播回看（catchup）的模型与 URL 生成（`docs/phase9/design/03` §2）。
///
/// 对齐安卓 `Catchup.java` 的语义：
/// - `type` 为 `default` 时，`source` 本身就是完整地址；
/// - 其余情况（含空串）按 `append` 处理：先做 `replace` 正则替换，
///   再把渲染后的查询串追加到频道地址；
/// - 模板占位：`${(b)yyyyMMddHHmmss}` / `${(e)…}` / `${utc:}` / `${utcend:}`。
///
/// 任何无法解析的输入返回 `null`，由 UI 不显示回看入口（不猜、不伪造）。
library;

/// 回看参数。
class CatchupSpec {
  const CatchupSpec({
    this.type = '',
    this.days = '',
    this.regex = '',
    this.source = '',
    this.replace = '',
  });

  /// `default` / `append` / 空串（按 append 处理）。
  final String type;

  /// 可回看天数（仅展示）。
  final String days;

  /// 频道地址匹配用的正则（`append` 时可做替换定位）。
  final String regex;

  /// 时间模板。
  final String source;

  /// 逗号分隔的 `from,to` 正则替换。
  final String replace;

  bool get isEmpty => source.trim().isEmpty;

  bool get isDefault => type.trim().toLowerCase() == 'default';

  static const CatchupSpec none = CatchupSpec();

  factory CatchupSpec.fromJson(Object? value) {
    if (value is! Map) return none;
    String text(String key) {
      final raw = value[key];
      return raw is String ? raw.trim() : (raw == null ? '' : '$raw');
    }

    return CatchupSpec(
      type: text('type'),
      days: text('days'),
      regex: text('regex'),
      source: text('source'),
      replace: text('replace'),
    );
  }

  /// 从 M3U 属性解析。
  ///
  /// 兼容两种写法：
  /// - `catchup="append" catchup-source="..." catchup-replace="..."`；
  /// - 只写 `catchup="..."`（此时 type 与 source 共用同一个值，安卓同款）。
  factory CatchupSpec.fromAttributes(Map<String, String> attributes) {
    final catchup = (attributes['catchup'] ?? '').trim();
    final source = (attributes['catchup-source'] ?? '').trim();
    final replace = (attributes['catchup-replace'] ?? '').trim();
    final days =
        (attributes['timeshift'] ?? attributes['tvg-rec'] ?? '').trim();
    if (catchup.isEmpty && source.isEmpty) return none;

    // 只有 catchup、没有 catchup-source：把 catchup 当作 type；
    // 若 catchup 看起来像模板（含 `${`），则它同时是 source。
    final type = source.isEmpty && !catchup.contains(r'${') ? catchup : catchup;
    final resolvedSource = source.isNotEmpty
        ? source
        : (catchup.contains(r'${') ? catchup : '');

    return CatchupSpec(
      type: type,
      days: days,
      replace: replace,
      source: resolvedSource,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    if (type.isNotEmpty) 'type': type,
    if (days.isNotEmpty) 'days': days,
    if (regex.isNotEmpty) 'regex': regex,
    if (source.isNotEmpty) 'source': source,
    if (replace.isNotEmpty) 'replace': replace,
  };

  CatchupSpec copyWith({
    String? type,
    String? days,
    String? regex,
    String? source,
    String? replace,
  }) => CatchupSpec(
    type: type ?? this.type,
    days: days ?? this.days,
    regex: regex ?? this.regex,
    source: source ?? this.source,
    replace: replace ?? this.replace,
  );

  @override
  bool operator ==(Object other) =>
      other is CatchupSpec &&
      other.type == type &&
      other.days == days &&
      other.regex == regex &&
      other.source == source &&
      other.replace == replace;

  @override
  int get hashCode => Object.hash(type, days, regex, source, replace);

  @override
  String toString() =>
      'CatchupSpec(type="$type", days="$days", source="$source", '
      'replace="$replace")';
}

final RegExp _tokenPattern = RegExp(r'\$\{([^}]*)\}');
final RegExp _formatTokenPattern = RegExp(
  r'yyyy|MM|dd|HH|mm|ss|SSS|M|d|H|m|s',
);

/// 生成回看地址；无法生成时返回 null。
///
/// [startMs]/[endMs] 是节目单给出的起止时刻（毫秒）。
String? formatCatchupUrl({
  required CatchupSpec spec,
  required String channelUrl,
  required int startMs,
  required int endMs,
}) {
  if (spec.isEmpty) return null;
  final url = channelUrl.trim();
  if (url.isEmpty) return null;
  if (endMs <= startMs) return null;

  var failed = false;
  final rendered = spec.source.replaceAllMapped(_tokenPattern, (match) {
    final token = match.group(1) ?? '';
    final value = _renderToken(token, startMs, endMs);
    if (value == null) failed = true;
    return value ?? '';
  });
  if (failed || rendered.contains(r'${')) return null;

  if (spec.isDefault) return rendered;

  var base = url;
  final replace = spec.replace;
  if (replace.contains(',')) {
    final parts = replace.split(',');
    final from = parts.first;
    final to = parts.sublist(1).join(',');
    if (from.isEmpty) return null;
    try {
      base = base.replaceAll(RegExp(from), to);
    } catch (_) {
      return null;
    }
  }
  var suffix = rendered;
  if (base.contains('?') && suffix.startsWith('?')) {
    suffix = suffix.substring(1);
    return '$base&$suffix';
  }
  return '$base$suffix';
}

String? _renderToken(String raw, int startMs, int endMs) {
  final token = raw.trim();
  if (token == 'utc:') return '${startMs ~/ 1000}';
  if (token == 'utcend:') return '${endMs ~/ 1000}';

  final open = token.indexOf(')');
  if (!token.startsWith('(') || open < 0) return null;
  final kind = token.substring(1, open);
  final fmt = token.substring(open + 1);
  if (kind != 'b' && kind != 'e') return null;
  return formatCatchupTime(kind == 'b' ? startMs : endMs, fmt);
}

/// 按 Java/Android 常用格式格式化时间（本地时区）。
///
/// 支持 `yyyy MM dd HH mm ss SSS M d H m s` 与 `timestamp`（秒）。
/// 未知的字母片段返回 null（宁可不出入口，也不生成坏地址）。
String? formatCatchupTime(int millis, String format) {
  if (format.isEmpty) return null;
  if (format == 'timestamp') return '${millis ~/ 1000}';

  final time = DateTime.fromMillisecondsSinceEpoch(millis);
  final replaced = format.replaceAllMapped(_formatTokenPattern, (match) {
    switch (match.group(0)) {
      case 'yyyy':
        return time.year.toString().padLeft(4, '0');
      case 'MM':
        return time.month.toString().padLeft(2, '0');
      case 'dd':
        return time.day.toString().padLeft(2, '0');
      case 'HH':
        return time.hour.toString().padLeft(2, '0');
      case 'mm':
        return time.minute.toString().padLeft(2, '0');
      case 'ss':
        return time.second.toString().padLeft(2, '0');
      case 'SSS':
        return time.millisecond.toString().padLeft(3, '0');
      case 'M':
        return time.month.toString();
      case 'd':
        return time.day.toString();
      case 'H':
        return time.hour.toString();
      case 'm':
        return time.minute.toString();
      case 's':
        return time.second.toString();
      default:
        return match.group(0)!;
    }
  });

  // 剩余未替换的字母片段（例如 `yyyy年MM月` 里的中文不算）视为不支持。
  if (RegExp(r'[A-Za-z]').hasMatch(replaced)) return null;
  return replaced;
}
