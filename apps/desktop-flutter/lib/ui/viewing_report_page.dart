/// 观影报告页（Phase 9 · P2-2）。
///
/// 数据来自本地 `history` 表；不联网也能产出完整基础报告。
/// AI 解读是可选叠加：未配置时按钮禁用并说明，失败时只提示错误、不移除基础报告。
library;

import 'package:flutter/material.dart';

import '../core/ai_config.dart';
import '../core/viewing_report.dart';
import '../services/storage.dart';
import '../services/viewing_report_ai.dart';
import 'viewing_report_ai_view.dart';
import '../state/app_state.dart';
import 'tokens.dart';

class ViewingReportPage extends StatefulWidget {
  const ViewingReportPage({
    super.key,
    required this.state,
    this.historyOverride,
    this.analyzer,
    this.now,
    this.aiConfigOverride,
  });

  final AppState state;

  /// 测试注入：不传时读 `state.recentHistory(limit: 100000)`。
  final List<PlaybackHistory>? historyOverride;

  /// 测试注入：默认 `ViewingReportAiAnalyzer()`。
  final ViewingReportAiAnalyzer? analyzer;

  /// 测试注入：固定「现在」让范围与徽章可复现。
  final DateTime? now;

  /// 测试注入：不传时用 `state.aiConfig`（未 bootstrap 的 AppState 不能读它）。
  final AiConfig? aiConfigOverride;

  @override
  State<ViewingReportPage> createState() => _ViewingReportPageState();
}

class _ViewingReportPageState extends State<ViewingReportPage> {
  late final List<PlaybackHistory> _records;
  late final ViewingReportAiAnalyzer _analyzer;
  ViewingReportRange _range = ViewingReportRange.all;
  ViewingReportAiResult? _aiResult;
  bool _aiLoading = false;

  @override
  void initState() {
    super.initState();
    _records =
        widget.historyOverride ??
        widget.state.recentHistory(limit: 100000);
    _analyzer = widget.analyzer ?? ViewingReportAiAnalyzer();
  }

  ViewingReport get _report => generateViewingReport(
    records: _records,
    range: _range,
    now: widget.now,
  );

  /// 未 bootstrap 的 `AppState`（部分单元测试/诊断场景）读 `aiConfig` 会抛
  /// `LateInitializationError`；这里回落到「未配置」，基础报告仍然可用。
  AiConfig get _aiConfig {
    final override = widget.aiConfigOverride;
    if (override != null) return override;
    try {
      return widget.state.aiConfig;
    } catch (_) {
      return const AiConfig();
    }
  }

  Future<void> _analyze(ViewingReport report) async {
    if (_aiLoading) return;
    setState(() {
      _aiLoading = true;
      _aiResult = null;
    });
    final result = await _analyzer.analyze(
      config: _aiConfig,
      report: report,
    );
    if (!mounted) return;
    setState(() {
      _aiLoading = false;
      _aiResult = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('观影报告'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<ViewingReportRange>(
                key: const ValueKey('viewing-report-range'),
                value: _range,
                dropdownColor: theme.colorScheme.surfaceContainerHigh,
                items: [
                  for (final range in ViewingReportRange.values)
                    DropdownMenuItem(
                      value: range,
                      child: Text(
                        widget.now == null
                            ? range.label
                            : range.displayLabel(widget.now!),
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _range = value);
                },
              ),
            ),
          ),
        ],
      ),
      body: report.isEmpty
          ? _EmptyReport(range: report.range)
          : ListView(
              key: const ValueKey('viewing-report-list'),
              padding: const EdgeInsets.all(AppSpace.lg),
              children: [
                _SummaryGrid(report: report),
                const SizedBox(height: AppSpace.lg),
                _Section(
                  title: '观看时段',
                  child: _TimeSlotBars(report: report),
                ),
                if (report.badges.isNotEmpty) ...[
                  const SizedBox(height: AppSpace.lg),
                  _Section(
                    title: '徽章',
                    child: Wrap(
                      spacing: AppSpace.sm,
                      runSpacing: AppSpace.sm,
                      children: [
                        for (final badge in report.badges)
                          _BadgeChip(badge: badge),
                      ],
                    ),
                  ),
                ],
                if (report.topVods.isNotEmpty) ...[
                  const SizedBox(height: AppSpace.lg),
                  _Section(
                    title: '最常看',
                    child: Column(
                      children: [
                        for (final vod in report.topVods)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.movie_outlined, size: 18),
                            title: Text(
                              vod.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Text(
                              '${vod.watchMinutes} 分钟 · ${vod.episodes} 条',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: AppSpace.lg),
                _Section(
                  title: 'AI 解读（可选）',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '只读取上面的本地统计结果。未配置或调用失败都不影响基础报告。',
                        style: TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: AppSpace.sm),
                      if (!_aiConfig.isReady)
                        Text(
                          'AI 未配置：基础报告已完整生成。',
                          key: const ValueKey('viewing-report-ai-unconfigured'),
                          style: theme.textTheme.bodySmall,
                        )
                      else
                        Row(
                          children: [
                            FilledButton.icon(
                              key: const ValueKey('viewing-report-ai-run'),
                              onPressed: _aiLoading
                                  ? null
                                  : () => _analyze(report),
                              icon: _aiLoading
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.auto_awesome, size: 18),
                              label: Text(_aiLoading ? '生成中…' : '生成 AI 解读'),
                            ),
                          ],
                        ),
                      if (_aiResult != null) ...[
                        const SizedBox(height: AppSpace.sm),
                        if (_aiResult!.ok)
                          ViewingReportAiNarrativeView(text: _aiResult!.text)
                        else
                          Text(
                            'AI 解读失败：${_aiResult!.message}（基础报告不受影响）',
                            key: const ValueKey('viewing-report-ai-error'),
                            style: TextStyle(
                              color: theme.colorScheme.error,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _EmptyReport extends StatelessWidget {
  const _EmptyReport({required this.range});

  final ViewingReportRange range;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insights_outlined, size: 40),
          const SizedBox(height: AppSpace.sm),
          Text('${range.label}还没有观看记录'),
          const SizedBox(height: AppSpace.xs),
          const Text(
            '播放任意影片后，这里会统计时长、完播率与观看时段。',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _SummaryGrid extends StatelessWidget {
  const _SummaryGrid({required this.report});

  final ViewingReport report;

  @override
  Widget build(BuildContext context) {
    final items = <({String label, String value, String hint})>[
      (
        label: '观看时长',
        value: '${report.totalWatchMinutes} 分钟',
        hint: '按每条记录看到的位置累计',
      ),
      (
        label: '作品',
        value: '${report.uniqueVodCount} 部',
        hint: '同名（去标点）只算一部',
      ),
      (
        label: '记录',
        value: '${report.totalEpisodeCount} 条',
        hint: '每条历史算一集/一次',
      ),
      (
        label: '完播率',
        value: '${(report.completionRate * 100).round()}%',
        hint: '进度 ≥ 90% 视为完播',
      ),
      (
        label: '深夜观影',
        value: '${report.lateNightCount} 次',
        hint: '23:00–06:00',
      ),
      (
        label: '周末占比',
        value: '${(report.weekendRatio * 100).round()}%',
        hint: '按最后观看时间统计',
      ),
    ];
    return Wrap(
      spacing: AppSpace.md,
      runSpacing: AppSpace.md,
      children: [
        for (final item in items)
          Container(
            width: 180,
            padding: const EdgeInsets.all(AppSpace.md),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              borderRadius: AppRadius.mdAll,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.label, style: const TextStyle(fontSize: 12)),
                const SizedBox(height: AppSpace.xs),
                Text(
                  item.value,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: AppSpace.xs),
                Text(item.hint, style: const TextStyle(fontSize: 11)),
              ],
            ),
          ),
      ],
    );
  }
}

class _TimeSlotBars extends StatelessWidget {
  const _TimeSlotBars({required this.report});

  final ViewingReport report;

  @override
  Widget build(BuildContext context) {
    final max = report.timeSlots.values.fold<int>(0, (a, b) => a > b ? a : b);
    return Column(
      children: [
        for (final slot in ViewingTimeSlot.values)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(width: 44, child: Text(slot.label)),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: max == 0 ? 0 : report.timeSlots[slot]! / max,
                      minHeight: 8,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                SizedBox(
                  width: 32,
                  child: Text(
                    '${report.timeSlots[slot]}',
                    textAlign: TextAlign.end,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _BadgeChip extends StatelessWidget {
  const _BadgeChip({required this.badge});

  final ViewingBadge badge;

  @override
  Widget build(BuildContext context) {
    final icon = switch (badge.id) {
      'night_owl' => Icons.nightlight_outlined,
      'drama_king' => Icons.live_tv_outlined,
      'finisher' => Icons.emoji_events_outlined,
      _ => Icons.workspace_premium_outlined,
    };
    return Chip(
      avatar: Icon(icon, size: 16),
      label: Text('${badge.label} · ${badge.detail}'),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: AppSpace.sm),
        child,
      ],
    );
  }
}
