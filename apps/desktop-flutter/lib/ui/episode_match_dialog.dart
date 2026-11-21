/// 集级手动匹配的**匹配选择弹窗**：把一张选集卡片钉到 TMDB 的某一季某一集。
///
/// 为什么整行可点而不是每行一个「选它」按钮：手动匹配是**认条目**，不是按按钮
/// （与 meta_match_dialog.dart 同一套心智）——剧照、集号、标题、首播日期摆在
/// 一行里，扫一眼就能确认「这张卡就是这一集」，点行即选中。
///
/// 为什么初始定位用 ScrollController + postFrame 而不是 ensureVisible：
/// 后者要每行一个 GlobalKey，而且目标行必须先建好（长列表还没滚到就没有）；
/// 行高在这里是常量，直接算偏移量既便宜也不依赖 renderObject。
///
/// 为什么每次请求带季内序号：切季只影响当前季，旧季的迟到响应只该填缓存，
/// 绝不能把「已经切走的季」的结果当成当前季渲染（mounted 只挡关闭，不挡切季）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/episode_manual_match.dart';
import '../core/tmdb_media.dart';
import 'poster_image.dart';
import 'tokens.dart';

/// 用户在弹窗里选中的目标：哪一季哪一集，以及是否从这张卡起顺延。
class EpisodeMatchChoice {
  const EpisodeMatchChoice({
    required this.seasonNumber,
    required this.episodeNumber,
    required this.spread,
  });

  final int seasonNumber;
  final int episodeNumber;

  /// true = 从此集起顺延；false = 仅此一集。
  final bool spread;

  @override
  String toString() =>
      'EpisodeMatchChoice(S$seasonNumber E$episodeNumber spread=$spread)';
}

/// 打开匹配选择弹窗；取消（含点遮罩关闭）返回 null。
Future<EpisodeMatchChoice?> showEpisodeMatchDialog(
  BuildContext context, {
  required String title,
  required Map<int, int> seasonEpisodeCounts,
  required int initialSeason,
  required int initialEpisode,
  required bool variety,
  required Future<List<TmdbEpisode>?> Function(int season) loadSeason,
}) {
  return showDialog<EpisodeMatchChoice>(
    context: context,
    builder: (_) => _EpisodeMatchDialog(
      title: title,
      seasonEpisodeCounts: seasonEpisodeCounts,
      initialSeason: initialSeason,
      initialEpisode: initialEpisode,
      variety: variety,
      loadSeason: loadSeason,
    ),
  );
}

/// 行高（含行内边距）：定位初始集靠它按索引算偏移量。
const double _rowExtent = 80;

/// 剧照缩略的 16:9 尺寸。
const double _thumbWidth = 96;
const double _thumbHeight = 54;

class _EpisodeMatchDialog extends StatefulWidget {
  const _EpisodeMatchDialog({
    required this.title,
    required this.seasonEpisodeCounts,
    required this.initialSeason,
    required this.initialEpisode,
    required this.variety,
    required this.loadSeason,
  });

  final String title;
  final Map<int, int> seasonEpisodeCounts;
  final int initialSeason;
  final int initialEpisode;
  final bool variety;
  final Future<List<TmdbEpisode>?> Function(int season) loadSeason;

  @override
  State<_EpisodeMatchDialog> createState() => _EpisodeMatchDialogState();
}

class _EpisodeMatchDialogState extends State<_EpisodeMatchDialog> {
  /// 已拉到的季：按季缓存，切回来不再请求同一季。
  final Map<int, List<TmdbEpisode>> _episodes = {};

  /// 正在请求的季。
  final Set<int> _loading = {};

  /// 拉不到（null / 空表 / 抛错）的季：显式报不可用 + 重试，不猜集号。
  final Set<int> _unavailable = {};

  /// 每个季最近一次请求的序号：只有最后一次的响应能落地。
  final Map<int, int> _tickets = {};

  final ScrollController _scroll = ScrollController();

  int _loadToken = 0;
  late int _season = widget.initialSeason;
  int? _episode;

  /// initState 里发起首个请求时还不该 setState（首帧还没建），
  /// 用这个标记区分「首帧前」与「首帧后」。
  bool _bootstrapped = false;

  late final List<int> _seasons = _computeSeasons();

  List<int> _computeSeasons() {
    final seasons = widget.seasonEpisodeCounts.keys
        .where((season) => season >= 0)
        .toSet()
      ..add(widget.initialSeason);
    return seasons.toList()..sort();
  }

  int? get _initialEpisode =>
      widget.initialEpisode > 0 ? widget.initialEpisode : null;

  bool get _canConfirm => _episode != null && _episodes.containsKey(_season);

  @override
  void initState() {
    super.initState();
    _episode = _initialEpisode;
    // 打开即加载初始季并定位到初始集；响应到达后 _settleSelection 兜住
    // 「初始集不在这一季里」的情况。
    unawaited(_startLoad(_season));
    _bootstrapped = true;
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _startLoad(int season, {bool force = false}) async {
    if (_loading.contains(season)) return;
    if (!force &&
        (_episodes.containsKey(season) || _unavailable.contains(season))) {
      return;
    }
    _loading.add(season);
    final ticket = _tickets[season] = ++_loadToken;
    if (_bootstrapped) setState(() {});
    List<TmdbEpisode>? list;
    try {
      list = await widget.loadSeason(season);
    } catch (_) {
      // 请求失败与「拉不到」同义：弹窗只报事实，不把异常抛回调用方。
      list = null;
    }
    if (!mounted || _tickets[season] != ticket) return;
    setState(() {
      _loading.remove(season);
      if (list == null || list.isEmpty) {
        _episodes.remove(season);
        _unavailable.add(season);
        if (season == _season) _episode = null;
      } else {
        _episodes[season] = List<TmdbEpisode>.unmodifiable(list);
        _unavailable.remove(season);
        if (season == _season) _settleSelection();
      }
    });
    if (season == _season) _scheduleScrollToSelection();
  }

  /// 保证当前季有且只有一个落在真实集号上的选中项。
  void _settleSelection() {
    final list = _episodes[_season];
    if (list == null || list.isEmpty) {
      _episode = null;
      return;
    }
    final desired = _episode;
    if (desired == null) {
      _episode = list.first.number;
      return;
    }
    if (list.any((episode) => episode.number == desired)) return;
    // 目标集号在这一季里不存在（季集数过期 / 特殊季）：退到最近的一集，
    // 仍是 TMDB 真实存在的集号，不凭空造集。
    _episode = _nearestEpisode(list, desired);
  }

  static int _nearestEpisode(List<TmdbEpisode> list, int desired) {
    for (final episode in list) {
      if (episode.number >= desired) return episode.number;
    }
    return list.last.number;
  }

  void _selectSeason(int season) {
    if (season == _season) return;
    setState(() {
      _season = season;
      // 切季回到首集；切回初始季时还原初始集，用户的起点不变。
      _episode = season == widget.initialSeason ? _initialEpisode : null;
      if (_episodes.containsKey(season)) _settleSelection();
    });
    _scheduleScrollToSelection();
    unawaited(_startLoad(season));
  }

  void _scheduleScrollToSelection() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToSelection());
  }

  void _scrollToSelection() {
    if (!mounted || !_scroll.hasClients) return;
    final list = _episodes[_season];
    final episode = _episode;
    if (list == null || episode == null) return;
    final index = list.indexWhere((item) => item.number == episode);
    if (index < 0) return;
    final position = _scroll.position;
    // 把选中行摆到视口中间：直接算偏移量，不依赖行是否已建、也不用 GlobalKey。
    final target =
        index * _rowExtent - (position.viewportDimension - _rowExtent) / 2;
    _scroll.jumpTo(target.clamp(0.0, position.maxScrollExtent).toDouble());
  }

  void _closeWith(bool spread) {
    final episode = _episode;
    if (episode == null) return;
    Navigator.of(context).pop(
      EpisodeMatchChoice(
        seasonNumber: _season,
        episodeNumber: episode,
        spread: spread,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 桌面窗口可缩放：宽度 720 封顶，高度扣掉标题与动作条，避免 800x600
    // 这类窗口把列表硬裁掉（对齐 MetaMatchDialog 的算法）。
    final media = MediaQuery.sizeOf(context);
    final width = math.max(420.0, math.min(720.0, media.width - 120));
    final maxHeight = math.max(240.0, math.min(560.0, media.height - 220));
    final hint = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return AlertDialog(
      key: const ValueKey('episode-match-dialog'),
      title: Text(widget.title),
      content: SizedBox(
        width: width,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 只有一季时切换器没有意义（也就没有第二个可选目标）。
              if (_seasons.length > 1) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: AppSpace.sm,
                    children: [
                      for (final season in _seasons)
                        ChoiceChip(
                          key: ValueKey('episode-match-season-$season'),
                          label: Text('第 $season 季'),
                          selected: season == _season,
                          onSelected: (_) => _selectSeason(season),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpace.sm),
              ],
              Align(
                alignment: Alignment.centerLeft,
                child: Text('手动匹配 · 点一行即选中该集', style: hint),
              ),
              const SizedBox(height: AppSpace.xs),
              Flexible(child: _body(theme)),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          key: const ValueKey('episode-match-spread'),
          onPressed: _canConfirm ? () => _closeWith(true) : null,
          child: const Text('从此集起顺延'),
        ),
        OutlinedButton(
          key: const ValueKey('episode-match-single'),
          onPressed: _canConfirm ? () => _closeWith(false) : null,
          child: const Text('仅此一集'),
        ),
        TextButton(
          key: const ValueKey('episode-match-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }

  Widget _body(ThemeData theme) {
    final list = _episodes[_season];
    if (list != null) {
      return ListView.builder(
        controller: _scroll,
        itemExtent: _rowExtent,
        padding: EdgeInsets.zero,
        itemCount: list.length,
        itemBuilder: (context, index) {
          final episode = list[index];
          return _EpisodeRow(
            key: ValueKey('episode-match-row-${episode.number}'),
            episode: episode,
            seasonNumber: _season,
            variety: widget.variety,
            selected: episode.number == _episode,
            onTap: () => setState(() => _episode = episode.number),
          );
        },
      );
    }
    if (_unavailable.contains(_season)) return _unavailableBlock(theme);
    return _loadingBlock();
  }

  Widget _loadingBlock() => const Padding(
    padding: EdgeInsets.symmetric(vertical: AppSpace.xl),
    child: Center(
      child: SizedBox(
        width: AppSpace.xl,
        height: AppSpace.xl,
        child: CircularProgressIndicator(
          key: ValueKey('episode-match-loading'),
          strokeWidth: 2,
        ),
      ),
    ),
  );

  Widget _unavailableBlock(ThemeData theme) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '该季集列表不可用',
          key: const ValueKey('episode-match-unavailable'),
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: AppSpace.xs),
        Text(
          '换一季不受影响，重试只重打这一季。',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        TextButton(
          key: const ValueKey('episode-match-retry'),
          onPressed: () => unawaited(_startLoad(_season, force: true)),
          child: const Text('重试'),
        ),
      ],
    ),
  );
}

/// 一集一行：整行是命中区，选中的那一行自带底色与「当前」标记。
class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({
    super.key,
    required this.episode,
    required this.seasonNumber,
    required this.variety,
    required this.selected,
    required this.onTap,
  });

  final TmdbEpisode episode;
  final int seasonNumber;
  final bool variety;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final secondary = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    // 集号文案只走纯逻辑的 unitLabel：综艺是「第 3 期」，多季带季号，
    // 不在 UI 里拼字符串（拼出来的文案会和卡面/角标对不上）。
    final label = EpisodeManualMatch.unitLabel(
      variety: variety,
      seasonNumber: seasonNumber,
      episodeNumber: episode.number,
      compact: false,
    );
    final title = episode.title.trim();
    final date = episode.date.trim();
    return Ink(
      decoration: selected
          ? BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.10),
              borderRadius: AppRadius.mdAll,
            )
          : null,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.mdAll,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.xs,
            vertical: AppSpace.xs,
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: AppRadius.smAll,
                child: PosterImage(
                  url: episode.stillUrl,
                  width: _thumbWidth,
                  height: _thumbHeight,
                  cacheWidth: 192,
                ),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: selected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurface,
                        fontWeight: AppWeight.title,
                      ),
                    ),
                    if (title.isNotEmpty)
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: secondary,
                      ),
                    if (date.isNotEmpty)
                      Text(
                        date,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              if (selected) ...[
                const SizedBox(width: AppSpace.sm),
                const _CurrentBadge(),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 「当前」标记：选中的目标就地标出来，用户不必回头找哪一行是刚点的那行。
class _CurrentBadge extends StatelessWidget {
  const _CurrentBadge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: 1),
      decoration: BoxDecoration(
        color: primary.withValues(alpha: 0.14),
        borderRadius: AppRadius.pillAll,
      ),
      child: Text(
        '当前',
        style: theme.textTheme.labelSmall?.copyWith(color: primary),
      ),
    );
  }
}
