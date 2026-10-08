/// 纯 TMDB 详情页（`docs/phase4/design/04` §6）。
///
/// 与站点详情页的关键差异（`04` §6.2）：
/// - 身份只来自 `MediaIdentity`，没有站源 `Vod`；
/// - 季度选择器显示 TMDB **全部**季度（无播放约束）；
/// - 选集区是 TMDB 全部剧集，**只读、不可播**；
/// - **没有播放按钮**，改为 [搜索站源] 入口。
///
/// 关键约束：剧集卡片**不得**显示为可播放（`04` §6.2）。
/// 因此这里给卡片传入 `actionLabel: '搜索站源'`，点击后进入搜索页而非播放。
///
/// 渲染层复用 [TmdbDetailView]（动态背景 / 剧照墙 / 演职人员 / 相关推荐），
/// 使两种详情页的视觉与交互保持一致。
library;

import 'package:flutter/material.dart';

import '../core/app_error.dart';
import '../core/tmdb_detail_model.dart';
import '../core/tmdb_identity.dart';
import '../core/tmdb_media.dart';
import '../services/tmdb_service.dart';
import 'tmdb_detail_view.dart';
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
    this.onOpenItem,
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

  /// 相关推荐 / 人物作品点击（默认在当前页内继续打开 TMDB 详情）。
  final ValueChanged<TmdbItem>? onOpenItem;

  @override
  State<TmdbDetailPage> createState() => _TmdbDetailPageState();
}

class _TmdbDetailPageState extends State<TmdbDetailPage> {
  TmdbLoadPhase _phase = TmdbLoadPhase.idle;
  AppError? _error;
  TmdbDetailData? _data;
  List<TmdbEpisodeCard> _episodeCards = const [];
  List<TmdbItem> _recommendations = const [];
  List<TmdbVideo> _videos = const [];
  int _selectedSeason = -1;
  List<int> _tmdbSeasons = const [];

  int _generation = 0;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialItem != null) {
      _data = TmdbDetailData.fromItem(widget.initialItem!);
    }
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
      final snapshot =
          widget.initialItem ??
          TmdbItem(
            tmdbId: widget.identity.tmdbId,
            mediaType: widget.identity.mediaType,
            title: '',
          );
      final detail = await widget.service.detail(snapshot, includeRelated: true);
      if (_disposed || generation != _generation) return;
      final config = widget.service.config;
      final data = TmdbDetailData.fromDetail(
        detail,
        imageBase: config.imageBase,
        backdropBase: config.backdropBase,
        item: snapshot,
      );
      final seasons = data.seasons.map((season) => season.number).toList();
      final selected = seasons.isEmpty ? -1 : _defaultSeasonOf(seasons);
      setState(() {
        _data = data;
        _tmdbSeasons = seasons;
        _selectedSeason = selected;
        _recommendations = dedupeItems([
          ...widget.service.recommendationsFromDetail(detail),
          ...widget.service.similarFromDetail(detail),
        ]);
        _phase = TmdbLoadPhase.ready;
      });
      if (selected >= 0) {
        await _loadEpisodes(generation, selected);
      }
      await _loadVideos(generation, selected);
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

  Future<void> _loadEpisodes(int generation, int season) async {
    final item = widget.initialItem;
    if (item == null || season < 0) return;
    try {
      final episodes = await widget.service.seasonEpisodes(item, season);
      if (_disposed || generation != _generation) return;
      setState(() {
        _episodeCards = TmdbEpisodeCards.fromMetadata(episodes);
      });
    } catch (_) {
      if (_disposed || generation != _generation) return;
      setState(() => _episodeCards = const []);
    }
  }

  Future<void> _loadVideos(int generation, int season) async {
    final item = widget.initialItem;
    if (item == null) return;
    try {
      final videos = await widget.service.videos(
        item,
        seasonNumber: season >= 0 ? season : null,
      );
      if (_disposed || generation != _generation) return;
      setState(() => _videos = videos);
    } catch (_) {
      if (_disposed || generation != _generation) return;
      setState(() => _videos = const []);
    }
  }

  Future<void> _selectSeason(int season) async {
    if (_disposed || !_tmdbSeasons.contains(season) || season == _selectedSeason) {
      return;
    }
    setState(() {
      _selectedSeason = season;
      _episodeCards = const [];
    });
    await _loadEpisodes(_generation, season);
  }

  /// 默认选中季度：优先第一个**正片**季度（特别篇不作为默认）。
  static int _defaultSeasonOf(List<int> seasons) {
    for (final season in seasons) {
      if (season > 0) return season;
    }
    return seasons.first;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = _data;
    return Scaffold(
      appBar: AppBar(
        title: Text(data?.title.isNotEmpty == true ? data!.title : 'TMDB 详情'),
        actions: [
          // 「搜索站源」入口（`04` §6.2）：TMDB 详情页没有播放按钮
          TextButton.icon(
            key: const ValueKey('tmdb-search-source'),
            icon: const Icon(Icons.search),
            label: const Text('搜索站源'),
            onPressed: data == null || data.title.isEmpty
                ? null
                : () => widget.onSearchSource?.call(
                    data.title,
                    widget.identity,
                  ),
          ),
        ],
      ),
      body: switch (_phase) {
        TmdbLoadPhase.idle ||
        TmdbLoadPhase.loading => data == null
            ? const Center(child: CircularProgressIndicator())
            : _buildContent(context, data),
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
        TmdbLoadPhase.ready => _buildContent(context, data),
      },
    );
  }

  Widget _buildContent(BuildContext context, TmdbDetailData? data) {
    if (data == null) return const SizedBox.shrink();
    return SingleChildScrollView(
      child: TmdbDetailView(
        data: data,
        seasons: data.seasons,
        selectedSeason: _selectedSeason,
        selectableSeasons: _tmdbSeasons,
        onSeasonChanged: (season) => _selectSeason(season),
        seasonKeyPrefix: 'tmdb-only-season',
        episodeKeyPrefix: 'tmdb-only-episode',
        // 纯 TMDB 页没有播放按钮（`04` §6.2）：动作改为「搜索站源」。
        episodeActionLabel: '搜索站源',
        episodeCards: _episodeCards,
        recommendations: _recommendations,
        videos: _videos,
        metadataBadge: '元数据季度 · 不可直接播放',
        onEpisodeTap: (_, card) {
          if (data.title.isEmpty) return;
          widget.onSearchSource?.call(data.title, widget.identity);
        },
        onPersonTap: (person) => _openPerson(person),
        onRecommendationTap: (item) => _openItem(item),
        onOpenVideo: widget.onOpenVideo,
        onCopyVideo: widget.onCopyVideo,
      ),
    );
  }

  void _openPerson(TmdbPerson person) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdbPersonPage(
          service: widget.service,
          person: person,
          onOpenItem: (item) => _openItem(item),
        ),
      ),
    );
  }

  void _openItem(TmdbItem item) {
    final identity = item.identity;
    if (identity == null) return;
    final external = widget.onOpenItem;
    if (external != null) {
      external(item);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdbDetailPage(
          service: widget.service,
          identity: identity,
          initialItem: item,
          onSearchSource: widget.onSearchSource,
          onOpenVideo: widget.onOpenVideo,
          onCopyVideo: widget.onCopyVideo,
          onOpenItem: widget.onOpenItem,
        ),
      ),
    );
  }
}
