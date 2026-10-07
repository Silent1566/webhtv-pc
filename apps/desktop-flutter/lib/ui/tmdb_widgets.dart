/// TMDB 详情页组件（`docs/phase4/design/04` §3–§5、§7）。
///
/// 包含：
/// - **状态条**（6 态：未配置 / 站点禁用 / 未匹配 / 匹配中 / 已匹配 / 失败）；
/// - **季度选择器**（单季隐藏切换，多季分段控件，未知季度给选择入口）；
/// - **选集区辅助**（严格「不补集、不丢集」）；
/// - **手动匹配弹窗**与**季度绑定弹窗**；
/// - **相关视频**卡片（浏览器打开 + 复制链接）。
///
/// 关键契约：
/// - 站点禁用时**整块不渲染**（`04` §3.1）；
/// - 骨架屏高度与最终内容一致，避免布局跳动（`04` §3.3）；
/// - 全部 `tmdb*` 错误文案必须含「不影响站源浏览与播放」（`04` §3.4）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_error.dart';
import '../core/protocol.dart';
import '../core/tmdb_identity.dart';
import '../core/tmdb_media.dart';
import '../core/tmdb_season.dart';
import '../state/tmdb_state.dart';
import 'app.dart' show PosterImage;

/// 季度绑定的语义化选择类型定义在纯逻辑层（`lib/core/tmdb_season.dart`），
/// 此处重导出，使 UI 层与既有门禁用例只需依赖一个模块。
export '../core/tmdb_season.dart'
    show
        TmdbSeasonAuto,
        TmdbSeasonAutoSlice,
        TmdbSeasonChoice,
        TmdbSeasonKeepOriginal,
        TmdbSeasonNumber;

/// 加载阶段（`04` §3.3）。
enum TmdbLoadPhase {
  /// 未开始（尚未加载或已清空）。
  idle,

  /// 加载中（显示骨架屏）。
  loading,

  /// 已就绪。
  ready,

  /// 加载失败（显示错误态 + 重试）。
  failed,

  /// TMDB 能力不可用（未配置 / 站点禁用）；整块不渲染。
  disabled,
}

/// 骨架屏固定高度（`04` §3.3：与最终内容高度一致，避免布局跳动）。
const double tmdbStatusBarHeight = 72;
const double tmdbSeasonSelectorHeight = 48;
const double tmdbSkeletonBlockHeight = 96;

/// TMDB 状态条（`04` §3.1 ②）。
///
/// 站点禁用 / 未配置时返回 `SizedBox.shrink()`（整块不渲染）。
class TmdbStatusBar extends StatelessWidget {
  const TmdbStatusBar({
    super.key,
    required this.state,
    this.onConfigure,
    this.onMatch,
    this.onRematch,
    this.onSelectSeason,
    this.onRetry,
  });

  final TmdbState state;
  final VoidCallback? onConfigure;
  final VoidCallback? onMatch;
  final VoidCallback? onRematch;
  final VoidCallback? onSelectSeason;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    // 仅「站点被规则禁用」时整块不渲染（`04` §3.1）。
    // 「未配置」必须渲染——否则用户没有进入 TMDB 设置页的入口。
    if (!state.shouldRender) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return SizedBox(
      height: tmdbStatusBarHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.movie_filter_outlined, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(child: _buildBody(context)),
            const SizedBox(width: 8),
            ..._buildActions(context),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final theme = Theme.of(context);
    switch (state.phase) {
      case TmdbLoadPhase.disabled:
        // 走到这里只可能是「未配置」（站点禁用已被 shouldRender 挡住）。
        return Text(
          '未配置 TMDB',
          key: const ValueKey('tmdb-status-unconfigured'),
          style: theme.textTheme.bodyMedium,
        );
      case TmdbLoadPhase.loading:
        return const _SkeletonLine(width: 160);
      case TmdbLoadPhase.failed:
        return Text(
          describeTmdbFailure(state.error),
          key: const ValueKey('tmdb-status-error'),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.error,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        );
      case TmdbLoadPhase.idle:
        return const SizedBox.shrink();
      case TmdbLoadPhase.ready:
        if (!state.hasMatch) {
          return Text(
            '未匹配 TMDB',
            key: const ValueKey('tmdb-status-unmatched'),
            style: theme.textTheme.bodyMedium,
          );
        }
        final title = state.item?.title ?? '';
        final rating = state.ratingText;
        return Text(
          'TMDB · $title${rating.isEmpty ? '' : ' · $rating'}',
          key: const ValueKey('tmdb-status-matched'),
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
    }
  }

  List<Widget> _buildActions(BuildContext context) {
    switch (state.phase) {
      case TmdbLoadPhase.disabled:
        return [
          FilledButton.tonal(
            key: const ValueKey('tmdb-configure'),
            onPressed: onConfigure,
            child: const Text('去设置'),
          ),
        ];
      case TmdbLoadPhase.idle:
        return const [];
      case TmdbLoadPhase.loading:
        return const [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ];
      case TmdbLoadPhase.failed:
        return [
          TextButton(
            key: const ValueKey('tmdb-retry'),
            onPressed: onRetry,
            child: const Text('重试'),
          ),
        ];
      case TmdbLoadPhase.ready:
        if (!state.hasMatch) {
          return [
            FilledButton.tonal(
              key: const ValueKey('tmdb-match'),
              onPressed: onMatch,
              child: const Text('匹配 TMDB'),
            ),
          ];
        }
        return [
          if (state.selectedSeason >= 0 && onSelectSeason != null)
            TextButton(
              key: const ValueKey('tmdb-select-season'),
              onPressed: onSelectSeason,
              child: const Text('仅选季度'),
            ),
          TextButton(
            key: const ValueKey('tmdb-rematch'),
            onPressed: onRematch,
            child: const Text('重新匹配'),
          ),
        ];
    }
  }
}

class _SkeletonLine extends StatelessWidget {
  const _SkeletonLine({required this.width});

  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: width,
      height: 16,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}

/// 季度选择器（`04` §4.1）。
class TmdbSeasonSelector extends StatelessWidget {
  const TmdbSeasonSelector({
    super.key,
    required this.state,
    this.onChanged,
    this.onSelectManual,
  });

  final TmdbState state;
  final ValueChanged<int>? onChanged;
  final VoidCallback? onSelectManual;

  @override
  Widget build(BuildContext context) {
    if (!state.shouldRender || !state.hasMatch) return const SizedBox.shrink();
    final item = state.item;
    if (item == null || !item.isTv) return const SizedBox.shrink();

    final seasons = state.availableSeasons;
    if (seasons.isEmpty) {
      // 无法可靠分季 → 显示「未确定季度」+ 选择入口（`04` §4.1）
      return SizedBox(
        height: tmdbSeasonSelectorHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Text('未确定季度', style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(width: 8),
              TextButton(
                key: const ValueKey('tmdb-choose-season'),
                onPressed: onSelectManual,
                child: const Text('选择季度'),
              ),
            ],
          ),
        ),
      );
    }

    if (seasons.length == 1) {
      // 单季：隐藏切换控件，但显示季度上下文（`04` §4.1）
      return SizedBox(
        height: tmdbSeasonSelectorHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _seasonLabel(seasons.first),
              key: const ValueKey('tmdb-season-context'),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: tmdbSeasonSelectorHeight,
      child: ListView.separated(
        key: const ValueKey('tmdb-season-switcher'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        itemCount: seasons.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final season = seasons[index];
          final selected = season == state.selectedSeason;
          return ChoiceChip(
            key: ValueKey('tmdb-season-$season'),
            label: Text(_seasonLabel(season)),
            selected: selected,
            onSelected: (_) => onChanged?.call(season),
          );
        },
      ),
    );
  }

  static String _seasonLabel(int season) =>
      season == 0 ? '特别篇' : '第 $season 季';
}

/// 选集区渲染辅助（`02` §4.7）。
///
/// **不补集**：不生成线路没有的剧集。
/// **不丢集**：未分类（`-1`）的集永远保留。
abstract final class TmdbEpisodeRenderPolicy {
  /// 按季度过滤线路剧集。
  ///
  /// - `availableSeasons` 为空 → 返回全部（退化为扁平列表）；
  /// - 否则只保留 `season == selectedSeason` 的集**以及所有未分类的集**。
  static List<VodEpisode> filter({
    required List<VodEpisode> episodes,
    required List<int> availableSeasons,
    required int selectedSeason,
    required int Function(VodEpisode episode) seasonOf,
  }) {
    if (availableSeasons.isEmpty) return episodes;
    final result = <VodEpisode>[];
    for (final episode in episodes) {
      final season = seasonOf(episode);
      // 未分类的集无法被证明不属于当前季 → 必须保留（不得丢集）
      if (season < 0 || season == selectedSeason) result.add(episode);
    }
    return result;
  }

  /// 剧集卡片主标题：优先 TMDB 展示名，否则来源集名（`04` §4.2）。
  static String displayName(VodEpisode episode) {
    final display = episode.extra['display_name'];
    if (display is String && display.trim().isNotEmpty) return display;
    return episode.name;
  }

  /// 剧集卡片副标题：TMDB 播出日期（有元数据时）。
  static String? subtitle(VodEpisode episode) {
    final metadata = episode.extra['tmdb_episode'];
    if (metadata is TmdbEpisode) {
      final date = metadata.date.trim();
      if (date.isNotEmpty) return date;
    }
    return null;
  }

  /// 剧集缩略图：TMDB 剧照（有元数据时）。
  static String? stillUrl(VodEpisode episode) {
    final metadata = episode.extra['tmdb_episode'];
    if (metadata is TmdbEpisode) return metadata.stillUrl;
    return null;
  }

  /// 强制断言辅助：渲染数量必须等于该季线路剧集数（不得补集）。
  static bool matchesSeasonEpisodeCount({
    required List<VodEpisode> rendered,
    required List<VodEpisode> sourceEpisodes,
    required int selectedSeason,
    required int Function(VodEpisode episode) seasonOf,
  }) {
    if (rendered.length > sourceEpisodes.length) return false;
    final expected = sourceEpisodes
        .where((e) {
          final season = seasonOf(e);
          return season < 0 || season == selectedSeason;
        })
        .length;
    return rendered.length == expected;
  }
}

/// 手动匹配弹窗（`04` §5.1）。
class TmdbMatchDialog extends StatefulWidget {
  const TmdbMatchDialog({
    super.key,
    required this.search,
    required this.resolveProviderId,
    this.initialQuery = '',
  });

  /// 搜索候选。
  final Future<List<TmdbItem>> Function(String keyword) search;

  /// Provider ID 直达（`tmdb:12345` / `movie:12345` / `tv:12345`）。
  final Future<TmdbItem?> Function(String input) resolveProviderId;

  final String initialQuery;

  @override
  State<TmdbMatchDialog> createState() => _TmdbMatchDialogState();
}

class _TmdbMatchDialogState extends State<TmdbMatchDialog> {
  late final TextEditingController _controller;
  List<TmdbItem> _results = const [];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery);
    // 打开即搜索（`04` §5.1：不要求用户点按钮）
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final input = _controller.text.trim();
    if (input.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // 先尝试 Provider ID 直达
      final direct = await widget.resolveProviderId(input);
      if (!mounted) return;
      if (direct != null) {
        setState(() {
          _results = [direct];
          _busy = false;
        });
        return;
      }
      final results = await widget.search(input);
      if (!mounted) return;
      setState(() {
        _results = results;
        _busy = false;
      });
    } on AppError catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeErrorKind(error.kind);
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      key: const ValueKey('tmdb-match-dialog'),
      title: const Text('匹配 TMDB 作品'),
      content: SizedBox(
        width: 560,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('tmdb-match-input'),
              controller: _controller,
              decoration: const InputDecoration(
                labelText: '搜索',
                hintText: '也可输入 tmdb:12345 / movie:12345 / tv:12345',
              ),
              onSubmitted: (_) => _run(),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton(
                  key: const ValueKey('tmdb-match-search'),
                  onPressed: _busy ? null : _run,
                  child: const Text('搜索'),
                ),
                const SizedBox(width: 8),
                if (_busy)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (_error != null)
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            Expanded(
              child: _results.isEmpty
                  ? Center(
                      child: Text(
                        _busy ? '搜索中…' : '没有候选结果',
                        style: theme.textTheme.bodyMedium,
                      ),
                    )
                  : ListView.builder(
                      itemCount: _results.length,
                      itemBuilder: (context, index) {
                        final item = _results[index];
                        return ListTile(
                          key: ValueKey('tmdb-result-${item.identity?.key}'),
                          leading: SizedBox(
                            width: 40,
                            height: 60,
                            child: PosterImage(url: item.posterUrl),
                          ),
                          title: Text(item.title),
                          subtitle: Text(
                            [
                              if (item.subtitle.isNotEmpty) item.subtitle,
                              item.isTv ? '剧集' : '电影',
                            ].join(' · '),
                          ),
                          onTap: () => Navigator.of(context).pop(item),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

/// 季度绑定弹窗（`04` §5.2）。
class TmdbSeasonDialog extends StatelessWidget {
  const TmdbSeasonDialog({
    super.key,
    required this.tmdbSeasons,
    required this.seasonCounts,
    required this.sourceEpisodeCount,
    this.currentSeason,
    this.canAutoSlice = false,
  });

  final List<int> tmdbSeasons;
  final Map<int, int> seasonCounts;
  final int sourceEpisodeCount;
  final int? currentSeason;

  /// `canSliceBySeasonCounts` 为真时「按集号自动切片」可用。
  final bool canAutoSlice;

  /// 风险提示阈值：`|季度集数 - 线路集数| > max(2, 20%)`。
  static bool needsRiskWarning({
    required int seasonEpisodeCount,
    required int sourceEpisodeCount,
  }) {
    final threshold = (sourceEpisodeCount * 0.2).floor();
    final limit = threshold > 2 ? threshold : 2;
    return (seasonEpisodeCount - sourceEpisodeCount).abs() > limit;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      key: const ValueKey('tmdb-season-dialog'),
      title: const Text('选择 TMDB 季度'),
      content: SizedBox(
        width: 480,
        height: 360,
        child: ListView(
          children: [
            ListTile(
              key: const ValueKey('tmdb-season-auto'),
              title: const Text('自动（清除手动绑定）'),
              selected: currentSeason == null,
              onTap: () => Navigator.of(context).pop(_SeasonChoice.auto),
            ),
            ListTile(
              key: const ValueKey('tmdb-season-auto-slice'),
              title: const Text('按集号自动切片'),
              subtitle: canAutoSlice
                  ? null
                  : const Text('当前线路集数与 TMDB 季集数不匹配，无法安全自动切分'),
              enabled: canAutoSlice,
              onTap: canAutoSlice
                  ? () => Navigator.of(context).pop(_SeasonChoice.autoSlice)
                  : null,
            ),
            ListTile(
              key: const ValueKey('tmdb-season-keep-original'),
              title: const Text('保持原始集列表'),
              onTap: () => Navigator.of(context).pop(_SeasonChoice.keepOriginal),
            ),
            const Divider(),
            for (final season in tmdbSeasons)
              ListTile(
                key: ValueKey('tmdb-season-option-$season'),
                title: Text(
                  season == 0 ? '特别篇' : '第 $season 季',
                ),
                subtitle: Text(
                  '${seasonCounts[season] ?? 0} 集'
                  '${needsRiskWarning(seasonEpisodeCount: seasonCounts[season] ?? 0, sourceEpisodeCount: sourceEpisodeCount) ? ' · ⚠ 与线路集数差异较大，请确认' : ''}',
                ),
                selected: currentSeason == season,
                onTap: () => Navigator.of(context).pop(season),
              ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '当前线路：$sourceEpisodeCount 集',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

/// 季度绑定弹窗的选择结果。
enum _SeasonChoice { auto, autoSlice, keepOriginal }

/// 把弹窗返回值翻译为语义化结果。
///
/// 语义化类型定义在 `lib/core/tmdb_season.dart`（纯逻辑层），此处转出以便 UI 层
/// 只依赖一个模块。
TmdbSeasonChoice? decodeSeasonChoice(Object? value) {
  if (value is int) return TmdbSeasonNumber(value);
  if (value is _SeasonChoice) {
    return switch (value) {
      _SeasonChoice.auto => const TmdbSeasonAuto(),
      _SeasonChoice.autoSlice => const TmdbSeasonAutoSlice(),
      _SeasonChoice.keepOriginal => const TmdbSeasonKeepOriginal(),
    };
  }
  return null;
}

/// 相关视频卡片（`04` §7.2）。
///
/// 点击用系统默认浏览器打开；打开失败时提供「复制链接」兜底。
/// **不做应用内播放**。
class TmdbVideoTile extends StatelessWidget {
  const TmdbVideoTile({
    super.key,
    required this.video,
    this.onOpen,
    this.onCopy,
  });

  final TmdbVideo video;

  /// 打开地址（由调用方注入，便于测试与无浏览器环境降级）。
  final Future<bool> Function(String url)? onOpen;
  final Future<void> Function(String url)? onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: ValueKey('tmdb-video-${video.identity}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            SizedBox(
              width: 96,
              height: 54,
              child: PosterImage(url: video.thumbnailUrl),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    video.name,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${video.displayType} · ${video.scopeLabel}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              key: ValueKey('tmdb-video-open-${video.identity}'),
              tooltip: '用浏览器打开',
              icon: const Icon(Icons.open_in_new),
              onPressed: () async {
                final url = video.watchUrl;
                final opened = await onOpen?.call(url) ?? false;
                if (!opened) {
                  await onCopy?.call(url);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('无法打开浏览器，已复制链接')),
                    );
                  }
                }
              },
            ),
            IconButton(
              key: ValueKey('tmdb-video-copy-${video.identity}'),
              tooltip: '复制链接',
              icon: const Icon(Icons.link),
              onPressed: () async {
                await onCopy?.call(video.watchUrl);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已复制链接')),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 复制文本到剪贴板（默认实现，供 [TmdbVideoTile] 使用）。
Future<void> copyToClipboard(String text) =>
    Clipboard.setData(ClipboardData(text: text));
