/// 追剧日历页（Phase 9 · P2-1 配套）。
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
import '../core/protocol.dart';
import '../core/tmdb_detail_model.dart';
import '../core/tmdb_identity.dart';
import '../services/following_air_time_service.dart';
import '../services/storage.dart';
import '../state/app_state.dart';
import 'app.dart';
import 'browse_pages.dart';
import 'playback_resume.dart';
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

class FollowingCalendarPage extends StatefulWidget {
  const FollowingCalendarPage({super.key, required this.state});

  final AppState state;

  @override
  State<FollowingCalendarPage> createState() => _FollowingCalendarPageState();
}

class _FollowingCalendarPageState extends State<FollowingCalendarPage> {
  /// 当前视图（默认整月，与历史行为一致）。
  _CalendarView _view = _CalendarView.month;

  /// 可见月份（当月 1 日 0:00）。
  late DateTime _month;

  /// 选中的自然日（0:00）；周视图以它为锚点，列表把它的分段高亮。
  late DateTime _selected;

  /// 真实播出时间（TMDB）；加载中/失败/未配置时为空列表。
  List<FollowingAirTime> _airTimes = const [];

  /// 官方该季总集数（TMDB）；空表示全部降级到本线路可播集数。
  List<FollowingSeasonTotal> _seasonTotals = const [];

  /// 最近一次发起加载时的追番身份集合（用于判断追番变化后是否需要重取）。
  String _loadedKey = '';

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
    _loadRealData();
  }

  @override
  void dispose() {
    _state.removeListener(_onStateChanged);
    _listController.dispose();
    super.dispose();
  }

  void _onStateChanged() {
    if (!mounted) return;
    setState(() {});
    _loadRealData();
  }

  /// 追番集合变化后重取播出时间与官方总集数（两者共享同一次 TMDB 请求）。
  void _loadRealData() {
    final items = _state.followings;
    final key = items.map((item) => item.identityKey).join(',');
    if (key == _loadedKey) return;
    _loadedKey = key;
    if (items.isEmpty) {
      // 追番为空时由上层的 setState 一并刷新，这里不再额外触发重建。
      _airTimes = const [];
      _seasonTotals = const [];
      return;
    }
    final interactionVersion = _interactionVersion;
    unawaited(() async {
      final airTimes = await _state.followingAirTimes();
      if (!mounted || _loadedKey != key) return;
      final totals = await _state.followingSeasonTotals();
      if (!mounted || _loadedKey != key) return;
      setState(() {
        _airTimes = airTimes;
        _seasonTotals = totals;
        // 数据改变布局后补定位，但不覆盖加载期间的用户操作。
        if (interactionVersion == _interactionVersion) _locateSelected = true;
      });
    }());
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

  /// 某天的条目卡：剧级信息（已播/进度条/来源）只在当天该剧的**首条**出现一次。
  List<Widget> _dayCards(CalendarDay day) {
    final leads = followingCalendarSeriesLeadIndexes(day.entries);
    return [
      for (final (index, entry) in day.entries.indexed)
        _CalendarEntryCard(
          entry: entry,
          showSeriesInfo: leads.contains(index),
          releasedEpisode: _itemFor(entry)?.releasedEpisode ?? entry.episode,
          onPlay: _playEntry,
          onShowDetails: (entry) => _showEntryDetails(entry, day.date),
        ),
    ];
  }

  Future<void> _showEntryDetails(CalendarEntry entry, DateTime day) async {
    final item = _itemFor(entry);
    var date = day;
    for (final airTime in _airTimes) {
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
          appBar: AppBar(title: const Text('搜索站源')),
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
      showToast('该追番已不在列表中：${entry.vodName}', kind: ToastKind.error);
      return;
    }
    final isLatest =
        entry.episode >= 1 && entry.episode == item.releasedEpisode;
    if (!isLatest || item.latestEpisodeTarget.isEmpty) {
      if (entry.episode >= 1 && !isLatest) {
        showToast('${entry.code} 不是最新一集，请在详情页选集播放', kind: ToastKind.info);
      }
      await _openDetail(item);
      return;
    }
    final history = PlaybackHistory(
      id: 0,
      siteKey: item.siteKey,
      vodId: item.vodId,
      vodName: item.vodName,
      vodPic: item.vodPic,
      flag: item.sourceFlag.isEmpty ? item.flag : item.sourceFlag,
      episodeName: item.latestEpisodeName,
      episodeId: item.latestEpisodeTarget,
      positionMs: 0,
      durationMs: 0,
      updatedAt: item.updatedAtMs,
    );
    await resumeHistoryEntry(context, _state, history);
    if (!mounted) return;
    await _state.markFollowingWatched(item);
  }

  Future<void> _openDetail(Following item) async {
    final config = _state.config;
    final site = config?.sites
        .where((candidate) => candidate.key == item.siteKey)
        .firstOrNull;
    if (site == null) {
      showToast('该追番所属站点已不在当前配置中：${item.siteKey}', kind: ToastKind.error);
      return;
    }
    await _state.selectSite(site);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailPage(
          state: _state,
          vod: Vod(
            vodId: item.vodId,
            vodName: item.vodName,
            vodPic: item.vodPic,
          ),
          historyFlag: item.flag,
        ),
      ),
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
      for (final total in _seasonTotals) total.identityKey: total.totalEpisodes,
    };
    final byDay = followingCalendarByDay(
      items: items,
      nowMs: nowMs,
      airTimes: _airTimes,
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
                child: SingleChildScrollView(
                  primary: false,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpace.md,
                          vertical: AppSpace.xs,
                        ),
                        child: SizedBox(
                          height: 40,
                          child: Row(
                            children: [
                              IconButton(
                                key: const ValueKey('calendar-prev-month'),
                                tooltip: _view == _CalendarView.week
                                    ? '上一周'
                                    : '上一月',
                                icon: const Icon(Icons.chevron_left),
                                onPressed: () => _view == _CalendarView.week
                                    ? _shiftWeek(-1)
                                    : _shiftMonth(-1),
                              ),
                              Text(
                                '${_month.year}年${_month.month}月',
                                key: const ValueKey('calendar-title'),
                                style: theme.textTheme.titleMedium,
                              ),
                              IconButton(
                                key: const ValueKey('calendar-next-month'),
                                tooltip: _view == _CalendarView.week
                                    ? '下一周'
                                    : '下一月',
                                icon: const Icon(Icons.chevron_right),
                                onPressed: () => _view == _CalendarView.week
                                    ? _shiftWeek(1)
                                    : _shiftMonth(1),
                              ),
                              if (_view == _CalendarView.week) ...[
                                const SizedBox(width: AppSpace.sm),
                                Text(
                                  '${week.start.month}月${week.start.day}日 - '
                                  '${week.end.month}月${week.end.day}日',
                                  key: const ValueKey('calendar-week-title'),
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                              const Spacer(),
                              TextButton(
                                key: const ValueKey('calendar-today-button'),
                                onPressed: _goToday,
                                child: const Text('今日'),
                              ),
                              const SizedBox(width: AppSpace.sm),
                              _ViewToggle(view: _view, onChanged: _setView),
                            ],
                          ),
                        ),
                      ),
                      if (items.isNotEmpty) ...[
                        if (_view == _CalendarView.week)
                          _CalendarWeekStrip(
                            week: week,
                            today: today,
                            selected: _selected,
                            onTap: _selectDay,
                          )
                        else ...[
                          // 周一至周日表头。
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Row(
                              key: const ValueKey('calendar-weekdays'),
                              children: [
                                for (final label
                                    in followingCalendarWeekdayLabels)
                                  Expanded(
                                    child: Text(
                                      label,
                                      textAlign: TextAlign.center,
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpace.md,
                              vertical: 2,
                            ),
                            child: Column(
                              key: const ValueKey('calendar-grid'),
                              children: [
                                for (final week in month.weeks)
                                  Row(
                                    children: [
                                      for (final cell in week)
                                        Expanded(
                                          child: _CalendarDayCell(
                                            key:
                                                _isSameDay(cell.date, _selected)
                                                ? _selectedCell
                                                : null,
                                            cell: cell,
                                            height: cellHeight,
                                            isToday:
                                                cell.date.year == today.year &&
                                                cell.date.month ==
                                                    today.month &&
                                                cell.date.day == today.day,
                                            hasUpdate:
                                                cell.inMonth &&
                                                dayUpdates.containsKey(
                                                  cell.date.day,
                                                ),
                                            hasUnwatched:
                                                cell.inMonth &&
                                                (dayUpdates[cell.date.day] ??
                                                    false),
                                            selected:
                                                cell.date.year ==
                                                    _selected.year &&
                                                cell.date.month ==
                                                    _selected.month &&
                                                cell.date.day == _selected.day,
                                            onTap: () => _selectDay(cell.date),
                                          ),
                                        ),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
              if (items.isEmpty)
                const Expanded(child: _CalendarEmpty())
              else ...[
                const Divider(height: 1),
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
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                          children: [
                            // 各日段完整布局，远端日期也能定位；卡片之间用间隙，不用分隔线。
                            Column(
                              spacing: AppSpace.sm,
                              children: [
                                for (final day in days) ...[
                                  _CalendarDayHeader(
                                    key: _dayHeaders.putIfAbsent(
                                      day.date,
                                      GlobalKey.new,
                                    ),
                                    day: day,
                                    selected: _isSameDay(day.date, _selected),
                                  ),
                                  for (final card in _dayCards(day)) card,
                                ],
                              ],
                            ),
                          ],
                        ),
                      if (noUpdates)
                        Align(
                          alignment: Alignment.topCenter,
                          child: Material(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: AppRadius.smAll,
                            child: Padding(
                              padding: const EdgeInsets.all(AppSpace.sm),
                              child: Text(
                                '${_selected.month}月${_selected.day}日 没有更新',
                                key: const ValueKey('calendar-selected-empty'),
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                          ),
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
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: AppRadius.pillAll,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final option in _CalendarView.values)
            InkWell(
              key: ValueKey('calendar-view-${option.name}'),
              onTap: option == view ? null : () => onChanged(option),
              borderRadius: AppRadius.pillAll,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: option == view
                    ? BoxDecoration(
                        color: scheme.primary,
                        borderRadius: AppRadius.pillAll,
                      )
                    : null,
                child: Text(
                  option.label,
                  style: TextStyle(
                    fontSize: 12,
                    color: option == view
                        ? scheme.onPrimary
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 一个月历格子。
class _CalendarDayCell extends StatelessWidget {
  const _CalendarDayCell({
    super.key,
    required this.cell,
    required this.height,
    required this.isToday,
    required this.hasUpdate,
    required this.hasUnwatched,
    required this.selected,
    required this.onTap,
  });

  final CalendarCell cell;
  final double height;
  final bool isToday;

  /// 当天有条目。
  final bool hasUpdate;

  /// 当天存在未看的条目（与 [hasUpdate] 合起来决定圆点颜色）。
  final bool hasUnwatched;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textColor = isToday
        ? scheme.onPrimary
        : cell.inMonth
        ? scheme.onSurface
        : theme.disabledColor;
    return InkWell(
      key: ValueKey(
        'calendar-day-${cell.date.year}-${cell.date.month}-${cell.date.day}',
      ),
      onTap: onTap,
      borderRadius: AppRadius.smAll,
      child: SizedBox(
        height: height,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              key: isToday ? const ValueKey('calendar-today') : null,
              width: height - 8,
              height: height - 8,
              alignment: Alignment.center,
              decoration: isToday
                  ? BoxDecoration(color: scheme.primary, shape: BoxShape.circle)
                  : selected
                  ? BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: scheme.primary),
                    )
                  : null,
              child: Text(
                '${cell.dayOfMonth}',
                style: TextStyle(fontSize: 12, color: textColor),
              ),
            ),
            const SizedBox(height: 2),
            // 占位高度固定，有更新时才画小圆点，避免整行跳动。
            // 圆点颜色就是状态：存在未看 → 强调色实心；全部已看 → 弱化色小点。
            SizedBox(
              height: 6,
              child: !hasUpdate
                  ? null
                  : Center(
                      child: Container(
                        key: ValueKey(
                          'calendar-dot-${cell.date.year}-'
                          '${cell.date.month}-${cell.date.day}',
                        ),
                        width: hasUnwatched ? 6 : 4,
                        height: hasUnwatched ? 6 : 4,
                        decoration: BoxDecoration(
                          color: hasUnwatched
                              ? scheme.primary
                              : scheme.outlineVariant,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「整周」条带：周一 → 周日 7 天。
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Row(
        key: const ValueKey('calendar-week-strip'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final day in week.days)
            Expanded(
              child: _CalendarWeekDayCell(
                day: day,
                isToday: _isSameDay(day.date, today),
                selected: _isSameDay(day.date, selected),
                onTap: () => onTap(day.date),
              ),
            ),
        ],
      ),
    );
  }
}

/// 条带里的一天：星期字 + 日号 + 有更新时的圆点；今天/选中日左侧一条主题色竖条。
class _CalendarWeekDayCell extends StatelessWidget {
  const _CalendarWeekDayCell({
    required this.day,
    required this.isToday,
    required this.selected,
    required this.onTap,
  });

  final CalendarDay day;
  final bool isToday;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasUpdate = day.isNotEmpty;
    final hasUnwatched = day.unwatchedCount > 0;
    final active = isToday || selected;
    return InkWell(
      key: ValueKey(
        'calendar-week-day-${day.date.year}-'
        '${day.date.month}-${day.date.day}',
      ),
      onTap: onTap,
      borderRadius: AppRadius.smAll,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Row(
          children: [
            // 参考截图：今天/选中日左侧一条主题色竖条。
            Container(
              width: 3,
              height: 48,
              decoration: BoxDecoration(
                color: active ? scheme.primary : Colors.transparent,
                borderRadius: AppRadius.pillAll,
              ),
            ),
            const SizedBox(width: AppSpace.xs),
            Expanded(
              child: Column(
                children: [
                  Text(
                    followingCalendarWeekdayLabel(day.date),
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: AppSpace.xs),
                  Container(
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: isToday
                        ? BoxDecoration(
                            color: scheme.primary,
                            shape: BoxShape.circle,
                          )
                        : selected
                        ? BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: scheme.primary),
                          )
                        : null,
                    child: Text(
                      '${day.date.day}',
                      style: TextStyle(
                        fontSize: 12,
                        color: isToday ? scheme.onPrimary : scheme.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.xs),
                  // 固定占位，有更新才画圆点，避免整行跳动。
                  SizedBox(
                    height: 6,
                    child: !hasUpdate
                        ? null
                        : Center(
                            child: Container(
                              key: ValueKey(
                                'calendar-week-dot-${day.date.year}-'
                                '${day.date.month}-${day.date.day}',
                              ),
                              width: hasUnwatched ? 6 : 4,
                              height: hasUnwatched ? 6 : 4,
                              decoration: BoxDecoration(
                                color: hasUnwatched
                                    ? scheme.primary
                                    : scheme.outlineVariant,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 列表分段标题：左侧日期，右侧「N 部更新 · 未看 M 集」。
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
        const Spacer(),
        Text(
          summary.label,
          key: ValueKey(
            'calendar-day-summary-${day.date.year}-'
            '${day.date.month}-${day.date.day}',
          ),
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 11,
            color: summary.hasUnwatched
                ? scheme.primary
                : scheme.onSurfaceVariant,
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
    required this.showSeriesInfo,
    required this.releasedEpisode,
    required this.onPlay,
    required this.onShowDetails,
  });

  final CalendarEntry entry;

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
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: AppRadius.lgAll,
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .72)),
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
                          Expanded(
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
                                  _Badge(
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
                            _Badge(
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
class _Badge extends StatelessWidget {
  const _Badge({super.key, required this.text, required this.emphasized});

  final String text;

  /// `true` 用主色淡底（未看），`false` 用容器色（来源标记）。
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: emphasized
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        borderRadius: AppRadius.pillAll,
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: emphasized
              ? scheme.onPrimaryContainer
              : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

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
          const Text('还没有追番，日历暂时没有内容'),
          const SizedBox(height: AppSpace.xs),
          const Text(
            '在影片详情页点右上角 ★ 加入追番后，这里会按日期列出更新。',
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
