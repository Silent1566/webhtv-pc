import 'dart:io';

import 'package:flutter/material.dart';

import '../services/external_player.dart';
import 'tokens.dart';

class ExternalPlayerPickerDialog extends StatefulWidget {
  const ExternalPlayerPickerDialog({
    super.key,
    required this.loadPlayers,
    required this.savePlayer,
    this.selectedPath,
    this.pathMissing = false,
  });

  final Future<List<ExternalPlayer>> Function() loadPlayers;
  final Future<bool> Function({
    String? originalExecutable,
    required String name,
    required String executable,
  })
  savePlayer;
  final String? selectedPath;
  final bool pathMissing;

  @override
  State<ExternalPlayerPickerDialog> createState() =>
      _ExternalPlayerPickerDialogState();
}

class _ExternalPlayerPickerDialogState
    extends State<ExternalPlayerPickerDialog> {
  final _nameController = TextEditingController();
  final _pathController = TextEditingController();
  List<ExternalPlayer> _players = [];
  String? _selectedPath;
  String? _originalExecutable;
  String? _error;
  bool _loading = true;
  bool _editing = false;
  bool _saving = false;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _selectedPath = widget.selectedPath;
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _pathController.dispose();
    super.dispose();
  }

  bool _samePath(String? left, String? right) {
    if (left == null || right == null) return false;
    if (!Platform.isWindows) return left == right;
    return left.replaceAll('/', r'\').toLowerCase() ==
        right.replaceAll('/', r'\').toLowerCase();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final players = await widget.loadPlayers();
      if (!mounted) return;
      setState(() {
        _players = players;
        _loading = false;
        _loadFailed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
        _error = '播放器列表加载失败，请重试。';
      });
    }
  }

  void _edit([ExternalPlayer? player]) {
    _nameController.text = player?.name ?? '';
    _pathController.text = player?.executable ?? '';
    setState(() {
      _originalExecutable = player?.executable;
      _editing = true;
      _error = null;
    });
  }

  String? _pathError(String path) {
    if (path.isEmpty || !File(path).isAbsolute) {
      return '请输入独立程序文件的完整路径';
    }
    if (Platform.isWindows && !path.toLowerCase().endsWith('.exe')) {
      return '请选择 .exe 程序文件，不支持脚本或额外参数';
    }
    try {
      if (!File(path).existsSync()) return '文件不存在，请检查路径';
    } on FileSystemException {
      return '无法读取程序文件，请检查路径';
    }
    return null;
  }

  Future<void> _save() async {
    if (_saving) return;
    final name = _nameController.text.trim();
    final executable = _pathController.text.trim();
    final error = name.isEmpty ? '请输入播放器名称' : _pathError(executable);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    final wasSelected = _samePath(_selectedPath, _originalExecutable);
    setState(() {
      _saving = true;
      _error = null;
    });
    var saved = false;
    try {
      saved = await widget.savePlayer(
        originalExecutable: _originalExecutable,
        name: name,
        executable: executable,
      );
      if (!mounted) return;
      if (!saved) {
        setState(() => _error = '保存失败，请检查路径是否重复或稍后重试。');
        return;
      }
      // 保存已落地；即使重新载入失败，重试也应编辑现有条目。
      _originalExecutable = executable;
      if (wasSelected) _selectedPath = executable;
      final players = await widget.loadPlayers();
      if (!mounted) return;
      setState(() {
        _players = players;
        _editing = false;
        _loadFailed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadFailed = _loadFailed || saved;
        _error = saved ? '已保存，但列表加载失败，请重试。' : '保存失败，请稍后重试。';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _use() {
    final selected = _players.where(
      (player) => _samePath(player.executable, _selectedPath),
    );
    if (selected.isEmpty) {
      setState(() => _error = '请选择一个播放器');
      return;
    }
    final executable = selected.first.executable;
    final error = _pathError(executable);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(executable);
  }

  @override
  Widget build(BuildContext context) {
    final counts = <String, int>{};
    final ordinals = <String, int>{};
    for (final player in _players) {
      counts.update(player.name, (count) => count + 1, ifAbsent: () => 1);
    }
    return AlertDialog(
      title: Text(
        _editing ? (_originalExecutable == null ? '新增播放器' : '编辑播放器') : '外部播放器',
      ),
      content: SizedBox(
        width: 600,
        height: MediaQuery.sizeOf(context).height * 0.55,
        child: _editing
            ? SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _nameController,
                      autofocus: true,
                      enabled: !_saving,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(labelText: '播放器名称'),
                    ),
                    const SizedBox(height: AppSpace.lg),
                    TextField(
                      controller: _pathController,
                      enabled: !_saving,
                      decoration: const InputDecoration(
                        labelText: '可执行文件路径',
                        hintText: r'D:\PotPlayer\PotPlayerMini64.exe',
                      ),
                      onSubmitted: (_) => _save(),
                    ),
                    const SizedBox(height: AppSpace.md),
                    const Text('保存只更新播放器列表，不会开始播放。'),
                    if (_error != null) _errorText(),
                  ],
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.pathMissing)
                    const Padding(
                      padding: EdgeInsets.only(bottom: AppSpace.sm),
                      child: Text('上次配置的播放器已不在原路径，请编辑或重新选择。'),
                    ),
                  if (_error != null) _errorText(),
                  Expanded(
                    child: _loading
                        ? const Center(child: CircularProgressIndicator())
                        : _loadFailed
                        ? Center(
                            child: TextButton(
                              onPressed: _load,
                              child: const Text('重新加载'),
                            ),
                          )
                        : _players.isEmpty
                        ? const Center(child: Text('没有可用的播放器，请新增程序文件。'))
                        : ListView(
                            children: [
                              for (final player in _players)
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(
                                    _samePath(_selectedPath, player.executable)
                                        ? Icons.radio_button_checked
                                        : Icons.radio_button_unchecked,
                                  ),
                                  title: Text(
                                    counts[player.name]! > 1
                                        ? '${player.name} #${ordinals.update(player.name, (n) => n + 1, ifAbsent: () => 1)}'
                                        : player.name,
                                  ),
                                  subtitle: Text(player.executable),
                                  trailing: IconButton(
                                    tooltip: '编辑播放器',
                                    onPressed: () => _edit(player),
                                    icon: const Icon(Icons.edit_outlined),
                                  ),
                                  selected: _samePath(
                                    _selectedPath,
                                    player.executable,
                                  ),
                                  onTap: () => setState(() {
                                    _selectedPath = player.executable;
                                    _error = _loadFailed
                                        ? '播放器列表加载失败，请重试。'
                                        : null;
                                  }),
                                ),
                            ],
                          ),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  TextButton.icon(
                    onPressed: _loading || _loadFailed ? null : () => _edit(),
                    icon: const Icon(Icons.add),
                    label: const Text('新增播放器'),
                  ),
                ],
              ),
      ),
      actions: _editing
          ? [
              TextButton(
                onPressed: _saving
                    ? null
                    : () => setState(() {
                        _editing = false;
                        _error = _loadFailed ? '播放器列表加载失败，请重试。' : null;
                      }),
                child: const Text('取消编辑'),
              ),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? '保存中…' : '保存'),
              ),
            ]
          : [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: _loading || _loadFailed ? null : _use,
                child: const Text('使用'),
              ),
            ],
    );
  }

  Widget _errorText() => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
    child: Text(
      _error!,
      style: TextStyle(color: Theme.of(context).colorScheme.error),
      semanticsLabel: _error,
    ),
  );
}
