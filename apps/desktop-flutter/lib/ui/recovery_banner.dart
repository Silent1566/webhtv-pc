/// 崩溃恢复横幅（Phase 9 · P2-8）。
///
/// 独立成公开 widget：`AppShell` 负责决定何时显示，横幅本身只做展示与回调，
/// 这样可以在不挂整个壳层（及其定时器）的情况下单测。
library;

import 'package:flutter/material.dart';

import '../core/session_recovery.dart';
import 'tokens.dart';

/// 崩溃恢复横幅（Phase 9 · P2-8）。
///
/// 只在「上次进程没有走正常退出路径」（标记还在且 pid 不是当前进程）时出现。
/// 继续播放走历史续播同一条路径（重新解析），标记里没有直链与凭据。
class RecoveryBanner extends StatelessWidget {
  const RecoveryBanner({
    super.key,
    required this.marker,
    required this.hasCrashLog,
    required this.onResume,
    required this.onShowLog,
    required this.onDismiss,
  });

  final SessionMarker marker;
  final bool hasCrashLog;
  final ValueChanged<SessionPlaybackContext> onResume;
  final VoidCallback onShowLog;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final playback = marker.playback;
    return Container(
      width: double.infinity,
      color: scheme.tertiaryContainer,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.xl,
        vertical: AppSpace.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            Icons.restart_alt_outlined,
            size: 18,
            color: scheme.onTertiaryContainer,
          ),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(
              describeRecoveredSession(marker, DateTime.now()),
              key: const ValueKey('recovery-banner-text'),
              style: TextStyle(color: scheme.onTertiaryContainer, fontSize: 12),
            ),
          ),
          if (playback != null)
            TextButton(
              key: const ValueKey('recovery-resume'),
              onPressed: () => onResume(playback),
              child: const Text('继续上次播放'),
            ),
          if (hasCrashLog)
            TextButton(
              key: const ValueKey('recovery-show-log'),
              onPressed: onShowLog,
              child: const Text('崩溃日志'),
            ),
          TextButton(
            key: const ValueKey('recovery-dismiss'),
            onPressed: onDismiss,
            child: const Text('忽略'),
          ),
        ],
      ),
    );
  }
}

