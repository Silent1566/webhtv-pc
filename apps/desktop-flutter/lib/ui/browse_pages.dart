/// 浏览页：首页/分类 + 详情（§17.2 首页/分类页、详情页）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/app_error.dart';
import '../core/episode_range.dart';
import '../core/history_view.dart';
import '../core/poster_badge.dart';
import '../core/protocol.dart';
import '../core/source_swap.dart';
import '../core/tmdb_detail_model.dart';
import '../core/tmdb_identity.dart';
import '../core/tmdb_media.dart';
import '../core/tmdb_playback.dart';
import '../core/tmdb_title.dart';
import '../services/ai_episode_season_service.dart';
import '../services/spider_router.dart';
import '../services/storage.dart';
import '../services/ui_preferences_store.dart';
import '../state/app_state.dart';
import '../state/playback_source_context.dart';
import '../state/tmdb_state.dart';
import 'ai_settings_page.dart';
import 'app.dart';
import 'config_pages.dart';
import 'player_page.dart';
import 'search_page.dart';
import 'tmdb_detail_page.dart';
import 'tmdb_detail_view.dart';
import 'common.dart';
import 'scroll_behavior.dart';
import 'source_field.dart';
import 'source_swap_sheet.dart';
import 'tmdb_widgets.dart';
import 'toast.dart';
import 'tokens.dart';

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
      return const _EmptyHint(title: '请选择站点', message: '点击顶栏「选择站点」挑选一个可运行的站点。');
    }
    final availability = state.siteItems
        .where((item) => item.site.key == site.key)
        .map((item) => item.availability)
        .firstWhereOrNull();
    if (availability != null && !availability.available) {
      return _UnsupportedSiteHint(site: site, availability: availability);
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

  /// 筛选面板是否展开。
  ///
  /// 状态提在这一层：面板是分类条正下方的**内联区**，展开/收起由分类条上的按钮
  /// 驱动，两者必须共享同一个状态源——放在按钮里也活不过一帧重建，放在面板里
  /// 它自己就没法决定自己该不该在树里。
  bool _filtersOpen = false;

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
    // 当前分类可用的筛选维度。空 = 这个分类没有筛选，入口按钮**不渲染**。
    final filters = _VodGrid.filtersFor(state, selected);
    // 切到没有筛选维度的分类时按钮会消失，面板必须跟着收——否则用户再也收不起它。
    final open = _filtersOpen && filters.isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
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
                // 鼠标左右拖由 `HorizontalMouseDrag` 打开（同样 §17.4）。
                child: HorizontalMouseDrag(
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
              ),
              // 筛选入口：**只有真的有筛选维度时才出现**。
              //
              // 「没有筛选的分组就不应该有筛选按钮」（用户反馈 2026-10-13）——
              // 一个点了什么也没有的按钮比没有按钮更糟。
              if (filters.isNotEmpty)
                _FilterToggleButton(
                  state: state,
                  open: open,
                  onToggle: () => setState(() => _filtersOpen = !_filtersOpen),
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
        ),
        // 面板是**页面内联区**：展开时把下面的海报网格推下去，不遮住它。
        // 收起时子节点换成 `SizedBox.shrink()` —— 面板内容真的离开 widget 树
        // （不是 opacity 0），所以收起态 `find.text('重置筛选')` 必须是空。
        AnimatedSize(
          duration: AppMotion.base,
          curve: AppMotion.ease,
          alignment: Alignment.topCenter,
          child: open
              ? _FilterPanel(state: state, groups: filters)
              : const SizedBox.shrink(),
        ),
      ],
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

/// 分类条上的**筛选开关按钮**：点一下展开、再点一下收起正下方的内联筛选面板。
///
/// 设计取舍（用户反馈 2026-10-13：「筛选区域不再默认展示，加一个按钮点击后
/// 展开」；2026-11 追加：「筛选层显示不好看，横向铺满？」）：
/// - **按需出现**：`groups` 为空时调用点根本不渲染这个按钮——没有筛选的分组
///   不该有一个点了没反应的按钮；
/// - **内联展开而不是悬浮小窗**：面板是分类条下方的页面内联区，宽度吃满内容区、
///   把海报网格往下推。原来 520px 的悬浮弹层排「年份 15 项 + 字母 27 项」这类
///   大维度要 5~6 行，右侧贴边、左侧大片留空，还压在海报墙上，观感零碎；
/// - **必须显示"已生效"**：面板收起之后，用户看不到自己选过什么。所以有生效
///   筛选时按钮**染成星等琥珀 + 数字角标**，一眼知道"现在筛着 2 个维度"；
/// - **「重置筛选」放进面板**：它属于筛选状态，和筛选控件在一起才不会找不到。
class _FilterToggleButton extends StatelessWidget {
  const _FilterToggleButton({
    required this.state,
    required this.open,
    required this.onToggle,
  });

  final AppState state;

  /// 面板当前是否展开。展开态图标翻转并给一层主色淡底，说明"这块归我管"。
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = context.semanticColors;
    final activeCount = state.categoryFilters.length;

    return Padding(
      padding: const EdgeInsets.only(right: AppSpace.xs),
      child: TextButton.icon(
        key: const ValueKey('category-filter-menu'),
        onPressed: onToggle,
        icon: Icon(
          open ? Icons.expand_less : Icons.tune,
          size: 18,
          color: activeCount > 0 ? semantic.magnitude : null,
        ),
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('筛选'),
            if (activeCount > 0) ...[
              const SizedBox(width: AppSpace.xs),
              // 数字角标：面板收起后，这是"筛了几项"的唯一提示。
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 5,
                  vertical: 1,
                ),
                decoration: BoxDecoration(
                  color: semantic.magnitude,
                  borderRadius: AppRadius.pillAll,
                ),
                child: Text(
                  '$activeCount',
                  style: theme.textTheme.labelSmall?.copyWith(
                    // 琥珀底上用夜空墨色：琥珀是亮色，白字对比度不足。
                    color: AppPalette.nightGround,
                    fontWeight: AppWeight.title,
                  ),
                ),
              ),
            ],
          ],
        ),
        style: TextButton.styleFrom(
          backgroundColor: open
              ? theme.colorScheme.primary.withValues(alpha: 0.10)
              : null,
          foregroundColor: activeCount > 0
              ? semantic.magnitude
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 分类条正下方的**内联筛选面板**容器：贴齐内容区左右内边距、横铺满整个宽度。
///
/// 视觉目标是「媒体库的筛选工作台」而不是一个弹窗：
/// - 底色 `surfaceContainerLow`（比页面底色亮/暗一档，两套主题都由 ColorScheme
///   给出），下沿一条发丝线收边，**不投影片阴影**——它是页面的一块区域，不是浮在
///   页面之上的东西；
/// - 维度多时面板自身纵向滚动，最大高度 = `max(窗口高 × 0.45, 340px)`：宽屏下
///   「年份 + 字母」这类大维度排成 1~3 行就够，不需要吃掉半屏；窗口最小尺寸
///   （1024×640，见 `app.dart` 的 `minimumSize`）下这也只占 340px，网格仍有余量；
/// - 上下内边距 `AppSpace.md`、左右 `AppSpace.lg`（= 海报网格的 16px 内边距，
///   面板里的第一枚 chip 与第一列海报左边缘对齐）。
class _FilterPanel extends StatelessWidget {
  const _FilterPanel({required this.state, required this.groups});

  final AppState state;
  final List<VodFilterGroup> groups;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxHeight = math.max(
      MediaQuery.sizeOf(context).height * 0.45,
      340.0,
    );
    final active = state.categoryFilters;
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          // 只有下沿这条线：上沿的分隔线由分类条自己的 bottom border 担任，
          // 两条贴在一起会变成 2px 的粗线。
          bottom: BorderSide(color: theme.dividerColor),
        ),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        // 只有 chip 区滚动，"已生效 + 重置"这一条钉在面板底部：维度多到要滚动时
        // 重置按钮不能跟着滚出视野（那是用户筛不出结果时的唯一退路）。
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.lg,
                  AppSpace.md,
                  AppSpace.lg,
                  AppSpace.md,
                ),
                child: _FilterPanelBody(state: state, groups: groups),
              ),
            ),
            if (active.isNotEmpty) _FilterResetBar(state: state, groups: groups),
          ],
        ),
      ),
    );
  }
}

/// 面板底部那条**只在有生效筛选时出现**的汇总行。
///
/// 左边回答"我现在筛着什么"（面板收起后这个问题只能靠按钮上的数字角标回答），
/// 右边是「重置筛选」。没有生效筛选时整条不渲染——留一条空的分隔线加一个点不动
/// 的按钮，只会让面板底部多出一块没有信息量的死区。
class _FilterResetBar extends StatelessWidget {
  const _FilterResetBar({required this.state, required this.groups});

  final AppState state;
  final List<VodFilterGroup> groups;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.xs,
        AppSpace.md,
        AppSpace.xs,
      ),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _activeFilterSummary(groups, state.categoryFilters),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: AppSpace.md),
          TextButton.icon(
            key: const ValueKey('category-filter-clear'),
            onPressed: state.clearCategoryFilters,
            icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
            label: const Text('重置筛选'),
          ),
        ],
      ),
    );
  }
}

/// 「已生效 2 项：剧情 喜剧 · 地区 中国大陆」。
///
/// 维度名取站点给的 `group.name`、值取选项自己的 `name`（不是 key 里的原值：
/// 「中国大陆」这类显示名和 `cn` 这种值不是一回事）。生效值里若有当前分组列表
/// 里已经找不到的（切站、换分类后残留），直接把它原样带出来，不静默丢掉——
/// 用户看到的必须等于实际正在生效的。
String _activeFilterSummary(
  List<VodFilterGroup> groups,
  Map<String, String> active,
) {
  final parts = <String>[];
  final usedKeys = <String>{};
  for (final group in groups) {
    final value = active[group.key] ?? '';
    if (value.isEmpty) continue;
    usedKeys.add(group.key);
    var label = value;
    for (final option in group.options) {
      if (option.value == value) {
        label = option.name;
        break;
      }
    }
    parts.add('${group.name} $label');
  }
  for (final entry in active.entries) {
    if (entry.value.isEmpty || usedKeys.contains(entry.key)) continue;
    parts.add('${entry.key} ${entry.value}');
  }
  if (parts.isEmpty) return '';
  return '已生效 ${parts.length} 项：${parts.join(' · ')}';
}

/// 内联筛选面板的内容：每个维度一行「等宽标签 + 横向 chip」，维度再按可用宽
/// 排成 1~3 列。
///
/// 底部的「已生效 + 重置」不在这里，而在 `_FilterResetBar`：它必须钉在面板
/// 底部不随 chip 区滚动，所以由 `_FilterPanel` 的 Column 分层拼。
///
/// 布局对齐主流桌面媒体库：行首是该维度的标签列（**列内**各行等宽，所以同一个
/// 列里的 chip 左边缘对齐），右侧 chip 自适应换行。选中态是主色淡底 + 主色文字，
/// 未选中是弱化纯文字。
///
/// 为什么不是单列竖排：面板是通栏的（从 NavigationRail 右侧一直铺到窗口右缘），
/// 单列时三个维度只占左边约 1/3，右边是一大片同色空底，整条读起来像空条幅。
/// 多列是让「横向铺满」落到内容上而不是只落到容器上。
///
/// 为什么不用「每条一行 + 勾选框」：勾选框 + 实底高亮是设置表单的视觉语言，
/// 不像媒体库的筛选条；横向 chip 换行后「剧情」这类 17 项的维度只占 3 行。
class _FilterPanelBody extends StatelessWidget {
  const _FilterPanelBody({required this.state, required this.groups});

  final AppState state;
  final List<VodFilterGroup> groups;

  /// 标签列宽度的上下限：短名（「地区」）不留大片空白，长名（「资源类型」）
  /// 也不能无限挤压 chip 区。
  static const double _minLabelWidth = 40;
  static const double _maxLabelWidth = 88;

  /// 一列可用宽的下限。
  ///
  /// 420 ≈ 标签列上限 88 + 约 330 的 chip 区：这刚好能让「中国大陆」这类 4 字
  /// chip 并排 3 枚。再窄下去 chip 会碎成一列一枚，多列反而比单列更长，所以
  /// 面板每收窄一档 420，列数就少一列。
  static const double _columnMinWidth = 420;

  @override
  Widget build(BuildContext context) {
    // 筛选 chip **始终可点**。
    //
    // 原来这里在 `contentPhase == loading` 时把整条筛选栏禁用，理由写的是
    // 「连点会把多个响应乱序写回状态」。但那个理由**不成立**：状态层已经用
    // `_categoryRunId` 作废在途响应（`app_state.dart:1442`、`:1459`），
    // 乱序写回早就被挡住了。代价却很实在——站点慢的时候（桥接站、网盘站，
    // 实测 0.3~2s）整条筛选栏在请求期间完全点不动，用户看到的就是
    // 「筛选按钮点击没反应，不会筛选」（用户反馈 2026-10-11）。
    //
    // 即时生效的控件不应该在每次生效的过程中把自己关掉。
    const enabled = true;
    final active = state.categoryFilters;
    if (groups.isEmpty) return const SizedBox.shrink();
    // 列数由**面板实际可用宽**决定，而不是窗口宽：面板两侧各有 `AppSpace.lg`
    // 内边距、外面还挡着 NavigationRail。按窗口宽算会在小窗口下多切出一列。
    return LayoutBuilder(
      builder: (context, constraints) {
        final columnCount = math
            .min((constraints.maxWidth / _columnMinWidth).floor(), 3)
            .clamp(1, groups.length);
        final columns = _splitBalanced(groups, columnCount);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var index = 0; index < columns.length; index++) ...[
              if (index > 0) const SizedBox(width: AppSpace.xxl),
              Expanded(
                child: _buildColumn(context, columns[index], active, enabled),
              ),
            ],
          ],
        );
      },
    );
  }

  /// 一列竖向排列若干维度，列内组与组之间补 `AppSpace.sm`。
  Widget _buildColumn(
    BuildContext context,
    List<VodFilterGroup> columnGroups,
    Map<String, String> active,
    bool enabled,
  ) {
    // 标签宽度**按列各算各的**：三列共享一个宽度时，最长那个维度名会替另外两列
    // 撑出一片没有内容的空白，横向铺满就白铺了。列内对齐已经足够读。
    final labelWidth = _measureLabelWidth(context, columnGroups);
    final rows = <Widget>[];
    for (final group in columnGroups) {
      if (rows.isNotEmpty) rows.add(const SizedBox(height: AppSpace.sm));
      rows.add(
        _FilterRow(
          group: group,
          labelWidth: labelWidth,
          selectedValue: active[group.key] ?? '',
          enabled: enabled,
          onSelect: (value) => state.setCategoryFilter(group.key, value),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
  }

  /// 把维度按**连续均衡**切成 [columnCount] 段：段长差 ≤ 1，且保持原顺序。
  ///
  /// 连续切而不是 round-robin：维度顺序（剧情 → 地区 → 时间）本身是用户可读的
  /// 语义，轮转会把它打散成「第 1、4 组在前，第 2、5 组在后」。
  List<List<VodFilterGroup>> _splitBalanced(
    List<VodFilterGroup> source,
    int columnCount,
  ) {
    final base = source.length ~/ columnCount;
    final extra = source.length % columnCount;
    final columns = <List<VodFilterGroup>>[];
    var start = 0;
    for (var index = 0; index < columnCount; index++) {
      final take = base + (index < extra ? 1 : 0);
      columns.add(source.sublist(start, start + take));
      start += take;
    }
    return columns;
  }

  /// 标签列宽度 = 所有维度名里最宽者 + 间距，夹在 [min, max] 之间。
  ///
  /// 用固定宽度会让「资源类型」被截断或「地区」后留一片空白；各行宽度不一致又会让
  /// chip 左边缘参差。按实际文本量一次即可两全。
  double _measureLabelWidth(
    BuildContext context,
    List<VodFilterGroup> columnGroups,
  ) {
    final style = _filterLabelStyle(context);
    final direction = Directionality.of(context);
    var widest = 0.0;
    for (final group in columnGroups) {
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
    //
    // 先按 `value` 去重：chip 的 key 是 `category-filter-<维度>-<值>`，
    // 一旦站点数据里出现两个同值选项（实测有站点给出两个空值选项），key 就重复，
    // Flutter 抛 `Duplicate keys found` —— **在真机上那是一屏红**。
    // 同值选项在语义上本来就是同一个筛选项，去重不丢信息，也保住了 key 的格式
    // （外部没有依赖 key 的测试，但没必要改）。
    final options = <VodFilterOption>[];
    final seenValues = <String>{};
    for (final option in group.options) {
      if (seenValues.add(option.value)) options.add(option);
    }
    final hasAll = options.any((option) => option.value.isEmpty);
    // 竖向节奏：行内 chip 之间 4px（`_FilterChip` 各 2px），维度之间 8px。
    // 维度间比维度内宽一档，读者才看得出「这一行是一个维度」而不是 chip 的
    // 连续换行。
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
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
                for (final option in options)
                  _FilterChip(
                    key: ValueKey(
                      'category-filter-${group.key}-${option.value}',
                    ),
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      child: TagChip(
        label: label,
        selected: selected,
        onTap: onTap,
        // 这是可选控件：禁用时也必须保留选中态（见 `TagChip.selectable`）。
        selectable: true,
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
    final loading = state.contentPhase == LoadPhase.loading;
    // 分页页脚只在分类上下文里出现：首页结果没有分页语义。
    final paged = state.selectedTypeId != null && vods.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 错误与通知不再在页面内拼横幅：它们由 `app.dart` 的全局投影推成右下角
        // 通知（见 `ui/toast.dart`），页面只负责海报网格本身。
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) =>
                NotificationListener<ScrollNotification>(
                  onNotification: _onScroll,
                  child: CustomScrollView(
                    slivers: [
                      // 筛选条**不再常驻**。
                      //
                      // 它原来占内容区顶部 150~200px（多维度时更多），把海报挤下去，
                      // 而多数时候用户并不筛选（用户反馈 2026-10-13：「筛选区域不再
                      // 默认展示」）。现在它归分类条上的「筛选」按钮，点击后**悬浮**
                      // 显示——不占布局、不推挤网格。
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
    if (loading) return const LoadingBlock();
    if (hasClasses) {
      return const _EmptyHint(
        title: '请选择一个分类',
        message:
            '该站点首页只返回分类列表（未提供推荐内容）。'
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
  /// 当前分类可用的筛选维度（分类结果优先，其次首页）。
  ///
  /// 公开而不是私有：分类条上的筛选入口按钮也要用它来决定**是否渲染**
  /// （没有维度就不该有按钮）。
  static List<VodFilterGroup> filtersFor(AppState state, String? typeId) {
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
    // 此时只要只有一组就直接用它。
    if (filters.length == 1) return filters.values.first;
    // 多组且没有一组对应当前 type_id：合并全部，但**按维度 key 去重**
    // （去重的原因与取舍见 `mergeFilterGroups` 的文档）。
    return mergeFilterGroups(filters.values);
  }

  Future<void> _openDetail(BuildContext context, Vod vod) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailPage(state: state, vod: vod),
      ),
    );
  }
}

/// 海报卡片：海报（2:3 圆角，带年份/评分角标）+ 居中标题 + 备注。
///
/// 标题居中、只用一档弱化色——参照实现的卡片就是「图 + 居中一行字」，不加边框
/// 与卡片底色，密集排列时比带底色的卡片干净得多。
///
/// 角标（用户提供参考截图 2026-10-09）：左上角**年份**、右下角**评分**。
/// 取值与判定在 `core/poster_badge.dart`（纯逻辑，含「remarks 不一定是评分」的
/// 关键约束：网盘站给的是 `全29集`，那种情况不能当评分画角标）。
class _VodCard extends StatelessWidget {
  const _VodCard({super.key, required this.vod, required this.onTap});

  final Vod vod;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final year = PosterBadge.yearOf(vod);
    final score = PosterBadge.scoreOf(vod);
    final remark = PosterBadge.textRemarkOf(vod);
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
              child: Stack(
                fit: StackFit.expand,
                children: [
                  PosterImage(url: vod.vodPic),
                  if (year != null)
                    Positioned(
                      left: 6,
                      top: 6,
                      child: _PosterBadge(
                        text: year,
                        key: const ValueKey('poster-badge-year'),
                      ),
                    ),
                  if (score != null)
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: _PosterBadge(
                        text: score,
                        highlight: true,
                        key: const ValueKey('poster-badge-score'),
                      ),
                    ),
                ],
              ),
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
                  if (remark != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      remark,
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

/// 海报角标（年份 / 评分）。
///
/// 用半透明黑底 + 白字而不是主题色：海报画面本身色彩不可控（实测有高饱和海报），
/// 半透明黑底在任何海报上都能保证白字可读，且不与主色冲突。
class _PosterBadge extends StatelessWidget {
  const _PosterBadge({super.key, required this.text, this.highlight = false});

  final String text;

  /// 评分角标用暖色强调（年份是中性信息）。
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
            child: LoadingBlock(center: false),
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
  const DetailPage({
    super.key,
    required this.state,
    required this.vod,
    this.historyFlag = '',
    this.historyEpisodeId = '',
    this.resumeSeed,
    this.sourceContext,
    this.sourceSiteKey = '',
  });

  final AppState state;
  final Vod vod;

  /// 用**哪一份配置**看这一页（`null` = 生效配置，既有行为）。
  ///
  /// 只有「历史记录来自其它配置」时才非空：那种记录必须用原配置的站点与请求头
  /// 加载详情、播放，而**不能**为此切换生效配置（用户决定：不切配置，也不改
  /// 顶栏选中的站点）。取值见 `AppState.playbackContextFor`。
  final PlaybackSourceContext? sourceContext;

  /// 原来源配置里这条记录所属站点的 key（[sourceContext] 非空时才有意义）。
  final String sourceSiteKey;

  /// 历史命中的线路 flag（空串 = 未传入）。
  ///
  /// 由历史页传入**用户点的那一条**记录，优先于页面自己查到的"最近一条"：
  /// 同一部剧有多条历史时，点旧记录却续新记录是错的
  /// （`docs/phase6/design/02` §7.1）。
  final String historyFlag;

  /// 历史命中的集入口目标（空串 = 未传入）。
  final String historyEpisodeId;

  /// 跨源续播种子：原记录的线路/集/进度（null = 本次不是"从别的源续播"）。
  ///
  /// 跨源时 [AppState.resumePositionFor] 必然落空——它按**当前站点**的
  /// `siteKey + flag + episodeId` 查本机历史，而用户点的那条记录属于另一个源。
  /// 所以必须把原记录自带的 `positionMs/durationMs` 一路带进来，由
  /// [resolveResumeStart] 判定"是不是同一集"后再换算成起点。
  final ResumeSeed? resumeSeed;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  /// 本页加载详情/播放用的**站点**。
  ///
  /// 原来源记录要落在它自己那份配置的站点上；普通记录仍是当前选中站点
  /// （既有行为）。这里**不**调用 `selectSite`，顶栏与生效配置不受影响。
  Site? get _pageSite =>
      widget.sourceContext?.siteByKey(widget.sourceSiteKey) ??
      widget.state.selectedSite;

  /// 本页查询/写入历史用的来源 key（`null` = 沿用当前历史范围）。
  String? get _pageSourceKey {
    final context = widget.sourceContext;
    if (context == null) return null;
    return context.sourceKey;
  }

  /// 当前选中线路的 `flag`（`04` §3.1 ④）。
  ///
  /// 点击线路条即切换，下方剧集卡片随之变成该线路的集（对齐上游 `@id/flag`）。
  /// 空串表示「尚未选定」，此时默认取第一条线路。
  String _selectedLineFlag = '';

  /// 剧集卡片是否倒序（对齐上游 `@id/episodeReverse`）。
  bool _episodesReversed = false;

  /// 剧集是否网格模式（对齐上游 `@id/episodeViewMode`）。
  ///
  /// 初值取用户偏好（`UiEpisodeViewMode`，默认网格）：这是「上次怎么看的，
  /// 这次还怎么看」的记忆，不再是每次进详情页都重置的临时状态。
  /// 用 `late` 初始化器是为了能读 `widget`——它在 `initState` 之后才求值。
  late bool _episodeGridMode =
      widget.state.episodeViewMode == UiEpisodeViewMode.grid;

  /// 选集区间下标（`docs/phase6/design/03` §4.4）。
  ///
  /// 页面级临时状态（与 `_episodesReversed` / `_episodeGridMode` 同级），
  /// **不进 `AppState`**：它是纯展示状态，跨页面保留没有意义。
  int _rangeIndex = 0;

  /// 用户是否**手动**点过区间 chip。
  ///
  /// 手动选过之后切集不再重置区间（对齐上游 `manualEpisodeRange`）：
  /// 用户的显式意图优先于自动跟随。
  bool _manualRange = false;

  /// 上一次渲染时的季度序号，用于检测切季（`design/03` §5.1）。
  int _lastSeasonEpoch = -1;

  /// 已触发过「按季聚合」的「作品 + 代际」键（导航源全集摊平用）。
  ///
  /// 记键而不是记 bool：换作品/重新加载会推进 `TmdbState.generation`，那时必须
  /// 再拉一次；同一代际内重复触发只是白打一串季节请求。
  String _aggregateRequestKey = '';

  /// 换源并入的**外部线路**（页面级临时状态）。
  ///
  /// 三条集合按 `flag` 对齐，缺一不可：
  /// - [_externalLines] 是渲染用的线路（`flag = 站点名 · 原线路名`）；
  /// - [_externalRoutes] 记住它真正来自哪个站点/哪个 vod，播放时定向解析；
  /// - [_externalStatus] 记住该站点的健康态，行尾色点用来源色。
  ///
  /// 全部**不写盘**：换源是「这一次看这部片」的临时选择，写盘会让下一次进别的
  /// 剧也带着上一部剧的外部线路（串线路）。
  final List<VodPlayLine> _externalLines = [];
  final Map<String, SwapLineRoute> _externalRoutes = {};
  final Map<String, SourceStatus> _externalStatus = {};

  /// 「换源后自动续播」的待续播集号；-1 表示当前没有这个意图。
  ///
  /// 用户在一集**播不出来**时才需要它：换源并入后应当接着播刚才那一集，而不是
  /// 回到第 1 集。这是一次性的意图，用过即复位（见 [_openSourceSwap]）。
  ///
  /// 注意它只是**原线路里的数组下标**（= 下面的 ordinal 减一），绝不能再拿去当
  /// 新线路的下标：不同站点的剧集数组**不同构**（可能含预告/花絮、可能季集
  /// 混排），下标相同不等于同一集。定位同一集靠下面两个「集号锚点」，
  /// 见 [_locateResumeEpisode]。
  int _pendingResumeEpisode = -1;

  /// 被点那一集在**它自己那条线路**里的 1-based 序号（episodeIndex + 1）。
  ///
  /// 新线路没有 tmdb 集号时按集名里的数字回落到它（第06集 / EP06 / S01E06）。
  int _pendingResumeOrdinal = -1;

  /// 被点那一集的 extra['tmdb_episode_number']；取不到为 -1。
  ///
  /// 这是首选锚点：集号是**语义**身份，不随外部线路的数组形态（预告/花絮/季集
  /// 混排）漂移。
  int _pendingResumeEpisodeNumber = -1;

  /// 自动续播那一次 [_play] 期间为 true：此时失败不再弹换源确认框。
  ///
  /// 否则「续播也失败」会再问一次换源，确认后又续播，形成自我递归的对话框。
  bool _resumingAfterSwap = false;

  /// 上一次已经推成通知的详情错误。
  ///
  /// 与 `app.dart` 的 `_shownLastError` 同一做法：拿上一次投影过的值做比较，只在
  /// 值**变成另一个错误**时推一条，因此同一个错误不会重复弹。比较用 [identical]，
  /// 所以「清掉后再来一个新错误」会重新推——按「非空与否」比较就做不到这一点。
  AppError? _shownDetailError;

  /// 当前由详情错误推出去的那条通知的 id（没有则为 null）。
  int? _detailErrorToastId;

  /// 页面内已占用的线路 `flag`（原线路 + 已并入的外部线路）。
  Set<String> get _takenFlags => {for (final line in _externalLines) line.flag};

  /// 本页**全部**线路：来源线路在前，外部并入线路恒在其后。
  ///
  /// 合并顺序是定案：外部线路是「补充」，排在后面才不会让原本习惯的线路
  /// 位置发生跳动；所有需要「全部线路」的地方都必须走这里，否则会出现
  /// 「线路条有 4 条、hero 播的还是第 1 条」这类分裂。
  List<VodPlayLine> _linesOf(Vod vod) => [
    ...widget.state.playLinesOf(vod),
    ..._externalLines,
  ];

  /// 本页**真正可渲染、可播放**的线路。
  ///
  /// 导航源（`indexs == 1`）的站源线路只是索引条目（例如「片单（4 集）」），
  /// 站源在那一侧没有播放入口。用户反馈 2026-10-22：换源后线路条把这条
  /// 不可播放的线路也一并列了出来，点它只会得到「这一集没有可播放的地址」。
  /// 既然导航源的站源集数信息本来就一律丢弃，它也不该出现在线路条上——
  /// 因此导航源只认换源并入的外部线路。
  ///
  /// 普通站点仍是「原线路 + 外部线路」，与 [_linesOf] 完全一致。
  List<VodPlayLine> _playableLines(Vod vod) =>
      _pageSite?.indexs == 1 ? [..._externalLines] : _linesOf(vod);

  /// **渲染归属门**：保留的 TMDB 数据是否属于本页影片。
  ///
  /// 为什么需要：`AppState.clearDetail()` 不再清 TMDB（否则第二次进同一部剧必然先
  /// 渲染一帧站源「原始模式」，再等 TMDB 重新请求回来才换成 TMDB 版本——用户反馈的
  /// 就是这句），于是内存里可能还留着**上一部剧**的作品维度数据。渲染侧必须先确认
  /// 归属，不属于本页的一律按「无 TMDB」降级，否则上一部剧的海报/标题/演职人员/
  /// 季集数字会串到本页（这正是当初 `clear()` 要解决的问题，不能为了秒开换回来）。
  ///
  /// `vodId` 为空（还没绑定过任何作品）时按「属于本页」处理：没有别人的数据可泄漏，
  /// 而状态条/设置入口需要照常显示。
  bool get _tmdbOwnsThisPage {
    final tmdb = widget.state.tmdb;
    return tmdb.vodId.isEmpty || tmdb.belongsTo(widget.vod.vodId);
  }

  /// 属于本页影片的 TMDB 状态；`null` 表示按「无 TMDB」渲染。
  TmdbState? get _ownedTmdb => _tmdbOwnsThisPage ? widget.state.tmdb : null;

  /// 是否走「导航源」的极简选集路径：本页站点是导航源（`indexs == 1`），
  /// 且用户**还没有换源**。
  ///
  /// 换源并入外部线路后判据自然失效（[_externalLines] 非空），页面回到既有的
  /// 「线路条 + 该线路的集」——那时才有真实线路与真实集可播（用户决策 5）。
  /// 导航源本身没有播放线路（用户原话：「实际也没有播放线路」）。
  bool get _navSourceMode => _pageSite?.indexs == 1 && _externalLines.isEmpty;

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
      // 详情错误的投影也排在首帧之后：`showToast` 会 `notifyListeners`，在
      // `initState` 里直接推等于把已挂载的全局 `ToastHost` 在构建期标脏
      // （与 `app.dart` 首次投影同样的理由）。
      _syncDetailErrorToast();
      widget.state.loadDetail(
        widget.vod,
        // 原来源记录用那份配置自己的站点与服务（不切生效配置）。
        siteOverride: _pageSite,
        serviceOverride: widget.sourceContext?.service,
      );
    });
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChanged);
    widget.state.tmdb.removeListener(_onStateChanged);
    // 详情错误通知的动作指向本页的 `_openSourceSwap`，页面销毁后那条通知必须一起
    // 收走：否则用户返回列表后点「换源」，回调会拿一个已失效的 context 去开浮层。
    // 放到首帧之后而不是就地调用，理由同上——构建期不能标脏 `ToastHost`。
    final toastId = _detailErrorToastId;
    _detailErrorToastId = null;
    if (toastId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => dismissToast(toastId));
    }
    super.dispose();
  }

  void _onStateChanged() {
    if (!mounted) return;
    _syncDetailErrorToast();
    setState(() {});
  }

  /// 把 [AppState.detailError] 投影成一条带「换源」动作的右下角通知。
  ///
  /// 为什么在这里而不是 `app.dart`：这条错误的动作是 `_openSourceSwap`——本页的
  /// 私有方法，全局投影够不着它。此前把横幅换成全局通知时，那个按钮就此丢失，
  /// 而文案里还写着「换源」，等于一句空话。**谁拥有动作，谁就拥有这条通知。**
  ///
  /// 按 [identical] 比较上一次投影过的错误：同一个错误只会推一条；清掉之后再出现
  /// 一个新错误（新的 `AppError` 实例）会重新推。
  void _syncDetailErrorToast() {
    final error = widget.state.detailError;
    if (identical(error, _shownDetailError)) return;
    _shownDetailError = error;
    if (error == null) {
      // 状态被别处清掉（刷新详情、离开页面）：那条通知不该留在屏幕上。已经不在
      // 栈里的 id 是空操作，所以重复走这里也不会出错。
      final staleId = _detailErrorToastId;
      _detailErrorToastId = null;
      if (staleId != null) dismissToast(staleId);
      return;
    }
    _detailErrorToastId = showToast(
      error.userMessage,
      kind: ToastKind.error,
      detail: '错误码：${error.kind.name}${error.retryable ? " · 可重试" : ""}',
      action: AppToastAction(
        // 测试契约（5 个文件按这个 key 定位「换源」入口），随按钮一起搬进通知。
        key: const ValueKey('detail-swap-source'),
        label: '换源',
        icon: Icons.swap_horiz,
        onPressed: _openSourceSwap,
      ),
      onDismiss: _onDetailErrorToastDismissed,
    );
  }

  /// 详情错误通知被收走（计时器/×）时清状态。
  ///
  /// [mounted] 这层门是必需的：通知挂在**全局**宿主上，页面先于它消失时
  /// （见 [dispose] 里的收尾）状态层可能已经被销毁，此时再清就是
  /// 「A AppState was used after being disposed」。
  void _onDetailErrorToastDismissed() {
    if (!mounted) return;
    widget.state.clearDetailError();
  }

  void _closeDetail() {
    // 离开详情页时清掉全局详情状态（§8.3）：结果与所选影片是页面级临时状态，
    // 不清理会让下一次进入详情页先渲染上一部剧的线路（实测串剧）。
    // 外部线路同样在这里失效（不写盘、不跨页残留）：它属于「这一次换源」，
    // 而不是这部片的新身份。
    _externalLines.clear();
    _externalRoutes.clear();
    _externalStatus.clear();
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
        initialQuery: _ownedTmdb?.item?.title ?? vod?.vodName ?? '',
        search: state.searchTmdb,
        resolveProviderId: state.resolveTmdbProviderId,
      ),
    );
    if (item == null || !mounted) return;
    await state.matchTmdbManual(item: item, sourceTitle: vod?.vodName);
  }

  Future<void> _openSeasonDialog() async {
    final state = widget.state;
    // 归属门：不属于本页影片的 TMDB 数据不能拿来手动绑定季度（会把上一部剧的
    // 季集数绑到本页线路上）。
    final tmdb = _ownedTmdb;
    final counts = tmdb?.seasonEpisodeCounts ?? const <int, int>{};
    final seasons = counts.keys.toList()..sort();
    if (seasons.isEmpty) {
      showToast('TMDB 未返回季度信息，暂时无法手动绑定季度', kind: ToastKind.error);
      return;
    }
    final line = tmdb?.sourceLine;
    // 【必须用**无类型**路由 + `decodeSeasonChoice`，不能 `showDialog<TmdbSeasonChoice>`】
    //
    // 弹窗 pop 的是 `_SeasonChoice`（私有枚举）或 `int`（季号），两者都不是
    // `TmdbSeasonChoice`。若把路由声明成 `showDialog<TmdbSeasonChoice>`，
    // `Navigator.pop` 会因「结果类型与路由期望类型不符」抛异常，
    // 对话框结果恒为 `null`——用户点“第 2 季”看起来就是“点了没反应”
    // （Phase 4 起就存在的缺陷，2026-10-16 由 L3 `phase6_ai_season_flow_test`
    // 驱动真实弹窗时揪出）。
    //
    // `decodeSeasonChoice` 本来就是为这一步写的转换函数，此前**从未被接线**。
    final raw = await showDialog<Object?>(
      context: context,
      builder: (_) => TmdbSeasonDialog(
        tmdbSeasons: seasons,
        seasonCounts: counts,
        sourceEpisodeCount: line?.episodeCount ?? 0,
        currentSeason: tmdb != null && tmdb.selectedSeason >= 0
            ? tmdb.selectedSeason
            : null,
        canAutoSlice: tmdb?.canAutoSlice ?? false,
        aiReady: state.aiReady,
      ),
    );
    if (raw == null || !mounted) return;
    final choice = decodeSeasonChoice(raw);
    if (choice == null || !mounted) return;

    // **分流必须在 bindTmdbSeason 之前**（`docs/phase6/design/04` §7.1.1）：
    // `bindingModeOf` 对 AI 两项返回 null，与 `TmdbSeasonAuto` 同值，而 null 的
    // 含义是「清除手动绑定」。直接喂给 bindTmdbSeason 会让用户点「AI 识别」
    // 或「去配置 AI」时把已有绑定静默清掉。
    if (choice is TmdbSeasonAiSettings) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => AiSettingsPage(state: state)),
      );
      return;
    }
    if (choice is TmdbSeasonAi) {
      await _runAiSeasonAnalysis();
      return;
    }

    await state.bindTmdbSeason(choice);
    if (!mounted) return;
    await state.reloadTmdb();
  }

  /// 跑一次 AI 集季分析并走预览确认（`docs/phase6/design/04` §7.2–§7.5）。
  Future<void> _runAiSeasonAnalysis() async {
    final state = widget.state;
    // 归属门：不属于本页影片的季集数不能参与 AI 切分（会按上一部剧的季集数切本页）。
    final tmdb = _ownedTmdb;
    final vod = _currentVod;
    final tmdbLine = tmdb?.sourceLine;
    if (vod == null || tmdbLine == null || tmdbLine.episodeCount == 0) {
      showToast('当前线路没有可分析的剧集', kind: ToastKind.error);
      return;
    }

    // 用 tmdb 线路自己的集名重建集列表，而**不是**取 UI 的 `_activeLine`：
    // 这样 `episodes.length` 与快照里的 `episodeCount` 必然同源（§7.5 的
    // 前后比对才有意义），也不会因 UI 线路选中态与 tmdb 态短暂不一致而错位。
    final episodes = [
      for (var i = 0; i < tmdbLine.episodeNames.length; i++)
        VodEpisode(
          name: tmdbLine.episodeNames[i],
          url: i < tmdbLine.episodeUrls.length ? tmdbLine.episodeUrls[i] : '',
        ),
    ];

    // 快照（`04` §7.5）：分析可能耗时几十秒，期间用户可能切了线路或换了站点，
    // 应用前必须比对，否则会把结果写到新线路上。
    final snapshotFlagKey = tmdbLine.flagKey;
    final snapshotCount = tmdbLine.episodeCount;

    final service = AiEpisodeSeasonService(config: state.aiConfig);
    var canceled = false;
    // 提前拿住 navigator：要等 `await` 之后才能关进度框，届时 `context` 可能已失效
    // （也因此不能用 `Navigator.of(context, ...)` 去做那件事）。
    final navigator = Navigator.of(context, rootNavigator: true);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          key: const ValueKey('ai-season-progress'),
          title: const Text('AI 正在分析剧集结构…'),
          content: const Text('分析期间不会改动任何绑定。'),
          actions: [
            TextButton(
              key: const ValueKey('ai-season-cancel'),
              onPressed: () {
                canceled = true;
                service.cancel();
                Navigator.of(dialogContext).pop();
              },
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    );

    final result = await service.analyze(
      title: vod.vodName,
      flagName: tmdbLine.sourceFlag,
      episodes: episodes,
      seasonCounts: tmdb?.seasonEpisodeCounts ?? const <int, int>{},
    );
    service.dispose();

    // 只在取消路径下**跳过**关闭进度框。
    //
    // 【两处都不能照抄计划的写法】
    //
    // 1. 顺序：计划写的是「先 `maybePop()` 再判 `canceled`」。用户点取消时进度框
    //    已由取消按钮自己 pop 掉了，此时 `maybePop()` 弹掉的是**详情页本身**
    //    （用户点「取消」却被退出详情页）。
    //
    // 2. `pop()` 而不是 `maybePop()`：`maybePop()` 会调 `Route.willPop()`，
    //    而 `ModalRoute.willPop()` 断言本路由的 `_ModalScopeState` 已构建
    //    （`routes.dart`: `'scope != null'`）。假服务端回得快时，`await` 在
    //    进度框的**第一帧之前**就返回了，`maybePop()` 当场断言失败
    //    （实测 `phase6_ai_season_flow_test`）。`pop()` 不经过 `willPop()`，
    //    因此不依赖“已经渲染过”。
    //
    // 安全性：进度框 `barrierDismissible: false`，唯一的退出路径就是取消按钮
    // （会置 `canceled`），所以 `!canceled` 时栈顶必然仍是进度框。
    if (!canceled && mounted) navigator.pop();
    if (canceled || !mounted) return;

    if (!result.success) {
      // 「已取消」是用户自己的选择，不是故障：按 info 推，否则错误通知永不自动
      // 关闭，用户取消一次分析就会留下一条要手动收走的提示。
      showToast(
        _aiFailureText(result.reason),
        kind: result.reason == AiSeasonFailure.canceled
            ? ToastKind.info
            : ToastKind.error,
      );
      return;
    }

    await _showAiPreview(
      result: result,
      snapshotFlagKey: snapshotFlagKey,
      snapshotCount: snapshotCount,
    );
  }

  /// AI 结果预览确认（§7.3）与应用（§7.4）。**必经确认才落盘。**
  Future<void> _showAiPreview({
    required AiSeasonAnalysis result,
    required String snapshotFlagKey,
    required int snapshotCount,
  }) async {
    final previewOnly = result.mode == AiSeasonMode.explicitMapping;
    final confirmed = await showDialog<bool>(
      context: context,
      // 包一层**带 key 的** `RepaintBoundary`：证据截图必须能拍到这张对话框本身。
      //
      // 【为什么非加不可】每个路由（含 dialog）在 `Navigator` 里各有自己的
      // `RepaintBoundary`，**没有任何一个** boundary 同时包含页面与对话框的
      // 内容。所以「拍整窗」并不存在：默认取第一个 boundary 只会拍到详情页，
      // 对话框完全不在图里（实测 173791 字节的图里没有预览框）。既有套件
      // 用的是同一个办法：`tmdb_detail_visual_flow_test` 为图片查看器加了
      // `tmdb-photo-viewer-boundary`，截图时按 key 指定这一层。
      builder: (context) => RepaintBoundary(
        key: const ValueKey('ai-season-preview-boundary'),
        child: AlertDialog(
          key: const ValueKey('ai-season-preview'),
          title: const Text('AI 剧集 / 季度分析建议'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${_aiModeLabel(result.mode)} · '
                  '${(result.confidence * 100).round()}%',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                if (result.seasonNumber >= 0)
                  Text(
                    result.seasonNumber == 0
                        ? '特别篇'
                        : '第 ${result.seasonNumber} 季',
                  ),
                if (result.summary.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(result.summary),
                ],
                for (final warning in result.warnings) ...[
                  const SizedBox(height: 4),
                  Text('• $warning'),
                ],
                if (previewOnly) ...[
                  const SizedBox(height: 12),
                  Text(
                    '本版本仅预览，不会写入绑定。',
                    key: const ValueKey('ai-season-preview-only'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(previewOnly ? '知道了' : '取消'),
            ),
            if (!previewOnly)
              FilledButton(
                key: const ValueKey('ai-season-apply'),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('应用建议'),
              ),
          ],
        ),
      ),
    );
    if (confirmed != true || previewOnly || !mounted) return;

    // 快照校验（`04` §7.5）。
    final current = _ownedTmdb?.sourceLine;
    if (current == null ||
        current.flagKey != snapshotFlagKey ||
        current.episodeCount != snapshotCount) {
      showToast('线路已变化，AI 建议不再适用，请重新分析', kind: ToastKind.error);
      return;
    }

    switch (result.mode) {
      case AiSeasonMode.singleSeason:
        await widget.state.bindTmdbSeason(
          TmdbSeasonNumber(result.seasonNumber),
        );
      case AiSeasonMode.keepOriginal:
        await widget.state.bindTmdbSeason(const TmdbSeasonKeepOriginal());
      case AiSeasonMode.flatByCounts:
        // 应用前**再校验一次**（`04` §7.4）：AI 说可以，本地校验不过就拒绝。
        if (!(_ownedTmdb?.canAutoSlice ?? false)) {
          if (!mounted) return;
          showToast(
            '当前线路集数与 TMDB 季集数不匹配，无法安全自动切分',
            kind: ToastKind.error,
          );
          return;
        }
        await widget.state.bindTmdbSeason(const TmdbSeasonAutoSlice());
      case AiSeasonMode.explicitMapping:
        return; // 上面已短路，这里只为穷尽 switch。
      case null:
        return;
    }
    if (!mounted) return;
    await widget.state.reloadTmdb();
  }

  static String _aiModeLabel(AiSeasonMode? mode) => switch (mode) {
    AiSeasonMode.singleSeason => '单季',
    AiSeasonMode.flatByCounts => '按集数切片',
    AiSeasonMode.keepOriginal => '保持原始集列表',
    AiSeasonMode.explicitMapping => '逐集映射',
    null => '未知',
  };

  static String _aiFailureText(AiSeasonFailure reason) => switch (reason) {
    AiSeasonFailure.configIncomplete => 'AI 服务未配置完成',
    AiSeasonFailure.noEpisodes => '没有可分析的剧集',
    AiSeasonFailure.http => 'AI 接口返回错误',
    AiSeasonFailure.network => 'AI 网络错误',
    AiSeasonFailure.timeout => 'AI 请求超时',
    AiSeasonFailure.canceled => '已取消',
    AiSeasonFailure.invalidJson => 'AI 返回的不是合法 JSON',
    AiSeasonFailure.invalidMode => 'AI 返回的模式无法识别',
    AiSeasonFailure.invalidSeason => 'AI 给出的季度与 TMDB 不符',
    AiSeasonFailure.unsafeFlatMapping => 'AI 给出的集号映射不完整，已拒绝',
    AiSeasonFailure.invalidMapping => 'AI 的逐集映射不合法，已拒绝',
    AiSeasonFailure.none => 'AI 分析失败',
  };

  /// 本页要用的历史记录。
  ///
  /// 优先级：**构造参数 > 自己查**（`docs/phase6/design/02` §7.1）。
  PlaybackHistory? get _history {
    final seed = widget.resumeSeed;
    if (seed != null) {
      // 跨源续播：线路/集/进度全部来自原记录。`episodeName` 也要带上——
      // 原记录的 `episodeId` 可能是安卓哈希，只有集名还能对上目标站点。
      return PlaybackHistory(
        id: 0,
        siteKey: _pageSite?.key ?? '',
        vodId: widget.vod.vodId,
        vodName: widget.vod.vodName,
        vodPic: widget.vod.vodPic,
        flag: seed.flag,
        episodeName: seed.episodeName,
        episodeId: seed.episodeId,
        positionMs: seed.positionMs,
        durationMs: seed.durationMs,
        updatedAt: 0,
        completed: seed.completed,
      );
    }
    if (widget.historyFlag.isNotEmpty || widget.historyEpisodeId.isNotEmpty) {
      return PlaybackHistory(
        id: 0,
        siteKey: _pageSite?.key ?? '',
        vodId: widget.vod.vodId,
        vodName: widget.vod.vodName,
        vodPic: widget.vod.vodPic,
        flag: widget.historyFlag,
        episodeName: '',
        episodeId: widget.historyEpisodeId,
        positionMs: 0,
        durationMs: 0,
        updatedAt: 0,
      );
    }
    return widget.state.findHistory(
      siteKey: _pageSite?.key ?? '',
      vodId: widget.vod.vodId,
      // 原来源记录必须查它自己那条源的行。
      sourceKey: _pageSourceKey,
    );
  }

  /// 本页的续播目标（线路 + 集下标）。
  ///
  /// 在详情到达后才解析：`_activeLine` 依赖 `lines`，而 `lines` 在详情请求
  /// 返回前可能是列表页传入的残缺数据，在残缺数据上解析会得出错误线路。
  ///
  /// 传三个标量而不是 `PlaybackHistory`：`resolveHistoryTarget` 在纯逻辑层
  /// （`core/`），不得依赖 `services/storage.dart`。
  HistoryResumeTarget _resumeTarget(List<VodPlayLine> lines) {
    final history = _history;
    return resolveHistoryTarget(
      historyFlag: history?.flag ?? '',
      historyEpisodeId: history?.episodeId ?? '',
      historyEpisodeName: history?.episodeName ?? '',
      lines: lines,
    );
  }

  /// 首屏按钮文案（`docs/phase6/design/02` §3.1）。
  ///
  /// 只有「线路与集都对上」且还有续播位置才叫「继续播放」——两个条件都交给
  /// 已有实现判断：`matched` 由 [resolveHistoryTarget] 给出，续播位置由
  /// [AppState.resumePositionFor] 给出（它已把 `completed` 与「位置过短」
  /// 一起处理）。这里不重复实现其中任何一条，否则两处判定会漂移。
  ///
  /// `matched == false` 时**不**提前返回：`historyPlayLabel` 内部已经判过
  /// `matched` 并回落到 `fallback`，在这里再判一次就是重复判定——也正是
  /// §3.1 要避免的那种漂移。
  String _heroPlayLabel(List<VodPlayLine> lines, Vod vod) {
    final target = _resumeTarget(lines);
    final resume = _resumePositionOf(vod, lines, target);
    return historyPlayLabel(target: target, resumePosition: resume);
  }

  /// 历史那一集的续播位置（`design/02` §3.1 的第二个条件）。
  ///
  /// **必须用与 [_play] 完全相同的身份去查**，否则就是「明明有播放记录却查不到」：
  ///
  /// - **线路**：`history.flag` 存的是**站点源线路名**，只能拿
  ///   [VodPlayLine.playbackFlag]（`sourceFlag ?? flag`）去比。
  ///   [HistoryResumeTarget.flag] 是**展示线路名**，桥接详情
  ///   （`bridge_playback_flags`）里两者并不相等——用户实报的历史写在「丫仙女」、
  ///   详情展示为「uc」：拿展示名查 `flag = ?` 永远落空，于是 `matched` 为真
  ///   （「上次看到这里」标记是对的）而文案回落成「播放第一集」。
  /// - **集**：`episodeId` 必须给 [VodEpisode.url]（站点入口，本地播放就是这样
  ///   写入的），`episodeName` 也必须一并给——同步来的 `episode_id` 是安卓哈希，
  ///   只能靠集名对上（同 [_play] 里那段注释）。
  ///
  /// 只认命中线路里的那一集：`episodeIndex` 是线路**原始下标**，越界时返回 null
  /// （详情刷新期间 `lines` 与本行可能短暂不同步），而不是拿别的集去猜。
  Duration? _resumePositionOf(
    Vod vod,
    List<VodPlayLine> lines,
    HistoryResumeTarget target,
  ) {
    for (final line in lines) {
      if (line.flag != target.flag) continue;
      if (target.episodeIndex < 0 ||
          target.episodeIndex >= line.episodes.length) {
        return null;
      }
      return _resumeStartFor(vod, lines, line, target.episodeIndex);
    }
    return null;
  }

  /// 续播起点：同源查本机历史，跨源用原记录的进度换算。
  ///
  /// [resolveResumeStart] 的语义是「先给同源的精确答案，没有才用种子换算」：
  /// 传入的 `fallback` 一旦命中就直接返回，所以同源场景的行为与改造前完全一致。
  /// `targetDurationMs` 传 0：详情页拿不到目标集的真实时长（要 open 视频才有），
  /// 纯逻辑层对 0 的约定是「走绝对毫秒」，见 [ResumePositionPolicy.migrate]。
  Duration? _resumeStartFor(
    Vod vod,
    List<VodPlayLine> lines,
    VodPlayLine line,
    int episodeIndex,
  ) {
    final episode = line.episodes[episodeIndex];
    final fallback = widget.state.resumePositionFor(
      siteKey: _pageSite?.key ?? '',
      vodId: vod.vodId,
      flag: line.playbackFlag,
      episodeId: episode.url,
      episodeName: episode.name,
      sourceKey: _pageSourceKey,
    );
    // `targetDurationMs` 传 0：详情页拿不到目标集的真实时长（要 `open()` 成功
    // 才有），纯逻辑层对 0 的约定是「走绝对毫秒」。真正的比例换算交给播放器
    // ——种子的副本会随 `PlaybackRequest.resumeSeed` 一起下去，播放器拿到
    // `_controller.duration` 后重算一次（`player_page.dart` 的
    // `_effectiveStartPosition`）。这里算出的值同时也是首屏按钮文案的依据。
    return resolveResumeStart(
      lines: lines,
      seed: widget.resumeSeed,
      targetLine: line,
      targetEpisodeIndex: episodeIndex,
      targetEpisodeName: episode.name,
      targetDurationMs: 0,
      fallback: fallback,
    );
  }

  /// 历史那一集在**渲染列表**里的下标（-1 = 无，`design/02` §6）。
  ///
  /// 为什么需要换算：`resolveHistoryTarget` 给的是**线路原始下标**，而卡片是按
  /// `ordered`（已套用 TMDB 元数据 + 已季度过滤 + 可能已倒序）渲染的，
  /// 两个下标在「多季线路」或「倒序」下并不相等。直接把原始下标交给
  /// [TmdbEpisodeStrip.recentIndex] 会标错集。
  ///
  /// 用集 **URL** 而不是集号做桥接：集号可能缺失或重复（`stillKey` 的注释里
  /// 已记过这个坑），URL 才是「同一集」的稳定身份。
  ///
  /// 三道守卫都不可省：
  /// 1. `matched` —— `matched == false` 涵盖「无历史」与「历史线路在但那一集
  ///    已消失」（§4.1），标出来会把用户引到一条没有那一集的线路上；
  /// 2. `rawLine.flag == target.flag` —— 只有历史命中的**那条线路**才标，
  ///    否则切到别的线路也会看到标记；
  /// 3. 下标越界 —— `lines` 与 `rawLine` 理论上同源，但越界时必须回落到
  ///    「无标记」而不是抛异常（详情刷新期间两者可能短暂不同步）。
  int _recentRenderedIndex(
    Vod vod,
    VodPlayLine rawLine,
    List<VodEpisode> ordered,
  ) {
    final lines = _playableLines(vod);
    final target = _resumeTarget(lines);
    if (!target.matched) return -1;
    if (rawLine.flag != target.flag) return -1;
    if (target.episodeIndex < 0 ||
        target.episodeIndex >= rawLine.episodes.length) {
      return -1;
    }
    final episode = rawLine.episodes[target.episodeIndex];
    for (var i = 0; i < ordered.length; i++) {
      if (identical(ordered[i], episode) || ordered[i].url == episode.url) {
        return i;
      }
    }
    return -1;
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
    // 外部（换源并入）线路：播放必须**定向**到它自己那一个站点解析。
    //
    // 为什么不能只靠 `flag`：并入后的 `flag` 是本页的展示名（`站点名 · 原线路名`），
    // 站点自己并不认识它；真正的线路标识在 `playbackFlag` 里。而 `vodId` 也得换成
    // 来源站点的 vod，否则会拿原站点的 id 去问外部站点。
    final route = _externalRoutes[line.flag];
    try {
      final decision = await state.resolvePlayback(
        episodeTarget: episode.url,
        flag: line.playbackFlag,
        vodId: route?.vodId ?? vod.vodId,
        // 非 null 时只解析这一次、不切全局站源（顶栏/设置里的 site 不许变）。
        siteOverride: route == null
            ? (widget.sourceContext == null ? null : _pageSite)
            : state.siteByKey(route.siteKey),
        // 原来源记录：解析走它自己那份配置的服务（请求头/规则/运行时都不串）。
        //
        // 外部并入线路是个例外：那条线路的站点属于**当前配置**，用原配置的
        // 服务去问会拿错请求头/运行时。两条来源不能混着用，按线路各自的归属走。
        serviceOverride: route == null ? widget.sourceContext?.service : null,
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
      //
      // 必须同时给 `episodeName`：同步来的历史 `episode_id` 存的是安卓哈希
      // （`episodeUrl` 的 SHA-256），与这里的 `episode.url`（站点入口）不同源，
      // 只靠 `episodeId` 永远命不中 → 手动拉取的历史点开就从头开始。
      //
      // 跨源（`resumeSeed` 非空）时上面这条查询必然落空：它按当前站点的
      // `siteKey` 查本机历史。此时改用原记录的进度做迁移，见 [_resumeStartFor]。
      final resume = _resumeStartFor(vod, _linesOf(vod), line, episodeIndex);
      // TMDB 季度身份（`04` §8.1）：已确证季度时透传；未确证时只传 URL/集名。
      // 归属门：不属于本页影片的 TMDB 数据不得带进播放器身份（会把进度写到错的季集上）。
      final tmdb = _ownedTmdb;
      final identity = TmdbPlaybackIdentity.of(
        identity: tmdb?.identity,
        episode: episode,
        flagKey: tmdb?.sourceLine?.flagKey ?? line.flag,
        seasonNumber: tmdb != null && tmdb.hasMatch && tmdb.selectedSeason >= 0
            ? tmdb.selectedSeason
            : -1,
        episodeNumber: _tmdbEpisodeNumberOf(episode),
      );
      // 选集卡片数据（阶段 A）：与 [_buildEpisodes] 的 `cards` 用**同一套构造**，
      // 否则播放器浮层里的卡片会与详情页选集对不上——两者都按「当前季度过滤 →
      // 可能倒序 → 按原始线路下标推断缺号集编号」得出，任一环节走样都会错位。
      // 每条线路各算一份：播放器切线路时要取那条线路自己的卡片。
      final episodeCardsByFlag = _episodeCardsByFlag(vod);
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
              // 历史要记在**真正来源**站点上：外部线路播出来的那条记录属于
              // 那个站点，记成「当前站源」会让历史页里的来源是错的。
              // 原来源播放时 `_pageSite` 就是那份配置里的站点。
              siteKey: route?.siteKey ?? _pageSite?.key ?? '',
              vodId: route?.vodId ?? vod.vodId,
              vodName: vod.vodName,
              episodeName: episode.name,
              flag: line.flag,
              playbackFlag: line.playbackFlag,
              playLines: _playableLines(vod),
              // 播放器换集/切线路要重新解析，必须继续定向到同一条外部线路。
              lineRoutes: _externalRoutes,
              episodeCardsByFlag: episodeCardsByFlag,
              // 面板的排列方向必须与详情页这一刻一致（用户看到的第 0 张 =
              // 播放器里的第 0 张），否则区间标签方向反着来。
              episodesReversed: _episodesReversed,
              episodeIndex: episodeIndex,
              vodPic: vod.vodPic,
              startPosition: resume,
              // 外挂字幕（§10.3）与弹幕（§21 Phase 3）：播放结果 + 代理前 Header。
              subtitles: decision.subs,
              danmaku: decision.danmaku,
              subtitleHeaders:
                  decision.assetHeaders?.asRequestHeaders ?? const {},
              tmdb: identity.hasIdentity ? identity : null,
              // 种子随请求一起下去，由播放器拿到目标集真实时长后重算比例
              // （见 `_resumeStartFor` 注释与 `PlaybackRequest.resumeSeed`）。
              resumeSeed: widget.resumeSeed,
              // 播放源归属：原来源播放时进度要写回那条记录自己的源。
              //
              // 外部并入线路例外：那条线路的站点属于**当前配置**，把它们记到
              // 原来源下会造出一条源与站点不匹配的历史（历史页点开会失败）。
              sourceKey: route == null
                  ? (widget.sourceContext?.sourceKey ?? '')
                  : '',
            ),
          ),
        ),
      );
    } catch (error) {
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      if (!mounted) return;
      // 用户在站点里主动中断不是「这一集没有地址」，再问一次换源只会打断连播；
      // 自动续播那一趟失败同样只回到 通知（见 [_resumingAfterSwap]）。
      if (failure.kind == AppErrorKind.siteCancelled || _resumingAfterSwap) {
        showToast(failure.userMessage, kind: ToastKind.error);
        return;
      }
      // 只闪一条 SnackBar，用户没有任何可执行动作（用户反馈：看到「没有集数
      // 信息」的报错后不知道能干什么）。改成先问要不要换源：不换源就什么都不
      // 做；确认了才记住这一集，并入后自动接着播（见 [_openSourceSwap]）。
      final wantsSwap = await _confirmSwapAfterPlayFailure(episode, failure);
      if (!mounted || !wantsSwap) return;
      // 记下**三个**锚点：下标（原线路）、1-based 集号、tmdb 集号。续播定位
      // 按「tmdb 集号 → 集名数字 → 下标」的顺序在新线路里找同一集（见
      // [_locateResumeEpisode]），下标只是最后的兜底，不能单独用。
      setState(() {
        _pendingResumeEpisode = episodeIndex;
        _pendingResumeOrdinal = episodeIndex + 1;
        _pendingResumeEpisodeNumber = _tmdbEpisodeNumberOf(episode);
      });
      await _openSourceSwap();
    }
  }

  /// 播放失败时的换源确认框；返回 `true` 才继续换源。
  ///
  /// 文案说清两件事：这一集缺可播放地址、换源后会自动接着播这一集。
  /// [RepaintBoundary] 的 key 与 :1530 同一约定——每个路由各有自己的
  /// RepaintBoundary，证据截图只能按 key 指这一层，整窗截图不存在。
  Future<bool> _confirmSwapAfterPlayFailure(
    VodEpisode episode,
    AppError failure,
  ) async {
    // 标题已经说明了「这一集没有可播放的地址」，正文只需要**具体原因**：
    // [AppError.userMessage] 会把错误类别再拼一遍，遇到 detail 又重复同类描述
    // 时就变成括号嵌套的重复噪音（见 buildPlayRequest 里的 detail），故优先取
    // message；只有在 message 为空这种退化情况下才回落到 userMessage。
    final message = failure.message.trim();
    final reason = message.isNotEmpty ? message : failure.userMessage;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => RepaintBoundary(
        key: const ValueKey('detail-playback-failed-boundary'),
        child: AlertDialog(
          key: const ValueKey('detail-playback-failed'),
          title: const Text('这一集没有可播放的地址'),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(episode.name),
              const SizedBox(height: 6),
              // 原始错误弱化处理：它是给用户判断「是站点挂了还是真没地址」的
              // 线索，不该和标题抢注意力。
              Text(
                reason,
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              const Text('换到别的线路后，会自动接着播这一集。'),
            ],
          ),
          actions: [
            TextButton(
              key: const ValueKey('detail-playback-failed-dismiss'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('知道了'),
            ),
            FilledButton(
              key: const ValueKey('detail-playback-failed-swap'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('换源'),
            ),
          ],
        ),
      ),
    );
    return confirmed ?? false;
  }

  /// 站点 key → 来源健康态（浮层里的色点与并入后线路的行尾色点共用）。
  ///
  /// 走 [buildMagnitudes] 而不是自己算星等：星等与状态色的换算只该有一处实现，
  /// 否则浮层与列表页会对同一个站点给出两种颜色。它逐条按 `item.site.key` 算，
  /// 所以直接按 [SiteMagnitude.siteKey] 建表——**不要**用名称中转：重名的两个
  /// 站点会在名称键上互相覆盖，一个站显示成另一个站的健康度。
  Map<String, SourceStatus> _siteStatusByKey() {
    final state = widget.state;
    final items = state.siteItems;
    final magnitudes = buildMagnitudes(
      items: items,
      health: {
        for (final row in state.siteHealth()) row.siteKey: row,
      },
    );
    final byKey = <String, SourceStatus>{
      for (final magnitude in magnitudes) magnitude.siteKey: magnitude.status,
    };
    return {
      for (final item in items)
        item.site.key: byKey[item.site.key] ?? SourceStatus.unknown,
    };
  }

  /// 清空换源并入的外部线路，回到默认线路。
  void _clearExternalLines() {
    if (_externalLines.isEmpty) return;
    setState(() {
      _externalLines.clear();
      _externalRoutes.clear();
      _externalStatus.clear();
      // 选中态归零 = 回到默认（第一条 / 历史命中的那条），而不是停在一条
      // 已经不存在的 flag 上（那会让 `_activeLine` 落到 `lines.first` 之外的猜测）。
      _selectedLineFlag = '';
    });
  }

  /// 打开换源浮层，并把选中的候选并入本页线路。
  ///
  /// 浮层负责搜索/勾选/解析（W1 已实现），这里只做三件事：把它需要的三个回调
  /// 接到 [AppState]（UI 层不得直接发网络请求）、把结果包装成外部线路、把选择
  /// 落到「集数最多」的那条线路上。
  Future<void> _openSourceSwap() async {
    final state = widget.state;
    final vod = _currentVod;
    if (vod == null) {
      // 拿不到本片详情就无从换源：待续播意图跟着失效，别留给下一次。
      _clearPendingResume();
      return;
    }
    final statuses = _siteStatusByKey();
    final rows = await showSourceSwapSheet(
      context,
      // 用**当前详情**到的片名搜：列表页传入的条目可能没有片名/是别名。
      keyword: vod.vodName,
      // 与大搜索共用同一套全局状态：浮层不再自建搜索、也不再等整批结果，
      // 直接消费 activeSearch 的流式快照（每完成一个站点就刷新）。
      searchListenable: state,
      outcomeOf: () => state.activeSearch,
      // 与安卓换源一致：仍然一次性提交范围内的全部站点，靠 quick=true 限流
      // （安卓 TmdbDetailActivity.java:12255 的 startInlineSourceSearch 传的就是
      // searchContent(sites, keyword, true)；这是既有语义，不是新发明）。
      // 并发沿用用户设置 searchThread（默认 20），单站超时用默认 20 秒。
      onSearch: (keyword) => state.searchAll(keyword, quick: true),
      onProbe: (candidate) => state.swapProbe(
        siteKey: candidate.siteKey,
        vodId: candidate.vodId,
        vodName: candidate.vodName,
      ),
      statusOf: (siteKey) => statuses[siteKey] ?? SourceStatus.unknown,
    );
    // 浮层一关，在途批次立刻作废：否则用户看到的是「关了还在打后端」。
    // 放在这里而不是 dispose：此刻已彻底离开构建阶段，取消时触发的
    // notifyListeners() 是安全的；对已完成的批次它是 no-op。
    state.cancelSearch();
    // 取消 = 什么都不做。绝不在这里清空已有外部线路：用户按 Esc 不该丢掉刚才的工作。
    if (rows == null || rows.isEmpty || !mounted) {
      // 浮层被关掉（返回 null）说明这次换源没发生：待续播意图必须失效，
      // 否则它会让**下一次**换源并入后莫名自动开播。
      _clearPendingResume();
      return;
    }
    // 只取**原线路 + 已并入**的 flag 做占用集：外部 flag 必须页面内唯一。
    final taken = <String>{
      for (final line in state.playLinesOf(vod)) line.flag,
      ..._takenFlags,
    };
    final mergedLines = <VodPlayLine>[];
    final mergedRoutes = <String, SwapLineRoute>{};
    final mergedStatus = <String, SourceStatus>{};
    for (final row in rows) {
      for (final line in row.lines) {
        // 空线路没有任何可播的集，并入只会得到一条点不动的 chip。
        if (line.episodes.isEmpty) continue;
        final merged = externalPlayLine(
          siteName: row.candidate.siteName,
          line: line,
          taken: taken,
        );
        mergedLines.add(merged);
        mergedRoutes[merged.flag] = SwapLineRoute(
          siteKey: row.candidate.siteKey,
          siteName: row.candidate.siteName,
          vodId: row.candidate.vodId,
        );
        mergedStatus[merged.flag] =
            statuses[row.candidate.siteKey] ?? SourceStatus.unknown;
      }
    }
    if (mergedLines.isEmpty) {
      // 勾选的候选项全都没有集数：什么都没并入，意图一并失效。
      _clearPendingResume();
      return;
    }
    setState(() {
      _externalLines.addAll(mergedLines);
      _externalRoutes.addAll(mergedRoutes);
      _externalStatus.addAll(mergedStatus);
    });
    // 选线的两套语义，按「本次有没有待续播意图」分开：
    // - 没有意图（错误条 CTA 进来的普通换源）：默认选「集数最多」的那条，原线路
    //   一起比；只在外部线路不少于当前线路时才切，全部更少就保持用户原来的
    //   选择，不做无谓跳动。
    // - 有意图（刚有一集播失败了）：必须落到外部线路上，见下。
    // 导航源例外：站源线路不可播放，不参与选线（见 [_playableLines]）。
    final lines = _playableLines(vod);
    final VodPlayLine best;
    if (_pendingResumeEpisode >= 0 && _externalLines.isNotEmpty) {
      // 有续播意图时，选中的线路与播的集必须是**同一条**，且必须是外部线路：
      // 原线路刚刚被证明播不通，落回去等于换源没换（且续播那一趟抑制了确认框，
      // 用户只会看到一条 SnackBar）。
      best = _widestExternalLine();
    } else {
      // 没有待续播意图：语义与改造前逐字一致——并入后选「集数最多」的那条。
      var widest = _activeLine(lines);
      for (final line in _externalLines) {
        if (line.episodes.length >= widest.episodes.length) widest = line;
      }
      best = widest;
    }
    _selectLine(best, lines);
    await _resumeAfterSourceSwap(vod, best);
  }

  /// [_externalLines] 里集数最多的那条（并列取先并入的）。调用方保证非空。
  ///
  /// 为什么是它：续播必须落在**本次并入进来**的线路上。原线路刚刚被证明播不通，
  /// 拿它续播只会再失败一次，用户除了 SnackBar 什么都看不到。
  VodPlayLine _widestExternalLine() {
    var widest = _externalLines.first;
    for (final line in _externalLines.skip(1)) {
      if (line.episodes.length > widest.episodes.length) widest = line;
    }
    return widest;
  }

  /// 在 [episodes] 里按**集号**定位待续播的那一集。
  ///
  /// 固定优先级，逐级回落（每一步都是「证据更强的身份优先」）：
  /// 1. tmdb 集号相等——语义身份，最可靠；
  /// 2. 集名里**最后一个**数字段等于 ordinal——`第06集`/`EP06`/`S01E06` 都命中 6；
  /// 3. 原下标（`ordinal - 1`），仅当下标仍落在范围内时可用；
  /// 4. 全落空 → 第 0 集，并把「发生了回退」带回去（调用方要提示用户）。
  ///
  /// 返回值是 (下标, 是否回退)。用私有结果类而不是 record：本仓库既有代码里
  /// 没有 record 解构的用法，保持同一个风格。
  _ResumeLocatorHit _locateResumeEpisode(
    List<VodEpisode> episodes,
    int episodeNumber,
    int ordinal,
  ) {
    if (episodes.isEmpty) return const _ResumeLocatorHit(0, true);
    if (episodeNumber >= 0) {
      for (var i = 0; i < episodes.length; i += 1) {
        if (_tmdbEpisodeNumberOf(episodes[i]) == episodeNumber) {
          return _ResumeLocatorHit(i, false);
        }
      }
    }
    if (ordinal >= 1) {
      for (var i = 0; i < episodes.length; i += 1) {
        if (_episodeNameNumber(episodes[i].name) == ordinal) {
          return _ResumeLocatorHit(i, false);
        }
      }
      final byIndex = ordinal - 1;
      if (byIndex < episodes.length) return _ResumeLocatorHit(byIndex, false);
    }
    return const _ResumeLocatorHit(0, true);
  }

  /// 集名里的**最后一个** 1~4 位数字段；整条名字里没有数字时返回 -1。
  ///
  /// 为什么取最后一个：`S01E06` 的最后一个数字才是集号，`第2季第6集` 同理；
  /// 取第一个会在季集混排时稳定错位。
  static int _episodeNameNumber(String name) {
    var value = -1;
    for (final match in _episodeNumberPattern.allMatches(name)) {
      final parsed = int.tryParse(match.group(1) ?? '');
      if (parsed != null) value = parsed;
    }
    return value;
  }

  static final RegExp _episodeNumberPattern = RegExp(r'(\d{1,4})');

  /// 并入完成后自动续播换源前那一集（见 [_pendingResumeEpisode]）。
  ///
  /// [line] 必须是**新并入的外部线路**（见 [_openSourceSwap] 的选线分支）：
  /// 原线路已经播不通，回到它上面续播等于这次换源白做。
  ///
  /// 定位按集号而不是下标（见 [_locateResumeEpisode]）；真的找不到同一集时从
  /// 第 1 集开始，并说清为什么——否则用户只会觉得「换源把我的集数弄丢了」。
  Future<void> _resumeAfterSourceSwap(Vod vod, VodPlayLine line) async {
    final resumeIndex = _pendingResumeEpisode;
    if (resumeIndex < 0) return;
    final episodeNumber = _pendingResumeEpisodeNumber;
    final ordinal = _pendingResumeOrdinal;
    // **先复位再播**：这一次续播若再失败，不能把同一个意图带到下一次换源上。
    // 这里不需要 setState：浮层刚关，页面上没有依赖它的渲染。
    _pendingResumeEpisode = -1;
    _pendingResumeOrdinal = -1;
    _pendingResumeEpisodeNumber = -1;
    if (line.episodes.isEmpty) return;
    final hit = _locateResumeEpisode(line.episodes, episodeNumber, ordinal);
    if (hit.fellBack) {
      showToast('「${line.flag}」只有 ${line.episodes.length} 集，已从第 1 集开始播放');
    }
    // 续播这一趟不再问「要不要换源」：失败仍回到 通知（见 [_play] 的 catch）。
    _resumingAfterSwap = true;
    try {
      await _play(vod, line, hit.index);
    } finally {
      _resumingAfterSwap = false;
    }
  }

  /// 清掉「换源后自动续播」的意图（浮层被取消、或什么都没并入时）。
  ///
  /// 三个锚点必须一起清：只清下标而留下集号，等于让一次被取消的意图从
  /// 下一次换源里漏出来。
  void _clearPendingResume() {
    if (_pendingResumeEpisode < 0) {
      _pendingResumeOrdinal = -1;
      _pendingResumeEpisodeNumber = -1;
      return;
    }
    if (!mounted) {
      _pendingResumeEpisode = -1;
      _pendingResumeOrdinal = -1;
      _pendingResumeEpisodeNumber = -1;
      return;
    }
    setState(() {
      _pendingResumeEpisode = -1;
      _pendingResumeOrdinal = -1;
      _pendingResumeEpisodeNumber = -1;
    });
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
    final belongs =
        result != null &&
        result.list.isNotEmpty &&
        result.list.first.vodId == widget.vod.vodId;
    final vod = belongs ? result.list.first : widget.vod;
    // 原线路 + 换源并入的外部线路（外部恒在后，见 [_linesOf]）。
    // 导航源例外：站源线路不可播放，不进线路条（见 [_playableLines]）。
    final lines = _playableLines(vod);
    // 详情到达后自动切到历史线路（`docs/phase6/design/02` §4、§4.1）。
    //
    // 为什么在 build 里而不是 initState：详情请求在页面挂载后才完成，
    // initState 时 lines 还是残缺的。
    //
    // **必须等 `belongs` 为真**（= 本页的详情结果已到达），不能只看
    // `lines.isNotEmpty`：后者在详情未到达时可能是**列表页传入条目的残缺线路**，
    // 在残缺集合上解析会得出错误线路（§2.1 第二级的"唯一命中"在集合变小时
    // 可能假唯一），而且 `_selectedLineFlag` 一旦写入就**永久锁死**
    // （下面 `isEmpty` 守卫会让真详情到达后不再重解析）。
    //
    // **只有 `matched == true` 才切**（`design/02` §4.1）：`matched == false`
    // 涵盖「无历史」「历史线路在但那一集已消失」两种情形，它们都不该改变
    // 用户的线路选择——切过去也没有那一集。
    if (belongs && lines.isNotEmpty) {
      final target = _resumeTarget(lines);
      // 只在「用户还没手动选过」时应用（`_selectedLineFlag` 为空）。
      // 用户手动切过线路后，历史不得把选择抢回去。
      if (target.matched && _selectedLineFlag.isEmpty) {
        _selectedLineFlag = target.flag;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          state.tmdb.selectLine(target.flag);
          unawaited(state.reloadTmdb());
        });
      }
    }
    final loading = state.detailPhase == LoadPhase.loading;
    final tmdb = state.tmdb;
    // 归属门：保留的 TMDB 数据不属于本页影片时，整块 TMDB 渲染按「无 TMDB」降级
    // （上一部剧的海报/标题/演职人员绝不能出现在本页，哪怕只有一帧）。
    final owned = _tmdbOwnsThisPage;
    // 头部补位（`04` §3.2）：**仅补位不覆盖**来源已有字段。
    final display = owned && tmdb.hasMatch ? tmdb.enrich(vod).vod : vod;
    // TMDB 展示模型（海报/背景/类型/时长/季集数/演职人员…）。
    final tmdbData = owned ? tmdb.detailData : null;
    // 头部数据：未匹配 TMDB 时回退到来源海报，保证头部不空白。
    //
    // 提成局部变量是因为**页面级背景**要用同一份。两处各算一次的话，
    // 回退分支可能得出不同结果（背景与头部的图不一致）。
    final headerData =
        tmdbData ??
        TmdbDetailData(
          title: display.vodName,
          overview: display.vodContent,
          posterUrl: display.vodPic,
          backdropUrls: [
            if ((display.vodPic ?? '').isNotEmpty) display.vodPic!,
          ],
          rating: 0,
        );

    return Scaffold(
      // 头部是**全幅 hero**（用户反馈 2026-10-09：「详情页太简陋，背景海报也没有
      // 全屏显示」）：背景海报铺满整宽并延伸到 app bar 之下，app bar 自身透明，
      // 只把返回/收藏/刷新浮在背景上。内容区不再整体加 16 边距（那样 hero 两侧会
      // 露出底色，就没有「全屏」可言），改由正文各自留边。
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        // 顶部透明：hero 的背景海报能一直铺到屏幕最上边。
        backgroundColor: Colors.transparent,
        // 滚动到内容经过 app bar 下方时恢复不透明底色（用页面底色而非主题色
        // 调），否则标题会与正文文字叠在一起。
        surfaceTintColor: Theme.of(context).colorScheme.surface,
        elevation: 0,
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
          Builder(
            builder: (context) {
              final site = state.selectedSite;
              if (site == null) return const SizedBox.shrink();
              final existing = state.followingForVod(
                siteKey: site.key,
                vodId: vod.vodId,
              );
              final followed = existing != null;
              return IconButton(
                key: const ValueKey('detail-follow'),
                tooltip: followed ? '取消追番' : '追番',
                onPressed: () {
                  if (followed) {
                    unawaited(state.unfollowFollowing(existing));
                    showToast('已取消追番', kind: ToastKind.success);
                    return;
                  }
                  final line = lines.isEmpty ? null : _activeLine(lines);
                  state.followFromDetail(
                    site: site,
                    vod: vod,
                    flag: line?.flag ?? '',
                    sourceFlag: line?.sourceFlag ?? line?.playbackFlag ?? '',
                    releasedEpisode: line?.episodes.length ?? 0,
                  );
                  showToast('已加入追番', kind: ToastKind.success);
                },
                icon: Icon(followed ? Icons.star : Icons.star_border),
              );
            },
          ),
          IconButton(
            tooltip: '刷新详情',
            onPressed: () => state.loadDetail(widget.vod),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Stack(
        children: [
          // 页面级**固定**背景（用户反馈 2026-10-13：「后续内容也应该显示在图片上」）。
          //
          // 为什么放在这里而不是头部里：`Positioned.fill` **脱离滚动**，所以
          // 整页内容都浮在图上；图片不会随内容滚走、下半页也不会变回纯色。
          // 头部因此不再自己画图（`paintImage: false`）。
          Positioned.fill(
            child: TmdbDetailBackdrop(
              urls: headerData.backdropUrls,
              fallbackUrl: headerData.posterUrl,
            ),
          ),
          if (loading && lines.isEmpty)
            const Positioned.fill(child: Center(child: LoadingBlock()))
          else
            ListView(
              padding: EdgeInsets.zero,
              children: [
                // 详情错误不再在页面里拼横幅：它由 [_syncDetailErrorToast] 推成
                // 右下角通知，动作（「换源」）随通知一起走——页面内没有第二个
                // 渲染点，同一条错误只会出现在一处。
                // 动态背景头部（`04` §3.1 ①）：用 TMDB 海报/剧照当背景，
                // 未匹配时回退到来源海报，保证头部不空白。
                // 高度由组件按视口自适应：图片框取整屏，内容贴它的底部
                // （= 视口底部，窗口与全屏一致；2026-10-23 内容带退场）。
                TmdbDetailHeader(
                  // 图片由页面级背景负责（见本 body 的 Stack），头部只画内容。
                  paintImage: false,
                  data: headerData,
                  heroOverview: display.vodContent ?? tmdbData?.overview,
                  // 只剩播放入口：简介已改为在 hero 内按剩余高度完整显示，
                  // 「查看简介」按钮及其对话框按 2026-10-22 用户反馈移除。
                  heroActions: lines.isEmpty
                      ? null
                      : FilledButton.icon(
                          key: const ValueKey('detail-hero-play'),
                          onPressed: () => _play(
                            vod,
                            _activeLine(lines),
                            // 历史命中的那一集（`design/02` §3.2）。
                            // `matched == false` 时它本来就是 0，
                            // 正是「播放第一集」该有的行为，无需额外分支。
                            //
                            // 这里用的是**原始下标**（`VodPlayLine.episodes`
                            // 的下标），而渲染下标经过季度过滤与倒序——
                            // `_play` 要的正是原始下标（§3.3）。
                            _resumeTarget(lines).episodeIndex,
                          ),
                          icon: const Icon(Icons.play_arrow),
                          label: Text(_heroPlayLabel(lines, vod)),
                        ),
                ),
                // 正文统一留 16 边距（hero 不加，才能左右铺满）。
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // TMDB 状态条原在 hero 之上（会被悬浮 app bar 遮住），
                      // 改到 hero 下方：既不与图标重叠，也更靠近正文。
                      if (owned)
                        TmdbStatusBar(
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
                      // 信息表已退场（2026-10-22 用户反馈）：`备注` 去掉，
                      // `语言` 已进 hero 标签行，两行都不剩，空表不再渲染。
                      const SizedBox(height: 12),
                      // 季度选择器（`04` §4.1）：仅 tv 且已匹配时渲染。
                      // 导航源例外：卡片是全季一次性摊平的，切季没有意义
                      // （用户决策 6「不显示季度切换器」）。
                      if (owned && !_navSourceMode)
                        TmdbSeasonSelector(
                          state: tmdb,
                          onChanged: (season) {
                            tmdb.selectSeason(season);
                            unawaited(
                              tmdb.loadEpisodes(generation: tmdb.generation),
                            );
                          },
                          onSelectManual: _openSeasonDialog,
                        ),
                      // 纯 TMDB 详情页入口（`04` §6.1）。
                      if (owned && tmdb.hasMatch && tmdb.identity != null)
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
                      // 导航源模式**整段跳过**线路条、「没有可播放的剧集」提示与
                      // 清空外部线路按钮（用户决策 4：导航站进来不显示线路，
                      // 实际也没有播放线路），改渲染 TMDB 全集卡片。
                      // 非导航源模式走下面原样的两条分支，行为一字不改。
                      if (_navSourceMode)
                        _buildNavSourceEpisodes(context, _ownedTmdb)
                      else if (loading && lines.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: LoadingBlock(),
                        )
                      else if (lines.isEmpty)
                        Text(
                          state.detailError?.userMessage ??
                              '该影片没有可播放的剧集（vod_play_url 为空）。',
                        ),
                      if (!_navSourceMode && lines.isNotEmpty) ...[
                        // 线路选择（`04` §3.1 ④）：点击即切换，剧集卡片随之切换。
                        // 对齐上游 `@id/flag` —— 上游也只渲染**当前线路**的选集区。
                        TmdbLineSelector(
                          lines: lines,
                          selectedFlag: _activeLine(lines).flag,
                          // 「最近播放」标记（`design/02` §5）：只有
                          // `matched == true` 才标——`matched == false` 涵盖
                          // 「无历史」与「历史线路在但那一集已消失」两种情形，
                          // 后者标出来会把用户引到一条没有那一集的线路上。
                          recentFlag: _resumeTarget(lines).matched
                              ? _resumeTarget(lines).flag
                              : '',
                          episodeCounts: _episodeCountsByLine(lines),
                          onChanged: (line) => _selectLine(line, lines),
                          // 外部线路的来源站点与健康态（行尾色点 + Tooltip）。
                          externalOrigins: {
                            for (final entry in _externalRoutes.entries)
                              entry.key: entry.value.siteName,
                          },
                          externalStatus: _externalStatus,
                          // 换源的常驻次入口：即使没有报错也要能换。
                          onSwapSource: _openSourceSwap,
                        ),
                        // 清空是**显式**动作：外部线路是临时的，用户要能主动退回原线路，
                        // 而不是只能靠离开详情页来丢弃它。
                        if (_externalLines.isNotEmpty)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: const EdgeInsets.only(top: AppSpace.xs),
                              child: TextButton(
                                key: const ValueKey('detail-clear-external'),
                                onPressed: _clearExternalLines,
                                child: const Text('清空外部线路'),
                              ),
                            ),
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
                ),
              ],
            ),
        ],
      ),
    );
  }

  /// 线路已经在详情加载阶段展开，详情页只负责标准线路渲染。

  /// 剧照墙 / 演职人员 / 相关推荐 / 相关视频（`04` §3.1 ⑥–⑨）。
  ///
  /// 全部**可点击**（用户反馈：之前点击无效）：
  /// - 剧照 → 大图查看器（可翻页）；
  /// - 演职人员 → 人物页（简介/照片/作品）；
  /// - 相关推荐 → 该作品的 TMDB 详情页；
  /// - 相关视频 → 浏览器打开 / 复制链接。
  List<Widget> _buildTmdbBlocks(BuildContext context, TmdbState tmdb) {
    // 归属门：不属于本页影片时整块（简介/演职人员/推荐/视频）都不渲染。
    if (!_tmdbOwnsThisPage) return const [];
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
    // 归属门：不属于本页影片的 TMDB 数据不参与切线路（否则会把上一部剧的季号
    // 当成「当前季度意图」带进新线路解析）。
    final tmdb = _ownedTmdb;
    final preferred = tmdb?.selectedSeason ?? -1;
    setState(() => _selectedLineFlag = line.flag);
    tmdb?.selectLine(line.flag, preferredSeason: preferred);
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
  List<VodEpisode> _renderEpisodes(
    VodPlayLine rawLine, {
    required bool active,
  }) {
    // 归属门：不属于本页影片的 TMDB 数据一律不参与渲染，直接直通原集列表。
    final tmdb = _ownedTmdb;
    if (tmdb == null) return rawLine.episodes;
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

  /// 每集在**原始线路**中的下标（对应上游 `episodes.indexOf(episode)`）。
  ///
  /// `rendered` 是季度过滤后（可能还倒序过）的子集，它的下标不能用来推断集号。
  /// 匹配不上时返回 `-1`，由下游决定如何退化。
  List<int> _sourceEpisodeIndices(
    List<VodEpisode> source,
    List<VodEpisode> rendered,
  ) {
    final indices = <int>[];
    for (final episode in rendered) {
      var index = -1;
      for (var i = 0; i < source.length; i++) {
        if (identical(source[i], episode) || source[i].url == episode.url) {
          index = i;
          break;
        }
      }
      indices.add(index);
    }
    return indices;
  }

  /// 交给播放器的剧集卡片：**每条线路各一份**，按线路展示标识分组。
  ///
  /// 构造规则必须与 [_buildEpisodes] 里的 `cards` **逐条一致**，否则卡片与集对不上：
  /// - 当前线路取 `_renderEpisodes(rawLine, active: true)`（当前季度过滤后的渲染集）；
  /// - 尊重页面的倒序开关（用户看到的第 0 张必须就是播放器里的第 0 张）；
  /// - 缺号集的集号按**原始线路**下标推断（`sourceIndices`），不能用渲染下标。
  ///
  /// 为什么每条线路都算：卡片原先只给「当前选中的线路」，播放器切到别的线路后
  /// `PlaybackRequest.copyWith` 会把旧卡片原样带过——两条线路集数恰好相等时，
  /// 旧线路的剧照会被贴到新线路的集上，长度校验根本查不出来。
  ///
  /// 为什么非当前线路走 `active: false`：季度元数据是线路级的（`04` §4.3），
  /// 把当前线路的季度集标题/剧照套到另一条线路的集上就是串图串集
  /// （`_renderEpisodes` 的 `active: false` 分支正是为此存在）。非当前线路只按
  /// **来源集名**出自己的卡（集号 + 本剧通用剧照），不借用别条线路的集标题。
  ///
  /// 没有 TMDB 数据（未匹配/不属于本页影片）时返回空 Map：宁可没有卡片，
  /// 也不得用占位图或假简介冒充（`PRODUCT.md` §Product Principles 第 5 条）。
  Map<String, List<TmdbEpisodeCard>> _episodeCardsByFlag(Vod vod) {
    final tmdb = _ownedTmdb;
    if (tmdb == null) return const {};
    final lines = _linesOf(vod);
    if (lines.isEmpty) return const {};
    final activeFlag = _activeLine(lines).flag;
    final seasonNumber = tmdb.selectedSeason >= 0 ? tmdb.selectedSeason : null;
    final cards = <String, List<TmdbEpisodeCard>>{};
    for (final rawLine in lines) {
      final isActive = rawLine.flag == activeFlag;
      // `_buildEpisodes` 的 `sourceIndices` 取自 TMDB 应用元数据**之后**的线路集，
      // 这里必须用同一个来源，否则同一个缺号集会被算出两个集号。
      final enriched = tmdb.applyEpisodesToLine(rawLine).line;
      final episodes = _renderEpisodes(rawLine, active: isActive);
      final ordered = _episodesReversed ? episodes.reversed.toList() : episodes;
      cards[rawLine.flag] = tmdb.episodeCardsForEpisodes(
        ordered,
        seasonNumber: seasonNumber,
        includeMetadata: isActive,
        sourceIndices: _sourceEpisodeIndices(
          isActive ? enriched.episodes : rawLine.episodes,
          ordered,
        ),
      );
    }
    return cards;
  }

  /// 渲染当前线路的剧集区（区块头 + 剧集卡片）。
  Widget _buildEpisodes(
    BuildContext context,
    Vod vod,
    List<VodPlayLine> lines,
  ) {
    // 归属门：TMDB 数据不属于本页影片时只按来源集名出卡片（不带任何 TMDB 元数据，
    // 否则会拿到上一部剧的剧照/集标题）。
    final tmdb = _ownedTmdb;
    final rawLine = _activeLine(lines);
    final line = tmdb?.applyEpisodesToLine(rawLine).line ?? rawLine;
    final episodes = _renderEpisodes(rawLine, active: true);
    final ordered = _episodesReversed ? episodes.reversed.toList() : episodes;
    final cards = tmdb == null
        ? TmdbEpisodeCards.build(
            sourceNames: ordered.map((episode) => episode.name).toList(),
            metadataByNumber: const <int, TmdbEpisode>{},
            // 本分支没有 TMDB 元数据可用，缺号集的集号只能按线路位置推断；
            // `ordered` 可能已倒序，用它的下标会让缺号集整体错位，故取原始线路下标。
            sourceIndices: _sourceEpisodeIndices(rawLine.episodes, ordered),
          )
        : tmdb.episodeCardsForEpisodes(
            ordered,
            seasonNumber: tmdb.selectedSeason >= 0
                ? tmdb.selectedSeason
                : null,
            includeMetadata: true,
            // 集号只能按**原始线路**的位置推断：`ordered` 已季度过滤、可能已
            // 倒序，用它的下标会让缺号集的编号整体错位（上游同样用
            // `episodes.indexOf(episode)`）。
            sourceIndices: _sourceEpisodeIndices(line.episodes, ordered),
          );

    // 切季 → 区间回到该季第一集所在区间（`docs/phase6/design/03` §5.1）。
    _resetRangeOnSeasonChange(tmdb);

    // 区间分组（`docs/phase6/design/03` §4.1）。
    //
    // 未手动选过时，区间跟随「用户关注的那一集」：优先历史命中的集，
    // 否则第 0 集——否则用户从历史续播进来会看到第 1 页而当前集在第 4 页。
    final ranges = _rangeLabels(
      ordered,
      EpisodeRangePolicy.build(
        ordered.length,
        _manualRange
            ? _rangeIndex * EpisodeRangePolicy.groupSize(ordered.length)
            : _focusIndex(vod, rawLine, ordered),
        _episodesReversed,
      ),
    );
    final rangeIndex = _manualRange
        ? _rangeIndex.clamp(0, ranges.length - 1)
        : EpisodeRangePolicy.selectedPosition(ranges);

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
          onToggleGridMode: _toggleEpisodeGridMode,
        ),
        // 剧集海报卡片：本线路**唯一**的选集入口（用户反馈 2026-10-08：
        // 有卡片时不再渲染文字版集按钮，二者取其一）。
        // 卡片数量恒等于本线路渲染的集数；未匹配 TMDB 时用来源剧照/海报兑底，
        // 保证「每集都有画面」。
        TmdbEpisodeStrip(
          key: ValueKey('tmdb-episode-strip-${rawLine.flag}'),
          cards: cards,
          keyPrefix: 'tmdb-episode-card-${rawLine.flag}',
          actionLabel: '播放',
          cardWidth: _episodeCardWidth(context, episodes.length),
          gridMode: _episodeGridMode,
          recentIndex: _recentRenderedIndex(vod, rawLine, ordered),
          ranges: ranges,
          rangeIndex: rangeIndex,
          onRangeChanged: (index) => setState(() {
            _rangeIndex = index;
            _manualRange = true;
          }),
          onTap: (index, _) =>
              _playEpisodeAt(vod, rawLine, line, ordered, index),
        ),
      ],
    );
  }

  /// 自动跟随的焦点集在**渲染列表**里的下标。
  ///
  /// 优先「历史命中的那一集」，否则第 0 集。
  int _focusIndex(Vod vod, VodPlayLine rawLine, List<VodEpisode> ordered) {
    if (ordered.isEmpty) return 0;
    final recent = _recentRenderedIndex(vod, rawLine, ordered);
    return recent < 0 ? 0 : recent;
  }

  /// 用**真实集号**修正区间标签（`docs/phase6/design/03` §4.2）。
  ///
  /// 集号可能不连续（缺号、重复号），直接用列表下标会误导
  /// （对齐上游 `buildCardEpisodeRanges` 的标签修正）。
  List<EpisodeRange> _rangeLabels(
    List<VodEpisode> ordered,
    List<EpisodeRange> ranges,
  ) {
    final corrected = <EpisodeRange>[];
    for (final range in ranges) {
      final slice = EpisodeRangePolicy.slice(ordered, range);
      if (slice.isEmpty) {
        corrected.add(range);
        continue;
      }
      final first = _episodeNumberOr(slice.first, ordered, range.start + 1);
      final last = _episodeNumberOr(slice.last, ordered, range.end);
      corrected.add(
        EpisodeRange(
          label: first == last ? '$first' : '$first-$last',
          start: range.start,
          end: range.end,
          selected: range.selected,
        ),
      );
    }
    return corrected;
  }

  /// TMDB 富集的集号；取不到时退回 [fallback]（列表下标 + 1）。
  ///
  /// 复用既有的 [_tmdbEpisodeNumberOf]（它取不到时返回 -1），
  /// 不另写一份重复实现（对齐上游 `numbers.getOrDefault(first, start + 1)`）。
  int _episodeNumberOr(
    VodEpisode episode,
    List<VodEpisode> ordered,
    int fallback,
  ) {
    final number = _tmdbEpisodeNumberOf(episode);
    return number > 0 ? number : fallback;
  }

  /// 切季时把区间回到该季第一集所在区间（`docs/phase6/design/03` §5.1）。
  ///
  /// 用季度序号检测而不是回调链：`build` 会被多次通知触发，回调容易
  /// 在时序上漏掉或多触发。
  void _resetRangeOnSeasonChange(TmdbState? tmdb) {
    final seasonEpoch = tmdb?.seasonEpoch ?? -1;
    if (_lastSeasonEpoch == seasonEpoch) return;
    _lastSeasonEpoch = seasonEpoch;
    _rangeIndex = 0;
    _manualRange = false;
  }

  /// 切换「列表 / 网格」并把新值写回偏好。
  ///
  /// 只改本页状态、不写盘的话，用户的选择活不过一次返回；
  /// `AppState.setEpisodeViewMode` 内部已做归一化与 notify + 落盘。
  void _toggleEpisodeGridMode() {
    final next = !_episodeGridMode;
    setState(() => _episodeGridMode = next);
    unawaited(
      widget.state.setEpisodeViewMode(
        next ? UiEpisodeViewMode.grid : UiEpisodeViewMode.list,
      ),
    );
  }

  /// 导航源选集区：卡片**只**来自 TMDB，站源的集名/集数/顺序一律不参与。
  ///
  /// 卡片 key 前缀另起 `tmdb-episode-card-nav-` 命名空间：既有集成门禁按
  /// `tmdb-episode-card-<线路 flag>-` 前缀数卡来断言「不补集/不丢集」，两条
  /// 路径的口径必须彻底隔开。
  Widget _buildNavSourceEpisodes(BuildContext context, TmdbState? tmdb) {
    // TMDB 未配置 / 未匹配：给一句说明 + 换源入口，**不**回退渲染站源集卡片
    // （用户决策 7：站源没有可播地址，渲染出来只会误导）。
    if (tmdb == null || !tmdb.hasMatch) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('该站点是导航源，只提供索引，不提供可直接播放的剧集。'),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const ValueKey('nav-source-swap-empty'),
            onPressed: _openSourceSwap,
            icon: const Icon(Icons.swap_horiz, size: 16),
            label: const Text('换源'),
          ),
        ],
      );
    }
    if (tmdb.episodesBySeason.isEmpty) {
      // 聚合是**显式触发**的补充加载（`TmdbState` 不会自动调）：本帧先转圈，
      // 聚合到达后 `notifyListeners` 会重建本页。
      _ensureAllSeasonEpisodes(tmdb);
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: LoadingBlock(),
      );
    }
    // 全部季一次性摊平：季号升序、季内集号升序（用户决策 6：铺出 TMDB 全部季
    // 的全部集，不按季分组渲染）。
    final seasons = tmdb.episodesBySeason.keys.toList()..sort();
    final episodes = <TmdbEpisode>[
      for (final season in seasons)
        ...(tmdb.episodesBySeason[season]!.toList()
          ..sort((a, b) => a.number.compareTo(b.number))),
    ];
    final cards = TmdbEpisodeCards.fromMetadata(episodes);
    final ordered = _episodesReversed ? cards.reversed.toList() : cards;
    // 没有季度切换器，也就没有「切季重置区间」；焦点固定在首页区间。
    final ranges = _navRangeLabels(
      ordered,
      EpisodeRangePolicy.build(
        ordered.length,
        _manualRange
            ? _rangeIndex * EpisodeRangePolicy.groupSize(ordered.length)
            : 0,
        _episodesReversed,
      ),
    );
    final rangeIndex = _manualRange
        ? _rangeIndex.clamp(0, ranges.length - 1)
        : EpisodeRangePolicy.selectedPosition(ranges);
    final base = 'nav-${widget.vod.vodId}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TmdbEpisodeHeader(
          episodeCount: cards.length,
          reversed: _episodesReversed,
          gridMode: _episodeGridMode,
          // 没有线路可言：`lineName` 留空（用户决策 4）。
          onToggleReversed: () =>
              setState(() => _episodesReversed = !_episodesReversed),
          onToggleGridMode: _toggleEpisodeGridMode,
        ),
        TmdbEpisodeStrip(
          key: ValueKey('tmdb-episode-strip-$base'),
          cards: ordered,
          keyPrefix: 'tmdb-episode-card-$base',
          actionLabel: '换源播放',
          cardWidth: _episodeCardWidth(context, ordered.length),
          gridMode: _episodeGridMode,
          ranges: ranges,
          rangeIndex: rangeIndex,
          onRangeChanged: (index) => setState(() {
            _rangeIndex = index;
            _manualRange = true;
          }),
          // 全部卡片都可点（用户决策 3）：导航源没有可播地址，点击只是换源的
          // 入口，因此不把任何一张置灰。
          //
          // 「最近播放」标记不传：历史存的是**线路集下标**，卡片是 TMDB 摊平序，
          // 两者不同构，按位置标注会在多季剧上标错卡。
          onTap: (_, card) => unawaited(_showNavSourceSwapDialog(card)),
        ),
      ],
    );
  }

  /// 导航源卡片的区间标签：用卡片自身的 TMDB 集号修正（与 [_rangeLabels] 同一
  /// 目的）。跨季后集号会从 1 重新开始，取不到（`<= 0`）时退回下标口径。
  List<EpisodeRange> _navRangeLabels(
    List<TmdbEpisodeCard> ordered,
    List<EpisodeRange> ranges,
  ) {
    final corrected = <EpisodeRange>[];
    for (final range in ranges) {
      final slice = EpisodeRangePolicy.slice(ordered, range);
      if (slice.isEmpty) {
        corrected.add(range);
        continue;
      }
      final first = _cardNumberOr(slice.first, range.start + 1);
      final last = _cardNumberOr(slice.last, range.end);
      corrected.add(
        EpisodeRange(
          label: first == last ? '$first' : '$first-$last',
          start: range.start,
          end: range.end,
          selected: range.selected,
        ),
      );
    }
    return corrected;
  }

  /// 卡片的 TMDB 集号；解析不出（0）时退回 [fallback]（列表下标口径）。
  int _cardNumberOr(TmdbEpisodeCard card, int fallback) =>
      card.number > 0 ? card.number : fallback;

  /// 触发「按季聚合」，同一代际只触发一次。
  ///
  /// 不在 `build` 里 `await`：聚合要逐季多打几次请求，等它等于让选集区先空着。
  void _ensureAllSeasonEpisodes(TmdbState tmdb) {
    final key = '${tmdb.vodId}#${tmdb.generation}';
    if (key == _aggregateRequestKey) return;
    _aggregateRequestKey = key;
    unawaited(tmdb.ensureAllSeasonEpisodes(generation: tmdb.generation));
  }

  /// 导航源卡片的点击：先弹出「需要换源」说明，确认后才打开换源浮层。
  ///
  /// 卡片不可直接播（用户决策 3）：导航源只提供索引，没有可播地址。这里也**不**
  /// 记忆待续播意图——换源后线路与集都是另一套，按旧下标续播只会播错集。
  Future<void> _showNavSourceSwapDialog(TmdbEpisodeCard card) async {
    // `RepaintBoundary` 的 key 与 [DetailPageState._confirmSwapAfterPlayFailure]
    // 同一约定：每个路由各有自己的 RepaintBoundary，截图证据只能按 key 指这一层。
    final wantsSwap = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => RepaintBoundary(
        key: const ValueKey('nav-source-swap-boundary'),
        child: AlertDialog(
          key: const ValueKey('nav-source-swap'),
          title: const Text('导航源需要换源播放'),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_navEpisodeLabel(card)),
              const SizedBox(height: 6),
              // 说明弱化处理：它是解释「为什么点了不播」的背景，不该和标题抢
              // 注意力（与上面那条换源确认框同一口径）。
              Text(
                '当前站点是导航源，只提供索引，不提供可直接播放的地址。',
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              const Text('换到有播放线路的站点后，选集区即可正常播放。'),
            ],
          ),
          actions: [
            TextButton(
              key: const ValueKey('nav-source-swap-dismiss'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('知道了'),
            ),
            FilledButton(
              key: const ValueKey('nav-source-swap-confirm'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('换源'),
            ),
          ],
        ),
      ),
    );
    // `showDialog` await 之后 context 可能已随页面销毁而失效。
    if (!mounted || wantsSwap != true) return;
    await _openSourceSwap();
  }

  /// 卡片在提示框里的集信息：`S2E5 · 标题`。
  String _navEpisodeLabel(TmdbEpisodeCard card) {
    final code = card.seasonNumber > 0
        ? 'S${card.seasonNumber}E${card.number}'
        : 'E${card.number}';
    return card.title.isEmpty ? code : '$code · ${card.title}';
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
          // 选集视图模式是**全局偏好**：进页面时读出来给初值，页内切换时回调
          // 写回。该页不持有 `AppState`（只有 service/identity/回调），所以按它
          // 既有的依赖注入风格传两个参数，而不是把状态对象塞进去。
          initialViewMode: state.episodeViewMode,
          onViewModeChanged: state.setEpisodeViewMode,
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

/// [_DetailPageState._locateResumeEpisode] 的返回值：命中的下标 + 是否发生了回退。
///
/// 用一个小类而不是 record：本仓库既有代码里没有 record 解构的用法，
/// 而带名字的字段在调用处（读 `hit.index` / `hit.fellBack`）比 `$1`/`$2` 清楚。
class _ResumeLocatorHit {
  const _ResumeLocatorHit(this.index, this.fellBack);

  /// 目标线路里该集的数组下标。
  final int index;

  /// true 表示没找到同一集、已回退到第 1 集（调用方应提示用户）。
  final bool fellBack;
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return EmptyState(title: title, message: message);
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
      message:
          '站点「${site.name}」需要 ${availability.runtimeName} 运行时'
          '${availability.stage == null ? "" : "（计划阶段：${availability.stage}）"}。\n'
          '${availability.reason ?? ""}\n'
          '请在站点列表中选择其他可运行站点。',
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
