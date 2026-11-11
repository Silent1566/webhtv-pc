/// AI 设置页（`docs/phase6/design/04` §7.6）。
///
/// 只服务一件事：季度弹窗的「AI 识别剧集/季度」。页面上明说这一点，
/// 避免用户以为 AI 会在后台自动调用。
library;

import 'package:flutter/material.dart';

import '../core/ai_config.dart';
import '../services/ai_completion_client.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'settings_layout.dart';
import 'tokens.dart';

class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({super.key, required this.state, this.fetchModelList});

  final AppState state;

  /// 拉取模型列表的实现；默认真实网络请求，测试可注入以避免联网。
  final Future<List<String>> Function(AiConfig config)? fetchModelList;

  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  late final AiConfig _base;
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
    final config = widget.state.aiConfig.sanitized();
    _base = config;
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
  }

  @override
  void dispose() {
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
      'endpoint': _endpoint.text,
      'apiKey': _apiKey.text,
      'model': _model.text,
      'customUserAgent': _userAgent.text,
      'timeoutSeconds':
          int.tryParse(_timeout.text.trim()) ?? _base.timeoutSeconds,
      for (final entry in _prompts.entries)
        '${entry.key}Prompt': entry.value.text,
      for (final entry in _prompts.entries)
        '${entry.key}PromptVersion':
            entry.value.text.trim() == original['${entry.key}Prompt']
            ? original['${entry.key}PromptVersion']
            : defaults['${entry.key}PromptVersion'],
    });
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
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: '${_promptLabels[key]}提示词',
            border: const OutlineInputBorder(),
          ),
        ),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton.icon(
            key: ValueKey('ai-$key-prompt-reset'),
            onPressed: () => setState(() {
              _prompts[key]!.text =
                  const AiConfig().toJson()['${key}Prompt']! as String;
            }),
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
          onChanged: (value) => setState(() => _modelKeyword = value),
          decoration: InputDecoration(
            labelText: '模型',
            hintText: 'gpt-4.1-mini',
            border: const OutlineInputBorder(),
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
            decoration: BoxDecoration(
              border: Border.all(color: theme.dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: matches.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(AppSpace.md),
                    child: Text(
                      '没有匹配的模型名',
                      style: theme.textTheme.bodySmall,
                    ),
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
                        onTap: () => setState(() {
                          _model.text = name;
                          _modelKeyword = '';
                          _modelListOpen = false;
                        }),
                      );
                    },
                  ),
          ),
        ],
      ],
    );
  }

  Future<void> _save() async {
    setState(() => _status = '正在保存…');
    final ok = await widget.state.saveAiConfig(_draft);
    if (!mounted) return;
    setState(() => _status = ok ? '已保存' : '保存失败（详见日志）');
  }

  Future<void> _testConnection() async {
    setState(() {
      _busy = true;
      _status = '正在测试连接…';
    });
    final client = AiCompletionClient();
    final result = await client.complete(
      config: _draft,
      prompt:
          '这是 AI 服务连通性测试。请只返回 JSON: '
          '{"ok":true,"message":"connected"}',
    );
    client.close();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = result.ok ? '连接成功：${result.text}' : '连接失败：${result.message}';
    });
  }

  Future<void> _fetchModels() async {
    setState(() {
      _busy = true;
      _status = '正在拉取模型列表…';
    });
    final fetch = widget.fetchModelList ?? fetchAiModelList;
    final models = await fetch(_draft);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _modelOptions = models;
      _modelKeyword = '';
      _modelListOpen = models.isNotEmpty;
      _status = models.isEmpty
          ? '未取到模型列表（可手动填写模型名）'
          : '取到 ${models.length} 个模型：${models.take(5).join('、')}'
                '${models.length > 5 ? ' …' : ''}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      key: const ValueKey('ai-settings-page'),
      appBar: AppBar(title: const Text('AI 助手')),
      body: ListView(
        padding: formPagePadding(context),
        children: [
          Text(
            'AI 仅用于季度弹窗的「AI 识别剧集/季度」，不会自动调用。'
            '未配置时其余季度选项照常可用。',
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
                onChanged: (value) => setState(() => _enabled = value),
                title: const Text('启用 AI 服务'),
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: AppSpace.md),
              DropdownButtonFormField<String>(
                key: const ValueKey('ai-protocol'),
                initialValue: _protocol,
                decoration: const InputDecoration(
                  labelText: '协议',
                  border: OutlineInputBorder(),
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
                decoration: const InputDecoration(
                  labelText: '端点',
                  hintText: 'https://api.openai.com/v1/responses',
                  border: OutlineInputBorder(),
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
                obscureText: !_revealKey,
                decoration: InputDecoration(
                  labelText: 'API Key',
                  border: const OutlineInputBorder(),
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
                decoration: const InputDecoration(
                  labelText: 'User-Agent（可选）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppSpace.md),
              TextField(
                key: const ValueKey('ai-timeout'),
                controller: _timeout,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '请求超时（秒）',
                  helperText:
                      '默认 300 秒（5 分钟），可设 30–1800。推荐、画像这类长输出'
                      '在小模型或慢中转上容易超时，按需调大。',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          // 五套提示词：与安卓 `AiConfig` 同名，改了就随保存写回；
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
            description: '测试与拉取只使用当前输入，不落盘；保存后才写入设置。',
            children: [
              SettingsActions(
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('ai-test'),
                    onPressed: _busy ? null : _testConnection,
                    icon: const Icon(Icons.network_check),
                    label: const Text('测试连接'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('ai-fetch-models'),
                    onPressed: _busy ? null : _fetchModels,
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('拉取模型列表'),
                  ),
                  FilledButton.icon(
                    key: const ValueKey('ai-save'),
                    onPressed: _busy ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('保存'),
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
            ],
          ),
        ],
      ),
    );
  }
}
