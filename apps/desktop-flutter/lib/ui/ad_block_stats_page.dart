/// 去广告统计页（安卓统计页的 PC 化）。
///
/// 三块内容：顶部摘要（总数/总时长/站点 Top/规则 Top）、可按五个维度筛选的日志表、
/// 带二次确认的清空按钮。
///
/// key 统一带 `ad-block-stats-` 前缀，后续 UI 测试据此定位（行 key 里的下标是
/// **过滤后**的下标，即屏幕上看到的第几行）。
///
/// 依赖只有 material + 本任务的文件 + 既有公共组件，不碰 AppState：
/// 页面拿的是已构造好的 [AdBlockStatsService]，接线由上层负责。
library;

import 'package:flutter/material.dart';

import '../core/ad_block_stats.dart';
import '../services/ad_block_stats_service.dart';
import 'common.dart';
import 'settings_layout.dart';
import 'tokens.dart';

class AdBlockStatsPage extends StatefulWidget {
  const AdBlockStatsPage({super.key, required this.service});

  final AdBlockStatsService service;

  @override
  State<AdBlockStatsPage> createState() => _AdBlockStatsPageState();
}

class _AdBlockStatsPageState extends State<AdBlockStatsPage> {
  /// 时间列与片段列的固定宽度：其余列按 flex 分剩余宽度，窗口变宽时表格不散架。
  static const double _timeWidth = 104;
  static const double _segmentWidth = 132;

  final TextEditingController _site = TextEditingController();
  final TextEditingController _siteDomain = TextEditingController();
  final TextEditingController _rule = TextEditingController();
  final TextEditingController _adDomain = TextEditingController();
  final TextEditingController _pipeline = TextEditingController();

  @override
  void initState() {
    super.initState();
    // 统计文件可能被另一个实例（另一个代理进程）写过，进页面重新读一次。
    widget.service.store.reload();
  }

  @override
  void dispose() {
    _site.dispose();
    _siteDomain.dispose();
    _rule.dispose();
    _adDomain.dispose();
    _pipeline.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stats = widget.service.stats;
    final labels = _siteLabels(stats);
    final filter = AdBlockLogFilter.fromQuery(
      siteName: _site.text,
      siteDomain: _siteDomain.text,
      rule: _rule.text,
      adDomain: _adDomain.text,
      pipeline: _pipeline.text,
      // 表格里显示的是规则展示名，照着名字打字也必须筛得出来，所以把命名表
      // 一起交给筛选器（id 仍然命中）。
      ruleLabelOf: widget.service.ruleLabel,
    );
    final logs = filter.apply(stats.logsByTimeDescending);
    final loadError = widget.service.store.loadError;
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsPageHeader(
              title: '去广告统计',
              description:
                  '记录每次清单清洗删掉的广告分片；只保留最近 '
                  '${AdBlockStats.maxLogs} 条，没有时间淘汰。'
                  '筛选项多个值用逗号分隔（同列任一命中即保留，跨列同时命中的才算）。',
            ),
            if (loadError != null) ...[
              _LoadErrorNote(text: loadError),
              const SizedBox(height: AppSpace.lg),
            ],
            _summary(stats, labels),
            const SizedBox(height: AppSpace.lg),
            _filterBar(),
            const SizedBox(height: AppSpace.md),
            _tableHeader(),
            const Divider(height: 1, thickness: 1),
            Expanded(
              child: logs.isEmpty
                  ? const SectionEmpty(
                      title: '没有匹配的拦截记录。',
                      icon: Icons.ads_click_outlined,
                    )
                  : ListView.builder(
                      key: const ValueKey('ad-block-stats-table'),
                      itemCount: logs.length,
                      itemBuilder: (context, index) =>
                          _logRow(logs[index], index, labels),
                    ),
            ),
            const SizedBox(height: AppSpace.md),
            _actions(stats, logs.length),
          ],
        ),
      ),
    );
  }

  Widget _summary(AdBlockStats stats, Map<String, String> labels) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: AppSpace.xxl,
          runSpacing: AppSpace.md,
          children: [
            _metric(
              keyValue: 'ad-block-stats-summary-total',
              label: '总拦截段数',
              value: '${stats.totalBlocked} 段',
            ),
            _metric(
              keyValue: 'ad-block-stats-summary-duration',
              label: '拦截总时长（累计）',
              value: '${stats.blockedDurationSeconds.toStringAsFixed(1)} 秒',
            ),
            _metric(
              keyValue: 'ad-block-stats-summary-reset',
              label: '上次清空',
              value: stats.lastResetAt == 0
                  ? '从未清空'
                  : _formatTime(stats.lastResetAt),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.lg),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _ranking(
                keyValue: 'ad-block-stats-top-sites',
                title: '按站点 Top',
                entries: stats.topSites(),
                labelOf: (key) => labels[key] ?? key,
              ),
            ),
            const SizedBox(width: AppSpace.xxl),
            Expanded(
              child: _ranking(
                keyValue: 'ad-block-stats-top-rules',
                title: '按规则 Top',
                entries: stats.topRules(),
                labelOf: widget.service.ruleLabel,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _metric({
    required String keyValue,
    required String label,
    required String value,
  }) {
    final theme = Theme.of(context);
    return Column(
      key: ValueKey<String>(keyValue),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpace.xs),
        Text(value, style: theme.textTheme.titleLarge),
      ],
    );
  }

  Widget _ranking({
    required String keyValue,
    required String title,
    required List<MapEntry<String, int>> entries,
    required String Function(String key) labelOf,
  }) {
    final theme = Theme.of(context);
    return Column(
      key: ValueKey<String>(keyValue),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: theme.textTheme.titleSmall),
        const SizedBox(height: AppSpace.sm),
        if (entries.isEmpty)
          Text(
            '暂无数据',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        else
          for (final entry in entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      labelOf(entry.key),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  Text(
                    '${entry.value} 段',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  Widget _filterBar() => Wrap(
    spacing: AppSpace.md,
    runSpacing: AppSpace.sm,
    children: [
      _filterField(_site, 'ad-block-stats-filter-site', '站点名'),
      _filterField(_siteDomain, 'ad-block-stats-filter-site-domain', '站点域名'),
      _filterField(_rule, 'ad-block-stats-filter-rule', '规则'),
      _filterField(_adDomain, 'ad-block-stats-filter-ad-domain', '广告域名'),
      _filterField(_pipeline, 'ad-block-stats-filter-pipeline', '管线'),
    ],
  );

  Widget _filterField(
    TextEditingController controller,
    String keyValue,
    String label,
  ) => SizedBox(
    width: 176,
    child: TextField(
      key: ValueKey<String>(keyValue),
      controller: controller,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  Widget _tableHeader() => Padding(
    padding: const EdgeInsets.only(bottom: AppSpace.sm),
    child: Row(
      children: [
        _cell('时间', width: _timeWidth, header: true),
        _cell('站点', flex: 3, header: true),
        _cell('广告域名', flex: 3, header: true),
        _cell('规则', flex: 2, header: true),
        _cell('分集', flex: 3, header: true),
        _cell('片段起止秒', width: _segmentWidth, header: true),
      ],
    ),
  );

  Widget _logRow(AdBlockLog log, int index, Map<String, String> labels) {
    final theme = Theme.of(context);
    final siteKey = log.siteKey.isNotEmpty
        ? log.siteKey
        : log.siteName.isNotEmpty
        ? log.siteName
        : log.siteDomain;
    final site = labels[siteKey] ?? (siteKey.isEmpty ? '—' : siteKey);
    final episode = log.episodeName.isNotEmpty
        ? log.episodeName
        : log.vodName.isEmpty
        ? '—'
        : log.vodName;
    return Container(
      key: ValueKey<String>('ad-block-stats-row-$index'),
      padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          _cell(_formatTime(log.blockedAt), width: _timeWidth),
          _cell(site, flex: 3),
          _cell(log.adDomain.isEmpty ? '—' : log.adDomain, flex: 3),
          _cell(widget.service.ruleLabel(log.ruleId), flex: 2),
          _cell(episode, flex: 3),
          _cell(
            '${log.segmentStartSeconds.toStringAsFixed(1)} – '
            '${log.segmentEndSeconds.toStringAsFixed(1)}',
            width: _segmentWidth,
          ),
        ],
      ),
    );
  }

  /// 列单元：[width] 固定宽、否则按 [flex] 分剩余宽度。
  ///
  /// 返回的 [Expanded]/[SizedBox] 必须直接挂在 [Row] 下——本方法就是为这一点
  /// 存在的，别在外面再包一层。
  Widget _cell(
    String text, {
    double? width,
    int flex = 1,
    bool header = false,
  }) {
    final theme = Theme.of(context);
    final style = header
        ? theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          )
        : theme.textTheme.bodySmall;
    final child = Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
    return width == null
        ? Expanded(flex: flex, child: child)
        : SizedBox(width: width, child: child);
  }

  Widget _actions(AdBlockStats stats, int visibleCount) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(
          '共 ${stats.blockLogs.length} 条日志，当前匹配 $visibleCount 条',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const Spacer(),
        TextButton.icon(
          key: const ValueKey('ad-block-stats-refresh'),
          onPressed: () => setState(widget.service.store.reload),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('重新读取'),
        ),
        const SizedBox(width: AppSpace.md),
        FilledButton.tonalIcon(
          key: const ValueKey('ad-block-stats-clear'),
          onPressed: _clear,
          icon: const Icon(Icons.delete_outline, size: 18),
          label: const Text('清空统计'),
        ),
      ],
    );
  }

  /// 清空：二次确认后执行，且可以反复重入（清空后还能再清一次）。
  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('ad-block-stats-confirm'),
        title: const Text('清空去广告统计？'),
        content: const Text('计数与日志会一起清空，且不可撤销；之后新的拦截仍会继续记录。'),
        actions: [
          TextButton(
            key: const ValueKey('ad-block-stats-confirm-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('ad-block-stats-confirm-clear'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final ok = await widget.service.reset();
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? '统计已清空。' : '清空失败：统计文件写不进去，详见日志。')),
    );
  }

  /// 站点 key → 展示名：计数表只存 key，展示时回日志里找一次名字。
  Map<String, String> _siteLabels(AdBlockStats stats) {
    final labels = <String, String>{};
    for (final log in stats.blockLogs) {
      final key = log.siteKey.isNotEmpty
          ? log.siteKey
          : log.siteName.isNotEmpty
          ? log.siteName
          : log.siteDomain;
      if (key.isEmpty || labels.containsKey(key)) continue;
      labels[key] = log.siteName.isNotEmpty
          ? log.siteName
          : log.siteDomain.isNotEmpty
          ? log.siteDomain
          : key;
    }
    return labels;
  }
}

/// 统计不可用的降级提示：不影响播放，但用户得知道看到的是空表，以及为什么。
class _LoadErrorNote extends StatelessWidget {
  const _LoadErrorNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('ad-block-stats-load-error'),
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: AppRadius.smAll,
      ),
      // 逐字显示 store 自己的说明：读写失败的原因不同，套一句「读取失败」会把
      // 写失败说成读失败，用户据此排查就找错了方向。
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: scheme.onErrorContainer),
      ),
    );
  }
}

/// `MM-dd HH:mm:ss`：日志表的密度要求秒级可见，年份在这里没有信息量。
String _formatTime(int milliseconds) {
  if (milliseconds <= 0) return '—';
  final time = DateTime.fromMillisecondsSinceEpoch(milliseconds);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}
