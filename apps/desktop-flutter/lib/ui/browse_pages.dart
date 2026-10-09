/// 浏览页：首页/分类 + 详情（§17.2 首页/分类页、详情页）。
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/app_error.dart';
import '../core/protocol.dart';
import '../core/tmdb_detail_model.dart';
import '../core/tmdb_identity.dart';
import '../core/tmdb_media.dart';
import '../core/tmdb_playback.dart';
import '../core/tmdb_title.dart';
import '../services/spider_router.dart';import '../state/app_state.dart';
import '../state/tmdb_state.dart';
import 'app.dart';
import 'config_pages.dart';
import 'player_page.dart';
import 'search_page.dart';
import 'tmdb_detail_page.dart';
import 'tmdb_detail_view.dart';
import 'tmdb_widgets.dart';

class BrowsePage extends StatelessWidget {
  const BrowsePage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    if (!state.hasConfig) {
      return const _EmptyHint(
        title: '还没有导入配置',
        message: '请点击顶栏「导入配置」，支持 URL、本地文件和 JSON 文本三种方式。',
      );
    }
    final site = state.selectedSite;
    if (site == null) {
      return const _EmptyHint(
        title: '请选择站点',
        message: '点击顶栏「选择站点」挑选一个可运行的站点。',
      );
    }
    final availability = state.siteItems
        .where((item) => item.site.key == site.key)
        .map((item) => item.availability)
        .firstWhereOrNull();
    if (availability != null && !availability.available) {
      return _UnsupportedSiteHint(
        site: site,
        availability: availability,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 分类条固定（页面级上下文，永远可达），筛选条与网格一起滚动。
        _BrowseTabBar(state: state, site: site),
        Expanded(child: _VodGrid(state: state)),
      ],
    );
  }
}

/// 海报网格度量。
///
/// 竖版海报标准比例是 `2:3`，网格按这个比例反推格子高度（见
/// [_VodGrid._gridDelegate]）。
const double _posterTargetWidth = 150;
const double _posterSpacing = 14;
const double _posterGridPadding = 16;

/// 海报卡片文字区（标题 + 备注）的固定高度。
///
/// 给死高度而不是让它自适应：格子高度由「海报 2:3 + 本值」精确算出，文字区一旦
/// 浮动，海报就会被压成非 2:3。
const double _posterCaptionHeight = 40;

/// 顶部分类条（§17.1 分类区）：横向标签 + 选中下划线，**固定在网格上方**。
///
/// 为什么不再用「280px 左侧栏 + 垂直分类列表」（5559 真机实测 木偶[盘]）：
/// 1. 筛选维度渲染在侧栏里会**吃掉整栏高度**——该站点 5 个维度里仅「剧情」一组
///    就有 17 项，于是侧栏被筛选填满、真正的分类列表被挤出可视区（用户看到的
///    「分类不见了」正是这个）；
/// 2. 侧栏还带 `type=4 · key=02544b32…` 这类**内部调试字段**，不该出现在 UI 上；
/// 3. 分类是页面级上下文，横排在内容区顶部可以用满宽度，窗口缩放时也不挤压网格。
class _BrowseTabBar extends StatefulWidget {
  const _BrowseTabBar({required this.state, required this.site});

  final AppState state;
  final Site site;

  @override
  State<_BrowseTabBar> createState() => _BrowseTabBarState();
}

class _BrowseTabBarState extends State<_BrowseTabBar> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final home = state.homeResult;
    final classes = home?.classes ?? const <VodClass>[];
    // 首页有推荐内容才保留「默认推荐」标签（否则它只是个空态入口）。
    final hasHomeList = home?.list.isNotEmpty ?? false;
    final selected = state.selectedTypeId;
    final loading = state.contentPhase == LoadPhase.loading;
    final hasFilters = state.categoryFilters.isNotEmpty;

    return Container(
      height: 46,
      padding: const EdgeInsets.only(left: 8, right: 4),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            // 桌面端的竖滚轮在 Flutter 里不驱动横向滚动，需要显式转一次，
            // 否则分类多到溢出时滚轮推不动这条（§17.4 鼠标可用）。
            child: _WheelScroll(
              controller: _controller,
              child: SingleChildScrollView(
                controller: _controller,
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    // 首页**没有推荐内容**时不显示「默认推荐」标签：那个标签点进去
                    // 只有空态（实测 126 站点里 40 个如此），留在条上只会误导用户。
                    if (hasHomeList)
                      _BrowseTab(
                        key: const ValueKey('browse-tab-default'),
                        label: '默认推荐',
                        selected: selected == null,
                        onTap: loading ? null : state.selectDefaultListing,
                      ),
                    for (final item in classes)
                      _BrowseTab(
                        key: ValueKey('browse-tab-${item.typeId}'),
                        label: item.typeName,
                        selected: selected == item.typeId,
                        onTap: loading
                            ? null
                            : () => state.loadCategory(item.typeId),
                      ),
                  ],
                ),
              ),
            ),
          ),
          // 每组的「全部」只能各自取消自己，跨维度清空需要一个总入口。
          if (hasFilters)
            TextButton(
              key: const ValueKey('category-filter-clear'),
              onPressed: loading ? null : state.clearCategoryFilters,
              child: const Text('重置筛选'),
            ),
          IconButton(
            key: const ValueKey('browse-refresh'),
            tooltip: selected == null ? '刷新首页' : '刷新当前分类',
            onPressed: loading
                ? null
                : () => selected == null
                    ? state.loadHome(widget.site)
                    : state.loadCategory(selected),
            icon: const Icon(Icons.refresh, size: 18),
          ),
        ],
      ),
    );
  }
}

/// 单个分类标签：选中态用主色文字 + 下划线，未选中态为弱化文字。
///
/// 不用 `ChoiceChip` / `Tab`：Material 的 chip 自带实心底与描边，一行十几个会显得很
/// 重；这里需要的是「文字 + 细下划线」的轻量导航（对齐主流媒体库的分类条）。
class _BrowseTab extends StatelessWidget {
  const _BrowseTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      hoverColor: scheme.primary.withValues(alpha: 0.06),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: 14,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            const SizedBox(height: 4),
            Container(
              height: 3,
              width: 20,
              decoration: BoxDecoration(
                color: selected ? scheme.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 把纵向滚轮增量转成横向滚动（桌面端专用）。
///
/// Flutter 的横向 `Scrollable` 只消费 `scrollDelta.dx`，而普通鼠标只有 `dy`，
/// 于是「滚轮推不动横向标签条」。这里把明显偏向纵向的增量自己转成横向位移；
/// 横向分量更大时（触控板横扫）仍交给内部滚动视图处理，避免双重滚动。
class _WheelScroll extends StatelessWidget {
  const _WheelScroll({required this.controller, required this.child});

  final ScrollController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (event) {
        if (event is! PointerScrollEvent) return;
        final delta = event.scrollDelta;
        if (delta.dx.abs() >= delta.dy.abs()) return;
        if (!controller.hasClients) return;
        final position = controller.position;
        final target = (position.pixels + delta.dy).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        if (target == position.pixels) return;
        controller.jumpTo(target);
      },
      child: child,
    );
  }
}

/// 筛选条（§7.4.7）：每个维度一行「等宽标签 + 横向 chip」，随内容滚动。
///
/// 布局对齐主流桌面媒体库：行首是该维度的标签列（各行**等宽**，所以 chip 左边缘
/// 对齐），右侧 chip 自适应换行。选中态是主色淡底 + 主色文字，未选中是弱化纯文字。
///
/// 为什么不再用「每条一行 + 勾选框」：
/// - 垂直一行一项时，「剧情」这类 17 项的维度会把侧栏撞成几百像素高的长条，
///   真正的分类列表被挤到屏幕外；横向 chip 换行后同样 17 项只占 3 行；
/// - 早期用「更多（11）」折叠，用户根本不知道折起来的是什么，干脆全量展开；
/// - 勾选框 + 实底高亮是设置表单的视觉语言，不像媒体库的筛选条。
///
/// 整条**随网格滚动**而不是固定：窄窗口（1280×720）下多个维度约 150~200px，
/// 固定住会永久吃掉近 1/3 的网格高度。分类条（页面级上下文）固定即可。
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.state,
    required this.groups,
    required this.active,
  });

  final AppState state;
  final List<VodFilterGroup> groups;
  final Map<String, String> active;

  /// 标签列宽度的上下限：短名（「地区」）不留大片空白，长名（「资源类型」）
  /// 也不能无限挤压 chip 区。
  static const double _minLabelWidth = 40;
  static const double _maxLabelWidth = 88;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelWidth = _measureLabelWidth(context);
    // 请求在途时禁用点击：筛选是「即时生效」，连点会把多个响应乱序写回状态。
    final enabled = state.contentPhase != LoadPhase.loading;
    return Container(
      key: const ValueKey('category-filter-bar'),
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final group in groups)
            _FilterRow(
              group: group,
              labelWidth: labelWidth,
              selectedValue: active[group.key] ?? '',
              enabled: enabled,
              onSelect: (value) => state.setCategoryFilter(group.key, value),
            ),
        ],
      ),
    );
  }

  /// 标签列宽度 = 所有维度名里最宽者 + 间距，夹在 [min, max] 之间。
  ///
  /// 用固定宽度会让「资源类型」被截断或「地区」后留一片空白；各行宽度不一致又会让
  /// chip 左边缘参差。按实际文本量一次即可两全。
  double _measureLabelWidth(BuildContext context) {
    final style = _filterLabelStyle(context);
    final direction = Directionality.of(context);
    var widest = 0.0;
    for (final group in groups) {
      final painter = TextPainter(
        text: TextSpan(text: group.name, style: style),
        maxLines: 1,
        textDirection: direction,
      )..layout();
      if (painter.width > widest) widest = painter.width;
    }
    return (widest + 10).clamp(_minLabelWidth, _maxLabelWidth);
  }
}

/// 行首维度标签的样式（筛选条各行的标签列共用）。
TextStyle _filterLabelStyle(BuildContext context) {
  final theme = Theme.of(context);
  return theme.textTheme.bodySmall!.copyWith(
    fontSize: 13,
    height: 1.2,
    color: theme.colorScheme.onSurfaceVariant,
  );
}

/// 单个筛选维度：一行「标签 + chip 换行区」。
class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.group,
    required this.labelWidth,
    required this.selectedValue,
    required this.enabled,
    required this.onSelect,
  });

  final VodFilterGroup group;
  final double labelWidth;
  final String selectedValue;
  final bool enabled;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    // 站点自带「全部」（`v` 为空串）时不重复补；缺失时必须补，否则该维度一旦
    // 选中就没有任何入口能取消它（只能整条重置）。
    final hasAll = group.options.any((option) => option.value.isEmpty);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: labelWidth,
            child: Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Tooltip(
                message: group.name,
                child: Text(
                  group.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _filterLabelStyle(context),
                ),
              ),
            ),
          ),
          Expanded(
            child: Wrap(
              children: [
                if (!hasAll)
                  _FilterChip(
                    key: ValueKey('category-filter-${group.key}-all'),
                    label: '全部',
                    selected: selectedValue.isEmpty,
                    onTap: enabled ? () => onSelect('') : null,
                  ),
                for (final option in group.options)
                  _FilterChip(
                    key: ValueKey('category-filter-${group.key}-${option.value}'),
                    label: option.name,
                    selected: option.value == selectedValue,
                    onTap: enabled ? () => onSelect(option.value) : null,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 单个筛选项 chip：选中为主色淡底 + 主色文字，未选中为弱化纯文字。
///
/// 选中用 `primary` 的**透明度淡化**而不是 `primaryContainer`：后者在深色主题下
/// 是一块很重的实底蓝，十几个维度排下来会异常晦澀；淡化底在深浅两套主题下都能
/// 得到参考实现那种「淡淡一层色块」的观感，而且主色文字对比度始终足够。
class _FilterChip extends StatelessWidget {
  const _FilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: dark ? 0.22 : 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          hoverColor: scheme.primary.withValues(alpha: dark ? 0.10 : 0.06),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 13,
                height: 1.2,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 海报网格区（§17.1 海报网格）：筛选条 + 海报网格 + 滚动加载页脚。
class _VodGrid extends StatelessWidget {
  const _VodGrid({required this.state});

  final AppState state;

  /// 距底部多少像素时提前触发下一页。
  ///
  /// 提前量而不是“贴底”：桥接的网盘聚合站一次请求实测 0.3~2s，等滚到最后一排
  /// 才发请求会让底部出现明显的空窗。
  static const double _prefetchExtent = 700;

  @override
  Widget build(BuildContext context) {
    final result = state.selectedTypeId == null
        ? state.homeResult
        : state.categoryResult;
    final vods = result?.list ?? const <Vod>[];
    // 猫源/部分站点首页只返回分类（`class` 非空）而 `list` 为空，需要用户先点分类。
    // 直接显示"没有内容"会把正常站点误报成空站（实测 126 站点里 40 个如此），
    // 因此按“有无分类”区分两种空态文案。
    final hasClasses = result?.classes.isNotEmpty ?? false;
    final filters = _filtersFor(state, state.selectedTypeId);
    final loading = state.contentPhase == LoadPhase.loading;
    // 分页页脚只在分类上下文里出现：首页结果没有分页语义。
    final paged = state.selectedTypeId != null && vods.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.lastError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: ErrorBanner(
              error: state.lastError!,
              onDismiss: state.clearError,
            ),
          ),
        if (state.notice != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: _NoticeBanner(
              message: state.notice!,
              onDismiss: state.clearNotice,
            ),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => NotificationListener<
                ScrollNotification>(
              onNotification: _onScroll,
              child: CustomScrollView(
                slivers: [
                  // 筛选条随网格一起滚动：窄窗口下多个维度约占 150~200px，固定住
                  // 会永久吃掉近 1/3 的网格高度；分类条（页面级上下文）才固定。
                  if (filters.isNotEmpty)
                    SliverToBoxAdapter(
                      child: _FilterBar(
                        state: state,
                        groups: filters,
                        active: state.categoryFilters,
                      ),
                    ),
                  if (vods.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _emptyState(
                        loading: loading,
                        hasClasses: hasClasses,
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(
                        _posterGridPadding,
                        14,
                        _posterGridPadding,
                        8,
                      ),
                      sliver: SliverGrid(
                        gridDelegate: _gridDelegate(constraints.maxWidth),
                        delegate: SliverChildBuilderDelegate(
                          (context, index) => _VodCard(
                            key: ValueKey('vod-card-${vods[index].vodId}'),
                            vod: vods[index],
                            onTap: () => _openDetail(context, vods[index]),
                          ),
                          childCount: vods.length,
                        ),
                      ),
                    ),
                  // 刷新首页时旧列表**不被清空**（loadHome 保留 _homeResult），
                  // 此时只压一条细进度条：整页闪成空白会让用户以为断网了。
                  if (loading && vods.isNotEmpty)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: LinearProgressIndicator(minHeight: 2),
                      ),
                    ),
                  if (paged)
                    SliverToBoxAdapter(child: _ScrollFooter(state: state)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 滚动到底自动加载下一页。
  ///
  /// 重入靠**状态层**拦（`categoryLoadingMore` / `categoryHasMore`），这里不自己
  /// 记账：滚动通知一帧可能来好几条（update + end），在 UI 里判重很容易漏。
  bool _onScroll(ScrollNotification notification) {
    // 只认最外层列表；嵌套滚动（如筛选条内部）不参与触发。
    if (notification.depth != 0) return false;
    if (notification.metrics.maxScrollExtent - notification.metrics.pixels >
        _prefetchExtent) {
      return false;
    }
    if (state.selectedTypeId == null) return false;
    if (state.contentPhase == LoadPhase.loading) return false;
    if (!state.categoryHasMore || state.categoryLoadingMore) return false;
    unawaited(state.loadMoreCategory());
    return false;
  }

  Widget _emptyState({required bool loading, required bool hasClasses}) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (hasClasses) {
      return const _EmptyHint(
        title: '请选择一个分类',
        message: '该站点首页只返回分类列表（未提供推荐内容）。'
            '点顶部分类条里的任一项即可加载影片；若分类也为空，再切换站点或更新配置。',
      );
    }
    return const _EmptyHint(
      title: '没有内容',
      message: '该分类返回空列表。若站点不可用，请切换站点或更新配置。',
    );
  }

  /// 网格度量：先按可用宽度定列数与列宽，再由列宽推出格子高度。
  ///
  /// 为什么不用 `SliverGridDelegateWithMaxCrossAxisExtent`：它的 `mainAxisExtent`
  /// 是固定值，窗口变窄时列宽变小、高度不变，海报会被压成非 2:3 或被裁切。
  /// 这里列宽已知，格子高度就能精确算成「海报 2:3 + 文字区」，任何窗口宽度下
  /// 比例都稳定（§17.5 要求窗口缩放布局稳定）。
  static SliverGridDelegate _gridDelegate(double maxWidth) {
    final usable = maxWidth - _posterGridPadding * 2;
    final columns = (usable / (_posterTargetWidth + _posterSpacing))
        .round()
        .clamp(2, 12);
    final cellWidth = (usable - (columns - 1) * _posterSpacing) / columns;
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      crossAxisSpacing: _posterSpacing,
      mainAxisSpacing: 8,
      mainAxisExtent: cellWidth * 1.5 + 8 + _posterCaptionHeight,
    );
  }

  /// 取当前分类的筛选维度。
  ///
  /// 三个来源按优先级：分类结果 → 首页结果。
  /// 首页的 `filters` 是按 `type_id` 分组的 map，所以必须用当前 `type_id` 取子集；
  /// 分类请求返回的 `filters` 已经是**该分类自己的**一组（`map` 只有一个键或
  /// 直接就是列表），因此优先用它，拿不到再回退首页。
  static List<VodFilterGroup> _filtersFor(AppState state, String? typeId) {
    if (typeId == null) return const [];
    final fromCategory = _groupFor(state.categoryResult, typeId);
    if (fromCategory.isNotEmpty) return fromCategory;
    return _groupFor(state.homeResult, typeId);
  }

  static List<VodFilterGroup> _groupFor(SiteResult? result, String typeId) {
    final filters = result?.filters;
    if (filters == null || filters.isEmpty) return const [];
    final direct = filters[typeId];
    if (direct != null && direct.isNotEmpty) return direct;
    // 某些站点把全部维度放在单个键下（或键名与 type_id 不一致）：
    // 此时只要只有一组就直接用它，否则合并全部（宁多不少）。
    if (filters.length == 1) return filters.values.first;
    return [for (final group in filters.values) ...group];
  }

  Future<void> _openDetail(BuildContext context, Vod vod) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailPage(state: state, vod: vod),
      ),
    );
  }
}

/// 海报卡片：海报（2:3 圆角）+ 居中标题 + 备注。
///
/// 标题居中、只用一档弱化色——参照实现的卡片就是「图 + 居中一行字」，不加边框
/// 与卡片底色，密集排列时比带底色的卡片干净得多。
class _VodCard extends StatelessWidget {
  const _VodCard({super.key, required this.vod, required this.onTap});

  final Vod vod;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final remarks = vod.vodRemarks?.trim() ?? '';
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // `AspectRatio` 而不是 `Expanded`：海报比例由比例盒子保证，文字区再高
          // 也不会把海报压成非 2:3。
          AspectRatio(
            aspectRatio: 2 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: PosterImage(url: vod.vodPic),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            // 放大字号（无障碍）时只缩不放：文字区高度是固定值，不夹住就会溢出格子。
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.25,
              child: Column(
                children: [
                  Text(
                    vod.vodName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontSize: 13,
                      height: 1.2,
                    ),
                  ),
                  if (remarks.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      remarks,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        height: 1.2,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 滚动加载页脚：[加载中] / [加载更多] / [没有更多了]。
///
/// 为什么除了自动触发还要有按钮：第一页不足一屏时（实测站点只回 3~6 条的短
/// 分类），列表不产生任何滚动，滚动通知永远不触发，下一页就永远拿不到。
/// 按钮是这种「无滚动可滚」场景的唯一入口，同时也给不习惯无限滚动的用户一个
/// 明确的下一步。
class _ScrollFooter extends StatelessWidget {
  const _ScrollFooter({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (state.categoryLoadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      );
    }
    if (state.categoryHasMore) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
        child: Center(
          child: TextButton.icon(
            key: const ValueKey('category-load-more'),
            onPressed: state.contentPhase == LoadPhase.loading
                ? null
                : state.loadMoreCategory,
            icon: const Icon(Icons.expand_more, size: 18),
            label: const Text('加载更多'),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 10, 0, 20),
      child: Center(
        child: Text(
          '已经到底啦',
          key: const ValueKey('category-list-end'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 详情页（§17.2 详情页）。
class DetailPage extends StatefulWidget {
  const DetailPage({super.key, required this.state, required this.vod});

  final AppState state;
  final Vod vod;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  /// 当前选中线路的 `flag`（`04` §3.1 ④）。
  ///
  /// 点击线路条即切换，下方剧集卡片随之变成该线路的集（对齐上游 `@id/flag`）。
  /// 空串表示「尚未选定」，此时默认取第一条线路。
  String _selectedLineFlag = '';

  /// 剧集卡片是否倒序（对齐上游 `@id/episodeReverse`）。
  bool _episodesReversed = false;

  /// 剧集是否网格模式（对齐上游 `@id/episodeViewMode`）。
  bool _episodeGridMode = false;

  @override
  void initState() {
    super.initState();
    // 必须监听 AppState：详情请求在页面挂载后才完成，不重建就永远停在加载中
    // （实测「第一次进去说没有线路、第二次一直转圈」的直接成因）。
    // 搜索页、Spider 管理页同样监听了各自的状态变更。
    widget.state.addListener(_onStateChanged);
    // TMDB 区块也需监听（异步匹配/详情完成后重建，`04` §3.3）。
    widget.state.tmdb.addListener(_onStateChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.state.loadDetail(widget.vod);
    });
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChanged);
    widget.state.tmdb.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  void _closeDetail() {
    // 离开详情页时清掉全局详情状态（§8.3）：结果与所选影片是页面级临时状态，
    // 不清理会让下一次进入详情页先渲染上一部剧的线路（实测串剧）。
    widget.state.clearDetail();
    Navigator.of(context).pop();
  }

  /// 打开手动匹配弹窗（`04` §5.1）。
  Future<void> _openMatchDialog() async {
    final state = widget.state;
    final vod = _currentVod;
    final item = await showDialog<TmdbItem>(
      context: context,
      builder: (_) => TmdbMatchDialog(
        initialQuery: state.tmdb.item?.title ?? vod?.vodName ?? '',
        search: state.searchTmdb,
        resolveProviderId: state.resolveTmdbProviderId,
      ),
    );
    if (item == null || !mounted) return;
    await state.matchTmdbManual(item: item, sourceTitle: vod?.vodName);
  }

  /// 打开季度绑定弹窗（`04` §5.2）。
  Future<void> _openSeasonDialog() async {
    final state = widget.state;
    final tmdb = state.tmdb;
    final counts = tmdb.seasonEpisodeCounts;
    final seasons = counts.keys.toList()..sort();
    if (seasons.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('TMDB 未返回季度信息，暂时无法手动绑定季度')),
      );
      return;
    }
    final line = tmdb.sourceLine;
    final choice = await showDialog<TmdbSeasonChoice>(
      context: context,
      builder: (_) => TmdbSeasonDialog(
        tmdbSeasons: seasons,
        seasonCounts: counts,
        sourceEpisodeCount: line?.episodeCount ?? 0,
        currentSeason: tmdb.selectedSeason >= 0 ? tmdb.selectedSeason : null,
        canAutoSlice: tmdb.canAutoSlice,
      ),
    );
    if (choice == null || !mounted) return;
    await state.bindTmdbSeason(choice);
    if (!mounted) return;
    await state.reloadTmdb();
  }

  Vod? get _currentVod {
    final result = widget.state.detailResult;
    if (result != null &&
        result.list.isNotEmpty &&
        result.list.first.vodId == widget.vod.vodId) {
      return result.list.first;
    }
    return widget.vod;
  }

  Future<void> _play(Vod vod, VodPlayLine line, int episodeIndex) async {
    final episode = line.episodes[episodeIndex];
    final state = widget.state;
    try {
      final decision = await state.resolvePlayback(
        episodeTarget: episode.url,
        flag: line.flag,
        vodId: vod.vodId,
      );
      if (decision == null || decision.url == null) {
        throw AppError(
          AppErrorKind.playbackUrlMissing,
          '播放决策没有返回可用地址',
          detail: 'line=${line.flag} episode=${episode.name}',
        );
      }
      if (!mounted) return;
      // §15.2「继续播放」：进入播放器时从历史位置续播（无有效历史则为 null）。
      final resume = state.resumePositionFor(
        siteKey: state.selectedSite?.key ?? '',
        vodId: vod.vodId,
        flag: line.flag,
        episodeId: episode.url,
      );
      // TMDB 季度身份（`04` §8.1）：已确证季度时透传；未确证时只传 URL/集名。
      final tmdb = state.tmdb;
      final identity = TmdbPlaybackIdentity.of(
        identity: tmdb.identity,
        episode: episode,
        flagKey: tmdb.sourceLine?.flagKey ?? line.flag,
        seasonNumber: tmdb.hasMatch && tmdb.selectedSeason >= 0
            ? tmdb.selectedSeason
            : -1,
        episodeNumber: _tmdbEpisodeNumberOf(episode),
      );
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerPage(
            state: state,
            request: PlaybackRequest(
              url: decision.url!,
              // 历史里存**站点入口目标**（`episode.url`），而不是这个解析后的
              // 可播地址（带时效签名，站点不认）。续播时要拿它回传站点重解析。
              episodeTarget: episode.url,
              headers: decision.headers?.asRequestHeaders ?? const {},
              title: vod.vodName,
              siteKey: state.selectedSite?.key ?? '',
              vodId: vod.vodId,
              vodName: vod.vodName,
              episodeName: episode.name,
              flag: line.flag,
              playLines: state.playLinesOf(vod),
              episodeIndex: episodeIndex,
              vodPic: vod.vodPic,
              startPosition: resume,
              // 外挂字幕（§10.3）与弹幕（§21 Phase 3）：播放结果 + 代理前 Header。
              subtitles: decision.subs,
              danmaku: decision.danmaku,
              subtitleHeaders:
                  decision.assetHeaders?.asRequestHeaders ?? const {},
              tmdb: identity.hasIdentity ? identity : null,
            ),
          ),
        ),
      );
    } catch (error) {
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(failure.userMessage)),
      );
    }
  }

  static int _tmdbEpisodeNumberOf(VodEpisode episode) {
    final raw = episode.extra['tmdb_episode_number'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return -1;
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    // 只有「结果属于本页影片」才允许渲染（§8.3）。
    //
    // 详情结果是 AppState 上的全局字段，用户「返回列表 → 点另一部剧」时，前一个
    // 请求可能还在飞行（本机实测 3.9~7.1s），若直接取 `detailResult.list.first`，
    // 新页面会先套用上一部剧的线路与简介，点播即串剧。这里以 vod_id 判归属，
    // 不属于本页时退回列表页传入的条目（其线路可能已由列表数据携带）。
    final result = state.detailResult;
    final belongs = result != null &&
        result.list.isNotEmpty &&
        result.list.first.vodId == widget.vod.vodId;
    final vod = belongs ? result.list.first : widget.vod;
    final lines = state.playLinesOf(vod);
    final loading = state.detailPhase == LoadPhase.loading;
    final tmdb = state.tmdb;
    // 头部补位（`04` §3.2）：**仅补位不覆盖**来源已有字段。
    final display = tmdb.hasMatch ? tmdb.enrich(vod).vod : vod;
    // TMDB 展示模型（海报/背景/类型/时长/季集数/演职人员…）。
    final tmdbData = tmdb.detailData;

    return Scaffold(
      appBar: AppBar(
        title: Text(vod.vodName),
        leading: IconButton(
          tooltip: '返回',
          onPressed: _closeDetail,
          icon: const Icon(Icons.arrow_back),
        ),
        actions: [
          IconButton(
            tooltip: state.isFavorite(kind: 'vod', targetId: vod.vodId)
                ? '取消收藏'
                : '收藏该影片',
            onPressed: () => state.toggleFavorite(
              kind: 'vod',
              targetId: vod.vodId,
              title: vod.vodName,
              subtitle: vod.vodRemarks,
            ),
            icon: Icon(
              state.isFavorite(kind: 'vod', targetId: vod.vodId)
                  ? Icons.bookmark
                  : Icons.bookmark_border,
            ),
          ),
          IconButton(
            tooltip: '刷新详情',
            onPressed: () => state.loadDetail(widget.vod),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: loading && lines.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // 详情错误只在「确实是在拉本页详情且没有可用线路」时提示，
                // 避免上一个条目的失败信息干扰当前页面（§8.3、§8.4）。
                if (state.detailError != null && lines.isEmpty)
                  ErrorBanner(
                    error: state.detailError!,
                    onDismiss: state.clearDetailError,
                  ),
                // 动态背景头部（`04` §3.1 ①）：用 TMDB 海报/剧照当背景，
                // 未匹配时回退到来源海报，保证头部不空白。
                TmdbDetailHeader(
                  data: tmdb.detailData ??
                      TmdbDetailData(
                        title: display.vodName,
                        overview: display.vodContent,
                        posterUrl: display.vodPic,
                        backdropUrls: [
                          if ((display.vodPic ?? '').isNotEmpty) display.vodPic!,
                        ],
                        rating: 0,
                      ),
                  statusBar: TmdbStatusBar(
                    state: tmdb,
                    onConfigure: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => TmdbSettingsPage(state: state),
                      ),
                    ),
                    onMatch: _openMatchDialog,
                    onRematch: _openMatchDialog,
                    onSelectSeason: _openSeasonDialog,
                    onRetry: () => state.reloadTmdb(),
                  ),
                ),
                const SizedBox(height: 12),
                // 信息表（`04` §3.1 ①）：对齐上游 `site/year/area/type/
                // director/actor` 的元信息行。**来源字段优先**，缺失处用 TMDB
                // 补位值（§3.2「仅补位不覆盖」），因此这里直接读补位后的 `display`
                // 与 `tmdbData`。
                TmdbInfoTable(
                  rows: [
                    ('类型', tmdbData?.genres.join(' / ')),
                    ('地区', display.vodArea),
                    ('年份', display.vodYear),
                    ('时长', tmdbData?.runtimeLabel),
                    ('季集', tmdbData?.seasonEpisodeLabel),
                    ('状态', tmdbData?.status),
                    ('导演', display.vodDirector),
                    ('演员', display.vodActor),
                    ('评分', tmdb.ratingText),
                    ('备注', display.vodRemarks),
                    ('语言', tmdbData?.languages.join(' / ')),
                  ],
                ),
                if (display.vodContent != null &&
                    display.vodContent!.trim().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  // 简介：默认 4 行 + 「展开」（`04` §11 长文本要求）。
                  _ExpandableOverview(text: display.vodContent!.trim()),
                ],
                const SizedBox(height: 12),
                // 季度选择器（`04` §4.1）：仅 tv 且已匹配时渲染。
                TmdbSeasonSelector(
                  state: tmdb,
                  onChanged: (season) {
                    tmdb.selectSeason(season);
                    unawaited(tmdb.loadEpisodes(generation: tmdb.generation));
                  },
                  onSelectManual: _openSeasonDialog,
                ),
                // 纯 TMDB 详情页入口（`04` §6.1）。
                if (tmdb.hasMatch && tmdb.identity != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const ValueKey('tmdb-open-detail'),
                      onPressed: () => _openTmdbDetail(tmdb.identity!),
                      icon: const Icon(Icons.movie_outlined, size: 18),
                      label: const Text('在 TMDB 中查看'),
                    ),
                  ),
                const Divider(height: 32),
                if (loading && lines.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                // `folder` 展开结果：不是单部作品的线路，而是一串**资源条目**
                // （百度/夸克/阿里分享链…），点一条即播。
                //
                // 为什么单独一个分支：网盘聚合站（实测 170 站点里 93 个共用
                // `spring.jar`）的详情只能这样打开——把 `folder` 当普通条目
                // 调 `ids=` 只会拿到空壳（`vod_name`/`vod_play_url` 均空）。
                else if (_isFolderExpansion(result))
                  _buildFolderEntries(context, vod, result!.list)
                else if (lines.isEmpty)
                  const Text('该影片没有可播放的剧集（vod_play_url 为空）。')
                else ...[
                  // 线路选择（`04` §3.1 ④）：点击即切换，剧集卡片随之切换。
                  // 对齐上游 `@id/flag` —— 上游也只渲染**当前线路**的选集区。
                  TmdbLineSelector(
                    lines: lines,
                    selectedFlag: _activeLine(lines).flag,
                    episodeCounts: _episodeCountsByLine(lines),
                    onChanged: (line) => _selectLine(line, lines),
                  ),
                  _buildEpisodes(context, vod, lines),
                ],
                // ⑥⑦⑧⑨ TMDB 附加区块（`04` §3.1）：失败时整块隐藏（不显示空态占位）。
                //
                // folder 展开**也要**渲染：被点的 folder 条目本身就是一部作品
                // （名称/海报/集数备注齐备），只是它没有线路而已（用户反馈
                // 「桥接站点还是没有 tmdb 详情页」）。信息表缺失字段由
                // `TmdbInfoTable` 自行跳过空值行。
                ..._buildTmdbBlocks(context, tmdb),
              ],
            ),
    );
  }

  /// 当前详情结果是否是 `folder` 展开产物（资源列表而非单部作品）。
  ///
  /// 判据：本页点开的条目是 `folder`，且返回的条目**自身不再有可播线路**
  /// （它们是 `file` 类型的分享链，没有 `vod_play_from`/`vod_play_url`）。
  /// 不用“结果条数”判：单部作品的详情也可能返回多条。
  static bool _isFolderExpansion(SiteResult? result) {
    if (result == null || result.list.isEmpty) return false;
    return result.list.every(
      (item) =>
          item.vodTag == 'file' &&
          (item.vodPlayUrl == null || item.vodPlayUrl!.isEmpty),
    );
  }

  /// 渲染 `folder` 展开后的资源条目（点一条即播）。
  Widget _buildFolderEntries(
    BuildContext context,
    Vod vod,
    List<Vod> entries,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '选择资源（${entries.length}）',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        Text(
          '该站点是网盘聚合源：每个条目是一条分享链，点一条即开始播放。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        for (final entry in entries)
          Card(
            key: ValueKey('folder-entry-${entry.vodId}'),
            child: ListTile(
              leading: const Icon(Icons.cloud_download_outlined),
              title: Text(entry.vodName),
              subtitle: entry.vodRemarks == null || entry.vodRemarks!.isEmpty
                  ? null
                  : Text(entry.vodRemarks!),
              trailing: const Icon(Icons.play_arrow),
              onTap: () => _playFolderEntry(vod, entry),
            ),
          ),
      ],
    );
  }

  /// 播放一条 folder 展开出来的资源条目。
  ///
  /// `flag` 取条目标题（实测插件接受任意非空 flag；它靠 `play=` 里的分享链
  /// 自行判定网盘类型）。**不能留空**：空 flag 会被网关拒绝（实测返回
  /// `缺少 flag 或 id 参数`）。
  Future<void> _playFolderEntry(Vod vod, Vod entry) async {
    final state = widget.state;
    try {
      final decision = await state.resolvePlayback(
        episodeTarget: entry.vodId,
        flag: entry.vodName.isEmpty ? '网盘' : entry.vodName,
        vodId: vod.vodId,
      );
      if (decision == null || decision.url == null) {
        throw AppError(
          AppErrorKind.playbackUrlMissing,
          '播放决策没有返回可用地址',
          detail: 'entry=${entry.vodName}',
        );
      }
      if (!mounted) return;
      final resume = state.resumePositionFor(
        siteKey: state.selectedSite?.key ?? '',
        vodId: vod.vodId,
        flag: entry.vodName,
        episodeId: entry.vodId,
      );
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerPage(
            state: state,
            request: PlaybackRequest(
              url: decision.url!,
              // folder 条目的入口目标是分享链本身（`entry.vodId`），不是解析后的
              // 代理/网盘直链；历史续播必须用它回传站点重解析。
              episodeTarget: entry.vodId,
              headers: decision.headers?.asRequestHeaders ?? const {},
              title: vod.vodName,
              siteKey: state.selectedSite?.key ?? '',
              vodId: vod.vodId,
              vodName: vod.vodName,
              episodeName: entry.vodName,
              flag: entry.vodName,
              startPosition: resume,
            ),
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(failure.userMessage)),
      );
    }
  }

  /// 剧照墙 / 演职人员 / 相关推荐 / 相关视频（`04` §3.1 ⑥–⑨）。
  ///
  /// 全部**可点击**（用户反馈：之前点击无效）：
  /// - 剧照 → 大图查看器（可翻页）；
  /// - 演职人员 → 人物页（简介/照片/作品）；
  /// - 相关推荐 → 该作品的 TMDB 详情页；
  /// - 相关视频 → 浏览器打开 / 复制链接。
  List<Widget> _buildTmdbBlocks(BuildContext context, TmdbState tmdb) {
    final data = tmdb.detailData;
    if (data == null) return const [];
    return [
      const Divider(height: 32),
      TmdbDetailSections(
        data: data,
        recommendations: tmdb.recommendations,
        videos: tmdb.videos,
        onPersonTap: _openPerson,
        onRecommendationTap: _openItemDetail,
        onOpenVideo: widget.state.openExternalUrl,
        onCopyVideo: copyToClipboard,
      ),
    ];
  }

  /// 打开人物页（演职人员点击）。
  void _openPerson(TmdbPerson person) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdbPersonPage(
          service: widget.state.tmdbService,
          person: person,
          onOpenItem: _openItemDetail,
        ),
      ),
    );
  }

  /// 打开某个 TMDB 作品详情（相关推荐 / 人物作品点击）。
  void _openItemDetail(TmdbItem item) {
    final identity = item.identity;
    if (identity == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdbDetailPage(
          service: widget.state.tmdbService,
          identity: identity,
          initialItem: item,
          onSearchSource: (title, hint) {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SearchPage(
                  state: widget.state,
                  initialKeyword: title,
                  identityHint: hint,
                ),
              ),
            );
          },
          onOpenVideo: widget.state.openExternalUrl,
          onCopyVideo: copyToClipboard,
        ),
      ),
    );
  }

  /// 当前线路（未选定时取第一条）。
  ///
  /// 必须先于任何渲染使用：线路决定「用哪条线路的集 + 哪个季度解析结果」。
  VodPlayLine _activeLine(List<VodPlayLine> lines) {
    for (final line in lines) {
      if (line.flag == _selectedLineFlag) return line;
    }
    return lines.first;
  }

  /// 切换线路（`04` §4.3：切换线路必须重新解析该线路的可播放季度）。
  ///
  /// 必须把**当前季度作为意图**传给状态层：新线路可能没有当前季度的集
  /// （例如「线路一 S1+S2」切到「只有 S2 的线路二」），不给意图就会回落到
  /// 默认季（S1），线路二在 S1 下一集都没有 → 剧集区空白。
  void _selectLine(VodPlayLine line, List<VodPlayLine> lines) {
    if (line.flag == _activeLine(lines).flag) return;
    final tmdb = widget.state.tmdb;
    final preferred = tmdb.selectedSeason;
    setState(() => _selectedLineFlag = line.flag);
    tmdb.selectLine(line.flag, preferredSeason: preferred);
    unawaited(widget.state.reloadTmdb());
  }

  /// 每条线路在当前季度下**渲染**的集数（供线路条展示）。
  ///
  /// 只有当前线路能拿到 TMDB 季度解析结果（季度是线路级的，`02` §2.2），
  /// 因此其余线路只做**来源季度信号**过滤，不套用当前线路的季度。
  Map<String, int> _episodeCountsByLine(List<VodPlayLine> lines) {
    final active = _activeLine(lines);
    final result = <String, int>{};
    for (final line in lines) {
      final isActive = line.flag == active.flag;
      if (isActive) {
        result[line.flag] = _renderEpisodes(line, active: true).length;
        continue;
      }
      result[line.flag] = _renderEpisodes(line, active: false).length;
    }
    return result;
  }

  /// 某条线路在「当前季度」下要渲染的集（`04` §4.2）。
  ///
  /// - 当前线路：先应用 TMDB 剧集元数据，再按可播放季度过滤；
  /// - 其他线路：不套用当前季度的元数据与过滤（避免跨线路串集），
  ///   只保留来源集名自带的季度信号过滤。
  List<VodEpisode> _renderEpisodes(VodPlayLine rawLine, {required bool active}) {
    final tmdb = widget.state.tmdb;
    if (!active) {
      final selected = tmdb.selectedSeason;
      if (selected < 0) return rawLine.episodes;
      return TmdbEpisodeRenderPolicy.filter(
        episodes: rawLine.episodes,
        availableSeasons: const [],
        selectedSeason: selected,
        seasonOf: _seasonOfEpisode,
      );
    }
    final line = tmdb.applyEpisodesToLine(rawLine).line;
    return TmdbEpisodeRenderPolicy.filter(
      episodes: line.episodes,
      availableSeasons: tmdb.availableSeasons,
      selectedSeason: tmdb.selectedSeason,
      seasonOf: _seasonOfEpisode,
    );
  }

  /// 渲染当前线路的剧集区（区块头 + 剧集卡片）。
  Widget _buildEpisodes(
    BuildContext context,
    Vod vod,
    List<VodPlayLine> lines,
  ) {
    final state = widget.state;
    final tmdb = state.tmdb;
    final rawLine = _activeLine(lines);
    final line = tmdb.applyEpisodesToLine(rawLine).line;
    final episodes = _renderEpisodes(rawLine, active: true);
    final ordered = _episodesReversed
        ? episodes.reversed.toList()
        : episodes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TmdbEpisodeHeader(
          episodeCount: episodes.length,
          reversed: _episodesReversed,
          gridMode: _episodeGridMode,
          lineName: rawLine.displayName,
          onToggleReversed: () =>
              setState(() => _episodesReversed = !_episodesReversed),
          onToggleGridMode: () =>
              setState(() => _episodeGridMode = !_episodeGridMode),
        ),
        // 剧集海报卡片：本线路**唯一**的选集入口（用户反馈 2026-10-08：
        // 有卡片时不再渲染文字版集按钮，二者取其一）。
        // 卡片数量恒等于本线路渲染的集数；未匹配 TMDB 时用来源剧照/海报兑底，
        // 保证「每集都有画面」。
        TmdbEpisodeStrip(
          key: ValueKey('tmdb-episode-strip-${rawLine.flag}'),
          cards: tmdb.episodeCardsForEpisodes(
            ordered,
            seasonNumber: tmdb.selectedSeason >= 0 ? tmdb.selectedSeason : null,
            includeMetadata: true,
          ),
          keyPrefix: 'tmdb-episode-card-${rawLine.flag}',
          actionLabel: '播放',
          cardWidth: _episodeCardWidth(context, episodes.length),
          gridMode: _episodeGridMode,
          onTap: (index, _) => _playEpisodeAt(
            vod,
            rawLine,
            line,
            ordered,
            index,
          ),
        ),
      ],
    );
  }

  /// 按**渲染下标**播放（卡片下标 → 线路原始下标）。
  void _playEpisodeAt(
    Vod vod,
    VodPlayLine rawLine,
    VodPlayLine line,
    List<VodEpisode> episodes,
    int index,
  ) {
    if (index < 0 || index >= episodes.length) return;
    final episode = episodes[index];
    // 播放必须用**线路原始下标**（TMDB 只丰富展示，不改变播放事实源）。
    final rawIndex = line.episodes.indexWhere(
      (candidate) =>
          identical(candidate, episode) || candidate.url == episode.url,
    );
    _play(vod, rawLine, rawIndex < 0 ? index : rawIndex);
  }

  /// 剧集卡片宽度（`04` §4.4 列数策略的卡片版）。
  ///
  /// 集数多的线路把卡做窄，使一行能看到更多集，减少横向滚动；集数少时保持
  /// 大卡以突出剧照。窗口很窄时兜底到最小宽度，不得为负或过小。
  static double _episodeCardWidth(BuildContext context, int episodeCount) {
    final width = MediaQuery.sizeOf(context).width;
    final targetColumns = switch (episodeCount) {
      <= 8 => 5,
      <= 20 => 7,
      _ => 9,
    };
    final available = width - 32 - (targetColumns - 1) * 10;
    final raw = available / targetColumns;
    return raw.clamp(150.0, 300.0);
  }

  /// 剧集所在季度。
  ///
  /// 优先取 TMDB 富集写入的 `tmdb_season_number`；否则回退到**来源集名**里的
  /// 季度信号（`第 N 季` / `SxxExx`）。
  ///
  /// 为什么必须回退：富集只为**当前选中季度**写 `tmdb_season_number`，其余
  /// 季度的集不会被标记。若只看 `extra`，多季线路的季度过滤就会失效
  /// （所有集都被当成「未分类」而保留，选集数永不缩小）。
  /// 来源集名是**事实源**（§27 原则 1），用它分类不引入任何猜测。
  static int _seasonOfEpisode(VodEpisode episode) {
    final raw = episode.extra['tmdb_season_number'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return sourceSeasonNumber(episode.name);
  }

  /// 打开纯 TMDB 详情页（`04` §6）。
  ///
  /// 该页面**没有播放按钮**；剧集卡片点击后跳搜索页并带入标题与身份提示。
  Future<void> _openTmdbDetail(TmdbIdentity identity) async {
    final state = widget.state;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdbDetailPage(
          service: state.tmdbService,
          identity: identity,
          initialItem: state.tmdb.item,
          onSearchSource: (title, hint) {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SearchPage(
                  state: state,
                  initialKeyword: title,
                  identityHint: hint,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 简介：默认 4 行 + 「展开 / 收起」（`04` §11 长文本要求）。
class _ExpandableOverview extends StatefulWidget {
  const _ExpandableOverview({required this.text});

  final String text;

  @override
  State<_ExpandableOverview> createState() => _ExpandableOverviewState();
}

class _ExpandableOverviewState extends State<_ExpandableOverview> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      key: const ValueKey('tmdb-overview'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.text,
          style: theme.textTheme.bodyMedium,
          maxLines: _expanded ? null : 4,
          overflow: _expanded ? null : TextOverflow.ellipsis,
        ),
        if (widget.text.length > 120)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('tmdb-overview-toggle'),
              onPressed: () => setState(() => _expanded = !_expanded),
              child: Text(_expanded ? '收起' : '展开'),
            ),
          ),
      ],
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.inbox_outlined,
            size: 40,
            color: Theme.of(context).disabledColor,
          ),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// 站点运行时未支持时的明确提示（§8.1 “不得显示空列表”）。
class _UnsupportedSiteHint extends StatelessWidget {
  const _UnsupportedSiteHint({required this.site, required this.availability});

  final Site site;
  final SiteAvailability availability;

  @override
  Widget build(BuildContext context) {
    return _EmptyHint(
      title: '站点运行时未安装或不支持',
      message: '站点「${site.name}」需要 ${availability.runtimeName} 运行时'
          '${availability.stage == null ? "" : "（计划阶段：${availability.stage}）"}。\n'
          '${availability.reason ?? ""}\n'
          '请在站点列表中选择其他可运行站点。',
    );
  }
}

class _NoticeBanner extends StatelessWidget {
  const _NoticeBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(Icons.notifications_none, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(message)),
          IconButton(
            tooltip: '关闭提示',
            onPressed: onDismiss,
            icon: const Icon(Icons.close, size: 16),
          ),
        ],
      ),
    );
  }
}

/// 与 `package:collection` 的 `firstOrNull` 等价的本地实现，避免为此新增依赖。
extension _FirstWhereOrNull<T> on Iterable<T> {
  T? firstWhereOrNull() {
    for (final item in this) {
      return item;
    }
    return null;
  }
}
