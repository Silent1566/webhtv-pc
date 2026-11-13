import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_error.dart';
import '../core/protocol.dart';
import '../services/site_service.dart';
import '../state/app_state.dart';
import '../state/folder_browser_state.dart';
import '../state/folder_playback_queue.dart';
import '../state/playback_source_context.dart';
import 'browse_pages.dart';
import 'async_action_feedback.dart';
import 'folder_episode_view.dart';
import 'player_page.dart';

/// 独立目录路由：进入子层或影片时隐藏本层，不重建父层列表。
class FolderBrowserPage extends StatefulWidget {
  const FolderBrowserPage({
    super.key,
    required this.state,
    required this.folder,
    required this.site,
    required this.service,
    this.filters = const {},
    this.sourceContext,
    this.ancestors = const [],
  });

  final AppState state;
  final Vod folder;
  final Site? site;
  final SiteService? service;
  final Map<String, String> filters;
  final PlaybackSourceContext? sourceContext;
  final List<String> ancestors;

  @override
  State<FolderBrowserPage> createState() => _FolderBrowserPageState();
}

class _FolderBrowserPageState extends State<FolderBrowserPage> {
  FolderBrowserState? _browser;
  final _scroll = ScrollController();
  final _episodeScroll = ScrollController();
  FolderPlaybackQueue? _queue;
  bool _episodeMode = false;
  String? _openingKey;

  @override
  void initState() {
    super.initState();
    final site = widget.site;
    final service = widget.service;
    if (site != null && service != null) {
      _browser = FolderBrowserState(
        service: service,
        site: site,
        folder: widget.folder,
        filters: widget.filters,
      )..addListener(_changed);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_browser!.load());
      });
    }
    _scroll.addListener(_onScroll);
    _episodeScroll.addListener(_onScroll);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _onScroll() {
    final browser = _browser;
    final scroll = _episodeMode ? _episodeScroll : _scroll;
    if (browser == null || !scroll.hasClients || browser.error != null) return;
    if (scroll.position.extentAfter < 240) unawaited(_loadEpisodePage());
  }

  @override
  void dispose() {
    _queue?.dispose();
    _browser?.dispose();
    _scroll.dispose();
    _episodeScroll.dispose();
    super.dispose();
  }

  List<Vod> get _videos =>
      _browser!.items.where(isVideoCandidate).toList()..sort((a, b) {
        final order = naturalCompare(a.vodName, b.vodName);
        return order == 0 ? a.vodId.compareTo(b.vodId) : order;
      });

  FolderPlaybackQueue _playbackQueue() => _queue ??= FolderPlaybackQueue(
    state: widget.state,
    browser: _browser!,
    sourceKey: widget.sourceContext?.sourceKey ?? '',
  );

  Future<void> _loadEpisodePage() => _playbackQueue().loadMore();

  Future<void> _open(Vod item) async {
    if (_openingKey != null) return;
    final browser = _browser!;
    if (item.isFolder || isBridgeFolderVodId(item.vodId)) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => !isBridgeFolderVodId(item.vodId)
              ? FolderBrowserPage(
                  state: widget.state,
                  folder: item,
                  site: browser.site,
                  service: browser.service,
                  filters: browser.filters,
                  sourceContext: widget.sourceContext,
                  ancestors: [...widget.ancestors, widget.folder.vodName],
                )
              : DetailPage(
                  state: widget.state,
                  vod: item,
                  sourceContext: widget.sourceContext,
                  sourceSiteKey: browser.site.key,
                ),
        ),
      );
      return;
    }
    if (!isVideoCandidate(item)) return;
    final feedback = AsyncActionFeedback.begin(
      context,
      '正在准备播放：${item.vodName}',
    );
    if (feedback == null) return;
    setState(() => _openingKey = item.vodId);
    try {
      final queue = _playbackQueue()..startPlaybackSession(item.vodId);
      final request = await queue.resolve(
        item.vodId,
        isCurrent: () => mounted && feedback.isCurrent,
      );
      if (!mounted || !feedback.isCurrent) return;
      feedback.dismiss();
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerPage(
            state: widget.state,
            request: request,
            queue: queue,
            queueItemKey: item.vodId,
          ),
        ),
      );
    } catch (error) {
      if (!mounted || !feedback.isCurrent) return;
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      feedback.dismiss();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(failure.userMessage)));
    } finally {
      feedback.close();
      if (mounted) setState(() => _openingKey = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final browser = _browser;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => Navigator.of(context).maybePop()),
        title: Text(widget.folder.vodName),
        actions: [
          if (browser != null) ...[
            SegmentedButton<bool>(
              key: const ValueKey('folder-mode-switch'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: false,
                  icon: Icon(Icons.view_list_outlined, size: 18),
                  label: Text('文件列表'),
                ),
                ButtonSegment(
                  value: true,
                  icon: Icon(Icons.grid_view_outlined, size: 18),
                  label: Text('剧集模式'),
                ),
              ],
              selected: {_episodeMode},
              onSelectionChanged: (values) =>
                  setState(() => _episodeMode = values.single),
            ),
            const SizedBox(width: 12),
            IconButton(
              tooltip: '刷新目录',
              onPressed: browser.loading ? null : browser.load,
              icon: const Icon(Icons.refresh),
            ),
          ],
          const SizedBox(width: 8),
        ],
      ),
      body: browser == null
          ? const Center(child: Text('来源站点不可用，请返回列表重新选择。'))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        [
                          browser.site.name,
                          ...widget.ancestors,
                          widget.folder.vodName,
                        ].join(' / '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (browser.filters.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final filter in browser.filters.entries)
                              Chip(
                                label: Text('${filter.key}：${filter.value}'),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                if (browser.loading)
                  const LinearProgressIndicator(minHeight: 2),
                const Divider(height: 1),
                Expanded(child: _content(browser)),
              ],
            ),
    );
  }

  Widget _content(FolderBrowserState browser) {
    if (browser.items.isNotEmpty && _episodeMode) {
      return FolderEpisodeView(
        title: widget.folder.vodName,
        videos: _videos,
        folders: browser.items.where((item) => item.isFolder).toList(),
        controller: _episodeScroll,
        openingKey: _openingKey,
        onOpen: _open,
        footer: _footer(browser),
      );
    }
    if (browser.items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                browser.error != null
                    ? Icons.folder_off_outlined
                    : Icons.folder_open_outlined,
                size: 40,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              Text(
                browser.error != null
                    ? '目录加载失败'
                    : browser.loading
                    ? '正在加载目录…'
                    : '此目录暂无内容',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (browser.error != null) ...[
                const SizedBox(height: 8),
                Text(browser.error!.userMessage, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: browser.retry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return Scrollbar(
      controller: _scroll,
      child: ListView.builder(
        key: const ValueKey('folder-list'),
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: browser.items.length + 1,
        itemBuilder: (context, index) {
          if (index == browser.items.length) return _footer(browser);
          final item = browser.items[index];
          return ListTile(
            key: ValueKey('folder-entry-${item.vodId}'),
            leading: Icon(
              item.isFolder ? Icons.folder_outlined : Icons.movie_outlined,
              color: item.isFolder
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            title: Text(
              item.vodName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: item.vodRemarks == null
                ? null
                : Text(
                    item.vodRemarks!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
            trailing: Icon(
              item.isFolder ? Icons.chevron_right : Icons.arrow_outward,
              size: 18,
            ),
            onTap: () => _open(item),
          );
        },
      ),
    );
  }

  Widget _footer(FolderBrowserState browser) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 20),
    child: Center(
      child: browser.loading
          ? const Text('正在加载目录…')
          : browser.error != null
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  browser.failedAppend ? '下一页加载失败' : '刷新目录失败',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                TextButton.icon(
                  onPressed: browser.retry,
                  icon: const Icon(Icons.refresh),
                  label: Text(browser.failedAppend ? '重试下一页' : '重试刷新'),
                ),
              ],
            )
          : browser.hasMore
          ? TextButton(onPressed: _loadEpisodePage, child: const Text('加载更多'))
          : const Text('没有更多了'),
    ),
  );
}
