/// 最近观看与收藏页（§17.2 历史页 / 收藏页，§15）。
library;

import 'package:flutter/material.dart';

import '../core/app_error.dart';
import '../services/storage.dart';
import '../state/app_state.dart';
import 'app.dart';
import 'player_page.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, required this.state});

  final AppState state;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  String _keyword = '';

  AppState get _state => widget.state;

  List<PlaybackHistory> get _items => _keyword.isEmpty
      ? _state.recentHistory()
      : _state.searchHistory(_keyword);

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search),
                    hintText: '搜索片名或剧集名',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) => setState(() => _keyword = value.trim()),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('清空播放历史'),
                      content: const Text('该操作只清空播放历史，不会删除配置。'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          child: const Text('清空'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    _state.clearHistory();
                    if (mounted) setState(() {});
                  }
                },
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('清空历史'),
              ),
            ],
          ),
        ),
        if (_state.database == null)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Text('本地存储不可用，播放历史暂不记录。'),
          ),
        const Divider(height: 1),
        Expanded(
          child: items.isEmpty
              ? const Center(child: Text('暂无播放记录。播放任意剧集后会自动记录进度。'))
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return ListTile(
                      leading: SizedBox(
                        width: 48,
                        height: 64,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: PosterImage(url: item.vodPic),
                        ),
                      ),
                      title: Text(item.vodName),
                      subtitle: Text(
                        '${item.episodeName} · ${item.progressPercent}%'
                        '${item.completed ? " · 已看完" : ""}\n'
                        '更新 ${DateTime.fromMillisecondsSinceEpoch(item.updatedAt).toLocal()}',
                      ),
                      isThreeLine: true,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          OutlinedButton(
                            onPressed: () => _resume(item),
                            child: Text(item.completed ? '重播' : '继续播放'),
                          ),
                          IconButton(
                            tooltip: '删除该记录',
                            onPressed: () {
                              _state.deleteHistory(item.id);
                              setState(() {});
                            },
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// 从历史恢复播放。
  ///
  /// 设计约束：历史只保存剧集地址与站点 key，恢复时需要重新解析播放决策，
  /// 避免把过期直链直接交给播放器（§15.2 “继续播放”）。
  Future<void> _resume(PlaybackHistory item) async {
    final state = _state;
    final config = state.config;
    final site = config?.sites
        .where((candidate) => candidate.key == item.siteKey)
        .firstOrNull;
    if (site == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('该记录所属站点已不在当前配置中：${item.siteKey}')),
      );
      return;
    }
    await state.selectSite(site);
    try {
      final decision = await state.resolvePlayback(
        episodeTarget: item.episodeId,
        flag: item.flag,
        vodId: item.vodId,
      );
      if (decision == null || decision.url == null) {
        throw AppError(
          AppErrorKind.playbackUrlMissing,
          '历史记录没有可用播放地址',
          detail: item.episodeId,
        );
      }
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerPage(
            state: state,
            request: PlaybackRequest(
              url: decision.url!,
              headers: decision.headers?.asRequestHeaders ?? const {},
              title: item.vodName,
              siteKey: item.siteKey,
              vodId: item.vodId,
              vodName: item.vodName,
              episodeName: item.episodeName,
              flag: item.flag,
              startPosition: Duration(milliseconds: item.positionMs),
              vodPic: item.vodPic,
              // 外挂字幕（§10.3）/弹幕（§21 Phase 3）：历史恢复同样带入。
              subtitles: decision.subs,
              danmaku: decision.danmaku,
              subtitleHeaders:
                  decision.assetHeaders?.asRequestHeaders ?? const {},
            ),
          ),
        ),
      );
    } catch (error) {
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(failure.userMessage)),
      );
    }
  }
}

class FavoritesPage extends StatelessWidget {
  const FavoritesPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final items = state.favorites();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Text(
                '收藏（${items.length}）',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(width: 12),
              const Text('收藏站点、影片或分组；数据保存在本地数据库。'),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: items.isEmpty
              ? const Center(child: Text('暂无收藏。在详情页右上角可以收藏影片。'))
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return ListTile(
                      leading: Icon(
                        item.kind == 'vod' ? Icons.movie_outlined : Icons.dns_outlined,
                      ),
                      title: Text(item.title),
                      subtitle: Text(
                        '类型=${item.kind} 站点=${item.siteKey} '
                        '目标=${item.targetId}'
                        '${item.subtitle == null ? "" : " · ${item.subtitle}"}',
                      ),
                      trailing: IconButton(
                        tooltip: '取消收藏',
                        onPressed: () {
                          state.database?.removeFavorite(
                            kind: item.kind,
                            siteKey: item.siteKey,
                            targetId: item.targetId,
                          );
                          (context as Element).markNeedsBuild();
                        },
                        icon: const Icon(Icons.bookmark_remove_outlined),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// 本地实现的 firstOrNull，避免为单个用法引入 `package:collection`。
extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    for (final item in this) {
      return item;
    }
    return null;
  }
}

/// 便于测试与诊断：把历史列表渲染成纯文本。
String describeHistory(List<PlaybackHistory> items) => items
    .map(
      (item) =>
          '${item.vodName} | ${item.episodeName} | ${item.progressPercent}% | '
          '${item.completed ? "completed" : "in-progress"}',
    )
    .join('\n');

/// 保持对 [AppError] 的显式引用，便于本文件单独测试错误提示。
String describeHistoryError(AppError error) => error.userMessage;
