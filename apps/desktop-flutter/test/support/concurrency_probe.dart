/// 并发探针：真正**并发**处理请求，并记录同时在途的峰值请求数。
///
/// 用它而不是 `TestFixtureServer` 的原因：后者串行处理请求（`await for` +
/// `await _handle`），会把客户端的并发掩盖成串行，从而测不出 `searchAll`
/// 的真实并发行为。
///
/// 为什么单独成文件：搜索并发至少有两处门禁要观测同一个量（`phase2_search_test`
/// 的 maxConcurrency、`search_thread_setting_test` 的「搜索线程」设置），
/// 复制一份必然分叉。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class ConcurrencyProbe {
  ConcurrencyProbe._(this._server, this._hold);

  final HttpServer _server;
  final Duration _hold;
  int _inFlight = 0;
  int _maxInFlight = 0;

  /// 同时在处理的最大请求数。
  int get maxInFlight => _maxInFlight;

  /// 把峰值计数归零，供「同一探针观测两个阶段」的用例使用
  /// （例如：先证明在途批次不受设置变更影响，再证明下一次搜索用了新值）。
  void resetPeak() => _maxInFlight = 0;

  /// 站点 `api`（`type=1` 的基地址）。
  String get api => 'http://127.0.0.1:${_server.port}/api/type1/';

  /// 启动探针；[holdMs] 是每个请求的保持时长（给并发重叠留窗口）。
  static Future<ConcurrencyProbe> start({int holdMs = 400}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final probe = ConcurrencyProbe._(server, Duration(milliseconds: holdMs));
    unawaited(probe._listen());
    return probe;
  }

  Future<void> _listen() async {
    await for (final request in _server) {
      // 必须 unawaited，否则又变回串行，无法观测并发。
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    _inFlight += 1;
    if (_inFlight > _maxInFlight) _maxInFlight = _inFlight;
    try {
      // hold 期间保持请求在途，给并发重叠留出窗口。
      await Future<void>.delayed(_hold);
      request.response.headers.contentType = ContentType(
        'application',
        'json',
        charset: 'utf-8',
      );
      request.response.write(
        jsonEncode({
          'list': [
            {'vod_id': 'probe-1', 'vod_name': '并发探针'},
          ],
        }),
      );
    } finally {
      _inFlight -= 1;
      try {
        await request.response.close();
      } catch (_) {
        // 客户端可能已断开。
      }
    }
  }

  Future<void> stop() async {
    await _server.close(force: true);
  }
}
