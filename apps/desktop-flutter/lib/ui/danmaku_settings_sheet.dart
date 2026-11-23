/// 播放器里的「页签式弹幕设置弹层」。
///
/// 为什么不是把整页搬进弹层：整页同时承担弹幕库管理与全部显示参数，一屏放不
/// 下；这里放用户看着画面时最常改的显示字段、以及本集弹幕源的即时切换，
/// 弹幕库的增删改仍回整页。四页签把「显示 / 时间 / 轨道 / 弹幕源」分开，
/// 弹层高度受限时内部滚动，不挤压播放器。
///
/// 为什么没有「应用」按钮：每一处修改先更新本层状态再立即回调，播放器拿到
/// 新样式就重绘并落盘——调字号时眼睛盯着画面，退一步才看到结果就没意义了。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/danmaku_style.dart';
import '../core/protocol.dart';
import 'tokens.dart';

/// 弹层关闭后要播放器做的事。
///
/// 返回值只表达「下一步」，不表达「弹层里改了什么」：显示项已经通过
/// [DanmakuSettingsSheet.onChanged] 即时生效，源切换也已经在弹层内完成。
enum DanmakuSheetAction { closed, openFullPage, openSearch }

/// 弹层展示的本集弹幕源快照。
///
/// 为什么由播放器传进来而不是弹层自己去 state 里翻：播放器才知道本集实际
/// 用的是 _request.danmaku、当前地址和最近一次错误；弹层只是这份事实的
/// 一次可编辑投影。
class DanmakuSourceView {
  const DanmakuSourceView({
    this.sources = const <DanmakuSource>[],
    this.currentUrl,
    this.itemCount = 0,
    this.error,
    this.libraryUrl,
    this.libraryTotal = 0,
  });

  final List<DanmakuSource> sources;
  final String? currentUrl;
  final int itemCount;
  final String? error;
  final String? libraryUrl;
  final int libraryTotal;
}

/// 选择一条弹幕源后的结果；字段口径与 [DanmakuSourceView] 一致。
class DanmakuSourceLoadOutcome {
  const DanmakuSourceLoadOutcome({
    required this.ok,
    this.currentUrl,
    this.itemCount = 0,
    this.error,
    this.statusText,
  });

  final bool ok;
  final String? currentUrl;
  final int itemCount;
  final String? error;
  final String? statusText;
}

/// 弹层最大宽度：桌面窗口很宽时，让滑块与标签保持可读的一行长度。
const double _sheetMaxWidth = 720;

/// 弹层最大高度：预留出播放器画面与拖拽把手，内容超出时内部滚动。
const double _sheetMaxHeight = 620;

/// 打开弹幕设置弹层；返回用户下一步要去的页面或 [DanmakuSheetAction.closed]。
///
/// 直接关掉弹层（遮罩、返回键、拖拽）都是 closed，不额外跳页。
Future<DanmakuSheetAction> showDanmakuSettingsSheet(
  BuildContext context, {
  required DanmakuStyle style,
  required ValueChanged<DanmakuStyle> onChanged,
  required DanmakuSourceView sourceView,
  required Future<DanmakuSourceLoadOutcome> Function(DanmakuSource)
  onSelectSource,
}) async {
  final result = await showModalBottomSheet<DanmakuSheetAction>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: _sheetMaxWidth),
    builder: (context) => DanmakuSettingsSheet(
      style: style,
      onChanged: onChanged,
      sourceView: sourceView,
      onSelectSource: onSelectSource,
    ),
  );
  return result ?? DanmakuSheetAction.closed;
}

/// 弹层本体：持有 [style] 与 [sourceView] 的可变副本。
class DanmakuSettingsSheet extends StatefulWidget {
  const DanmakuSettingsSheet({
    super.key,
    required this.style,
    required this.onChanged,
    required this.sourceView,
    required this.onSelectSource,
  });

  final DanmakuStyle style;
  final ValueChanged<DanmakuStyle> onChanged;
  final DanmakuSourceView sourceView;
  final Future<DanmakuSourceLoadOutcome> Function(DanmakuSource) onSelectSource;

  @override
  State<DanmakuSettingsSheet> createState() => _DanmakuSettingsSheetState();
}

class _DanmakuSettingsSheetState extends State<DanmakuSettingsSheet> {
  late DanmakuStyle _style = widget.style;
  late DanmakuSourceView _sourceView = widget.sourceView;
  int _tabIndex = 0;

  /// 正在请求的源地址：只锁这一行，不让用户连点把上一条请求挤掉。
  String? _loadingUrl;

  /// 最近一次选择失败的源地址；失败原因跟着这条行走，而不是只飘在顶部。
  String? _errorUrl;

  /// 最近一次直播选择回报的状态文案（已连接 / 连接失败）。
  String? _currentStatusText;

  /// 成功请求但 0 条弹幕的源地址：文案是「该源没有弹幕」，不是加载失败。
  String? _emptySourceUrl;

  /// 先刷新本层再回调：调用方可能在回调里触发别的重建，顺序反了会把旧值画回去。
  void _update(DanmakuStyle next) {
    setState(() => _style = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxHeight = math.min(
      _sheetMaxHeight,
      MediaQuery.sizeOf(context).height * 0.9,
    );
    return SafeArea(
      key: const ValueKey('player-danmaku-sheet'),
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.xl,
                0,
                AppSpace.xl,
                0,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.comment_outlined,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: AppSpace.sm),
                  Text('弹幕设置', style: theme.textTheme.titleLarge),
                ],
              ),
            ),
            _summaryRow(context),
            _tabBar(context),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                key: const ValueKey('player-danmaku-sheet-body'),
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.xl,
                  AppSpace.md,
                  AppSpace.xl,
                  AppSpace.sm,
                ),
                child: _tabContent(context),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.xl,
                AppSpace.sm,
                AppSpace.xl,
                AppSpace.md,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        key: const ValueKey('player-danmaku-reset'),
                        onPressed: () => _update(DanmakuStyle.defaults),
                        child: const Text('恢复默认'),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  FilledButton.tonal(
                    key: const ValueKey('player-danmaku-full-page'),
                    onPressed: () => _finish(DanmakuSheetAction.openFullPage),
                    child: const Text('完整设置页…'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 自定页签：四档，选中态用主题色下划线标出，不引入 TabController。
  ///
  /// 弹层高度由内容决定，TabBarView 需要固定高度；这里直接按索引换内容，
  /// 未选中的页签不建树，低矮窗口里也不会一次铺开整页设置。
  Widget _tabBar(BuildContext context) {
    const tabs = [
      ('display', '显示'),
      ('timing', '时间'),
      ('tracks', '轨道'),
      ('sources', '弹幕源'),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
      child: Row(
        children: [
          for (var index = 0; index < tabs.length; index++)
            _tabButton(
              context,
              field: tabs[index].$1,
              label: tabs[index].$2,
              index: index,
            ),
        ],
      ),
    );
  }

  Widget _tabButton(
    BuildContext context, {
    required String field,
    required String label,
    required int index,
  }) {
    final theme = Theme.of(context);
    final selected = _tabIndex == index;
    final color = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return Expanded(
      child: InkWell(
        key: ValueKey('player-danmaku-tab-$field'),
        onTap: () => setState(() => _tabIndex = index),
        borderRadius: AppRadius.mdAll,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: color,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              const SizedBox(height: AppSpace.xs + 2),
              AnimatedContainer(
                duration: AppMotion.fast,
                height: 2,
                width: 28,
                decoration: BoxDecoration(
                  color: selected ? color : Colors.transparent,
                  borderRadius: AppRadius.pillAll,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tabContent(BuildContext context) => switch (_tabIndex) {
    1 => _timingTab(context),
    2 => _tracksTab(context),
    3 => _sourcesTab(context),
    _ => _displayTab(context),
  };

  void _finish(DanmakuSheetAction action) => Navigator.of(context).pop(action);

  /// 当前弹幕摘要：整行都是入口，点击直接跳到「弹幕源」页签。
  ///
  /// 不再写「弹幕库与弹幕源在完整设置页里」：本弹层已经能换本集地址，
  /// 留着那句话会把用户赶去一屏放不下的整页，反而绕远路。
  Widget _summaryRow(BuildContext context) {
    final theme = Theme.of(context);
    final summary = _currentSummary;
    final currentUrl = _sourceView.currentUrl;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.xl,
        AppSpace.xs,
        AppSpace.xl,
        AppSpace.md,
      ),
      child: InkWell(
        key: const ValueKey('player-danmaku-summary'),
        onTap: () => setState(() => _tabIndex = 3),
        borderRadius: AppRadius.smAll,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
          child: Row(
            children: [
              Expanded(
                // 摘要只显示 host/末段；完整地址（含端口/query/fragment）
                // 靠悬停读出，不能用省略号把事实截掉。
                child: Tooltip(
                  message: currentUrl == null || currentUrl.isEmpty
                      ? summary
                      : currentUrl,
                  child: Text(
                    summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              Text(
                '弹幕源',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 16,
                color: theme.colorScheme.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 合成「当前项」：当前地址不在本集列表里时（弹幕库搜索、匹配记忆），
  /// 仍然要让用户看见它并知道不会重复请求。
  List<DanmakuSource> get _sourceRows {
    final currentUrl = _sourceView.currentUrl;
    final rows = <DanmakuSource>[];
    if (currentUrl != null &&
        currentUrl.isNotEmpty &&
        !_sourceView.sources.any((source) => source.url == currentUrl)) {
      rows.add(DanmakuSource(url: currentUrl, name: '当前在用 · 弹幕库'));
    }
    rows.addAll(_sourceView.sources);
    return rows;
  }

  String get _currentSummary {
    final currentUrl = _sourceView.currentUrl;
    if (currentUrl == null || currentUrl.isEmpty) return '当前弹幕：未加载';
    DanmakuSource? matched;
    for (final source in _sourceView.sources) {
      if (source.url == currentUrl) {
        matched = source;
        break;
      }
    }
    final name = matched?.displayName ?? '弹幕库';
    // 只数本集 sourceView.sources：合成的「当前在用 · 弹幕库」只是展示行，
    // 不是本集地址，算进去会让摘要虚高。
    return '当前弹幕：$name · ${_urlDetail(currentUrl)}'
        '（共 ${_sourceView.sources.length} 条地址）';
  }

  Widget _displayTab(BuildContext context) => Column(
    key: const ValueKey('player-danmaku-tab-display-body'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _switchTile(
        field: 'enabled',
        title: '弹幕',
        subtitle: '总开关；关闭后播放器不再渲染任何弹幕',
        value: _style.enabled,
        onChanged: (value) => _update(_style.copyWith(enabled: value)),
      ),
      _sliderTile(
        context,
        field: 'opacity',
        label: '透明度',
        valueText: _percent(_style.opacity),
        value: _style.opacity,
        min: 0.1,
        max: 1.0,
        divisions: 9,
        onChanged: (value) => _update(_style.copyWith(opacity: value)),
      ),
      _sliderTile(
        context,
        field: 'textScale',
        label: '字号',
        valueText: _percent(_style.textScale),
        value: _style.textScale,
        min: 0.5,
        max: 2.0,
        divisions: 15,
        onChanged: (value) => _update(_style.copyWith(textScale: value)),
      ),
      _sliderTile(
        context,
        field: 'strokeWidth',
        label: '描边',
        valueText: _style.strokeWidth == 0
            ? '关闭'
            : _style.strokeWidth.toStringAsFixed(1),
        value: _style.strokeWidth,
        min: 0,
        max: 2,
        divisions: 20,
        onChanged: (value) => _update(_style.copyWith(strokeWidth: value)),
      ),
    ],
  );

  Widget _timingTab(BuildContext context) => Column(
    key: const ValueKey('player-danmaku-tab-timing-body'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _sliderTile(
        context,
        field: 'scrollDurationMs',
        label: '速度',
        valueText: _durationLabel(_style.scrollDurationMs),
        value: _style.scrollDurationMs.toDouble(),
        min: 2000,
        max: 60000,
        divisions: 116,
        onChanged: (value) =>
            _update(_style.copyWith(scrollDurationMs: _snap(value, 500))),
      ),
      _sliderTile(
        context,
        field: 'fixedDurationMs',
        label: '停留',
        valueText: _durationLabel(_style.fixedDurationMs),
        value: _style.fixedDurationMs.toDouble(),
        min: 1000,
        max: 10000,
        divisions: 18,
        onChanged: (value) =>
            _update(_style.copyWith(fixedDurationMs: _snap(value, 500))),
      ),
      _sliderTile(
        context,
        field: 'timeOffsetMs',
        label: '时间偏移',
        valueText: _offsetLabel(_style.timeOffsetMs),
        value: _style.timeOffsetMs.toDouble(),
        min: -5000,
        max: 5000,
        divisions: 20,
        onChanged: (value) =>
            _update(_style.copyWith(timeOffsetMs: _snap(value, 500))),
      ),
    ],
  );

  Widget _tracksTab(BuildContext context) => Column(
    key: const ValueKey('player-danmaku-tab-tracks-body'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _sliderTile(
        context,
        field: 'areaRatio',
        label: '区域',
        valueText: _percent(_style.areaRatio),
        value: _style.areaRatio,
        min: 0.2,
        max: 0.9,
        divisions: 7,
        onChanged: (value) => _update(_style.copyWith(areaRatio: value)),
      ),
      _tracksTile(context),
      _switchTile(
        field: 'showScroll',
        title: '滚动弹幕',
        subtitle: '从右向左飞过画面的普通弹幕',
        value: _style.showScroll,
        onChanged: (value) => _update(_style.copyWith(showScroll: value)),
      ),
      _switchTile(
        field: 'showTop',
        title: '顶部弹幕',
        subtitle: '固定在画面上方停留的弹幕',
        value: _style.showTop,
        onChanged: (value) => _update(_style.copyWith(showTop: value)),
      ),
      _switchTile(
        field: 'showBottom',
        title: '底部弹幕',
        subtitle: '固定在画面下方停留的弹幕',
        value: _style.showBottom,
        onChanged: (value) => _update(_style.copyWith(showBottom: value)),
      ),
    ],
  );

  Widget _sourcesTab(BuildContext context) {
    final theme = Theme.of(context);
    final rows = _sourceRows;
    return Column(
      key: const ValueKey('player-danmaku-tab-sources-body'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 初始错误没有「刚点的是哪条」的信息：放在列表上方，避免把错误
        // 错挂到某一条源上。
        if (_sourceView.error != null && _errorUrl == null)
          _sourceErrorBanner(theme, _sourceView.error!),
        if (rows.isEmpty)
          _emptySources(context)
        else
          for (final source in rows) _sourceTile(context, source),
        const SizedBox(height: AppSpace.sm),
        _libraryRow(context),
        // 空状态已经把「搜索弹幕…」放进自己的两个入口里；非空时才是
        // 列表下方的第三个块，避免同一动作在页签里出现两次。
        if (rows.isNotEmpty) ...[
          const SizedBox(height: AppSpace.md),
          OutlinedButton.icon(
            key: const ValueKey('player-danmaku-source-search'),
            onPressed: () => _finish(DanmakuSheetAction.openSearch),
            icon: const Icon(Icons.search, size: 18),
            label: const Text('搜索弹幕…'),
          ),
        ],
      ],
    );
  }

  Widget _sourceTile(BuildContext context, DanmakuSource source) {
    final theme = Theme.of(context);
    final current = source.url == _sourceView.currentUrl;
    final loading = _loadingUrl == source.url;
    final failed = _errorUrl == source.url;
    final missing = source.url == _emptySourceUrl;
    final status = failed
        ? '${source.isLive ? '连接失败' : '加载失败'}：'
              '${_sourceView.error ?? '未知原因'}'
        : missing
        ? '该源没有弹幕'
        : current
        ? source.isLive && _currentStatusText != null
              ? '当前在用 · $_currentStatusText'
              : '当前在用'
        : null;
    final canTap = !loading && (!current || failed || missing);
    return ListTile(
      key: ValueKey('player-danmaku-source-${source.url}'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      // 当前项不发请求：再点一次不能把正在看的弹幕卸载掉。关闭弹幕归
      // 「显示」页签的总开关；失败/空源允许再点重试。
      enabled: canTap,
      onTap: canTap ? () => _selectSource(source) : null,
      title: Row(
        children: [
          Expanded(
            child: Text(
              source.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge,
            ),
          ),
          if (source.isLive) _liveBadge(theme),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Tooltip(
            message: source.url,
            child: Text(
              _urlLabel(source.url),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (status != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.xs),
              child: Wrap(
                spacing: AppSpace.sm,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    status,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: failed
                          ? theme.colorScheme.error
                          : missing
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.primary,
                    ),
                  ),
                  if (current &&
                      !failed &&
                      !missing &&
                      !source.isLive &&
                      _sourceView.itemCount > 0)
                    Text(
                      '已载入 ${_sourceView.itemCount} 条',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
      trailing: loading
          ? const SizedBox(
              key: ValueKey('player-danmaku-source-loading'),
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : failed
          ? Icon(Icons.error_outline, size: 18, color: theme.colorScheme.error)
          : missing
          ? Icon(
              Icons.info_outline,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            )
          : current
          ? Icon(Icons.check, size: 18, color: theme.colorScheme.primary)
          : const Icon(Icons.chevron_right, size: 18),
    );
  }

  Widget _liveBadge(ThemeData theme) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: theme.colorScheme.secondaryContainer,
      borderRadius: AppRadius.smAll,
    ),
    child: Text(
      '直播',
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSecondaryContainer,
      ),
    ),
  );

  Widget _sourceErrorBanner(ThemeData theme, String message) => Container(
    padding: const EdgeInsets.all(AppSpace.sm),
    decoration: BoxDecoration(
      color: theme.colorScheme.errorContainer,
      borderRadius: AppRadius.smAll,
    ),
    child: Text(
      '加载失败：$message',
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onErrorContainer,
      ),
    ),
  );

  Widget _emptySources(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      key: const ValueKey('player-danmaku-source-empty'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('本集没有弹幕地址', style: theme.textTheme.bodyLarge),
        const SizedBox(height: AppSpace.sm),
        Wrap(
          spacing: AppSpace.sm,
          runSpacing: AppSpace.sm,
          children: [
            OutlinedButton(
              key: const ValueKey('player-danmaku-source-search'),
              onPressed: () => _finish(DanmakuSheetAction.openSearch),
              child: const Text('搜索弹幕…'),
            ),
            TextButton(
              key: const ValueKey('player-danmaku-source-empty-full-page'),
              onPressed: () => _finish(DanmakuSheetAction.openFullPage),
              child: const Text('弹幕库设置…'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _libraryRow(BuildContext context) {
    final theme = Theme.of(context);
    final libraryUrl = _sourceView.libraryUrl;
    final configured =
        libraryUrl != null &&
        libraryUrl.isNotEmpty &&
        _sourceView.libraryTotal > 0;
    final label = configured ? _urlLabel(libraryUrl) : '未配置';
    return InkWell(
      key: const ValueKey('player-danmaku-library'),
      onTap: () => _finish(DanmakuSheetAction.openFullPage),
      borderRadius: AppRadius.smAll,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
        child: Row(
          children: [
            Text('弹幕库：', style: theme.textTheme.bodySmall),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (configured)
              Text(
                '（共 ${_sourceView.libraryTotal} 条）',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            Icon(
              Icons.chevron_right,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  /// 选源：成功用 outcome 刷新当前项/条数；失败把原因挂回被点的那一行。
  Future<void> _selectSource(DanmakuSource source) async {
    final current = source.url == _sourceView.currentUrl;
    final failed = _errorUrl == source.url;
    final missing = _emptySourceUrl == source.url;
    // 当前项不重复请求；失败/空源允许重试。
    if (_loadingUrl != null || (current && !failed && !missing)) return;
    setState(() => _loadingUrl = source.url);
    try {
      final outcome = await widget.onSelectSource(source);
      if (!mounted) return;
      final empty = !outcome.ok && outcome.error == null;
      setState(() {
        _loadingUrl = null;
        _errorUrl = outcome.ok || empty ? null : source.url;
        _emptySourceUrl = empty ? source.url : null;
        _currentStatusText = outcome.ok ? outcome.statusText : null;
        _sourceView = DanmakuSourceView(
          sources: _sourceView.sources,
          // 直播/点播的调用方可能不回报 currentUrl；成功时回落到刚点的地址。
          currentUrl: outcome.ok
              ? (outcome.currentUrl ?? source.url)
              : outcome.currentUrl,
          itemCount: outcome.itemCount,
          error: outcome.ok ? null : outcome.error,
          libraryUrl: _sourceView.libraryUrl,
          libraryTotal: _sourceView.libraryTotal,
        );
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingUrl = null;
        _errorUrl = source.url;
        _emptySourceUrl = null;
        _currentStatusText = null;
        _sourceView = DanmakuSourceView(
          sources: _sourceView.sources,
          currentUrl: _sourceView.currentUrl,
          itemCount: _sourceView.itemCount,
          error: '选择失败：$error',
          libraryUrl: _sourceView.libraryUrl,
          libraryTotal: _sourceView.libraryTotal,
        );
      });
    }
  }

  Widget _tracksTile(BuildContext context) {
    final theme = Theme.of(context);
    // 手改 settings.json 的 maxTracks 可能落在预设之外；当前值必须进候选，
    // 否则 DropdownButton 会因为 value 不在 items 里直接断言。
    final options = <int>{0, 3, 5, 8, _style.maxTracks}.toList()..sort();
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text('行数', style: theme.textTheme.bodyLarge),
      subtitle: Text(
        '最多同时占用几条轨道；不限时只受「区域」限制',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: DropdownButton<int>(
        key: const ValueKey('player-danmaku-maxTracks'),
        value: _style.maxTracks,
        underline: const SizedBox.shrink(),
        borderRadius: AppRadius.mdAll,
        items: [
          for (final option in options)
            DropdownMenuItem(
              value: option,
              child: Text(option == 0 ? '不限' : '$option 行'),
            ),
        ],
        onChanged: (value) {
          if (value == null) return;
          _update(_style.copyWith(maxTracks: value));
        },
      ),
    );
  }

  Widget _switchTile({
    required String field,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      key: ValueKey('player-danmaku-$field'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: onChanged,
    );
  }

  Widget _sliderTile(
    BuildContext context, {
    required String field,
    required String label,
    required String valueText,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: theme.textTheme.bodyLarge)),
              Text(
                valueText,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          Slider(
            key: ValueKey('player-danmaku-$field'),
            // 夹到滑轨区间：手改 settings.json 的字段可能超出弹层给出的范围
            // （如字号核心允许到 2.5），Slider 会直接断言，整层白屏。
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

String _percent(double value) => '${(value * 100).round()}%';

/// 时长文案：整秒不拖 .0，半秒保留一位（与时间偏移同一读法）。
String _durationLabel(int milliseconds) {
  final seconds = milliseconds / 1000;
  final rounded = seconds.roundToDouble();
  return seconds == rounded
      ? '${rounded.toInt()}s'
      : '${seconds.toStringAsFixed(1)}s';
}

/// 时间偏移沿用整页 _offsetLabel 的口径：0 写 0s，正数带 +，负数带 -。
String _offsetLabel(int ms) {
  if (ms == 0) return '0s';
  final seconds = (ms.abs() / 1000)
      .toStringAsFixed(1)
      .replaceFirst(RegExp(r'\.0$'), '');
  return '${ms > 0 ? '+' : '-'}${seconds}s';
}

/// 把滑块给的值吸附到 [step]，避免出现 1234ms 这类无法展示成整秒的数。
int _snap(double value, int step) => (value / step).round() * step;

/// 摘要里的「域名或末段」：有 host 用 host（带端口），本地路径/异常 URL 用末段。
String _urlDetail(String url) {
  final trimmed = url.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri != null && uri.host.isNotEmpty) {
    // 同一主机不同端口可能是两台中转，摘要不能把它们显示成同一来源。
    return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  }
  final segments = trimmed
      .split(RegExp(r'[/\\]'))
      .where((segment) => segment.isNotEmpty);
  return segments.isEmpty ? trimmed : segments.last;
}

/// 列表里的地址：保留 scheme + host + 端口 + path + query + fragment，
/// 过长时从中间截断。
///
/// 不用单纯的 end ellipsis：地址的尾部（文件名/房间号）往往才是区分两条源
/// 的部分，只截尾部会让两行看起来一样。端口同样不能省：同一主机的 :9321 /
/// :9322 可能是两台中转，省略后两行会完全相同。
String _urlLabel(String url) {
  final trimmed = url.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri != null && uri.host.isNotEmpty) {
    final scheme = uri.scheme.isEmpty ? '' : '${uri.scheme}://';
    final port = uri.hasPort ? ':${uri.port}' : '';
    final query = uri.hasQuery ? '?${uri.query}' : '';
    final fragment = uri.hasFragment ? '#${uri.fragment}' : '';
    return _middleEllipsis(
      '$scheme${uri.host}$port${uri.path}$query$fragment',
      64,
    );
  }
  return _middleEllipsis(trimmed, 64);
}

String _middleEllipsis(String value, int maxLength) {
  if (value.length <= maxLength) return value;
  final head = (maxLength - 1) ~/ 2;
  final tail = maxLength - 1 - head;
  return '${value.substring(0, head)}…${value.substring(value.length - tail)}';
}
