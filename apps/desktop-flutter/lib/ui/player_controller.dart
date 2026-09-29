/// 播放器控制器：media-kit 封装与可观测状态（§10.2、§10.3、§10.5）。
///
/// 这是产品代码，不是 Phase 0 探针：它暴露播放/暂停、Seek、音量、静音、倍速、
/// 全屏、上下集、错误与首帧观测，并区分“加载完成”和“首帧已呈现”（Phase 0
/// 已确认 media-kit 无独立首帧回调，因此用 position>0 作为可观测代理）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'dart:io';

import '../core/playback_diagnostics.dart';
import '../core/protocol.dart';
import '../core/subtitle.dart';
import '../services/subtitle_service.dart';

/// 播放错误分类（§10.4）。
enum PlayerFailureKind {
  /// 403/404：链接失效，建议换线路。
  notFound,

  /// 401：Header 或 Cookie 丢失。
  unauthorized,

  /// DNS/连接失败。
  network,

  /// 超时。
  timeout,

  /// 格式不支持。
  unsupportedFormat,

  /// 其他加载失败。
  loadFailed,
}

String describePlayerFailure(PlayerFailureKind kind) {
  switch (kind) {
    case PlayerFailureKind.notFound:
      return '播放地址失效（403/404），建议切换线路或更新配置';
    case PlayerFailureKind.unauthorized:
      return '播放地址需要鉴权（401），请检查站点 Header 或 Cookie 是否完整';
    case PlayerFailureKind.network:
      return '网络不可达：请检查网络、代理或 DNS 设置';
    case PlayerFailureKind.timeout:
      return '播放超时：请重试一次或切换线路';
    case PlayerFailureKind.unsupportedFormat:
      return '播放器不支持该格式，请切换线路';
    case PlayerFailureKind.loadFailed:
      return '播放加载失败，请重试或切换线路';
  }
}

/// 从引擎错误文本推断失败分类。
PlayerFailureKind classifyPlayerError(String message) {
  final lowered = message.toLowerCase();
  if (lowered.contains('403') || lowered.contains('404')) {
    return PlayerFailureKind.notFound;
  }
  if (lowered.contains('401')) return PlayerFailureKind.unauthorized;
  if (lowered.contains('timed out') || lowered.contains('timeout')) {
    return PlayerFailureKind.timeout;
  }
  if (lowered.contains('could not resolve') ||
      lowered.contains('name or service not known') ||
      lowered.contains('connection refused') ||
      lowered.contains('no route to host') ||
      lowered.contains('failed to connect')) {
    return PlayerFailureKind.network;
  }
  if (lowered.contains('could not open codec') ||
      lowered.contains('unsupported') ||
      lowered.contains('codec not found')) {
    return PlayerFailureKind.unsupportedFormat;
  }
  return PlayerFailureKind.loadFailed;
}

/// 一次加载的可观测结果。
class PlayerLoadOutcome {
  const PlayerLoadOutcome({
    required this.succeeded,
    required this.url,
    this.failureKind,
    this.errorMessage,
    this.duration = Duration.zero,
    this.loadElapsed = Duration.zero,
    this.firstFrame,
  });

  final bool succeeded;
  final String url;
  final PlayerFailureKind? failureKind;
  final String? errorMessage;
  final Duration duration;
  final Duration loadElapsed;

  /// `position` 首次大于 0 的相对耗时；未观测到为 null。
  final Duration? firstFrame;

  String get summary =>
      'succeeded=$succeeded url=${redactUrl(url)} '
      'duration=${duration.inMilliseconds}ms '
      'load=${loadElapsed.inMilliseconds}ms '
      'firstFrame=${firstFrame == null ? "unobserved" : "${firstFrame!.inMilliseconds}ms"} '
      '${failureKind == null ? "" : "failure=${failureKind!.name} "}'
      '${errorMessage == null ? "" : "error=${errorMessage!.length > 160 ? errorMessage!.substring(0, 160) : errorMessage!}"}';
}

/// 播放器控制器。
class PlayerController extends ChangeNotifier {
  PlayerController({Player? player, SubtitleLoader? subtitleLoader})
    : _player = player ?? Player(),
      _subtitleLoader = subtitleLoader ?? SubtitleService() {
    _videoController = VideoController(_player);
    _bind();
  }

  final Player _player;
  late final VideoController _videoController;

  /// 字幕加载器（§10.3）：用宿主自己的 HTTP 客户端携带 Header 拉取，
  /// 再把文本交给播放器，避免字幕请求丢失 Referer/UA/Cookie。
  final SubtitleLoader _subtitleLoader;

  final List<StreamSubscription<dynamic>> _subscriptions = [];
  String? _lastEngineError;
  Timer? _retryTimer;
  int _retryCount = 0;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  bool _playing = false;
  bool _loading = false;
  bool _completed = false;
  double _volume = 100;
  bool _muted = false;
  double _volumeBeforeMute = 100;
  double _rate = 1.0;
  String? _currentUrl;
  PlayerLoadOutcome? _lastOutcome;

  /// 本次播放的诊断信息（§23）。每次 [open] 重建，包含引擎/格式/网络/错误与阶段耗时。
  PlaybackDiagnostics? _diagnostics;
  PlaybackDiagnosticsBuilder? _diagnosticsBuilder;

  VideoController get videoController => _videoController;
  Player get player => _player;
  Duration get position => _position;
  Duration get duration => _duration;
  Duration get buffered => _buffered;
  bool get isPlaying => _playing;
  bool get isLoading => _loading;
  bool get isCompleted => _completed;
  double get volume => _volume;
  bool get muted => _muted;
  double get rate => _rate;
  String? get currentUrl => _currentUrl;
  PlayerLoadOutcome? get lastOutcome => _lastOutcome;
  String? get lastEngineError => _lastEngineError;

  /// 最近一次播放的诊断快照（§23）。未开始播放时为 null。
  PlaybackDiagnostics? get diagnostics => _diagnostics;

  // ---------------------------------------------------------------- 字幕

  /// 外挂字幕候选（由播放结果的 `subs` 构建，§10.3）。
  List<SubtitleOption> _externalSubtitleOptions = const [];

  /// 内嵌字幕候选（由播放器上报的字幕轨构建）。
  List<SubtitleOption> _embeddedSubtitleOptions = const [];

  SubtitleOption? _selectedSubtitle;
  String? _subtitleError;
  bool _subtitleBusy = false;

  /// 外挂字幕落盘后的临时文件路径 → 对应菜单条目。
  ///
  /// 为什么落盘而不是用 `SubtitleTrack.data`：media-kit 的 `.data` 会写一个
  /// **没有扩展名**的临时文件（`TempFile` 用 UUID 命名），mpv 只能靠内容嗅探
  /// 识别格式，并出现“轨已加入但 `tracks`/`track` 状态迟迟不刷新”的观测不一致；
  /// 写成带真实扩展名（`.srt`/`.ass`/…）的临时文件后 libass 能直接按扩展名解析，
  /// 轨表也能立即反映出来（Windows 实测，见 phase3 字幕集成测试）。
  /// 宿主先自己带 Header 拉取文本再落盘，因此不会把 Header 泄漏给播放器。
  final Map<String, SubtitleOption> _externalTrackFiles = {};

  /// 字幕菜单（外挂 + 内嵌 + 关闭），供播放器页展示（§17.3）。
  List<SubtitleOption> get subtitleOptions =>
      subtitleMenu(_externalSubtitleOptions, _embeddedSubtitleOptions);

  /// 外挂字幕候选（供页面做丢弃统计/展示）。
  List<SubtitleOption> get externalOptions => _externalSubtitleOptions;

  /// 内嵌字幕轨候选。
  List<SubtitleOption> get embeddedOptions => _embeddedSubtitleOptions;

  /// 当前选中的字幕；null 表示未显式选择（交给播放器默认行为）。
  SubtitleOption? get selectedSubtitle => _selectedSubtitle;

  /// 最近一次字幕错误（§10.4：字幕失败只提示，不影响视频播放）。
  String? get subtitleError => _subtitleError;
  bool get subtitleBusy => _subtitleBusy;
  bool get hasSubtitles => subtitleOptions.length > 1;

  /// 设置本次播放结果携带的外挂字幕。
  ///
  /// [onDiscard] 用于上报被丢弃的条目（缺地址/格式不支持），避免静默丢弃。
  void setExternalSubtitles(
    List<SubtitleInfo> subs, {
    void Function(SubtitleInfo sub, String reason)? onDiscard,
  }) {
    final options = externalSubtitleOptions(subs, onDiscard: onDiscard);
    if (listEquals(options, _externalSubtitleOptions)) return;
    _externalSubtitleOptions = options;
    notifyListeners();
  }

  /// 自动启用默认/强制外挂字幕（§10.3）。
  ///
  /// 内嵌轨的默认选择由 mpv 自己处理（`default` 标记）；这里只负责外挂字幕，
  /// 因为引擎无从知道它们的存在。返回 true 表示已启用。
  Future<bool> applyDefaultSubtitle({
    Map<String, String> headers = const {},
  }) async {
    if (_selectedSubtitle != null) return false;
    final option = defaultSubtitleOption(_externalSubtitleOptions);
    if (option == null) return false;
    return selectSubtitle(option, headers: headers);
  }

  /// 选择字幕轨（关闭 / 内嵌 / 外挂）。
  ///
  /// 任何失败都只落到 [subtitleError]，**不抛出、不影响视频播放**（§10.4）。
  Future<bool> selectSubtitle(
    SubtitleOption option, {
    Map<String, String> headers = const {},
  }) async {
    _subtitleBusy = true;
    _subtitleError = null;
    notifyListeners();
    try {
      if (option.id == SubtitleOption.offId) {
        await _player.setSubtitleTrack(SubtitleTrack.no());
        _selectedSubtitle = SubtitleOption.off;
        return true;
      }
      if (option.isExternal) {
        final document = await _subtitleLoader.load(
          SubtitleInfo(
            url: option.url ?? '',
            name: option.label,
            lang: option.language,
            format: option.format,
          ),
          headers: headers,
        );
        final file = await _writeSubtitleFile(document);
        await _player.setSubtitleTrack(
          SubtitleTrack.uri(
            file.path,
            title: option.label,
            language: option.language.isEmpty ? 'auto' : option.language,
          ),
        );
        _externalTrackFiles[file.path] = option;
        _selectedSubtitle = option;
        // 上一份外挂字幕文件已不再需要：保留当前这一份即可。
        await _pruneSubtitleFiles(option);
        return true;
      }
      final trackId = option.id.substring('embedded:'.length);
      await _player.setSubtitleTrack(
        SubtitleTrack(
          trackId,
          option.label,
          option.language.isEmpty ? null : option.language,
        ),
      );
      _selectedSubtitle = option;
      return true;
    } catch (error) {
      _subtitleError = describeSubtitleFailure(error);
      return false;
    } finally {
      _subtitleBusy = false;
      notifyListeners();
    }
  }

  /// 清空字幕错误（用户重新选择时）。
  void clearSubtitleError() {
    if (_subtitleError == null) return;
    _subtitleError = null;
    notifyListeners();
  }

  /// 把字幕文本写入带正确扩展名的临时文件（§10.3）。
  Future<File> _writeSubtitleFile(SubtitleDocument document) async {
    final directory = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}webhtv-pc-subtitles',
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    final extension = document.format.isEmpty ? 'srt' : document.format;
    final file = File(
      '${directory.path}${Platform.pathSeparator}'
      'sub-${DateTime.now().microsecondsSinceEpoch}.$extension',
    );
    await file.writeAsString(document.text);
    return file;
  }

  /// 清理不再使用的外挂字幕临时文件（避免临时目录持续增长）。
  ///
  /// [keep] 为需要保留的条目（通常是当前选择），传 null 表示全部删除（销毁时）。
  Future<void> _pruneSubtitleFiles(SubtitleOption? keep) async {
    final stale = _externalTrackFiles.entries
        .where((entry) => entry.value != keep)
        .toList();
    for (final entry in stale) {
      _externalTrackFiles.remove(entry.key);
      try {
        final file = File(entry.key);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // 临时文件清理失败不应影响播放（§20 资源释放是尽力而为）。
      }
    }
  }

  double get progress {
    if (_duration.inMilliseconds <= 0) return 0;
    return (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
  }

  void _bind() {
    _subscriptions.addAll([
      _player.stream.position.listen((value) {
        _position = value;
        notifyListeners();
      }),
      _player.stream.duration.listen((value) {
        _duration = value;
        notifyListeners();
      }),
      _player.stream.buffer.listen((value) {
        _buffered = value;
        notifyListeners();
      }),
      _player.stream.playing.listen((value) {
        _playing = value;
        notifyListeners();
      }),
      _player.stream.completed.listen((value) {
        _completed = value;
        notifyListeners();
      }),
      _player.stream.volume.listen((value) {
        _volume = value;
        notifyListeners();
      }),
      _player.stream.rate.listen((value) {
        _rate = value;
        notifyListeners();
      }),
      _player.stream.error.listen((message) {
        _lastEngineError = message;
        // 非致命告警（无声卡/无 GPU）不应被当成加载失败：加载结果以 duration 判定。
        notifyListeners();
      }),
      _player.stream.tracks.listen((tracks) {
        _updateEmbeddedSubtitles(tracks.subtitle);
      }),
      _player.stream.track.listen((track) {
        _syncSelectedSubtitle(track.subtitle);
      }),
    ]);
  }

  /// 播放器上报的内嵌字幕轨变化（切集/换片后重新计算菜单）。
  void _updateEmbeddedSubtitles(List<SubtitleTrack> tracks) {
    final options = embeddedSubtitleOptions(
      tracks.map(
        (track) => (
          id: track.id,
          title: track.title ?? '',
          language: track.language ?? '',
          isDefault: track.isDefault ?? false,
        ),
      ),
    );
    if (listEquals(options, _embeddedSubtitleOptions)) return;
    _embeddedSubtitleOptions = options;
    notifyListeners();
  }

  /// 播放器当前字幕轨 → 菜单选中态。
  ///
  /// 外挂字幕由本控制器自己发起（`uri/data` 形态），不能被引擎回写覆盖，
  /// 否则 `sub-add` 后 `state.track` 的 `id` 是临时文件路径，菜单会显示成内嵌轨。
  /// 同时把外部字幕轨同步到菜单候选里：mpv 加载完外挂字幕后会把它列入轨道表。
  void _syncSelectedSubtitle(SubtitleTrack track) {
    if (track.uri || track.data) {
      // 外挂字幕由本控制器落盘后交给引擎，id 即我们生成的临时文件路径。
      final external = _externalTrackFiles[track.id];
      if (external != null) {
        if (_selectedSubtitle != external) {
          _selectedSubtitle = external;
          notifyListeners();
        }
      }
      return;
    }
    if (!isRealSubtitleTrackId(track.id)) {
      // `no`：关闭；`auto`：未显式选择。
      final next = track.id.trim() == 'no' ? SubtitleOption.off : null;
      if (_selectedSubtitle != next) {
        _selectedSubtitle = next;
        notifyListeners();
      }
      return;
    }
    final matched = _embeddedSubtitleOptions.firstWhere(
      (option) => option.id == 'embedded:${track.id}',
      orElse: () => SubtitleOption.off,
    );
    final next = matched.id == SubtitleOption.offId ? null : matched;
    if (_selectedSubtitle != next) {
      _selectedSubtitle = next;
      notifyListeners();
    }
  }

  /// 加载媒体。
  ///
  /// [headers] 由 PlaybackResolver 给出，已经完成全局 → 站点 → 播放结果优先级合并。
  /// [diagnosticsBuilder] 由 [openWithRetry] 传入以跨重试累积阶段；直接调用时为 null，
  /// 本次加载自建。
  Future<PlayerLoadOutcome> open(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 20),
    Duration firstFrameTimeout = const Duration(seconds: 5),
    bool awaitFirstFrame = true,
    PlaybackDiagnosticsBuilder? diagnosticsBuilder,
    String? siteKey,
    String? flag,
    String? episodeName,
  }) async {
    _loading = true;
    _completed = false;
    _lastEngineError = null;
    _currentUrl = url;

    // 诊断：记录入口地址与注入 Header（输出时统一脱敏，§23）。
    final builder = diagnosticsBuilder ??
        PlaybackDiagnosticsBuilder(
          siteKey: siteKey,
          flag: flag,
          episodeName: episodeName,
        );
    _diagnosticsBuilder = builder;
    builder.setFinalUrl(url);
    builder.setHeaders(headers);
    notifyListeners();

    final stopwatch = Stopwatch()..start();
    final loadCompleter = Completer<Duration>();
    final localSubscriptions = <StreamSubscription<dynamic>>[];
    Duration? firstFrame;
    var openIssued = false;
    String? loadError;

    void completeLoad() {
      if (loadCompleter.isCompleted) return;
      if (_player.state.duration <= Duration.zero) return;
      loadCompleter.complete(stopwatch.elapsed);
    }

    localSubscriptions.add(
      _player.stream.error.listen((message) => loadError ??= message),
    );
    localSubscriptions.add(
      _player.stream.duration.listen((value) {
        if (value > Duration.zero) completeLoad();
      }),
    );
    localSubscriptions.add(
      _player.stream.position.listen((value) {
        if (!openIssued || value <= Duration.zero) return;
        firstFrame ??= stopwatch.elapsed;
      }),
    );
    localSubscriptions.add(
      _player.stream.playing.listen((value) {
        if (value) completeLoad();
      }),
    );

    try {
      await _player.open(Media(url, httpHeaders: headers));
      openIssued = true;

      final loadElapsed = await loadCompleter.future.timeout(
        timeout,
        onTimeout: () => throw TimeoutException(
          'load timeout after ${timeout.inSeconds}s',
        ),
      );

      if (awaitFirstFrame && firstFrame == null) {
        final deadline = stopwatch.elapsed + firstFrameTimeout;
        while (firstFrame == null && stopwatch.elapsed < deadline) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
          if (openIssued && _player.state.position > Duration.zero) {
            firstFrame ??= stopwatch.elapsed;
          }
        }
      }

      final outcome = PlayerLoadOutcome(
        succeeded: true,
        url: url,
        duration: _player.state.duration,
        loadElapsed: loadElapsed,
        firstFrame: firstFrame,
      );
      _lastOutcome = outcome;
      _loading = false;
      _retryCount = 0;
      _finishDiagnostics(succeeded: true, loadElapsed: loadElapsed, firstFrame: firstFrame);
      notifyListeners();
      return outcome;
    } on TimeoutException catch (error) {
      final outcome = _failure(url, loadError ?? error.message ?? 'timeout', stopwatch);
      _lastOutcome = outcome;
      _loading = false;
      _finishFailureDiagnostics(outcome);
      notifyListeners();
      return outcome;
    } catch (error) {
      final outcome = _failure(url, loadError ?? '$error', stopwatch);
      _lastOutcome = outcome;
      _loading = false;
      _finishFailureDiagnostics(outcome);
      notifyListeners();
      return outcome;
    } finally {
      for (final subscription in localSubscriptions) {
        await subscription.cancel();
      }
    }
  }

  PlayerLoadOutcome _failure(String url, String message, Stopwatch stopwatch) {
    final kind = classifyPlayerError(message);
    return PlayerLoadOutcome(
      succeeded: false,
      url: url,
      failureKind: kind,
      errorMessage: message,
      loadElapsed: stopwatch.elapsed,
    );
  }

  /// 成功时补齐阶段耗时并落定诊断快照（§23）。
  void _finishDiagnostics({
    required bool succeeded,
    required Duration loadElapsed,
    Duration? firstFrame,
  }) {
    final builder = _diagnosticsBuilder;
    if (builder == null) return;
    builder.addStage(PlaybackStage.load, loadElapsed);
    if (firstFrame != null) {
      builder.addStage(PlaybackStage.firstFrame, firstFrame);
    } else if (succeeded) {
      builder.addStage(
        PlaybackStage.firstFrame,
        loadElapsed,
        note: '首帧未单独观测到',
      );
    }
    builder.addStage(PlaybackStage.playing, Duration.zero);
    builder.succeed();
    _diagnostics = builder.build();
  }

  /// 失败时记录失败分类、引擎错误与用户提示，并落定诊断快照（§10.4、§23）。
  void _finishFailureDiagnostics(PlayerLoadOutcome outcome) {
    final builder = _diagnosticsBuilder;
    if (builder == null) return;
    builder.addStage(PlaybackStage.load, outcome.loadElapsed);
    builder.addStage(PlaybackStage.failed, outcome.loadElapsed);
    final kind = outcome.failureKind;
    builder.fail(
      kind: kind ?? PlayerFailureKind.loadFailed,
      message: outcome.errorMessage,
      hint: kind == null ? null : describePlayerFailure(kind),
    );
    _diagnostics = builder.build();
  }

  /// 超时场景只重试一次（§10.4）。
  ///
  /// 诊断阶段跨重试累积到同一个快照，便于区分「首次失败」与「重试后失败/成功」。
  Future<PlayerLoadOutcome> openWithRetry(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 20),
    String? siteKey,
    String? flag,
    String? episodeName,
  }) async {
    final builder = PlaybackDiagnosticsBuilder(
      siteKey: siteKey,
      flag: flag,
      episodeName: episodeName,
    );
    var outcome = await open(
      url,
      headers: headers,
      timeout: timeout,
      diagnosticsBuilder: builder,
    );
    if (outcome.succeeded) return outcome;
    if (outcome.failureKind != PlayerFailureKind.timeout &&
        outcome.failureKind != PlayerFailureKind.network) {
      return outcome;
    }
    if (_retryCount >= 1) return outcome;
    _retryCount++;
    final retryStopwatch = Stopwatch()..start();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    builder.addStage(PlaybackStage.retry, retryStopwatch.elapsed);
    outcome = await open(
      url,
      headers: headers,
      timeout: timeout,
      diagnosticsBuilder: builder,
    );
    return outcome;
  }

  Future<void> play() => _player.play();

  Future<void> pause() => _player.pause();

  Future<void> playOrPause() async {
    if (_playing) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> seek(Duration target) => _player.seek(target);

  Future<void> seekBy(Duration delta) {
    final next = _position + delta;
    if (next < Duration.zero) return _player.seek(Duration.zero);
    if (_duration > Duration.zero && next > _duration) {
      return _player.seek(_duration);
    }
    return _player.seek(next);
  }

  Future<void> setVolume(double value) async {
    final clamped = value.clamp(0.0, 100.0);
    if (clamped > 0) _volumeBeforeMute = clamped;
    _muted = clamped == 0;
    await _player.setVolume(clamped);
    notifyListeners();
  }

  /// 静音切换：静音时记住原音量，取消静音时恢复，不使用硬编码 100。
  Future<void> toggleMute() async {
    if (_muted || _volume <= 0) {
      _muted = false;
      final restored = _volumeBeforeMute <= 0 ? 100.0 : _volumeBeforeMute;
      await _player.setVolume(restored);
    } else {
      _volumeBeforeMute = _volume;
      _muted = true;
      await _player.setVolume(0);
    }
    notifyListeners();
  }

  Future<void> setRate(double value) => _player.setRate(value.clamp(0.25, 4.0));
  Future<void> stop() => _player.stop();

  /// 取消挂起的重试定时器，避免页面销毁后继续操作引擎。
  void cancelPendingRetries() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  @override
  void dispose() {
    cancelPendingRetries();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    // 清理外挂字幕临时文件（§20 资源释放）。
    _pruneSubtitleFiles(null);
    _player.dispose();
    super.dispose();
  }
}
