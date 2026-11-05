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
import 'common.dart';
import 'scroll_behavior.dart';
import 'toast.dart';

/// 季度绑定的语义化选择类型定义在纯逻辑层（`lib/core/tmdb_season.dart`），
/// 此处重导出，使 UI 层与既有门禁用例只需依赖一个模块。
export '../core/tmdb_season.dart'
    show
        TmdbSeasonAi,
        TmdbSeasonAiSettings,
        TmdbSeasonAuto,
        TmdbSeasonAutoSlice,
        TmdbSeasonChoice,
        TmdbSeasonKeepOriginal,
        TmdbSeasonNumber,
        bindingModeOf;

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
            child: LoadingBlock(center: false, size: 18),
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

/// 季度文案（`docs/phase6/design/03` §2.2）。
///
/// 顶层而不是私有静态：季度按钮与 chip 条都要用。
String _seasonLabel(int season) => season == 0 ? '特别篇' : '第 $season 季';

/// 季度按钮的文案（`docs/phase6/design/03` §2.2）。
///
/// 对齐上游 `TmdbDetailActivity#detailSeasonButtonLabel`：先看当前季度上下文，
/// 再看解析出的季度，都没有才用「选择季度」。
///
/// 【关于 §2.2 表格的中间一行】原文还列了一行
/// 「`selectedSeason < 0` 但解析出季度 → 同『第 N 季』」。
/// 该行**当前不可达**：`TmdbState` 在 `availableSeasons` 非空时总会把
/// `_selectedSeason` 落定（`scope is KnownSeason` 或 `_defaultSeasonOf`），
/// 因此「有季度而 `selectedSeason < 0`」不会出现。
/// 这里**不写**那行分支（写了就是不可达的死代码）；
/// 一旦状态机改了，`test/phase6_season_controls_test.dart` 的
/// 「selectedSeason<0 而季度已解析 → 不可达（现状）」用例会失败并提醒补上。
String tmdbSeasonButtonLabel(TmdbState state) {
  final season = state.selectedSeason;
  if (season >= 0) return _seasonLabel(season);
  return '选择季度';
}

/// 季度 chip 条（`docs/phase6/design/03` §3）。
///
/// 站点详情页与纯 TMDB 详情页**共用**这一个实现：同一个概念只有一种视觉。
/// 它是纯展示组件（不依赖 `TmdbState`），因此两页都能用。
///
/// ## [selectableSeasons] 的语义（保留既有约定）
///
/// **空 = 全部不可点击（只展示）**，与 `TmdbDetailView` 原有语义一致
/// （`tmdb_detail_view.dart` 的该字段注释：「为空但 `seasons` 非空时只展示不可切换」）。
///
/// 注意**不要**写成 `selectableSeasons.isEmpty || contains(...)`：
/// 纯 TMDB 页传的是「已解析的可选季度」，解析不出时就是空——
/// 「空即可点」会让用户选到未确证的季度。
/// 站点页的季度本来就都是可选的，它显式传全量（见 `TmdbSeasonSelector`）。
class SeasonChipStrip extends StatelessWidget {
  const SeasonChipStrip({
    super.key,
    required this.seasons,
    required this.selectedSeason,
    this.selectableSeasons = const [],
    this.onChanged,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
    this.switcherKey = 'tmdb-season-switcher',
    this.chipKeyPrefix = 'tmdb-season',
  });

  /// 全部季度号（升序）。
  final List<int> seasons;

  /// 当前选中的季度。
  final int selectedSeason;

  /// 可切换的季度号；**为空表示全部不可切换**（只展示）。
  final List<int> selectableSeasons;

  final ValueChanged<int>? onChanged;

  /// 内容内边距。
  final EdgeInsets padding;

  /// chip 条容器的 key。站点页与纯 TMDB 页各用各的字面值，避免同树冲突。
  final String switcherKey;

  /// 各季 chip 的 key 前缀。
  ///
  /// **与 [switcherKey] 分开**而不是从它推导：站点页的既有字面值是
  /// 容器 `tmdb-season-switcher` + chip `tmdb-season-<n>`
  /// （`phase4_tmdb_ui_test` 按它们断言），推导会算出 `tmdb-season-switcher-1`。
  final String chipKeyPrefix;

  @override
  Widget build(BuildContext context) {
    // 单季无 chip 条（与站点页一致）：一个 chip 的「切换」没有意义。
    if (seasons.length <= 1) return const SizedBox.shrink();
    return SizedBox(
      height: tmdbSeasonSelectorHeight,
      // 季数多到溢出时用鼠标左右拖。
      child: HorizontalMouseDrag(
        child: ListView.separated(
          key: ValueKey(switcherKey),
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(
            horizontal: padding.horizontal / 2,
            vertical: 6,
          ),
          itemCount: seasons.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final season = seasons[index];
            final selectable =
                selectableSeasons.contains(season) && onChanged != null;
            return ChoiceChip(
              key: ValueKey('$chipKeyPrefix-$season'),
              label: Text(_seasonLabel(season)),
              selected: season == selectedSeason,
              onSelected: selectable ? (_) => onChanged!(season) : null,
            );
          },
        ),
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
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
    this.showManualEntry = true,
  });

  final TmdbState state;
  final ValueChanged<int>? onChanged;
  final VoidCallback? onSelectManual;

  /// 内容内边距（纯 TMDB 页传 `EdgeInsets.zero` 以贴合其内容列）。
  final EdgeInsets padding;

  /// 是否允许手动改绑。
  ///
  /// 默认 `true`。为 `false` 时季度按钮**渲染但禁用**——
  /// 与整块隐藏相比，禁用态仍能告诉用户「这里可以换季」，
  /// 只是当前上下文不允许（`DESIGN.md`：不要给点了没反应的假入口，
  /// 但也不要把能力藏起来）。
  final bool showManualEntry;

  /// 常驻的季度按钮（`docs/phase6/design/03` §2）。
  ///
  /// 为什么必须常驻：单季剧集原先只显示一行上下文文字，**没有任何改绑入口**
  /// ——用户发现 TMDB 匹配错了季度也没法手动纠正。上游
  /// `updateTmdbSeasonActionVisibility` 的条件里 `seasonNumbers` 非空即可见，
  /// 不要求多季，正是这个理由。
  ///
  /// [labelKey] 用于把 `tmdb-season-context` 挂到按钮文字上：
  /// 单季时按钮文字**就是**季度上下文，再另外渲染一行「第 1 季」会变成
  /// 同一句话出现两次（`design/03` §2.3 的单季示意图里只有 `[ 第 1 季 ▾ ]`）。
  Widget _seasonButton(BuildContext context, {Key? labelKey}) =>
      TextButton.icon(
        key: const ValueKey('tmdb-season-button'),
        onPressed: showManualEntry ? onSelectManual : null,
        iconAlignment: IconAlignment.end,
        icon: const Icon(Icons.expand_more, size: 18),
        label: Text(tmdbSeasonButtonLabel(state), key: labelKey),
      );

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
          padding: padding,
          child: Row(
            children: [
              _seasonButton(context),
              const SizedBox(width: 8),
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
      // 单季：按钮本身就是季度上下文（`design/03` §2.3 的示意图里只有
      // `[ 第 1 季 ▾ ]`）。
      //
      // 【裁定】`design/03` §2 正文说「保留既有 key `tmdb-season-context`」，
      // 而 §2.3 的图只画了按钮——两者直接相加会出现**同一句话两次**
      // （按钮「第 1 季」+ 上下文文字「第 1 季」），既违反图示也是可见冗余。
      // 取图示（用户看到什么）+ 把该 key **移到按钮文字上**：
      // key 仍存在（`phase4_tmdb_ui_test` 的 `findsOneWidget` 与
      // `phase6_season_controls_test` 都按它断言），画面也不再重复。
      return SizedBox(
        height: tmdbSeasonSelectorHeight,
        child: Padding(
          padding: padding,
          child: Align(
            alignment: Alignment.centerLeft,
            child: _seasonButton(
              context,
              labelKey: const ValueKey('tmdb-season-context'),
            ),
          ),
        ),
      );
    }

    // 多季：按钮在左，chip 条在右。
    //
    // 按钮单独包一层 `Padding`（只吃 `padding.left`）而不是给整行加 padding：
    // chip 条自己带 `padding.horizontal / 2`，两边相加正好等于 `padding.horizontal`，
    // 于是「按钮对齐内容列左沿」与「chip 条仍有呼吸」同时成立。
    return SizedBox(
      height: tmdbSeasonSelectorHeight,
      child: Row(
        children: [
          Padding(
            padding: EdgeInsets.only(left: padding.left),
            child: _seasonButton(context),
          ),
          Expanded(
            child: SeasonChipStrip(
              seasons: seasons,
              selectedSeason: state.selectedSeason,
              // 站点页的季度**本来就都是可选的**（`availableSeasons` 已经过
              // 可播放季度解析），因此显式传全量而不是留空——
              // `SeasonChipStrip` 的空值语义是「只展示不可切换」。
              selectableSeasons: seasons,
              onChanged: onChanged,
              padding: padding,
              // 站点页沿用既有 key 字面值：`phase4_tmdb_ui_test` 按
              // `tmdb-season-switcher` / `tmdb-season-<n>` 断言，不得改名。
              switcherKey: 'tmdb-season-switcher',
              chipKeyPrefix: 'tmdb-season',
            ),
          ),
        ],
      ),
    );
  }
}

/// 选集区渲染辅助（`02` §4.7）。
///
/// **不补集**：不生成线路没有的剧集。
/// **不丢集**：未分类（`-1`）的集永远保留。
abstract final class TmdbEpisodeRenderPolicy {
  /// 按季度过滤线路剧集。
  ///
  /// - `availableSeasons` 为空 → 返回全部（退化为扁平列表）；
  /// - 否则只保留 `season == selectedSeason` 的集**以及所有未分类的集**；
  /// - **过滤结果为空时返回全部集**（`design/03` §5.2）：详见函数末尾注释。
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
    // 过滤结果为空 → 回退全部集（`docs/phase6/design/03` §5.2）。
    //
    // 宁可显示「可能不对季」的集，也不能显示空白——用户会以为剧集丢了。
    // 这与 `DESIGN.md` 的「不丢集」纪律一致，也对齐上游
    // `computeVisibleEpisodes` 的 `visible.isEmpty() ? episodes : visible`。
    return result.isEmpty ? episodes : result;
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
                    child: LoadingBlock(center: false, size: 18),
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
    this.aiReady = false,
  });

  final List<int> tmdbSeasons;
  final Map<int, int> seasonCounts;
  final int sourceEpisodeCount;
  final int? currentSeason;

  /// `canSliceBySeasonCounts` 为真时「按集号自动切片」可用。
  final bool canAutoSlice;

  /// AI 服务是否就绪。未就绪时 AI 项引导去设置页（`04` §7.1）。
  final bool aiReady;

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
        child: ListView(
          // 高度由内容决定，并由 `AlertDialog` 的可用空间封顶（两者取小）。
          //
          // 【为什么不再写死 360】`docs/phase6/design/04` §7.1 要求在「保持原始
          // 集列表」与「各季」之间插入 AI 项，固定 360 会把「各季」顶出可视区：
          // phase4 的「选择季度返回语义化结果」正是靠「不用滚动就能点到第 2 季」
          // 锁住季度选择的语义。改成按内容定高后，空间够就全展开，不够才滚动。
          shrinkWrap: true,
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
            // AI 项（`docs/phase6/design/04` §7.1）。
            //
            // 位置：在「保持原始集列表」之后、「各季」之前——AI 是**另一条**
            // 取得绑定的途径（结果仍需预览确认），与上面三个手动项同组，
            // 而不属于下面那一列“直接选定某一季”。
            //
            // 未配置时不隐藏这一项而是引导去设置：隐藏会让用户永远不知道
            // 有 AI 能力（Phase 4 的 TMDB 入口就是在这一点上踩过坑）。
            ListTile(
              key: const ValueKey('tmdb-season-ai'),
              leading: const Icon(Icons.auto_awesome),
              title: const Text('AI 识别剧集/季度'),
              subtitle: aiReady
                  ? null
                  : const Text('未配置 AI 服务，点击前往设置'),
              onTap: () => Navigator.of(context).pop(
                aiReady ? _SeasonChoice.ai : _SeasonChoice.aiSettings,
              ),
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
enum _SeasonChoice { auto, autoSlice, keepOriginal, ai, aiSettings }

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
      _SeasonChoice.ai => const TmdbSeasonAi(),
      _SeasonChoice.aiSettings => const TmdbSeasonAiSettings(),
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
                    showToast('无法打开浏览器，已复制链接');
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
                  showToast('已复制链接', kind: ToastKind.success);
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
