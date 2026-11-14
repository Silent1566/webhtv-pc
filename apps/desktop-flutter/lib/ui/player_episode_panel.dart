/// 播放器「选集」面板（播放器专用）。
///
/// 结构自上而下三段，对齐安卓 dev5 的
/// `dialog_episode_list.xml` + `EpisodeListDialog.java`：
///
/// 1. **线路行**：`ChoiceChip` 横排，只有一条线路时不渲染（渲染一条等于噪音）；
/// 2. **区间行**：`1-20` / `21-27` 的 `ChoiceChip` 横排，逻辑**全部**来自
///    `core/episode_range.dart` 的 `EpisodeRangePolicy`——分组上限、余数段落点、
///    选中区间定位都与详情页共用同一套算法，禁止在这里重算；
/// 3. **卡片网格**：16:9 剧照满铺 + 底部渐变遮罩 + 集号角标 + 标题（≤2 行）
///    + 副信息（时长 / 首播日期），当前集强高亮。
///
/// 为什么**不复用**详情页的 `TmdbEpisodeCardTile`：那张卡是「带播放按钮的
/// 横向卡片条」，宽高由详情页布局写死；这里是「剧照满铺的网格格子」，
/// 宽高由网格列宽算出来，命中区与信息层次也不同。硬参数化只会得到
/// 一个两边都不像的组件，还会把详情页的门禁（按 `episode-<flag>-` 计数）
/// 一起搅乱。
///
/// 配色全部取自 `tokens.dart` 的星等星表：底色 `surfaceContainerLow`
/// （暗色 = `#141A2E`）、卡片 `surfaceContainerHigh`（`#232C46`）、
/// 分隔线 `outlineVariant`（`#232C46`）、强调色 `semanticColors.magnitude`
/// （`#F0B429`）。这里**不写死任何色值**，亮色主题自动跟着走。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/episode_range.dart';
import '../core/protocol.dart';
import '../core/tmdb_detail_model.dart';
import 'layout_scale.dart';
import 'scroll_behavior.dart';
import 'tokens.dart';

/// 从集名里取出**集号**（取最后一个数字段）。
///
/// 为什么不写死「第N集」这类正则：源站的集名格式五花八门
/// （`第03集`、`03`、`S01E03`、`03 高清`），而「最后一个数字」在这些
/// 常见格式里都指向集号。取不到返回 `null`，调用方据此回退。
int? episodeNumberFromName(String name) {
  if (name.isEmpty) return null;
  final matches = RegExp(r'\d+').allMatches(name);
  if (matches.isEmpty) return null;
  return int.tryParse(matches.last.group(0)!);
}

/// 切线路后续播**同一集**的定位（对齐安卓 `VideoActivity.java:3684-3687`）。
///
/// 判定顺序（先精确、后宽松、最后兜底）：
/// 1. **集名完全相同**——同一部剧的同一集在不同线路里通常一字不差，这是最可靠的一条；
/// 2. **集号相同**（[episodeNumberFromName]）——线路命名习惯不同但集号一致是常态；
/// 3. 都不命中 → 返回 0（第 1 集）。
///
/// 为什么**不**按下标兜底（`min(旧下标, 新长度-1)`）：两条线路的集数常常不等
/// （有的线路缺花絮/缺预告，有的把一集拆成两集），按位置猜会把用户丢到
/// 完全无关的一集；回第 1 集至少是可解释的行为，和安卓一致。
int locateEpisodeInLine({
  required List<VodEpisode> episodes,
  required String currentName,
}) {
  if (episodes.isEmpty) return 0;
  if (currentName.isNotEmpty) {
    for (var i = 0; i < episodes.length; i++) {
      if (episodes[i].name == currentName) return i;
    }
  }
  final number = episodeNumberFromName(currentName);
  if (number != null) {
    for (var i = 0; i < episodes.length; i++) {
      if (episodeNumberFromName(episodes[i].name) == number) return i;
    }
  }
  return 0;
}

/// 播放器选集面板。
///
/// 自身只负责「展示 + 选择」：切集与切线路都由调用方注入（播放器握着
/// 解析与历史写入），面板不碰任何播放状态。
class PlayerEpisodePanel extends StatefulWidget {
  const PlayerEpisodePanel({
    super.key,
    required this.title,
    required this.lineLabel,
    required this.playLines,
    required this.lineFlag,
    required this.episodes,
    required this.episodeIndex,
    required this.onSelectEpisode,
    required this.onSelectLine,
    this.episodeCards = const [],
    this.reversed = false,
  });

  /// 片名（面板标题区第一行）。
  final String title;

  /// 当前线路的展示名（标题区第二行）。
  final String lineLabel;

  /// 详情页给出的全部线路（只有 >1 条时渲染线路行）。
  final List<VodPlayLine> playLines;

  /// 当前线路在 [playLines] 里的展示标识。
  final String lineFlag;

  /// **当前线路**的剧集（面板的集数、分组与下标都以它为准）。
  final List<VodEpisode> episodes;

  /// 详情页为这条线路渲染的卡片（`PlaybackRequest.episodeCardsByFlag[flag]`）。
  ///
  /// 顺序是**展示顺序**：与面板渲染的集列表一一对应（详情页倒序时它也是倒序的），
  /// 所以取卡片只能用展示下标，不能用 [episodes] 的原始下标。
  ///
  /// 允许比 [episodes] 短，甚至为空（未匹配 TMDB / 历史续播 / 换源）：
  /// 缺卡片的集退化为「集名文字卡」，**不补集、不编造剧照**。
  final List<TmdbEpisodeCard> episodeCards;

  /// 详情页的页面级「倒序」开关状态（`browse_pages.dart` 的 `_episodesReversed`）。
  ///
  /// 面板不解释这个开关的业务含义，只**跟随详情页那一刻的展示顺序**：详情页倒序时
  /// 它下发的卡片是按倒序排的，面板必须把集列表一起倒过来，否则区间标签会与详情页
  /// 相反、卡片会贴到别的集上。
  final bool reversed;

  /// 当前集在 [episodes] 里的下标。
  final int episodeIndex;

  /// 点卡片：参数是 [episodes] 里的**绝对下标**。
  final ValueChanged<int> onSelectEpisode;

  /// 点线路 chip：参数是线路的展示标识。
  final ValueChanged<String> onSelectLine;

  @override
  State<PlayerEpisodePanel> createState() => _PlayerEpisodePanelState();
}

class _PlayerEpisodePanelState extends State<PlayerEpisodePanel> {
  final ScrollController _gridScroll = ScrollController();

  late List<EpisodeRange> _ranges;
  late int _rangeIndex;

  /// 打开后是否已经滚动到当前集（只做一次：用户自己滚动后不该被拽回去）。
  bool _didAutoScroll = false;

  @override
  void initState() {
    super.initState();
    _ranges = EpisodeRangePolicy.build(
      widget.episodes.length,
      // 区间与标签都按**展示顺序**算：详情页倒序时区间方向必须一起倒过来，
      // 否则面板第一个区间标的是「1-20」而里面装的是最后的 20 集。
      _displayEpisodeIndex,
      widget.reversed,
    );
    _rangeIndex = EpisodeRangePolicy.selectedPosition(_ranges);
  }

  /// 当前集在**展示顺序**里的下标。
  ///
  /// 倒序时集列表被整体翻过来，当前集的原始下标 `i` 对应展示下标
  /// `length - 1 - i`；区间、滚动定位与卡片取用都必须用展示下标。
  int get _displayEpisodeIndex {
    final count = widget.episodes.length;
    if (count <= 0) return 0;
    final mapped = widget.reversed
        ? count - 1 - widget.episodeIndex
        : widget.episodeIndex;
    return mapped.clamp(0, count - 1);
  }

  /// 展示下标 → 原始下标（[episodes] 里的绝对下标）。
  ///
  /// 卡片 key 与切集回调都必须用原始下标，否则倒序下点第一张卡会播成第 1 集。
  int _originalIndex(int displayIndex) =>
      widget.reversed ? widget.episodes.length - 1 - displayIndex : displayIndex;

  @override
  void dispose() {
    _gridScroll.dispose();
    super.dispose();
  }

  int get _safeRangeIndex =>
      _ranges.isEmpty ? 0 : _rangeIndex.clamp(0, _ranges.length - 1);

  /// 当前区间要渲染的 `(展示下标, 剧集)`。
  ///
  /// 为什么把展示下标一路带走：卡片元数据是按展示顺序下发的，只有展示下标能取对
  /// 卡片；而切集回调必须收到**原始下标**（[_originalIndex]），否则倒序下点第一张
  /// 卡会播成第 1 集。两者在正序时恰好相等，所以正序路径的行为一字未变。
  List<(int, VodEpisode)> get _visibleEntries {
    if (widget.episodes.isEmpty || _ranges.isEmpty) return const [];
    final range = _ranges[_safeRangeIndex];
    // 与 `EpisodeRangePolicy.slice` 同一套夹取规则，保证下标与切片一一对应。
    final start = range.start.clamp(0, widget.episodes.length);
    final end = range.end.clamp(start, widget.episodes.length);
    return [
      for (var i = start; i < end; i++)
        (i, widget.episodes[_originalIndex(i)]),
    ];
  }

  /// 取**展示顺序**第 [displayIndex] 张卡片；没有可信卡片时返回 `null`（退化为文字卡）。
  ///
  /// 为什么按展示顺序取：详情页下发的卡片与它自己的渲染顺序一一对应（倒序时卡片
  /// 也是倒序的），按原始下标取会把第 1 张卡的剧照贴到最后一集上。
  ///
  /// 为什么卡片数必须与集数**相等**才认：`episodeCards` 是详情页按**那条线路**
  /// 算好的一次性快照，播放器自己算不回来（缺选中季度与季过滤后的渲染顺序）。
  /// 切到集数不同的线路后，按下标对齐会把第 3 集的剧照贴到第 5 集上——
  /// 宁可全部退回集名文字卡，也不给错的信息。
  TmdbEpisodeCard? _cardAt(int displayIndex) {
    if (widget.episodeCards.length != widget.episodes.length) return null;
    if (displayIndex < 0 || displayIndex >= widget.episodeCards.length) {
      return null;
    }
    return widget.episodeCards[displayIndex];
  }

  void _close() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
  }

  /// 点卡片：先关面板再切集。
  ///
  /// 顺序不能反：切集会立刻重建播放器请求（新剧集、新地址），面板留着
  /// 就会显示上一集的高亮；先关掉，切集失败也不会留下一个假装在播的面板。
  void _selectEpisode(int index) {
    _close();
    widget.onSelectEpisode(index);
  }

  /// 点线路：同样先关面板。
  ///
  /// 线路切换会重载整条线路的剧集与卡片，面板里收到的 `episodes` /
  /// `episodeCards` 都是**打开那一刻**的快照，原地刷新会是错的数据；
  /// 重新打开面板拿最新快照才是对的（安卓是原地刷新，PC 端差异记在交付说明里）。
  void _selectLine(VodPlayLine line) {
    if (line.flag == widget.lineFlag) return;
    _close();
    widget.onSelectLine(line.flag);
  }

  void _selectRange(int index) {
    if (index == _safeRangeIndex) return;
    setState(() {
      _rangeIndex = index;
      _didAutoScroll = true; // 换区间不跳回当前集：用户是在看别的集。
    });
    // 新区间是另一批集，停在上一个区间的滚动位置会让人以为漏了集。
    if (_gridScroll.hasClients) _gridScroll.jumpTo(0);
  }

  /// 打开后把当前集滚进视口。
  ///
  /// 为什么自己算偏移而不用 `Scrollable.ensureVisible`：网格是 `builder`
  /// 懒加载的，当前集那张卡在滚动到它之前**根本不存在**，没有可定位的 element。
  void _scheduleScrollToCurrent({
    required int columns,
    required double rowExtent,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_gridScroll.hasClients) return;
      final range = _ranges[_safeRangeIndex];
      final span = math.max(1, range.end - range.start);
      final local = (_displayEpisodeIndex - range.start).clamp(0, span - 1);
      final row = local ~/ columns;
      // 上留半行余量：贴顶会让人以为面板是从这一集开始的。
      final target = (row * rowExtent - rowExtent * 0.5).clamp(
        0.0,
        _gridScroll.position.maxScrollExtent,
      );
      _gridScroll.jumpTo(target);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final size = MediaQuery.sizeOf(context);
    final width = math.min(980.0, size.width * 0.86);
    final height = math.min(640.0, size.height * 0.82);
    final showLines = widget.playLines.length > 1;
    final showRanges = _ranges.length > 1;

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(AppSpace.lg),
      child: Container(
        key: const ValueKey('player-episode-panel'),
        width: width,
        height: height,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: AppRadius.lgAll,
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(theme),
            if (showLines) _buildLineRow(theme),
            if (showRanges) _buildRangeRow(theme),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.md,
                  AppSpace.sm,
                  AppSpace.md,
                  AppSpace.md,
                ),
                child: _buildGrid(theme),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    final scheme = theme.colorScheme;
    final linePart = widget.lineLabel.isEmpty ? '' : '${widget.lineLabel} · ';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.md,
        AppSpace.sm,
        AppSpace.xs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$linePart共 ${widget.episodes.length} 集',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('player-episode-close'),
            tooltip: '关闭',
            onPressed: _close,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  /// 线路行。
  Widget _buildLineRow(ThemeData theme) => SizedBox(
    height: 40,
    child: HorizontalMouseDrag(
      // 线路多到溢出时要能用鼠标左右拖（与详情页 chip 条同一处理）。
      child: ListView.separated(
        key: const ValueKey('player-episode-line-strip'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
        itemCount: widget.playLines.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpace.sm),
        itemBuilder: (context, index) {
          final line = widget.playLines[index];
          return _chip(
            theme: theme,
            key: ValueKey('player-episode-line-$index'),
            label: line.displayName,
            selected: line.flag == widget.lineFlag,
            onSelected: () => _selectLine(line),
          );
        },
      ),
    ),
  );

  /// 区间行。
  Widget _buildRangeRow(ThemeData theme) => SizedBox(
    height: 40,
    child: HorizontalMouseDrag(
      child: ListView.separated(
        key: const ValueKey('player-episode-range-strip'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
        itemCount: _ranges.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpace.sm),
        itemBuilder: (context, index) => _chip(
          theme: theme,
          key: ValueKey('player-episode-range-$index'),
          label: _ranges[index].label,
          selected: index == _safeRangeIndex,
          onSelected: () => _selectRange(index),
        ),
      ),
    ),
  );

  Widget _chip({
    required ThemeData theme,
    required Key key,
    required String label,
    required bool selected,
    required VoidCallback onSelected,
  }) {
    final scheme = theme.colorScheme;
    final accent = context.semanticColors.magnitude;
    return ChoiceChip(
      key: key,
      label: Text(label),
      selected: selected,
      // 勾选标记会把 chip 撑宽并推挤整排，选中态已经由描边与底色表达。
      showCheckmark: false,
      backgroundColor: scheme.surfaceContainer,
      selectedColor: accent.withValues(alpha: 0.18),
      side: BorderSide(color: selected ? accent : scheme.outlineVariant),
      labelStyle: theme.textTheme.labelLarge?.copyWith(
        color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
      ),
      onSelected: (_) => onSelected(),
    );
  }

  Widget _buildGrid(ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = AppSpace.md;
        // 卡片最小宽度：16:9 剧照 + 两行标题要放得下。列数由可用宽度决定，
        // 不写死——面板宽度本身是 min(980, 屏宽*0.86)。下界跟着密度标度走，
        // 否则 1440p 全屏下面板里还是 190 的小格子。
        final minCardWidth = 190 * LayoutScale.of(context);
        final columns =
            ((constraints.maxWidth + spacing) / (minCardWidth + spacing))
                .floor()
                .clamp(2, 6);
        final cardWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        // 剧照 16:9 + 64 的标题区（两行标题 + 一行副信息）。
        final cardHeight = cardWidth * 9 / 16 + _captionHeight;

        final entries = _visibleEntries;
        if (entries.isEmpty) {
          // 没有剧集时不抛错也不留白：标题区已经把「共 0 集」说清楚了。
          return const SizedBox.shrink();
        }
        if (!_didAutoScroll) {
          _didAutoScroll = true;
          _scheduleScrollToCurrent(
            columns: columns,
            rowExtent: cardHeight + spacing,
          );
        }
        return GridView.builder(
          key: const ValueKey('player-episode-grid'),
          controller: _gridScroll,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisExtent: cardHeight,
            crossAxisSpacing: spacing,
            mainAxisSpacing: spacing,
          ),
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final (displayIndex, episode) = entries[index];
            return _tile(
              theme: theme,
              // 卡片 key、高亮判定与切集回调都用**原始下标**，卡片元数据用展示下标。
              index: _originalIndex(displayIndex),
              episode: episode,
              card: _cardAt(displayIndex),
            );
          },
        );
      },
    );
  }

  /// 标题区高度：两行标题 + 一行副信息。
  static const double _captionHeight = 64;

  Widget _tile({
    required ThemeData theme,
    required int index,
    required VodEpisode episode,
    required TmdbEpisodeCard? card,
  }) {
    final scheme = theme.colorScheme;
    final accent = context.semanticColors.magnitude;
    final current = index == widget.episodeIndex;
    final title = card != null && card.title.isNotEmpty
        ? card.title
        : (episode.name.isNotEmpty ? episode.name : '第${index + 1}集');
    final meta = <String>[
      if (card != null && card.runtime > 0) '${card.runtime}m',
      if (card != null && card.date.isNotEmpty) card.date,
    ].join(' · ');

    return Container(
      key: ValueKey('player-episode-card-$index'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: AppRadius.mdAll,
        border: Border.all(
          color: current ? accent : scheme.outlineVariant,
          width: current ? 2 : 1,
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: () => _selectEpisode(index),
          child: card == null
              // 没有卡片元数据（未匹配 TMDB / 历史续播）：集名文字卡。
              // 不补剧照、不编简介——宁可少给信息，也不给假信息。
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpace.md),
                    child: _caption(
                      theme: theme,
                      title: title,
                      meta: meta,
                      current: current,
                      center: true,
                    ),
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _still(theme: theme, card: card, current: current),
                    ),
                    SizedBox(
                      height: _captionHeight,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpace.sm,
                          vertical: AppSpace.xs,
                        ),
                        child: _caption(
                          theme: theme,
                          title: title,
                          meta: meta,
                          current: current,
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  /// 16:9 剧照满铺；无剧照时是纯色占位块 + 集号（**不放假图**）。
  Widget _still({
    required ThemeData theme,
    required TmdbEpisodeCard card,
    required bool current,
  }) {
    final scheme = theme.colorScheme;
    final accent = context.semanticColors.magnitude;
    final number = card.number > 0 ? 'E${card.number}' : '';
    return Stack(
      fit: StackFit.expand,
      children: [
        if (card.hasStill)
          Image.network(
            card.stillUrl!,
            fit: BoxFit.cover,
            // 图挂了也留住格子与集号：宁可显示占位，也不让卡片消失（消失=丢集）。
            errorBuilder: (_, _, _) => _stillPlaceholder(theme, number),
          )
        else
          _stillPlaceholder(theme, number),
        // 底部渐变遮罩：剧照明暗不可预知，集号角标必须始终读得出来。
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 44,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    scheme.surface.withValues(alpha: 0.72),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (card.hasStill && number.isNotEmpty)
          Positioned(
            left: AppSpace.sm,
            top: AppSpace.sm,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.surface.withValues(alpha: 0.78),
                borderRadius: AppRadius.smAll,
              ),
              child: Text(
                number,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurface,
                ),
              ),
            ),
          ),
        if (current)
          Positioned(
            right: AppSpace.sm,
            top: AppSpace.sm,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.92),
                borderRadius: AppRadius.smAll,
              ),
              child: Text(
                '正在播放',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppPalette.nightGround,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _stillPlaceholder(ThemeData theme, String number) {
    final scheme = theme.colorScheme;
    return Container(
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: number.isEmpty
          ? const SizedBox.shrink()
          : Text(
              number,
              style: theme.textTheme.titleMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
    );
  }

  Widget _caption({
    required ThemeData theme,
    required String title,
    required String meta,
    required bool current,
    bool center = false,
  }) {
    final scheme = theme.colorScheme;
    final accent = context.semanticColors.magnitude;
    return Column(
      crossAxisAlignment: center
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: center ? 3 : 2,
          textAlign: center ? TextAlign.center : TextAlign.start,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelMedium?.copyWith(
            color: current ? accent : scheme.onSurface,
            fontWeight: current ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
        if (meta.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            meta,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}
