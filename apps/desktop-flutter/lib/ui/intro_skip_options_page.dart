/// 跳过片段的独立设置页。
///
/// 这四项原本埋在「设置 → 播放 → 高级设置 → 播放参数」第三层的滚动区里，
/// 用户反馈两次「找不到片头片尾设置」——开关的**可见性**和开关本身一样重要，
/// 所以提成「播放」页的一级入口，与「播放器按钮排版」同级。
library;

import 'package:flutter/material.dart';

import '../core/player_options.dart';
import '../core/skip_plan.dart';
import '../core/skip_segment_colors.dart';
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

  Future<void> _editColor(BuildContext context, SkipKind kind) async {
    final color = await showDialog<int>(
      context: context,
      builder: (_) => _SkipColorDialog(
        kind: kind,
        initialColor: state.playerOptions.skipSegmentColors.colorFor(kind),
      ),
    );
    if (color == null) return;
    final current = state.playerOptions;
    await state.setPlayerOptions(
      current.copyWith(
        skipSegmentColors: current.skipSegmentColors.withColor(kind, color),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final options = state.playerOptions;
        return SettingsDetailScaffold(
          title: '跳过片段',
          description: '远端标定与手动标记共同决定跳哪一段；改动即时保存。',
          children: [
            SettingsSection(
              title: '自动跳过',
              children: [
                SwitchListTile(
                  key: const ValueKey('settings-player-skip-remote'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('远端识别可跳过片段'),
                  subtitle: const Text(
                    '从 IntroDB / TheIntroDB / TODB 获取时间轴；片段类型以远端标定为准',
                  ),
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
              title: '片段颜色',
              description: '用于进度条上的片段标记；颜色不影响跳过模式或类型。',
              children: [
                SwitchListTile(
                  key: const ValueKey('settings-player-skip-highlight'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('显示片段高亮'),
                  subtitle: const Text('仅显示或隐藏进度条颜色，不影响识别和自动跳过'),
                  value: options.showSkipSegmentHighlights,
                  onChanged: (value) => state.setPlayerOptions(
                    state.playerOptions.copyWith(
                      showSkipSegmentHighlights: value,
                    ),
                  ),
                ),
                for (final kind in SkipKind.values)
                  ListTile(
                    key: ValueKey('settings-player-skip-color-${kind.name}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: _colorSwatch(
                      context,
                      options.skipSegmentColors.colorFor(kind),
                      key: ValueKey(
                        'settings-player-skip-color-swatch-${kind.name}',
                      ),
                    ),
                    title: Text(kind.label),
                    subtitle: Text(
                      _colorHex(options.skipSegmentColors.colorFor(kind)),
                    ),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () => _editColor(context, kind),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const ValueKey('settings-player-skip-colors-reset'),
                    onPressed: () => state.setPlayerOptions(
                      state.playerOptions.copyWith(
                        skipSegmentColors: const SkipSegmentColors(),
                      ),
                    ),
                    child: const Text('恢复全部默认颜色'),
                  ),
                ),
              ],
            ),
            SettingsSection(
              title: '跳段预载',
              children: [
                SwitchListTile(
                  key: const ValueKey('settings-player-skip-prefetch'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('预载跳过落点'),
                  subtitle: const Text('提前下载落点后的分片，可能增加流量；仅支持点播 HLS。'),
                  value: options.skipPrefetch,
                  onChanged: (value) {
                    state.setPlayerOptions(
                      options.copyWith(skipPrefetch: value),
                    );
                    if (!value) state.cancelSkipPrefetch();
                  },
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

String _colorHex(int color) =>
    '#${(color & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

Container _colorSwatch(BuildContext context, int color, {Key? key}) =>
    Container(
      key: key,
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Color(color),
        border: Border.all(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );

class _SkipColorDialog extends StatefulWidget {
  const _SkipColorDialog({required this.kind, required this.initialColor});

  final SkipKind kind;
  final int initialColor;

  @override
  State<_SkipColorDialog> createState() => _SkipColorDialogState();
}

class _SkipColorDialogState extends State<_SkipColorDialog> {
  // Same preset colors as the existing subtitle palette.
  static const _presets = [
    (label: '白', value: 0xFFFFFFFF),
    (label: '黄', value: 0xFFFFEB3B),
    (label: '青', value: 0xFF18FFFF),
    (label: '绿', value: 0xFFB2FF59),
    (label: '橙', value: 0xFFFFAB40),
    (label: '粉', value: 0xFFFF4081),
  ];

  late final TextEditingController _controller = TextEditingController(
    text: _colorHex(widget.initialColor),
  );
  String? _error;

  int? get _draft {
    final text = _controller.text.trim();
    if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(text)) return null;
    return 0xFF000000 | int.parse(text.substring(1), radix: 16);
  }

  void _save() {
    final color = _draft;
    if (color == null) {
      setState(() => _error = '请输入 #RRGGBB 格式的颜色，例如 #38D9A9');
      return;
    }
    Navigator.of(context).pop(color);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('${widget.kind.label}颜色'),
    scrollable: true,
    content: SizedBox(
      width: 360,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final preset in _presets)
                ChoiceChip(
                  key: ValueKey(
                    'skip-color-preset-${preset.value.toRadixString(16).toUpperCase()}',
                  ),
                  avatar: _colorSwatch(context, preset.value),
                  label: Text(preset.label),
                  selected: _draft == preset.value,
                  showCheckmark: true,
                  checkmarkColor: Theme.of(context).colorScheme.onSurface,
                  onSelected: (_) => setState(() {
                    _controller.text = _colorHex(preset.value);
                    _error = null;
                  }),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('skip-color-input'),
            controller: _controller,
            decoration: InputDecoration(
              labelText: '自定义颜色',
              helperText: '#RRGGBB，例如 #38D9A9；不支持透明度',
              errorText: _error,
            ),
            onChanged: (_) => setState(() => _error = null),
            onSubmitted: (_) => _save(),
          ),
          if (_draft case final color?) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                _colorSwatch(context, color),
                const SizedBox(width: 8),
                Text('预览 ${_colorHex(color)}'),
              ],
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey('skip-color-save'),
        onPressed: _save,
        child: const Text('保存颜色'),
      ),
    ],
  );
}
