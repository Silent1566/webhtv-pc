import 'dart:async';

import 'package:flutter/material.dart';

import '../core/protocol.dart';
import '../services/site_self_check.dart';
import '../services/site_service.dart';
import 'health_filter_controls.dart';
import 'settings_layout.dart';
import 'tokens.dart';

/// An additive, manual-only diagnostic surface. No browsing state is changed.
class SiteSelfCheckPanel extends StatefulWidget {
  const SiteSelfCheckPanel({
    super.key,
    required this.service,
    required this.sites,
  });
  final SiteService? service;
  final List<Site> sites;

  @override
  State<SiteSelfCheckPanel> createState() => _SiteSelfCheckPanelState();
}

enum _ManualStageFilter {
  any,
  success,
  failed,
  empty,
  timedOut,
  cancelled,
  running,
  notChecked,
}

const Map<_ManualStageFilter, String> _manualStageFilterLabels = {
  _ManualStageFilter.any: '全部状态',
  _ManualStageFilter.success: '成功',
  _ManualStageFilter.failed: '失败',
  _ManualStageFilter.empty: '空内容',
  _ManualStageFilter.timedOut: '超时',
  _ManualStageFilter.cancelled: '取消',
  _ManualStageFilter.running: '进行中',
  _ManualStageFilter.notChecked: '未检查',
};

_ManualStageFilter _manualStageFilterFrom(String label) =>
    _manualStageFilterLabels.entries
        .firstWhere((entry) => entry.value == label)
        .key;

const String _allCheckStatuses = '全部结论';

class _SiteSelfCheckPanelState extends State<SiteSelfCheckPanel> {
  SiteSelfCheck? _check;
  final Set<String> _selected = {};
  final TextEditingController _filterName = TextEditingController();
  SiteCheckStatus? _statusFilter;
  final Map<SiteCheckPhase, _ManualStageFilter> _phaseFilters = {
    for (final phase in SiteCheckPhase.values) phase: _ManualStageFilter.any,
  };
  String? _error;
  List<Site> get _sites {
    final configured =
        widget.service?.appConfig.sites.map((s) => s.key).toSet() ?? <String>{};
    final unique = <String, Site>{};
    for (final site in widget.sites) {
      if (configured.contains(site.key)) unique[site.key] = site;
    }
    return unique.values.toList();
  }

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    final service = widget.service;
    if (service != null) {
      _check = SiteSelfCheck(service: service)..addListener(_changed);
    }
  }

  void _detach() {
    _check?.removeListener(_changed);
    _check?.dispose();
    _check = null;
  }

  @override
  void didUpdateWidget(covariant SiteSelfCheckPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.service, widget.service)) {
      _detach();
      _selected.clear();
      _resetResultFilters(notify: false);
      _error = null;
      _attach();
    } else {
      _selected.retainAll(_sites.map((s) => s.key));
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _filterName.dispose();
    _detach();
    super.dispose();
  }

  bool get _hasResultFilters =>
      _filterName.text.trim().isNotEmpty ||
      _statusFilter != null ||
      _phaseFilters.values.any((filter) => filter != _ManualStageFilter.any);

  bool _phaseMatches(
    SiteCheckReport report,
    SiteCheckPhase phase,
    _ManualStageFilter filter,
  ) {
    final stages = report.stages.where((s) => s.phase == phase);
    return switch (filter) {
      _ManualStageFilter.any => true,
      _ManualStageFilter.notChecked => stages.isEmpty,
      _ManualStageFilter.success => stages.any(
        (s) => s.status == SiteCheckStageStatus.success,
      ),
      _ManualStageFilter.failed => stages.any(
        (s) => s.status == SiteCheckStageStatus.failed,
      ),
      _ManualStageFilter.empty => stages.any(
        (s) => s.status == SiteCheckStageStatus.empty,
      ),
      _ManualStageFilter.timedOut => stages.any(
        (s) => s.status == SiteCheckStageStatus.timedOut,
      ),
      _ManualStageFilter.cancelled => stages.any(
        (s) => s.status == SiteCheckStageStatus.cancelled,
      ),
      _ManualStageFilter.running => stages.any(
        (s) => s.status == SiteCheckStageStatus.running,
      ),
    };
  }

  List<SiteCheckReport> _visibleReports(List<SiteCheckReport> reports) {
    final query = _filterName.text.trim().toLowerCase();
    return reports.where((report) {
      final nameMatches =
          query.isEmpty ||
          report.site.name.toLowerCase().contains(query) ||
          report.site.key.toLowerCase().contains(query);
      return nameMatches &&
          (_statusFilter == null || report.status == _statusFilter) &&
          _phaseFilters.entries.every(
            (entry) => _phaseMatches(report, entry.key, entry.value),
          );
    }).toList();
  }

  List<String> get _statusFilterOptions => [
    _allCheckStatuses,
    for (final status in SiteCheckStatus.values) _status(status),
  ];

  SiteCheckStatus? _statusFromFilter(String label) {
    if (label == _allCheckStatuses) return null;
    for (final status in SiteCheckStatus.values) {
      if (_status(status) == label) return status;
    }
    return null;
  }

  void _resetResultFilters({bool notify = true}) {
    _filterName.clear();
    _statusFilter = null;
    _phaseFilters.updateAll((_, _) => _ManualStageFilter.any);
    if (notify && mounted) setState(() {});
  }

  Future<void> _run(Iterable<Site> sites) async {
    setState(() => _error = null);
    try {
      await _check?.run(sites);
    } catch (_) {
      if (mounted) setState(() => _error = '无法开始体检，请重新选择当前配置中的站点（最多 100 个）。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sites = _sites;
    final check = _check;
    final running = check?.running ?? false;
    final reports = check?.reports ?? const <SiteCheckReport>[];
    final visibleReports = _visibleReports(reports);
    final retry = reports
        .where((r) => r.isTerminal && r.status != SiteCheckStatus.success)
        .map((r) => r.site)
        .toList();
    return SettingsSection(
      title: '手动站点体检',
      description: '只检查首页和分类，不检查详情、搜索或播放；结果不代表已验证能播。',
      children: [
        Text(
          '开始后会联网，并可能运行当前配置提供的用户 Spider。仅在你点击开始后执行，不改变当前浏览或播放站点。',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: AppSpace.sm),
        Text(
          '每批最多 100 站 · 并发 2 站 · 每站总预算 30 秒 · 最多检查 2 个内容分类',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpace.md),
        if (widget.service == null)
          const Text('请先导入并启用配置，再选择要体检的站点。')
        else if (sites.isEmpty)
          const Text('当前配置没有可选择的站点，请检查配置内容或站点显示设置。')
        else ...[
          Wrap(
            spacing: AppSpace.md,
            runSpacing: AppSpace.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('已选 ${_selected.length} / ${sites.length} 站'),
              TextButton(
                key: const ValueKey('self-check-select-all'),
                onPressed: running
                    ? null
                    : () => setState(() {
                        _selected.clear();
                        _selected.addAll(
                          sites.take(SiteSelfCheck.maxSites).map((s) => s.key),
                        );
                      }),
                child: Text(
                  sites.length > SiteSelfCheck.maxSites ? '选择前 100 站' : '全选',
                ),
              ),
              TextButton(
                onPressed: running || _selected.isEmpty
                    ? null
                    : () => setState(_selected.clear),
                child: const Text('清空选择'),
              ),
            ],
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 216),
            child: Scrollbar(
              child: ListView(
                shrinkWrap: true,
                primary: false,
                children: [
                  for (final site in sites)
                    CheckboxListTile(
                      key: ValueKey('self-check-site-${site.key}'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(site.name),
                      value: _selected.contains(site.key),
                      onChanged:
                          running ||
                              (!_selected.contains(site.key) &&
                                  _selected.length >= SiteSelfCheck.maxSites)
                          ? null
                          : (value) => setState(() {
                              if (value == true) {
                                _selected.add(site.key);
                              } else {
                                _selected.remove(site.key);
                              }
                            }),
                    ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: AppSpace.md),
        SettingsActions(
          children: [
            FilledButton.icon(
              key: const ValueKey('self-check-start'),
              onPressed: check == null || running || _selected.isEmpty
                  ? null
                  : () => unawaited(
                      _run(sites.where((s) => _selected.contains(s.key))),
                    ),
              icon: const Icon(Icons.fact_check_outlined),
              label: Text(reports.isEmpty ? '开始体检' : '重跑所选站点'),
            ),
            if (running)
              OutlinedButton.icon(
                key: const ValueKey('self-check-cancel'),
                onPressed: check?.cancel,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('取消体检'),
              ),
            if (!running && retry.isNotEmpty)
              OutlinedButton(
                key: const ValueKey('self-check-retry'),
                onPressed: () => unawaited(_run(retry)),
                child: const Text('重试未通过站点'),
              ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.sm),
            child: Text(
              _error!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        const SizedBox(height: AppSpace.md),
        Text(
          '取消会停止后续调度。运行时未提供请求级取消能力时，只能停止等待，后台任务可能继续；不会强停共享宿主。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (reports.isNotEmpty) ...[
          const SizedBox(height: AppSpace.lg),
          Semantics(
            liveRegion: true,
            child: Text(
              '${running ? '正在体检' : '本批次已结束'} · ${check!.completed} / ${reports.length} 站完成',
              style: theme.textTheme.titleSmall,
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          LinearProgressIndicator(
            value: check.completed / reports.length,
            semanticsLabel: '站点体检进度',
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            '本批次结果会计入站点健康页的历史调用统计，但两者口径不同：返回分类不等于返回内容，有限可用表示仅部分内容阶段有结果。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          HealthFilterBar(
            summary: '显示 ${visibleReports.length} / ${reports.length} 站',
            children: [
              healthFilterNameField(
                key: const ValueKey('self-check-filter-name'),
                controller: _filterName,
                hint: '搜索站点名称或标识',
                onChanged: (_) => setState(() {}),
              ),
              healthFilterSelect(
                context: context,
                key: const ValueKey('self-check-filter-status'),
                label: '结论',
                value: _statusFilter == null
                    ? _allCheckStatuses
                    : _status(_statusFilter!),
                options: _statusFilterOptions,
                onChanged: (value) =>
                    setState(() => _statusFilter = _statusFromFilter(value)),
              ),
              for (final phase in SiteCheckPhase.values)
                healthFilterSelect(
                  context: context,
                  key: ValueKey('self-check-filter-${phase.name}'),
                  label: _phase(phase),
                  value: _manualStageFilterLabels[_phaseFilters[phase]]!,
                  options: _manualStageFilterLabels.values.toList(),
                  onChanged: (value) => setState(
                    () => _phaseFilters[phase] = _manualStageFilterFrom(value),
                  ),
                ),
              if (_hasResultFilters)
                TextButton.icon(
                  key: const ValueKey('self-check-filter-reset'),
                  onPressed: _resetResultFilters,
                  icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
                  label: const Text('重置筛选'),
                ),
            ],
          ),
          Text(
            '筛选只作用于本批次结果；详情、播放不在手动体检范围。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          if (visibleReports.isEmpty)
            const Text('没有匹配的体检结果。')
          else
            for (final report in visibleReports) _ReportRow(report: report),
        ],
      ],
    );
  }
}

String _status(SiteCheckStatus status) => switch (status) {
  SiteCheckStatus.queued => '排队中',
  SiteCheckStatus.running => '检查中',
  SiteCheckStatus.success => '内容检查通过',
  SiteCheckStatus.limited => '有限可用',
  SiteCheckStatus.empty => '无内容',
  SiteCheckStatus.failed => '失败',
  SiteCheckStatus.timedOut => '超时',
  SiteCheckStatus.cancelled => '已取消',
};
String _phase(SiteCheckPhase phase) => switch (phase) {
  SiteCheckPhase.runtime => '运行时',
  SiteCheckPhase.home => '首页',
  SiteCheckPhase.category => '分类',
};
String _stageStatus(SiteCheckStageStatus status) => switch (status) {
  SiteCheckStageStatus.running => '进行中',
  SiteCheckStageStatus.success => '成功',
  SiteCheckStageStatus.empty => '空内容',
  SiteCheckStageStatus.failed => '失败',
  SiteCheckStageStatus.timedOut => '超时',
  SiteCheckStageStatus.cancelled => '取消',
};

class _ReportRow extends StatelessWidget {
  const _ReportRow({required this.report});
  final SiteCheckReport report;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed =
        report.status == SiteCheckStatus.failed ||
        report.status == SiteCheckStatus.timedOut;
    final last = report.stages.lastOrNull;
    return ExpansionTile(
      key: ValueKey('self-check-result-${report.site.key}'),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: AppSpace.md),
      title: Wrap(
        spacing: AppSpace.md,
        runSpacing: AppSpace.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(report.site.name),
          Text(
            _status(report.status),
            style: theme.textTheme.labelLarge?.copyWith(
              color: failed
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      subtitle: Text(
        '${last == null ? '尚未调用' : _phase(last.phase)} · ${report.elapsed.inMilliseconds} ms${report.canCancelRequest == false ? ' · 仅能停止等待' : ''}',
      ),
      children: [
        for (final stage in report.stages)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.sm),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${_phase(stage.phase)}${stage.category == null ? '' : ' / ${stage.category}'} · ${_stageStatus(stage.status)} · ${stage.elapsed.inMilliseconds} ms',
                    style: theme.textTheme.labelLarge,
                  ),
                  Text(
                    '内容 ${stage.itemCount} 条 · 分类 ${stage.categoryCount} 个',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (stage.reason != null)
                    SelectableText(
                      stage.reason!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
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
