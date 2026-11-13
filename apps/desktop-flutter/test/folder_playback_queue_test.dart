import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/state/folder_browser_state.dart';
import 'package:webhtv_pc/state/folder_playback_queue.dart';

void main() {
  late AppState state;
  late FolderBrowserState browser;
  late FolderPlaybackQueue queue;
  late Directory dir;
  late Future<http.Response> Function(Uri) respond;
  final calls = <Uri>[];
  http.Response body(Object value) => http.Response(
    jsonEncode(value),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
  Map<String, Object?> file(String id, String name, {String tag = 'file'}) => {
    'vod_id': id,
    'vod_name': name,
    'vod_tag': tag,
  };
  Map<String, Object?> page(List<Object> items, {int count = 5}) => {
    'list': items,
    'pagecount': count,
  };

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('folder-queue-');
    calls.clear();
    respond = (_) async => body({'list': []});
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${dir.path}/config',
          'data': '${dir.path}/data',
          'cache': '${dir.path}/cache',
          'state': '${dir.path}/state',
        },
      ),
      log: LogService(),
      httpClient: MockClient((request) {
        calls.add(request.url);
        return respond(request.url);
      }),
    );
    await state.bootstrap();
    await state.importConfig(
      jsonEncode({
        'sites': [
          {
            'key': 'fixture',
            'name': '原来源',
            'type': 4,
            'api': 'https://fixture.invalid/api',
          },
        ],
      }),
    );
    browser = FolderBrowserState(
      service: state.siteService!,
      site: state.selectedSite!,
      folder: Vod(vodId: '/目录?原样 &值', vodName: '目录', vodTag: 'folder'),
      filters: {'sort': '原样 /&值'},
    );
    queue = FolderPlaybackQueue(
      state: state,
      browser: browser,
      sourceKey: state.activeSourceKey,
      resumeItemKey: 'f2',
    );
    calls.clear();
  });
  tearDown(() async {
    queue.dispose();
    browser.dispose();
    state.dispose();
    await dir.delete(recursive: true);
  });

  test('natural queue excludes folders attachments actions without detail prefetch', () async {
    respond = (_) async => body(
      page([
        file('f10', '第10集.mp4'),
        file('f2', '第2集.mkv'),
        file('f1', '第1集'),
        file('dir', '子目录', tag: 'folder'),
        file('txt', '说明.txt'),
        file('srt', '字幕.srt'),
        file('action', '刷新', tag: 'action'),
      ], count: 1),
    );
    await browser.load();
    expect(queue.snapshot.items.map((i) => i.key), ['f1', 'f2', 'f10']);
    expect(calls.where((u) => u.queryParameters.containsKey('ids')), isEmpty);
  });

  test('loadMore skips directory and attachment pages then merges stable natural keys', () async {
    respond = (uri) async => body(switch (uri.queryParameters['pg']) {
      '1' => page([file('f2', '第2集.mp4'), file('f10', '第10集.mp4')]),
      '2' => page([file('dir', '子目录', tag: 'folder')]),
      '3' => page([file('srt', '字幕.srt')]),
      _ => page([file('f2', '第2集.mp4'), file('f1', '第1集.mp4')], count: 4),
    });
    await browser.load();
    await queue.loadMore();
    expect(queue.snapshot.items.map((i) => i.key), ['f1', 'f2', 'f10']);
    expect(queue.snapshot.hasMore, isFalse);
    expect(calls.map((u) => u.queryParameters['pg']), ['1', '2', '3', '4']);
    for (final uri in calls) {
      expect(uri.queryParameters['t'], '/目录?原样 &值');
      expect(
        jsonDecode(
          utf8.decode(
            base64Url.decode(base64Url.normalize(uri.queryParameters['ext']!)),
          ),
        ),
        {'sort': '原样 /&值'},
      );
    }
  });

  test('known pagination continues past duplicate pages without losing unseen video', () async {
    respond = (uri) async => body(
      page([
        file(
          uri.queryParameters['pg'] == '3' ? 'f2' : 'f1',
          uri.queryParameters['pg'] == '3' ? '第2集.mp4' : '第1集.mp4',
        ),
      ], count: 3),
    );
    await browser.load();
    await queue.loadMore();
    expect(queue.snapshot.items.map((i) => i.key), ['f1', 'f2']);
    expect(calls.map((u) => u.queryParameters['pg']), ['1', '2', '3']);
  });

  test(
    'queue page failure retains hasMore and retry uses the failed page',
    () async {
      var failing = true;
      respond = (uri) async => body(
        uri.queryParameters['pg'] == '1'
            ? page([file('f1', '第1集.mp4')], count: 2)
            : failing
            ? {'code': -1, 'msg': '暂时失败'}
            : page([file('f2', '第2集.mp4')], count: 2),
      );
      await browser.load();
      await queue.loadMore();
      expect(queue.snapshot.error, isNotNull);
      expect(queue.snapshot.hasMore, isTrue);
      expect(queue.snapshot.items.single.key, 'f1');
      failing = false;
      await queue.loadMore();
      expect(queue.snapshot.error, isNull);
      expect(queue.snapshot.items.map((i) => i.key), ['f1', 'f2']);
      expect(calls.map((u) => u.queryParameters['pg']), ['1', '2', '2']);
    },
  );

  test(
    'selected file resolves lazily with its own complete identity and assets',
    () async {
      respond = (uri) async {
        if (uri.queryParameters['t'] != null) {
          return body(
            page([file('f2', '第2集'), file('f10', '第10集.mp4')], count: 1),
          );
        }
        if (uri.queryParameters['ids'] != null) {
          return body({
            'list': [
              {
                'vod_id': 'f2',
                'vod_name': '第2集详情',
                'vod_play_from': '原线路',
                'vod_play_url': r'正片$opaque-target-2',
              },
            ],
          });
        }
        return body({
          'url': [
            {'name': '原画', 'url': 'http://127.0.0.1/video.mp4'},
          ],
          'parse': 0,
          'header': {'Referer': 'original', 'Cookie': 'file2'},
          'subs': [
            {'url': 'http://127.0.0.1/file2.srt', 'name': '中文'},
          ],
          'danmaku': [
            {'url': 'http://127.0.0.1/file2.xml', 'name': '弹幕'},
          ],
          'urls': [
            {'name': '原画', 'url': 'http://127.0.0.1/video.mp4'},
          ],
        });
      };
      await browser.load();
      final selected = state.selectedSite;
      final category = state.categoryResult;
      final request = await queue.resolve('f2');
      expect(request.vodId, 'f2');
      expect(request.siteKey, 'fixture');
      expect(request.sourceKey, state.activeSourceKey);
      expect(request.episodeTarget, 'opaque-target-2');
      expect(request.flag, '原线路');
      expect(request.playbackFlag, '原线路');
      expect(request.headers['Cookie'], 'file2');
      expect(request.subtitleHeaders['Referer'], 'original');
      expect(request.subtitles.single.name, '中文');
      expect(request.danmaku.single.name, '弹幕');
      expect(request.qualities.single.name, '原画');
      expect(request.tmdb, isNull);
      expect(state.selectedSite, same(selected));
      expect(state.categoryResult, same(category));
      expect(state.detailResult, isNull);
      expect(
        calls
            .where((u) => u.queryParameters['ids'] != null)
            .map((u) => u.queryParameters['ids']),
        ['f2'],
      );
      expect(calls.last.queryParameters['play'], 'opaque-target-2');
    },
  );

  test('initial resume belongs to the actual file and never carries into another file', () async {
    respond = (uri) async {
      if (uri.queryParameters['t'] != null) {
        return body(
          page([file('f2', '第2集.mp4'), file('f10', '第10集.mp4')], count: 1),
        );
      }
      if (uri.queryParameters['ids'] != null) {
        return body({
          'list': [
            {
              'vod_id': uri.queryParameters['ids'],
              'vod_name': '文件详情',
              'vod_play_from': '线路',
              'vod_play_url': r'正片$entry',
            },
          ],
        });
      }
      return body({'url': 'http://127.0.0.1/video.mp4'});
    };
    state.recordProgress(
      vod: Vod(vodId: 'f2', vodName: '第2集.mp4'),
      flag: '线路',
      episodeName: '正片',
      episodeId: 'entry',
      position: const Duration(seconds: 35),
      duration: const Duration(minutes: 5),
      siteKey: 'fixture',
      sourceKey: state.activeSourceKey,
    );
    state.recordProgress(
      vod: Vod(vodId: 'f10', vodName: '第10集.mp4'),
      flag: '线路',
      episodeName: '正片',
      episodeId: 'entry',
      position: const Duration(seconds: 65),
      duration: const Duration(minutes: 5),
      siteKey: 'fixture',
      sourceKey: state.activeSourceKey,
    );
    state.recordProgress(
      vod: Vod(vodId: '/目录?原样 &值', vodName: '目录'),
      flag: '线路',
      episodeName: '正片',
      episodeId: 'entry',
      position: const Duration(seconds: 80),
      duration: const Duration(minutes: 5),
      siteKey: 'fixture',
      sourceKey: state.activeSourceKey,
    );
    await browser.load();
    final initial = await queue.resolve('f2');
    final next = await queue.resolve('f10');
    expect(initial.startPosition, const Duration(seconds: 35));
    expect(next.vodId, 'f10');
    expect(next.startPosition, isNull);
    expect(next.resumeSeed, isNull);
    expect((await queue.resolve('f2')).startPosition, isNull);
    expect((await queue.resolve('f10')).startPosition, isNull);
  });

  test('stale play response preserves the previous proxy decision', () async {
    final started = Completer<void>();
    final pending = Completer<http.Response>();
    var stall = false;
    respond = (uri) async {
      if (uri.queryParameters['t'] != null) {
        return body(page([file('f2', '第2集')], count: 1));
      }
      if (uri.queryParameters['ids'] != null) {
        return body({
          'list': [
            {
              'vod_id': 'f2',
              'vod_name': '第2集',
              'vod_play_from': '线路',
              'vod_play_url': r'正片$entry-2',
            },
          ],
        });
      }
      if (!stall) return body({'url': 'http://127.0.0.1/first.mp4'});
      if (!started.isCompleted) started.complete();
      return pending.future;
    };
    await browser.load();
    final accepted = await queue.resolve('f2');
    final previous = state.lastDecision;
    expect(previous, isNotNull);
    stall = true;
    var current = true;
    final resolving = queue.resolve('f2', isCurrent: () => current);
    final assertion = expectLater(resolving, throwsA(isA<AppError>()));
    await started.future;
    current = false;
    pending.complete(body({'url': 'http://127.0.0.1/stale.mp4'}));
    await assertion;
    expect(accepted.url, 'http://127.0.0.1/first.mp4');
    expect(state.lastDecision, same(previous), reason: '过期响应不得覆盖上一决策');
  });

  test(
    'attachment dot filters real subtitles but keeps suffixless titles',
    () async {
      respond = (_) async => body(
        page([
          file('v1', '1.mkv'),
          file('v2', 'mysrt'),
          file('v3', '无后缀影片'),
          file('v4', '第1集.srt'),
          file('v5', '说明.ass'),
          file('v6', '封面.PNG'),
        ], count: 1),
      );
      await browser.load();
      expect(queue.snapshot.items.map((i) => i.key), ['v1', 'v2', 'v3']);
    },
  );

  test(
    'concurrent loadMore joins the running page instead of returning early',
    () async {
      final pending = Completer<http.Response>();
      respond = (uri) async {
        if (uri.queryParameters['pg'] == '1') {
          return body(page([file('f1', '第1集.mp4')], count: 2));
        }
        return pending.future;
      };
      await browser.load();
      final first = queue.loadMore();
      var secondDone = false;
      final second = queue.loadMore().then((_) => secondDone = true);
      await Future<void>.delayed(Duration.zero);
      expect(secondDone, isFalse, reason: '并发 loadMore 必须等待在途分页');
      pending.complete(body(page([file('f2', '第2集.mp4')], count: 2)));
      await Future.wait([first, second]);
      expect(queue.snapshot.items.map((i) => i.key), ['f1', 'f2']);
      expect(calls.where((u) => u.queryParameters['pg'] == '2'), hasLength(1));
    },
  );

  test(
    'disposing route completes queue load waiting on browser without new page',
    () async {
      final pending = Completer<http.Response>();
      respond = (_) => pending.future;
      final loadingBrowser = browser.load();
      var queueDone = false;
      final loadingQueue = queue.loadMore().then((_) => queueDone = true);
      queue.dispose();
      browser.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(queueDone, isTrue, reason: '路由取消必须结束等待，不靠已 dispose 浏览器通知');
      pending.complete(body(page([file('f2', '第2集.mp4')], count: 3)));
      await Future.wait([loadingQueue, loadingBrowser]);
      expect(calls.map((u) => u.queryParameters['pg']), ['1']);
      // teardown owns fresh disposed-safe objects after this route was removed.
      browser = FolderBrowserState(
        service: state.siteService!,
        site: state.selectedSite!,
        folder: Vod(vodId: 'unused', vodName: 'unused', vodTag: 'folder'),
      );
      queue = FolderPlaybackQueue(state: state, browser: browser);
    },
  );

  test('authoritative detail identity feeds player and history while key stays stable', () async {
    respond = (uri) async {
      if (uri.queryParameters['t'] != null) {
        return body(page([file('f2', '第2集.mp4')], count: 1));
      }
      if (uri.queryParameters['ids'] != null) {
        return body({
          'list': [
            {
              'vod_id': 'f2-canonical',
              'vod_name': '权威文件名',
              'vod_tag': 'file',
              'vod_play_from': '线路',
              'vod_play_url': r'正片$canonical-entry',
            },
          ],
        });
      }
      return body({'url': 'http://127.0.0.1/video.mp4'});
    };
    state.recordProgress(
      vod: Vod(vodId: 'f2-canonical', vodName: '权威文件名'),
      flag: '线路',
      episodeName: '第2集.mp4',
      episodeId: 'canonical-entry',
      position: const Duration(seconds: 42),
      duration: const Duration(minutes: 5),
      siteKey: 'fixture',
      sourceKey: state.activeSourceKey,
    );
    await browser.load();
    expect(queue.snapshot.items.single.key, 'f2');
    final request = await queue.resolve('f2');
    expect(
      calls
          .singleWhere((u) => u.queryParameters['ids'] != null)
          .queryParameters['ids'],
      'f2',
    );
    expect(request.vodId, 'f2-canonical');
    expect(request.vodName, '权威文件名');
    expect(request.episodeName, '第2集.mp4');
    expect(request.episodeTarget, 'canonical-entry');
    expect(request.startPosition, const Duration(seconds: 42));
    expect(queue.snapshot.items.single.key, 'f2');
  });

  test('stale selected detail never enters player resolution or overwrites decision', () async {
    final pending = Completer<http.Response>();
    respond = (uri) async => uri.queryParameters['t'] != null
        ? body(page([file('f2', '第2集')], count: 1))
        : pending.future;
    await browser.load();
    var current = true;
    final resolving = queue.resolve('f2', isCurrent: () => current);
    final assertion = expectLater(resolving, throwsA(isA<AppError>()));
    current = false;
    pending.complete(
      body({
        'list': [
          {
            'vod_id': 'f2',
            'vod_name': '第2集',
            'vod_play_from': '线路',
            'vod_play_url': r'正片$entry-2',
          },
        ],
      }),
    );
    await assertion;
    expect(calls.where((u) => u.queryParameters['play'] != null), isEmpty);
    expect(state.lastDecision, isNull);
  });
}
