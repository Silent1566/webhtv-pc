/// 追番页（Phase 9 · P2-1）。
///
/// 数据来自本地 `following` 表；检查更新走「站点详情 → 线路集数」，
/// 应用关闭后不检查（PC 没有后台服务，见 `core/following.dart` 的边界说明）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/following.dart';
import '../core/protocol.dart';
import '../services/storage.dart';
import '../state/app_state.dart';
import 'app.dart';
import 'browse_pages.dart';
import 'playback_resume.dart';
import 'tokens.dart';
import 'toast.dart';

class FollowingPage extends StatefulWidget {
  const FollowingPage({super.key, required this.state});

  final AppState state;

  @override
  State<FollowingPage> createState() => _FollowingPageState();
}

class _FollowingPageState extends State<FollowingPage> {
  bool _checking = false;
  String _message = '';

  AppState get _state => widget.state;

  @override
  void initState() {
    super.initState();
    // 外部（检查/追番/取消）都会 notify；页面必须跟着重建。
    _state.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    _state.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  List<Following> get _items => _state.followings;

  Future<void> _checkAll() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _message = '';
    });
    final summary = await _state.checkAllFollowings();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _message =
          '检查 ${summary.checked} 部：新集 ${summary.changed} 部，失败 ${summary.failed} 部';
    });
  }

  Future<void> _checkOne(Following item) async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _message = '';
    });
    final outcome = await _state.checkFollowing(item);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _message = outcome == null
          ? '本地存储不可用'
          : outcome.ok
          ? (outcome.changed ? '发现新集：${item.vodName}' : '没有新集')
          : '检查失败：${outcome.error}';
    });
  }

  Future<void> _playLatest(Following item) async {
    if (item.latestEpisodeTarget.isEmpty) {
      await _openDetail(item);
      return;
    }
    final history = PlaybackHistory(
      id: 0,
      siteKey: item.siteKey,
      vodId: item.vodId,
      vodName: item.vodName,
      vodPic: item.vodPic,
      flag: item.sourceFlag.isEmpty ? item.flag : item.sourceFlag,
      episodeName: item.latestEpisodeName,
      episodeId: item.latestEpisodeTarget,
      positionMs: 0,
      durationMs: 0,
      updatedAt: item.updatedAtMs,
    );
    await resumeHistoryEntry(context, _state, history);
    if (!mounted) return;
    await _state.markFollowingWatched(item);
  }

  Future<void> _openDetail(Following item) async {
    final config = _state.config;
    final site = config?.sites
        .where((candidate) => candidate.key == item.siteKey)
        .firstOrNull;
    if (site == null) {
      showToast('该追番所属站点已不在当前配置中：${item.siteKey}', kind: ToastKind.error);
      return;
    }
    await _state.selectSite(site);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailPage(
          state: _state,
          vod: Vod(
            vodId: item.vodId,
            vodName: item.vodName,
            vodPic: item.vodPic,
          ),
          historyFlag: item.flag,
        ),
      ),
    );
  }

  Future<void> _remove(Following item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('取消追番？'),
        content: Text('不再检查《${item.vodName}》的更新。已下载/已看的记录不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('保留'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('取消追番'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _state.unfollowFollowing(item);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _items;
    final updateCount = items.where((item) => item.hasUpdate).length;
    final settings = _state.followingSettings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              Text(
                '追番（${items.length}）',
                style: theme.textTheme.titleMedium,
              ),
              if (updateCount > 0)
                Container(
                  key: const ValueKey('following-update-summary'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Text(
                    '$updateCount 部有新集',
                    style: TextStyle(
                      color: theme.colorScheme.onPrimaryContainer,
                      fontSize: 12,
                    ),
                  ),
                ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                key: const ValueKey('following-check-all'),
                onPressed: _checking || items.isEmpty ? null : _checkAll,
                icon: _checking
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 18),
                label: Text(_checking ? '检查中…' : '检查更新'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              _toggle(
                key: 'following-auto',
                label: '自动检查',
                value: settings.enabled,
                subtitle: '应用运行期间每 ${settings.intervalMinutes ~/ 60} 小时',
                onChanged: (value) async {
                  await _state.setFollowingSettings(
                    settings.copyWith(enabled: value),
                  );
                },
              ),
              _toggle(
                key: 'following-notify',
                label: '新集提示',
                value: settings.notifyEnabled,
                subtitle: '应用内徽标提示（系统通知未实现）',
                onChanged: (value) async {
                  await _state.setFollowingSettings(
                    settings.copyWith(notifyEnabled: value),
                  );
                },
              ),
            ],
          ),
        ),
        if (_message.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Text(_message, style: theme.textTheme.bodySmall),
          ),
        const SizedBox(height: 4),
        Expanded(
          child: items.isEmpty
              ? const _FollowingEmpty()
              : ListView.separated(
                  key: const ValueKey('following-list'),
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const Divider(height: 12),
                  itemBuilder: (context, index) => _FollowingCard(
                    item: items[index],
                    checking: _checking,
                    onPlay: _playLatest,
                    onOpenDetail: _openDetail,
                    onCheck: _checkOne,
                    onMarkRead: (item) => _state.markFollowingRead(item),
                    onRemove: _remove,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _toggle({
    required String key,
    required String label,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SizedBox(
      width: 300,
      child: SwitchListTile(
        key: ValueKey(key),
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 11)),
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}

class _FollowingEmpty extends StatelessWidget {
  const _FollowingEmpty();

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const ValueKey('following-empty'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_border, size: 44),
          const SizedBox(height: AppSpace.sm),
          const Text('还没有追番'),
          const SizedBox(height: AppSpace.xs),
          const Text(
            '在影片详情页点右上角 ★ 加入追番；有新集时这里会显示徽标。',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _FollowingCard extends StatelessWidget {
  const _FollowingCard({
    required this.item,
    required this.checking,
    required this.onPlay,
    required this.onOpenDetail,
    required this.onCheck,
    required this.onMarkRead,
    required this.onRemove,
  });

  final Following item;
  final bool checking;
  final ValueChanged<Following> onPlay;
  final ValueChanged<Following> onOpenDetail;
  final ValueChanged<Following> onCheck;
  final ValueChanged<Following> onMarkRead;
  final ValueChanged<Following> onRemove;

  int get _newEpisodes =>
      math.max(0, item.releasedEpisode - math.max(item.watchedEpisode, item.readWatermarkEpisode));

  String get _statusText {
    final status = FollowingStatus.label(item.status);
    final line = item.flag.isEmpty ? '默认线路' : item.flag;
    return '$status · $line · 已更新 ${item.releasedEpisode} 集';
  }

  String get _lastCheckText {
    if (item.lastError.isNotEmpty) return '上次检查失败：${item.lastError}';
    if (item.lastCheckedAtMs <= 0) return '尚未检查';
    final time = DateTime.fromMillisecondsSinceEpoch(item.lastCheckedAtMs);
    String two(int v) => v.toString().padLeft(2, '0');
    return '上次检查 ${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      key: ValueKey('following-card-${item.identityKey}'),
      onTap: () => onPlay(item),
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: SizedBox(
                width: 56,
                height: 84,
                child: PosterImage(url: item.vodPic),
              ),
            ),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.vodName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      if (_newEpisodes > 0)
                        Container(
                          key: ValueKey('following-badge-${item.identityKey}'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '$_newEpisodes 新',
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(_statusText, style: theme.textTheme.bodySmall),
                  const SizedBox(height: 2),
                  Text(
                    _lastCheckText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: item.lastError.isEmpty
                          ? null
                          : theme.colorScheme.error,
                    ),
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              key: ValueKey('following-menu-${item.identityKey}'),
              tooltip: '更多',
              onSelected: (value) {
                switch (value) {
                  case 'play':
                    onPlay(item);
                  case 'detail':
                    onOpenDetail(item);
                  case 'check':
                    onCheck(item);
                  case 'read':
                    onMarkRead(item);
                  case 'remove':
                    onRemove(item);
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'play', child: Text('播放最新集')),
                const PopupMenuItem(value: 'detail', child: Text('打开详情')),
                PopupMenuItem(
                  value: 'check',
                  enabled: !checking,
                  child: const Text('检查更新'),
                ),
                const PopupMenuItem(value: 'read', child: Text('标记已读')),
                const PopupMenuItem(value: 'remove', child: Text('取消追番')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
