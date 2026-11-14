/// 源内嵌 TMDB payload 的安全裁剪与规范化（纯 Dart，不依赖 protocol）。
library;

import 'dart:convert';

const int maxTmdbProtocolBytes = 2 * 1024 * 1024;
const int maxTmdbArrayItems = 500;
const int maxTmdbStringBytes = 64 * 1024;

const Set<String> _imageFields = {
  'poster_path',
  'backdrop_path',
  'still_path',
  'profile_path',
  'logo_path',
  'file_path',
};
const Set<String> _stringFields = {
  'title',
  'name',
  'original_title',
  'original_name',
  'overview',
  'tagline',
  'status',
  'release_date',
  'first_air_date',
  'original_language',
  'poster_path',
  'backdrop_path',
  'still_path',
  'profile_path',
  'logo_path',
  'file_path',
  'imdb_id',
  'iso_639_1',
  'iso_3166_1',
};
const Set<String> _numberFields = {
  'id',
  'vote_average',
  'vote_count',
  'runtime',
  'number_of_seasons',
  'number_of_episodes',
  'season_number',
  'episode_number',
  'order',
  'popularity',
};
const Set<String> _objectFields = {
  'images',
  'credits',
  'aggregate_credits',
  'external_ids',
  'videos',
  'recommendations',
  'similar',
  'translations',
  'content_ratings',
  'release_dates',
};
const Set<String> _arrayFields = {
  'genres',
  'origin_country',
  'episode_run_time',
  'seasons',
  'episodes',
  'results',
  'cast',
  'crew',
  'guest_stars',
  'translations',
  'content_ratings',
  'release_dates',
  'backdrops',
  'posters',
  'logos',
  'profiles',
};

int tmdbJsonBytes(Object? value) => utf8.encode(jsonEncode(value)).length;

Object? freezeTmdbValue(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable({
      for (final entry in value.entries)
        entry.key as String: freezeTmdbValue(entry.value),
    });
  }
  if (value is List) {
    return List<Object?>.unmodifiable([
      for (final item in value) freezeTmdbValue(item),
    ]);
  }
  return value;
}

Object? deepCopyTmdbValue(Object? value) {
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries)
        entry.key as String: deepCopyTmdbValue(entry.value),
    };
  }
  if (value is List) {
    return <Object?>[for (final item in value) deepCopyTmdbValue(item)];
  }
  return value;
}

/// 空字符串表示非法或不受支持的图片引用。
String normalizeTmdbImageUrl(String? value) {
  if (value == null) return '';
  final result = value.trim();
  if (result.isEmpty || result.startsWith('//')) return '';
  if (result.startsWith('/')) {
    return result.contains('\\') || result.contains(RegExp(r'\s'))
        ? ''
        : result;
  }
  if (result.contains(RegExp(r'\s'))) return '';
  final uri = Uri.tryParse(result);
  if (uri == null || uri.scheme.toLowerCase() != 'https' || uri.host.isEmpty) {
    return '';
  }
  return result;
}

Map<String, Object?> sanitizeTmdbSourceDetail(Object? value) {
  if (value is! Map) return <String, Object?>{};
  final sanitized = _sanitize(value, '');
  return sanitized is Map<String, Object?> ? sanitized : <String, Object?>{};
}

Object? _sanitize(Object? element, String field) {
  if (element == null) return null;
  if (element is String) {
    if (utf8.encode(element).length > maxTmdbStringBytes) return null;
    if (_imageFields.contains(field)) {
      final image = normalizeTmdbImageUrl(element);
      return image.isEmpty ? null : image;
    }
    return element;
  }
  if (element is num) {
    if (_stringFields.contains(field)) return null;
    return element;
  }
  if (element is bool) {
    if (_numberFields.contains(field) || _stringFields.contains(field)) {
      return null;
    }
    return element;
  }
  if (_arrayFields.contains(field) && element is! List) return null;
  if (_objectFields.contains(field) && element is! Map) return null;
  if (element is List) {
    if (element.length > maxTmdbArrayItems) return null;
    final result = <Object?>[];
    for (final item in element) {
      final sanitized = _sanitize(item, '');
      if (sanitized != null) result.add(sanitized);
    }
    return result;
  }
  if (element is Map) {
    final result = <String, Object?>{};
    for (final entry in element.entries) {
      final sanitized = _sanitize(entry.value, entry.key as String);
      if (sanitized != null) result[entry.key as String] = sanitized;
    }
    if (result.isEmpty &&
        element.isNotEmpty &&
        _objectFields.contains(field) &&
        field != 'external_ids') {
      return null;
    }
    return result;
  }
  return null;
}
