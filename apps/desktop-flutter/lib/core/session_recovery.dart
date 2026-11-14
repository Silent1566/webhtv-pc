/// 会话恢复的纯数据模型（Phase 9 · P2-8）。
///
/// 崩溃恢复只保存**标识与进度**，不保存播放直链、不保存任何 Header：
/// 恢复时按站点重新解析（与历史续播同一条路径），因此不会把凭据写到磁盘上。
library;

/// 崩溃时正在播放的上下文（标识 + 进度）。
class SessionPlaybackContext {
  const SessionPlaybackContext({
    required this.siteKey,
    required this.vodId,
    required this.vodName,
    required this.flag,
    required this.episodeName,
    required this.episodeId,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAtMs,
  });

  final String siteKey;
  final String vodId;
  final String vodName;
  final String flag;
  final String episodeName;
  final String episodeId;
  final int positionMs;
  final int durationMs;
  final int updatedAtMs;

  Map<String, Object?> toJson() => {
    'siteKey': siteKey,
    'vodId': vodId,
    'vodName': vodName,
    'flag': flag,
    'episodeName': episodeName,
    'episodeId': episodeId,
    'positionMs': positionMs,
    'durationMs': durationMs,
    'updatedAt': updatedAtMs,
  };

  static SessionPlaybackContext? tryParse(Object? raw) {
    if (raw is! Map) return null;
    String text(String key) {
      final value = raw[key];
      return value is String ? value : '';
    }

    int number(String key) {
      final value = raw[key];
      return value is num ? value.toInt() : 0;
    }

    final siteKey = text('siteKey');
    final vodId = text('vodId');
    if (siteKey.isEmpty || vodId.isEmpty) return null;
    return SessionPlaybackContext(
      siteKey: siteKey,
      vodId: vodId,
      vodName: text('vodName'),
      flag: text('flag'),
      episodeName: text('episodeName'),
      episodeId: text('episodeId'),
      positionMs: number('positionMs'),
      durationMs: number('durationMs'),
      updatedAtMs: number('updatedAt'),
    );
  }

  @override
  String toString() =>
      'SessionPlaybackContext($siteKey/$vodId $episodeName @$positionMs)';
}

/// 会话标记文件内容（`<data>/session.json`）。
class SessionMarker {
  const SessionMarker({
    required this.version,
    required this.pid,
    required this.startedAtMs,
    required this.appVersion,
    this.playback,
  });

  static const int formatVersion = 1;

  final int version;

  /// 写入标记的进程号：同进程重复 bootstrap 不算崩溃。
  final int pid;
  final int startedAtMs;
  final String appVersion;
  final SessionPlaybackContext? playback;

  Map<String, Object?> toJson() => {
    'version': version,
    'pid': pid,
    'startedAt': startedAtMs,
    'appVersion': appVersion,
    if (playback != null) 'playback': playback!.toJson(),
  };

  static SessionMarker? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final version = raw['version'];
    final pid = raw['pid'];
    final startedAt = raw['startedAt'];
    final appVersion = raw['appVersion'];
    if (version is! num || version.toInt() != formatVersion) return null;
    if (pid is! num || startedAt is! num) return null;
    return SessionMarker(
      version: version.toInt(),
      pid: pid.toInt(),
      startedAtMs: startedAt.toInt(),
      appVersion: appVersion is String ? appVersion : '',
      playback: SessionPlaybackContext.tryParse(raw['playback']),
    );
  }
}

/// 崩溃日志单条上限与文件上限（避免崩溃循环把磁盘写满）。
const int crashLogEntryMaxChars = 4000;
const int crashLogFileMaxChars = 64 * 1024;

/// 把异常整理成一条有界、可读的崩溃记录。
String formatCrashEntry({
  required DateTime at,
  required String kind,
  required String error,
  String? stack,
}) {
  final buffer = StringBuffer()
    ..writeln('[$kind] ${at.toIso8601String()}')
    ..writeln(_bounded(error, crashLogEntryMaxChars ~/ 2));
  final trace = stack?.trim() ?? '';
  if (trace.isNotEmpty) {
    buffer.writeln(_bounded(trace, crashLogEntryMaxChars ~/ 2));
  }
  return buffer.toString();
}

String _bounded(String text, int maxChars) =>
    text.length <= maxChars ? text : '${text.substring(0, maxChars)}…';

/// 崩溃横幅文案（不含任何 URL/凭据）。
String describeRecoveredSession(SessionMarker marker, DateTime now) {
  final started = DateTime.fromMillisecondsSinceEpoch(marker.startedAtMs);
  final minutes = now.difference(started).inMinutes;
  final duration = minutes <= 0 ? '不到 1 分钟' : '约 $minutes 分钟';
  return '上次运行未正常退出（$duration）。'
      '${marker.playback == null ? "没有可恢复的播放上下文。" : "可以继续上次播放。"}';
}
