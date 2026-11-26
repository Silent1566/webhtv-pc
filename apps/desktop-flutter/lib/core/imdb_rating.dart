/// IMDb GraphQL 与标题页的分值解析（纯逻辑：不依赖 Flutter、不依赖 dart:io、不发请求）。
///
/// 为什么单独一层：IMDb 分有两个消费方——详情页评分标签（`DetailRatingService`）
/// 与元数据兜底（`ExternalMetaService` 的 `rating` 字段）。两边共用同一份解析，
/// 抓不到时的语义（返回空值、**不抛异常**）才不会各写一套。
///
/// GraphQL 解析 title.ratingsSummary；HTML 兜底先认 JSON-LD aggregateRating，
/// 再认内嵌 ratingsSummary。字段缺失或非法时返回空值。
library;

import 'dart:convert';

/// 一次 IMDb 分值快照。
class ImdbRating {
  const ImdbRating({this.value = '', this.votes = ''});

  /// 取不到分时的唯一空值。
  static const ImdbRating empty = ImdbRating();

  /// 十分制文案（`8.1`）；空串表示没拿到。
  final String value;

  /// 投票数（千分位，`12,345`）；空串表示没拿到。
  final String votes;

  bool get isEmpty => value.isEmpty;

  bool get isNotEmpty => value.isNotEmpty;

  ImdbRating merge(ImdbRating other) => ImdbRating(
    value: value.isEmpty ? other.value : value,
    votes: votes.isEmpty ? other.votes : votes,
  );

  @override
  String toString() => 'ImdbRating(value=$value, votes=$votes)';
}

/// 从 IMDb 标题页 HTML 取分值。取不到返回 [ImdbRating.empty]，**不抛异常**。
ImdbRating parseImdbTitlePage(String html) {
  final text = html.trim();
  if (text.isEmpty) return ImdbRating.empty;
  return (_fromJsonLd(text) ?? _fromEmbeddedSummary(text) ?? ImdbRating.empty);
}

/// JSON-LD：`{"aggregateRating": {"@type": "AggregateRating", "ratingValue": 8.1,
/// "ratingCount": 12345}}`。
ImdbRating? _fromJsonLd(String html) {
  const marker = '"aggregateRating"';
  var index = html.indexOf(marker);
  while (index >= 0) {
    final block = _objectAfter(html, index + marker.length);
    if (block != null) {
      final rating = _readNumber(block, const ['ratingValue', 'rating']);
      if (rating != null) {
        final value = _formatRating(rating);
        if (value.isNotEmpty) {
          final votes = _readNumber(block, const ['ratingCount', 'voteCount']);
          return ImdbRating(value: value, votes: _formatVotes(votes));
        }
      }
    }
    index = html.indexOf(marker, index + marker.length);
  }
  return null;
}

/// 页面内嵌状态：`"ratingsSummary":{"aggregateRating":8.1,"voteCount":12345}`。
ImdbRating? _fromEmbeddedSummary(String html) {
  const marker = '"ratingsSummary"';
  var index = html.indexOf(marker);
  while (index >= 0) {
    final block = _objectAfter(html, index + marker.length);
    if (block != null) {
      final rating = _readNumber(block, const ['aggregateRating']);
      if (rating != null) {
        final value = _formatRating(rating);
        if (value.isNotEmpty) {
          final votes = _readNumber(block, const ['voteCount']);
          return ImdbRating(value: value, votes: _formatVotes(votes));
        }
      }
    }
    index = html.indexOf(marker, index + marker.length);
  }
  return null;
}

/// 从 IMDb GraphQL `title.ratingsSummary` 响应取分值。
///
/// 为什么走 GraphQL：标题页 HTML 会被 AWS WAF 的 JS 挑战拦成 202 空 body（本机实测），
/// 而 `api.graphql.imdb.com` 对同一出口返回 200 与 `aggregateRating`。取不到时返回
/// [ImdbRating.empty]，**不抛异常**。
ImdbRating parseImdbGraphqlRating(Object? json) {
  if (json is! Map) return ImdbRating.empty;
  final data = json['data'];
  if (data is! Map) return ImdbRating.empty;
  final title = data['title'];
  if (title is! Map) return ImdbRating.empty;
  final summary = title['ratingsSummary'];
  if (summary is! Map) return ImdbRating.empty;
  final rating = _numberOf(summary['aggregateRating']);
  if (rating == null) return ImdbRating.empty;
  final value = _formatRating(rating);
  if (value.isEmpty) return ImdbRating.empty;
  return ImdbRating(
    value: value,
    votes: _formatVotes(_numberOf(summary['voteCount'])),
  );
}

double? _numberOf(Object? raw) {
  final parsed = raw is num ? raw.toDouble() : double.tryParse('$raw'.trim());
  if (parsed == null || !parsed.isFinite) return null;
  return parsed;
}

/// 只读取当前属性的对象值，按括号配平切出文本（跳过字符串里的括号）。
String? _objectAfter(String html, int start) {
  var open = start;
  while (open < html.length && html[open].trim().isEmpty) {
    open++;
  }
  if (open >= html.length || html[open] != ':') return null;
  open++;
  while (open < html.length && html[open].trim().isEmpty) {
    open++;
  }
  if (open >= html.length || html[open] != '{') return null;
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = open; i < html.length; i++) {
    final char = html.codeUnitAt(i);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (char == 0x5c) {
        escaped = true;
      } else if (char == 0x22) {
        inString = false;
      }
      continue;
    }
    if (char == 0x22) {
      inString = true;
      continue;
    }
    if (char == 0x7b) {
      depth++;
    } else if (char == 0x7d) {
      depth--;
      if (depth == 0) return html.substring(open, i + 1);
    }
  }
  return null;
}

/// 在对象文本里按 [keys] 顺序找第一个合法数字。
double? _readNumber(String block, List<String> keys) {
  try {
    final decoded = jsonDecode(block);
    if (decoded is! Map) return null;
    for (final key in keys) {
      final value = _numberOf(decoded[key]);
      if (value != null) return value;
    }
  } on FormatException {
    return null;
  }
  return null;
}

/// 十分制文案：`8` → `8.0`，`8.14` → `8.1`；越界返回空串。
String _formatRating(double value) {
  if (!value.isFinite || value <= 0 || value > 10) return '';
  return value.toStringAsFixed(1);
}

/// 投票数千分位；`null` 或 0 返回空串。
String _formatVotes(double? value) {
  if (value == null || !value.isFinite || value <= 0) return '';
  final digits = value.round().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}
