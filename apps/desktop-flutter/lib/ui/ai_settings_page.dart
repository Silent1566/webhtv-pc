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
  const AiSettingsPage({super.key, required this.state});

  final AppState state;

  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  late bool _enabled;
  late String _protocol;
  late final TextEditingController _endpoint;
  late final TextEditingController _apiKey;
  late final TextEditingController _model;
  late final TextEditingController _userAgent;

  /// 是否显示 API Key 明文。默认遮蔽。
  bool _revealKey = false;

  /// 测试连接 / 拉模型的结果提示。
  String _status = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final config = widget.state.aiConfig.sanitized();
    _enabled = config.enabled;
    _protocol = config.protocol;
    _endpoint = TextEditingController(text: config.endpoint);
    _apiKey = TextEditingController(text: config.apiKey);
    _model = TextEditingController(text: config.model);
    _userAgent = TextEditingController(text: config.customUserAgent);
  }

  @override
  void dispose() {
    _endpoint.dispose();
    _apiKey.dispose();
    _model.dispose();
    _userAgent.dispose();
    super.dispose();
  }

  AiConfig get _draft => AiConfig(
    enabled: _enabled,
    protocol: _protocol,
    endpoint: _endpoint.text.trim(),
    apiKey: _apiKey.text.trim(),
    model: _model.text.trim(),
    customUserAgent: _userAgent.text.trim(),
  ).sanitized();

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
    final models = await fetchAiModelList(_draft);
    if (!mounted) return;
    setState(() {
      _busy = false;
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
              TextField(
                key: const ValueKey('ai-model'),
                controller: _model,
                decoration: const InputDecoration(
                  labelText: '模型',
                  hintText: 'gpt-4.1-mini',
                  border: OutlineInputBorder(),
                ),
              ),
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
