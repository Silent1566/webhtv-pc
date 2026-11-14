/// 高级设置中枢：按用途分组，控件在独立明细页即时保存。
library;

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'advanced_detail_pages.dart';
import 'ai_integration_widgets.dart';
import 'backup_page.dart';
import 'common.dart';
import 'injected_sites_page.dart';
import 'local_sources_page.dart';
import 'pan_check_page.dart';
import 'settings_layout.dart';
import 'subtitle_settings_page.dart';
import 'tokens.dart';

class AdvancedSettingsPage extends StatelessWidget {
  const AdvancedSettingsPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('高级设置')),
      // 为什么在这里再监听一次 AppState：本页由 `Navigator.push` 打开，是独立路由；
      // `AppShell` 的监听管不到它，`MaterialApp.builder` 那层 `ListenableBuilder`
      // 把 `child`（Navigator）原样透传，Flutter 对同一实例会跳过子树重建。
      // 不包这一层，`SwitchListTile.value` 拿到的是进页那一刻的旧快照，拨动后
      // 父级不重建 → 受控开关视觉回弹（整页所有开关同一根因）。
      // 只包 body：`AppBar` 不进监听，避免重建导致滚动位置/焦点抖动。
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) => ListView(
          padding: formPagePadding(context),
          children: [
            Text(
              '按用途分组；每行进入明细页，开关即时生效。',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            SettingsSection(
              title: '播放与观看',
              description: '直播换源、播放参数与播放期的弹幕、字幕来源。',
              children: [
                SettingsRowList(
                  children: [
                    SwitchListTile(
                      key: const ValueKey('settings-live-source-fallback'),
                      // ListTile 的 leading 槽位比自绘行多 4px：用 8 而不是 12，标题列才与行对齐。
                      horizontalTitleGap: AppSpace.sm,
                      secondary: const SizedBox(
                        width: 20,
                        child: Icon(Icons.swap_horiz, size: 20),
                      ),
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '直播源失败时自动换源',
                        style: theme.textTheme.bodyLarge,
                      ),
                      subtitle: Text(
                        '当前源所有线路都失败后，尝试其他源的同名频道',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      value: state.liveSettings.sourceFallback,
                      onChanged: (value) async {
                        await state.setLiveSettings(
                          state.liveSettings.copyWith(sourceFallback: value),
                        );
                      },
                    ),
                    SwitchListTile(
                      key: const ValueKey('settings-live-change-line'),
                      // ListTile 的 leading 槽位比自绘行多 4px：用 8 而不是 12，标题列才与行对齐。
                      horizontalTitleGap: AppSpace.sm,
                      secondary: const SizedBox(
                        width: 20,
                        child: Icon(Icons.alt_route, size: 20),
                      ),
                      contentPadding: EdgeInsets.zero,
                      title: Text('线路失败自动换线', style: theme.textTheme.bodyLarge),
                      subtitle: Text(
                        '关闭后单条线路失败直接报错，不再尝试同频道其他线路',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      value: state.liveSettings.changeLine,
                      onChanged: (value) async {
                        await state.setLiveSettings(
                          state.liveSettings.copyWith(changeLine: value),
                        );
                      },
                    ),
                    SettingsNavRow(
                      key: const ValueKey('settings-player-options-open'),
                      icon: Icons.tune,
                      title: '播放参数',
                      subtitle:
                          '硬件解码 ${_onOff(state.playerOptions.hardwareDecoding)}'
                          ' · 自动连播 ${_onOff(state.playerOptions.autoNext)}'
                          ' · 缓存 ${state.playerOptions.demuxerMaxBytesMiB} MiB',
                      onTap: () =>
                          _push(context, PlaybackOptionsPage(state: state)),
                    ),
                    SettingsNavRow(
                      key: const ValueKey('settings-danmaku-open'),
                      icon: Icons.comment_outlined,
                      title: '弹幕源',
                      subtitle:
                          '${state.danmakuSettings.autoSearch ? "自动搜索已开" : "自动搜索已关"}'
                          ' · ${state.danmakuSettings.apiUrl.isEmpty ? "未配置地址" : "已配置地址"}',
                      onTap: () =>
                          _push(context, DanmakuSourcePage(state: state)),
                    ),
                    SettingsNavRow(
                      key: const ValueKey('settings-subtitle-open'),
                      icon: Icons.subtitles_outlined,
                      title: '字幕源',
                      subtitle: state.subtitleSettings.hasAnyProvider
                          ? '已配置${state.subtitleSettings.autoMatch ? " · 自动匹配已开" : ""}'
                          : '未配置：播放结果没有字幕时不会自动匹配',
                      subtitleKey: const ValueKey('settings-subtitle-summary'),
                      onTap: () => _push(
                        context,
                        SubtitleSettingsPage(state: state, paths: state.paths),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            SettingsSection(
              title: '站点与搜索',
              description: '解析顺序、分组规则与站点注入；广告规则同样作用于站点请求链。',
              children: [
                SettingsRowList(
                  children: [
                    SwitchListTile(
                      key: const ValueKey('settings-parse-failover'),
                      // ListTile 的 leading 槽位比自绘行多 4px：用 8 而不是 12，标题列才与行对齐。
                      horizontalTitleGap: AppSpace.sm,
                      secondary: const SizedBox(
                        width: 20,
                        child: Icon(Icons.swap_calls, size: 20),
                      ),
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '解析接口失败时尝试其他接口',
                        style: theme.textTheme.bodyLarge,
                      ),
                      subtitle: Text(
                        '按配置顺序最多再试一个；只尝试 JSON 类接口',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      value: state.parseFailoverSettings.enabled,
                      onChanged: (value) async {
                        await state.setParseFailoverSettings(
                          state.parseFailoverSettings.copyWith(enabled: value),
                        );
                      },
                    ),
                    SwitchListTile(
                      key: const ValueKey('settings-site-health-sort'),
                      // ListTile 的 leading 槽位比自绘行多 4px：用 8 而不是 12，标题列才与行对齐。
                      horizontalTitleGap: AppSpace.sm,
                      secondary: const SizedBox(
                        width: 20,
                        child: Icon(Icons.sort, size: 20),
                      ),
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '按站点健康排序搜索结果',
                        style: theme.textTheme.bodyLarge,
                      ),
                      subtitle: Text(
                        '成功的站点优先；没有实测记录的站点排在最后',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      value: state.siteOrder.healthSort,
                      onChanged: (value) async {
                        await state.setSiteOrder(
                          state.siteOrder.copyWith(healthSort: value),
                        );
                      },
                    ),
                    SettingsNavRow(
                      key: const ValueKey('settings-group-rules-open'),
                      icon: Icons.account_tree_outlined,
                      title: '分组规则',
                      subtitle:
                          '${state.siteGroupSettings.rules.length} 条规则'
                          ' · ${state.siteGroupSettings.rules.where((e) => e.enabled).length} 条启用',
                      onTap: () =>
                          _push(context, SiteGroupRulesPage(state: state)),
                    ),
                    SettingsNavRow(
                      key: const ValueKey('settings-injected-sites-open'),
                      icon: Icons.code_outlined,
                      title: '站点注入',
                      subtitle: state.injectedSites.isEmpty
                          ? '未注入站点：可粘贴站点 JSON 追加到站点列表'
                          : '已注入 ${state.injectedSites.length} 个站点'
                                '（启用 ${state.injectedSites.where((e) => e.enabled).length}）',
                      subtitleKey: const ValueKey(
                        'settings-injected-sites-summary',
                      ),
                      onTap: () =>
                          _push(context, InjectedSitesPage(state: state)),
                    ),
                    SettingsNavRow(
                      key: const ValueKey('settings-local-sources-open'),
                      icon: Icons.folder_open_outlined,
                      title: '本地源',
                      subtitle: '扫描本机媒体目录，按文件名匹配剧集',
                      onTap: () =>
                          _push(context, LocalSourcesPage(state: state)),
                    ),
                    SwitchListTile(
                      key: const ValueKey('settings-ad-block'),
                      // ListTile 的 leading 槽位比自绘行多 4px：用 8 而不是 12，标题列才与行对齐。
                      horizontalTitleGap: AppSpace.sm,
                      secondary: const SizedBox(
                        width: 20,
                        child: Icon(Icons.block, size: 20),
                      ),
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '启用配置中的广告规则',
                        style: theme.textTheme.bodyLarge,
                      ),
                      subtitle: Text(
                        '${state.config?.ads.length ?? 0} 个广告主机 · '
                        '${state.config?.hlsRules.length ?? 0} 条 HLS 规则；'
                        '规则为空时无效果',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      value: state.adBlockEnabled,
                      onChanged: (value) async {
                        await state.setAdBlockEnabled(value);
                      },
                    ),
                  ],
                ),
              ],
            ),
            SettingsSection(
              title: '网络',
              description: '出站请求的代理与 DNS 解析；不影响本地播放代理。',
              children: [
                SettingsRowList(
                  children: [
                    SettingsNavRow(
                      key: const ValueKey('settings-outbound-proxy-open'),
                      icon: Icons.hub_outlined,
                      title: '出站代理',
                      subtitle: _outboundProxySummary(),
                      onTap: () =>
                          _push(context, OutboundProxyPage(state: state)),
                    ),
                    SettingsNavRow(
                      key: const ValueKey('settings-doh-open'),
                      icon: Icons.dns_outlined,
                      title: '加密 DNS（DoH）',
                      subtitle: dohStatusText(state),
                      onTap: () =>
                          _push(context, DohSettingsPage(state: state)),
                    ),
                  ],
                ),
              ],
            ),
            SettingsSection(
              title: '工具',
              description: '独立的检查与维护入口，不在这里做任何后台自动调用。',
              children: [
                SettingsRowList(
                  children: [
                    SettingsNavRow(
                      key: const ValueKey('settings-pan-check-open'),
                      icon: Icons.link_outlined,
                      title: '网盘检测',
                      subtitle: '粘贴分享链接检测有效性',
                      onTap: () => _push(context, PanCheckPage(state: state)),
                    ),
                    SettingsNavRow(
                      key: const ValueKey('settings-ai-assist-open'),
                      icon: Icons.auto_awesome,
                      title: 'AI 辅助',
                      subtitle: state.aiReady
                          ? '已启用（协议 ${state.aiConfig.protocol}）：标题清洗 / 日志诊断 / 分组建议 / 广告分片判定'
                          : '未配置：这些能力不会发起任何请求',
                      subtitleKey: const ValueKey('settings-ai-assist-summary'),
                      onTap: () => _push(context, AiBusinessPage(state: state)),
                    ),
                    SettingsNavRow(
                      key: const ValueKey('settings-backup-open'),
                      icon: Icons.settings_backup_restore,
                      title: '备份与恢复',
                      subtitle: '导出设置与数据库，或从备份恢复',
                      onTap: () => _push(context, BackupPage(state: state)),
                    ),
                    SettingsNavRow(
                      key: const ValueKey('settings-browser-open'),
                      icon: Icons.web_asset_outlined,
                      title: '浏览器内核',
                      subtitle: 'Web 嗅探使用本机 Chromium 内核',
                      onTap: () =>
                          _push(context, BrowserEnginePage(paths: state.paths)),
                    ),
                  ],
                ),
              ],
            ),
            SettingsSection(
              title: '隐私与诊断',
              description: '本机记录与排查开关。',
              children: [
                SettingsRowList(
                  children: [
                    SwitchListTile(
                      key: const ValueKey('settings-incognito'),
                      // ListTile 的 leading 槽位比自绘行多 4px：用 8 而不是 12，标题列才与行对齐。
                      horizontalTitleGap: AppSpace.sm,
                      secondary: const Icon(
                        Icons.visibility_off_outlined,
                        size: 20,
                      ),
                      contentPadding: EdgeInsets.zero,
                      title: Text('隐身模式', style: theme.textTheme.bodyLarge),
                      subtitle: Text(
                        '不写播放历史与搜索记录；季度进度等历史投影同样不写',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      value: state.incognito,
                      onChanged: (value) async {
                        await state.setIncognito(value);
                      },
                    ),
                    SwitchListTile(
                      key: const ValueKey('settings-spider-debug-log'),
                      // ListTile 的 leading 槽位比自绘行多 4px：用 8 而不是 12，标题列才与行对齐。
                      horizontalTitleGap: AppSpace.sm,
                      secondary: const Icon(
                        Icons.bug_report_outlined,
                        size: 20,
                      ),
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '详细调试日志（爬虫入参/出参）',
                        style: theme.textTheme.bodyLarge,
                      ),
                      subtitle: Text(
                        '记录每次爬虫 IPC 调用的完整请求参数与响应结果（落盘前脱敏），'
                        '单份日志上限放大到 20MB。切换即时生效；日志量很大，排查完请关掉',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      value: state.spiderDebugLog,
                      onChanged: (value) async {
                        await state.setSpiderDebugLog(value);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _onOff(bool value) => value ? '开' : '关';

  String _outboundProxySummary() {
    final proxy = state.outboundProxy;
    if (!proxy.enabled) return '未启用';
    return proxy.isEffective
        ? '${proxy.validRules.length} 条规则'
        : '未生效（没有规则或地址不合法）';
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }
}
