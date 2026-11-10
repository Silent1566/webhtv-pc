import 'dart:async';

import 'package:flutter/material.dart';

import '../core/epg.dart';
import '../core/protocol.dart';
import 'live_playback_session.dart';
import 'player_live_line_panel.dart';
import 'tokens.dart';

class PlayerLivePanel extends StatefulWidget {
  const PlayerLivePanel({
    super.key,
    required this.session,
    required this.onDismiss,
    required this.onLines,
    this.lineChannel,
  });

  final LivePlaybackSession session;
  final VoidCallback onDismiss;
  final ValueChanged<LiveChannel> onLines;
  final LiveChannel? lineChannel;

  @override
  State<PlayerLivePanel> createState() => _PlayerLivePanelState();
}

class _PlayerLivePanelState extends State<PlayerLivePanel> {
  final _scroll = ScrollController();
  bool _programs = false;
  bool _groupDrawer = false;
  LiveChannel? _preview;
  LiveSource? _previewSource;
  LivePlaylist? _rowPlaylist;
  final List<Object> _rows = [];
  final Map<String, int> _groupRows = {};
  String? _locatedGroup;

  @override
  void didUpdateWidget(covariant PlayerLivePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.lineChannel != oldWidget.lineChannel &&
        widget.lineChannel != null) {
      _programs = false;
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _locate(String group) {
    final index = _groupRows[group];
    if (index == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(
        (index * 64.0).clamp(0.0, _scroll.position.maxScrollExtent),
      );
    });
  }

  void _showLines(LiveChannel channel) {
    setState(() {
      _preview = channel;
      _previewSource = widget.session.browseSource;
      _programs = false;
    });
    widget.onLines(channel);
  }

  LiveChannel get _detailChannel {
    final session = widget.session;
    if (_programs) return session.channel;
    final requested = widget.lineChannel;
    if (requested != null &&
        (identical(requested, session.channel) ||
            (session.browsePlaylist?.allChannels.contains(requested) ??
                false))) {
      return requested;
    }
    if (_previewSource == session.browseSource && _preview != null) {
      return _preview!;
    }
    return session.channel;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) {
      final session = widget.session;
      final colors = Theme.of(context).colorScheme;
      return Actions(
        actions: <Type, Action<Intent>>{
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              widget.onDismiss();
              return null;
            },
          ),
        },
        child: Material(
          // 半透明：面板贴右覆盖在画面上，透过它要能看见左侧还在播什么。
          // 只用透明度、不加模糊——星等星表是平坦的场，玻璃/模糊属于装饰。
          color: colors.surfaceContainerLow.withValues(alpha: 0.90),
          elevation: 0,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.lg,
                  AppSpace.sm,
                  AppSpace.sm,
                  AppSpace.sm,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '直播源 / 频道',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: AppSpace.xs),
                          Tooltip(
                            message:
                                '${session.source.name} · ${session.channel.name}',
                            child: Text(
                              '正在播放 · ${session.source.name}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          if (session.program != null)
                            Text(
                              '回看 · ${session.program!.title}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                    if (session.program != null)
                      TextButton.icon(
                        onPressed: session.returnToLive,
                        icon: const Icon(Icons.live_tv, size: 18),
                        label: const Text('回到直播'),
                      ),
                    IconButton(
                      tooltip: '关闭直播抽屉（Esc）',
                      onPressed: widget.onDismiss,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // 面板贴右后宽度收窄（520–720），三列必须共用这点宽度：
                    // 源列固定窄栏，详情列按比例但有下限，剩下的留给频道，
                    // 保证窄面板里频道名仍有可读宽度。
                    final sourceWidth = (constraints.maxWidth * .2).clamp(
                      124.0,
                      176.0,
                    );
                    final detailWidth = (constraints.maxWidth * .36).clamp(
                      200.0,
                      280.0,
                    );
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: sourceWidth,
                          child: _buildSources(context),
                        ),
                        const VerticalDivider(width: 1),
                        Expanded(child: _buildChannels(context)),
                        const VerticalDivider(width: 1),
                        SizedBox(
                          key: const ValueKey('player-live-channel-detail'),
                          width: detailWidth,
                          child: _buildDetail(context),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _buildSources(BuildContext context) {
    final session = widget.session;
    final sources = [...session.state.liveSources];
    for (final extra in [session.source, session.browseSource]) {
      if (!sources.any(
        (source) => source.name == extra.name && source.url == extra.url,
      )) {
        sources.add(extra);
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpace.md),
          child: Text('直播源', style: Theme.of(context).textTheme.titleSmall),
        ),
        Expanded(
          child: ListView.builder(
            key: const ValueKey('player-live-source-list'),
            itemCount: sources.length,
            itemBuilder: (context, index) {
              final source = sources[index];
              final selected =
                  source.name == session.browseSource.name &&
                  source.url == session.browseSource.url;
              return Tooltip(
                message: source.name,
                child: ListTile(
                  key: ValueKey('live-panel-source-${source.name}'),
                  dense: true,
                  selected: selected,
                  selectedTileColor: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHigh,
                  leading: const Icon(Icons.playlist_play, size: 18),
                  title: Text(
                    '${source.name}${session.isPlayingSource(source) ? ' · 播放中' : ''}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: selected
                      ? Text(
                          session.browseLoading
                              ? '加载中…'
                              : session.browseError != null
                              ? '加载失败'
                              : '${session.browsePlaylist?.groups.length ?? 0} 分组 · ${session.browsePlaylist?.channelCount ?? 0} 频道',
                        )
                      : null,
                  onTap: () {
                    setState(() {
                      _preview = null;
                      _previewSource = null;
                      _programs = false;
                    });
                    unawaited(session.browse(source));
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildChannels(BuildContext context) {
    final session = widget.session;
    if (session.browseLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (session.browseError != null) {
      return _feedback(
        session.browseError!,
        '重试加载源',
        () => unawaited(session.retryBrowse()),
      );
    }
    final playlist = session.browsePlaylist;
    if (playlist == null || playlist.allChannels.isEmpty) {
      return _feedback(
        '此源没有频道',
        '重新加载',
        () => unawaited(session.retryBrowse()),
      );
    }
    _syncRows(playlist);
    if (_locatedGroup != session.browseGroup) {
      _locatedGroup = session.browseGroup;
      if (_locatedGroup != null) _locate(_locatedGroup!);
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
          child: Tooltip(
            message: '选择分组',
            child: InkWell(
              key: const ValueKey('player-live-group-toggle'),
              onTap: () => setState(() => _groupDrawer = !_groupDrawer),
              child: SizedBox(
                height: 40,
                child: Row(
                  children: [
                    Icon(
                      _groupDrawer ? Icons.folder_open : Icons.folder_outlined,
                      size: 18,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: Text(
                        _currentGroupName(playlist),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    Icon(
                      _groupDrawer ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _groupDrawer
              ? _groupListView(context, playlist)
              : _channelListView(context, playlist),
        ),
      ],
    );
  }

  void _syncRows(LivePlaylist playlist) {
    if (identical(playlist, _rowPlaylist)) return;
    _rowPlaylist = playlist;
    _rows.clear();
    _groupRows.clear();
    for (final group in playlist.groups) {
      _groupRows[group.name] = _rows.length;
      _rows.add(group);
      _rows.addAll(group.channels);
    }
    _locatedGroup = null;
  }

  String _currentGroupName(LivePlaylist playlist) {
    final group = playlist.groups
        .where((item) => item.name == widget.session.browseGroup)
        .firstOrNull;
    final resolved = group ?? playlist.groups.first;
    return '${resolved.name}（${resolved.channels.length}）';
  }

  Widget _groupListView(BuildContext context, LivePlaylist playlist) {
    final current = _currentGroupName(playlist);
    return ListView.builder(
      key: const ValueKey('player-live-group-list'),
      itemCount: playlist.groups.length,
      itemExtent: 48,
      itemBuilder: (context, index) {
        final group = playlist.groups[index];
        final selected = '${group.name}（${group.channels.length}）' == current;
        return ListTile(
          key: ValueKey('player-live-group-$index'),
          dense: true,
          selected: selected,
          selectedTileColor: Theme.of(context).colorScheme.surfaceContainerHigh,
          leading: Icon(
            selected ? Icons.folder_open : Icons.folder_outlined,
            size: 18,
          ),
          title: Text(group.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${group.channels.length} 频道'),
          onTap: () {
            setState(() => _groupDrawer = false);
            widget.session.selectGroup(group.name);
            _locate(group.name);
          },
        );
      },
    );
  }

  Widget _channelListView(BuildContext context, LivePlaylist playlist) {
    return ListView.builder(
      key: const ValueKey('player-live-channel-list'),
      controller: _scroll,
      itemExtent: 64,
      itemCount: _rows.length,
      itemBuilder: (context, index) {
        final row = _rows[index];
        if (row is LiveGroup) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.md,
              AppSpace.xl,
              AppSpace.sm,
              AppSpace.sm,
            ),
            child: Text(
              '${row.name}（${row.channels.length}）',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          );
        }
        final channel = row as LiveChannel;
        final channelIndex = playlist.allChannels.indexOf(channel);
        final selected = widget.session.isPlayingChannel(channel);
        final urls = channel.urls
            .where((url) => url.trim().isNotEmpty)
            .toList();
        return InkWell(
          key: ValueKey('live-panel-channel-$channelIndex'),
          onTap: urls.isEmpty
              ? null
              : () {
                  setState(() {
                    _preview = channel;
                    _previewSource = widget.session.browseSource;
                    _programs = false;
                  });
                  widget.session.selectChannel(channel);
                },
          onDoubleTap: selected ? () => _showLines(channel) : null,
          child: ListTile(
            dense: true,
            selected: selected,
            selectedTileColor: Theme.of(context)
                .colorScheme
                .surfaceContainerHigh,
            leading: Icon(
              selected ? Icons.play_arrow : Icons.tv,
              size: 18,
              color: selected ? Theme.of(context).colorScheme.primary : null,
            ),
            title: Tooltip(
              message: channel.name,
              child: Text(
                channel.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: selected ? AppWeight.title : AppWeight.body,
                ),
              ),
            ),
            subtitle: Text(
              urls.isEmpty
                  ? '没有可播放线路'
                  : '${urls.length} 条线路${selected ? ' · 播放中' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              key: ValueKey('live-panel-channel-lines-$channelIndex'),
              tooltip: '${channel.name}的线路',
              visualDensity: VisualDensity.compact,
              onPressed: urls.isEmpty ? null : () => _showLines(channel),
              icon: const Icon(Icons.alt_route, size: 18),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDetail(BuildContext context) => Column(
    children: [
      Row(
        children: [
          Expanded(
            child: TextButton(
              onPressed: () => setState(() => _programs = false),
              child: Text(
                '线路',
                style: TextStyle(
                  color: _programs
                      ? Theme.of(context).colorScheme.onSurfaceVariant
                      : Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ),
          Expanded(
            child: TextButton(
              onPressed: () {
                setState(() => _programs = true);
                if (widget.session.guide == null &&
                    !widget.session.guideLoading) {
                  unawaited(widget.session.loadGuide());
                }
              },
              child: Text(
                '节目单',
                style: TextStyle(
                  color: _programs
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
      const Divider(height: 1),
      Expanded(
        child: _programs
            ? _buildPrograms(context)
            : PlayerLiveLinePanel(
                session: widget.session,
                channel: _detailChannel,
                onDismiss: widget.onDismiss,
                onSelect: (index) =>
                    identical(_detailChannel, widget.session.channel)
                    ? widget.session.selectLine(index)
                    : widget.session.selectChannel(
                        _detailChannel,
                        lineIndex: index,
                      ),
              ),
      ),
    ],
  );

  Widget _buildPrograms(BuildContext context) {
    final session = widget.session;
    if (session.guideLoading) {
      return const Center(child: Text('正在加载节目单，不影响播放…'));
    }
    if (session.guideError != null) {
      return _feedback(
        session.guideError!,
        '重试节目单',
        () => unawaited(session.loadGuide(refresh: true)),
      );
    }
    if (session.programs.isEmpty) {
      return _feedback(
        '当前频道暂无节目单，不影响播放',
        '刷新节目单',
        () => unawaited(session.loadGuide(refresh: true)),
      );
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final spec = session.channel.catchup.isEmpty
        ? session.source.catchup
        : session.channel.catchup;
    return ListView.builder(
      itemCount: session.programs.length,
      itemBuilder: (context, index) {
        final program = session.programs[index];
        final current = program.isLiveAt(now);
        final finished = program.isFinishedAt(now);
        final canCatchup = finished && !spec.isEmpty;
        return ListTile(
          dense: true,
          selected: session.program == program,
          title: Text(
            program.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${formatEpgTime(program.startMs)}–${formatEpgTime(program.stopMs)} · ${current
                ? '当前播出'
                : finished
                ? '已结束'
                : '即将播出'}',
          ),
          trailing: canCatchup
              ? IconButton(
                  tooltip: '回看${program.title}',
                  onPressed: () => session.watchProgram(program),
                  icon: const Icon(Icons.replay),
                )
              : null,
          onTap: canCatchup ? () => session.watchProgram(program) : null,
        );
      },
    );
  }

  Widget _feedback(String message, String action, VoidCallback onPressed) =>
      Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                message,
                textAlign: TextAlign.center,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppSpace.md),
              OutlinedButton(onPressed: onPressed, child: Text(action)),
            ],
          ),
        ),
      );
}
