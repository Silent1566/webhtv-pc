import 'package:flutter/material.dart';

import '../core/protocol.dart';
import 'live_playback_session.dart';
import 'tokens.dart';

class PlayerLiveLinePanel extends StatelessWidget {
  const PlayerLiveLinePanel({
    super.key,
    required this.session,
    required this.channel,
    required this.onDismiss,
    required this.onSelect,
  });
  final LivePlaybackSession session;
  final LiveChannel channel;
  final VoidCallback onDismiss;
  final bool Function(int) onSelect;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final urls = channel.urls.where((url) => url.trim().isNotEmpty).toList();
      final colors = Theme.of(context).colorScheme;
      return Material(
        // 透明底：线路区嵌在联动面板内部，铺不透明白会吃掉面板的半透明。
        color: Colors.transparent,
        elevation: 0,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.lg,
                AppSpace.sm,
                AppSpace.sm,
                0,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${channel.name} · 线路（${urls.length}）',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭线路面板（Esc）',
                    onPressed: onDismiss,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(
                horizontal: AppSpace.lg,
                vertical: AppSpace.sm,
              ),
              child: Text('线路来自配置，未测量可用性'),
            ),
            const Divider(height: 1),
            Expanded(
              child: urls.isEmpty
                  ? const Center(child: Text('此频道没有可播放线路'))
                  : ListView.builder(
                      itemCount: urls.length,
                      itemBuilder: (context, index) => Tooltip(
                        message: urls[index],
                        child: ListTile(
                          key: ValueKey('live-line-$index'),
                          selected:
                              identical(session.channel, channel) &&
                              session.lineIndex == index &&
                              session.program == null,
                          selectedTileColor: colors.surfaceContainerHigh,
                          leading: const Icon(Icons.alt_route),
                          title: Text('线路 ${index + 1}'),
                          subtitle: Text(
                            urls[index],
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing:
                              identical(session.channel, channel) &&
                                  session.lineIndex == index &&
                                  session.program == null
                              ? const Icon(Icons.check)
                              : null,
                          onTap: () => onSelect(index),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      );
    },
  );
}
