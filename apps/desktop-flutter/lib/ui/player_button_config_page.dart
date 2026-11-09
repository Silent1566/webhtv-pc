/// 播放器按钮配置页（`docs/phase8/design/03` §6）。
///
/// 上游依据：`PlayerButtonConfigDialog.java`（可重排列表 + 可见性开关）。
///
/// 入口有两个（`docs/phase8/design/00` §5 第 10 条要求非右键的等价路径）：
/// - 设置页 → 「播放器按钮」；
/// - 播放器右键菜单 → 「控制栏按钮…」。
///
/// ## 与 brief 伪代码的两处偏离（都是修缺陷，不是改版）
///
/// 1. **`buildDefaultDragHandles: false`**。`ReorderableListView` 的默认值是
///    `true`，它在 Windows/Linux/macOS 上会给**每一行再插一个不带 key 的
///    `Icons.drag_handle`**，位置是 `Positioned(end: 8)` + 居右对齐——也就是
///    正好压在 `trailing` 的开关上。那个手柄不带 key，任何 `find.byKey` 断言都
///    抓不到它，但用户在行尾会看到两个手柄、而且行尾那个盖住了开关
///    （`Listener` 不消费手势，所以点击仍能落到开关上，缺陷因此更难被发现）。
///    本页自己已经在 `leading` 放了带 key 的手柄，所以必须显式关掉默认手柄。
/// 2. **自定义 `proxyDecorator`**。默认实现是
///    `Material(elevation: lerpDouble(0, 6, animValue)!)`——拖动时 elevation
///    会从 0 动到 6，直接违反 `DESIGN.md` 的 **The Zero-Elevation Rule**
///    （「全站 `elevation: 0`」「不使用阴影」）。这里改成用**表面阶梯**
///    表达「被拖起的行浮在其它行之上」，elevation 恒为 0。
library;

import 'package:flutter/material.dart';

import '../core/player_buttons.dart';
import '../state/app_state.dart';
import 'tokens.dart';

class PlayerButtonConfigPage extends StatefulWidget {
  const PlayerButtonConfigPage({super.key, required this.state});

  final AppState state;

  @override
  State<PlayerButtonConfigPage> createState() => _PlayerButtonConfigPageState();
}

class _PlayerButtonConfigPageState extends State<PlayerButtonConfigPage> {
  /// 本地顺序副本。
  ///
  /// 为什么不在每次 `build` 里读 `widget.state.playerButtonOrder`：拖动过程中
  /// 每一帧都要一个稳定的列表，而写盘是异步的（`writeSettingsSectionSync` +
  /// 串行队列）。本地副本让拖动**立刻**反映在界面上，落盘在后台完成。
  late List<String> _order;

  @override
  void initState() {
    super.initState();
    _order = List.of(widget.state.playerButtonOrder);
  }

  Set<String> get _hidden => widget.state.playerButtonHidden;

  Map<String, PlayerButtonSpec> get _byId => {
    for (final spec in kPlayerButtons) spec.id: spec,
  };

  Future<void> _persistOrder() async {
    await widget.state.setPlayerButtonOrder(_order);
  }

  Future<void> _toggle(String id, bool visible) async {
    final next = Set<String>.of(_hidden);
    if (visible) {
      next.remove(id);
    } else {
      next.add(id);
    }
    // 先重建再落盘：`AppState` 的隐藏集是**同步**更新的（`rememberButtonHidden`
    // 先改内存、再返回 `_persist()` 的 Future），所以 `setState` 放在 `await`
    // 之前，界面在真实 I/O 完成前就已经反映选择。反过来写（先 await 再
    // `setState`）会让开关在写盘期间保持旧值，并且在 `testWidgets` 的假时钟下
    // 永远等不到那次 `setState`。
    setState(() {});
    await widget.state.setPlayerButtonHidden(next);
  }

  /// 恢复默认**必须二次确认**（`00` §5 第 9 条：「一个『改乱了回不去』的配置是
  /// 不可接受的」）。第一次点击只弹确认框，不碰任何状态。
  Future<void> _confirmReset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复默认'),
        content: const Text('将按钮顺序与显示状态恢复为默认值。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // 与 `_toggle` 同理：`resetPlayerButtons()` 在**同步**阶段就把两个键清掉了
    // （`UiPreferencesStore.resetPlayerButtons` 先置 null、再返回 `_persist()`），
    // 所以界面刷新不能挂在写盘 Future 上——假时钟下那次 `setState` 永远不会到。
    final pending = widget.state.resetPlayerButtons();
    if (!mounted) return;
    setState(() => _order = List.of(widget.state.playerButtonOrder));
    await pending;
  }

  /// 预览行文字。
  ///
  /// 复用 `resolveVisibleButtons`（`core/player_buttons.dart:215`）而不是
  /// 自己再写一遍「按 order 排序 + 按 hidden 过滤」：那段逻辑已经存在，
  /// 而两处实现漂移会让预览行与实际控制栏不一致——预览行的**唯一价值**
  /// 就是「不离开页面也能看到真实结果」。
  ///
  /// 全部隐藏时**不能**回落成空串：全站约束要求 `Text.data` 非空
  /// （空串虽非 null 但同样是无内容占位，且会在遍历 `allWidgets` 取 `.data`
  /// 的测试里被当成缺陷——`phase8_osd_layer_test.dart:329` 是同类先例）。
  String get _previewText {
    final labels = [
      for (final spec in resolveVisibleButtons(order: _order, hidden: _hidden))
        // 外部播放器在没配置播放器时**不会**出现在控制栏
        // （`player_page._buildActionButtons` 的 `when` 分支），预览必须跟着
        // 一起隐藏，否则预览说的是谎话。
        if (spec.id != 'external_player' || widget.state.hasExternalPlayer)
          spec.label,
    ];
    if (labels.isEmpty) return '（已隐藏全部按钮）';
    return labels.join('  ·  ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final byId = _byId;
    return Scaffold(
      appBar: AppBar(title: const Text('播放器按钮')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.lg,
              AppSpace.md,
              AppSpace.lg,
              AppSpace.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '拖动调整顺序，开关控制是否显示。',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: AppSpace.sm),
                // 预览行：不离开页面就能看到结果。
                // 不做真实的控制栏预览——那需要把播放器状态搬进来，成本远超收益。
                Text(
                  _previewText,
                  key: const ValueKey('player-buttons-preview'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            // 外层滚动 + `shrinkWrap`：9 行在 600px 高的测试视口里放不下，
            // 惰性列表只会建出视口内那几行，于是「列出全部 9 个按钮」这类
            // 断言会假失败。`ShrinkWrappingViewport` 给 sliver 无限
            // `remainingPaintExtent`，9 行全部建出来，页面整体滚动。
            child: SingleChildScrollView(
              child: ReorderableListView.builder(
                // 关掉默认手柄：它不带 key、落在行尾并盖住开关（见文件头注释）。
                buildDefaultDragHandles: false,
                // 默认 proxyDecorator 会把 elevation 从 0 动到 6，违反
                // The Zero-Elevation Rule；这里改用表面阶梯表达层级。
                proxyDecorator: (child, index, animation) => Material(
                  elevation: 0,
                  color: theme.colorScheme.surfaceContainerHigh,
                  child: child,
                ),
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
                itemCount: _order.length,
                // 用 `onReorderItem` 而不是已废弃的 `onReorder`：框架在
                // `_handleReorderItem`（`reorderable_list.dart:1022-1025`）里
                // 已经替 `onReorderItem` 做过「移除一项后下标左移」的 -1 调整，
                // 所以这里**直接插入**，再减一次会把行拖到错误位置。
                // `onReorder` 分支（同函数 1017-1020）不做调整，需要调用方自己减。
                onReorderItem: (oldIndex, newIndex) {
                  setState(() {
                    final moved = _order.removeAt(oldIndex);
                    _order.insert(newIndex, moved);
                  });
                  _persistOrder();
                },
                itemBuilder: (context, index) {
                  final id = _order[index];
                  final spec = byId[id];
                  if (spec == null) {
                    return SizedBox.shrink(key: ValueKey('button-row-$id'));
                  }
                  return _row(context, spec, index);
                },
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(AppSpace.lg),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                  key: const ValueKey('player-buttons-reset'),
                  onPressed: _confirmReset,
                  child: const Text('恢复默认'),
                ),
                const SizedBox(width: AppSpace.sm),
                FilledButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('完成'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 行副标题：分组名，外加「这一项当前为什么不在控制栏里」的实情。
  ///
  /// 外部播放器没配置时控制栏不渲染它，但这一行的开关照常可拨——不讲清楚
  /// 的话，用户拨完回播放器找不到按钮，只会以为开关坏了。
  String _subtitleFor(PlayerButtonSpec spec) {
    if (spec.id == 'external_player' && !widget.state.hasExternalPlayer) {
      return '${spec.group.label} · 未配置播放器，暂不显示';
    }
    return spec.group.label;
  }

  Widget _row(BuildContext context, PlayerButtonSpec spec, int index) {    final theme = Theme.of(context);
    final visible = !_hidden.contains(spec.id);
    return ListTile(
      key: ValueKey('button-row-${spec.id}'),
      leading: ReorderableDragStartListener(
        index: index,
        child: Icon(
          Icons.drag_handle,
          key: ValueKey('button-handle-${spec.id}'),
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      title: Text(spec.label),
      subtitle: Text(
        _subtitleFor(spec),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: Switch(
        key: ValueKey('button-visible-${spec.id}'),
        value: visible,
        onChanged: (value) => _toggle(spec.id, value),
      ),
    );
  }
}
