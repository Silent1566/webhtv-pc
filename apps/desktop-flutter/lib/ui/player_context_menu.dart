/// 播放器右键菜单（`docs/phase8/design/04`）。
///
/// ## 为什么不用 `showMenu` / `MenuAnchor`（进 `Navigator` 的 `Overlay`）
///
/// 本项目的截图 harness（`integration_test/ui_redesign_visual_flow_test.dart:71-99`）
/// 取树中**第一个 `RepaintBoundary`**（`Scaffold` 那层）。`Overlay` 里的浮层
/// **拍不到**——该文件已在两处记录过这个限制（`:584-587` 的筛选面板、
/// `:708-711` 的播放器溢出菜单），并明确写了「不拿重复的图冒充新证据」。
///
/// 因此本菜单实现为**页内 `Stack` 子层**：它在 `Scaffold` 的 `RepaintBoundary`
/// 内，harness 能拍到**真实渲染**的菜单，也能断言它的矩形。
///
/// 代价是要自己实现「点外关闭」与「Esc 关闭」。两者都在 `player_page.dart` 里
/// （`design/04` §5.3：全屏透明遮罩是菜单层的**兄弟**、`Esc` 用内层
/// `CallbackShortcuts` 盖住全局的 `exitFullscreen`），远小于「拿不到视觉证据」的代价。
///
/// ## 坐标空间
///
/// [PlayerContextMenu.anchor] 必须是**父 `Stack` 的坐标**（不是屏幕坐标）。
/// 在 `Scaffold(appBar: null, body: Stack(...))` 里两者相同，因为 Windows 桌面
/// 全屏播放器的 body 原点就是窗口原点。`viewport` 同理（`MediaQuery.sizeOf`）。
///
/// ## 飞出式多列（本层为什么不只是一个菜单框）
///
/// 子菜单**不就地展开**，而是从父项右缘飞出一列新菜单，子列里还能再飞出一列
/// （PotPlayer 形态，深度不设上限）。这带来一个结构性问题：父 `Stack` 的一个
/// child 只能产出一个 widget，而第 2..N 列必须和父 `Stack` 的坐标空间对齐。
///
/// 试过的两种省事办法都不行：
/// 1. 把子列塞进父列的 `Stack`：`RenderBox.hitTest` 先判
///    `size.contains(position)`，画在父框外的子列**画得出来但点不到**；
///    `OverflowBox`/`Transform` 只改绘制不改命中范围，同样点不到。
/// 2. 用一个包住所有列的包围盒 `Positioned`：列高由内容决定，包围盒算不准；
///    一旦某列被竖直方向夹到父列上方便越界，又回到问题 1。
///
/// 所以顶层返回 `Positioned.fill`——仍然是 `Positioned`、仍然在页内 `Stack` 里
/// （截图 harness 照旧拍得到），只是把「全窗口大小的坐标底板」交给各列自己摆。
/// 命中的穿透性由 `RenderStack.hitTestSelf == false` 保证：点在列外时事件穿到
/// 兄弟层的全屏遮罩上，「点外关闭」不受影响。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// 菜单宽度（`design/04` §5.6：240，与 `DESIGN.md` 的对话框量级一致）。
const double _menuWidth = 240;

/// 项高（`design/04` §5.6：36，桌面密度）。
const double _itemHeight = 36;

/// clamp 用的菜单高度估值（`design/04` §5.2）。
///
/// 设计文档写明这是估算值、应由 `LayoutBuilder` 实测。这里保留估值只用来推算
/// **左上角**（菜单最终多高取决于内容，见 [_PlayerContextMenuState.build]），
/// 同时把「真实高度」交给布局约束：菜单高度上限是 `视口高 - 左上角 - 边距`。
/// 两者合起来保证 **菜单永远整块落在窗口内**：估值偏小只会让菜单更早开始
/// 内部滚动，不会让它伸出窗口下沿——这正是 `design/04` §5.2 要防的那个
/// 「右下角右键 → 部分项不可点」缺陷。
const double _estimatedMenuHeight = 420;

/// 菜单与窗口边缘的最小留白（`design/04` §5.2 的 `8`）。
const double _viewportMargin = AppSpace.sm;

/// 相邻两列的水平间隙。
///
/// 取 0：子列紧贴父列边缘，两列的发丝边并成一条视觉分界；留出间隙会在两级
/// 之间露出底图，反而像两块不相干的浮动面板。
const double _columnGap = 0;

/// 子列被竖直方向夹住时仍要保留的最低可用高度（3 项）。
///
/// 只按「行顶边以下的空间」给上限，靠近窗口下沿的父项会把子列压成一条缝
/// （600px 高窗口里的最后一项只剩 30px）——列几乎不可读，还滚不出内容。
/// 夹到「还剩 3 项」为止，剩下的高度交给列内滚动。
const double _minColumnViewport = _itemHeight * 3;

/// 飞出层数上限。
///
/// 列是从**展开路径**迭代推导出来的（不是递归渲染同一棵树），所以这里防的不是
/// 递归爆栈，而是「数据或状态写错导致要摆出成百上千列」：超过就停下并断言。
const int _maxFlyoutDepth = 8;

/// 分组行（第 1 列里代表一个分组的父项）的 id 前缀，合成 id 形如
/// `section:速度`。
///
/// 分进独立命名空间是为了两点：`player_page.dart` 的项 id 全是 `rate_1.0` /
/// `sub_size` 这类下划线风格，冒号前缀撞不上；而测试可以用一句
/// `player-menu-item-section:*` 把「主列全是分组行」精确断言出来。
const String _sectionIdPrefix = 'section:';

/// 悬停离开「正弹出子列的那一行」后，延迟多久才真的收起那一列。
///
/// **为什么收起必须延迟**：鼠标从父项沿斜线移向刚飞出的子列时，会先离开父项的
/// 行、再进入子列，中途必然经过一段**不属于任何列**的区域（两列顶边对齐只是
/// 理想情况：子列可能因为竖直夹取整体上移，父列也可能正在滚动，行与列之间还
/// 有四像素的内边距）。立即收起会让子列在指针到达之前就消失——用户永远点不到
/// 子项，这是悬停式飞出菜单最经典的缺陷。
///
/// **为什么不能无限期保持**：指针早已离开菜单、子列还挂在画面上挡住视频，
/// 而且下一层的判断会一直基于过期的展开路径。
///
/// 200ms 的取舍：长于一次斜向穿越（够指针从父项走到子列），短于人「看清单个
/// 菜单项再决定」的时间（不会在用户已经改主意时还赖着）。
const Duration _collapseDelay = Duration(milliseconds: 200);

/// 菜单里的一项。
class PlayerMenuItem {
  const PlayerMenuItem({
    required this.id,
    required this.label,
    this.icon,
    this.selected = false,
    this.enabled = true,
    this.children = const [],
    this.onSelect,
  });

  final String id;
  final String label;
  final IconData? icon;

  /// 当前生效的项（当前倍速 / 当前画面模式 / 已开启的屏显项）。
  ///
  /// **必须可见**：这是隐藏式菜单最容易丢的信息
  /// （`DESIGN.md` 关于筛选面板的同类教训：「必须显示已生效」）。
  final bool selected;

  final bool enabled;

  /// 非空表示点它会在右侧**飞出一列**子菜单（子列里还能再飞出，深度不设上限）。
  ///
  /// 起飞出式而不是就地展开（更早的版本是就地展开、且只允许一级）：就地展开
  /// 只有 240 宽，多一层缩进就没有可读空间；屏显那 7 个开关也已经把主列撑到
  /// 需要滚动，状态一多就看不到「已开启的是哪几个」。
  /// 飞出式的两个经典难题在这里这样处理：
  /// 1. **飞出后超出窗口**：每一列独立 clamp，右缘放不下就翻到父列左侧；
  /// 2. **鼠标斜向移动丢失 hover**：悬停即展开（PotPlayer 行为），但**收起
  ///    带 [_collapseDelay] 延迟**——见该常量的注释（斜线穿越空白区）。
  ///
  /// 展开**同时**接受悬停与点击两种入口（见 [_row]）：
  /// - 悬停是桌面播放器的肌肉记忆，用户不该为了看一眼子菜单而先点一下；
  /// - 点击仍必须可用：键盘（未来的回车/空格）、触屏、以及「我就想用鼠标点」
  ///   的用户都不能被剥夺入口，而且点击是唯一的**收起**手段（悬停本身没有
  ///   「离开」的对称动作）。
  final List<PlayerMenuItem> children;

  final VoidCallback? onSelect;
}

/// 菜单的一个分组。
class PlayerMenuSection {
  const PlayerMenuSection({required this.title, required this.items});

  final String title;
  final List<PlayerMenuItem> items;
}

/// 把菜单左上角约束在窗口内（`docs/phase8/design/04` §5.2）。
///
/// 为什么必须 clamp：在画面右下角右键，菜单会溢出窗口、部分项不可点——
/// 这是桌面菜单的经典缺陷。
///
/// 菜单比窗口还大时**贴左上角留白**而不是抛异常：`num.clamp` 在
/// `lowerLimit > upperLimit` 时会断言失败（debug 下直接抛），
/// 而「窗口比菜单还小」是真实存在的（窄窗口、用户把窗口拖到很矮）。
Offset clampMenuOrigin({
  required Offset anchor,
  required Size viewport,
  required Size menuSize,
}) {
  final maxX = viewport.width - menuSize.width - _viewportMargin;
  final maxY = viewport.height - menuSize.height - _viewportMargin;
  return Offset(
    _clampStart(anchor.dx, maxX),
    _clampStart(anchor.dy, maxY),
  );
}

/// 单个轴上的 clamp：可用空间不足一个留白时退回留白本身。
double _clampStart(double value, double maxStart) =>
    maxStart <= _viewportMargin ? _viewportMargin : value.clamp(_viewportMargin, maxStart);

/// 右键菜单。
///
/// **返回的是一个 `Positioned`**：调用方必须把它直接放进**页内 `Stack`**
/// （`design/04` §3.3 的第 4 层），不要放进 `Column`，也不要指望它自建浮层。
///
/// 菜单层由两个兄弟组成（见 `player_page.dart`）：
/// 1. `Positioned.fill` + `GestureDetector(onTap: 关闭)`：点外关闭；
/// 2. 本 widget：菜单本体（第 1 列，以及它飞出的所有子列）。
///
/// 所以 [onDismiss] 由**调用方**持有：本 widget 不吞指针也不抢焦点
/// （`design/04` §5.3、§5.1 要求菜单打开时右键仍能移动菜单，那需要页面层的
/// `onSecondaryTapDown` 还能收到事件，全屏遮罩不能由菜单本体自己铺）。
class PlayerContextMenu extends StatefulWidget {
  const PlayerContextMenu({
    super.key,
    required this.anchor,
    required this.viewport,
    required this.sections,
    required this.onDismiss,
  });

  /// 菜单左上角的期望位置（父 `Stack` 坐标，通常是右键的 `globalPosition`）。
  ///
  /// 会被 [clampMenuOrigin] 拉回窗口内。
  final Offset anchor;

  /// 窗口尺寸（`MediaQuery.sizeOf(context)`），用于 clamp 与高度上限。
  final Size viewport;

  final List<PlayerMenuSection> sections;

  /// 菜单关闭回调。
  ///
  /// **本 widget 目前不调用它**：点外关闭由调用方的全屏遮罩完成，`Esc` 由
  /// 调用方的内层 `CallbackShortcuts` 完成（`design/04` §5.3）。保留这个参数
  /// 是为了让菜单层的「关闭」只有一个入口——菜单层要加其它关闭途径
  /// （例如未来的键盘导航取消）时不必再改调用方签名。
  final VoidCallback onDismiss;

  @override
  State<PlayerContextMenu> createState() => _PlayerContextMenuState();
}

class _PlayerContextMenuState extends State<PlayerContextMenu> {
  /// 展开路径：`_openIds[k]` 是**第 k+1 列**里那个正弹出下一列的项的 id。
  ///
  /// 用一个「路径」而不是「已展开 id 的集合」：飞出式菜单里「三列同时开着但彼此
  /// 无关」是不可能的形状（第 3 列只能由第 2 列的某个项弹出），集合会允许这种
  /// 非法状态存在，路径直接从结构上排除它。
  final List<String> _openIds = [];

  /// 可展开项（有 `children` 的行）实测的行顶边，键是 [_rowKeyOf]。
  ///
  /// 为什么必须实测而不是算：子列顶边要贴父项的**行顶边**，而行顶边取决于
  /// 分组标题的高度、字体行高和父列此刻的滚动偏移——算出来的一定会和真实
  /// 布局差几像素，滚动后差得更多。用 `GlobalKey` 在帧后量真值。
  final Map<String, double> _rowTops = {};
  final Map<String, GlobalKey> _rowKeys = {};

  final GlobalKey _rootKey = GlobalKey();
  bool _measureScheduled = false;

  /// 待执行的「延迟收起」。
  ///
  /// 只有一个：本菜单任意时刻最多有一条展开路径（[_openIds]），所以也最多只有
  /// 一个「刚离开、可能还要撤销」的层级。新的一次离开直接覆盖旧的，不必排队。
  Timer? _collapseTimer;

  @override
  void dispose() {
    // 必须显式取消：定时器回调里会 setState，页面销毁后触发就是
    // 「setState() called after dispose()」。而「指针离开父项」常常就是菜单被
    // 关掉的原因，这条路径在真实使用里非常容易走到。
    _collapseTimer?.cancel();
    super.dispose();
  }

  /// 撤销待执行的收起（指针又回到了展开链路上）。
  void _cancelCollapse() {
    _collapseTimer?.cancel();
    _collapseTimer = null;
  }

  /// 悬停到第 [level] 列里带子列的行：展开它，并砍掉更深的后代链。
  void _hoverOpen(PlayerMenuItem item, int level) {
    // 先掐掉上一个父项排下的收起计时器：否则刚展开的列会在这段延迟里被别人
    // 的计时器收掉。
    _cancelCollapse();
    final isOpen = _openIds.length > level && _openIds[level] == item.id;
    // 已经展开就什么都不做。**不能当开关用**：悬停没有「第二次进入」这种动作，
    // 每次 onEnter 都 toggle 会让指针只在行内抖动就把子列收掉。收起由
    // 「离开这一行」的延迟、或再点一下这一行负责。
    if (isOpen) return;
    setState(() {
      // 同层换支时砍掉整条旧分支：展开路径必须始终是一条单链
      // （[_openIds] 的注释说明了为什么不允许「两列同时开着但彼此无关」）。
      _openIds.removeRange(level, _openIds.length);
      _openIds.add(item.id);
    });
  }

  /// 指针离开第 [level] 列里带子列的行：排一次延迟收起。
  void _scheduleCollapse(PlayerMenuItem item, int level) {
    _cancelCollapse();
    _collapseTimer = Timer(_collapseDelay, () {
      _collapseTimer = null;
      if (!mounted) return;
      // 到点后重新校验，不直接收：这 200ms 里指针可能已经进了子列（子列里的
      // 行会调 [_cancelCollapse]），也可能这一行早已不是展开路径上的那一项。
      // 只有「这一行仍然恰好是第 level 号展开项」才真的收，否则收的是别人。
      final stillOpen = _openIds.length > level && _openIds[level] == item.id;
      if (!stillOpen) return;
      setState(() {
        _openIds.removeRange(level, _openIds.length);
      });
    });
  }

  /// 菜单宽度：窗口比 240 还窄时收窄，保证整块在窗口内（`design/04` §5.2）。
  ///
  /// 所有列同宽：收窄是「窗口装不下 240」时的降级，各列各自收窄只会让子列比
  /// 父列更窄、读起来更碎。
  double get _width => math.min(
    _menuWidth,
    math.max(0, widget.viewport.width - 2 * _viewportMargin),
  );

  @override
  Widget build(BuildContext context) {
    final width = _width;
    final origin = clampMenuOrigin(
      anchor: widget.anchor,
      viewport: widget.viewport,
      menuSize: Size(width, _estimatedMenuHeight),
    );
    final levels = _visibleLevels();

    final columns = <Widget>[];
    var columnLeft = origin.dx;
    var columnTop = origin.dy;
    for (var level = 0; level < levels.length; level++) {
      if (level > 0) {
        final parentId = _openIds[level - 1];
        columnLeft = _childColumnLeft(columnLeft, width);
        // 量不到（首帧这一行还没被测量）就先贴父列顶边，下一帧校正。
        columnTop = _childColumnTop(
          _rowTops[_rowKeyOf(level - 1, parentId)] ?? columnTop,
        );
      }
      // 每列高度上限 = 该列左上角以下的可用空间。和主列同一条理由：只按视口高
      // 给上限时，左上角偏下的列会伸到窗口外沿且滚不到。
      final maxHeight = math.max(
        0.0,
        widget.viewport.height - columnTop - _viewportMargin,
      );
      columns.add(
        _column(
          level: level,
          left: columnLeft,
          top: columnTop,
          maxHeight: maxHeight,
          items: levels[level],
        ),
      );
    }

    if (_rowKeys.isNotEmpty) _scheduleMeasure();

    // 全窗口大小的坐标底板，各列用 `Positioned` 自己摆（理由见库注释）。
    return Positioned.fill(
      child: Stack(key: _rootKey, children: columns),
    );
  }

  /// 从展开路径推导出每一列的项：**第 1 列是十个分组行**，其后每列是上一路径项的孩子。
  ///
  /// ## 为什么第 1 列是「分组行」而不是各组的项
  ///
  /// 用户反馈原话：「速度下的选项没有收到子菜单中，还有其他的设置也有类似问题」。
  /// 旧实现里分组标题只是一个静态的 `Padding + Text`（那个 `_sectionTitle` 已随本
  /// 改动删除），于是**每一组的项都摊在主列里**：播放 6 + 速度 6 + 字幕 4 + 画面 2 + 声音 3 + 轨道 5 + 显示 2 +
  /// 片头片尾 7 + 信息 3 + 设置 5 = 43 个叶子项。按 36px 项高是 1548px，720px
  /// 高的窗口里主列要滚四屏——「速度」被压在滚不出去的列表中间，用户看到的就是
  /// 「6 个档位平铺在主列里」，而不是「速度」这一项该有的子菜单。
  ///
  /// PotPlayer 的形状是：顶层只有十个带 `▸` 的组，点/悬停才飞出该组的项，组内
  /// 项自己带 `children` 时继续往下飞。主列因此从 43 行降到 **10 行（368px）**，
  /// 一屏放得下——这同时是「已生效状态必须可见」的前提：主列塞满滚动区时，
  /// 下半部分的分组（片头片尾/信息/设置）用户根本看不到。
  ///
  /// ## 分组行不显 `selected` 勾
  ///
  /// 分组是**容器**，不是状态项：勾号的含义是「这一项就是当前生效值」
  /// （见 [PlayerMenuItem.selected]）。给分组打勾会同时出现两个歧义——
  /// 「勾的是整组吗」和「十个分组里有几个被打勾」，而动宾关系其实属于组内的
  /// **叶子**（例如「速度」组里被勾的是 `1.0×`）。所以勾只留在叶子行上，
  /// 由 [_sectionRows] 造出的分组行恒为 `selected: false`。
  List<List<PlayerMenuItem>> _visibleLevels() {
    final levels = <List<PlayerMenuItem>>[
      _sectionRows(),
    ];
    for (var i = 0; i < _openIds.length; i++) {
      final parent = _findById(levels[i], _openIds[i]);
      if (parent == null || parent.children.isEmpty) {
        // 分组被重建后 id 可能不再存在：把断掉的那一段路径连同它后面的列一起
        // 丢掉。这里直接改状态（不 setState）是安全的——同一次 build 用的就是
        // 截断后的结果。
        _openIds.removeRange(i, _openIds.length);
        break;
      }
      if (levels.length >= _maxFlyoutDepth) {
        assert(
          false,
          '右键菜单飞出层数超过 $_maxFlyoutDepth：展开路径 '
          '${_openIds.join(' > ')} 不合法（player_context_menu.dart）',
        );
        break;
      }
      levels.add(parent.children);
    }
    return levels;
  }

  /// 把每个分组包装成第 1 列里的**一个可飞出父项**。
  ///
  /// 合成项的 id 由标题派生（`section:<title>`）：[PlayerContextMenu.sections]
  /// 是每次 build 重建的对象（`player_page.dart` 的 `_contextMenuSections()`），
  /// 没有稳定 id 可用，而展开路径 [_openIds] 必须靠 id 跨帧记住「展开的是哪一组」。
  ///
  /// `children` 直接就是该组的 items（**不复制**）：组内项自己带 `children` 时
  /// 走的是同一套飞出机制，分组行不引入第二套下钻规则。
  ///
  /// [PlayerMenuItem.onSelect] 留空：带 `children` 的行在 [_row] 的 `onTap` 里
  /// 只做展开/收起，永远不执行动作，所以这里给不出也不该给出回调。
  List<PlayerMenuItem> _sectionRows() {
    final rows = [
      for (final section in widget.sections)
        PlayerMenuItem(
          id: '$_sectionIdPrefix${section.title}',
          label: section.title,
          children: section.items,
        ),
    ];
    // 分组 id 由标题派生，标题重复会在同一列里出现两个同 key 的行（Flutter 会
    // 直接抛「Duplicate keys」）。与其让用户看到一条难懂的框架异常，不如在这里
    // 说清楚原因；**不做静默去重**——两组合并会悄悄吞掉其中一组的项。
    assert(
      rows.map((row) => row.id).toSet().length == rows.length,
      '右键菜单的分组标题重复了：${widget.sections.map((s) => s.title).join(" / ")}'
      '（分组行的 id 由标题派生，标题必须唯一）',
    );
    return rows;
  }

  static PlayerMenuItem? _findById(List<PlayerMenuItem> items, String id) {
    for (final item in items) {
      if (item.id == id) return item;
    }
    return null;
  }

  String _rowKeyOf(int level, String itemId) => '$level/$itemId';

  GlobalKey _rowKey(int level, String itemId) =>
      _rowKeys.putIfAbsent(_rowKeyOf(level, itemId), GlobalKey.new);

  /// 第 N 列的左缘（N >= 2）：默认贴父列右缘，放不下就翻到父列左侧。
  double _childColumnLeft(double parentLeft, double width) {
    final maxLeft = widget.viewport.width - width - _viewportMargin;
    final flyoutLeft = parentLeft + width + _columnGap;
    final preferred = flyoutLeft > maxLeft
        ? parentLeft - width - _columnGap
        : flyoutLeft;
    // 翻到左侧仍越界（窄窗口）时退回留白——和主列同一条降级规则。
    return _clampStart(preferred, maxLeft);
  }

  /// 第 N 列的顶边：贴父项行顶边，但不许整列伸出窗口。
  double _childColumnTop(double rowTop) {
    // 上移的下限是「还剩下 [_minColumnViewport] 的可用高度」：再往下就会把子列
    // 压成一条缝。
    final maxTop = widget.viewport.height - _viewportMargin - _minColumnViewport;
    return _clampStart(rowTop, maxTop);
  }

  /// 一列。每列都是**独立的** `Column`，不从同一棵树递归渲染。
  Widget _column({
    required int level,
    required double left,
    required double top,
    required double maxHeight,
    required List<PlayerMenuItem> items,
  }) {
    final theme = Theme.of(context);
    return Positioned(
      left: left,
      top: top,
      width: _width,
      child: MouseRegion(
        // 进入**任意一列**就撤销待执行的收起。这是斜向容错闭环的另一半：
        // 行级 `onExit` 排下延迟后，指针只要落进子列（或退回父列）就作废它，
        // 否则用户刚把指针挪到子项上，子列就被 200ms 的计时器收掉了。
        //
        // 只做「撤销」不排「收起」：离开子列不收列是**既有且不变**的行为
        // （点击驱动的旧实现同样只在点击时改状态），关闭菜单仍由调用方的全屏
        // 遮罩负责（见 [PlayerContextMenu.onDismiss]）。
        onEnter: (_) => _cancelCollapse(),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Material(
            // elevation 0 + 无阴影：`DESIGN.md` 的 The Zero-Elevation Rule。
            // 层级靠更亮的表面 + 发丝边表达，不靠投影。
            elevation: 0,
            color: AppPalette.nightSurface3.withValues(alpha: 0.96),
            // 发丝边画在 `shape` 上而不是另包一层 `DecoratedBox`。
            //
            // 如实说明：**这不是在修一个视觉缺陷**。实测两种写法在相同整数偏移下
            // 渲染结果逐像素相同（115200 个通道无一不同，边缘均为 `(35,43,69)`），
            // 所以我先前的「会被裁成半像素」猜想是**错的**。
            //
            // 保留 `shape` 的真实理由是可断言性：圆角、边宽、边色变成
            // `Material.shape` 上可直接读的属性，测试不必去翻内层 `DecoratedBox`。
            // （`BorderSide` 默认 `strokeAlignInside = -1.0`，边落在内测。）
            // `DESIGN.md` The Hairline Rule。
            shape: RoundedRectangleBorder(
              borderRadius: AppRadius.mdAll,
              side: BorderSide(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.72),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: NotificationListener<ScrollNotification>(
              // 父列滚动后行顶边会变，子列必须跟着走；滚动通知在布局阶段发出，
              // 只能排到帧后再量。
              onNotification: (_) {
                _scheduleMeasure();
                return false;
              },
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  // 每一列都只渲染 [items]：分组标题不再是「标题 + 摊平的项」，
                  // 而是第 1 列里的一行（见 [_visibleLevels]）。这里不再需要按
                  // level 分支——第 2..N 列本来就是这个形状。
                  children: [for (final item in items) _row(item, level)],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(PlayerMenuItem item, int level) {
    final theme = Theme.of(context);
    final semantic = context.semanticColors;
    final hasChildren = item.children.isNotEmpty;
    final isOpen = _openIds.length > level && _openIds[level] == item.id;
    // 第 1 列的分组行多画一个**轻量状态提示点**：组内只要有一个叶子是
    // `selected`（当前倍速 / 已开启的屏显项 / 正在循环…）就点一个 6px 的点。
    //
    // **为什么需要**：分组行本身不显示勾（理由见 [_visibleLevels]），收起状态下
    // 「速度组里勾的是 1.0×」「屏显已经开了四项」这类信息就完全不可见了——而
    // `DESIGN.md` 的「必须显示已生效」正是就此而立。提示点是最小投影：不占
    // 标签空间、不改行高，也和勾号不会混淆（勾号的含义是「这一项就是当前值」）。
    //
    // 为什么只查**一层**孩子、不递归：容器里还套容器时（字幕样式 → 字号），
    // 深层状态由用户真正展开那一列去看；递归会让几乎每个分组都亮起来，
    // 提示反而失去区分力。
    final hasEffectiveChild =
        level == 0 && item.children.any((child) => child.selected);
    // 选中态用星等琥珀前景，其余用 onSurface。
    //
    // **禁用不能抹掉选中态**（`DESIGN.md:373`：「禁用只降低强调，不能抹掉状态」；
    // 该条来自一次真实用户反馈——把 `onTap == null` 一律当成静态标签，
    // 导致整排控件「长得一模一样且点不动」）。
    // 所以「选中 + 禁用」是**把琥珀压暗**而不是换成中性灰：
    // 仍能看出「这一项是选中的，只是现在不可用」。
    // 「未选中 + 禁用」没有状态要保留，沿用原来的 onSurfaceVariant @ 0.5。
    final color = item.selected
        ? (item.enabled
              ? semantic.magnitude
              : semantic.magnitude.withValues(alpha: 0.5))
        : (item.enabled
              ? theme.colorScheme.onSurface
              : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5));

    final row = InkWell(
      key: ValueKey('player-menu-item-${item.id}'),
      onTap: !item.enabled
          ? null
          : () {
              if (hasChildren) {
                // 带子列的项本身不发动作：否则「飞出」和「执行」会撞在同一次
                // 点击上（`design/04` §5.5）。
                setState(() {
                  final wasOpen = isOpen;
                  // 无论开还是关，先砍掉本层及更深的所有列：点父项关掉它弹出的
                  // 整条后代链，点同层另一个父项也不许留下上一支的深层列。
                  _openIds.removeRange(level, _openIds.length);
                  if (!wasOpen) _openIds.add(item.id);
                });
                return;
              }
              item.onSelect?.call();
            },
      child: SizedBox(
        height: _itemHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
          child: Row(
            children: [
              if (item.icon != null) ...[
                Icon(item.icon, size: 18, color: color),
                const SizedBox(width: AppSpace.sm),
              ],
              Expanded(
                child: Text(
                  item.label,
                  style: theme.textTheme.bodyMedium?.copyWith(color: color),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (item.selected)
                Icon(Icons.check, size: 16, color: semantic.magnitude),
              if (hasEffectiveChild)
                Padding(
                  padding: const EdgeInsets.only(left: AppSpace.xs),
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: semantic.magnitude,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              if (hasChildren)
                // 飞出式的方向指示：子列在右侧。
                Icon(Icons.chevron_right, size: 16, color: color),
            ],
          ),
        ),
      ),
    );
    // 悬停只挂在「带子列」的行上。
    //
    // 叶子项**不挂** `MouseRegion`：指针划过菜单不该让任何状态变化（尤其不该
    // 把别人刚飞出的子列收掉）；叶子项只在点击时执行 `onSelect`。
    //
    // **第 1 列的分组行没有另写一套悬停**：它们由 [_sectionRows] 造出来时就带着
    // `children`（整组的项），所以 `hasChildren` 为真，走的是和「屏显」「画面
    // 比例」完全相同的这一条分支——同一个 `MouseRegion`、同一个 [_hoverOpen] /
    // [_scheduleCollapse]、同一个 [_collapseDelay]。分组只是「第 1 列里恰好
    // 每行都带 children」的普通父项，没有第二套展开机制。
    //
    // `onEnter` 即展开：这是桌面播放器的肌肉记忆，不该为了看一眼子菜单先点
    // 一下。`onExit` 只是**排一次延迟收起**，绝不立即收——理由见
    // [_collapseDelay] 的注释（斜线移向子列必然经过不属于任何列的空白区）。
    //
    // 点击路径（上面的 `onTap`）**保留**：它是唯一的收起手段（悬停没有对称的
    // 「离开」动作），也是键盘/触屏用户的唯一入口。两者互不冲突——`onTap` 里
    // 重新读 `isOpen` 而不是用悬停留下的中间状态。
    //
    // 测量键挂在 `MouseRegion` 外面（不是里面）：量的是同一块矩形，且
    // `KeyedSubtree` 仍是 `_rowTops` 取坐标的那一层。
    return hasChildren
        ? KeyedSubtree(
            key: _rowKey(level, item.id),
            child: MouseRegion(
              onEnter: (_) => _hoverOpen(item, level),
              onExit: (_) => _scheduleCollapse(item, level),
              child: row,
            ),
          )
        // 其余行的顶边没人用，不挂测量键。
        : row;
  }

  /// 帧后量一次可展开项的行顶边（[_rowTops] 的注释说明了为什么量）。
  void _scheduleMeasure() {
    if (_measureScheduled) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      if (!mounted) return;
      _measureRowTops();
    });
  }

  void _measureRowTops() {
    final rootBox = _rootKey.currentContext?.findRenderObject() as RenderBox?;
    if (rootBox == null || !rootBox.hasSize) return;
    final next = <String, double>{};
    for (final entry in _rowKeys.entries) {
      final box = entry.value.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      // 相对根底板取坐标：滚动偏移由 localToGlobal 自动带进来。
      next[entry.key] = box.localToGlobal(Offset.zero, ancestor: rootBox).dy;
    }
    final changed =
        next.length != _rowTops.length ||
        next.entries.any((e) => _rowTops[e.key] != e.value);
    if (!changed) return;
    setState(() {
      _rowTops
        ..clear()
        ..addAll(next);
    });
  }
}
