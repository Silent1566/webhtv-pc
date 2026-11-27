/// 去广告二级页（设置 → 内容与站点 → 去广告）。
///
/// 这一页只做**开关与入口**：总开关、启发式兜底开关、规则库、统计与日志。
/// 规则编辑与统计明细各自在自己的页里——一行一件事，与设置页的分类纪律一致。
library;

import 'package:flutter/material.dart';

import '../core/ad_rule_library.dart';
import '../state/app_state.dart';
import 'ad_block_stats_page.dart';
import 'ad_rule_library_page.dart';
import 'settings_layout.dart';
import 'tokens.dart';

class AdBlockPage extends StatelessWidget {
  const AdBlockPage({super.key, required this.state});

  final AppState state;

  /// 独立路由必须自己听 AppState。
  ///
  /// 设置分类页由宿主在 `notifyListeners` 后重建，但 push 出来的这一页不在宿主
  /// 的子树里——不自己听，开关就永远停在进页那一刻的旧快照上（用户看到的是
  /// 「点了没反应」）。仓库里 `settings_overview_page_test` 有同一条先例。
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final theme = Theme.of(context);
    final library = state.adRuleLibrary;
    final enabledCount = library.entries.where((entry) => entry.enabled).length;
    final configHosts = state.config?.ads.length ?? 0;
    final configRules = state.config?.hlsRules.length ?? 0;
    final summary = state.adBlockSummary;

    return SettingsDetailScaffold(
      title: '去广告',
      description:
          '播放时由本地代理读取 HLS 清单，删掉命中规则的广告分片。'
          '规则只来自你自己的配置与本地规则库，不下载任何广告清单。',
      children: [
        SettingsSection(
          title: '开关',
          children: [
            SettingsRowList(
              children: [
                _switch(
                  context,
                  key: const ValueKey('ad-block-enabled'),
                  icon: Icons.block,
                  title: '启用广告过滤',
                  subtitle: state.adBlockEnabled
                      ? '关闭时配置规则与规则库都不生效'
                      : '已关闭：清单原样转发，代理不删除任何分片',
                  value: state.adBlockEnabled,
                  onChanged: state.setAdBlockEnabled,
                ),
                _switch(
                  context,
                  key: const ValueKey('ad-block-heuristic'),
                  icon: Icons.auto_fix_high_outlined,
                  title: '规则没命中时使用启发式清洗',
                  subtitle:
                      '默认关闭。启发式按少数派地址、短分组、广告标记推断，'
                      '可能误删正片；只在规则一条都没命中时兜底。',
                  value: state.adBlockHeuristicEnabled,
                  onChanged: state.setAdBlockHeuristicEnabled,
                ),
              ],
            ),
          ],
        ),
        SettingsSection(
          title: '规则',
          description: '清单里的 ads 与 hlsRules 仍然生效；规则库用来放你自己维护的规则集。',
          children: [
            SettingsRowList(
              children: [
                SettingsNavRow(
                  key: const ValueKey('ad-block-rule-library-open'),
                  icon: Icons.rule_folder_outlined,
                  title: '本地规则库',
                  subtitleKey: const ValueKey('ad-block-rule-library-summary'),
                  subtitle:
                      '$configHosts 个配置广告主机 · $configRules 条配置 HLS 规则 · '
                      '规则库 ${library.entries.length} 组（$enabledCount 组启用）',
                  onTap: () => _openRuleLibrary(context, library),
                ),
                if (library.loadError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpace.sm),
                    child: Text(
                      '规则库读取失败：${library.loadError}（已按空库打开，'
                      '保存前请先确认原文件）',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
        SettingsSection(
          title: '拦截',
          description: '统计只记「删掉的广告分片」，安全回退的请求不记账。',
          children: [
            SettingsRowList(
              children: [
                SettingsNavRow(
                  key: const ValueKey('ad-block-stats-open'),
                  icon: Icons.query_stats_outlined,
                  title: '拦截统计与日志',
                  subtitle: summary == null
                      ? '本次播放还没有拦截记录'
                      : '本次已拦 ${summary.removedSegments} 段 · '
                            '${summary.removedDurationSec.toStringAsFixed(1)} 秒'
                            '${summary.heuristic ? " · 启发式" : ""}',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          AdBlockStatsPage(service: state.adBlockStats),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  /// 规则库是纯存储而不是 `ChangeNotifier`：返回本页后统一重解析一次生效规则。
  Future<void> _openRuleLibrary(
    BuildContext context,
    AdRuleLibraryStore library,
  ) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AdRuleLibraryPage(
          store: library,
          effectiveRules: (entries) => resolveEffectiveRules(
            config: state.config,
            library: entries,
            adBlockEnabled: state.adBlockEnabled,
          ),
        ),
      ),
    );
    state.adRulesChanged();
  }

  /// 与设置页同一个开关行形态：leading 槽位 20、标题 bodyLarge、零内边距。
  Widget _switch(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final theme = Theme.of(context);
    return SwitchListTile(
      key: key,
      horizontalTitleGap: AppSpace.sm,
      secondary: SizedBox(width: 20, child: Icon(icon, size: 20)),
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: theme.textTheme.bodyLarge),
      subtitle: Text(
        subtitle,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      value: value,
      onChanged: onChanged,
    );
  }
}
