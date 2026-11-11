import 'tmdb_identity.dart';

class RecommendationSeed {
  const RecommendationSeed({
    required this.title,
    this.mediaType,
    this.year = '',
    this.tmdbId = 0,
    this.isAudio = false,
    this.isShortDrama = false,
  });

  final String title, year;
  final TmdbMediaType? mediaType;
  final int tmdbId;
  final bool isAudio, isShortDrama;

  TmdbIdentity? get identity => TmdbIdentity.of(mediaType, tmdbId);
}

enum RecommendationSource { tmdb, douban }

class RecommendationEntry {
  const RecommendationEntry({
    required this.item,
    required this.source,
    this.reason = '',
    this.doubanId,
    this.doubanRating = 0,
  });

  final TmdbItem item;
  final RecommendationSource source;
  final String reason;
  final String? doubanId;
  final double doubanRating;

  String get key =>
      item.identity?.key ??
      (doubanId != null && doubanId!.trim().isNotEmpty
          ? 'douban:${doubanId!.trim()}'
          : 'title:${recommendationTitleKey(item.title)}');
}

class RecommendationPage {
  const RecommendationPage({
    this.items = const [],
    this.nextOffset = 0,
    this.hasMore = false,
  });

  final List<RecommendationEntry> items;
  final int nextOffset;
  final bool hasMore;
}

String recommendationTitleKey(String title) => title
    .replaceAll(RegExp(r'[\s·•・._\-/\\|()（）\[\]【】《》<>:：,，。]+'), '')
    .trim()
    .toLowerCase();
