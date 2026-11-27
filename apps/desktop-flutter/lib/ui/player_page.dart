/// 播放器页（§17.3）。
///
/// 包含：播放器画面、标题、线路选择、剧集列表、播放/暂停、进度条、音量、倍速、
/// 全屏、上一集/下一集、加载状态、错误提示，以及键盘快捷键（§10.3、§17.4）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_error.dart';
import '../core/danmaku.dart';
import '../core/danmaku_style.dart';
import '../core/danmaku_match.dart';
import '../core/danmaku_settings.dart';
import '../core/history_view.dart';
import '../core/episode_aggregation.dart';
import '../core/lut.dart';
import '../core/mpv_properties.dart';
import '../core/osd_config.dart';
import '../core/osd_diagnostics.dart';
import '../core/osd_style.dart';
import '../core/playback.dart';
import '../core/playback_diagnostics.dart';
import '../core/playback_error_gate.dart';
import '../core/playback_fallback.dart';
import '../core/playback_line_match.dart';
import '../core/playback_request.dart';
import '../core/playback_queue.dart';
export '../core/playback_request.dart';
import '../core/playback_repeat.dart';
import '../core/player_buttons.dart';
import '../core/player_options.dart';
import '../core/player_tracks.dart';
import '../core/protocol.dart';
import '../core/seek_recovery.dart';
import '../core/skip_plan.dart';
import '../core/skip_segments.dart';
import '../core/sleep_timer.dart';
import '../core/source_swap.dart';
import '../core/subtitle.dart';
import '../core/subtitle_provider.dart';
import '../core/subtitle_style.dart';
import '../core/tmdb_playback.dart';
import '../core/tmdb_season.dart';
import '../services/intro_skip/provider.dart';
import '../services/intro_skip/registry.dart';
import '../services/danmaku_auto_pick.dart';
import '../services/danmaku_library_service.dart';
import '../services/danmaku_service.dart';
import '../services/external_player.dart';
import '../services/live_danmaku_session.dart';
import '../services/lut_store.dart';
import '../services/subtitle_asset_store.dart';
import '../services/subtitle_match_service.dart';
import '../state/app_state.dart';
import 'app.dart';
import 'danmaku_search_dialog.dart';
import 'settings_overview_page.dart';
import 'intro_skip_options_page.dart';
import 'subtitle_search_dialog.dart';
import 'subtitle_settings_page.dart';
import 'ai_integration_widgets.dart';
import 'audio_ai/audio_ai_controls.dart';
import '../services/ai_integration.dart';
import '../services/karaoke/track_repository.dart';
import '../services/karaoke/karaoke_controller.dart';
import '../core/audio_ai/audio_ai.dart';
import '../services/subtitle_service.dart';
import '../core/ai_content/recommendation.dart';
import 'danmaku_engine_view.dart';
import 'danmaku_settings_page.dart';
import 'danmaku_settings_sheet.dart';
import 'player_button_config_page.dart';
import 'player_context_menu.dart';
import 'external_player_picker_dialog.dart';
import 'player_controller.dart';
import 'player_episode_panel.dart';
import 'episode_version_dialog.dart';
import 'player_queue_panel.dart';
import 'live_playback_session.dart';
import 'lut_menu.dart';
import 'lut_picker_sheet.dart';
import 'player_live_panel.dart';
import 'player_osd.dart';
import 'player_overlay.dart';
import 'player_parse_source_strip.dart';
import 'player_quality_panel.dart';
import 'theme.dart';
import 'window_mode.dart';
import 'tokens.dart';
import 'toast.dart';
part 'player_menu_sections.dart';
part 'player_playback_params.dart';
part 'player_subtitle_menu.dart';

/// 画面显示模式：保留原始比例、裁切铺满、拉伸填充或固定常用比例。
///
/// 这些模式直接映射到 media_kit_video 的 [BoxFit] / [Video.aspectRatio]，
/// 不改变媒体流本身，只改变窗口内的显示方式。
String formatPlayerLiveStatus({String? status, int? online}) =>
    [?status, if (online != null) '在线 $online'].join(' · ');

/// 双击判定窗，与 Flutter 自带的 [kDoubleTapTimeout] 对齐（300ms）。
///
/// **为什么不直接用 `GestureDetector.onDoubleTap`**：一旦注册它，Flutter 会把
/// 单击挂起整整一个判定窗再落地——仓库里
/// `integration_test/live_interaction_flow_test.dart` 记过这个坑（轮询里重复
/// 点击被识别成双击）。桌面播放器（PotPlayer / VLC）里单击是高频的传输控制，
/// 「点一下要等 0.3 秒才暂停」是明显迟滞。
///
/// 这里改为**每一击立即执行**，再自己判窗口：第 2 击把播放状态拨回第 1 击前
/// 的值（而不是再翻转一次），同时切换全屏。净效果与 PotPlayer / VLC 一致：
/// 双击不改变播放状态、只切全屏。
const Duration kPlayerDoubleClickWindow = kDoubleTapTimeout;

/// 画面点击的语义（桌面播放器惯例，`design/01` §4.6）。
///
/// 与上游安卓控制层**有意不同**：安卓里单击只显隐控制栏、双击才全屏；
/// 桌面上控制栏由指针移动唤醒、静止 3 秒自动隐藏（`design/01` §4.4），
/// 单击让给传输控制。这个差异是产品决策，不是疏漏。
enum PlayerGestureAction { togglePlayback, togglePlaybackAndFullscreen }

/// 距上一击不超过 [kPlayerDoubleClickWindow] 即视为双击。
PlayerGestureAction resolvePlayerGesture({required bool doubleClick}) =>
    doubleClick
    ? PlayerGestureAction.togglePlaybackAndFullscreen
    : PlayerGestureAction.togglePlayback;

/// 画面双击判定器：只回答「这一击算不算双击」，不碰播放器。
///
/// 单独成类而不是塞进页面状态：判定窗是**有状态**的纯计时逻辑，抽出来之后
/// L1 用例可以用假时钟直接推进（`testWidgets` 里的 [Timer] 就是假的），
/// 不必挂一个真实播放器。
class PlayerDoubleClickGate {
  PlayerDoubleClickGate({this.window = kPlayerDoubleClickWindow});

  /// 判定窗长度。
  final Duration window;

  Timer? _pending;
  bool? _rightSide;

  /// 登记一次点击，返回它是否与上一击在同侧构成双击。
  ///
  /// 双击成立后窗口立即重置：第 3 击属于新的一轮，不能继续被当成双击。
  bool registerTap({bool rightSide = false}) {
    final doubleClick =
        (_pending?.isActive ?? false) && _rightSide == rightSide;
    _pending?.cancel();
    _rightSide = doubleClick ? null : rightSide;
    _pending = doubleClick ? null : Timer(window, () => _pending = null);
    return doubleClick;
  }

  /// 释放计时器（页面 dispose 时调用，避免用例留下 pending timer）。
  void dispose() {
    _pending?.cancel();
    _pending = null;
  }
}

/// 拖动进度条时的暂停/续播判定器：只回答「该不该 pause / play」，不碰播放器。
///
/// 与 [PlayerDoubleClickGate] 同样单独成类：语义全在"上一次 begin 记下了
/// 什么"，抽出来后 L1 用例不必挂真实播放器就能把四种情形走一遍。
///
/// 为什么必须记住拖动**前**的播放状态：松手时若一律 `play()`，等于替一个
/// 本来就暂停着的用户点了播放；这不是"恢复"，是改变了用户意图。
class PlayerDragPauseGate {
  /// 本次拖动开始前是否在播；null 表示当前没有进行中的拖动。
  bool? _wasPlaying;

  /// 登记一次拖动开始，返回 true 表示"应当 pause()"。
  ///
  /// 重复调用（页面重建、乱序事件）返回 false 且**不覆盖**已记录的值：
  /// 覆盖会把"拖动前本就暂停"读成"松手要播"。
  bool begin({required bool playing}) {
    if (_wasPlaying != null) return false;
    _wasPlaying = playing;
    return playing;
  }

  /// 登记一次拖动结束，返回 true 表示"应当 play()"。
  ///
  /// 无条件清状态：没 begin 过就 end（例如拖动中途切了片源）返回 false。
  bool end() {
    final wasPlaying = _wasPlaying;
    _wasPlaying = null;
    return wasPlaying ?? false;
  }

  /// 丢弃进行中的拖动（换台/换媒等"这次拖动已经不算数"的场合）。
  ///
  /// 没有它时残留的 `_wasPlaying` 有两种坏结果：下一次 begin() 被判成重复
  /// 而静默失效（不再暂停），以及下一次 end() 拿着旧状态强行 play()——
  /// 正是本类要避免的"替暂停着的用户点播放"。
  void reset() => _wasPlaying = null;
}

enum PlayerVideoFitMode {
  contain('原始比例', BoxFit.contain, null),
  cover('裁切铺满', BoxFit.cover, null),
  fill('拉伸填充', BoxFit.fill, null),
  ratio16x9('固定 16:9', BoxFit.contain, 16 / 9),
  ratio4x3('固定 4:3', BoxFit.contain, 4 / 3);

  const PlayerVideoFitMode(this.label, this.fit, this.aspectRatio);

  final String label;
  final BoxFit fit;
  final double? aspectRatio;
}

/// 字幕样式的渲染投影：core 的 [SubtitleStyle] → media-kit 的视图配置。
///
/// 样式模型在 `core/subtitle_style.dart`（core 不能依赖 Flutter，颜色以
/// 0xAARRGGBB 落盘），这里只负责把它翻成 [SubtitleViewConfiguration]：
/// 默认透明底 + 黑色描边，避免视频上出现整块黑色背景。
extension SubtitleStyleView on SubtitleStyle {
  List<Shadow> get shadows {
    if (outlineWidth <= 0) return const [];
    final d = outlineWidth.clamp(0.5, 4.0).toDouble();
    return [
      for (final offset in [
        Offset(-d, -d),
        Offset(0, -d),
        Offset(d, -d),
        Offset(-d, 0),
        Offset(d, 0),
        Offset(-d, d),
        Offset(0, d),
        Offset(d, d),
      ])
        Shadow(color: Colors.black, offset: offset, blurRadius: 0),
    ];
  }

  SubtitleViewConfiguration get configuration => SubtitleViewConfiguration(
    style: TextStyle(
      height: 1.35,
      fontSize: 32 * textScale,
      color: Color(textColorValue),
      fontWeight: FontWeight.w500,
      backgroundColor: Colors.black.withValues(alpha: backgroundOpacity),
      shadows: shadows,
    ),
    textAlign: TextAlign.center,
    padding: EdgeInsets.fromLTRB(16, 0, 16, bottomPadding),
  );
}

// `subtitleColorChoices` 已搬到 `player_subtitle_menu.dart`（同一 library 的 `part`，弹层与菜单仍共用）。

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.state,
    required this.request,
    this.queue,
    this.queueItemKey,
    this.danmakuLoader,
    this.onLiveSourceFallback,
    this.liveSession,
    this.externalPlayerStarter,
    this.clock,
  });

  final AppState state;
  final PlaybackRequest request;
  final DateTime Function()? clock;
  final PlaybackQueue? queue;
  final String? queueItemKey;
  final LivePlaybackSession? liveSession;
  final Future<Process> Function(String executable, List<String> arguments)?
  externalPlayerStarter;

  /// 直播源级回退（Phase 9）：当前源所有线路都失败时，向调用方要下一个
  /// 同名频道的播放请求；返回 null 表示没有可回退的源。
  final Future<PlaybackRequest?> Function()? onLiveSourceFallback;

  /// 弹幕加载器；测试可注入替身，默认自建 [DanmakuService]。
  final DanmakuLoader? danmakuLoader;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WindowListener {
  /// LUT 预设仓库：应用级单例挂在 AppState 上，播放页/面板/设置页共用。
  LutStore get _lutStore => widget.state.lutStore;
  late PlayerController _controller;
  late PlaybackRequest _request;
  VoidCallback? _releaseProxySession;
  bool _playLinesRequested = false;
  int _playLinesRevision = 0;
  String? _queueItemKey;
  String? _pendingQueueItemKey;
  int? _pendingQueueStep;
  bool _pendingQueueAutomatic = false;
  Duration? _queueRestorePosition;
  bool? _queueRestorePlaying;

  bool get _hasQueue => widget.queue != null && !_isLive && !_isCatchup;
  int get _queueIndex =>
      widget.queue?.snapshot.items.indexWhere(
        (item) => item.key == _queueItemKey,
      ) ??
      -1;
  bool get _queueCanGoNext =>
      _queueIndex >= 0 &&
      (_queueIndex + 1 < widget.queue!.snapshot.items.length ||
          widget.queue!.snapshot.hasMore);

  void _onQueueChanged() {
    if (mounted) setState(() {});
  }

  final FocusNode _playerFocus = FocusNode(debugLabel: 'player');
  bool _livePanelOpen = false;
  LiveChannel? _linePanelChannel;
  bool _linePanelFollowsPlaying = false;
  int _sessionRevision = 0;
  bool _liveOpenInFlight = false;
  bool get _isLive =>
      widget.liveSession != null && widget.liveSession!.requestProgram == null;
  bool get _isCatchup =>
      widget.liveSession?.requestProgram != null || _request.flag == '回看';
  bool get _hasLivePanels => _livePanelOpen || _linePanelChannel != null;
  bool _progressReady = false;

  /// 引擎时长的诊断基线（毫秒）；-1 表示本次播放还没记过。
  ///
  /// 只在**真正写日志时**前进，所以一个刚变化、又被 1 秒节流挡下的值会留到
  /// 下一次通知（位置每 250ms 一次）补记，不会把最终值丢掉。
  int _loggedDurationMs = -1;
  DateTime? _lastDurationLogAt;

  /// 本次播放是否已经记过「已播时间超过引擎总长」。
  bool _loggedOverrun = false;
  int _mediaGeneration = 0;

  /// 一次跳转尝试（§3.2）：原位置 + 目标，失败时才有「重试目标 / 返回原位置」。
  SeekRecovery? _seekRecovery;
  DateTime get _recoveryNow => (widget.clock ?? DateTime.now)();

  /// 已经判定失败的跳转；非 null 时画面上挂恢复出口。
  SeekRecovery? _seekRecoveryFailure;
  Duration? _seekRecoveryLastPosition;
  bool _seekRecoveryExcluded = false;
  Timer? _recoveryTicker;

  /// 运行中引擎错误的确认闸门（§3.3）：位置真的停住才算播放失败。
  PlaybackErrorGate _errorGate = PlaybackErrorGate();

  /// 只消费真实引擎错误事件，不把留存文本当成新事件。
  int _errorGateObservedRevision = 0;

  /// 当前失败提示是不是闸门写进去的：只有它才可以被「错误自愈」撤销。
  bool _errorGateOwnedLoadError = false;
  PlayerAudioAiSession? _audioAi;
  StreamSubscription<RealtimeSubtitleState>? _audioStateSubscription;
  Future<void> _aiSubtitleQueue = Future<void>.value();
  SubtitleOption? _originalAiSubtitle;
  bool _audioPanelVisible = false;
  String _audioLanguage = 'en';
  KaraokePitchTrack? _karaokeTrack;
  List<TimedLyricLine> _karaokeLines = const [];
  bool _karaokeVisible = false;
  int _qualitySelectionRevision = 0;
  bool _fullscreen = false;

  /// 本页是否亲手把窗口切进了全屏。
  ///
  /// 只有它为 true 时 dispose() 才恢复窗口——启动参数
  /// --fullscreen=true 是应用级全屏，播放器并不拥有它。
  bool _enteredFullscreen = false;

  /// 返回被 PopScope 拦下后，恢复窗口期间忽略重复的返回请求。
  bool _popAfterRestore = false;
  bool _controlsVisible = true;
  Timer? _saveTimer;
  Timer? _controlHideTimer;

  /// 画面双击判定（见 [PlayerDoubleClickGate]）。
  final PlayerDoubleClickGate _clickGate = PlayerDoubleClickGate();
  final GlobalKey _videoGestureKey = GlobalKey();

  /// 单击画面之前的播放状态（优先使用尚未获引擎确认的点击意图）。
  ///
  /// 双击的第 2 击用它确定最终状态（播放切换之外的动作保持原状态）。不能改成
  /// 再调一次 `playOrPause()`：`isPlaying` 由引擎事件流异步回传，同一 tick
  /// 内两次读到的可能都是旧值，两次调用会发同一条命令，双击于是真的暂停了。
  bool? _playingBeforeFirstTap;
  bool? _gesturePlaybackIntent;
  Timer? _gesturePlaybackTimer;
  StreamSubscription<bool>? _gesturePlayingSubscription;
  String? _loadError;

  /// 本次播放已经自动回退过几次（迭代 3-C，见 [maxPlaybackFallbackAttempts]）。
  ///
  /// 只在「失败 → 自动换线路/解析源」这条链上累加：用户自己点重试、换集、换线路
  /// 都算新一轮，由 [_load] 入口按 [_fallbackPending] 清零。
  int _fallbackAttempts = 0;

  /// 下一次 [_load] 是否来自回退链（而不是用户动作）。
  ///
  /// 为什么要这个标记：回退同样走 [_openTarget] → [_load]，若不分来源，链上
  /// 第二次失败时次数会被清零，上限就永远到不了。
  bool _fallbackPending = false;

  /// 连播单次守卫（`design/03` §4.1 D1）。
  ///
  /// 一次连播未完成时忽略后续所有控制器通知，避免「一次播完连跳多集」。
  bool _advanceInFlight = false;
  ({int generation, Duration duration})? _skippedProgress;
  bool _completionPaused = false;
  bool _sleepStoppedAtCompletion = false;

  void _clearCompletionProgress() {
    _skippedProgress = null;
    _completionPaused = false;
    _sleepStoppedAtCompletion = false;
  }

  /// 「跳过片尾」afterwards 多久内算同一次跳转（我们自己的跳转不该被当成伪结束）。
  static const int _skipSeekWindowMs = 5000;

  /// 「跳过片尾」发起 seek 的时刻；这一次 seek 导致的 EOF 就是真播完。
  DateTime? _skipSeekAt;

  /// 本次 `completed` 已被判定为 seek 造成的伪结束。
  ///
  /// 一旦置位，直到引擎把 `completed` 落回 false（下一次 open / seek 会这么做）
  /// 为止都不再连播：mpv 的 `eof-reached` 在 `--keep-open=yes` 下不会自己
  /// 回落，只看「seek 之后 5 秒」会让同一个伪结束在冷静期过后又被判成真播完。
  bool _spuriousCompletion = false;

  /// 上一次位置采样（毫秒）；-1 表示还没有基线（刚换媒体）。
  int _lastPositionMs = -1;

  /// 最近一次 seed 过的 seek 次数（见 [PlayerController.seekCount]）。
  int _seenSeekCount = 0;

  /// 发生过 seek 且之后还没连续播过：本次 completed 可能是 seek 伪结束。
  bool _seekPending = false;

  /// 同一时刻只允许一个「跳转重开」在跑：并发 `_load` 会在 media_kit 的串行锁上
  /// 互相等（前一次的 open 还没放锁，后一次的 stop 已经排队），实测能把播放卡死。
  bool _reloadInFlight = false;
  Object? _seekReloadOwner;

  /// 重开期间用户又点了别处：只保留最后一次，由进行中的那一轮接力执行。
  Duration? _queuedSeekTarget;
  bool _queuedSeekPlaying = true;

  // ------------------------------------------------- Phase 9 播放增强

  /// 播放参数（缓冲/硬解/自动连播/失败回退/片头片尾开关/LUT）。
  PlayerOptions _options = const PlayerOptions.defaults();

  /// 拖动进度条与播放状态的衔接（见 [PlayerDragPauseGate]）。
  final PlayerDragPauseGate _dragPauseGate = PlayerDragPauseGate();

  /// 拖动中的"预览目标"：**不落引擎**，只在松手时 seek 一次。
  ///
  /// 每移动一格就 seek 的代价不是线性的：这条 HLS 代理单次 seek 要 1–3 秒，
  /// 几十次串行排队会把 mpv 长时间按在 `seeking=yes` 上（画面静止，
  /// 用户实测"等一会儿会自己恢复"）。频率才是根因，与拖动暂停开关无关。
  ///
  /// 非 null 期间拇指与时间标签显示它（拖到哪、读数就到哪），松手时取走并 seek；
  /// 换媒时清掉，绝不把上一部片的目标 seek 到新片上。
  ///
  /// **松手后不立刻清空**：这条代理的 seek 要 1–3 秒才落地，立刻清空会让拇指
  /// 与读数先弹回旧位置、再跳到目标。所以留到引擎位置追上为止
  /// （见 [_settleDragSeekTarget]）。
  Duration? _dragSeekTarget;

  /// 松手提交 seek 的时刻；null 表示这次拖动还没提交（仍在拖动中）。
  ///
  /// 只用来给「目标迟迟等不到引擎追上」设一条兜底时限，避免 seek 静默失败时
  /// 拇指永远钉在目标上。
  DateTime? _dragSeekCommittedAt;

  /// 判定「引擎已追上拖动目标」的窗口：进入它就把显示交还给引擎。
  static const Duration _dragSeekSettleWindow = Duration(seconds: 2);

  /// 目标最多保留这么久（seek 失败/被丢弃时的兜底）。
  static const Duration _dragSeekSettleTimeout = Duration(seconds: 15);

  /// 引擎位置追上拖动目标后，把显示交还给引擎。
  ///
  /// 只在**已提交** seek 之后才这么做：拖动进行中没有提交，位置当然还没到
  /// 目标，此时清掉会让读数中途跳回旧值。
  void _settleDragSeekTarget() {
    if (_dragSeekTarget == null || _dragSeekCommittedAt == null) return;
    final target = _dragSeekTarget!;
    final caughtUp =
        (_controller.position - target).abs() <= _dragSeekSettleWindow;
    final timedOut =
        DateTime.now().difference(_dragSeekCommittedAt!) >
        _dragSeekSettleTimeout;
    if (!caughtUp && !timedOut) return;
    setState(() {
      _dragSeekTarget = null;
      _dragSeekCommittedAt = null;
    });
  }

  /// 串行化**所有** mpv 参数写入（整表 + 只写 `af`）。
  ///
  /// 整表写入（`_applyPlaybackEnhancements` 的开播注入、`_livePatchOptions`）
  /// 也带 `af`。两条链各自并发时，较早发起、较晚落地的那一笔会把内核的 `af`
  /// 盖成旧值，出现「界面显示关、实际仍在归一」。串成一条链后，内核顺序与
  /// 用户操作顺序一致，最终值总等于最后一次操作的偏好。
  Future<void> _optionWriteQueue = Future<void>.value();

  /// 本片的**手动**片头/片尾标记（用户可改，落 DB）。
  SkipSegments _skipSegments = const SkipSegments.none();

  /// 远端标定拿回的原始段：**未折算**，时长变化后按新时长重算。
  List<RawSkipSegment> _skipRawSegments = const <RawSkipSegment>[];

  /// 本集的完整跳过计划：远端标定 ∪ 手动标记（手动优先）。
  SkipPlan _skipPlan = SkipPlan.empty;

  /// 已经处理过的段身份：每段每集只自动处理一次。
  ///
  /// 用 identity 集合而不是「片头/片尾两个布尔」：远端一集可能同时给回顾、
  /// 片头、片尾、预告四段，布尔表达不了「哪一段处理过」。
  final Set<String> _skipHandled = <String>{};

  /// 同一媒体的重开共用缓存；换集/版本后不能沿用旧时间轴。
  IntroSkipCache _skipCache = IntroSkipCache();
  Object? _skipMediaIdentity;
  int _skipLookupEpoch = 0;

  Object _skipIdentityFor(PlaybackRequest request) => (
    request.sourceKey,
    request.siteKey,
    request.vodId,
    request.episodeTarget,
    request.episodeName,
    request.flag,
    request.url,
    request.qualityIndex,
    request.tmdb?.tmdbId,
    request.tmdb?.imdbId,
    request.tmdb?.mediaType,
    request.tmdb?.seasonNumber,
    request.tmdb?.episodeNumber,
  );

  /// 本集是否已发起过远端查询（每集一次；失败也不重试，免得拖慢播放）。
  bool _skipLookupStarted = false;

  /// 折算计划时用的时长；时长变化（HLS 精化）时重算一次。
  int _skipPlanDurationMs = -1;

  /// 是否已允许自动跳过。
  ///
  /// 加载/续播期间必须先完成 seek 再判定，否则会「先跳片头、再被续播拉回」。
  bool _skipArmed = false;

  /// 循环模式（会话级，不落盘）。
  PlaybackRepeat _repeat = PlaybackRepeat.off;

  /// 本次播放是否已经尝试过「跨源回退」，避免多源之间来回跳。
  bool _sourceFallbackTried = false;

  /// 定时关闭（会话级）。
  SleepTimerPlan _sleepTimer = const SleepTimerPlan.idle();
  Timer? _sleepTicker;

  /// 最近一次字幕错误提示是否已展示，避免每次 setState 重复弹提示。
  String? _lastShownSubtitleError;

  // ---------------------------------------------------------------- 弹幕

  /// 弹幕加载器（§21 Phase 3）。
  late final DanmakuLoader _danmakuLoader;

  /// 当前集已加载的弹幕（按时间排序）。
  List<DanmakuItem> _danmakuItems = const [];

  ({int revision, Duration target})? _danmakuSeek;

  void _onDanmakuSeek(Duration position) {
    _clearCompletionProgress();
    if (mounted) {
      setState(() {
        _danmakuSeek = (
          revision: (_danmakuSeek?.revision ?? 0) + 1,
          target: position,
        );
      });
    }
    _audioAi?.seek(position);
  }

  /// 播放器**正在使用**的那条弹幕地址（对应 [_danmakuItems] 的来源）。
  ///
  /// 搜索对话框靠它标出「当前」：用户重开搜索时最想知道的是「我现在这条是从哪
  /// 来的」，而不是在几十行里自己回忆。空 = 没有正在使用的弹幕（未加载/失败/
  /// 已切集），此时 UI 不渲染任何标记。
  String? _danmakuSourceUrl;

  /// 弹幕显示设置（开关/透明度/字号）。
  DanmakuStyle _danmakuStyle = const DanmakuStyle();

  String? _danmakuError;
  String? _lastShownDanmakuError;

  /// 直播弹幕会话（§13.1「直播弹幕」）。仅当弹幕源是 `ws://`/`wss://` 时建立。
  LiveDanmakuSession? _liveSession;

  /// 当前直播源地址；与 [_danmakuSourceUrl] 分开，搜索对话框仍只认点播地址。
  String? _liveSourceUrl;

  /// 弹层打开时的媒体代次；切集后旧弹层里的选源请求必须作废。
  int? _danmakuSheetGeneration;

  /// 已收到的直播弹幕（保留最近一段时间，过期条目会被修剪）。
  List<DanmakuItem> _liveItems = const [];

  /// 每条直播弹幕的接收时刻（ms）；与 `_liveItems` 一一对应，驱动生命周期。
  final Map<DanmakuItem, int> _liveReceivedAt = {};

  /// 最近一批直播弹幕到达的墙钟时刻（ms），作为渲染时钟。
  int _liveNowMs = 0;

  /// 直播弹幕连接状态与在线人数（用于 UI 展示）。
  String? _liveStatus;
  int? _liveOnline;

  /// 驱动直播弹幕逐帧重绘的定时器（仅在会话存活期间运行）。
  Timer? _liveTicker;

  /// 最近一次播放诊断快照（§23），用于播放器内展示与复制。
  PlaybackDiagnostics? _diagnostics;

  /// 当前画面显示模式，不改变原始媒体流。
  PlayerVideoFitMode _videoFitMode = PlayerVideoFitMode.contain;

  /// 本集（含线路）记住的轨道选择；每次 [_load] 重读。
  final Map<PlayerTrackSlot, TrackChoice> _rememberedTrackChoices = {};

  /// 已经应用过记忆的槽：引擎在一次加载里会多次上报轨道表（先空表、
  /// 再补齐，中途切轨还会再报），每次都重新 set 会把用户的手动切换顶回去。
  ///
  /// **只有真正命中并调用了 setTrack 才加进来**：表非空不代表能匹配上
  /// （首帧只有 `auto` 这类伪轨时三级回落必然返回 null），提前标记会让该槽
  /// 在本集内永久失去重试机会。
  final Set<PlayerTrackSlot> _appliedTrackChoices = {};

  /// 各槽上一次尝试恢复时看到的轨道 id 列表（按引擎上报顺序）。
  ///
  /// 未命中时不标记已应用，但也不能任由每次 notifyListeners 都重算+写日志：
  /// 只有轨道集合真的变了（引擎补齐了真实轨）才值得再试一次。
  final Map<PlayerTrackSlot, List<String>> _lastTriedTrackIds = {};

  /// 字幕显示样式（P1-4 起从偏好存储初始化，改动即时写盘）。
  SubtitleStyle _subtitleStyle = SubtitleStyle.defaults;

  /// 屏显样式（P1-4）：字号缩放与整层不透明度。
  OsdStyle _osdStyle = OsdStyle.defaults;
  double? _gestureRateBeforeLongPress;

  /// 最近一次长按手势请求的倍速（仅供测试观测，生产代码不读）。
  double? _lastGestureSpeed;

  /// 右键菜单的锚点；null 表示菜单关闭。
  Offset? _contextMenuAnchor;

  /// 屏显的时钟基准；由 [_osdTimer] 每秒推进。
  ///
  /// 取值统一走 [debugOsdClockOverride]（默认 null，即真实时间），
  /// 好让视觉证据采集能冻结时钟、让截图可复核。
  DateTime _osdNow = debugOsdClockOverride ?? DateTime.now();

  /// 屏显刷新循环（时钟/进度/诊断）。
  ///
  /// **只在需要时运行**：屏显全关且控制栏隐藏时停止（`design/02` §4.3），
  /// 否则一个每秒空转的 Timer 会在每个用例里留下 pending timer。
  Timer? _osdTimer;

  @override
  void initState() {
    super.initState();
    _request = widget.request;
    _queueItemKey = widget.queueItemKey;
    widget.queue?.addListener(_onQueueChanged);
    _sessionRevision = widget.liveSession?.playbackRevision ?? 0;
    final savedFit = widget.state.playerVideoFitModeFor(
      siteKey: _request.siteKey,
      vodId: _request.vodId,
    );
    if (savedFit != null) {
      for (final mode in PlayerVideoFitMode.values) {
        if (mode.name == savedFit) {
          _videoFitMode = mode;
          break;
        }
      }
    }
    _danmakuLoader = widget.danmakuLoader ?? DanmakuService();
    _danmakuStyle = widget.state.danmakuStyle;
    _subtitleStyle = widget.state.subtitleStyle;
    _osdStyle = widget.state.osdStyle;
    _options = widget.state.playerOptions;
    _skipSegments = widget.state.skipSegmentsFor(
      siteKey: _request.siteKey,
      vodId: _request.vodId,
    );
    _controller = PlayerController(
      observedMediaFormatFor: widget.state.proxyObservedFormatFor,
      initialVolume: widget.state.hasExplicitPlayerVolume
          ? widget.state.playerVolume
          : null,
      initialResumeVolume: widget.state.playerResumeVolume,
      onVolumeChanged: _rememberVolume,
      onSeek: _onDanmakuSeek,
    )..addListener(_onControllerChanged);
    _bindGesturePlaybackStream();
    windowManager.addListener(this);
    widget.liveSession?.addListener(_onPlaybackSessionChanged);
    _osdNow = debugOsdClockOverride ?? DateTime.now();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncOsdTimer();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _touchControls();
      _load();
      unawaited(_ensurePlayLines());
    });
  }

  @override
  void didUpdateWidget(covariant PlayerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.liveSession != widget.liveSession) {
      oldWidget.liveSession?.removeListener(_onPlaybackSessionChanged);
      widget.liveSession?.addListener(_onPlaybackSessionChanged);
      _sessionRevision = widget.liveSession?.playbackRevision ?? 0;
    }
    final queueChanged = oldWidget.queue != widget.queue;
    if (queueChanged) {
      oldWidget.queue?.removeListener(_onQueueChanged);
      widget.queue?.addListener(_onQueueChanged);
    }
    if (oldWidget.request == widget.request &&
        !queueChanged &&
        oldWidget.queueItemKey == widget.queueItemKey) {
      return;
    }
    _beginMediaTransition();
    _queueItemKey = widget.queueItemKey;
    _pendingQueueItemKey = null;
    _pendingQueueStep = null;
    _request = widget.request;
    _playLinesRequested = false;
    _playLinesRevision++;
    if (_hasQueue) {
      _queueRestorePosition = _request.startPosition;
      _clearQueueMediaView();
    }
    _sessionRevision = widget.liveSession?.playbackRevision ?? 0;
    _episodesCache = const [];
    unawaited(_load());
    unawaited(_ensurePlayLines());
  }

  /// 历史入口没有线路时先播再补；完整命中当前集才开放选集，歧义就不猜。
  ///
  /// 用户看到的是「播放器里没有选集按钮」，而这里每个提前返回都是**静默**的：
  /// 没有日志就只能让站点再跑一遍才知道卡在哪。因此每个出口各留一条 debug，
  /// 且只记分类与数量，不输出完整 URL/Header。
  Future<void> _ensurePlayLines() async {
    if (_playLinesRequested) {
      _logPlayLinesSkip('本次会话已请求过线路补齐');
      return;
    }
    if (widget.liveSession != null) {
      _logPlayLinesSkip('直播会话');
      return;
    }
    // 本地文件没有站点：显式短路，别依赖 `siteByKey('local-file')` 恰好查不到。
    // 后者只在配置里没有同名站源时成立，一旦用户的配置里真有 key 为 `local-file`
    // 的站点，本地播放就会拿磁盘路径去问它。
    if (_request.isLocal) {
      _logPlayLinesSkip('本地文件播放没有站点线路');
      return;
    }
    if (_hasQueue) {
      _logPlayLinesSkip('目录连播队列自带选集');
      return;
    }
    if (_request.playLines.isNotEmpty) {
      _logPlayLinesSkip('请求已自带线路 lines=${_request.playLines.length}');
      return;
    }
    if (_request.siteKey.trim().isEmpty || _request.vodId.trim().isEmpty) {
      // 空身份时 site/vod 由 _logPlayLinesSkip 统一带上，这里不再重复。
      _logPlayLinesSkip('请求缺少站源身份');
      return;
    }
    _playLinesRequested = true;
    final request = _request;
    final revision = _playLinesRevision;
    // 起播清种子、添加字幕、同集重试都会换请求对象，不能据 identical 误丢同集。
    // 外部请求更替单独计代次：即使复用旧对象，迟到的详情也不能串进新会话。
    //
    // 返回**第一个**不一致的字段名而不是 bool：补齐结果被丢弃时，日志要能直接
    // 指出是哪一处变了（换集？换片？切到外部源？），否则只剩「没补上」。
    String? mismatch() {
      if (!mounted) return 'unmounted';
      if (widget.liveSession != null) return 'liveSession';
      if (_hasQueue) return 'queue';
      // 先比语义字段再比代次：换集同时会改 vodId 与代次，只报代次等于没说清。
      if (_request.siteKey != request.siteKey) return 'siteKey';
      if (_request.vodId != request.vodId) return 'vodId';
      if (_request.sourceKey != request.sourceKey) return 'sourceKey';
      // 入口目标可能是完整播放地址，只记字段名。
      if (_request.episodeTarget != request.episodeTarget) {
        return 'episodeTarget';
      }
      if (revision != _playLinesRevision) return 'revision';
      return null;
    }

    bool isCurrent() => mismatch() == null;
    widget.state.log.debug(
      '开始补齐选集入口 site="${request.siteKey}" vod="${request.vodId}" '
      'flag="${request.flag}"',
      scope: 'player',
    );
    final started = DateTime.now();
    final fetched = await widget.state.playLinesForRecord(
      siteKey: request.siteKey,
      vodId: request.vodId,
      vodName: request.vodName,
      sourceKey: request.sourceKey,
      isCurrent: isCurrent,
    );
    final elapsed = DateTime.now().difference(started).inMilliseconds;
    final stale = mismatch();
    if (stale != null) {
      // 页面已经卸载时连日志都不落：State 已 dispose，没有任何用户可见结果，
      // 落一条「过期」只会把「用户自己关掉了播放器」写成缺陷。
      if (stale != 'unmounted') {
        widget.state.log.debug(
          '无选集入口：补齐结果已过期 field=$stale vod="${request.vodId}" '
          'elapsed=${elapsed}ms',
          scope: 'player',
        );
      }
      return;
    }
    final lines = fetched?.lines ?? const <VodPlayLine>[];
    widget.state.log.debug(
      '补齐线路取回 vod="${request.vodId}" lines=${lines.length} '
      'routes=${fetched?.routes.length ?? 0} elapsed=${elapsed}ms',
      scope: 'player',
    );
    if (lines.isEmpty || _request.playLines.isNotEmpty) {
      widget.state.log.debug(
        '无选集入口：站点详情没有可用线路 vod="${request.vodId}" '
        'lines=${lines.length}',
        scope: 'player',
      );
      return;
    }
    final current = _request;
    final target = resolveHistoryTarget(
      historyFlag: current.flag,
      historyEpisodeId: current.episodeTarget,
      historyEpisodeName: current.episodeName,
      lines: lines,
    );
    if (!target.matched) {
      widget.state.log.debug(
        '无选集入口：线路里定位不到当前集 vod="${request.vodId}" '
        'flag="${current.flag}" episode="${current.episodeName}" '
        'lines=${lines.length}',
        scope: 'player',
      );
      return;
    }
    final line = lines.where((line) => line.flag == target.flag).firstOrNull;
    if (line == null || line.episodes.isEmpty) {
      // 按钮的渲染条件是「`_request.flag` 指得到一条有分集的线路」：
      // 命中的 flag 取不到线路或分集为空时采纳它，只会得到一个空按钮。
      widget.state.log.debug(
        '无选集入口：命中线路取不到分集 vod="${request.vodId}" '
        'flag="${target.flag}" lines=${lines.length}',
        scope: 'player',
      );
      return;
    }
    final preservesSkipSession =
        _skipMediaIdentity == _skipIdentityFor(current);
    setState(() {
      // 合并到当前请求，保住详情等待期间更新过的字幕、画质与起播状态。
      // 路由必须跟着线路一起采纳：目录条目补出来的线路各自属于**不同条目**，
      // 少了路由，换集就会拿父目录的 vodId 去解析（站源判为业务错误）。
      _request = current.copyWith(
        playLines: lines,
        lineRoutes: fetched!.routesWith(current.lineRoutes),
        flag: target.flag,
        playbackFlag: line.playbackFlag,
        episodeIndex: target.episodeIndex,
        tmdb: current.tmdb,
      );
      if (preservesSkipSession) {
        // 已确认同一在播媒体的metadata规范化不使pending标定失效。
        _skipMediaIdentity = _skipIdentityFor(_request);
      }
    });
    widget.state.log.debug(
      '选集入口已补齐 vod="${request.vodId}" lines=${lines.length} '
      'flag="${target.flag}" episodeIndex=${target.episodeIndex} '
      'episodes=${line.episodes.length} elapsed=${elapsed}ms',
      scope: 'player',
    );
  }

  /// 补齐入口的提前返回原因（静默出口的统一落点）。
  void _logPlayLinesSkip(String reason) {
    widget.state.log.debug(
      '无选集入口：$reason site="${_request.siteKey}" vod="${_request.vodId}"',
      scope: 'player',
    );
  }

  void _onPlaybackSessionChanged() {
    if (!mounted) return;
    final session = widget.liveSession;
    if (session == null) return;
    if (_sessionRevision == session.playbackRevision) {
      setState(() {
        if (_linePanelFollowsPlaying && _linePanelChannel != null) {
          _linePanelChannel = session.channel;
        }
      });
      return;
    }
    _beginMediaTransition();
    _sessionRevision = session.playbackRevision;
    setState(() {
      _request = session.request;
      _episodesCache = const [];
      _danmakuItems = const [];
      _danmakuSourceUrl = null;
      _danmakuError = null;
      _loadError = null;
    });
    final revision = _sessionRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && revision == _sessionRevision) unawaited(_load());
    });
  }

  bool get _canUseChannelKeys {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    final editing =
        focusContext != null &&
        (focusContext.widget is EditableText ||
            focusContext.findAncestorWidgetOfExactType<EditableText>() != null);
    return _isLive &&
        !editing &&
        _contextMenuAnchor == null &&
        (ModalRoute.of(context)?.isCurrent ?? false);
  }

  void _stepChannelFromKeyboard(int delta) {
    if (_canUseChannelKeys) widget.liveSession!.stepChannel(delta);
  }

  void _openLivePanel() {
    final session = widget.liveSession;
    if (session == null) return;
    if (_livePanelOpen) {
      _closeLivePanels();
      return;
    }
    unawaited(session.browse(session.source));
    session.selectGroup(session.channel.group);
    setState(() {
      _livePanelOpen = true;
      _linePanelChannel = null;
      _contextMenuAnchor = null;
    });
    _touchControls();
  }

  void _openLiveLines(LiveChannel channel) {
    if (!_livePanelOpen) {
      unawaited(widget.liveSession!.browse(widget.liveSession!.source));
    }
    setState(() {
      _livePanelOpen = true;
      _linePanelChannel = channel;
      _linePanelFollowsPlaying = identical(
        channel,
        widget.liveSession!.channel,
      );
    });
    _touchControls();
  }

  void _closeLivePanels() {
    setState(() {
      _linePanelChannel = null;
      _livePanelOpen = false;
    });
    _playerFocus.requestFocus();
    _touchControls();
  }

  /// 最近这次 seek 是不是「跳过片尾」发起的。
  ///
  /// `_applySkip` 与控制器 `seek()` 在同一帧内先后执行，两者时刻只差微秒，
  /// 所以用一个短窗口判定「同一次 seek」。
  bool _isSkipSeekJustNow() {
    final at = _skipSeekAt;
    if (at == null) return false;
    return DateTime.now().difference(at).inMilliseconds < _skipSeekWindowMs;
  }

  /// 记录位置采样是否「跳变」，并在 `completed` 落回 false 时作废伪结束判定。
  ///
  /// 引擎在下一次 `open` / `seek` 都会把 `completed` 复位；不复位标志的话，
  /// 一次 seek 伪结束会永久掐掉本集的连播。
  void _trackPositionSample() {
    final currentMs = _controller.position.inMilliseconds;
    final previousMs = _lastPositionMs;
    _lastPositionMs = currentMs;
    final seekCount = _controller.seekCount;
    if (seekCount != _seenSeekCount) {
      // 新的 seek：在它落地之前到达的 completed 都可能是伪结束。
      _seenSeekCount = seekCount;
      _seekPending = true;
    } else if (previousMs >= 0 &&
        currentMs > previousMs &&
        !isPositionJump(previousMs: previousMs, currentMs: currentMs)) {
      // 在新位置连续播起来了：seek 已经落地，伪结束的因果消失。
      _seekPending = false;
    }
    if (!_controller.isCompleted) _spuriousCompletion = false;
  }

  /// 跳转重开收尾：**位置真的到达目标**才撤遮罩。
  ///
  /// 不能按流程节点撤（比如 `_progressReady`）：往后跳要的数据还没缓冲好，
  /// `keep-open` 留着的旧帧会立刻从撤掉的遮罩后面露出来，用户看到的就是
  /// 「先闪一下之前的画面，再刷新到当前进度」。往回跳走的是同连接直接 seek，
  /// 画面被新帧覆盖，所以只有往后跳会闪。
  void _maybeFinishReposition() {
    if (!_controller.isRepositioning) return;
    // 兜底：定位始终没到（线路不支持或媒体异常）时也必须把画面放出来。
    if (_controller.repositionTimedOut) {
      _controller.endReposition();
      _settleSeekRecovery();
      return;
    }
    final target = _controller.repositionTarget;
    if (target == null) return;
    // 必须用**引擎真实上报**的位置：`position` 在跳转期间是占位值，
    // 用它判断会在新首帧上屏之前就撤掉遮罩（用户看到旧帧闪一下）。
    if (!_controller.enginePositionSeen) return;
    // 光看位置不够：`start` 定位成功后引擎的 `time-pos` **立刻**就是目标值，
    // 那时画面还没解码出来。必须等引擎真的播起来（playing）。
    if (!_controller.isPlaying) return;
    final enginePosition = _controller.enginePosition;
    if ((enginePosition - target).inMilliseconds.abs() > 3000) return;
    _controller.endReposition();
    _settleSeekRecovery();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    _settleDragSeekTarget();
    _audioAi?.update(
      position: _controller.position,
      playing: _controller.isPlaying && !_controller.isBuffering,
      rate: _controller.rate,
    );
    _logEngineDurationDrift();
    setState(() {});
    _syncOsdTimer();
    // 连播改为**事件驱动**（`design/03` §4.1 D1）：
    // 旧实现在 `build()` 里排 postFrameCallback，任何一次通知（position/
    // duration/buffer/volume/… 每秒多次）只要 `isCompleted` 仍为 true 就会
    // 再排一个 `_onCompleted()`。于是「唤醒后点继续播放」这种纯重建动作
    // 也会立即跳下一集。
    _trackPositionSample();
    _maybeFinishReposition();
    _settleSeekRecovery();
    _observePlaybackError();
    _syncSkipPlanWithDuration();
    _maybeStartSkipLookup();
    _primeSkipPrefetch();
    _maybeAutoSkip();
    _maybeAdvanceOnGenuineEnd();
    _applyRememberedTrackChoices();
  }

  /// 记录「引擎上报的时长」怎么变，以及第一次被已播时间跑过的那一刻。
  ///
  /// 为什么单独记：进度条的总长完全照搬引擎（[PlayerController.duration]），
  /// 而 HLS 线路的引擎总长可能是假的——同一部两小时的片子，载入时引擎只报
  /// 1.78s / 4.14s（见 `[player] 播放结果` 的 duration 字段）。界面把这句话
  /// 当真之后，拇指走到那个很小的总长就被钳住，明明还在放却不再动。只看载入
  /// 那一个点，分不清「引擎算错」还是「清单本来就只有两分钟」，所以把变化过程
  /// 和越界时刻一起留在日志里（清单侧的段数与 Σ `#EXTINF` 由代理
  /// `[proxy] 清单形状` 行给出）。
  ///
  /// 节奏：时长每秒最多记一行——滚动窗口的清单会让引擎反复改这个值。
  void _logEngineDurationDrift() {
    final durationMs = _controller.duration.inMilliseconds;
    final positionMs = _controller.position.inMilliseconds;
    if (durationMs > 0 && durationMs != _loggedDurationMs) {
      final now = DateTime.now();
      final last = _lastDurationLogAt;
      if (last == null || now.difference(last) >= const Duration(seconds: 1)) {
        _lastDurationLogAt = now;
        final previous = _loggedDurationMs < 0
            ? '未上报'
            : '${_loggedDurationMs}ms';
        _loggedDurationMs = durationMs;
        widget.state.log.debug(
          '引擎时长 ${durationMs}ms（上次 $previous）position=${positionMs}ms',
          scope: 'player',
        );
      }
    }
    if (_loggedOverrun || durationMs <= 0 || positionMs <= durationMs) return;
    _loggedOverrun = true;
    widget.state.log.warning(
      '已播超过引擎总长 position=${positionMs}ms duration=${durationMs}ms'
      '（进度条拇指会被钳在末端，不再跟随播放）',
      scope: 'player',
    );
  }

  /// 自动跳过片头/片尾（`docs/phase9/design/01` §3）。
  ///
  /// 只读控制器状态，不重建播放器；`_skipArmed` 保证续播 seek 完成之前不判定。
  void _maybeAutoSkip() {
    if (_isLive || !_skipArmed || _loadError != null) return;
    if (_skipPlan.isEmpty) return;
    final duration = _controller.duration;
    if (duration <= Duration.zero) return;
    final decision = _skipPlan.decide(
      positionMs: _controller.position.inMilliseconds,
      durationMs: duration.inMilliseconds,
      kinds: _options.skipKinds,
      mode: _options.skipMode,
      handled: _skipHandled,
      resumeMs: _request.startPosition?.inMilliseconds ?? 0,
    );
    if (!decision.shouldSeek) return;
    final segment = decision.segment!;
    // 先记账再动作：确认框是异步的，等它回来期间每一帧位置通知都会再次命中
    // 同一段，不先登记就会连弹一串框。
    _skipHandled.add(segment.identity);
    if (decision.needsConfirm) {
      unawaited(_confirmAndSkip(segment, decision));
      return;
    }
    _applySkip(segment, decision);
  }

  /// 真正执行跳转（自动模式与「确认后再跳」共用）。
  void _applySkip(SkipSegment segment, SkipPlanDecision decision) {
    widget.state.log.info(
      '跳过${segment.kind.label} target=${decision.targetMs}ms '
      'provider=${segment.provider} openEnd=${decision.openEnd} '
      'episode=${_request.episodeName}',
      scope: 'player',
    );
    _showPlayerMessage(
      '已跳过${segment.kind.label} → ${_formatMs(decision.targetMs)}',
      kind: ToastKind.success,
    );
    if (decision.openEnd &&
        decision.targetMs >= _controller.duration.inMilliseconds &&
        !_isLive &&
        !_isCatchup) {
      unawaited(_finishSkippedEpisode());
      return;
    }
    // 这一步是应用自己发起的「跳到片尾」：跳完若紧接着 EOF，那就是本集真的
    // 看完了，不能按「seek 伪结束」挡掉连播。
    _skipSeekAt = DateTime.now();
    // 走同一条跳转通道：片尾段可能在缓冲之外，同样只能靠重开定位。
    unawaited(_seekFromUser(Duration(milliseconds: decision.targetMs)));
  }

  Future<void> _finishSkippedEpisode() async {
    if (_advanceInFlight) return;
    if (_isLive || _isCatchup || !_progressReady) return;
    final generation = _mediaGeneration;
    _advanceInFlight = true;
    _skipArmed = false;
    _skippedProgress = (generation: generation, duration: _controller.duration);
    _completionPaused = false;
    _persistProgress();
    try {
      await _controller.pause();
      if (!mounted || generation != _mediaGeneration) return;
    } finally {
      _advanceInFlight = false;
    }
    _advanceAfterCompletion();
  }

  /// `confirm` 模式先问用户（安卓 `INTRO_SKIP_CONFIRM`）。
  ///
  /// 用户点「不跳」也不再重问：这一段已记进 `_skipHandled`，否则每次位置通知
  /// 都会重新弹框，播放页会变成关不掉的弹框循环。
  Future<void> _confirmAndSkip(
    SkipSegment segment,
    SkipPlanDecision decision,
  ) async {
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('跳过${segment.kind.label}？'),
        content: Text(
          '已识别到${segment.kind.label}，跳到 ${_formatMs(decision.targetMs)}。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('不跳'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('跳过'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    _applySkip(segment, decision);
  }

  void _primeSkipPrefetch() {
    if (!widget.state.playerOptions.skipPrefetch ||
        !_options.skipPrefetch ||
        _isLive ||
        _isCatchup ||
        _controller.duration <= Duration.zero) {
      widget.state.cancelSkipPrefetch();
      return;
    }
    final position = _controller.position.inMilliseconds;
    final ordered = _skipPlan.segments.toList()
      ..sort((left, right) => left.startMs.compareTo(right.startMs));
    for (final segment in ordered) {
      if ((_options.skipKinds & segment.kind.bit) == 0 ||
          _skipHandled.contains(segment.identity)) {
        continue;
      }
      final target = segment.openEnded
          ? _controller.duration.inMilliseconds
          : segment.endMs;
      if (target <= position || target >= _controller.duration.inMilliseconds) {
        continue;
      }
      // Keep preparation close in wall time even at slow/fast playback rates.
      final leadMs = (15000 * _controller.rate.clamp(0.25, 4.0)).round();
      if (segment.startMs - position > leadMs) {
        widget.state.cancelSkipPrefetch(clearCache: false);
        return;
      }
      final uri = Uri.tryParse(_request.url);
      if (uri != null) {
        widget.state.primeSkipPrefetch([
          uri.replace(fragment: 't=${target / 1000}'),
        ]);
      }
      return;
    }
    widget.state.cancelSkipPrefetch(clearCache: false);
  }

  /// 时长首次已知或被精化时重算一次计划（尾部段折算依赖时长）。
  void _syncSkipPlanWithDuration() {
    final durationMs = _controller.duration.inMilliseconds;
    if (durationMs <= 0 || durationMs == _skipPlanDurationMs) return;
    _skipPlanDurationMs = durationMs;
    _rebuildSkipPlan();
  }

  /// 远端标定 ∪ 手动标记 → 当前计划。
  void _rebuildSkipPlan() {
    final durationMs = _controller.duration.inMilliseconds;
    _skipPlan = SkipPlan.resolve(
      _skipRawSegments,
      durationMs: durationMs,
    ).withManualOverride(manual: _skipSegments, durationMs: durationMs);
  }

  /// 每集最多发起一次远端查询；无 TMDB 身份或关了远端识别就不发。
  ///
  /// 只看 [PlayerOptions.skipRemoteEnabled]，**不看跳过模式**：模式管的是「自动跳
  /// 不跳」，而标定本身还要供给右键菜单里的手动跳过与「本集已识别到片头」的显示。
  /// 两者捆在一起会让「远端识别开着」这个开关在默认（模式 off）下形同虚设。
  /// 代价是每集一轮查询（进程内缓存按集去重，播放过程中不重发）。
  void _maybeStartSkipLookup() {
    if (_skipLookupStarted) return;
    if (!_options.skipRemoteEnabled) return;
    final tmdb = _request.tmdb;
    if (tmdb == null || !tmdb.hasIdentity) return;
    final providers = buildIntroSkipProviders(_options.skipSources);
    if (providers.isEmpty) return;
    _skipLookupStarted = true;
    final durationMs = _controller.duration.inMilliseconds;
    unawaited(
      _loadRemoteSkipSegments(
        SkipQuery(
          tmdbId: tmdb.tmdbId,
          imdbId: tmdb.imdbId,
          mediaType: tmdb.mediaType.name,
          season: tmdb.seasonNumber > 0 ? tmdb.seasonNumber : 0,
          episode: tmdb.episodeNumber > 0 ? tmdb.episodeNumber : 0,
          durationMs: durationMs > 0 ? durationMs : 0,
        ),
        providers,
        _skipLookupEpoch,
      ),
    );
  }

  Future<void> _loadRemoteSkipSegments(
    SkipQuery query,
    List<IntroSkipProvider> providers,
    int epoch,
  ) async {
    final result = await lookupIntroSkip(
      query: query,
      providers: providers,
      cache: _skipCache,
    );
    if (!mounted ||
        epoch != _skipLookupEpoch ||
        _skipIdentityFor(_request) != _skipMediaIdentity) {
      return;
    }
    setState(() {
      _skipRawSegments = result.segments;
      _rebuildSkipPlan();
    });
    widget.state.log.info(
      '片头片尾标定 ${result.segments.length} 段 '
      'cacheable=${result.cacheable} episode=${_request.episodeName}',
      scope: 'player',
    );
    // 标定到位时可能已经播过点了，立刻按当前位置判一次。
    _primeSkipPrefetch();
    _maybeAutoSkip();
  }

  SkipSegment? _manualSkipSegment(SkipKind kind) {
    final durationMs = _controller.duration.inMilliseconds;
    if (_isLive || durationMs <= 0) return null;
    final positionMs = _controller.position.inMilliseconds;
    SkipSegment? next;
    for (final segment in _skipPlan.segments) {
      if (segment.kind != kind) continue;
      final endMs = segment.openEnded ? durationMs : segment.endMs;
      if (endMs <= positionMs || endMs > durationMs) continue;
      if (segment.startMs <= positionMs) return segment;
      if (next == null || segment.startMs < next.startMs) next = segment;
    }
    return next;
  }

  Future<void> _manualSkip(SkipAction action) => _manualSkipKind(
    action == SkipAction.intro ? SkipKind.intro : SkipKind.outro,
  );

  Future<void> _manualSkipKind(SkipKind kind) async {
    final segment = _manualSkipSegment(kind);
    if (segment == null) {
      _showPlayerMessage('本集暂无可跳过的${kind.label}');
      return;
    }
    final target = segment.openEnded
        ? _controller.duration.inMilliseconds
        : segment.endMs;
    _skipHandled.add(segment.identity);
    await _controller.seek(Duration(milliseconds: target));
    widget.state.log.info(
      '手动跳过${segment.kind.label} target=$target ms '
      'provider=${segment.provider}',
      scope: 'player',
    );
  }

  /// 标记当前进度为片头/片尾。
  Future<void> _markSkipSegment(SkipAction action) async {
    final position = _controller.position.inMilliseconds;
    if (position <= 0) {
      _showPlayerMessage('当前位置为 0，无法标记', kind: ToastKind.error);
      return;
    }
    final next = action == SkipAction.intro
        ? _skipSegments.copyWith(introEndMs: position)
        : _skipSegments.copyWith(outroStartMs: position);
    final saved = await widget.state.saveSkipSegments(
      siteKey: _request.siteKey,
      vodId: _request.vodId,
      introEndMs: next.introEndMs,
      outroStartMs: next.outroStartMs,
    );
    if (!mounted) return;
    if (!saved) {
      _showPlayerMessage('保存标记失败（数据库不可用）', kind: ToastKind.error);
      return;
    }
    setState(() {
      _skipSegments = next;
      // 手动端点变了：重算计划并忘掉「处理过」，让新端点立刻生效。
      _skipHandled.clear();
      _rebuildSkipPlan();
    });
    _showPlayerMessage(
      action == SkipAction.intro
          ? '已标记片头：${_formatMs(position)}'
          : '已标记片尾：${_formatMs(position)}',
      kind: ToastKind.success,
    );
  }

  /// 清除本片标记。
  Future<void> _clearSkipSegments() async {
    final saved = await widget.state.saveSkipSegments(
      siteKey: _request.siteKey,
      vodId: _request.vodId,
    );
    if (!mounted) return;
    if (!saved) {
      _showPlayerMessage('清除标记失败（数据库不可用）', kind: ToastKind.error);
      return;
    }
    setState(() {
      _skipSegments = const SkipSegments.none();
      _skipHandled.clear();
      _rebuildSkipPlan();
    });
    _showPlayerMessage('已清除本片的片头/片尾标记', kind: ToastKind.success);
  }

  String _formatMs(int value) {
    final total = value ~/ 1000;
    final minutes = (total ~/ 60).toString().padLeft(2, '0');
    final seconds = (total % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  void _showPlayerMessage(String text, {ToastKind kind = ToastKind.info}) {
    if (!mounted) return;
    // 时长不在这里定：不传 duration，让 toast.dart 按类型取默认值
    // （error -> 30s，info/success -> 15s）。
    // 这里曾把信息/成功单独收窄到 3 秒，理由是「播放页反馈频繁，怕右下角一直有东西」；
    // 但 3 秒连「已标记片头 12:34」这种一句话都读不完，且播放页的提示多半是低频的
    // 「已标记 / 已清除」，堆积不是真问题（可见栈上限 4 条兜底）。于是回到全站同一套时长。
    showToast(text, kind: kind);
  }

  /// 连播闸门：单次守卫 + 真播完判定（`design/03` §4.1）。
  ///
  /// 四道闸门缺一不可：
  /// 1. [_advanceInFlight] 防重入（D1）：一次连播未完成时忽略后续通知；
  /// 2. [PlayerController.isCompleted] 是 media_kit 的「到达流末尾」；
  /// 3. [isGenuineEnd] 排除提前 EOF（D2）——缓存耗尽时 `duration` 往往还没取到，
  ///    此时 `completed=true` 一定是误报；
  /// 4. [isPositionJump] 排除 seek 伪结束——点击/拖动进度条到未缓冲
  ///    位置时 mpv 会短暂走到末尾，这一帧与「自然播完」的数字完全一样。
  void _maybeAdvanceOnGenuineEnd() {
    if (_advanceInFlight) return;
    if (_isLive || _isCatchup) return;
    if (!_progressReady) return;
    if (!_controller.isCompleted) return;
    if (!_isGenuineEnd()) return;
    // 第四道闸门：这次 completed 是不是被 seek 送来的。
    //
    // 点击/拖动进度条到未缓冲位置时，mpv 会短暂 `eof-reached` 并把 `time-pos`
    // 报成 `duration`，那一帧与「自然播完」在 isGenuineEnd 眼里完全一样。
    // 只靠前三道闸门，用户点一下进度条就会被当成「本集播完」而跳到下一集
    // （实测 0.4s 内发生）。判据见 [isPositionJump]。
    if (_spuriousCompletion) return;
    if (_isSkipSeekJustNow()) {
      // 「跳过片尾」是我们自己发起的跳转：它跳到片尾就是本集真的看完了。
      _skipSeekAt = null;
    } else if (_seekPending) {
      _spuriousCompletion = true;
      widget.state.log.debug(
        '连播闸门：completed 紧跟 seek（seek 伪结束），本集不连播 '
        'position=${_controller.position.inMilliseconds}ms '
        'duration=${_controller.duration.inMilliseconds}ms '
        'episode=${_request.episodeName}',
        scope: 'player',
      );
      return;
    }

    _advanceAfterCompletion();
  }

  void _advanceAfterCompletion() {
    if (_advanceInFlight ||
        _isLive ||
        _isCatchup ||
        !_progressReady ||
        _sleepStoppedAtCompletion) {
      return;
    }
    if (_sleepTimer.shouldStopOnEpisodeEnd()) {
      _sleepStoppedAtCompletion = true;
      _stopBySleepTimer();
      return;
    }
    if (_hasQueue) {
      if (_repeat == PlaybackRepeat.off && !_options.autoNext) return;
      _advanceInFlight = true;
      unawaited(
        _advanceQueue().whenComplete(() {
          _advanceInFlight = false;
          if (mounted) _controller.clearCompleted();
        }),
      );
      return;
    }

    final episodes = _episodesCache.isNotEmpty ? _episodesCache : _episodes;
    final groups = _aggregatedEpisodeGroups(episodes);
    final groupIndex = groups?.indexWhere(
      (group) => group.versions.any(
        (version) => version.sourceIndex == _request.episodeIndex,
      ),
    );
    final decision = decidePlaybackAdvance(
      repeat: _repeat,
      autoNext: _options.autoNext,
      currentIndex: groupIndex ?? _request.episodeIndex,
      episodeCount: groups?.length ?? episodes.length,
      genuineEnd: true,
    );

    if (decision.action == PlaybackAdvanceAction.stop) return;

    _advanceInFlight = true;
    unawaited(
      _performAdvance(decision).whenComplete(() {
        _advanceInFlight = false;
        // 无论连播成功还是失败，都必须复位 `completed`（`design/03` §4.1 D1）。
        //
        // 两个典型残留场景：
        // - **末集**：`_performAdvance()` 因下标无效直接返回，`_completed` 仍为
        //   true，下一次重建会再跑一遍闸门（虽然结果一样，但会刷日志、且若用户
        //   此时手动切回中间某集就会误跳）；
        // - **下一集加载失败**：失败路径已自己清过（`_load()` 的失败分支），
        //   这里是幂等兼底。
        if (mounted) _controller.clearCompleted();
      }),
    );
  }

  /// 执行连播决策（Phase 9：循环模式 > 自动连播开关）。
  Future<void> _performAdvance(PlaybackAdvance decision) async {
    if (decision.action == PlaybackAdvanceAction.replay) {
      await _replayCurrent();
      return;
    }
    final suggested = decision.nextIndex;
    if (suggested == null) return;
    final episodes = _episodesCache.isNotEmpty ? _episodesCache : _episodes;
    final groups = _aggregatedEpisodeGroups(episodes);
    if (groups != null) {
      final wrap = suggested == 0 && !(_request.tmdb?.hasSeason ?? false);
      if (wrap && groups.length == 1) {
        await _replayCurrent();
      } else {
        await _playAggregatedAdjacent(
          episodes,
          groups,
          1,
          wrap: wrap,
          pauseForSelection: false,
        );
      }
      return;
    }
    final index = _resolveAdvanceIndex(suggested, episodes);
    if (index < 0 || index >= episodes.length) return;
    await _openTarget(
      episodes[index],
      flag: _request.flag,
      episodeIndex: index,
    );
  }

  /// TMDB 季度边界：自动连播不跨季（沿用 `TmdbAutoPlay.nextIndex`）。
  ///
  /// 没有季度身份时直接采用循环/连播给出的下标（含 `all` 的回到首集）。
  int _resolveAdvanceIndex(int suggested, List<VodEpisode> episodes) {
    final identity = _request.tmdb;
    if (identity == null || !identity.hasSeason) return suggested;
    return TmdbAutoPlay.nextIndex(
      episodes: episodes,
      currentIndex: _request.episodeIndex,
      availableSeasons: [identity.seasonNumber],
      selectedSeason: identity.seasonNumber,
    );
  }

  /// 单集循环：回到开头重播（不重建播放器）。
  Future<void> _replayCurrent() async {
    _skipArmed = false;
    // 重播不再跳片头，否则会陷入「跳一次又重播」的循环；片尾仍要能跳。
    _skipHandled
      ..clear()
      ..addAll(_skipPlan.openings.map((segment) => segment.identity));
    await _controller.seek(Duration.zero);
    await _controller.play();
    _skipArmed = true;
    _controller.clearCompleted();
    widget.state.log.info(
      '单集循环重播 episode=${_request.episodeName}',
      scope: 'player',
    );
  }

  /// 开启/替换定时关闭。`idle` 表示取消。
  void _applySleepTimer(SleepTimerPlan plan) {
    _sleepTicker?.cancel();
    _sleepTicker = null;
    setState(() => _sleepTimer = plan);
    if (plan.idle) return;
    if (plan.mode == SleepTimerMode.duration) {
      _sleepTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        if (_sleepTimer.isExpired(DateTime.now())) {
          _stopBySleepTimer();
        }
      });
    }
    widget.state.log.info('定时关闭 ${plan.summary}', scope: 'player');
  }

  /// 定时到点：暂停并清除计划（只触发一次）。
  void _stopBySleepTimer() {
    _sleepTicker?.cancel();
    _sleepTicker = null;
    final wasActive = !_sleepTimer.idle;
    if (!wasActive) return;
    setState(() => _sleepTimer = const SleepTimerPlan.idle());
    unawaited(_controller.pause());
    widget.state.log.info('定时关闭生效，已暂停', scope: 'player');
    _showPlayerMessage('定时关闭已生效', kind: ToastKind.success);
  }

  /// 「真播完」判定（`design/03` §4.1 D2、P5）。
  ///
  /// 不信任 media_kit 的 `completed` 单独结论：它表示「到达流末尾」，
  /// **不区分**「正常播到片尾」与「提前 EOF」。判定公式与
  /// `SyncHistoryItem.completed` / 安卓 `PlaybackRecord.completed` 的 PC 侧重算
  /// 同源（`lib/core/playback.dart` 的 [isGenuineEnd]），因此三处口径不会漂移。
  bool _isGenuineEnd() => isGenuineEndDuration(
    duration: _controller.duration,
    position: _controller.position,
  );

  /// 传给 `open` 的起播定位：0 与 null 都表示「从头开始」，不下发。
  Duration? _startPositionForOpen(Duration? want) {
    if (want == null || want <= Duration.zero) return null;
    return want;
  }

  /// 用户点击/拖动进度条后的跳转。
  ///
  /// **为什么不能一律 `_controller.seek`**：mpv 的 mid-stream seek 会新建第二条
  /// HTTP 连接去发 `Range`，而站点（T4 内网源）每客户端只允许 **1 条活动流**，
  /// 第二条直接回 429。ffmpeg 定位失败被判为致命错误后，mpv 置
  /// `eof-reached` 并把 `time-pos` 报成 `duration`——用户看到的就是「拖到缓冲
  /// 区外就停住/跳下一集」。实测证据见 `.probe/seek-fix-verify`。
  ///
  /// 正确做法：缓冲内直接 seek（同连接 Range，服务端接受）；缓冲外重开本集，
  /// 让定位发生在**打开时**（`Media.start`），全程只用一条连接。
  Future<void> _seekFromUser(
    Duration target, {
    bool? restorePlaying,
    Duration? recoveryOrigin,
  }) async {
    widget.state.cancelSkipPrefetch(clearCache: false);
    _clearCompletionProgress();
    if (_isLive || _isCatchup || _hasQueue) {
      await _controller.seek(target);
      return;
    }
    var clamped = target < Duration.zero ? Duration.zero : target;
    final duration = _controller.duration;
    if (duration > Duration.zero && clamped > duration) clamped = duration;
    final playing = restorePlaying ?? _controller.isPlaying;
    final origin =
        recoveryOrigin ??
        _seekRecovery?.origin ??
        (_controller.enginePositionSeen
            ? _controller.enginePosition
            : _controller.position);
    final recovery = SeekRecovery(
      origin: origin,
      target: clamped,
      generation: _mediaGeneration,
      startedAt: _recoveryNow,
    );
    // 原位置与目标重合时没有可恢复的差异，不留记录也不启动轮询（§3.2）。
    _seekRecovery = recovery.recoverable ? recovery : null;
    _seekRecoveryLastPosition = null;
    setState(() => _seekRecoveryFailure = null);
    _startRecoveryTicker();
    final buffered = _controller.buffered;
    if (!_reloadInFlight &&
        (buffered <= Duration.zero || clamped <= buffered)) {
      try {
        await _controller.seek(clamped);
      } catch (_) {
        if (mounted && identical(_seekRecovery, recovery)) {
          setState(() => _seekRecoveryFailure = recovery);
        }
        rethrow;
      }
      return;
    }
    _queuedSeekTarget = clamped;
    _queuedSeekPlaying = playing;
    if (_reloadInFlight) return;
    _reloadInFlight = true;
    final owner = Object();
    _seekReloadOwner = owner;
    final controller = _controller;
    var ownerGeneration = _mediaGeneration;
    try {
      while (_queuedSeekTarget != null &&
          mounted &&
          identical(owner, _seekReloadOwner) &&
          ownerGeneration == _mediaGeneration) {
        final next = _queuedSeekTarget!;
        final nextPlaying = _queuedSeekPlaying;
        _queuedSeekTarget = null;
        // 诊断要能回答「为什么卡了一下」：beta 的重写移除了这条日志，但用户
        // 反馈跨缓冲重开时它是唯一的现场证据，保留它不改变跳转机制。
        widget.state.log.info(
          '跨缓冲跳转：重开本集并在打开时定位 '
          'target=${next.inMilliseconds}ms '
          'buffered=${buffered.inMilliseconds}ms '
          'episode=${_request.episodeName}',
          scope: 'player',
        );
        final attempt =
            _seekRecovery ??
            SeekRecovery(
              origin:
                  recoveryOrigin ??
                  (_controller.enginePositionSeen
                      ? _controller.enginePosition
                      : _controller.position),
              target: next,
              generation: _mediaGeneration,
              startedAt: _recoveryNow,
            );
        _seekRecovery = attempt;
        setState(
          () => _request = _request.copyWith(
            // 同媒体重开必须原样保留 TMDB 身份，否则跳段标定会整集丢失。
            tmdb: _request.tmdb,
            startPosition: next,
            clearResumeSeed: true,
          ),
        );
        controller.beginReposition(next);
        final loading = _load(
          restorePlaying: nextPlaying,
          seekRecovery: attempt,
        );
        ownerGeneration = _mediaGeneration;
        await loading;
        if (!mounted || ownerGeneration != _mediaGeneration) break;
      }
    } finally {
      if (identical(owner, _seekReloadOwner)) {
        _seekReloadOwner = null;
        _reloadInFlight = false;
        _queuedSeekTarget = null;
      }
      if (mounted &&
          ownerGeneration == _mediaGeneration &&
          identical(controller, _controller)) {
        _settleSeekRecovery();
      }
    }
  }

  void _startRecoveryTicker() {
    _recoveryTicker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _maybeFinishReposition();
      _settleSeekRecovery();
      _observePlaybackError();
      if (_seekRecovery == null &&
          !_errorGate.pending &&
          !_errorGate.committed) {
        _recoveryTicker?.cancel();
        _recoveryTicker = null;
      }
    });
  }

  void _settleSeekRecovery() {
    final recovery = _seekRecovery;
    if (recovery == null || !mounted || _controller.isLoading) return;
    if (recovery.generation != _mediaGeneration) return;
    // 自然片尾：这次跳转已经无所谓失败，记录与轮询一起收掉。
    if (_controller.isCompleted && _isGenuineEnd()) {
      _seekRecovery = null;
      _seekRecoveryLastPosition = null;
      _recoveryTicker?.cancel();
      _recoveryTicker = null;
      return;
    }
    final excluded =
        _controller.isBuffering ||
        _controller.isSeeking ||
        !_controller.isPlaying ||
        _controller.isCompleted;
    if (excluded) {
      _seekRecoveryExcluded = true;
      return;
    }
    if (_seekRecoveryExcluded) {
      // 只累计**可观察的播放时间**：离开暂停/缓冲的第一次采样重新开窗，
      // 否则「缓冲 30 秒后的第一帧」会被按已过窗口立刻判失败（瞬时误报）。
      _seekRecoveryExcluded = false;
      _seekRecovery = recovery.rebased(_recoveryNow);
      _seekRecoveryLastPosition = null;
      return;
    }
    final position = _controller.enginePosition;
    final verdict = evaluateSeekRecovery(
      recovery: recovery,
      generation: _mediaGeneration,
      enginePosition: position,
      previousEnginePosition: _seekRecoveryLastPosition,
      enginePositionSeen: _controller.enginePositionSeen,
      playing: _controller.isPlaying,
      buffering: _controller.isBuffering,
      isSeeking: _controller.isSeeking,
      now: _recoveryNow,
    );
    _seekRecoveryLastPosition = _controller.enginePositionSeen
        ? position
        : null;
    if (verdict == SeekRecoveryVerdict.pending) return;
    if (verdict == SeekRecoveryVerdict.settled) {
      _seekRecovery = null;
      _seekRecoveryLastPosition = null;
      _controller.endReposition();
      if (_seekRecoveryFailure != null) {
        setState(() => _seekRecoveryFailure = null);
      }
      return;
    }
    if (_seekRecoveryFailure != null) return;
    widget.state.log.warning(
      '跳转未落地 target=${recovery.target.inMilliseconds}ms '
      'origin=${recovery.origin.inMilliseconds}ms',
      scope: 'player',
    );
    _controller.endReposition();
    setState(() => _seekRecoveryFailure = recovery);
  }

  Future<void> _retrySeekTarget() async {
    final recovery = _seekRecoveryFailure;
    if (recovery == null || recovery.generation != _mediaGeneration) return;
    await _seekFromUser(recovery.target, recoveryOrigin: recovery.origin);
  }

  Future<void> _returnToSeekOrigin() async {
    final recovery = _seekRecoveryFailure;
    if (recovery == null || recovery.generation != _mediaGeneration) return;
    await _seekFromUser(recovery.origin);
  }

  /// 运行中错误的确认（§3.3）。
  ///
  /// 引擎 error 流里混着非致命告警；只有「报错后位置真的停住」并过了观察窗口才
  /// 升级成播放失败。位置又走起来就撤销——既不让第一条告警锁死播放，也让真正的
  /// 断流留下可定位的结论。
  void _observePlaybackError() {
    if (!mounted) return;
    final revision = _controller.playbackErrorRevision;
    final fresh = revision != _errorGateObservedRevision
        ? _controller.playbackErrorMessage
        : null;
    _errorGateObservedRevision = revision;
    if (_controller.isLoading || !_progressReady) return;
    final position = _controller.enginePosition;
    final observingPlayback =
        _controller.isPlaying || (_controller.isCompleted && !_isGenuineEnd());
    final action = fresh == null
        ? _errorGate.observe(
            generation: _mediaGeneration,
            position: position,
            at: _recoveryNow,
            playing: observingPlayback,
            buffering: _controller.isBuffering,
            seeking:
                _controller.isSeeking ||
                _controller.isRepositioning ||
                _seekRecovery != null,
          )
        : _errorGate.offer(
            message: fresh,
            generation: _mediaGeneration,
            position: position,
            at: _recoveryNow,
            playing: observingPlayback,
            buffering: _controller.isBuffering,
            seeking:
                _controller.isSeeking ||
                _controller.isRepositioning ||
                _seekRecovery != null,
          );
    if (_errorGate.pending || _errorGate.committed) _startRecoveryTicker();
    switch (action) {
      case PlaybackErrorGateAction.committed:
        if (_loadError != null) return;
        widget.state.log.warning('引擎错误已确认进度停止', scope: 'player');
        setState(() {
          _errorGateOwnedLoadError = true;
          _loadError = '播放中断：内核报错且进度停止，请重试本集或从最近进度续播';
        });
      case PlaybackErrorGateAction.recovered:
        if (!_errorGateOwnedLoadError) return;
        widget.state.log.info('引擎错误后进度恢复，撤销失败结论', scope: 'player');
        setState(() {
          _errorGateOwnedLoadError = false;
          _loadError = null;
        });
      case PlaybackErrorGateAction.idle:
      case PlaybackErrorGateAction.pending:
        return;
    }
  }

  Future<void> _load({
    bool? restorePlaying,
    SeekRecovery? seekRecovery,
    double? restoreRate,
  }) async {
    if (!mounted) return;
    // 回退链上的重开保留次数；其余入口（重试、换集、换线路、续播）都是新一轮。
    if (!_fallbackPending) _fallbackAttempts = 0;
    _fallbackPending = false;
    final generation = _beginMediaTransition(seekRecovery: seekRecovery);
    // 记录本次加载的「意图」，失败时用它回滚 `_request`（`design/03` §4.3 D3）。
    //
    // 为什么必须回滚：`_openTarget` 在调 `_load()` **之前**就已经把 `_request`
    // 改成了下一集（`episodeIndex` 已 +1、`clearStartPosition: true`）。
    // 若加载失败而不回滚，续播上下文（原集 + 原进度）就已丢失，
    // 用户看到的是「上一集失败 → 已经切到下一集」。
    final intent = _request;
    _releaseProxySession = widget.state.captureProxySessionRelease(intent.url);
    final sessionRevision = _sessionRevision;
    // 轨道记忆的键里含线路与集，换集/换线路后必须重读，上一集的记忆绝不能带过来。
    _loadRememberedTrackChoices();
    _skipArmed = false;
    final skipIdentity = _skipIdentityFor(intent);
    if (skipIdentity != _skipMediaIdentity) {
      _skipMediaIdentity = skipIdentity;
      _skipLookupEpoch++;
      _skipHandled.clear();
      _skipRawSegments = const <RawSkipSegment>[];
      _skipPlan = SkipPlan.empty;
      _skipLookupStarted = false;
      _skipCache = IntroSkipCache();
      _skipSegments = widget.state.skipSegmentsFor(
        siteKey: intent.siteKey,
        vodId: intent.vodId,
      );
    }
    _skipPlanDurationMs = -1;
    setState(() => _loadError = null);
    final controller = _controller;
    if (widget.liveSession != null) _liveOpenInFlight = true;
    late PlayerLoadOutcome outcome;
    try {
      outcome = await controller.openWithRetry(
        intent.url,
        headers: intent.headers,
        siteKey: intent.siteKey,
        flag: intent.playbackFlag,
        episodeName: intent.episodeName,
        isCurrent: () => mounted && generation == _mediaGeneration,
        // 起播定位跟着 open 一起下发（见 [PlayerController.open] 的 startAt）：
        // 打开后再 seek 会新建第二条连接，服务端只允许 1 条活动流。
        startAt: _startPositionForOpen(intent.startPosition),
        // 预取与失败分类的开关来自设置里的播放选项：不传＝历史行为，传了才在
        // 开播前发一次探测并按失败性质决定能不能重试/回退（PlayerOptions.openPolicy）。
        policy: widget.state.playerOptions.openPolicy,
      );
    } finally {
      if (identical(controller, _controller)) _liveOpenInFlight = false;
    }
    if (!mounted || generation != _mediaGeneration) return;
    widget.state.log.info('播放结果 ${outcome.summary}', scope: 'player');
    // 起播落点必须在**这一刻**记下来：后面还要装配字幕与弹幕（实测枚举弹幕库那次
    // 装配了十几秒），那时再读 controller.position 读到的是播放进度而不是落点，
    // 会把正常续播误报成「起播定位未生效」，并给用户弹一条假的「已从头播放」。
    final landingPosition = controller.position;
    final diagnostics = controller.diagnostics;
    if (diagnostics != null) {
      widget.state.log.info(
        '播放诊断 ${diagnostics.logLine}',
        scope: 'diagnostics',
      );
      _diagnostics = diagnostics;
      widget.state.recordPlaybackDiagnostics(diagnostics);
    }
    if (!outcome.succeeded) {
      // 本地文件不走这条回退：directUrl 恒为 false，也没有「直播线路」可换。
      if ((_isLive ||
              (_request.directUrl &&
                  widget.onLiveSourceFallback != null &&
                  _request.flag == '直播线路')) &&
          widget.state.liveSettings.changeLine &&
          await _fallbackLiveLine()) {
        return;
      }
      if (!mounted || generation != _mediaGeneration) return;
      // 失败路径的收尾（`design/03` §4.3）：
      // 1. 回滚 `_request` 到本次加载前的意图（保住续播上下文）；
      // 2. 清除残留的 `completed`，否则重建会再次触发连播（D1）；
      // 3. 记一条含 nearEnd 判定的诊断，让「缓存耗尽」在 PC 侧可见（§4.6）。
      _logFailureDiagnostics(outcome);
      // 自动回退（迭代 3-C）：设置显式开启且策略还给出下一步时，按结论换线路/
      // 换解析源/原地重试，成功发起重开就不再走下面的失败收尾。
      // 关掉回退时**不能**引入任何 await**：失败收尾必须与接线前完全同步。
      // 多一次微任务让步就会让 `_loadError` 晚一帧落地，失败态三出口（重试/续播/
      // 下一集）在首帧看不到——`player_history_lines_test` 的同集重试用例当场红。
      if (widget.state.playerOptions.failureFallback !=
              PlayerFailureFallback.off &&
          await _tryPlaybackFallback(outcome)) {
        return;
      }
      if (!mounted || generation != _mediaGeneration) return;
      var rollback = intent;
      if (_playLinesRequested &&
          intent.playLines.isEmpty &&
          _request.playLines.isNotEmpty &&
          widget.liveSession == null &&
          !_hasQueue &&
          _request.siteKey == intent.siteKey &&
          _request.vodId == intent.vodId &&
          _request.sourceKey == intent.sourceKey &&
          _request.episodeTarget == intent.episodeTarget) {
        // 起播失败仍要回滚原意图，但同集先补到的线路不能被回滚丢掉。
        // 重新完整定位，确保线路与集下标成对；其它起播字段继续来自 intent。
        final lines = _request.playLines;
        final target = resolveHistoryTarget(
          historyFlag: intent.flag,
          historyEpisodeId: intent.episodeTarget,
          historyEpisodeName: intent.episodeName,
          lines: lines,
        );
        if (target.matched) {
          final line = lines
              .where((line) => line.flag == target.flag)
              .firstOrNull;
          rollback = intent.copyWith(
            playLines: lines,
            // 线路与路由同进同出：回滚丢掉路由，下一次换集就退回父目录 id。
            lineRoutes: _request.lineRoutes,
            flag: target.flag,
            playbackFlag: line?.playbackFlag ?? intent.playbackFlag,
            episodeIndex: target.episodeIndex,
            tmdb: intent.tmdb,
          );
        }
      }
      setState(() {
        _request = rollback;
        _loadError = outcome.failureKind == null
            ? '播放失败'
            : describePlayerFailure(outcome.failureKind!);
      });
      _controller.clearCompleted();
      return;
    }
    if (restoreRate != null) {
      await controller.setRate(restoreRate);
      if (!mounted || generation != _mediaGeneration) return;
    }
    if (restorePlaying == false) {
      await controller.pause();
      if (!mounted || generation != _mediaGeneration) return;
    }
    widget.liveSession?.confirmPlayback(sessionRevision);
    // 进度恢复：仅对同一剧集且位置有效时执行（§10.3 播放恢复）。
    final start = _effectiveStartPosition();
    // 种子是**一次性交接**：无论重算成功与否，落定后都要清掉，否则下一次
    // `_load()`（失败重试、换线路）会把同一颗种子再套一遍，甚至套到别的集上。
    if (_request.resumeSeed != null || start != _request.startPosition) {
      _request = _request.copyWith(
        tmdb: _request.tmdb,
        startPosition: start,
        clearStartPosition: start == null,
        clearResumeSeed: true,
      );
    }
    if (start != null &&
        start > Duration.zero &&
        start < _controller.duration) {
      // 起播已经定位到 [intent.startPosition]；只有重算结果不同且**落在已缓冲
      // 区间内**时才补一次 seek。跨缓冲的 seek 会新建第二条连接被服务端 429，
      // 表现为「停住 + eof-reached」，绝不能在这里发。
      final alreadyPositioned = isSameStartPosition(
        intent.startPosition,
        start,
      );
      if (alreadyPositioned) {
        // 起播定位写在 mpv 的 `start` 选项里，生效与否只有引擎自己知道：
        // 落地位置明显偏离就说明这次定位没吃上（此时是从头播，而不是跳转失败）。
        final actual = landingPosition;
        final drift = (actual - start).inMilliseconds.abs();
        if (drift > 5000) {
          widget.state.log.warning(
            '起播定位未生效：wanted=${start.inMilliseconds}ms '
            'actual=${actual.inMilliseconds}ms episode=${_request.episodeName}',
            scope: 'player',
          );
          // 定位失败**不会抛异常**（`start` 只是内核选项），所以必须显式告诉
          // 用户「没跳过去」——否则他只是看到画面从头开始，以为点了没反应。
          _showPlayerMessage('未能跳到该位置，已从头播放');
        } else {
          widget.state.log.info(
            '恢复播放进度 episode=${_request.episodeName} '
            'position=${start.inMilliseconds}ms',
            scope: 'player',
          );
        }
      } else if (start <= _controller.buffered) {
        await _controller.seek(start);
        if (!mounted || generation != _mediaGeneration) return;
        widget.state.log.info(
          '恢复播放进度 episode=${_request.episodeName} '
          'position=${start.inMilliseconds}ms',
          scope: 'player',
        );
      } else {
        widget.state.log.warning(
          '进度重算落在缓冲之外，未下发 seek（避免 429 伪结束）'
          'wanted=${start.inMilliseconds}ms '
          'buffered=${_controller.buffered.inMilliseconds}ms '
          'openedAt=${intent.startPosition?.inMilliseconds ?? 0}ms '
          'episode=${_request.episodeName}',
          scope: 'player',
        );
      }
    }
    // 续播 seek 完成之后才允许自动跳片头/片尾（design/01 §3.1）。
    _progressReady = true;
    _skipArmed = true;

    if (restorePlaying == null) _maybeAutoSkip();
    if (!mounted || generation != _mediaGeneration) return;
    _startProgressSaver();
    // 视频与续播已就绪：辅助能力仍按原顺序等待，不阻塞自动跳段。
    // Phase 9：注入 mpv 播放参数与 LUT。失败不阻断播放，只提示能力不可用。
    await _applyPlaybackEnhancements();
    if (!mounted || generation != _mediaGeneration) return;
    // 字幕（§10.3）：装配外挂字幕候选并自动启用默认/强制字幕。
    // 字幕失败不得阻断播放，因此整段吞掉错误，只落日志与提示。
    await _configureSubtitles();
    if (!mounted || generation != _mediaGeneration) return;
    await _audioAi?.karaoke.bindMedia(
      _karaokeMedia,
      lyrics: _currentSrtForAi == null
          ? const []
          : lyricLinesFromSrt(_currentSrtForAi!),
    );
    if (!mounted || generation != _mediaGeneration) return;
    // 弹幕（§21 Phase 3）：拉取并启用弹幕。同样不得阻断播放。
    await _configureDanmaku();
  }

  /// 本次加载实际要 seek 的位置：优先用「待迁移种子 + 目标集真实时长」重算。
  ///
  /// 为什么不能直接信 [PlaybackRequest.startPosition]：详情页算它时拿不到
  /// 目标集的真实时长（要 `open()` 成功才有），只能按绝对毫秒搬运；两个源
  /// 同一集的时长差很大时（同一部剧不同剪辑/片头长度）绝对毫秒会落到中段甚至
  /// 片尾，片尾还会被 `endingGuard` 拦成「从头开始」。这里拿到
  /// `_controller.duration` 后再走一次同一套策略，就能落进比例换算分支。
  ///
  /// 重算失败（不是同一集、位置无效、时长未知）时退回详情页给的值：那一路
  /// 只可能给出「绝对毫秒」，不会比这里更差。
  Duration? _effectiveStartPosition() {
    final base = _request.startPosition;
    final seed = _request.resumeSeed;
    if (seed == null) return base;
    final line = _lineOf(_request.flag);
    final index = _request.episodeIndex;
    if (line == null || index < 0 || index >= line.episodes.length) return base;
    return resolveResumeStart(
          lines: _request.playLines,
          seed: seed,
          targetLine: line,
          targetEpisodeIndex: index,
          targetEpisodeName: line.episodes[index].name,
          targetDurationMs: _controller.duration.inMilliseconds,
          // 同源精确值已在详情页作为 `fallback` 消费过；这里只做比例换算，
          // 故不重复传入（否则会短路掉重算）。
          fallback: null,
        ) ??
        base;
  }

  // `_applyPlaybackEnhancements` 已搬到 `player_playback_params.dart`（`part` 里的 `_PlayerPageState` 扩展）。

  /// 直播线路回退（§13.3）：按顺序尝试当前频道剩余的线路。
  ///
  /// 返回 true 表示已切换到另一条线路并重新加载。
  Future<bool> _fallbackLiveLine() async {
    final session = widget.liveSession;
    if (session != null) {
      return session.fallback(
        changeLine: widget.state.liveSettings.changeLine,
        sourceFallback: widget.state.liveSettings.sourceFallback,
      );
    }
    final generation = _mediaGeneration;
    final lines = _episodes;
    if (lines.isEmpty) return false;
    final next = _request.episodeIndex + 1;
    if (next >= lines.length) {
      widget.state.log.info(
        '直播全部线路均失败 channel=${_request.episodeName} tried=${lines.length}',
        scope: 'live',
      );
      // 源级回退（Phase 9）：只在当前源用尽、且调用方提供了回退入口时尝试一次。
      final fallback = widget.onLiveSourceFallback;
      if (fallback != null &&
          widget.state.liveSettings.sourceFallback &&
          !_sourceFallbackTried) {
        _sourceFallbackTried = true;
        final nextRequest = await fallback();
        if (nextRequest != null && mounted && generation == _mediaGeneration) {
          widget.state.log.info(
            '已切换直播源 channel=${nextRequest.episodeName} '
            'source=${nextRequest.siteKey}',
            scope: 'live',
          );
          setState(() => _request = nextRequest);
          await _load();
          return true;
        }
      }
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
        // 直播的 `episode.url` 就是最终可播地址，入口目标与之一致。
        episodeTarget: episode.url,
        episodeName: episode.name,
        episodeIndex: next,
        clearStartPosition: true,
      );
    });
    await _load();
    return true;
  }

  /// 开播失败后的自动回退（迭代 3-C）。
  ///
  /// **默认什么都不做**：`PlayerFailureFallback.off` 是设置的默认值，第一行就
  /// 返回，行为与接线之前完全一致（不改错误提示、不写日志）。只有用户显式开启
  /// 才继续往下走。
  ///
  /// 下一步由 `decidePlaybackFallback`（`lib/core/playback_fallback.dart`）这个
  /// 纯策略给出，本方法只执行结论，三条路都复用既有入口、不另写开播逻辑：
  /// - 换线路 → [_switchLineResumingEpisode]（尽量续播同一集）；
  /// - 换解析源 → [_switchParseSource]（用当前集重新走站点播放入口 + 解析器）；
  /// - 原地重试 → 再跑一次 [_load]。
  ///
  /// 返回 true 表示已经发起了一次重开：调用方必须立刻返回，把失败收尾（回滚
  /// `_request`、写 `_loadError`）让给新一轮。两处都做会把错误提示盖在正在
  /// 加载的画面上。
  ///
  /// `giveUp` 时返回 false，失败收尾照旧执行——错误提示与接线前逐字相同。
  Future<bool> _tryPlaybackFallback(PlayerLoadOutcome outcome) async {
    final mode = widget.state.playerOptions.failureFallback;
    if (mode == PlayerFailureFallback.off) return false;
    // 直播/回看/目录队列/本地/直连各有自己的失败路径（直播另有线路回退），
    // 这里的阶梯只治「站点线路 + 解析源」这一种形态。
    if (_isLive ||
        _isCatchup ||
        _hasQueue ||
        _request.isLocal ||
        _request.directUrl) {
      return false;
    }
    final lines = _request.playLines;
    final decision = decidePlaybackFallback(
      PlaybackFallbackRequest(
        // 引擎没给分类时按「加载失败」处理：那是不可回退的一档，宁可不动，
        // 也不拿一个无处归因的失败去换线路。
        failure: classifyPlaybackFailureClass(
          outcome.failureKind ?? PlayerFailureKind.loadFailed,
        ),
        mode: mode,
        lineIndex: lines.indexWhere((line) => line.flag == _request.flag),
        lineCount: lines.length,
        parseSourceIndex: _request.parseSources.indexOf(_request.parseSource),
        parseSourceCount: _request.parseSources.length,
        attempts: _fallbackAttempts,
      ),
    );
    if (!decision.hasNext) {
      widget.state.log.info(
        '失败回退放弃：${decision.reason} '
        'episode=${_request.episodeName} attempts=$_fallbackAttempts',
        scope: 'player',
      );
      return false;
    }
    final before = _mediaGeneration;
    _fallbackAttempts++;
    _fallbackPending = true;
    try {
      switch (decision.step) {
        case FallbackStep.giveUp:
          return false;
        case FallbackStep.retrySame:
          widget.state.log.info(
            '失败回退 原地重试：${decision.reason} '
            'attempts=$_fallbackAttempts episode=${_request.episodeName}',
            scope: 'player',
          );
          await _load();
        case FallbackStep.nextLine:
          final flag = lines[decision.targetIndex!].flag;
          widget.state.log.info(
            '失败回退 换线路：${decision.reason} '
            'from=${_request.flag} to=$flag '
            'attempts=$_fallbackAttempts episode=${_request.episodeName}',
            scope: 'player',
          );
          if (!await _switchLineResumingEpisodeStrict(flag)) {
            widget.state.log.info(
              '失败回退放弃：线路 $flag 里没有唯一同集，不猜落点 '
              'episode=${_request.episodeName}',
              scope: 'player',
            );
            return false;
          }
        case FallbackStep.nextParseSource:
          final name = _request.parseSources[decision.targetIndex!];
          widget.state.log.info(
            '失败回退 换解析源：${decision.reason} '
            'from=${_request.parseSource} to=$name '
            'attempts=$_fallbackAttempts episode=${_request.episodeName}',
            scope: 'player',
          );
          await _switchParseSource(name);
      }
    } finally {
      _fallbackPending = false;
    }
    if (!mounted) return true;
    // 一次新的媒体切换都没发生＝切换入口自己拒了（目标线路没有选集、解析源
    // 没变、下标越界）。这时回退不成立，交回失败收尾把原错误提示出来。
    return _mediaGeneration != before;
  }

  /// 装配字幕（§10.3「外挂字幕」「字幕轨选择」）。
  ///
  /// 顺序：先登记播放结果里的 `subs`，再自动启用默认/强制外挂字幕。
  /// 任何失败都只记日志/提示，绝不影响视频播放（§10.4）。
  Future<void> _configureSubtitles() async {
    final request = _request;
    final controller = _controller;
    final generation = _mediaGeneration;
    final queueMedia = _hasQueue;
    bool isCurrent() =>
        !queueMedia ||
        (mounted &&
            generation == _mediaGeneration &&
            identical(request, _request) &&
            identical(controller, _controller));
    // 本集用户显式选过内嵌字幕轨，且那条轨真的在当前容器里：不再自动挂外挂字幕。
    // 两条路径都调 setSubtitleTrack，后到的会顶掉先到的，用户的选择不能赌时序。
    if (_hasResolvableRememberedSubtitle()) {
      widget.state.log.info('本集记过内嵌字幕，跳过自动挂载外挂字幕', scope: 'subtitle');
      return;
    }
    final subtitles = request.subtitles;
    if (queueMedia) {
      controller.setExternalSubtitles(subtitles);
      await controller.selectSubtitle(SubtitleOption.off);
      if (!isCurrent()) return;
    }
    if (subtitles.isEmpty) {
      await _autoMatchSubtitle();
      return;
    }
    if (!isCurrent()) return;
    controller.setExternalSubtitles(
      subtitles,
      onDiscard: (sub, reason) => widget.state.log.warning(
        '字幕条目已丢弃 name=${sub.name} reason=$reason',
        scope: 'subtitle',
      ),
    );
    if (controller.externalOptions.isEmpty) return;
    final defaultOption = defaultSubtitleOption(controller.externalOptions);
    final enabled = queueMedia && defaultOption != null
        ? await controller.selectSubtitle(
            defaultOption,
            headers: request.subtitleHeaders,
          )
        : await controller.applyDefaultSubtitle(
            headers: request.subtitleHeaders,
          );
    if (!isCurrent()) return;
    final error = controller.subtitleError;
    if (error != null) {
      widget.state.log.warning(
        '默认字幕加载失败 sub=${controller.selectedSubtitle?.label ?? ""} $error',
        scope: 'subtitle',
      );
      _showSubtitleError(error);
      return;
    }
    if (enabled) {
      widget.state.log.info(
        '默认字幕已启用 sub=${controller.selectedSubtitle?.label ?? ""}',
        scope: 'subtitle',
      );
    }
  }

  /// 本集记住的内嵌字幕轨是否仍能在当前容器的轨道表里匹配到。
  ///
  /// 只判「可命中」而不是「有记录」：记录还在但这条轨已不存在时，外挂默认字幕
  /// 仍是用户唯一能得到的字幕，不该被跳掉。
  bool _hasResolvableRememberedSubtitle() {
    final choice = _rememberedTrackChoices[PlayerTrackSlot.subtitle];
    if (choice == null) return false;
    return matchTrackChoice(
          tracks: _controller.embeddedSubtitleTrackInfos,
          choice: choice,
        ) !=
        null;
  }

  /// 构造字幕查询（标题优先用片名，季集优先用 TMDB 身份）。
  SubtitleQuery _subtitleQuery() {
    final identity = _request.tmdb;
    final hasSeason = identity != null && identity.hasSeason;
    final rawEpisode = int.tryParse(
      RegExp(r'\d+').firstMatch(_request.episodeName)?.group(0) ?? '',
    );
    return SubtitleQuery(
      title: _request.vodName.trim().isEmpty
          ? _request.title
          : _request.vodName,
      season: hasSeason ? identity.seasonNumber : null,
      episode: hasSeason ? rawEpisode : rawEpisode,
      siteKey: _request.siteKey,
      vodId: _request.vodId,
      episodeName: _request.episodeName,
      // 射手按本地文件特征码搜索；网络流两个来源都推不出路径，结果为 null。
      mediaPath:
          deriveLocalMediaPath(_request.url) ??
          deriveLocalMediaPath(_request.episodeTarget),
    );
  }

  /// 构造字幕匹配服务：统一的缓存目录与超时口径。
  ///
  /// 自动匹配用 8s（不拖慢起播），用户主动搜索/下载用 15s（与参考实现一致）。
  SubtitleMatchService _subtitleService({Duration? timeout}) =>
      SubtitleMatchService(
        log: widget.state.log,
        cacheDir: SubtitleAssetStore.defaultCacheDir(
          widget.state.paths.cacheDir,
        ),
        timeout: timeout ?? const Duration(seconds: 8),
      );

  /// 播放结果没有字幕时，按设置自动匹配（`design/02` §1.3）。
  Future<void> _autoMatchSubtitle() async {
    final settings = widget.state.subtitleSettings;
    if (!settings.autoMatch || !settings.hasAnyProvider) return;
    final query = _subtitleQuery();
    final memory = widget.state.subtitleMatchFor(
      siteKey: _request.siteKey,
      vodId: _request.vodId,
      episodeName: _request.episodeName,
    );
    if (memory != null) {
      final applied = await _applySubtitleCandidate(
        memory.toCandidate(),
        remember: false,
      );
      if (applied) {
        widget.state.log.info(
          '字幕记忆命中 provider=${memory.providerId} title=${memory.title}',
          scope: 'subtitle',
        );
      }
      return;
    }
    final generation = _mediaGeneration;
    final service = _subtitleService();
    var best = await service.autoMatch(query: query, settings: settings);
    if (best == null && mounted && generation == _mediaGeneration) {
      final title = await widget.state.resolveBusinessTitle(
        query.title,
        siteKey: query.siteKey,
        vodId: query.vodId,
      );
      if (!mounted || generation != _mediaGeneration) return;
      if (title != null && title != query.title) {
        best = await service.autoMatch(
          query: SubtitleQuery(
            title: title,
            season: query.season,
            episode: query.episode,
            siteKey: query.siteKey,
            vodId: query.vodId,
            episodeName: query.episodeName,
          ),
          settings: settings,
        );
      }
    }
    if (best == null || !mounted || generation != _mediaGeneration) return;
    await _applySubtitleCandidate(best, remember: true);
  }

  /// 加载候选并选中；失败只提示，不影响播放。
  Future<bool> _applySubtitleCandidate(
    SubtitleCandidate candidate, {
    required bool remember,
  }) async {
    final generation = _mediaGeneration;
    final controller = _controller;
    var url = candidate.url;
    var format = candidate.format;
    if (candidate.requiresResolve) {
      // ASSRT 是两跳 + 可能 ZIP，落成本地文件后播放器才认得。
      final asset = await _subtitleService(timeout: const Duration(seconds: 15))
          .resolve(
            candidate,
            query: _subtitleQuery(),
            settings: widget.state.subtitleSettings,
          );
      if (!mounted || generation != _mediaGeneration) return false;
      if (asset == null) {
        _showSubtitleError(
          '字幕下载失败（${subtitleProviderLabel(candidate.providerId)}）',
        );
        return false;
      }
      url = asset.path;
      format = asset.format;
    }
    final info = SubtitleInfo(
      url: url,
      name: candidate.title,
      lang: candidate.language,
      format: format,
      flag: SubtitleInfo.selectionFlagDefault,
    );
    controller.setExternalSubtitles(
      [info],
      onDiscard: (sub, reason) => widget.state.log.warning(
        '字幕候选被丢弃 name=${sub.name} reason=$reason',
        scope: 'subtitle',
      ),
    );
    if (controller.externalOptions.isEmpty) {
      _showSubtitleError('字幕候选格式不受支持');
      return false;
    }
    final ok = await controller.selectSubtitle(
      controller.externalOptions.first,
      headers: _request.subtitleHeaders,
    );
    if (!mounted || generation != _mediaGeneration) return false;
    final error = controller.subtitleError;
    if (!ok) {
      widget.state.log.warning('字幕加载失败 $error', scope: 'subtitle');
      if (error != null) _showSubtitleError(error);
      return false;
    }
    if (remember) {
      await widget.state.rememberSubtitleMatch(
        SubtitleMatchRecord.fromCandidate(
          siteKey: _request.siteKey,
          vodId: _request.vodId,
          episodeName: _request.episodeName,
          candidate: candidate,
        ),
      );
    }
    if (!mounted || generation != _mediaGeneration) return false;
    widget.state.log.info(
      '字幕已启用 provider=${candidate.providerId} title=${candidate.title} '
      'lang=${candidate.language}',
      scope: 'subtitle',
    );
    return true;
  }

  // `_showSubtitleSearch` 已搬到 `player_subtitle_menu.dart`（`part` 里的 `_PlayerPageState` 扩展）。

  // `_pickLocalSubtitleFile` 已搬到 `player_subtitle_menu.dart`（`part` 里的 `_PlayerPageState` 扩展）。

  // `_showLocalSubtitlePicker` 已搬到 `player_subtitle_menu.dart`（`part` 里的 `_PlayerPageState` 扩展）。

  // `_showSubtitleError` 已搬到 `player_subtitle_menu.dart`（`part` 里的 `_PlayerPageState` 扩展）。

  // ---------------------------------------------------------------- 弹幕

  /// 装配弹幕（§21 Phase 3「字幕/弹幕可开启和关闭」）。
  ///
  /// 自动启用第一个可用的弹幕源；直播弹幕（`ws`/`wss`）走 WebSocket 会话（§13.1）。
  /// 任何失败都只记日志/提示，绝不影响视频播放（§10.4 同语义）。
  Future<void> _configureDanmaku() async {
    // 换集/重新装配时先停旧直播会话：否则新一集没有直播源时，旧 ws
    // 仍会被当成「当前弹幕」，还会继续往新画面推流。
    await _teardownLiveSession('configure');
    final sources = _request.danmaku;
    // 一次装载只该装配一次：这条日志让「同一 generation 出现两次」当场可见
    // （实测同一集会连跑两遍站源弹幕请求，白等 2–4 秒还多一条失败警告）。
    widget.state.log.debug(
      '弹幕装配 generation=$_mediaGeneration 源=${sources.length}',
      scope: 'danmaku',
    );
    if (sources.isEmpty) {
      await _autoSearchDanmaku();
      return;
    }
    // 优先用户显式选择的源，其余按原顺序依次尝试；**全部失败再回退弹幕库**。
    //
    // 为什么不能只试第一个：站源给的 `do=danmu` 地址实测时好时坏（一次返回非弹幕
    // 内容、一次指向已关闭的本机数据面）。站源给了但不可用时只试一个，等于整条
    // 弹幕链作废——用户看到"这集没弹幕"，而弹幕库其实是好的。
    final ordered = <DanmakuSource>[
      ...sources.where((source) => source.selected),
      ...sources.where((source) => !source.selected),
    ];
    for (final source in ordered) {
      if (source.isLive) {
        await _connectLiveDanmaku(source);
        return;
      }
      // 中间候选静默失败：不逐条弹提示，交给最终兜底结果统一告知。
      if (await _loadDanmakuSource(source, quiet: true, origin: 'configure')) {
        return;
      }
    }
    await _autoSearchDanmaku();
  }

  /// 构造弹幕库查询。
  DanmakuQuery _danmakuQuery() => DanmakuQuery(
    title: _request.vodName.trim().isEmpty ? _request.title : _request.vodName,
    episode: _request.episodeName,
    year: _danmakuQueryYear,
    siteKey: _request.siteKey,
    vodId: _request.vodId,
    episodeName: _request.episodeName,
  );

  /// 查询年份：先信详情页的 `vod_year`（结构化字段，可能是 '2026'、
  /// '2026-01-01'，也可能为空/自由文本），从中抠出第一个 4 位年份；
  /// 取不到才回退到片名里的 `(2026)` 一类括注。
  ///
  /// 两者都没有就返回 null（打分按中性处理）：从别处猜一个年份会让「同名不同年」
  /// 的另一部剧被硬判成不匹配，比不知道更糟。
  int? get _danmakuQueryYear {
    final raw = _request.vodYear?.trim() ?? '';
    final match = RegExp(r'(?:19|20)\d{2}').firstMatch(raw);
    if (match != null) return int.tryParse(match.group(0)!);
    return parseDanmakuTitleInfo(_request.vodName).year;
  }

  /// 多源并行搜索本集弹幕；只回条目，逐源的失败记账留在
  /// `DanmakuLibraryService.searchSources` 的结果里（自动搜索不需要展示它）。
  ///
  /// 每次新建服务并在结束时关闭：`DanmakuLibraryService` 的 http client 是
  /// 按实例持有的，播放页常驻一个连接池没有收益（换集就换查询）。
  Future<List<DanmakuLibraryEntry>> _searchDanmakuEntries(
    List<DanmakuSourceConfig> sources,
    DanmakuQuery query, {
    String? title,
  }) async {
    final service = DanmakuLibraryService();
    try {
      final result = await service.searchSources(
        sources: sources,
        title: title ?? query.title,
        episode: query.episode,
      );
      return result.entries;
    } finally {
      service.close();
    }
  }

  /// 播放结果没有弹幕时按设置搜索弹幕库（`design/02` §2.3）。
  Future<void> _autoSearchDanmaku() async {
    if (!widget.state.canAutoSearchDanmaku) return;
    final sources = widget.state.resolvedDanmakuSources.sources;
    if (sources.isEmpty) return;
    final query = _danmakuQuery();
    final memory = widget.state.danmakuMatchFor(
      siteKey: _request.siteKey,
      vodId: _request.vodId,
      episodeName: _request.episodeName,
    );
    if (memory != null) {
      await _loadDanmakuSource(
        origin: 'auto:memory',
        DanmakuSource(
          url: memory.url,
          name: memory.title,
          source: memory.providerId,
        ),
      );
      return;
    }
    final generation = _mediaGeneration;
    var entries = await _searchDanmakuEntries(sources, query);
    // 阈值必须比较**实际检索用的片名**：用 AI 改名重搜后仍拿旧名打分，
    // 真名与原名不相似时真实命中会被 0.6 阈值丢掉。
    var matchQuery = query;
    if (entries.isEmpty) {
      final title = await widget.state.resolveBusinessTitle(
        query.title,
        siteKey: query.siteKey,
        vodId: query.vodId,
      );
      if (!mounted || generation != _mediaGeneration) return;
      if (title != null && title != query.title) {
        entries = await _searchDanmakuEntries(sources, query, title: title);
        if (entries.isNotEmpty) {
          matchQuery = DanmakuQuery(
            title: title,
            episode: query.episode,
            siteKey: query.siteKey,
            vodId: query.vodId,
            episodeName: query.episodeName,
          );
        }
      }
    }
    if (!mounted || generation != _mediaGeneration) return;
    // 阈值仍然前置过滤：低于阈值只说明「标题不像」，不能因为"恰好载得动"
    // 就把无关弹幕记成本集的匹配（记忆一旦写下会一直命中）。
    final ranked = rankDanmakuEntries(
      entries: entries,
      query: matchQuery,
    ).where((entry) => entry.score >= kDanmakuAutoPickThreshold).toList();
    if (ranked.isEmpty) return;
    var attempted = 0;
    // 多来源候选里可能有空源：依次试到第一条**真的载入到弹幕**的候选，
    // 失败的那些不弹 toast，全部失败才提示一次。
    final best = await autoLoadDanmakuCandidates(
      ranked: ranked,
      load: (entry) async {
        attempted++;
        return _loadDanmakuSource(
          DanmakuSource(
            url: entry.url,
            name: entry.title,
            source: entry.providerId,
          ),
          quiet: true,
          origin: 'auto:candidate',
        );
      },
    );
    if (best == null) {
      if (!mounted) return;
      _showPlayerMessage('没有可用的弹幕来源（已尝试 $attempted 个）');
      return;
    }
    await widget.state.rememberDanmakuMatch(
      DanmakuMatchRecord.fromEntry(
        siteKey: _request.siteKey,
        vodId: _request.vodId,
        episodeName: _request.episodeName,
        entry: best,
      ),
    );
    widget.state.log.info(
      '弹幕自动匹配 provider=${best.providerId} title=${best.title} '
      'episode=${best.episode} score=${best.score.toStringAsFixed(2)}',
      scope: 'danmaku',
    );
  }

  /// 手动搜索弹幕：大对话框（关键词/来源/渠道/倒序/分组/仅本集）→ 加载并记忆。
  ///
  /// 筛选与分组都在对话框里（`danmaku_search_dialog.dart`）：播放页只负责
  /// 「把当前在用的源和本集查询递进去」以及「选中之后的那条链」。
  Future<void> _showDanmakuSearch() async {
    final selected = await showDanmakuSearchDialog(
      context: context,
      sources: widget.state.resolvedDanmakuSources.sources,
      query: _danmakuQuery(),
      initialKeyword: _request.vodName,
      currentUrl: _danmakuSourceUrl,
    );
    if (selected == null || !mounted) return;
    await _loadDanmakuSource(
      DanmakuSource(
        url: selected.url,
        name: selected.title,
        source: selected.providerId,
      ),
      origin: 'search:selected',
    );
    await widget.state.learnBusinessTitle(
      rawTitle: _request.vodName,
      confirmedTitle: selected.title,
      siteKey: _request.siteKey,
      vodId: _request.vodId,
    );
    await widget.state.rememberDanmakuMatch(
      DanmakuMatchRecord.fromEntry(
        siteKey: _request.siteKey,
        vodId: _request.vodId,
        episodeName: _request.episodeName,
        entry: selected,
      ),
    );
    widget.state.log.info(
      '弹幕手动匹配 provider=${selected.providerId} '
      'source=${selected.libraryName} channel=${selected.channel} '
      'title=${selected.title} episode=${selected.episode} '
      'score=${selected.score.toStringAsFixed(2)}',
      scope: 'danmaku',
    );
  }

  /// 连接直播弹幕（§13.1「直播弹幕」）。
  Future<void> _connectLiveDanmaku(DanmakuSource source) async {
    await _teardownLiveSession('replace');
    _liveSourceUrl = source.url;
    widget.state.log.info(
      '直播弹幕连接 url=${redactUrl(source.url)} name=${source.displayName}',
      scope: 'danmaku',
    );
    final session = LiveDanmakuSession(
      onEvent: _onLiveEvent,
      onMessage: _onLiveMessage,
    );
    _liveSession = session;
    _liveStatus = '连接中';
    if (mounted) setState(() {});
    try {
      await session.connect(source.url);
      // 渲染时钟：让屏幕上已有的弹幕在没有新消息时也能继续移动、到期消失。
      _startLiveTicker();
    } catch (error) {
      _liveStatus = null;
      _danmakuError = describeDanmakuFailure(error);
      widget.state.log.warning(
        '直播弹幕连接失败 source=${source.displayName} $_danmakuError',
        scope: 'danmaku',
      );
      if (mounted) {
        setState(() {});
        _showDanmakuError(_danmakuError!);
      }
    }
  }

  /// 直播弹幕会话状态回调：更新连接状态与在线人数。
  ///
  /// 连接失败（进入重连等待/停止）且从未成功时，提示一次（不反复打扰）。
  void _onLiveEvent(LiveDanmakuSessionEvent event) {
    switch (event.state) {
      case LiveDanmakuSessionState.open:
        _liveStatus = '已连接';
        break;
      case LiveDanmakuSessionState.connecting:
        _liveStatus = '连接中';
        break;
      case LiveDanmakuSessionState.retryWait:
        _liveStatus = '重连中（${(event.retryMs ?? 0) ~/ 1000}s）';
        // 首次失败提示一次；已经提示过就不重复弹。
        _danmakuError ??= '直播弹幕连接失败，正在重连';
        widget.state.log.warning(
          '直播弹幕连接失败，重连中 retry=${event.retryMs}ms '
          'detail=${event.detail ?? ""}',
          scope: 'danmaku',
        );
        if (mounted) _showDanmakuError(_danmakuError!);
        break;
      case LiveDanmakuSessionState.stopped:
        if (_liveStatus != null) _liveStatus = '已断开';
        break;
      case LiveDanmakuSessionState.idle:
      case LiveDanmakuSessionState.released:
        break;
    }
    if (event.online != null) _liveOnline = event.online;
    if (mounted) setState(() {});
  }

  /// 直播弹幕消息回调：入队实时弹幕（带接收时刻）。
  void _onLiveMessage(LiveDanmakuIncoming incoming) {
    final item = DanmakuItem(
      timeMs: incoming.receivedAtMs,
      text: incoming.text,
      type: DanmakuType.scroll,
      color: incoming.color,
      textSizeSp: incoming.textSizeSp,
    );
    _liveReceivedAt[item] = incoming.receivedAtMs;
    _liveNowMs = incoming.receivedAtMs;
    _liveItems = [..._liveItems, item];
    _pruneLiveItems();
    if (mounted) setState(() {});
  }

  /// 修剪直播弹幕：超过 [scrollDurationMs] + 余量的条目不再显示（回收内存）。
  void _pruneLiveItems() {
    final cutoff = _liveNowMs - 15000;
    _liveItems = _liveItems.where((item) {
      final receivedAt = _liveReceivedAt[item];
      return receivedAt != null && receivedAt >= cutoff;
    }).toList();
    _liveReceivedAt.removeWhere((item, receivedAt) => receivedAt < cutoff);
  }

  /// 直播弹幕的「现在」：定时推进 [liveNowMs]，用于把过了
  /// [scrollDurationMs] 的条目修剪掉。
  ///
  /// 渲染不再靠它逐帧推进——叠加层有自己的渲染时钟（墙钟采样），
  /// 否则直播弹幕只能按这个 250ms 的节拍一跳一跳地走。
  /// 会话断开时停止。
  void _startLiveTicker() {
    _liveTicker?.cancel();
    _liveTicker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      // 渲染时钟用真实墙钟：即使没有新消息，也要让屏幕上已有的弹幕继续移动。
      _liveNowMs = DateTime.now().millisecondsSinceEpoch;
      if (mounted) setState(() {});
    });
  }

  /// 关闭直播弹幕会话（请求销毁/切集时调用）。
  Future<void> _teardownLiveSession(String reason) async {
    final session = _liveSession;
    _liveSession = null;
    _liveTicker?.cancel();
    _liveTicker = null;
    _liveItems = const [];
    _liveSourceUrl = null;
    _liveReceivedAt.clear();
    _liveOnline = null;
    _liveStatus = null;
    if (session != null) {
      try {
        await session.dispose();
      } catch (_) {
        // 销毁失败不抛出；会话是尽力而为的附加资源。
      }
    }
  }

  /// 拉取并启用一个弹幕源；失败只提示，不影响播放。
  ///
  /// 返回值 = 「仍在这一代媒体」且**真的载入到非空弹幕**。自动搜索要靠它判断
  /// 单条候选是否可用：中转对同一片名会返回多来源候选，其中可能有空源
  /// （200 + 空 XML），撞上就必须换下一个而不是判定「没有弹幕」。
  ///
  /// [quiet] 为 true 时失败不弹 toast（自动换源的过程中连弹多次只会更吵），
  /// 日志仍记 warning。live 源恒返回 false：自动搜索不处理直播弹幕。
  Future<bool> _loadDanmakuSource(
    DanmakuSource source, {
    bool quiet = false,
    String origin = 'unknown',
  }) async {
    final generation = _hasQueue ? _mediaGeneration : null;
    bool isCurrent() =>
        mounted && (generation == null || generation == _mediaGeneration);
    final stopwatch = Stopwatch()..start();
    try {
      final document = await _danmakuLoader.load(
        source,
        headers: _request.subtitleHeaders,
      );
      if (!isCurrent()) return false;
      _danmakuItems = document.items;
      // 只有真的载入到非空弹幕才算「当前在用」：空源等于没弹幕，标它只会误导。
      // 直播弹幕走 [_connectLiveDanmaku]，不是这里加载的一条点播弹幕。
      _danmakuSourceUrl = !source.isLive && document.items.isNotEmpty
          ? source.url
          : null;
      _danmakuError = null;
      widget.state.log.info(
        '弹幕已加载 ${document.logLine} elapsed=${stopwatch.elapsed.inMilliseconds}ms'
        ' origin=$origin',
        scope: 'danmaku',
      );
      if (mounted) setState(() {});
      return !source.isLive && document.items.isNotEmpty;
    } catch (error) {
      if (!isCurrent()) return false;
      _danmakuItems = const [];
      _danmakuSourceUrl = null;
      _danmakuError = describeDanmakuFailure(error);
      final detail = error is AppError ? error.detail : null;
      widget.state.log.warning(
        '弹幕加载失败 origin=$origin source=${source.displayName} $_danmakuError'
        '${detail == null || detail.isEmpty ? '' : ' detail=$detail'}',
        scope: 'danmaku',
      );
      if (!mounted) return false;
      setState(() {});
      if (!quiet) _showDanmakuError(_danmakuError!);
      return false;
    }
  }

  /// 弹幕失败提示：不阻断播放（§10.4 同语义）。
  void _showDanmakuError(String message) {
    if (_lastShownDanmakuError == message) return;
    _lastShownDanmakuError = message;
    // 不传 duration：走 error 默认的 15s。
    showToast(message, kind: ToastKind.error);
  }

  /// 弹幕总开关（§13.3「弹幕可开启和关闭」）。
  void _toggleDanmaku() {
    final next = _danmakuStyle.copyWith(enabled: !_danmakuStyle.enabled);
    _applyDanmakuStyle(next);
    widget.state.log.info(
      '弹幕 ${next.enabled ? "开启" : "关闭"} '
      'items=${_danmakuItems.length}',
      scope: 'danmaku',
    );
  }

  /// 先开页签式弹层调显示参数、切本集弹幕源；返回三态决定下一步。
  ///
  /// 弹层里的显示项都经 [_applyDanmakuStyle] 立即应用并落盘；源切换也已经在
  /// 弹层内完成，所以这里不再有「应用一次」的步骤。
  Future<void> _openDanmakuQuickSettings() async {
    final resolved = widget.state.resolvedDanmakuSources;
    _danmakuSheetGeneration = _mediaGeneration;
    final action = await showDanmakuSettingsSheet(
      context,
      style: _danmakuStyle,
      onChanged: _applyDanmakuStyle,
      sourceView: DanmakuSourceView(
        sources: _request.danmaku,
        // 直播与点播各记一份地址：ws 地址不能塞进 _danmakuSourceUrl，
        // 搜索对话框靠它标当前点播源。
        currentUrl: _liveSession != null ? _liveSourceUrl : _danmakuSourceUrl,
        itemCount: _liveSession != null
            ? _liveItems.length
            : _danmakuItems.length,
        error: _danmakuError,
        libraryUrl: resolved.sources.isEmpty
            ? null
            : resolved.sources.first.url,
        libraryTotal: resolved.sources.length,
      ),
      onSelectSource: _selectDanmakuSourceForSheet,
    );
    _danmakuSheetGeneration = null;
    if (!mounted) return;
    switch (action) {
      case DanmakuSheetAction.openFullPage:
        await _openDanmakuSettingsPage();
      case DanmakuSheetAction.openSearch:
        await _showDanmakuSearch();
      case DanmakuSheetAction.closed:
        break;
    }
  }

  /// 弹层里点一条源：直播走已有会话，点播走已有加载器。
  ///
  /// 失败只把 outcome 交回弹层；toast 仍由 _loadDanmakuSource 自己弹，
  /// 这里再弹一次会让同一个失败提示出现两遍。
  Future<DanmakuSourceLoadOutcome> _selectDanmakuSourceForSheet(
    DanmakuSource source,
  ) async {
    // 弹层打开后可能自动切集；旧快照里的地址属于上一集，不能装进新一集。
    if (_danmakuSheetGeneration == null ||
        _danmakuSheetGeneration != _mediaGeneration) {
      return const DanmakuSourceLoadOutcome(
        ok: false,
        error: '本集已切换，请重新打开弹幕设置',
      );
    }
    if (source.isLive) {
      // 直播分支不经过 _loadDanmakuSource；不复位点播状态，旧弹幕会继续
      // 和直播弹幕一起被 DanmakuOverlay 渲染。
      if (mounted) {
        setState(() {
          _danmakuItems = const [];
          _danmakuSourceUrl = null;
          _danmakuError = null;
        });
      }
      await _connectLiveDanmaku(source);
      // connect() 在握手失败时先返回，真正的失败由 onEvent 异步写入；给
      // 事件一个短窗口，避免把「连接中」当成成功。
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // 直播会话失败由 _connectLiveDanmaku 自己 toast 并进入重连；「当前」
      // 仍指向用户刚选的 ws 地址，但成功与否必须如实回报给弹层。
      return DanmakuSourceLoadOutcome(
        ok: _danmakuError == null,
        currentUrl: source.url,
        itemCount: _liveItems.length,
        error: _danmakuError,
        statusText: _liveStatus ?? (_danmakuError != null ? '连接失败' : '已连接'),
      );
    }
    // 点播分支不经过直播会话；不先停掉会继续推流并渲染到新弹幕上。
    await _teardownLiveSession('danmaku-switch');
    if (mounted) setState(() {});
    final ok = await _loadDanmakuSource(source, origin: 'sheet:switch');
    return DanmakuSourceLoadOutcome(
      ok: ok,
      currentUrl: _danmakuSourceUrl,
      itemCount: _danmakuItems.length,
      error: _danmakuError,
    );
  }

  /// 打开「弹幕设置」**整页**（弹幕库 + 全部显示参数，P1 的独立页）。
  ///
  /// 页里每一处修改都直接写 state.setDanmakuStyle，而播放器渲染读的是本页
  /// 的 _danmakuStyle 副本：不重新同步的话，用户在页里把字号调到 150%、
  /// 返回后画面一点没变，只有下次进播放器才生效——「改完立刻看得见」正是
  /// 这次把弹层换成整页时要保住的性质。
  Future<void> _openDanmakuSettingsPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DanmakuSettingsPage(state: widget.state),
      ),
    );
    if (!mounted) return;
    setState(() => _danmakuStyle = widget.state.danmakuStyle);
  }

  /// 应用并持久化弹幕显示样式。
  ///
  /// 写盘失败只记日志：当前会话的显示效果已经生效，不因为磁盘问题回滚。
  void _applyDanmakuStyle(DanmakuStyle next) {
    if (!mounted) return;
    setState(() => _danmakuStyle = next);
    unawaited(
      widget.state.setDanmakuStyle(next).then((ok) {
        if (!ok) {
          widget.state.log.warning('保存弹幕显示设置失败', scope: 'player');
        }
      }),
    );
  }

  /// 字幕菜单：外挂 / 内嵌 / 关闭（§13.3「字幕可开启和关闭」）。
  // --------------------------------------------------- Phase 9 播放面板

  /// 重读本集（含线路）记住的轨道选择。
  ///
  /// 线路用 [PlaybackRequest.playbackFlag]：那才是用户此刻在看的线路，
  /// 与历史记录写入的口径是同一个值。
  void _loadRememberedTrackChoices() {
    _rememberedTrackChoices.clear();
    _appliedTrackChoices.clear();
    _lastTriedTrackIds.clear();
    for (final slot in PlayerTrackSlot.values) {
      final choice = widget.state.playerTrackChoiceFor(
        slot: slot,
        siteKey: _request.siteKey,
        vodId: _request.vodId,
        flag: _request.playbackFlag,
        episodeId: _request.episodeTarget,
        episodeName: _request.episodeName,
      );
      if (choice != null) _rememberedTrackChoices[slot] = choice;
    }
  }

  /// 轨道表就绪后应用记住的选择，每个槽真正命中一次就停。
  ///
  /// 挂在控制器通知里而不是 `_load()` 之后：轨道表由引擎在 `open()` 内部
  /// 上报，直播/慢源会晚于 `_load()` 返回。
  ///
  /// 「标记已应用」必须等 [applyTrackChoice] 真的命中并调用了 setTrack：
  /// 首帧只有 `auto` 这类伪轨时表非空但匹配必落空，提前标记会让该槽永久
  /// 失去重试机会。未命中时靠 [shouldAttemptTrackChoice] 去重，同样的轨道
  /// 集合只尝试一次（不重复 set、也不刷日志）。
  void _applyRememberedTrackChoices() {
    _scheduleTrackChoice(
      slot: PlayerTrackSlot.audio,
      tracks: _controller.audioTrackInfos,
      setTrack: _controller.selectAudioTrack,
    );
    _scheduleTrackChoice(
      slot: PlayerTrackSlot.video,
      tracks: _controller.videoTrackInfos,
      setTrack: _controller.selectVideoTrack,
    );
    _scheduleTrackChoice(
      slot: PlayerTrackSlot.subtitle,
      tracks: _controller.embeddedSubtitleTrackInfos,
      setTrack: (id) async {
        final option = _embeddedSubtitleOption(id);
        if (option == null) return false;
        return _controller.selectSubtitle(
          option,
          headers: _request.subtitleHeaders,
        );
      },
    );
  }

  /// 单个槽的「值得尝试吗 → 尝试 → 命中才标记」。
  void _scheduleTrackChoice({
    required PlayerTrackSlot slot,
    required List<PlayerTrackInfo> tracks,
    required Future<bool> Function(String id) setTrack,
  }) {
    final choice = _pendingTrackChoice(slot);
    if (choice == null) return;
    final ids = <String>[for (final track in tracks) track.id];
    if (!shouldAttemptTrackChoice(
      currentIds: ids,
      lastTriedIds: _lastTriedTrackIds[slot],
    )) {
      return;
    }
    _lastTriedTrackIds[slot] = ids;
    unawaited(
      _applyRememberedTrackChoice(
        slot: slot,
        tracks: tracks,
        choice: choice,
        setTrack: setTrack,
      ).then((hit) {
        if (!hit || !mounted) return;
        _appliedTrackChoices.add(slot);
        _lastTriedTrackIds.remove(slot);
      }),
    );
  }

  /// 还没应用过的记忆；已应用过或本来没有记忆都返回 null。
  TrackChoice? _pendingTrackChoice(PlayerTrackSlot slot) {
    if (_appliedTrackChoices.contains(slot)) return null;
    return _rememberedTrackChoices[slot];
  }

  SubtitleOption? _embeddedSubtitleOption(String id) {
    for (final option in _controller.embeddedOptions) {
      if (option.id == id) return option;
    }
    return null;
  }

  /// 应用一条记忆并留一条日志，返回是否真正命中并调用了 setTrack。
  ///
  /// 全程静默：未命中就保持引擎默认，不弹窗、不打断播放（用户明确要求）。
  /// 返回值就是 [applyTrackChoice] 的语义，调用方只在该值为 true 时把槽标记
  /// 为「已应用」——未命中必须留着重试的机会。
  Future<bool> _applyRememberedTrackChoice({
    required PlayerTrackSlot slot,
    required List<PlayerTrackInfo> tracks,
    required TrackChoice choice,
    required Future<bool> Function(String id) setTrack,
  }) async {
    final hit = await applyTrackChoice(
      tracks: tracks,
      choice: choice,
      setTrack: (id) {
        widget.state.log.info('恢复记住的${slot.label} id=$id', scope: 'player');
        return setTrack(id);
      },
    );
    if (hit) return true;
    widget.state.log.info(
      '记住的${slot.label}未命中（id=${choice.engineId} '
      'language=${choice.language} title=${choice.title}），保持引擎默认',
      scope: 'player',
    );
    return false;
  }

  /// 用户**显式**选择后写回记忆。自动回落的结果绝不走这里。
  void _rememberTrackChoice(PlayerTrackSlot slot, String id) {
    final infos = switch (slot) {
      PlayerTrackSlot.audio => _controller.audioTrackInfos,
      PlayerTrackSlot.video => _controller.videoTrackInfos,
      PlayerTrackSlot.subtitle => _controller.embeddedSubtitleTrackInfos,
      // 次字幕写的是 mpv 的轨道号，只能用引擎原文（剥掉 `embedded:` 前缀）。
      PlayerTrackSlot.secondarySubtitle => _controller.rawSubtitleTrackInfos,
    };
    // 菜单 id 与引擎原文分开：label 拼过语言/序号，只有原文能做 title 回落。
    var choice = TrackChoice(engineId: id);
    for (final info in infos) {
      if (info.id != id) continue;
      choice = TrackChoice(
        engineId: id,
        language: info.language,
        title: info.title,
      );
      break;
    }
    widget.state.rememberPlayerTrackChoice(
      slot: slot,
      siteKey: _request.siteKey,
      vodId: _request.vodId,
      flag: _request.playbackFlag,
      episodeId: _request.episodeTarget,
      episodeName: _request.episodeName,
      choice: choice,
    );
    // 记在同一页里，避免同一集内重开（换线路再换回来）时读到旧内存。
    _rememberedTrackChoices[slot] = choice;
    // 用户刚选过，本集不必再应用记忆；顺手清掉该槽的试错记录，
    // 免得残留的「上次试过哪些 id」让后续判断读到过期状态。
    _appliedTrackChoices.add(slot);
    _lastTriedTrackIds.remove(slot);
  }

  /// 音轨/视频轨选择。单轨时只提示，不弹一个点不出东西的菜单。
  Future<void> _showTrackMenu(PlayerTrackKind kind) async {
    final options = kind == PlayerTrackKind.audio
        ? _controller.audioTrackOptions
        : _controller.videoTrackOptions;
    if (options.isEmpty) {
      _showPlayerMessage('引擎尚未上报${kind.label}');
      return;
    }
    if (!hasSwitchableTracks(options)) {
      _showPlayerMessage('当前只有一条${kind.label}，无需切换');
      return;
    }
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text('选择${kind.label}'),
              titleTextStyle: const TextStyle(fontWeight: FontWeight.w600),
            ),
            for (final option in options)
              ListTile(
                leading: Icon(
                  option.selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 20,
                ),
                title: Text(option.label),
                subtitle: option.isDefault ? const Text('引擎默认') : null,
                onTap: () => Navigator.of(context).pop(option.id),
              ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    final ok = kind == PlayerTrackKind.audio
        ? await _controller.selectAudioTrack(selected)
        : await _controller.selectVideoTrack(selected);
    if (!ok) {
      _showPlayerMessage('${kind.label}切换失败', kind: ToastKind.error);
      return;
    }
    widget.state.log.info('切换${kind.label} id=$selected', scope: 'player');
    _rememberTrackChoice(
      kind == PlayerTrackKind.audio
          ? PlayerTrackSlot.audio
          : PlayerTrackSlot.video,
      selected,
    );
    setState(() {});
  }

  /// 循环与定时关闭。
  Future<void> _showPlaybackModeSheet() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('循环'),
              titleTextStyle: TextStyle(fontWeight: FontWeight.w600),
            ),
            for (final mode in PlaybackRepeat.values)
              ListTile(
                leading: Icon(
                  _repeat == mode
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 20,
                ),
                title: Text(mode.label),
                onTap: () => Navigator.of(context).pop('repeat:${mode.id}'),
              ),
            const Divider(height: 1),
            const ListTile(
              title: Text('定时关闭'),
              titleTextStyle: TextStyle(fontWeight: FontWeight.w600),
              subtitle: Text('退出播放器即取消，不会跨重启生效'),
            ),
            for (final minutes in kSleepTimerMinutes)
              ListTile(
                title: Text('$minutes 分钟后'),
                onTap: () => Navigator.of(context).pop('sleep:$minutes'),
              ),
            ListTile(
              title: const Text('本集结束后'),
              onTap: () => Navigator.of(context).pop('sleep:end'),
            ),
            ListTile(
              title: Text(
                _sleepTimer.idle
                    ? '取消定时（当前未开启）'
                    : '取消定时（${_sleepTimer.summary}）',
              ),
              enabled: !_sleepTimer.idle,
              onTap: () => Navigator.of(context).pop('sleep:off'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action.startsWith('repeat:')) {
      final mode = PlaybackRepeat.fromId(action.substring('repeat:'.length));
      setState(() => _repeat = mode);
      widget.state.log.info('循环模式 ${mode.id}', scope: 'player');
      return;
    }
    if (action == 'sleep:end') {
      _applySleepTimer(const SleepTimerPlan.untilEpisodeEnd());
      return;
    }
    if (action == 'sleep:off') {
      _applySleepTimer(const SleepTimerPlan.idle());
      return;
    }
    final minutes = int.tryParse(action.substring('sleep:'.length));
    if (minutes != null) {
      _applySleepTimer(SleepTimerPlan.forDuration(Duration(minutes: minutes)));
    }
  }

  /// LUT 选择/清除：内置 / 我的 / 在线。
  Future<void> _showLutSettings() async {
    final result = await showModalBottomSheet<LutPickerResult>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => LutPickerSheet(
        store: _lutStore,
        currentPath: _options.lutPath.trim(),
        currentPresetId: _options.lutPresetId,
      ),
    );
    if (result == null || !mounted) return;
    await _applyLutPreset(result.cleared ? null : result.preset);
  }

  /// 落盘并应用 LUT；失败时保持原设置不变。
  ///
  /// 内置项先经 LutStore.materialize 写成真实文件——mpv 的 lut3d 只吃路径；
  /// 用户项在应用前整读校验一次，避免「列表里能选、点了却放不出画面」。
  Future<void> _applyLutPreset(LutPreset? preset) async {
    if (preset == null) {
      final applied = await _controller.applyLut(null);
      if (!applied) {
        _showPlayerMessage('当前播放内核不支持 LUT', kind: ToastKind.error);
        return;
      }
      await _persistOptions(_options.copyWith(lutPath: '', lutPresetId: ''));
      if (mounted) setState(() {});
      return;
    }
    try {
      if (!preset.isBundled) {
        final text = await File(preset.path).readAsString();
        final parsed = parseCube(text, path: preset.path);
        if (!parsed.ok) {
          _showPlayerMessage('LUT 不可用：${parsed.error}', kind: ToastKind.error);
          return;
        }
      }
      final path = await _lutStore.materialize(preset);
      final applied = await _controller.applyLut(path);
      if (!applied) {
        _showPlayerMessage('当前播放内核不支持 LUT', kind: ToastKind.error);
        return;
      }
      await _persistOptions(
        _options.copyWith(
          lutPath: path,
          lutPresetId: preset.isBundled ? preset.id : '',
        ),
      );
      if (mounted) setState(() {});
      _showPlayerMessage('已应用 LUT：${preset.name}', kind: ToastKind.success);
    } on LutStoreException catch (error) {
      _showPlayerMessage('LUT 不可用：${error.message}', kind: ToastKind.error);
    } catch (error) {
      _showPlayerMessage('LUT 加载失败：$error', kind: ToastKind.error);
    }
  }

  // `_persistOptions` 已搬到 `player_playback_params.dart`（`part` 里的 `_PlayerPageState` 扩展）。

  Future<void> _setSkipMode(SkipMode mode) async {
    await _persistOptions(_options.copyWith(skipMode: mode));
    if (!mounted) return;
    setState(() {});
    _maybeAutoSkip();
  }

  /// 沿用既有行为：off 时打开一个类型，将模式升为 auto。
  Future<void> _toggleAutoSkip(SkipKind kind) async {
    final bit = kind.bit;
    final on = (_options.skipKinds & bit) != 0;
    final kinds = on ? _options.skipKinds & ~bit : _options.skipKinds | bit;
    final mode = !on && _options.skipMode == SkipMode.off
        ? SkipMode.auto
        : _options.skipMode;
    await _persistOptions(_options.copyWith(skipKinds: kinds, skipMode: mode));
    if (!mounted) return;
    setState(() => _rebuildSkipPlan());
    _maybeAutoSkip();
  }

  Future<void> _showSkipOptions() =>
      _showSettingsAndSyncOptions(IntroSkipOptionsPage(state: widget.state));

  Future<void> _showSettingsAndSyncOptions(Widget page) async {
    await Navigator.of(context)
        .push<void>(MaterialPageRoute(builder: (_) => page));
    if (!mounted) return;
    setState(() {
      _options = widget.state.playerOptions;
      _rebuildSkipPlan();
    });
    _primeSkipPrefetch();
  }

  // `_showSubtitleMenu` 已搬到 `player_subtitle_menu.dart`（`part` 里的 `_PlayerPageState` 扩展）。

  void _rememberVolume(double volume) {
    unawaited(
      widget.state.setPlayerVolume(
        volume,
        resumeVolume: _controller.volumeState.resumeVolume,
      ),
    );
  }

  int _beginMediaTransition({SeekRecovery? seekRecovery}) {
    widget.state.cancelSkipPrefetch(
      clearCache: _skipMediaIdentity != _skipIdentityFor(_request),
    );
    _clearGesturePlaybackIntent();
    _clickGate.dispose();
    _playingBeforeFirstTap = null;
    // 同一次拖动不会跨媒体：换媒后松手不该再按旧状态续播，
    // 也不该把上一部片的拖动目标 seek 到新片上。
    _dragPauseGate.reset();
    _dragSeekTarget = null;
    _dragSeekCommittedAt = null;
    if (_hasQueue) {
      _pendingQueueItemKey = null;
      _pendingQueueStep = null;
    }
    if (_hasQueue && _progressReady) {
      _queueRestorePosition = _controller.position;
      _queueRestorePlaying = _controller.isPlaying;
    }
    widget.state.clearAiAdApplication();
    _originalAiSubtitle = null;
    _karaokeTrack = null;
    _karaokeLines = const [];
    _karaokeVisible = false;
    _audioAi?.seek(Duration.zero);
    if (_audioAi != null) unawaited(_audioAi!.stop());
    // 在替换请求或打开媒体前，最后一次用仍配对的旧标识保存。
    _persistProgress();
    _clearCompletionProgress();
    _progressReady = false;
    _skipArmed = false;
    _saveTimer?.cancel();
    _saveTimer = null;
    if ((widget.liveSession != null || _hasQueue) &&
        (_liveOpenInFlight ||
            _controller.hasPendingNativeOpen ||
            (_hasQueue && _controller.subtitleBusy))) {
      final previous = _controller;
      final volume = previous.volumeState;
      final rate = previous.rate;
      previous.removeListener(_onControllerChanged);
      _controller = PlayerController(
        observedMediaFormatFor: widget.state.proxyObservedFormatFor,
        initialVolume: volume.volume,
        initialResumeVolume: volume.resumeVolume,
        onVolumeChanged: _rememberVolume,
        onSeek: _onDanmakuSeek,
      )..addListener(_onControllerChanged);
      _bindGesturePlaybackStream();
      final replacement = _controller;
      _liveOpenInFlight = false;
      previous.dispose();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !identical(replacement, _controller)) return;
        unawaited(replacement.setRate(rate));
      });
    }
    // 采样基线与 seek 溯源随媒体一起作废：上一集的位置对新载入的媒体无意义。
    _controller.clearLastSeek();
    _lastPositionMs = -1;
    _seenSeekCount = _controller.seekCount;
    // 换集本身不是跳转；只有「用户跳转引起的重开」才武装伪结束闸门。
    _seekPending = seekRecovery != null;
    _skipSeekAt = null;
    _spuriousCompletion = false;
    // 每换一次媒体（含重试、换线路）都要换一份诊断基线。
    _loggedDurationMs = -1;
    _lastDurationLogAt = null;
    _loggedOverrun = false;
    // 换媒体（换集/换线路/重试）＝上一条弹幕的来源失效：留着它会让下一次
    // 搜索把「上一集的源」标成当前。
    _danmakuSourceUrl = null;
    _danmakuSeek = null;
    _recoveryTicker?.cancel();
    _recoveryTicker = null;
    final generation = ++_mediaGeneration;
    _seekRecovery = seekRecovery == null
        ? null
        : SeekRecovery(
            origin: seekRecovery.origin,
            target: seekRecovery.target,
            generation: generation,
            startedAt: seekRecovery.startedAt,
          );
    _queuedSeekPlaying = true;
    _seekRecoveryLastPosition = null;
    _seekRecoveryExcluded = false;
    _seekRecoveryFailure = null;
    if (seekRecovery == null) {
      _seekReloadOwner = null;
      _reloadInFlight = false;
      _queuedSeekTarget = null;
      _controller.endReposition();
    }
    if (_seekRecovery != null) _startRecoveryTicker();
    _errorGate = PlaybackErrorGate();
    _errorGateObservedRevision = _controller.playbackErrorRevision;
    _errorGateOwnedLoadError = false;
    return generation;
  }

  /// 播放中周期性写入进度（§15.2 “播放中写入进度”）。
  void _startProgressSaver() {
    if (!_progressReady) return;
    _saveTimer?.cancel();
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _persistProgress();
    });
  }

  void _persistProgress() {
    if (!_progressReady) return;
    // 直播没有可续播时间轴，引擎报出的伪时长不能污染点播播放历史。
    if (_request.isLive) return;
    // 本地文件不写历史：站标识是合成的「local-file」、集 id 就是磁盘路径，
    // 落库只会得到一条历史页点了「续播」回不去的记录。
    if (_request.isLocal) return;
    // seek 伪结束期间的位置是假的（引擎把 time-pos 报成了 duration），
    // 落库会把「点了一下进度条」写成「这一集已看完」，下次续播直接失效。
    if (_spuriousCompletion) return;
    // 显式跳至文件末尾的完成快照：位置按本集总长记录，离开本媒体后作废。
    final skipped = _skippedProgress;
    final completedDuration = skipped?.generation == _mediaGeneration
        ? skipped?.duration
        : null;
    final duration = completedDuration ?? _controller.duration;
    if (duration <= Duration.zero) return;
    final position = completedDuration ?? _controller.position;
    widget.state.recordProgress(
      vod: Vod(
        vodId: _request.vodId,
        vodName: _request.vodName,
        vodPic: _request.vodPic,
      ),
      flag: _request.playbackFlag,
      episodeName: _request.episodeName,
      // 存**站点入口目标**而不是解析后的播放地址：历史续播要把这个值回传给站点
      // 重新解析（§15.2）。存播放地址会得到「站点返回业务错误」，因为那是带时效
      // 签名的 CDN/代理地址，站点认不了（用户反馈 2026-10-09）。
      episodeId: _request.episodeTarget,
      position: position,
      duration: duration,
      siteKey: _request.siteKey,
      // 原来源播放（其它配置的历史）必须写回它自己的源：留空时
      // `recordProgress` 按生效源写入，那会让同一条记录在当前源里裂出第二条。
      sourceKey: _request.sourceKey,
      // 作品身份（历史同名聚合用，见 `core/history_grouping.dart`）：
      // 有 TMDB 身份就带上，没有则留空由聚合按片名回退。
      tmdbId: _request.tmdb?.tmdbId ?? 0,
      mediaType: _request.tmdb?.mediaType.name ?? '',
    );
    // 季度进度（`02` §6.2）：`UnknownSeason` 不写，电影不写。
    // 来源 `history` 无论如何都写（既有行为不变）。
    final identity = _request.tmdb;
    if (identity != null && identity.hasIdentity) {
      widget.state.recordSeasonProgress(
        identity: identity,
        scope: identity.hasSeason
            ? KnownSeason(identity.seasonNumber)
            : const UnknownSeason(),
        siteKey: _request.siteKey,
        vodId: _request.vodId,
        sourceFlag: _request.playbackFlag,
        sourceEpisodeName: _request.episodeName,
        // 同样必须存**站点入口目标**：`TmdbEpisodeLocator` 拿它与 `VodEpisode.url`
        // （详情里的入口目标）精确比对来定位集号，存解析后的可播地址（T4 站点是
        // 本地代理 `127.0.0.1/p/<token>/…`）永远匹配不上，季度续播就定位不到集。
        // 同时也让 `sourceHistoryKey` 与 `history.episodeId` 指向同一个值。
        sourceEpisodeUrl: _request.episodeTarget,
        positionMs: position.inMilliseconds,
        durationMs: duration.inMilliseconds,
      );
    }
  }

  @override
  void dispose() {
    widget.state.cancelSkipPrefetch();
    _releaseProxySession?.call();
    _releaseProxySession = null;
    windowManager.removeListener(this);
    // 路由 pop / 页面被替换时，窗口级全屏必须成对收尾；
    // 正常的返回路径已由 PopScope 处理，这里是最后兜底（幂等）。
    unawaited(_restoreWindowedModeIfOwned());
    widget.liveSession?.removeListener(_onPlaybackSessionChanged);
    widget.queue?.removeListener(_onQueueChanged);
    _playerFocus.dispose();
    _saveTimer?.cancel();
    _recoveryTicker?.cancel();
    _controlHideTimer?.cancel();
    _clickGate.dispose();
    _clearGesturePlaybackIntent();
    unawaited(_gesturePlayingSubscription?.cancel());
    _osdTimer?.cancel();
    _osdTimer = null;
    _endGestureSpeed();
    _persistProgress();
    _progressReady = false;
    _mediaGeneration++;
    // 直播弹幕会话是网络资源，必须显式关闭（§20 资源释放）。
    unawaited(_teardownLiveSession('dispose'));
    _sleepTicker?.cancel();
    _sleepTicker = null;
    _audioStateSubscription?.cancel();
    if (_audioAi != null) unawaited(_audioAi!.dispose());
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  void onWindowEnterFullScreen() {
    if (!mounted) return;
    setState(() {
      _fullscreen = true;
      _enteredFullscreen = true;
      _controlsVisible = true;
    });
    _touchControls();
  }

  @override
  void onWindowLeaveFullScreen() {
    if (!mounted) return;
    setState(() {
      _fullscreen = false;
      _enteredFullscreen = false;
      _controlsVisible = true;
    });
    _controlHideTimer?.cancel();
    // 兜住仍需要手动恢复标题栏的平台。
    unawaited(restoreWindowTitleBar());
  }

  Future<void> _toggleFullscreen() async {
    final next = !await windowManager.isFullScreen();
    try {
      if (next) {
        await enterPlayerFullscreen();
      } else {
        await restoreWindowedMode();
      }
      _enteredFullscreen = next;
    } catch (error) {
      // 非 Windows 平台可能已先隐藏标题栏，失败时也要恢复。
      await restoreWindowedMode();
      _enteredFullscreen = false;
      widget.state.log.warning('切换全屏失败：$error', scope: 'player');
      if (mounted) {
        showToast('全屏切换失败，请再试一次', kind: ToastKind.error);
      }
      return;
    }
    if (!mounted) return;
    final actual = await windowManager.isFullScreen();
    setState(() {
      _fullscreen = actual;
      _controlsVisible = true;
    });
    _touchControls();
  }

  /// 全屏状态下拦截返回：先恢复窗口，再真正 pop。
  ///
  /// 不能只靠 dispose()：dispose 时路由已经出栈，用户会先看到一帧
  /// 「全屏的列表页」；而且 pop 之后页面没了，没有任何 UI 能提示失败。
  Future<void> _onPopInvokedWithResult(bool didPop, Object? result) async {
    if (didPop || _popAfterRestore) return;
    _popAfterRestore = true;
    await restoreWindowedMode();
    _enteredFullscreen = false;
    if (!mounted) return;
    setState(() {
      _fullscreen = false;
      _controlsVisible = true;
    });
    // canPop 要等这一帧重建后才生效；postFrame 里再 pop，避免再次被
    // 自己的 PopScope 拦下（那会形成「恢复 → 拦截」的循环）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route == null || !route.isCurrent) {
        _popAfterRestore = false;
        return;
      }
      Navigator.of(context).pop(result);
    });
  }

  /// dispose() 兜底：只恢复**本页进入过**的全屏。
  ///
  /// 不能无条件 setFullScreen(false)：--fullscreen=true 是应用级启动参数
  /// （app.dart），播放器并没有拥有那次全屏。
  Future<void> _restoreWindowedModeIfOwned() async {
    if (!_enteredFullscreen) return;
    _enteredFullscreen = false;
    _fullscreen = false;
    await restoreWindowedMode();
  }

  Future<void> _exitFullscreen() async {
    if (await windowManager.isFullScreen()) await _toggleFullscreen();
  }

  List<VodEpisode> get _episodes =>
      _lineOf(_request.flag)?.episodes ?? const [];

  /// 按**展示名**找线路（`_request.flag` 与线路下拉用的都是展示名）。
  VodPlayLine? _lineOf(String flag) {
    for (final line in _request.playLines) {
      if (line.flag == flag) return line;
    }
    return null;
  }

  String _playbackFlagFor(String displayFlag) {
    for (final line in _request.playLines) {
      if (line.flag == displayFlag) return line.playbackFlag;
    }
    return displayFlag == _request.flag ? _request.playbackFlag : displayFlag;
  }

  void _clearQueueMediaView() {
    _episodesCache = const [];
    _danmakuItems = const [];
    _danmakuSourceUrl = null;
    _danmakuError = null;
    _lastShownDanmakuError = null;
    _lastShownSubtitleError = null;
    _diagnostics = null;
    _controller.setExternalSubtitles(const []);
    _controller.clearSubtitleError();
    _skipSegments = widget.state.skipSegmentsFor(
      siteKey: _request.siteKey,
      vodId: _request.vodId,
    );
    final fit = widget.state.playerVideoFitModeFor(
      siteKey: _request.siteKey,
      vodId: _request.vodId,
    );
    _videoFitMode = PlayerVideoFitMode.values.firstWhere(
      (mode) => mode.name == fit,
      orElse: () => PlayerVideoFitMode.contain,
    );
  }

  void _queueFailure(Object error) {
    final failure = error is AppError
        ? error
        : AppError(AppErrorKind.unknown, '$error', cause: error);
    setState(() => _loadError = failure.userMessage);
    _controller.clearCompleted();
    widget.state.log.error('目录队列播放失败 ${failure.logLine}', scope: 'player');
  }

  Future<void> _openQueueItem(String key) async {
    final queue = widget.queue;
    if (!_hasQueue || queue == null) return;
    if (_externalPlayerRunning != null) {
      if (!await _confirmDropExternalPlayback() || !mounted) return;
      setState(() => _externalPlayerRunning = null);
    }
    final generation = _beginMediaTransition();
    _pendingQueueItemKey = key;
    _pendingQueueStep = null;
    setState(() => _loadError = null);
    bool isCurrent() =>
        mounted &&
        generation == _mediaGeneration &&
        identical(queue, widget.queue);
    try {
      final request = await queue.resolve(key, isCurrent: isCurrent);
      if (!isCurrent()) return;
      setState(() {
        _request = request;
        _queueItemKey = key;
        _pendingQueueItemKey = null;
        _queueRestorePosition = request.startPosition;
        _queueRestorePlaying = true;
        _clearQueueMediaView();
      });
      await _teardownLiveSession('queue-file-change');
      if (!isCurrent()) return;
      await _load();
    } catch (error) {
      if (isCurrent()) _queueFailure(error);
    }
  }

  Future<void> _advanceQueue() async {
    if (_repeat == PlaybackRepeat.one) {
      await _replayCurrent();
      return;
    }
    await _stepQueue(1, automatic: true);
  }

  Future<void> _stepQueue(int delta, {bool automatic = false}) async {
    final queue = widget.queue;
    if (!_hasQueue || queue == null || _queueIndex < 0) return;
    if (automatic && _repeat == PlaybackRepeat.off && !_options.autoNext) {
      return;
    }
    if (!automatic &&
        (_queueIndex + delta < 0 || (delta > 0 && !_queueCanGoNext))) {
      return;
    }
    final key = _queueItemKey;
    final generation = _beginMediaTransition();
    _pendingQueueItemKey = null;
    _pendingQueueStep = delta;
    _pendingQueueAutomatic = automatic;
    bool isCurrent() =>
        mounted &&
        generation == _mediaGeneration &&
        identical(queue, widget.queue) &&
        key == _queueItemKey;
    try {
      var snapshot = queue.snapshot;
      var index = snapshot.items.indexWhere((item) => item.key == key);
      while (delta > 0 &&
          index + 1 >= snapshot.items.length &&
          snapshot.hasMore) {
        final count = snapshot.items.length;
        await queue.loadMore();
        if (!isCurrent()) return;
        snapshot = queue.snapshot;
        if (snapshot.error != null) throw snapshot.error!;
        index = snapshot.items.indexWhere((item) => item.key == key);
        if (snapshot.hasMore && snapshot.items.length == count) {
          throw AppError(AppErrorKind.unknown, '目录暂无新增剧集，请重试加载');
        }
      }
      if (!isCurrent()) return;
      if (index < 0) throw AppError(AppErrorKind.unknown, '当前文件已不在目录队列中');
      final int next;
      if (automatic) {
        final decision = decidePlaybackAdvance(
          repeat: _repeat,
          autoNext: _options.autoNext,
          currentIndex: index,
          episodeCount: snapshot.items.length,
          genuineEnd: true,
        );
        if (decision.nextIndex == null) {
          _pendingQueueStep = null;
          if (_sleepTimer.shouldStopOnEpisodeEnd()) _stopBySleepTimer();
          return;
        }
        next = decision.nextIndex!;
      } else {
        next = index + delta;
      }
      _pendingQueueStep = null;
      if (next < 0 || next >= snapshot.items.length) return;
      await _openQueueItem(snapshot.items[next].key);
    } catch (error) {
      if (isCurrent()) _queueFailure(error);
    }
  }

  Future<void> _retryPlayback() async {
    if (!_hasQueue) {
      await _load();
      return;
    }
    final key = _pendingQueueItemKey;
    if (key != null) {
      await _openQueueItem(key);
      return;
    }
    final step = _pendingQueueStep;
    if (step != null) {
      await _stepQueue(step, automatic: _pendingQueueAutomatic);
      return;
    }
    await _reloadQueueCurrent();
  }

  Future<void> _reloadQueueCurrent({Duration? position}) async {
    final intent = _request;
    final start =
        position ??
        (_progressReady
            ? _controller.position
            : _queueRestorePosition ?? intent.startPosition);
    final playing = _progressReady
        ? _controller.isPlaying
        : _queueRestorePlaying ?? _controller.isPlaying;
    final generation = _beginMediaTransition();
    _pendingQueueItemKey = null;
    _pendingQueueStep = null;
    bool isCurrent() =>
        mounted &&
        generation == _mediaGeneration &&
        identical(intent, _request);
    try {
      // 本地文件没有站点可重新解析：重试＝直接重开同一个路径。
      if (intent.isLocal) {
        await _load(restorePlaying: playing);
        return;
      }
      final route = intent.lineRoutes[intent.flag];
      final decision = await _resolvePlayback(
        episodeTarget: intent.episodeTarget,
        flag: intent.playbackFlag,
        vodId: route?.vodId ?? intent.vodId,
        route: route,
        qualityIndex: intent.qualityIndex,
        isCurrent: isCurrent,
      );
      if (!isCurrent()) return;
      if (decision?.url == null) {
        throw AppError(AppErrorKind.playbackUrlMissing, '本文件没有可用播放地址');
      }
      // 新结果没有可切换解析源时丢掉上一次的手动指定：留着它会被带到
      // 下一个需要解析的集，变成用户没选过的解析器。
      if (decision!.parseSources.isEmpty) _parseSourceOverride = null;
      setState(() {
        _request = intent.copyWith(
          tmdb: intent.tmdb,
          url: decision.url!,
          headers: decision.headers?.asRequestHeaders ?? const {},
          subtitleHeaders: decision.assetHeaders?.asRequestHeaders ?? const {},
          qualities: decision.qualities,
          qualityIndex: decision.qualityIndex,
          // 解析选项随本次决策**无条件**覆盖（含空值）：直链结果必须清掉
          // 上一次解析留下的入口，否则控制区会挂着点了不生效的解析条。
          parseSources: decision.parseSources,
          parseSource: decision.parseSource,
          subtitles: decision.subs,
          danmaku: decision.danmaku,
          startPosition: start,
          clearStartPosition: start == null,
          clearResumeSeed: true,
        );
        _clearQueueMediaView();
      });
      await _teardownLiveSession('queue-retry');
      if (!mounted || generation != _mediaGeneration) return;
      await _load(restorePlaying: playing);
    } catch (error) {
      if (isCurrent()) _queueFailure(error);
    }
  }

  Future<void> _playEpisode(
    int index, {
    String? overrideFlag,
    Duration? startPosition,
    bool restorePlaying = true,
    double? rate,
  }) async {
    if (_isLive) {
      widget.liveSession!.selectLine(index);
      return;
    }
    if (_isCatchup) return;
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
        startPosition: startPosition,
        restorePlaying: restorePlaying,
        rate: rate,
      );
      return;
    }
    final episodes = _episodesCache.isNotEmpty ? _episodesCache : _episodes;
    if (index < 0 || index >= episodes.length) return;
    await _openTarget(episodes[index], flag: flag, episodeIndex: index);
  }

  List<VodEpisode> _episodesCache = const [];

  /// 本次播放手动指定的解析源（解析源切换栏）。
  ///
  /// `null` = 默认（超级解析，自动遍历所有解析器）。**刻意不落盘**：用户点一下
  /// 只是为了救这一集，记住它会让下一部片悄悄用错源（安卓的解析源选择也不跨
  /// 播放持久化）。
  String? _parseSourceOverride;

  /// 失败时的可观测性（`design/03` §4.6）。
  ///
  /// 缓存耗尽（提前 EOF）当前在 PC 侧**不可见**：media_kit 很可能无法区分
  /// 「正常播到片尾」与「源站断流」，因此退化为记录失败瞬间的
  /// `position`/`duration`/`buffered` 与 `nearEnd` 结论。
  ///
  /// 关键作用：`nearEnd=false` 的失败**永远**不触发连播（已由
  /// [_maybeAdvanceOnGenuineEnd] 的真播完闸门保证），这条日志是事后
  /// 排查「到底是不是提前 EOF」的唯一线索。
  void _logFailureDiagnostics(PlayerLoadOutcome outcome) {
    final duration = _controller.duration;
    final position = _controller.position;
    final nearEnd = isGenuineEndDuration(
      duration: duration,
      position: position,
    );
    widget.state.log.warning(
      '播放失败定位 kind=${outcome.failureKind?.name ?? "unknown"} '
      'position=${position.inMilliseconds}ms '
      'duration=${duration.inMilliseconds}ms '
      'buffered=${_controller.buffered.inMilliseconds}ms '
      'nearEnd=$nearEnd '
      'episode=${_request.episodeName} '
      'episodeIndex=${_request.episodeIndex}',
      scope: 'player',
    );
  }

  /// 本次播放是否用**记录自己那份配置**解析（跨源续播）。
  bool get _crossSource {
    final source = _request.sourceKey.trim();
    return source.isNotEmpty && source != widget.state.activeSourceKey;
  }

  /// 本次播放的解析入口（换集/切线路/失败重试都走它）。
  ///
  /// 为什么不让调用点各写一遍：原来源播放（`_request.sourceKey` 是**别的**
  /// 配置）必须一直用那份配置解析，任何一处漏掉就会回落到当前配置的同名站点上，
  /// 表现为「换集后播的是当前源的另一部片」。
  ///
  /// [route] 是这条线路自己的来源路由（`PlaybackRequest.lineRoutes`）。跨源时
  /// **必须**把路由的 `siteKey`/`vodId` 交给 [AppState.resolvePlaybackForSource]：
  /// 请求上的 `siteKey`/`vodId` 是**记录**的身份（目录记录就是父目录 id），
  /// 拿它去问那份配置会解析到别的条目，甚至被站源判为业务错误。
  Future<PlaybackDecision?> _resolvePlayback({
    required String episodeTarget,
    required String flag,
    required String vodId,
    SwapLineRoute? route,
    int? qualityIndex,
    bool Function()? isCurrent,
  }) async {
    final labels = _request.adBlockLabelsFor(
      episodeTarget: episodeTarget,
      flag: flag,
    );
    final decision = await _resolvePlaybackForLabels(
      episodeTarget: episodeTarget,
      flag: flag,
      vodId: vodId,
      route: route,
      qualityIndex: qualityIndex,
      isCurrent: isCurrent,
    );
    // 解析过程中每次撤销会话都会清空归属，所以只能**成功之后**登记：
    // 随后的清单请求由代理读取它记账，换集时不会继承上一集的标签。
    if (decision != null) widget.state.noteAdBlockPlayback(labels);
    return decision;
  }

  /// 真正的解析（归属登记见 [_resolvePlayback]）。
  Future<PlaybackDecision?> _resolvePlaybackForLabels({
    required String episodeTarget,
    required String flag,
    required String vodId,
    SwapLineRoute? route,
    int? qualityIndex,
    bool Function()? isCurrent,
  }) {
    // 本地文件没有站点可问：解析＝把磁盘路径当播放入口发给站源，只会拿到业务
    // 错误。这里返回 null 兜底，各调用点另有自己的短路（画质/队列路径提前
    // return，_openTarget 走直连分支）。
    if (_request.isLocal) return Future<PlaybackDecision?>.value();
    final state = widget.state;
    if (_crossSource) {
      return state.resolvePlaybackForSource(
        sourceKey: _request.sourceKey,
        siteKey: route?.siteKey ?? _request.siteKey,
        qualityIndex: qualityIndex,
        isCurrent: isCurrent,
        episodeTarget: episodeTarget,
        flag: flag,
        vodId: vodId,
        preferredParseName: _parseSourceOverride,
      );
    }
    return state.resolvePlayback(
      episodeTarget: episodeTarget,
      flag: flag,
      vodId: vodId,
      siteOverride: route == null ? null : state.siteByKey(route.siteKey),
      qualityIndex: qualityIndex,
      isCurrent: isCurrent,
      preferredParseName: _parseSourceOverride,
    );
  }

  // -------------------------------------------------------------- 外部播放器

  /// 当前外调中的播放器；`null` 表示没有外调播放。
  ///
  /// 只在 UI 层记事：外部进程什么时候退出我们不知道，也不去轮询。它只用来
  /// 回答一个问题——换集前要不要提醒用户「外部播放会断」。
  String? _externalPlayerRunning;

  /// 用外部本地播放器打开当前这一集。
  ///
  /// 入口只放在播放器页：外部播放器要的是**已经解析好的媒体地址**，而地址、
  /// Header 注入与代理会话都只在这一层存在（详情页手里只有站点入口目标）。
  Future<void> _openInExternalPlayer() async {
    final previous = widget.state.externalPlayerPath;
    final missing = previous != null && !File(previous).existsSync();
    final executable = await _pickExternalPlayer(pathMissing: missing);
    if (!mounted || executable == null) return;

    final result = await ExternalPlayers.launch(
      executable: executable,
      url: _request.url,
      starter: widget.externalPlayerStarter,
    );
    if (!mounted) return;
    if (!result.ok) {
      _showPlayerMessage(result.error ?? '外部播放器启动失败', kind: ToastKind.error);
      return;
    }
    // 外调成功后暂停内置：否则两个播放器同时出声。
    unawaited(_controller.pause());
    setState(() => _externalPlayerRunning = executable);
    _showPlayerMessage('已用外部播放器打开', kind: ToastKind.success);
  }

  /// 上次路径只预选，只有确认使用后才记录并外调。
  Future<String?> _pickExternalPlayer({bool pathMissing = false}) async {
    final chosen = await showDialog<String>(
      context: context,
      builder: (_) => ExternalPlayerPickerDialog(
        loadPlayers: widget.state.listExternalPlayers,
        savePlayer: widget.state.saveExternalPlayer,
        selectedPath: widget.state.externalPlayerPath,
        pathMissing: pathMissing,
      ),
    );
    if (!mounted || chosen == null) return null;
    final saved = await widget.state.setExternalPlayerPath(chosen);
    if (!mounted) return null;
    if (!saved) {
      _showPlayerMessage('播放器选择保存失败，请重试。', kind: ToastKind.error);
      return null;
    }
    return chosen;
  }

  /// 换集前确认：外部播放器拿的是本地代理地址，换集会让代理重建会话。
  Future<bool> _confirmDropExternalPlayback() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('中断外部播放？'),
        content: const Text('换集会切换本地代理会话，外部播放器里的这一集会立即中断。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('继续换集'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  TmdbPlaybackIdentity? _identityForEpisode(VodEpisode episode, String flag) =>
      aiPlaybackIdentityForEpisode(_request.tmdb, episode, flag);

  Future<void> _openTarget(
    VodEpisode episode, {
    required String flag,
    required int episodeIndex,
    Duration? startPosition,
    bool restorePlaying = true,
    double? rate,
  }) async {
    final state = widget.state;
    // 外调播放依赖当前代理会话：换集会重建会话并撤掉 token，外部播放器随即
    // 断流。撤之前先把话说清楚，别让用户以为播放器自己崩了。
    // 顺序在 `_beginMediaTransition()` **之前**：用户取消换集时不应该已经
    // 落了一次进度、并把旧一代的媒体回调判成过期。
    if (_externalPlayerRunning != null) {
      final proceed = await _confirmDropExternalPlayback();
      if (!mounted || !proceed) return;
      setState(() => _externalPlayerRunning = null);
    }
    final generation = _beginMediaTransition();
    try {
      // 直播：地址已是最终可播地址，不经站点解析（§13.3）。
      final String url;
      final List<SubtitleInfo> subtitles;
      final List<DanmakuSource> danmaku;
      final List<PlaybackQuality> qualities;
      final int qualityIndex;
      final Map<String, String> headers;
      final Map<String, String> subtitleHeaders;
      // 换集后解析源选择也要跟着这一集的决策走：不同线路/不同集可以是不同
      // 的解析路径（直链集不该继承上一集的解析条）。
      final List<String> parseSources;
      final String parseSource;
      // 提到外层：下面写进度归属时要判断「这一集是不是外部并入线路」。
      final route = _request.lineRoutes[flag];
      // 直播与本地文件的地址都已是最终可播地址：本地路径没有站点可以重新解析，
      // 走这条分支才不会把磁盘路径发给站源。
      if (_request.directUrl || _request.isLocal) {
        url = episode.url;
        subtitles = _request.subtitles;
        danmaku = _request.danmaku;
        qualities = const [];
        qualityIndex = 0;
        headers = _request.headers;
        subtitleHeaders = _request.subtitleHeaders;
        // 直播/本地直连不经站点解析：没有可切换的解析源。
        parseSources = const [];
        parseSource = '';
      } else {
        // 外部（换源并入）线路：只定向解析到它自己的站点，**不**切全局站源。
        final decision = await _resolvePlayback(
          episodeTarget: episode.url,
          flag: _playbackFlagFor(flag),
          vodId: route?.vodId ?? _request.vodId,
          route: route,
          isCurrent: _hasQueue
              ? () => mounted && generation == _mediaGeneration
              : null,
        );
        if (decision == null || decision.url == null) {
          throw AppError(
            AppErrorKind.playbackUrlMissing,
            '播放决策没有返回可用地址',
            detail: 'flag=$flag episode=${episode.name}',
          );
        }
        url = decision.url!;
        // 换集后字幕/弹幕也要换成该集结果里的 subs/danmaku（§10.3、Phase 3）。
        subtitles = decision.subs;
        danmaku = decision.danmaku;
        qualities = decision.qualities;
        qualityIndex = decision.qualityIndex;
        headers = decision.headers?.asRequestHeaders ?? const {};
        subtitleHeaders = decision.assetHeaders?.asRequestHeaders ?? const {};
        parseSources = decision.parseSources;
        parseSource = decision.parseSource;
      }
      if (!mounted || generation != _mediaGeneration) return;
      // 换集后新结果没有可切换解析源时，手动指定不再成立。
      if (parseSources.isEmpty) _parseSourceOverride = null;
      setState(() {
        _loadError = null;
        _request = _request.copyWith(
          url: url,
          // 换集必须把「站点入口目标」一起换成该集的输入值（`episode.url`），
          // 否则历史里记的仍是上一集的入口，续播会跳回上一集。
          episodeTarget: episode.url,
          episodeName: episode.name,
          tmdb: _identityForEpisode(episode, flag),
          flag: flag,
          playbackFlag: _playbackFlagFor(flag),
          headers: headers,
          subtitleHeaders: subtitleHeaders,
          qualities: qualities,
          qualityIndex: qualityIndex,
          parseSources: parseSources,
          parseSource: parseSource,
          episodeIndex: episodeIndex,
          // 自动恢复换线时把**真实播到的位置**显式带过去（§3.1）：目标线路自己的
          // 历史不参与决定起点，否则「换线路续播」会变成「从新线路自己的记录续」。
          startPosition: startPosition,
          clearStartPosition: startPosition == null,
          // 种子属于**原记录那一集**：换集后必须一起清掉，否则会被当成
          // 「这一集也要按原进度续播」而把用户丢到新集的中段。
          clearResumeSeed: true,
          subtitles: subtitles,
          danmaku: danmaku,
          // 切到外部并入线路时，这条线路属于**当前配置**：进度不能再写回
          // 原来源（否则历史里多出一条挂错源的记录）。
          // 跨源续播的目录线路不属于这种情况：它们是**记录自己那份配置**展开出来
          // 的，清掉 sourceKey 会把一次换集的进度写进当前源，历史里立刻多一条
          // 挂错源的记录。
          clearSourceKey: route != null && !_crossSource,
        );
        _episodesCache = const [];
        // 换集后旧弹幕立即失效，避免新集开头出现上一集的弹幕；
        // 直播弹幕连接也必须断开，否则切集后旧会话会继续推流到新画面上。
        _danmakuItems = const [];
        _danmakuSourceUrl = null;
        _danmakuError = null;
      });
      await _teardownLiveSession('episode-change');
      if (!mounted || generation != _mediaGeneration) return;
      await _load(restorePlaying: restorePlaying, restoreRate: rate);
    } catch (error) {
      if (!mounted || generation != _mediaGeneration) return;
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      setState(() => _loadError = failure.userMessage);
      state.log.error('切换剧集失败 ${failure.logLine}', scope: 'player');
    }
  }

  /// 从最近一次配对就绪时保存的进度续播（失败态三出口之二）。
  ///
  /// 转换与失败窗口不再写入；重新查库避免沿用请求里较早的续播种子。
  ///
  /// 恢复路径**不得**触发连播（`design/03` §4.5 步骤 5、P5）：
  /// 这里只重建 `_request` 并重新 `_load()`；`_load()` 成功路径不调
  /// `_playNext()`，且 `open()` 会先把 `_completed` 复位。
  Future<void> _resumeFromLatestProgress() async {
    final state = widget.state;
    final latest = state.resumePositionFor(
      siteKey: _request.siteKey,
      vodId: _request.vodId,
      flag: _request.flag,
      episodeId: _request.episodeTarget,
      // 同步来的历史 `episode_id` 是安卓哈希，与 `episodeTarget` 不同源，
      // 需要集名兜底（详见 `AppDatabase.findHistory` 的三级匹配）。
      episodeName: _request.episodeName,
      // 原来源播放要查它自己那条源的行，否则查不到任何进度。
      sourceKey: _request.sourceKey.trim().isEmpty ? null : _request.sourceKey,
    );
    if (_hasQueue) {
      await _reloadQueueCurrent(position: latest);
      return;
    }
    // 查不到（已看完 / 无记录 / 低于续播下限）时退回「重试本集」语义，
    // 而不是静默无动作——用户点了按钮就必须有反馈。
    if (latest == null) {
      widget.state.log.info(
        '失败态续播：库内无可续播进度，退化为重试本集 '
        'episode=${_request.episodeName}',
        scope: 'player',
      );
      await _load();
      return;
    }
    widget.state.log.info(
      '失败态续播：position=${latest.inMilliseconds}ms '
      'episode=${_request.episodeName}',
      scope: 'player',
    );
    setState(() {
      // 这里查到的就是**这一集**的最新进度，比种子更准；种子必须清掉，
      // 否则 `_load()` 会拿种子再算一次把它覆盖掉。
      _request = _request.copyWith(
        tmdb: _request.tmdb,
        startPosition: latest,
        clearResumeSeed: true,
      );
    });
    await _load();
  }

  bool _episodeVersionSelectionInFlight = false;

  List<EpisodeGroup>? _aggregatedEpisodeGroups(List<VodEpisode> episodes) {
    if (_isLive ||
        _isCatchup ||
        _hasQueue ||
        _request.isLocal ||
        !widget.state.episodeAggregateVersions) {
      return null;
    }
    final groups = EpisodeAggregation.build(
      episodes,
      scope: '${_request.siteKey}/${_request.vodId}/${_request.flag}',
    );
    return groups.any((group) => group.isMultiple) ? groups : null;
  }

  Future<void> _playAggregatedAdjacent(
    List<VodEpisode> episodes,
    List<EpisodeGroup> groups,
    int direction, {
    bool wrap = false,
    bool pauseForSelection = true,
  }) async {
    if (_episodeVersionSelectionInFlight) return;
    final currentIndex = _request.episodeIndex;
    if (currentIndex < 0 || currentIndex >= episodes.length) return;
    final current = episodes[currentIndex];
    if (current.url != _request.episodeTarget) return;
    var group = EpisodeAggregation.adjacentGroup(
      groups,
      currentSourceIndex: currentIndex,
      direction: direction,
    );
    if (group == null &&
        wrap &&
        groups.last.versions.any((v) => v.sourceIndex == currentIndex)) {
      group = EpisodeAggregation.adjacentGroup(
        [groups.last, groups.first],
        currentSourceIndex: currentIndex,
        direction: 1,
      );
    }
    if (group == null) return;
    final identity = _request.tmdb;
    if (identity != null && identity.hasSeason) {
      for (final version in group.versions) {
        if (TmdbAutoPlay.nextIndex(
              episodes: [current, version.episode],
              currentIndex: 0,
              availableSeasons: [identity.seasonNumber],
              selectedSeason: identity.seasonNumber,
            ) <
            0) {
          return;
        }
      }
    }
    final generation = _mediaGeneration;
    final request = _request;
    bool isCurrentMedia() =>
        mounted && generation == _mediaGeneration && request == _request;
    var version = EpisodeAggregation.preferredVersion(group, current);
    if (version == null) {
      _episodeVersionSelectionInFlight = true;
      final restorePlaying = pauseForSelection && _controller.isPlaying;
      try {
        if (restorePlaying) await _controller.pause();
        if (!mounted ||
            !isCurrentMedia() ||
            !widget.state.episodeAggregateVersions) {
          return;
        }
        version = await showEpisodeVersionDialog(
          context,
          group: group,
          lineName: request.flag,
        );
      } finally {
        try {
          if (restorePlaying &&
              isCurrentMedia() &&
              (version == null || !widget.state.episodeAggregateVersions)) {
            await _controller.play();
          }
        } finally {
          _episodeVersionSelectionInFlight = false;
        }
      }
    }
    if (!mounted ||
        generation != _mediaGeneration ||
        request != _request ||
        !widget.state.episodeAggregateVersions ||
        version == null) {
      return;
    }
    await _openTarget(
      version.episode,
      flag: request.flag,
      episodeIndex: version.sourceIndex,
    );
  }

  Future<void> _playNext() async {
    if (_isLive) {
      widget.liveSession!.stepChannel(1);
      return;
    }
    if (_isCatchup) return;
    if (_hasQueue) {
      await _stepQueue(1);
      return;
    }
    final episodes = _episodesCache.isNotEmpty ? _episodesCache : _episodes;
    if (episodes.isEmpty) return;
    final groups = _aggregatedEpisodeGroups(episodes);
    if (groups != null) {
      await _playAggregatedAdjacent(episodes, groups, 1);
      return;
    }
    final identity = _request.tmdb;
    // 自动连播**不跨季度**（`04` §8.4）：季度边界处停止。
    final next = identity == null || !identity.hasSeason
        ? (_request.episodeIndex + 1 < episodes.length
              ? _request.episodeIndex + 1
              : -1)
        : TmdbAutoPlay.nextIndex(
            episodes: episodes,
            currentIndex: _request.episodeIndex,
            availableSeasons: [identity.seasonNumber],
            selectedSeason: identity.seasonNumber,
          );
    if (next < 0) return;
    await _openTarget(episodes[next], flag: _request.flag, episodeIndex: next);
  }

  Future<void> _playPrevious() async {
    if (_isLive) {
      widget.liveSession!.stepChannel(-1);
      return;
    }
    if (_isCatchup) return;
    if (_hasQueue) {
      await _stepQueue(-1);
      return;
    }
    final episodes = _episodesCache.isNotEmpty ? _episodesCache : _episodes;
    if (episodes.isEmpty) return;
    final groups = _aggregatedEpisodeGroups(episodes);
    if (groups != null) {
      await _playAggregatedAdjacent(episodes, groups, -1);
      return;
    }
    final previous = _request.episodeIndex - 1;
    if (previous < 0) return;
    await _openTarget(
      episodes[previous],
      flag: _request.flag,
      episodeIndex: previous,
    );
  }

  bool get _navigationAvailable =>
      !_isLive && _controller.duration > Duration.zero;

  Future<void> _seekToKeyframe({required bool forward}) async {
    if (!_navigationAvailable) return;
    var succeeded = false;
    try {
      succeeded = await _controller.seekToKeyframe(forward: forward);
    } catch (_) {}
    if (mounted && !succeeded) {
      showToast('关键帧跳转不可用', duration: const Duration(seconds: 3));
    }
  }

  /// 画面是否停滞到「弹幕应该原地不动」：加载、缓冲、定位都算。
  ///
  /// 它**不等于**缓冲提示用的 `showBufferingIndicator`：那个判据刻意在 loading
  /// 时返回 false（已有全屏 LoadingBlock，不再叠第二个圈），而弹幕在 loading
  /// 期间同样不该推进，所以这里是两者的**并集**。改动任一判据时两处要一起看。
  bool get _pictureStalled =>
      _controller.isLoading ||
      showBufferingIndicator(
        isBuffering: _controller.isBuffering,
        isSeeking: _controller.isSeeking,
        isLoading: _controller.isLoading,
      );

  @override
  Widget build(BuildContext context) {
    final audioInputGeneration = _mediaGeneration;
    final shortcuts = buildPlayerShortcuts(
      togglePlay: _controller.playOrPause,
      seekBackward: () => _controller.seekBy(const Duration(seconds: -10)),
      seekForward: () => _controller.seekBy(const Duration(seconds: 10)),
      previousKeyframe: _navigationAvailable
          ? () => unawaited(_seekToKeyframe(forward: false))
          : null,
      nextKeyframe: _navigationAvailable
          ? () => unawaited(_seekToKeyframe(forward: true))
          : null,
      volumeUp: () => _controller.setVolume(_controller.volume + 5),
      volumeDown: () => _controller.setVolume(_controller.volume - 5),
      toggleMute: _controller.toggleMute,
      previousEpisode: _playPrevious,
      nextEpisode: _playNext,
      toggleFullscreen: _toggleFullscreen,
      exitFullscreen: _exitFullscreen,
    );
    shortcuts[const SingleActivator(
          LogicalKeyboardKey.keyN,
          shift: true,
          includeRepeats: false,
        )] =
        _toggleAudioNormalization;
    if (_isLive || _isCatchup) {
      shortcuts.removeWhere(
        (activator, _) =>
            activator is SingleActivator &&
            (activator.trigger == LogicalKeyboardKey.bracketLeft ||
                activator.trigger == LogicalKeyboardKey.bracketRight),
      );
    }
    if (_isLive) {
      shortcuts[const SingleActivator(LogicalKeyboardKey.pageUp)] = () =>
          _stepChannelFromKeyboard(-1);
      shortcuts[const SingleActivator(LogicalKeyboardKey.pageDown)] = () =>
          _stepChannelFromKeyboard(1);
    }
    // Phase 9：Alt+[ / Alt+] 手动跳过片头/片尾（避免占用已有的 [ / ]）。
    shortcuts[const SingleActivator(
      LogicalKeyboardKey.bracketLeft,
      alt: true,
    )] = () {
      unawaited(_manualSkip(SkipAction.intro));
    };
    shortcuts[const SingleActivator(
      LogicalKeyboardKey.bracketRight,
      alt: true,
    )] = () {
      unawaited(_manualSkip(SkipAction.outro));
    };
    // 右键菜单的键盘入口：菜单里的 37 行主项（LUT、音轨、视频轨、标记片头
    // 片尾等）没有别的入口，只靠鼠标右键就等于把它们对键盘用户关掉了。
    //
    // **为什么不改 `buildPlayerShortcuts`**：那是 `app.dart` 里的共享纯函数，
    // 签名被多个页面锁定，改它要把「本页才有的菜单」概念塞进公共 API；
    // 而本页已经在它返回的 map 上做追加（上面 Alt+[ / Alt+] 就是先例），
    // 沿用同一条路风险最小。
    //
    // 这三个激活器在 `buildPlayerShortcuts` 里都没有登记（那张表只有
    // space/←/→/↑/↓/M/[/]/F11/F/Esc，见 `app.dart:1372-1384`），所以直接
    // 赋值不会覆盖既有绑定。
    for (final activator in _contextMenuActivators) {
      shortcuts[activator] = _openContextMenuAtCenter;
    }

    if (_controller.isCompleted) {
      // 连播**不**在这里触发（`design/03` §4.1 D1）：
      // `build()` 会被任何一次 `setState` 走到，在这里排 postFrameCallback
      // 等于把「重建」当成「播完」的信号。真正的触发点是
      // `_onControllerChanged()` 里的 `_maybeAdvanceOnGenuineEnd()`。
      //
      // 这里只保留一个**兜底**：若因异常路径漏掉了事件（例如控制器在
      // `initState` 订阅生效前就已 completed），下一次重建时补一次判定。
      // 判定本身带单次守卫与真播完闸门，因此重复调用是安全的。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeAdvanceOnGenuineEnd();
      });
    }

    // 菜单打开时 Esc 只关菜单，不退出全屏（`design/04` §5.3）。
    //
    // **必须在同一张表里改，不能靠「内层 `CallbackShortcuts` 优先」**：
    // 键盘事件从主焦点节点**沿祖先向上冒泡**，而嵌套的那个
    // `CallbackShortcuts` 是主焦点的**后代**，根本不在冒泡路径上。
    // 实测：菜单打开时按 Esc，菜单不关、反而退出了全屏。
    //
    // 这里按「是否接受 Esc」筛掉旧绑定再插新绑定，而不是
    // `shortcuts[const SingleActivator(escape)] = ...` 直接覆盖——
    // `SingleActivator` 没有重写 `==`/`hashCode`，直接覆盖能否命中
    // 取决于 `const` 规范化这个实现细节；而 `CallbackShortcuts`
    // 取**首个**命中的绑定，漏掉旧绑定就会让 `exitFullscreen` 继续赢。
    if (_contextMenuAnchor != null || _hasLivePanels) {
      shortcuts.removeWhere(
        (activator, _) =>
            activator is SingleActivator &&
            activator.trigger == LogicalKeyboardKey.escape,
      );
      shortcuts[const SingleActivator(LogicalKeyboardKey.escape)] =
          _hasLivePanels ? _closeLivePanels : _closeContextMenu;
    }

    return PopScope<Object?>(
      canPop: !_fullscreen,
      onPopInvokedWithResult: _onPopInvokedWithResult,
      child: CallbackShortcuts(
        bindings: shortcuts,
        child: Focus(
          focusNode: _playerFocus,
          autofocus: true,
          child: Scaffold(
            backgroundColor: Colors.black,
            // 顶栏改由浮层承载（`design/01` §4.2）：全屏时不再置 null，
            // 于是进出全屏不再有 56px 跳变。
            appBar: null,
            body: Theme(
              data: buildAppTheme(Brightness.dark),
              child: Stack(
                children: [
                  // 第 1 层：画面 + 弹幕 + 加载/错误。
                  Positioned.fill(
                    // 指针在画面上移动即唤醒（`design/01` §4.5）。
                    // **只在隐藏态唤醒**：可见时若也调 `_touchControls`，
                    // 指针每动一次都会重置 3 秒计时器，控制栏将永不隐藏。
                    child: MouseRegion(
                      onHover: (_) {
                        if (!_controlsVisible) _touchControls();
                      },
                      child: GestureDetector(
                        key: _videoGestureKey,
                        behavior: HitTestBehavior.opaque,
                        // 不注册 onDoubleTap：单击仍立即落地，双击由 _clickGate 判定。
                        onTapUp: (details) =>
                            _onVideoTap(details.localPosition),
                        onLongPressStart: (_) => _beginGestureSpeed(),
                        onLongPressEnd: (_) => _endGestureSpeed(),
                        onLongPressCancel: _endGestureSpeed,
                        // 右键：打开菜单（`design/04` §5.1）。
                        // 两个回调都指向同一方法，方法内部幂等。
                        onSecondaryTapDown: (details) =>
                            _openContextMenu(details.globalPosition),
                        onSecondaryTap: () {},
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: Video(
                                controller: _controller.videoController,
                                fit: _videoFitMode.fit,
                                aspectRatio: _videoFitMode.aspectRatio,
                                controls: NoVideoControls,
                                subtitleViewConfiguration:
                                    _subtitleStyle.configuration,
                              ),
                            ),
                            // 弹幕层（§21 Phase 3 / §13.1 直播弹幕）：绘制在视频上方、
                            // 控制层下方。关闭时（style.enabled=false）不渲染任何内容。
                            //
                            // 运动由 canvas_danmaku 自己的动画时钟推进；播放位置只决定
                            // 「此刻该投放哪几条」。位置上报迟到/重复/倒退因此不再影响画面，
                            // 见 ADR-0013 修订 5。
                            Positioned.fill(
                              child: DanmakuEngineView(
                                items: _danmakuItems,
                                position: _controller.position,
                                style: _danmakuStyle,
                                playing: _controller.isPlaying,
                                rate: _controller.rate,
                                held: _pictureStalled,
                                seek: _danmakuSeek,
                                seeking: _controller.isSeeking,
                                liveItems: _liveItems,
                              ),
                            ),
                            if (_audioAi != null)
                              Positioned(
                                left: 32,
                                right: 32,
                                bottom: 100,
                                child: RealtimeSubtitleOverlay(
                                  controller: _audioAi!.realtime,
                                  clock: _audioAi!.clock,
                                  onSearchText: (text) => Navigator.push(
                                    context,
                                    MaterialPageRoute<void>(
                                      builder: (_) => aiSearchRouteHost(
                                        widget.state,
                                        text,
                                        useExistingResults: false,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            if (_karaokeVisible && _karaokeTrack != null)
                              Positioned(
                                left: 32,
                                right: 32,
                                bottom: 180,
                                child: _karaokeOverlay(),
                              ),
                            if (_audioAi != null)
                              Positioned(
                                top: 16,
                                right: 16,
                                width: 480,
                                child: Offstage(
                                  offstage: !_audioPanelVisible,
                                  child: Material(
                                    elevation: 8,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .surfaceContainer,
                                    child: SizedBox(
                                      height: 580,
                                      child: Column(
                                        children: [
                                          Row(
                                            children: [
                                              const Expanded(
                                                child: Padding(
                                                  padding: EdgeInsets.all(8),
                                                  child: Text('音频AI控制'),
                                                ),
                                              ),
                                              IconButton(
                                                tooltip: '收起音频AI面板',
                                                onPressed: () => setState(
                                                  () => _audioPanelVisible =
                                                      false,
                                                ),
                                                icon: const Icon(Icons.close),
                                              ),
                                            ],
                                          ),
                                          Expanded(
                                            child: PlayerAudioAiPanel(
                                              key: ValueKey(
                                                '${identityHashCode(_audioAi)}-$audioInputGeneration',
                                              ),
                                              state: widget.state,
                                              session: _audioAi!,
                                              mediaUri: Uri.parse(_request.url),
                                              headers: _request.headers,
                                              title: _request.vodName,
                                              language: _audioLanguage,
                                              karaokeMedia: _karaokeMedia,
                                              currentSrt: _currentSrtForAi,
                                              onSettingsChanged:
                                                  _configureAudioAi,
                                              onPickSrt: _pickSrtForAi,
                                              onTranslated: (result) =>
                                                  _applyAiTranslation(
                                                    result,
                                                    inputGeneration:
                                                        audioInputGeneration,
                                                  ),
                                              onTrack: (track, lines) =>
                                                  _applyKaraokeTrack(
                                                    track,
                                                    lines,
                                                    inputGeneration:
                                                        audioInputGeneration,
                                                  ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            if (_controller.isLoading)
                              Positioned.fill(
                                child: PlayerBufferingIndicator(
                                  size: 36,
                                  bytesPerSecond: _controller.bytesPerSecond,
                                ),
                              ),
                            // 跳转重开期间盖一层**不透明**底：mpv 的 `keep-open`
                            // 会把上一帧留在画面控件上，直到新位置首帧解码出来；
                            // 无底色的转圈挡不住它，旧帧会直接透出来（用户看到
                            // 「先闪一下之前的画面再跳到新位置」）。
                            if (_controller.isRepositioning)
                              Positioned.fill(
                                child: ColoredBox(
                                  color: Colors.black,
                                  child: PlayerBufferingIndicator(
                                    size: 36,
                                    bytesPerSecond: _controller.bytesPerSecond,
                                  ),
                                ),
                              ),
                            // 缓冲中提示：与加载态同一层（画面之上、屏显与控制
                            // 浮层之下），且判据互斥——加载阶段已经有上面那个
                            // 全屏圈，再叠一个就是两个圈（判据见
                            // [showBufferingIndicator]）。
                            //
                            // 放这一层而不是控制浮层里：浮层隐藏时（opacity 0 +
                            // IgnorePointer）缓冲提示仍必须可见——卡顿时用户
                            // 恰恰看不到控制栏。
                            if (showBufferingIndicator(
                              isBuffering: _controller.isBuffering,
                              // seek 期间 mpv 不上报 buffering，只有 seeking=yes
                              // （判据见 [showBufferingIndicator]）。
                              isSeeking: _controller.isSeeking,
                              isLoading: _controller.isLoading,
                            ))
                              Positioned.fill(
                                child: PlayerBufferingIndicator(
                                  percent: _controller.bufferingPercent,
                                  bytesPerSecond: _controller.bytesPerSecond,
                                ),
                              ),
                            // §3.2 恢复出口：跳转没落地时不能只留一个黑画面。
                            if (_seekRecoveryFailure != null)
                              Positioned(
                                left: AppSpace.xl,
                                right: AppSpace.xl,
                                // 底栏内容高 92：留出 36 的空隙，横幅压在控制栏上方
                                // 而不是踩在动作行上。
                                bottom: 128,
                                child: Center(
                                  child: PlayerSeekRecoveryBanner(
                                    onRetry: _retrySeekTarget,
                                    onReturn: _returnToSeekOrigin,
                                  ),
                                ),
                              ),
                            if (_loadError != null)
                              Positioned.fill(
                                child: Center(
                                  child: _PlayerErrorOverlay(
                                    message: _loadError!,
                                    url: _request.url,
                                    onRetry: _retryPlayback,
                                    onResume: _resumeFromLatestProgress,
                                    onNext: _playNext,
                                    canGoNext:
                                        !_isCatchup &&
                                        (_isLive ||
                                            (_hasQueue
                                                ? _queueCanGoNext
                                                : (_episodesCache.isNotEmpty
                                                          ? _episodesCache
                                                                .length
                                                          : _episodes.length) >
                                                      _request.episodeIndex +
                                                          1)),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // 第 2 层：屏显（`design/02`）。自身已 IgnorePointer。
                  Positioned.fill(
                    child: PlayerOsdLayer(
                      flags: widget.state.osdFlags,
                      style: _osdStyle,
                      controlsVisible: _controlsVisible,
                      title: _isLive || _isCatchup
                          ? _request.title
                          : '${_request.vodName} · ${_request.episodeName}',
                      resolution: _mediaResolution() == '未知'
                          ? null
                          : _mediaResolution(),
                      position: _controller.position,
                      duration: _controller.duration,
                      // 本地文件故意不复用 directUrl（它在播放页等价于「直播」）：
                      // 这里保持 false，进度条与时长读法才不会被当成直播。
                      isLive: _isLive || (_request.directUrl && !_isCatchup),
                      now: _osdNow,
                      bytesPerSecond: _controller.bytesPerSecond,
                      diagnostics: _osdDiagnosticsRows(),
                      environment: _osdEnvironmentRows(),
                    ),
                  ),
                  // 第 3 层：控制浮层（`design/01`）。
                  //
                  // 用 AnimatedOpacity 而不是 `if (_controlsVisible)`：
                  // 条件插入会改变子树结构，且 Positioned.fill 的命中测试范围
                  // 会随之跳变。隐藏时必须 IgnorePointer，否则透明按钮仍可点。
                  Positioned.fill(
                    child: IgnorePointer(
                      ignoring: !_controlsVisible,
                      child: AnimatedOpacity(
                        opacity: _controlsVisible ? 1 : 0,
                        duration: AppMotion.fast,
                        curve: AppMotion.ease,
                        child: PlayerControlOverlay(
                          topBar: _buildPlayerAppBar(),
                          progressRow: _buildProgressRow(),
                          actionButtons: _buildActionButtons(),
                          actionGroups: _actionGroups(),
                          extraRow: _buildParseSourceStrip(),
                        ),
                      ),
                    ),
                  ),
                  if (widget.liveSession != null)
                    Positioned(
                      right: AppSpace.lg,
                      top: kToolbarHeight + AppSpace.sm,
                      child: OutlinedButton.icon(
                        key: const ValueKey('player-live-panel-toggle'),
                        onPressed: _openLivePanel,
                        icon: const Icon(Icons.live_tv, size: 18),
                        label: const Text('直播源 / 频道'),
                        style: OutlinedButton.styleFrom(
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .surfaceContainerLow,
                        ),
                      ),
                    ),
                  if (_hasLivePanels && widget.liveSession != null) ...[
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _closeLivePanels,
                      ),
                    ),
                    // 贴右：面板贴住窗口右缘，左侧始终留出画面可见区域。
                    // 半透明底由 PlayerLivePanel 自己给（不看这里的宽度）。
                    Positioned(
                      top: 0,
                      bottom: 0,
                      right: 0,
                      width: (MediaQuery.sizeOf(context).width * .56).clamp(
                        560.0,
                        MediaQuery.sizeOf(context).width < 720
                            ? MediaQuery.sizeOf(context).width
                            : 720.0,
                      ),
                      child: PlayerLivePanel(
                        session: widget.liveSession!,
                        lineChannel: _linePanelChannel,
                        onDismiss: _closeLivePanels,
                        onLines: _openLiveLines,
                      ),
                    ),
                  ],
                  // 第 4 层：右键菜单（`design/04` §3）。
                  if (_contextMenuAnchor != null) ...[
                    // 全屏透明遮罩：点击菜单外关闭。
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _closeContextMenu,
                      ),
                    ),
                    PlayerContextMenu(
                      anchor: _contextMenuAnchor!,
                      viewport: MediaQuery.sizeOf(context),
                      sections: _contextMenuSections(),
                      onDismiss: _closeContextMenu,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

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

  String _formatBitrate(num? bitsPerSecond) {
    if (bitsPerSecond == null || bitsPerSecond <= 0) return '未知';
    final bits = bitsPerSecond.toDouble();
    if (bits >= 1000000) return '${(bits / 1000000).toStringAsFixed(1)} Mbps';
    if (bits >= 1000) return '${(bits / 1000).toStringAsFixed(0)} Kbps';
    return '${bits.toStringAsFixed(0)} bps';
  }

  String _mediaResolution() {
    final width = _controller.videoWidth;
    final height = _controller.videoHeight;
    if (width == null || height == null || width <= 0 || height <= 0) {
      return '未知';
    }
    return '$width×$height';
  }

  /// 播放器顶栏。
  ///
  /// **必须保持 `AppBar` widget 类型**：`ui_redesign_visual_flow_test.dart:677-681`
  /// 用 `find.descendant(of: find.byType(AppBar), matching: find.byTooltip('更多'))`
  /// 断言「更多」按钮的位置。换成自绘 `Row` 会让那条断言找不到东西。
  ///
  /// 全屏时**不再置 null**：顶栏仍在浮层里，只是随浮层一起隐藏——
  /// 这样进出全屏不再有 56px 跳变（`design/01` §4.2）。
  Future<void> _openAudioAi() async {
    // 本地路径没有网络语义：面板要拿 mediaUri 去拉音频流（调用点的
    // Uri.parse(_request.url)），本地只可能失败，所以干脆不给入口。
    if (_request.isLocal) {
      _showPlayerMessage('本地文件播放不支持实时字幕 / 卡拉OK');
      return;
    }
    if (_audioAi == null) {
      final settings = widget.state.audioAiSettings;
      _audioLanguage = settings['audioLanguage'] as String? ?? 'en';
      await _configureAudioAi(
        settings['audioModelId'] as String?,
        _audioLanguage,
      );
    }
    if (mounted) setState(() => _audioPanelVisible = !_audioPanelVisible);
  }

  Future<void> _configureAudioAi(String? modelId, String language) async {
    final old = _audioAi;
    await _audioStateSubscription?.cancel();
    if (old != null) {
      await old.dispose();
      await _restoreAiSubtitle();
    }
    if (!mounted) return;
    _audioLanguage = language.isEmpty ? 'en' : language;
    final session = PlayerAudioAiSession(
      paths: widget.state.paths,
      config: widget.state.aiConfig,
      language: _audioLanguage,
      modelId: modelId,
    );
    _audioAi = session;
    await session.karaoke.bindMedia(_karaokeMedia);
    session.update(
      position: _controller.position,
      playing: _controller.isPlaying && !_controller.isBuffering,
      rate: _controller.rate,
    );
    _audioStateSubscription = session.realtime.states.listen((state) {
      final generation = _mediaGeneration;
      _aiSubtitleQueue = _aiSubtitleQueue.then((_) async {
        if (!mounted ||
            generation != _mediaGeneration ||
            !identical(session, _audioAi)) {
          return;
        }
        if (state == RealtimeSubtitleState.listening) {
          _originalAiSubtitle ??=
              _controller.selectedSubtitle ?? SubtitleOption.off;
          await _controller.selectSubtitle(SubtitleOption.off);
          if (mounted &&
              generation == _mediaGeneration &&
              session.realtime.state != RealtimeSubtitleState.listening) {
            await _restoreAiSubtitle();
          }
        } else if (state == RealtimeSubtitleState.off ||
            state == RealtimeSubtitleState.error) {
          await _restoreAiSubtitle();
        }
        if (mounted) setState(() {});
      });
    });
    await widget.state.saveAudioAiSettings({
      'audioModelId': session.model.id,
      'audioLanguage': _audioLanguage,
    });
    if (mounted) setState(() {});
  }

  Future<void> _restoreAiSubtitle() async {
    final original = _originalAiSubtitle;
    _originalAiSubtitle = null;
    if (!mounted ||
        original == null ||
        _controller.selectedSubtitle != SubtitleOption.off) {
      return;
    }
    await _controller.selectSubtitle(
      original,
      headers: _request.subtitleHeaders,
    );
  }

  SrtDocument? get _currentSrtForAi {
    final doc = _controller.selectedSubtitleDocument;
    if (doc == null ||
        doc.format != 'srt' ||
        _controller.selectedSubtitle?.isExternal != true) {
      return null;
    }
    try {
      return SrtDocument.parse(doc.text);
    } catch (_) {
      return null;
    }
  }

  Future<SrtDocument?> _pickSrtForAi() async {
    final generation = _mediaGeneration;
    final choice = await showDialog<Object>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('选择原SRT（仅读取，不切换字幕轨）'),
        children: [
          for (final option in _controller.externalOptions)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, option),
              child: Text(option.label),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'search'),
            child: const Text('搜索字幕候选…'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted || generation != _mediaGeneration) {
      return null;
    }
    SubtitleInfo? sub;
    if (choice is SubtitleOption) {
      sub = SubtitleInfo(
        url: choice.url ?? '',
        name: choice.label,
        lang: choice.language,
        format: choice.format,
      );
    } else if (choice == 'search') {
      final query = _subtitleQuery();
      final candidates = await _subtitleService(
        timeout: const Duration(seconds: 15),
      ).search(query: query, settings: widget.state.subtitleSettings);
      if (!mounted || generation != _mediaGeneration) return null;
      final candidate = await showDialog<SubtitleCandidate>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('选择用于翻译的搜索候选'),
          children: [
            for (final item in candidates)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, item),
                child: Text(item.title),
              ),
            if (candidates.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('没有真实字幕候选'),
              ),
          ],
        ),
      );
      if (candidate == null) return null;
      var url = candidate.url;
      var format = candidate.format;
      if (candidate.requiresResolve) {
        final asset =
            await _subtitleService(timeout: const Duration(seconds: 15))
                .resolve(
                  candidate,
                  query: query,
                  settings: widget.state.subtitleSettings,
                );
        if (!mounted || generation != _mediaGeneration) return null;
        if (asset == null) return null;
        url = asset.path;
        format = asset.format;
      }
      sub = SubtitleInfo(
        url: url,
        name: candidate.title,
        lang: candidate.language,
        format: format,
      );
    }
    if (sub == null) return null;
    final loader = SubtitleService();
    try {
      final doc = await loader.load(sub, headers: _request.subtitleHeaders);
      if (!mounted || generation != _mediaGeneration) return null;
      if (doc.format != 'srt') {
        throw const FormatException('当前仅接受真实SRT，不能假装已转换其他字幕');
      }
      return SrtDocument.parse(doc.text);
    } finally {
      loader.close();
    }
  }

  Future<void> _applyAiTranslation(
    SrtTranslationResult result, {
    required int inputGeneration,
  }) async {
    if (!result.ok || inputGeneration != _mediaGeneration) return;
    final generation = _mediaGeneration;
    final sub = aiTranslatedSubtitle(result, widget.state.paths, generation);
    final file = File(Uri.parse(sub.url).toFilePath());
    await file.parent.create(recursive: true);
    await file.writeAsString(result.translatedSrt, flush: true);
    if (!mounted || generation != _mediaGeneration) return;
    _request = _request.copyWith(
      tmdb: _request.tmdb,
      subtitles: [..._request.subtitles, sub],
    );
    _controller.setExternalSubtitles(_request.subtitles);
    final option = _controller.externalOptions.last;
    await _controller.selectSubtitle(option);
    if (mounted) setState(() {});
  }

  KaraokeMedia get _karaokeMedia => KaraokeMedia(
    key:
        '${widget.state.activeSourceKey}|${_request.siteKey}|${_request.vodId}|${_request.flag}|${_request.episodeName}',
    url: _request.url,
    headers: _request.headers,
    title: _request.vodName,
    artist: '',
    durationMs: _controller.duration.inMilliseconds,
  );

  Future<void> _applyKaraokeTrack(
    KaraokePitchTrack track,
    List<TimedLyricLine> lines, {
    required int inputGeneration,
  }) async {
    final audio = _audioAi;
    if (inputGeneration != _mediaGeneration || audio == null) return;
    final imported = await audio.karaokeRepository.importGenerated(
      _karaokeMedia,
      track,
    );
    if (!mounted ||
        inputGeneration != _mediaGeneration ||
        !identical(audio, _audioAi)) {
      return;
    }
    if (!imported.success || imported.track == null) {
      _showPlayerMessage('评分轨导入失败：${imported.error}', kind: ToastKind.error);
      return;
    }
    audio.karaoke.selectTrack(imported.track);
    audio.karaoke.updateLyrics(lines);
    setState(() {
      _karaokeTrack = track;
      _karaokeLines = lines;
      _karaokeVisible = true;
    });
  }

  Widget _karaokeOverlay() {
    final position = _controller.position.inMilliseconds;
    final lines = _karaokeLines.where(
      (line) => line.startMs <= position && line.endMs >= position,
    );
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer
          .withValues(alpha: .9),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final line in lines)
              Text(line.text, style: Theme.of(context).textTheme.titleLarge),
            Text('参考音高轨 ${_karaokeTrack!.noteCount}个音符'),
            if (_audioAi != null)
              StreamBuilder<KaraokeState>(
                stream: _audioAi!.karaoke.changes,
                initialData: _audioAi!.karaoke.state,
                builder: (context, snapshot) => Text(
                  '${snapshot.data!.snapshot.scorePercent}分 · ${snapshot.data!.snapshot.grade} · ${snapshot.data!.status.name}',
                ),
              ),
            TextButton(
              onPressed: () => setState(() => _karaokeVisible = false),
              child: const Text('关闭歌词音高轨'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAiBusinessMenu() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('当前播放AI业务'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: const Text('当前影片推荐'),
            leading: const Icon(Icons.movie_outlined),
            onTap: () {
              Navigator.pop(context);
              openAiBusiness(
                this.context,
                widget.state,
                source: RecommendationSource.current,
                title: _request.vodName,
              );
            },
          ),
          ListTile(
            title: const Text('分析 / 复验广告候选'),
            leading: const Icon(Icons.filter_alt_outlined),
            onTap: () {
              Navigator.pop(context);
              openAiAdReview(
                this.context,
                widget.state,
                siteKey: _request.siteKey,
                title: _request.vodName,
                flag: _request.flag,
                episode: _request.episodeName,
              );
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  PreferredSizeWidget _buildPlayerAppBar() {
    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      title: Text(
        _isLive || _isCatchup
            ? _request.title
            : '${_request.vodName} · ${_request.episodeName}',
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        // 播放中真正会**反复碰**的两个留在外面：字幕轨、弹幕开关。
        // 「全屏」不在这里——它归底部控制条（一个动作只有一个家）。
        IconButton(
          tooltip: '字幕轨',
          icon: const Icon(Icons.subtitles_outlined),
          onPressed: _showSubtitleMenu,
        ),
        IconButton(
          tooltip: _danmakuStyle.enabled ? '弹幕（开启）' : '弹幕（关闭）',
          icon: Icon(
            _danmakuStyle.enabled ? Icons.comment : Icons.comment_bank_outlined,
          ),
          onPressed: _toggleDanmaku,
        ),
        // 其余是**设一次**或**出问题时才用**的，收进溢出菜单。
        //
        // 原来这 8 个图标同尺寸、同字重、平铺成一行，扫视时找不到落点
        // （用户反馈 2026-10-11：「图标也处理吧」）。分组依据是**使用
        // 时机**，不是功能相似度：播放中要碰的留在外面，配置与诊断收进去。
        //
        // 注意：字幕轨与弹幕的 tooltip 被集成测试按**精确串**查找并直接
        // `tap`（`subtitle_flow_test.dart`、`danmaku_flow_test.dart`），
        // 所以它们**不能**被收进菜单——收进去测试就点不到了。
        //
        // ## 「更多」为什么只剩 5 项
        //
        // 右键菜单收编全量设置后，两处大面积重复会让「一个动作只有一个家」
        // 失效。但「更多」不能删：右键是鼠标专属，键盘/触控板用户需要
        // 一条不走右键的路径（`design/04` §4.3）。
        //
        // 留下的 5 项判据是**「右键之外还有没有别的入口」**，而不是使用频率：
        // 它们在整棵 UI 树里**只有**右键菜单和这里两处入口，删掉「更多」
        // 就变成「只有鼠标能到达」——
        // - 字幕样式 / 弹幕设置：纯样式偏好，顶栏只有字幕轨与弹幕**开关**；
        // - 画面比例与缩放：底部控制条只放「全屏」，比例归菜单；
        // - 媒体信息：没有任何页面复制这份数据；
        // - 快捷键说明：它本身就是「键盘用户的说明书」，只能从 UI 进。
        //
        // 去掉的 5 项在别处**另有**入口，不算失去路径：
        // - 音轨 / 视频轨 → 右键「声音」「轨道」组；单轨时底部控制条也没有
        //   可切内容，留一个点了只弹说明的入口没有意义；
        // - 循环与定时 → 右键「播放 → 循环与定时…」；
        // - LUT 滤镜 → 右键「画面 → LUT 滤镜…」；
        // - 播放诊断 → 设置 › 日志页顶部的「最近播放诊断」卡片
        //   （`diagnostics_pages.dart:676` 的 `_PlaybackDiagnosticsCard`）。
        IconButton(
          key: const ValueKey('player-audio-ai'),
          tooltip: '实时字幕 / 翻译 / 卡拉OK',
          onPressed: _openAudioAi,
          icon: const Icon(Icons.record_voice_over_outlined),
        ),
        IconButton(
          key: const ValueKey('player-ai-business'),
          tooltip: 'AI推荐 / 广告规则',
          icon: const Icon(Icons.auto_awesome_outlined),
          onPressed: () => _showAiBusinessMenu(),
        ),
        PopupMenuButton<_PlayerMenuAction>(
          tooltip: '更多',
          icon: const Icon(Icons.more_vert),
          onSelected: (action) {
            switch (action) {
              case _PlayerMenuAction.subtitleStyle:
                _showSubtitleStyleSettings();
              case _PlayerMenuAction.danmakuSettings:
                // 与右键「弹幕 → 弹幕设置…」同一入口：先弹层，整页在弹层底部。
                unawaited(_openDanmakuQuickSettings());
              case _PlayerMenuAction.videoFit:
                _showVideoFitSettings();
              case _PlayerMenuAction.mediaInfo:
                _showMediaInfo();
              case _PlayerMenuAction.shortcuts:
                _showShortcutHelp();
            }
          },
          itemBuilder: (context) => [
            _menuItem(
              _PlayerMenuAction.subtitleStyle,
              Icons.format_color_text_outlined,
              '字幕样式',
            ),
            _menuItem(
              _PlayerMenuAction.danmakuSettings,
              Icons.comment_outlined,
              '弹幕设置',
            ),
            _menuItem(
              _PlayerMenuAction.videoFit,
              Icons.aspect_ratio_outlined,
              '画面比例与缩放',
            ),
            _menuItem(_PlayerMenuAction.mediaInfo, Icons.info_outline, '媒体信息'),
            _menuItem(_PlayerMenuAction.shortcuts, Icons.keyboard, '快捷键说明'),
          ],
        ),
      ],
    );
  }

  /// 进度行：等宽时间 + 滑杆（`design/01` §4）。
  ///
  /// 滑杆用 [PlayerProgressSlider] 而不是裸 `Slider`：缓冲区间要画在同一根
  /// 轨道上。行高仍由滑杆决定，没有新增一层——进度行的 32 是浮层几何断言
  /// 的一部分（`phase8_overlay_layout_test.dart`）。
  Widget _buildProgressRow() {
    final duration = _controller.duration;
    return Row(
      children: [
        // 时间必须用**等宽字形**：比例字形下秒数每跳一次，整行时间
        // 就会左右抖动，读进度时很难受。
        Text(
          // 拖动期间显示拖动目标：这一次拖动还没落引擎，读数只能来自
          // `_dragSeekTarget`，否则时间会停在按下那一刻不动。
          _formatDuration(_dragSeekTarget ?? _controller.position),
          style: tabular(Theme.of(context).textTheme.bodyMedium!),
        ),
        Expanded(
          child: PlayerProgressSlider(
            // 拖动中与「已提交但引擎还没追上」期间都显示目标位置，否则拇指
            // 会先弹回旧位置再跳过去（慢 seek 上尤其明显）。
            position: _dragSeekTarget ?? _controller.position,
            duration: duration,
            buffered: _controller.buffered,
            skipSegments: _skipPlan.segments,
            skipSegmentColors: _options.skipSegmentColors,
            showSkipSegmentHighlights: _options.showSkipSegmentHighlights,
            // 拖动期间**只记录、不 seek**（见 [_dragSeekTarget]）。
            onSeek: (target) {
              // 直播不 seek：页面其它 seek 入口（快捷键、右键菜单、
              // `seekBy`）对直播一律禁用，这里不能开一个例外。
              if (_isLive) return;
              setState(() => _dragSeekTarget = target);
            },
            thumbnailPreviewEnabled:
                _navigationAvailable && _options.showThumbnailPreview,
            thumbnailProvider:
                _navigationAvailable && _options.showThumbnailPreview
                ? _controller.thumbnailAt
                : null,
            previewSourceKey: _controller.thumbnailGeneration,
            // 只有用户拖动才暂停：程序化 seek（自动跳片头片尾、seekBy、
            // 关键帧跳转、续播）走 `_controller.seek`，根本不经过这两个回调。
            //
            // 两个回调**恒定挂载**，判据搬进回调内部、在调用当时求值：
            // 关掉开关/切到直播都不是 rebuild 时固化成一个 null 回调，否则
            // 拖动中途被关掉时 end 永远走不到，gate 会把"拖动前在播"永久
            // 留下来，下一次拖动就会不暂停却强行 play()。
            //
            // 直播再挡一层：滑杆用引擎上报的 `duration <= 0` 判断直播，但有些
            // 流会报出非零时长，于是滑杆可拖、回调照发——那会把直播流 pause
            // 掉。滑杆负责值域，页面负责语义，两者互为兜底。
            onSeekStart: () {
              if (!_options.dragPause || _isLive) {
                // 关掉/直播时也要清一次：上一次拖动的残留不能带进下一次。
                _dragPauseGate.reset();
                return;
              }
              if (_dragPauseGate.begin(playing: _controller.isPlaying)) {
                _applyDragPausePlayback(_controller.pause());
              }
            },
            onSeekEnd: () {
              final target = _dragSeekTarget;
              final resume = _dragPauseGate.end();
              // 目标先留着：慢 seek 期间拇指/读数必须停在目标上，等引擎追上
              // 再交还（见 [_settleDragSeekTarget]）。
              if (target != null) {
                setState(() => _dragSeekCommittedAt = DateTime.now());
              }
              // 拖动中途被关掉/切到直播时，这一次拖动按"用户已经不想要
              // 暂停"处理：先清状态，再决定不续播。
              final shouldResume = resume && _options.dragPause && !_isLive;
              // 关掉开关也必须 seek（只有这一次）：暂停与否是另一回事，
              // 用户要跳到的位置照样得跳。
              if (target == null || _isLive) {
                // 没有可提交的目标（或直播不 seek）：显示立刻交还引擎，
                // 不能让它钉在目标上等 15 秒。
                if (target != null) {
                  setState(() {
                    _dragSeekTarget = null;
                    _dragSeekCommittedAt = null;
                  });
                }
                if (shouldResume) _applyDragPausePlayback(_controller.play());
                return;
              }
              unawaited(_commitDragSeek(target, resume: shouldResume));
            },
          ),
        ),
        Text(
          _formatDuration(duration),
          style: tabular(Theme.of(context).textTheme.bodyMedium!),
        ),
        // 直播弹幕连接状态。
        //
        // **它必须留在这里**：改造前它是 `_ControlBar` 末尾的一段，
        // 而 `_ControlBar` 是它**唯一**的渲染点——删掉控制条就静默丢了
        // 「连接中 / 已连接 / 重连中 / 已断开」与在线人数，
        // 用户将无法得知直播弹幕为什么没有弹幕。
        //
        // 放在进度行而不是动作行：动作行是**可配置按钮**的集合
        // （`resolveVisibleButtons` 的 10 个 id，`PlayerOverlayActionRow`
        // 还断言 buttons 与 groups 一一对应），状态指示器不是按钮，
        // 混进去会破坏那个一一对应。
        //
        // 可见性语义与改造前一致：它随控制浮层一起出现/消失。
        if (_liveStatus != null || _liveOnline != null) ...[
          const SizedBox(width: AppSpace.sm),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.podcasts, size: 16),
              const SizedBox(width: AppSpace.xs),
              Text(
                formatPlayerLiveStatus(
                  status: _liveStatus,
                  online: _liveOnline,
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// 动作行按钮：按用户配置的顺序与可见性渲染（`design/03` §5.1）。
  ///
  /// 每个 id 对应的 widget 类型与 tooltip 精确串是**既有的、被测试锁定的**，
  /// 不得改动（`design/03` §5.2）。
  List<Widget> _buildActionButtons() {
    final episodes = _episodes;
    return [
      for (final spec in _visibleButtonSpecs())
        switch (spec.id) {
          'prev' => IconButton(
            tooltip: _isLive ? '上一台（PgUp）' : '上一集（[）',
            onPressed: _isCatchup ? null : _playPrevious,
            icon: const Icon(Icons.skip_previous),
          ),
          'play' => IconButton(
            tooltip: _controller.isPlaying ? '暂停（空格）' : '播放（空格）',
            onPressed: _controller.playOrPause,
            icon: Icon(_controller.isPlaying ? Icons.pause : Icons.play_arrow),
          ),
          'next' => IconButton(
            tooltip: _isLive ? '下一台（PgDn）' : '下一集（]）',
            onPressed: _isCatchup ? null : _playNext,
            icon: const Icon(Icons.skip_next),
          ),
          'mute' => IconButton(
            tooltip: _controller.muted || _controller.volume == 0
                ? '取消静音（M）'
                : '静音（M）',
            onPressed: _controller.toggleMute,
            icon: Icon(
              _controller.muted || _controller.volume == 0
                  ? Icons.volume_off
                  : Icons.volume_up,
            ),
          ),
          'volume' => SizedBox(
            width: 120,
            child: Slider(
              value: _controller.volume.clamp(0, 100),
              max: 100,
              onChanged: _controller.setVolume,
            ),
          ),
          'speed' => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('倍速'),
              DropdownButton<double>(
                // 去掉框架默认下划线：那是 Material 2 的遗留装饰，
                // 在已经设计过的深色纱上像一条莫名的横线。
                // craft-floor 点名的正是这一类"你没画的那些部分也在承载设计"。
                underline: const SizedBox.shrink(),
                // value 必须落在 items 里，否则 DropdownButton 直接断言。
                // 长按快进会把速率临时抬到 3×（默认，可配置），那一档不在常规
                // 档位表里：把当前真实速率并进候选，控制栏才不会把 3× 谎报成 2.0x。
                value: _controller.rate,
                items: _speedChoices(_controller.rate)
                    .map(
                      (rate) => DropdownMenuItem(
                        value: rate,
                        child: Text('${rate.toString()}x'),
                      ),
                    )
                    .toList(),
                onChanged: (rate) {
                  if (rate != null) _controller.setRate(rate);
                },
              ),
            ],
          ),
          'episodes' when _isCatchup && widget.liveSession != null =>
            OutlinedButton.icon(
              onPressed: widget.liveSession!.returnToLive,
              icon: const Icon(Icons.live_tv, size: 18),
              label: const Text('回到直播'),
            ),
          // 画质入口：只在**当前集返回多个候选**时出现（单地址/直播没有可选内容）。
          // 当前值写在按钮上，用户不打开面板也能读到正在播哪一档。
          'quality'
              when !_request.isLocal &&
                  !_request.directUrl &&
                  !_isLive &&
                  _request.qualities.length > 1 =>
            OutlinedButton.icon(
              key: const ValueKey('player-quality-button'),
              onPressed: () => unawaited(_openQualityPanel()),
              icon: const Icon(Icons.high_quality_outlined, size: 18),
              label: Text('画质：${_qualityName(_request.qualityIndex)}'),
            ),
          'episodes' when _isLive => OutlinedButton.icon(
            onPressed: () => _openLiveLines(widget.liveSession!.channel),
            icon: const Icon(Icons.alt_route, size: 18),
            label: Text('线路（${widget.liveSession!.lines.length}）'),
          ),
          'episodes' when !_request.isLocal && _hasQueue => OutlinedButton.icon(
            onPressed: () => _showEpisodes(context),
            icon: const Icon(Icons.list, size: 18),
            label: Text('选集（${widget.queue!.snapshot.items.length}）'),
          ),
          'episodes'
              when !_request.isLocal && !_isCatchup && episodes.isNotEmpty =>
            OutlinedButton.icon(
              onPressed: () => _showEpisodes(context),
              icon: const Icon(Icons.list, size: 18),
              label: Text('选集（${episodes.length}）'),
            ),
          'fullscreen' => IconButton(
            tooltip: '全屏（F11）',
            onPressed: _toggleFullscreen,
            icon: const Icon(Icons.fullscreen),
          ),
          // 未配置外部播放器时落到下面的兜底占位：按钮默认不出现，配置过才有。
          'external_player' when widget.state.hasExternalPlayer => IconButton(
            tooltip: _externalPlayerRunning == null ? '用外部播放器打开' : '外部播放器播放中',
            onPressed: () => unawaited(_openInExternalPlayer()),
            icon: Icon(
              _externalPlayerRunning == null
                  ? Icons.open_in_new
                  : Icons.play_circle_fill,
            ),
          ),
          // 条件不成立的项（如没有剧集时的 `episodes`）不渲染。
          // 占位仍在：`_actionGroups` 是按 `resolveVisibleButtons` 的长度配平的。
          _ => const SizedBox.shrink(),
        },
    ];
  }

  /// 与 [_buildActionButtons] 一一对应的分组（用于插分隔线）。
  List<PlayerButtonGroup> _actionGroups() => [
    for (final spec in _visibleButtonSpecs()) spec.group,
  ];

  /// 控制栏可见按钮的**唯一来源**：按钮与其分组必须一一对应
  /// （`PlayerOverlayActionRow` 有断言），所以两处都从这里取。
  ///
  /// 本地文件没有上一集/下一集（右键菜单同口径），摘掉不给死按钮；
  /// 若将来支持「本地文件 + 目录连播队列」，改成 `!_request.isLocal || _hasQueue`。
  List<PlayerButtonSpec> _visibleButtonSpecs() {
    final specs = resolveVisibleButtons(
      order: widget.state.playerButtonOrder,
      hidden: widget.state.playerButtonHidden,
    );
    if (!_request.isLocal) return specs;
    return specs
        .where((spec) => spec.id != 'prev' && spec.id != 'next')
        .toList(growable: false);
  }

  /// 控制栏倍速下拉的候选：常规档位 + 当前真实速率（去重升序）。
  ///
  /// 常规档位只到 2×；长按快进（默认 3×）或右键菜单改快速率之后，控制栏必须
  /// 显示真实值，而不是「最接近的常规档」。
  static List<double> _speedChoices(double current) =>
      <double>{0.5, 0.75, 1.0, 1.25, 1.5, 2.0, current}.toList()..sort();

  /// 倍速文案：整数不带小数点（3× 而不是 3.0×）。
  static String _speedText(double speed) =>
      speed == speed.roundToDouble() ? '${speed.toInt()}×' : '$speed×';

  String _qualityName(int index) {
    if (index < 0 || index >= _request.qualities.length) return '默认';
    final name = _request.qualities[index].name.trim();
    return name.isEmpty ? '画质 ${index + 1}' : name;
  }

  /// 打开画质面板；选中当前项等于取消（不得重载媒体）。
  Future<void> _openQualityPanel() async {
    if (_request.isLocal ||
        _request.directUrl ||
        _isLive ||
        _request.qualities.length <= 1) {
      return;
    }
    final selected = await showPlayerQualityPanel(
      context,
      qualities: _request.qualities,
      selectedIndex: _request.qualityIndex,
    );
    if (!mounted || selected == null) return;
    await _selectQuality(selected);
  }

  /// 切画质：用当前集的入口目标重新解析同一候选，保留进度与播放状态。
  ///
  /// 不直接把候选原 URL 交给 media_kit：那会绕过 Header 注入、解析器与本地代理。
  /// 换集/关闭页面后旧请求返回的决策一律丢弃（[_qualitySelectionRevision] +
  /// [_mediaGeneration] + 请求身份三重判定），避免旧结果盖住新集状态。
  Future<void> _selectQuality(int index) async {
    if (_request.isLocal ||
        _request.directUrl ||
        _isLive ||
        _request.qualities.length <= 1) {
      return;
    }
    if (index < 0 || index >= _request.qualities.length) return;
    if (index == _request.qualityIndex) return;
    final selection = ++_qualitySelectionRevision;
    final intent = _request;
    final generation = _mediaGeneration;
    int? restoreGeneration;
    PlaybackRequest? restoreRequest;
    bool isCurrent() =>
        mounted &&
        selection == _qualitySelectionRevision &&
        generation == _mediaGeneration &&
        identical(intent, _request);
    try {
      final route = intent.lineRoutes[intent.flag];
      final decision = await _resolvePlayback(
        episodeTarget: intent.episodeTarget,
        flag: intent.playbackFlag,
        vodId: route?.vodId ?? intent.vodId,
        route: route,
        qualityIndex: index,
        isCurrent: isCurrent,
      );
      if (!isCurrent()) return;
      if (decision == null || decision.url == null) {
        throw AppError(AppErrorKind.playbackUrlMissing, '该画质没有可用播放地址');
      }
      final position = _controller.position;
      final playing = _controller.isPlaying;
      // 同上：新画质结果没有可切换解析源时，手动指定不再成立。
      if (decision.parseSources.isEmpty) _parseSourceOverride = null;
      _beginMediaTransition();
      setState(() {
        _request = intent.copyWith(
          tmdb: intent.tmdb,
          url: decision.url!,
          headers: decision.headers?.asRequestHeaders ?? const {},
          subtitleHeaders: decision.assetHeaders?.asRequestHeaders ?? const {},
          qualities: decision.qualities,
          qualityIndex: decision.qualityIndex,
          parseSources: decision.parseSources,
          parseSource: decision.parseSource,
          subtitles: decision.subs,
          danmaku: decision.danmaku,
          startPosition: position,
          clearResumeSeed: true,
        );
        _danmakuItems = const [];
        _danmakuSourceUrl = null;
        _danmakuError = null;
      });
      final restoring = _load(restorePlaying: playing);
      restoreGeneration = _mediaGeneration;
      restoreRequest = _request;
      await restoring;
    } catch (error) {
      // 解析阶段属于旧请求，恢复阶段属于已打开的新画质；两者各用自己的代次。
      final current = restoreGeneration == null
          ? isCurrent()
          : mounted &&
                selection == _qualitySelectionRevision &&
                restoreGeneration == _mediaGeneration &&
                identical(restoreRequest, _request);
      if (!current) return;
      _showPlayerMessage('画质切换失败：$error', kind: ToastKind.error);
      widget.state.log.error('画质切换失败 $error', scope: 'player');
    }
  }

  /// 选集面板（对齐安卓 `EpisodeListDialog`）。
  ///
  /// 与上一版 `showModalBottomSheet` 的区别：面板要容纳「线路行 + 区间行 +
  /// 16:9 剧照网格」，底部抽屉的高度放不下，改为居中弹窗。
  /// 面板本身不碰播放状态：线路 chip 只换预览，点某张集数卡片才回调回这里起播
  /// （线路与集号一起回传——预览的那条可能不是正在播放的那条）。
  void _showEpisodes(BuildContext context) {
    // 本地文件没有选集与线路：整张面板（含线路行）在本地没有可切的目标。
    if (_request.isLocal) return;
    if (_isLive) {
      _openLiveLines(widget.liveSession!.channel);
      return;
    }
    if (_isCatchup) return;
    if (_hasQueue) {
      unawaited(
        showDialog<void>(
          context: context,
          barrierColor: Colors.black.withValues(alpha: 0.62),
          builder: (_) => PlayerQueuePanel(
            title: _request.vodName.isNotEmpty
                ? _request.vodName
                : _request.title,
            queue: widget.queue!,
            currentKey: _queueItemKey,
            onSelect: (key) => unawaited(_openQueueItem(key)),
            playLines: _request.playLines,
            lineFlag: _request.flag,
            onSelectLine: (flag) => unawaited(_switchLineResumingEpisode(flag)),
          ),
        ),
      );
      return;
    }
    unawaited(
      showDialog<void>(
        context: context,
        barrierColor: Colors.black.withValues(alpha: 0.62),
        builder: (_) => PlayerEpisodePanel(
          title: _request.vodName.isNotEmpty
              ? _request.vodName
              : _request.title,
          playLines: _request.playLines,
          lineFlag: _request.flag,
          // **每条线路**的卡片都给它：线路 chip 只换预览，面板要能就地取到预览
          // 线路自己那份卡片（只给当前线路会串图：两条线路集数相等时连错位都
          // 查不出来）。
          episodeCardsByFlag: _request.episodeCardsByFlag,
          // 详情页那一刻是倒序的话，面板的排列方向、区间标签与当前集定位都要跟着倒。
          reversed: _request.episodesReversed,
          episodeIndex: _request.episodeIndex,
          // 剧照缺席时回退本剧海报，与详情页同一条回退（TMDB 海报 → 站源封面）。
          posterUrl: _request.posterUrl ?? _request.vodPic,
          // 预览线路与集号必须一起回来：面板里可能已经切到别的线路，
          // 只回下标会把「预览线路的第 N 集」播成「正在播放线路的第 N 集」。
          //
          // 一律走 `overrideFlag`：面板显示的是 `playLines[flag]` 里的第 index 集，
          // 必须按**同一条线路的同一份列表**取值。无 flag 的那条分支会优先用
          // `_episodesCache`（切线路解析途中缓存的是**另一条**线路的分集），
          // 那个窗口里点卡片会播成别的线路的同一位置。
          onSelectEpisode: (flag, index) =>
              unawaited(_playEpisode(index, overrideFlag: flag)),
        ),
      ),
    );
  }

  /// 控制区的解析源条；本次播放没有可切换的解析源时返回 `null`。
  ///
  /// 判定只读**本次播放的解析结果**（`PlaybackRequest.parseSources`），不看配置
  /// 里有没有解析器：直链播放、本地文件与直播都不产生解析结果，读配置就会凭空
  /// 给出一个点了不生效的入口。少于两项也不给——只有一个解析源时选不选都一样。
  Widget? _buildParseSourceStrip() {
    if (_request.isLocal || _isLive || _isCatchup) return null;
    final sources = _request.parseSources;
    if (sources.length < 2) return null;
    return PlayerParseSourceStrip(
      sources: sources,
      selected: _request.parseSource,
      onSelect: (name) => unawaited(_switchParseSource(name)),
    );
  }

  /// 切解析源：只对本次播放生效，并立即用当前集重新解析。
  ///
  /// 为什么复用 [_playEpisode] 而不是直接改地址：解析源是「怎么拿到地址」的选择，
  /// 换源必须重新走站点播放入口 + 解析器，否则播放器里还是旧源算出来的地址。
  Future<void> _switchParseSource(String name) async {
    if (_request.isLocal) return;
    final normalized = name == superParseEntryName ? null : name;
    if (normalized == _parseSourceOverride) return;
    setState(() => _parseSourceOverride = normalized);
    await _playEpisode(_request.episodeIndex, overrideFlag: _request.flag);
  }

  /// 切线路：尽量续播**同一集**（对齐安卓 `VideoActivity.java:3684-3687`）。
  ///
  /// 只给「已经决定要换线路」的两条路径用：失败自动回退（[_tryPlaybackFallback]）
  /// 与目录连播面板（`PlayerQueuePanel`）。选集面板**不走这里**——那里的线路 chip
  /// 只换预览，起播由用户点的那张卡片决定（`_playEpisode(index, overrideFlag:)`）。
  ///
  /// 定位规则见 [locateEpisodeInLine]：集名精确匹配 → 集号匹配 → 第 1 集。
  ///
  /// 为什么不改 [_playEpisode]：它的 `overrideFlag` 分支已经负责「按新线路
  /// 解析地址 + 写 `_episodesCache`」，续同集只是换一个下标传进去；动那条分支
  /// 等于重写既有的换集路径，而阶段 B 要求这里的改动保守。
  Future<void> _switchLineResumingEpisode(String flag) async {
    if (_request.isLocal || flag == _request.flag) return;
    final target = _lineOf(flag)?.episodes ?? const <VodEpisode>[];
    if (target.isEmpty) return;
    final index = locateEpisodeInLine(
      episodes: target,
      currentName: _request.episodeName,
    );
    await _playEpisode(index, overrideFlag: flag);
  }

  /// 自动回退的换线（§3.1）：只有目标线路里**唯一**定位到同一集才换。
  ///
  /// 落错集的代价是从头看另一集且不易察觉，所以找不到唯一同集就跳过这条线路，
  /// 绝不回第 1 集。换线时把真实播放位置与倍速一起显式带过去。
  Future<bool> _switchLineResumingEpisodeStrict(String flag) async {
    final line = _lineOf(flag);
    if (line == null || line.episodes.isEmpty) return false;
    final match = locateUniqueEpisodeInLine(
      names: [for (final episode in line.episodes) episode.name],
      currentName: _request.episodeName,
    );
    if (!match.matched) {
      widget.state.log.info(
        '自动换线跳过：${match.skippedReason} flag=$flag',
        scope: 'player',
      );
      return false;
    }
    final origin = _controller.enginePositionSeen
        ? _controller.enginePosition
        : _controller.position;
    final rate = _controller.rate;
    final playing = _controller.isPlaying;
    widget.state.log.info(
      '自动换线 续同集 flag=$flag target=${match.index} basis=${match.basis} '
      'position=${origin.inMilliseconds}ms rate=$rate',
      scope: 'player',
    );
    await _playEpisode(
      match.index!,
      overrideFlag: flag,
      startPosition: origin,
      restorePlaying: playing,
      rate: rate,
    );
    return true;
  }

  /// 屏显诊断主列（`design/02` §3.2）。
  List<OsdDiagnosticsRow> _osdDiagnosticsRows() {
    final video = _controller.selectedVideoTrack;
    final audio = _controller.selectedAudioTrack;
    final audioParams = _controller.audioParams;
    return buildOsdDiagnostics(
      videoWidth: _controller.videoWidth,
      videoHeight: _controller.videoHeight,
      videoCodec: video?.codec,
      videoFps: video?.fps,
      videoBitrate: video?.bitrate,
      audioCodec: audio?.codec,
      audioChannels: audioParams.hrChannels ?? audioParams.channels,
      audioSampleRate: audioParams.sampleRate,
      audioBitrate: _controller.audioBitrate ?? audio?.bitrate,
      position: _controller.position,
      duration: _controller.duration,
      buffered: _controller.buffered,
      rate: _controller.rate,
      volume: _controller.volume,
      muted: _controller.muted,
      formatLabel: _diagnostics?.format.label ?? '未知',
      targetHost: _diagnostics?.target.host ?? '',
      siteKey: _request.siteKey,
      flag: _request.flag,
      episodeName: _request.episodeName,
      // 结论行：来自本次播放的诊断快照。
      // `_diagnostics` 为 null（还没起播/还没落定）→ 传 null，结论行不渲染。
      //
      // `succeeded` 在起播前确实是 null（`playback_diagnostics.dart:315`
      // 声明为 `bool? _succeeded`，只在 `succeed()`/`fail()` 里赋值），
      // 所以不会短暂显示「失败」。
      succeeded: _diagnostics?.succeeded,
      // `failureKind` 的运行时类型是 `PlayerFailureKind` **枚举**，
      // 直接插值会渲染成 `失败 · PlayerFailureKind.timeout`。
      // 传 `.name` 得到短而稳定的分类（`timeout`），屏显是窄栏位。
      failureKind: _diagnostics?.failureKind is Enum
          ? (_diagnostics!.failureKind! as Enum).name
          : _diagnostics?.failureKind,
    );
  }

  /// 屏显诊断附加列（`design/02` §3.2）。
  ///
  /// 拿不到的项**不出现**（不是显示「未知」）。
  List<OsdDiagnosticsRow> _osdEnvironmentRows() {
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return buildOsdEnvironment(
      operatingSystemVersion: Platform.operatingSystemVersion,
      windowSize: '${size.width.round()}×${size.height.round()}',
      devicePixelRatio: dpr,
      themeMode: widget.state.themeMode,
      proxyPort: null,
      adBlockSummary: _adBlockOsdSummary(),
    );
  }

  /// 本次会话累计拦截摘要；没拦过返回 null（该行不出现）。
  String? _adBlockOsdSummary() {
    final summary = widget.state.adBlockSummary;
    if (summary == null) return null;
    final seconds = summary.removedDurationSec;
    return '已拦 ${summary.removedSegments} 段'
        '${seconds > 0 ? ' · ${seconds.toStringAsFixed(1)} 秒' : ''}'
        '${summary.heuristic ? ' · 启发式' : ''}';
  }

  /// 屏显是否需要刷新循环。
  ///
  /// 控制栏可见时**必须**运行（为了强制显示的时钟），
  /// 即使屏显开关全关（上游同语义：`PlayerOsdController.java:152-158`）。
  bool get _osdNeedsTicker =>
      _controlsVisible ||
      anyOsdEnabled(widget.state.osdFlags) ||
      _controller.isLoading ||
      _controller.isBuffering;

  void _syncOsdTimer() {
    if (_osdNeedsTicker) {
      if (_osdTimer == null) {
        // 起播/卡顿的第一秒不该先空一拍：提示一出现就采一次。
        _sampleNetworkRate();
      }
      _osdTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _osdNow = debugOsdClockOverride ?? DateTime.now());
        _sampleNetworkRate();
      });
    } else {
      _osdTimer?.cancel();
      _osdTimer = null;
    }
  }

  /// 网速采样，挂在屏显刷新循环上（不另起 Timer，见
  /// `PlayerController.sampleNetworkRate` 的注释）。
  ///
  /// 屏显网速开启或加载/缓冲提示可见时采样，共用同一个读数。
  void _sampleNetworkRate() {
    // 本地文件不走网络：没有代理流量，采样只会让屏显挂一个恒为 0 的读数。
    if (_request.isLocal) return;
    final wanted = shouldSampleNetworkRate(
      trafficEnabled: widget.state.osdFlags[OsdFlag.traffic] ?? false,
      isLoading: _controller.isLoading,
      isBuffering: _controller.isBuffering,
    );
    if (!wanted) return;
    unawaited(
      _controller.sampleNetworkRate(
        proxyTraffic: widget.state.proxyTrafficFor(
          _controller.currentUrl ?? '',
        ),
      ),
    );
  }

  void _touchControls() {
    _controlHideTimer?.cancel();
    if (mounted && !_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _syncOsdTimer();
    // 菜单打开期间不排隐藏计时器（`design/04` §5.4）。
    if (_contextMenuAnchor != null || _hasLivePanels) return;
    _controlHideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (_contextMenuAnchor != null || _hasLivePanels) return;
      setState(() => _controlsVisible = false);
      _syncOsdTimer();
    });
  }

  /// 单击立即翻转播放；同侧双击按配置执行，并显式确定最终播放状态。
  void _onVideoTap(Offset localPosition) {
    final box =
        _videoGestureKey.currentContext!.findRenderObject()! as RenderBox;
    final rightSide = localPosition.dx >= box.size.width / 2;
    final doubleClick = _clickGate.registerTap(rightSide: rightSide);
    _touchControls();
    if (!doubleClick) {
      final before = _gesturePlaybackIntent ?? _controller.isPlaying;
      _playingBeforeFirstTap = before;
      unawaited(_applyPlayerGesturePlayback(!before));
      return;
    }
    var action = rightSide
        ? _options.doubleClickRight
        : _options.doubleClickLeft;
    if ((_isLive || _isCatchup) && action.isSeek) {
      action = PlayerDoubleClickAction.none;
    }
    final originalPlaying = _playingBeforeFirstTap;
    _playingBeforeFirstTap = null;
    if (originalPlaying != null) {
      unawaited(
        _applyPlayerGesturePlayback(
          action == PlayerDoubleClickAction.togglePlayback
              ? !originalPlaying
              : originalPlaying,
        ),
      );
    }
    switch (action) {
      case PlayerDoubleClickAction.toggleFullscreen:
        unawaited(_toggleFullscreen());
      case PlayerDoubleClickAction.seekBackward:
        unawaited(_controller.seekBy(const Duration(seconds: -10)));
      case PlayerDoubleClickAction.seekForward:
        unawaited(_controller.seekBy(const Duration(seconds: 10)));
      case PlayerDoubleClickAction.volumeUp:
        unawaited(_controller.setVolume(_controller.volume + 5));
      case PlayerDoubleClickAction.volumeDown:
        unawaited(_controller.setVolume(_controller.volume - 5));
      case PlayerDoubleClickAction.togglePlayback:
      case PlayerDoubleClickAction.none:
        break;
    }
  }

  void _clearGesturePlaybackIntent() {
    _gesturePlaybackTimer?.cancel();
    _gesturePlaybackTimer = null;
    _gesturePlaybackIntent = null;
  }

  void _bindGesturePlaybackStream() {
    unawaited(_gesturePlayingSubscription?.cancel());
    _gesturePlayingSubscription = _controller
        .videoController
        .player
        .stream
        .playing
        .listen((playing) {
          _clearGesturePlaybackIntent();
          if (_skippedProgress == null && !_sleepStoppedAtCompletion) return;
          if (!playing) {
            _completionPaused = true;
          } else if (_completionPaused) {
            _clearCompletionProgress();
            _skipArmed = true;
          }
        });
  }

  /// 显式应用点击目标；仅在双击窗口内保留未获引擎确认的意图。
  /// 新 playing 事件、换媒体与窗口到期都以引擎真值为准。
  ///
  /// 失败只记日志：流未就绪/已断开时点一下画面不该让整页抛异常
  /// （`play()` 在没有原生实现的环境里会抛 `MissingPluginException`）。
  Future<void> _applyPlayerGesturePlayback(bool playing) async {
    _gesturePlaybackIntent = playing;
    _gesturePlaybackTimer?.cancel();
    _gesturePlaybackTimer = Timer(
      kPlayerDoubleClickWindow,
      _clearGesturePlaybackIntent,
    );
    try {
      if (playing) {
        await _controller.play();
      } else {
        await _controller.pause();
      }
    } catch (error) {
      _clearGesturePlaybackIntent();
      widget.state.log.warning('画面点击切换播放失败：$error', scope: 'player');
    }
  }

  /// 松手时的**唯一一次** seek，之后按拖动前状态决定是否恢复播放。
  ///
  /// 顺序是 seek → play（与 [_replayCurrent] 一致）：先 play 再 seek 会让引擎
  /// 在旧位置先播一帧再跳，观感上是一次"闪回"。
  Future<void> _commitDragSeek(Duration target, {required bool resume}) async {
    final controller = _controller;
    late final int generation;
    try {
      // 走统一跳转通道：缓冲内同连接直接 seek；缓冲外必须重开并在打开时定位
      // （服务端每客户端只允许 1 条活动流，mid-stream seek 会被回 429）。
      final seeking = _seekFromUser(
        target,
        restorePlaying: resume || controller.isPlaying,
      );
      generation = _mediaGeneration;
      await seeking;
    } catch (error) {
      widget.state.log.warning('拖动进度条后跳转失败：$error', scope: 'player');
      return;
    }
    // seek 在飞的时候可能已经换媒：那份 gate 状态属于上一部片，不许续播。
    if (!mounted ||
        generation != _mediaGeneration ||
        !identical(controller, _controller)) {
      return;
    }
    if (resume) {
      _applyDragPausePlayback(controller.play());
    }
  }

  /// 拖动暂停的 pause/play 都走这里。
  ///
  /// 与 [_applyPlayerGesturePlayback] 同一条理由：`play()` 在没有原生实现的
  /// 环境里会抛 `MissingPluginException`，松手续播失败不该变成未处理的
  /// async error（拖动是高频操作，静默失败也要留日志）。
  void _applyDragPausePlayback(Future<void> action) {
    unawaited(
      action.catchError((Object error) {
        widget.state.log.warning('拖动进度条时切换播放状态失败：$error', scope: 'player');
      }),
    );
  }

  /// 打开右键菜单（`design/04` §5.1）。
  ///
  /// 幂等：已打开时只移动位置（部分平台只发 `onSecondaryTap` 不发 `onSecondaryTapDown`）。
  void _openContextMenu(Offset globalPosition) {
    _controlHideTimer?.cancel();
    setState(() {
      _contextMenuAnchor = globalPosition;
      _controlsVisible = true;
    });
    _syncOsdTimer();
  }

  /// 键盘打开右键菜单的三个激活器：菜单键、Shift+F10（Windows 惯例）、
  /// 以及无修饰的 F10（部分键盘没有菜单键，也没有 Shift 习惯）。
  static const List<SingleActivator> _contextMenuActivators = [
    SingleActivator(LogicalKeyboardKey.contextMenu),
    SingleActivator(LogicalKeyboardKey.f10, shift: true),
    SingleActivator(LogicalKeyboardKey.f10),
  ];

  /// 在画面中央打开右键菜单（菜单键 / Shift+F10 / F10）。
  ///
  /// 复用 [_openContextMenu] 而不是另写一套打开逻辑：它已经幂等（菜单开着时
  /// 只移动位置），也带着「强制显示控制栏 + 取消隐藏计时器」那套行为，
  /// 分叉出去这两点就会各自漂移。
  ///
  /// 为什么减掉半个菜单尺寸：[_openContextMenu] 的入参是菜单**左上角**
  /// （`player_context_menu.dart:178-181`），直接传画面中心会让菜单整体落到
  /// 右下象限、看起来像跑偏了。菜单宽高是 `player_context_menu.dart` 的私有
  /// 常量（`_menuWidth = 240`、`_estimatedMenuHeight = 420`），外部取不到，
  /// 这里镜像一份**只用于视觉居中**；镜像值漂移最多让菜单偏几十像素，
  /// 不改变任何行为。坐标空间沿用既有约定（见 `player_context_menu.dart:17-21`：
  /// Windows 全屏播放器里 globalPosition 与父 Stack 坐标一致）。
  void _openContextMenuAtCenter() {
    const halfMenu = Offset(120, 210);
    final center = MediaQuery.sizeOf(context).center(Offset.zero);
    _openContextMenu(center - halfMenu);
  }

  /// 关闭右键菜单并恢复自动隐藏计时（`design/04` §5.4）。
  void _closeContextMenu() {
    if (_contextMenuAnchor == null) return;
    setState(() => _contextMenuAnchor = null);
    _touchControls();
  }

  // `_contextMenuSections` 已搬到 `player_menu_sections.dart`（`part` 里的 `_PlayerPageState` 扩展）。

  /// 应用并持久化字幕样式（右键菜单叶子项与底部弹层的「应用」同一入口）。
  ///
  /// 顺序对齐 `_toggleOsdFlag`：**先 setState、再不 await 落盘**。写盘失败只
  /// 记日志——当前会话已经按新样式渲染，不因磁盘问题回滚。
  void _applySubtitleStyle(SubtitleStyle next) {
    if (!mounted) return;
    setState(() => _subtitleStyle = next);
    unawaited(
      widget.state.setSubtitleStyle(next).then((ok) {
        if (!ok) {
          widget.state.log.warning('保存字幕样式失败', scope: 'player');
        }
      }),
    );
  }

  /// 应用并持久化屏显样式（字号缩放 / 不透明度）。语义同 [_applySubtitleStyle]。
  void _applyOsdStyle(OsdStyle next) {
    if (!mounted) return;
    setState(() => _osdStyle = next);
    unawaited(
      widget.state.setOsdStyle(next).then((ok) {
        if (!ok) {
          widget.state.log.warning('保存屏显样式失败', scope: 'player');
        }
      }),
    );
  }

  /// 切换一项屏显开关（菜单里就地生效，**不关闭菜单**，便于连续调整）。
  void _toggleOsdFlag(String id) {
    final next = !(widget.state.osdFlags[id] ?? false);
    unawaited(widget.state.setOsdFlag(id, next));
    setState(() {});
    _syncOsdTimer();
  }

  // ------------------------------------------------------------ 设置树下钻项
  //
  // 这里的四项与 `_toggleOsdFlag` 同语义：**先 setState、再（不 await）落盘**。
  //
  // 为什么顺序不能反过来（先 await 再 setState）：
  // 1. 「就地生效」承诺的是**点完立刻变**。`AppState` 的各 `set*` 都是
  //    同步改内存、只把 `_persist()` 的 Future 交回来
  //    （`ui_preferences_store.dart:632-733`），等 I/O 只会让勾选晚一拍；
  // 2. 在 `testWidgets` 的假时钟下，那个 Future 由**真实 zone** 的写盘队列
  //    驱动，`await` 之后的那次 `setState` 可能永远等不到
  //    （`player_button_config_page.dart:71-75` 记录过同一个坑）。
  //
  // 为什么**不关菜单**：这一层里有 5 个开关 + 9 个控制栏按钮，用户的真实
  // 动作是「连着改几项再对比效果」。每改一项就关菜单，等于每一项都要重新
  // 右键、重新走两三层——那正是这次要消灭的负担。

  // `_settingsToggle` 已搬到 `player_menu_sections.dart`（`part` 里的 `_PlayerPageState` 扩展）。

  /// 就地改播放参数：立即应用到内核、立即刷新界面，落盘在后台。
  ///
  /// 与「完整设置页」读同一份 `PlayerOptions`（`state.setPlayerOptions`），
  /// 所以两处入口不会漂移：页面里改完回菜单，勾选就是新值。
  /// mpv 属性注入失败（非 NativePlayer 平台）不在这里报警——那会变成
  /// 每点一次一个提示；失败路径与启动时一致，由 `_applyPlaybackEnhancements`
  /// 的日志承接。
  void _livePatchOptions(PlayerOptions next) {
    final normalized = next.normalized();
    _options = normalized;
    unawaited(widget.state.setPlayerOptions(normalized));
    unawaited(_queueOptionsApply(normalized));
    setState(() {});
  }

  // `_queueOptionsApply` 已搬到 `player_playback_params.dart`（`part` 里的 `_PlayerPageState` 扩展）。

  Future<bool> _enqueueWrite(Future<bool> Function() write) {
    final run = _optionWriteQueue.then((_) => write());
    // 队列只承载顺序：单笔失败不让后续写入永远挂住（失败已由调用方提示）。
    _optionWriteQueue = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  void _toggleAudioNormalization() {
    final current = widget.state.playerOptions;
    final enabled = !current.audioNormalization;
    _options = current.copyWith(audioNormalization: enabled);
    unawaited(
      widget.state.setPlayerOptions(_options).then((saved) {
        if (!mounted || saved) return;
        widget.state.log.warning('音量归一偏好保存失败', scope: 'player');
        _showPlayerMessage('音量归一偏好保存失败', kind: ToastKind.error);
      }),
    );
    setState(() {});
    // 只写 `af`，且与整表写入共用一条队列：不会被更早发起、更晚落地的
    // 整表写入盖回旧值。
    unawaited(() async {
      if (!mounted) return;
      final applied = await _enqueueWrite(
        () => _controller.applyMpvProperties({
          'af': enabled ? audioNormalizationAf : '',
        }),
      );
      if (!mounted) return;
      if (!applied) {
        final rejected = _controller.rejectedMpvProperties;
        final reason = rejected.isNotEmpty
            ? rejected.map((entry) => entry.reason).join('；')
            : _controller.lastEngineError ?? '当前内核不支持';
        final message = '音量归一${enabled ? '开启' : '关闭'}未生效：$reason';
        widget.state.log.warning(message, scope: 'player');
        _showPlayerMessage(message, kind: ToastKind.error);
      } else if (enabled && widget.state.playerOptions.audioPassthrough) {
        const message = '音量归一：音频直通时不生效，仅对解码后的音频生效';
        widget.state.log.warning(message, scope: 'player');
        _showPlayerMessage(message);
      }
    }());
  }

  /// 「自动匹配字幕」开关：没有配置任何字幕源时不给改（菜单行已灰）。
  void _toggleSubtitleAutoMatch(bool value) {
    final current = widget.state.subtitleSettings;
    if (!current.hasAnyProvider) return;
    unawaited(
      widget.state.setSubtitleSettings(current.copyWith(autoMatch: value)),
    );
    setState(() {});
  }

  /// 显示/隐藏一个控制栏按钮（菜单里就地生效，不关菜单）。
  void _togglePlayerButtonVisible(String id, bool visible) {
    final next = Set<String>.of(widget.state.playerButtonHidden);
    if (visible) {
      next.remove(id);
    } else {
      next.add(id);
    }
    unawaited(widget.state.setPlayerButtonHidden(next));
    setState(() {});
  }

  /// 从菜单把控制栏按钮恢复默认（顺序 + 显示状态各归各位）。
  ///
  /// 不弹二次确认：`PlayerButtonConfigPage._confirmReset` 那边要确认，是因为
  /// 同一页上还挂着用户手动拖出来的顺序；这里只是一次「回到默认」的快捷方式，
  /// 代价可逆（再点一遍开关即可）。
  void _resetPlayerButtonsFromMenu() {
    unawaited(widget.state.resetPlayerButtons());
    setState(() {});
  }

  /// 应用画面模式并持久化（从菜单调用，与 `_showVideoFitSettings` 同语义）。
  void _applyVideoFitMode(PlayerVideoFitMode mode) {
    setState(() => _videoFitMode = mode);
    widget.state.rememberPlayerVideoFitMode(
      siteKey: _request.siteKey,
      vodId: _request.vodId,
      mode: mode.name,
    );
  }

  /// 长按画面开始快进：临时切到用户设置的长按倍速（默认 3×）。
  ///
  /// 倍速是播放参数的一部分（PlayerOptions.longPressSpeed），设置页与右键菜单
  /// 改的是同一份值。
  void _beginGestureSpeed() {
    if (_gestureRateBeforeLongPress != null) return;
    _gestureRateBeforeLongPress = _controller.rate;
    // 直接读 AppState 而不是 [_options] 快照：在播放器里打开「完整设置页」
    // 改完返回后，快照可能还是旧值，而长按必须用刚改的那一档。
    final speed = widget.state.playerOptions.longPressSpeed;
    _lastGestureSpeed = speed;
    unawaited(_setGestureRate(speed));
    _touchControls();
  }

  /// 长按期间/松开后修改播放速率；失败只记日志。
  ///
  /// 手势不该让整页抛异常：流未就绪或平台拒绝改速时（无原生引擎的测试环境
  /// 同样会走到这里）静默降级，画面上的长按仍然成立。
  Future<void> _setGestureRate(double rate) async {
    try {
      await _controller.setRate(rate);
    } catch (error) {
      widget.state.log.warning('长按倍速切换失败：$error', scope: 'player');
    }
  }

  void _endGestureSpeed() {
    final previous = _gestureRateBeforeLongPress;
    _gestureRateBeforeLongPress = null;
    if (previous != null) unawaited(_setGestureRate(previous));
  }

  // `_showSubtitleStyleSettings` 已搬到 `player_subtitle_menu.dart`（`part` 里的 `_PlayerPageState` 扩展）。

  Future<void> _showVideoFitSettings() async {
    final selected = await showModalBottomSheet<PlayerVideoFitMode>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              leading: Icon(Icons.aspect_ratio_outlined),
              title: Text('画面比例与缩放'),
              subtitle: Text('只改变显示方式，不改变原始视频'),
            ),
            for (final mode in PlayerVideoFitMode.values)
              ListTile(
                selected: mode == _videoFitMode,
                leading: Icon(
                  mode == _videoFitMode
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                title: Text(mode.label),
                onTap: () => Navigator.of(context).pop(mode),
              ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    setState(() => _videoFitMode = selected);
    widget.state.rememberPlayerVideoFitMode(
      siteKey: _request.siteKey,
      vodId: _request.vodId,
      mode: selected.name,
    );
  }

  void _showMediaInfo() {
    final video = _controller.selectedVideoTrack;
    final audio = _controller.selectedAudioTrack;
    final params = _controller.videoParams;
    final audioParams = _controller.audioParams;
    final diagnostics = _diagnostics;
    final rows = <(String, String)>[
      ('分辨率', _mediaResolution()),
      (
        '显示比例',
        params.aspect == null ? '未知' : params.aspect!.toStringAsFixed(3),
      ),
      ('视频编码', video?.codec?.isNotEmpty == true ? video!.codec! : '未知'),
      (
        '帧率',
        video?.fps == null ? '未知' : '${video!.fps!.toStringAsFixed(2)} fps',
      ),
      ('视频码率', _formatBitrate(video?.bitrate)),
      ('像素格式', params.pixelformat ?? '未知'),
      ('音频编码', audio?.codec?.isNotEmpty == true ? audio!.codec! : '未知'),
      (
        '采样率',
        audioParams.sampleRate == null ? '未知' : '${audioParams.sampleRate} Hz',
      ),
      ('声道', audioParams.hrChannels ?? audioParams.channels ?? '未知'),
      ('音频码率', _formatBitrate(_controller.audioBitrate ?? audio?.bitrate)),
      ('格式', diagnostics?.format.label ?? '未知'),
      ('缓冲', _formatDuration(_controller.buffered)),
    ];
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('媒体信息'),
        content: SizedBox(
          width: 480,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: rows.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final (label, value) = rows[index];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 88,
                      child: Text(
                        label,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    Expanded(child: SelectableText(value)),
                  ],
                ),
              );
            },
          ),
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

  /// 展示播放诊断（§23）：引擎/格式/网络/错误与阶段耗时，可一键复制。
  void _showDiagnostics() {
    final diagnostics = _diagnostics;
    if (diagnostics == null) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('播放诊断'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: SelectableText(
              diagnostics.report,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: diagnostics.report));
              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Text('复制'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
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
            for (final (key, description) in [
              for (final entry in playerShortcuts)
                if (((!_isLive && !_isCatchup) || entry.$1 != '[ / ]') &&
                    (_navigationAvailable || entry.$1 != 'Ctrl+Shift+← / →'))
                  entry,
              if (_isLive) ('PgUp / PgDn', '上一台 / 下一台（跨分组）'),
              ..._contextMenuShortcutHelp,
            ])
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

/// 本页独有、`playerShortcuts`（`app.dart:1348` 的共享常量，不改它）里
/// 没有的快捷键说明：键盘打开右键菜单是本页自己的入口，说明也只属于本页。
const List<(String, String)> _contextMenuShortcutHelp = [
  ('Shift + F10', '打开右键菜单（画面中央）'),
  ('菜单键', '打开右键菜单（画面中央）'),
  ('F10', '打开右键菜单（画面中央）'),
];

/// 屏显开关的中文名（`design/02` §5.1）。
String _osdLabelOf(String id) {
  switch (id) {
    case OsdFlag.title:
      return '标题';
    case OsdFlag.size:
      return '分辨率';
    case OsdFlag.time:
      return '时钟';
    case OsdFlag.progress:
      return '播放进度';
    case OsdFlag.traffic:
      return '网速';
    case OsdFlag.mini:
      return '迷你进度条';
    case OsdFlag.diagnostics:
      return '诊断面板';
    default:
      return id;
  }
}

/// 播放器顶栏**溢出菜单**的动作。
///
/// 只保留**右键之外再没有别的入口**的五项（理由见 `_buildPlayerAppBar` 里
/// 「更多」那段注释）：字幕样式、弹幕设置、画面比例与缩放、媒体信息、
/// 快捷键说明。其余能力全部收进右键菜单的多层分组，不在顶栏重复第二次。
enum _PlayerMenuAction {
  subtitleStyle,
  danmakuSettings,
  videoFit,
  mediaInfo,
  shortcuts,
}

/// 溢出菜单里的一行（图标 + 文字）。
Widget _menuRow(IconData icon, String label) {
  return Row(
    children: [
      Icon(icon, size: 18),
      const SizedBox(width: AppSpace.md),
      Text(label),
    ],
  );
}

PopupMenuItem<_PlayerMenuAction> _menuItem(
  _PlayerMenuAction value,
  IconData icon,
  String label,
) {
  return PopupMenuItem<_PlayerMenuAction>(
    value: value,
    child: _menuRow(icon, label),
  );
}

class _PlayerErrorOverlay extends StatelessWidget {
  const _PlayerErrorOverlay({
    required this.message,
    required this.url,
    required this.onRetry,
    required this.onResume,
    required this.onNext,
    required this.canGoNext,
  });

  final String message;
  final String url;

  /// 出口一：用**原** `_request`（原集、原 `startPosition`）重新加载。
  final VoidCallback onRetry;

  /// 出口二：重新查库拿最新进度后续播（`design/03` §4.4）。
  final VoidCallback onResume;

  /// 出口三：显式用户动作地切下一集（**不是**自动连播）。
  final VoidCallback onNext;
  final bool canGoNext;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = context.semanticColors;
    return Container(
      constraints: const BoxConstraints(maxWidth: 520),
      margin: const EdgeInsets.all(AppSpace.xl),
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        // 这是盖在**视频画面**上的浮层，必须始终够暗才读得清——
        // 但用设计系统的夜空底（带色相）而不是裸 `Colors.black`：
        // 纯黑会从整个世界（深靛夜空）里掉出来。
        color: AppPalette.nightGround.withValues(alpha: 0.92),
        borderRadius: AppRadius.mdAll,
        border: Border.all(color: semantic.statusFailed),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline, color: semantic.statusFailed),
              const SizedBox(width: AppSpace.sm),
              Text(
                '播放失败',
                // 用真实存在的 w700，不用 w600：雅黑没有真 Medium，
                // w600 会走合成加粗（笔画粘连、小字号发糊）。
                // 这是全站统一修过的同一类缺陷，浮层这里漏了。
                style: theme.textTheme.titleMedium?.copyWith(
                  color: AppPalette.nightInk,
                  fontWeight: AppWeight.title,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          Text(
            message,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppPalette.nightInk,
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          SelectableText(
            '地址：${redactUrl(url)}',
            style: theme.textTheme.bodySmall?.copyWith(
              // 从底色色相染出的副文本，不是 `Colors.white70`。
              color: AppPalette.nightInkMuted,
            ),
          ),
          const SizedBox(height: AppSpace.lg),
          // 失败态必须提供三个明确出口（`design/03` §4.4）：
          // 只给一行错误会让用户只能反复点「重试」，而真正的诉求往往是
          // 「从刚才的位置接着看」。
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.xs,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('player-error-retry'),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试本集'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('player-error-resume'),
                onPressed: onResume,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('从最近进度续播'),
              ),
              if (canGoNext)
                OutlinedButton.icon(
                  key: const ValueKey('player-error-next'),
                  onPressed: onNext,
                  icon: const Icon(Icons.skip_next, size: 18),
                  label: const Text('播放下一集'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 仅供测试：屏显刷新循环是否在运行（`design/02` §4.3）。
///
/// **为什么必须有这个缝**：该需求（「屏显全关 + 控制栏隐藏 → Timer 停止」）
/// 在 widget 树上**没有任何可观测的表象**——屏显层此时完全隐藏，
/// 时钟文本不渲染，没有可断言的像素或文本。
///
/// 三个候选观测面都不可用（均已实测）：
/// - `transientCallbackCount == 0`：加载态永远挂着 `LoadingBlock` 的
///   `CircularProgressIndicator`，该计数**恒 ≥1**（探针实测推进到 25 秒仍为 1；
///   连一个裸 spinner 也是 1）。原 brief 用这个断言，是一条**永不成立**的用例。
/// - 时钟文本跳秒：控制栏隐藏 + 屏显全关时时钟**根本不渲染**，无文本可观测。
/// - 测试结束时的「pending Timer」不变式：`dispose()` 会 cancel `_osdTimer`
///   （见 `dispose`），所以泄漏的 ticker 也不会被它抓到。
///
/// 因此显式暴露一个 `@visibleForTesting` 读取口。仓库已有同类先例
/// （`app_state.dart:458,672,1317,1334`）。
@visibleForTesting
bool debugOsdTickerRunning(State<PlayerPage> state) =>
    (state as _PlayerPageState)._osdTimer?.isActive ?? false;

/// 仅供测试：读取当前控制器的格式观测委托，不触发播放。
@visibleForTesting
MediaFormat? Function(String)? debugPlayerObservedMediaFormatFor(
  State<PlayerPage> state,
) => (state as _PlayerPageState)._controller.observedMediaFormatFor;

/// 仅供测试：控制浮层当前是否可见（`design/01` §4.4）。
///
/// **为什么必须有这个缝**：浮层隐藏时只是 `opacity: 0` + `IgnorePointer`，
/// 里面的按钮**仍然在树里**，`find.byTooltip(...)` 照样命中。于是测试无法
/// 从「找得到」判断它能不能点：隐藏态下点击被 `IgnorePointer` 吃掉，
/// `tester.tap` 默认只打印一条 warning，断言随后以「菜单没打开」的
/// 形式失败，看不出真正原因（实测 `subtitle_flow_test.dart`、
/// `danmaku_flow_test.dart` 都是这样红的）。
///
/// 也不适合让测试去读 `IgnorePointer.ignoring`：那要按祖先链定位到
/// 第 3 层里那个特定的 `IgnorePointer`，浮层结构一改就静默失准。
@visibleForTesting
bool debugPlayerControlsVisible(State<PlayerPage> state) =>
    (state as _PlayerPageState)._controlsVisible;

/// 仅供测试：最近一次长按画面请求的倍速（默认 3×，可在设置里改）。
///
/// 引擎在无原生实现的测试环境里不会回报真实速率，所以用请求值作为观测缝。
@visibleForTesting
double? debugLastGestureSpeed(State<PlayerPage> state) =>
    (state as _PlayerPageState)._lastGestureSpeed;

/// 仅供测试：把控制浮层唤回可见态。
///
/// **单击画面现在带传输语义**（暂停/播放）：测试若只想让控制栏出现，不能再点
/// 画面——那会顺带暂停播放，字幕/弹幕等用例后续的「仍在播」断言就全变了。
/// 这里复用的就是产品的唤醒路径 [_touchControls]，不另写一套状态。
///
/// 也**不要**改用模拟鼠标悬停：真实窗口下 `LiveTestWidgetsFlutterBinding`
/// 已在跟踪真实鼠标设备，`tester.createGesture(kind: PointerDeviceKind.mouse)`
/// 会让 `MouseTracker` 断言失败（`design/05` §1.7）。
@visibleForTesting
void debugRevealPlayerControls(State<PlayerPage> state) =>
    (state as _PlayerPageState)._touchControls();

/// 仅供测试：冻结屏显时钟（`design/05` §8.1）。
///
/// **为什么必须有**：屏显右上角是**实时时钟**，每秒重绘。视觉证据采集
/// （`integration_test/phase8_visual_flow_test.dart`）会把截图提交入库，
/// 而实时时钟让同一份代码每次跑出**不同字节**的 PNG——实测只有右上角
/// 约 34×10 像素在变（`player-controls-r16x10.png` 的差异包围盒是
/// `(1390, 21, 1424, 31)`），其余像素逐字节相同。
/// 那会让「截图证据」无法复核：无法判断差异来自代码改动还是走时。
///
/// 置为非 null 后时钟固定在该时刻；置回 null 恢复真实时间。
/// 生产代码不读这个变量（默认 null），对运行时行为零影响。
@visibleForTesting
DateTime? debugOsdClockOverride;
