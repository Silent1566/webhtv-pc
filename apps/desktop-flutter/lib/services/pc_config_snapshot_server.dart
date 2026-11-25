/// 本机快照发布器：127.0.0.1:0、精确 token 路径、GET/HEAD 与 no-store。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../core/android_config_execution.dart';
import 'log_service.dart';

class _SnapshotEntry {
  _SnapshotEntry(this.bytes, this.etag);

  final Uint8List bytes;
  final String etag;
}

/// 只把内存里的 JSON 快照暴露给本机回环地址；不读私有文件、不暴露任意路由。
class PcConfigSnapshotServer {
  PcConfigSnapshotServer({required this.log});

  final LogService log;

  final Map<String, _SnapshotEntry> _snapshots = {};
  HttpServer? _server;

  /// 在途的启动：并发首个调用共享同一次 bind，close 与失败都会清空。
  Future<void>? _starting;

  /// 启动序号：在途 bind 落地时据此判断自己是否已被 close 或后来的 start 作废。
  int _startSeq = 0;

  bool get running => _server != null;

  int get port => _server?.port ?? 0;

  Future<void> start() {
    if (_server != null) return Future<void>.value();
    return _starting ??= _start(++_startSeq);
  }

  Future<void> _start(int seq) async {
    bool isCurrent() => seq == _startSeq && _starting != null;
    final HttpServer bound;
    try {
      bound = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    } catch (_) {
      if (isCurrent()) _starting = null;
      rethrow;
    }
    if (!isCurrent()) {
      // 已被 close() 或后来的 start() 作废：关掉自己的监听，绝不留悬空端口。
      await bound.close(force: true);
      return;
    }
    _server = bound;
    bound.listen(_handleRequest);
    log.info('PC 配置快照发布器 status=started count=0', scope: 'android');
  }

  /// 返回稳定的 `/<token>.json` 路径；同 token 再次调用只替换正文。
  String putSnapshot(String token, Map<String, Object?> snapshot) {
    if (!isValidAndroidSnapshotToken(token)) {
      throw ArgumentError('快照 token 不合法');
    }
    late final List<int> encoded;
    try {
      encoded = utf8.encode(jsonEncode(snapshot));
    } catch (_) {
      throw ArgumentError('快照不是可编码的 JSON 对象');
    }
    if (encoded.length > androidExecutionSnapshotMaxBytes) {
      throw ArgumentError('快照超过 2 MiB 上限');
    }
    final bytes = Uint8List.fromList(encoded);
    _snapshots[token] = _SnapshotEntry(bytes, sha256.convert(bytes).toString());
    log.info(
      'PC 配置快照已更新 status=updated token=#${_fingerprint(token)} count=${_snapshots.length}',
      scope: 'android',
    );
    return '/$token.json';
  }

  void removeSnapshot(String token) {
    _snapshots.remove(token);
  }

  /// 设备侧稳定地址：host 固定 127.0.0.1，端口是 ADB reverse 的 guest 端口。
  Uri deviceUri(String token, int guestPort) {
    if (!isValidAndroidSnapshotToken(token)) {
      throw ArgumentError('快照 token 不合法');
    }
    if (guestPort < 1 || guestPort > 65535) {
      throw ArgumentError('guest 端口越界');
    }
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: guestPort,
      path: '/$token.json',
    );
  }

  Future<void> close() async {
    // 不等待在途 bind：只作废它，落地后由 _start 自己关闭监听。
    _starting = null;
    final server = _server;
    _server = null;
    _snapshots.clear();
    await server?.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        await _emptyResponse(
          request,
          HttpStatus.methodNotAllowed,
          extra: {'allow': 'GET, HEAD'},
        );
        return;
      }
      if (request.uri.hasQuery) {
        await _emptyResponse(request, HttpStatus.notFound);
        return;
      }
      final path = request.uri.path;
      if (!path.startsWith('/') || !path.endsWith('.json')) {
        await _emptyResponse(request, HttpStatus.notFound);
        return;
      }
      final token = path.substring(1, path.length - '.json'.length);
      if (!isValidAndroidSnapshotToken(token)) {
        await _emptyResponse(request, HttpStatus.notFound);
        return;
      }
      final entry = _snapshots[token];
      if (entry == null) {
        await _emptyResponse(request, HttpStatus.notFound);
        return;
      }

      final response = request.response;
      response.statusCode = HttpStatus.ok;
      response.headers.contentType = ContentType(
        'application',
        'json',
        charset: 'utf-8',
      );
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      response.headers.set('etag', '"${entry.etag}"');
      response.headers.set('x-content-type-options', 'nosniff');
      response.contentLength = entry.bytes.length;
      if (request.method == 'GET') {
        response.add(entry.bytes);
      }
      await response.close();
      log.info(
        'PC 配置快照 ${request.method} status=200 token=#${_fingerprint(token)} count=${_snapshots.length}',
        scope: 'android',
      );
    } catch (_) {
      try {
        await _emptyResponse(request, HttpStatus.internalServerError);
      } catch (_) {}
    }
  }

  Future<void> _emptyResponse(
    HttpRequest request,
    int status, {
    Map<String, String> extra = const {},
  }) async {
    final response = request.response;
    response.statusCode = status;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.headers.set('x-content-type-options', 'nosniff');
    for (final entry in extra.entries) {
      response.headers.set(entry.key, entry.value);
    }
    response.contentLength = 0;
    await response.close();
    log.info(
      'PC 配置快照 ${request.method} status=$status count=${_snapshots.length}',
      scope: 'android',
    );
  }
}

String _fingerprint(String token) =>
    sha256.convert(utf8.encode(token)).toString().substring(0, 8);
