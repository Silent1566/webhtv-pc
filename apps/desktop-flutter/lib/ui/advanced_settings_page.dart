/// 高级设置页（Phase 9 的直播/广告/弹幕/字幕/播放参数/站点注入）。
///
/// 为什么独立成页：设置页是长表单，既有测试用固定视口且不带 `ensureVisible`
/// （`docs/phase8/design/05` §5）。把 Phase 9 的区块继续堆在设置页里，会把
/// `settings-osd` / `settings-player-buttons` 挤出视口。收进独立页后设置页
/// 长度回到 Phase 8 的水平，新增能力也不再挤占既有入口。
library;

import 'package:flutter/material.dart';

import '../core/doh.dart';
import '../core/doh_settings.dart';
import '../core/outbound_proxy.dart';
import '../core/player_options.dart';
import '../core/site_group_rules.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'ai_assist_page.dart';
import 'backup_page.dart';
import 'injected_sites_page.dart';
import 'pan_check_page.dart';
import 'subtitle_settings_page.dart';
import 'toast.dart';

class AdvancedSettingsPage extends StatelessWidget {
  const AdvancedSettingsPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('高级设置')),
      body: ListView(
        padding: formPagePadding(context),
        children: [
          // ---------------------------------------------------------- 直播
          Text('直播', style: theme.textTheme.titleMedium),
          SwitchListTile(
            key: const ValueKey('settings-live-source-fallback'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('直播源失败时自动换源'),
            subtitle: const Text('当前源所有线路都失败后，尝试其他源的同名频道'),
            value: state.liveSettings.sourceFallback,
            onChanged: (value) async {
              await state.setLiveSettings(
                state.liveSettings.copyWith(sourceFallback: value),
              );
            },
          ),
          SwitchListTile(
            key: const ValueKey('settings-live-change-line'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('线路失败自动换线'),
            subtitle: const Text('关闭后单条线路失败直接报错，不再尝试同频道其他线路'),
            value: state.liveSettings.changeLine,
            onChanged: (value) async {
              await state.setLiveSettings(
                state.liveSettings.copyWith(changeLine: value),
              );
            },
          ),
          const Divider(height: 32),
          // ---------------------------------------------------------- 广告
          Text('广告过滤', style: theme.textTheme.titleMedium),
          SwitchListTile(
            key: const ValueKey('settings-ad-block'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('启用配置中的广告规则'),
            subtitle: Text(
              '${state.config?.ads.length ?? 0} 个广告主机 · '
              '${state.config?.hlsRules.length ?? 0} 条 HLS 规则；'
              '规则为空时无效果',
            ),
            value: state.adBlockEnabled,
            onChanged: (value) async {
              await state.setAdBlockEnabled(value);
            },
          ),
          const Divider(height: 32),
          // ------------------------------------------------------ 网盘检测
          Text('网盘检测', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            '粘贴分享链接检测有效性（有效 / 失效 / 需要提取码 / 无法判定）。',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            key: const ValueKey('settings-pan-check-open'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => PanCheckPage(state: state),
              ),
            ),
            icon: const Icon(Icons.link_outlined),
            label: const Text('打开网盘检测'),
          ),
          const Divider(height: 32),
          // ------------------------------------------------------ 出站代理
          Text('出站代理', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            '按域名把请求转发到 HTTP 代理（如 127.0.0.1:7890）。'
            '只影响站点/解析/字幕等出站请求，不影响本地播放代理。',
            style: TextStyle(fontSize: 12),
          ),
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
          for (final rule in state.outboundProxy.rules)
            ListTile(
              key: ValueKey('settings-outbound-proxy-rule-${rule.proxyUrl}'),
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
          OutlinedButton.icon(
            key: const ValueKey('settings-outbound-proxy-add'),
            onPressed: () => _addOutboundRule(context),
            icon: const Icon(Icons.add),
            label: const Text('添加域名规则'),
          ),
          const Divider(height: 32),
          // ------------------------------------------------------ 分组规则
          Text('分组规则', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            '从站点名抽取分组标记（如「木偶[盘]」→「盘」）。内置规则可单独关闭；'
            '自定义规则须含一个捕获组。',
            style: TextStyle(fontSize: 12),
          ),
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
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const ValueKey('settings-group-rule-add'),
            onPressed: () => _addGroupRule(context),
            icon: const Icon(Icons.add),
            label: const Text('添加自定义规则'),
          ),
          const Divider(height: 32),
          // -------------------------------------------------------- 解析
          Text('解析与搜索', style: theme.textTheme.titleMedium),
          SwitchListTile(
            key: const ValueKey('settings-parse-failover'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('解析接口失败时尝试其他接口'),
            subtitle: const Text('按配置顺序最多再试一个；只尝试 JSON 类接口'),
            value: state.parseFailoverSettings.enabled,
            onChanged: (value) async {
              await state.setParseFailoverSettings(
                state.parseFailoverSettings.copyWith(enabled: value),
              );
            },
          ),
          SwitchListTile(
            key: const ValueKey('settings-site-health-sort'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('按站点健康排序搜索结果'),
            subtitle: const Text('成功的站点优先；没有实测记录的站点排在最后'),
            value: state.siteOrder.healthSort,
            onChanged: (value) async {
              await state.setSiteOrder(
                state.siteOrder.copyWith(healthSort: value),
              );
            },
          ),
          const Divider(height: 32),
          // --------------------------------------------------------- AI 辅助
          Text('AI 辅助', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            state.aiReady
                ? '已启用（协议 ${state.aiConfig.protocol}）：标题清洗 / 日志诊断 / 分组建议 / 广告分片判定'
                : '未配置：这些能力不会发起任何请求',
            key: const ValueKey('settings-ai-assist-summary'),
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            key: const ValueKey('settings-ai-assist-open'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => AiAssistPage(state: state),
              ),
            ),
            icon: const Icon(Icons.auto_awesome),
            label: const Text('打开 AI 辅助'),
          ),
          const Divider(height: 32),
          // -------------------------------------------------------- 弹幕源
          Text('弹幕源', style: theme.textTheme.titleMedium),
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
          const Divider(height: 32),
          // -------------------------------------------------------- 字幕源
          Text('字幕源', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            state.subtitleSettings.hasAnyProvider
                ? '已配置${state.subtitleSettings.autoMatch ? " · 自动匹配已开" : ""}'
                : '未配置：播放结果没有字幕时不会自动匹配',
            key: const ValueKey('settings-subtitle-summary'),
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            key: const ValueKey('settings-subtitle-open'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SubtitleSettingsPage(
                  state: state,
                  paths: state.paths,
                ),
              ),
            ),
            icon: const Icon(Icons.subtitles_outlined),
            label: const Text('打开字幕源设置'),
          ),
          const Divider(height: 32),
          // -------------------------------------------------------- 站点注入
          Text('站点注入', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            state.injectedSites.isEmpty
                ? '未注入站点：可粘贴站点 JSON 追加到站点列表'
                : '已注入 ${state.injectedSites.length} 个站点'
                      '（启用 ${state.injectedSites.where((e) => e.enabled).length}）',
            key: const ValueKey('settings-injected-sites-summary'),
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            key: const ValueKey('settings-injected-sites-open'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => InjectedSitesPage(state: state),
              ),
            ),
            icon: const Icon(Icons.extension_outlined),
            label: const Text('管理注入站点'),
          ),
          const Divider(height: 32),
          // ------------------------------------------------------ 播放参数
          Text('播放参数', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
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
                      DropdownMenuItem(value: mode, child: Text(mode.label)),
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
          const SizedBox(height: 8),
          Text(
            '缓存上限：${state.playerOptions.demuxerMaxBytesMiB} MiB'
            '（前向）+ ${state.playerOptions.demuxerMaxBackBytesMiB} MiB（回看）',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
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
                  demuxerMaxBackBytesMiB: (selection.first ~/ 4).clamp(8, 512),
                ),
              );
            },
          ),
          const Divider(height: 32),
          // ------------------------------------------------------ 备份与恢复
          Text('备份与恢复', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            '导出设置与数据库（配置记录/历史/收藏），或从备份恢复、重置本地数据。',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            key: const ValueKey('settings-backup-open'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => BackupPage(state: state),
              ),
            ),
            icon: const Icon(Icons.settings_backup_restore),
            label: const Text('打开备份与恢复'),
          ),
          const Divider(height: 32),
          // ---------------------------------------------------------- 隐私
          Text('隐私', style: theme.textTheme.titleMedium),
          SwitchListTile(
            key: const ValueKey('settings-incognito'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('隐身模式'),
            subtitle: const Text('不写播放历史与搜索记录；季度进度等历史投影同样不写'),
            value: state.incognito,
            onChanged: (value) async {
              await state.setIncognito(value);
            },
          ),
          const Divider(height: 32),
          // ---------------------------------------------------------- DoH
          Text('加密 DNS（DoH）', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            _dohStatusText(),
            style: const TextStyle(fontSize: 12),
          ),
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

  String _dohStatusText() {
    final endpoints = DohEndpoint.parseList(state.config?.doh);
    final hosts = DohHostMap.parse(state.config?.hosts);
    final buffer = StringBuffer('配置提供 ${endpoints.length} 个 DoH 服务商');
    if (endpoints.isNotEmpty) {
      buffer.write('（${endpoints.map((e) => e.name.isEmpty ? redactDohUrl(e.url) : e.name).join("、")}）');
    }
    buffer.write('、${hosts.entries.length} 条 hosts 静态映射');
    if (endpoints.isEmpty && hosts.isEmpty && !state.dohSettings.hasCustomUrl) {
      buffer.write('；两者都为空时 DoH 不生效，可在这里填自定义端点');
    }
    return buffer.toString();
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
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('outbound-rule-url'),
                controller: url,
                decoration: const InputDecoration(
                  labelText: '代理地址',
                  hintText: 'http://127.0.0.1:7890',
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
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
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('group-rule-pattern'),
                controller: patternController,
                decoration: const InputDecoration(
                  labelText: '正则（含一个捕获组）',
                  hintText: r'\[([^\]]+)\]',
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
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
