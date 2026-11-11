/// 字幕源设置页（`docs/phase9/design/02` §3）。
///
/// 只配置「去哪里找字幕」：自动匹配开关、语言优先级、本地目录、HTTP 源。
/// 不在这里做搜索——搜索是播放期行为，入口在播放器字幕菜单。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../services/app_paths.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'settings_layout.dart';
import 'tokens.dart';

class SubtitleSettingsPage extends StatefulWidget {
  const SubtitleSettingsPage({super.key, required this.state, this.paths});

  final AppState state;

  /// 用于给出「默认字幕目录」的当前路径（测试可注入）。
  final AppPaths? paths;

  @override
  State<SubtitleSettingsPage> createState() => _SubtitleSettingsPageState();
}

class _SubtitleSettingsPageState extends State<SubtitleSettingsPage> {
  late bool _autoMatch;
  late final TextEditingController _endpoint;
  late final TextEditingController _token;
  late final TextEditingController _directories;
  bool _revealToken = false;
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    final settings = widget.state.subtitleSettings;
    _autoMatch = settings.autoMatch;
    _endpoint = TextEditingController(text: settings.httpEndpoint);
    _token = TextEditingController(text: settings.httpToken);
    _directories = TextEditingController(
      text: settings.localDirectories.join('\n'),
    );
  }

  @override
  void dispose() {
    _endpoint.dispose();
    _token.dispose();
    _directories.dispose();
    super.dispose();
  }

  List<String> get _directoryList => [
    for (final line in _directories.text.split(RegExp(r'\r?\n')))
      if (line.trim().isNotEmpty) line.trim(),
  ];

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final settings = widget.state.subtitleSettings.copyWith(
      autoMatch: _autoMatch,
      httpEndpoint: _endpoint.text.trim(),
      httpToken: _token.text.trim(),
      localDirectories: _directoryList,
    );
    final ok = await widget.state.setSubtitleSettings(settings);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = ok ? '已保存' : '保存失败：设置文件不可写';
    });
  }

  Future<void> _addDefaultDirectory() async {
    final paths = widget.paths ?? widget.state.paths;
    final suggested = '${paths.configDir}${Platform.pathSeparator}subtitles';
    final existing = _directoryList;
    if (existing.contains(suggested)) return;
    setState(() {
      _directories.text = [...existing, suggested].join('\n');
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('字幕源')),
      body: ListView(
        padding: formPagePadding(context),
        children: [
          SettingsSection(
            title: '自动匹配',
            children: [
              SwitchListTile(
                key: const ValueKey('subtitle-auto-match'),
                contentPadding: EdgeInsets.zero,
                title: const Text('播放结果没有字幕时自动匹配'),
                subtitle: const Text('只在配置了至少一个字幕源时生效；失败不阻塞播放'),
                value: _autoMatch,
                onChanged: (value) => setState(() => _autoMatch = value),
              ),
            ],
          ),
          SettingsSection(
            title: '本地目录',
            children: [
              Text(
                '每行一个目录，递归两层；文件名包含片名即视为候选。',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: AppSpace.sm),
              TextField(
                key: const ValueKey('subtitle-local-directories'),
                controller: _directories,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: r'C:\Users\you\Videos\subtitles',
                ),
              ),
              const SizedBox(height: AppSpace.md),
              SettingsActions(
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('subtitle-add-default-dir'),
                    onPressed: _addDefaultDirectory,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('加入默认目录'),
                  ),
                ],
              ),
            ],
          ),
          SettingsSection(
            title: 'HTTP 字幕源',
            children: [
              const Text(
                '请求：GET <地址>?q=标题&season=&episode=&token=\n'
                '响应：{"code":0,"data":[{"title","language","format","url"}]} 或数组。\n'
                '未填写地址时该源完全不启用。',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: AppSpace.sm),
              TextField(
                key: const ValueKey('subtitle-http-endpoint'),
                controller: _endpoint,
                decoration: const InputDecoration(
                  labelText: '搜索地址',
                  border: OutlineInputBorder(),
                  hintText: 'https://example.test/subtitles/search',
                ),
              ),
              const SizedBox(height: AppSpace.md),
              TextField(
                key: const ValueKey('subtitle-http-token'),
                controller: _token,
                obscureText: !_revealToken,
                decoration: InputDecoration(
                  labelText: '令牌（可选）',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: _revealToken ? '隐藏令牌' : '显示令牌',
                    icon: Icon(
                      _revealToken ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () =>
                        setState(() => _revealToken = !_revealToken),
                  ),
                ),
              ),
              const SizedBox(height: AppSpace.sm),
              Text(
                '令牌只保存在本机 settings.json，不写日志、不参与同步。',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          SettingsActions(
            children: [
              FilledButton(
                key: const ValueKey('subtitle-save'),
                onPressed: _busy ? null : _save,
                child: const Text('保存'),
              ),
              if (_message != null)
                Text(
                  _message!,
                  key: const ValueKey('subtitle-save-message'),
                  style: theme.textTheme.bodySmall,
                ),
            ],
          ),
          const SizedBox(height: AppSpace.xl),
          Text(
            '当前状态：${widget.state.subtitleSettings.hasAnyProvider ? "已配置字幕源" : "未配置任何字幕源"}'
            '${widget.state.subtitleSettings.autoMatch ? " · 自动匹配已开" : ""}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpace.sm),
          const Text(
            '字幕只增强观看，不改变播放事实：任何字幕失败都只提示，视频照常播。',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}
