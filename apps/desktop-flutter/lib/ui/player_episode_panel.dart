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
/// ## 线路 chip = **预览**，不是播放
///
/// 点线路 chip 只换「这一屏显示哪条线路的集与卡片」，**不动播放**（用户反馈
/// 2026-11-22：以前点一下就切走了正在看的那一集）；真正换线路发生在用户点某张
/// 集数卡片时——那一下同时带上线路与集号（[onSelectEpisode]），
/// 对齐安卓 `VideoActivity.onItemClick(Flag)` 的「只重绑选集、不起播」。
///
/// 预览别的线路时，面板按 `locateEpisodeInLine` 定位到「正在播放那一集」在
/// 新线路里的对应位置（集名 → 集号 → 第 1 集），区间与滚动都落在那里，
/// 但**不画「正在播放」高亮**：那一集此刻并没有在播。
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
import 'poster_image.dart';
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

/// 选集回调：`(线路展示标识, 该线路剧集列表里的绝对下标)`。
///
/// 线路与下标必须一起给：预览线路与正在播放的线路可以不同，只回一个下标会让
/// 调用方拿「预览线路的第 N 集」去播「正在播放线路的第 N 集」。
typedef PlayerEpisodeTap = void Function(String flag, int index);

/// 播放器选集面板。
///
/// 自身只负责「展示 + 选择」：切集与切线路都由调用方注入（播放器握着
/// 解析与历史写入），面板不碰任何播放状态。
class PlayerEpisodePanel extends StatefulWidget {
  const PlayerEpisodePanel({
    super.key,
    required this.title,
    required this.playLines,
    required this.lineFlag,
    required this.episodeIndex,
    required this.episodeCardsByFlag,
    required this.onSelectEpisode,
    this.reversed = false,
    this.posterUrl,
  });

  /// 片名（面板标题区第一行）。
  final String title;

  /// 详情页给出的全部线路（只有 >1 条时渲染线路行）。
  ///
  /// 线路行点一下就**只换预览**：面板从这份列表里取那条线路自己的剧集，
  /// 不再回调调用方起播。分集必须在这里带全——面板不另问调用方要第二条线路的集。
  final List<VodPlayLine> playLines;

  /// **正在播放**的线路在 [playLines] 里的展示标识。
  ///
  /// 它不是「正在预览的线路」：预览是面板内部状态，点别的 chip 换的是面板从
  /// [playLines] / [episodeCardsByFlag] 取到的那一份数据。
  final String lineFlag;

  /// 正在播放的集在**当前线路**剧集列表里的下标。
  final int episodeIndex;

  /// 详情页为**每条线路**各算一次的卡片（`PlaybackRequest.episodeCardsByFlag`）。
  ///
  /// 顺序是**展示顺序**：与面板渲染的集列表一一对应（详情页倒序时它也是倒序的），
  /// 所以取卡片只能用展示下标，不能用剧集的原始下标。
  ///
  /// 允许缺线路、比剧集短，甚至为空（未匹配 TMDB / 历史续播 / 换源）：
  /// 缺卡片的集退化为「集名文字卡」，**不补集、不编造剧照**。
  final Map<String, List<TmdbEpisodeCard>> episodeCardsByFlag;

  /// 详情页的页面级「倒序」开关状态（`browse_pages.dart` 的 `_episodesReversed`）。
  ///
  /// 面板不解释这个开关的业务含义，只**跟随详情页那一刻的展示顺序**：详情页倒序时
  /// 它下发的卡片是按倒序排的，面板必须把集列表一起倒过来，否则区间标签会与详情页
  /// 相反、卡片会贴到别的集上。
  final bool reversed;

  /// 本剧海报：某集剧照缺失/加载失败时回退到它（与详情页 `TmdbEpisodeCardTile`
  /// 的 `posterUrl` 同一条回退）。它也不可用时保留集号占位，不丢集。
  final String? posterUrl;

  /// 点卡片：参数是**预览线路的展示标识**与该线路剧集列表里的**绝对下标**。
  final PlayerEpisodeTap onSelectEpisode;

  @override
  State<PlayerEpisodePanel> createState() => _PlayerEpisodePanelState();

  /// 某条线路的剧集；线路不在 [playLines] 里时返回空（不猜、不借用别条线路）。
  List<VodEpisode> episodesOf(String flag) {
    for (final line in playLines) {
      if (line.flag == flag) return line.episodes;
    }
    return const [];
  }

  /// 正在播放线路的剧集。
  List<VodEpisode> get episodes => episodesOf(lineFlag);

  /// 正在播放线路的展示名（标题区第二行的来源）。
  String get lineLabel => displayNameOf(lineFlag);

  /// 线路展示名；线路不在 [playLines] 里时用 flag 本身兜底。
  String displayNameOf(String flag) {
    for (final line in playLines) {
      if (line.flag == flag) return line.displayName;
    }
    return flag;
  }
}

class _PlayerEpisodePanelState extends State<PlayerEpisodePanel> {
  final ScrollController _gridScroll = ScrollController();

  /// 正在**预览**的线路（初值 = 正在播放的线路）。
  ///
  /// 面板的一切展示（集列表、区间、卡片、标题区）都跟着它走；点 chip 只改它，
  /// 真正起播发生在点卡片时。
  late String _previewFlag;

  /// 正在预览线路的剧集（[PlayerEpisodePanel.episodesOf]）。
  late List<VodEpisode> _episodes;

  late List<EpisodeRange> _ranges;
  late int _rangeIndex;

  /// 区间与滚动优先定位到的集（[_episodes] 里的下标）。
  ///
  /// 预览正在播放的线路时是 [PlayerEpisodePanel.episodeIndex]；预览别的线路时是
  /// [locateEpisodeInLine] 定位出的对应集。它只决定落点，**不画「正在播放」高亮**：
  /// 那一集此刻并没有在播。
  late int _focusIndex;

  /// 打开/换线路后是否已经滚动到 [_focusIndex]（只做一次：用户自己滚动后不该被拽回去）。
  bool _didAutoScroll = false;

  @override
  void initState() {
    super.initState();
    _previewFlag = widget.lineFlag;
    _episodes = widget.episodesOf(_previewFlag);
    _focusIndex = _clampEpisodeIndex(widget.episodeIndex);
    _resetRanges();
  }

  int _clampEpisodeIndex(int index) => _episodes.isEmpty
      ? 0
      : index.clamp(0, _episodes.length - 1);

  /// 按当前预览线路重算区间与选中区间。
  void _resetRanges() {
    _ranges = EpisodeRangePolicy.build(
      _episodes.length,
      // 区间与标签都按**展示顺序**算：详情页倒序时区间方向必须一起倒过来，
      // 否则面板第一个区间标的是「1-20」而里面装的是最后的 20 集。
      _displayIndex(_focusIndex),
      widget.reversed,
    );
    _rangeIndex = EpisodeRangePolicy.selectedPosition(_ranges);
  }

  /// 某集在**展示顺序**里的下标。
  ///
  /// 倒序时集列表被整体翻过来，原始下标 `i` 对应展示下标 `length - 1 - i`；
  /// 区间、滚动定位与卡片取用都必须用展示下标。
  int _displayIndex(int index) {
    final count = _episodes.length;
    if (count <= 0) return 0;
    final mapped = widget.reversed ? count - 1 - index : index;
    return mapped.clamp(0, count - 1);
  }

  /// 展示下标 → 原始下标（[_episodes] 里的绝对下标）。
  ///
  /// 卡片 key 与切集回调都必须用原始下标，否则倒序下点第一张卡会播成第 1 集。
  int _originalIndex(int displayIndex) =>
      widget.reversed ? _episodes.length - 1 - displayIndex : displayIndex;

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
    if (_episodes.isEmpty || _ranges.isEmpty) return const [];
    final range = _ranges[_safeRangeIndex];
    // 与 `EpisodeRangePolicy.slice` 同一套夹取规则，保证下标与切片一一对应。
    final start = range.start.clamp(0, _episodes.length);
    final end = range.end.clamp(start, _episodes.length);
    return [
      for (var i = start; i < end; i++) (i, _episodes[_originalIndex(i)]),
    ];
  }

  /// 正在播放那一集的集名（用它在别的线路里定位对应集）。
  String get _playingEpisodeName {
    final episodes = widget.episodes;
    final index = widget.episodeIndex;
    if (index < 0 || index >= episodes.length) return '';
    return episodes[index].name;
  }

  /// 取**展示顺序**第 [displayIndex] 张卡片；没有可信卡片时返回 `null`（退化为文字卡）。
  ///
  /// 为什么按展示顺序取：详情页下发的卡片与它自己的渲染顺序一一对应（倒序时卡片
  /// 也是倒序的），按原始下标取会把第 1 张卡的剧照贴到最后一集上。
  ///
  /// 为什么卡片数必须与**这条线路**的集数**相等**才认：`episodeCardsByFlag` 是
  /// 详情页按线路算好的一次性快照，播放器自己算不回来（缺选中季度与季过滤后的
  /// 渲染顺序）。线路集数不同还按下标对齐，会把第 3 集的剧照贴到第 5 集上——
  /// 宁可全部退回集名文字卡，也不给错的信息。
  TmdbEpisodeCard? _cardAt(int displayIndex) {
    final cards =
        widget.episodeCardsByFlag[_previewFlag] ?? const <TmdbEpisodeCard>[];
    if (cards.length != _episodes.length) return null;
    if (displayIndex < 0 || displayIndex >= cards.length) return null;
    return cards[displayIndex];
  }

  void _close() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
  }

  /// 点卡片：先关面板再起播（线路跟着一起回传——预览的可能不是正在播放的那条）。
  ///
  /// 顺序不能反：切集会立刻重建播放器请求（新剧集、新地址），面板留着
  /// 就会显示上一集的高亮；先关掉，切集失败也不会留下一个假装在播的面板。
  void _selectEpisode(int index) {
    final flag = _previewFlag;
    _close();
    widget.onSelectEpisode(flag, index);
  }

  /// 点线路：只换预览，**不关面板、不起播**。
  ///
  /// 以前这里是「关面板 + 立即切线路续播」，用户反馈 2026-11-22 明确否掉：
  /// 想看一眼别的线路有哪些集，不该把正在看的这一集停掉。面板手里的
  /// [PlayerEpisodePanel.playLines] / [episodeCardsByFlag] 本来就是全线路的，
  /// 原地换一份数据即可，不必重开面板。
  void _selectLine(VodPlayLine line) {
    if (line.flag == _previewFlag) return;
    final episodes = widget.episodesOf(line.flag);
    setState(() {
      _previewFlag = line.flag;
      _episodes = episodes;
      // 落在「正在播放那一集」在新线路里的对应位置（沿用切线路续播的同一套
      // 定位：集名 → 集号 → 第 1 集），换线路不会凭空回到第一集。
      _focusIndex = locateEpisodeInLine(
        episodes: episodes,
        currentName: _playingEpisodeName,
      );
      _resetRanges();
      // 新区间是另一批集：让下一帧重新把对应集滚进视口。
      _didAutoScroll = false;
    });
    if (_gridScroll.hasClients) _gridScroll.jumpTo(0);
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

  /// 打开/换线路后把要落点的那一集滚进视口。
  ///
  /// 为什么自己算偏移而不用 `Scrollable.ensureVisible`：网格是 `builder`
  /// 懒加载的，那一集那张卡在滚动到它之前**根本不存在**，没有可定位的 element。
  void _scheduleScrollToCurrent({
    required int columns,
    required double rowExtent,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_gridScroll.hasClients) return;
      final range = _ranges[_safeRangeIndex];
      final span = math.max(1, range.end - range.start);
      final local = (_displayIndex(_focusIndex) - range.start).clamp(0, span - 1);
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
    final lineName = widget.displayNameOf(_previewFlag);
    final linePart = lineName.isEmpty ? '' : '$lineName · ';
    // 预览的不是正在播放的线路时补一句提示：用户点 chip 后画面不会变，
    // 不说明一句会以为「没切过去」。真正的切换发生在点集数卡片那一下。
    final hint = _previewFlag == widget.lineFlag ? '' : ' · 点集数卡片起播';
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
                  '$linePart共 ${_episodes.length} 集$hint',
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
            // 选中态跟着**预览**走：点哪条线路，那一屏就显示哪条线路的集。
            selected: line.flag == _previewFlag,
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
    // 只有「预览的是正在播放的那条线路」时才有当前集：预览别的线路时那一集
    // 并没有在播，强高亮会谎报播放状态。
    final current = _previewFlag == widget.lineFlag && index == widget.episodeIndex;
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

  /// 16:9 剧照满铺；剧照缺失/加载失败时回退**本剧海报**（与详情页
  /// `TmdbEpisodeCardTile` 的 `posterUrl` 同一条回退），两者都不可用时才是
  /// 纯色占位块 + 集号（**不放假图**）。
  ///
  /// 为什么必须回退：未匹配 TMDB 的集、以及**非当前线路**的卡片本来就没有剧照
  /// （`episodeCardsForEpisodes(includeMetadata: false)`），没有回退时一屏灰块
  /// （用户反馈 2026-11-22：「黑白空白太丑了」）。海报是整部剧的图，不是这一集的
  /// 画面，所以只在剧照缺席时兜底，不冒充剧照。
  Widget _still({
    required ThemeData theme,
    required TmdbEpisodeCard card,
    required bool current,
  }) {
    final scheme = theme.colorScheme;
    final accent = context.semanticColors.magnitude;
    final number = card.number > 0 ? 'E${card.number}' : '';
    final poster = widget.posterUrl?.trim() ?? '';
    // 回退海报也算「有图」：同一张海报铺满一屏时，集号角标是唯一的区分线索，
    // 不能因为主图缺失就把它一起藏掉。
    final hasImage = card.hasStill || poster.isNotEmpty;
    return Stack(
      fit: StackFit.expand,
      children: [
        PosterImage(
          url: card.stillUrl,
          fallbackUrl: poster,
          // 两张都拿不到时仍要留住格子与集号：卡片不消失（消失=丢集）。
          placeholder: _stillPlaceholder(theme, number),
        ),
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
        if (hasImage && number.isNotEmpty)
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
