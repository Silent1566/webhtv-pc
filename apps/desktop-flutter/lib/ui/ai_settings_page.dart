/// AI 设置页（`docs/phase6/design/04` §7.6）。
///
/// 只服务一件事：季度弹窗的「AI 识别剧集/季度」。页面上明说这一点，
/// 避免用户以为 AI 会在后台自动调用。
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/ai_config.dart';
import '../services/ai_completion_client.dart';
import '../state/app_state.dart';
import 'ai_integration_widgets.dart';
import 'common.dart';
import 'settings_layout.dart';
import 'tokens.dart';

/// push（或同族内替换）打开 AI 设置页。
///
/// 为什么要有这个 seam：业务页的齿轮与设置页的星标都指这里，两页互为兄弟；
/// 直接 `Navigator.push` 会在来回点击时叠栈（A→B→A→B，每层都是新 State）。
Future<void> openAiSettingsPage(
  BuildContext context,
  AppState state, {
  bool replace = false,
}) {
  final route = MaterialPageRoute<void>(
    builder: (_) => AiSettingsPage(state: state),
  );
  if (replace) return Navigator.of(context).pushReplacement(route);
  return Navigator.of(context).push(route);
}

class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({super.key, required this.state, this.fetchModelList});

  final AppState state;

  /// 拉取模型列表的实现；默认真实网络请求，测试可注入以避免联网。
  final Future<List<String>> Function(AiConfig config)? fetchModelList;

  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSaveSession extends ChangeNotifier {
  _AiSaveSession(this.config);

  AiConfig config;
  String? error;
  bool pending = false;
  int _revision = 0;
  Future<void> _queue = Future.value();

  void save(AppState state, AiConfig next) {
    config = next;
    pending = true;
    final revision = ++_revision;
    notifyListeners();
    _queue = _queue.then((_) async {
      var ok = false;
      try {
        ok = await state.saveAiConfig(next);
      } catch (_) {
        ok = false;
      }
      if (revision != _revision) return;
      pending = false;
      error = ok ? null : '保存失败，本次修改未写入磁盘；请修改后重试（详见日志）';
      notifyListeners();
    });
  }
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  late AiConfig _base;
  static final _saveSessions = Expando<_AiSaveSession>();
  late final _AiSaveSession _saveSession;
  int _saveStatusVersion = 0;
  int _statusVersion = 0;
  late final Map<String, TextEditingController> _prompts;
  static const _promptLabels = {
    'recommend': '影视推荐',
    'titleExtraction': '片名提取',
    'viewingReport': '观影画像',
    'adDetection': '广告规则',
    'groupRule': '源名称分组',
  };
  late bool _enabled;
  late String _protocol;
  late final TextEditingController _endpoint;
  late final TextEditingController _apiKey;
  late final TextEditingController _model;
  late final TextEditingController _userAgent;
  late final TextEditingController _timeout;

  /// 是否显示 API Key 明文。默认遮蔽。
  bool _revealKey = false;

  /// 测试连接 / 拉模型的结果提示。
  String _status = '';
  String? get _saveError => _saveSession.error;
  bool _busy = false;

  /// 最近一次成功拉取到的模型名（为空时模型框退回普通输入）。
  List<String> _modelOptions = const [];

  /// 模型下拉面板是否展开；拉取成功后自动展开一次。
  bool _modelListOpen = false;

  /// 用户本会话手动输入的筛选词：只在手动输入时生效。
  String _modelKeyword = '';

  @override
  void initState() {
    super.initState();
    _saveSession = _saveSessions[widget.state] ??= _AiSaveSession(
      widget.state.aiConfig.sanitized(),
    );
    if (!_saveSession.pending && _saveSession.error == null) {
      _saveSession.config = widget.state.aiConfig.sanitized();
    }
    final config = _saveSession.config;
    _base = config;
    _status = _saveSession.pending ? '正在保存…' : _saveError ?? '';
    final json = config.toJson();
    _prompts = {
      for (final key in _promptLabels.keys)
        key: TextEditingController(text: json['${key}Prompt']! as String),
    };
    _enabled = config.enabled;
    _protocol = config.protocol;
    _endpoint = TextEditingController(text: config.endpoint);
    _apiKey = TextEditingController(text: config.apiKey);
    _model = TextEditingController(text: config.model);
    _userAgent = TextEditingController(text: config.customUserAgent);
    _timeout = TextEditingController(text: '${config.timeoutSeconds}');
    _saveSession.addListener(_saveChanged);
  }

  @override
  void dispose() {
    _saveSession.removeListener(_saveChanged);
    for (final controller in _prompts.values) {
      controller.dispose();
    }
    _endpoint.dispose();
    _apiKey.dispose();
    _model.dispose();
    _userAgent.dispose();
    _timeout.dispose();
    super.dispose();
  }

  /// 用 fromJson 合并而不是直接构造：**未知字段必须原样带回去**，
  /// 否则一次「读—改—写」就会把旧版/安卓端的其它字段抹掉。
  AiConfig get _draft {
    final original = _base.toJson();
    final defaults = const AiConfig().toJson();
    return AiConfig.fromJson({
      ...original,
      'enabled': _enabled,
      'protocol': _protocol,
      'endpoint': _endpointError == null ? _endpoint.text : _base.endpoint,
      'apiKey': _apiKey.text,
      'model': _model.text,
      'customUserAgent': _userAgent.text,
      'timeoutSeconds': _timeoutError != null
          ? _base.timeoutSeconds
          : int.tryParse(_timeout.text.trim()) ??
                AiConfig.defaultTimeoutSeconds,
      for (final entry in _prompts.entries)
        '${entry.key}Prompt': entry.value.text,
      for (final entry in _prompts.entries)
        '${entry.key}PromptVersion':
            entry.value.text.trim() == original['${entry.key}Prompt']
            ? original['${entry.key}PromptVersion']
            : defaults['${entry.key}PromptVersion'],
    });
  }

  String? get _endpointError {
    final text = _endpoint.text.trim();
    if (text.isEmpty) return null;
    final uri = Uri.tryParse(text);
    return uri != null &&
            (uri.scheme == 'http' || uri.scheme == 'https') &&
            uri.host.isNotEmpty &&
            !RegExp(r'\s').hasMatch(text)
        ? null
        : '请输入完整的 http:// 或 https:// 服务地址';
  }

  String? get _timeoutError {
    final text = _timeout.text.trim();
    if (text.isEmpty) return null;
    final seconds = int.tryParse(text);
    return seconds != null &&
            seconds >= AiConfig.minTimeoutSeconds &&
            seconds <= AiConfig.maxTimeoutSeconds
        ? null
        : '请输入 30–1800 之间的整数秒数';
  }

  bool get _invalidInput => _endpointError != null || _timeoutError != null;

  void _saveChanged() {
    if (!mounted) return;
    setState(() {
      if (_saveStatusVersion == _statusVersion && !_invalidInput) {
        _status = _saveSession.pending ? '正在保存…' : _saveError ?? '已生效并保存';
      }
    });
  }

  void _changed({bool validChange = true}) {
    final version = ++_statusVersion;
    final next = _draft;
    final changed = jsonEncode(next.toJson()) != jsonEncode(_base.toJson());
    final retry = validChange && _saveError != null;
    setState(() {
      if (_invalidInput) {
        _status = '输入无效，已保留上次有效值';
      } else {
        _status = changed || retry || _saveSession.pending
            ? '正在保存…'
            : _saveError ?? '';
      }
    });
    if (!changed && !retry) {
      if (!_invalidInput && _saveSession.pending) _saveStatusVersion = version;
      return;
    }
    _base = next;
    _saveStatusVersion = version;
    _saveSession.save(widget.state, next);
  }

  /// 切换协议：端点为空、或仍等于旧协议默认端点时，自动填新协议默认端点。
  ///
  /// 为什么不无条件覆盖：用户可能已经手填了中转站地址，覆盖会丢掉它。
  void _changeProtocol(String next) {
    final previousDefault = AiProtocol.defaultEndpoint(_protocol);
    final current = _endpoint.text.trim();
    setState(() {
      _protocol = next;
      if (current.isEmpty || current == previousDefault) {
        _endpoint.text = AiProtocol.defaultEndpoint(next);
      }
    });
    _changed();
  }

  Widget _promptSection(String key) {
    final json = _draft.toJson();
    final custom = json['${key}PromptCustom'] == true;
    return ExpansionTile(
      key: ValueKey('ai-$key-prompt-section'),
      title: Text(_promptLabels[key]!),
      subtitle: Text(
        '${custom ? '自定义' : '内置'} · 版本 ${json['${key}PromptVersion']}',
      ),
      tilePadding: EdgeInsets.zero,
      children: [
        TextField(
          key: ValueKey('ai-$key-prompt'),
          controller: _prompts[key],
          minLines: 4,
          maxLines: 10,
          onChanged: (_) => _changed(),
          decoration: InputDecoration(
            labelText: '${_promptLabels[key]}提示词',
          ),
        ),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton.icon(
            key: ValueKey('ai-$key-prompt-reset'),
            onPressed: () {
              _prompts[key]!.text =
                  const AiConfig().toJson()['${key}Prompt']! as String;
              _changed();
            },
            icon: const Icon(Icons.restore),
            label: const Text('恢复内置提示词'),
          ),
        ),
      ],
    );
  }

  /// 模型选择：既保留手动输入（自定义模型名），又可在拉取列表后下拉筛选。
  Widget _modelField(ThemeData theme) {
    final keyword = _modelKeyword.trim().toLowerCase();
    final matches = keyword.isEmpty
        ? _modelOptions
        : _modelOptions
              .where((name) => name.toLowerCase().contains(keyword))
              .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('ai-model'),
          controller: _model,
          // 输入即筛选：本地匹配，不发起任何网络请求。
          onChanged: (value) {
            _modelKeyword = value;
            _changed();
          },
          decoration: InputDecoration(
            labelText: '模型',
            hintText: 'gpt-4.1-mini',
            helperText: _modelOptions.isEmpty
                ? null
                : '已拉取 ${_modelOptions.length} 个模型：可下拉选择，也可继续手动输入',
            suffixIcon: _modelOptions.isEmpty
                ? null
                : IconButton(
                    key: const ValueKey('ai-model-toggle'),
                    tooltip: _modelListOpen ? '收起模型列表' : '展开模型列表',
                    onPressed: () =>
                        setState(() => _modelListOpen = !_modelListOpen),
                    icon: Icon(
                      _modelListOpen
                          ? Icons.arrow_drop_up
                          : Icons.arrow_drop_down,
                    ),
                  ),
          ),
        ),
        if (_modelListOpen && _modelOptions.isNotEmpty) ...[
          const SizedBox(height: 4),
          Container(
            key: const ValueKey('ai-model-options'),
            constraints: const BoxConstraints(maxHeight: 240),
            padding: const EdgeInsets.all(1),
            child: matches.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(AppSpace.md),
                    child: Text('没有匹配的模型名', style: theme.textTheme.bodySmall),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: matches.length,
                    itemBuilder: (context, index) {
                      final name = matches[index];
                      final selected = name == _model.text.trim();
                      return ListTile(
                        key: ValueKey('ai-model-option-$name'),
                        dense: true,
                        selected: selected,
                        title: Text(name),
                        trailing: selected
                            ? const Icon(Icons.check, size: 18)
                            : null,
                        onTap: () {
                          _model.text = name;
                          _modelKeyword = '';
                          _modelListOpen = false;
                          _changed();
                        },
                      );
                    },
                  ),
          ),
        ],
      ],
    );
  }

  Future<void> _testConnection() async {
    final version = ++_statusVersion;
    final config = _draft;
    setState(() {
      _busy = true;
      _status = '正在测试连接…';
    });
    final client = AiCompletionClient();
    try {
      final result = await client.complete(
        config: config,
        prompt:
            '这是 AI 服务连通性测试。请只返回 JSON: '
            '{"ok":true,"message":"connected"}',
      );
      if (!mounted || version != _statusVersion) return;
      setState(() {
        _status = result.ok ? '连接成功：${result.text}' : '连接失败：${result.message}';
      });
    } catch (_) {
      if (mounted && version == _statusVersion) {
        setState(() => _status = '连接失败，请检查服务设置后重试');
      }
    } finally {
      client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _fetchModels() async {
    final version = ++_statusVersion;
    final config = _draft;
    setState(() {
      _busy = true;
      _status = '正在拉取模型列表…';
    });
    try {
      final fetch = widget.fetchModelList ?? fetchAiModelList;
      final models = await fetch(config);
      if (!mounted || version != _statusVersion) return;
      setState(() {
        _modelOptions = models;
        _modelKeyword = '';
        _modelListOpen = models.isNotEmpty;
        _status = models.isEmpty
            ? '未取到模型列表（可手动填写模型名）'
            : '取到 ${models.length} 个模型：${models.take(5).join('、')}'
                  '${models.length > 5 ? ' …' : ''}';
      });
    } catch (_) {
      if (mounted && version == _statusVersion) {
        setState(() => _status = '拉取模型列表失败，请检查服务设置后重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SettingsRouteScaffold(
      key: const ValueKey('ai-settings-page'),
      title: const Text('AI 助手'),
      actions: [
        // 对称入口：业务页的齿轮指到本页（ai_integration_widgets.dart），
        // 本页也必须能回指——否则从设置点进「AI 助手」就再也到不了阅读器。
        IconButton(
          key: const ValueKey('ai-settings-open-business'),
          tooltip: 'AI 业务与阅读器',
          onPressed: () => openAiBusiness(context, widget.state, replace: true),
          icon: const Icon(Icons.auto_awesome_outlined),
        ),
      ],
      body: ListView(
        padding: formPagePadding(context),
        children: [
          Text(
            'AI 仅用于季度弹窗的「AI 识别剧集/季度」，不会自动调用。'
            '未配置时其余季度选项照常可用。设置修改后即时生效并自动保存。',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpace.xl),
          SettingsSection(
            title: '服务连接',
            description: '协议决定请求形状，端点决定请求发往哪里；模型名留空时使用固定默认模型 gpt-4.1-mini。',
            children: [
              SwitchListTile(
                key: const ValueKey('ai-enabled'),
                value: _enabled,
                onChanged: (value) {
                  _enabled = value;
                  _changed();
                },
                title: const Text('启用 AI 服务'),
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: AppSpace.md),
              SettingsDropdownField<String>(
                key: const ValueKey('ai-protocol'),
                initialValue: _protocol,
                decoration: const InputDecoration(
                  labelText: '协议',
                ),
                items: const [
                  DropdownMenuItem(
                    value: AiProtocol.openAiResponses,
                    child: Text('OpenAI Responses'),
                  ),
                  DropdownMenuItem(
                    value: AiProtocol.openAiChat,
                    child: Text('OpenAI Chat Completions'),
                  ),
                  DropdownMenuItem(
                    value: AiProtocol.anthropicMessages,
                    child: Text('Anthropic Messages'),
                  ),
                  DropdownMenuItem(
                    value: AiProtocol.geminiNative,
                    child: Text('Gemini Native'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) _changeProtocol(value);
                },
              ),
              const SizedBox(height: AppSpace.md),
              TextField(
                key: const ValueKey('ai-endpoint'),
                controller: _endpoint,
                onChanged: (_) => _changed(validChange: _endpointError == null),
                decoration: InputDecoration(
                  errorText: _endpointError,
                  labelText: '端点',
                  hintText: 'https://api.openai.com/v1/responses',
                ),
              ),
              const SizedBox(height: AppSpace.md),
              _modelField(Theme.of(context)),
            ],
          ),
          SettingsSection(
            title: '访问凭据',
            description: '凭据只保存在本机 settings.json；默认遮蔽，显示只影响当前输入框。',
            children: [
              TextField(
                key: const ValueKey('ai-api-key'),
                controller: _apiKey,
                onChanged: (_) => _changed(),
                obscureText: !_revealKey,
                decoration: InputDecoration(
                  labelText: 'API Key',
                  suffixIcon: IconButton(
                    tooltip: _revealKey ? '隐藏' : '显示',
                    onPressed: () => setState(() => _revealKey = !_revealKey),
                    icon: Icon(
                      _revealKey ? Icons.visibility_off : Icons.visibility,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpace.md),
              TextField(
                key: const ValueKey('ai-user-agent'),
                controller: _userAgent,
                onChanged: (_) => _changed(),
                decoration: const InputDecoration(
                  labelText: 'User-Agent（可选）',
                ),
              ),
              const SizedBox(height: AppSpace.md),
              TextField(
                key: const ValueKey('ai-timeout'),
                controller: _timeout,
                onChanged: (_) => _changed(validChange: _timeoutError == null),
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  errorText: _timeoutError,
                  labelText: '请求超时（秒）',
                  helperText:
                      '默认 300 秒（5 分钟），可设 30–1800。推荐、画像这类长输出'
                      '在小模型或慢中转上容易超时，按需调大。',
                ),
              ),
            ],
          ),
          // 五套提示词：与安卓 `AiConfig` 同名，修改后自动写回；
          // 内置旧版会自动升级到当前版，自定义内容原样保留。
          SettingsSection(
            title: '提示词',
            description: '留空或恢复默认 = 使用当前内置版本；自定义内容会原样保存。',
            children: [
              for (final key in _promptLabels.keys) _promptSection(key),
            ],
          ),
          SettingsSection(
            title: '操作与状态',
            description: '设置修改后即时生效并自动保存；测试连接与拉取模型列表仅在点击时发起请求。',
            children: [
              SettingsActions(
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('ai-test'),
                    onPressed: _busy || _invalidInput ? null : _testConnection,
                    icon: const Icon(Icons.network_check),
                    label: const Text('测试连接'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('ai-fetch-models'),
                    onPressed: _busy || _invalidInput ? null : _fetchModels,
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('拉取模型列表'),
                  ),
                ],
              ),
              if (_status.isNotEmpty) ...[
                const SizedBox(height: AppSpace.md),
                Text(
                  _status,
                  key: const ValueKey('ai-settings-status'),
                  style: theme.textTheme.bodySmall,
                ),
              ],
              if (_saveError != null && _saveError != _status) ...[
                const SizedBox(height: AppSpace.md),
                Text(
                  _saveError!,
                  key: const ValueKey('ai-settings-save-error'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
