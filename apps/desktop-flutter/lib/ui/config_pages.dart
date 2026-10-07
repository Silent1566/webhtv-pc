/// 配置导入与管理页（§17.2 配置导入页 / 配置管理页，§7.5 配置验收）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/protocol.dart';
import '../core/tmdb_config.dart';
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

/// TMDB 设置页（`docs/phase4/design/04` §10）。
///
/// 设计要点：
/// - Key/Token 默认掩码，可切换明文；**不写入日志**（`03` §5.4）；
/// - 「重置为默认规则」需二次确认（`04` §10.2）；
/// - 点「保存」统一保存（对齐上游 `TmdbSourceDialog`）。
class TmdbSettingsPage extends StatefulWidget {
  const TmdbSettingsPage({super.key, required this.state});

  final AppState state;

  @override
  State<TmdbSettingsPage> createState() => _TmdbSettingsPageState();
}

class _TmdbSettingsPageState extends State<TmdbSettingsPage> {
  late TmdbConfig _draft;
  late final TextEditingController _apiKey;
  late final TextEditingController _accessToken;
  late final TextEditingController _apiBase;
  late final TextEditingController _imageBase;
  late final TextEditingController _language;
  final TextEditingController _siteRule = TextEditingController();
  final TextEditingController _allowRule = TextEditingController();
  final TextEditingController _denyRule = TextEditingController();
  bool _showApiKey = false;
  bool _showAccessToken = false;
  bool _busy = false;
  String? _testResult;
  String? _saveResult;

  @override
  void initState() {
    super.initState();
    _draft = widget.state.tmdbConfig;
    _apiKey = TextEditingController(text: _draft.apiKey);
    _accessToken = TextEditingController(text: _draft.accessToken);
    _apiBase = TextEditingController(text: _draft.apiBase);
    _imageBase = TextEditingController(text: _draft.imageBase);
    _language = TextEditingController(text: _draft.language);
  }

  @override
  void dispose() {
    _apiKey.dispose();
    _accessToken.dispose();
    _apiBase.dispose();
    _imageBase.dispose();
    _language.dispose();
    _siteRule.dispose();
    _allowRule.dispose();
    _denyRule.dispose();
    super.dispose();
  }

  TmdbConfig _collect() => _draft.copyWith(
    apiKey: _apiKey.text.trim(),
    accessToken: _accessToken.text.trim(),
    apiBase: _apiBase.text.trim(),
    imageBase: _imageBase.text.trim(),
    language: _language.text.trim(),
  );

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _saveResult = null;
    });
    final config = _collect();
    final saved = await widget.state.saveTmdbConfig(config);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _draft = widget.state.tmdbConfig;
      _saveResult = saved ? '已保存（凭据已写入本地设置文件）' : '保存失败';
    });
  }

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _testResult = null;
    });
    // 测试连接用**当前草稿**：先落盘再测，避免用户改了 Key 但测的是旧值。
    await widget.state.saveTmdbConfig(_collect());
    final result = await widget.state.testTmdbConnection();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _testResult = result;
      _draft = widget.state.tmdbConfig;
    });
  }

  Future<void> _resetRules() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('tmdb-reset-confirm'),
        title: const Text('重置为默认站点规则'),
        content: const Text(
          '将把「禁用站点」恢复为默认的 11 条规则，并清空自定义的启用/白名单规则。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('重置'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _draft = _draft.copyWith(
        enabledSites: const [],
        allowedSites: const [],
      ).withDefaultDisabledRules();
    });
  }

  void _addRule(TextEditingController controller, List<String> current, void Function(List<String>) apply) {
    final value = controller.text.trim();
    if (value.isEmpty) return;
    if (current.contains(value)) return;
    apply([...current, value]);
    controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('TMDB 设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            key: const ValueKey('tmdb-enabled'),
            title: const Text('启用 TMDB 增强'),
            subtitle: const Text('关闭后等同未配置：不发起任何 TMDB 请求'),
            value: _draft.enabled,
            onChanged: (value) => setState(
              () => _draft = _draft.copyWith(enabled: value),
            ),
          ),
          const Divider(height: 32),
          Text('凭据', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('tmdb-api-key'),
                  controller: _apiKey,
                  obscureText: !_showApiKey,
                  decoration: const InputDecoration(
                    labelText: 'API Key（v3）',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                key: const ValueKey('tmdb-api-key-toggle'),
                onPressed: () => setState(() => _showApiKey = !_showApiKey),
                child: Text(_showApiKey ? '隐藏' : '显示'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('tmdb-access-token'),
                  controller: _accessToken,
                  obscureText: !_showAccessToken,
                  decoration: const InputDecoration(
                    labelText: 'Access Token（v4）',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                key: const ValueKey('tmdb-access-token-toggle'),
                onPressed: () =>
                    setState(() => _showAccessToken = !_showAccessToken),
                child: Text(_showAccessToken ? '隐藏' : '显示'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            '日志与诊断中只出现掩码：key=${_draft.redactedApiKey} '
            'token=${_draft.redactedAccessToken}',
            style: theme.textTheme.bodySmall,
          ),
          const Divider(height: 32),
          Text('服务', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('tmdb-api-base'),
            controller: _apiBase,
            decoration: const InputDecoration(
              labelText: 'API 主机',
              hintText: 'https://api.tmdb.org/3',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('tmdb-image-base'),
            controller: _imageBase,
            decoration: const InputDecoration(
              labelText: '图片主机',
              hintText: 'https://images.tmdb.org/t/p/w342',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('tmdb-language'),
            controller: _language,
            decoration: const InputDecoration(
              labelText: '语言',
              hintText: 'zh-CN',
              border: OutlineInputBorder(),
            ),
          ),
          const Divider(height: 32),
          Text('匹配', style: theme.textTheme.titleMedium),
          SwitchListTile(
            key: const ValueKey('tmdb-smart-match'),
            title: const Text('智能匹配'),
            value: _draft.smartMatch,
            onChanged: (value) => setState(
              () => _draft = _draft.copyWith(smartMatch: value),
            ),
          ),
          SwitchListTile(
            key: const ValueKey('tmdb-heuristic'),
            title: const Text('启发式季度推断'),
            subtitle: const Text('关闭后证据不足时不再猜测季度（保持「未确定季度」）'),
            value: _draft.heuristicSeasonGuessing,
            onChanged: (value) => setState(
              () => _draft = _draft.copyWith(heuristicSeasonGuessing: value),
            ),
          ),
          const Divider(height: 32),
          Row(
            children: [
              Text('站点规则', style: theme.textTheme.titleMedium),
              const Spacer(),
              OutlinedButton.icon(
                key: const ValueKey('tmdb-reset-rules'),
                onPressed: _resetRules,
                icon: const Icon(Icons.restart_alt),
                label: const Text('重置为默认规则'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _ruleSection(
            label: '启用站点（留空 = 全部允许）',
            keyPrefix: 'tmdb-enabled-sites',
            controller: _siteRule,
            values: _draft.enabledSites,
            onAdd: () => _addRule(
              _siteRule,
              _draft.enabledSites,
              (next) => setState(
                () => _draft = _draft.copyWith(enabledSites: next),
              ),
            ),
            onRemove: (value) => setState(
              () => _draft = _draft.copyWith(
                enabledSites: [..._draft.enabledSites]..remove(value),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _ruleSection(
            label: '白名单（精确命中优先于禁用规则）',
            keyPrefix: 'tmdb-allowed-sites',
            controller: _allowRule,
            values: _draft.allowedSites,
            onAdd: () => _addRule(
              _allowRule,
              _draft.allowedSites,
              (next) => setState(
                () => _draft = _draft.copyWith(allowedSites: next),
              ),
            ),
            onRemove: (value) => setState(
              () => _draft = _draft.copyWith(
                allowedSites: [..._draft.allowedSites]..remove(value),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _ruleSection(
            label: '禁用站点',
            keyPrefix: 'tmdb-disabled-sites',
            controller: _denyRule,
            values: _draft.disabledSites,
            onAdd: () => _addRule(
              _denyRule,
              _draft.disabledSites,
              (next) => setState(
                () => _draft = _draft.copyWith(
                  disabledSites: next,
                  excludeKeywordsConfigured: true,
                ),
              ),
            ),
            onRemove: (value) => setState(
              () => _draft = _draft.copyWith(
                disabledSites: [..._draft.disabledSites]..remove(value),
                excludeKeywordsConfigured: true,
              ),
            ),
          ),
          const Divider(height: 32),
          Row(
            children: [
              FilledButton.icon(
                key: const ValueKey('tmdb-save'),
                onPressed: _busy ? null : _save,
                icon: const Icon(Icons.save_outlined),
                label: const Text('保存'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                key: const ValueKey('tmdb-test'),
                onPressed: _busy ? null : _test,
                icon: const Icon(Icons.wifi_tethering),
                label: const Text('测试连接'),
              ),
              if (_busy) ...[
                const SizedBox(width: 12),
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
          if (_testResult != null) ...[
            const SizedBox(height: 8),
            Text(
              _testResult!,
              key: const ValueKey('tmdb-test-result'),
              style: theme.textTheme.bodyMedium,
            ),
          ],
          if (_saveResult != null) ...[
            const SizedBox(height: 8),
            Text(_saveResult!, key: const ValueKey('tmdb-save-result')),
          ],
          const SizedBox(height: 8),
          SelectableText(
            '设置文件：${widget.state.tmdbSettingsPath}',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _ruleSection({
    required String label,
    required String keyPrefix,
    required TextEditingController controller,
    required List<String> values,
    required VoidCallback onAdd,
    required ValueChanged<String> onRemove,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: ValueKey('$keyPrefix-input'),
                controller: controller,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: '输入站点 key 或名称',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => onAdd(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              key: ValueKey('$keyPrefix-add'),
              tooltip: '添加',
              onPressed: onAdd,
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (values.isEmpty)
          const Text('（空）')
        else
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final value in values)
                InputChip(
                  key: ValueKey('$keyPrefix-chip-$value'),
                  label: Text(value),
                  onDeleted: () => onRemove(value),
                ),
            ],
          ),
      ],
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
