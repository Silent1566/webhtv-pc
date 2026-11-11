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

import '../core/lut.dart';
import '../core/playback_diagnostics.dart';
import '../core/player_options.dart';
import '../core/player_tracks.dart';
import '../core/protocol.dart';
import '../core/subtitle.dart';
import '../services/subtitle_service.dart';

/// 起播加载超时的默认预算（180 秒）。
///
/// 与站点请求预算 `siteRequestTimeout`（`lib/core/http_api.dart:748`）对齐：
/// 网盘点播是 GB 级**整文件**流，起播前还要经过解析接口、代理隧道与上游首字节，
/// 20 秒会把「慢但真能播」的情况误判成超时（§10.4 只约束「重试一次」，
/// 不约束单次等待时长）。
const Duration playerLoadTimeout = Duration(seconds: 180);

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
  PlayerController({
    Player? player,
    SubtitleLoader? subtitleLoader,
    this.onSeek,
  }) : _player = player ?? Player(),
       _subtitleLoader = subtitleLoader ?? SubtitleService() {
    _videoController = VideoController(_player);
    _bind();
  }

  final Player _player;
  final ValueChanged<Duration>? onSeek;
  SubtitleDocument? _selectedSubtitleDocument;
  SubtitleDocument? get selectedSubtitleDocument =>
      _selectedSubtitle?.isExternal == true &&
          _selectedSubtitle?.url == _selectedSubtitleDocument?.sourceUrl
      ? _selectedSubtitleDocument
      : null;
  late final VideoController _videoController;

  /// 字幕加载器（§10.3）：用宿主自己的 HTTP 客户端携带 Header 拉取，
  /// 再把文本交给播放器，避免字幕请求丢失 Referer/UA/Cookie。
  final SubtitleLoader _subtitleLoader;

  final List<StreamSubscription<dynamic>> _subscriptions = [];
  String? _lastEngineError;
  Timer? _retryTimer;
  int _retryCount = 0;
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  bool _playing = false;
  bool _loading = false;

  /// 播放中途的缓冲状态（
  /// `core-idle` / `paused-for-cache`）。
  ///
  /// 与 [_loading] **不是同一件事**：[_loading] 只覆盖 `open()`
  /// 的生命周期（起播到首帧），它一旦落定就不再变；用户真正会遇到的
  /// "卡住了"全部发生在之后，只能靠这两个流观测。
  bool _buffering = false;

  /// 缓冲百分比（0–100）。
  ///
  /// 来源是 mpv 的 `cache-buffering-state`（media_kit 的
  /// `stream.bufferingPercentage`）。**null 表示"引擎还没上报"**，
  /// 不是 0：两者在界面上是不同形态（无数字的无限环 vs "0%"），
  /// 把"没数据"画成 0% 会让用户以为卡死在零。
  double? _bufferingPercent;

  /// 最近一次采样到的网络吞吐（字节/秒）。null 表示**取不到**。
  ///
  /// 为什么是 null 而不是 0：0 会被读成"网络停了"，而真正的 0 只在
  /// 播放器确实没有流量时出现，取不到值完全是另一回事。屏显对两者
  /// 显示不同文本（见 `formatByteRate`）。
  double? _bytesPerSecond;
  bool _completed = false;
  double _volume = 100;
  bool _muted = false;
  double _volumeBeforeMute = 100;
  double _rate = 1.0;
  String? _currentUrl;
  PlayerLoadOutcome? _lastOutcome;

  /// media-kit 在媒体打开后持续上报的真实媒体元数据。
  VideoParams _videoParams = const VideoParams();
  AudioParams _audioParams = const AudioParams();
  Tracks _tracks = const Tracks();
  int? _videoWidth;
  int? _videoHeight;
  double? _audioBitrate;

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

  /// 播放中途是否在缓冲（见 [_buffering]）。
  bool get isBuffering => _buffering;

  /// 缓冲百分比 0–100；null 表示引擎尚未上报（见 [_bufferingPercent]）。
  double? get bufferingPercent => _bufferingPercent;

  /// 最近一次采样到的网速（字节/秒）；null 表示取不到（见 [_bytesPerSecond]）。
  double? get bytesPerSecond => _bytesPerSecond;

  bool get isCompleted => _completed;

  /// 显式清除 `completed`（失败/回滚路径用，`design/03` §4.3）。
  ///
  /// **为什么必须显式**：media_kit 的 `completed` 只在下次 `open()` 时复位，
  /// 而失败路径不会再 `open()`（否则就是死循环重试）。若不清除，那个残留的
  /// `completed=true` 会在下一次 `setState`/重建时再次触发连播——
  /// 正是用户实测的「缓存耗尽后跳下一集」（D1 + D2 的叠加形态）。
  ///
  /// 返回是否真的发生了变化，便于调用点与测试断言「失败路径确实清了」。
  bool clearCompleted() {
    if (_disposed || !_completed) return false;
    _completed = false;
    notifyListeners();
    return true;
  }

  double get volume => _volume;
  bool get muted => _muted;
  double get rate => _rate;
  String? get currentUrl => _currentUrl;
  PlayerLoadOutcome? get lastOutcome => _lastOutcome;
  String? get lastEngineError => _lastEngineError;
  VideoParams get videoParams => _videoParams;
  AudioParams get audioParams => _audioParams;
  Tracks get tracks => _tracks;
  int? get videoWidth => _videoWidth ?? _videoParams.dw ?? _videoParams.w;
  int? get videoHeight => _videoHeight ?? _videoParams.dh ?? _videoParams.h;
  double? get audioBitrate => _audioBitrate;

  /// 当前视频/音频轨，包含 codec、fps、bitrate、采样率等信息。
  VideoTrack? get selectedVideoTrack => _selectedVideoTrack;
  AudioTrack? get selectedAudioTrack => _selectedAudioTrack;

  VideoTrack? get _selectedVideoTrack {
    final id = _player.state.track.video.id;
    for (final track in _tracks.video) {
      if (track.id == id) return track;
    }
    return _tracks.video
        .where((track) => track.id != 'auto' && track.id != 'no')
        .firstOrNull;
  }

  AudioTrack? get _selectedAudioTrack {
    final id = _player.state.track.audio.id;
    for (final track in _tracks.audio) {
      if (track.id == id) return track;
    }
    return _tracks.audio
        .where((track) => track.id != 'auto' && track.id != 'no')
        .firstOrNull;
  }

  /// 引擎上报的原始音轨（标题未加工）。
  ///
  /// 与 [audioTrackOptions] 分开：菜单标签会拼上语言与序号，而轨道记忆要做
  /// title 精确回落，只能拿引擎原文（拼过的标签下次一定对不上）。
  List<PlayerTrackInfo> get audioTrackInfos => _tracks.audio
      .map(
        (track) => PlayerTrackInfo(
          id: track.id,
          title: track.title ?? '',
          language: track.language ?? '',
          isDefault: track.isDefault ?? false,
        ),
      )
      .toList(growable: false);

  /// 引擎上报的原始视频轨（见 [audioTrackInfos]）。
  List<PlayerTrackInfo> get videoTrackInfos => _tracks.video
      .map(
        (track) => PlayerTrackInfo(
          id: track.id,
          title: track.title ?? '',
          language: track.language ?? '',
          isDefault: track.isDefault ?? false,
        ),
      )
      .toList(growable: false);

  /// 内嵌字幕轨，id 用菜单里的 `embedded:<trackId>` 形态。
  ///
  /// 用菜单 id 而不是裸 trackId：记忆写回时拿到的就是菜单项 id，
  /// 两边同一套标识才不用来回剥前缀。
  List<PlayerTrackInfo> get embeddedSubtitleTrackInfos => <PlayerTrackInfo>[
    for (final track in _tracks.subtitle)
      if (isRealSubtitleTrackId(track.id))
        PlayerTrackInfo(
          id: 'embedded:${track.id}',
          title: track.title ?? '',
          language: track.language ?? '',
          isDefault: track.isDefault ?? false,
        ),
  ];

  /// 音轨菜单（Phase 9）。空表表示引擎尚未上报轨道。
  List<PlayerTrackOption> get audioTrackOptions => buildPlayerTrackOptions(
    kind: PlayerTrackKind.audio,
    tracks: audioTrackInfos,
    selectedId: _player.state.track.audio.id,
  );

  /// 视频轨菜单（Phase 9）。
  List<PlayerTrackOption> get videoTrackOptions => buildPlayerTrackOptions(
    kind: PlayerTrackKind.video,
    tracks: videoTrackInfos,
    selectedId: _player.state.track.video.id,
  );

  /// 是否值得显示音轨/视频轨入口。
  bool get hasSwitchableAudioTracks => hasSwitchableTracks(audioTrackOptions);
  bool get hasSwitchableVideoTracks => hasSwitchableTracks(videoTrackOptions);

  /// 切换音轨。`auto` 回到引擎默认；失败只记错误，不打断播放。
  Future<bool> selectAudioTrack(String id) async {
    if (_disposed) return false;
    final target = id.trim();
    if (target.isEmpty) return false;
    try {
      if (target == 'auto') {
        await _player.setAudioTrack(AudioTrack.auto());
      } else if (target == 'no') {
        await _player.setAudioTrack(AudioTrack.no());
      } else {
        final source = _tracks.audio.firstWhere(
          (track) => track.id == target,
          orElse: () => const AudioTrack('', null, null),
        );
        if (source.id.isEmpty) return false;
        await _player.setAudioTrack(source);
      }
      return true;
    } catch (error) {
      if (!_disposed) _lastEngineError = '$error';
      return false;
    }
  }

  /// 切换视频轨。语义与音轨一致。
  Future<bool> selectVideoTrack(String id) async {
    if (_disposed) return false;
    final target = id.trim();
    if (target.isEmpty) return false;
    try {
      if (target == 'auto') {
        await _player.setVideoTrack(VideoTrack.auto());
      } else if (target == 'no') {
        await _player.setVideoTrack(VideoTrack.no());
      } else {
        final source = _tracks.video.firstWhere(
          (track) => track.id == target,
          orElse: () => const VideoTrack('', null, null),
        );
        if (source.id.isEmpty) return false;
        await _player.setVideoTrack(source);
      }
      return true;
    } catch (error) {
      if (!_disposed) _lastEngineError = '$error';
      return false;
    }
  }

  /// 注入 mpv 属性。返回 false 表示当前平台不是 NativePlayer 或属性被拒绝。
  Future<bool> applyMpvProperties(Map<String, String> properties) async {
    if (_disposed) return false;
    final platform = _player.platform;
    if (platform is! NativePlayer) return false;
    try {
      for (final entry in properties.entries) {
        if (_disposed) return false;
        await platform.setProperty(entry.key, entry.value);
      }
      return true;
    } catch (error) {
      if (!_disposed) _lastEngineError = '$error';
      return false;
    }
  }

  /// 采样一次网络吞吐（字节/秒），成功时更新 [bytesPerSecond]。
  ///
  /// **挂在已有的屏显刷新循环上**（`player_page.dart` 的 `_startOsdTicker`，
  /// 1 秒一跳），因此本方法**不持有任何 Timer**：另起一个定时器会多一份
  /// 每秒唤醒，还会让"屏显全关时停止刷新"这条既有优化失效
  /// （那个优化的判据是"没有东西要刷新"，网速就是东西）。
  ///
  /// **双数据源，首选失败才回退**（两拍顺序读会让屏显跳变，所以同一拍内
  /// 完成）：
  /// 1. 首选 `demuxer-cache-state`：它是 JSON 串，内含 `raw-input-rate`。
  ///    `raw-input-rate` **不是独立属性**（`mpv_get_property` 回
  ///    `MPV_ERROR_PROPERTY_NOT_FOUND`），只能从这里取。
  /// 2. 回退 `cache-speed`：独立属性，double 的字符串形式，单位字节/秒。
  ///
  /// 取不到值的四种情形（都返回 null，**不**退化成 0）：
  /// - 当前平台不是 `NativePlayer`（非桌面构建）；
  /// - 属性为空串（`getProperty` 在失败时返回 `""`，见
  ///   `media_kit/.../native/player/real.dart:1278`）。缓存建立前的那一两拍
  ///   `demuxer-cache-state` 正是回 NULL，这里如实给 null、下一拍重试；
  /// - 解析失败（mpv 在某些状态下会回 `"nan"` / `"inf"`）；
  /// - 值为负数或非有限。
  Future<double?> sampleNetworkRate() async {
    if (_disposed) return null;
    final platform = _player.platform;
    if (platform is! NativePlayer) {
      _setBytesPerSecond(null);
      return null;
    }
    String cacheState;
    try {
      cacheState = await platform.getProperty('demuxer-cache-state');
    } catch (error) {
      if (!_disposed) _lastEngineError = '$error';
      cacheState = '';
    }
    var parsed = parseRawInputRateFromCacheState(cacheState);
    if (_disposed) return parsed;
    String? cacheSpeed;
    // 首选真的失败才读回退属性：首选成功时多读一次纯属每秒一次的浪费。
    if (parsed == null) {
      try {
        cacheSpeed = await platform.getProperty('cache-speed');
      } catch (error) {
        if (!_disposed) _lastEngineError = '$error';
      }
    }
    parsed = resolveNetworkRate(parsed, cacheSpeed);
    _setBytesPerSecond(parsed);
    return parsed;
  }

  /// 只在值真的变了时通知，避免每秒一次无意义重建。
  ///
  /// 屏显的时钟本来就在每秒重建，但那是 `setState`（页面级）；这里多通知
  /// 一次会让 `_onControllerChanged` 里的连播判定也跟着每秒跑一遍。
  void _setBytesPerSecond(double? value) {
    if (_disposed || _bytesPerSecond == value) return;
    _bytesPerSecond = value;
    notifyListeners();
  }

  /// 应用播放参数（Phase 9）。失败不阻断播放，只留错误文本。
  Future<bool> applyPlayerOptions(PlayerOptions options) =>
      applyMpvProperties(options.mpvProperties);

  /// 应用/清除 LUT。空路径表示清除。
  Future<bool> applyLut(String? path) =>
      applyMpvProperties({'vf': buildLutVfArgument(path)});

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
    if (_disposed) return;
    final options = externalSubtitleOptions(subs, onDiscard: onDiscard);
    if (_disposed) return;
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
    if (_disposed || _selectedSubtitle != null) return false;
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
    if (_disposed) return false;
    _subtitleBusy = true;
    _subtitleError = null;
    notifyListeners();
    try {
      if (_disposed) return false;
      if (option.id == SubtitleOption.offId) {
        await _player.setSubtitleTrack(SubtitleTrack.no());
        if (!_disposed) _selectedSubtitle = SubtitleOption.off;
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
        if (_disposed) return false;
        final file = await _writeSubtitleFile(document);
        if (_disposed) {
          await file.delete();
          return false;
        }
        await _player.setSubtitleTrack(
          SubtitleTrack.uri(
            file.path,
            title: option.label,
            language: option.language.isEmpty ? 'auto' : option.language,
          ),
        );
        if (_disposed) {
          await file.delete();
          return true;
        }
        _selectedSubtitleDocument = document;
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
      if (!_disposed) _selectedSubtitle = option;
      return true;
    } catch (error) {
      if (!_disposed) _subtitleError = describeSubtitleFailure(error);
      return false;
    } finally {
      if (!_disposed) {
        _subtitleBusy = false;
        notifyListeners();
      }
    }
  }

  /// 清空字幕错误（用户重新选择时）。
  void clearSubtitleError() {
    if (_disposed || _subtitleError == null) return;
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
    return (_position.inMilliseconds / _duration.inMilliseconds).clamp(
      0.0,
      1.0,
    );
  }

  void _bind() {
    _subscriptions.addAll([
      _player.stream.position.listen((value) {
        if (_disposed) return;
        _position = value;
        notifyListeners();
      }),
      _player.stream.duration.listen((value) {
        if (_disposed) return;
        _duration = value;
        notifyListeners();
      }),
      _player.stream.buffer.listen((value) {
        if (_disposed) return;
        _buffered = value;
        notifyListeners();
      }),
      _player.stream.buffering.listen((value) {
        if (_disposed) return;
        _buffering = value;
        // 停止缓冲时把百分比清空：那是上一次卡顿留下的残值，留着会让
        // 下一次卡顿在引擎上报之前先闪一下旧数字。
        if (!value) _bufferingPercent = null;
        notifyListeners();
      }),
      _player.stream.bufferingPercentage.listen((value) {
        if (_disposed) return;
        // mpv 在非缓冲期也会持续上报 0；0 是真实的"还没填"，不是"没数据"，
        // 这里照收，由界面决定怎么画。
        _bufferingPercent = value.clamp(0, 100).toDouble();
        notifyListeners();
      }),
      _player.stream.playing.listen((value) {
        if (_disposed) return;
        _playing = value;
        notifyListeners();
      }),
      _player.stream.completed.listen((value) {
        if (_disposed) return;
        _completed = value;
        notifyListeners();
      }),
      _player.stream.volume.listen((value) {
        if (_disposed) return;
        _volume = value;
        notifyListeners();
      }),
      _player.stream.rate.listen((value) {
        if (_disposed) return;
        _rate = value;
        notifyListeners();
      }),
      _player.stream.videoParams.listen((value) {
        if (_disposed) return;
        _videoParams = value;
        notifyListeners();
      }),
      _player.stream.audioParams.listen((value) {
        if (_disposed) return;
        _audioParams = value;
        notifyListeners();
      }),
      _player.stream.audioBitrate.listen((value) {
        if (_disposed) return;
        _audioBitrate = value;
        notifyListeners();
      }),
      _player.stream.width.listen((value) {
        if (_disposed) return;
        _videoWidth = value;
        notifyListeners();
      }),
      _player.stream.height.listen((value) {
        if (_disposed) return;
        _videoHeight = value;
        notifyListeners();
      }),
      _player.stream.error.listen((message) {
        if (_disposed) return;
        _lastEngineError = message;
        // 非致命告警（无声卡/无 GPU）不应被当成加载失败：加载结果以 duration 判定。
        notifyListeners();
      }),
      _player.stream.tracks.listen((tracks) {
        if (_disposed) return;
        _tracks = tracks;
        _updateEmbeddedSubtitles(tracks.subtitle);
        if (_disposed) return;
        notifyListeners();
      }),
      _player.stream.track.listen((track) {
        if (_disposed) return;
        _syncSelectedSubtitle(track.subtitle);
        if (_disposed) return;
        notifyListeners();
      }),
    ]);
  }

  /// 播放器上报的内嵌字幕轨变化（切集/换片后重新计算菜单）。
  void _updateEmbeddedSubtitles(List<SubtitleTrack> tracks) {
    if (_disposed) return;
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
    if (_disposed) return;
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
    Duration timeout = playerLoadTimeout,
    Duration firstFrameTimeout = const Duration(seconds: 5),
    bool awaitFirstFrame = true,
    PlaybackDiagnosticsBuilder? diagnosticsBuilder,
    String? siteKey,
    String? flag,
    String? episodeName,
  }) async {
    if (_disposed) {
      return _failure(
        url,
        'PlayerController is disposed',
        Stopwatch()..start(),
      );
    }
    _loading = true;
    _completed = false;
    _lastEngineError = null;
    _currentUrl = url;

    // 诊断：记录入口地址与注入 Header（输出时统一脱敏，§23）。
    final builder =
        diagnosticsBuilder ??
        PlaybackDiagnosticsBuilder(
          siteKey: siteKey,
          flag: flag,
          episodeName: episodeName,
        );
    _diagnosticsBuilder = builder;
    builder.setFinalUrl(url);
    builder.setHeaders(headers);
    notifyListeners();

    if (_disposed) {
      return _failure(
        url,
        'PlayerController is disposed',
        Stopwatch()..start(),
      );
    }
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
        onTimeout: () =>
            throw TimeoutException('load timeout after ${timeout.inSeconds}s'),
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
      if (!_disposed) {
        _lastOutcome = outcome;
        _loading = false;
        _retryCount = 0;
        _finishDiagnostics(
          succeeded: true,
          loadElapsed: loadElapsed,
          firstFrame: firstFrame,
        );
        notifyListeners();
      }
      return outcome;
    } on TimeoutException catch (error) {
      final outcome = _failure(
        url,
        loadError ?? error.message ?? 'timeout',
        stopwatch,
      );
      if (!_disposed) {
        _lastOutcome = outcome;
        _loading = false;
        _finishFailureDiagnostics(outcome);
        notifyListeners();
      }
      return outcome;
    } catch (error) {
      final outcome = _failure(url, loadError ?? '$error', stopwatch);
      if (!_disposed) {
        _lastOutcome = outcome;
        _loading = false;
        _finishFailureDiagnostics(outcome);
        notifyListeners();
      }
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
      builder.addStage(PlaybackStage.firstFrame, loadElapsed, note: '首帧未单独观测到');
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
    Duration timeout = playerLoadTimeout,
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
    if (_disposed || outcome.succeeded) return outcome;
    if (outcome.failureKind != PlayerFailureKind.timeout &&
        outcome.failureKind != PlayerFailureKind.network) {
      return outcome;
    }
    if (_retryCount >= 1) return outcome;
    _retryCount++;
    final retryStopwatch = Stopwatch()..start();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (_disposed) return outcome;
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

  Future<void> seek(Duration target) {
    onSeek?.call(target);
    return _player.seek(target);
  }

  Future<void> seekBy(Duration delta) {
    final next = _position + delta;
    if (next < Duration.zero) return seek(Duration.zero);
    if (_duration > Duration.zero && next > _duration) {
      return seek(_duration);
    }
    return seek(next);
  }

  Future<void> setVolume(double value) async {
    if (_disposed) return;
    final clamped = value.clamp(0.0, 100.0);
    if (clamped > 0) _volumeBeforeMute = clamped;
    _muted = clamped == 0;
    await _player.setVolume(clamped);
    if (_disposed) return;
    notifyListeners();
  }

  /// 静音切换：静音时记住原音量，取消静音时恢复，不使用硬编码 100。
  Future<void> toggleMute() async {
    if (_disposed) return;
    if (_muted || _volume <= 0) {
      _muted = false;
      final restored = _volumeBeforeMute <= 0 ? 100.0 : _volumeBeforeMute;
      await _player.setVolume(restored);
    } else {
      _volumeBeforeMute = _volume;
      _muted = true;
      await _player.setVolume(0);
    }
    if (_disposed) return;
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
    if (_disposed) return;
    _disposed = true;
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

/// 从 mpv `demuxer-cache-state` 的 JSON 串里取出 `raw-input-rate`。
///
/// **不做整体 JSON 解析、不引入 JSON 依赖**，理由是三条：
/// - 这串是 mpv 自己的 JSON 风格输出（键名带引号、数字不带空格、顺序随
///   版本变），字段会随 mpv 版本增减，整体解析会因无关字段把有用的那个
///   也一起废掉；
/// - 要的只有一个数，定向查找对 mpv 字段增删是免疫的；
/// - 单测要能直接用真实抓到的原串当输入，正则比"喂 JSON 库"更贴事实。
///
/// 键名必须完整匹配：`"raw-input-rate-foo"` 不算命中（正则要求键名右引号
/// 紧跟 `rate`）。值不是数字（`null`、`"abc"`）交给 [parseByteRate] 判空。
double? parseRawInputRateFromCacheState(String? cacheStateJson) {
  if (cacheStateJson == null) return null;
  final match = _rawInputRateField.firstMatch(cacheStateJson);
  if (match == null) return null;
  return parseByteRate(match.group(1));
}

/// `demuxer-cache-state` 里 `raw-input-rate` 字段的值。
///
/// 取到逗号/右花括号/空白为止：mpv 在该字段后面必然跟分隔符，这条边界
/// 同时挡住了把后续字段一起吞进去。
final RegExp _rawInputRateField = RegExp(r'"raw-input-rate"\s*:\s*([^,}\s]+)');

/// 双数据源的落定规则：首选优先，首选没值才看回退。
///
/// 单独一个纯函数是为了让"回退顺序"能在单测里断言（`getProperty` 需要
/// 真引擎，测不了）。[fallbackRaw] 为 null 表示**没有去读**回退属性。
double? resolveNetworkRate(double? primary, String? fallbackRaw) =>
    primary ?? parseByteRate(fallbackRaw);

/// 把 mpv 的 `raw-input-rate` 原始串解析成字节/秒；解析不出来就是 null。
///
/// 为什么单独一个纯函数：这个解析要在单测里覆盖 `nan` / `inf`
/// / 空串 / 负数 / 带小数的各种形态，而 `getProperty` 需要真引擎。
/// 抽出来之后剩下的唯一不知情点就是"引擎给的是不是这个串"。
///
/// 返回 null 的四种情形都**不是 0**：0 会被界面上读成"网速为零（卡了）"，
/// 与"没数据"完全不是一回事（见 `formatByteRate`）。
double? parseByteRate(String? raw) {
  if (raw == null) return null;
  final text = raw.trim();
  if (text.isEmpty) return null;
  final value = double.tryParse(text);
  if (value == null || !value.isFinite || value < 0) return null;
  return value;
}

/// 把字节/秒格式化成屏显用的短串：`12.8 MB/s` / `860 KB/s` / `—`。
///
/// 三条规则，每条都有理由：
/// - **null 显示 `—`**：取不到值时如实说"没有"，不写 0（见上）；
/// - **1000 进制**而不是 1024：这是**网络吞吐**，链路的 MB/s 是按 10^6 说的，
///   按 1024 算会让 8 Mbps 宽带显示成 `0.95 MB/s`，与运营商口径对不上；
/// - **KB/s 不带小数**：`860.3` 的精度是假的（mpv 自己就在抖），
///   而 MB/s 保留一位是因为那个量级下一位小数肉眼可见地有意义。
String formatByteRate(double? bytesPerSecond) {
  if (bytesPerSecond == null ||
      !bytesPerSecond.isFinite ||
      bytesPerSecond < 0) {
    return '—';
  }
  const kb = 1000.0;
  const mb = 1000.0 * 1000.0;
  if (bytesPerSecond >= mb) {
    return '${(bytesPerSecond / mb).toStringAsFixed(1)} MB/s';
  }
  if (bytesPerSecond >= kb) return '${(bytesPerSecond / kb).round()} KB/s';
  return '${bytesPerSecond.round()} B/s';
}
