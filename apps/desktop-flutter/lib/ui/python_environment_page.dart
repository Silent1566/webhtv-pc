/// 运行环境设置页（任务书 Task C）。
///
/// 本页只做**呈现与调用**：环境检测、离线修复、自定义解释器与恢复默认全部由
/// `AppState.pythonEnvironment*`（Task B）完成，页面不判断包哈希、不解压、
/// 不探测注册表。
///
/// 三条界面纪律：
/// 1. **当前状态与操作结果分开**：`status.error` 说当前环境为什么不可用，
///    `pythonEnvironmentError` 与页面自己的返回消息说上一次操作为什么失败，
///    两者不同源，不能合并成一条把人绕晕的提示。
/// 2. **失败不写成功**：`Future<bool>` 只有显式 `true` 才算成功；`false` 与抛出
///    都如实说明「仍在使用哪一个解释器」，绝不把刚失败的选择说成当前环境。
/// 3. **忙碌即全禁**：检测/修复/切换/恢复期间四个入口与回车提交一起禁用，
///    避免同一操作重入；异步回调一律先查 `mounted`。
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/python_environment.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'settings_layout.dart';
import 'tokens.dart';

/// 运行环境页。
///
/// [pickExecutablePath] 只用于替换「系统文件对话框」这一外部依赖（与
/// `AppState` 注入外部播放器检测器同一模式）：`null` 时走真实的
/// `file_picker`，测试注入可控结果，不触达原生窗口。
class PythonEnvironmentPage extends StatefulWidget {
  const PythonEnvironmentPage({
    super.key,
    required this.state,
    this.pickExecutablePath,
  });

  final AppState state;
  final Future<String?> Function()? pickExecutablePath;

  @override
  State<PythonEnvironmentPage> createState() => _PythonEnvironmentPageState();
}

class _PythonEnvironmentPageState extends State<PythonEnvironmentPage> {
  final TextEditingController _customPath = TextEditingController();

  /// 本页发起的调用是否还在进行中。
  ///
  /// [AppState.pythonEnvironmentBusy] 由 B 维护，但它在调用真正开始后才置位，
  /// 两次快速点击之间仍可能漏进来一次；本地标志把这段间隙也封上。
  bool _submitting = false;
  int _operationGeneration = 0;

  /// 上一次操作的可见结果（成功 / 失败 / 输入校验）。
  String? _message;

  AppState get _state => widget.state;

  bool get _busy => _state.pythonEnvironmentBusy || _submitting;

  @override
  void initState() {
    super.initState();
    _syncCandidate();

    _state.addListener(_onStateChanged);
  }

  @override
  void didUpdateWidget(PythonEnvironmentPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_onStateChanged);
      widget.state.addListener(_onStateChanged);
      _operationGeneration++;
      _submitting = false;
      _message = null;
      _syncCandidate();
    }
  }

  @override
  void dispose() {
    _operationGeneration++;
    _state.removeListener(_onStateChanged);
    _customPath.dispose();
    super.dispose();
  }

  void _onStateChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final status = _state.pythonEnvironmentStatus;
    return Scaffold(
      appBar: AppBar(title: const Text('运行环境')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kFormMaxWidth),
          child: ListView(
            padding: const EdgeInsets.all(AppSpace.lg),
            children: [
              SettingsSection(
                title: '当前运行环境',
                description: '本软件自带专用 Python 与依赖；这里显示它实际用的解释器。',
                children: [
                  Text(
                    _statusSummary(status),
                    key: const ValueKey('python-environment-status'),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: status?.ready == true
                          ? context.semanticColors.statusOk
                          : Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: AppSpace.md),
                  _row(
                    '来源',
                    _sourceLabel(status?.source),
                    'python-environment-source',
                  ),
                  _row(
                    '解释器',
                    _orUnknown(status?.executable),
                    'python-environment-path',
                  ),
                  _row(
                    '版本',
                    _orUnknown(status?.version),
                    'python-environment-version',
                  ),
                  if (status?.error != null && status!.error!.isNotEmpty) ...[
                    const SizedBox(height: AppSpace.sm),
                    Text(
                      status.error!,
                      key: const ValueKey('python-environment-status-error'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.semanticColors.statusFailed,
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpace.md),
                  Text('依赖检查', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: AppSpace.xs),
                  ..._dependencyRows(context, status),
                ],
              ),
              SettingsSection(
                title: '环境检查与修复',
                description: '检测只读本机状态；离线修复只用随包内置的运行环境包。',
                children: [
                  SettingsActions(
                    children: [
                      FilledButton.icon(
                        key: const ValueKey('python-environment-refresh'),
                        onPressed: _busy ? null : _refresh,
                        icon: const Icon(Icons.refresh_outlined),
                        label: const Text('重新检测'),
                      ),
                      OutlinedButton.icon(
                        key: const ValueKey('python-environment-repair'),
                        onPressed: _busy ? null : _repair,
                        icon: const Icon(Icons.healing_outlined),
                        label: const Text('离线修复内置环境'),
                      ),
                      OutlinedButton.icon(
                        key: const ValueKey(
                          'python-environment-restore-default',
                        ),
                        onPressed: _busy ? null : _useDefault,
                        icon: const Icon(
                          Icons.settings_backup_restore_outlined,
                        ),
                        label: const Text('恢复默认内置运行时'),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpace.sm),
                  Text(
                    '离线修复只从发行目录里的内置包重建专用运行时：不联网、不下载、'
                    '不更新依赖版本，也不是去安装系统 Python。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (_busy) ...[
                    const SizedBox(height: AppSpace.md),
                    Row(
                      key: const ValueKey('python-environment-busy'),
                      children: [
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2.4),
                        ),
                        const SizedBox(width: AppSpace.sm),
                        Text(
                          '正在处理，请稍候…',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ],
                  if (_feedbackText().isNotEmpty) ...[
                    const SizedBox(height: AppSpace.md),
                    Text(
                      _feedbackText(),
                      key: const ValueKey('python-environment-message'),
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ],
              ),
              SettingsSection(
                title: '自定义解释器',
                description: '只接受 python.exe 的完整路径；留空不会被提交。',
                children: [
                  TextField(
                    key: const ValueKey('python-environment-custom-path'),
                    controller: _customPath,
                    decoration: const InputDecoration(
                      labelText: 'python.exe 完整路径',
                      hintText: r'D:\tools\python\python.exe',
                    ),
                    onSubmitted: (_) => _applyCustom(),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  SettingsActions(
                    children: [
                      OutlinedButton.icon(
                        key: const ValueKey('python-environment-pick'),
                        onPressed: _busy ? null : _pickExecutable,
                        icon: const Icon(Icons.folder_open_outlined),
                        label: const Text('选择 python.exe'),
                      ),
                      FilledButton.tonalIcon(
                        key: const ValueKey('python-environment-custom-apply'),
                        onPressed: _busy ? null : _applyCustom,
                        icon: const Icon(Icons.check_outlined),
                        label: const Text('使用自定义解释器'),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpace.sm),
                  Text(
                    '选择文件只会填入候选路径，点「使用自定义解释器」才真正切换；'
                    '校验不通过时仍使用原来的解释器。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              SettingsSection(
                title: '不会改动什么',
                description: '这些边界是产品承诺，页面上没有对应的开关。',
                children: const [
                  Text('· 不改系统 PATH，也不往系统 Python 里装包。'),
                  Text('· 不修改、不删除你已保存的自定义解释器环境。'),
                  Text('· 清理缓存不会删除专用运行环境与已保存的选择。'),
                  Text('· 没有在线下载或在线更新入口；修复只用内置包。'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _statusSummary(PythonEnvironmentStatus? status) {
    if (status == null) return '尚未检测运行环境状态。点「重新检测」开始检查。';
    if (status.ready) return '当前运行环境可用。';
    return status.source == PythonEnvironmentSource.missing
        ? '未检测到可用解释器，Python 站源暂时不能使用。'
        : '当前运行环境不可用，Python 站源暂时不能使用。';
  }

  String _sourceLabel(PythonEnvironmentSource? source) => switch (source) {
    PythonEnvironmentSource.bundled => '内置运行时',
    PythonEnvironmentSource.custom => '自定义解释器',
    PythonEnvironmentSource.system => '系统 Python',
    PythonEnvironmentSource.missing => '未检测到',
    null => '未检测',
  };

  String _orUnknown(String? value) =>
      (value == null || value.isEmpty) ? '—' : value;

  List<Widget> _dependencyRows(
    BuildContext context,
    PythonEnvironmentStatus? status,
  ) {
    final dependencies = status?.dependencies ?? const <String, bool>{};
    if (dependencies.isEmpty) {
      return <Widget>[
        Text(
          '尚未检测依赖。',
          key: const ValueKey('python-environment-dependency-empty'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ];
    }
    final names = dependencies.keys.toList()..sort();
    return <Widget>[
      for (final name in names)
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.xs),
          child: Text(
            '$name：${dependencies[name] == true ? '可用' : '缺失'}',
            key: ValueKey<String>('python-environment-dependency-$name'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: dependencies[name] == true
                  ? context.semanticColors.statusOk
                  : context.semanticColors.statusFailed,
            ),
          ),
        ),
    ];
  }

  Widget _row(String label, String value, String key) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              key: ValueKey<String>(key),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  String _feedbackText() {
    final parts = <String>[
      if (_message != null && _message!.isNotEmpty) _message!,
      if (_state.pythonEnvironmentError != null &&
          _state.pythonEnvironmentError!.isNotEmpty)
        _state.pythonEnvironmentError!,
    ];
    return parts.join('\n');
  }

  void _syncCandidate() {
    final status = _state.pythonEnvironmentStatus;
    _customPath.text = status?.source == PythonEnvironmentSource.custom
        ? status!.executable
        : '';
  }

  bool _ownsOperation(AppState state, int generation) =>
      mounted && identical(_state, state) && _operationGeneration == generation;

  int _beginOperation() {
    final generation = ++_operationGeneration;
    setState(() {
      _submitting = true;
      _message = null;
    });
    return generation;
  }

  void _finishOperation(AppState state, int generation) {
    if (!_ownsOperation(state, generation)) return;
    setState(() => _submitting = false);
  }

  Future<void> _runOperation({
    required Future<bool> Function(AppState) action,
    required String Function(AppState, bool) resultMessage,
    required String Function(AppState, Object) failureMessage,
  }) async {
    if (_busy) return;
    final state = _state;
    final generation = _beginOperation();
    try {
      final ok = await action(state);
      if (!_ownsOperation(state, generation)) return;
      setState(() {
        _message = ok && state.pythonEnvironmentError?.isNotEmpty == true
            ? null
            : resultMessage(state, ok);
      });
    } catch (error) {
      if (!_ownsOperation(state, generation)) return;
      setState(() => _message = failureMessage(state, error));
    } finally {
      _finishOperation(state, generation);
    }
  }

  Future<void> _refresh() => _runOperation(
    action: (state) async {
      await state.refreshPythonEnvironment();
      return true;
    },
    resultMessage: (_, _) => '重新检测完成。',
    failureMessage: (_, error) => '重新检测失败：$error',
  );

  Future<void> _repair() => _runOperation(
    action: (state) => state.repairPythonEnvironment(),
    resultMessage: (_, ok) => ok ? '离线修复完成，运行环境已重新准备。' : '离线修复未成功，当前运行环境保持不变。',
    failureMessage: (_, error) => '离线修复失败：$error',
  );

  Future<void> _useDefault() => _runOperation(
    action: (state) => state.useDefaultPythonEnvironment(),
    resultMessage: (_, ok) => ok ? '已恢复默认内置运行时。' : '恢复默认运行环境失败，当前解释器保持不变。',
    failureMessage: (_, error) => '恢复默认运行环境失败：$error',
  );

  Future<void> _applyCustom() async {
    if (_busy) return;
    final path = _customPath.text.trim();
    if (path.isEmpty) {
      setState(() => _message = '请填写 python.exe 的完整路径后再使用自定义解释器。');
      return;
    }
    await _runOperation(
      action: (state) => state.setCustomPythonExecutable(path),
      resultMessage: (state, ok) => ok
          ? '已切换自定义解释器：$path'
          : '自定义解释器未生效，仍在使用：${_orUnknown(state.pythonEnvironmentStatus?.executable)}，已保存的选择保持不变。',
      failureMessage: (state, error) =>
          '设置自定义解释器失败：$error，仍在使用：${_orUnknown(state.pythonEnvironmentStatus?.executable)}',
    );
  }

  Future<void> _pickExecutable() async {
    if (_busy) return;
    final state = _state;
    final pick = widget.pickExecutablePath ?? _pickWithFilePicker;
    final generation = _beginOperation();
    try {
      final picked = await pick();
      if (!_ownsOperation(state, generation) || state.pythonEnvironmentBusy) {
        return;
      }
      if (picked == null || picked.trim().isEmpty) return;
      setState(() {
        _customPath.text = picked.trim();
        _message = '已填入候选路径，点「使用自定义解释器」才会切换。';
      });
    } catch (error) {
      if (!_ownsOperation(state, generation) || state.pythonEnvironmentBusy) {
        return;
      }
      setState(() => _message = '打开文件选择器失败：$error');
    } finally {
      _finishOperation(state, generation);
    }
  }

  /// 真实文件对话框：只允许选 `.exe`，手输路径不受此限。
  Future<String?> _pickWithFilePicker() async {
    final file = await FilePicker.pickFile(
      dialogTitle: '选择 python.exe',
      type: FileType.custom,
      allowedExtensions: const <String>['exe'],
    );
    return file?.path;
  }
}
