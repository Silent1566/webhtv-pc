/// 设置页、日志页与站点健康页（§17.2 设置页 / 日志页 / 站点健康页）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/playback_diagnostics.dart';
import '../services/log_service.dart';
import '../services/storage.dart';
import '../state/app_state.dart';
import 'app.dart';
import 'config_pages.dart';

/// 设置页：TMDB、运行信息、目录、缓存维护、合规说明。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final info = state.startupInfo;
    final tmdb = state.tmdbConfig;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // TMDB 区块（`04` §10.3）：设置页必须有独立入口。
        // 只靠详情页状态条会形成死锁——未配置时详情页也可能没有区块，
        // 用户就永远进不来（发布包实测缺陷）。
        Text('TMDB 元数据增强', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          tmdb.isReady
              ? '已启用（站点规则 ${tmdb.disabledSites.length} 条禁用'
                    '${tmdb.enabledSites.isEmpty ? '' : '、${tmdb.enabledSites.length} 条启用'}）'
              : '未配置：填写 API Key 或 Access Token 后启用',
          key: const ValueKey('settings-tmdb-summary'),
        ),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          key: const ValueKey('settings-tmdb-open'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => TmdbSettingsPage(state: state),
            ),
          ),
          icon: const Icon(Icons.movie_filter_outlined),
          label: const Text('打开 TMDB 设置'),
        ),
        const Divider(height: 32),
        Text('运行信息', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (info == null)
          const Text('启动信息尚未就绪。')
        else
          SelectableText(info.detailLines),
        const Divider(height: 32),
        Text('本地数据', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SelectableText(
          '配置：${state.paths.configDir}\n'
          '数据：${state.paths.dataDir}\n'
          '缓存：${state.paths.cacheDir}\n'
          '日志：${state.paths.logDir}',
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: () async {
                await state.resetCache();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('缓存目录已重建')),
                  );
                }
              },
              icon: const Icon(Icons.cleaning_services_outlined),
              label: const Text('清理缓存目录'),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: state.log.export()),
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已复制脱敏日志')),
                  );
                }
              },
              icon: const Icon(Icons.copy_all_outlined),
              label: const Text('复制脱敏日志'),
            ),
          ],
        ),
        const Divider(height: 32),
        Text('隐私与合规', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const SelectableText(usageBoundaryNotice),
        const SizedBox(height: 12),
        const Text(
          '• 遥测与崩溃上报：关闭（未实现上报通道）\n'
          '• 站点配置同步：关闭（Phase 4 能力）\n'
          '• 自动更新：不更新站源，仅更新应用本体',
        ),
        const Divider(height: 32),
        Text('站点健康', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        _HealthTable(items: state.siteHealth()),
      ],
    );
  }
}

class _HealthTable extends StatelessWidget {
  const _HealthTable({required this.items});

  final List<SiteHealth> items;

  String _rate(int ok, int total) {
    if (total == 0) return '暂无数据';
    return '$ok/$total (${(ok / total * 100).toStringAsFixed(0)}%)';
  }

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Text('还没有调用记录。浏览、搜索或播放后会累计成功率与耗时。');
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: const [
          DataColumn(label: Text('站点')),
          DataColumn(label: Text('首页')),
          DataColumn(label: Text('分类')),
          DataColumn(label: Text('详情')),
          DataColumn(label: Text('播放')),
          DataColumn(label: Text('平均耗时')),
          DataColumn(label: Text('最近错误')),
        ],
        rows: [
          for (final item in items)
            DataRow(
              cells: [
                DataCell(Text(item.siteKey)),
                DataCell(Text(_rate(item.homeOk, item.homeTotal))),
                DataCell(Text(_rate(item.categoryOk, item.categoryTotal))),
                DataCell(Text(_rate(item.detailOk, item.detailTotal))),
                DataCell(Text(_rate(item.playOk, item.playTotal))),
                DataCell(Text('${item.avgLatencyMs}ms')),
                DataCell(
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: Text(
                      item.lastError ?? '-',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// 日志页：结构化日志、级别过滤、导出（§17.2 日志页，§18.2 日志脱敏）。
class LogsPage extends StatefulWidget {
  const LogsPage({super.key, required this.state});

  final AppState state;

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  LogLevel? _filter;

  @override
  Widget build(BuildContext context) {
    final entries = widget.state.log.entries
        .where((entry) => _filter == null || entry.level == _filter)
        .toList()
        .reversed
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.state.lastDiagnostics != null)
          _PlaybackDiagnosticsCard(diagnostics: widget.state.lastDiagnostics!),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Text('级别过滤：'),
              const SizedBox(width: 8),
              DropdownButton<LogLevel?>(
                value: _filter,
                items: [
                  const DropdownMenuItem(value: null, child: Text('全部')),
                  for (final level in LogLevel.values)
                    DropdownMenuItem(
                      value: level,
                      child: Text(level.name.toUpperCase()),
                    ),
                ],
                onChanged: (value) => setState(() => _filter = value),
              ),
              const Spacer(),
              Text('${entries.length} 条'),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: widget.state.log.export()),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已复制脱敏日志')),
                    );
                  }
                },
                icon: const Icon(Icons.copy_all_outlined, size: 18),
                label: const Text('复制全部'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: entries.isEmpty
              ? const Center(child: Text('暂无日志。'))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    return SelectableText(
                      entry.line,
                      style: TextStyle(
                        fontFamily: 'Consolas',
                        fontFamilyFallback: const ['monospace'],
                        fontSize: 12,
                        color: switch (entry.level) {
                          LogLevel.error => Theme.of(context).colorScheme.error,
                          LogLevel.warning => Colors.orangeAccent,
                          LogLevel.info => Theme.of(context).colorScheme.primary,
                          LogLevel.debug => Theme.of(context).textTheme.bodySmall
                              ?.color,
                        },
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// 最近一次播放诊断卡片（§23：输出引擎/格式/网络/错误）。
///
/// 在日志页顶部展示，提供“一眼可定位”的关键字段与完整的可复制报告。
class _PlaybackDiagnosticsCard extends StatelessWidget {
  const _PlaybackDiagnosticsCard({required this.diagnostics});

  final PlaybackDiagnostics diagnostics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = diagnostics.succeeded == false;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: failed
              ? theme.colorScheme.error
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                failed ? Icons.error_outline : Icons.monitor_heart_outlined,
                size: 18,
                color: failed ? theme.colorScheme.error : null,
              ),
              const SizedBox(width: 8),
              Text('最近播放诊断', style: theme.textTheme.titleSmall),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: diagnostics.report),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已复制播放诊断')),
                    );
                  }
                },
                icon: const Icon(Icons.copy_all_outlined, size: 16),
                label: const Text('复制'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              _chip('引擎', PlaybackEngine.displayName(diagnostics.engine)),
              _chip('格式', diagnostics.format.label),
              if (diagnostics.target.host.isNotEmpty)
                _chip('主机', diagnostics.target.host),
              if (diagnostics.flag != null && diagnostics.flag!.isNotEmpty)
                _chip('线路', diagnostics.flag!),
              _chip(
                '网络',
                diagnostics.target.scheme.isEmpty
                    ? '未知'
                    : '${diagnostics.target.scheme}'
                        '${diagnostics.target.isSecure ? '（加密）' : ''}',
              ),
              _chip(
                '结果',
                switch (diagnostics.succeeded) {
                  true => '成功',
                  false => '失败',
                  null => '进行中',
                },
              ),
              for (final stage in PlaybackStage.values)
                if (diagnostics.elapsedOf(stage) != null)
                  _chip(
                    stage.label,
                    '${diagnostics.elapsedOf(stage)!.inMilliseconds}ms',
                  ),
            ],
          ),
          if (failed) ...[
            const SizedBox(height: 8),
            Text(
              diagnostics.failureHint ?? '播放失败',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _chip(String label, String value) => Padding(
    padding: const EdgeInsets.only(right: 4),
    child: Text('$label：$value'),
  );
}
