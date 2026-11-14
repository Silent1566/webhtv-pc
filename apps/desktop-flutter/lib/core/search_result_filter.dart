/// 搜索结果相似度过滤（移植上游安卓「默影视」`SearchResultFilter.java`）。
///
/// 语义与上游一一对应（PC 端不做 t2s 繁简转换，上游 `Trans.t2s(false, …)`
/// 在 PC 侧的等价物缺失，直接用原文归一化——归一化里的 NFKC + 小写 + 季数
/// 归一已覆盖绝大多数场景）：
/// - **完全相等** → 100 分；
/// - **候选包含查询**（查询 ≥ 2 字符）→ 按覆盖率打分，封顶 99；
/// - **数字兼容**：查询里的数字序列必须与候选一致（`庆余年2` 不匹配 `庆余年3`）；
/// - 其余走编辑距离相似度，长度差距超过 20% 直接 0 分。
///
/// 阈值语义（上游 `Setting.getSearchSimilarity()` 默认 30，0 = 不过滤）：
/// - 0：不过滤，全部结果可见；
/// - 1~99：按分数 ≥ 阈值过滤；
/// - 100：只保留**完全一致**的标题（上游 `search_filter_similarity_exact`）。
library;

final RegExp _seasonPattern = RegExp(
  r'(?:第\s*([0-9零〇一二三四五六七八九十百两]+)\s*(?:季|部)'
  r'|season\s*0*([0-9]{1,3})'
  r'|\bs\s*0*([0-9]{1,3})(?=\s*(?:e\s*[0-9]{1,4})?\b))',
  caseSensitive: false,
);
final RegExp _nonToken = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// 查询与候选标题是否匹配（阈值 0 时恒为 true）。
bool searchResultMatches(String keyword, String title, int similarityPercent) {
  if (similarityPercent <= 0) return true;
  return searchScore(keyword, title) >= _clamp(similarityPercent);
}

/// 按阈值过滤列表（不修改原表）。
List<T> filterSearchResults<T>(
  List<T> items,
  String keyword,
  int similarityPercent, {
  required String Function(T item) titleOf,
}) {
  if (items.isEmpty || similarityPercent <= 0) return List.of(items);
  final threshold = _clamp(similarityPercent);
  if (threshold == 0) return List.of(items);
  final query = _normalize(keyword);
  if (query.compact.isEmpty) return List.of(items);
  return [
    for (final item in items)
      if (_score(query, _normalize(titleOf(item))) >= threshold) item,
  ];
}

/// 打分入口：0~100，100 表示完全一致。
int searchScore(String keyword, String title) =>
    _score(_normalize(keyword), _normalize(title));

int _score(_Normalized query, _Normalized candidate) {
  if (query.compact.isEmpty || candidate.compact.isEmpty) return 0;
  if (candidate.compact == query.compact) return 100;
  if (_canContain(query) && _contains(candidate, query)) {
    final coverage =
        (query.compact.length * 100 / candidate.compact.length).round();
    return coverage > 99 ? 99 : coverage;
  }
  if (!_numbersCompatible(candidate.digits, query.digits)) return 0;
  final maxLength =
      candidate.compact.length > query.compact.length
      ? candidate.compact.length
      : query.compact.length;
  if (maxLength < 4) return 0;
  final maxGap = maxLength ~/ 5;
  if ((candidate.compact.length - query.compact.length).abs() > maxGap) {
    return 0;
  }
  return (_similarity(candidate.compact, query.compact) * 100).round();
}

int _clamp(int value) => value < 0 ? 0 : (value > 100 ? 100 : value);

bool _canContain(_Normalized query) => query.compact.length >= 2;

bool _contains(_Normalized candidate, _Normalized query) {
  if (_hasHan(query.compact) || query.compact.length >= 3) {
    // 被数字截断的包含不算（`3年` 不匹配 `庆余年3年2班` 的截断位置）。
    var start = candidate.compact.indexOf(query.compact);
    while (start >= 0) {
      if (!_cutsNumericToken(candidate, query, start)) return true;
      start = candidate.compact.indexOf(query.compact, start + 1);
    }
    return false;
  }
  // 拉丁短词按整词匹配（`s2` 不命中 `as234`）。
  final paddedCandidate = ' ${candidate.tokens} ';
  final paddedQuery = ' ${query.tokens} ';
  return paddedCandidate.contains(paddedQuery);
}

bool _cutsNumericToken(_Normalized candidate, _Normalized query, int start) {
  final end = start + query.compact.length;
  final cutsLeading =
      _isDigit(query.compact.codeUnitAt(0)) &&
      start > 0 &&
      _isDigit(candidate.compact.codeUnitAt(start - 1)) &&
      _sameToken(candidate.tokens, start - 1, start);
  final queryLast = query.compact.length - 1;
  final cutsTrailing =
      _isDigit(query.compact.codeUnitAt(queryLast)) &&
      end < candidate.compact.length &&
      _isDigit(candidate.compact.codeUnitAt(end)) &&
      _sameToken(candidate.tokens, end - 1, end);
  return cutsLeading || cutsTrailing;
}

bool _isDigit(int codeUnit) =>
    codeUnit >= 0x30 && codeUnit <= 0x39;

bool _sameToken(String tokens, int leftCompactIndex, int rightCompactIndex) {
  final leftToken = _tokenIndex(tokens, leftCompactIndex);
  return leftToken >= 0 && leftToken == _tokenIndex(tokens, rightCompactIndex);
}

int _tokenIndex(String tokens, int compactIndex) {
  var compactPosition = 0;
  var tokenIndex = 0;
  for (var i = 0; i < tokens.length; i++) {
    if (tokens.codeUnitAt(i) == 0x20) {
      tokenIndex++;
    } else if (compactPosition++ == compactIndex) {
      return tokenIndex;
    }
  }
  return -1;
}

bool _numbersCompatible(String candidateDigits, String queryDigits) {
  if (queryDigits.isEmpty) return true;
  return queryDigits == candidateDigits;
}

double _similarity(String left, String right) {
  final maxLength = left.length > right.length ? left.length : right.length;
  if (maxLength == 0) return 1.0;
  return (maxLength - _editDistance(left, right)) / maxLength;
}

int _editDistance(String left, String right) {
  var previous = List<int>.generate(right.length + 1, (j) => j);
  var current = List<int>.filled(right.length + 1, 0);
  for (var i = 1; i <= left.length; i++) {
    current[0] = i;
    for (var j = 1; j <= right.length; j++) {
      final replace =
          previous[j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1);
      final insert = current[j - 1] + 1;
      final delete = previous[j] + 1;
      var best = replace;
      if (insert < best) best = insert;
      if (delete < best) best = delete;
      current[j] = best;
    }
    final swap = previous;
    previous = current;
    current = swap;
  }
  return previous[right.length];
}

_Normalized _normalize(String text) {
  var value = text.trim();
  value = value.toLowerCase();
  value = _normalizeSeason(value);
  final stripped = value.replaceAll(_nonToken, ' ').trim();
  final tokens = stripped.replaceAll(RegExp(r'\s+'), ' ');
  final compact = tokens.replaceAll(' ', '');
  return _Normalized(tokens, compact, _digits(compact));
}

String _normalizeSeason(String value) {
  final buffer = StringBuffer();
  var lastEnd = 0;
  for (final match in _seasonPattern.allMatches(value)) {
    final raw = _firstNonEmpty([
      match.group(1),
      match.group(2),
      match.group(3),
    ]);
    final number = _parseNumber(raw);
    buffer
      ..write(value.substring(lastEnd, match.start))
      ..write(number > 0 ? '$number' : (raw ?? ''));
    lastEnd = match.end;
  }
  buffer.write(value.substring(lastEnd));
  return buffer.toString();
}

String? _firstNonEmpty(List<String?> values) {
  for (final value in values) {
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

int _parseNumber(String? raw) {
  if (raw == null || raw.isEmpty) return 0;
  final parsed = int.tryParse(raw);
  if (parsed != null) return parsed;
  var total = 0;
  var current = 0;
  for (var i = 0; i < raw.length; i++) {
    final ch = raw[i];
    if (ch == '十') {
      total += (current == 0 ? 1 : current) * 10;
      current = 0;
    } else if (ch == '百') {
      total += (current == 0 ? 1 : current) * 100;
      current = 0;
    } else {
      current = _chineseDigit(ch);
    }
  }
  return total + current;
}

int _chineseDigit(String value) => switch (value) {
  '一' => 1,
  '二' || '两' => 2,
  '三' => 3,
  '四' => 4,
  '五' => 5,
  '六' => 6,
  '七' => 7,
  '八' => 8,
  '九' => 9,
  _ => 0,
};

String _digits(String value) {
  final buffer = StringBuffer();
  for (var i = 0; i < value.length; i++) {
    final ch = value[i];
    if (_isDigit(value.codeUnitAt(i))) buffer.write(ch);
  }
  return buffer.toString();
}

bool _hasHan(String value) => value.runes.any((r) => r >= 0x4E00 && r <= 0x9FFF);

final class _Normalized {
  const _Normalized(this.tokens, this.compact, this.digits);

  final String tokens;
  final String compact;
  final String digits;
}
