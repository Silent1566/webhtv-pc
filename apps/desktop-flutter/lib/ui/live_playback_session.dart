import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/epg.dart';
import '../core/live_catchup.dart';
import '../core/playback_request.dart';
import '../core/protocol.dart';
import '../state/app_state.dart';

class _Selection {
  const _Selection(
    this.source,
    this.playlist,
    this.channel,
    this.lineIndex,
    this.program,
  );
  final LiveSource source;
  final LivePlaylist playlist;
  final LiveChannel channel;
  final int lineIndex;
  final EpgProgram? program;
}

/// 浏览候选与播放请求分离；只有当前请求成功才提交到返回列表所读的状态。
class LivePlaybackSession extends ChangeNotifier {
  LivePlaybackSession({
    required this.state,
    required LiveSource source,
    required LivePlaylist playlist,
    required LiveChannel channel,
    int lineIndex = 0,
    EpgGuide? guide,
    EpgProgram? initialProgram,
  }) : _playing = _Selection(
         source,
         playlist,
         channel,
         _safeIndex(channel, lineIndex),
         initialProgram,
       ),
       _browseSource = source,
       _browsePlaylist = playlist,
       _browseGroup = _groupFor(playlist, channel) {
    _guide = guide;
    _target = _playing;
    _visitedSources.add(_sourceId(source));
  }

  final AppState state;
  late _Selection _target;
  _Selection _playing;
  LiveSource _browseSource;
  LivePlaylist? _browsePlaylist;
  String? _browseGroup;
  EpgGuide? _guide;
  String? browseError;
  String? guideError;
  bool browseLoading = false;
  bool guideLoading = false;
  bool _disposed = false;
  bool _targetFromFallback = false;
  int _browseGeneration = 0;
  int _guideGeneration = 0;
  int _playbackRevision = 0;
  final Set<String> _visitedSources = {};

  LiveSource get source => _playing.source;
  LivePlaylist get playlist => _playing.playlist;
  LiveChannel get channel => _playing.channel;
  int get lineIndex => _playing.lineIndex;
  EpgProgram? get program => _playing.program;
  EpgProgram? get requestProgram => _target.program;
  EpgGuide? get guide => _guide;
  LiveSource get browseSource => _browseSource;
  LivePlaylist? get browsePlaylist => _browsePlaylist;
  String? get browseGroup => _browseGroup;
  int get playbackRevision => _playbackRevision;
  List<LiveSource> get sources => [
    source,
    ...state.liveSources.where((item) => _sourceId(item) != _sourceId(source)),
  ];
  List<String> get lines => _urls(channel);
  List<LiveChannel> get browseChannels => [
    for (final group in _browsePlaylist?.groups ?? <LiveGroup>[])
      if (group.name == _browseGroup) ...group.channels,
  ];
  List<EpgProgram> get programs =>
      epgGuideForChannel(_guide, channel)?.programs ?? const [];
  bool isPlayingSource(LiveSource item) => _sourceId(item) == _sourceId(source);
  bool isPlayingChannel(LiveChannel item) =>
      isPlayingSource(_browseSource) && identical(channel, item);

  static String? _groupFor(LivePlaylist playlist, LiveChannel channel) {
    for (final group in playlist.groups) {
      if (group.channels.contains(channel)) return group.name;
    }
    return playlist.groups.firstOrNull?.name;
  }

  static List<String> _urls(LiveChannel channel) =>
      channel.urls.where((url) => url.trim().isNotEmpty).toList();
  static int _safeIndex(LiveChannel channel, int index) {
    final urls = _urls(channel);
    return urls.isEmpty ? 0 : index.clamp(0, urls.length - 1);
  }

  static String _sourceId(LiveSource source) =>
      '${source.name}\n${source.url ?? ''}';
  static String _channelKey(String name) => name
      .toUpperCase()
      .replaceAll(
        RegExp(r'(?:[\s\-_]*(?:UHD|FHD|HD|SD|4K|8K|超高清|高清|标清))+$'),
        '',
      )
      .replaceAll(RegExp(r'[\s\-_]'), '');

  PlaybackRequest get request => _requestFor(_target);
  PlaybackRequest _requestFor(_Selection selection) {
    final channel = selection.channel;
    final urls = _urls(channel);
    final index = selection.lineIndex;
    final liveUrl = urls.isEmpty ? '' : urls[index];
    final program = selection.program;
    final spec = channel.catchup.isEmpty
        ? selection.source.catchup
        : channel.catchup;
    final url = program == null
        ? liveUrl
        : formatCatchupUrl(
                spec: spec,
                channelUrl: liveUrl,
                startMs: program.startMs,
                endMs: program.stopMs,
              ) ??
              '';
    final flag = program == null ? '直播线路' : '回看';
    return PlaybackRequest(
      url: url,
      title: program == null
          ? channel.name
          : '${channel.name} · ${program.title}',
      siteKey: selection.source.name,
      vodId: channel.name,
      vodName: channel.name,
      episodeName: program?.title ?? channel.name,
      flag: flag,
      headers: channel.header.asRequestHeaders,
      playLines: [
        VodPlayLine(
          flag: flag,
          episodes: program == null
              ? [
                  for (final (i, url) in urls.indexed)
                    VodEpisode(name: '线路 ${i + 1}', url: url),
                ]
              : [VodEpisode(name: program.title, url: url)],
        ),
      ],
      episodeIndex: program == null ? index : 0,
      directUrl: true,
    );
  }

  Future<void> browse(LiveSource source, {bool refresh = false}) async {
    if (_disposed) return;
    final generation = ++_browseGeneration;
    _browseSource = source;
    _browsePlaylist = isPlayingSource(source) ? playlist : null;
    _browseGroup = _browsePlaylist == null
        ? null
        : _groupFor(_browsePlaylist!, channel);
    browseError = null;
    if (_browsePlaylist != null && !refresh) {
      browseLoading = false;
      notifyListeners();
      return;
    }
    browseLoading = true;
    notifyListeners();
    try {
      final result = await state.liveService.load(source, useCache: !refresh);
      if (_disposed || generation != _browseGeneration) return;
      _browsePlaylist = result.playlist;
      _browseGroup = result.playlist.groups.firstOrNull?.name;
    } catch (error) {
      if (_disposed || generation != _browseGeneration) return;
      browseError = '源加载失败：$error';
    }
    if (_disposed || generation != _browseGeneration) return;
    browseLoading = false;
    notifyListeners();
  }

  Future<void> retryBrowse() => browse(_browseSource, refresh: true);
  void selectGroup(String group) {
    if (_disposed ||
        !(_browsePlaylist?.groups.any((item) => item.name == group) ?? false)) {
      return;
    }
    _browseGroup = group;
    notifyListeners();
  }

  bool selectChannel(LiveChannel channel, {int lineIndex = 0}) {
    final playlist = _browsePlaylist;
    if (_disposed ||
        playlist == null ||
        !playlist.allChannels.contains(channel)) {
      return false;
    }
    final urls = _urls(channel);
    if (lineIndex < 0 || lineIndex >= urls.length) return false;
    _setTarget(_Selection(_browseSource, playlist, channel, lineIndex, null));
    return true;
  }

  bool selectLine(int index) {
    if (_disposed || index < 0 || index >= lines.length) return false;
    _setTarget(_Selection(source, playlist, channel, index, null));
    return true;
  }

  bool stepChannel(int delta) {
    final target = _target;
    final channels = target.playlist.allChannels
        .where((item) => _urls(item).isNotEmpty)
        .toList();
    if (_disposed || channels.isEmpty) return false;
    final index = channels.indexOf(target.channel);
    final next = channels[(index + delta) % channels.length];
    _setTarget(_Selection(target.source, target.playlist, next, 0, null));
    return true;
  }

  bool watchProgram(EpgProgram program) {
    if (_disposed ||
        !program.isFinishedAt(DateTime.now().millisecondsSinceEpoch)) {
      return false;
    }
    final selection = _Selection(source, playlist, channel, lineIndex, program);
    if (_requestFor(selection).url.isEmpty) return false;
    _setTarget(selection);
    return true;
  }

  bool returnToLive() {
    if (_disposed || lines.isEmpty) return false;
    _setTarget(_Selection(source, playlist, channel, lineIndex, null));
    return true;
  }

  void _setTarget(_Selection selection, {bool fallback = false}) {
    _target = selection;
    _targetFromFallback = fallback;
    if (!fallback) _visitedSources.clear();
    _visitedSources.add(_sourceId(selection.source));
    _playbackRevision++;
    notifyListeners();
  }

  /// 外部播放器只在 open 成功且 revision 仍有效时调用。
  void confirmPlayback(int revision) {
    if (_disposed || revision != _playbackRevision) return;
    final changedSource = _sourceId(source) != _sourceId(_target.source);
    _playing = _target;
    if (_targetFromFallback) {
      _browseGeneration++;
      _browseSource = source;
      _browsePlaylist = playlist;
      _browseGroup = _groupFor(playlist, channel);
      browseLoading = false;
      browseError = null;
    }
    if (changedSource) {
      _guideGeneration++;
      guideLoading = false;
      _guide = null;
      guideError = null;
    }
    notifyListeners();
    if (changedSource || _guide == null) unawaited(loadGuide());
  }

  Future<void> loadGuide({bool refresh = false}) async {
    if (_disposed) return;
    final generation = ++_guideGeneration;
    final selection = _playing;
    final url = (playlist.epg?.trim().isNotEmpty ?? false)
        ? playlist.epg!
        : source.epg ?? '';
    if (url.isEmpty) {
      guideLoading = false;
      guideError = null;
      notifyListeners();
      return;
    }
    guideLoading = true;
    guideError = null;
    notifyListeners();
    try {
      final result = await state.epgService.load(
        url: url,
        liveChannels: selection.playlist.allChannels,
        sourceName: selection.source.name,
        forceRefresh: refresh,
      );
      if (_disposed ||
          generation != _guideGeneration ||
          _sourceId(source) != _sourceId(selection.source)) {
        return;
      }
      _guide = result.guide;
    } catch (error) {
      if (_disposed ||
          generation != _guideGeneration ||
          _sourceId(source) != _sourceId(selection.source)) {
        return;
      }
      guideError = describeEpgFailure(error);
    }
    guideLoading = false;
    notifyListeners();
  }

  Future<bool> fallback({
    required bool changeLine,
    required bool sourceFallback,
  }) async {
    if (_disposed || !changeLine || _target.program != null) return false;
    final target = _target;
    final revision = _playbackRevision;
    final urls = _urls(target.channel);
    if (target.lineIndex + 1 < urls.length) {
      _setTarget(
        _Selection(
          target.source,
          target.playlist,
          target.channel,
          target.lineIndex + 1,
          null,
        ),
        fallback: true,
      );
      return true;
    }
    if (!sourceFallback) return false;
    for (final source in state.liveSources) {
      if (!_visitedSources.add(_sourceId(source))) continue;
      try {
        final result = await state.liveService.load(source);
        if (_disposed || revision != _playbackRevision) return false;
        final matches = result.playlist.allChannels.where(
          (item) =>
              _channelKey(item.name) == _channelKey(target.channel.name) &&
              _urls(item).isNotEmpty,
        );
        if (matches.isEmpty) continue;
        _setTarget(
          _Selection(source, result.playlist, matches.first, 0, null),
          fallback: true,
        );
        return true;
      } catch (_) {
        if (_disposed || revision != _playbackRevision) return false;
      }
    }
    return false;
  }

  @override
  void dispose() {
    _disposed = true;
    _browseGeneration++;
    _guideGeneration++;
    super.dispose();
  }
}
