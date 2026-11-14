/// 将 Android T4 返回的回环播放地址转换为 PC 可达地址。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/android_bridge.dart';
import '../core/app_error.dart';
import '../core/protocol.dart';
import 'log_service.dart';

typedef AdbCommand = Future<ProcessResult> Function(List<String> arguments);

class AndroidPlaybackBridge {
  AndroidPlaybackBridge({AdbCommand? runAdb, this.log})
    : _runAdb = runAdb ?? _executeAdb;

  final AdbCommand _runAdb;
  final LogService? log;
  final Map<String, Future<int>> _pending = {};
  final Set<_Forward> _owned = {};
  bool _closed = false;

  Future<String> resolve(Site site, String target) async {
    final api = Uri.tryParse(site.api);
    final media = Uri.tryParse(target);
    if (site.type != 4 ||
        api == null ||
        !(api.path == '/vod/api' || api.path.startsWith('/vod/api/')) ||
        media == null ||
        !['http', 'https'].contains(media.scheme) ||
        !isLoopbackHost(media.host)) {
      return target;
    }
    if (_closed) throw _unreachable();

    // 真机以自身局域网主机承接代理；代理服务可能运行在独立的 5000 端口。
    if (!isLoopbackHost(api.host)) {
      return media.replace(host: api.host).toString();
    }
    if (media.port == api.port) return target;

    try {
      final forwards = await _listForwards();
      // 必须从当前网关入口反查设备，不能选 devices 的第一台或固定 5559。
      final gateways = forwards.where((row) => row.local == api.port).toList();
      if (gateways.length != 1) throw _unreachable();
      final gateway = gateways.single;
      final existing = forwards
          .where(
            (row) => row.serial == gateway.serial && row.remote == media.port,
          )
          .firstOrNull;
      final int localPort;
      if (existing != null) {
        localPort = existing.local;
      } else {
        final key = '${gateway.serial}:${media.port}';
        final pending = _pending.putIfAbsent(
          key,
          () => _createForward(gateway.serial, media.port),
        );
        try {
          localPort = await pending;
        } finally {
          if (identical(_pending[key], pending)) _pending.remove(key);
        }
      }
      if (_closed) throw _unreachable();
      return media.replace(host: '127.0.0.1', port: localPort).toString();
    } on AppError {
      rethrow;
    } catch (_) {
      throw _unreachable();
    }
  }

  Future<PlaybackDecision> resolveDecision(
    Site site,
    PlaybackDecision decision,
  ) async {
    final url = decision.url;
    if (url == null) return decision;
    final reachable = await resolve(site, url);
    if (reachable == url) return decision;
    return PlaybackDecision(
      action: decision.action,
      url: reachable,
      headers: decision.headers,
      format: decision.format,
      reason: decision.reason,
      flag: decision.flag,
      parse: decision.parse,
      jx: decision.jx,
      subs: decision.subs,
      danmaku: decision.danmaku,
      upstreamHeaders: decision.upstreamHeaders,
      qualities: decision.qualities,
      qualityIndex: decision.qualityIndex,
    );
  }

  Future<List<_Forward>> _listForwards() async {
    final result = await _runAdb(['forward', '--list']);
    if (result.exitCode != 0) throw _unreachable();
    final rows = <_Forward>[];
    for (final line in '${result.stdout}'.split(RegExp(r'[\r\n]+'))) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length != 3 ||
          !fields[1].startsWith('tcp:') ||
          !fields[2].startsWith('tcp:')) {
        continue;
      }
      final local = int.tryParse(fields[1].substring(4));
      final remote = int.tryParse(fields[2].substring(4));
      if (local != null && remote != null) {
        rows.add(_Forward(fields[0], local, remote));
      }
    }
    return rows;
  }

  Future<int> _createForward(String serial, int remote) async {
    if (_closed) throw _unreachable();
    final result = await _runAdb([
      '-s',
      serial,
      'forward',
      'tcp:0',
      'tcp:$remote',
    ]);
    final port = int.tryParse('${result.stdout}'.trim());
    if (result.exitCode != 0 || port == null || port < 1 || port > 65535) {
      throw _unreachable();
    }
    _owned.add(_Forward(serial, port, remote));
    return port;
  }

  /// 只移除本实例创建且仍属于同一设备的转发，保留用户已有的网关/媒体转发。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await Future.wait(
      _pending.values.map((future) async {
        try {
          await future;
        } catch (_) {}
      }),
    );
    if (_owned.isEmpty) return;
    try {
      final current = await _listForwards();
      for (final row in _owned) {
        if (!current.any(
          (other) =>
              other.serial == row.serial &&
              other.local == row.local &&
              other.remote == row.remote,
        )) {
          continue;
        }
        final result = await _runAdb([
          '-s',
          row.serial,
          'forward',
          '--remove',
          'tcp:${row.local}',
        ]);
        if (result.exitCode != 0) throw _unreachable();
      }
    } catch (_) {
      log?.warning('清理 Android 播放转发失败，请检查设备连接', scope: 'bridge');
    } finally {
      _owned.clear();
    }
  }

  static AppError _unreachable() => AppError(
    AppErrorKind.bridgeUnreachable,
    '无法连接 Android 的播放代理，请保持默影视运行，并检查该设备的连接与 ADB 转发',
    retryable: true,
  );

  static Future<ProcessResult> _executeAdb(List<String> arguments) async {
    final process = await Process.start('adb', arguments);
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.transform(utf8.decoder).join();
    try {
      final code = await process.exitCode.timeout(const Duration(seconds: 8));
      return ProcessResult(process.pid, code, await stdout, await stderr);
    } on TimeoutException {
      process.kill();
      await process.exitCode;
      rethrow;
    }
  }
}

class _Forward {
  const _Forward(this.serial, this.local, this.remote);
  final String serial;
  final int local;
  final int remote;
}
