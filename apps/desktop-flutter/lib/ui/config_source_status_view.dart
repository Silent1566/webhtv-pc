import 'package:flutter/material.dart';

import '../core/protocol.dart';
import '../services/config_source_status.dart';
import '../services/storage.dart';
import 'tokens.dart';

String _reason(ConfigSourceStatus status) =>
    status.availability == ConfigSourceAvailability.unreadable
        ? '来源文件无法读取'
        : '来源文件已丢失';

const _recovery = '刷新不可用；请恢复来源文件、编辑来源地址或切换配置。';

class ConfigSourceStatusView extends StatefulWidget {
  const ConfigSourceStatusView({
    super.key,
    required this.record,
    required this.metadata,
    this.inspect = inspectConfigSource,
  });

  final ConfigRecord record;
  final String metadata;
  final Future<ConfigSourceStatus> Function(ConfigRecord) inspect;

  @override
  State<ConfigSourceStatusView> createState() => _ConfigSourceStatusViewState();
}

class _ConfigSourceStatusViewState extends State<ConfigSourceStatusView> {
  late Future<ConfigSourceStatus> _status;

  @override
  void initState() {
    super.initState();
    _status = widget.inspect(widget.record);
  }

  @override
  void didUpdateWidget(ConfigSourceStatusView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.record.id != widget.record.id ||
        oldWidget.record.origin != widget.record.origin) {
      _status = widget.inspect(widget.record);
    }
  }

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final origin = record.bridgeInterfaceKey.isEmpty
        ? '来源 ${redactUrl(record.origin)}'
        : '该设备的播放源 · ${redactUrl(record.bridgeConfigUrl.trim().isEmpty ? record.origin : record.bridgeConfigUrl)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.metadata, maxLines: 2, overflow: TextOverflow.ellipsis),
        Tooltip(
          message: origin,
          child: Text(origin, maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
        FutureBuilder<ConfigSourceStatus>(
          future: _status,
          builder: (context, snapshot) {
            final status = snapshot.connectionState == ConnectionState.done
                ? snapshot.data
                : null;
            if (status == null || !status.needsAttention || status.recordId != record.id) {
              return const SizedBox.shrink();
            }
            final color = context.semanticColors.statusDegraded;
            return Tooltip(
              message: '${_reason(status)}，当前配置继续使用缓存。\n$_recovery',
              child: Padding(
                padding: const EdgeInsets.only(top: AppSpace.xs),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: color, size: 16),
                    const SizedBox(width: AppSpace.xs),
                    Expanded(child: Text(
                      '${_reason(status)} · 使用缓存',
                      key: ValueKey('config-source-warning-${record.id}'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
                    )),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class RestoredConfigSourceBanner extends StatelessWidget {
  const RestoredConfigSourceBanner({
    super.key,
    required this.status,
    required this.onManage,
    required this.onDismiss,
  });

  final ConfigSourceStatus status;
  final VoidCallback onManage;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = context.semanticColors.statusDegraded;
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('${status.name}：${_reason(status)} · 使用缓存',
          style: theme.textTheme.bodyMedium?.copyWith(color: color)),
        Text(_recovery, style: theme.textTheme.bodySmall),
      ],
    );
    final actions = Wrap(
      spacing: AppSpace.xs,
      children: [
        TextButton(key: const ValueKey('config-source-manage'),
          onPressed: onManage, child: const Text('管理配置')),
        TextButton(key: const ValueKey('config-source-dismiss'),
          onPressed: onDismiss, child: const Text('关闭提示')),
      ],
    );
    return Container(
      key: const ValueKey('config-source-restored-warning'),
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl, vertical: AppSpace.sm),
      child: LayoutBuilder(builder: (context, constraints) {
        final content = constraints.maxWidth < 720
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [text, actions])
            : Row(children: [Expanded(child: text), const SizedBox(width: AppSpace.sm), actions]);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(padding: const EdgeInsets.only(top: AppSpace.xs),
              child: Icon(Icons.warning_amber_rounded, size: 18, color: color)),
            const SizedBox(width: AppSpace.sm),
            Expanded(child: content),
          ],
        );
      }),
    );
  }
}
