import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/android_playback_bridge.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/services/spider_router.dart';

Site site(String base, {int type = 4, String path = '/vod/api'}) =>
    Site(key: 'bridge', name: '桥接', type: type, api: '$base$path?key=bridge');

void main() {
  test('站点播放解析使用分集目标，映射最终地址并保留 Header 与字幕', () async {
    final gateway = site('http://127.0.0.1:19978');
    final bridge = AndroidPlaybackBridge(
      runAdb: (_) async => ProcessResult(
        0,
        0,
        'assigned tcp:19978 tcp:9978\nassigned tcp:25001 tcp:5000',
        '',
      ),
    );
    final client = HttpApiClient(
      client: MockClient((request) async {
        expect(request.url.queryParameters['play'], '1@7865@0@1');
        expect(request.url.queryParameters['flag'], '丫仙女');
        return http.Response(
          jsonEncode({
            'parse': 0,
            'url': 'http://127.0.0.1:5000/proxy/pan115/episode-2',
            'header': {'User-Agent': '115Browser'},
            'subs': [
              {'url': 'https://cdn.example/ep2.srt', 'name': '中文'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final router = SpiderRouter(client: client, globalHeaders: const []);
    final service = SiteService(
      appConfig: AppConfig(sites: [gateway]),
      router: router,
      playbackBridge: bridge,
    );
    addTearDown(router.dispose);
    addTearDown(bridge.close);
    final result = await service.resolvePlayback(
      site: gateway,
      episodeTarget: '1@7865@0@1',
      flag: '丫仙女',
    );
    expect(result.value.url, 'http://127.0.0.1:25001/proxy/pan115/episode-2');
    expect(result.value.headers?['User-Agent'], '115Browser');
    expect(result.value.flag, '丫仙女');
    expect(result.value.subs.single.url, 'https://cdn.example/ep2.srt');
  });

  test('关闭时等待创建中的转发并回收，播放请求不再使用已关闭桥接', () async {
    final created = Completer<ProcessResult>();
    final started = Completer<void>();
    var listed = 'assigned tcp:19978 tcp:9978';
    var removed = false;
    final bridge = AndroidPlaybackBridge(
      runAdb: (args) async {
        if (args.contains('--list')) return ProcessResult(0, 0, listed, '');
        if (args.contains('--remove')) {
          removed = true;
          return ProcessResult(0, 0, '', '');
        }
        started.complete();
        return created.future;
      },
    );
    final pending = bridge.resolve(
      site('http://127.0.0.1:19978'),
      'http://localhost:5000/proxy/file',
    );
    final rejected = expectLater(pending, throwsA(isA<AppError>()));
    await started.future;
    final closing = bridge.close();
    listed += '\nassigned tcp:26000 tcp:5000';
    created.complete(ProcessResult(0, 0, '26000', ''));
    await closing;
    await rejected;
    expect(removed, isTrue);
  });

  test('局域网桥接保留代理端口、路径和签名，仅替换 Android 回环主机', () async {
    final bridge = AndroidPlaybackBridge(
      runAdb: (_) async => throw StateError('不应调用 adb'),
    );
    expect(
      await bridge.resolve(
        site('http://192.168.1.20:9978'),
        'http://127.0.0.1:5000/proxy/pan115/2/1024/id?sign=a%2Bb',
      ),
      'http://192.168.1.20:5000/proxy/pan115/2/1024/id?sign=a%2Bb',
    );
    await bridge.close();
  });

  test('只处理 Android T4 网关返回的回环地址', () async {
    final bridge = AndroidPlaybackBridge(
      runAdb: (_) async => throw StateError('不应调用 adb'),
    );
    const proxy = 'http://127.0.0.1:5000/proxy/file';
    expect(
      await bridge.resolve(site('http://192.168.1.20:9978', type: 1), proxy),
      proxy,
    );
    expect(
      await bridge.resolve(
        site('http://192.168.1.20:3000', path: '/video/api'),
        proxy,
      ),
      proxy,
    );
    expect(
      await bridge.resolve(
        site('http://127.0.0.1:19978'),
        'https://cdn.example/video.mp4',
      ),
      'https://cdn.example/video.mp4',
    );
    await bridge.close();
  });

  test('按网关转发识别设备，动态映射媒体端口，退出只清理自己创建的映射', () async {
    final calls = <List<String>>[];
    final forwards = <String>[
      'device-other tcp:19979 tcp:9978',
      'device-5559 tcp:19978 tcp:9978',
      'device-other tcp:5000 tcp:5000',
    ];
    final bridge = AndroidPlaybackBridge(
      runAdb: (args) async {
        calls.add(args);
        if (args.join(' ') == 'forward --list') {
          return ProcessResult(0, 0, forwards.join('\n'), '');
        }
        if (args.contains('--remove')) {
          expect(args, [
            '-s',
            'device-5559',
            'forward',
            '--remove',
            'tcp:25000',
          ]);
          forwards.remove('device-5559 tcp:25000 tcp:5000');
          return ProcessResult(0, 0, '', '');
        }
        expect(args, ['-s', 'device-5559', 'forward', 'tcp:0', 'tcp:5000']);
        forwards.add('device-5559 tcp:25000 tcp:5000');
        return ProcessResult(0, 0, '25000\n', '');
      },
    );
    final gateway = site('http://127.0.0.1:19978');
    expect(
      await bridge.resolve(gateway, 'http://127.0.0.1:5000/proxy/pan115/id'),
      'http://127.0.0.1:25000/proxy/pan115/id',
    );
    expect(
      await bridge.resolve(gateway, 'http://localhost:5000/proxy/pan115/next'),
      'http://127.0.0.1:25000/proxy/pan115/next',
    );
    expect(calls.where((args) => args.contains('tcp:0')).length, 1);
    await bridge.close();
    expect(forwards.length, 3);
    expect(forwards, contains('device-other tcp:5000 tcp:5000'));
  });

  test('已有媒体转发会复用，网关自身端口映射到当前入口', () async {
    final bridge = AndroidPlaybackBridge(
      runAdb: (args) async {
        expect(args, ['forward', '--list']);
        return ProcessResult(
          0,
          0,
          'assigned tcp:19978 tcp:9978\nassigned tcp:25001 tcp:5000\n',
          '',
        );
      },
    );
    final gateway = site('http://localhost:19978');
    expect(
      await bridge.resolve(gateway, 'http://127.0.0.1:9978/proxy?id=1'),
      'http://127.0.0.1:19978/proxy?id=1',
    );
    expect(
      await bridge.resolve(gateway, 'http://[::1]:5000/proxy/file'),
      'http://127.0.0.1:25001/proxy/file',
    );
    await bridge.close();
  });

  test('没有匹配设备时明确报错，不把 Android 地址误交给 PC 播放器', () async {
    final bridge = AndroidPlaybackBridge(
      runAdb: (_) async =>
          ProcessResult(0, 0, 'other tcp:19979 tcp:9978\n', ''),
    );
    await expectLater(
      bridge.resolve(
        site('http://127.0.0.1:19978'),
        'http://127.0.0.1:5000/proxy/file',
      ),
      throwsA(
        isA<AppError>().having(
          (e) => e.kind,
          'kind',
          AppErrorKind.bridgeUnreachable,
        ),
      ),
    );
    await bridge.close();
  });
}
