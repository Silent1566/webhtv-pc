/// TMDB 图片线路探测（`docs/phase4/design/03` §5.6 的「测试图片线路」）。
///
/// 只测服务层：注入 fake 客户端，验证三种线路形态拼出的探测地址、成功/失败
/// 结果，以及结论句。真实网络不在单测里跑。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_route.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';

class _ImageClient extends http.BaseClient {
  _ImageClient({this.statusCode = 200, this.body = const []});

  int statusCode;
  List<int> body;
  Object? failure;
  final List<Uri> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    final error = failure;
    if (error != null) throw error;
    return http.StreamedResponse(
      Stream<List<int>>.value(Uint8List.fromList(body)),
      statusCode,
      request: request,
    );
  }
}

TmdbService _service(http.Client client) => TmdbService(
  config: () => const TmdbConfig(),
  client: client,
  timeout: const Duration(seconds: 2),
);

void main() {
  test('三种线路形态都拼出可用的探测地址，且只发一次请求', () async {
    final client = _ImageClient(body: List<int>.filled(38425, 7));
    final service = _service(client);

    final official = await service.probeImageRoute(
      'https://images.tmdb.org/t/p/w342',
    );
    final proxied = await service.probeImageRoute(
      'https://jsnzkpg4.pages.dev/https://image.tmdb.org/t/p/w342',
    );
    final wrapped = await service.probeImageRoute(
      'https://wsrv.nl/?url=https://image.tmdb.org/t/p/w342',
    );

    for (final probe in [official, proxied, wrapped]) {
      expect(probe.ok, isTrue, reason: probe.url);
      expect(probe.statusCode, 200);
      expect(probe.bytes, 38425);
      expect(probe.error, isNull);
    }
    expect(
      client.requests.map((uri) => uri.toString()).toList(),
      [
        'https://images.tmdb.org$tmdbImageProbePath',
        'https://jsnzkpg4.pages.dev/https://image.tmdb.org$tmdbImageProbePath',
        'https://wsrv.nl/?url=https://image.tmdb.org$tmdbImageProbePath',
      ],
    );
    expect(client.requests, hasLength(3));
  });

  test('线路返回 404 时不算正常，状态码原样带回', () async {
    final client = _ImageClient(statusCode: 404);
    final probe = await _service(client).probeImageRoute(
      'https://jsnzkpg4.pages.dev/https://image.tmdb.org',
    );
    expect(probe.ok, isFalse);
    expect(probe.statusCode, 404);
    expect(probe.bytes, 0);
    expect(tmdbImageProbeSummary(probe), contains('HTTP 404'));
  });

  test('网络失败时给出可读原因而不是抛异常', () async {
    final client = _ImageClient()..failure = const SocketExceptionLike();
    final probe = await _service(client).probeImageRoute(
      'https://images.tmdb.org',
    );
    expect(probe.ok, isFalse);
    expect(probe.statusCode, 0);
    expect(probe.error, isNotNull);
    expect(tmdbImageProbeSummary(probe), contains('不可用'));
  });

  test('空线路不发请求', () async {
    final client = _ImageClient();
    final probe = await _service(client).probeImageRoute('   ');
    expect(probe.url, isEmpty);
    expect(probe.ok, isFalse);
    expect(client.requests, isEmpty);
    expect(tmdbImageProbeSummary(probe), contains('图片线路为空'));
  });
}

/// 模拟连接层失败（不引入 `dart:io`，以便 Web 端也能跑这份测试）。
class SocketExceptionLike implements Exception {
  const SocketExceptionLike();

  @override
  String toString() => 'SocketException: Connection refused';
}
