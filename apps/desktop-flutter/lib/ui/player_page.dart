/// 播放器页（§17.3）。
///
/// 包含：播放器画面、标题、线路选择、剧集列表、播放/暂停、进度条、音量、倍速、
/// 全屏、上一集/下一集、加载状态、错误提示，以及键盘快捷键（§10.3、§17.4）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_error.dart';
import '../core/protocol.dart';
import '../state/app_state.dart';
import 'app.dart';
import 'player_controller.dart';

/// 一次播放请求（由详情页或命令行构造）。
class PlaybackRequest {
  const PlaybackRequest({
    required this.url,
    required this.title,
    required this.siteKey,
    required this.vodId,
    required this.vodName,
    required this.episodeName,
    required this.flag,
    this.headers = const {},
    this.startPosition,
    this.playLines = const [],
    this.episodeIndex = 0,
    this.vodPic,
    this.directUrl = false,
  });

  final String url;
  final String title;
  final String siteKey;
  final String vodId;
  final String vodName;
  final String episodeName;
  final String flag;
  final Map<String, String> headers;
  final Duration? startPosition;

  /// 详情页给出的全部线路，用于线路切换与上下集。
  final List<VodPlayLine> playLines;
  final int episodeIndex;
  final String? vodPic;

  /// 地址已是最终可播地址（直播频道），无需经站点播放入口解析。
  ///
  /// 直播源的 `urls` 直接在本地就是媒体地址，走解析器只会多余地请求站点；
  /// 同时直播需要「失败按顺序切线路」（§13.3），与点播的剧集切换语义不同。
  final bool directUrl;

  PlaybackRequest copyWith({
    String? url,
    String? episodeName,
    String? flag,
    Map<String, String>? headers,
    int? episodeIndex,
    Duration? startPosition,
    bool clearStartPosition = false,
  }) {
    return PlaybackRequest(
      url: url ?? this.url,
      title: title,
      siteKey: siteKey,
      vodId: vodId,
      vodName: vodName,
      episodeName: episodeName ?? this.episodeName,
      flag: flag ?? this.flag,
      headers: headers ?? this.headers,
      startPosition: clearStartPosition ? null : (startPosition ?? this.startPosition),
      playLines: playLines,
      episodeIndex: episodeIndex ?? this.episodeIndex,
      vodPic: vodPic,
      directUrl: directUrl,
    );
  }
}

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.state,
    required this.request,
  });

  final AppState state;
  final PlaybackRequest request;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final PlayerController _controller;
  late PlaybackRequest _request;
  bool _fullscreen = false;
  bool _controlsVisible = true;
  Timer? _saveTimer;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _request = widget.request;
    _controller = PlayerController()..addListener(_onControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    final outcome = await _controller.openWithRetry(
      _request.url,
      headers: _request.headers,
    );
    widget.state.log.info('播放结果 ${outcome.summary}', scope: 'player');
    if (!outcome.succeeded) {
      // 直播：当前线路失败时按顺序自动切到下一个线路（§13.3 播放失败可切线路）。
      if (_request.directUrl && await _fallbackLiveLine()) return;
      setState(() {
        _loadError = outcome.failureKind == null
            ? '播放失败'
            : describePlayerFailure(outcome.failureKind!);
      });
      return;
    }
    // 进度恢复：仅对同一剧集且位置有效时执行（§10.3 播放恢复）。
    final start = _request.startPosition;
    if (start != null && start > Duration.zero && start < _controller.duration) {
      await _controller.seek(start);
      widget.state.log.info(
        '恢复播放进度 episode=${_request.episodeName} '
        'position=${start.inMilliseconds}ms',
        scope: 'player',
      );
    }
    _startProgressSaver();
  }

  /// 直播线路回退（§13.3）：按顺序尝试当前频道剩余的线路。
  ///
  /// 返回 true 表示已切换到另一条线路并重新加载。
  Future<bool> _fallbackLiveLine() async {
    final lines = _episodes;
    if (lines.length <= 1) return false;
    final next = _request.episodeIndex + 1;
    if (next >= lines.length) {
      widget.state.log.info(
        '直播全部线路均失败 channel=${_request.episodeName} tried=${lines.length}',
        scope: 'live',
      );
      return false;
    }
    widget.state.log.info(
      '直播线路失败，自动切换 channel=${_request.episodeName} '
      'from=${_request.episodeIndex} to=$next',
      scope: 'live',
    );
    final episode = lines[next];
    setState(() {
      _request = _request.copyWith(
        url: episode.url,
        episodeName: episode.name,
        episodeIndex: next,
        clearStartPosition: true,
      );
    });
    await _load();
    return true;
  }

  /// 播放中周期性写入进度（§15.2 “播放中写入进度”）。
  void _startProgressSaver() {
    _saveTimer?.cancel();
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _persistProgress();
    });
  }

  void _persistProgress() {
    if (_controller.duration <= Duration.zero) return;
    widget.state.recordProgress(
      vod: Vod(vodId: _request.vodId, vodName: _request.vodName),
      flag: _request.flag,
      episodeName: _request.episodeName,
      episodeId: _request.url,
      position: _controller.position,
      duration: _controller.duration,
      siteKey: _request.siteKey,
    );
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _persistProgress();
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _toggleFullscreen() async {
    final next = !await windowManager.isFullScreen();
    await windowManager.setFullScreen(next);
    if (mounted) setState(() => _fullscreen = next);
  }

  Future<void> _exitFullscreen() async {
    if (await windowManager.isFullScreen()) {
      await windowManager.setFullScreen(false);
      if (mounted) setState(() => _fullscreen = false);
    }
  }

  List<VodEpisode> get _episodes {
    for (final line in _request.playLines) {
      if (line.flag == _request.flag) return line.episodes;
    }
    return const [];
  }

  Future<void> _playEpisode(int index, {String? overrideFlag}) async {
    final flag = overrideFlag ?? _request.flag;
    List<VodPlayLine> lines = _request.playLines;
    if (overrideFlag != null) {
      // 线路切换后需要按新线路解析地址。
      final target = lines
          .firstWhere(
            (line) => line.flag == overrideFlag,
            orElse: () => VodPlayLine(flag: overrideFlag, episodes: const []),
          )
          .episodes;
      if (index < 0 || index >= target.length) return;
      _episodesCache = target;
      await _openTarget(
        target[index],
        flag: overrideFlag,
        episodeIndex: index,
      );
      return;
    }
    final episodes = _episodesCache.isNotEmpty ? _episodesCache : _episodes;
    if (index < 0 || index >= episodes.length) return;
    await _openTarget(episodes[index], flag: flag, episodeIndex: index);
  }

  List<VodEpisode> _episodesCache = const [];

  Future<void> _openTarget(
    VodEpisode episode, {
    required String flag,
    required int episodeIndex,
  }) async {
    final state = widget.state;
    try {
      // 直播：地址已是最终可播地址，不经站点解析（§13.3）。
      final String url;
      if (_request.directUrl) {
        url = episode.url;
      } else {
        final decision = await state.resolvePlayback(
          episodeTarget: episode.url,
          flag: flag,
          vodId: _request.vodId,
        );
        if (decision == null || decision.url == null) {
          throw AppError(
            AppErrorKind.playbackUrlMissing,
            '播放决策没有返回可用地址',
            detail: 'flag=$flag episode=${episode.name}',
          );
        }
        url = decision.url!;
      }
      setState(() {
        _loadError = null;
        _request = _request.copyWith(
          url: url,
          episodeName: episode.name,
          flag: flag,
          headers: _request.directUrl
              ? _request.headers
              : null,
          episodeIndex: episodeIndex,
          clearStartPosition: true,
        );
        _episodesCache = const [];
      });
      _persistProgress();
      await _load();
    } catch (error) {
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      setState(() => _loadError = failure.userMessage);
      state.log.error('切换剧集失败 ${failure.logLine}', scope: 'player');
    }
  }

  Future<void> _playNext() async {
    final episodes = _episodesCache.isNotEmpty ? _episodesCache : _episodes;
    if (episodes.isEmpty) return;
    final next = _request.episodeIndex + 1;
    if (next >= episodes.length) return;
    await _openTarget(episodes[next], flag: _request.flag, episodeIndex: next);
  }

  Future<void> _playPrevious() async {
    final episodes = _episodesCache.isNotEmpty ? _episodesCache : _episodes;
    if (episodes.isEmpty) return;
    final previous = _request.episodeIndex - 1;
    if (previous < 0) return;
    await _openTarget(
      episodes[previous],
      flag: _request.flag,
      episodeIndex: previous,
    );
  }

  /// 自动连播（§10.3 MVP-B 能力，产品基础已就绪）。
  void _onCompleted() {
    _playNext();
  }

  @override
  Widget build(BuildContext context) {
    final shortcuts = buildPlayerShortcuts(
      togglePlay: _controller.playOrPause,
      seekBackward: () => _controller.seekBy(const Duration(seconds: -10)),
      seekForward: () => _controller.seekBy(const Duration(seconds: 10)),
      volumeUp: () => _controller.setVolume(_controller.volume + 5),
      volumeDown: () => _controller.setVolume(_controller.volume - 5),
      toggleMute: _controller.toggleMute,
      previousEpisode: _playPrevious,
      nextEpisode: _playNext,
      toggleFullscreen: _toggleFullscreen,
      exitFullscreen: _exitFullscreen,
    );

    if (_controller.isCompleted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onCompleted();
      });
    }

    return CallbackShortcuts(
      bindings: shortcuts,
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          appBar: _fullscreen
              ? null
              : AppBar(
                  title: Text(
                    '${_request.vodName} · ${_request.episodeName}',
                    overflow: TextOverflow.ellipsis,
                  ),
                  actions: [
                    IconButton(
                      tooltip: '快捷键说明',
                      icon: const Icon(Icons.keyboard),
                      onPressed: _showShortcutHelp,
                    ),
                    IconButton(
                      tooltip: _fullscreen ? '退出全屏' : '全屏',
                      icon: Icon(
                        _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                      ),
                      onPressed: _toggleFullscreen,
                    ),
                  ],
                ),
          body: Column(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () =>
                      setState(() => _controlsVisible = !_controlsVisible),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Video(
                          controller: _controller.videoController,
                          controls: NoVideoControls,
                        ),
                      ),
                      if (_controller.isLoading)
                        const Positioned.fill(
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      if (_loadError != null)
                        Positioned.fill(
                          child: Center(
                            child: _PlayerErrorOverlay(
                              message: _loadError!,
                              url: _request.url,
                              onRetry: _load,
                              onNext: _playNext,
                              canGoNext: (_episodesCache.isNotEmpty
                                      ? _episodesCache.length
                                      : _episodes.length) >
                                  _request.episodeIndex + 1,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (_controlsVisible || !_fullscreen)
                _ControlBar(
                  controller: _controller,
                  request: _request,
                  onToggleFullscreen: _toggleFullscreen,
                  onPrevious: _playPrevious,
                  onNext: _playNext,
                  onSelectEpisode: (index) => _playEpisode(index),
                  onSelectLine: (flag) => _playEpisode(0, overrideFlag: flag),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showShortcutHelp() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('快捷键'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (key, description) in playerShortcuts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('$key：$description'),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}

class _PlayerErrorOverlay extends StatelessWidget {
  const _PlayerErrorOverlay({
    required this.message,
    required this.url,
    required this.onRetry,
    required this.onNext,
    required this.canGoNext,
  });

  final String message;
  final String url;
  final VoidCallback onRetry;
  final VoidCallback onNext;
  final bool canGoNext;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 520),
      margin: const EdgeInsets.all(24),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.error),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.error_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(width: 8),
              const Text(
                '播放失败',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(message),
          const SizedBox(height: 8),
          SelectableText(
            '地址：${redactUrl(url)}',
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试一次'),
              ),
              const SizedBox(width: 8),
              if (canGoNext)
                OutlinedButton.icon(
                  onPressed: onNext,
                  icon: const Icon(Icons.skip_next, size: 18),
                  label: const Text('换下一集'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ControlBar extends StatelessWidget {
  const _ControlBar({
    required this.controller,
    required this.request,
    required this.onToggleFullscreen,
    required this.onPrevious,
    required this.onNext,
    required this.onSelectEpisode,
    required this.onSelectLine,
  });

  final PlayerController controller;
  final PlaybackRequest request;
  final VoidCallback onToggleFullscreen;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final ValueChanged<int> onSelectEpisode;
  final ValueChanged<String> onSelectLine;

  String _formatDuration(Duration value) {
    final total = value.inSeconds;
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    String two(int number) => number.toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:${two(minutes)}:${two(seconds)}'
        : '${two(minutes)}:${two(seconds)}';
  }

  @override
  Widget build(BuildContext context) {
    final duration = controller.duration;
    final maxMs = duration.inMilliseconds <= 0 ? 1.0 : duration.inMilliseconds.toDouble();
    final value = controller.position.inMilliseconds
        .clamp(0, maxMs.toInt())
        .toDouble();
    final episodes = () {
      for (final line in request.playLines) {
        if (line.flag == request.flag) return line.episodes;
      }
      return const <VodEpisode>[];
    }();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(_formatDuration(controller.position)),
              Expanded(
                child: Slider(
                  value: value,
                  max: maxMs,
                  onChanged: duration.inMilliseconds <= 0
                      ? null
                      : (next) => controller
                          .seek(Duration(milliseconds: next.round())),
                ),
              ),
              Text(_formatDuration(duration)),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IconButton(
                tooltip: '上一集（[）',
                onPressed: onPrevious,
                icon: const Icon(Icons.skip_previous),
              ),
              IconButton(
                tooltip: controller.isPlaying ? '暂停（空格）' : '播放（空格）',
                onPressed: controller.playOrPause,
                icon: Icon(controller.isPlaying ? Icons.pause : Icons.play_arrow),
              ),
              IconButton(
                tooltip: '下一集（]）',
                onPressed: onNext,
                icon: const Icon(Icons.skip_next),
              ),
              IconButton(
                tooltip: controller.muted || controller.volume == 0 ? '取消静音（M）' : '静音（M）',
                onPressed: controller.toggleMute,
                icon: Icon(
                  controller.muted || controller.volume == 0
                      ? Icons.volume_off
                      : Icons.volume_up,
                ),
              ),
              SizedBox(
                width: 120,
                child: Slider(
                  value: controller.volume.clamp(0, 100),
                  max: 100,
                  onChanged: controller.setVolume,
                ),
              ),
              const Text('倍速'),
              DropdownButton<double>(
                value: _nearestRate(controller.rate),
                items: const [
                  0.5,
                  0.75,
                  1.0,
                  1.25,
                  1.5,
                  2.0,
                ]
                    .map(
                      (rate) => DropdownMenuItem(
                        value: rate,
                        child: Text('${rate}x'),
                      ),
                    )
                    .toList(),
                onChanged: (rate) {
                  if (rate != null) controller.setRate(rate);
                },
              ),
              if (request.playLines.length > 1)
                DropdownButton<String>(
                  value: request.flag,
                  hint: const Text('线路'),
                  items: request.playLines
                      .map(
                        (line) => DropdownMenuItem(
                          value: line.flag,
                          child: Text(line.displayName),
                        ),
                      )
                      .toList(),
                  onChanged: (flag) {
                    if (flag != null) onSelectLine(flag);
                  },
                ),
              if (episodes.isNotEmpty)
                OutlinedButton.icon(
                  onPressed: () => _showEpisodes(context, episodes),
                  icon: const Icon(Icons.list, size: 18),
                  label: Text('剧集（${episodes.length}）'),
                ),
              IconButton(
                tooltip: '全屏（F11）',
                onPressed: onToggleFullscreen,
                icon: const Icon(Icons.fullscreen),
              ),
              Text(
                '缓冲 ${_formatDuration(controller.buffered)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ],
      ),
    );
  }

  double _nearestRate(double rate) {
    const rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    var best = rates.first;
    for (final candidate in rates) {
      if ((candidate - rate).abs() < (best - rate).abs()) best = candidate;
    }
    return best;
  }

  void _showEpisodes(BuildContext context, List<VodEpisode> episodes) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => SizedBox(
        height: 320,
        child: GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 180,
            mainAxisExtent: 40,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: episodes.length,
          itemBuilder: (context, index) => OutlinedButton(
            onPressed: () {
              Navigator.of(context).pop();
              onSelectEpisode(index);
            },
            child: Text(
              episodes[index].name,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );
  }
}
