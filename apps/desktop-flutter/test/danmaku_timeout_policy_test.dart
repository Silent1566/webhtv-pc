/// 站源脚本弹幕要等它自己的上游（实测 9.5–27 秒），弹幕库不该跟着等。
///
/// 这里用真实的本地 HTTP 服务复现两类目标：本机数据面 `/s/<token>/proxy` 与弹幕库地址。
/// 断言的是**可观察行为**——慢响应在站源预算下能成功、在弹幕库预算下会超时。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/danmaku_service.dart';

const _xml =
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<i><d p="1.0,1,25,16777215">hi</d></i>';

Future<HttpServer> _slowServer(Duration delay) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    await Future<void>.delayed(delay);
    request.response.headers.contentType = ContentType.parse(
      'application/xml; charset=utf-8',
    );
    request.response.write(_xml);
    await request.response.close();
  });
  return server;
}

void main() {
  final library = const Duration(milliseconds: 150);
  final siteSource = const Duration(seconds: 3);

  group('站源脚本弹幕用长预算，弹幕库仍用短预算', () {
    late HttpServer server;
    late String base;

    setUp(() async {
      server = await _slowServer(const Duration(milliseconds: 600));
      base = 'http://127.0.0.1:${server.port}';
    });

    tearDown(() async {
      await server.close(force: true);
    });

    for (final path in <String>[
      '/s/tok-1/proxy?do=danmu&name=a&episode=1&season=1',
      '/s/another/proxy',
    ]) {
      test('慢站源 $path 不被弹幕库预算砍断', () async {
        final service = DanmakuService(
          timeout: library,
          siteSourceTimeout: siteSource,
        );
        addTearDown(service.close);

        final document = await service.load(DanmakuSource(url: '$base$path'));

        expect(document.items, hasLength(1));
      });
    }

    for (final path in <String>[
      '/api/v2/comment/156372',
      '/f763cef1fe944371/api/v2/comment/1',
    ]) {
      test('弹幕库地址 $path 仍在短预算内超时', () async {
        final service = DanmakuService(
          timeout: library,
          siteSourceTimeout: siteSource,
        );
        addTearDown(service.close);

        await expectLater(
          service.load(DanmakuSource(url: '$base$path')),
          throwsA(
            isA<AppError>().having(
              (e) => e.kind,
              'kind',
              AppErrorKind.danmakuNetwork,
            ),
          ),
        );
      });
    }
  });

  group('弹幕失败文案保留真实原因', () {
    test('超时说超时，不说“网络不可达或 DNS 失败”', () {
      final text = describeDanmakuFailure(
        AppError(AppErrorKind.danmakuNetwork, '站源弹幕超时（45s 无响应）'),
      );

      expect(text, contains('超时'));
      expect(text, contains('不影响视频播放'));
      expect(text, isNot(contains('DNS')));
    });

    test('非 2xx 带出状态码', () {
      final text = describeDanmakuFailure(
        AppError(AppErrorKind.danmakuHttp, '弹幕下载返回 HTTP 502', statusCode: 502),
      );

      expect(text, contains('HTTP 502'));
      expect(text, contains('不影响视频播放'));
    });

    test('能识别但无条目时保留可区分的原因', () {
      final text = describeDanmakuFailure(
        AppError(AppErrorKind.danmakuEmpty, '弹幕文件没有可用条目（丢弃 0 条）'),
      );

      expect(text, contains('没有可用条目'));
    });
  });
}
