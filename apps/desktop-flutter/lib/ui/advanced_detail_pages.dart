/// 高级设置明细页。独立路由自行监听 AppState，避免受控开关视觉回弹。
library;

import 'package:flutter/material.dart';

import '../core/doh.dart';
import '../core/doh_settings.dart';
import '../core/outbound_proxy.dart';
import '../core/player_options.dart';
import '../core/site_group_rules.dart';
import '../services/app_paths.dart';
import '../state/app_state.dart';
import 'browser_component_settings.dart';
import 'settings_layout.dart';
import 'toast.dart';
import 'tokens.dart';

/// hub 与明细页共用原有的 DoH 状态说明。
String dohStatusText(AppState state) {
  final endpoints = DohEndpoint.parseList(state.config?.doh);
  final hosts = DohHostMap.parse(state.config?.hosts);
  final buffer = StringBuffer('配置提供 ${endpoints.length} 个 DoH 服务商');
  if (endpoints.isNotEmpty) {
    buffer.write(
      '（${endpoints.map((e) => e.name.isEmpty ? redactDohUrl(e.url) : e.name).join("、")}）',
    );
  }
  buffer.write('、${hosts.entries.length} 条 hosts 静态映射');
  if (endpoints.isEmpty && hosts.isEmpty && !state.dohSettings.hasCustomUrl) {
    buffer.write('；两者都为空时 DoH 不生效，可在这里填自定义端点');
  }
  return buffer.toString();
}

/// 播放参数明细页：解码、连播、倍速、回退与缓存上限。
class PlaybackOptionsPage extends StatelessWidget {
  const PlaybackOptionsPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final theme = Theme.of(context);
        return SettingsDetailScaffold(
          title: '播放参数',
          description: '解码、连播、缓存与失败回退；改动即时保存。',
          children: [
            SettingsSection(
              title: '播放',
              children: [
                Column(
                  key: const ValueKey('settings-player-options'),
                  children: [
                    _switch(
                      'settings-player-hardware-decoding',
                      '硬件解码',
                      '关闭后强制软解；花屏/绿屏时可作为排查手段',
                      state.playerOptions.hardwareDecoding,
                      (value) async {
                        await state.setPlayerOptions(
                          state.playerOptions.copyWith(hardwareDecoding: value),
                        );
                      },
                    ),
                    _switch(
                      'settings-player-auto-next',
                      '自动连播下一集',
                      '关闭后播完当前集会停住；循环模式优先于该开关',
                      state.playerOptions.autoNext,
                      (value) async {
                        await state.setPlayerOptions(
                          state.playerOptions.copyWith(autoNext: value),
                        );
                      },
                    ),
                    ListTile(
                      key: const ValueKey('settings-player-long-press-speed'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('长按画面倍速'),
                      subtitle: Text(
                        '按住画面期间临时 ${_speedText(state.playerOptions.longPressSpeed)} 播放，松开恢复原速',
                      ),
                      trailing: DropdownButton<double>(
                        value: state.playerOptions.longPressSpeed,
                        underline: const SizedBox.shrink(),
                        items: _speedItems(state.playerOptions.longPressSpeed),
                        onChanged: (speed) async {
                          if (speed == null) return;
                          await state.setPlayerOptions(
                            state.playerOptions.copyWith(longPressSpeed: speed),
                          );
                        },
                      ),
                    ),
                    _switch(
                      'settings-player-preload-next',
                      '预解析下一集地址',
                      '只提前解析播放地址，不下载媒体数据',
                      state.playerOptions.preloadNext,
                      (value) async {
                        await state.setPlayerOptions(
                          state.playerOptions.copyWith(preloadNext: value),
                        );
                      },
                    ),
                    _switch(
                      'settings-player-audio-passthrough',
                      '音频直通',
                      '交给功放/回音壁解码；接收端不支持时可能无声',
                      state.playerOptions.audioPassthrough,
                      (value) async {
                        await state.setPlayerOptions(
                          state.playerOptions.copyWith(audioPassthrough: value),
                        );
                      },
                    ),
                    _switch(
                      'settings-player-auto-skip-intro',
                      '自动跳过片头',
                      '需要在播放器菜单里标记过片头才生效',
                      state.playerOptions.autoSkipIntro,
                      (value) async {
                        await state.setPlayerOptions(
                          state.playerOptions.copyWith(autoSkipIntro: value),
                        );
                      },
                    ),
                    _switch(
                      'settings-player-auto-skip-outro',
                      '自动跳过片尾',
                      '需要在播放器菜单里标记过片尾才生效',
                      state.playerOptions.autoSkipOutro,
                      (value) async {
                        await state.setPlayerOptions(
                          state.playerOptions.copyWith(autoSkipOutro: value),
                        );
                      },
                    ),
                    ListTile(
                      key: const ValueKey('settings-player-failure-fallback'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('失败回退'),
                      subtitle: Text(state.playerOptions.failureFallback.label),
                      trailing: DropdownButton<PlayerFailureFallback>(
                        value: state.playerOptions.failureFallback,
                        underline: const SizedBox.shrink(),
                        items: [
                          for (final mode in PlayerFailureFallback.values)
                            DropdownMenuItem(
                              value: mode,
                              child: Text(mode.label),
                            ),
                        ],
                        onChanged: (mode) async {
                          if (mode == null) return;
                          await state.setPlayerOptions(
                            state.playerOptions.copyWith(failureFallback: mode),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
            SettingsSection(
              title: '缓存',
              children: [
                Text(
                  '缓存上限：${state.playerOptions.demuxerMaxBytesMiB} MiB'
                  '（前向）+ ${state.playerOptions.demuxerMaxBackBytesMiB} MiB（回看）',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: AppSpace.md),
                SegmentedButton<int>(
                  key: const ValueKey('settings-player-cache-size'),
                  segments: const [
                    ButtonSegment(value: 128, label: Text('128 MiB')),
                    ButtonSegment(value: 256, label: Text('256 MiB')),
                    ButtonSegment(value: 512, label: Text('512 MiB')),
                  ],
                  selected: {state.playerOptions.demuxerMaxBytesMiB},
                  onSelectionChanged: (selection) async {
                    await state.setPlayerOptions(
                      state.playerOptions.copyWith(
                        demuxerMaxBytesMiB: selection.first,
                        demuxerMaxBackBytesMiB: (selection.first ~/ 4).clamp(
                          8,
                          512,
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _switch(
    String key,
    String title,
    String subtitle,
    bool value,
    Future<void> Function(bool) onChanged,
  ) => SwitchListTile(
    key: ValueKey(key),
    dense: true,
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: Text(subtitle),
    value: value,
    onChanged: (next) => onChanged(next),
  );

  /// 倍速文案：整数不带小数点（3× 而不是 3.0×）。
  String _speedText(double speed) =>
      speed == speed.roundToDouble() ? '${speed.toInt()}×' : '$speed×';

  /// 长按倍速的下拉候选：常用档位 + 当前值。
  ///
  /// 当前值必须在候选里，否则 DropdownButton 直接断言（手改 settings.json
  /// 成 3.5× 这类区间内的值时）。去重升序，常用档不会重复出现。
  List<DropdownMenuItem<double>> _speedItems(double current) {
    final speeds = <double>{
      ...PlayerOptions.longPressSpeedChoices,
      current,
    }.toList()..sort();
    return [
      for (final speed in speeds)
        DropdownMenuItem(value: speed, child: Text(_speedText(speed))),
    ];
  }
}

/// 弹幕源明细页。
class DanmakuSourcePage extends StatelessWidget {
  const DanmakuSourcePage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) => SettingsDetailScaffold(
      title: '弹幕源',
      children: [
        SwitchListTile(
          key: const ValueKey('settings-danmaku-auto-search'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('没有弹幕时自动搜索弹幕库'),
          subtitle: const Text('需要先配置弹幕库地址；失败只提示，不影响播放'),
          value: state.danmakuSettings.autoSearch,
          onChanged: (value) async {
            await state.setDanmakuSettings(
              state.danmakuSettings.copyWith(autoSearch: value),
            );
          },
        ),
        ListTile(
          key: const ValueKey('settings-danmaku-api'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('弹幕库地址'),
          subtitle: Text(
            state.danmakuSettings.apiUrl.isEmpty
                ? '未配置'
                : state.danmakuSettings.apiUrl,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.edit_outlined, size: 18),
          onTap: () => _editDanmakuApi(context),
        ),
      ],
    ),
  );

  Future<void> _editDanmakuApi(BuildContext context) async {
    final controller = TextEditingController(
      text: state.danmakuSettings.apiUrl,
    );
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('弹幕库地址'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'https://example.test/danmaku/search',
          ),
          onSubmitted: (text) => Navigator.of(context).pop(text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null) return;
    await state.setDanmakuSettings(
      state.danmakuSettings.copyWith(apiUrl: value.trim()),
    );
  }
}

/// 站点分组规则明细页。
class SiteGroupRulesPage extends StatelessWidget {
  const SiteGroupRulesPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => SettingsDetailScaffold(
        title: '站点分组规则',
        description:
            '从站点名抽取分组标记（如「木偶[盘]」→「盘」）。内置规则可单独关闭；'
            '自定义规则须含一个捕获组。',
        children: [
          Column(
            key: const ValueKey('settings-group-rules'),
            children: [
              for (final rule in state.siteGroupSettings.rules)
                SwitchListTile(
                  key: ValueKey('settings-group-rule-${rule.id}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(rule.name),
                  subtitle: Text(rule.pattern),
                  value: rule.enabled,
                  onChanged: (value) => _setGroupRuleEnabled(rule.id, value),
                  secondary: rule.builtin
                      ? null
                      : IconButton(
                          tooltip: '删除规则 ${rule.name}',
                          icon: const Icon(Icons.delete_outline, size: 18),
                          onPressed: () => _removeGroupRule(rule.id),
                        ),
                ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          SettingsActions(
            children: [
              OutlinedButton.icon(
                key: const ValueKey('settings-group-rule-add'),
                onPressed: () => _addGroupRule(context),
                icon: const Icon(Icons.add),
                label: const Text('添加自定义规则'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _setGroupRuleEnabled(String id, bool enabled) async {
    final settings = state.siteGroupSettings;
    await state.setSiteGroupSettings(
      settings.copyWith(
        rules: [
          for (final rule in settings.rules)
            if (rule.id == id) rule.copyWith(enabled: enabled) else rule,
        ],
      ),
    );
  }

  Future<void> _removeGroupRule(String id) async {
    final settings = state.siteGroupSettings;
    await state.setSiteGroupSettings(
      settings.copyWith(
        rules: [
          for (final rule in settings.rules)
            if (rule.id != id) rule,
        ],
      ),
    );
  }

  Future<void> _addGroupRule(BuildContext context) async {
    final nameController = TextEditingController();
    final patternController = TextEditingController();
    String? error;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('添加分组规则'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const ValueKey('group-rule-name'),
                controller: nameController,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              const SizedBox(height: AppSpace.sm),
              TextField(
                key: const ValueKey('group-rule-pattern'),
                controller: patternController,
                decoration: const InputDecoration(
                  labelText: '正则（含一个捕获组）',
                  hintText: r'\[([^\]]+)\]',
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: AppSpace.sm),
                Text(
                  error!,
                  key: const ValueKey('group-rule-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final name = nameController.text.trim();
                final pattern = patternController.text.trim();
                if (name.isEmpty || pattern.isEmpty) {
                  setDialogState(() => error = '名称与正则都不能为空');
                  return;
                }
                if (!isValidSiteGroupPattern(pattern)) {
                  setDialogState(() => error = '正则无法编译');
                  return;
                }
                Navigator.of(context).pop(true);
              },
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
    final name = nameController.text.trim();
    final pattern = patternController.text.trim();
    nameController.dispose();
    patternController.dispose();
    if (result != true || !context.mounted) return;
    final settings = state.siteGroupSettings;
    final id = 'custom-${DateTime.now().millisecondsSinceEpoch}';
    await state.setSiteGroupSettings(
      settings.copyWith(
        rules: [
          ...settings.rules,
          SiteGroupRule(id: id, name: name, pattern: pattern),
        ],
      ),
    );
  }
}

/// 出站代理明细页。
class OutboundProxyPage extends StatelessWidget {
  const OutboundProxyPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => SettingsDetailScaffold(
        title: '出站代理',
        description:
            '按域名把请求转发到 HTTP 代理（如 127.0.0.1:7890）。'
            '只影响站点/解析/字幕等出站请求，不影响本地播放代理。',
        children: [
          SwitchListTile(
            key: const ValueKey('settings-outbound-proxy-enabled'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('启用出站代理'),
            subtitle: Text(
              state.outboundProxy.isEffective
                  ? '${state.outboundProxy.validRules.length} 条规则'
                  : '未生效（没有规则或地址不合法）',
            ),
            value: state.outboundProxy.enabled,
            onChanged: (value) async {
              await state.setOutboundProxy(
                state.outboundProxy.copyWith(enabled: value),
              );
            },
          ),
          ListTile(
            key: const ValueKey('settings-outbound-proxy-default'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('默认代理'),
            subtitle: Text(
              state.outboundProxy.defaultProxyUrl.isEmpty
                  ? '未设置（未命中的域名直连）'
                  : state.outboundProxy.defaultProxyUrl,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.edit_outlined, size: 18),
            onTap: () => _editDefaultProxy(context),
          ),
          for (final (index, rule) in state.outboundProxy.rules.indexed)
            ListTile(
              key: ValueKey(
                'settings-outbound-proxy-rule-$index-${rule.proxyUrl}',
              ),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(rule.patterns.join('、')),
              subtitle: Text(rule.proxyUrl),
              trailing: IconButton(
                tooltip: '删除规则',
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: () => _removeOutboundRule(rule),
              ),
            ),
          const SizedBox(height: AppSpace.md),
          SettingsActions(
            children: [
              OutlinedButton.icon(
                key: const ValueKey('settings-outbound-proxy-add'),
                onPressed: () => _addOutboundRule(context),
                icon: const Icon(Icons.add),
                label: const Text('添加域名规则'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _editDefaultProxy(BuildContext context) async {
    final controller = TextEditingController(
      text: state.outboundProxy.defaultProxyUrl,
    );
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('默认代理地址'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'http://127.0.0.1:7890'),
          onSubmitted: (text) => Navigator.of(context).pop(text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null) return;
    await state.setOutboundProxy(
      state.outboundProxy.copyWith(defaultProxyUrl: value.trim()),
    );
  }

  Future<void> _addOutboundRule(BuildContext context) async {
    final patterns = TextEditingController();
    final url = TextEditingController();
    String? error;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('添加出站代理规则'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const ValueKey('outbound-rule-patterns'),
                controller: patterns,
                decoration: const InputDecoration(
                  labelText: '域名（逗号分隔）',
                  hintText: 'example.com, *.example.org',
                ),
              ),
              const SizedBox(height: AppSpace.sm),
              TextField(
                key: const ValueKey('outbound-rule-url'),
                controller: url,
                decoration: const InputDecoration(
                  labelText: '代理地址',
                  hintText: 'http://127.0.0.1:7890',
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: AppSpace.sm),
                Text(
                  error!,
                  key: const ValueKey('outbound-rule-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final list = [
                  for (final part in patterns.text.split(','))
                    if (part.trim().isNotEmpty) part.trim(),
                ];
                if (list.isEmpty || url.text.trim().isEmpty) {
                  setDialogState(() => error = '域名与代理地址都不能为空');
                  return;
                }
                final rule = OutboundProxyRule(
                  patterns: list,
                  proxyUrl: url.text.trim(),
                );
                if (!rule.isValid) {
                  setDialogState(() => error = '代理地址必须是 http://host:port');
                  return;
                }
                Navigator.of(context).pop(true);
              },
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
    final list = [
      for (final part in patterns.text.split(','))
        if (part.trim().isNotEmpty) part.trim(),
    ];
    final proxyUrl = url.text.trim();
    patterns.dispose();
    url.dispose();
    if (result != true || !context.mounted) return;
    await state.setOutboundProxy(
      state.outboundProxy.copyWith(
        rules: [
          ...state.outboundProxy.rules,
          OutboundProxyRule(patterns: list, proxyUrl: proxyUrl),
        ],
      ),
    );
  }

  Future<void> _removeOutboundRule(OutboundProxyRule rule) async {
    await state.setOutboundProxy(
      state.outboundProxy.copyWith(
        rules: [
          for (final item in state.outboundProxy.rules)
            if (item != rule) item,
        ],
      ),
    );
  }
}

/// 加密 DNS（DoH）明细页。
class DohSettingsPage extends StatelessWidget {
  const DohSettingsPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => SettingsDetailScaffold(
        title: '加密 DNS（DoH）',
        description: dohStatusText(state),
        children: [
          SwitchListTile(
            key: const ValueKey('settings-doh-enabled'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('启用 DoH 解析'),
            subtitle: const Text('只作用于站点/解析/字幕等出站请求；解析失败自动回落系统 DNS'),
            value: state.dohSettings.enabled,
            onChanged: (value) async {
              await state.setDohSettings(
                state.dohSettings.copyWith(enabled: value),
              );
            },
          ),
          ListTile(
            key: const ValueKey('settings-doh-endpoint'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('DoH 端点'),
            subtitle: Text(
              state.dohSettings.hasCustomUrl
                  ? redactDohUrl(state.dohSettings.url)
                  : '使用配置中的第一个有效服务商',
            ),
            onTap: () => _editDohEndpoint(context),
          ),
          ListTile(
            key: const ValueKey('settings-doh-cache'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('缓存时长'),
            subtitle: Text('${state.dohSettings.cacheMinutes} 分钟'),
            onTap: () async {
              final next = _nextDohCacheMinutes(state.dohSettings.cacheMinutes);
              await state.setDohSettings(
                state.dohSettings.copyWith(cacheMinutes: next),
              );
            },
          ),
        ],
      ),
    );
  }

  int _nextDohCacheMinutes(int current) {
    const options = [15, 60, 240, 1440];
    final index = options.indexOf(current);
    return index < 0 ? options[1] : options[(index + 1) % options.length];
  }

  Future<void> _editDohEndpoint(BuildContext context) async {
    final controller = TextEditingController(text: state.dohSettings.url);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('DoH 端点'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'https://dns.example.com/dns-query',
          ),
          onSubmitted: (text) => Navigator.of(context).pop(text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(''),
            child: const Text('清空'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null) return;
    final text = value.trim();
    if (text.isNotEmpty && !isUsableDohUrl(text)) {
      if (!context.mounted) return;
      showToast('DoH 端点必须是 https 地址', kind: ToastKind.error);
      return;
    }
    await state.setDohSettings(state.dohSettings.copyWith(url: text));
  }
}

class BrowserEnginePage extends StatelessWidget {
  const BrowserEnginePage({super.key, required this.paths});

  final AppPaths paths;

  @override
  Widget build(BuildContext context) => SettingsDetailScaffold(
    title: '浏览器内核',
    description: 'Web 嗅探使用本机 Chromium 内核；仅安装你选择的本地目录或 zip，不联网下载。',
    children: [BrowserComponentSettingsSection(paths: paths)],
  );
}
