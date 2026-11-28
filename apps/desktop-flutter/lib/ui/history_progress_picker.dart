/// 「选择续播记录」弹框：同一部剧在本站与其它爬虫源都有进度时，让用户自己选。
///
/// 用户 2026-11-29 的选型：进度**都标记、展示有差异**，真正续播时由用户选择，
/// 而不是替他把某一条记录当成唯一真相。入口只有「续播」这一处（首屏按钮与
/// 已标进度的选集卡片），浏览详情本身不弹框。
///
/// 为什么把选项做成 [HistoryProgressChoice] 而不是直接收 `PlaybackHistory`：
/// 详情页要的是「选完之后播哪条线路的哪一集、用哪个迁移种子」，这些身份在
/// 映射阶段（`core/history_cross_site.dart`）已经算好；弹框只负责展示与选择，
/// 不重新推导一遍身份——两处各算一次必然漂移。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/history_cross_site.dart';
import '../core/history_view.dart';
import 'glass_dialog.dart';
import 'tokens.dart';

/// 一条可续播记录：展示信息 + 播放所需身份。
class HistoryProgressChoice {
  const HistoryProgressChoice({
    required this.sourceLabel,
    required this.isOwnSite,
    required this.lineFlag,
    required this.episodeIndex,
    required this.episodeName,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAt,
    this.seed,
  });

  /// 来源站点的展示名；本站为「本站」。
  final String sourceLabel;

  /// 是否属于当前页面所在的站点（决定标注配色与「本站」文案）。
  final bool isOwnSite;

  /// 目标线路的页面内 flag。
  final String lineFlag;

  /// 目标线路 `episodes` 里的原始下标。
  final int episodeIndex;

  final String episodeName;
  final int positionMs;
  final int durationMs;
  final int updatedAt;

  /// 跨站点续播的迁移种子（本站记录为 null：走既有的精确查询）。
  final ResumeSeed? seed;

  /// 0..100；时长未知时为 0。
  int get progressPercent {
    if (durationMs <= 0) return 0;
    return ((positionMs / durationMs) * 100).round().clamp(0, 100);
  }
}

/// 弹出选择框；用户取消时返回 `null`（**不**替用户选默认那条）。
///
/// [choices] 由调用方按「最近观看倒序」排好：本层不再排序，避免与详情页的
/// 默认目标（最近可续播）出现两套顺序。[nowMs] 只用于相对时间文案，测试可注入。
Future<HistoryProgressChoice?> showHistoryProgressPicker(
  BuildContext context, {
  required List<HistoryProgressChoice> choices,
  int? nowMs,
}) {
  if (choices.isEmpty) return Future.value();
  return showGlassDialog<HistoryProgressChoice>(
    context: context,
    builder: (_) => _HistoryProgressPickerDialog(
      choices: choices,
      nowMs: nowMs ?? DateTime.now().millisecondsSinceEpoch,
    ),
  );
}

class _HistoryProgressPickerDialog extends StatefulWidget {
  const _HistoryProgressPickerDialog({
    required this.choices,
    required this.nowMs,
  });

  final List<HistoryProgressChoice> choices;
  final int nowMs;

  @override
  State<_HistoryProgressPickerDialog> createState() =>
      _HistoryProgressPickerDialogState();
}

class _HistoryProgressPickerDialogState
    extends State<_HistoryProgressPickerDialog> {
  int _selected = 0;

  void _select(int index) {
    setState(() => _selected = index.clamp(0, widget.choices.length - 1));
  }

  void _confirm() => Navigator.of(context).pop(widget.choices[_selected]);

  void _cancel() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const panelKey = ValueKey('history-progress-dialog');
    final title = const Text('选择续播记录');
    final content = SizedBox(
      width: 560,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .55,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('同一部剧有多条可续播记录，选一条继续：', style: theme.textTheme.bodySmall),
              const SizedBox(height: 12),
              for (var i = 0; i < widget.choices.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _optionTile(context, i, widget.choices[i]),
                ),
            ],
          ),
        ),
      ),
    );
    final actions = <Widget>[
      TextButton(
        key: const ValueKey('history-progress-cancel'),
        onPressed: _cancel,
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey('history-progress-confirm'),
        onPressed: _confirm,
        child: const Text('播放'),
      ),
    ];
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _cancel,
        const SingleActivator(LogicalKeyboardKey.enter): _confirm,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): _confirm,
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _select(_selected + 1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _select(_selected - 1),
      },
      child: Focus(
        autofocus: true,
        // 明暗都是玻璃面板（材质 = AppGlass，按亮度分档）。
        // 面板的 key 不变，测试仍然按键找得到；面板外的遮罩按亮度分档，
        // 暗色仍是 Material 默认的 black54，所以面板外像素不变。
        child: GlassAlertDialog(
          constraints: const BoxConstraints(maxWidth: 560 + 2 * AppSpace.xl),
          key: panelKey,
          title: title,
          content: content,
          actions: actions,
        ),
      ),
    );
  }

  Widget _optionTile(
    BuildContext context,
    int index,
    HistoryProgressChoice choice,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = index == _selected;
    final ago = watchedAgoLabel(choice.updatedAt, nowMs: widget.nowMs);
    final meta = [
      '已看 ${clockText(choice.positionMs)} / ${clockText(choice.durationMs)}',
      if (choice.durationMs > 0) '${choice.progressPercent}%',
      if (ago.isNotEmpty) ago,
    ].join(' · ');
    return Material(
      color: selected
          ? scheme.primaryContainer.withValues(alpha: .35)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        key: ValueKey('history-progress-option-$index'),
        onTap: () => _select(index),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 18,
                color: selected ? scheme.primary : scheme.outline,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: choice.isOwnSite
                                ? scheme.primaryContainer
                                : scheme.tertiaryContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            choice.sourceLabel,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: choice.isOwnSite
                                  ? scheme.onPrimaryContainer
                                  : scheme.onTertiaryContainer,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            choice.episodeName.isEmpty
                                ? '未知集'
                                : choice.episodeName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      meta,
                      style: theme.textTheme.bodySmall?.copyWith(
                        // 玻璃面板上的 12px 说明文字：明暗都走玻璃专用角色
                        // （亮色 onSurface / 暗色 nightInkOnGlass，见 tokens.dart）。
                        color: glassSecondaryInk(context),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
