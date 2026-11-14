/// TMDB 显示语言策略的纯 Dart 移植（对齐安卓 TmdbLanguagePolicy）。
library;

String normalizeTmdbLanguage(String? language) {
  final value = (language ?? '').trim();
  if (value.isEmpty) return 'zh-CN';
  final lower = value.toLowerCase();
  const simplified = {'zh-hans', 'zh-hans-cn', 'zh-cn', 'zh-sg', 'zh-my'};
  const traditional = {'zh-hant', 'zh-hant-tw', 'zh-tw', 'zh-hk', 'zh-mo'};
  if (simplified.contains(lower)) return 'zh-CN';
  if (traditional.contains(lower)) return 'zh-TW';
  final match = RegExp(r'^([^-_]+)[-_]([^-_]+)').firstMatch(lower);
  if (match != null) {
    return '${match.group(1)}-${match.group(2)!.toUpperCase()}';
  }
  return lower.toUpperCase();
}

String tmdbLanguageRoot(String? language) {
  final normalized = normalizeTmdbLanguage(language);
  final separator = normalized.indexOf('-');
  return separator > 0 ? normalized.substring(0, separator) : normalized;
}

bool isChineseTmdbLanguage(String? language) =>
    tmdbLanguageRoot(language).toUpperCase() == 'ZH';

bool matchesTmdbTarget(String? target, String? candidateLanguage) {
  if ((target ?? '').trim().isEmpty) {
    return (candidateLanguage ?? '').trim().isEmpty;
  }
  final expected = normalizeTmdbLanguage(target);
  final candidate = (candidateLanguage ?? '').trim();
  if (candidate.isEmpty) return false;
  final normalizedCandidate = normalizeTmdbLanguage(candidate);
  return expected.toLowerCase() == normalizedCandidate.toLowerCase() ||
      tmdbLanguageRoot(expected).toLowerCase() ==
          normalizedCandidate.toLowerCase();
}

bool isDisplayLanguageCompatible(String? target, String? payloadLanguage) =>
    matchesTmdbTarget(target, payloadLanguage);

bool looksTargetLanguage(String? target, String? value) {
  final text = (value ?? '').trim();
  if (text.isEmpty) return false;
  if (!isChineseTmdbLanguage(target)) return true;
  for (final rune in text.runes) {
    if ((rune >= 0x3400 && rune <= 0x9FFF) ||
        (rune >= 0xF900 && rune <= 0xFAFF) ||
        (rune >= 0x20000 && rune <= 0x3FFFF)) {
      return true;
    }
  }
  return false;
}
