/// 网盘链接检测页（`docs/phase9/README.md` P1-8）。
///
/// 粘贴一条或多条分享链接 → 检测 → 按状态展示。会话级结果，不落盘
/// （链接本身是用户数据，不写入设置文件）。
library;

import 'package:flutter/material.dart';

import '../core/pan_check.dart';
import '../services/pan_check_service.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'settings_layout.dart';
import 'tokens.dart';

class PanCheckPage extends StatefulWidget {
  const PanCheckPage({super.key, required this.state, this.service});

  final AppState state;

  /// 测试注入；默认自建。
  final PanCheckService? service;

  @override
  State<PanCheckPage> createState() => _PanCheckPageState();
}

class _PanCheckPageState extends State<PanCheckPage> {
  late final PanCheckService _service =
      widget.service ?? PanCheckService(log: widget.state.log);
  final TextEditingController _input = TextEditingController();
  List<PanCheckResult> _results = const [];
  bool _busy = false;
  String? _message;

  @override
  void dispose() {
    _input.dispose();
    if (widget.service == null) _service.close();
    super.dispose();
  }

  Future<void> _check({bool forceRefresh = false}) async {
    final links = [
      for (final line in _input.text.split(RegExp(r'\r?\n')))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    if (links.isEmpty) {
      setState(() => _message = '请先粘贴至少一条分享链接');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    final results = await _service.checkAll(
      links,
      forceRefresh: forceRefresh,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _results = results;
      _message = results.isEmpty ? '没有可检测的链接' : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('网盘链接检测')),
      body: ListView(
        padding: formPagePadding(context),
        children: [
          SettingsSection(
            title: '分享链接',
            description:
                '每行一条分享链接（可带「提取码: xxxx」）。检测只做可达性与页面特征判定：'
                '无法判定时显示「无法判定」，不会误报失效。',
            children: [
              TextField(
                key: const ValueKey('pan-check-input'),
                controller: _input,
                minLines: 4,
                maxLines: 8,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'https://pan.quark.cn/s/xxxx 提取码: abcd',
                ),
              ),
              const SizedBox(height: AppSpace.md),
              SettingsActions(
                children: [
                  FilledButton.icon(
                    key: const ValueKey('pan-check-run'),
                    onPressed: _busy ? null : () => _check(),
                    icon: const Icon(Icons.play_arrow),
                    label: Text(_busy ? '检测中…' : '开始检测'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('pan-check-refresh'),
                    onPressed: _busy ? null : () => _check(forceRefresh: true),
                    icon: const Icon(Icons.refresh),
                    label: const Text('忽略缓存重检'),
                  ),
                ],
              ),
              if (_message != null)
                Text(
                  _message!,
                  key: const ValueKey('pan-check-message'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
            ],
          ),
          SettingsSection(
            title: '检测结果',
            children: [
              if (_results.isEmpty)
                const Text('还没有检测结果', key: ValueKey('pan-check-empty'))
              else
                for (final result in _results)
                  ListTile(
                    key: ValueKey('pan-check-result-${result.url}'),
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      _iconOf(result.state),
                      color: _colorOf(theme, result.state),
                    ),
                    title: Text(
                      '${result.diskType.label} · ${result.state.label}',
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${result.summary}${result.fromCache ? " · 缓存" : ""}',
                        ),
                        const SizedBox(height: AppSpace.xs),
                        Text(
                          _hostOf(result.url),
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
            ],
          ),
        ],
      ),
    );
  }

  static IconData _iconOf(PanCheckState state) => switch (state) {
    PanCheckState.ok => Icons.check_circle_outline,
    PanCheckState.bad => Icons.error_outline,
    PanCheckState.locked => Icons.lock_outline,
    PanCheckState.unsupported => Icons.help_outline,
    PanCheckState.uncertain => Icons.question_mark,
  };

  static Color _colorOf(ThemeData theme, PanCheckState state) =>
      switch (state) {
        PanCheckState.ok => theme.colorScheme.primary,
        PanCheckState.bad => theme.colorScheme.error,
        _ => theme.colorScheme.onSurfaceVariant,
      };

  static String _hostOf(String url) => Uri.tryParse(url)?.host ?? '';
}
