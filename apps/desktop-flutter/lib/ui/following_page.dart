/// 追剧页（Phase 9 · P2-1；追番列表与追剧日历合并后的宿主页）。
///
/// 两个视角共用本地 `following` 表：`列表` 是系列视角（检查/通知/移除），
/// `日历` 是时间视角（[FollowingCalendarView]：整周/整月 + 按日分段）。
/// 检查更新走「站点详情 → 线路集数」，应用关闭后不检查（PC 没有后台服务，
/// 见 `core/following.dart` 的边界说明）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/following.dart';
import '../core/playback_platform.dart';
import '../state/app_state.dart';
import 'glass_dialog.dart';
import 'tmdb_widgets.dart' show ContentMenuBorder;
import 'poster_image.dart';
import 'following_actions.dart';
import 'following_air_data.dart';
import 'following_badge.dart';
import 'following_calendar_page.dart';
import 'tokens.dart';
import 'glass_chrome.dart';

/// 追剧页的两个视角：系列列表 / 日历。
enum _FollowingView {
  list('列表'),
  calendar('日历');

  const _FollowingView(this.label);

  final String label;
}

class FollowingPage extends StatefulWidget {
  const FollowingPage({
    super.key,
    required this.state,
    this.shellUnderlap = false,
  });

  final bool shellUnderlap;

  final AppState state;

  @override
  State<FollowingPage> createState() => _FollowingPageState();
}

/// 「⋯」菜单项取值（页面内部路由用，不是持久化字段）。
const String _menuAuto = 'auto';
const String _menuNotify = 'notify';
const String _menuInterval = 'interval';

class _FollowingPageState extends State<FollowingPage> {
  bool _checking = false;
  String _message = '';

  /// 当前视角：系列列表 / 日历。
  _FollowingView _view = _FollowingView.list;

  /// 日历视图是否已创建过：首次切过去才创建，之后一直留在树里，
  /// 由 IndexedStack 保住它的月份/选中日/滚动位置。
  ///
  /// 注意这只省下日历视图本身的构建：TMDB 播出数据由宿主在页面打开时统一取，
  /// 列表卡也要用（见 [FollowingAirData]）。
  bool _calendarBuilt = false;

  AppState get _state => widget.state;

  /// 两个视角共用的 TMDB 播出数据：列表卡显示官方集数/下一集，日历用它归日与分母。
  ///
  /// 数据在页面打开时就取（列表视角也要用），日历视图只是不再自己取一份。
  late final FollowingAirData _airData = FollowingAirData(state: _state);

  @override
  void initState() {
    super.initState();
    // 外部（检查/追番/取消）都会 notify；页面必须跟着重建。
    _state.addListener(_onStateChanged);
    _airData.addListener(_onAirDataChanged);
    unawaited(_airData.refresh(_state.followings));
    // 恢复上次视角（壳层切页会重建本页，会话内不该被打回列表）。
    if (_state.followingViewIndex == _FollowingView.calendar.index) {
      _view = _FollowingView.calendar;
      _calendarBuilt = true;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _consumeOpenRequest());
  }

  @override
  void dispose() {
    _state.removeListener(_onStateChanged);
    _airData.removeListener(_onAirDataChanged);
    _airData.dispose();
    super.dispose();
  }

  void _onStateChanged() {
    if (!mounted) return;
    setState(() {});
    unawaited(_airData.refresh(_state.followings));
    _consumeOpenRequest();
  }

  /// TMDB 数据回来了：重画（列表卡的「官方集数 / 下一集」跟着变）。
  void _onAirDataChanged() {
    if (!mounted) return;
    setState(() {});
  }

  /// 系统通知被点击后打开对应追番的最新集（请求由 AppState 记录）。
  void _consumeOpenRequest() {
    final key = _state.followingOpenRequest;
    if (key.isEmpty) return;
    _state.clearFollowingOpenRequest();
    // 从系统通知进来必须落在列表视角：日历视角没有这条剧的播放入口。
    if (_view != _FollowingView.list) {
      setState(() {
        _view = _FollowingView.list;
        _state.followingViewIndex = _FollowingView.list.index;
      });
    }
    final item = _items
        .where((candidate) => candidate.identityKey == key)
        .firstOrNull;
    if (item == null) return;
    _message = '来自系统通知：${item.vodName}';
    unawaited(playFollowingLatest(context, _state, item));
  }

  List<Following> get _items => _state.followings;

  void _setView(_FollowingView view) {
    if (view == _view) return;
    setState(() {
      _view = view;
      _state.followingViewIndex = view.index;
      if (view == _FollowingView.calendar) _calendarBuilt = true;
    });
  }

  /// 页头「⋯」：原先把这三项平铺成一行，合并后页头要让位给视角切换，
  /// 收进菜单里；写入口与生效开关（[AppState.setFollowingSettings]）不变。
  Widget _followingMenu(FollowingSettings settings) {
    return PopupMenuButton<String>(
      shape: ContentMenuBorder(Theme.of(context)),
      color: Theme.of(context).colorScheme.surfaceContainerHigh
          .withValues(alpha: .97),
      elevation: 0,
      key: const ValueKey('following-more'),
      tooltip: '追剧设置',
      icon: const Icon(Icons.more_horiz),
      onSelected: (value) => unawaited(_onMenuSelected(value, settings)),
      itemBuilder: (context) => [
        CheckedPopupMenuItem(
          key: const ValueKey('following-auto'),
          value: _menuAuto,
          checked: settings.enabled,
          child: Text('自动检查（应用运行期间${settings.intervalLabel}）'),
        ),
        CheckedPopupMenuItem(
          key: const ValueKey('following-notify'),
          value: _menuNotify,
          checked: settings.notifyEnabled,
          child: const Text('新集提示'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          key: const ValueKey('following-interval'),
          value: _menuInterval,
          child: Text('检查间隔：${settings.intervalLabel}'),
        ),
      ],
    );
  }

  Future<void> _onMenuSelected(String value, FollowingSettings settings) async {
    switch (value) {
      case _menuNotify:
        await _state.setFollowingSettings(
          settings.copyWith(notifyEnabled: !settings.notifyEnabled),
        );
      case _menuInterval:
        await _editInterval(settings);
      case _menuAuto:
        await _state.setFollowingSettings(
          settings.copyWith(enabled: !settings.enabled),
        );
    }
  }

  Future<void> _checkAll() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _message = '';
    });
    final summary = await _state.checkAllFollowings();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _message =
          '检查 ${summary.checked} 部：新集 ${summary.changed} 部，失败 ${summary.failed} 部';
    });
  }

  Future<void> _checkOne(Following item) async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _message = '';
    });
    final outcome = await _state.checkFollowing(item);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _message = outcome == null
          ? '本地存储不可用'
          : outcome.ok
          ? (outcome.changed ? '发现新集：${item.vodName}' : '没有新集')
          : '检查失败：${outcome.error}';
    });
  }

  /// 检查间隔预设（分钟）；自定义输入另开一格。
  static const List<int> _intervalPresets = [15, 30, 60, 180, 360, 720, 1440];

  Future<void> _editInterval(FollowingSettings settings) async {
    final controller = TextEditingController(
      text: '${settings.intervalMinutes}',
    );
    var selected = settings.intervalMinutes;
    String? error;
    var revision = 0;
    Future<void> commit(int minutes) async {
      final current = ++revision;
      final saved = await _state.setFollowingSettings(
        _state.followingSettings.copyWith(intervalMinutes: minutes),
      );
      if (!mounted || current != revision) return;
      setState(() {
        _message = saved
            ? '检查间隔已自动保存为 ${_state.followingSettings.intervalLabel}'
            : '检查间隔自动保存失败，请重新修改后重试';
      });
    }

    final route = DialogRoute<void>(
      context: context,
      barrierColor: glassBarrierColor(context),
      builder: (context) => GlassAlertDialog(
        key: const ValueKey('following-interval-dialog'),
        title: const Text('自动检查间隔'),
        content: StatefulBuilder(
          builder: (context, setLocal) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final minutes in _intervalPresets)
                    ChoiceChip(
                      key: ValueKey('following-interval-$minutes'),
                      label: Text(FollowingSettings.formatInterval(minutes)),
                      selected: selected == minutes,
                      onSelected: (_) {
                        setLocal(() {
                          selected = minutes;
                          error = null;
                          controller.text = '$minutes';
                        });
                        commit(minutes);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('following-interval-input'),
                controller: controller,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: '自定义分钟（15–1440）',
                  errorText: error,
                ),
                onChanged: (value) {
                  final minutes = int.tryParse(value.trim());
                  final valid =
                      minutes != null && minutes >= 15 && minutes <= 1440;
                  setLocal(() {
                    error = valid ? null : '请输入 15–1440 之间的整数';
                    if (valid) selected = minutes;
                  });
                  if (valid) {
                    commit(minutes);
                  } else {
                    revision++;
                  }
                },
              ),
              const SizedBox(height: 8),
              const Text('有效修改即生效并自动保存'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    await Navigator.of(context).push(route);
    await route.completed;
    controller.dispose();
  }

  Future<void> _remove(Following item) async {
    final confirmed = await showGlassDialog<bool>(
      context: context,
      builder: (context) => GlassAlertDialog(
        title: const Text('取消追剧？'),
        content: Text('不再检查《${item.vodName}》的更新。已下载/已看的记录不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('保留'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('取消追剧'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _state.unfollowFollowing(item);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _items;
    // 汇总口径 = 有未看的发布集（已读水位不参与，水位只抑制新集提示）。
    final unwatchedCount = items
        .where((item) => item.unwatchedCount > 0)
        .length;
    final settings = _state.followingSettings;
    // 页面自身结果优先，其次是通知降级/发送结果。
    final notice = _message.isNotEmpty ? _message : _state.followingNotice;
    return LayoutBuilder(
      builder: (context, page) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.shellUnderlap)
            const SizedBox(height: kShellContentTopInset),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Material(
              type: MaterialType.transparency,
              child: Row(
                children: [
                  Expanded(
                    child: Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        Text(
                          '追剧（${items.length}）',
                          style: theme.textTheme.titleMedium,
                        ),
                        if (unwatchedCount > 0)
                          Container(
                            key: const ValueKey('following-update-summary'),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(AppRadius.sm),
                            ),
                            child: Text(
                              '$unwatchedCount 部有未看',
                              style: TextStyle(
                                color: theme.colorScheme.onPrimaryContainer,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        const SizedBox(width: 8),
                        FilledButton.tonalIcon(
                          key: const ValueKey('following-check-all'),
                          onPressed: _checking || items.isEmpty
                              ? null
                              : _checkAll,
                          icon: _checking
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.refresh, size: 18),
                          label: Text(_checking ? '检查中…' : '检查更新'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpace.md),
                  _FollowingViewToggle(view: _view, onChanged: _setView),
                  _followingMenu(settings),
                ],
              ),
            ),
          ),
          if (notice.isNotEmpty)
            Padding(
              key: const ValueKey('following-notice'),
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Text(notice, style: theme.textTheme.bodySmall),
            ),
          const SizedBox(height: 4),
          Expanded(
            child: Material(
              type: MaterialType.transparency,
              child: IndexedStack(
                index: _view.index,
                sizing: StackFit.expand,
                children: [
                  if (items.isEmpty)
                    const _FollowingEmpty()
                  else
                    ShellScrollUnderlap(
                      viewportBottom: widget.shellUnderlap
                          ? page.maxHeight
                          : null,
                      builder: (context, _, leading) => ListView.separated(
                        key: const ValueKey('following-list'),
                        padding: EdgeInsets.fromLTRB(12, 4 + leading, 12, 16),
                        itemCount: items.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 12),
                        itemBuilder: (context, index) {
                          final item = items[index];
                          return FollowingCard(
                            episodeLabel: _airData.episodeLabelFor(item),
                            airSummary: _airData.airSummaryFor(item),
                            platformLabel: playbackPlatformLabel(
                              networks:
                                  _airData.networks[item.identityKey] ??
                                  const [],
                            ),
                            item: item,
                            checking: _checking,
                            globalNotifyEnabled: settings.notifyEnabled,
                            onPlay: (item) =>
                                playFollowingLatest(context, _state, item),
                            onOpenDetail: (item) => openFollowingDetail(
                              context,
                              _state,
                              item,
                              markRead: true,
                              syncProgress: true,
                            ),
                            onCheck: _checkOne,
                            onMarkRead: (item) =>
                                _state.markFollowingRead(item),
                            onSetNotify: (enabled) =>
                                _state.setFollowingNotifyEnabled(item, enabled),
                            onRemove: _remove,
                          );
                        },
                      ),
                    ),
                  // 日历首次进入才创建；之后由 IndexedStack 保活（月份/选中日/滚动位置）。
                  if (_calendarBuilt)
                    FollowingCalendarView(state: _state, airData: _airData)
                  else
                    const SizedBox.shrink(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 列表 / 日历视角切换（视觉与日历内的「整周 / 整月」一致）。
class _FollowingViewToggle extends StatelessWidget {
  const _FollowingViewToggle({required this.view, required this.onChanged});

  final _FollowingView view;
  final ValueChanged<_FollowingView> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget buildOption(_FollowingView option) {
      final selected = option == view;
      Color? selectedInk(Color color) =>
          selected ? scheme.onPrimary.withValues(alpha: color.a) : null;
      return Semantics(
        button: true,
        enabled: true,
        selected: selected,
        inMutuallyExclusiveGroup: true,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: selected ? scheme.primary : null,
            borderRadius: AppRadius.pillAll,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: ValueKey('following-view-${option.name}'),
              onTap: () => onChanged(option),
              borderRadius: AppRadius.pillAll,
              focusColor: selectedInk(theme.focusColor),
              hoverColor: selectedInk(theme.hoverColor),
              splashColor: selectedInk(theme.splashColor),
              highlightColor: selectedInk(theme.highlightColor),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                child: Text(
                  option.label,
                  style: TextStyle(
                    fontSize: 12,
                    color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: AppRadius.pillAll,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: _FollowingView.values.map(buildOption).toList(),
      ),
    );
  }
}

class _FollowingEmpty extends StatelessWidget {
  const _FollowingEmpty();

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const ValueKey('following-empty'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_border, size: 44),
          const SizedBox(height: AppSpace.sm),
          const Text('还没有追剧'),
          const SizedBox(height: AppSpace.xs),
          const Text(
            '在影片详情页点右上角 ★ 加入追剧；有新集时这里会显示徽标。',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// 一条追番卡片（纯展示，无状态；公开以便 widget 测试直接构造）。
class FollowingCard extends StatelessWidget {
  const FollowingCard({
    super.key,
    required this.item,
    required this.checking,
    required this.globalNotifyEnabled,
    required this.onPlay,
    required this.onOpenDetail,
    required this.onCheck,
    required this.onMarkRead,
    required this.onSetNotify,
    required this.onRemove,
    this.airSummary = '',
    this.platformLabel = '',
    this.episodeLabel = '',
  });

  final Following item;

  /// TMDB 摘要（官方共 N 集 / 下一集 M月D日）；空串表示未知，不占位。
  final String airSummary;

  /// 播放平台（TMDB networks 转中文名，如「湖南卫视 / 芒果TV」）；空串不占位。
  ///
  /// 与日历条目同一个 [FollowingBadge] 组件，样式与日历一致。
  final String platformLabel;

  /// 集数行（含官方总集数的完整口径）；空串表示宿主没给，退回本线路可播集数。
  final String episodeLabel;
  final bool checking;

  /// 全局「新集提示」开关（`FollowingSettings.notifyEnabled`）。
  ///
  /// 条目自身的 [Following.notifyEnabled] 只在追番那一刻从全局值拷贝下来，
  /// 之后可单独开关（kebab 菜单「新集通知」），所以生效值必须两个都开——
  /// 只显示条目值会把「全局关了、条目仍是开」显示成开。
  final bool globalNotifyEnabled;

  final ValueChanged<Following> onPlay;
  final ValueChanged<Following> onOpenDetail;
  final ValueChanged<Following> onCheck;
  final ValueChanged<Following> onMarkRead;

  /// 本次要设置的条目开关目标值（菜单里已按当前值取反），
  /// 父层直接转给 `AppState.setFollowingNotifyEnabled`。
  final ValueChanged<bool> onSetNotify;

  final ValueChanged<Following> onRemove;

  /// 未看集数（`Following.unwatchedCount`：已读水位不参与，水位只抑制新集提示）。
  int get _unwatched => item.unwatchedCount;

  bool get _notifyEffective => globalNotifyEnabled && item.notifyEnabled;

  String get _statusText {
    final status = FollowingStatus.label(item.status);
    final line = item.flag.isEmpty ? '默认线路' : item.flag;
    return '$status · $line';
  }

  /// 集数行：宿主给了完整口径（含官方总集数）就用它；否则退回本线路可播集数。
  String get _episodeText {
    if (episodeLabel.isNotEmpty) return episodeLabel;
    return item.releasedEpisode > 0
        ? '本线路可播 ${item.releasedEpisode} 集'
        : '集数未知';
  }

  String get _watchedText =>
      item.watchedEpisode > 0 ? '已看 ${item.watchedEpisode} 集' : '未开始看';

  /// 三态：生效开 / 条目关 / 全局关（条目开着但推送不会发生）。
  /// 三态短文案：生效开 / 条目关 / 全局关（条目开着但推送不会发生）。
  String get _notifyText {
    if (_notifyEffective) return '新集通知：开';
    if (!item.notifyEnabled) return '新集通知：关（本条）';
    return '新集通知：关（全局）';
  }

  /// 下一季入口：仅当有比追踪季更新的发布季时显示（PC 暂无季数据，恒不显示），
  /// 且 PC 没有「追下一季」能力，所以只给文字，不做可点击控件。
  bool get _showNextSeason => item.latestReleasedSeason > item.trackedSeason;

  String get _lastCheckText {
    if (item.lastError.isNotEmpty) return '上次检查失败：${item.lastError}';
    if (item.lastCheckedAtMs <= 0) return '尚未检查';
    final time = DateTime.fromMillisecondsSinceEpoch(item.lastCheckedAtMs);
    String two(int v) => v.toString().padLeft(2, '0');
    return '上次检查 ${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final emphasis = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.w600,
    );
    return InkWell(
      key: ValueKey('following-card-${item.identityKey}'),
      onTap: () => onPlay(item),
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: SizedBox(
                width: 56,
                height: 84,
                child: PosterImage(url: item.vodPic),
              ),
            ),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.vodName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      if (_unwatched > 0)
                        Container(
                          key: ValueKey('following-badge-${item.identityKey}'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '$_unwatched 集未看',
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(_statusText, style: theme.textTheme.bodySmall),
                  const SizedBox(height: 2),
                  Wrap(
                    spacing: AppSpace.sm,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (platformLabel.isNotEmpty)
                        FollowingBadge(
                          key: ValueKey(
                            'following-platform-${item.identityKey}',
                          ),
                          text: platformLabel,
                        ),
                      Text(_episodeText, style: subtle),
                      if (airSummary.isNotEmpty)
                        Text(
                          airSummary,
                          key: ValueKey('following-air-${item.identityKey}'),
                          style: subtle,
                        ),
                      Text(_watchedText, style: subtle),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _notifyEffective
                                ? Icons.notifications_active_outlined
                                : Icons.notifications_off_outlined,
                            size: 13,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: AppSpace.xs),
                          Text(
                            _notifyText,
                            key: ValueKey(
                              'following-notify-${item.identityKey}',
                            ),
                            style: subtle,
                          ),
                        ],
                      ),
                      if (_showNextSeason)
                        Text(
                          '第 ${item.latestReleasedSeason + 1} 季已开播',
                          key: ValueKey(
                            'following-next-season-${item.identityKey}',
                          ),
                          style: emphasis,
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _lastCheckText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: item.lastError.isEmpty
                          ? null
                          : theme.colorScheme.error,
                    ),
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              shape: ContentMenuBorder(Theme.of(context)),
              color: Theme.of(context).colorScheme.surfaceContainerHigh
                  .withValues(alpha: .97),
              elevation: 0,
              key: ValueKey('following-menu-${item.identityKey}'),
              tooltip: '更多',
              onSelected: (value) {
                switch (value) {
                  case 'play':
                    onPlay(item);
                  case 'detail':
                    onOpenDetail(item);
                  case 'check':
                    onCheck(item);
                  case 'notify':
                    onSetNotify(!item.notifyEnabled);
                  case 'read':
                    onMarkRead(item);
                  case 'remove':
                    onRemove(item);
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'play', child: Text('播放最新集')),
                const PopupMenuItem(value: 'detail', child: Text('打开详情')),
                PopupMenuItem(
                  value: 'check',
                  enabled: !checking,
                  child: const Text('检查更新'),
                ),
                PopupMenuItem(
                  key: ValueKey('following-menu-notify-${item.identityKey}'),
                  value: 'notify',
                  height: 64,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.notifyEnabled ? '新集通知：已开启' : '新集通知：已关闭'),
                      Text(
                        globalNotifyEnabled
                            ? '仅对这部剧生效'
                            : '全局「新集提示」已关闭，开启后也不会推送',
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const PopupMenuItem(value: 'read', child: Text('标为已读（仅清除提示）')),
                const PopupMenuItem(value: 'remove', child: Text('取消追剧')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
