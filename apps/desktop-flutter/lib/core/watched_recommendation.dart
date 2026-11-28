import 'detail_recommendation.dart';
import 'tmdb_identity.dart';

/// Identity of an explicitly watched work, independent of any playback record.
class RecommendationWork {
  const RecommendationWork({
    required this.title,
    required this.mediaType,
    this.year,
    this.tmdbId,
    this.doubanId,
  });

  factory RecommendationWork.fromEntry(RecommendationEntry entry) {
    final item = entry.item;
    return RecommendationWork(
      title: item.title,
      mediaType: item.mediaType,
      year: item.year > 0 ? item.year : null,
      tmdbId: item.identity?.tmdbId,
      doubanId: entry.doubanId,
    );
  }

  final String title;
  final TmdbMediaType mediaType;
  final int? year, tmdbId;
  final String? doubanId;

  String get titleKey => recommendationTitleKey(title);
  TmdbIdentity? get _tmdb => TmdbIdentity.of(mediaType, tmdbId);
  String get _douban => doubanId?.trim() ?? '';

  bool matches(RecommendationWork other) {
    if (mediaType != other.mediaType) return false;
    final id = _tmdb;
    final otherId = other._tmdb;
    if (id != null && otherId != null) return id == otherId;
    if (_douban.isNotEmpty && other._douban.isNotEmpty) {
      return _douban == other._douban;
    }
    if (titleKey.isEmpty || titleKey != other.titleKey || year != other.year) {
      return false;
    }
    return year != null ||
        (id == null &&
            otherId == null &&
            _douban.isEmpty &&
            other._douban.isEmpty);
  }

  Map<String, Object?> toJson() => {
    'title': title,
    'mediaType': mediaType.wireName,
    if (year != null) 'year': year,
    if (_tmdb != null) 'tmdbId': tmdbId,
    if (_douban.isNotEmpty) 'doubanId': _douban,
  };

  static RecommendationWork? fromJson(Object? value) {
    if (value is! Map) return null;
    final title = value['title'];
    final mediaType = TmdbMediaType.parse(value['mediaType']);
    if (title is! String || mediaType == null) return null;
    final year = value['year'];
    final tmdbId = value['tmdbId'];
    final doubanId = value['doubanId'];
    final work = RecommendationWork(
      title: title.trim(),
      mediaType: mediaType,
      year: year is int ? year : null,
      tmdbId: tmdbId is int ? tmdbId : null,
      doubanId: doubanId is String ? doubanId : null,
    );
    return work.titleKey.isEmpty ? null : work;
  }
}
