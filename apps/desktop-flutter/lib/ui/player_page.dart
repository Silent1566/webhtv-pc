/// 播放器页（§17.3）。
///
/// 包含：播放器画面、标题、线路选择、剧集列表、播放/暂停、进度条、音量、倍速、
/// 全屏、上一集/下一集、加载状态、错误提示，以及键盘快捷键（§10.3、§17.4）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_error.dart';
import '../core/danmaku.dart';
import '../core/danmaku_match.dart';
import '../core/history_view.dart';
import '../core/lut.dart';
import '../core/osd_config.dart';
import '../core/osd_diagnostics.dart';
import '../core/playback.dart';
import '../core/playback_diagnostics.dart';
import '../core/playback_repeat.dart';
import '../core/player_buttons.dart';
import '../core/player_options.dart';
import '../core/player_tracks.dart';
import '../core/protocol.dart';
import '../core/skip_segments.dart';
import '../core/source_swap.dart';
import '../core/sleep_timer.dart';
import '../core/subtitle.dart';
import '../core/subtitle_provider.dart';
import '../core/tmdb_detail_model.dart';
import '../core/tmdb_playback.dart';
import '../core/tmdb_season.dart';
import '../services/danmaku_library_service.dart';
import '../services/danmaku_service.dart';
import '../services/live_danmaku_session.dart';
import '../services/subtitle_match_service.dart';
import '../state/app_state.dart';
import 'advanced_settings_page.dart';
import 'app.dart';
import 'common.dart';
import 'subtitle_settings_page.dart';
import 'danmaku_overlay.dart';
import 'player_button_config_page.dart';
import 'player_context_menu.dart';
import 'player_controller.dart';
import 'player_episode_panel.dart';
import 'player_osd.dart';
import 'player_overlay.dart';
import 'theme.dart';
import 'tokens.dart';
import 'toast.dart';

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
    String? playbackFlag,
    String? episodeTarget,
    this.headers = const {},
    this.startPosition,
    this.playLines = const [],
    this.lineRoutes = const {},
    this.episodeCardsByFlag = const {},
    this.episodesReversed = false,
    this.episodeIndex = 0,
    this.vodPic,
    this.directUrl = false,
    this.subtitles = const [],
    this.subtitleHeaders = const {},
    this.danmaku = const [],
    this.tmdb,
    this.resumeSeed,
    this.sourceKey = '',
  }) : episodeTarget = episodeTarget ?? url,
       playbackFlag = playbackFlag ?? flag;

  final String url;
  final String title;
  final String siteKey;
  final String vodId;
  final String vodName;
  final String episodeName;
  final String flag;
  final String playbackFlag;
  final Map<String, String> headers;
  final Duration? startPosition;

  /// 站点播放入口的**输入目标**（详情 `vod_play_url` 里该集 `$` 之后的值）。
  ///
  /// 与 [url] 的区别很关键：
  /// - [url] 是**解析后的可播地址**（T4 站点还要再经本地代理换成 `127.0.0.1/p/<token>/…`），
  ///   带时效签名，**不能**当作再次解析的输入；
  /// - [episodeTarget] 是站点能认的原始目标（网盘站是分享链，普通站是剧集地址）。
  ///
  /// 历史续播必须用 [episodeTarget] 重新解析：拿 [url] 去问站点只会得到
  /// 「站点返回业务错误」（用户反馈 2026-10-09「无法从历史记录页面继续播放」）。
  /// 为空时回退到 [url]（兼容命令行/直播等无需二次解析的场景）。
  final String episodeTarget;

  /// 播放结果携带的外挂字幕（§10.3）。
  final List<SubtitleInfo> subtitles;

  /// 拉取外挂字幕时使用的 Header（与媒体一致，含 Referer/UA/Cookie）。
  ///
  /// 与 [headers] 分开：走本地代理时 [headers] 被清空（由代理注入），而字幕由
  /// 宿主自己请求，必须用代理前的原始 Header（§11.3.1）。
  final Map<String, String> subtitleHeaders;

  /// 播放结果携带的弹幕源（§21 Phase 3）。拉取弹幕同样使用 [subtitleHeaders]。
  final List<DanmakuSource> danmaku;

  /// TMDB 季度身份（`docs/phase4/design/04` §8.1）。
  ///
  /// 为 `null` 时表示未携带季度身份（历史恢复、直播、命令行），
  /// 此时只写来源 `history`，不写季度进度（`02` §6.2）。
  final TmdbPlaybackIdentity? tmdb;

  /// 详情页给出的全部线路，用于线路切换与上下集。
  final List<VodPlayLine> playLines;

  /// 外部（换源并入）线路的来源路由：页面内 flag → 来源站点与它自己的 vodId。
  ///
  /// 为什么播放器也要收：换集、切线路都会重新解析地址，而外部线路必须**继续**
  /// 定向到它自己的站点。只看 [siteKey] 不够——[siteKey] 记的是真来源站点，
  /// 但 `vodId` 也得跟着换，否则会拿原站点的 vod 去问外部站点。
  final Map<String, SwapLineRoute> lineRoutes;

  /// 详情页为**每一条线路**各算一次的剧集卡片（`tmdb_detail_model.dart`），
  /// 按线路展示标识（[flag]）分组。
  ///
  /// 为什么播放器还要收一次：浮层里的选集面板要显示详情页那套海报卡片
  /// （集号/集标题/剧照），而播放器手上只有 [playLines] 里的来源集名。
  /// 卡片只能由详情页算好传下来——集号推断依赖季过滤后的渲染顺序与
  /// `sourceIndices`（见 `TmdbEpisodeCards.build`），播放器没有这些上下文。
  ///
  /// 为什么是 **Map 而不是单个列表**：卡片以前只给「详情页当时选中的那条线路」，
  /// 播放器切到别的线路时 `copyWith` 会把旧卡片原样带过；两条线路集数恰好相等时，
  /// 旧线路的剧照会被贴到新线路的集上，长度校验根本查不出来。按线路分组后，
  /// 切到哪条线路就取哪条线路自己的卡片。
  ///
  /// 空 Map = 这次播放没有卡片可用（未匹配 TMDB、历史恢复、直播、命令行），
  /// 不是「暂时还没传」：调用方不得为它编造占位卡片。
  final Map<String, List<TmdbEpisodeCard>> episodeCardsByFlag;

  /// 详情页当时的页面级「倒序」开关状态（`browse_pages.dart` 的 `_episodesReversed`）。
  ///
  /// 卡片顺序由详情页按它当时的倒序状态算好，播放器的选集面板必须跟着同一个方向
  /// 排列，否则集列表、区间标签与卡片三者会互相错位。这是**页面级临时状态**，
  /// 只在用户点播那一刻快照一次，播放器不再翻它。
  final bool episodesReversed;

  final int episodeIndex;
  final String? vodPic;

  /// 待迁移的续播种子（跨源续播用，`docs/phase5/design/05` §7.3）。
  ///
  /// 为什么播放器还要收一次：比例换算需要**目标集的真实时长**，而目标集要
  /// `open()` 成功后才拿得到（[_load] 里 `_controller.duration`）。详情页算出的
  /// [startPosition] 只能按绝对毫秒给（它拿不到时长），两源同一集时长差很大时
  /// 会落到中段甚至片尾。带上种子后由播放器用真实时长重算一遍。
  ///
  /// 这是**一次性交接**：首次恢复成功后即被清掉（见 [_load]），换集与
  /// 「从最新进度续播」也必须清掉，否则会把上一集的种子套到新集上。
  final ResumeSeed? resumeSeed;

  /// 这一次播放用的**播放源标识**（`core/source_key.dart`）。
  ///
  /// 空串 = 当前生效源（既有语义）。非空且与生效源不同时，说明这次播放来自
  /// 「其它配置的历史」：换集/切线路必须继续用**那份配置**解析
  /// （[AppState.resolvePlaybackForSource]），进度也必须写回它自己的
  /// `source_key`，否则一次续播就会在当前源里多出一条同名历史。
  final String sourceKey;

  /// 地址已是最终可播地址（直播频道），无需经站点播放入口解析。
  ///
  /// 直播源的 `urls` 直接在本地就是媒体地址，走解析器只会多余地请求站点；
  /// 同时直播需要「失败按顺序切线路」（§13.3），与点播的剧集切换语义不同。
  final bool directUrl;

  PlaybackRequest copyWith({
    String? url,
    String? episodeTarget,
    String? episodeName,
    String? flag,
    String? playbackFlag,
    Map<String, String>? headers,
    int? episodeIndex,
    Duration? startPosition,
    bool clearStartPosition = false,
    List<SubtitleInfo>? subtitles,
    List<DanmakuSource>? danmaku,
    ResumeSeed? resumeSeed,
    bool clearResumeSeed = false,
    String? sourceKey,
    bool clearSourceKey = false,
  }) {
    return PlaybackRequest(
      url: url ?? this.url,
      // `episodeTarget` **不随 `url` 自动跟随**：两者语义不同（前者是站点入口
      // 目标、后者是解析后的可播地址），若换 `url` 时把入口目标也顶成播放地址，
      // 历史里存的就又是站点认不了的值。换集的调用点必须**显式**传 `episodeTarget`。
      episodeTarget: episodeTarget ?? this.episodeTarget,
      title: title,
      siteKey: siteKey,
      vodId: vodId,
      vodName: vodName,
      episodeName: episodeName ?? this.episodeName,
      flag: flag ?? this.flag,
      playbackFlag: playbackFlag ?? this.playbackFlag,
      headers: headers ?? this.headers,
      startPosition: clearStartPosition
          ? null
          : (startPosition ?? this.startPosition),
      // 与 `startPosition` 一样是「一次性交接」：显式清除优先，其次是新值。
      resumeSeed: clearResumeSeed ? null : (resumeSeed ?? this.resumeSeed),
      playLines: playLines,
      // 与 `playLines` / `siteKey` 一样原样带过：换集不能把外部线路的路由丢掉。
      lineRoutes: lineRoutes,
      // 卡片同属「详情页一次性算好」的上下文：换集不带过来，选集面板就退回裸集名，
      // 而播放器自己再也算不回来（缺选中季度与季过滤后的渲染顺序）。按线路分组后
      // 切线路也能取到**那条线路自己**的卡片，不必等详情页重新算。
      episodeCardsByFlag: episodeCardsByFlag,
      // 倒序是详情页那一刻的展示顺序，与卡片同属一次性快照：换集不能把它翻回去。
      episodesReversed: episodesReversed,
      episodeIndex: episodeIndex ?? this.episodeIndex,
      vodPic: vodPic,
      directUrl: directUrl,
      subtitles: subtitles ?? this.subtitles,
      subtitleHeaders: subtitleHeaders,
      danmaku: danmaku ?? this.danmaku,
      tmdb: tmdb,
      // 播放源归属默认原样带过：换集后进度仍要写回同一条来源。
      // 切到**外部并入线路**（属于当前配置）时必须显式清空，否则进度会被
      // 写回原来源，历史页从此多出一条挂错源的记录。
      sourceKey: clearSourceKey ? '' : (sourceKey ?? this.sourceKey),
    );
  }
}

/// 画面显示模式：保留原始比例、裁切铺满、拉伸填充或固定常用比例。
///
/// 这些模式直接映射到 media_kit_video 的 [BoxFit] / [Video.aspectRatio]，
/// 不改变媒体流本身，只改变窗口内的显示方式。
enum PlayerGestureAction { toggleControls, enterFullscreen, togglePlayback }

PlayerGestureAction resolvePlayerGesture({
  required bool doubleTap,
  required bool fullscreen,
}) {
  if (!doubleTap) return PlayerGestureAction.toggleControls;
  return fullscreen
      ? PlayerGestureAction.togglePlayback
      : PlayerGestureAction.enterFullscreen;
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

/// 字幕显示样式：默认透明底 + 黑色描边，避免视频上出现整块黑色背景。
class PlayerSubtitleStyle {
  const PlayerSubtitleStyle({
    this.color = Colors.white,
    this.backgroundColor = Colors.black,
    this.backgroundOpacity = 0,
    this.outlineWidth = 2,
    this.textScale = 1,
    this.bottomPadding = 24,
  });

  final Color color;
  final Color backgroundColor;
  final double backgroundOpacity;
  final double outlineWidth;
  final double textScale;
  final double bottomPadding;

  PlayerSubtitleStyle copyWith({
    Color? color,
    Color? backgroundColor,
    double? backgroundOpacity,
    double? outlineWidth,
    double? textScale,
    double? bottomPadding,
  }) => PlayerSubtitleStyle(
    color: color ?? this.color,
    backgroundColor: backgroundColor ?? this.backgroundColor,
    backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
    outlineWidth: outlineWidth ?? this.outlineWidth,
    textScale: textScale ?? this.textScale,
    bottomPadding: bottomPadding ?? this.bottomPadding,
  );

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
      color: color,
      fontWeight: FontWeight.w500,
      backgroundColor: backgroundColor.withValues(alpha: backgroundOpacity),
      shadows: shadows,
    ),
    textAlign: TextAlign.center,
    padding: EdgeInsets.fromLTRB(16, 0, 16, bottomPadding),
  );
}

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.state,
    required this.request,
    this.danmakuLoader,
    this.onLiveSourceFallback,
  });

  final AppState state;
  final PlaybackRequest request;

  /// 直播源级回退（Phase 9）：当前源所有线路都失败时，向调用方要下一个
  /// 同名频道的播放请求；返回 null 表示没有可回退的源。
  final Future<PlaybackRequest?> Function()? onLiveSourceFallback;

  /// 弹幕加载器；测试可注入替身，默认自建 [DanmakuService]。
  final DanmakuLoader? danmakuLoader;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WindowListener {
  late final PlayerController _controller;
  late PlaybackRequest _request;
  bool _fullscreen = false;
  bool _controlsVisible = true;
  Timer? _saveTimer;
  Timer? _controlHideTimer;
  String? _loadError;

  /// 连播单次守卫（`design/03` §4.1 D1）。
  ///
  /// 一次连播未完成时忽略后续所有控制器通知，避免「一次播完连跳多集」。
  bool _advanceInFlight = false;

  // ------------------------------------------------- Phase 9 播放增强

  /// 播放参数（缓冲/硬解/自动连播/失败回退/片头片尾开关/LUT）。
  PlayerOptions _options = const PlayerOptions.defaults();

  /// 本片的片头/片尾标记。
  SkipSegments _skipSegments = const SkipSegments.none();

  /// 本集是否已经自动跳过片头/片尾（每集各一次）。
  bool _introSkipped = false;
  bool _outroSkipped = false;

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

  /// 弹幕显示设置（开关/透明度/字号）。
  DanmakuStyle _danmakuStyle = const DanmakuStyle();

  String? _danmakuError;
  String? _lastShownDanmakuError;

  /// 直播弹幕会话（§13.1「直播弹幕」）。仅当弹幕源是 `ws://`/`wss://` 时建立。
  LiveDanmakuSession? _liveSession;

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
  PlayerSubtitleStyle _subtitleStyle = const PlayerSubtitleStyle();
  double? _gestureRateBeforeLongPress;

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
    _options = widget.state.playerOptions;
    _skipSegments = widget.state.skipSegmentsFor(
      siteKey: _request.siteKey,
      vodId: _request.vodId,
    );
    _controller = PlayerController()..addListener(_onControllerChanged);
    windowManager.addListener(this);
    _osdNow = debugOsdClockOverride ?? DateTime.now();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncOsdTimer();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _touchControls();
      _load();
    });
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
    // 连播改为**事件驱动**（`design/03` §4.1 D1）：
    // 旧实现在 `build()` 里排 postFrameCallback，任何一次通知（position/
    // duration/buffer/volume/… 每秒多次）只要 `isCompleted` 仍为 true 就会
    // 再排一个 `_onCompleted()`。于是「唤醒后点继续播放」这种纯重建动作
    // 也会立即跳下一集。
    _maybeAutoSkip();
    _maybeAdvanceOnGenuineEnd();
    _applyRememberedTrackChoices();
  }

  /// 自动跳过片头/片尾（`docs/phase9/design/01` §3）。
  ///
  /// 只读控制器状态，不重建播放器；`_skipArmed` 保证续播 seek 完成之前不判定。
  void _maybeAutoSkip() {
    if (!_skipArmed || _loadError != null) return;
    final duration = _controller.duration;
    if (duration <= Duration.zero) return;
    final decision = _skipSegments.decide(
      positionMs: _controller.position.inMilliseconds,
      durationMs: duration.inMilliseconds,
      autoIntro: _options.autoSkipIntro,
      autoOutro: _options.autoSkipOutro,
      introDone: _introSkipped,
      outroDone: _outroSkipped,
    );
    if (!decision.shouldSeek) return;
    if (decision.action == SkipAction.intro) {
      _introSkipped = true;
    } else if (decision.action == SkipAction.outro) {
      _outroSkipped = true;
    }
    widget.state.log.info(
      '自动跳过 ${decision.action.name} target=${decision.targetMs}ms '
      'episode=${_request.episodeName}',
      scope: 'player',
    );
    unawaited(_controller.seek(Duration(milliseconds: decision.targetMs)));
  }

  /// 手动跳过片头/片尾（不依赖开关；未标记时如实提示）。
  Future<void> _manualSkip(SkipAction action) async {
    final duration = _controller.duration;
    final segments = _skipSegments.normalizedFor(duration.inMilliseconds);
    final target = action == SkipAction.intro
        ? segments.introEndMs
        : segments.outroStartMs;
    if (target == null) {
      _showPlayerMessage(action == SkipAction.intro ? '本集未标记片头' : '本集未标记片尾');
      return;
    }
    if (action == SkipAction.intro) {
      _introSkipped = true;
    } else {
      _outroSkipped = true;
    }
    await _controller.seek(
      Duration(milliseconds: action == SkipAction.intro ? target : duration.inMilliseconds),
    );
    widget.state.log.info(
      '手动跳过 ${action.name} target=$target ms',
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
      _introSkipped = false;
      _outroSkipped = false;
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
      _introSkipped = false;
      _outroSkipped = false;
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
    // 错误给足阅读时间但不赖着：不传 duration，让 toast.dart 按类型取默认值
    // （error -> 15s，info/success -> 4s）。只有信息/成功在播放器里收窄到 3s：
    // 播放页的操作反馈更频繁，4s 会让右下角一直有东西。
    showToast(
      text,
      kind: kind,
      duration: kind == ToastKind.error ? null : const Duration(seconds: 3),
    );
  }

  /// 连播闸门：单次守卫 + 真播完判定（`design/03` §4.1）。
  ///
  /// 三道闸门缺一不可：
  /// 1. [_advanceInFlight] 防重入（D1）：一次连播未完成时忽略后续通知；
  /// 2. [PlayerController.isCompleted] 是 media_kit 的「到达流末尾」；
  /// 3. [isGenuineEnd] 排除提前 EOF（D2）——缓存耗尽时 `duration` 往往还没取到，
  ///    此时 `completed=true` 一定是误报。
  void _maybeAdvanceOnGenuineEnd() {
    if (_advanceInFlight) return;
    if (!_controller.isCompleted) return;
    if (!_isGenuineEnd()) return;

    final episodes = _episodesCache.isNotEmpty ? _episodesCache : _episodes;
    final decision = decidePlaybackAdvance(
      repeat: _repeat,
      autoNext: _options.autoNext,
      currentIndex: _request.episodeIndex,
      episodeCount: episodes.length,
      genuineEnd: true,
    );

    if (decision.action == PlaybackAdvanceAction.stop) {
      // 「本集结束」定时到点：停在当前画面，不前进。
      if (_sleepTimer.shouldStopOnEpisodeEnd()) {
        _stopBySleepTimer();
      }
      return;
    }

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
    _introSkipped = true; // 重播不再跳片头，否则会陷入「跳一次又重播」的循环。
    _outroSkipped = false;
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

  Future<void> _load() async {
    // 记录本次加载的「意图」，失败时用它回滚 `_request`（`design/03` §4.3 D3）。
    //
    // 为什么必须回滚：`_openTarget` 在调 `_load()` **之前**就已经把 `_request`
    // 改成了下一集（`episodeIndex` 已 +1、`clearStartPosition: true`）。
    // 若加载失败而不回滚，续播上下文（原集 + 原进度）就已丢失，
    // 用户看到的是「上一集失败 → 已经切到下一集」。
    final intent = _request;
    // 轨道记忆的键里含线路与集，换集/换线路后必须重读，上一集的记忆绝不能带过来。
    _loadRememberedTrackChoices();
    _skipArmed = false;
    _introSkipped = false;
    _outroSkipped = false;
    setState(() => _loadError = null);
    final outcome = await _controller.openWithRetry(
      _request.url,
      headers: _request.headers,
      siteKey: _request.siteKey,
      flag: _request.playbackFlag,
      episodeName: _request.episodeName,
    );
    widget.state.log.info('播放结果 ${outcome.summary}', scope: 'player');
    // 诊断：落定快照并写入日志（§23 输出引擎/格式/网络/错误）。
    final diagnostics = _controller.diagnostics;
    if (diagnostics != null) {
      widget.state.log.info(
        '播放诊断 ${diagnostics.logLine}',
        scope: 'diagnostics',
      );
      _diagnostics = diagnostics;
      widget.state.recordPlaybackDiagnostics(diagnostics);
    }
    if (!outcome.succeeded) {
      // 直播：当前线路失败时按顺序自动切到下一个线路（§13.3 播放失败可切线路）。
      // Phase 9：`changeLine` 关闭时不再自动换线（失败直接报错）。
      if (_request.directUrl &&
          widget.state.liveSettings.changeLine &&
          await _fallbackLiveLine()) {
        return;
      }
      // 失败路径的收尾（`design/03` §4.3）：
      // 1. 回滚 `_request` 到本次加载前的意图（保住续播上下文）；
      // 2. 清除残留的 `completed`，否则重建会再次触发连播（D1）；
      // 3. 记一条含 nearEnd 判定的诊断，让「缓存耗尽」在 PC 侧可见（§4.6）。
      _logFailureDiagnostics(outcome);
      setState(() {
        _request = intent;
        _loadError = outcome.failureKind == null
            ? '播放失败'
            : describePlayerFailure(outcome.failureKind!);
      });
      _controller.clearCompleted();
      return;
    }
    // Phase 9：注入 mpv 播放参数与 LUT。失败不阻断播放，只提示能力不可用。
    await _applyPlaybackEnhancements();
    // 字幕（§10.3）：装配外挂字幕候选并自动启用默认/强制字幕。
    // 字幕失败不得阻断播放，因此整段吞掉错误，只落日志与提示。
    await _configureSubtitles();
    // 弹幕（§21 Phase 3）：拉取并启用弹幕。同样不得阻断播放。
    await _configureDanmaku();
    // 进度恢复：仅对同一剧集且位置有效时执行（§10.3 播放恢复）。
    final start = _effectiveStartPosition();
    // 种子是**一次性交接**：无论重算成功与否，落定后都要清掉，否则下一次
    // `_load()`（失败重试、换线路）会把同一颗种子再套一遍，甚至套到别的集上。
    if (_request.resumeSeed != null || start != _request.startPosition) {
      _request = _request.copyWith(
        startPosition: start,
        clearStartPosition: start == null,
        clearResumeSeed: true,
      );
    }
    if (start != null &&
        start > Duration.zero &&
        start < _controller.duration) {
      await _controller.seek(start);
      widget.state.log.info(
        '恢复播放进度 episode=${_request.episodeName} '
        'position=${start.inMilliseconds}ms',
        scope: 'player',
      );
    }
    // 续播 seek 完成之后才允许自动跳片头/片尾（design/01 §3.1）。
    _skipArmed = true;
    _maybeAutoSkip();
    _startProgressSaver();
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

  /// 应用播放参数与 LUT（Phase 9）。
  ///
  /// 两者都走 mpv 属性注入；平台不是 NativePlayer 或属性被拒绝时只提示一次，
  /// 不把失败升级成播放失败（`docs/phase9/design/01` §5）。
  Future<void> _applyPlaybackEnhancements() async {
    _options = widget.state.playerOptions;
    final applied = await _controller.applyPlayerOptions(_options);
    if (!applied) {
      widget.state.log.warning(
        '播放参数未生效（当前平台不是 NativePlayer）',
        scope: 'player',
      );
    }
    final lut = _options.lutPath.trim();
    if (lut.isEmpty) return;
    try {
      final text = await File(lut).readAsString();
      final parsed = parseCube(text, path: lut);
      if (!parsed.ok) {
        widget.state.log.warning(
          'LUT 解析失败 ${parsed.error} path=$lut',
          scope: 'player',
        );
        _showPlayerMessage('LUT 不可用：${parsed.error}', kind: ToastKind.error);
        return;
      }
      final ok = await _controller.applyLut(lut);
      if (!ok) {
        _showPlayerMessage('当前播放内核不支持 LUT', kind: ToastKind.error);
      }
    } catch (error) {
      widget.state.log.warning('LUT 加载失败 $error path=$lut', scope: 'player');
      _showPlayerMessage('LUT 加载失败：$error', kind: ToastKind.error);
    }
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
      // 源级回退（Phase 9）：只在当前源用尽、且调用方提供了回退入口时尝试一次。
      final fallback = widget.onLiveSourceFallback;
      if (fallback != null && !_sourceFallbackTried) {
        _sourceFallbackTried = true;
        final nextRequest = await fallback();
        if (nextRequest != null && mounted) {
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

  /// 装配字幕（§10.3「外挂字幕」「字幕轨选择」）。
  ///
  /// 顺序：先登记播放结果里的 `subs`，再自动启用默认/强制外挂字幕。
  /// 任何失败都只记日志/提示，绝不影响视频播放（§10.4）。
  Future<void> _configureSubtitles() async {
    // 本集用户显式选过内嵌字幕轨，且那条轨真的在当前容器里：不再自动挂外挂字幕。
    // 两条路径都调 setSubtitleTrack，后到的会顶掉先到的，用户的选择不能赌时序。
    if (_hasResolvableRememberedSubtitle()) {
      widget.state.log.info('本集记过内嵌字幕，跳过自动挂载外挂字幕', scope: 'subtitle');
      return;
    }
    final subtitles = _request.subtitles;
    if (subtitles.isEmpty) {
      await _autoMatchSubtitle();
      return;
    }
    _controller.setExternalSubtitles(
      subtitles,
      onDiscard: (sub, reason) => widget.state.log.warning(
        '字幕条目已丢弃 name=${sub.name} reason=$reason',
        scope: 'subtitle',
      ),
    );
    if (_controller.externalOptions.isEmpty) return;
    final enabled = await _controller.applyDefaultSubtitle(
      headers: _request.subtitleHeaders,
    );
    final error = _controller.subtitleError;
    if (error != null) {
      widget.state.log.warning(
        '默认字幕加载失败 sub=${_controller.selectedSubtitle?.label ?? ""} $error',
        scope: 'subtitle',
      );
      _showSubtitleError(error);
      return;
    }
    if (enabled) {
      widget.state.log.info(
        '默认字幕已启用 sub=${_controller.selectedSubtitle?.label ?? ""}',
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
    );
  }

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
    final service = SubtitleMatchService(log: widget.state.log);
    final best = await service.autoMatch(query: query, settings: settings);
    if (best == null) return;
    await _applySubtitleCandidate(best, remember: true);
  }

  /// 加载候选并选中；失败只提示，不影响播放。
  Future<bool> _applySubtitleCandidate(
    SubtitleCandidate candidate, {
    required bool remember,
  }) async {
    final info = SubtitleInfo(
      url: candidate.url,
      name: candidate.title,
      lang: candidate.language,
      format: candidate.format,
      flag: SubtitleInfo.selectionFlagDefault,
    );
    _controller.setExternalSubtitles(
      [info],
      onDiscard: (sub, reason) => widget.state.log.warning(
        '字幕候选被丢弃 name=${sub.name} reason=$reason',
        scope: 'subtitle',
      ),
    );
    if (_controller.externalOptions.isEmpty) {
      _showSubtitleError('字幕候选格式不受支持');
      return false;
    }
    final ok = await _controller.selectSubtitle(
      _controller.externalOptions.first,
      headers: _request.subtitleHeaders,
    );
    final error = _controller.subtitleError;
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
    widget.state.log.info(
      '字幕已启用 provider=${candidate.providerId} title=${candidate.title} '
      'lang=${candidate.language}',
      scope: 'subtitle',
    );
    return true;
  }

  /// 手动搜索字幕：关键词 → 候选列表 → 选中并记忆。
  Future<void> _showSubtitleSearch() async {
    final settings = widget.state.subtitleSettings;
    if (!settings.hasAnyProvider) {
      _showPlayerMessage('未配置字幕源：请先在设置页填写字幕目录或 HTTP 源', kind: ToastKind.error);
      return;
    }
    final query = _subtitleQuery();
    final controller = TextEditingController(text: query.title);
    final keyword = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('搜索字幕'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '剧名 / 关键词'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('搜索'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (keyword == null || !mounted) return;
    final text = keyword.trim();
    if (text.isEmpty) return;

    setState(() {});
    final service = SubtitleMatchService(log: widget.state.log);
    final results = await service.search(
      query: SubtitleQuery(
        title: text,
        season: query.season,
        episode: query.episode,
        siteKey: query.siteKey,
        vodId: query.vodId,
        episodeName: query.episodeName,
      ),
      settings: settings,
    );
    if (!mounted) return;
    if (results.isEmpty) {
      _showPlayerMessage('没有找到字幕（可换关键词或检查字幕源）');
      return;
    }
    final selected = await showModalBottomSheet<SubtitleCandidate>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('搜索结果'),
              titleTextStyle: TextStyle(fontWeight: FontWeight.w600),
            ),
            for (final candidate in results)
              ListTile(
                title: Text(candidate.title),
                subtitle: Text(
                  '${candidate.providerId} · ${candidate.language.isEmpty ? "未知语言" : candidate.language} '
                  '· ${candidate.score.toStringAsFixed(2)}',
                ),
                onTap: () => Navigator.of(context).pop(candidate),
              ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    await _applySubtitleCandidate(selected, remember: true);
  }

  /// 选择本地字幕文件：路径输入 → 加载并记忆。
  Future<void> _showLocalSubtitlePicker() async {
    final controller = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('本地字幕文件'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: r'C:\subtitles\movie.srt'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('加载'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = path?.trim() ?? '';
    if (trimmed.isEmpty || !mounted) return;
    final candidate = SubtitleCandidate(
      providerId: 'local',
      assetId: trimmed,
      title: trimmed.split(Platform.pathSeparator).last,
      language: '',
      format: '',
      url: trimmed,
    );
    await _applySubtitleCandidate(candidate, remember: true);
  }

  /// 字幕失败提示：不阻断播放，只用浮动提示告知（§10.4）。
  void _showSubtitleError(String message) {
    if (!mounted || _lastShownSubtitleError == message) return;
    _lastShownSubtitleError = message;
    // 不传 duration：走 error 默认的 15s，`字幕设置` 动作在这段时间内都可点。
    // 去重闸门 [_lastShownSubtitleError] 必须保留：同一条失败只提示一次。
    showToast(
      message,
      kind: ToastKind.error,
      action: AppToastAction(label: '字幕设置', onPressed: _showSubtitleMenu),
    );
  }

  // ---------------------------------------------------------------- 弹幕

  /// 装配弹幕（§21 Phase 3「字幕/弹幕可开启和关闭」）。
  ///
  /// 自动启用第一个可用的弹幕源；直播弹幕（`ws`/`wss`）走 WebSocket 会话（§13.1）。
  /// 任何失败都只记日志/提示，绝不影响视频播放（§10.4 同语义）。
  Future<void> _configureDanmaku() async {
    final sources = _request.danmaku;
    if (sources.isEmpty) {
      await _autoSearchDanmaku();
      return;
    }
    // 优先用户显式选择的源，其次第一个源（静态或直播均可）。
    var selected = sources.firstWhere(
      (source) => source.selected,
      orElse: () => sources.first,
    );
    if (selected.isLive) {
      await _connectLiveDanmaku(selected);
      return;
    }
    await _loadDanmakuSource(selected);
  }

  /// 构造弹幕库查询。
  DanmakuQuery _danmakuQuery() => DanmakuQuery(
    title: _request.vodName.trim().isEmpty
        ? _request.title
        : _request.vodName,
    episode: _request.episodeName,
    siteKey: _request.siteKey,
    vodId: _request.vodId,
    episodeName: _request.episodeName,
  );

  /// 播放结果没有弹幕时按设置搜索弹幕库（`design/02` §2.3）。
  Future<void> _autoSearchDanmaku() async {
    final settings = widget.state.danmakuSettings;
    if (!settings.isEnabled) return;
    final query = _danmakuQuery();
    final memory = widget.state.danmakuMatchFor(
      siteKey: _request.siteKey,
      vodId: _request.vodId,
      episodeName: _request.episodeName,
    );
    if (memory != null) {
      await _loadDanmakuSource(
        DanmakuSource(
          url: memory.url,
          name: memory.title,
          source: memory.providerId,
        ),
      );
      return;
    }
    final service = DanmakuLibraryService();
    final entries = await service.search(
      apiUrl: settings.apiUrl,
      title: query.title,
      episode: query.episode,
    );
    final best = pickDanmakuEntry(entries: entries, query: query);
    if (best == null) return;
    await _loadDanmakuSource(
      DanmakuSource(url: best.url, name: best.title, source: best.providerId),
    );
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

  /// 手动搜索弹幕：关键词 → 候选列表 → 加载并记忆。
  Future<void> _showDanmakuSearch() async {
    final settings = widget.state.danmakuSettings;
    if (!settings.hasLibrary) {
      _showPlayerMessage('未配置弹幕库地址：请先在设置页填写', kind: ToastKind.error);
      return;
    }
    final query = _danmakuQuery();
    final controller = TextEditingController(text: query.title);
    final keyword = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('搜索弹幕'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '剧名 / 关键词'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('搜索'),
          ),
        ],
      ),
    );
    controller.dispose();
    final text = keyword?.trim() ?? '';
    if (text.isEmpty || !mounted) return;

    final service = DanmakuLibraryService();
    final entries = await service.search(
      apiUrl: settings.apiUrl,
      title: text,
      episode: query.episode,
    );
    if (!mounted) return;
    if (entries.isEmpty) {
      _showPlayerMessage('没有找到弹幕（可换关键词或检查弹幕库）');
      return;
    }
    final ranked = rankDanmakuEntries(entries: entries, query: query);
    final selected = await showModalBottomSheet<DanmakuLibraryEntry>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('搜索结果'),
              titleTextStyle: TextStyle(fontWeight: FontWeight.w600),
            ),
            for (final entry in ranked)
              ListTile(
                title: Text(entry.title),
                subtitle: Text(
                  '${entry.providerId} · ${entry.episode.isEmpty ? "未标注集" : entry.episode} '
                  '${entry.count > 0 ? "· ${entry.count} 条" : ""} '
                  '· ${entry.score.toStringAsFixed(2)}',
                ),
                onTap: () => Navigator.of(context).pop(entry),
              ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    await _loadDanmakuSource(
      DanmakuSource(
        url: selected.url,
        name: selected.title,
        source: selected.providerId,
      ),
    );
    await widget.state.rememberDanmakuMatch(
      DanmakuMatchRecord.fromEntry(
        siteKey: _request.siteKey,
        vodId: _request.vodId,
        episodeName: _request.episodeName,
        entry: selected,
      ),
    );
  }

  /// 连接直播弹幕（§13.1「直播弹幕」）。
  Future<void> _connectLiveDanmaku(DanmakuSource source) async {
    await _teardownLiveSession('replace');
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

  /// 直播弹幕渲染时钟：定时推进 [liveNowMs]，使已过期的弹幕逐帧淡出。
  /// 会话断开时停止（没有新消息就不需要重绘）。
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
  Future<void> _loadDanmakuSource(DanmakuSource source) async {
    final stopwatch = Stopwatch()..start();
    try {
      final document = await _danmakuLoader.load(
        source,
        headers: _request.subtitleHeaders,
      );
      _danmakuItems = document.items;
      _danmakuError = null;
      widget.state.log.info(
        '弹幕已加载 ${document.logLine} elapsed=${stopwatch.elapsed.inMilliseconds}ms',
        scope: 'danmaku',
      );
      if (mounted) setState(() {});
    } catch (error) {
      _danmakuItems = const [];
      _danmakuError = describeDanmakuFailure(error);
      widget.state.log.warning(
        '弹幕加载失败 source=${source.displayName} $_danmakuError',
        scope: 'danmaku',
      );
      if (!mounted) return;
      setState(() {});
      _showDanmakuError(_danmakuError!);
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

  /// 弹幕设置菜单（§17.5）：开关 / 透明度 / 字号 / 速度 / 行数 / 区域 /
  /// 描边 / 时间偏移 / 类型显隐 / 库搜索。
  Future<void> _showDanmakuSettings() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.text_fields),
              title: const Text('弹幕设置'),
              titleTextStyle: const TextStyle(fontWeight: FontWeight.w600),
            ),
            _settingTile(
              '弹幕开关',
              subtitle: _danmakuStyle.enabled ? '已开启' : '已关闭',
              onTap: () async {
                Navigator.of(context).pop('toggle');
              },
            ),
            _settingTile(
              '透明度 ${(_danmakuStyle.opacity * 100).round()}%',
              onTap: () async {
                Navigator.of(context).pop('opacity');
              },
            ),
            _settingTile(
              '字号 ${(_danmakuStyle.textScale * 100).round()}%',
              onTap: () async {
                Navigator.of(context).pop('scale');
              },
            ),
            _settingTile(
              '速度 ${(_danmakuStyle.scrollDurationMs / 1000).toStringAsFixed(0)}s',
              subtitle: '滚动弹幕穿过画面的时长（越小越快）',
              onTap: () async {
                Navigator.of(context).pop('duration');
              },
            ),
            _settingTile(
              '行数 ${_danmakuStyle.maxTracks == 0 ? "不限" : _danmakuStyle.maxTracks}',
              subtitle: '最多同时占用的弹幕轨道数',
              onTap: () async {
                Navigator.of(context).pop('tracks');
              },
            ),
            _settingTile(
              '区域 ${(_danmakuStyle.areaRatio * 100).round()}%',
              subtitle: '滚动弹幕最多占用的画面高度',
              onTap: () async {
                Navigator.of(context).pop('area');
              },
            ),
            _settingTile(
              '描边 ${_strokeLabel(_danmakuStyle.strokeWidth)}',
              onTap: () async {
                Navigator.of(context).pop('stroke');
              },
            ),
            _settingTile(
              '时间偏移 ${_offsetLabel(_danmakuStyle.timeOffsetMs)}',
              subtitle: '正数＝弹幕整体延后出现',
              onTap: () async {
                Navigator.of(context).pop('offset');
              },
            ),
            _settingTile(
              '滚动弹幕',
              subtitle: _danmakuStyle.showScroll ? '显示' : '隐藏',
              onTap: () async {
                Navigator.of(context).pop('scroll');
              },
            ),
            _settingTile(
              '顶部弹幕',
              subtitle: _danmakuStyle.showTop ? '显示' : '隐藏',
              onTap: () async {
                Navigator.of(context).pop('top');
              },
            ),
            _settingTile(
              '底部弹幕',
              subtitle: _danmakuStyle.showBottom ? '显示' : '隐藏',
              onTap: () async {
                Navigator.of(context).pop('bottom');
              },
            ),
            _settingTile(
              '搜索弹幕…',
              subtitle: widget.state.danmakuSettings.hasLibrary
                  ? '按标题在弹幕库中搜索'
                  : '未配置弹幕库地址',
              onTap: () async {
                Navigator.of(context).pop('search');
              },
            ),
            _settingTile(
              '重新加载弹幕',
              onTap: () async {
                Navigator.of(context).pop('reload');
              },
            ),
            ListTile(
              onTap: () => Navigator.of(context).pop('close'),
              title: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
    if (action == null) return;
    switch (action) {
      case 'search':
        await _showDanmakuSearch();
      case 'toggle':
        _toggleDanmaku();
      case 'opacity':
        _applyDanmakuStyle(
          _danmakuStyle.copyWith(
            opacity: _nextStep(_danmakuStyle.opacity, 0.1, 0.3, 1.0),
          ),
        );
      case 'scale':
        _applyDanmakuStyle(
          _danmakuStyle.copyWith(
            textScale: _nextStep(_danmakuStyle.textScale, 0.25, 0.5, 2.0),
          ),
        );
      case 'duration':
        _applyDanmakuStyle(
          _danmakuStyle.copyWith(
            scrollDurationMs: _nextOption(
              _danmakuStyle.scrollDurationMs,
              const [4000, 6000, 8000, 10000, 12000],
            ),
          ),
        );
      case 'tracks':
        _applyDanmakuStyle(
          _danmakuStyle.copyWith(
            maxTracks: _nextOption(
              _danmakuStyle.maxTracks,
              const [0, 3, 5, 8],
            ),
          ),
        );
      case 'area':
        _applyDanmakuStyle(
          _danmakuStyle.copyWith(
            areaRatio: _nextOption(
              _danmakuStyle.areaRatio,
              const [0.3, 0.45, 0.6, 0.75],
            ),
          ),
        );
      case 'stroke':
        _applyDanmakuStyle(
          _danmakuStyle.copyWith(
            strokeWidth: _nextOption(
              _danmakuStyle.strokeWidth,
              const [0.0, 1.2, 2.0],
            ),
          ),
        );
      case 'offset':
        final next = _danmakuStyle.timeOffsetMs + 1000;
        _applyDanmakuStyle(
          _danmakuStyle.copyWith(timeOffsetMs: next > 5000 ? -5000 : next),
        );
      case 'scroll':
        _applyDanmakuStyle(
          _danmakuStyle.copyWith(showScroll: !_danmakuStyle.showScroll),
        );
      case 'top':
        _applyDanmakuStyle(
          _danmakuStyle.copyWith(showTop: !_danmakuStyle.showTop),
        );
      case 'bottom':
        _applyDanmakuStyle(
          _danmakuStyle.copyWith(showBottom: !_danmakuStyle.showBottom),
        );
      case 'reload':
        // 重新拉取时绕过缓存，否则“重新加载”会命中旧结果。
        DanmakuSource? source;
        for (final candidate in _request.danmaku) {
          if (!candidate.isLive) {
            source = candidate;
            break;
          }
        }
        source ??= _request.danmaku.isEmpty ? null : _request.danmaku.first;
        if (source != null) await _loadDanmakuSource(source);
    }
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

  String _strokeLabel(double width) {
    if (width <= 0) return '关';
    return width >= 2.0 ? '粗' : '细';
  }

  String _offsetLabel(int offsetMs) {
    if (offsetMs == 0) return '0s';
    final seconds = offsetMs ~/ 1000;
    return '${seconds > 0 ? '+' : ''}${seconds}s';
  }

  /// 在固定选项里循环取下一个（找不到当前值时回到第一项）。
  T _nextOption<T>(T current, List<T> options) {
    final index = options.indexOf(current);
    if (index < 0) return options.first;
    return options[(index + 1) % options.length];
  }

  /// 步进到下一个可选值（循环）。
  double _nextStep(double current, double step, double min, double max) {
    final next = current + step;
    return next > max ? min : next;
  }

  Widget _settingTile(
    String title, {
    String? subtitle,
    required VoidCallback onTap,
  }) => ListTile(
    leading: const Icon(Icons.tune),
    title: Text(title),
    trailing: subtitle == null
        ? null
        : Text(subtitle, style: const TextStyle(fontSize: 13)),
    onTap: onTap,
  );

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
                  option.selected ? Icons.radio_button_checked : Icons.radio_button_off,
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
                  _repeat == mode ? Icons.radio_button_checked : Icons.radio_button_off,
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
                _sleepTimer.idle ? '取消定时（当前未开启）' : '取消定时（${_sleepTimer.summary}）',
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
      _applySleepTimer(
        SleepTimerPlan.forDuration(Duration(minutes: minutes)),
      );
    }
  }

  /// LUT 选择/清除。
  Future<void> _showLutSettings() async {
    final current = _options.lutPath;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('LUT 滤镜'),
              titleTextStyle: TextStyle(fontWeight: FontWeight.w600),
              subtitle: Text('只支持 3D .cube；由 mpv 的 lut3d 滤镜应用'),
            ),
            ListTile(
              title: const Text('当前'),
              subtitle: Text(current.isEmpty ? '未启用' : current),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('输入 .cube 路径…'),
              onTap: () => Navigator.of(context).pop('pick'),
            ),
            ListTile(
              leading: const Icon(Icons.clear),
              title: const Text('清除 LUT'),
              enabled: current.isNotEmpty,
              onTap: () => Navigator.of(context).pop('clear'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'clear') {
      await _applyLutPath('');
      return;
    }
    if (action != 'pick') return;
    final controller = TextEditingController(text: current);
    final path = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('LUT 文件路径'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: r'C:\luts\movie.cube'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('应用'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (path == null || !mounted) return;
    await _applyLutPath(path.trim());
  }

  /// 解析并应用 LUT；失败时保持原设置不变。
  Future<void> _applyLutPath(String path) async {
    if (path.isEmpty) {
      final applied = await _controller.applyLut(null);
      if (!applied) {
        _showPlayerMessage('当前播放内核不支持 LUT', kind: ToastKind.error);
        return;
      }
      await _persistOptions(_options.copyWith(lutPath: ''));
      if (mounted) setState(() {});
      return;
    }
    try {
      final text = await File(path).readAsString();
      final parsed = parseCube(text, path: path);
      if (!parsed.ok) {
        _showPlayerMessage('LUT 不可用：${parsed.error}', kind: ToastKind.error);
        return;
      }
      final applied = await _controller.applyLut(path);
      if (!applied) {
        _showPlayerMessage('当前播放内核不支持 LUT', kind: ToastKind.error);
        return;
      }
      await _persistOptions(_options.copyWith(lutPath: path));
      if (mounted) setState(() {});
      _showPlayerMessage('已应用 LUT：${parsed.preset!.name}', kind: ToastKind.success);
    } catch (error) {
      _showPlayerMessage('LUT 读取失败：$error', kind: ToastKind.error);
    }
  }

  Future<void> _persistOptions(PlayerOptions options) async {
    _options = options.normalized();
    await widget.state.setPlayerOptions(_options);
  }

  Future<void> _toggleAutoSkip({required bool intro}) async {
    final next = intro
        ? _options.copyWith(autoSkipIntro: !_options.autoSkipIntro)
        : _options.copyWith(autoSkipOutro: !_options.autoSkipOutro);
    await _persistOptions(next);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _showSubtitleMenu() async {
    final options = _controller.subtitleOptions;
    final selected = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final option in options)
              ListTile(
                leading: Icon(
                  option.id == SubtitleOption.offId
                      ? Icons.subtitles_off_outlined
                      : (option.isExternal
                            ? Icons.description_outlined
                            : Icons.subtitles_outlined),
                ),
                title: Text(option.label),
                subtitle: option.isExternal
                    ? Text(
                        '外挂 · ${option.format.toUpperCase()}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )
                    : const Text('内嵌'),
                trailing: _controller.selectedSubtitle == option
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.of(context).pop(option),
              ),
            if (options.isEmpty)
              const ListTile(
                title: Text('当前视频没有字幕轨'),
                subtitle: Text('可以搜索字幕或选择本地文件'),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.search),
              title: const Text('搜索字幕…'),
              onTap: () => Navigator.of(context).pop('search'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('选择本地字幕文件…'),
              onTap: () => Navigator.of(context).pop('local'),
            ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    if (selected == 'search') {
      await _showSubtitleSearch();
      return;
    }
    if (selected == 'local') {
      await _showLocalSubtitlePicker();
      return;
    }
    if (selected is! SubtitleOption) return;
    _controller.clearSubtitleError();
    final ok = await _controller.selectSubtitle(
      selected,
      headers: _request.subtitleHeaders,
    );
    final error = _controller.subtitleError;
    if (ok) {
      widget.state.log.info(
        '字幕已切换 sub=${selected.label} kind=${selected.kind.name}',
        scope: 'subtitle',
      );
      // 只记内嵌轨：外挂/本地/网络字幕随集变化，由 `SubtitleMatchRecord` 另管。
      if (!selected.isExternal && selected.id != SubtitleOption.offId) {
        _rememberTrackChoice(PlayerTrackSlot.subtitle, selected.id);
      }
      return;
    }
    widget.state.log.warning(
      '字幕切换失败 sub=${selected.label} ${error ?? "未知错误"}',
      scope: 'subtitle',
    );
    if (error != null) _showSubtitleError(error);
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
    final position = _controller.position;
    final duration = _controller.duration;
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
    windowManager.removeListener(this);
    _saveTimer?.cancel();
    _controlHideTimer?.cancel();
    _osdTimer?.cancel();
    _osdTimer = null;
    _endGestureSpeed();
    _persistProgress();
    // 直播弹幕会话是网络资源，必须显式关闭（§20 资源释放）。
    unawaited(_teardownLiveSession('dispose'));
    _sleepTicker?.cancel();
    _sleepTicker = null;
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  void onWindowEnterFullScreen() {
    if (!mounted) return;
    setState(() {
      _fullscreen = true;
      _controlsVisible = true;
    });
    _touchControls();
  }

  @override
  void onWindowLeaveFullScreen() {
    if (!mounted) return;
    setState(() {
      _fullscreen = false;
      _controlsVisible = true;
    });
    _controlHideTimer?.cancel();
  }

  Future<void> _toggleFullscreen() async {
    final next = !await windowManager.isFullScreen();
    try {
      if (next) {
        // window_manager 在 Windows 上的全屏是「去边框 + 把窗口 SetWindowPos 到
        // 显示器 rcMonitor 铺满」，而这段铺满逻辑只在插件内部 is_frameless_ 为
        // false 时才执行（window_manager.cpp:593）。所以这里**不能**调
        // setAsFrameless：它会把 is_frameless_ 置 true，铺满分支整体被跳过，
        // 窗口停在原尺寸只是变成无边框小窗。标题栏设为 hidden 已足以让
        // WM_NCCALCSIZE 在全屏时去掉边框。
        await windowManager.setTitleBarStyle(
          TitleBarStyle.hidden,
          windowButtonVisibility: false,
        );
        await windowManager.setFullScreen(true);
        await windowManager.focus();
      } else {
        await windowManager.setFullScreen(false);
        await windowManager.setTitleBarStyle(
          TitleBarStyle.normal,
          windowButtonVisibility: true,
        );
      }
    } catch (error) {
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

  Future<void> _exitFullscreen() async {
    if (await windowManager.isFullScreen()) await _toggleFullscreen();
  }

  List<VodEpisode> get _episodes => _lineOf(_request.flag)?.episodes ?? const [];

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
      await _openTarget(target[index], flag: overrideFlag, episodeIndex: index);
      return;
    }
    final episodes = _episodesCache.isNotEmpty ? _episodesCache : _episodes;
    if (index < 0 || index >= episodes.length) return;
    await _openTarget(episodes[index], flag: flag, episodeIndex: index);
  }

  List<VodEpisode> _episodesCache = const [];

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

  /// 本次播放的解析入口（换集/切线路/失败重试都走它）。
  ///
  /// 为什么不让调用点各写一遍：原来源播放（`_request.sourceKey` 是**别的**
  /// 配置）必须一直用那份配置解析，任何一处漏掉就会回落到当前配置的同名站点上，
  /// 表现为「换集后播的是当前源的另一部片」。
  Future<PlaybackDecision?> _resolvePlayback({
    required String episodeTarget,
    required String flag,
    required String vodId,
    Site? siteOverride,
    bool isExternalRoute = false,
  }) {
    final state = widget.state;
    final source = _request.sourceKey.trim();
    // 外部并入线路属于**当前配置**：那条线路必须用当前配置解析，不能借原配置的
    // 服务去问（站点在两份配置里是两回事）。
    if (!isExternalRoute && source.isNotEmpty && source != state.activeSourceKey) {
      return state.resolvePlaybackForSource(
        sourceKey: source,
        siteKey: _request.siteKey,
        episodeTarget: episodeTarget,
        flag: flag,
        vodId: vodId,
      );
    }
    return state.resolvePlayback(
      episodeTarget: episodeTarget,
      flag: flag,
      vodId: vodId,
      siteOverride: siteOverride,
    );
  }

  Future<void> _openTarget(
    VodEpisode episode, {
    required String flag,
    required int episodeIndex,
  }) async {
    final state = widget.state;
    try {
      // 直播：地址已是最终可播地址，不经站点解析（§13.3）。
      final String url;
      final List<SubtitleInfo> subtitles;
      final List<DanmakuSource> danmaku;
      // 提到外层：下面写进度归属时要判断「这一集是不是外部并入线路」。
      final route = _request.lineRoutes[flag];
      if (_request.directUrl) {
        url = episode.url;
        subtitles = _request.subtitles;
        danmaku = _request.danmaku;
      } else {
        // 外部（换源并入）线路：只定向解析到它自己的站点，**不**切全局站源。
        final decision = await _resolvePlayback(
          episodeTarget: episode.url,
          flag: _playbackFlagFor(flag),
          vodId: route?.vodId ?? _request.vodId,
          siteOverride: route == null ? null : state.siteByKey(route.siteKey),
          isExternalRoute: route != null,
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
      }
      setState(() {
        _loadError = null;
        _request = _request.copyWith(
          url: url,
          // 换集必须把「站点入口目标」一起换成该集的输入值（`episode.url`），
          // 否则历史里记的仍是上一集的入口，续播会跳回上一集。
          episodeTarget: episode.url,
          episodeName: episode.name,
          flag: flag,
          playbackFlag: _playbackFlagFor(flag),
          headers: _request.directUrl ? _request.headers : null,
          episodeIndex: episodeIndex,
          clearStartPosition: true,
          // 种子属于**原记录那一集**：换集后必须一起清掉，否则会被当成
          // 「这一集也要按原进度续播」而把用户丢到新集的中段。
          clearResumeSeed: true,
          subtitles: subtitles,
          danmaku: danmaku,
          // 切到外部并入线路时，这条线路属于**当前配置**：进度不能再写回
          // 原来源（否则历史里多出一条挂错源的记录）。
          clearSourceKey: route != null,
        );
        _episodesCache = const [];
        // 换集后旧弹幕立即失效，避免新集开头出现上一集的弹幕；
        // 直播弹幕连接也必须断开，否则切集后旧会话会继续推流到新画面上。
        _danmakuItems = const [];
        _danmakuError = null;
      });
      await _teardownLiveSession('episode-change');
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

  /// 从**最新进度**续播（失败态三出口之二，`design/03` §4.4/§4.5）。
  ///
  /// **为什么必须重新查库**：失败期间进度仍在周期写入（[_persistProgress]），
  /// 最新值可能比 `_request.startPosition` 更靠后。用旧值续播会让用户
  /// 回到比失败点更早的位置。
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
      sourceKey: _request.sourceKey.trim().isEmpty
          ? null
          : _request.sourceKey,
    );
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
        startPosition: latest,
        clearResumeSeed: true,
      );
    });
    await _load();
  }

  Future<void> _playNext() async {
    final episodes = _episodesCache.isNotEmpty ? _episodesCache : _episodes;
    if (episodes.isEmpty) return;
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
    if (_contextMenuAnchor != null) {
      shortcuts.removeWhere(
        (activator, _) =>
            activator is SingleActivator &&
            activator.trigger == LogicalKeyboardKey.escape,
      );
      shortcuts[const SingleActivator(LogicalKeyboardKey.escape)] =
          _closeContextMenu;
    }

    return CallbackShortcuts(
      bindings: shortcuts,
      child: Focus(
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
                          behavior: HitTestBehavior.opaque,
                          onTap: _toggleControlsByGesture,
                          onDoubleTap: _handleDoubleTapGesture,
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
                              // 弹幕叠加层（§21 Phase 3 / §13.1 直播弹幕）：绘制在视频上方、
                              // 控制层下方。关闭时（style.enabled=false）不绘制任何内容。
                              Positioned.fill(
                                child: DanmakuOverlay(
                                  items: _danmakuItems,
                                  position: _controller.position,
                                  style: _danmakuStyle,
                                  liveItems: _liveItems,
                                  liveNowMs: _liveNowMs,
                                ),
                              ),
                              if (_controller.isLoading)
                                const Positioned.fill(child: LoadingBlock()),
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
                                isLoading: _controller.isLoading,
                              ))
                                Positioned.fill(
                                  child: PlayerBufferingIndicator(
                                    percent: _controller.bufferingPercent,
                                  ),
                                ),
                              if (_loadError != null)
                                Positioned.fill(
                                  child: Center(
                                    child: _PlayerErrorOverlay(
                                      message: _loadError!,
                                      url: _request.url,
                                      onRetry: _load,
                                      onResume: _resumeFromLatestProgress,
                                      onNext: _playNext,
                                      canGoNext:
                                          (_episodesCache.isNotEmpty
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
                    ),
                    // 第 2 层：屏显（`design/02`）。自身已 IgnorePointer。
                    Positioned.fill(
                      child: PlayerOsdLayer(
                        flags: widget.state.osdFlags,
                        controlsVisible: _controlsVisible,
                        title: '${_request.vodName} · ${_request.episodeName}',
                        resolution: _mediaResolution() == '未知'
                            ? null
                            : _mediaResolution(),
                        position: _controller.position,
                        duration: _controller.duration,
                        isLive: _request.directUrl,
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
                          ),
                        ),
                      ),
                    ),
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
  PreferredSizeWidget _buildPlayerAppBar() {
    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      title: Text(
        '${_request.vodName} · ${_request.episodeName}',
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
        PopupMenuButton<_PlayerMenuAction>(
          tooltip: '更多',
          icon: const Icon(Icons.more_vert),
          onSelected: (action) {
            switch (action) {
              case _PlayerMenuAction.subtitleStyle:
                _showSubtitleStyleSettings();
              case _PlayerMenuAction.danmakuSettings:
                _showDanmakuSettings();
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
            _menuItem(
              _PlayerMenuAction.mediaInfo,
              Icons.info_outline,
              '媒体信息',
            ),
            _menuItem(
              _PlayerMenuAction.shortcuts,
              Icons.keyboard,
              '快捷键说明',
            ),
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
          _formatDuration(_controller.position),
          style: tabular(Theme.of(context).textTheme.bodyMedium!),
        ),
        Expanded(
          child: PlayerProgressSlider(
            position: _controller.position,
            duration: duration,
            buffered: _controller.buffered,
            onSeek: _controller.seek,
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
        // （`resolveVisibleButtons` 的 8 个 id，`PlayerOverlayActionRow`
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
                [?_liveStatus, if (_liveOnline != null) '在线 $_liveOnline'].join(
                  ' · ',
                ),                style: Theme.of(context).textTheme.bodySmall,
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
    final specs = resolveVisibleButtons(
      order: widget.state.playerButtonOrder,
      hidden: widget.state.playerButtonHidden,
    );
    final episodes = _episodes;
    return [
      for (final spec in specs)
        switch (spec.id) {
          'prev' => IconButton(
            tooltip: '上一集（[）',
            onPressed: _playPrevious,
            icon: const Icon(Icons.skip_previous),
          ),
          'play' => IconButton(
            tooltip: _controller.isPlaying ? '暂停（空格）' : '播放（空格）',
            onPressed: _controller.playOrPause,
            icon: Icon(_controller.isPlaying ? Icons.pause : Icons.play_arrow),
          ),
          'next' => IconButton(
            tooltip: '下一集（]）',
            onPressed: _playNext,
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
                value: _nearestRate(_controller.rate),
                items: const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
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
          'episodes' when episodes.isNotEmpty => OutlinedButton.icon(
            onPressed: () => _showEpisodes(context, episodes),
            icon: const Icon(Icons.list, size: 18),
            label: Text('选集（${episodes.length}）'),
          ),
          'fullscreen' => IconButton(
            tooltip: '全屏（F11）',
            onPressed: _toggleFullscreen,
            icon: const Icon(Icons.fullscreen),
          ),
          // 条件不成立的项（如没有剧集时的 `episodes`）不渲染。
          // 占位仍在：`_actionGroups` 是按 `resolveVisibleButtons` 的长度配平的。
          _ => const SizedBox.shrink(),
        },
    ];
  }

  /// 与 [_buildActionButtons] 一一对应的分组（用于插分隔线）。
  List<PlayerButtonGroup> _actionGroups() {
    final specs = resolveVisibleButtons(
      order: widget.state.playerButtonOrder,
      hidden: widget.state.playerButtonHidden,
    );
    return [for (final spec in specs) spec.group];
  }

  double _nearestRate(double rate) {
    const rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    var best = rates.first;
    for (final candidate in rates) {
      if ((candidate - rate).abs() < (best - rate).abs()) best = candidate;
    }
    return best;
  }

  /// 选集面板（对齐安卓 `EpisodeListDialog`）。
  ///
  /// 与上一版 `showModalBottomSheet` 的区别：面板要容纳「线路行 + 区间行 +
  /// 16:9 剧照网格」，底部抽屉的高度放不下，改为居中弹窗。
  /// 面板本身不碰播放状态：切集、切线路都回调回这里。
  void _showEpisodes(BuildContext context, List<VodEpisode> episodes) {
    final line = _lineOf(_request.flag);
    unawaited(
      showDialog<void>(
        context: context,
        barrierColor: Colors.black.withValues(alpha: 0.62),
        builder: (_) => PlayerEpisodePanel(
          title: _request.vodName.isNotEmpty
              ? _request.vodName
              : _request.title,
          lineLabel: line?.displayName ?? _request.flag,
          playLines: _request.playLines,
          lineFlag: _request.flag,
          episodes: episodes,
          // 只取**当前线路**那一份：切线路后 `_request.flag` 已经换过，
          // 拿别的线路的卡片会串图（长度相等时连错位都查不出来）。
          episodeCards:
              _request.episodeCardsByFlag[_request.flag] ?? const [],
          // 详情页那一刻是倒序的话，面板的排列方向、区间标签与当前集定位都要跟着倒。
          reversed: _request.episodesReversed,
          episodeIndex: _request.episodeIndex,
          onSelectEpisode: (index) => unawaited(_playEpisode(index)),
          onSelectLine: (flag) => unawaited(_switchLineResumingEpisode(flag)),
        ),
      ),
    );
  }

  /// 切线路：尽量续播**同一集**（对齐安卓 `VideoActivity.java:3684-3687`）。
  ///
  /// 定位规则见 [locateEpisodeInLine]：集名精确匹配 → 集号匹配 → 第 1 集。
  ///
  /// 为什么不改 [_playEpisode]：它的 `overrideFlag` 分支已经负责「按新线路
  /// 解析地址 + 写 `_episodesCache`」，续同集只是换一个下标传进去；动那条分支
  /// 等于重写既有的换集路径，而阶段 B 要求这里的改动保守。
  Future<void> _switchLineResumingEpisode(String flag) async {
    if (flag == _request.flag) return;
    final target = _lineOf(flag)?.episodes ?? const <VodEpisode>[];
    if (target.isEmpty) return;
    final index = locateEpisodeInLine(
      episodes: target,
      currentName: _request.episodeName,
    );
    await _playEpisode(index, overrideFlag: flag);
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
    );
  }

  /// 屏显是否需要刷新循环。
  ///
  /// 控制栏可见时**必须**运行（为了强制显示的时钟），
  /// 即使屏显开关全关（上游同语义：`PlayerOsdController.java:152-158`）。
  bool get _osdNeedsTicker =>
      _controlsVisible || anyOsdEnabled(widget.state.osdFlags);

  void _syncOsdTimer() {
    if (_osdNeedsTicker) {
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
  /// **只在网速开关开着时采**：关着时每秒读一次 mpv 属性纯属浪费，
  /// 而且会把 "屏显全关 → 停止刷新" 的优化打回半残（循环虽停，
  /// 这里若另起唤醒就又活了）。
  void _sampleNetworkRate() {
    if (!(widget.state.osdFlags[OsdFlag.traffic] ?? false)) return;
    unawaited(_controller.sampleNetworkRate());
  }

  void _touchControls() {
    _controlHideTimer?.cancel();
    if (mounted && !_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _syncOsdTimer();
    // 菜单打开期间不排隐藏计时器（`design/04` §5.4）。
    if (_contextMenuAnchor != null) return;
    _controlHideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (_contextMenuAnchor != null) return;
      setState(() => _controlsVisible = false);
      _syncOsdTimer();
    });
  }

  void _toggleControlsByGesture() {
    if (resolvePlayerGesture(doubleTap: false, fullscreen: _fullscreen) ==
        PlayerGestureAction.toggleControls) {
      if (_controlsVisible) {
        _controlHideTimer?.cancel();
        setState(() => _controlsVisible = false);
        _syncOsdTimer();
      } else {
        _touchControls();
      }
    }
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

  /// 右键菜单的分组内容（`design/04` §4.1）。
  ///
  /// ## 为什么是 10 组、且每组都能往下钻
  ///
  /// 上一版是 7 个**扁平**组、约 40 项：子菜单基本为空，本该分层的选项
  /// （字幕字号/描边/位置/底色、各画面比例、7 个屏显开关、定时关闭）全被摊在
  /// 主列里，主列要滚到底才看得见「屏显」。现在的形态对齐 PotPlayer 的分组
  /// 逻辑——**按功能域分组、组内下钻**：主列只回答「我要动哪一类」，
  /// 具体取值落在第 2、第 3 列。
  ///
  /// ## 带子列的父项**只有** children、没有 onSelect
  ///
  /// 引擎对「有 children 的项」不发动作（`design/04` §5.5：一次点击不能既
  /// 飞出又执行）。所以父项只承载「打开下一列」，真实动作全部落在叶子上。
  ///
  /// ## 当前值必须可见
  ///
  /// 倍速、音量档位、静音、画面模式、LUT、屏显开关、自动跳过、循环模式、
  /// 定时关闭、字幕样式各档都用 `selected` 标出来。不可用项用
  /// `enabled: false` 但**保留 selected**：引擎把「选中 + 禁用」画成压暗的
  /// 琥珀，仍读得出这是当前值（`DESIGN.md:373`「禁用只降低强调，不能抹掉
  /// 状态」）。
  ///
  /// ## 每组至少两项
  ///
  /// 只有一个子项的分组没有存在价值（分组的目的是缩短主列），宁可合并掉。
  /// 所以「画面」只有画面比例与 LUT 两项、全屏归「显示」——全屏是显示模式，
  /// 与屏显开关同一类。
  List<PlayerMenuSection> _contextMenuSections() {
    const rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    // 音量档位：与底部控制条滑杆同值域（0–100），20 一档。
    const volumeSteps = [0.0, 20.0, 40.0, 60.0, 80.0, 100.0];
    final osd = widget.state.osdFlags;
    final volume = _controller.volume;
    final subtitle = _controller.selectedSubtitle;
    final audioTracks = _controller.audioTrackOptions;
    // 设置组下钻树的数据源：每次建菜单都重读，菜单里显示的就是**真实值**，
    // 不走本地缓存（`_options` 只是播放参数的会话副本，字幕/弹幕设置没有副本）。
    final subtitleSettings = widget.state.subtitleSettings;
    final danmakuSettings = widget.state.danmakuSettings;

    /// 叶子项的统一收尾：**先关菜单再执行**。
    ///
    /// 菜单层由本页持有；不关掉会盖在随后弹出的底部弹层/对话框上。
    VoidCallback act(VoidCallback action) => () {
      _closeContextMenu();
      action();
    };

    return [
      // ------------------------------------------------------ 1. 播放
      PlayerMenuSection(
        title: '播放',
        items: [
          PlayerMenuItem(
            id: 'play',
            label: _controller.isPlaying ? '暂停' : '播放',
            icon: _controller.isPlaying ? Icons.pause : Icons.play_arrow,
            onSelect: act(_controller.playOrPause),
          ),
          PlayerMenuItem(
            id: 'prev',
            label: '上一集',
            icon: Icons.skip_previous,
            onSelect: act(_playPrevious),
          ),
          PlayerMenuItem(
            id: 'next',
            label: '下一集',
            icon: Icons.skip_next,
            onSelect: act(_playNext),
          ),
          PlayerMenuItem(
            id: 'back10',
            label: '后退 10 秒',
            icon: Icons.replay_10,
            onSelect: act(
              () => _controller.seekBy(const Duration(seconds: -10)),
            ),
          ),
          PlayerMenuItem(
            id: 'forward10',
            label: '前进 10 秒',
            icon: Icons.forward_10,
            onSelect: act(
              () => _controller.seekBy(const Duration(seconds: 10)),
            ),
          ),
          // 循环与定时是**会话级**状态，取值有 3 种循环 + 8 种定时，全部
          // 摊进主列会让「播放」组比别的组高出一倍，所以保留原来的底部弹层
          // 作为唯一入口。`selected` 让「已开启循环或定时」在主列直接可见——
          // 上一版这两个状态在菜单里完全不可见。
          PlayerMenuItem(
            id: 'playback_mode',
            label: '循环与定时…',
            icon: Icons.repeat,
            selected: _repeat != PlaybackRepeat.off || !_sleepTimer.idle,
            onSelect: act(_showPlaybackModeSheet),
          ),
        ],
      ),

      // ------------------------------------------------------ 2. 速度
      PlayerMenuSection(
        title: '速度',
        items: [
          for (final rate in rates)
            PlayerMenuItem(
              id: 'rate_$rate',
              label: '${rate.toString()}×',
              selected: (_controller.rate - rate).abs() < 0.01,
              onSelect: act(() => _controller.setRate(rate)),
            ),
        ],
      ),

      // ------------------------------------------------------ 3. 字幕
      PlayerMenuSection(
        title: '字幕',
        items: [
          PlayerMenuItem(
            id: 'subtitle_track',
            label: '字幕轨…',
            icon: Icons.subtitles_outlined,
            selected: subtitle != null && subtitle.id != SubtitleOption.offId,
            onSelect: act(_showSubtitleMenu),
          ),
          PlayerMenuItem(
            id: 'subtitle_search',
            label: '在线搜索字幕…',
            icon: Icons.search,
            onSelect: act(_showSubtitleSearch),
          ),
          PlayerMenuItem(
            id: 'subtitle_local',
            label: '本地字幕文件…',
            icon: Icons.folder_open_outlined,
            onSelect: act(_showLocalSubtitlePicker),
          ),
          // 字幕样式在本轮**没有落盘能力**（`PlayerSubtitleStyle` 是页面字段），
          // 所以不能只给一个「打开设置页」的入口——四档取值每次都要点开底部
          // 弹层才看得见。这里做成二级 + 三级：字号 / 描边 / 位置 / 底色
          // 各自飞出一列具体档位。
          PlayerMenuItem(
            id: 'subtitle_style',
            label: '字幕样式',
            icon: Icons.format_color_text_outlined,
            children: [
              PlayerMenuItem(
                id: 'sub_size',
                label: '字号',
                icon: Icons.text_fields,
                children: [
                  for (final scale in const [0.8, 1.0, 1.25, 1.5])
                    PlayerMenuItem(
                      id: 'sub_size_${(scale * 100).round()}',
                      label: '${(scale * 100).round()}%',
                      selected:
                          (_subtitleStyle.textScale - scale).abs() < 0.001,
                      onSelect: () => _applySubtitleStyle(
                        _subtitleStyle.copyWith(textScale: scale),
                      ),
                    ),
                ],
              ),
              PlayerMenuItem(
                id: 'sub_outline',
                label: '描边',
                icon: Icons.border_color_outlined,
                children: [
                  for (final width in const [0.0, 1.0, 2.0, 3.0])
                    PlayerMenuItem(
                      id: 'sub_outline_${width.round()}',
                      label: width <= 0 ? '无描边' : '${width.round()}px',
                      selected:
                          (_subtitleStyle.outlineWidth - width).abs() < 0.001,
                      onSelect: () => _applySubtitleStyle(
                        _subtitleStyle.copyWith(outlineWidth: width),
                      ),
                    ),
                ],
              ),
              PlayerMenuItem(
                id: 'sub_pos',
                label: '位置',
                icon: Icons.vertical_align_bottom,
                children: [
                  for (final padding in const [0.0, 24.0, 48.0, 72.0])
                    PlayerMenuItem(
                      id: 'sub_pos_${padding.round()}',
                      label: '${padding.round()}dp',
                      selected:
                          (_subtitleStyle.bottomPadding - padding).abs() <
                          0.001,
                      onSelect: () => _applySubtitleStyle(
                        _subtitleStyle.copyWith(bottomPadding: padding),
                      ),
                    ),
                ],
              ),
              PlayerMenuItem(
                id: 'sub_bg',
                label: '底色',
                icon: Icons.format_color_fill,
                children: [
                  for (final alpha in const [0.0, 0.25, 0.5, 0.75])
                    PlayerMenuItem(
                      id: 'sub_bg_${(alpha * 100).round()}',
                      label: alpha <= 0 ? '透明' : '${(alpha * 100).round()}%',
                      selected:
                          (_subtitleStyle.backgroundOpacity - alpha).abs() <
                          0.001,
                      onSelect: () => _applySubtitleStyle(
                        _subtitleStyle.copyWith(backgroundOpacity: alpha),
                      ),
                    ),
                ],
              ),
              PlayerMenuItem(
                id: 'sub_style_reset',
                label: '恢复默认样式',
                icon: Icons.restart_alt,
                onSelect: act(
                  () => _applySubtitleStyle(const PlayerSubtitleStyle()),
                ),
              ),
            ],
          ),
        ],
      ),

      // ------------------------------------------------------ 4. 画面
      PlayerMenuSection(
        title: '画面',
        items: [
          PlayerMenuItem(
            id: 'video_fit',
            label: '画面比例与缩放',
            icon: Icons.aspect_ratio_outlined,
            children: [
              for (final mode in PlayerVideoFitMode.values)
                PlayerMenuItem(
                  id: 'fit_${mode.name}',
                  label: mode.label,
                  selected: mode == _videoFitMode,
                  onSelect: act(() => _applyVideoFitMode(mode)),
                ),
            ],
          ),
          PlayerMenuItem(
            id: 'lut',
            label: 'LUT 滤镜…',
            icon: Icons.palette_outlined,
            selected: _options.hasLut,
            onSelect: act(_showLutSettings),
          ),
        ],
      ),

      // ------------------------------------------------------ 5. 声音
      PlayerMenuSection(
        title: '声音',
        items: [
          PlayerMenuItem(
            id: 'volume',
            label: '音量',
            icon: _controller.muted ? Icons.volume_off : Icons.volume_up,
            children: [
              for (final step in volumeSteps)
                PlayerMenuItem(
                  id: 'volume_${step.round()}',
                  label: '${step.round()}%',
                  selected: (volume - step).abs() < 0.5,
                  onSelect: act(() => _controller.setVolume(step)),
                ),
            ],
          ),
          PlayerMenuItem(
            id: 'mute',
            label: _controller.muted ? '取消静音（M）' : '静音（M）',
            icon: _controller.muted ? Icons.volume_up : Icons.volume_off,
            selected: _controller.muted,
            onSelect: act(_controller.toggleMute),
          ),
          PlayerMenuItem(
            id: 'sound_audio_track',
            label: '音轨…',
            icon: Icons.graphic_eq,
            // 只有一条音轨时引擎没有可切的东西（`_showTrackMenu` 会弹说明），
            // 这里直接按「无多轨」灰掉，但仍保留在菜单里（隐藏更像功能没了）。
            enabled: audioTracks.length > 1,
            onSelect: act(() => _showTrackMenu(PlayerTrackKind.audio)),
          ),
        ],
      ),

      // ------------------------------------------------------ 6. 轨道
      PlayerMenuSection(
        title: '轨道',
        items: [
          PlayerMenuItem(
            id: 'track_video',
            label: '视频轨…',
            icon: Icons.video_settings_outlined,
            onSelect: act(() => _showTrackMenu(PlayerTrackKind.video)),
          ),
          PlayerMenuItem(
            id: 'track_subtitle',
            label: '字幕轨…',
            icon: Icons.subtitles_outlined,
            selected: subtitle != null && subtitle.id != SubtitleOption.offId,
            onSelect: act(_showSubtitleMenu),
          ),
          PlayerMenuItem(
            id: 'track_danmaku',
            label: _danmakuStyle.enabled ? '关闭弹幕' : '开启弹幕',
            icon: _danmakuStyle.enabled
                ? Icons.comment
                : Icons.comment_bank_outlined,
            selected: _danmakuStyle.enabled,
            // 就地生效、**不关菜单**：连续调整时会反复按。
            onSelect: _toggleDanmaku,
          ),
          PlayerMenuItem(
            id: 'track_danmaku_settings',
            label: '弹幕设置…',
            icon: Icons.comment_outlined,
            onSelect: act(_showDanmakuSettings),
          ),
          PlayerMenuItem(
            id: 'track_danmaku_search',
            label: '搜索弹幕…',
            icon: Icons.travel_explore,
            onSelect: act(_showDanmakuSearch),
          ),
        ],
      ),

      // ------------------------------------------------------ 7. 显示
      PlayerMenuSection(
        title: '显示',
        items: [
          PlayerMenuItem(
            id: 'osd',
            label: '屏显',
            icon: Icons.subtitles,
            children: [
              for (final id in OsdFlag.values)
                PlayerMenuItem(
                  id: 'osd_$id',
                  label: _osdLabelOf(id),
                  selected: osd[id] ?? false,
                  // 就地生效、不关菜单：7 个开关常要连着拨
                  // （`_toggleOsdFlag` 自己 setState，勾选当场刷新）。
                  onSelect: () => _toggleOsdFlag(id),
                ),
            ],
          ),
          PlayerMenuItem(
            id: 'fullscreen',
            label: _fullscreen ? '退出全屏' : '全屏',
            icon: _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
            onSelect: act(_toggleFullscreen),
          ),
        ],
      ),

      // ------------------------------------------------------ 8. 片头片尾
      PlayerMenuSection(
        title: '片头片尾',
        items: [
          PlayerMenuItem(
            id: 'auto_skip_intro',
            label: '自动跳过片头',
            icon: Icons.fast_forward_outlined,
            selected: _options.autoSkipIntro,
            onSelect: () => _toggleAutoSkip(intro: true),
          ),
          PlayerMenuItem(
            id: 'auto_skip_outro',
            label: '自动跳过片尾',
            icon: Icons.fast_forward,
            selected: _options.autoSkipOutro,
            onSelect: () => _toggleAutoSkip(intro: false),
          ),
          // 手动跳过依赖数据库里的标记：没有标记时**灰掉但仍然列出**，
          // 隐藏会让用户以为功能没了（`DESIGN.md` 同类教训）。
          PlayerMenuItem(
            id: 'skip_intro',
            label: '跳过片头',
            icon: Icons.skip_next_outlined,
            enabled: _skipSegments.hasIntro,
            onSelect: act(() => _manualSkip(SkipAction.intro)),
          ),
          PlayerMenuItem(
            id: 'skip_outro',
            label: '跳过片尾',
            icon: Icons.skip_next,
            enabled: _skipSegments.hasOutro,
            onSelect: act(() => _manualSkip(SkipAction.outro)),
          ),
          PlayerMenuItem(
            id: 'mark_intro',
            label: '标记片头为当前位置',
            icon: Icons.flag_outlined,
            onSelect: act(() => _markSkipSegment(SkipAction.intro)),
          ),
          PlayerMenuItem(
            id: 'mark_outro',
            label: '标记片尾为当前位置',
            icon: Icons.flag,
            onSelect: act(() => _markSkipSegment(SkipAction.outro)),
          ),
          PlayerMenuItem(
            id: 'clear_skip',
            label: '清除本片标记',
            icon: Icons.clear,
            enabled: _skipSegments.active,
            onSelect: act(_clearSkipSegments),
          ),
        ],
      ),

      // ------------------------------------------------------ 9. 信息
      PlayerMenuSection(
        title: '信息',
        items: [
          PlayerMenuItem(
            id: 'media_info',
            label: '媒体信息',
            icon: Icons.info_outline,
            onSelect: act(_showMediaInfo),
          ),
          PlayerMenuItem(
            id: 'diagnostics',
            label: '播放诊断',
            icon: Icons.monitor_heart_outlined,
            enabled: _diagnostics != null,
            onSelect: act(_showDiagnostics),
          ),
          PlayerMenuItem(
            id: 'shortcuts',
            label: '快捷键说明',
            icon: Icons.keyboard,
            onSelect: act(_showShortcutHelp),
          ),
        ],
      ),

      // ------------------------------------------------------ 10. 设置
      //
      // 这一组是**下钻设置树**，不再只是三个跳转入口：硬解 / 缓存 / 自动连播
      // 这类开关本身就在这里改，用户不必离开画面（上一版三项全是
      // `Navigator.push`，点一下播放器就没了——用户反馈「还有些没有聚合」
      // 指的正是这件事）。
      //
      // 为什么仍保留跳转项（`完整设置页…` / `打开完整字幕源设置…` /
      // `打开弹幕库设置…`）：那几个页面里是**文本表单**——字幕源 URL、token
      // （**不得进日志**）、多个本地目录、弹幕库地址。菜单列宽固定 240
      // （`design/04` §5.2），放不下一个可读的输入框；硬塞进去也只会被
      // `maxLines: 1` 的省略号截断，用户看不到自己在改什么，比跳页更难用。
      // 所以切分标准是**「一步操作 vs 长文本录入」**，不是「开关 vs 页面」：
      // 开关就地改，表单仍交给专门页面，两边不重复实现同一份偏好。
      PlayerMenuSection(
        title: '设置',
        items: [
          PlayerMenuItem(
            id: 'settings_player_options',
            label: '播放参数',
            icon: Icons.tune,
            children: [
              _settingsToggle(
                id: 'settings_hwdec',
                label: '硬件解码',
                value: _options.hardwareDecoding,
                onChanged: (value) => _livePatchOptions(
                  _options.copyWith(hardwareDecoding: value),
                ),
              ),
              _settingsToggle(
                id: 'settings_cache',
                label: '缓存',
                value: _options.cache,
                onChanged: (value) =>
                    _livePatchOptions(_options.copyWith(cache: value)),
              ),
              _settingsToggle(
                id: 'settings_preload_next',
                label: '预加载下一集',
                value: _options.preloadNext,
                onChanged: (value) =>
                    _livePatchOptions(_options.copyWith(preloadNext: value)),
              ),
              _settingsToggle(
                id: 'settings_audio_passthrough',
                label: '音频直通',
                value: _options.audioPassthrough,
                onChanged: (value) => _livePatchOptions(
                  _options.copyWith(audioPassthrough: value),
                ),
              ),
              _settingsToggle(
                id: 'settings_auto_next',
                label: '自动连播',
                value: _options.autoNext,
                onChanged: (value) =>
                    _livePatchOptions(_options.copyWith(autoNext: value)),
              ),
              // 第 3 层：失败回退阶梯。四档是**互斥单选**，摊成四条开关会让
              // 「当前是哪一档」看不出来；飞出子列则天然单选（只有一项打勾）。
              PlayerMenuItem(
                id: 'settings_failure_fallback',
                label: '失败回退',
                icon: Icons.alt_route,
                children: [
                  for (final mode in PlayerFailureFallback.values)
                    PlayerMenuItem(
                      id: 'settings_fallback_${mode.id}',
                      label: mode.label,
                      selected: _options.failureFallback == mode,
                      // 就地生效、不关菜单：改完回退策略常常还要接着调缓存上限。
                      onSelect: () => _livePatchOptions(
                        _options.copyWith(failureFallback: mode),
                      ),
                    ),
                ],
              ),
              // 第 3 层：缓存上限。真值是 int（16–2048 MiB，见
              // `PlayerOptions.minDemuxerMaxMiB`），菜单里没有数字输入，所以
              // 给四档常用值；要精调仍走「完整设置页…」的滑杆——**不假装**
              // 四档就是全部取值。
              PlayerMenuItem(
                id: 'settings_cache_cap',
                label: '缓存上限',
                icon: Icons.sd_storage_outlined,
                children: [
                  for (final mib in const [64, 128, 256, 512])
                    PlayerMenuItem(
                      id: 'settings_cache_cap_$mib',
                      label: '$mib MiB',
                      selected: _options.demuxerMaxBytesMiB == mib,
                      onSelect: () =>
                          _livePatchOptions(_options.copyWith(
                            demuxerMaxBytesMiB: mib,
                          )),
                    ),
                ],
              ),
            ],
          ),
          PlayerMenuItem(
            id: 'settings_subtitle_source',
            label: '字幕源',
            icon: Icons.subtitles_outlined,
            children: [
              _settingsToggle(
                id: 'settings_subtitle_auto_match',
                label: '自动匹配字幕',
                value: subtitleSettings.autoMatch,
                // 一个源都没有时匹配必然落空：**灰掉但保留 selected**。
                // 引擎把「选中 + 禁用」画成压暗琥珀，状态仍可读
                // （`player_context_menu.dart:503-515`：「禁用只降低强调，
                // 不能抹掉状态」）。
                enabled: subtitleSettings.hasAnyProvider,
                onChanged: _toggleSubtitleAutoMatch,
              ),
              PlayerMenuItem(
                id: 'settings_subtitle_provider_status',
                label: subtitleSettings.hasAnyProvider
                    ? '字幕源：已配置'
                    : '字幕源：未配置',
                icon: subtitleSettings.hasAnyProvider
                    ? Icons.check_circle_outline
                    : Icons.new_releases_outlined,
                // 纯状态行：不给动作，也**不置灰**（灰色读起来像「坏了」）。
                // 「已配置」用 selected 表达，与开关列同一套视觉语言。
                selected: subtitleSettings.hasAnyProvider,
              ),
              PlayerMenuItem(
                id: 'settings_subtitle_source_form',
                label: '打开完整字幕源设置…',
                icon: Icons.folder_open_outlined,
                // 为什么仍是跳转：URL / token / 多个本地目录都是长文本、
                // 多值录入，见本组顶部注释。
                onSelect: act(
                  () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SubtitleSettingsPage(state: widget.state),
                    ),
                  ),
                ),
              ),
            ],
          ),
          PlayerMenuItem(
            id: 'settings_danmaku_library',
            label: '弹幕库',
            icon: Icons.forum_outlined,
            children: [
              _settingsToggle(
                id: 'settings_danmaku_auto_search',
                label: '自动搜索弹幕',
                value: danmakuSettings.autoSearch,
                // 未配置库地址时搜不到任何东西：灰掉但保留 selected。
                enabled: danmakuSettings.hasLibrary,
                onChanged: _toggleDanmakuAutoSearch,
              ),
              PlayerMenuItem(
                id: 'settings_danmaku_library_form',
                label: '打开弹幕库设置…',
                icon: Icons.link,
                // 为什么仍是跳转：弹幕库地址是一个 URL，改完还要重新探测库
                // 是否可用——那是表单页的职责，不是一次点击能表达的。
                onSelect: act(
                  () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => AdvancedSettingsPage(state: widget.state),
                    ),
                  ),
                ),
              ),
            ],
          ),
          PlayerMenuItem(
            id: 'settings_buttons',
            label: '控制栏按钮',
            icon: Icons.view_week_outlined,
            children: [
              // 8 项（`kPlayerButtons`）：selected = **未隐藏**。
              // 用「显示中」而不是「已隐藏」做勾选态，是因为用户找的是
              // 「这个按钮还在不在控制栏上」。
              for (final spec in kPlayerButtons)
                _settingsToggle(
                  id: 'settings_button_${spec.id}',
                  label: spec.label,
                  value: !widget.state.playerButtonHidden.contains(spec.id),
                  onChanged: (value) =>
                      _togglePlayerButtonVisible(spec.id, value),
                ),
              PlayerMenuItem(
                id: 'settings_buttons_reset',
                label: '恢复默认顺序',
                icon: Icons.restart_alt,
                // 就地执行、不关菜单：结果在控制栏上立刻可见，不需要离开画面。
                // 这里**不弹二次确认**：误点一次的代价是「回到默认」，
                // 而默认本身就是绝大多数用户的状态（表单页要求确认是因为
                // 那里会连拖动顺序一起改）。
                onSelect: _resetPlayerButtonsFromMenu,
              ),
              PlayerMenuItem(
                id: 'settings_buttons_form',
                label: '拖动排序…',
                icon: Icons.drag_indicator,
                // 顺序调整是拖拽手势，菜单里没有可表达的载体——只能跳页。
                onSelect: act(
                  () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          PlayerButtonConfigPage(state: widget.state),
                    ),
                  ),
                ),
              ),
            ],
          ),
          PlayerMenuItem(
            id: 'settings_advanced_page',
            label: '完整设置页…',
            icon: Icons.settings_outlined,
            // 兜底入口：直播源回退、广告规则、DoH、站点注入等不在本树的项，
            // 以及需要数字输入的精调（缓存上限滑杆）都在这里。
            onSelect: act(
              () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => AdvancedSettingsPage(state: widget.state),
                ),
              ),
            ),
          ),
        ],
      ),
    ];
  }

  /// 字幕样式的就地改动（右键菜单三级叶子项用）。
  ///
  /// **不落盘**：与 `_showSubtitleStyleSettings` 的「应用」同语义——
  /// `PlayerSubtitleStyle` 目前是页面级字段，没有持久化能力，这里也不假装有。
  void _applySubtitleStyle(PlayerSubtitleStyle next) {
    setState(() => _subtitleStyle = next);
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
  // 为什么**不关菜单**：这一层里有 5 个开关 + 8 个控制栏按钮，用户的真实
  // 动作是「连着改几项再对比效果」。每改一项就关菜单，等于每一项都要重新
  // 右键、重新走两三层——那正是这次要消灭的负担。

  /// 设置树里的一个开关行。
  ///
  /// 只做「布尔 → 菜单项」的形状转换，不含业务：每个开关的真实语义仍在
  /// 各自的 `onChanged` 里，读的是当前生效值（`selected` 即真相）。
  PlayerMenuItem _settingsToggle({
    required String id,
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool enabled = true,
  }) => PlayerMenuItem(
    id: id,
    label: label,
    selected: value,
    enabled: enabled,
    onSelect: () => onChanged(!value),
  );

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
    unawaited(_controller.applyPlayerOptions(normalized));
    setState(() {});
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

  /// 「自动搜索弹幕」开关：没有配置弹幕库地址时不给改（菜单行已灰）。
  void _toggleDanmakuAutoSearch(bool value) {
    final current = widget.state.danmakuSettings;
    if (!current.hasLibrary) return;
    unawaited(
      widget.state.setDanmakuSettings(current.copyWith(autoSearch: value)),
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

  Future<void> _handleDoubleTapGesture() async {
    switch (resolvePlayerGesture(doubleTap: true, fullscreen: _fullscreen)) {
      case PlayerGestureAction.enterFullscreen:
        await _toggleFullscreen();
      case PlayerGestureAction.togglePlayback:
        await _controller.playOrPause();
        _touchControls();
      case PlayerGestureAction.toggleControls:
        _toggleControlsByGesture();
    }
  }

  void _beginGestureSpeed() {
    if (_gestureRateBeforeLongPress != null) return;
    _gestureRateBeforeLongPress = _controller.rate;
    _controller.setRate(2.0);
    _touchControls();
  }

  void _endGestureSpeed() {
    final previous = _gestureRateBeforeLongPress;
    _gestureRateBeforeLongPress = null;
    if (previous != null) _controller.setRate(previous);
  }

  Future<void> _showSubtitleStyleSettings() async {
    var draft = _subtitleStyle;
    final result = await showModalBottomSheet<PlayerSubtitleStyle>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('字幕样式', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  '去除黑色字幕底框，并调整字幕位置、描边和时间偏移。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 18),
                Text('文字颜色', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  children: [
                    for (final color in const [
                      Colors.white,
                      Colors.yellow,
                      Colors.cyanAccent,
                      Colors.lightGreenAccent,
                      Colors.orangeAccent,
                      Colors.pinkAccent,
                    ])
                      InkWell(
                        onTap: () => setModalState(
                          () => draft = draft.copyWith(color: color),
                        ),
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: color,
                            border: Border.all(
                              color: draft.color == color
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.white54,
                              width: draft.color == color ? 3 : 1,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  '字幕底色（默认透明）',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Slider(
                  value: draft.backgroundOpacity,
                  min: 0,
                  max: 0.8,
                  divisions: 8,
                  label: '${(draft.backgroundOpacity * 100).round()}%',
                  onChanged: (value) => setModalState(
                    () => draft = draft.copyWith(backgroundOpacity: value),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '描边宽度 ${draft.outlineWidth.toStringAsFixed(1)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Slider(
                  value: draft.outlineWidth,
                  min: 0,
                  max: 4,
                  divisions: 8,
                  label: draft.outlineWidth.toStringAsFixed(1),
                  onChanged: (value) => setModalState(
                    () => draft = draft.copyWith(outlineWidth: value),
                  ),
                ),
                Text(
                  '字号 ${((draft.textScale) * 100).round()}%',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Slider(
                  value: draft.textScale,
                  min: 0.6,
                  max: 1.8,
                  divisions: 12,
                  label: '${(draft.textScale * 100).round()}%',
                  onChanged: (value) => setModalState(
                    () => draft = draft.copyWith(textScale: value),
                  ),
                ),
                Text(
                  '字幕位置 ${draft.bottomPadding.round()}dp',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Slider(
                  value: draft.bottomPadding,
                  min: 0,
                  max: 120,
                  divisions: 12,
                  label: '${draft.bottomPadding.round()}dp',
                  onChanged: (value) => setModalState(
                    () => draft = draft.copyWith(bottomPadding: value),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    TextButton(
                      onPressed: () => setModalState(() {
                        draft = const PlayerSubtitleStyle();
                      }),
                      child: const Text('恢复默认'),
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(draft),
                      child: const Text('应用'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _subtitleStyle = result);
  }

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
              ...playerShortcuts,
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