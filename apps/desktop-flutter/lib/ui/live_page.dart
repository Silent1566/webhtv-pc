/// 直播页：直播源 → 分组 → 频道 → 播放（设计文档 §13、§17.2）。
///
/// 设计要点：
/// - 左侧列出配置声明的直播源（§7.1 `lives`）与分组/频道树；
/// - 频道有多条线路时，右侧提供线路选择；播放失败自动按顺序切线路（§13.3）；
/// - 单个直播源加载失败只影响该源，不阻塞其他源（§14.3）；
/// - EPG（§13.1、§13.3「可加载、刷新、显示当前节目」）：从清单的 `url-tvg`
///   （或直播源 `epg` 字段）拉取 XMLTV，列表显示当前节目、详情显示节目单；
/// - **EPG 失败只提示，不影响直播播放**（EPG 是增强项，不是播放前置条件）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_error.dart';
import '../core/epg.dart';
import '../core/live_catchup.dart';
import '../core/protocol.dart';
import '../services/live_service.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'image_header_scope.dart';
import 'player_page.dart';
import 'tokens.dart';
import 'toast.dart';

class LivePage extends StatefulWidget {
  const LivePage({super.key, required this.state, this.clock});

  final AppState state;

  /// 「现在」的取时函数（§13.3 当前节目判定）；测试注入固定时钟，
  /// 否则用系统时间。
  final DateTime Function()? clock;

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

  /// 已加载的节目单（按 EPG 地址缓存；同一地址只拉一次）。
  final Map<String, EpgGuide> _guides = {};

  /// 正在加载/失败的 EPG 地址（失败只提示，不影响直播）。
  final Set<String> _guideLoading = {};
  final Map<String, AppError> _guideErrors = {};

  /// 「现在」的滑动时刻，用于当前节目判定；EPG 刷新时推进一次。
  late int _nowMs;

  int _readNow() =>
      (widget.clock ?? DateTime.now)().millisecondsSinceEpoch;

  String? _selectedSourceName;

  AppState get _state => widget.state;

  List<LiveSource> get _sources => _state.liveSources;

  @override
  void initState() {
    super.initState();
    _nowMs = _readNow();
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
      // EPG 地址：清单 `url-tvg` 优先，其次直播源 `epg` 字段（§13.1）。
      unawaited(_loadGuideFor(result, refresh: refresh));
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

  /// EPG 地址：清单 `url-tvg`（M3U）优先，其次直播源声明的 `epg`。
  static String? _epgUrlFor(LiveLoadResult result) {
    final fromList = result.playlist.epg?.trim() ?? '';
    if (fromList.isNotEmpty) return fromList;
    final fromSource = result.source.epg?.trim() ?? '';
    return fromSource.isEmpty ? null : fromSource;
  }

  /// 加载某直播源对应的 EPG。
  ///
  /// 失败只记录到 `_guideErrors` 并写日志，**不抛出、不影响频道列表与播放**（§13.3）。
  Future<void> _loadGuideFor(
    LiveLoadResult result, {
    bool refresh = false,
  }) async {
    final url = _epgUrlFor(result);
    if (url == null) return;
    if (!refresh && _guides.containsKey(url)) return;
    if (_guideLoading.contains(url)) return;

    setState(() {
      _guideLoading.add(url);
      _guideErrors.remove(url);
    });
    try {
      final loaded = await _state.epgService.load(
        url: url,
        liveChannels: result.playlist.allChannels,
        sourceName: result.source.name,
        forceRefresh: refresh,
      );
      if (!mounted) return;
      setState(() {
        _guides[url] = loaded.guide;
        _guideLoading.remove(url);
        _nowMs = _readNow();
      });
      _state.log.info('EPG 已加载 ${loaded.logLine}', scope: 'live');
    } catch (error) {
      // 捕获所有错误类型：EPG 的任何失败都不能升级为直播失败（§13.3）。
      final normalized = error is AppError
          ? error
          : AppError(
              AppErrorKind.epgNetwork,
              'EPG 加载失败：$error',
              detail: redactUrl(url),
              cause: error,
            );
      if (!mounted) return;
      setState(() {
        _guideLoading.remove(url);
        _guideErrors[url] = normalized;
      });
      _state.log.error(
        'EPG 加载失败（不影响直播）url=${redactUrl(url)} '
        '${normalized.logLine}',
        scope: 'live',
      );
    }
  }

  /// 当前源对应的节目单（未加载或失败时为 null）。
  EpgGuide? _guideForSource(LiveLoadResult? result) {
    final url = result == null ? null : _epgUrlFor(result);
    return url == null ? null : _guides[url];
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
          onLiveSourceFallback: () => _fallbackSourceRequest(channel),
        ),
      ),
    );
  }

  /// 源级回退：在其他已加载/可加载的直播源里找同名频道。
  ///
  /// 归一化只去掉常见清晰度后缀与标点，不做模糊匹配——宁可找不到，
  /// 也不要把「CCTV5」切到「CCTV5+」。
  Future<PlaybackRequest?> _fallbackSourceRequest(LiveChannel channel) async {
    if (!_state.liveSettings.sourceFallback) return null;
    final current = _selectedSourceName;
    for (final source in _sources) {
      if (source.name == current) continue;
      var result = _states[source.name]?.result;
      if (result == null) {
        try {
          result = await _state.liveService.load(source);
          if (!mounted) return null;
          setState(() {
            _states[source.name] = _SourceState(result: result);
          });
        } catch (error) {
          _state.log.warning(
            '回退源加载失败 name=${source.name} $error',
            scope: 'live',
          );
          continue;
        }
      }
      final match = _findChannel(result.playlist, channel.name);
      if (match == null) continue;
      setState(() => _preview = match);
      return LivePage.requestForChannel(match, sourceName: source.name);
    }
    return null;
  }

  LiveChannel? _findChannel(LivePlaylist playlist, String name) {
    final target = _normalizeChannelName(name);
    if (target.isEmpty) return null;
    for (final group in playlist.groups) {
      for (final channel in group.channels) {
        if (channel.urls.isEmpty) continue;
        if (_normalizeChannelName(channel.name) == target) return channel;
      }
    }
    return null;
  }

  String _normalizeChannelName(String raw) {
    var text = raw.trim().toLowerCase();
    text = text.replaceAll(RegExp(r'[（(][^)）]*[)）]'), '');
    text = text.replaceAll(
      RegExp(r'高清|超清|蓝光|4k|8k|hd|fhd|uhd|频道'),
      '',
    );
    return text.replaceAll(RegExp(r'[^0-9a-z一-鿿]'), '');
  }

  /// 回看：用节目单的起止时间 + catchup 模板生成地址。
  ///
  /// 没有 catchup 参数时不生成地址（入口本身也不显示）。
  Future<void> _playCatchup(LiveChannel channel, EpgProgram program) async {
    final source = _sources.firstWhere(
      (item) => item.name == _selectedSourceName,
      orElse: () => _sources.first,
    );
    final spec = channel.catchup.isEmpty ? source.catchup : channel.catchup;
    final channelUrl = channel.urls.isEmpty ? '' : channel.urls.first;
    final url = formatCatchupUrl(
      spec: spec,
      channelUrl: channelUrl,
      startMs: program.startMs,
      endMs: program.stopMs,
    );
    if (url == null) {
      if (!mounted) return;
      showToast('该节目无法回看：回看参数不完整', kind: ToastKind.error);
      _state.log.warning(
        '回看地址生成失败 channel=${channel.name} program=${program.title}',
        scope: 'live',
      );
      return;
    }
    _state.log.info(
      '回看 channel=${channel.name} program=${program.title} '
      'url=${redactUrl(url)}',
      scope: 'live',
    );
    final request = PlaybackRequest(
      url: url,
      title: '${channel.name} · ${program.title}',
      siteKey: source.name,
      vodId: channel.name,
      vodName: channel.name,
      episodeName: program.title,
      flag: '回看',
      playLines: [
        VodPlayLine(
          flag: '回看',
          episodes: [VodEpisode(name: program.title, url: url)],
        ),
      ],
      headers: channel.header.toJson().map(
        (key, value) => MapEntry(key, value.toString()),
      ),
      directUrl: true,
    );
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(state: _state, request: request),
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
    final result = state?.result;
    final guideUrl = result == null ? null : _epgUrlFor(result);
    final guide = _guideForSource(result);
    final guideLoading = guideUrl != null && _guideLoading.contains(guideUrl);
    final guideError = guideUrl == null ? null : _guideErrors[guideUrl];

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
            null => const LoadingBlock(),
            _SourceState(loading: true) =>
              const LoadingBlock(),
            _SourceState(error: final error?) => _LiveErrorView(
              error: error,
              onRetry: () => unawaitedLoad(selected, refresh: true),
            ),
            _SourceState(result: final result?) => _PlaylistView(
              playlist: result.playlist,
              guide: guide,
              nowMs: _nowMs,
              epgLoading: guideLoading,
              epgError: guideError,
              onRefreshEpg: guideUrl == null
                  ? null
                  : () => unawaited(
                      _loadGuideFor(result, refresh: true),
                    ),
              preview: _preview,
              onPreview: (channel) => setState(() => _preview = channel),
              onPlay: _play,
              defaultCatchup: selected.catchup,
              onCatchup: _playCatchup,
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
                        child: LoadingBlock(center: false),
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
    required this.guide,
    required this.nowMs,
    required this.epgLoading,
    required this.epgError,
    required this.onRefreshEpg,
    required this.preview,
    required this.onPreview,
    required this.onPlay,
    required this.defaultCatchup,
    required this.onCatchup,
  });

  final LivePlaylist playlist;

  /// 当前源的节目单；未加载/无 EPG 地址时为 null。
  final EpgGuide? guide;
  final int nowMs;
  final bool epgLoading;

  /// EPG 加载失败（只提示，不影响直播，§13.3）。
  final AppError? epgError;

  /// 刷新 EPG（null 表示该源没有 EPG 地址）。
  final VoidCallback? onRefreshEpg;

  final LiveChannel? preview;
  final ValueChanged<LiveChannel> onPreview;
  final void Function(LiveChannel channel, {int startLine}) onPlay;

  /// 源级默认回看参数（频道未声明时继承）。
  final CatchupSpec defaultCatchup;
  final void Function(LiveChannel channel, EpgProgram program) onCatchup;

  @override
  Widget build(BuildContext context) {
    if (playlist.groups.isEmpty) {
      return const EmptyState(
        icon: Icons.tv_off_outlined,
        title: '该直播源没有解析出任何频道',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _EpgStatusBar(
          guide: guide,
          loading: epgLoading,
          error: epgError,
          sourceDeclared: playlist.epg != null || onRefreshEpg != null,
          onRefresh: onRefreshEpg,
        ),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 3,
                child: ListView(
                  children: [
                    for (final group in playlist.groups)
                      _GroupSection(
                        group: group,
                        guide: guide,
                        nowMs: nowMs,
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
                    guide: guide,
                    nowMs: nowMs,
                    onPlay: (index) => onPlay(preview!, startLine: index),
                    catchup: preview!.catchup.isEmpty
                        ? defaultCatchup
                        : preview!.catchup,
                    onCatchup: (program) => onCatchup(preview!, program),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// EPG 状态条：节目单概况 + 刷新入口；失败只提示不影响播放。
class _EpgStatusBar extends StatelessWidget {
  const _EpgStatusBar({
    required this.guide,
    required this.loading,
    required this.error,
    required this.sourceDeclared,
    required this.onRefresh,
  });

  final EpgGuide? guide;
  final bool loading;
  final AppError? error;
  final bool sourceDeclared;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final guide = this.guide;
    final error = this.error;

    final (IconData icon, String text) = switch ((error, guide)) {
      (final AppError failed, _) => (
        Icons.info_outline,
        describeEpgFailure(failed),
      ),
      (_, final EpgGuide loaded) => (
        Icons.event_available,
        '节目单：${loaded.totalPrograms} 条 '
            '(${loaded.channels.length} 个频道)',
      ),
      _ when loading => (Icons.hourglass_empty, '节目单加载中…'),
      _ when sourceDeclared => (
        Icons.event_busy,
        '该直播源声明了 EPG 地址，暂未加载',
      ),
      _ => (Icons.event_busy, '该直播源未声明 EPG 地址'),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (loading)
            const SizedBox(
              width: 14,
              height: 14,
              child: LoadingBlock(center: false),
            )
          else
            IconButton(
              tooltip: '刷新节目单',
              icon: const Icon(Icons.event_repeat, size: 18),
              onPressed: onRefresh,
            ),
        ],
      ),
    );
  }
}

class _GroupSection extends StatelessWidget {
  const _GroupSection({
    required this.group,
    required this.guide,
    required this.nowMs,
    required this.preview,
    required this.onPreview,
    required this.onPlay,
  });

  final LiveGroup group;
  final EpgGuide? guide;
  final int nowMs;
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
                    // 频道图标也是外部图片：按 host 注入顶层 `headers` 规则（§7.4.6）。
                    headers: imageHeadersOrNull(context, channel.logo!),
                    errorBuilder: (_, _, _) => const Icon(Icons.live_tv, size: 18),
                  )
                : const Icon(Icons.live_tv, size: 18),
            title: Text(channel.name, overflow: TextOverflow.ellipsis),
            subtitle: _ChannelSubtitle(
              channel: channel,
              nowLabel: epgNowLabel(guide, channel, nowMs),
            ),
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

/// 频道行副标题：频道号 + 当前/下一节目（§13.3「显示当前节目」）。
class _ChannelSubtitle extends StatelessWidget {
  const _ChannelSubtitle({required this.channel, required this.nowLabel});

  final LiveChannel channel;
  final String? nowLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final number = channel.number;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (number != null)
          Text('频道 $number', style: theme.textTheme.bodySmall),
        if (nowLabel != null)
          Text(
            nowLabel!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );
  }
}

/// 频道线路列表（多线路逐个可选，§13.3）。
class _ChannelDetail extends StatelessWidget {
  const _ChannelDetail({
    required this.channel,
    required this.guide,
    required this.nowMs,
    required this.onPlay,
    required this.catchup,
    required this.onCatchup,
  });

  final LiveChannel channel;
  final EpgGuide? guide;
  final int nowMs;
  final ValueChanged<int> onPlay;

  /// 生效的回看参数（频道级优先，源级兜底）。
  final CatchupSpec catchup;
  final ValueChanged<EpgProgram> onCatchup;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final channelGuide = epgGuideForChannel(guide, channel);
    final programs = channelGuide?.programs ?? const <EpgProgram>[];

    final header = Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(channel.name, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '${channel.group} · ${channel.urls.length} 条线路',
            style: theme.textTheme.bodySmall,
          ),
          if (channel.epgId != null)
            Text(
              'EPG: ${channel.epgId}',
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
    );

    // 无节目单时保持原样，只列线路（不凭空多出一个空 tab）。
    if (programs.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const Divider(height: 1),
          Expanded(child: _LineList(channel: channel, onPlay: onPlay)),
        ],
      );
    }

    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const TabBar(
            isScrollable: false,
            labelStyle: TextStyle(fontSize: 13),
            tabs: [
              Tab(height: 34, text: '节目单'),
              Tab(height: 34, text: '线路'),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: TabBarView(
              children: [
                _ProgramList(
                  programs: programs,
                  nowMs: nowMs,
                  catchup: catchup,
                  onCatchup: onCatchup,
                ),
                _LineList(channel: channel, onPlay: onPlay),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 节目单列表：当前节目高亮，已播出置灰（§13.3「显示当前节目」）。
class _ProgramList extends StatelessWidget {
  const _ProgramList({
    required this.programs,
    required this.nowMs,
    required this.catchup,
    required this.onCatchup,
  });

  final List<EpgProgram> programs;
  final int nowMs;
  final CatchupSpec catchup;
  final ValueChanged<EpgProgram> onCatchup;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView.builder(
      itemCount: programs.length,
      itemBuilder: (context, index) {
        final program = programs[index];
        final live = program.isLiveAt(nowMs);
        final finished = program.isFinishedAt(nowMs);
        final color = live
            ? theme.colorScheme.primary
            : finished
            ? theme.textTheme.bodySmall?.color
            : null;
        final canCatchup = finished && !catchup.isEmpty;
        return ListTile(
          dense: true,
          selected: live,
          leading: live
              ? Icon(Icons.play_circle_fill, size: 18, color: color)
              : null,
          trailing: canCatchup
              ? IconButton(
                  tooltip: '回看 ${program.title}',
                  icon: const Icon(Icons.replay, size: 18),
                  onPressed: () => onCatchup(program),
                )
              : null,
          onTap: canCatchup ? () => onCatchup(program) : null,
          title: Text(
            program.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: color,
              fontWeight: live ? FontWeight.w600 : null,
            ),
          ),
          subtitle: Text(
            '${formatEpgTime(program.startMs)}-${formatEpgTime(program.stopMs)}',
            style: theme.textTheme.bodySmall,
          ),
        );
      },
    );
  }
}

/// 频道线路列表（多线路逐个可选，§13.3）。
class _LineList extends StatelessWidget {
  const _LineList({required this.channel, required this.onPlay});

  final LiveChannel channel;
  final ValueChanged<int> onPlay;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
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
    );
  }
}

class _LiveErrorView extends StatelessWidget {
  const _LiveErrorView({required this.error, required this.onRetry});

  final AppError error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 错误图标必须承载**错误色相**：原来不给颜色，走框架默认的
            // `onSurface`，于是错误态看起来和普通空态一样，
            // 看不出"这里出事了"（与 `_EmptyHint` 曾经用框架灰是同类问题）。
            Icon(
              Icons.error_outline,
              size: 32,
              color: context.semanticColors.statusFailed,
            ),
            const SizedBox(height: AppSpace.md),
            Text(
              error.userMessage,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpace.md),
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
    return const EmptyState(
      icon: Icons.live_tv_outlined,
      title: '当前配置没有直播源',
      message: '在配置里添加 lives 字段（M3U/TXT/JSON），或导入包含直播源的配置。',
    );
  }
}
