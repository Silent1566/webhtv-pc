import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'search_cancel_harness.dart';

class ProbeCancelHarness extends SearchCancelHarness {
  @override
  String get source =>
      p.join(Directory.current.path, 'test', 'support', 'probe_cancel_host.py');

  Future<Map<String, dynamic>> probeFrame(String method) async {
    await until(() => frames.any((frame) => frame['method'] == method));
    final frame = frames.firstWhere((frame) => frame['method'] == method);
    await until(() => gates.containsKey(frame['id']));
    return frame;
  }

  Future<void> replyError(String id) async {
    await until(() => gates.containsKey(id));
    final request = gates.remove(id)!;
    request.response.write(jsonEncode({'fixtureError': true}));
    await request.response.close();
  }
}

class ProbeWireRequest {
  ProbeWireRequest(this.method, this.uri, this.headers, this.body);
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final String body;
}

/// Holds each real TCP response until the test releases it or the client aborts.
class ProbeWireServer {
  ProbeWireServer._(this._server) {
    _server.listen(_accept);
  }

  static Future<ProbeWireServer> start() async => ProbeWireServer._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
  );

  final ServerSocket _server;
  final _sockets = <Socket>{};
  final _held = <String, Socket>{};
  final _received = <String, Completer<ProbeWireRequest>>{};
  final _disconnected = <String, Completer<void>>{};
  final requests = <ProbeWireRequest>[];
  final partialBodies = <String>{};

  String api(String key) => 'http://127.0.0.1:${_server.port}/$key';
  Future<ProbeWireRequest> received(String key) =>
      (_received[key] ??= Completer<ProbeWireRequest>()).future;
  Future<void> disconnected(String key) =>
      (_disconnected[key] ??= Completer<void>()).future;

  void _accept(Socket socket) {
    _sockets.add(socket);
    final bytes = <int>[];
    String? key;
    var handled = false;
    void disconnected() {
      _sockets.remove(socket);
      if (key != null) {
        final signal = _disconnected[key!] ??= Completer<void>();
        if (!signal.isCompleted) signal.complete();
      }
      socket.destroy();
    }

    socket.listen(
      (chunk) {
        if (handled) return;
        bytes.addAll(chunk);
        final raw = latin1.decode(bytes);
        final end = raw.indexOf('\r\n\r\n');
        if (end < 0) return;
        final lines = raw.substring(0, end).split('\r\n');
        final first = lines.first.split(' ');
        final headers = <String, String>{};
        for (final line in lines.skip(1)) {
          final separator = line.indexOf(':');
          headers[line.substring(0, separator).toLowerCase()] = line
              .substring(separator + 1)
              .trim();
        }
        final length = int.parse(headers['content-length'] ?? '0');
        if (bytes.length < end + 4 + length) return;
        handled = true;
        final uri = Uri.parse(first[1]);
        key = uri.pathSegments.first;
        final request = ProbeWireRequest(
          first[0],
          uri,
          headers,
          utf8.decode(bytes.sublist(end + 4, end + 4 + length)),
        );
        requests.add(request);
        _held[key!] = socket;
        (_received[key!] ??= Completer<ProbeWireRequest>()).complete(request);
        if (partialBodies.contains(key)) {
          socket.write(
            'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n1\r\n{\r\n',
          );
        }
      },
      onDone: disconnected,
      onError: (Object _) => disconnected(),
    );
  }

  void complete(String key) {
    final socket = _held.remove(key)!;
    final body = utf8.encode(
      '{"list":[{"vod_id":"wire-id","vod_name":"peer alive"}]}',
    );
    socket.write(
      'HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n',
    );
    socket.add(body);
    unawaited(socket.flush().then((_) => socket.close()));
  }

  Future<void> close() async {
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    await _server.close();
  }
}
