/// 配置导入与管理页（§17.2 配置导入页 / 配置管理页，§7.5 配置验收）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/android_bridge.dart';
import '../core/protocol.dart';
import '../core/tmdb_config.dart';
import '../state/app_state.dart';
import '../state/sync_state.dart';
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
          const Divider(height: 32),
          Text('设备与同步', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          ListTile(
            key: const ValueKey('settings-android-open'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.android_outlined),
            title: const Text('打开安卓接入'),
            subtitle: const Text(
              '接入安卓的 T4 网关以间接使用它的全部站源，并双向共用播放历史',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => AndroidSettingsPage(state: widget.state),
              ),
            ),
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

/// 安卓设备接入与同步设置页（`docs/phase5/design/02` §5、设计文档 §28）。
///
/// 三条不可退让的 UI 约定（P3）：
/// 1. 同步相关开关**全部默认关闭**，开启服务端前必须展示 [SyncState.serverBindHint]；
/// 2. 导入站点**不切换**当前配置（`design/00` Q10），文案必须说清这一点；
/// 3. 失败必须按类别展示（P5）：403/404/超时/空结果不得折叠成"0 个站点"或"成功"。
class AndroidSettingsPage extends StatefulWidget {
  const AndroidSettingsPage({super.key, required this.state});

  final AppState state;

  @override
  State<AndroidSettingsPage> createState() => _AndroidSettingsPageState();
}

class _AndroidSettingsPageState extends State<AndroidSettingsPage> {
  final TextEditingController _address = TextEditingController();

  SyncState get _sync => widget.state.syncState;

  @override
  void initState() {
    super.initState();
    _sync.addListener(_onSyncChanged);
  }

  void _onSyncChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _sync.removeListener(_onSyncChanged);
    _address.dispose();
    super.dispose();
  }

  Future<void> _probe() async {
    final value = _address.text.trim();
    if (value.isEmpty) {
      _sync.clearMessages();
      return;
    }
    await _sync.probe(value);
  }

  Future<void> _scan() => _sync.scan();

  /// 从历史一键重连：先探测，探到就自动导入站点（用户点「接入」就是想用上）。
  Future<void> _reconnect(DeviceHistoryEntry entry) async {
    _address.text = entry.address;
    final device = await _sync.probe(entry.address);
    if (!mounted || device == null) return;
    await _import(device);
  }

  /// 导入站点，并在成功后询问是否切换到该配置。
  ///
  /// 为什么要有这一步：导入受 Q10 约束**不**切换当前配置（不静默抢走用户正在用的
  /// 配置是对的），但用户点「导入站点」的意图通常就是「我要用这台设备的站源」。
  /// 原先导入完就停在原地，用户得自己回配置页再点一次「启用」——多一次无意义的
  /// 导航（用户反馈 2026-10-09）。现在导入成功后弹确认框，用户一键切换。
  ///
  /// 两种情形**不弹框**（避免无意义的打扰）：
  /// - 刚导入的记录已是当前配置（无需切换）；
  /// - 当前配置本来就指向**同一台设备**（只是重复导入刷新站点，没有可切的东西）。
  Future<void> _import(AndroidDevice device) async {
    final state = widget.state;
    final sitesBefore = state.configs.length;
    final ok = await _sync.importSites(device.reachableBase);
    if (!mounted) return;
    if (!ok) return;

    final recordId = _sync.lastImportRecordId;
    if (recordId == null) return;

    final active = state.activeRecord;
    final sameDeviceActive =
        active != null && normalizeBase(active.origin) == device.reachableBase;
    if (active?.id == recordId || sameDeviceActive) return;

    final liveCount = state.configs
        .where((item) => item.id == recordId)
        .map((item) => item.liveCount)
        .firstOrNull;
    final siteCount = _sync.conversionFor(device.reachableBase)?.siteCount ?? 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('bridge-switch-confirm'),
        title: const Text('已导入站点，是否切换到该配置？'),
        content: Text(
          '设备：${device.name}\n'
          '站点：$siteCount 个'
          '${liveCount == null || liveCount == 0 ? '' : '，直播源 $liveCount 个'}\n\n'
          '切换后浏览与直播将改用这台设备的站源。'
          '${sitesBefore == 0 ? '' : '当前配置不会被删除，可随时在配置页切回。'}',
        ),
        actions: [
          TextButton(
            key: const ValueKey('bridge-switch-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('稍后再说'),
          ),
          FilledButton(
            key: const ValueKey('bridge-switch-confirm-ok'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('切换'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await state.activateConfigRecord(recordId);
  }

  Future<void> _push(SyncPeer peer) async {
    final result = await _sync.pushHistoryTo(peer);
    if (!mounted || result == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result.describe())),
    );
  }

  Future<void> _toggleServer(bool value) async {
    if (value) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('开启局域网同步服务'),
          content: Text(_sync.serverBindHint),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('开启'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await _sync.setServerEnabled(value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sync = _sync;
    return Scaffold(
      appBar: AppBar(title: const Text('安卓设备接入')),
      body: ListView(
        key: const ValueKey('android-bridge'),
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '接入安卓的 T4 网关可以间接使用安卓上的全部站源（含 T3 爬虫、网盘、猫源），'
            'PC 不复制这些爬虫，只做 HTTP 客户端。',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('android-device-input'),
                  controller: _address,
                  decoration: const InputDecoration(
                    labelText: '手动输入地址',
                    hintText: '例如 192.168.50.9:9978',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _probe(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                key: const ValueKey('android-device-add'),
                onPressed: sync.busy ? null : _probe,
                icon: const Icon(Icons.cable_outlined),
                label: const Text('接入设备'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                key: const ValueKey('android-scan'),
                onPressed: sync.busy ? null : _scan,
                icon: const Icon(Icons.wifi_find_outlined),
                label: const Text('扫描局域网'),
              ),
            ],
          ),
          if (sync.scanTotal > 0) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: sync.scanDone / sync.scanTotal,
            ),
            const SizedBox(height: 4),
            Text('已扫描 ${sync.scanDone}/${sync.scanTotal}'),
          ],
          if (sync.busy) ...[
            const SizedBox(height: 8),
            // 刻意不用 `LinearProgressIndicator`：不确定进度条是无限动画，
            // 会让 widget 测试的 `pumpAndSettle` 永不收敛，也会让低配机器
            // 持续重绘。文字提示已经足够。
            const Row(
              children: [
                Icon(Icons.hourglass_top_outlined, size: 16),
                SizedBox(width: 8),
                Text('正在处理…'),
              ],
            ),
          ],
          if (sync.lastError != null) ...[
            const SizedBox(height: 8),
            Card(
              key: const ValueKey('android-error'),
              color: theme.colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.error_outline),
                title: Text(sync.lastError!.userMessage),
                subtitle: Text('类别：${sync.lastError!.kind.name}'),
              ),
            ),
          ],
          if (sync.notice != null) ...[
            const SizedBox(height: 8),
            Card(
              key: const ValueKey('android-notice'),
              child: ListTile(
                leading: const Icon(Icons.info_outline),
                title: Text(sync.notice!),
              ),
            ),
          ],
          const Divider(height: 32),
          Row(
            children: [
              Text('最近接入', style: theme.textTheme.titleMedium),
              const SizedBox(width: 8),
              // 用户反馈：设备接入需要历史记录方便再次使用。一键重连不用再输地址。
              Text(
                '（点一下就重新接入，不用再输地址）',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (sync.deviceHistory.isEmpty)
            const Text('还没有接入过设备。')
          else
            for (final entry in sync.deviceHistory)
              ListTile(
                key: ValueKey('bridge-history-${entry.uuid}'),
                dense: true,
                leading: const Icon(Icons.history),
                title: Text(entry.name),
                subtitle: Text(entry.address),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      key: ValueKey('bridge-history-connect-${entry.uuid}'),
                      onPressed: sync.busy
                          ? null
                          : () => _reconnect(entry),
                      child: const Text('接入'),
                    ),
                    IconButton(
                      key: ValueKey('bridge-history-forget-${entry.uuid}'),
                      tooltip: '从历史中删除',
                      onPressed: sync.busy
                          ? null
                          : () => _sync.forgetDevice(entry.uuid),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
              ),
          const Divider(height: 32),
          Text('安卓设备', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (sync.devices.isEmpty)
            const Text('尚未接入设备：可手动输入地址，或扫描局域网。')
          else
            for (final device in sync.devices) _deviceCard(theme, device),
          const Divider(height: 32),
          Text('同步设置', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          SwitchListTile(
            key: const ValueKey('android-sync-server'),
            title: const Text('接收安卓推送（本机服务端）'),
            subtitle: Text(
              sync.serverRunning
                  ? '正在监听 ${sync.serverBaseUrl}（仅接受已授权对端）'
                  : '默认关闭：开启后同局域网设备可访问本机',
            ),
            value: sync.serverEnabled,
            onChanged: sync.busy ? null : _toggleServer,
          ),
          SwitchListTile(
            key: const ValueKey('android-sync-push'),
            title: const Text('向安卓推送'),
            subtitle: const Text('默认关闭：把本机历史/收藏推送到已授权设备'),
            value: sync.pushEnabled,
            onChanged: sync.busy ? null : sync.setPushEnabled,
          ),
          SwitchListTile(
            key: const ValueKey('android-sync-settings'),
            title: const Text('同步设置项（含凭据）'),
            subtitle: const Text('默认关闭：开启后会把 TMDB 等含凭据的设置推送到对端'),
            value: sync.settingsSyncEnabled,
            onChanged: sync.busy ? null : sync.setSettingsSyncEnabled,
          ),
          if (sync.lastStats != null) ...[
            const SizedBox(height: 8),
            SelectableText(
              '最近一次同步：${sync.lastStats!.describe()}',
              key: const ValueKey('sync-stats'),
              style: theme.textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 8),
          Text('已授权对端', style: theme.textTheme.titleSmall),
          if (sync.peers.isEmpty)
            const Text('尚未授权任何对端：安卓推送历史前需先在此授权。')
          else
            for (final peer in sync.peers) _peerTile(theme, peer),
          const SizedBox(height: 8),
          SelectableText(
            '本机设备标识：${sync.maskedDeviceUuid}（${sync.deviceName}）',
            style: theme.textTheme.bodySmall,
          ),
          SelectableText(
            '设置文件：${sync.settingsPath}',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _deviceCard(ThemeData theme, AndroidDevice device) {
    final conversion = _sync.conversionFor(device.reachableBase);
    return Card(
      key: ValueKey('android-device-${device.uuid}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${device.name}（${device.typeLabel}）',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('android-import'),
                  onPressed: _sync.busy ? null : () => _import(device),
                  icon: const Icon(Icons.cloud_download_outlined),
                  label: const Text('导入站点'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SelectableText(
              '可达地址 ${device.reachableBase} · '
              '设备自报 ${device.reportedIp.isEmpty ? '(未提供)' : device.reportedIp} · '
              '标识 ${device.maskedUuid}'
              '${conversion == null ? '' : ' · 站点 ${conversion.siteCount}'}',
              style: theme.textTheme.bodySmall,
            ),
            if (conversion != null && conversion.hostRewrites.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('站点地址已修正', style: theme.textTheme.labelLarge),
              for (final rewrite in conversion.hostRewrites.take(5))
                SelectableText(
                  '${rewrite.from} → ${rewrite.to}',
                  key: ValueKey('bridge-host-${rewrite.siteKey}'),
                  style: theme.textTheme.bodySmall,
                ),
            ],
            if (conversion != null && conversion.diagnostics.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final line in conversion.diagnostics)
                Text(line, style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }

  Widget _peerTile(ThemeData theme, SyncPeer peer) => ListTile(
    key: ValueKey('sync-peer-${peer.uuid}'),
    leading: const Icon(Icons.devices_other_outlined),
    title: Text(peer.name),
    subtitle: Text('${peer.maskedUuid} · ${peer.address}'),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FilledButton.tonal(
          key: const ValueKey('android-sync-push-now'),
          onPressed: _sync.busy ? null : () => _push(peer),
          child: const Text('推送到设备'),
        ),
        IconButton(
          key: ValueKey('sync-peer-revoke-${peer.uuid}'),
          tooltip: '移除授权',
          onPressed: () => _sync.revokePeer(peer.uuid),
          icon: const Icon(Icons.link_off_outlined),
        ),
      ],
    ),
  );
}
