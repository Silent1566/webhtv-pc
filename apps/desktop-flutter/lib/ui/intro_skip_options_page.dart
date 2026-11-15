/// 片头/片尾跳过的独立设置页。
///
/// 这四项原本埋在「设置 → 播放 → 高级设置 → 播放参数」第三层的滚动区里，
/// 用户反馈两次「找不到片头片尾设置」——开关的**可见性**和开关本身一样重要，
/// 所以提成「播放」页的一级入口，与「播放器按钮排版」同级。
library;

import 'package:flutter/material.dart';

import '../core/player_options.dart';
import '../core/skip_plan.dart';
import '../state/app_state.dart';
import 'settings_layout.dart';

class IntroSkipOptionsPage extends StatelessWidget {
  const IntroSkipOptionsPage({super.key, required this.state});

  final AppState state;

  /// 数据源显示名（落盘标识见 [SkipSourceBits.ids]）。
  static const Map<String, String> _sourceLabels = <String, String>{
    'introdb': 'IntroDB',
    'theintrodb': 'TheIntroDB',
    'todb': 'TODB',
  };

  static String _modeLabel(SkipMode mode) => switch (mode) {
    SkipMode.off => '关闭',
    SkipMode.auto => '自动跳过',
    SkipMode.confirm => '先询问',
  };

  /// 模式的一句话解释。
  ///
  /// 关闭模式**不是**「什么都不做」：远端标定照常查询，供播放器右键菜单手动跳过，
  /// 只是不自动 seek。写成「不查询远端」会误导用户以为关了就没有数据。
  static String _modeHint(SkipMode mode) => switch (mode) {
    SkipMode.off => '不自动跳段；远端标定仍会查询，供播放器菜单手动跳过',
    SkipMode.auto => '命中片段后直接跳到段末',
    SkipMode.confirm => '命中后先弹确认框，点确定才跳',
  };

  /// 入口行的状态摘要（「播放」页那一行用）。
  static String summary(PlayerOptions options) {
    final mode = switch (options.skipMode) {
      SkipMode.off => '关',
      SkipMode.auto => '自动',
      SkipMode.confirm => '先问',
    };
    final kinds = SkipKind.values
        .where((kind) => (options.skipKinds & kind.bit) != 0)
        .map((kind) => kind.label)
        .join('/');
    return '模式 $mode · ${kinds.isEmpty ? '未选类型' : kinds}';
  }

  static int _toggleBit(int mask, int bit, bool on) =>
      on ? (mask | bit) : (mask & ~bit);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final options = state.playerOptions;
        return SettingsDetailScaffold(
          title: '片头片尾跳过',
          description: '远端标定与手动标记共同决定跳哪一段；改动即时保存。',
          children: [
            SettingsSection(
              title: '自动跳过',
              children: [
                SwitchListTile(
                  key: const ValueKey('settings-player-skip-remote'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('远端识别片头片尾'),
                  subtitle: const Text('从 IntroDB / TheIntroDB / TODB 自动获取时间轴'),
                  value: options.skipRemoteEnabled,
                  onChanged: (value) async {
                    await state.setPlayerOptions(
                      options.copyWith(skipRemoteEnabled: value),
                    );
                  },
                ),
                ListTile(
                  key: const ValueKey('settings-player-skip-mode'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('跳过模式'),
                  subtitle: Text(_modeHint(options.skipMode)),
                  trailing: DropdownButton<SkipMode>(
                    value: options.skipMode,
                    underline: const SizedBox.shrink(),
                    items: [
                      for (final mode in SkipMode.values)
                        DropdownMenuItem(
                          value: mode,
                          child: Text(_modeLabel(mode)),
                        ),
                    ],
                    onChanged: (mode) async {
                      if (mode == null) return;
                      await state.setPlayerOptions(
                        options.copyWith(skipMode: mode),
                      );
                    },
                  ),
                ),
              ],
            ),
            SettingsSection(
              title: '跳过哪些片段',
              children: [
                Column(
                  key: const ValueKey('settings-player-skip-kinds'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final kind in SkipKind.values)
                      CheckboxListTile(
                        key: ValueKey('settings-player-skip-kind-${kind.name}'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(kind.label),
                        value: (options.skipKinds & kind.bit) != 0,
                        onChanged: (value) async {
                          if (value == null) return;
                          await state.setPlayerOptions(
                            options.copyWith(
                              skipKinds: _toggleBit(
                                options.skipKinds,
                                kind.bit,
                                value,
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ],
            ),
            SettingsSection(
              title: '数据源',
              children: [
                Column(
                  key: const ValueKey('settings-player-skip-sources'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final id in SkipSourceBits.ids)
                      CheckboxListTile(
                        key: ValueKey('settings-player-skip-source-$id'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(_sourceLabels[id] ?? id),
                        value: SkipSourceBits.enabled(options.skipSources, id),
                        onChanged: (value) async {
                          if (value == null) return;
                          await state.setPlayerOptions(
                            options.copyWith(
                              skipSources: _toggleBit(
                                options.skipSources,
                                SkipSourceBits.bitOf(id),
                                value,
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
