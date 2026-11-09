/// 追番页（Phase 9 · P2-1）。
///
/// 数据来自本地 `following` 表；检查更新走「站点详情 → 线路集数」，
/// 应用关闭后不检查（PC 没有后台服务，见 `core/following.dart` 的边界说明）。
library;

import 'dart:async';

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _consumeOpenRequest());
  }

  @override
  void dispose() {
    _state.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    if (!mounted) return;
    setState(() {});
    _consumeOpenRequest();
  }

  /// 系统通知被点击后打开对应追番的最新集（请求由 AppState 记录）。
  void _consumeOpenRequest() {
    final key = _state.followingOpenRequest;
    if (key.isEmpty) return;
    _state.clearFollowingOpenRequest();
    final item = _items
        .where((candidate) => candidate.identityKey == key)
        .firstOrNull;
    if (item == null) return;
    _message = '来自系统通知：${item.vodName}';
    unawaited(_playLatest(item));
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

  /// 检查间隔预设（分钟）；自定义输入另开一格。
  static const List<int> _intervalPresets = [15, 30, 60, 180, 360, 720, 1440];

  Future<void> _editInterval(FollowingSettings settings) async {
    final controller = TextEditingController(
      text: '${settings.intervalMinutes}',
    );
    var selected = settings.intervalMinutes;
    final picked = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('following-interval-dialog'),
        title: const Text('自动检查间隔'),
        content: StatefulBuilder(
          builder: (context, setLocal) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final minutes in _intervalPresets)
                    ChoiceChip(
                      key: ValueKey('following-interval-$minutes'),
                      label: Text(FollowingSettings.formatInterval(minutes)),
                      selected: selected == minutes,
                      onSelected: (_) => setLocal(() {
                        selected = minutes;
                        controller.text = '$minutes';
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('following-interval-input'),
                controller: controller,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '自定义分钟（15–1440）'),
                onChanged: (value) => setLocal(() {
                  selected = int.tryParse(value.trim()) ?? selected;
                }),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('following-interval-save'),
            onPressed: () => Navigator.of(context).pop(
              int.tryParse(controller.text.trim()) ?? settings.intervalMinutes,
            ),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (picked == null) return;
    // 夹取在 `FollowingSettings.copyWith` 里做；保存后立即重建定时器并补检查。
    await _state.setFollowingSettings(
      settings.copyWith(intervalMinutes: picked),
    );
    if (!mounted) return;
    setState(() {
      _message = '检查间隔已设为 ${_state.followingSettings.intervalLabel}';
    });
  }

  Future<void> _playLatest(Following item) async {
    if (item.latestEpisodeTarget.isEmpty) {
      await _openDetail(item);
      return;
    }
    await _state.markFollowingRead(item);
    if (!mounted) return;
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
    _syncProgress(item);
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
    await _state.markFollowingRead(item);
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
    if (!mounted) return;
    _syncProgress(item);
  }

  void _syncProgress(Following item) {
    final result = _state.syncFollowingProgress(items: [item]);
    if (result.updated > 0) setState(() {});
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
    // 汇总口径 = 有未看的发布集（已读水位不参与，水位只抑制新集提示）。
    final unwatchedCount = items
        .where((item) => item.unwatchedCount > 0)
        .length;
    final settings = _state.followingSettings;
    // 页面自身结果优先，其次是通知降级/发送结果。
    final notice = _message.isNotEmpty ? _message : _state.followingNotice;
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
              Text('追番（${items.length}）', style: theme.textTheme.titleMedium),
              if (unwatchedCount > 0)
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
                    '$unwatchedCount 部有未看',
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
                subtitle: '应用运行期间${settings.intervalLabel}',
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
                subtitle: '系统通知；不可用时降级为应用内徽标与提示条',
                onChanged: (value) async {
                  await _state.setFollowingSettings(
                    settings.copyWith(notifyEnabled: value),
                  );
                },
              ),
              TextButton.icon(
                key: const ValueKey('following-interval'),
                onPressed: () => _editInterval(settings),
                icon: const Icon(Icons.schedule, size: 16),
                label: Text('检查间隔：${settings.intervalLabel}'),
              ),
            ],
          ),
        ),
        if (notice.isNotEmpty)
          Padding(
            key: const ValueKey('following-notice'),
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Text(notice, style: theme.textTheme.bodySmall),
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
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return FollowingCard(
                      item: item,
                      checking: _checking,
                      globalNotifyEnabled: settings.notifyEnabled,
                      onPlay: _playLatest,
                      onOpenDetail: _openDetail,
                      onCheck: _checkOne,
                      onMarkRead: (item) => _state.markFollowingRead(item),
                      onSetNotify: (enabled) =>
                          _state.setFollowingNotifyEnabled(item, enabled),
                      onRemove: _remove,
                    );
                  },
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

/// 一条追番卡片（纯展示，无状态；公开以便 widget 测试直接构造）。
class FollowingCard extends StatelessWidget {
  const FollowingCard({
    super.key,
    required this.item,
    required this.checking,
    required this.globalNotifyEnabled,
    required this.onPlay,
    required this.onOpenDetail,
    required this.onCheck,
    required this.onMarkRead,
    required this.onSetNotify,
    required this.onRemove,
  });

  final Following item;
  final bool checking;

  /// 全局「新集提示」开关（`FollowingSettings.notifyEnabled`）。
  ///
  /// 条目自身的 [Following.notifyEnabled] 只在追番那一刻从全局值拷贝下来，
  /// 之后可单独开关（kebab 菜单「新集通知」），所以生效值必须两个都开——
  /// 只显示条目值会把「全局关了、条目仍是开」显示成开。
  final bool globalNotifyEnabled;

  final ValueChanged<Following> onPlay;
  final ValueChanged<Following> onOpenDetail;
  final ValueChanged<Following> onCheck;
  final ValueChanged<Following> onMarkRead;

  /// 本次要设置的条目开关目标值（菜单里已按当前值取反），
  /// 父层直接转给 `AppState.setFollowingNotifyEnabled`。
  final ValueChanged<bool> onSetNotify;

  final ValueChanged<Following> onRemove;

  /// 未看集数（`Following.unwatchedCount`：已读水位不参与，水位只抑制新集提示）。
  int get _unwatched => item.unwatchedCount;

  bool get _notifyEffective => globalNotifyEnabled && item.notifyEnabled;

  String get _statusText {
    final status = FollowingStatus.label(item.status);
    final line = item.flag.isEmpty ? '默认线路' : item.flag;
    return '$status · $line';
  }

  /// 本线路可播集数（来自站点线路，不是官方/元数据集数）。
  String get _episodeText =>
      item.releasedEpisode > 0 ? '本线路可播 ${item.releasedEpisode} 集' : '集数未知';

  String get _watchedText =>
      item.watchedEpisode > 0 ? '已看 ${item.watchedEpisode} 集' : '未开始看';

  /// 三态：生效开 / 条目关 / 全局关（条目开着但推送不会发生）。
  String get _notifyText {
    if (_notifyEffective) return '新集通知：开';
    if (!item.notifyEnabled) return '新集通知：关（条目关闭）';
    return '新集通知：关（全局开关关闭）';
  }

  /// 下一季入口：仅当有比追踪季更新的发布季时显示（PC 暂无季数据，恒不显示），
  /// 且 PC 没有「追下一季」能力，所以只给文字，不做可点击控件。
  bool get _showNextSeason => item.latestReleasedSeason > item.trackedSeason;

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
    final subtle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final emphasis = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.w600,
    );
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
                      if (_unwatched > 0)
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
                            '$_unwatched 集未看',
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
                  Wrap(
                    spacing: AppSpace.sm,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(_episodeText, style: subtle),
                      Text(_watchedText, style: subtle),
                      if (_unwatched > 0)
                        Text(
                          '未看 $_unwatched 集',
                          key: ValueKey(
                            'following-unwatched-${item.identityKey}',
                          ),
                          style: emphasis,
                        ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _notifyEffective
                                ? Icons.notifications_active_outlined
                                : Icons.notifications_off_outlined,
                            size: 13,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: AppSpace.xs),
                          Text(
                            _notifyText,
                            key: ValueKey(
                              'following-notify-${item.identityKey}',
                            ),
                            style: subtle,
                          ),
                        ],
                      ),
                      if (_showNextSeason)
                        Text(
                          '第 ${item.latestReleasedSeason + 1} 季已开播',
                          key: ValueKey(
                            'following-next-season-${item.identityKey}',
                          ),
                          style: emphasis,
                        ),
                    ],
                  ),
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
                  case 'notify':
                    onSetNotify(!item.notifyEnabled);
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
                PopupMenuItem(
                  key: ValueKey('following-menu-notify-${item.identityKey}'),
                  value: 'notify',
                  height: 64,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.notifyEnabled ? '新集通知：已开启' : '新集通知：已关闭'),
                      Text(
                        globalNotifyEnabled
                            ? '仅对这部剧生效'
                            : '全局「新集提示」已关闭，开启后也不会推送',
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'read',
                  child: Text('标为已读（仅清除提示）'),
                ),
                const PopupMenuItem(value: 'remove', child: Text('取消追番')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
