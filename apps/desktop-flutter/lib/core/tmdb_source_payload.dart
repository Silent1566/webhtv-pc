/// 源内嵌 TMDB payload：解析、校验、安全裁剪、能力缺口规划与 fill-only 合并。
///
/// 本文件不依赖 protocol，避免与 Vod 模型形成循环依赖。
library;

import 'tmdb_identity.dart';
import 'tmdb_source_language.dart';
import 'tmdb_source_normalize.dart';

const int _schemaVersion = 1;
const Set<String> _staticCapabilities = {
  'core',
  'credits',
  'images',
  'external_ids',
  'videos',
  'recommendations',
  'similar',
};
final RegExp _fetchedAtPattern = RegExp(
  r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$',
);
final RegExp _seasonPattern = RegExp(r'^season:(\d+)$');
final RegExp _seasonVideosPattern = RegExp(r'^season_videos:(\d+)$');
final RegExp _episodePattern = RegExp(r'^episode:(\d+):(\d+)$');
final RegExp _episodeVideosPattern = RegExp(r'^episode_videos:(\d+):(\d+)$');
const List<String> _trimOrder = [
  'release_dates',
  'content_ratings',
  'translations',
  'similar',
  'recommendations',
  'videos',
  'images',
  'credits',
  'aggregate_credits',
  'seasons',
  'episodes',
];

class TmdbSourcePayload {
  TmdbSourcePayload._({
    required this.schema,
    required this.id,
    required this.mediaType,
    required this.seasonNumber,
    required this.language,
    required this.fetchedAt,
    required Set<String> complete,
    required Map<String, Object?> detail,
  }) : complete = Set.unmodifiable(complete),
       detail = freezeTmdbValue(detail) as Map<String, Object?>;

  final int schema;
  final int id;
  final TmdbMediaType mediaType;
  final int seasonNumber;
  final String language;
  final String fetchedAt;
  final Set<String> complete;
  final Map<String, Object?> detail;

  TmdbIdentity get identity => TmdbIdentity.of(mediaType, id)!;

  static TmdbSourcePayload? fromJson(Object? value) {
    if (value is! Map) return null;
    try {
      if (tmdbJsonBytes(value) > maxTmdbProtocolBytes) return null;
    } catch (_) {
      return null;
    }

    final schema = value['schema'];
    final id = value['id'];
    final mediaTypeValue = value['media_type'];
    if (schema is! int || schema != _schemaVersion) return null;
    if (id is! int || id <= 0) return null;
    if (mediaTypeValue is! String) return null;
    final mediaType = TmdbMediaType.parse(mediaTypeValue);
    if (mediaType == null) return null;

    final rawSeason = value['season_number'];
    final seasonNumber = rawSeason is int ? rawSeason : 0;
    if (seasonNumber < 0 ||
        (mediaType == TmdbMediaType.movie && seasonNumber != 0)) {
      return null;
    }

    final rawLanguage = value['language'];
    var language = rawLanguage is String ? rawLanguage.trim() : '';
    if (language.length > 64) {
      language = '';
    } else if (language.isNotEmpty) {
      language = normalizeTmdbLanguage(language);
    }

    final rawFetchedAt = value['fetched_at'];
    final fetchedAtCandidate = rawFetchedAt is String
        ? rawFetchedAt.trim()
        : '';
    final fetchedAt = _fetchedAtPattern.hasMatch(fetchedAtCandidate)
        ? fetchedAtCandidate
        : '';

    final detail = _parseDetail(value['detail']);
    final normalized = _normalizeIdentity(
      detail,
      id: id,
      mediaType: mediaType,
      seasonNumber: seasonNumber,
    );
    if (normalized == null) return null;

    final complete = _canonicalCapabilities(value['complete']);
    _removeUnsupportedClaims(normalized, complete);
    final trimmed = _trimToLimit(normalized, complete);
    if (trimmed == null) return null;

    final payload = TmdbSourcePayload._(
      schema: schema,
      id: id,
      mediaType: mediaType,
      seasonNumber: seasonNumber,
      language: language,
      fetchedAt: fetchedAt,
      complete: complete,
      detail: trimmed,
    );
    try {
      if (tmdbJsonBytes(payload.toJson()) > maxTmdbProtocolBytes) return null;
    } catch (_) {
      return null;
    }
    return payload;
  }

  Map<String, Object?> toJson() {
    final sortedComplete = complete.toList()..sort();
    return <String, Object?>{
      'schema': schema,
      'id': id,
      if (mediaType.name.isNotEmpty) 'media_type': mediaType.name,
      if (seasonNumber != 0 || mediaType == TmdbMediaType.tv)
        'season_number': seasonNumber,
      if (language.isNotEmpty) 'language': language,
      if (fetchedAt.isNotEmpty) 'fetched_at': fetchedAt,
      if (sortedComplete.isNotEmpty) 'complete': sortedComplete,
      'detail': deepCopyTmdbValue(detail),
    };
  }
}

class TmdbSourcePlan {
  TmdbSourcePlan({
    required Set<String> required,
    required Set<String> available,
    required Set<String> missing,
  }) : required = Set.unmodifiable(required),
       available = Set.unmodifiable(available),
       missing = Set.unmodifiable(missing);

  final Set<String> required;
  final Set<String> available;
  final Set<String> missing;

  bool get needsNetwork => missing.isNotEmpty;
}

TmdbSourcePlan planTmdbSource(
  TmdbSourcePayload payload, {
  required Set<String> required,
  String targetLanguage = '',
}) {
  final ordered = required.toList()..sort();
  final available = <String>{};
  for (final group in ordered) {
    if (_isAvailable(payload, group, targetLanguage)) available.add(group);
  }
  final missing = <String>{
    for (final group in ordered)
      if (!available.contains(group)) group,
  };
  return TmdbSourcePlan(
    required: ordered.toSet(),
    available: available,
    missing: missing,
  );
}

Map<String, Object?> mergeTmdbSourceDetail(
  TmdbSourcePayload payload,
  Map<String, Object?> lower, {
  String targetLanguage = '',
}) {
  if (!_sameIdentity(payload, lower)) {
    return deepCopyTmdbValue(payload.detail) as Map<String, Object?>;
  }
  return _mergeObject(payload.detail, lower, payload, targetLanguage, 'detail');
}

Map<String, Object?> _parseDetail(Object? value) {
  return sanitizeTmdbSourceDetail(value);
}

Map<String, Object?>? _normalizeIdentity(
  Map<String, Object?> detail, {
  required int id,
  required TmdbMediaType mediaType,
  required int seasonNumber,
}) {
  final result = Map<String, Object?>.from(detail);
  final rawId = result['id'];
  if (rawId != null) {
    if (rawId is! num) {
      result.remove('id');
    } else if (rawId.toInt() != id) {
      return null;
    }
  }
  if (mediaType == TmdbMediaType.tv) {
    final rawSeason = result['season_number'];
    if (rawSeason != null) {
      if (rawSeason is! num) {
        result.remove('season_number');
      } else if (rawSeason.toInt() != seasonNumber) {
        return null;
      }
    }
  } else {
    result.remove('season_number');
  }
  return result;
}

Set<String> _canonicalCapabilities(Object? value) {
  final result = <String>{};
  if (value is List) {
    for (final item in value) {
      final canonical = _canonicalCapability(item);
      if (canonical.isNotEmpty) result.add(canonical);
    }
  }
  final sorted = result.toList()..sort();
  return sorted.toSet();
}

String _canonicalCapability(Object? value) {
  if (value is! String) return '';
  final group = value.trim().toLowerCase();
  if (_staticCapabilities.contains(group)) return group;
  final season = _seasonPattern.firstMatch(group);
  if (season != null) return _canonicalSeason('season', season.group(1)!);
  final seasonVideos = _seasonVideosPattern.firstMatch(group);
  if (seasonVideos != null) {
    return _canonicalSeason('season_videos', seasonVideos.group(1)!);
  }
  final episode = _episodePattern.firstMatch(group);
  if (episode != null) {
    return _canonicalEpisode('episode', episode.group(1)!, episode.group(2)!);
  }
  final episodeVideos = _episodeVideosPattern.firstMatch(group);
  if (episodeVideos != null) {
    return _canonicalEpisode(
      'episode_videos',
      episodeVideos.group(1)!,
      episodeVideos.group(2)!,
    );
  }
  return '';
}

String _canonicalSeason(String prefix, String number) {
  final value = int.tryParse(number);
  if (value == null || value < 0 || value > 0x7fffffff) return '';
  return '$prefix:$value';
}

String _canonicalEpisode(String prefix, String season, String episode) {
  final seasonNumber = int.tryParse(season);
  final episodeNumber = int.tryParse(episode);
  if (seasonNumber == null ||
      episodeNumber == null ||
      seasonNumber < 0 ||
      seasonNumber > 0x7fffffff ||
      episodeNumber <= 0 ||
      episodeNumber > 0x7fffffff) {
    return '';
  }
  return '$prefix:$seasonNumber:$episodeNumber';
}

void _removeUnsupportedClaims(
  Map<String, Object?> detail,
  Set<String> complete,
) {
  if (!_hasAny(detail, 'credits', 'aggregate_credits')) {
    complete.remove('credits');
  }
  if (!_hasAny(detail, 'images', 'poster_path', 'backdrop_path')) {
    complete.remove('images');
  }
  if (detail['external_ids'] is! Map) complete.remove('external_ids');
  if (detail['videos'] is! Map) complete.remove('videos');
  if (detail['recommendations'] is! Map) complete.remove('recommendations');
  if (detail['similar'] is! Map) complete.remove('similar');
  if (detail['seasons'] is! List) {
    complete.removeWhere(
      (group) =>
          group.startsWith('season:') || group.startsWith('season_videos:'),
    );
  }
}

Map<String, Object?>? _trimToLimit(
  Map<String, Object?> detail,
  Set<String> complete,
) {
  for (final field in _trimOrder) {
    if (tmdbJsonBytes(detail) <= maxTmdbProtocolBytes) return detail;
    detail.remove(field);
    _removeCapabilityForField(complete, field);
  }
  return tmdbJsonBytes(detail) <= maxTmdbProtocolBytes ? detail : null;
}

void _removeCapabilityForField(Set<String> complete, String field) {
  switch (field) {
    case 'credits':
    case 'aggregate_credits':
      complete.remove('credits');
    case 'images':
      complete.remove('images');
    case 'videos':
      complete.remove('videos');
    case 'recommendations':
      complete.remove('recommendations');
    case 'similar':
      complete.remove('similar');
    case 'seasons':
      complete.removeWhere(
        (group) =>
            group.startsWith('season:') || group.startsWith('season_videos:'),
      );
    case 'episodes':
      complete.removeWhere(
        (group) =>
            group.startsWith('episode:') || group.startsWith('episode_videos:'),
      );
  }
}

bool _hasAny(
  Map<String, Object?> detail,
  String first, [
  String? second,
  String? third,
]) => [
  first,
  second,
  third,
].any((field) => field != null && detail[field] != null);

bool _isAvailable(
  TmdbSourcePayload payload,
  String group,
  String targetLanguage,
) {
  if (group.isEmpty) return false;
  if (group == 'core' && !_coreLanguageAvailable(payload, targetLanguage)) {
    return false;
  }
  if (payload.complete.contains(group)) return true;
  final detail = payload.detail;
  switch (group) {
    case 'core':
      return _coreAvailable(payload, detail, targetLanguage);
    case 'credits':
      return _hasNonEmptyList(detail['credits'], 'cast', 'crew') ||
          _hasNonEmptyList(detail['aggregate_credits'], 'cast', 'crew');
    case 'images':
      return _nonEmptyString(detail['poster_path']) &&
          _nonEmptyString(detail['backdrop_path']);
    case 'external_ids':
      return _externalIdsAvailable(detail['external_ids']);
    case 'videos':
      return _hasNonEmptyList(detail['videos'], 'results');
    case 'recommendations':
      return _pageOneAvailable(detail['recommendations']);
    case 'similar':
      return _pageOneAvailable(detail['similar']);
    default:
      return _seasonalAvailable(payload, group);
  }
}

bool _coreAvailable(
  TmdbSourcePayload payload,
  Map<String, Object?> detail,
  String targetLanguage,
) {
  if (!_coreLanguageAvailable(payload, targetLanguage)) return false;
  if (_displayTitle(detail).isEmpty ||
      !_nonEmptyString(detail['overview']) ||
      _date(detail).isEmpty) {
    return false;
  }
  if (!detail.containsKey('vote_average') || !detail.containsKey('genres')) {
    return false;
  }
  if (payload.mediaType == TmdbMediaType.tv &&
      (!detail.containsKey('number_of_seasons') ||
          !detail.containsKey('number_of_episodes'))) {
    return false;
  }
  return true;
}

bool _coreLanguageAvailable(TmdbSourcePayload payload, String targetLanguage) {
  if (targetLanguage.trim().isEmpty) return true;
  final declared = payload.language;
  if (declared.isNotEmpty) {
    return isDisplayLanguageCompatible(targetLanguage, declared);
  }
  final title = _displayTitle(payload.detail);
  final overview = _stringValue(payload.detail['overview']);
  return looksTargetLanguage(targetLanguage, title) ||
      looksTargetLanguage(targetLanguage, overview);
}

String _displayTitle(Map<String, Object?> detail) {
  for (final key in const [
    'title',
    'name',
    'original_title',
    'original_name',
  ]) {
    final value = _stringValue(detail[key]);
    if (value.isNotEmpty) return value;
  }
  return '';
}

bool _seasonalAvailable(TmdbSourcePayload payload, String group) {
  if (group.startsWith('season_videos:') ||
      group.startsWith('episode_videos:')) {
    return false;
  }
  final parts = group.split(':');
  if (parts.length == 2 && parts.first == 'season') {
    final number = int.tryParse(parts[1]);
    if (number == null) return false;
    final episodes = _seasonEpisodes(payload, number);
    return episodes is List && episodes.isNotEmpty;
  }
  if (parts.length == 3 && parts.first == 'episode') {
    final seasonNumber = int.tryParse(parts[1]);
    final episodeNumber = int.tryParse(parts[2]);
    if (seasonNumber == null || episodeNumber == null) return false;
    final episodes = _seasonEpisodes(payload, seasonNumber);
    if (episodes is! List) return false;
    return episodes.any(
      (episode) =>
          episode is Map &&
          _intValue(episode['episode_number']) == episodeNumber,
    );
  }
  return false;
}

Object? _seasonEpisodes(TmdbSourcePayload payload, int number) {
  final ownEpisodes = payload.detail['episodes'];
  if (number == payload.seasonNumber && ownEpisodes is List) {
    return ownEpisodes;
  }
  final seasons = payload.detail['seasons'];
  if (seasons is! List) return null;
  return _seasonEntry(seasons, number)?['episodes'];
}

Map<String, Object?>? _seasonEntry(List<Object?> seasons, int number) {
  for (final item in seasons) {
    if (item is Map && _intValue(item['season_number']) == number) {
      return item.map((key, value) => MapEntry(key as String, value));
    }
  }
  return null;
}

bool _pageOneAvailable(Object? value) {
  if (value is! Map) return false;
  final page = value['page'];
  if (page is! num || page.toInt() != 1) return false;
  final results = value['results'];
  return results is List && results.isNotEmpty;
}

bool _externalIdsAvailable(Object? value) {
  if (value is! Map) return false;
  for (final item in value.values) {
    if (item is String && item.trim().isNotEmpty) return true;
    if (item is num && item > 0) return true;
  }
  return false;
}

bool _hasNonEmptyList(Object? value, String first, [String? second]) {
  if (value is! Map) return false;
  for (final key in [first, ?second]) {
    final items = value[key];
    if (items is List && items.isNotEmpty) return true;
  }
  return false;
}

String _date(Map<String, Object?> detail) {
  final release = _stringValue(detail['release_date']);
  return release.isNotEmpty ? release : _stringValue(detail['first_air_date']);
}

String _stringValue(Object? value) => value is String ? value.trim() : '';

bool _nonEmptyString(Object? value) => _stringValue(value).isNotEmpty;

int? _intValue(Object? value) => value is num
    ? value.toInt()
    : (value is String ? int.tryParse(value) : null);

bool _sameIdentity(TmdbSourcePayload payload, Map<String, Object?> lower) {
  final id = lower['id'];
  if (id != null && (id is! num || id.toInt() != payload.id)) return false;
  final mediaType = lower['media_type'];
  if (mediaType is String &&
      mediaType.trim().isNotEmpty &&
      mediaType.trim().toLowerCase() != payload.mediaType.name) {
    return false;
  }
  final season = lower['season_number'];
  if (season != null) {
    if (season is! num) return false;
    if (payload.mediaType == TmdbMediaType.tv) {
      if (season.toInt() != payload.seasonNumber) return false;
    } else if (season.toInt() != 0) {
      return false;
    }
  }
  return true;
}

Map<String, Object?> _mergeObject(
  Map<String, Object?> source,
  Map<String, Object?> lower,
  TmdbSourcePayload payload,
  String targetLanguage,
  String path,
) {
  final result = deepCopyTmdbValue(source) as Map<String, Object?>;
  for (final entry in lower.entries) {
    final key = entry.key;
    final childPath = path.isEmpty ? key : '$path.$key';
    final replacement = deepCopyTmdbValue(entry.value);
    final current = result[key];
    final languageOverride =
        _isCoreDisplayField(childPath) &&
        _nonEmptyString(replacement) &&
        _shouldOverrideCoreDisplay(
          _stringValue(current),
          _stringValue(replacement),
          payload,
          targetLanguage,
        );
    if (!result.containsKey(key) ||
        languageOverride ||
        _isEmptyValue(current, payload, childPath)) {
      result[key] = replacement;
    } else if (current is Map && replacement is Map) {
      result[key] = _mergeObject(
        current.map((k, v) => MapEntry(k as String, v)),
        replacement.map((k, v) => MapEntry(k as String, v)),
        payload,
        targetLanguage,
        childPath,
      );
    } else if (current is List && replacement is List) {
      result[key] = _mergeArray(current, replacement, payload, childPath);
    }
  }
  return result;
}

List<Object?> _mergeArray(
  List<Object?> source,
  List<Object?> lower,
  TmdbSourcePayload payload,
  String path,
) {
  final result = deepCopyTmdbValue(source) as List<Object?>;
  if (source.isNotEmpty ||
      payload.complete.contains(_capabilityForField(path))) {
    return result;
  }
  for (final item in lower) {
    result.add(deepCopyTmdbValue(item));
  }
  return result;
}

bool _isEmptyValue(Object? value, TmdbSourcePayload payload, String path) {
  if (value == null) return true;
  if (value is String) return value.trim().isEmpty;
  if (value is num) {
    return value == 0 && !payload.complete.contains(_capabilityForField(path));
  }
  if (value is Map) {
    return value.isEmpty &&
        !payload.complete.contains(_capabilityForField(path));
  }
  if (value is List) {
    return value.isEmpty &&
        !payload.complete.contains(_capabilityForField(path));
  }
  return false;
}

bool _shouldOverrideCoreDisplay(
  String source,
  String lower,
  TmdbSourcePayload payload,
  String targetLanguage,
) {
  if (source.trim().isEmpty || lower.trim().isEmpty) return false;
  if (targetLanguage.trim().isEmpty) return false;
  final target = normalizeTmdbLanguage(targetLanguage);
  if (!isDisplayLanguageCompatible(target, payload.language)) {
    return looksTargetLanguage(target, lower);
  }
  return false;
}

bool _isCoreDisplayField(String path) {
  final field = path.substring(path.lastIndexOf('.') + 1);
  return field == 'title' || field == 'name' || field == 'overview';
}

String _capabilityForField(String path) {
  final normalized = path;
  if (normalized.contains('credits')) return 'credits';
  if (normalized.contains('recommendations')) return 'recommendations';
  if (normalized.contains('similar')) return 'similar';
  if (normalized.contains('videos')) return 'videos';
  if (normalized.contains('images')) return 'images';
  if (normalized.contains('external_ids')) return 'external_ids';
  if (_isCoreField(normalized)) return 'core';
  final field = normalized.substring(normalized.lastIndexOf('.') + 1);
  switch (field) {
    case 'credits':
    case 'aggregate_credits':
    case 'cast':
    case 'crew':
      return 'credits';
    case 'images':
      return 'images';
    case 'external_ids':
      return 'external_ids';
    case 'videos':
      return 'videos';
    case 'recommendations':
      return 'recommendations';
    case 'similar':
      return 'similar';
    default:
      return '';
  }
}

bool _isCoreField(String path) {
  final field = path.substring(path.lastIndexOf('.') + 1);
  const coreFields = {
    'id',
    'title',
    'name',
    'original_title',
    'original_name',
    'overview',
    'tagline',
    'status',
    'release_date',
    'first_air_date',
    'vote_average',
    'vote_count',
    'genres',
    'origin_country',
    'original_language',
    'runtime',
    'episode_run_time',
    'number_of_seasons',
    'number_of_episodes',
    'poster_path',
    'backdrop_path',
  };
  return coreFields.contains(field);
}
