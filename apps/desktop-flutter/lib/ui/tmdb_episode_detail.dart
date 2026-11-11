import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

import '../core/tmdb_detail_model.dart';
import '../core/tmdb_identity.dart';
import '../core/tmdb_media.dart';
import '../services/tmdb_service.dart';
import '../state/detail_recommendation_state.dart';
import 'app.dart' show PosterImage;
import 'tmdb_detail_page.dart';
import 'tokens.dart';
import 'tmdb_detail_view.dart' show showTmdbPhotoViewer, TmdbPersonPage;

/// 立即展示基础信息，再按明确的影片身份与季集加载详情；不触发隐式播放。
Future<void> showTmdbEpisodeDetails(
  BuildContext context, {
  required TmdbEpisodeCard card,
  String sourceName = '',
  TmdbService? service,
  TmdbItem? item,
  Future<TmdbItem?> Function()? resolveItem,
  String actionLabel = '播放',
  VoidCallback? onAction,
  ValueChanged<TmdbPerson>? onPersonTap,
  DetailRecommendationDependencies? recommendationDependencies,
  ValueChanged<String>? onSearchTitle,
  void Function(String title, TmdbIdentity identity)? onSearchSource,
  ValueChanged<TmdbItem>? onOpenItem,
}) => Navigator.of(context, rootNavigator: true).push<void>(
  MaterialPageRoute<void>(
    builder: (_) => _EpisodeDetailsPage(
      card: card,
      sourceName: sourceName,
      service: service,
      item: item,
      resolveItem: resolveItem,
      actionLabel: actionLabel,
      onAction: onAction,
      onPersonTap: onPersonTap,
      recommendationDependencies: recommendationDependencies,
      onSearchTitle: onSearchTitle,
      onSearchSource: onSearchSource,
      onOpenItem: onOpenItem,
    ),
  ),
);

class _EpisodeDetailsPage extends StatefulWidget {
  const _EpisodeDetailsPage({
    required this.card,
    required this.sourceName,
    required this.service,
    required this.item,
    required this.resolveItem,
    required this.actionLabel,
    required this.onAction,
    required this.onPersonTap,
    required this.recommendationDependencies,
    required this.onSearchTitle,
    required this.onSearchSource,
    required this.onOpenItem,
  });

  final TmdbEpisodeCard card;
  final String sourceName;
  final TmdbService? service;
  final TmdbItem? item;
  final Future<TmdbItem?> Function()? resolveItem;
  final String actionLabel;
  final VoidCallback? onAction;
  final ValueChanged<TmdbPerson>? onPersonTap;
  final DetailRecommendationDependencies? recommendationDependencies;
  final ValueChanged<String>? onSearchTitle;
  final void Function(String title, TmdbIdentity identity)? onSearchSource;
  final ValueChanged<TmdbItem>? onOpenItem;

  @override
  State<_EpisodeDetailsPage> createState() => _EpisodeDetailsPageState();
}

class _EpisodeDetailsPageState extends State<_EpisodeDetailsPage> {
  final _cancel = TmdbCancellationToken();
  final _scroll = ScrollController();
  late TmdbEpisodeCard _card = widget.card;
  late TmdbItem? _item = widget.item;
  Map<String, Object?>? _movieDetail;
  List<String> _photos = const [];
  List<TmdbPerson> _guests = const [];
  bool _loading = false;
  bool _closing = false;

  bool get _active => mounted && !_closing && !_cancel.isCancelled;
  bool get _isMovie => _item?.identity?.isMovie ?? false;

  @override
  void initState() {
    super.initState();
    _loading = widget.service != null;
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_load()));
  }

  @override
  void dispose() {
    _cancel.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!_active) return;
    try {
      final service = widget.service;
      if (service == null || !service.config.isReady) return;
      final item = _item?.identity != null
          ? _item
          : await widget.resolveItem?.call();
      if (!_active || item?.identity == null) return;
      setState(() => _item = item);
      if (item!.isMovie) {
        final detail = await service.detail(
          item,
          includeRelated: false,
          cancel: _cancel,
        );
        if (!_active) return;
        final photos = service.photos(detail, preferLandscape: true);
        final cast = service.cast(detail);
        setState(() {
          _movieDetail = detail;
          _photos = photos;
          _guests = cast;
        });
      } else {
        // 0 在卡片中也代表未知季，不能擅自当成特辑或第一季。
        if (_card.seasonNumber <= 0 || _card.number <= 0) return;
        final detail = await service.episode(
          item,
          _card.seasonNumber,
          _card.number,
          cancel: _cancel,
        );
        if (!_active) return;
        final episode = TmdbEpisode.fromJson(
          detail,
          image: TmdbImageSelector.image,
          imageBase: service.config.backdropBase,
          fallbackSeasonNumber: _card.seasonNumber,
        );
        if (episode == null ||
            episode.number != _card.number ||
            episode.seasonNumber != _card.seasonNumber) {
          return;
        }
        final photos = TmdbImageSelector.stills(
          detail,
          service.config.backdropBase,
        );
        final guests = service.episodeGuests(detail);
        setState(() {
          _card = TmdbEpisodeCard(
            number: _card.number,
            seasonNumber: _card.seasonNumber,
            title: episode.title.trim().isEmpty
                ? _card.title
                : episode.displayTitle,
            date: episode.date.isEmpty ? _card.date : episode.date,
            overview: service.translatedOverview(detail) ?? _card.overview,
            stillUrl: _nonEmpty(episode.stillUrl) ?? _card.stillUrl,
            runtime: episode.runtime > 0 ? episode.runtime : _card.runtime,
            rating: episode.voteAverage > 0
                ? episode.voteAverage
                : _card.rating,
          );
          _photos = photos;
          _guests = guests;
        });
      }
    } catch (_) {
      // 匹配、配置或网络失败只影响富媒体，已有基础信息始终保留。
    } finally {
      if (_active) setState(() => _loading = false);
    }
  }

  void _close({bool action = false}) {
    if (!_active) return;
    _closing = true;
    _cancel.cancel();
    Navigator.of(context).pop();
    if (action) widget.onAction?.call();
  }

  void _openPhoto(String url, List<String> urls) {
    if (!_active) return;
    unawaited(
      showTmdbPhotoViewer(context, urls: urls, url: url, title: _title),
    );
  }

  void _openPerson(TmdbPerson person) {
    if (!_active) return;
    final callback = widget.onPersonTap;
    if (callback != null) {
      callback(person);
      return;
    }
    final service = widget.service;
    if (service == null) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    unawaited(
      navigator.push<void>(
        MaterialPageRoute(
          builder: (_) => TmdbPersonPage(
            service: service,
            person: person,
            onOpenItem: (item) {
              if (widget.onOpenItem != null) {
                widget.onOpenItem!(item);
                return;
              }
              final identity = item.identity;
              if (identity == null || !navigator.mounted) return;
              unawaited(
                navigator.push<void>(
                  MaterialPageRoute(
                    builder: (_) => TmdbDetailPage(
                      service: service,
                      identity: identity,
                      initialItem: item,
                      recommendationDependencies:
                          widget.recommendationDependencies,
                      onSearchTitle: widget.onSearchTitle,
                      onSearchSource: widget.onSearchSource,
                      onOpenItem: widget.onOpenItem,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  String get _title => _isMovie
      ? _nonEmpty(_movieDetail?['title']) ??
            _nonEmpty(_item?.title) ??
            _card.title
      : _nonEmpty(_card.title) ?? _nonEmpty(widget.sourceName) ?? '单集详情';

  String get _overview => _isMovie
      ? _nonEmpty(_movieDetail?['overview']) ??
            _nonEmpty(_item?.overview) ??
            '暂无简介'
      : _nonEmpty(_card.overview) ?? '暂无简介';

  String? get _cover {
    if (!_isMovie) return _nonEmpty(_card.stillUrl);
    final config = widget.service?.config;
    final path = _nonEmpty(_movieDetail?['backdrop_path']);
    final poster = _nonEmpty(_movieDetail?['poster_path']);
    return (path != null && config != null
            ? TmdbImageSelector.image(config.backdropBase, path)
            : null) ??
        _nonEmpty(_item?.backdropUrl) ??
        (poster != null && config != null
            ? TmdbImageSelector.image(config.imageBase, poster)
            : null) ??
        _nonEmpty(_item?.posterUrl) ??
        (_photos.isEmpty ? null : _photos.first);
  }

  String get _meta {
    if (_isMovie) {
      final rating = _number(_movieDetail?['vote_average']);
      final fallbackRating = (_item?.tmdbRating ?? 0) > 0
          ? _item!.tmdbRating
          : _item?.rating ?? 0;
      final vote = rating > 0 ? rating : fallbackRating;
      final runtime = _number(_movieDetail?['runtime']).toInt();
      return [
        if (vote > 0) '★ ${vote.toStringAsFixed(1)}',
        ?(_nonEmpty(_movieDetail?['release_date']) ??
            _nonEmpty(_item?.subtitle)),
        if (runtime > 0) '$runtime 分钟',
      ].join(' · ');
    }
    return [
      if (_card.seasonNumber > 0 && _card.number > 0)
        'S${_card.seasonNumber}E${_card.number}'
      else ...[
        if (_card.seasonNumber > 0) '第 ${_card.seasonNumber} 季' else '季度未知',
        if (_card.number > 0) 'E${_card.number}' else '集号未知',
      ],
      if (_card.date.isNotEmpty) _card.date,
      if (_card.rating > 0) '★ ${_card.rating.toStringAsFixed(1)}',
      if (_card.runtime > 0) '${_card.runtime} 分钟',
    ].join(' · ');
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _title,
          key: const ValueKey('tmdb-episode-title'),
          style: theme.textTheme.headlineSmall,
        ),
        if (widget.sourceName.isNotEmpty) ...[
          const SizedBox(height: AppSpace.sm),
          Text(
            '原始名称：${widget.sourceName}',
            key: const ValueKey('tmdb-episode-source-name'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (_meta.isNotEmpty) ...[
          const SizedBox(height: AppSpace.sm),
          Text(
            _meta,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
    final cover = _cover;
    if (cover == null) return info;
    final image = AspectRatio(
      aspectRatio: 16 / 9,
      child: _imageButton(
        key: const ValueKey('tmdb-episode-cover'),
        url: cover,
        label: '查看封面大图',
        onTap: () => _openPhoto(cover, [cover]),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 640) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: (constraints.maxWidth * .36)
                    .clamp(0.0, 480.0)
                    .toDouble(),
                child: image,
              ),
              const SizedBox(width: AppSpace.lg),
              Expanded(child: info),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            image,
            const SizedBox(height: AppSpace.lg),
            info,
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: PopScope<void>(
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) {
            _closing = true;
            _cancel.cancel();
          }
        },
        child: Scaffold(
          key: const ValueKey('tmdb-episode-details'),
          appBar: AppBar(
            leading: IconButton(
              key: const ValueKey('tmdb-episode-close'),
              autofocus: true,
              tooltip: '返回',
              onPressed: _close,
              icon: const Icon(Icons.arrow_back),
            ),
            title: Text(_isMovie ? '影片详情' : '单集详情'),
          ),
          body: SafeArea(
            child: Scrollbar(
              controller: _scroll,
              child: SingleChildScrollView(
                key: const ValueKey('tmdb-episode-scroll'),
                controller: _scroll,
                padding: const EdgeInsets.all(AppSpace.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeader(context),
                    const SizedBox(height: AppSpace.lg),
                    Text('简介', style: theme.textTheme.titleMedium),
                    const SizedBox(height: AppSpace.sm),
                    Text(
                      _overview,
                      key: const ValueKey('tmdb-episode-overview'),
                      style: theme.textTheme.bodyLarge,
                    ),
                    if (_loading) ...[
                      const SizedBox(height: 16),
                      const LinearProgressIndicator(),
                      const SizedBox(height: 8),
                      const Text('正在加载详情与媒体…'),
                    ],
                    if (_photos.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      Text('剧照', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          for (var i = 0; i < _photos.length; i++)
                            SizedBox(
                              width: 200,
                              height: 112,
                              child: _imageButton(
                                key: ValueKey('tmdb-episode-photo-$i'),
                                url: _photos[i],
                                label: '查看第 ${i + 1} 张剧照',
                                onTap: () => _openPhoto(_photos[i], _photos),
                              ),
                            ),
                        ],
                      ),
                    ],
                    if (_guests.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      Text(
                        _isMovie ? '演员' : '客串',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          for (final person in _guests)
                            SizedBox(
                              width: 140,
                              child: Card(
                                margin: EdgeInsets.zero,
                                clipBehavior: Clip.antiAlias,
                                child: _MediaFocusFrame(
                                  focusKey: ValueKey(
                                    'tmdb-episode-person-${person.personId}-focus',
                                  ),
                                  child: InkWell(
                                    key: ValueKey(
                                      'tmdb-episode-person-${person.personId}',
                                    ),
                                    onTap: () => _openPerson(person),
                                    child: Padding(
                                      padding: const EdgeInsets.all(8),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          AspectRatio(
                                            aspectRatio: 2 / 3,
                                            child: PosterImage(
                                              url: person.profileUrl,
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          Text(
                                            person.name,
                                            style: theme.textTheme.titleSmall,
                                          ),
                                          if (person.subtitle.isNotEmpty)
                                            Text(
                                              person.subtitle,
                                              style: theme.textTheme.bodySmall,
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                    if (widget.actionLabel.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      FilledButton(
                        key: const ValueKey('tmdb-episode-action'),
                        onPressed: widget.onAction == null
                            ? null
                            : () => _close(action: true),
                        child: Text(
                          widget.actionLabel,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _imageButton({
    required ValueKey<String> key,
    required String url,
    required String label,
    required VoidCallback onTap,
  }) => ClipRRect(
    borderRadius: BorderRadius.circular(8),
    child: Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Tooltip(
        message: label,
        child: _MediaFocusFrame(
          focusKey: ValueKey('${key.value}-focus'),
          child: InkWell(
            key: key,
            onTap: onTap,
            child: Semantics(
              button: true,
              label: label,
              child: PosterImage(url: url, fit: BoxFit.cover),
            ),
          ),
        ),
      ),
    ),
  );
}

class _MediaFocusFrame extends StatefulWidget {
  const _MediaFocusFrame({required this.focusKey, required this.child});

  final Key focusKey;
  final Widget child;

  @override
  State<_MediaFocusFrame> createState() => _MediaFocusFrameState();
}

class _MediaFocusFrameState extends State<_MediaFocusFrame> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    onFocusChange: (focused) {
      setState(() => _focused = focused);
      if (focused) unawaited(Scrollable.ensureVisible(context));
    },
    child: Container(
      key: widget.focusKey,
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          width: 3,
          color: _focused
              ? Theme.of(context).colorScheme.primary
              : Colors.transparent,
        ),
      ),
      child: widget.child,
    ),
  );
}

String? _nonEmpty(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;

double _number(Object? value) => value is num ? value.toDouble() : 0;
