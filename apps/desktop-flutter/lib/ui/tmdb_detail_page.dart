/// 纯 TMDB 详情页（`docs/phase4/design/04` §6）。
///
/// 与站点详情页的关键差异（`04` §6.2）：
/// - 身份只来自 `MediaIdentity`，没有站源 `Vod`；
/// - 季度选择器显示 TMDB **全部**季度（无播放约束）；
/// - 选集区是 TMDB 全部剧集，**只读、不可播**；
/// - **没有播放按钮**，改为 [搜索站源] 入口。
///
/// 关键约束：剧集卡片**不得**显示为可播放（`04` §6.2）。
library;

import 'package:flutter/material.dart';

import '../core/app_error.dart';
import '../core/tmdb_identity.dart';
import '../core/tmdb_media.dart';
import '../services/tmdb_service.dart';
import 'app.dart' show PosterImage;
import 'tmdb_widgets.dart';

/// 纯 TMDB 详情页。
class TmdbDetailPage extends StatefulWidget {
  const TmdbDetailPage({
    super.key,
    required this.service,
    required this.identity,
    this.initialItem,
    this.onSearchSource,
    this.onOpenVideo,
    this.onCopyVideo,
  });

  final TmdbService service;

  /// 媒体身份（唯一入口，无站源 `Vod`）。
  final TmdbIdentity identity;

  /// 可选的列表项快照（用于首屏立即渲染头部）。
  final TmdbItem? initialItem;

  /// 「搜索站源」入口：把标题与身份提示交给调用方（跳搜索页）。
  final void Function(String title, TmdbIdentity identity)? onSearchSource;

  /// 相关视频打开（浏览器）。
  final Future<bool> Function(String url)? onOpenVideo;
  final Future<void> Function(String url)? onCopyVideo;

  @override
  State<TmdbDetailPage> createState() => _TmdbDetailPageState();
}

class _TmdbDetailPageState extends State<TmdbDetailPage> {
  TmdbLoadPhase _phase = TmdbLoadPhase.idle;
  AppError? _error;
  TmdbItem? _item;
  List<TmdbEpisode> _episodes = const [];
  List<TmdbPerson> _cast = const [];
  List<TmdbVideo> _videos = const [];
  List<String> _photos = const [];
  List<int> _seasons = const [];
  Map<int, int> _seasonCounts = const {};
  int _selectedSeason = -1;

  int _generation = 0;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _item = widget.initialItem;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }

  Future<void> _load() async {
    if (_disposed) return;
    _generation++;
    final generation = _generation;
    setState(() {
      _phase = TmdbLoadPhase.loading;
      _error = null;
    });
    try {
      final item =
          _item ??
          TmdbItem(
            tmdbId: widget.identity.tmdbId,
            mediaType: widget.identity.mediaType,
            title: '',
          );
      final detail = await widget.service.detail(item, includeRelated: true);
      if (_disposed || generation != _generation) return;
      final title = widget.identity.isTv
          ? _string(detail['name']) ?? _string(detail['title']) ?? item.title
          : _string(detail['title']) ?? _string(detail['name']) ?? item.title;
      final vote = _double(detail['vote_average']);
      final date = widget.identity.isTv
          ? _string(detail['first_air_date'])
          : _string(detail['release_date']);
      final resolved = TmdbItem(
        tmdbId: widget.identity.tmdbId,
        mediaType: widget.identity.mediaType,
        title: title,
        subtitle: TmdbItem.buildSubtitle(date, vote),
        overview: _string(detail['overview']),
        posterUrl: widget.service.image(
          _string(detail['poster_path']) == null ? '' : _imageBase,
          _string(detail['poster_path']),
        ),
        backdropUrl: widget.service.image(
          _imageBaseBackdrop,
          _string(detail['backdrop_path']),
        ),
        rating: vote,
        tmdbRating: vote,
        originalLanguage: _string(detail['original_language']) ?? '',
      );
      final seasons = _seasonsFromDetail(detail);
      setState(() {
        _item = resolved;
        _cast = widget.service.cast(detail);
        _photos = widget.service.photos(detail, preferLandscape: true);
        _seasons = seasons.map((entry) => entry.$1).toList();
        _seasonCounts = {
          for (final entry in seasons) entry.$1: entry.$2,
        };
        // 默认选第一季（元数据季度，无播放约束）
        _selectedSeason = _seasons.isEmpty ? -1 : _seasons.first;
        _phase = TmdbLoadPhase.ready;
      });
      if (_selectedSeason >= 0) {
        await _loadEpisodes(generation);
      }
      await _loadVideos(generation);
    } on TmdbCancelledException {
      if (_disposed || generation != _generation) return;
      setState(() => _phase = TmdbLoadPhase.idle);
    } on TmdbAuthException catch (error) {
      if (_disposed || generation != _generation) return;
      setState(() {
        _error = AppError(
          AppErrorKind.tmdbAuth,
          'TMDB 鉴权失败',
          detail: error.message,
          statusCode: error.statusCode,
        );
        _phase = TmdbLoadPhase.failed;
      });
    } on AppError catch (error) {
      if (_disposed || generation != _generation) return;
      setState(() {
        _error = error;
        _phase = TmdbLoadPhase.failed;
      });
    } catch (error) {
      if (_disposed || generation != _generation) return;
      setState(() {
        _error = AppError(
          AppErrorKind.tmdbNetwork,
          'TMDB 请求失败',
          detail: '$error',
          retryable: true,
        );
        _phase = TmdbLoadPhase.failed;
      });
    }
  }

  Future<void> _loadEpisodes(int generation) async {
    final item = _item;
    if (item == null || _selectedSeason < 0) return;
    try {
      final episodes = await widget.service.seasonEpisodes(
        item,
        _selectedSeason,
      );
      if (_disposed || generation != _generation) return;
      setState(() => _episodes = episodes);
    } catch (_) {
      if (_disposed || generation != _generation) return;
      setState(() => _episodes = const []);
    }
  }

  Future<void> _loadVideos(int generation) async {
    final item = _item;
    if (item == null) return;
    try {
      final videos = await widget.service.videos(item);
      if (_disposed || generation != _generation) return;
      setState(() => _videos = videos);
    } catch (_) {
      if (_disposed || generation != _generation) return;
      setState(() => _videos = const []);
    }
  }

  Future<void> _selectSeason(int season) async {
    if (_disposed || !_seasons.contains(season) || season == _selectedSeason) {
      return;
    }
    setState(() {
      _selectedSeason = season;
      _episodes = const [];
    });
    await _loadEpisodes(_generation);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = _item;
    return Scaffold(
      appBar: AppBar(
        title: Text(item?.title ?? 'TMDB 详情'),
        actions: [
          // 「搜索站源」入口（`04` §6.2）：TMDB 详情页没有播放按钮
          TextButton.icon(
            key: const ValueKey('tmdb-search-source'),
            icon: const Icon(Icons.search),
            label: const Text('搜索站源'),
            onPressed: item == null || item.title.isEmpty
                ? null
                : () => widget.onSearchSource?.call(item.title, widget.identity),
          ),
        ],
      ),
      body: switch (_phase) {
        TmdbLoadPhase.idle ||
        TmdbLoadPhase.loading => const Center(
          child: CircularProgressIndicator(),
        ),
        TmdbLoadPhase.disabled => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '未配置 TMDB（不影响站源浏览与播放）',
              key: const ValueKey('tmdb-only-disabled'),
              style: theme.textTheme.bodyLarge,
            ),
          ),
        ),
        TmdbLoadPhase.failed => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  describeTmdbFailure(_error),
                  key: const ValueKey('tmdb-only-error'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 12),
                FilledButton(
                  key: const ValueKey('tmdb-only-retry'),
                  onPressed: _load,
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
        TmdbLoadPhase.ready => _buildContent(context, item),
      },
    );
  }

  Widget _buildContent(BuildContext context, TmdbItem? item) {
    final theme = Theme.of(context);
    if (item == null) return const SizedBox.shrink();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 头部
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 140,
              height: 210,
              child: PosterImage(url: item.posterUrl),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    key: const ValueKey('tmdb-only-title'),
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  if (item.subtitle.isNotEmpty)
                    Text(item.subtitle, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 8),
                  Text(
                    TmdbEnrichmentRatingText.of(item.tmdbRating),
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  // 明确标注：这是元数据季度，不是可播放内容（`04` §6.3）
                  Chip(
                    key: const ValueKey('tmdb-only-metadata-badge'),
                    avatar: const Icon(Icons.info_outline, size: 16),
                    label: const Text('元数据季度 · 不可直接播放'),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if ((item.overview ?? '').trim().isNotEmpty) ...[
          Text('简介', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(item.overview!, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 16),
        ],
        // 季度选择器：显示 TMDB 全部季度
        if (_seasons.isNotEmpty) ...[
          Text('季度', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final season in _seasons)
                ChoiceChip(
                  key: ValueKey('tmdb-only-season-$season'),
                  label: Text(
                    season == 0
                        ? '特别篇 · ${_seasonCounts[season] ?? 0} 集'
                        : '第 $season 季 · ${_seasonCounts[season] ?? 0} 集',
                  ),
                  selected: season == _selectedSeason,
                  onSelected: (_) => _selectSeason(season),
                ),
            ],
          ),
          const SizedBox(height: 16),
        ],
        // 选集区：只读、不可播
        Text(
          _selectedSeason >= 0
              ? '剧集（第 $_selectedSeason 季）'
              : '剧集',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        if (_episodes.isEmpty)
          Text('没有可展示的剧集', style: theme.textTheme.bodyMedium)
        else
          GridView.builder(
            key: const ValueKey('tmdb-only-episodes'),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              mainAxisExtent: 64,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: _episodes.length,
            itemBuilder: (context, index) {
              final episode = _episodes[index];
              return _ReadOnlyEpisodeTile(episode: episode);
            },
          ),
        if (_cast.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('演职人员', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final person in _cast.take(12))
                Chip(
                  avatar: person.profileUrl == null
                      ? null
                      : SizedBox(
                          width: 24,
                          height: 24,
                          child: PosterImage(url: person.profileUrl),
                        ),
                  label: Text(
                    person.subtitle.isEmpty
                        ? person.name
                        : '${person.name} · ${person.subtitle}',
                  ),
                ),
            ],
          ),
        ],
        if (_photos.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('剧照', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          SizedBox(
            height: 120,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _photos.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) => SizedBox(
                width: 200,
                child: PosterImage(url: _photos[index]),
              ),
            ),
          ),
        ],
        if (_videos.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('相关视频', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final video in _videos)
            TmdbVideoTile(
              video: video,
              onOpen: widget.onOpenVideo,
              onCopy: widget.onCopyVideo,
            ),
        ],
      ],
    );
  }

  static const String _imageBase = 'https://images.tmdb.org/t/p/w342';
  static const String _imageBaseBackdrop = 'https://images.tmdb.org/t/p/w780';

  List<(int, int)> _seasonsFromDetail(Map<String, Object?> detail) {
    final raw = detail['seasons'];
    if (raw is! List) return const [];
    final result = <(int, int)>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final number = _int(item['season_number']);
      final count = _int(item['episode_count']);
      if (number == null || count == null || count <= 0) continue;
      result.add((number, count));
    }
    return result;
  }
}

/// 只读剧集卡片（`04` §6.2：**不得**显示为可播放）。
class _ReadOnlyEpisodeTile extends StatelessWidget {
  const _ReadOnlyEpisodeTile({required this.episode});

  final TmdbEpisode episode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: ValueKey('tmdb-only-episode-${episode.number}'),
      // 明确不可播：无播放按钮、无点击行为
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(
              Icons.article_outlined,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                episode.displayTitle,
                style: theme.textTheme.bodyMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 评分文案辅助（纯 TMDB 详情页用）。
abstract final class TmdbEnrichmentRatingText {
  static String of(double tmdbRating) => tmdbRating > 0
      ? 'TMDB ${tmdbRating.toStringAsFixed(1)}'
      : 'TMDB —';
}

int? _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

double _double(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

String? _string(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  return value.toString();
}
