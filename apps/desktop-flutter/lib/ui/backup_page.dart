/// 备份与恢复页（Phase 9 · P2-7）。
///
/// 备份是单个 zip（清单 + settings.json + 数据库快照）。恢复前会先校验
/// 清单与 SHA-256；重置会删除设置与数据库并回到「未导入配置」。
library;

import 'package:flutter/material.dart';

import '../core/backup_manifest.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'tokens.dart';
import 'toast.dart';

class BackupPage extends StatefulWidget {
  const BackupPage({super.key, required this.state});

  final AppState state;

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  late final TextEditingController _backupPath;
  final TextEditingController _restorePath = TextEditingController();
  BackupManifest? _inspected;
  String _message = '';
  bool _busy = false;

  AppState get _state => widget.state;

  @override
  void initState() {
    super.initState();
    _backupPath = TextEditingController(text: _state.defaultBackupPath());
  }

  @override
  void dispose() {
    _backupPath.dispose();
    _restorePath.dispose();
    super.dispose();
  }

  Future<void> _createBackup() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = '';
    });
    final result = await _state.createBackup(outputPath: _backupPath.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = result.ok
          ? '${result.message}\n${result.path}'
          : result.message;
    });
  }

  Future<void> _inspect() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = '';
      _inspected = null;
    });
    final result = await _state.inspectBackup(_restorePath.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _inspected = result.ok ? result.manifest : null;
      _message = result.ok
          ? '${result.message}\n${_describe(result.manifest!)}'
          : result.message;
    });
  }

  Future<void> _restore() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复备份？'),
        content: const Text(
          '当前设置与播放历史/收藏会被备份内容替换。\n'
          '恢复前会先校验备份；校验失败不会改动当前数据。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _busy = true;
      _message = '';
    });
    final error = await _state.restoreBackup(_restorePath.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = error ?? '恢复完成：设置与数据库已替换。';
    });
    if (error == null) {
      showToast('备份已恢复', kind: ToastKind.success);
    }
  }

  Future<void> _reset() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重置全部本地数据？'),
        content: const Text(
          '会删除本机设置、配置记录、播放历史与收藏，且不可撤销。\n'
          '建议先导出一份备份。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('重置'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _busy = true;
      _message = '';
    });
    final error = await _state.resetAllData();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = error ?? '本地数据已重置。';
    });
    if (error == null) {
      showToast('本地数据已重置', kind: ToastKind.success);
    }
  }

  String _describe(BackupManifest manifest) {
    final created = DateTime.fromMillisecondsSinceEpoch(manifest.createdAt);
    return '创建时间：$created\n'
        '应用版本：${manifest.appVersion} · 库 v${manifest.databaseSchema}\n'
        '配置 ${manifest.stats.configs} · 历史 ${manifest.stats.history} · '
        '收藏 ${manifest.stats.favorites}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('备份与恢复')),
      body: ListView(
        padding: formPagePadding(context),
        children: [
          Text('备份', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpace.sm),
          const Text(
            '包含设置与数据库（配置记录、历史、收藏）。缓存与日志不进入备份。',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: AppSpace.sm),
          TextField(
            key: const ValueKey('backup-output-path'),
            controller: _backupPath,
            decoration: const InputDecoration(
              labelText: '备份文件路径',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          FilledButton.icon(
            key: const ValueKey('backup-create'),
            onPressed: _busy ? null : _createBackup,
            icon: const Icon(Icons.save_alt),
            label: Text(_busy ? '处理中…' : '立即备份'),
          ),
          const Divider(height: 32),
          Text('恢复', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpace.sm),
          const Text(
            '先「检查备份」确认清单与校验和，再执行恢复。恢复会替换当前数据。',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: AppSpace.sm),
          TextField(
            key: const ValueKey('backup-restore-path'),
            controller: _restorePath,
            decoration: const InputDecoration(
              labelText: '备份文件路径',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          Wrap(
            spacing: AppSpace.sm,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('backup-inspect'),
                onPressed: _busy ? null : _inspect,
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('检查备份'),
              ),
              FilledButton.tonalIcon(
                key: const ValueKey('backup-restore'),
                onPressed: _busy || _inspected == null ? null : _restore,
                icon: const Icon(Icons.restore),
                label: const Text('恢复'),
              ),
            ],
          ),
          if (_message.isNotEmpty) ...[
            const SizedBox(height: AppSpace.sm),
            SelectableText(
              _message,
              key: const ValueKey('backup-message'),
              style: theme.textTheme.bodySmall,
            ),
          ],
          const Divider(height: 32),
          Text('重置', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpace.sm),
          const Text(
            '删除本机设置、配置记录、历史与收藏，回到未导入配置状态。',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: AppSpace.sm),
          OutlinedButton.icon(
            key: const ValueKey('backup-reset'),
            style: OutlinedButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
            onPressed: _busy ? null : _reset,
            icon: const Icon(Icons.delete_forever_outlined),
            label: const Text('重置全部本地数据'),
          ),
        ],
      ),
    );
  }
}
