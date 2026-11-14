/// 播放诊断（设计文档 §10.4、§23 Phase 3「播放诊断能输出引擎、格式、网络和错误」）。
///
/// 这是**纯数据 + 纯函数**层：把一次播放的可定位事实（引擎、媒体格式、网络
/// 目标、错误分类与用户提示、阶段时序）收敛成一个可序列化的诊断对象，
/// 不依赖 Flutter 与播放器实现，便于单元测试与日志页展示。
///
/// 设计约束：
/// - 敏感信息必须脱敏：地址经 [redactUrl]（去掉 query/片段）、Header 经
///   [redactHeadersForLog]（Cookie/Authorization 等替换为 `<redacted>`）；
/// - 诊断不得成为播放阻断项：任何字段缺失都降级为「未知」，不抛异常；
/// - 阶段时序用「阶段 + 相对耗时」表达，用于区分「加载慢」与「首帧慢」。
library;

import 'protocol.dart';

/// 播放引擎标识（首版只有 media-kit，字段为后续兼容保留）。
abstract final class PlaybackEngine {
  static const String mediaKit = 'media-kit/mpv';

  /// 引擎在用户可见文案中的展示名。
  static const Map<String, String> displayNames = {
    mediaKit: 'media-kit (libmpv)',
  };

  static String displayName(String engine) =>
      displayNames[engine] ?? engine;
}

/// 媒体格式分类（§12.2「识别媒体 URL」）。
enum MediaFormat {
  hls('HLS (m3u8)'),
  dash('DASH (mpd)'),
  mp4('MP4'),
  flv('FLV'),
  rtsp('RTSP'),
  rtmp('RTMP'),
  audio('音频'),
  file('本地文件'),
  unknown('未知');

  const MediaFormat(this.label);

  final String label;
}

/// 从地址推断媒体格式（按扩展名与 schema，§12.2）。
///
/// 只做保守推断：无法确定时返回 [MediaFormat.unknown]，不猜测。
MediaFormat detectMediaFormat(String? url) {
  final text = (url ?? '').trim();
  if (text.isEmpty) return MediaFormat.unknown;

  final uri = Uri.tryParse(text);
  final scheme = uri?.scheme.toLowerCase() ?? '';
  if (scheme == 'file') return MediaFormat.file;
  if (scheme == 'rtsp') return MediaFormat.rtsp;
  if (scheme == 'rtmp' || scheme == 'rtmps') return MediaFormat.rtmp;

  // 取路径部分（无 scheme 时用原文），并去掉代理 base64 编码路径的干扰：
  // 本地代理形态 `/p/<token>/<base64url>` 里的目标已编码，此处按扩展名兜底。
  final path = (uri?.path ?? text).toLowerCase();
  final withoutQuery = path.split('?').first;

  if (withoutQuery.endsWith('.m3u8') || withoutQuery.contains('.m3u8')) {
    return MediaFormat.hls;
  }
  if (withoutQuery.endsWith('.mpd')) return MediaFormat.dash;
  if (withoutQuery.endsWith('.mp4') ||
      withoutQuery.endsWith('.mkv') ||
      withoutQuery.endsWith('.mov') ||
      withoutQuery.endsWith('.webm')) {
    return MediaFormat.mp4;
  }
  if (withoutQuery.endsWith('.flv')) return MediaFormat.flv;
  if (withoutQuery.endsWith('.mp3') ||
      withoutQuery.endsWith('.m4a') ||
      withoutQuery.endsWith('.aac') ||
      withoutQuery.endsWith('.flac') ||
      withoutQuery.endsWith('.wav')) {
    return MediaFormat.audio;
  }
  return MediaFormat.unknown;
}

/// 网络目标概要：只保留脱敏地址与主机，用于定位 DNS/代理问题而不泄露签名。
class NetworkTarget {
  const NetworkTarget({required this.host, required this.scheme, required this.redactedUrl});

  final String host;
  final String scheme;
  final String redactedUrl;

  static NetworkTarget of(String? url) {
    final text = (url ?? '').trim();
    if (text.isEmpty) {
      return const NetworkTarget(host: '', scheme: '', redactedUrl: '');
    }
    final uri = Uri.tryParse(text);
    return NetworkTarget(
      host: uri?.host ?? '',
      scheme: uri?.scheme.toLowerCase() ?? '',
      redactedUrl: redactUrl(text),
    );
  }

  bool get isSecure => scheme == 'https' || scheme == 'rtmps';

  Map<String, Object?> toJson() => {
    'host': host,
    'scheme': scheme,
    'url': redactedUrl,
  };
}

/// 播放阶段（用于时序归因）。
enum PlaybackStage {
  decision('播放决策'),
  load('媒体加载'),
  firstFrame('首帧呈现'),
  playing('播放中'),
  retry('重试'),
  lineFallback('线路回退'),
  failed('失败');

  const PlaybackStage(this.label);

  final String label;
}

/// 一次阶段耗时记录。
class StageTiming {
  const StageTiming({
    required this.stage,
    required this.elapsed,
    this.note,
  });

  final PlaybackStage stage;
  final Duration elapsed;
  final String? note;

  Map<String, Object?> toJson() => {
    'stage': stage.name,
    'label': stage.label,
    'elapsedMs': elapsed.inMilliseconds,
    if (note != null) 'note': note,
  };
}

/// 一次播放的完整诊断快照（§23 要求包含引擎、格式、网络、错误）。
class PlaybackDiagnostics {
  PlaybackDiagnostics({
    required this.engine,
    required this.format,
    required this.target,
    required this.timings,
    this.siteKey,
    this.flag,
    this.episodeName,
    this.enterUrl,
    this.finalUrl,
    Map<String, String> requestedHeaders = const {},
    this.succeeded,
    this.failureKind,
    this.failureMessage,
    this.failureHint,
    this.completedAt,
  }) : requestedHeaders = Map.unmodifiable(requestedHeaders);

  /// 引擎标识（[PlaybackEngine]）。
  final String engine;

  /// 媒体格式（[detectMediaFormat]）。
  final MediaFormat format;

  /// 网络目标（脱敏）。
  final NetworkTarget target;

  /// 阶段时序（按发生顺序）。
  final List<StageTiming> timings;

  final String? siteKey;
  final String? flag;
  final String? episodeName;

  /// 站点给出的原始剧集目标（脱敏）。
  final String? enterUrl;

  /// 最终交给播放器的地址（脱敏）。
  final String? finalUrl;

  /// 本次播放请求注入的 Header（已脱敏，仅键值摘要）。
  final Map<String, String> requestedHeaders;

  /// 最终结果：null 表示仍在进行中。
  final bool? succeeded;

  /// 失败分类（§10.4）。
  final Object? failureKind;

  /// 引擎原始错误文本（截断后保留，供排查）。
  final String? failureMessage;

  /// 面向用户的失败提示（§10.4 策略文案）。
  final String? failureHint;

  final DateTime? completedAt;

  /// 是否可用媒体格式（未知格式仍尝试播放，但诊断标注）。
  bool get hasKnownFormat => format != MediaFormat.unknown;

  /// 阶段耗时查找（同阶段可能出现多次，取最后一次）。
  Duration? elapsedOf(PlaybackStage stage) {
    for (final timing in timings.reversed) {
      if (timing.stage == stage) return timing.elapsed;
    }
    return null;
  }

  /// 面向日志的单行摘要（敏感信息已脱敏）。
  String get logLine {
    final parts = <String>[
      'engine=$engine',
      'format=${format.name}',
      if (target.host.isNotEmpty) 'host=${target.host}',
      if (flag != null && flag!.isNotEmpty) 'flag=$flag',
      ...timings.map(
        (timing) => '${timing.stage.name}=${timing.elapsed.inMilliseconds}ms',
      ),
      if (succeeded != null) 'succeeded=$succeeded',
      if (failureKind != null) 'failure=$failureKind',
    ];
    return parts.join(' ');
  }

  /// 面向用户的诊断详情（多行，可直接粘贴到问题报告）。
  String get report {
    final buffer = StringBuffer()
      ..writeln('播放诊断')
      ..writeln('引擎：${PlaybackEngine.displayName(engine)}')
      ..writeln('格式：${format.label}');
    if (siteKey != null) buffer.writeln('站点：$siteKey');
    if (episodeName != null) buffer.writeln('剧集：$episodeName');
    if (flag != null && flag!.isNotEmpty) buffer.writeln('线路：$flag');
    if (target.host.isNotEmpty) {
      buffer.writeln('目标：${target.scheme}://${target.host}');
    }
    if (enterUrl != null && enterUrl!.isNotEmpty) {
      buffer.writeln('入口：$enterUrl');
    }
    if (finalUrl != null && finalUrl!.isNotEmpty && finalUrl != enterUrl) {
      buffer.writeln('实际：$finalUrl');
    }
    if (requestedHeaders.isNotEmpty) {
      buffer.writeln('请求头：${requestedHeaders.entries.map((e) => "${e.key}=${e.value}").join(", ")}');
    }
    if (timings.isNotEmpty) {
      buffer.writeln('阶段耗时：');
      for (final timing in timings) {
        final note = timing.note == null ? '' : '（${timing.note}）';
        buffer.writeln('  · ${timing.stage.label} ${timing.elapsed.inMilliseconds}ms$note');
      }
    }
    if (succeeded == false) {
      buffer.writeln('结果：失败');
      if (failureKind != null) buffer.writeln('分类：$failureKind');
      if (failureHint != null) buffer.writeln('提示：$failureHint');
      if (failureMessage != null && failureMessage!.isNotEmpty) {
        buffer.writeln('引擎错误：$failureMessage');
      }
    } else if (succeeded == true) {
      buffer.writeln('结果：成功');
    }
    return buffer.toString().trimRight();
  }

  Map<String, Object?> toJson() => {
    'engine': engine,
    'format': format.name,
    'network': target.toJson(),
    if (siteKey != null) 'siteKey': siteKey,
    if (flag != null) 'flag': flag,
    if (episodeName != null) 'episodeName': episodeName,
    if (enterUrl != null) 'enterUrl': enterUrl,
    if (finalUrl != null) 'finalUrl': finalUrl,
    if (requestedHeaders.isNotEmpty) 'headers': requestedHeaders,
    'timings': timings.map((timing) => timing.toJson()).toList(),
    if (succeeded != null) 'succeeded': succeeded,
    if (failureKind != null) 'failureKind': '$failureKind',
    if (failureMessage != null) 'failureMessage': failureMessage,
    if (failureHint != null) 'failureHint': failureHint,
    if (completedAt != null) 'completedAt': completedAt!.toIso8601String(),
  };
}

/// 诊断构建器：播放过程中增量填充，最后产出不可变快照。
class PlaybackDiagnosticsBuilder {
  PlaybackDiagnosticsBuilder({
    this.engine = PlaybackEngine.mediaKit,
    this.siteKey,
    this.flag,
    this.episodeName,
    this.enterUrl,
  });

  final String engine;
  String? siteKey;
  String? flag;
  String? episodeName;
  String? enterUrl;

  String? _rawFinalUrl;
  Map<String, String> _headers = const {};
  final List<StageTiming> _timings = [];
  bool? _succeeded;
  Object? _failureKind;
  String? _failureMessage;
  String? _failureHint;

  /// 记录最终交给播放器的地址（保留原文以推断 host，输出时统一脱敏）。
  void setFinalUrl(String? url) {
    _rawFinalUrl = (url ?? '').trim().isEmpty ? null : url!.trim();
  }

  /// 记录本次请求注入的 Header（脱敏在 [PlaybackDiagnostics] 输出时完成）。
  void setHeaders(Map<String, String> headers) {
    _headers = {
      for (final entry in headers.entries)
        entry.key: isSensitiveHeaderKey(entry.key) ? '<redacted>' : entry.value,
    };
  }

  /// 记录一个阶段耗时。
  void addStage(PlaybackStage stage, Duration elapsed, {String? note}) {
    _timings.add(StageTiming(stage: stage, elapsed: elapsed, note: note));
  }

  /// 记录失败结果。
  void fail({
    required Object kind,
    String? message,
    String? hint,
  }) {
    _succeeded = false;
    _failureKind = kind;
    _failureMessage = _truncate(message, 300);
    _failureHint = hint;
  }

  /// 记录成功结果。
  void succeed() {
    _succeeded = true;
  }

  static String? _truncate(String? value, int max) {
    if (value == null) return null;
    return value.length <= max ? value : '${value.substring(0, max)}…';
  }

  /// 产出快照。地址优先取最终地址，否则回落到入口地址。
  PlaybackDiagnostics build() {
    final raw = _rawFinalUrl ?? enterUrl;
    return PlaybackDiagnostics(
      engine: engine,
      format: detectMediaFormat(raw),
      target: NetworkTarget.of(raw),
      timings: List.unmodifiable(_timings),
      siteKey: siteKey,
      flag: flag,
      episodeName: episodeName,
      enterUrl: redactUrl(enterUrl),
      finalUrl: redactUrl(raw),
      requestedHeaders: Map.unmodifiable(_headers),
      succeeded: _succeeded,
      failureKind: _failureKind,
      failureMessage: _failureMessage,
      failureHint: _failureHint,
      completedAt: _succeeded == null ? null : DateTime.now(),
    );
  }
}
