/// 播放参数与失败回退策略（`docs/phase9/design/01` §5）。
///
/// 纯数据 + 校验：不碰播放器、不读磁盘。播放器消费播放参数与手势选项；
/// 设置持久化消费 `toJson`/`fromJson`。
///
/// 缺省值**必须等价于当前行为**：缓存开、硬解自动、自动连播开、回退到线路。
/// 唯一的例外是 [longPressSpeed]：2026-11 起默认 3×（此前写死 2×），这是需求方
/// 明确要的默认值变更，不是漏改。
library;

import 'mpv_properties.dart';
import 'skip_plan.dart';

/// 失败回退阶梯。
enum PlayerFailureFallback {
  /// 不自动回退，直接把错误交给 UI。
  off('off', '不自动回退'),

  /// 只切当前线路内的下一个地址。
  line('line', '只切线路'),

  /// 线路失败后再试下一个解析接口。
  lineAndParse('line_parse', '线路 → 解析接口'),

  /// 线路、解析都失败后再尝试换源。
  lineAndParseAndSource('line_parse_source', '线路 → 解析 → 换源');

  const PlayerFailureFallback(this.id, this.label);

  /// 落盘标识，**不得改名**。
  final String id;

  final String label;

  static PlayerFailureFallback fromId(Object? raw) {
    final value = raw is String ? raw.trim().toLowerCase() : '';
    for (final item in values) {
      if (item.id == value) return item;
    }
    return PlayerFailureFallback.line;
  }

  bool get allowsParse => this == lineAndParse || this == lineAndParseAndSource;

  bool get allowsSource => this == lineAndParseAndSource;
}

/// HDR 色调映射算法（mpv `tone-mapping`）。
///
/// 只在「片源是 HDR、显示端只能吃 SDR」时起作用：把高动态范围压回可用亮度。
/// [auto] 是 mpv 默认，等价于改造前的行为。
enum HdrToneMapping {
  auto('auto', '自动（跟随内核）'),
  bt2390('bt.2390', 'BT.2390'),
  spline('spline', 'Spline'),
  mobius('mobius', 'Mobius'),
  reinhard('reinhard', 'Reinhard'),
  clip('clip', 'Clip（直接裁剪）');

  const HdrToneMapping(this.id, this.label);

  /// 落盘标识，**不得改名**；同时就是 mpv 的取值。
  final String id;

  final String label;

  /// 注入 mpv 的取值。
  String get mpvValue => id;

  static HdrToneMapping fromId(Object? raw) {
    final value = raw is String ? raw.trim().toLowerCase() : '';
    for (final item in values) {
      if (item.id == value) return item;
    }
    return HdrToneMapping.auto;
  }
}

/// 峰值亮度计算（mpv `hdr-compute-peak`）。
///
/// [auto] 是 mpv 默认（内核按输出后端决定），因此默认值不改变既有行为。
enum HdrPeakCompute {
  auto('auto', 'auto', '自动（跟随内核）'),
  on('on', 'yes', '按帧计算（更亮，更吃性能）'),
  off('off', 'no', '不计算（按元数据静态压缩）');

  const HdrPeakCompute(this.id, this.mpvValue, this.label);

  /// 落盘标识，**不得改名**。
  final String id;

  /// 注入 mpv 的取值：`auto` / `yes` / `no`。
  final String mpvValue;

  final String label;

  static HdrPeakCompute fromId(Object? raw) {
    final value = raw is String ? raw.trim().toLowerCase() : '';
    for (final item in values) {
      if (item.id == value) return item;
    }
    return HdrPeakCompute.auto;
  }
}

/// 画面左右半屏各自的双击动作；默认保持只切换全屏。
enum PlayerDoubleClickAction {
  toggleFullscreen('toggleFullscreen', '切换全屏'),
  togglePlayback('togglePlayback', '播放 / 暂停'),
  seekBackward('seekBackward', '快退'),
  seekForward('seekForward', '快进'),
  volumeUp('volumeUp', '音量增加'),
  volumeDown('volumeDown', '音量减少'),
  none('none', '无动作');

  const PlayerDoubleClickAction(this.id, this.label);

  final String id;
  final String label;

  bool get isSeek => this == seekBackward || this == seekForward;

  static PlayerDoubleClickAction fromId(Object? raw) {
    final value = raw is String ? raw.trim().toLowerCase() : '';
    for (final item in values) {
      if (item.id.toLowerCase() == value) return item;
    }
    return toggleFullscreen;
  }
}

/// 播放器参数。
class PlayerOptions {
  const PlayerOptions({
    this.hardwareDecoding = true,
    this.cache = true,
    this.showThumbnailPreview = false,
    this.dragPause = true,
    this.demuxerMaxBytesMiB = defaultDemuxerMaxMiB,
    this.demuxerMaxBackBytesMiB = defaultDemuxerBackMiB,
    this.audioPassthrough = false,
    this.audioNormalization = false,
    this.toneMapping = HdrToneMapping.auto,
    this.hdrPeakCompute = HdrPeakCompute.auto,
    this.autoNext = true,
    this.failureFallback = PlayerFailureFallback.line,
    this.preloadNext = false,
    SkipMode skipMode = SkipMode.off,
    int skipKinds = SkipKindBits.defaults,
    this.skipRemoteEnabled = true,
    this.skipSources = defaultSkipSources,
    bool? autoSkipIntro,
    bool? autoSkipOutro,
    this.longPressSpeed = defaultLongPressSpeed,
    this.doubleClickLeft = PlayerDoubleClickAction.toggleFullscreen,
    this.doubleClickRight = PlayerDoubleClickAction.toggleFullscreen,
    this.lutPath = '',
    this.lutPresetId = '',
  }) : skipMode = autoSkipIntro == true || autoSkipOutro == true
           ? (skipMode == SkipMode.off ? SkipMode.auto : skipMode)
           : skipMode,
       // 旧参数的翻译：true 置位，false 清位，两者都没传时保留 skipKinds。
       skipKinds =
           (skipKinds |
               (autoSkipIntro == true ? SkipKindBits.intro : 0) |
               (autoSkipOutro == true ? SkipKindBits.outro : 0)) &
           ~((autoSkipIntro == false ? SkipKindBits.intro : 0) |
               (autoSkipOutro == false ? SkipKindBits.outro : 0));

  /// 默认值：与 Phase 0–8 的行为一致（唯一例外见 [longPressSpeed]：默认 3×）。
  const PlayerOptions.defaults() : this();

  static const int defaultDemuxerMaxMiB = 256;
  static const int defaultDemuxerBackMiB = 64;
  static const int minDemuxerMaxMiB = 16;
  static const int maxDemuxerMaxMiB = 2048;
  static const int minDemuxerBackMiB = 8;
  static const int maxDemuxerBackMiB = 512;

  /// 远端标定默认全开（IntroDB / TheIntroDB / TODB）。
  static const int defaultSkipSources = SkipSourceBits.defaults;

  /// 长按画面期间的临时倍速（松开恢复）的默认值与合法区间。
  ///
  /// 2026-11 起可配置；默认 3×（此前在 `_beginGestureSpeed` 里写死 2×）。
  /// 只影响长按手势，不改变正常播放速率，也不写 mpv 属性。
  static const double defaultLongPressSpeed = 3;
  static const double minLongPressSpeed = 2;
  static const double maxLongPressSpeed = 4;

  /// 设置页与右键菜单提供的常用档位（区间内还允许手改成别的值，见 [normalized]）。
  static const List<double> longPressSpeedChoices = [2, 2.5, 3, 4];

  /// `hwdec=auto-safe`；关闭时 `no`。
  final bool hardwareDecoding;

  /// mpv `cache=yes/no`。
  final bool cache;

  /// 导航栏缩略图预览；默认关闭，开启可能增加网络请求。
  final bool showThumbnailPreview;

  /// 拖动进度条时先暂停，松手按拖动前的状态续播。
  ///
  /// 默认开：网络流每拖一格就 seek 一次，边播边丢缓冲会让拖动变成"拖不动"，
  /// 而且用户看不出松手后是继续播还是停住。关掉等于回到今天的手感（拖动中
  /// 继续播），只在本地文件、或者想边拖边看画面时才值得关。
  final bool dragPause;

  /// 前向 demuxer 缓存上限（MiB）。
  final int demuxerMaxBytesMiB;

  /// 回看缓存上限（MiB）。
  final int demuxerMaxBackBytesMiB;

  /// 音频直通（`audio-spdif`）。桌面默认关闭：直通需要接收端支持。
  final bool audioPassthrough;

  /// 全局实时音量归一（`af=dynaudnorm`，见 [audioNormalizationAf]）。
  /// 默认关闭，不改变音量偏好。
  final bool audioNormalization;

  /// HDR 色调映射算法（`tone-mapping`）。默认跟随内核。
  final HdrToneMapping toneMapping;

  /// 峰值亮度计算（`hdr-compute-peak`）。默认跟随内核。
  final HdrPeakCompute hdrPeakCompute;

  /// 真正播完后是否自动进下一集（`PlaybackRepeat.off` 时生效）。
  final bool autoNext;

  /// 失败回退阶梯。
  final PlayerFailureFallback failureFallback;

  /// 是否预解析下一集地址（**不下载媒体数据**）。
  final bool preloadNext;

  /// 跳过模式：关、静默跳、跳前询问（见 [SkipMode]）。
  final SkipMode skipMode;

  /// 允许自动跳过的片段类型位图（见 [SkipKindBits]）。
  final int skipKinds;

  /// 是否向远端数据源查询片头/片尾时间轴。
  final bool skipRemoteEnabled;

  /// 启用的远端数据源位图（见 [SkipSourceBits]）。
  final int skipSources;

  /// 旧字段的派生态：模式开着且类型位包含片头。
  bool get autoSkipIntro =>
      skipMode != SkipMode.off && (skipKinds & SkipKindBits.intro) != 0;

  /// 旧字段的派生态：模式开着且类型位包含片尾。
  bool get autoSkipOutro =>
      skipMode != SkipMode.off && (skipKinds & SkipKindBits.outro) != 0;

  /// 长按画面期间的临时倍速（松开恢复原速）。见 [defaultLongPressSpeed]。
  final double longPressSpeed;

  final PlayerDoubleClickAction doubleClickLeft;
  final PlayerDoubleClickAction doubleClickRight;

  /// 选中的 LUT 文件路径；空串表示未启用。
  final String lutPath;

  bool get hasLut => lutPath.trim().isNotEmpty;

  /// 选中的内置预设 id（`builtinLutPresets` 里的一项）；空串表示选的是用户文件或未选。
  ///
  /// 它**不参与**播放：mpv 注入只看 [lutPath]。存它是为了让界面在缓存被清理、
  /// 或换了机器之后仍知道「当前是哪一档」，并按 id 重新落盘。
  final String lutPresetId;

  /// 夹到合法区间并在类型异常时回落默认。
  PlayerOptions normalized() {
    int clamp(int value, int min, int max, int fallback) {
      if (value < min || value > max) {
        if (value < min) return min;
        if (value > max) return max;
        return fallback;
      }
      return value;
    }

    // 非有限值（NaN/Infinity）没有"夹"的意义，直接回落默认。
    final speed = longPressSpeed.isFinite
        ? longPressSpeed.clamp(minLongPressSpeed, maxLongPressSpeed).toDouble()
        : defaultLongPressSpeed;

    return PlayerOptions(
      hardwareDecoding: hardwareDecoding,
      cache: cache,
      showThumbnailPreview: showThumbnailPreview,
      dragPause: dragPause,
      demuxerMaxBytesMiB: clamp(
        demuxerMaxBytesMiB,
        minDemuxerMaxMiB,
        maxDemuxerMaxMiB,
        defaultDemuxerMaxMiB,
      ),
      demuxerMaxBackBytesMiB: clamp(
        demuxerMaxBackBytesMiB,
        minDemuxerBackMiB,
        maxDemuxerBackMiB,
        defaultDemuxerBackMiB,
      ),
      audioPassthrough: audioPassthrough,
      audioNormalization: audioNormalization,
      toneMapping: toneMapping,
      hdrPeakCompute: hdrPeakCompute,
      autoNext: autoNext,
      failureFallback: failureFallback,
      preloadNext: preloadNext,
      skipMode: skipMode,
      skipKinds: clamp(
        skipKinds,
        SkipKindBits.none,
        SkipKindBits.all,
        SkipKindBits.defaults,
      ),
      skipRemoteEnabled: skipRemoteEnabled,
      // 上界是「全部已知源位」，不是「出厂默认源位」：新增第 4 个源时
      // [SkipSourceBits.allBits] 会跟着长，[SkipSourceBits.defaults] 不会。
      skipSources: clamp(
        skipSources,
        SkipSourceBits.none,
        SkipSourceBits.allBits,
        SkipSourceBits.defaults,
      ),
      longPressSpeed: speed,
      doubleClickLeft: doubleClickLeft,
      doubleClickRight: doubleClickRight,
      lutPath: lutPath.trim(),
      lutPresetId: lutPresetId.trim(),
    );
  }

  /// 要注入 mpv 的属性。空值/默认项也写：保证切换设置后不回落到引擎旧值。
  Map<String, String> get mpvProperties => <String, String>{
    'hwdec': hardwareDecoding ? 'auto-safe' : 'no',
    'cache': cache ? 'yes' : 'no',
    'demuxer-max-bytes': '${demuxerMaxBytesMiB * 1024 * 1024}',
    'demuxer-max-back-bytes': '${demuxerMaxBackBytesMiB * 1024 * 1024}',
    'audio-spdif': audioPassthrough ? 'ac3,eac3,dts' : '',
    'af': audioNormalization ? audioNormalizationAf : '',
    'tone-mapping': toneMapping.mpvValue,
    'hdr-compute-peak': hdrPeakCompute.mpvValue,
  };

  PlayerOptions copyWith({
    bool? hardwareDecoding,
    bool? cache,
    bool? showThumbnailPreview,
    bool? dragPause,
    int? demuxerMaxBytesMiB,
    int? demuxerMaxBackBytesMiB,
    bool? audioPassthrough,
    bool? audioNormalization,
    HdrToneMapping? toneMapping,
    HdrPeakCompute? hdrPeakCompute,
    bool? autoNext,
    PlayerFailureFallback? failureFallback,
    bool? preloadNext,
    SkipMode? skipMode,
    int? skipKinds,
    bool? skipRemoteEnabled,
    int? skipSources,
    bool? autoSkipIntro,
    bool? autoSkipOutro,
    double? longPressSpeed,
    PlayerDoubleClickAction? doubleClickLeft,
    PlayerDoubleClickAction? doubleClickRight,
    String? lutPath,
    String? lutPresetId,
  }) => PlayerOptions(
    hardwareDecoding: hardwareDecoding ?? this.hardwareDecoding,
    cache: cache ?? this.cache,
    showThumbnailPreview: showThumbnailPreview ?? this.showThumbnailPreview,
    dragPause: dragPause ?? this.dragPause,
    demuxerMaxBytesMiB: demuxerMaxBytesMiB ?? this.demuxerMaxBytesMiB,
    demuxerMaxBackBytesMiB:
        demuxerMaxBackBytesMiB ?? this.demuxerMaxBackBytesMiB,
    audioPassthrough: audioPassthrough ?? this.audioPassthrough,
    audioNormalization: audioNormalization ?? this.audioNormalization,
    toneMapping: toneMapping ?? this.toneMapping,
    hdrPeakCompute: hdrPeakCompute ?? this.hdrPeakCompute,
    autoNext: autoNext ?? this.autoNext,
    failureFallback: failureFallback ?? this.failureFallback,
    preloadNext: preloadNext ?? this.preloadNext,
    skipMode: skipMode ?? this.skipMode,
    skipKinds: skipKinds ?? this.skipKinds,
    skipRemoteEnabled: skipRemoteEnabled ?? this.skipRemoteEnabled,
    skipSources: skipSources ?? this.skipSources,
    autoSkipIntro: autoSkipIntro,
    autoSkipOutro: autoSkipOutro,
    longPressSpeed: longPressSpeed ?? this.longPressSpeed,
    doubleClickLeft: doubleClickLeft ?? this.doubleClickLeft,
    doubleClickRight: doubleClickRight ?? this.doubleClickRight,
    lutPath: lutPath ?? this.lutPath,
    lutPresetId: lutPresetId ?? this.lutPresetId,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'hardwareDecoding': hardwareDecoding,
    'cache': cache,
    'showThumbnailPreview': showThumbnailPreview,
    'dragPause': dragPause,
    'demuxerMaxBytesMiB': demuxerMaxBytesMiB,
    'demuxerMaxBackBytesMiB': demuxerMaxBackBytesMiB,
    'audioPassthrough': audioPassthrough,
    'audioNormalization': audioNormalization,
    'toneMapping': toneMapping.id,
    'hdrPeakCompute': hdrPeakCompute.id,
    'autoNext': autoNext,
    'failureFallback': failureFallback.id,
    'preloadNext': preloadNext,
    'skipMode': skipMode.name,
    'skipKinds': skipKinds,
    'skipRemoteEnabled': skipRemoteEnabled,
    'skipSources': skipSources,
    // 旧键照写派生值：老版本读新配置时仍能认出「跳过片头/片尾」。
    'autoSkipIntro': autoSkipIntro,
    'autoSkipOutro': autoSkipOutro,
    'longPressSpeed': longPressSpeed,
    'doubleClickLeft': doubleClickLeft.id,
    'doubleClickRight': doubleClickRight.id,
    'lutPath': lutPath,
    'lutPresetId': lutPresetId,
  };

  /// 宽松解析：任何缺失/非法字段回落默认，**不抛异常**（设置文件可能被手改）。
  factory PlayerOptions.fromJson(Object? raw) {
    final map = raw is Map ? raw : const {};
    bool boolOf(String key, bool fallback) {
      final value = map[key];
      return value is bool ? value : fallback;
    }

    int intOf(String key, int fallback) {
      final value = map[key];
      return value is num ? value.toInt() : fallback;
    }

    double doubleOf(String key, double fallback) {
      final value = map[key];
      return value is num && value.isFinite ? value.toDouble() : fallback;
    }

    // 片头/片尾：新键优先；只有旧布尔键时按旧语义折成「模式 + 类型位」。
    //
    // 旧配置里没有任何「回顾」信息，所以迁移只能还原用户真开过的那两类；两个
    // 都为 false（等于从没用过这功能）时回落到出厂默认，而不是留下一张空表——
    // 否则用户日后打开「自动跳过」会发现片头片尾都不跳。
    final hasSkipMode = map.containsKey('skipMode');
    final hasLegacySkip =
        map.containsKey('autoSkipIntro') || map.containsKey('autoSkipOutro');
    final legacyIntro = boolOf('autoSkipIntro', false);
    final legacyOutro = boolOf('autoSkipOutro', false);
    final legacyKinds =
        (legacyIntro ? SkipKindBits.intro : 0) |
        (legacyOutro ? SkipKindBits.outro : 0);

    return PlayerOptions(
      hardwareDecoding: boolOf('hardwareDecoding', true),
      cache: boolOf('cache', true),
      showThumbnailPreview: boolOf('showThumbnailPreview', false),
      // 旧 settings.json 里没有这个键：缺键即默认开（不是"缺键即关"）。
      dragPause: boolOf('dragPause', true),
      demuxerMaxBytesMiB: intOf('demuxerMaxBytesMiB', defaultDemuxerMaxMiB),
      demuxerMaxBackBytesMiB: intOf(
        'demuxerMaxBackBytesMiB',
        defaultDemuxerBackMiB,
      ),
      audioPassthrough: boolOf('audioPassthrough', false),
      audioNormalization: boolOf('audioNormalization', false),
      toneMapping: HdrToneMapping.fromId(map['toneMapping']),
      hdrPeakCompute: HdrPeakCompute.fromId(map['hdrPeakCompute']),
      autoNext: boolOf('autoNext', true),
      failureFallback: PlayerFailureFallback.fromId(map['failureFallback']),
      preloadNext: boolOf('preloadNext', false),
      skipMode: hasSkipMode
          ? SkipMode.fromName(map['skipMode'])
          : (legacyIntro || legacyOutro ? SkipMode.auto : SkipMode.off),
      skipKinds: hasSkipMode || !hasLegacySkip
          ? intOf('skipKinds', SkipKindBits.defaults)
          : (legacyKinds == 0 ? SkipKindBits.defaults : legacyKinds),
      skipRemoteEnabled: boolOf('skipRemoteEnabled', true),
      skipSources: intOf('skipSources', defaultSkipSources),
      longPressSpeed: doubleOf('longPressSpeed', defaultLongPressSpeed),
      doubleClickLeft: PlayerDoubleClickAction.fromId(map['doubleClickLeft']),
      doubleClickRight: PlayerDoubleClickAction.fromId(map['doubleClickRight']),
      lutPath: map['lutPath'] is String
          ? (map['lutPath'] as String).trim()
          : '',
      lutPresetId: map['lutPresetId'] is String
          ? (map['lutPresetId'] as String).trim()
          : '',
    ).normalized();
  }

  @override
  bool operator ==(Object other) =>
      other is PlayerOptions &&
      other.hardwareDecoding == hardwareDecoding &&
      other.cache == cache &&
      other.showThumbnailPreview == showThumbnailPreview &&
      other.dragPause == dragPause &&
      other.demuxerMaxBytesMiB == demuxerMaxBytesMiB &&
      other.demuxerMaxBackBytesMiB == demuxerMaxBackBytesMiB &&
      other.audioPassthrough == audioPassthrough &&
      other.audioNormalization == audioNormalization &&
      other.toneMapping == toneMapping &&
      other.hdrPeakCompute == hdrPeakCompute &&
      other.autoNext == autoNext &&
      other.failureFallback == failureFallback &&
      other.preloadNext == preloadNext &&
      other.skipMode == skipMode &&
      other.skipKinds == skipKinds &&
      other.skipRemoteEnabled == skipRemoteEnabled &&
      other.skipSources == skipSources &&
      other.longPressSpeed == longPressSpeed &&
      other.doubleClickLeft == doubleClickLeft &&
      other.doubleClickRight == doubleClickRight &&
      other.lutPath == lutPath &&
      other.lutPresetId == lutPresetId;

  @override
  int get hashCode => Object.hashAll([
    hardwareDecoding,
    cache,
    showThumbnailPreview,
    dragPause,
    demuxerMaxBytesMiB,
    demuxerMaxBackBytesMiB,
    audioPassthrough,
    audioNormalization,
    toneMapping,
    hdrPeakCompute,
    autoNext,
    failureFallback,
    preloadNext,
    skipMode,
    skipKinds,
    skipRemoteEnabled,
    skipSources,
    longPressSpeed,
    doubleClickLeft,
    doubleClickRight,
    lutPath,
    lutPresetId,
  ]);

  @override
  String toString() =>
      'PlayerOptions(hwdec=$hardwareDecoding cache=$cache '
      'max=${demuxerMaxBytesMiB}MiB back=${demuxerMaxBackBytesMiB}MiB '
      'spdif=$audioPassthrough normalizer=$audioNormalization '
      'tone=${toneMapping.id} '
      'peak=${hdrPeakCompute.id} autoNext=$autoNext ${failureFallback.id} '
      'preload=$preloadNext skip=${skipMode.name} kinds=$skipKinds '
      'src=$skipSources remote=$skipRemoteEnabled '
      'speed=$longPressSpeed lut="${lutPath.isEmpty ? '' : 'set'}")';
}
