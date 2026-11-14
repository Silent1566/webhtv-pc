/// 播放器「画质」选择面板。
///
/// 与 `player_episode_panel.dart` 同一套做法：面板自己不碰播放状态，
/// 选中哪一项通过回调回给 `player_page.dart`，由它走既有解析路径重新取地址。
///
/// 为什么是居中弹窗而不是 `PopupMenuButton`：入口在底部控制栏，下拉菜单
/// 会向屏幕外展开（实测菜单项落在 720 高的窗口之外，y≈758），鼠标点不到。
/// 居中弹窗的可用高度只受窗口高度约束，全屏与窄窗口下都可达。
library;

import 'package:flutter/material.dart';

import '../core/protocol.dart';

/// 画质面板的稳定标识（测试与语义断言用）。
const Key playerQualityPanelKey = ValueKey('player-quality-panel');

/// 一张画质卡片的标识：`player-quality-option-<下标>`。
Key playerQualityOptionKey(int index) =>
    ValueKey('player-quality-option-$index');

/// 画质展示名：名称为空时退化为「画质 N」，不显示空白项。
String playbackQualityLabel(PlaybackQuality quality, int index) {
  final name = quality.name.trim();
  return name.isEmpty ? '画质 ${index + 1}' : name;
}

/// 弹出画质面板；返回用户选中的下标，取消返回 null。
Future<int?> showPlayerQualityPanel(
  BuildContext context, {
  required List<PlaybackQuality> qualities,
  required int selectedIndex,
  String title = '画质',
}) {
  return showDialog<int>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.62),
    builder: (_) => PlayerQualityPanel(
      title: title,
      qualities: qualities,
      selectedIndex: selectedIndex,
    ),
  );
}

/// 画质选择面板本体（无状态）。
class PlayerQualityPanel extends StatelessWidget {
  const PlayerQualityPanel({
    super.key,
    required this.qualities,
    required this.selectedIndex,
    this.title = '画质',
  });

  /// 当前集播放接口返回的多个候选地址（原始、未代理）。
  final List<PlaybackQuality> qualities;

  /// 当前正在播放的候线下标。
  final int selectedIndex;

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      key: playerQualityPanelKey,
      backgroundColor: const Color(0xFF16181D),
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360, maxHeight: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: qualities.length,
                itemBuilder: (context, index) {
                  final selected = index == selectedIndex;
                  return ListTile(
                    key: playerQualityOptionKey(index),
                    selected: selected,
                    title: Text(playbackQualityLabel(qualities[index], index)),
                    // 标选定项：勾选图标 + 强调色，不靠颜色单独区分。
                    trailing: selected
                        ? Icon(
                            Icons.check,
                            size: 20,
                            color: theme.colorScheme.primary,
                          )
                        : null,
                    onTap: () => Navigator.of(context).pop(index),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
