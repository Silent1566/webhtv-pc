/// 配置导入与管理页（§17.2 配置导入页 / 配置管理页，§7.5 配置验收）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/protocol.dart';
import '../state/app_state.dart';
import 'app.dart';

/// 配置导入页：URL / 本地文件 / JSON 文本三种入口。
class ConfigPage extends StatefulWidget {
  const ConfigPage({super.key, required this.state});

  final AppState state;

  @override
  State<ConfigPage> createState() => _ConfigPageState();
}

class _ConfigPageState extends State<ConfigPage> {
  final TextEditingController _input = TextEditingController();
  final TextEditingController _name = TextEditingController();
  bool _busy = false;
  String? _resultMessage;
  bool _resultIsError = false;

  @override
  void dispose() {
    _input.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    final value = _input.text.trim();
    if (value.isEmpty) {
      setState(() {
        _resultIsError = true;
        _resultMessage = '请输入配置 URL、本地文件路径或 JSON 文本';
      });
      return;
    }
    setState(() {
      _busy = true;
      _resultMessage = null;
    });
    final name = _name.text.trim();
    final succeeded = await widget.state.importConfig(
      value,
      displayName: name.isEmpty ? null : name,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _resultIsError = !succeeded;
      _resultMessage = succeeded
          ? '导入成功：${widget.state.config?.sites.length ?? 0} 个站点，'
                '${widget.state.config?.lives.length ?? 0} 个直播源'
          : widget.state.lastError?.userMessage ?? '导入失败';
    });
  }

  Future<void> _pickFile() async {
    final controller = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('输入本地配置文件路径'),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: r'例如 C:\Users\you\config.json',
            ),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (path != null && path.trim().isNotEmpty) {
      _input.text = path.trim();
      await _import();
    }
  }

  Future<void> _importFixture() async {
    _input.text =
        'packages/test-fixtures/config/minimal-tvbox.json';
    await _import();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return Scaffold(
      appBar: AppBar(title: const Text('配置导入与管理')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '支持三种导入方式：HTTP(S) 配置地址、本地文件路径、直接粘贴 JSON 文本。'
              '导入失败不会覆盖已有配置。',
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _name,
                    decoration: const InputDecoration(
                      labelText: '配置名称（可选）',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _pickFile,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('选择本地文件'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _importFixture,
                  icon: const Icon(Icons.science_outlined),
                  label: const Text('使用仓库 fixture'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TextField(
                controller: _input,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(
                  labelText: '配置 URL / 文件路径 / JSON 文本',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _import,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.playlist_add_check),
                  label: const Text('导入'),
                ),
                const SizedBox(width: 12),
                if (_resultMessage != null)
                  Expanded(
                    child: Text(
                      _resultMessage!,
                      style: TextStyle(
                        color: _resultIsError
                            ? Theme.of(context).colorScheme.error
                            : Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
              ],
            ),
            if (state.lastError != null) ...[
              const SizedBox(height: 12),
              ErrorBanner(
                error: state.lastError!,
                onDismiss: state.clearError,
              ),
            ],
            const Divider(height: 32),
            _SavedConfigs(
              state: state,
              onActivate: (id) async {
                await state.activateConfigRecord(id);
                if (mounted) setState(() {});
              },
              onDelete: (id) async {
                await state.deleteConfigRecord(id);
                if (mounted) setState(() {});
              },
              onCopyOrigin: (value) async {
                await Clipboard.setData(ClipboardData(text: value));
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SavedConfigs extends StatelessWidget {
  const _SavedConfigs({
    required this.state,
    required this.onActivate,
    required this.onDelete,
    required this.onCopyOrigin,
  });

  final AppState state;
  final Future<void> Function(int id) onActivate;
  final Future<void> Function(int id) onDelete;
  final Future<void> Function(String value) onCopyOrigin;

  @override
  Widget build(BuildContext context) {
    if (state.configs.isEmpty) {
      return const Align(
        alignment: Alignment.centerLeft,
        child: Text('还没有保存的配置。'),
      );
    }
    return Expanded(
      child: ListView.builder(
        itemCount: state.configs.length,
        itemBuilder: (context, index) {
          final record = state.configs[index];
          return ListTile(
            dense: true,
            leading: Icon(
              record.isActive ? Icons.radio_button_checked : Icons.circle_outlined,
            ),
            title: Text('${record.name}${record.isActive ? "（当前）" : ""}'),
            subtitle: SelectableText(
              '站点 ${record.siteCount} · 直播 ${record.liveCount} · '
              '更新 ${record.updatedAt.toLocal()} · '
              '来源 ${redactUrl(record.origin)}',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '复制来源',
                  onPressed: () => onCopyOrigin(record.origin),
                  icon: const Icon(Icons.copy, size: 18),
                ),
                if (!record.isActive)
                  TextButton(
                    onPressed: () => onActivate(record.id),
                    child: const Text('启用'),
                  ),
                IconButton(
                  tooltip: '删除该配置记录（不删除站点源文件）',
                  onPressed: () => onDelete(record.id),
                  icon: const Icon(Icons.delete_outline, size: 18),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
