/// 本地观影报告；AI 仅在用户主动请求时叠加解读。
library;

import 'package:flutter/material.dart';

import '../core/ai_config.dart';
import '../core/viewing_metadata.dart';
import '../core/viewing_report.dart';
import '../services/storage.dart';
import '../services/viewing_report_ai.dart';
import '../state/app_state.dart';
import 'tokens.dart';
import 'viewing_report_ai_view.dart';
import 'viewing_report_sections.dart';

class ViewingReportPage extends StatefulWidget {
  const ViewingReportPage({
    super.key,
    required this.state,
    this.historyOverride,
    this.metadataOverride,
    this.analyzer,
    this.now,
    this.aiConfigOverride,
  });
  final AppState state;
  final List<PlaybackHistory>? historyOverride;
  final Map<int, ViewingMetadata>? metadataOverride;
  final ViewingReportAiAnalyzer? analyzer;
  final DateTime? now;
  final AiConfig? aiConfigOverride;

  @override
  State<ViewingReportPage> createState() => _ViewingReportPageState();
}

class _ViewingReportPageState extends State<ViewingReportPage> {
  late final List<PlaybackHistory> _records;
  late final Map<int, ViewingMetadata> _metadata;
  late final ViewingReportAiAnalyzer _analyzer;
  ViewingReportRange _range = ViewingReportRange.all;
  ViewingReportAiResult? _aiResult;
  bool _aiLoading = false;
  int _aiGeneration = 0;

  @override
  void initState() {
    super.initState();
    _records =
        widget.historyOverride ?? widget.state.recentHistory(limit: 100000);
    _metadata =
        widget.metadataOverride ?? widget.state.viewingReportMetadata(_records);
    _analyzer = widget.analyzer ?? ViewingReportAiAnalyzer();
  }

  ViewingReport get _report => generateViewingReport(
    records: _records,
    range: _range,
    now: widget.now,
    metadata: _metadata,
  );

  AiConfig get _aiConfig {
    if (widget.aiConfigOverride != null) return widget.aiConfigOverride!;
    try {
      return widget.state.aiConfig;
    } catch (_) {
      return const AiConfig();
    }
  }

  void _changeRange(ViewingReportRange? range) {
    if (range == null || range == _range) return;
    setState(() {
      _range = range;
      _aiGeneration++;
      _aiResult = null;
      _aiLoading = false;
    });
  }

  Future<void> _analyze(ViewingReport report) async {
    if (_aiLoading) return;
    final generation = ++_aiGeneration;
    setState(() {
      _aiLoading = true;
      _aiResult = null;
    });
    ViewingReportAiResult result;
    try {
      result = await _analyzer.analyze(config: _aiConfig, report: report);
    } catch (_) {
      result = const ViewingReportAiResult(
        ok: false,
        text: '',
        message: '请求异常，请稍后重试',
      );
    }
    if (!mounted || generation != _aiGeneration) return;
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
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
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
                onChanged: _changeRange,
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
                ViewingReportSummaryGrid(report: report),
                const SizedBox(height: AppSpace.md),
                Text(
                  '统计口径：时长累计历史记录的播放位置，并非实际观看会话计时；时段与周末按最后观看时间统计。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                ViewingReportComparisonSection(report: report),
                ViewingReportSection(
                  title: '观看时段',
                  child: Column(
                    children: [
                      ViewingReportTimeSlotBars(report: report),
                      const SizedBox(height: AppSpace.lg),
                      ViewingReportHeatmap(report: report),
                    ],
                  ),
                ),
                ViewingReportPreferences(report: report),
                if (report.badges.isNotEmpty)
                  ViewingReportSection(
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
                ViewingReportSources(report: report),
                if (report.topVods.isNotEmpty)
                  ViewingReportSection(
                    title: '最常看',
                    child: Column(
                      children: [
                        for (final vod in report.topVods)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: AppSpace.md,
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.movie_outlined, size: 18),
                                const SizedBox(width: AppSpace.md),
                                Expanded(
                                  child: Tooltip(
                                    message: vod.name,
                                    child: Text(
                                      vod.name,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: AppSpace.md),
                                Text(
                                  '${vod.watchMinutes} 分钟 · ${vod.episodes} 条',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontFeatures: kTabularFigures,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ViewingReportSection(
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
                        FilledButton.icon(
                          key: const ValueKey('viewing-report-ai-run'),
                          onPressed: _aiLoading ? null : () => _analyze(report),
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
                      if (_aiResult != null) ...[
                        const SizedBox(height: AppSpace.sm),
                        if (_aiResult!.ok)
                          ViewingReportAiNarrativeView(text: _aiResult!.text)
                        else
                          Text(
                            'AI 解读失败：${_aiResult!.message}（基础报告不受影响）',
                            key: const ValueKey('viewing-report-ai-error'),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.error,
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
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insights_outlined, size: 40),
          const SizedBox(height: AppSpace.sm),
          Text('${range.label}还没有观看记录', textAlign: TextAlign.center),
          const SizedBox(height: AppSpace.xs),
          const Text(
            '播放任意影片后，这里会统计时长、完播率与观看时段。',
            style: TextStyle(fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}

class _BadgeChip extends StatelessWidget {
  const _BadgeChip({required this.badge});
  final ViewingBadge badge;

  @override
  Widget build(BuildContext context) => Chip(
    avatar: Icon(switch (badge.id) {
      'night_owl' => Icons.nightlight_outlined,
      'drama_king' => Icons.live_tv_outlined,
      'finisher' => Icons.emoji_events_outlined,
      'explorer' => Icons.public_outlined,
      _ => Icons.workspace_premium_outlined,
    }, size: 16),
    label: Text('${badge.label} · ${badge.detail}'),
    visualDensity: VisualDensity.compact,
  );
}
