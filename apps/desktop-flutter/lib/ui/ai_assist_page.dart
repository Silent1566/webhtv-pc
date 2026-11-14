/// AI 辅助页（`docs/phase9/README.md` P1-10）。
///
/// 四种任务共用一个页面：选任务 → 填输入 → 运行 → 看结果。
/// **结果只展示，不自动应用**；需要用户自己复制/决定。
library;

import 'package:flutter/material.dart';

import '../core/ai_assist.dart';
import '../services/ai_assist_service.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'settings_layout.dart';
import 'tokens.dart';

class AiAssistPage extends StatefulWidget {
  const AiAssistPage({super.key, required this.state, this.service});

  final AppState state;

  /// 测试注入；默认按当前配置自建。
  final AiAssistService? service;

  @override
  State<AiAssistPage> createState() => _AiAssistPageState();
}

class _AiAssistPageState extends State<AiAssistPage> {
  late final AiAssistService _service =
      widget.service ?? AiAssistService(config: widget.state.aiConfig, log: widget.state.log);

  AiAssistTask _task = AiAssistTask.titleClean;
  final TextEditingController _input = TextEditingController();
  AiAssistResult? _result;
  bool _busy = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _result = null;
    });
    final result = await _service.run(task: _task, input: _input.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('AI 辅助')),
      body: ListView(
        padding: formPagePadding(context),
        children: [
          if (!_service.isReady)
            Card(
              key: const ValueKey('ai-assist-not-ready'),
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.md),
                child: Text(
                  '尚未配置 AI：请先在设置页填写端点/密钥/模型。'
                  '未配置时不会发起任何请求。',
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
            ),
          SettingsSection(
            title: '任务',
            children: [
              LayoutBuilder(
                builder: (context, constraints) =>
                    SegmentedButton<AiAssistTask>(
                      key: const ValueKey('ai-assist-task'),
                      direction: constraints.maxWidth < 600
                          ? Axis.vertical
                          : Axis.horizontal,
                      segments: [
                        for (final task in AiAssistTask.values)
                          ButtonSegment(value: task, label: Text(task.label)),
                      ],
                      selected: {_task},
                      onSelectionChanged: (selection) {
                        setState(() {
                          _task = selection.first;
                          _result = null;
                        });
                      },
                    ),
              ),
              const SizedBox(height: AppSpace.md),
              TextField(
                key: const ValueKey('ai-assist-input'),
                controller: _input,
                minLines: 5,
                maxLines: 12,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: '输入',
                  hintText: _hintFor(_task),
                ),
              ),
              const SizedBox(height: AppSpace.md),
              Text('结果只展示，不会自动修改标题、分组或播放地址。', style: theme.textTheme.bodySmall),
              const SizedBox(height: AppSpace.sm),
              SettingsActions(
                children: [
                  FilledButton.icon(
                    key: const ValueKey('ai-assist-run'),
                    onPressed: _busy || !_service.isReady ? null : _run,
                    icon: const Icon(Icons.auto_awesome),
                    label: Text(_busy ? '分析中…' : '运行'),
                  ),
                ],
              ),
            ],
          ),
          SettingsSection(title: '结果', children: [_buildResult(theme)]),
        ],
      ),
    );
  }

  Widget _buildResult(ThemeData theme) {
    final result = _result;
    if (result == null) {
      return const Text('还没有结果', key: ValueKey('ai-assist-empty'));
    }
    if (!result.ok) {
      return Text(
        result.error ?? '分析失败',
        key: const ValueKey('ai-assist-error'),
        style: TextStyle(color: theme.colorScheme.error),
      );
    }
    return Column(
      key: const ValueKey('ai-assist-result'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...switch (_task) {
          AiAssistTask.titleClean => [
            Text('片名：${result.cleanedTitle ?? "（未给出）"}'),
            if (result.cleanedYear != null) Text('年份：${result.cleanedYear}'),
          ],
          AiAssistTask.logDiagnosis => [
            if (result.causes.isEmpty) const Text('没有给出原因'),
            for (final cause in result.causes)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(cause.reason),
                subtitle: Text('下一步：${cause.action}'),
              ),
          ],
          AiAssistTask.groupSuggestion => [
            Text('建议分组：${result.suggestedGroups.join("、")}'),
          ],
          AiAssistTask.adSegmentReview => [
            if (result.adSegments.isEmpty) const Text('没有给出可疑分片'),
            for (final segment in result.adSegments)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('第 ${segment.line} 行'),
                subtitle: Text(segment.reason),
              ),
          ],
        },
      ],
    );
  }

  static String _hintFor(AiAssistTask task) => switch (task) {
    AiAssistTask.titleClean => '粘贴剧名，例如：[4K] 某剧 第二季 全集',
    AiAssistTask.logDiagnosis => '粘贴一段播放失败日志',
    AiAssistTask.groupSuggestion => '粘贴站点名，例如：木偶影视[盘]',
    AiAssistTask.adSegmentReview => '粘贴 HLS 分片行（时长 主机 路径），每行一条',
  };
}
