/// 加固壳解包的三处用户可见交互：导入后的确认框、多选解包、解包进度。
///
/// 本文件**只认展示模型**（[ShellTargetItem] / [ShellUnpackTickView]）：
/// 探测结果由 `state/app_state.dart` 映射进来，UI 层不直接读 `ShellJarTarget`
/// 之类的探测类型。理由很实际——解包前要下载约 40.7 MB 运行时，入口越窄，
/// 「随手点一下就把网跑起来」的可能就越少。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webhtv_pc/services/csp_jar_probe.dart' show ShellUnpackTick;

/// 一个待解包 jar 的展示条目（探测结果 → UI 的桥）。
///
/// [selected] / [disabled] 由 state 层决定：已解包的条目默认不勾选并置灰，
/// 用户点的那个站点所属 jar 默认勾选。对话框自己不做这个判断——它没有探测
/// 上下文，猜出来的默认值只会和真实状态分叉。
class ShellTargetItem {
  const ShellTargetItem({
    required this.jarUrl,
    required this.label,
    required this.siteCount,
    required this.stateLabel,
    this.selected = true,
    this.disabled = false,
  });

  /// 解包目标的唯一键（远端 jar 地址）。
  final String jarUrl;

  /// 列表主文案（通常是 jar 文件名或源站名）。
  final String label;

  /// 该 jar 覆盖的站点数。
  final int siteCount;

  /// 当前状态文案：需下载 / 需解包 / 已解包 / 上次失败（阶段）。
  final String stateLabel;

  /// 打开对话框时是否默认勾选。
  final bool selected;

  /// 是否禁止勾选（已解包、无可解包内容）。
  final bool disabled;
}

/// 进度快照的展示模型（[ShellUnpackTick] 的一次采样）。
class ShellUnpackTickView {
  const ShellUnpackTickView({
    required this.jarIndex,
    required this.jarCount,
    required this.stage,
    required this.fraction,
    this.eta,
  });

  /// 当前 jar 在本次多选里的下标（与 [ShellUnpackTick.jarIndex] 一致，0 起）。
  final int jarIndex;

  /// 本次一共要解几个壳。
  final int jarCount;

  /// 阶段名（下载 / 解包 / 校验…）。
  final String stage;

  /// 0..1 的完成比例。
  final double fraction;

  /// 预计剩余；null 表示还算不出来。
  final Duration? eta;
}

/// 导入配置后检测到加固壳时的确认框。
///
/// 返回 true 仅代表用户点了主按钮且 [onConfirm] 已执行完；「稍后」与 Esc
/// 都返回 false，且**不执行** [onConfirm]——取消路径不允许产生任何下载。
Future<bool> showShellUnpackPrompt(
  BuildContext context, {
  required int siteCount,
  required bool runtimeInstalled,
  required Future<void> Function() onConfirm,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    // 取消必须是显式动作（「稍后」）：点遮罩被读成"确认"就会白下一份运行时。
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      key: const ValueKey('shell-unpack-prompt'),
      title: const Text('检测到加固壳站源'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('导入的配置里有 $siteCount 个加固壳站源，需要解包后才能在 PC 端运行。'),
          if (!runtimeInstalled) ...[
            const SizedBox(height: 12),
            const Text('解包运行时尚未安装，需要先下载（约 40.7 MB）。'),
          ],
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('shell-unpack-prompt-later'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('稍后'),
        ),
        FilledButton(
          key: const ValueKey('shell-unpack-prompt-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('下载并解包'),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;
  await onConfirm();
  return true;
}

/// 多选解包对话框。
///
/// 返回用户勾选的 jarUrl 集合；取消返回 null。默认全选（[ShellTargetItem.selected]），
/// 已解包的条目由 state 层置灰且不勾选，避免无意义重解。
Future<Set<String>?> showShellUnpackSelection(
  BuildContext context, {
  required List<ShellTargetItem> items,
  required String? runtimeStateLabel,
}) {
  return showDialog<Set<String>>(
    context: context,
    builder: (context) => _ShellUnpackSelectionDialog(
      items: items,
      runtimeStateLabel: runtimeStateLabel,
    ),
  );
}

class _ShellUnpackSelectionDialog extends StatefulWidget {
  const _ShellUnpackSelectionDialog({
    required this.items,
    required this.runtimeStateLabel,
  });

  final List<ShellTargetItem> items;
  final String? runtimeStateLabel;

  @override
  State<_ShellUnpackSelectionDialog> createState() =>
      _ShellUnpackSelectionDialogState();
}

class _ShellUnpackSelectionDialogState
    extends State<_ShellUnpackSelectionDialog> {
  late final Set<String> _selected = {
    for (final item in widget.items)
      if (item.selected && !item.disabled) item.jarUrl,
  };

  void _toggle(ShellTargetItem item, bool? checked) {
    setState(() {
      if (checked ?? false) {
        _selected.add(item.jarUrl);
      } else {
        _selected.remove(item.jarUrl);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectable = widget.items.where((item) => !item.disabled).length;
    return AlertDialog(
      key: const ValueKey('shell-unpack-selection'),
      title: const Text('选择要解包的加固壳'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.runtimeStateLabel != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  widget.runtimeStateLabel!,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (widget.items.isEmpty)
              const Text('没有需要解包的加固壳。')
            else
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final item in widget.items)
                        CheckboxListTile(
                          key: ValueKey('shell-target-${item.jarUrl}'),
                          value: _selected.contains(item.jarUrl),
                          onChanged: item.disabled
                              ? null
                              : (checked) => _toggle(item, checked),
                          dense: true,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(item.label),
                          subtitle: Text(
                            '${item.siteCount} 个站点 · ${item.stateLabel}',
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Text(
              '已解包的壳无需重解；已勾选 ${_selected.length}/$selectable 项。',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('shell-unpack-selection-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('shell-unpack-selection-start'),
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(Set<String>.of(_selected)),
          child: Text('开始解包（选中 ${_selected.length} 项）'),
        ),
      ],
    );
  }
}

/// 解包进度对话框。
///
/// [ticks] 每来一条就刷新一行；流正常结束意味着解包完成（可关闭），流出错则
/// **停在失败态**并显示阶段与原因——失败不许静默关掉。
Future<void> showShellUnpackProgress(
  BuildContext context, {
  required int jarCount,
  required Stream<ShellUnpackTick> ticks,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => ShellUnpackProgressDialog(
      jarCount: jarCount,
      ticks: ticks.map(_tickViewOf),
    ),
  );
}

ShellUnpackTickView _tickViewOf(ShellUnpackTick tick) => ShellUnpackTickView(
      jarIndex: tick.jarIndex,
      jarCount: tick.jarCount,
      stage: tick.stage,
      fraction: tick.fraction,
      eta: tick.eta,
    );

/// 进度对话框本体（吃展示模型，便于单独渲染验证）。
class ShellUnpackProgressDialog extends StatefulWidget {
  const ShellUnpackProgressDialog({
    super.key,
    required this.jarCount,
    required this.ticks,
  });

  final int jarCount;
  final Stream<ShellUnpackTickView> ticks;

  @override
  State<ShellUnpackProgressDialog> createState() =>
      _ShellUnpackProgressDialogState();
}

class _ShellUnpackProgressDialogState extends State<ShellUnpackProgressDialog> {
  StreamSubscription<ShellUnpackTickView>? _subscription;
  ShellUnpackTickView? _tick;
  bool _done = false;
  String? _failure;

  @override
  void initState() {
    super.initState();
    _subscription = widget.ticks.listen(
      (tick) => setState(() => _tick = tick),
      onError: (Object error) => setState(() => _failure = '$error'),
      onDone: () => setState(() => _done = true),
    );
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  String get _stageLabel => _tick?.stage ?? '准备中';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tick = _tick;
    final jarCount = tick != null && tick.jarCount > 0
        ? tick.jarCount
        : widget.jarCount;
    final fraction = (tick?.fraction ?? 0).clamp(0.0, 1.0);
    final percent = (fraction * 100).round();
    final failed = _failure != null;
    final running = !failed && !_done;
    return AlertDialog(
      key: const ValueKey('shell-unpack-progress'),
      title: Text(failed ? '加固壳解包失败' : '正在解包加固壳'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tick == null
                  ? '第 1/$jarCount 个壳'
                  : '第 ${tick.jarIndex + 1}/$jarCount 个壳',
              key: const ValueKey('shell-unpack-progress-counter'),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              '阶段：$_stageLabel',
              key: const ValueKey('shell-unpack-progress-stage'),
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              key: const ValueKey('shell-unpack-progress-bar'),
              value: running && fraction == 0 ? null : fraction,
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('$percent%'),
                Text(
                  _etaLabel(tick?.eta),
                  key: const ValueKey('shell-unpack-progress-eta'),
                ),
              ],
            ),
            if (failed) ...[
              const SizedBox(height: 12),
              Text(
                '失败于阶段「$_stageLabel」：$_failure',
                key: const ValueKey('shell-unpack-progress-failure'),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (!running)
          TextButton(
            key: const ValueKey('shell-unpack-progress-close'),
            onPressed: () => Navigator.of(context).pop(),
            child: Text(failed ? '关闭' : '完成'),
          ),
      ],
    );
  }
}

String _etaLabel(Duration? eta) {
  if (eta == null) return '预计剩余：计算中…';
  final total = eta.inSeconds;
  final minutes = (total ~/ 60).toString().padLeft(2, '0');
  final seconds = (total % 60).toString().padLeft(2, '0');
  return '预计剩余：$minutes:$seconds';
}
