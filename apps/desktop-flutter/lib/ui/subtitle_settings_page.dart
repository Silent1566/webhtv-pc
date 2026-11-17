/// 字幕源设置页（`docs/phase9/design/02` §3、
/// `docs/superpowers/plans/2026-11-15-subtitle-online-search.md`）。
///
/// 只配置「去哪里找字幕」：自动匹配开关，以及每个源自己的开关/令牌
/// （ASSRT、迅雷、射手、本地目录、HTTP 源）。
/// 不在这里做搜索——搜索是播放期行为，入口在播放器字幕菜单。
/// 也不判断某个源「是否可用」：什么算启用由 [SubtitleSettings] 的 getter 定义，
/// 这里只负责写设置和如实统计。
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

class _SubtitleSaveStatus extends ChangeNotifier {
  int _revision = 0;
  bool busy = false;
  bool? saved;

  int begin() {
    busy = true;
    notifyListeners();
    return ++_revision;
  }

  void finish(int revision, bool ok) {
    if (revision != _revision) return;
    busy = false;
    saved = ok;
    notifyListeners();
  }
}

class _SubtitleSettingsPageState extends State<SubtitleSettingsPage> {
  static final _saveStatuses = Expando<_SubtitleSaveStatus>();
  late final _SubtitleSaveStatus _saveStatus;
  late bool _autoMatch;
  late final TextEditingController _endpoint;
  late final TextEditingController _token;
  late final TextEditingController _assrtToken;
  late final TextEditingController _directories;
  bool _revealToken = false;
  bool _revealAssrtToken = false;
  bool _xunleiEnabled = false;
  bool _shooterEnabled = false;
  String? _endpointError;

  String? get _message => _saveStatus.saved == false
      ? '保存失败：设置文件不可写，请检查权限后重新修改'
      : !_saveStatus.busy && _saveStatus.saved == true
      ? '已保存'
      : null;

  void _saveStatusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _saveStatus = _saveStatuses[widget.state] ??= _SubtitleSaveStatus();
    _saveStatus.addListener(_saveStatusChanged);
    final settings = widget.state.subtitleSettings;
    _autoMatch = settings.autoMatch;
    _endpoint = TextEditingController(text: settings.httpEndpoint);
    _token = TextEditingController(text: settings.httpToken);
    _assrtToken = TextEditingController(text: settings.assrtToken);
    _directories = TextEditingController(
      text: settings.localDirectories.join('\n'),
    );
    _xunleiEnabled = settings.xunleiEnabled;
    _shooterEnabled = settings.shooterEnabled;
  }

  @override
  void dispose() {
    _saveStatus.removeListener(_saveStatusChanged);
    _endpoint.dispose();
    _token.dispose();
    _assrtToken.dispose();
    _directories.dispose();
    super.dispose();
  }

  List<String> get _directoryList => [
    for (final line in _directories.text.split(RegExp(r'\r?\n')))
      if (line.trim().isNotEmpty) line.trim(),
  ];

  void _endpointChanged(String value) {
    final endpoint = value.trim();
    final uri = Uri.tryParse(endpoint);
    final valid =
        endpoint.isEmpty ||
        (uri != null &&
            (uri.scheme == 'http' || uri.scheme == 'https') &&
            uri.host.isNotEmpty &&
            !RegExp(r'\s').hasMatch(endpoint));
    setState(() {
      _endpointError = valid ? null : '请输入有效的 HTTP(S) 地址，或留空停用该源';
    });
    if (valid) _save();
  }

  Future<void> _save() async {
    final state = widget.state;
    final settings = state.subtitleSettings.copyWith(
      autoMatch: _autoMatch,
      httpEndpoint: _endpointError == null
          ? _endpoint.text.trim()
          : state.subtitleSettings.httpEndpoint,
      httpToken: _token.text.trim(),
      localDirectories: _directoryList,
      assrtToken: _assrtToken.text.trim(),
      xunleiEnabled: _xunleiEnabled,
      shooterEnabled: _shooterEnabled,
    );
    if (settings == state.subtitleSettings && _saveStatus.saved != false) {
      return;
    }
    final revision = _saveStatus.begin();
    bool ok;
    try {
      ok = await state.setSubtitleSettings(settings);
    } catch (_) {
      ok = false;
    }
    _saveStatus.finish(revision, ok);
  }

  Future<void> _addDefaultDirectory() async {
    final paths = widget.paths ?? widget.state.paths;
    final suggested = '${paths.configDir}${Platform.pathSeparator}subtitles';
    final existing = _directoryList;
    if (existing.contains(suggested)) return;
    setState(() {
      _directories.text = [...existing, suggested].join('\n');
    });
    await _save();
  }

  /// 已启用的源数量：五个来源彼此独立，逐个问 [SubtitleSettings] 的 getter。
  int get _enabledSourceCount {
    final settings = widget.state.subtitleSettings;
    return [
      settings.hasLocalProvider,
      settings.hasHttpProvider,
      settings.hasAssrt,
      settings.hasXunlei,
      settings.hasShooter,
    ].where((enabled) => enabled).length;
  }

  String get _statusText {
    final settings = widget.state.subtitleSettings;
    final auto = settings.autoMatch ? ' · 自动匹配已开' : '';
    if (!settings.hasAnyProvider) return '当前状态：未配置任何字幕源$auto';
    return '当前状态：已配置字幕源 · 已启用 $_enabledSourceCount 个源$auto';
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
                onChanged: (value) {
                  setState(() => _autoMatch = value);
                  _save();
                },
              ),
            ],
          ),
          SettingsSection(
            title: 'ASSRT',
            children: [
              const Text(
                '在 assrt.net 注册后获取免费 token；留空则不启用该源，也不发任何请求',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: AppSpace.sm),
              TextField(
                key: const ValueKey('subtitle-assrt-token'),
                controller: _assrtToken,
                onChanged: (_) => _save(),
                obscureText: !_revealAssrtToken,
                decoration: InputDecoration(
                  labelText: 'ASSRT token',
                  border: const OutlineInputBorder(),
                  // tooltip 不能与 HTTP 源的「显示令牌」同名，否则一个
                  // find.byTooltip 会同时命中两个按钮。
                  suffixIcon: IconButton(
                    key: const ValueKey('subtitle-assrt-token-reveal'),
                    tooltip: _revealAssrtToken
                        ? '隐藏 ASSRT token'
                        : '显示 ASSRT token',
                    icon: Icon(
                      _revealAssrtToken
                          ? Icons.visibility_off
                          : Icons.visibility,
                    ),
                    onPressed: () =>
                        setState(() => _revealAssrtToken = !_revealAssrtToken),
                  ),
                ),
              ),
            ],
          ),
          SettingsSection(
            title: '迅雷字幕',
            children: [
              SwitchListTile(
                key: const ValueKey('subtitle-xunlei-enabled'),
                contentPadding: EdgeInsets.zero,
                title: const Text('启用迅雷字幕源'),
                subtitle: const Text('免 token，按片名搜索'),
                value: _xunleiEnabled,
                onChanged: (value) {
                  setState(() => _xunleiEnabled = value);
                  _save();
                },
              ),
            ],
          ),
          SettingsSection(
            title: '射手字幕',
            children: [
              SwitchListTile(
                key: const ValueKey('subtitle-shooter-enabled'),
                contentPadding: EdgeInsets.zero,
                title: const Text('启用射手字幕源'),
                subtitle: const Text('按本地视频文件特征码搜索，只对本地文件播放有效；网络播放不会出结果'),
                value: _shooterEnabled,
                onChanged: (value) {
                  setState(() => _shooterEnabled = value);
                  _save();
                },
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
                onChanged: (_) => _save(),
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
                onChanged: _endpointChanged,
                decoration: InputDecoration(
                  errorText: _endpointError,
                  labelText: '搜索地址',
                  border: OutlineInputBorder(),
                  hintText: 'https://example.test/subtitles/search',
                ),
              ),
              const SizedBox(height: AppSpace.md),
              TextField(
                key: const ValueKey('subtitle-http-token'),
                controller: _token,
                onChanged: (_) => _save(),
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
              Text(
                _saveStatus.busy ? '正在保存…' : '设置修改后立即生效',
                style: theme.textTheme.bodySmall,
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
            _statusText,
            key: const ValueKey('subtitle-status'),
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
