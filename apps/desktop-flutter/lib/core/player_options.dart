/// 播放参数与失败回退策略（`docs/phase9/design/01` §5）。
///
/// 纯数据 + 校验：不碰播放器、不读磁盘。播放器只消费 [mpvProperties] 与
/// [failureFallback]；设置页只消费 `toJson`/`fromJson`。
///
/// 缺省值**必须等价于当前行为**：缓存开、硬解自动、自动连播开、回退到线路。
/// 唯一的例外是 [longPressSpeed]：2026-11 起默认 3×（此前写死 2×），这是需求方
/// 明确要的默认值变更，不是漏改。
library;

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

/// 播放器参数。
class PlayerOptions {
  const PlayerOptions({
    this.hardwareDecoding = true,
    this.cache = true,
    this.demuxerMaxBytesMiB = defaultDemuxerMaxMiB,
    this.demuxerMaxBackBytesMiB = defaultDemuxerBackMiB,
    this.audioPassthrough = false,
    this.autoNext = true,
    this.failureFallback = PlayerFailureFallback.line,
    this.preloadNext = false,
    this.autoSkipIntro = false,
    this.autoSkipOutro = false,
    this.longPressSpeed = defaultLongPressSpeed,
    this.lutPath = '',
  });

  /// 默认值：与 Phase 0–8 的行为一致（唯一例外见 [longPressSpeed]：默认 3×）。
  const PlayerOptions.defaults() : this();

  static const int defaultDemuxerMaxMiB = 256;
  static const int defaultDemuxerBackMiB = 64;
  static const int minDemuxerMaxMiB = 16;
  static const int maxDemuxerMaxMiB = 2048;
  static const int minDemuxerBackMiB = 8;
  static const int maxDemuxerBackMiB = 512;

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

  /// 前向 demuxer 缓存上限（MiB）。
  final int demuxerMaxBytesMiB;

  /// 回看缓存上限（MiB）。
  final int demuxerMaxBackBytesMiB;

  /// 音频直通（`audio-spdif`）。桌面默认关闭：直通需要接收端支持。
  final bool audioPassthrough;

  /// 真正播完后是否自动进下一集（`PlaybackRepeat.off` 时生效）。
  final bool autoNext;

  /// 失败回退阶梯。
  final PlayerFailureFallback failureFallback;

  /// 是否预解析下一集地址（**不下载媒体数据**）。
  final bool preloadNext;

  /// 自动跳过片头/片尾（标记见 `SkipSegments`）。
  final bool autoSkipIntro;
  final bool autoSkipOutro;

  /// 长按画面期间的临时倍速（松开恢复原速）。见 [defaultLongPressSpeed]。
  final double longPressSpeed;

  /// 选中的 LUT 文件路径；空串表示未启用。
  final String lutPath;

  bool get hasLut => lutPath.trim().isNotEmpty;

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
        ? longPressSpeed
              .clamp(minLongPressSpeed, maxLongPressSpeed)
              .toDouble()
        : defaultLongPressSpeed;

    return PlayerOptions(
      hardwareDecoding: hardwareDecoding,
      cache: cache,
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
      autoNext: autoNext,
      failureFallback: failureFallback,
      preloadNext: preloadNext,
      autoSkipIntro: autoSkipIntro,
      autoSkipOutro: autoSkipOutro,
      longPressSpeed: speed,
      lutPath: lutPath.trim(),
    );
  }

  /// 要注入 mpv 的属性。空值/默认项也写：保证切换设置后不回落到引擎旧值。
  Map<String, String> get mpvProperties => <String, String>{
    'hwdec': hardwareDecoding ? 'auto-safe' : 'no',
    'cache': cache ? 'yes' : 'no',
    'demuxer-max-bytes': '${demuxerMaxBytesMiB * 1024 * 1024}',
    'demuxer-max-back-bytes': '${demuxerMaxBackBytesMiB * 1024 * 1024}',
    'audio-spdif': audioPassthrough ? 'ac3,eac3,dts' : '',
  };

  PlayerOptions copyWith({
    bool? hardwareDecoding,
    bool? cache,
    int? demuxerMaxBytesMiB,
    int? demuxerMaxBackBytesMiB,
    bool? audioPassthrough,
    bool? autoNext,
    PlayerFailureFallback? failureFallback,
    bool? preloadNext,
    bool? autoSkipIntro,
    bool? autoSkipOutro,
    double? longPressSpeed,
    String? lutPath,
  }) => PlayerOptions(
    hardwareDecoding: hardwareDecoding ?? this.hardwareDecoding,
    cache: cache ?? this.cache,
    demuxerMaxBytesMiB: demuxerMaxBytesMiB ?? this.demuxerMaxBytesMiB,
    demuxerMaxBackBytesMiB:
        demuxerMaxBackBytesMiB ?? this.demuxerMaxBackBytesMiB,
    audioPassthrough: audioPassthrough ?? this.audioPassthrough,
    autoNext: autoNext ?? this.autoNext,
    failureFallback: failureFallback ?? this.failureFallback,
    preloadNext: preloadNext ?? this.preloadNext,
    autoSkipIntro: autoSkipIntro ?? this.autoSkipIntro,
    autoSkipOutro: autoSkipOutro ?? this.autoSkipOutro,
    longPressSpeed: longPressSpeed ?? this.longPressSpeed,
    lutPath: lutPath ?? this.lutPath,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'hardwareDecoding': hardwareDecoding,
    'cache': cache,
    'demuxerMaxBytesMiB': demuxerMaxBytesMiB,
    'demuxerMaxBackBytesMiB': demuxerMaxBackBytesMiB,
    'audioPassthrough': audioPassthrough,
    'autoNext': autoNext,
    'failureFallback': failureFallback.id,
    'preloadNext': preloadNext,
    'autoSkipIntro': autoSkipIntro,
    'autoSkipOutro': autoSkipOutro,
    'longPressSpeed': longPressSpeed,
    'lutPath': lutPath,
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

    return PlayerOptions(
      hardwareDecoding: boolOf('hardwareDecoding', true),
      cache: boolOf('cache', true),
      demuxerMaxBytesMiB: intOf('demuxerMaxBytesMiB', defaultDemuxerMaxMiB),
      demuxerMaxBackBytesMiB: intOf(
        'demuxerMaxBackBytesMiB',
        defaultDemuxerBackMiB,
      ),
      audioPassthrough: boolOf('audioPassthrough', false),
      autoNext: boolOf('autoNext', true),
      failureFallback: PlayerFailureFallback.fromId(map['failureFallback']),
      preloadNext: boolOf('preloadNext', false),
      autoSkipIntro: boolOf('autoSkipIntro', false),
      autoSkipOutro: boolOf('autoSkipOutro', false),
      longPressSpeed: doubleOf('longPressSpeed', defaultLongPressSpeed),
      lutPath: map['lutPath'] is String ? (map['lutPath'] as String).trim() : '',
    ).normalized();
  }

  @override
  bool operator ==(Object other) =>
      other is PlayerOptions &&
      other.hardwareDecoding == hardwareDecoding &&
      other.cache == cache &&
      other.demuxerMaxBytesMiB == demuxerMaxBytesMiB &&
      other.demuxerMaxBackBytesMiB == demuxerMaxBackBytesMiB &&
      other.audioPassthrough == audioPassthrough &&
      other.autoNext == autoNext &&
      other.failureFallback == failureFallback &&
      other.preloadNext == preloadNext &&
      other.autoSkipIntro == autoSkipIntro &&
      other.autoSkipOutro == autoSkipOutro &&
      other.longPressSpeed == longPressSpeed &&
      other.lutPath == lutPath;

  @override
  int get hashCode => Object.hash(
    hardwareDecoding,
    cache,
    demuxerMaxBytesMiB,
    demuxerMaxBackBytesMiB,
    audioPassthrough,
    autoNext,
    failureFallback,
    preloadNext,
    autoSkipIntro,
    autoSkipOutro,
    longPressSpeed,
    lutPath,
  );

  @override
  String toString() =>
      'PlayerOptions(hwdec=$hardwareDecoding cache=$cache '
      'max=${demuxerMaxBytesMiB}MiB back=${demuxerMaxBackBytesMiB}MiB '
      'spdif=$audioPassthrough autoNext=$autoNext ${failureFallback.id} '
      'preload=$preloadNext skip=$autoSkipIntro/$autoSkipOutro '
      'speed=$longPressSpeed lut="${lutPath.isEmpty ? '' : 'set'}")';
}
