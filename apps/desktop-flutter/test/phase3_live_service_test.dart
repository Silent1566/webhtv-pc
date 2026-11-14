/// 直播源加载服务测试（设计文档 §13.1、§13.3）。
///
/// 覆盖 `LiveService` 的拉取与解析编排：
/// - HTTP（M3U/TXT/JSON）与本地文件两种来源；
/// - 编码探测（GBK 兜底，与配置导入一致）；
/// - 缓存命中/失效（同 URL 不重复请求）；
/// - 错误归一化（非 2xx → liveHttp；缺 url/协议 → liveUnsupported）；
/// - 单源失败不冒泡成未捕获异常（调用方可继续处理其他源，§14.3）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/live_service.dart';

import 'support/test_fixture_server.dart';

void main() {
  late TestFixtureServer server;
  late LiveService service;

  setUp(() async {
    server = await TestFixtureServer.start();
    service = LiveService(cacheTtl: const Duration(minutes: 5));
  });

  tearDown(() async {
    service.close();
    await server.stop();
  });

  int liveRequests() => server.captured
      .where((request) => request.path.startsWith('/live'))
      .length;

  group('LiveService 加载（§13.1、§13.3）', () {
    test('HTTP 加载 M3U 并解析出分组与频道', () async {
      final source = LiveSource(
        name: 'fixture-m3u',
        type: LiveLineType.m3u,
        url: '${server.baseUrl}/live/live.m3u',
      );

      final result = await service.load(source);

      expect(result.fromCache, isFalse);
      expect(result.source.name, 'fixture-m3u');
      expect(result.playlist.channelCount, 6);
      expect(
        result.playlist.groups.map((group) => group.name),
        ['央视', '卫视', '未分组'],
      );
      expect(result.playlist.channelById('CCTV-1 综合')!.urls, hasLength(1));
    });

    test('HTTP 加载 TXT 与 JSON', () async {
      final txt = await service.load(
        LiveSource(
          name: 'fixture-txt',
          type: LiveLineType.txt,
          url: '${server.baseUrl}/live/live.txt',
        ),
      );
      expect(txt.playlist.channelById('CCTV-2 财经')!.urls, hasLength(2));

      final json = await service.load(
        LiveSource(
          name: 'fixture-json',
          type: LiveLineType.json,
          url: '${server.baseUrl}/live/live.json',
        ),
      );
      expect(json.playlist.channelCount, 4);
    });

    test('cacheTtl 内同 URL 命中缓存，不重复请求', () async {
      final source = LiveSource(
        name: 'cache',
        type: LiveLineType.m3u,
        url: '${server.baseUrl}/live/live.m3u',
      );

      final first = await service.load(source);
      final second = await service.load(source);

      expect(first.fromCache, isFalse);
      expect(second.fromCache, isTrue);
      // 只发生一次网络请求。
      expect(liveRequests(), 1);
    });

    test('invalidate 后强制重新拉取', () async {
      final source = LiveSource(
        name: 'cache',
        type: LiveLineType.m3u,
        url: '${server.baseUrl}/live/live.m3u',
      );
      await service.load(source);
      service.invalidate(source.url);
      final refreshed = await service.load(source);

      expect(refreshed.fromCache, isFalse);
      expect(liveRequests(), 2);
    });

    test('useCache=false 时跳过缓存', () async {
      final source = LiveSource(
        name: 'cache',
        type: LiveLineType.m3u,
        url: '${server.baseUrl}/live/live.m3u',
      );
      await service.load(source);
      final refreshed = await service.load(source, useCache: false);

      expect(refreshed.fromCache, isFalse);
      expect(liveRequests(), 2);
    });

    test('本地文件加载（GBK 编码的 TXT 直播清单）', () async {
      final dir = await Directory.systemTemp.createTemp('webhtv-live-');
      addTearDown(() => dir.delete(recursive: true));

      // GBK 字节：央=D1 EB、视=CA D3、频=C6 B5、道=B5 C0。
      // 正确 TXT 形态为 `分组名,#genre#`。
      final gbkBytes = <int>[
        ...[0xD1, 0xEB, 0xCA, 0xD3, ...utf8.encode(',#genre#\n')],
        ...[0xC6, 0xB5, 0xB5, 0xC0, ...utf8.encode(',http://h/a.m3u8\n')],
      ];
      final file = File(p.join(dir.path, 'live.txt'));
      await file.writeAsBytes(gbkBytes);

      final result = await service.load(
        LiveSource(name: 'local', type: LiveLineType.txt, url: file.path),
      );

      // GBK 兜底解码出中文分组名与频道名，未变成乱码。
      expect(result.playlist.groups.single.name, '央视');
      expect(result.playlist.allChannels.single.name, '频道');
      expect(result.playlist.allChannels.single.urls, ['http://h/a.m3u8']);
    });
  });

  group('LiveService 错误归一化（§8.4）', () {
    test('非 2xx → liveHttp，不返回空列表', () async {
      final source = LiveSource(
        name: 'missing',
        type: LiveLineType.m3u,
        url: '${server.baseUrl}/live/nope.m3u',
      );

      await expectLater(
        service.load(source),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.liveHttp)
              .having((e) => e.statusCode, 'statusCode', 404),
        ),
      );
    });

    test('缺 url → liveUnsupported', () async {
      await expectLater(
        service.load(LiveSource(name: 'no-url', type: LiveLineType.m3u)),
        throwsA(
          isA<AppError>().having((e) => e.kind, 'kind', AppErrorKind.liveUnsupported),
        ),
      );
    });

    test('不支持的协议 → liveUnsupported', () async {
      await expectLater(
        service.load(
          LiveSource(name: 'ftp', type: LiveLineType.m3u, url: 'ftp://h/a.m3u'),
        ),
        throwsA(
          isA<AppError>().having((e) => e.kind, 'kind', AppErrorKind.liveUnsupported),
        ),
      );
    });

    test('本地文件不存在 → liveInvalid', () async {
      await expectLater(
        service.load(
          LiveSource(
            name: 'gone',
            type: LiveLineType.m3u,
            url: p.join(Directory.systemTemp.path, 'definitely-missing-live.m3u'),
          ),
        ),
        throwsA(
          isA<AppError>().having((e) => e.kind, 'kind', AppErrorKind.liveInvalid),
        ),
      );
    });

    test('申明为 JSON 但内容非法 → liveInvalid 透传', () async {
      final dir = await Directory.systemTemp.createTemp('webhtv-live-bad-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File(p.join(dir.path, 'bad.json'));
      await file.writeAsString('{oops');

      await expectLater(
        service.load(
          LiveSource(name: 'bad', type: LiveLineType.json, url: file.path),
        ),
        throwsA(
          isA<AppError>().having((e) => e.kind, 'kind', AppErrorKind.liveInvalid),
        ),
      );
    });

    test('单源失败可被捕获而不影响后续源加载（§14.3）', () async {
      final bad = LiveSource(
        name: 'bad',
        type: LiveLineType.m3u,
        url: '${server.baseUrl}/live/nope.m3u',
      );
      final good = LiveSource(
        name: 'good',
        type: LiveLineType.m3u,
        url: '${server.baseUrl}/live/live.m3u',
      );

      final errors = <AppError>[];
      final loaded = <LivePlaylist>[];
      for (final source in [bad, good]) {
        try {
          loaded.add((await service.load(source)).playlist);
        } on AppError catch (error) {
          errors.add(error);
        }
      }

      expect(errors, hasLength(1));
      expect(loaded, hasLength(1));
      expect(loaded.single.channelCount, 6);
    });
  });
}
