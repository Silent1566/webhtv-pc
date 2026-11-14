/// 会话恢复的文件读写（Phase 9 · P2-8）。
///
/// 全部用**同步 IO**：崩溃/退出路径上不能依赖事件循环还活着。
/// 文件都很小（标记 < 1 KiB，崩溃日志有 64 KiB 上限），同步读写不会卡。
library;

import 'dart:convert';
import 'dart:io';

import '../core/session_recovery.dart';
import 'app_paths.dart';
import 'log_service.dart';

class SessionRecoveryStore {
  SessionRecoveryStore({
    required this.dataDir,
    this.log,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final String dataDir;

  /// 失败日志（可为 null）。
  final LogService? log;
  final DateTime Function() _now;

  String get markerPath => '$dataDir${Platform.pathSeparator}session.json';

  String get crashLogPath => '$dataDir${Platform.pathSeparator}crash.log';

  /// 读取上一次会话留下的标记；文件不存在/损坏时返回 null。
  SessionMarker? readMarker() {
    try {
      final file = File(markerPath);
      if (!file.existsSync()) return null;
      return SessionMarker.tryParse(
        jsonDecode(file.readAsStringSync()),
      );
    } catch (error) {
      log?.warning('读取会话标记失败：$error', scope: 'recovery');
      return null;
    }
  }

  /// 开始一次会话：写入带当前 pid 的标记。
  void beginSession({required String appVersion, int? pid}) {
    try {
      final marker = SessionMarker(
        version: SessionMarker.formatVersion,
        pid: pid ?? currentPid,
        startedAtMs: _now().millisecondsSinceEpoch,
        appVersion: appVersion,
      );
      _writeMarker(marker);
    } catch (error) {
      log?.warning('写入会话标记失败：$error', scope: 'recovery');
    }
  }

  /// 更新当前会话的播放上下文（保留 pid/startedAt）。
  void updatePlayback(
    SessionPlaybackContext playback, {
    required String appVersion,
    int? pid,
  }) {
    final existing = readMarker();
    final marker = SessionMarker(
      version: SessionMarker.formatVersion,
      pid: existing?.pid ?? (pid ?? currentPid),
      startedAtMs: existing?.startedAtMs ?? _now().millisecondsSinceEpoch,
      appVersion: existing?.appVersion ?? appVersion,
      playback: playback,
    );
    try {
      _writeMarker(marker);
    } catch (error) {
      log?.warning('更新会话标记失败：$error', scope: 'recovery');
    }
  }

  /// 正常退出：删除标记（同步，进程可能马上消失）。
  void endSessionCleanly() {
    try {
      final file = File(markerPath);
      if (file.existsSync()) file.deleteSync();
    } catch (error) {
      log?.warning('清理会话标记失败：$error', scope: 'recovery');
    }
  }

  /// 用户已处理崩溃提示：删除标记，避免每次都提示。
  void acknowledgeRecovery() => endSessionCleanly();

  /// 追加一条崩溃日志（有界：超出上限时保留尾部）。
  void appendCrash(String entry) {
    try {
      final file = File(crashLogPath);
      final existing = file.existsSync() ? file.readAsStringSync() : '';
      var next = '$existing\n$entry';
      if (next.length > crashLogFileMaxChars) {
        next = next.substring(next.length - crashLogFileMaxChars);
      }
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(next, flush: true);
    } catch (_) {
      // 崩溃路径上不能再抛：写不进去就算了。
    }
  }

  String? readCrashLog() {
    try {
      final file = File(crashLogPath);
      if (!file.existsSync()) return null;
      final text = file.readAsStringSync().trim();
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  void clearCrashLog() {
    try {
      final file = File(crashLogPath);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  void _writeMarker(SessionMarker marker) {
    final file = File(markerPath);
    file.parent.createSync(recursive: true);
    final temp = File('$markerPath.tmp');
    temp.writeAsStringSync(jsonEncode(marker.toJson()), flush: true);
    if (file.existsSync()) file.deleteSync();
    temp.renameSync(markerPath);
  }

  /// 进程号（`dart:io` 的顶层 `pid`；测试可注入）。
  static int get currentPid => pid;

  /// 全局静态入口：崩溃处理器在 AppState 之前运行。
  static void appendCrashForPaths(AppPaths paths, String entry) {
    SessionRecoveryStore(dataDir: paths.dataDir).appendCrash(entry);
  }
}
