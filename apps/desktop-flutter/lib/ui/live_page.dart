/// 直播页：直播源 → 分组 → 频道 → 播放（设计文档 §13、§17.2）。
///
/// 设计要点：
/// - 左侧列出配置声明的直播源（§7.1 `lives`）与分组/频道树；
/// - 频道有多条线路时，右侧提供线路选择；播放失败自动按顺序切线路（§13.3）；
/// - 单个直播源加载失败只影响该源，不阻塞其他源（§14.3）；
/// - 未配置直播源时给出可定位的空态说明，而不是空白页面。
library;

import 'package:flutter/material.dart';

import '../core/app_error.dart';
import '../core/protocol.dart';
import '../services/live_service.dart';
import '../state/app_state.dart';
import 'player_page.dart';

class LivePage extends StatefulWidget {
  const LivePage({super.key, required this.state});

  final AppState state;

  /// 由频道构造直播播放请求（可独立测试；§13.3 多线路映射）。
  ///
  /// 直播地址本身即最终地址，因此请求标记 `directUrl`，跳过站点解析（§13.3）。
  static PlaybackRequest requestForChannel(
    LiveChannel channel, {
    required String sourceName,
    int startLine = 0,
  }) {
    final urls = channel.urls.where((url) => url.trim().isNotEmpty).toList();
    final safeStart = urls.isEmpty ? 0 : startLine.clamp(0, urls.length - 1);
    final lines = [
      VodPlayLine(
        flag: '直播线路',
        episodes: [
          for (final (index, url) in urls.indexed)
            VodEpisode(name: '线路 ${index + 1}', url: url),
        ],
      ),
    ];
    return PlaybackRequest(
      url: urls.isEmpty ? '' : urls[safeStart],
      title: channel.name,
      siteKey: sourceName,
      vodId: channel.name,
      vodName: channel.name,
      episodeName: channel.name,
      flag: '直播线路',
      // 频道级 Header（M3U #EXTVLCOPT / TXT url|header）必须随直链一起注入，
      // 否则需鉴权的直播线路会因缺 Header 无法播放（§13.1 直播 Header）。
      headers: channel.header.asRequestHeaders,
      playLines: lines,
      episodeIndex: safeStart,
      directUrl: true,
    );
  }

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  /// 每个直播源的加载状态：进行中 / 成功 / 失败（错误对象化，§8.4）。
  final Map<String, _SourceState> _states = {};

  /// 当前预览的频道（未即点即播时展示线路列表）。
  LiveChannel? _preview;

  String? _selectedSourceName;

  AppState get _state => widget.state;

  List<LiveSource> get _sources => _state.liveSources;

  @override
  void initState() {
    super.initState();
    // 只在有直播源时预加载第一个（避免无谓网络请求）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_sources.isNotEmpty) {
        final first = _sources.first;
        _selectedSourceName ??= first.name;
        unawaitedLoad(first);
      }
    });
  }

  /// 加载指定直播源（带缓存；失败只记录到该源的状态）。
  Future<void> unawaitedLoad(LiveSource source, {bool refresh = false}) async {
    setState(() {
      _states[source.name] = _SourceState(loading: true);
    });
    try {
      final result = await _state.liveService.load(source, useCache: !refresh);
      if (!mounted) return;
      setState(() {
        _states[source.name] = _SourceState(result: result);
      });
      _state.log.info(
        '直播源已加载 name=${source.name} channels=${result.playlist.channelCount} '
        'groups=${result.playlist.groups.length} '
        'cache=${result.fromCache} elapsed=${result.latency.inMilliseconds}ms',
        scope: 'live',
      );
    } on AppError catch (error) {
      if (!mounted) return;
      setState(() {
        _states[source.name] = _SourceState(error: error);
      });
      _state.log.error(
        '直播源加载失败 name=${source.name} ${error.logLine}',
        scope: 'live',
      );
    }
  }

  /// 打开一个频道的播放器；多线路映射为播放器的线路列表。
  ///
  /// 直播地址本身即最终地址，因此请求标记 `directUrl`，跳过站点解析（§13.3）。
  Future<void> _play(LiveChannel channel, {int startLine = 0}) async {
    final urls = channel.urls.where((url) => url.trim().isNotEmpty).toList();
    if (urls.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          state: _state,
          request: LivePage.requestForChannel(
            channel,
            sourceName: _selectedSourceName ?? 'live',
            startLine: startLine,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sources = _sources;
    if (sources.isEmpty) {
      return const _LiveEmptyState();
    }

    final selected = sources.firstWhere(
      (source) => source.name == _selectedSourceName,
      orElse: () => sources.first,
    );
    _selectedSourceName = selected.name;
    final state = _states[selected.name];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 260,
          child: _SourceList(
            sources: sources,
            selected: selected,
            states: _states,
            onSelect: (source) {
              setState(() {
                _selectedSourceName = source.name;
                _preview = null;
              });
              if (_states[source.name]?.result == null) unawaitedLoad(source);
            },
            onRefresh: () => unawaitedLoad(selected, refresh: true),
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: switch (state) {
            null => const Center(child: CircularProgressIndicator()),
            _SourceState(loading: true) =>
              const Center(child: CircularProgressIndicator()),
            _SourceState(error: final error?) => _LiveErrorView(
              error: error,
              onRetry: () => unawaitedLoad(selected, refresh: true),
            ),
            _SourceState(result: final result?) => _PlaylistView(
              playlist: result.playlist,
              preview: _preview,
              onPreview: (channel) => setState(() => _preview = channel),
              onPlay: _play,
            ),
            _ => const SizedBox.shrink(),
          },
        ),
      ],
    );
  }
}

/// 单个直播源的加载状态。
class _SourceState {
  const _SourceState({this.loading = false, this.result, this.error});

  final bool loading;
  final LiveLoadResult? result;
  final AppError? error;
}

/// 左侧直播源列表。
class _SourceList extends StatelessWidget {
  const _SourceList({
    required this.sources,
    required this.selected,
    required this.states,
    required this.onSelect,
    required this.onRefresh,
  });

  final List<LiveSource> sources;
  final LiveSource selected;
  final Map<String, _SourceState> states;
  final ValueChanged<LiveSource> onSelect;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 8, 4),
          child: Row(
            children: [
              Text('直播源', style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              IconButton(
                tooltip: '刷新当前直播源',
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: onRefresh,
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: sources.length,
            itemBuilder: (context, index) {
              final source = sources[index];
              final state = states[source.name];
              final selectedHere = source.name == selected.name;
              return ListTile(
                dense: true,
                selected: selectedHere,
                leading: Icon(_iconForType(source.type), size: 18),
                title: Text(source.name, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  _subtitleFor(state),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                trailing: state?.loading == true
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onTap: () => onSelect(source),
              );
            },
          ),
        ),
      ],
    );
  }

  static IconData _iconForType(int type) => switch (type) {
    LiveLineType.json => Icons.data_object,
    LiveLineType.txt => Icons.article_outlined,
    _ => Icons.playlist_play,
  };

  static String _subtitleFor(_SourceState? state) {
    if (state == null) return '未加载';
    if (state.loading) return '加载中…';
    final error = state.error;
    if (error != null) return error.message;
    final result = state.result;
    if (result != null) {
      return '${result.playlist.groups.length} 分组 · '
          '${result.playlist.channelCount} 频道'
          '${result.fromCache ? " · 缓存" : ""}';
    }
    return '未加载';
  }
}

/// 右侧：分组/频道树 + 频道线路预览。
class _PlaylistView extends StatelessWidget {
  const _PlaylistView({
    required this.playlist,
    required this.preview,
    required this.onPreview,
    required this.onPlay,
  });

  final LivePlaylist playlist;
  final LiveChannel? preview;
  final ValueChanged<LiveChannel> onPreview;
  final void Function(LiveChannel channel, {int startLine}) onPlay;

  @override
  Widget build(BuildContext context) {
    if (playlist.groups.isEmpty) {
      return const Center(child: Text('该直播源没有解析出任何频道'));
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 3,
          child: ListView(
            children: [
              for (final group in playlist.groups)
                _GroupSection(
                  group: group,
                  preview: preview,
                  onPreview: onPreview,
                  onPlay: onPlay,
                ),
            ],
          ),
        ),
        if (preview != null && preview!.urls.isNotEmpty) ...[
          const VerticalDivider(width: 1),
          SizedBox(
            width: 340,
            child: _ChannelDetail(
              channel: preview!,
              onPlay: (index) => onPlay(preview!, startLine: index),
            ),
          ),
        ],
      ],
    );
  }
}

class _GroupSection extends StatelessWidget {
  const _GroupSection({
    required this.group,
    required this.preview,
    required this.onPreview,
    required this.onPlay,
  });

  final LiveGroup group;
  final LiveChannel? preview;
  final ValueChanged<LiveChannel> onPreview;
  final void Function(LiveChannel channel, {int startLine}) onPlay;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      initiallyExpanded: true,
      title: Text('${group.name}（${group.channels.length}）'),
      children: [
        for (final channel in group.channels)
          ListTile(
            dense: true,
            selected: identical(channel, preview),
            leading: channel.logo != null && channel.logo!.isNotEmpty
                ? Image.network(
                    channel.logo!,
                    width: 28,
                    height: 20,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Icon(Icons.live_tv, size: 18),
                  )
                : const Icon(Icons.live_tv, size: 18),
            title: Text(channel.name, overflow: TextOverflow.ellipsis),
            subtitle: channel.number == null
                ? null
                : Text('频道 ${channel.number}'),
            trailing: channel.urls.isEmpty
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (channel.urls.length > 1)
                        Text('${channel.urls.length} 线路'),
                      IconButton(
                        tooltip: '播放 ${channel.name}',
                        icon: const Icon(Icons.play_arrow, size: 18),
                        onPressed: () => onPlay(channel),
                      ),
                    ],
                  ),
            onTap: () => onPreview(channel),
          ),
      ],
    );
  }
}

/// 频道线路列表（多线路逐个可选，§13.3）。
class _ChannelDetail extends StatelessWidget {
  const _ChannelDetail({required this.channel, required this.onPlay});

  final LiveChannel channel;
  final ValueChanged<int> onPlay;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(channel.name, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                '${channel.group} · ${channel.urls.length} 条线路',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (channel.epgId != null)
                Text('EPG: ${channel.epgId}', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            itemCount: channel.urls.length,
            itemBuilder: (context, index) => ListTile(
              dense: true,
              leading: CircleAvatar(
                radius: 12,
                child: Text('${index + 1}', style: const TextStyle(fontSize: 11)),
              ),
              title: Text(
                channel.urls[index],
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              trailing: const Icon(Icons.play_arrow, size: 18),
              onTap: () => onPlay(index),
            ),
          ),
        ),
      ],
    );
  }
}

class _LiveErrorView extends StatelessWidget {
  const _LiveErrorView({required this.error, required this.onRetry});

  final AppError error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 32),
            const SizedBox(height: 12),
            Text(error.userMessage, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveEmptyState extends StatelessWidget {
  const _LiveEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.live_tv_outlined, size: 36),
            const SizedBox(height: 12),
            Text(
              '当前配置没有直播源',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            const Text(
              '在配置里添加 lives 字段（M3U/TXT/JSON），或导入包含直播源的配置。',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
