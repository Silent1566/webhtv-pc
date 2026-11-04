/// 搜索结果视图：摘要行 + 分组/相似度筛选 + 站点侧栏 + 海报墙 + 分页页脚。
///
/// 为什么抽出来：搜索页与详情页的「换源」浮层展示的是**同一批**搜索结果
/// （同一个 `AppState.activeSearch` 快照，见 `source_swap_sheet.dart` 头部注释），
/// 只是落地动作不同——搜索页点开详情，浮层勾选后并线。各画一份的结果就是
/// 两种卡片尺寸、两套筛选逻辑（用户 2026-10-16 直接问了「换源界面能和搜索
/// 界面共用一套嘛？」），所以呈现层收敛到这里。
///
/// 这个组件不认识 `AppState`：快照、分页、相似度持久化、点开条目的动作
/// 全部经参数与回调进来，因此浮层可以脱开浏览页单独验证（浮层测试顶部
/// 那条「不要 import browse_pages.dart」的约定同样适用于这里）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/hot_rank_layout.dart';
import '../core/protocol.dart';
import '../core/search_result_filter.dart';
import '../state/search_state.dart';
import 'app.dart';
import 'common.dart';
import 'tokens.dart';

/// 相似度预设档位（与「自定义…」滑块互补）。
const List<int> _similarityPresets = [0, 30, 60, 100];

/// 相似度自动续翻的最大跳数。
///
/// 为什么需要上限：上游未声明总页数（`pageCount == 0`）时页码没有硬上限，
/// 若对端一直返回「新内容但都被过滤掉」的页，没有上限就会一直翻下去。
const int _maxAutoPagingHops = 8;

/// 海报卡片：搜索结果与热门推荐**共用**（140×190 竖版海报 + 标题 + 副标题）。
///
/// 为什么抽成一个：两者在同一个页面上相邻出现（结果区 / 落地页热门区），
/// 各写一份必然分叉；而仓库已有的 `browse_pages._VodCard` 是私有且被网格
/// 约束（文字区用 `Expanded` 撑满格子），直接搬过来会带上网格专用行为。
///
/// 角标：`rank` / `score` 只有热门榜单会传（结果条目的元信息走副标题）；
/// `overlay` 是换源浮层用的叠层（勾选框 / 集数 / 重试），搜索页不传。
class PosterCard extends StatelessWidget {
  const PosterCard({
    super.key,
    required this.title,
    required this.onTap,
    this.imageUrl,
    this.subtitle,
    this.rank,
    this.score,
    this.posterKey,
    this.highlighted = false,
    this.overlay,
  });

  static const double _width = 140;
  static const double _posterHeight = 190;

  final String title;
  final VoidCallback onTap;
  final String? imageUrl;
  final String? subtitle;

  /// 榜单名次角标（热门榜单用；搜索结果不传）。
  final int? rank;

  /// 评分角标（豆瓣分；榜单里多数条目为空）。
  final String? score;

  /// 海报本身的 key（浮层的候选行用它做尺寸/图片来源断言）。
  final Key? posterKey;

  /// 选中态描边（换源浮层勾选后高亮）。
  final bool highlighted;

  /// 叠在海报上的角标层（需要 `Positioned` 的子节点，父级是一个 `Stack`）。
  final Widget? overlay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rank = this.rank;
    final score = this.score;
    final overlay = this.overlay;
    // 空串与纯空白都按「没有图」处理：站点返回的 `vodPic` 常见是 `''` 或
    // 带空格的占位，交给 `PosterImage` 会变成一次注定失败的图片请求。
    final raw = imageUrl?.trim();
    final url = (raw == null || raw.isEmpty) ? null : raw;
    return SizedBox(
      width: _width,
      // 卡片总高**固定**（用户 2026-10-14：「自动基于高宽计算… 刚好铺满」）：
      // 热门网格按 `mainAxisExtent` 恰好铺满，行高必须可预测；结果区（`Wrap`）
      // 里的卡片也因此各行列对齐，不再因有无副标题而高低不齐。
      height: HotRankMetrics.cardHeight,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.mdAll,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              key: posterKey,
              borderRadius: AppRadius.mdAll,
              child: Stack(
                children: [
                  PosterImage(
                    url: url,
                    width: _width,
                    height: _posterHeight,
                    // 限解码尺寸：榜单封面的原始分辨率从 150×200 到 770×1080
                    // 都有（最大那张 PNG 1.6MB）。按 2 倍屏解码已经够清晰，
                    // 再大只是白吃内存与解码时间。
                    cacheWidth: (_width * 2).round(),
                  ),
                  if (highlighted)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: AppRadius.mdAll,
                            border: Border.all(color: scheme.primary, width: 2),
                          ),
                        ),
                      ),
                    ),
                  if (rank != null)
                    Positioned(
                      left: 6,
                      top: 6,
                      child: _CornerBadge(text: 'TOP$rank'),
                    ),
                  if (score != null)
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: _CornerBadge(text: score, highlight: true),
                    ),
                  if (overlay != null) Positioned.fill(child: overlay),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.xs),
            // 文字区吃掉剩余高度；放大字号时**只缩不放**，避免固定高的卡片溢出。
            Expanded(
              child: MediaQuery.withClampedTextScaling(
                maxScaleFactor: 1.0,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 海报角标（与 `browse_pages` 的卡片角标同一视觉语言）。
class _CornerBadge extends StatelessWidget {
  const _CornerBadge({required this.text, this.highlight = false});

  final String text;

  /// 评分/名次用暖色强调（中性信息则用半黑底）。
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: highlight ? const Color(0xCCE8830C) : const Color(0x99000000),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          height: 1.2,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 相似度滑块对话框（对齐上游安卓 `SliderNumberDialog`）。
///
/// 实现委托给共享的 [showNumberSliderDialog]：设置页的「搜索线程」是同一个
/// 交互形态（上游也是同一个对话框服务两处），两份实现必然分叉。
/// `keyPrefix` 保持 `similarity` 以免既有 widget 测试的 key 失效。
///
/// 返回用户确认的数值；取消时返回 null。
Future<int?> showSimilaritySliderDialog(
  BuildContext context, {
  required int current,
}) => showNumberSliderDialog(
  context,
  title: '相似度',
  current: current,
  minValue: 0,
  maxValue: 100,
  suffix: '%',
  hint: '调整搜索结果的匹配宽松度，100为精确匹配，0为不限',
  keyPrefix: 'similarity',
);

/// 多站点搜索结果视图。
///
/// 视觉与交互完全由这里决定；两个宿主只负责「结果从哪来」和「点开一条做什么」：
/// - 搜索页：`keyPrefix: 'search'`，相似度可见，分页接 `AppState.loadMoreSearch`；
/// - 换源浮层：`keyPrefix: 'source-swap'`，相似度隐藏（阈值恒 0 = 不过滤，
///   否则同一部剧在别的站的条目会被滤掉），分页关闭（quick 搜索只取首页），
///   每张卡上多一层勾选/解析角标。
///
/// 分组筛选由宿主持有（`group` + [onGroupChanged]）：两个宿主都会在「新一次
/// 搜索」时把它清回「全部」，而清空时机属于宿主的搜索语义，不属于呈现层。
class SearchResultView extends StatefulWidget {
  const SearchResultView({
    super.key,
    required this.outcome,
    required this.keyPrefix,
    required this.itemKeyOf,
    required this.onTapItem,
    this.group = '',
    this.onGroupChanged,
    this.siteNameOf,
    this.subtitleOf,
    this.overlayOf,
    this.isSelected,
    this.onLoadMore,
    this.onSimilarityChanged,
    this.initialSimilarity = 0,
    this.showSimilarity = true,
    this.showSummary = true,
    this.emptyState,
  });

  /// 当前搜索结果快照（同一批次内可变，逐站点投递）。
  final MultiSiteSearchOutcome outcome;

  /// widget key 前缀：`<prefix>-group-all`、`<prefix>-site-<siteKey>` 等。
  final String keyPrefix;

  /// 条目 key（`<prefix>-row-…` / `<prefix>-result-…`）。
  final String Function(String siteKey, String vodId) itemKeyOf;

  final void Function(String siteKey, Vod vod) onTapItem;

  /// 当前分组筛选（`''` = 全部）。
  final String group;

  final ValueChanged<String>? onGroupChanged;

  /// 摘要行「范围 站点：…」用；宿主持有 `AppState` 时传。
  final String? Function(String siteKey)? siteNameOf;

  /// 副标题（搜索页用 `vodRemarks`，浮层用「站点名 · 年份」）。
  final String? Function(String siteKey, Vod vod)? subtitleOf;

  /// 换源浮层：叠在海报上的勾选/解析角标。
  final Widget? Function(String siteKey, Vod vod)? overlayOf;

  /// 换源浮层：选中态（海报描边）。
  final bool Function(String siteKey, Vod vod)? isSelected;

  /// 翻页动作；null = 不分页（浮层）。
  final Future<bool> Function(String siteKey)? onLoadMore;

  /// 相似度落盘；null = 不持久化。
  final Future<void> Function(int value)? onSimilarityChanged;

  final int initialSimilarity;

  final bool showSimilarity;

  final bool showSummary;

  /// 没有可见结果时的空态（浮层要区分「这个分组没有结果」与「没有找到其它来源」）。
  final Widget? emptyState;

  @override
  State<SearchResultView> createState() => _SearchResultViewState();
}

class _SearchResultViewState extends State<SearchResultView> {
  static const String _allSitesKey = '__all__';

  late int _similarity;
  String _activeSiteKey = _allSitesKey;
  bool _autoPaging = false;
  final ScrollController _resultScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _similarity = widget.showSimilarity ? widget.initialSimilarity : 0;
    _resultScroll.addListener(_onResultScroll);
  }

  @override
  void dispose() {
    _resultScroll.removeListener(_onResultScroll);
    _resultScroll.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 派生
  // ---------------------------------------------------------------------------

  MultiSiteSearchOutcome get _outcome => widget.outcome;

  List<SiteSearchEntry> get _groupFilteredEntries {
    if (widget.group.isEmpty) return _outcome.results;
    return [
      for (final entry in _outcome.results)
        if (entry.groups.contains(widget.group)) entry,
    ];
  }

  List<Vod> _visibleOf(SiteSearchEntry entry) => filterSearchResults(
    entry.result?.list ?? const [],
    _outcome.keyword,
    _similarity,
    titleOf: (vod) => vod.vodName,
  );

  /// 有结果的站点（保留被相似度滤成空的站点，否则用户无法选中它继续翻页
  /// 去找命中项）。
  List<SiteSearchEntry> get _rawEntries => [
    for (final entry in _groupFilteredEntries)
      if (entry.succeeded && entry.itemCount > 0) entry,
  ];

  /// 结果里出现过的分组（按站点顺序去重；只统计**有结果**的站点，
  /// 空分组 chip 没有意义——上游 `Site.getGroups(mSites)` 同样只列真实分组）。
  List<String> get _resultGroups {
    final seen = <String>[];
    for (final entry in _groupFilteredEntries) {
      if (!entry.succeeded || entry.itemCount == 0) continue;
      for (final group in entry.groups) {
        if (!seen.contains(group)) seen.add(group);
      }
    }
    return seen;
  }

  SiteSearchEntry? get _activeEntry {
    if (_activeSiteKey == _allSitesKey) return null;
    for (final entry in _groupFilteredEntries) {
      if (entry.siteKey == _activeSiteKey) return entry;
    }
    return null;
  }

  List<Vod> get _allViewVods => [
    for (final entry in _rawEntries) ..._visibleOf(entry),
  ];

  // ---------------------------------------------------------------------------
  // 分页
  // ---------------------------------------------------------------------------

  void _scrollResultsToTop() {
    if (!_resultScroll.hasClients) return;
    _resultScroll.jumpTo(0);
  }

  void _onResultScroll() {
    if (!_resultScroll.hasClients) return;
    final position = _resultScroll.position;
    // 距底部不足 240px 就预取下一页：等到真正贴底再请求，用户会看到一次空白。
    if (position.extentAfter > 240) return;
    unawaited(_loadMore());
  }

  /// 加载当前站点的下一页。
  ///
  /// 三处调用：滚动到底 / 用户点「加载更多」/ [auto]（选中站点、改阈值）。
  /// [auto] 只在「相似度 > 0 且当前页过滤后全不可见」时才真的发请求——
  /// 否则会在用户刚选中站点时就把在看的内容换掉、还白打网络请求。翻完之后
  /// 若这一页「原始有条目但被相似度整页滤掉」继续自动续翻（对齐上游
  /// `CollectFragment.maybeLoadNextPage`），上限见 [_maxAutoPagingHops]。
  Future<void> _loadMore({bool auto = false}) async {
    final loadMore = widget.onLoadMore;
    if (loadMore == null) return;
    if (_autoPaging) return;
    _autoPaging = true;
    try {
      for (var hop = 0; hop < _maxAutoPagingHops; hop++) {
        if (!mounted) return;
        final entry = _activeEntry;
        if (entry == null || entry.loadingMore || !entry.hasMore) return;
        final rawBefore = entry.itemCount;
        final visibleBefore = _visibleOf(entry).length;
        if (auto && hop == 0 && !(_similarity > 0 && visibleBefore == 0)) return;
        final accepted = await loadMore(entry.siteKey);
        if (!mounted || !accepted) return;
        final after = _outcome.entryOf(entry.siteKey);
        if (after == null) return;
        final rawGrew = after.itemCount > rawBefore;
        final visibleGrew = _visibleOf(after).length > visibleBefore;
        final shouldContinue =
            _similarity > 0 && rawGrew && !visibleGrew && after.hasMore;
        if (!shouldContinue) return;
      }
    } finally {
      _autoPaging = false;
    }
  }

  void _selectSite(String siteKey) {
    setState(() => _activeSiteKey = siteKey);
    _scrollResultsToTop();
    if (siteKey != _allSitesKey) unawaited(_loadMore(auto: true));
  }

  Future<void> _applySimilarity(int value) async {
    setState(() => _similarity = value);
    final persist = widget.onSimilarityChanged;
    if (persist != null) await persist(value);
    if (!mounted) return;
    if (value > 0) unawaited(_loadMore(auto: true));
  }

  Future<void> _openSimilaritySlider() async {
    final value = await showSimilaritySliderDialog(
      context,
      current: _similarity,
    );
    if (value == null || !mounted) return;
    await _applySimilarity(value);
  }

  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final filterBar = _buildFilterBar();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.showSummary) ...[
          _buildSummary(),
          const SizedBox(height: AppSpace.sm),
        ],
        if (filterBar != null) ...[
          filterBar,
          const SizedBox(height: AppSpace.sm),
        ],
        Expanded(child: _buildSiteSplit()),
      ],
    );
  }

  Widget _buildSummary() {
    final outcome = _outcome;
    final visibleTotal = _rawEntries.fold<int>(
      0,
      (sum, entry) => sum + _visibleOf(entry).length,
    );
    final parts = <String>['“${outcome.keyword}”'];
    if (outcome.siteKey.isNotEmpty) {
      final name = widget.siteNameOf?.call(outcome.siteKey);
      parts.add('范围 站点：${name ?? outcome.siteKey}');
    } else if (outcome.group.isNotEmpty) {
      parts.add('范围 分组：${outcome.group}');
    }
    parts
      ..add('命中站点 ${outcome.succeededCount}/${outcome.results.length}')
      ..add('条目 $visibleTotal/${outcome.totalItems}');
    if (outcome.failedCount > 0) parts.add('失败 ${outcome.failedCount}');
    if (outcome.skippedUnsupported > 0) {
      parts.add('跳过不可运行站点 ${outcome.skippedUnsupported}');
    }
    if (outcome.skippedNotSearchable > 0) {
      parts.add('跳过不可搜索站点 ${outcome.skippedNotSearchable}');
    }
    if (outcome.cancelled) {
      parts.add('已取消');
    } else if (outcome.finished) {
      parts.add('耗时 ${outcome.totalElapsed.inMilliseconds}ms');
    } else {
      parts.add('搜索中…');
    }
    return Text(parts.join(' · '), style: Theme.of(context).textTheme.bodySmall);
  }

  Widget? _buildFilterBar() {
    final groups = _resultGroups;
    final custom = !_similarityPresets.contains(_similarity);
    final showGroups = groups.isNotEmpty;
    if (!showGroups && !widget.showSimilarity) return null;
    return Wrap(
      spacing: AppSpace.sm,
      runSpacing: AppSpace.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (showGroups) ...[
          const Text('分组:', style: TextStyle(fontWeight: FontWeight.w500)),
          TagChip(
            key: ValueKey('${widget.keyPrefix}-group-all'),
            label: '全部',
            selected: widget.group.isEmpty,
            onTap: () => widget.onGroupChanged?.call(''),
            selectable: true,
          ),
          for (final group in groups)
            TagChip(
              key: ValueKey('${widget.keyPrefix}-group-$group'),
              label: group,
              selected: widget.group == group,
              onTap: () => widget.onGroupChanged?.call(group),
              selectable: true,
            ),
        ],
        if (widget.showSimilarity) ...[
          if (showGroups) const SizedBox(width: AppSpace.md),
          const Text('相似度:', style: TextStyle(fontWeight: FontWeight.w500)),
          for (final value in _similarityPresets)
            TagChip(
              key: ValueKey('${widget.keyPrefix}-similarity-$value'),
              label: _similarityLabel(value),
              selected: _similarity == value,
              onTap: () => _applySimilarity(value),
              selectable: true,
            ),
          TagChip(
            key: ValueKey('${widget.keyPrefix}-similarity-custom'),
            label: custom ? '≥$_similarity%' : '自定义…',
            selected: custom,
            onTap: _openSimilaritySlider,
            selectable: true,
          ),
        ],
      ],
    );
  }

  String _similarityLabel(int value) => switch (value) {
    0 => '不限',
    100 => '精确',
    _ => '≥$value%',
  };

  Widget _buildSiteSplit() {
    final entries = _rawEntries;
    if (entries.isEmpty) return _buildNoVisibleResults();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 200, child: _buildSiteList(entries)),
        const SizedBox(width: AppSpace.md),
        Expanded(child: _buildActiveResults()),
      ],
    );
  }

  Widget _buildSiteList(List<SiteSearchEntry> entries) {
    final theme = Theme.of(context);
    // ListTile 把背景与墨水溅射画在最近的 Material 祖先上：嵌在带背景色的
    // 容器里（换源浮层的容器就是）会触发 assert，所以自己铺一层透明 Material。
    return Material(
      color: Colors.transparent,
      child: ListView(
        children: [
          ListTile(
            key: ValueKey('${widget.keyPrefix}-site-all'),
            dense: true,
            selected: _activeSiteKey == _allSitesKey,
            title: const Text('全部站点'),
            trailing: Text('${_allViewVods.length}'),
            onTap: () => _selectSite(_allSitesKey),
          ),
          for (final entry in entries)
            Builder(
              builder: (context) {
                final visible = _visibleOf(entry).length;
                return ListTile(
                  key: ValueKey('${widget.keyPrefix}-site-${entry.siteKey}'),
                  dense: true,
                  selected: _activeSiteKey == entry.siteKey,
                  title: Text(
                    entry.siteName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: entry.fromCache
                      ? const Text('缓存', style: TextStyle(fontSize: 11))
                      : null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (visible == 0 && entry.itemCount > 0)
                        Padding(
                          padding: const EdgeInsets.only(right: AppSpace.xs),
                          child: Icon(
                            Icons.filter_alt_off_outlined,
                            size: 14,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      Text('$visible'),
                    ],
                  ),
                  onTap: () => _selectSite(entry.siteKey),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildActiveResults() {
    final active = _activeEntry;
    if (active == null) {
      final vods = _allViewVods;
      if (vods.isEmpty) return _buildNoVisibleResults();
      return _buildResultPane(vods, footer: _buildAllViewPagingHint());
    }
    final visible = _visibleOf(active);
    final footer = _buildPagingFooter(active);
    if (visible.isEmpty) {
      return _buildResultPane(
        const [],
        footer: footer,
        placeholder: EmptyState(
          icon: Icons.filter_alt_off_outlined,
          title: '该站点当前筛选下没有可见结果',
          message: _similarity > 0
              ? '相似度阈值把这一页都过滤掉了，可放宽阈值或继续加载下一页。'
              : null,
        ),
      );
    }
    return _buildResultPane(visible, footer: footer);
  }

  /// 海报墙 + 固定页脚。
  ///
  /// 页脚必须在 `Expanded` **外面**：`ListView` 是懒构建的，把页脚塞进列表
  /// 末尾时，第一屏高度不够就根本不会创建它，「加载更多」永远不出现。
  Widget _buildResultPane(
    List<Vod> vods, {
    required Widget footer,
    Widget? placeholder,
  }) {
    final active = _activeEntry;
    return Column(
      children: [
        Expanded(
          child: vods.isEmpty
              ? (placeholder ?? const SizedBox.shrink())
              : ListView(
                  key: ValueKey('${widget.keyPrefix}-result-list'),
                  controller: _resultScroll,
                  children: [
                    Wrap(
                      spacing: AppSpace.md,
                      runSpacing: AppSpace.md,
                      children: [
                        for (final vod in vods)
                          _buildResultCard(
                            vod,
                            active?.siteKey ?? _ownerSiteKeyOf(vod),
                          ),
                      ],
                    ),
                  ],
                ),
        ),
        footer,
      ],
    );
  }

  /// 合并视图里这条结果属于哪个站点（`Wrap` 抹掉了站点边界）。
  String _ownerSiteKeyOf(Vod vod) {
    for (final entry in _rawEntries) {
      if (entry.result?.list.any((item) => identical(item, vod)) ?? false) {
        return entry.siteKey;
      }
    }
    return '';
  }

  Widget _buildResultCard(Vod vod, String siteKey) {
    final subtitleOf = widget.subtitleOf;
    final overlayOf = widget.overlayOf;
    return PosterCard(
      key: ValueKey(widget.itemKeyOf(siteKey, vod.vodId)),
      posterKey: ValueKey(
        '${widget.keyPrefix}-poster-$siteKey-${vod.vodId}',
      ),
      title: vod.vodName,
      imageUrl: vod.vodPic,
      subtitle: subtitleOf != null ? subtitleOf(siteKey, vod) : vod.vodRemarks,
      highlighted: widget.isSelected?.call(siteKey, vod) ?? false,
      overlay: overlayOf?.call(siteKey, vod),
      onTap: () => widget.onTapItem(siteKey, vod),
    );
  }

  Widget _buildPagingFooter(SiteSearchEntry entry) {
    if (widget.onLoadMore == null) return const SizedBox.shrink();
    if (entry.loadingMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: AppSpace.sm),
            Text('正在加载第 ${entry.page + 1} 页…'),
          ],
        ),
      );
    }
    if (entry.hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
        child: FilledButton.tonalIcon(
          key: ValueKey('${widget.keyPrefix}-load-more'),
          onPressed: () => _loadMore(),
          icon: const Icon(Icons.expand_more),
          label: Text('加载更多（第 ${entry.page + 1} 页）'),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
      child: Text(
        key: ValueKey('${widget.keyPrefix}-no-more'),
        entry.pageCount > 0
            ? '已全部加载（${entry.page} 页 · ${entry.itemCount} 条）'
            : '已全部加载（${entry.itemCount} 条）',
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }

  Widget _buildAllViewPagingHint() {
    if (widget.onLoadMore == null) return const SizedBox.shrink();
    return Padding(
      key: ValueKey('${widget.keyPrefix}-all-paging-hint'),
      padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
      child: Text(
        '在左侧选择单个站点可继续加载下一页',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildNoVisibleResults() {
    final empty = widget.emptyState;
    if (empty != null) return empty;
    final hasRaw = _outcome.totalItems > 0;
    return EmptyState(
      icon: Icons.filter_alt_off_outlined,
      title: hasRaw ? '当前筛选下没有可见结果' : '没有搜索结果',
      message: hasRaw ? '相似度阈值或分组筛选把全部结果过滤掉了，可放宽筛选再试。' : null,
    );
  }
}
