/// 追剧日历视图（Phase 9 · P2-1 配套；合并后的追剧页内视图）。
///
/// 宿主是 `FollowingPage`：本视图只画日历（整周/整月 + 按日分段列表），
/// 不带自己的壳层与导航；`following_page.dart` 用 IndexedStack 保它的状态。
///
/// 数据全部来自本地 `following` 表 + `core/following_calendar.dart` 的纯逻辑层：
/// 页面自己不做归日/合并计算，只负责把 `followingCalendarByDay` 的结果画成
/// 「整周条带」或「整月网格」+ 下方**按日期分段**的条目列表。
///
/// 真实播出时间（[FollowingAirTime]）与官方该季总集数（[FollowingSeasonTotal]）
/// 来自 [AppState.followingAirTimes] / [AppState.followingSeasonTotals]：未配置
/// TMDB、超时或无匹配时都是空，条目来源退回 `nextAirAtMs`（`real`）或本地推算
/// （`local`），进度分母退回本线路可播集数（`line`）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

import '../core/following.dart';
import '../core/following_calendar.dart';
import '../core/playback_platform.dart';
import '../core/tmdb_detail_model.dart';
import '../core/tmdb_identity.dart';
import '../services/following_air_time_service.dart';
import '../state/app_state.dart';
import 'glass_widgets.dart';
import 'poster_image.dart';
import 'following_actions.dart';
import 'following_air_data.dart';
import 'following_badge.dart';
import 'tmdb_episode_detail.dart';
import 'search_page.dart';
import 'tokens.dart';
import 'toast.dart';

/// 视图形态：整周条带 / 整月网格；两者下方都是按日期分段的列表。
enum _CalendarView {
  week('整周'),
  month('整月');

  const _CalendarView(this.label);

  final String label;
}

class FollowingCalendarView extends StatefulWidget {
  const FollowingCalendarView({super.key, required this.state, this.airData});

  final AppState state;

  /// 共享的 TMDB 播出数据（宿主页持有）。为 null 时本视图自建一份并自行刷新，
  /// 这样单独挂载（widget 测试）的行为与合并前一致。
  final FollowingAirData? airData;

  @override
  State<FollowingCalendarView> createState() => _FollowingCalendarViewState();
}

class _FollowingCalendarViewState extends State<FollowingCalendarView> {
  /// 当前视图（默认整月，与历史行为一致）。
  _CalendarView _view = _CalendarView.month;

  /// 可见月份（当月 1 日 0:00）。
  late DateTime _month;

  /// 选中的自然日（0:00）；周视图以它为锚点，列表把它的分段高亮。
  late DateTime _selected;

  /// 真实播出时间 / 官方总集数 / 播放平台名：由宿主共享，跨视角同一份。
  late final FollowingAirData _airData =
      widget.airData ?? FollowingAirData(state: widget.state);

  /// 没拿到宿主给的那份时，本视图自己负责刷新（单独挂载 / 测试）。
  bool get _ownsAirData => widget.airData == null;

  final _listController = ScrollController();
  final _dayHeaders = <DateTime, GlobalKey>{};
  final _selectedCell = GlobalKey();
  bool _locateSelected = true;
  bool _showSelectionFeedback = true;
  int _interactionVersion = 0;
  String? _lastLocation;

  AppState get _state => widget.state;

  @override
  void initState() {
    super.initState();
    final today = _today();
    _month = DateTime(today.year, today.month);
    _selected = today;
    // 追番检查/删除都会 notify；日历必须跟着重建。
    _state.addListener(_onStateChanged);
    _airData.addListener(_onAirDataChanged);
    if (_ownsAirData) unawaited(_airData.refresh(_state.followings));
  }

  @override
  void dispose() {
    _state.removeListener(_onStateChanged);
    _airData.removeListener(_onAirDataChanged);
    if (_ownsAirData) _airData.dispose();
    _listController.dispose();
    super.dispose();
  }

  void _onStateChanged() {
    if (!mounted) return;
    setState(() {});
    // 宿主页负责刷新共享数据；单独挂载时（测试）本视图自己刷。
    if (_ownsAirData) unawaited(_airData.refresh(_state.followings));
  }

  /// 上一次数据通知（取数发起 / 数据到达）时的交互版本。
  int _interactionAtLoad = 0;

  /// 共享数据变了：重画。数据到达改变条目的日期分布，需要补一次定位；
  /// 但取数期间用户手动滚动过就不抢位置（与合并前的 `_interactionVersion` 同义）。
  void _onAirDataChanged() {
    if (!mounted) return;
    final idle = _interactionVersion == _interactionAtLoad;
    _interactionAtLoad = _interactionVersion;
    setState(() {
      if (idle) _locateSelected = true;
    });
  }

  DateTime _today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  /// 切月时同步把选中日落到「今天」或目标月 1 日——
  /// 保留上个月的同一天会让列表停在当月不存在的日期上。
  void _shiftMonth(int delta) {
    _cancelLocation();
    final today = _today();
    final target = DateTime(_month.year, _month.month + delta);
    setState(() {
      _month = target;
      _selected = target.year == today.year && target.month == today.month
          ? today
          : target;
    });
  }

  void _goToday() => _selectDay(_today());

  /// 周视图里箭头按周平移：选中日 +7/-7 天，月份跟着选中日走，
  /// 这样切回月历时不会停在无关的月份上。
  void _shiftWeek(int delta) {
    _cancelLocation();
    final target = DateTime(
      _selected.year,
      _selected.month,
      _selected.day + 7 * delta,
    );
    setState(() {
      _selected = target;
      _month = DateTime(target.year, target.month);
    });
  }

  /// 切换视图：切回月历时把可见月份对齐到选中日。
  void _setView(_CalendarView view) {
    if (_view == view) return;
    _cancelLocation();
    setState(() {
      _view = view;
      _month = DateTime(_selected.year, _selected.month);
      _locateSelected = true;
    });
  }

  /// 选中某天；点击跨月格子时同步切到对应月份。
  void _selectDay(DateTime date) {
    _cancelLocation(forget: !_isSameDay(date, _selected));
    setState(() {
      _selected = DateTime(date.year, date.month, date.day);
      _month = DateTime(date.year, date.month);
      _locateSelected = true;
      _showSelectionFeedback = true;
    });
  }

  void _cancelLocation({bool forget = true}) {
    _interactionVersion++;
    _locateSelected = false;
    if (forget) _lastLocation = null;
  }

  void _scrollToSelected(List<CalendarDay> days) {
    if (!_locateSelected) return;
    _locateSelected = false;
    final date = _selected;
    DateTime? target;
    for (final day in days) {
      if (_isSameDay(day.date, date)) {
        target = day.date;
        break;
      }
      // 今天无更新时优先最近较早分段，找不到才取较晚分段。
      if (_isSameDay(date, _today())) {
        if (day.date.isBefore(date)) {
          target = day.date;
        } else {
          target ??= day.date;
          break;
        }
      }
    }
    final signature =
        '$date/$_view/$target/'
        '${days.map((day) => '${day.date}:${day.entries.map((entry) => '${entry.identityKey}/${entry.code}').join(',')}').join(';')}';
    if (signature == _lastLocation) return;
    final interactionVersion = _interactionVersion;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          interactionVersion != _interactionVersion ||
          signature == _lastLocation) {
        return;
      }
      final contexts = [
        _selectedCell.currentContext,
        _dayHeaders[target]?.currentContext,
      ];
      _lastLocation = signature;
      for (final targetContext in contexts) {
        if (targetContext == null) continue;
        unawaited(
          Scrollable.ensureVisible(
            targetContext,
            alignment: targetContext == contexts.last && target != date
                ? .12
                : 0,
            duration: AppMotion.base,
            curve: AppMotion.ease,
          ),
        );
      }
    });
  }

  Following? _itemFor(CalendarEntry entry) {
    for (final item in _state.followings) {
      if (item.identityKey == entry.identityKey) return item;
    }
    return null;
  }

  /// 选中日没有更新时的提示条：固定占一行，不浮在卡片上方、也不会被滚走。
  Widget _selectedEmptyHint(ThemeData theme) {
    return Row(
      key: const ValueKey('calendar-selected-empty'),
      children: [
        Icon(
          Icons.event_busy,
          size: 14,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: AppSpace.xs),
        Text(
          '${_selected.month}月${_selected.day}日 没有更新',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

  /// 某天的条目卡：剧级信息（已播/进度条/来源/平台）只在当天该剧的**首条**出现一次。
  List<Widget> _dayCards(CalendarDay day) {
    final leads = followingCalendarSeriesLeadIndexes(day.entries);
    return [
      for (final (index, entry) in day.entries.indexed)
        _CalendarEntryCard(
          entry: entry,
          platformLabel: _platformLabel(entry),
          showSeriesInfo: leads.contains(index),
          releasedEpisode: _itemFor(entry)?.releasedEpisode ?? entry.episode,
          onPlay: _playEntry,
          onShowDetails: (entry) => _showEntryDetails(entry, day.date),
        ),
    ];
  }

  /// 平台标签：TMDB 的 networks（腾讯视频 / 爱奇艺…）；没有台名时返回空串。
  String _platformLabel(CalendarEntry entry) => playbackPlatformLabel(
    networks: _airData.networks[entry.identityKey] ?? const [],
  );

  Future<void> _showEntryDetails(CalendarEntry entry, DateTime day) async {
    final item = _itemFor(entry);
    var date = day;
    for (final airTime in _airData.airTimes) {
      if (airTime.identityKey == entry.identityKey &&
          airTime.episode == entry.episode) {
        date = followingCalendarDateOf(airTime.airAtMs);
        break;
      }
    }
    final title = entry.episodeTitle.trim();
    final sourceName =
        item != null &&
            entry.episode >= 1 &&
            entry.season == item.latestReleasedSeason &&
            entry.episode == item.releasedEpisode
        ? item.latestEpisodeName
        : '';
    await showTmdbEpisodeDetails(
      context,
      card: TmdbEpisodeCard(
        number: entry.episode >= 1 ? entry.episode : 0,
        seasonNumber: entry.season < 0 ? 1 : entry.season + 1,
        title: title.isEmpty ? '${entry.vodName} ${entry.code}' : title,
        date:
            '${date.year}-${date.month.toString().padLeft(2, '0')}-'
            '${date.day.toString().padLeft(2, '0')}',
        stillUrl: entry.vodPic,
      ),
      sourceName: sourceName,
      service: _state.tmdbService,
      recommendationDependencies: _state.recommendationDependencies,
      onSearchTitle: (title) => _searchRecommendation(title),
      onSearchSource: (title, identity) =>
          _searchRecommendation(title, identityHint: identity),
      resolveItem: item == null || entry.episode < 1
          ? null
          : () => _state.followingTmdbItem(item),
      onAction: () => _playEntry(entry),
    );
  }

  void _searchRecommendation(String title, {TmdbIdentity? identityHint}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: const Text('搜索站源'),
            backgroundColor: Colors.transparent,
            flexibleSpace: const IgnorePointer(
              child: GlassPane(
                borderRadius: BorderRadius.zero,
                child: SizedBox.expand(),
              ),
            ),
          ),
          body: SearchPage(
            state: _state,
            initialKeyword: title,
            identityHint: identityHint,
          ),
        ),
      ),
    );
  }

  /// 播放某一条日历条目。
  ///
  /// 数据层每条追番只保存**最新一集**的播放入口（`latestEpisodeTarget/Name`），
  /// 没有逐集的播放目标，因此只有「条目正好是这条线路当前最新可播集」时能直达
  /// 播放；更早的集只能退回详情页由用户选集。这是能力边界，不做伪造。
  Future<void> _playEntry(CalendarEntry entry) async {
    final item = _itemFor(entry);
    if (item == null) {
      showToast('该追剧已不在列表中：${entry.vodName}', kind: ToastKind.error);
      return;
    }
    await playFollowingEntry(context, _state, item, entry);
  }

  Widget _buildCalendarToolbar(ThemeData theme, CalendarWeek week) {
    final weekly = _view == _CalendarView.week;
    final navigationStyle = IconButton.styleFrom(
      minimumSize: const Size.square(40),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    final endYear = week.end.year == week.start.year ? '' : '${week.end.year}年';
    final title = weekly
        ? '${week.start.year}年${week.start.month}月${week.start.day}日 - '
              '$endYear${week.end.month}月${week.end.day}日'
        : '${_month.year}年${_month.month}月';
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: AppSpace.md,
      runSpacing: AppSpace.xs,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                title,
                key: ValueKey(
                  weekly ? 'calendar-week-title' : 'calendar-title',
                ),
                style: theme.textTheme.titleMedium,
              ),
            ),
            const SizedBox(width: AppSpace.sm),
            IconButton(
              key: const ValueKey('calendar-prev-month'),
              style: navigationStyle,
              tooltip: weekly ? '上一周' : '上一月',
              icon: const Icon(Icons.chevron_left),
              onPressed: () => weekly ? _shiftWeek(-1) : _shiftMonth(-1),
            ),
            IconButton(
              key: const ValueKey('calendar-next-month'),
              style: navigationStyle,
              tooltip: weekly ? '下一周' : '下一月',
              icon: const Icon(Icons.chevron_right),
              onPressed: () => weekly ? _shiftWeek(1) : _shiftMonth(1),
            ),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              key: const ValueKey('calendar-today-button'),
              onPressed: _goToday,
              child: const Text('今日'),
            ),
            const SizedBox(width: AppSpace.sm),
            _ViewToggle(view: _view, onChanged: _setView),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _state.followings;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final month = followingCalendarMonth(
      year: _month.year,
      month: _month.month,
    );
    // 官方总集数 → 进度分母；键就是条目的 identityKey。
    final officialTotals = <String, int>{
      for (final total in _airData.seasonTotals)
        total.identityKey: total.totalEpisodes,
    };
    final byDay = followingCalendarByDay(
      items: items,
      nowMs: nowMs,
      airTimes: _airData.airTimes,
      officialTotalEpisodes: officialTotals,
    );
    final dayUpdates = followingCalendarUnwatchedDaysInMonth(
      byDay,
      year: month.year,
      month: month.month,
    );
    final today = followingCalendarDateOf(nowMs);
    final week = followingCalendarWeek(byDay, anchor: _selected);
    // 列表分段：整周视图是本周 7 天，整月视图是本月所有有更新的日子。
    final days = _view == _CalendarView.week
        ? week.days.where((day) => day.isNotEmpty).toList()
        : [
            for (final date in byDay.keys)
              if (date.year == month.year && date.month == month.month)
                followingCalendarDayOf(byDay, date),
          ];

    _dayHeaders.removeWhere((date, _) => !days.any((day) => day.date == date));
    _scrollToSelected(days);
    final noUpdates =
        _showSelectionFeedback &&
        followingCalendarDayOf(byDay, _selected).isEmpty;
    return NotificationListener<UserScrollNotification>(
      onNotification: (notification) {
        if (notification.direction != ScrollDirection.idle) _cancelLocation();
        return false;
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final cellHeight =
              ((constraints.maxHeight * .4 - 72) / month.weeks.length).clamp(
                24.0,
                30.0,
              );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(
                key: const ValueKey('calendar-region'),
                constraints: BoxConstraints(
                  maxHeight: constraints.maxHeight * .4,
                ),
                child: Material(
                  type: MaterialType.transparency,
                  child: SingleChildScrollView(
                    primary: false,
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.md,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildCalendarToolbar(theme, week),
                        if (items.isNotEmpty) ...[
                          if (_view == _CalendarView.week)
                            _CalendarWeekStrip(
                              week: week,
                              today: today,
                              selected: _selected,
                              onTap: _selectDay,
                            )
                          else ...[
                            Padding(
                              padding: const EdgeInsets.only(
                                bottom: AppSpace.xs,
                              ),
                              child: Row(
                                key: const ValueKey('calendar-weekdays'),
                                children: [
                                  for (final label
                                      in followingCalendarWeekdayLabels)
                                    Expanded(
                                      child: Text(
                                        label,
                                        textAlign: TextAlign.center,
                                        style: theme.textTheme.labelMedium
                                            ?.copyWith(
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            Column(
                              key: const ValueKey('calendar-grid'),
                              children: [
                                for (final row in month.weeks)
                                  Row(
                                    children: [
                                      for (final cell in row)
                                        Expanded(
                                          child: _CalendarDateButton(
                                            key:
                                                _isSameDay(cell.date, _selected)
                                                ? _selectedCell
                                                : null,
                                            date: cell.date,
                                            height: cellHeight,
                                            isToday: _isSameDay(
                                              cell.date,
                                              today,
                                            ),
                                            inMonth: cell.inMonth,
                                            hasUpdate:
                                                cell.inMonth &&
                                                dayUpdates.containsKey(
                                                  cell.date.day,
                                                ),
                                            hasUnwatched:
                                                cell.inMonth &&
                                                (dayUpdates[cell.date.day] ??
                                                    false),
                                            selected: _isSameDay(
                                              cell.date,
                                              _selected,
                                            ),
                                            onTap: () => _selectDay(cell.date),
                                          ),
                                        ),
                                    ],
                                  ),
                              ],
                            ),
                          ],
                          const SizedBox(height: AppSpace.xs),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              // 选中日没有更新：常驻在日历区与列表之间，占自己的高度——
              // 既不遮挡卡片，也不会像清单首项那样被滚走后看不见（2026-11-18 反馈）。
              if (noUpdates)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.md,
                    2,
                    AppSpace.md,
                    2,
                  ),
                  child: _selectedEmptyHint(theme),
                ),
              if (items.isEmpty)
                const Expanded(child: _CalendarEmpty())
              else ...[
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (days.isEmpty)
                        const _CalendarDayEmpty()
                      else
                        ListView(
                          key: const ValueKey('calendar-list'),
                          controller: _listController,
                          padding: const EdgeInsets.fromLTRB(
                            AppSpace.md,
                            AppSpace.xs,
                            AppSpace.md,
                            AppSpace.lg,
                          ),
                          children: [
                            // 保持所有日期分段可定位，组间距大于组内间距。
                            Column(
                              spacing: AppSpace.md,
                              children: [
                                for (final day in days)
                                  Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      _CalendarDayHeader(
                                        key: _dayHeaders.putIfAbsent(
                                          day.date,
                                          GlobalKey.new,
                                        ),
                                        day: day,
                                        selected: _isSameDay(
                                          day.date,
                                          _selected,
                                        ),
                                      ),
                                      const SizedBox(height: AppSpace.xs),
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        spacing: AppSpace.sm,
                                        children: _dayCards(day),
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// 右侧视图切换：两个选项，当前视图高亮。
class _ViewToggle extends StatelessWidget {
  const _ViewToggle({required this.view, required this.onChanged});

  final _CalendarView view;
  final ValueChanged<_CalendarView> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget buildOption(_CalendarView option) {
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
              key: ValueKey('calendar-view-${option.name}'),
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
        color: scheme.surfaceContainerHigh,
        borderRadius: AppRadius.pillAll,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: _CalendarView.values.map(buildOption).toList(),
      ),
    );
  }
}

class _CalendarDateButton extends StatelessWidget {
  const _CalendarDateButton({
    super.key,
    required this.date,
    required this.height,
    required this.isToday,
    required this.hasUpdate,
    required this.hasUnwatched,
    required this.selected,
    required this.onTap,
    this.inMonth = true,
    this.showWeekday = false,
  });

  final DateTime date;
  final double height;
  final bool isToday;
  final bool hasUpdate;
  final bool hasUnwatched;
  final bool selected;
  final VoidCallback onTap;
  final bool inMonth;
  final bool showWeekday;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final scaler = MediaQuery.textScalerOf(context);
    final dateWidth = scaler.scale(13) * 2;
    final todayWidth = scaler.scale(12);
    final textGrowth = (scaler.scale(13) - 13).clamp(0.0, double.infinity);
    final prefix = showWeekday ? 'calendar-week' : 'calendar';
    final dateId = '${date.year}-${date.month}-${date.day}';
    final updateLabel = !inMonth
        ? '非本月日期'
        : hasUnwatched
        ? '有未看更新'
        : hasUpdate
        ? '有更新'
        : '没有更新';
    final statusLabel = '${isToday ? '，今天' : ''}，$updateLabel';
    final textColor = selected
        ? scheme.onPrimary
        : isToday
        ? scheme.primary
        : inMonth
        ? scheme.onSurface
        : scheme.onSurfaceVariant;
    return Semantics(
      label: '${date.year}年${date.month}月${date.day}日$statusLabel',
      button: true,
      selected: selected,
      child: InkWell(
        key: ValueKey('$prefix-day-$dateId'),
        onTap: onTap,
        borderRadius: AppRadius.smAll,
        child: ExcludeSemantics(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showWeekday)
                Padding(
                  padding: const EdgeInsets.only(
                    top: AppSpace.xs,
                    bottom: AppSpace.xs,
                  ),
                  child: Text(
                    followingCalendarWeekdayLabel(date),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              SizedBox(
                height: height + textGrowth,
                child: Column(
                  children: [
                    Expanded(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (isToday) SizedBox(width: todayWidth),
                          Container(
                            key: isToday && !showWeekday
                                ? const ValueKey('calendar-today')
                                : null,
                            width: dateWidth,
                            height: double.infinity,
                            alignment: Alignment.center,
                            decoration: selected
                                ? BoxDecoration(
                                    color: scheme.primary,
                                    borderRadius: AppRadius.pillAll,
                                  )
                                : null,
                            child: Text(
                              '${date.day}',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: textColor,
                                fontWeight: selected || isToday
                                    ? FontWeight.w700
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                          if (isToday)
                            SizedBox(
                              width: todayWidth,
                              child: Text(
                                '今',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.primary,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    SizedBox(
                      height: 8,
                      child: hasUpdate
                          ? Center(
                              child: Container(
                                key: ValueKey('$prefix-dot-$dateId'),
                                width: hasUnwatched ? 6 : 4,
                                height: hasUnwatched ? 6 : 4,
                                decoration: BoxDecoration(
                                  color: hasUnwatched
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            )
                          : null,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CalendarWeekStrip extends StatelessWidget {
  const _CalendarWeekStrip({
    required this.week,
    required this.today,
    required this.selected,
    required this.onTap,
  });

  final CalendarWeek week;
  final DateTime today;
  final DateTime selected;
  final ValueChanged<DateTime> onTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const ValueKey('calendar-week-strip'),
      children: [
        for (final day in week.days)
          Expanded(
            child: _CalendarDateButton(
              date: day.date,
              height: 30,
              isToday: _isSameDay(day.date, today),
              hasUpdate: day.isNotEmpty,
              hasUnwatched: day.unwatchedCount > 0,
              selected: _isSameDay(day.date, selected),
              onTap: () => onTap(day.date),
              showWeekday: true,
            ),
          ),
      ],
    );
  }
}

/// 列表分段标题：日期与当日更新摘要。
class _CalendarDayHeader extends StatelessWidget {
  const _CalendarDayHeader({
    super.key,
    required this.day,
    required this.selected,
  });

  final CalendarDay day;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 部数按 identityKey 去重（一集一条时条目数不等于剧数）。
    final summary = followingCalendarDaySummary(day.entries);
    return Row(
      children: [
        Container(
          key: selected
              ? ValueKey(
                  'calendar-day-selected-${day.date.year}-${day.date.month}-${day.date.day}',
                )
              : null,
          width: 3,
          height: 18,
          decoration: BoxDecoration(
            color: selected ? scheme.primary : Colors.transparent,
            borderRadius: AppRadius.pillAll,
          ),
        ),
        const SizedBox(width: AppSpace.sm),
        Text(
          '${day.date.month}月${day.date.day}日',
          key: ValueKey(
            'calendar-day-header-${day.date.year}-'
            '${day.date.month}-${day.date.day}',
          ),
          style: theme.textTheme.titleSmall?.copyWith(
            color: selected ? scheme.primary : scheme.onSurface,
          ),
        ),
        const SizedBox(width: AppSpace.md),
        Flexible(
          child: Text(
            summary.label,
            key: ValueKey(
              'calendar-day-summary-${day.date.year}-'
              '${day.date.month}-${day.date.day}',
            ),
            style: theme.textTheme.labelMedium?.copyWith(
              color: summary.hasUnwatched
                  ? scheme.primary
                  : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// 两个 `DateTime` 是否同一天。
bool _isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 条目卡片：剧名 + 集号（区分度最高）→ 分集标题 → 仅首卡的剧级进度与来源。
class _CalendarEntryCard extends StatelessWidget {
  const _CalendarEntryCard({
    required this.entry,
    required this.platformLabel,
    required this.showSeriesInfo,
    required this.releasedEpisode,
    required this.onPlay,
    required this.onShowDetails,
  });

  final CalendarEntry entry;

  /// 播放平台标签（TMDB 台名）；空串表示整块不渲染。
  final String platformLabel;

  /// 是否展示剧级信息（该剧当天的首条卡才为 true）。
  final bool showSeriesInfo;

  /// 本线路已可播集数（播出进度的分子），来自 `Following.releasedEpisode`。
  final int releasedEpisode;

  final ValueChanged<CalendarEntry> onPlay;
  final ValueChanged<CalendarEntry> onShowDetails;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final total = entry.totalEpisodes;
    final released = releasedEpisode < 0 ? 0 : releasedEpisode;
    final airRatio = total > 0 ? (released / total).clamp(0.0, 1.0) : 0.0;
    final percent = (airRatio * 100).floor();
    final suffix = entry.code;
    final title = entry.episodeTitle.trim();
    return Container(
      key: ValueKey('calendar-card-${entry.identityKey}-$suffix'),
      padding: const EdgeInsets.all(1),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: AppRadius.lgAll,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('calendar-entry-${entry.identityKey}-$suffix'),
          onTap: () => onPlay(entry),
          onLongPress: () => onShowDetails(entry),
          borderRadius: AppRadius.lgAll,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.lg,
              vertical: AppSpace.md,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  child: SizedBox(
                    width: 48,
                    height: 72,
                    child: PosterImage(url: entry.vodPic),
                  ),
                ),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 主行：剧名后紧跟集号，一集一条时它是唯一的区分信息。
                      Row(
                        children: [
                          // 剧名组用 Flexible 而不是 Expanded：平台徽标是**非弹性**的
                          // 定宽内容，先于剧名拿到自己的宽度，剩余空间才给剧名，
                          // 因此长台名不会把主行撑溢出。
                          Flexible(
                            child: Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    entry.vodName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleSmall,
                                  ),
                                ),
                                const SizedBox(width: AppSpace.sm),
                                Text(
                                  entry.code,
                                  key: ValueKey(
                                    'calendar-code-${entry.identityKey}-$suffix',
                                  ),
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.primary,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (entry.episode >= 1) ...[
                                  const SizedBox(width: AppSpace.sm),
                                  FollowingBadge(
                                    key: ValueKey(
                                      'calendar-episode-state-'
                                      '${entry.identityKey}-$suffix',
                                    ),
                                    // 三态：已播未看 / 已播已看 / 排期在未来。
                                    text: entry.episodePending
                                        ? '待播'
                                        : (entry.episodeUnwatched
                                              ? '未看'
                                              : '已看'),
                                    emphasized: entry.episodeUnwatched,
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(width: AppSpace.sm),
                          // 平台徽标完整显示、不省略：卡片右侧本来就空着一大块，
                          // 长度由台名本身决定；空间不够时先挤压左侧剧名（Flexible），
                          // 而不是把平台截成「Hunan Television / …」。
                          //
                          // 平台是**剧级**信息：同一天同一部剧多集时只在首条出现，
                          // 与「第1季 · 线路已播」那行同一口径（[showSeriesInfo]）。
                          if (showSeriesInfo && platformLabel.isNotEmpty) ...[
                            FollowingBadge(
                              key: ValueKey(
                                'calendar-platform-'
                                '${entry.identityKey}-$suffix',
                              ),
                              text: platformLabel,
                              emphasized: false,
                            ),
                            const SizedBox(width: AppSpace.sm),
                          ],
                          Icon(
                            Icons.chevron_right,
                            size: 18,
                            color: scheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                      // 副行：该集标题（TMDB）；未知时整行省略，不留空白。
                      if (title.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            title,
                            key: ValueKey(
                              'calendar-title-${entry.identityKey}-$suffix',
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 11,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      // 剧级信息每天每剧只出现一次：同剧多集时重复的只是剧名。
                      if (showSeriesInfo) ...[
                        const SizedBox(height: AppSpace.xs),
                        Wrap(
                          spacing: AppSpace.sm,
                          runSpacing: AppSpace.xs,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              _airLine(entry, released),
                              key: ValueKey(
                                'calendar-aired-${entry.identityKey}-$suffix',
                              ),
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontSize: 11,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            // 百分比只在分母是官方总集数时给；线路分母不是总集数。
                            if (entry.hasOfficialTotal)
                              Text(
                                '$percent%',
                                key: ValueKey(
                                  'calendar-percent-${entry.identityKey}-'
                                  '$suffix',
                                ),
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: entry.episodeUnwatched
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                                ),
                              ),
                            // 来源必须能被用户看到：real 表示日期来自平台排期（数据源
                            // 是 TMDB 等元数据源，文案不暴露供应商），不代表已经播出
                            // （未来集见集级「待播」）；local 是本地推算。
                            FollowingBadge(
                              key: ValueKey(
                                'calendar-source-${entry.identityKey}-$suffix',
                              ),
                              text: entry.source.label,
                              emphasized: false,
                            ),
                          ],
                        ),
                        // 限宽：1280 宽下整行横跨会读成一条分隔线，280 仍能读出进度差。
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 280),
                          child: SizedBox(
                            width: 280,
                            height: 4,
                            child: ClipRRect(
                              key: ValueKey(
                                'calendar-air-progress-${entry.identityKey}-'
                                '$suffix',
                              ),
                              borderRadius: AppRadius.pillAll,
                              child: LinearProgressIndicator(
                                value: airRatio,
                                minHeight: 4,
                                backgroundColor: scheme.surfaceContainerHighest,
                                color: entry.hasOfficialTotal
                                    ? scheme.primary
                                    : scheme.outline,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 剧级播出进度行。
///
/// 分子恒是**本线路已可播集数**（不是排期到的集号），因此写「线路已播」；
/// 有未来排期时补一句排期上限，解释为什么集号可能大于已播集数。
/// 排期数据来自 TMDB 等元数据源，但用户可见文案不出现供应商名字。
String _airLine(CalendarEntry entry, int released) {
  // 只有跟踪季下标，不把下标误写成该剧总季数。
  final season = '第${entry.season + 1}季';
  final aired = switch (entry.totalSource) {
    CalendarTotalSource.official => '线路已播 $released / ${entry.totalEpisodes} 集',
    CalendarTotalSource.line ||
    CalendarTotalSource.unknown => '线路已播 $released 集',
  };
  final schedule = entry.airingThroughEpisode > released
      ? ' · 平台排期至 E${entry.airingThroughEpisode}'
      : '';
  return '$season · $aired$schedule';
}

/// 淡色小标签（集级状态与来源标记共用）。
/// 没有任何追番时的空态。
class _CalendarEmpty extends StatelessWidget {
  const _CalendarEmpty();

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const ValueKey('calendar-following-empty'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.calendar_month, size: 44),
          const SizedBox(height: AppSpace.sm),
          const Text('还没有追剧，日历暂时没有内容'),
          const SizedBox(height: AppSpace.xs),
          const Text(
            '在影片详情页点右上角 ★ 加入追剧后，这里会按日期列出更新。',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// 追番存在、但当前视图（本周/本月）没有任何更新。
class _CalendarDayEmpty extends StatelessWidget {
  const _CalendarDayEmpty();

  @override
  Widget build(BuildContext context) {
    return const Center(
      key: ValueKey('calendar-day-empty'),
      child: Text('这段时间没有更新', style: TextStyle(fontSize: 12)),
    );
  }
}
