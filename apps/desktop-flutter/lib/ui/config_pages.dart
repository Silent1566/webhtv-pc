/// 配置导入与管理页（§17.2 配置导入页 / 配置管理页，§7.5 配置验收）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/android_bridge.dart';
import '../core/realtime_sync.dart';
import '../core/tmdb_config.dart';
import '../services/realtime_sync_engine.dart';
import '../services/storage.dart';
import '../state/app_state.dart';
import '../state/sync_state.dart';
import 'common.dart';
import 'config_source_status_view.dart';
import 'settings_layout.dart';
import 'toast.dart';
import 'tokens.dart';

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

  /// 导入区是否展开。
  ///
  /// 默认收起：用户每次进这一页的**主要目的**是换配置或改一条记录，导入是
  /// 低频动作。一块 180px 的空输入框长期占据首屏，等于把最常用的列表挤到
  /// 折线以下（用户反馈 2026-11-05：「导入部分能默认收起来嘛」）。
  ///
  /// 例外：一条配置都没有时没有可管理的东西，唯一有意义的就是导入，
  /// 此时必须展开，否则用户进来看见一句"还没有保存的配置"却找不到入口。
  bool _importExpanded = false;

  /// 正在刷新/保存的记录 id。
  ///
  /// 存在的理由不是"好看"：刷新一条要真的打网络，用户完全可能在等待期间再
  /// 点一次同一行，或者点「全部刷新」——两路同时写同一条记录会让"最后写入"
  /// 变成随机的。这里把同一条记录的在途操作锁住。
  final Set<int> _busyIds = <int>{};
  bool _busyAll = false;

  @override
  void initState() {
    super.initState();
    _importExpanded = widget.state.savedConfigs.isEmpty;
  }

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
    _input.text = 'packages/test-fixtures/config/minimal-tvbox.json';
    await _import();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return Scaffold(
      appBar: AppBar(title: const Text('配置导入与管理')),
      body: Padding(
        // 表单收进限宽内容列（见 `formPagePadding`）。
        padding: formPagePadding(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 整行可点：标题本身就是开关，不必把指针精确移到右侧小按钮上
            // （用户反馈 2026-11-05）。
            //
            // 标题前**不放图标**：图标会把文字整体右推 26px，于是它与下方
            // 「已保存的配置」对不齐，看起来像缩进了一级的子菜单。两个区块是
            // 平级关系，左边缘必须落在同一条竖线上。
            _CollapsibleSectionHeader(
              keyValue: 'config-import-toggle',
              title: '导入新配置',
              expanded: _importExpanded,
              onTap: () => setState(() => _importExpanded = !_importExpanded),
            ),
            if (_importExpanded) ...[
              const Text(
                '支持三种导入方式：HTTP(S) 配置地址、本地文件路径、直接粘贴 JSON 文本。'
                '导入失败不会覆盖已有配置。',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: '配置名称（可选）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              // 输入框给**固定高度**，不再用 `Expanded` + `expands` 吃掉整窗剩余空间。
              //
              // 原来它是 `Expanded(child: TextField(expands: true))`，于是窗口多高
              // 它就多高——1440x900 下约 270px 的**空**输入框成了整页最重的东西，
              // 而它喂的「导入」按钮只有小小一颗，层级是反的（截图复核时发现，
              // 2026-10-11）。固定高度让"输入区"和"动作"回到应有的主次。
              SizedBox(
                height: 180,
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
              // 「导入」与它真正服务的两个来源放**同一行**。
              //
              // 原来两个来源按钮被放在「配置名称」那一行的右端，与它们服务的
              // 导入动作隔了一整个输入框；现在它们紧挨着导入按钮，读起来是
              // 「导入（从文件 / 从 fixture / 从上面的内容）」。
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: _busy ? null : _import,
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: LoadingBlock(center: false, size: 16),
                          )
                        : const Icon(Icons.playlist_add_check),
                    label: const Text('导入'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _pickFile,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('选择本地文件'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _importFixture,
                    icon: const Icon(Icons.science_outlined),
                    label: const Text('使用仓库 fixture'),
                  ),
                ],
              ),
            ],
            // 导入结果留在折叠区**外面**：收起之后仍然要能看到刚才那次导入
            // 成功还是失败，否则用户收起面板就丢失了唯一的反馈。
            if (_resultMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                _resultMessage!,
                style: TextStyle(
                  color: _resultIsError
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.primary,
                ),
              ),
            ],

            const Divider(height: 32),
            _SavedConfigs(
              state: state,
              busyIds: _busyIds,
              busyAll: _busyAll,
              onActivate: (id) async {
                await state.activateConfigRecord(id);
                if (mounted) setState(() {});
              },
              onDelete: (id) async {
                final record = state.configRecordById(id);
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    key: const ValueKey('config-delete-confirm'),
                    title: const Text('删除配置记录'),
                    content: Text(
                      '将删除「${record?.name ?? '该配置'}」这条本地记录。'
                      '只删除记录，不删除站点源文件，也不影响安卓设备上的配置。',
                    ),
                    actions: [
                      TextButton(
                        key: const ValueKey('config-delete-cancel'),
                        onPressed: () => Navigator.of(dialogContext).pop(false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        key: const ValueKey('config-delete-ok'),
                        onPressed: () => Navigator.of(dialogContext).pop(true),
                        child: const Text('删除'),
                      ),
                    ],
                  ),
                );
                if (confirmed != true) return;
                await state.deleteConfigRecord(id);
                if (mounted) setState(() {});
              },
              onRefresh: (id) async {
                if (_busyIds.contains(id)) return;
                setState(() => _busyIds.add(id));
                final ok = await state.refreshConfigRecord(id);
                if (!mounted) return;
                final record = state.configRecordById(id);
                setState(() => _busyIds.remove(id));
                showToast(
                  ok
                      ? '已刷新：${record?.name ?? '配置'}（${record?.siteCount ?? 0} 个站点）'
                      : '刷新失败：${state.lastError?.userMessage ?? '未知错误'}',
                  kind: ok ? ToastKind.success : ToastKind.error,
                );
                setState(() {});
              },
              onRefreshAll: () async {
                if (_busyAll) return;
                setState(() => _busyAll = true);
                final failures = await state.refreshAllConfigs();
                if (!mounted) return;
                final total = state.savedConfigs.length;
                setState(() => _busyAll = false);
                showToast(
                  failures.isEmpty
                      ? '已刷新全部 $total 个配置'
                      : '刷新完成：${total - failures.length} 个成功，'
                            '${failures.length} 个失败（${failures.join('、')}）',
                  kind: failures.isEmpty ? ToastKind.success : ToastKind.error,
                );
                setState(() {});
              },
              onEdit: (id) async {
                if (_busyIds.contains(id)) return;
                final record = state.configRecordById(id);
                if (record == null) return;
                final result = await _showEditConfigDialog(context, record);
                if (result == null || !mounted) return;
                if (result.name == record.name.trim() &&
                    result.origin == record.origin.trim()) {
                  return;
                }
                setState(() => _busyIds.add(id));
                final ok = await state.editConfigRecord(
                  id,
                  name: result.name,
                  origin: result.origin,
                );
                if (!mounted) return;
                setState(() => _busyIds.remove(id));
                showToast(
                  ok
                      ? '已保存：${result.name.isEmpty ? record.name : result.name}'
                      : '保存失败：${state.lastError?.userMessage ?? '未知错误'}',
                  kind: ok ? ToastKind.success : ToastKind.error,
                );
                setState(() {});
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
  late final TextEditingController _omdbKey;
  late final TextEditingController _apiBase;
  late final TextEditingController _imageBase;
  late final TextEditingController _language;
  final TextEditingController _siteRule = TextEditingController();
  final TextEditingController _allowRule = TextEditingController();
  final TextEditingController _denyRule = TextEditingController();
  bool _showApiKey = false;
  bool _showAccessToken = false;
  bool _showOmdbKey = false;
  bool _busy = false;
  String? _testResult;
  String? _saveResult;

  @override
  void initState() {
    super.initState();
    _draft = widget.state.tmdbUserConfig;
    _apiKey = TextEditingController(text: _draft.apiKey);
    _accessToken = TextEditingController(text: _draft.accessToken);
    _omdbKey = TextEditingController(text: _draft.omdbApiKey);
    _apiBase = TextEditingController(text: _draft.apiBase);
    _imageBase = TextEditingController(text: _draft.imageBase);
    _language = TextEditingController(text: _draft.language);
  }

  @override
  void dispose() {
    _apiKey.dispose();
    _accessToken.dispose();
    _omdbKey.dispose();
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
    omdbApiKey: _omdbKey.text.trim(),
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
      _draft = widget.state.tmdbUserConfig;
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
      _draft = widget.state.tmdbUserConfig;
    });
  }

  Future<void> _resetRules() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('tmdb-reset-confirm'),
        title: const Text('重置为默认站点规则'),
        content: const Text('将把「禁用站点」恢复为默认的 11 条规则，并清空自定义的启用/白名单规则。'),
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
      _draft = _draft
          .copyWith(enabledSites: const [], allowedSites: const [])
          .withDefaultDisabledRules();
    });
  }

  void _addRule(
    TextEditingController controller,
    List<String> current,
    void Function(List<String>) apply,
  ) {
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
        // 表单收进限宽内容列（见 `formPagePadding`）。
        padding: formPagePadding(context),
        children: [
          SwitchListTile(
            key: const ValueKey('tmdb-enabled'),
            title: const Text('启用 TMDB 增强'),
            subtitle: const Text('关闭后等同未配置：不发起任何 TMDB 请求'),
            value: _draft.enabled,
            onChanged: (value) =>
                setState(() => _draft = _draft.copyWith(enabled: value)),
          ),
          SettingsSection(
            title: '凭据',
            children: [
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
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('tmdb-omdb-key'),
                      controller: _omdbKey,
                      obscureText: !_showOmdbKey,
                      decoration: const InputDecoration(
                        labelText: 'OMDB API Key（可选）',
                        helperText:
                            '用于详情页 IMDb / 烂番茄 / Metacritic 评分；留空则不请求 OMDb',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    key: const ValueKey('tmdb-omdb-key-toggle'),
                    onPressed: () =>
                        setState(() => _showOmdbKey = !_showOmdbKey),
                    child: Text(_showOmdbKey ? '隐藏' : '显示'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SelectableText(
                '日志与诊断中只出现掩码：key=${_draft.redactedApiKey} '
                'token=${_draft.redactedAccessToken} '
                'omdb=${_draft.redactedOmdbApiKey}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          SettingsSection(
            title: '服务',
            children: [
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
            ],
          ),
          SettingsSection(
            title: '匹配',
            children: [
              SwitchListTile(
                key: const ValueKey('tmdb-smart-match'),
                title: const Text('智能匹配'),
                value: _draft.smartMatch,
                onChanged: (value) =>
                    setState(() => _draft = _draft.copyWith(smartMatch: value)),
              ),
              SwitchListTile(
                key: const ValueKey('tmdb-heuristic'),
                title: const Text('启发式季度推断'),
                subtitle: const Text('关闭后证据不足时不再猜测季度（保持「未确定季度」）'),
                value: _draft.heuristicSeasonGuessing,
                onChanged: (value) => setState(
                  () =>
                      _draft = _draft.copyWith(heuristicSeasonGuessing: value),
                ),
              ),
            ],
          ),
          SettingsSection(
            title: '站点规则',
            children: [
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
              const Divider(),
              SettingsActions(
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('tmdb-reset-rules'),
                    onPressed: _resetRules,
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('重置为默认规则'),
                  ),
                ],
              ),
            ],
          ),
          const Divider(height: AppSpace.xl),
          SettingsActions(
            children: [
              FilledButton.icon(
                key: const ValueKey('tmdb-save'),
                onPressed: _busy ? null : _save,
                icon: const Icon(Icons.save_outlined),
                label: const Text('保存'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('tmdb-test'),
                onPressed: _busy ? null : _test,
                icon: const Icon(Icons.wifi_tethering),
                label: const Text('测试连接'),
              ),
              if (_busy) ...[
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: LoadingBlock(center: false, size: 16),
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

/// 换配置选择器：只做一件事——切到另一条已保存的配置。
///
/// 与 [ConfigPage] 刻意分开：那是"维护配置"的地方（导入、编辑、刷新、删除），
/// 而用户点顶栏「配置：xxx」想要的是"换一个源"。两件事混在一页时，换配置这个
/// 高频动作会被 180px 的导入表单挤到首屏之外（用户反馈 2026-11-05）。
///
/// 返回被选中的记录 id；取消返回 `null`。
class ConfigSwitcherDialog extends StatelessWidget {
  const ConfigSwitcherDialog({
    super.key,
    required this.records,
    required this.activeId,
  });

  final List<ConfigRecord> records;
  final int? activeId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      key: const ValueKey('config-switcher'),
      title: const Text('切换配置'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '选择一个配置后，浏览与直播会改用它的站点。当前配置不会被删除。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: records.length,
                itemBuilder: (context, index) {
                  final record = records[index];
                  final isActive = record.id == activeId;
                  return ListTile(
                    key: ValueKey('config-switch-option-${record.id}'),
                    dense: true,
                    selected: isActive,
                    // 已经是它就没有可切的，直接禁用；这与列表页保持一致。
                    onTap: isActive
                        ? null
                        : () => Navigator.of(context).pop(record.id),
                    title: Text(record.name),
                    subtitle: ConfigSourceStatusView(
                      key: ValueKey('config-switch-source-${record.id}'),
                      record: record,
                      metadata: '站点 ${record.siteCount} · 直播 ${record.liveCount}'
                          '${record.bridgeInterfaceKey.isEmpty ? '' : ' · 安卓设备源'}',
                    ),
                    trailing: isActive
                        ? TagChip(
                            keyValue: 'config-switch-current-${record.id}',
                            label: '使用中',
                            emphasized: true,
                          )
                        : const Icon(Icons.chevron_right, size: 18),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('config-switcher-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

/// 可折叠区块的标题行：整行就是开关。
///
/// 用户反馈（2026-11-05）：「最好是点击整行就能折叠和展开」。只让右侧那个小
/// 按钮可点，等于要求用户把指针精确移到一颗 18px 的图标上——在桌面端这比
/// 点一个整行长条费劲得多。
///
/// 标题**不带前导图标**：带了之后文字右移，与下方「已保存的配置」左边缘对不
/// 齐，看起来像缩进了一级的子菜单，而两者本是平级区块。
class _CollapsibleSectionHeader extends StatelessWidget {
  const _CollapsibleSectionHeader({
    required this.title,
    required this.expanded,
    required this.onTap,
    this.keyValue,
  });

  final String title;
  final bool expanded;
  final VoidCallback onTap;

  /// 测试定位用的 key（例如 `config-import-toggle`）。
  final String? keyValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = keyValue;
    return InkWell(
      key: value == null ? null : ValueKey(value),
      onTap: onTap,
      borderRadius: AppRadius.smAll,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const Spacer(),
            Text(
              expanded ? '收起' : '展开',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// 编辑弹窗的返回值。
class _EditResult {
  const _EditResult({required this.name, required this.origin});

  final String name;
  final String origin;
}

/// 配置编辑弹窗：名称 + 源地址。
///
/// 桥接源（`bridgeInterfaceKey` 非空）的地址是安卓设备网关地址，改它没有意义
/// 也不受 PC 控制，因此只给它改名权限。
///
/// **控制器交给 StatefulWidget 自己管**（不在这里 new/dispose）：
/// `showDialog` 的 future 在路由**开始退场**时就完成，若那时 dispose 控制器，
/// 退场动画里的 `TextField` 会访问已释放的 `EditableTextState`，测试直接抛
/// "Looking up a deactivated widget's ancestor is unsafe"。
Future<_EditResult?> _showEditConfigDialog(
  BuildContext context,
  ConfigRecord record,
) {
  return showDialog<_EditResult>(
    context: context,
    builder: (dialogContext) => _EditConfigDialog(record: record),
  );
}

class _EditConfigDialog extends StatefulWidget {
  const _EditConfigDialog({required this.record});

  final ConfigRecord record;

  @override
  State<_EditConfigDialog> createState() => _EditConfigDialogState();
}

class _EditConfigDialogState extends State<_EditConfigDialog> {
  late final TextEditingController _name;
  late final TextEditingController _origin;

  bool get _isBridge => widget.record.bridgeInterfaceKey.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.record.name);
    _origin = TextEditingController(text: widget.record.origin);
  }

  @override
  void dispose() {
    _name.dispose();
    _origin.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context)
        .pop(_EditResult(name: _name.text.trim(), origin: _origin.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey('config-edit-dialog'),
      title: const Text('编辑配置'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('config-edit-name'),
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '配置名称',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('config-edit-origin'),
              controller: _origin,
              enabled: !_isBridge,
              maxLines: 3,
              minLines: 1,
              decoration: InputDecoration(
                labelText: '配置源地址',
                border: const OutlineInputBorder(),
                helperText: _isBridge
                    ? '地址由安卓设备决定，不能在这里修改'
                    : '改地址会立即按新地址重新拉取，失败则保留原配置',
                helperMaxLines: 2,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('config-edit-save'),
          onPressed: _submit,
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _SavedConfigs extends StatelessWidget {
  const _SavedConfigs({
    required this.state,
    required this.busyIds,
    required this.busyAll,
    required this.onActivate,
    required this.onDelete,
    required this.onEdit,
    required this.onRefresh,
    required this.onRefreshAll,
    required this.onCopyOrigin,
  });

  final AppState state;

  /// 正在刷新的记录 id（行内显示忙碌态并禁用按钮）。
  final Set<int> busyIds;

  /// 「全部刷新」在途。
  final bool busyAll;

  final Future<void> Function(int id) onActivate;
  final Future<void> Function(int id) onDelete;
  final Future<void> Function(int id) onEdit;
  final Future<void> Function(int id) onRefresh;
  final Future<void> Function() onRefreshAll;
  final Future<void> Function(String value) onCopyOrigin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final records = state.savedConfigs;
    if (records.isEmpty) {
      return const Align(
        alignment: Alignment.centerLeft,
        child: Text('还没有保存的配置。'),
      );
    }
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('已保存的配置', style: theme.textTheme.titleMedium),
              const Spacer(),
              TextButton.icon(
                key: const ValueKey('config-refresh-all'),
                onPressed: busyAll ? null : onRefreshAll,
                icon: busyAll
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 18),
                label: Text(busyAll ? '刷新中…' : '全部刷新'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '点击任意一行即可切换配置。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              itemCount: records.length,
              itemBuilder: (context, index) {
                final record = records[index];
                final busy = busyIds.contains(record.id);
                return ListTile(
                  key: ValueKey('config-row-${record.id}'),
                  dense: true,
                  selected: record.isActive,
                  // 当前生效项再点一次没有意义，置空让指针反馈也不出现。
                  onTap: record.isActive ? null : () => onActivate(record.id),
                  title: Row(
                    children: [
                      Flexible(child: Text(record.name)),
                      if (record.isActive) ...[
                        const SizedBox(width: 8),
                        TagChip(
                          keyValue: 'config-active-badge-${record.id}',
                          label: '使用中',
                          emphasized: true,
                        ),
                      ],
                    ],
                  ),
                  // 用 Text 而不是 SelectableText：可选文本自带手势识别，
                  // 会和整行的 onTap 抢点击——实测点副标题区域切不动配置，
                  // 而那块正是用户抱怨「能点的区域太小」的地方。
                  subtitle: ConfigSourceStatusView(
                    key: ValueKey('config-list-source-${record.id}'),
                    record: record,
                    metadata: '站点 ${record.siteCount} · 直播 ${record.liveCount} · '
                        '更新 ${record.updatedAt.toLocal()}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (busy)
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 26),
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      else ...[
                        IconButton(
                          key: ValueKey('config-edit-${record.id}'),
                          tooltip: '编辑名称与地址',
                          onPressed: () => onEdit(record.id),
                          icon: const Icon(Icons.edit_outlined, size: 18),
                        ),
                        IconButton(
                          key: ValueKey('config-refresh-${record.id}'),
                          tooltip: '重新拉取该配置的站点',
                          onPressed: () => onRefresh(record.id),
                          icon: const Icon(Icons.refresh, size: 18),
                        ),
                      ],
                      PopupMenuButton<String>(
                        key: ValueKey('config-menu-${record.id}'),
                        tooltip: '更多',
                        enabled: !busy,
                        onSelected: (value) {
                          switch (value) {
                            case 'copy':
                              onCopyOrigin(record.origin);
                            case 'delete':
                              onDelete(record.id);
                          }
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem(value: 'copy', child: Text('复制来源地址')),
                          PopupMenuItem(value: 'delete', child: Text('删除')),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
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
    final ok = await _sync.importSites(device.reachableBase);
    if (!mounted) return;
    if (!ok) return;

    final recordIds = _sync.importRecordIds;
    if (recordIds.isEmpty) return;
    // 单源时沿用原来的「是否切换」确认框；多源时让用户挑一个（或都不切）。
    final recordId = recordIds.length == 1
        ? recordIds.first
        : await _pickImportedSource(device, recordIds);
    if (!mounted || recordId == null) return;

    final active = state.activeRecord;
    if (active?.id == recordId) return;

    final liveCount = state.configs
        .where((item) => item.id == recordId)
        .map((item) => item.liveCount)
        .firstOrNull;
    final record = state.configs
        .where((item) => item.id == recordId)
        .firstOrNull;
    final siteCount = record?.siteCount ?? 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('bridge-switch-confirm'),
        title: const Text('已导入站点，是否切换到该配置？'),
        content: Text(
          '设备：${device.name}\n'
          '播放源：${record?.name ?? recordId}\n'
          '站点：$siteCount 个'
          '${liveCount == null || liveCount == 0 ? '' : '，直播源 $liveCount 个'}\n\n'
          '切换后浏览与直播将改用该播放源。当前配置不会被删除，可随时在配置页切回。',
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

  /// 多源导入后让用户挑一个源来切换（也可以先不切）。
  ///
  /// 返回 `null` 表示用户选择「先不切换」。
  Future<int?> _pickImportedSource(
    AndroidDevice device,
    List<int> recordIds,
  ) async {
    final state = widget.state;
    final records = [
      for (final id in recordIds)
        ...state.configs.where((item) => item.id == id),
    ];
    if (records.isEmpty) return null;
    return showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('bridge-source-picker'),
        title: Text('${device.name} 上有 ${records.length} 个播放源'),
        content: SizedBox(
          width: 420,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: records.length,
            itemBuilder: (context, index) {
              final record = records[index];
              return ListTile(
                key: ValueKey('bridge-source-pick-${record.id}'),
                dense: true,
                title: Text(record.name),
                subtitle: Text('站点 ${record.siteCount} 个'),
                trailing: record.isActive
                    ? const Text('当前')
                    : const Icon(Icons.chevron_right, size: 18),
                onTap: () => Navigator.of(context).pop(record.id),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('bridge-source-pick-later'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('先不切换'),
          ),
        ],
      ),
    );
  }

  Future<void> _push(SyncPeer peer) async {
    final result = await _sync.pushHistoryTo(peer);
    if (!mounted || result == null) return;
    showToast(result.describe(), kind: ToastKind.success);
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
        padding: formPagePadding(context),
        children: [
          SettingsSection(
            title: '设备接入',
            children: [
              Text(
                '接入安卓的 T4 网关可以间接使用安卓上的全部站源（含 T3 爬虫、网盘、猫源），'
                'PC 不复制这些爬虫，只做 HTTP 客户端。',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const ValueKey('android-device-input'),
                    controller: _address,
                    decoration: const InputDecoration(
                      labelText: '手动输入地址',
                      hintText: '例如 192.168.50.9:9978',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _probe(),
                  ),
                  const SizedBox(height: AppSpace.md),
                  SettingsActions(
                    children: [
                      FilledButton.icon(
                        key: const ValueKey('android-device-add'),
                        onPressed: sync.busy ? null : _probe,
                        icon: const Icon(Icons.cable_outlined),
                        label: const Text('接入设备'),
                      ),
                      OutlinedButton.icon(
                        key: const ValueKey('android-scan'),
                        onPressed: sync.busy ? null : _scan,
                        icon: const Icon(Icons.wifi_find_outlined),
                        label: const Text('扫描局域网'),
                      ),
                    ],
                  ),
                ],
              ),
              if (sync.scanTotal > 0) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(value: sync.scanDone / sync.scanTotal),
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
            ],
          ),
          SettingsSection(
            title: '最近接入',
            description: '（点一下就重新接入，不用再输地址）',
            children: [
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
                          onPressed: sync.busy ? null : () => _reconnect(entry),
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
            ],
          ),
          SettingsSection(
            title: '安卓设备',
            children: [
              if (sync.devices.isEmpty)
                const Text('尚未接入设备：可手动输入地址，或扫描局域网。')
              else
                for (final device in sync.devices) _deviceCard(theme, device),
            ],
          ),
          SettingsSection(
            title: '同步设置',
            children: [
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
            ],
          ),
          SettingsSection(
            title: '实时同步',
            children: _realtimeSection(theme, sync),
          ),
          SettingsSection(title: '手动操作', children: _manualSection(theme, sync)),
          SettingsSection(
            title: '已授权对端',
            children: [
              if (sync.peers.isEmpty)
                const Text('尚未授权任何对端：安卓推送历史前需先在此授权。')
              else
                for (final peer in sync.peers) _peerTile(theme, peer),
            ],
          ),
          const SizedBox(height: AppSpace.md),
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

  /// 「实时同步」区块（`design/01` §6.1、§7.2）。
  ///
  /// 全部默认**关闭**（P3）。每一条披露都对应一个具体、可行动的事实：
  /// 不说清楚用户只能猜。
  List<Widget> _realtimeSection(ThemeData theme, SyncState sync) {
    final realtime = sync.realtime;
    final snapshot = sync.realtimeSnapshot;
    final blocking = sync.busy;
    final subDisabled = blocking || !realtime.enabled;
    return [
      Text(
        '开启后按周期把安卓的观影记录拉到本机，并用心跳判断安卓是否还在线'
        '（默认关闭：每个方向都需要你显式开启）。',
        style: theme.textTheme.bodySmall,
      ),
      SwitchListTile(
        key: const ValueKey('realtime-enabled'),
        title: const Text('开启实时同步'),
        subtitle: const Text('关闭后定时器与心跳全部停止，子开关的选择会保留'),
        value: realtime.enabled,
        onChanged: blocking ? null : sync.setRealtimeEnabled,
      ),
      SwitchListTile(
        key: const ValueKey('realtime-pull'),
        title: const Text('实时拉取（PC → 安卓）'),
        subtitle: Text(
          realtime.pollAllSites
              ? '每 ${realtime.intervalSeconds}s 轮询全部站点'
              : '每 ${realtime.intervalSeconds}s 轮询最近活跃的 20 个站点',
        ),
        value: realtime.pullEnabled,
        onChanged: subDisabled ? null : sync.setRealtimePull,
      ),
      SwitchListTile(
        key: const ValueKey('realtime-push'),
        title: const Text('实时推送（安卓 → PC）'),
        subtitle: const Text('需本机服务端在听：开启时会自动拉起（否则安卓拉不到）'),
        value: realtime.pushEnabled,
        onChanged: subDisabled ? null : sync.setRealtimePush,
      ),
      SwitchListTile(
        key: const ValueKey('realtime-settings'),
        title: const Text('设置实时同步（含凭据）'),
        subtitle: const Text('将以明文 HTTP 在局域网传输 API Key，需先开启下方「同步设置项」'),
        value: realtime.settingsEnabled,
        onChanged: subDisabled ? null : sync.setRealtimeSettings,
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Wrap(
          spacing: AppSpace.md,
          runSpacing: AppSpace.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('轮询周期'),
            DropdownButton<int>(
              key: const ValueKey('realtime-interval'),
              value: realtime.intervalSeconds,
              onChanged: subDisabled
                  ? null
                  : (value) {
                      if (value != null) {
                        sync.setRealtimeIntervalSeconds(value);
                      }
                    },
              items: [
                for (final seconds in realtimeIntervalChoices)
                  DropdownMenuItem(value: seconds, child: Text('$seconds s')),
              ],
            ),
            Text(
              '心跳 ${realtime.heartbeatSeconds}s',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
      CheckboxListTile(
        key: const ValueKey('realtime-poll-all-sites'),
        dense: true,
        title: const Text('轮询全部站点'),
        subtitle: const Text('默认只轮询最近活跃的 20 个（更省电，也更准）'),
        value: realtime.pollAllSites,
        onChanged: subDisabled
            ? null
            : (value) => sync.setRealtimePollAllSites(value ?? false),
      ),
      if (snapshot != null) ...[
        SelectableText(
          key: const ValueKey('realtime-status'),
          '状态：${_realtimeStateText(snapshot)}',
          style: theme.textTheme.bodySmall,
        ),
        if (snapshot.lastPoll != null)
          SelectableText(
            key: const ValueKey('realtime-last-pull'),
            '最近一次：${_pullSummary(snapshot.lastPoll!)}',
            style: theme.textTheme.bodySmall,
          ),
        if (snapshot.needsUserAttention)
          Card(
            key: const ValueKey('realtime-attention'),
            color: theme.colorScheme.errorContainer,
            child: ListTile(
              leading: const Icon(Icons.warning_amber_outlined),
              title: const Text('自动同步已停止（重试不会自动恢复）'),
              subtitle: Text(snapshot.lastError?.userMessage ?? '点「立即重连」重新检测'),
              trailing: TextButton(
                key: const ValueKey('realtime-retry'),
                onPressed: blocking ? null : sync.retryRealtimeNow,
                child: const Text('立即重连'),
              ),
            ),
          ),
      ],
      // 披露（`design/01` §7.2）：每条都对应一个具体、可行动的事实。
      //
      // 降级/不支持这两条读的是**状态层**而不是引擎快照：手动拉取用的是
      // 临时引擎，快照不会留存，但披露必须照样上屏（P5）。
      if (sync.realtimeDegradedSites.isNotEmpty)
        SelectableText(
          key: const ValueKey('realtime-disclosure-degraded'),
          '本周期 ${sync.realtimeDegradedSites.length} 个站点只能读到「正在播放」的记录'
          '（安卓的读取接口不返回整站历史，请升级安卓端）。',
          style: theme.textTheme.bodySmall,
        ),
      if (sync.realtimePullCapability == RealtimePullCapability.unsupported)
        SelectableText(
          key: const ValueKey('realtime-disclosure-unsupported'),
          '安卓端不支持历史读取接口（路径 A 不可用，请升级安卓端）。',
          style: theme.textTheme.bodySmall,
        ),
      if (snapshot?.peerState == RealtimePeerState.serviceStopped)
        SelectableText(
          key: const ValueKey('realtime-disclosure-service-stopped'),
          '安卓的局域网服务未运行：请在安卓打开「管理页」并保持运行。',
          style: theme.textTheme.bodySmall,
        ),
      if (snapshot?.peerState == RealtimePeerState.peerFrozen)
        SelectableText(
          key: const ValueKey('realtime-disclosure-peer-frozen'),
          '安卓进程被系统冻结：请在安卓设置中允许本应用后台运行（电池 → 不受限制）。',
          style: theme.textTheme.bodySmall,
        ),
      if (snapshot?.backgroundGuide != null)
        SelectableText(
          key: const ValueKey('realtime-disclosure-background-guide'),
          '安卓提示：${snapshot!.backgroundGuide}',
          style: theme.textTheme.bodySmall,
        ),
      if (realtime.settingsEnabled)
        SelectableText(
          key: const ValueKey('realtime-disclosure-plaintext'),
          '已开启设置实时同步：API Key 等凭据将以明文 HTTP 在局域网传输。',
          style: theme.textTheme.bodySmall,
        ),
    ];
  }

  /// 「手动操作」区块（`design/01` §4.4、§4.5、§7.1）。
  ///
  /// 四个按钮的语义**必须分开写清**：它们在「服务端没开」「未授权」时的
  /// 行为完全不同，混成一个按钮只会给用户一个无法解释的失败。
  List<Widget> _manualSection(ThemeData theme, SyncState sync) {
    final blocking = sync.busy;
    return [
      Text(
        '「拉取最近记录」不依赖本机服务端，实时同步关着也能用；'
        '「请求安卓推送全量」需要本机服务端在听且设备已授权。',
        style: theme.textTheme.bodySmall,
      ),
      SettingsActions(
        children: [
          OutlinedButton.icon(
            key: const ValueKey('realtime-manual-pull'),
            onPressed: blocking ? null : sync.manualPullRecentRecords,
            icon: const Icon(Icons.download_outlined),
            label: const Text('拉取最近记录'),
          ),
          OutlinedButton.icon(
            key: const ValueKey('realtime-manual-request-push'),
            onPressed: blocking ? null : sync.requestAndroidPushFull,
            icon: const Icon(Icons.sync_outlined),
            label: const Text('请求安卓推送全量'),
          ),
          OutlinedButton.icon(
            key: const ValueKey('realtime-manual-push-history'),
            onPressed: blocking ? null : _pushToActivePeer,
            icon: const Icon(Icons.upload_outlined),
            label: const Text('推送历史'),
          ),
          OutlinedButton.icon(
            key: const ValueKey('realtime-manual-push-settings'),
            onPressed: blocking ? null : _pushSettingsToActivePeer,
            icon: const Icon(Icons.tune_outlined),
            label: const Text('推送设置'),
          ),
        ],
      ),
      if (sync.lastPullResult != null)
        SelectableText(
          key: const ValueKey('realtime-manual-result'),
          '上次手动拉取：${_pullSummary(sync.lastPullResult!)}',
          style: theme.textTheme.bodySmall,
        ),
    ];
  }

  /// 引擎状态的用户可读描述。
  String _realtimeStateText(RealtimeEngineSnapshot snapshot) {
    if (!snapshot.running) return '未启用';
    final parts = <String>[
      if (snapshot.pollScheduled)
        '轮询中'
      else if (snapshot.pollPaused)
        '轮询已暂停'
      else
        '轮询未启动',
      if (snapshot.heartbeatScheduled) '心跳中',
      if (snapshot.pollFailures > 0) '失败 ${snapshot.pollFailures} 次',
      '游标 ${snapshot.cursor}',
    ];
    return parts.join(' · ');
  }

  /// 一次拉取结果的一行摘要。
  String _pullSummary(RealtimePollResult result) =>
      '${result.stats.describe()} '
      '（${result.siteCount} 个站点${result.cursorAdvanced ? '' : '，游标未推进'}）';

  /// 推送到「当前目标设备」对应的已授权对端。
  Future<void> _pushToActivePeer() async {
    final peer = _activePeer();
    if (peer == null) return;
    await _push(peer);
  }

  /// 推送设置到当前目标设备（需已开启含凭据同步）。
  Future<void> _pushSettingsToActivePeer() async {
    final peer = _activePeer();
    if (peer == null) return;
    await _sync.pushSettingsTo(peer);
  }

  /// 手动推送的目标：最近接入的设备（未授权时提示授权）。
  SyncPeer? _activePeer() {
    final base = _sync.realtimeDeviceBase;
    if (base != null) {
      for (final peer in _sync.peers) {
        if (normalizeBase(peer.address) == normalizeBase(base)) return peer;
      }
    }
    // 没有目标设备 / 目标未授权：给出可行动的原因，而不是静默什么都不做。
    _sync.clearMessages();
    return null;
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
            Text(
              '${device.name}（${device.typeLabel}）',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: AppSpace.sm),
            SettingsActions(
              children: [
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
    subtitle: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${peer.maskedUuid} · ${peer.address}'),
        const SizedBox(height: AppSpace.sm),
        SettingsActions(
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
      ],
    ),
  );
}
