import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/viewing_report.dart';
import 'tokens.dart';

class ViewingReportSection extends StatelessWidget {
  const ViewingReportSection({
    super.key,
    required this.title,
    required this.child,
  });
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: AppSpace.xl),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSpace.sm),
        child,
      ],
    ),
  );
}

/// 平均每条时长：整数不带小数点，否则保留一位（与卡片里其它数值同一套读法）。
String _averageWatchLabel(double minutes) => minutes == minutes.roundToDouble()
    ? '${minutes.round()} 分钟'
    : '${minutes.toStringAsFixed(1)} 分钟';

class ViewingReportSummaryGrid extends StatelessWidget {
  const ViewingReportSummaryGrid({super.key, required this.report});
  final ViewingReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = <({String label, String value, String hint, String? key})>[
      (
        label: '观看时长',
        value: '${report.totalWatchMinutes} 分钟',
        hint: '按每条记录看到的位置累计',
        key: null,
      ),
      (
        label: '作品',
        value: '${report.uniqueVodCount} 部',
        hint: '同名（去标点）只算一部',
        key: null,
      ),
      (
        label: '记录',
        value: '${report.totalEpisodeCount} 条',
        hint: '每条历史算一集/一次',
        key: null,
      ),
      (
        label: '完播率',
        value: '${(report.completionRate * 100).round()}%',
        hint: '进度 ≥ 90% 视为完播',
        key: null,
      ),
      (
        label: '深夜观影',
        value: '${report.lateNightCount} 次',
        hint: '23:00–06:00',
        key: null,
      ),
      (
        label: '周末占比',
        value: '${(report.weekendRatio * 100).round()}%',
        hint: '按最后观看时间统计',
        key: null,
      ),
      (
        label: '平均每条',
        value: _averageWatchLabel(report.averageWatchMinutes),
        hint: '按记录条数平均',
        key: 'average',
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = width >= 1100
            ? 6
            : width >= 700
            ? 3
            : width >= 420
            ? 2
            : 1;
        final itemWidth = (width - AppSpace.md * (columns - 1)) / columns;
        return Wrap(
          spacing: AppSpace.md,
          runSpacing: AppSpace.md,
          children: [
            for (final item in items)
              Container(
                key: item.key == null
                    ? null
                    : ValueKey('viewing-summary-${item.key}'),
                width: itemWidth,
                padding: const EdgeInsets.all(AppSpace.lg),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: AppRadius.lgAll,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.label, style: theme.textTheme.bodySmall),
                    const SizedBox(height: AppSpace.xs),
                    Text(
                      item.value,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontFeatures: kTabularFigures,
                      ),
                    ),
                    const SizedBox(height: AppSpace.xs),
                    Text(
                      item.hint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class ViewingReportComparisonSection extends StatelessWidget {
  const ViewingReportComparisonSection({super.key, required this.report});
  final ViewingReport report;

  String _change(int current, int previous) {
    if (previous == 0) return current == 0 ? '无记录' : '新增';
    final percent = (current - previous) / previous * 100;
    return '${percent > 0 ? '+' : ''}${percent.toStringAsFixed(0)}%';
  }

  String _date(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}/${d.month}/${d.day}';
  }

  @override
  Widget build(BuildContext context) {
    final previous = report.comparison;
    return ViewingReportSection(
      title: '周期对比',
      child: previous == null
          ? Text(
              report.range == ViewingReportRange.all
                  ? '全部范围不提供上一周期对比。选择本周、本月等范围查看同期变化。'
                  : '当前范围尚未开始，暂无同期对比。',
              style: Theme.of(context).textTheme.bodySmall,
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '上一周期同期：${_date(previous.startMs)} — ${_date(previous.endMs)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: AppSpace.sm),
                Wrap(
                  spacing: AppSpace.xl,
                  runSpacing: AppSpace.sm,
                  children: [
                    Text(
                      '观看时长 ${_change(report.totalWatchMs, previous.totalWatchMs)} · 上期 ${previous.totalWatchMs ~/ 60000} 分钟',
                      key: const ValueKey('viewing-comparison-watch'),
                    ),
                    Text(
                      '作品 ${_change(report.uniqueVodCount, previous.uniqueVodCount)} · 上期 ${previous.uniqueVodCount} 部',
                      key: const ValueKey('viewing-comparison-vods'),
                    ),
                    Text(
                      '记录 ${_change(report.recordCount, previous.recordCount)} · 上期 ${previous.recordCount} 条',
                      key: const ValueKey('viewing-comparison-records'),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}

class ViewingReportTimeSlotBars extends StatelessWidget {
  const ViewingReportTimeSlotBars({super.key, required this.report});
  final ViewingReport report;

  @override
  Widget build(BuildContext context) {
    final max = report.timeSlots.values.fold<int>(0, math.max);
    return Column(
      children: [
        for (final slot in ViewingTimeSlot.values)
          Semantics(
            label: '${slot.label} · ${report.timeSlots[slot] ?? 0} 条记录',
            excludeSemantics: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
              child: Row(
                children: [
                  SizedBox(width: 44, child: Text(slot.label)),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: AppRadius.smAll,
                      child: LinearProgressIndicator(
                        value: max == 0
                            ? 0
                            : (report.timeSlots[slot] ?? 0) / max,
                        minHeight: 8,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  SizedBox(
                    width: 44,
                    child: Text(
                      '${report.timeSlots[slot] ?? 0}',
                      textAlign: TextAlign.end,
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(fontFeatures: kTabularFigures),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class ViewingReportHeatmap extends StatelessWidget {
  const ViewingReportHeatmap({super.key, required this.report});
  final ViewingReport report;
  static const _days = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  int _count(int day, int hour) =>
      day < report.weekdayHourCounts.length &&
          hour < report.weekdayHourCounts[day].length
      ? report.weekdayHourCounts[day][hour]
      : 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    var max = 0;
    for (var day = 0; day < 7; day++) {
      for (var hour = 0; hour < 24; hour++) {
        max = math.max(max, _count(day, hour));
      }
    }
    return Column(
      key: const ValueKey('viewing-report-heatmap'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('星期 × 小时', style: TextStyle(fontWeight: AppWeight.title)),
        const SizedBox(height: AppSpace.sm),
        LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: math.max(720, constraints.maxWidth),
              child: Column(
                children: [
                  Row(
                    children: [
                      const SizedBox(width: 44),
                      for (var hour = 0; hour < 24; hour++)
                        Expanded(
                          child: Center(
                            child: Text(
                              hour.toString().padLeft(2, '0'),
                              style: theme.textTheme.labelSmall,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpace.xs),
                  for (var day = 0; day < 7; day++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpace.xs),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 44,
                            child: Text(
                              _days[day],
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                          for (var hour = 0; hour < 24; hour++)
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 2,
                                ),
                                child: _cell(context, day, hour, max),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpace.xs),
        Text(
          '每格为记录数：空格 = 0（无记录） · 有记录才显示数字（最多 $max 条）。按历史最后观看时间统计。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _cell(BuildContext context, int day, int hour, int max) {
    final count = _count(day, hour);
    final scheme = Theme.of(context).colorScheme;
    final label =
        '${_days[day]} ${hour.toString().padLeft(2, '0')}:00–${(hour + 1).toString().padLeft(2, '0')}:00 · $count 条记录';
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        key: ValueKey('viewing-hour-$day-$hour'),
        label: label,
        excludeSemantics: true,
        child: Container(
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: AppRadius.smAll,
            color: count == 0
                ? scheme.surfaceContainerLow
                : Color.lerp(
                    scheme.surfaceContainerHigh,
                    scheme.primaryContainer,
                    max == 0 ? 0 : count / max,
                  ),
          ),
          child: Text(
            count == 0 ? '' : '$count',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: count == 0
                  ? scheme.onSurfaceVariant
                  : scheme.onPrimaryContainer,
              fontFeatures: kTabularFigures,
            ),
          ),
        ),
      ),
    );
  }
}

class ViewingReportPreferences extends StatelessWidget {
  const ViewingReportPreferences({super.key, required this.report});
  final ViewingReport report;

  @override
  Widget build(BuildContext context) => ViewingReportSection(
    title: '内容偏好',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '每条历史对每个标签计一次，不是作品级投票；各维度覆盖率独立计算，未知不进入榜单。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: AppSpace.md),
        Wrap(
          spacing: AppSpace.xl,
          runSpacing: AppSpace.sm,
          children: [
            Text(
              '电影 ${report.movieCount} 条',
              key: const ValueKey('viewing-report-type-movie'),
            ),
            Text(
              '剧集 ${report.tvCount} 条',
              key: const ValueKey('viewing-report-type-tv'),
            ),
            Text(
              '类型未知 ${report.unknownTypeCount} 条',
              key: const ValueKey('viewing-report-type-unknown'),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.lg),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 840 ? 2 : 1;
            final width =
                (constraints.maxWidth - AppSpace.xl * (columns - 1)) / columns;
            final dimensions =
                <
                  ({
                    String key,
                    String title,
                    List<ViewingPreferenceStat> stats,
                  })
                >[
                  (key: 'genre', title: '题材', stats: report.topGenres),
                  (key: 'area', title: '地区', stats: report.topAreas),
                  (key: 'actor', title: '演员', stats: report.topActors),
                  (key: 'director', title: '导演', stats: report.topDirectors),
                ];
            return Wrap(
              spacing: AppSpace.xl,
              runSpacing: AppSpace.xl,
              children: [
                for (final dimension in dimensions)
                  SizedBox(
                    width: width,
                    child: _PreferenceDimension(
                      key: ValueKey('viewing-preference-${dimension.key}'),
                      title: dimension.title,
                      stats: dimension.stats,
                      coverage: report.metadataCoverage[dimension.key] ?? 0,
                      total: report.recordCount,
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: AppSpace.md),
        Text(
          '缺失信息保留为未知。查看作品详情可增加本地元数据覆盖；已缓存的 TMDB 详情只补缺，打开报告不联网。',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
    ),
  );
}

class _PreferenceDimension extends StatelessWidget {
  const _PreferenceDimension({
    super.key,
    required this.title,
    required this.stats,
    required this.coverage,
    required this.total,
  });
  final String title;
  final List<ViewingPreferenceStat> stats;
  final int coverage, total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final max = stats.fold<int>(0, (n, stat) => math.max(n, stat.count));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: theme.textTheme.titleSmall),
        const SizedBox(height: AppSpace.xs),
        Text(
          '覆盖 $coverage/$total 条（${total == 0 ? 0 : (coverage / total * 100).round()}%） · 未知 ${total - coverage} 条',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        if (stats.isEmpty)
          Text('暂无已知$title信息', style: theme.textTheme.bodyMedium)
        else
          for (final stat in stats)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
              child: Semantics(
                label: '$title：${stat.name} · ${stat.count} 条记录',
                excludeSemantics: true,
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: Tooltip(
                        message: stat.name,
                        child: Text(
                          stat.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpace.md),
                    Expanded(
                      flex: 2,
                      child: LinearProgressIndicator(
                        value: max == 0 ? 0 : stat.count / max,
                        minHeight: 4,
                      ),
                    ),
                    const SizedBox(width: AppSpace.md),
                    SizedBox(
                      width: 52,
                      child: Text(
                        '${stat.count} 条',
                        textAlign: TextAlign.end,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFeatures: kTabularFigures,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}

class ViewingReportSources extends StatelessWidget {
  const ViewingReportSources({super.key, required this.report});
  final ViewingReport report;

  @override
  Widget build(BuildContext context) {
    final sourceNumbers = <String, int>{};
    for (final source in report.sources) {
      if (source.sourceKey.isNotEmpty) {
        sourceNumbers.putIfAbsent(
          source.sourceKey,
          () => sourceNumbers.length + 1,
        );
      }
    }
    final max = report.sources.fold<int>(
      0,
      (n, source) => math.max(n, source.count),
    );
    return ViewingReportSection(
      title: '站源分布',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '按配置来源 + 站点分组；配置编号仅用于本报告，不显示配置地址。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpace.sm),
          for (final source in report.sources)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
              child: _sourceRow(
                context,
                source,
                sourceNumbers[source.sourceKey],
                max,
              ),
            ),
        ],
      ),
    );
  }

  Widget _sourceRow(
    BuildContext context,
    ViewingSourceStat source,
    int? number,
    int max,
  ) {
    final site = source.siteKey.isEmpty
        ? '站点未知'
        : source.siteKey.contains('://') ||
              source.siteKey.contains('\\') ||
              source.siteKey.contains('/')
        ? '站点标识已隐藏'
        : source.siteKey;
    final label = '${number == null ? '来源不明' : '配置 $number'} · $site';
    return Semantics(
      label: '$label · ${source.count} 条记录',
      excludeSemantics: true,
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Tooltip(
              message: label,
              child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            flex: 2,
            child: LinearProgressIndicator(
              value: max == 0 ? 0 : source.count / max,
              minHeight: 4,
            ),
          ),
          const SizedBox(width: AppSpace.md),
          SizedBox(
            width: 64,
            child: Text(
              '${source.count} 条',
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(fontFeatures: kTabularFigures),
            ),
          ),
        ],
      ),
    );
  }
}
