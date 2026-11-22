/// 猫源 bundle 自带弹幕服务的自动发现（对齐安卓 `NodeRuntime.danmakuApiUrl()`）。
///
/// 只连 127.0.0.1 上的假服务：发现逻辑本身不允许对外发请求，测试也就不碰外网。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/cat_runtime.dart';

/// 一个可编排的假 HTTP 服务：按路径返回固定状态码与 body。
class FakeNode {
  FakeNode._(this._server) : port = _server.port;

  final HttpServer _server;
  final int port;

  /// 收到的全部请求路径，用来证明某些端口根本没被探过。
  final List<String> hits = <String>[];

  static Future<FakeNode> start({
    int status = 200,
    String body = '',
    int Function(String path)? statusFor,
    String Function(String path)? bodyFor,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeNode._(server);
    server.listen((request) async {
      fake.hits.add(request.uri.path);
      request.response.statusCode =
          statusFor?.call(request.uri.path) ?? status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(bodyFor?.call(request.uri.path) ?? body);
      await request.response.close();
    });
    return fake;
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cat_danmaku_');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  void writePorts(String text) =>
      File(p.join(dir.path, 'port')).writeAsStringSync(text);

  test('命中：跳过猫源本体端口，认 /danmaku 回 JSON 的那个', () async {
    // 猫源本体：/config 200，/danmaku 401（真实 bundle 的形态）。
    final cat = await FakeNode.start(
      statusFor: (path) => path == '/config' ? 200 : 401,
      bodyFor: (path) => path == '/config' ? '{"sites":[]}' : 'unauthorized',
    );
    final danmaku = await FakeNode.start(body: '[]');
    addTearDown(cat.close);
    addTearDown(danmaku.close);
    writePorts('${cat.port},${danmaku.port}');

    final url = await CatNodeRuntime.discoverDanmakuBaseUrl(
      bundleDir: dir.path,
      catPort: cat.port,
      deadline: const Duration(seconds: 5),
    );

    expect(url, 'http://127.0.0.1:${danmaku.port}/danmaku');
    // 猫源端口一个请求都不该收到：跳过它不只是「结果对」，而是不去探。
    expect(cat.hits, isEmpty);
    expect(danmaku.hits, everyElement('/danmaku'));
  });

  test('跳过非法候选：HTML / 500 之后继续找下一个', () async {
    final cat = await FakeNode.start(statusFor: (_) => 401, body: 'unauthorized');
    final html = await FakeNode.start(body: '<html>not json</html>');
    final broken = await FakeNode.start(status: 500, body: '{"error":"boom"}');
    final danmaku = await FakeNode.start(body: '[]');
    addTearDown(cat.close);
    addTearDown(html.close);
    addTearDown(broken.close);
    addTearDown(danmaku.close);
    writePorts(
      '${cat.port},${html.port},${broken.port},${danmaku.port}',
    );

    final url = await CatNodeRuntime.discoverDanmakuBaseUrl(
      bundleDir: dir.path,
      catPort: cat.port,
      deadline: const Duration(seconds: 5),
    );

    expect(url, 'http://127.0.0.1:${danmaku.port}/danmaku');
    expect(html.hits, isNotEmpty);
    expect(broken.hits, isNotEmpty);
  });

  test('端口文件稍后才追加弹幕端口：每轮重读仍能命中', () async {
    final cat = await FakeNode.start(statusFor: (_) => 401, body: 'unauthorized');
    final danmaku = await FakeNode.start(body: '[]');
    addTearDown(cat.close);
    addTearDown(danmaku.close);
    // 第一轮只有猫源端口：此时还不存在弹幕候选。
    writePorts('${cat.port}');

    final pending = CatNodeRuntime.discoverDanmakuBaseUrl(
      bundleDir: dir.path,
      catPort: cat.port,
      deadline: const Duration(seconds: 8),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    writePorts('${cat.port},${danmaku.port}');

    expect(
      await pending,
      'http://127.0.0.1:${danmaku.port}/danmaku',
    );
  });

  test('超时：只有非 JSON 候选时返回空串且不抛异常', () async {
    final cat = await FakeNode.start(statusFor: (_) => 401, body: 'unauthorized');
    final html = await FakeNode.start(body: '<html>nope</html>');
    addTearDown(cat.close);
    addTearDown(html.close);
    writePorts('${cat.port},${html.port}');

    final url = await CatNodeRuntime.discoverDanmakuBaseUrl(
      bundleDir: dir.path,
      catPort: cat.port,
      deadline: const Duration(milliseconds: 400),
    );

    expect(url, isEmpty);
  });

  test('以 { 开头的 JSON 对象同样算命中', () async {
    final cat = await FakeNode.start(statusFor: (_) => 401, body: 'unauthorized');
    final danmaku = await FakeNode.start(body: '{"count":0,"comments":[]}');
    addTearDown(cat.close);
    addTearDown(danmaku.close);
    writePorts('${cat.port},${danmaku.port}');

    expect(
      await CatNodeRuntime.discoverDanmakuBaseUrl(
        bundleDir: dir.path,
        catPort: cat.port,
        deadline: const Duration(seconds: 5),
      ),
      'http://127.0.0.1:${danmaku.port}/danmaku',
    );
  });
}
