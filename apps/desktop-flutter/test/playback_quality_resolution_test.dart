/// 当前集多画质（多播放地址候选）解析与选定画质播放链回归测试。
///
/// 合同（与并行 UI 任务共享）：
/// - `PlaybackQuality { name, url }`；`SiteResult.qualities` / `PlaybackDecision.qualities`
///   存未代理的原始候选列表；`qualityIndex` 为当前选中画质下标。
/// - `SiteService.resolvePlayback` / `AppState.resolvePlayback*` 增可选
///   `int? qualityIndex`，null 按结果默认（RAW 优先 / 对象 position），显式 index
///   选择对应当前重新取得的画质。
/// - `urls`（复数）是配置仓库键，不是画质；桥接/代理重建不得丢候选、不得提前
///   为所有候选发请求。
library;

import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/state/playback_source_context.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/services/app_paths.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/services/spider_router.dart';
import 'package:webhtv_pc/services/parse_service.dart';
import 'package:webhtv_pc/services/android_playback_bridge.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/playback.dart';
import 'package:webhtv_pc/core/protocol.dart';

SiteResult _parse(Map<String, Object?> playResult) =>
    HttpApiResponseParser.parse(jsonEncode(playResult), siteKey: 't');

void main() {
  test('原来源旧请求在proxy返回时已过期，返回null且新token保持有效', () async {
    final temp = await Directory.systemTemp.createTemp(
      'webhtv-quality-source-current-',
    );
    final site = Site(key: 't', name: 't', type: 4, api: 'https://gateway/api');
    final router = SpiderRouter(
      globalHeaders: const [],
      client: HttpApiClient(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'url': [
                'RAW',
                'https://cdn-a/raw.m3u8',
                'HD',
                'https://cdn-b/hd.m3u8',
              ],
              'header': {'Referer': 'entry'},
            }),
            200,
          ),
        ),
      ),
    );
    addTearDown(router.dispose);
    final config = AppConfig(sites: [site]);
    final state = _SourceQualityState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/webhtv-pc',
          'data': '${temp.path}/webhtv-pc',
          'cache': '${temp.path}/webhtv-pc/cache',
          'state': '${temp.path}/webhtv-pc/logs',
        },
      ),
      context: PlaybackSourceContext(
        sourceKey: 'source',
        record: ConfigRecord(
          id: 1,
          name: 'test',
          origin: 'fixture',
          updatedAt: DateTime(2026),
          siteCount: 1,
          liveCount: 0,
        ),
        config: config,
        service: SiteService(appConfig: config, router: router),
      ),
    );
    addTearDown(() async {
      await state.stopProxy();
      state.dispose();
      await temp.delete(recursive: true);
    });
    var oldCurrent = true;
    final old = state.resolvePlaybackForSource(
      sourceKey: 'source',
      siteKey: 't',
      episodeTarget: 'old',
      qualityIndex: 0,
      isCurrent: () => oldCurrent,
    );
    await state.oldProxied.future;
    oldCurrent = false;
    final fresh = await state.resolvePlaybackForSource(
      sourceKey: 'source',
      siteKey: 't',
      episodeTarget: 'new',
      qualityIndex: 1,
      isCurrent: () => true,
    );
    final token = Uri.parse(fresh!.url!).pathSegments[1];
    expect(state.proxySessions.byToken(token), isNotNull);
    state.releaseOld.complete();
    expect(await old, isNull, reason: 'proxy await后也要检查原来源结果时效');
    expect(state.proxySessions.byToken(token), isNotNull);
    expect(
      state.proxySessionFingerprint,
      state.proxySessions.byToken(token)!.fingerprint,
    );
  });
  for (final oldFails in [false, true]) {
    test('过期旧画质${oldFails ? "失败" : "成功"}返回不能撤销新token或污染lastDecision', () async {
      final temp = await Directory.systemTemp.createTemp(
        'webhtv-quality-current-',
      );
      final state = AppState(
        paths: AppPaths.resolve(
          overrides: {
            'config': '${temp.path}/webhtv-pc',
            'data': '${temp.path}/webhtv-pc',
            'cache': '${temp.path}/webhtv-pc/cache',
            'state': '${temp.path}/webhtv-pc/logs',
          },
        ),
      );
      addTearDown(() async {
        await state.stopProxy();
        state.dispose();
        await temp.delete(recursive: true);
      });
      final oldResponse = Completer<http.Response>();
      final oldStarted = Completer<void>();
      var oldCurrent = true;
      http.Response response() => http.Response(
        jsonEncode({
          'url': [
            'RAW',
            'https://cdn-a/raw.m3u8',
            'HD',
            'https://cdn-b/hd.m3u8',
          ],
          'header': {'Referer': 'entry'},
        }),
        200,
      );
      final site = Site(
        key: 't',
        name: 't',
        type: 4,
        api: 'https://gateway/api',
      );
      final router = SpiderRouter(
        globalHeaders: const [],
        client: HttpApiClient(
          client: MockClient((request) async {
            if (request.url.queryParameters['play'] == 'old') {
              oldStarted.complete();
              return oldResponse.future;
            }
            return response();
          }),
        ),
      );
      addTearDown(router.dispose);
      final service = SiteService(
        appConfig: AppConfig(sites: [site]),
        router: router,
      );
      var notifications = 0;
      state.addListener(() {
        notifications++;
      });
      final oldFuture = state.resolvePlayback(
        episodeTarget: 'old',
        siteOverride: site,
        serviceOverride: service,
        qualityIndex: 0,
        isCurrent: () => oldCurrent,
      );
      await oldStarted.future;
      oldCurrent = false;
      final fresh = await state.resolvePlayback(
        episodeTarget: 'new',
        siteOverride: site,
        serviceOverride: service,
        qualityIndex: 1,
        isCurrent: () => true,
      );
      final token = Uri.parse(fresh!.url!).pathSegments[1];
      expect(state.proxySessions.byToken(token), isNotNull);
      final count = notifications;
      oldResponse.complete(
        oldFails ? http.Response('old failed', 500) : response(),
      );
      expect(await oldFuture, isNull);
      expect(state.proxySessions.byToken(token), isNotNull);
      expect(state.lastDecision, same(fresh));
      expect(state.lastDecision?.qualityIndex, 1);
      expect(state.lastError, isNull);
      expect(notifications, count, reason: '过期结果不提交全局状态或通知');
    });
  }
  test('proxy启动await后已过期不能创建会话', () async {
    final temp = await Directory.systemTemp.createTemp(
      'webhtv-quality-proxy-current-',
    );
    final state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/webhtv-pc',
          'data': '${temp.path}/webhtv-pc',
          'cache': '${temp.path}/webhtv-pc/cache',
          'state': '${temp.path}/webhtv-pc/logs',
        },
      ),
    );
    addTearDown(() async {
      await state.stopProxy();
      state.dispose();
      await temp.delete(recursive: true);
    });
    var current = true;
    var notifications = 0;
    state.addListener(() {
      notifications++;
    });
    final pending = state.proxyDecision(
      PlaybackDecision(
        action: PlaybackAction.direct,
        url: 'https://cdn-a/raw.m3u8',
        headers: HeaderMap({'Referer': 'entry'}),
      ),
      siteKey: 't',
      isCurrent: () => current,
    );
    current = false;
    await pending;
    expect(state.proxySessions.activeSessions, isEmpty);
    expect(state.proxySessionFingerprint, isNull);
    expect(notifications, 0);
  });
  test('AppState转交显式索引，本地代理重建保留原始候选和附加请求头', () async {
    final temp = await Directory.systemTemp.createTemp('webhtv-quality-proxy-');
    final state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/webhtv-pc',
          'data': '${temp.path}/webhtv-pc',
          'cache': '${temp.path}/webhtv-pc/cache',
          'state': '${temp.path}/webhtv-pc/logs',
        },
      ),
    );
    addTearDown(() async {
      await state.stopProxy();
      state.dispose();
      await temp.delete(recursive: true);
    });
    final site = Site(key: 't', name: 't', type: 4, api: 'https://gateway/api');
    final router = SpiderRouter(
      globalHeaders: const [],
      client: HttpApiClient(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'url': [
                'RAW',
                'https://cdn-a/raw.m3u8',
                'HD',
                'https://cdn-b/hd.m3u8',
              ],
              'header': {'Referer': 'entry'},
              'subs': [
                {'url': 'https://cdn-b/sub.srt'},
              ],
              'danmaku': 'https://cdn-b/danmaku.xml',
            }),
            200,
          ),
        ),
      ),
    );
    addTearDown(router.dispose);
    final service = SiteService(
      appConfig: AppConfig(sites: [site]),
      router: router,
    );
    final decision = await state.resolvePlayback(
      episodeTarget: 'id',
      siteOverride: site,
      serviceOverride: service,
      qualityIndex: 1,
    );
    expect(decision, isNotNull);
    expect(Uri.parse(decision!.url!).host, '127.0.0.1');
    expect(decision.qualities.map((q) => q.url), [
      'https://cdn-a/raw.m3u8',
      'https://cdn-b/hd.m3u8',
    ]);
    expect(decision.qualityIndex, 1);
    expect(decision.headers?.isEmpty, isTrue);
    expect(decision.assetHeaders?['Referer'], 'entry');
    expect(decision.subs.single.url, 'https://cdn-b/sub.srt');
    expect(decision.danmaku.single.url, 'https://cdn-b/danmaku.xml');
  });
  group('SiteService 选定画质全链路', () {
    for (final shape in ['flat', 'values']) {
      test('结构化$shape候选保留opaque输入，只解析所选一条', () async {
        var parseCalls = 0;
        final site = Site(
          key: 't',
          name: 't',
          type: 4,
          api: 'https://gateway/api',
        );
        final router = SpiderRouter(
          globalHeaders: const [],
          client: HttpApiClient(
            client: MockClient(
              (_) async => http.Response(
                jsonEncode({
                  'parse': 1,
                  'url': shape == 'flat'
                      ? ['高清', 'opaque-a', '超清', 'opaque-b']
                      : {
                          'values': [
                            {'n': '高清', 'v': 'opaque-a'},
                            {'n': '超清', 'v': 'opaque-b'},
                          ],
                          'position': 0,
                        },
                }),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'},
              ),
            ),
          ),
        );
        final parser = ParseService(
          client: MockClient((request) async {
            parseCalls++;
            expect(request.url.queryParameters['url'], 'opaque-b');
            return http.Response(
              jsonEncode({'url': 'https://media/final.m3u8'}),
              200,
            );
          }),
        );
        addTearDown(router.dispose);
        addTearDown(parser.close);
        final service = SiteService(
          appConfig: AppConfig(
            sites: [site],
            parses: [
              ParseEntry(name: 'json', type: 1, url: 'https://parser/?url='),
            ],
          ),
          router: router,
        );
        final decision = (await service.resolvePlayback(
          site: site,
          episodeTarget: 'id',
          qualityIndex: 1,
          parseService: parser,
        )).value;
        expect(decision.url, 'https://media/final.m3u8');
        expect(decision.qualityIndex, 1);
        expect(decision.qualities.map((q) => q.name), ['高清', '超清']);
        expect(decision.qualities.map((q) => q.url), ['opaque-a', 'opaque-b']);
        expect(parseCalls, 1);
      });
    }
    test('结构化opaque候选依旧走playUrl前缀，坏条目不变名称媒体地址', () async {
      final site = Site(
        key: 't',
        name: 't',
        type: 4,
        api: 'https://gateway/api',
        extra: {'playUrl': 'https://media/video?id='},
      );
      final router = SpiderRouter(
        globalHeaders: const [],
        client: HttpApiClient(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'url': ['RAW', 'opaque-a', '无效', null, '超清', 'opaque-b'],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            ),
          ),
        ),
      );
      addTearDown(router.dispose);
      final service = SiteService(
        appConfig: AppConfig(sites: [site]),
        router: router,
      );
      final decision = (await service.resolvePlayback(
        site: site,
        episodeTarget: 'id',
        qualityIndex: 1,
      )).value;
      expect(decision.url, 'https://media/video?id=opaque-b');
      expect(decision.qualityIndex, 1);
      expect(decision.qualities.map((q) => q.name), ['RAW', '超清']);
      expect(decision.qualities.map((q) => q.url), ['opaque-a', 'opaque-b']);
    });
    test('显式索引使用重新取回的候选，headers按所选host合并，每次仅请求播放入口', () async {
      var calls = 0;
      final site = Site(
        key: 't',
        name: 't',
        type: 4,
        api: 'https://gateway/api',
      );
      final client = HttpApiClient(
        client: MockClient((request) async {
          calls++;
          expect(request.url.queryParameters['play'], 'episode-id');
          return http.Response(
            jsonEncode({
              'url': [
                'RAW',
                'https://cdn-a/old.m3u8',
                '超清',
                'https://cdn-b/fresh-$calls.m3u8',
              ],
              'header': {'Referer': 'entry', 'X-Result': 'yes'},
              'subs': [
                {'name': '中文', 'url': 'https://cdn-b/sub.srt'},
              ],
              'danmaku': 'https://cdn-b/danmaku.xml',
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final router = SpiderRouter(client: client, globalHeaders: const []);
      addTearDown(router.dispose);
      final service = SiteService(
        appConfig: AppConfig(
          sites: [site],
          headers: [
            HeaderRule.fromJson({
              'host': 'cdn-a',
              'header': {'X-Host': 'a'},
            })!,
            HeaderRule.fromJson({
              'host': 'cdn-b',
              'header': {'X-Host': 'b'},
            })!,
          ],
        ),
        router: router,
      );
      for (var i = 1; i <= 2; i++) {
        final decision = (await service.resolvePlayback(
          site: site,
          episodeTarget: 'episode-id',
          qualityIndex: 1,
        )).value;
        expect(decision.url, 'https://cdn-b/fresh-$i.m3u8');
        expect(decision.qualityIndex, 1);
        expect(decision.qualities.map((q) => q.name), ['RAW', '超清']);
        expect(decision.qualities.last.url, decision.url);
        expect(decision.headers?['X-Host'], 'b');
        expect(decision.headers?['Referer'], 'entry');
        expect(decision.subs.single.url, 'https://cdn-b/sub.srt');
        expect(decision.danmaku.single.url, 'https://cdn-b/danmaku.xml');
      }
      expect(calls, 2, reason: '重取两次，不预解析/请求其余候选');
    });

    test('对象默认position与越界显式索引回退上游默认', () async {
      final site = Site(
        key: 't',
        name: 't',
        type: 4,
        api: 'https://gateway/api',
      );
      final router = SpiderRouter(
        globalHeaders: const [],
        client: HttpApiClient(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'url': {
                  'values': [
                    {'n': 'RAW', 'v': 'https://a/a.m3u8'},
                    {'n': '高清', 'v': 'https://b/b.m3u8'},
                  ],
                  'position': 1,
                },
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            ),
          ),
        ),
      );
      addTearDown(router.dispose);
      final service = SiteService(
        appConfig: AppConfig(sites: [site]),
        router: router,
      );
      for (final index in [null, -1, 100]) {
        final decision = (await service.resolvePlayback(
          site: site,
          episodeTarget: 'id',
          qualityIndex: index,
        )).value;
        expect(decision.url, 'https://b/b.m3u8');
        expect(decision.qualityIndex, 1);
      }
    });

    test('只解析所选候选并保留入口header字幕弹幕及候选列表', () async {
      var playCalls = 0;
      var parseCalls = 0;
      final site = Site(
        key: 't',
        name: 't',
        type: 4,
        api: 'https://gateway/api',
        header: HeaderMap({'X-Site': 'site'}),
      );
      final router = SpiderRouter(
        globalHeaders: const [],
        client: HttpApiClient(
          client: MockClient((_) async {
            playCalls++;
            return http.Response(
              jsonEncode({
                'url': [
                  'RAW',
                  'https://web-a/watch',
                  '高清',
                  'https://web-b/watch',
                ],
                'parse': 1,
                'header': {'Referer': 'entry', 'X-Entry': 'entry'},
                'subs': [
                  {'url': 'https://a/original.srt'},
                ],
                'danmaku': 'https://a/danmaku.xml',
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        ),
      );
      final parser = ParseService(
        client: MockClient((request) async {
          parseCalls++;
          expect(request.url.queryParameters['url'], 'https://web-b/watch');
          return http.Response(
            jsonEncode({
              'url': 'https://media/final.m3u8',
              'header': {'Referer': 'parser'},
              'subs': [
                {'url': 'https://a/parsed.srt'},
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      addTearDown(router.dispose);
      addTearDown(parser.close);
      final service = SiteService(
        appConfig: AppConfig(
          sites: [site],
          parses: [
            ParseEntry(name: 'json', type: 1, url: 'https://parser/?url='),
          ],
        ),
        router: router,
      );
      final decision = (await service.resolvePlayback(
        site: site,
        episodeTarget: 'id',
        qualityIndex: 1,
        parseService: parser,
      )).value;
      expect(decision.url, 'https://media/final.m3u8');
      expect(decision.qualityIndex, 1);
      expect(decision.qualities.map((q) => q.url), [
        'https://web-a/watch',
        'https://web-b/watch',
      ]);
      expect(decision.headers?['X-Site'], 'site');
      expect(decision.headers?['X-Entry'], 'entry');
      expect(decision.headers?['Referer'], 'parser');
      expect(
        decision.subs.map((s) => s.url),
        containsAll(['https://a/original.srt', 'https://a/parsed.srt']),
      );
      expect(decision.danmaku.single.url, 'https://a/danmaku.xml');
      expect(playCalls, 1);
      expect(parseCalls, 1, reason: '只解析选中候选');
    });

    test('Android桥接仅重写选中url，原始候选不代理', () async {
      final site = Site(
        key: 't',
        name: 't',
        type: 4,
        api: 'http://192.168.1.20:9978/vod/api',
      );
      final bridge = AndroidPlaybackBridge(
        runAdb: (_) async => throw StateError('不应调用adb'),
      );
      addTearDown(bridge.close);
      final decision = await bridge.resolveDecision(
        site,
        const PlaybackDecision(
          action: PlaybackAction.direct,
          url: 'http://127.0.0.1:5001/hd',
          qualities: [
            PlaybackQuality(name: 'RAW', url: 'http://127.0.0.1:5000/raw'),
            PlaybackQuality(name: '高清', url: 'http://127.0.0.1:5001/hd'),
          ],
          qualityIndex: 1,
        ),
      );
      expect(decision.url, 'http://192.168.1.20:5001/hd');
      expect(decision.qualityIndex, 1);
      expect(decision.qualities.last.url, 'http://127.0.0.1:5001/hd');
      expect(decision.qualities, hasLength(2));
    });
  });

  group('SiteResult 多画质解析（http_api._playUrlFrom）', () {
    for (final bad in <Map<String, Object?>>[
      {'url': null},
      {'url': ''},
      {'name': '坏项'},
      {'v': 12},
    ]) {
      test('纯URL数组中的坏字段对象$bad不改变其余地址角色', () {
        final result = _parse({
          'url': ['https://a/a.m3u8', bad, 'https://b/b.m3u8'],
        });
        expect(result.qualities.map((q) => q.url), [
          'https://a/a.m3u8',
          'https://b/b.m3u8',
        ]);
        expect(result.qualities.map((q) => q.name), ['画质1', '画质3']);
        expect(result.playUrl, 'https://a/a.m3u8');
        expect(result.qualityIndex, 0);
      });
    }
    test('纯URL数组中的空对象不会将其余URL转入对象模式', () {
      final result = _parse({
        'url': ['https://a/a.m3u8', {}, 'https://b/b.m3u8'],
      });
      expect(result.qualities.map((q) => q.url), [
        'https://a/a.m3u8',
        'https://b/b.m3u8',
      ]);
      expect(result.qualities.map((q) => q.name), ['画质1', '画质3']);
    });
    test('纯地址数组首项缺失不会让后续有效地址串成名称', () {
      final result = _parse({
        'url': [null, 'https://a/a.m3u8', 'https://b/b.m3u8'],
      });
      expect(result.qualities.map((q) => q.url), [
        'https://a/a.m3u8',
        'https://b/b.m3u8',
      ]);
      expect(result.qualities.map((q) => q.name), ['画质2', '画质3']);
    });
    test('RAW非首项仍是平铺数组默认，顺序保持', () {
      final result = _parse({
        'url': ['高清', 'https://a/hd.m3u8', 'RAW', 'https://b/raw.m3u8'],
      });
      expect(result.qualityIndex, 1);
      expect(result.playUrl, 'https://b/raw.m3u8');
      expect(result.qualities.map((q) => q.name), ['高清', 'RAW']);
    });
    test('对象position基于原始数组，过滤坏条目后不能串项', () {
      final result = _parse({
        'url': {
          'values': [
            {'n': '坏条目', 'v': null},
            {'v': 'https://a/a.m3u8'},
            {'n': '高清', 'v': 'https://b/b.m3u8'},
          ],
          'position': 1,
        },
      });
      expect(result.playUrl, 'https://a/a.m3u8');
      expect(result.qualityIndex, 0);
      expect(result.qualities.map((q) => q.name), ['画质2', '高清']);
    });
    test('纯地址数组中混入无效字符串数字也不丢其余地址', () {
      final result = _parse({
        'url': ['https://a/a.m3u8', '高清', 12, 'https://b/b.m3u8'],
      });
      expect(result.qualities.map((q) => q.url), [
        'https://a/a.m3u8',
        'https://b/b.m3u8',
      ]);
      expect(result.qualities.map((q) => q.name), ['画质1', '画质4']);
    });
    test('单XML播放地址及裸文本地址保留单候选', () {
      for (final body in [
        '<rss><url>https://a/a.m3u8</url></rss>',
        'https://a/a.m3u8',
      ]) {
        final result = HttpApiResponseParser.parse(body, siteKey: 't');
        expect(result.playUrl, 'https://a/a.m3u8');
        expect(result.qualities.single.url, result.playUrl);
        expect(result.qualityIndex, 0);
      }
    });
    test('空列表、urls复数或缺失url没有候选', () {
      for (final map in <Map<String, Object?>>[
        {'url': []},
        {
          'urls': ['https://a/a.m3u8'],
        },
        {},
      ]) {
        final result = _parse(map);
        expect(result.playUrl, isNull);
        expect(result.qualities, isEmpty);
        expect(result.qualityIndex, 0);
      }
    });
    test('平铺 name/url 数组：RAW 优先为默认，候选完整保序', () {
      final result = _parse({
        'url': [
          'RAW',
          'https://a/raw.m3u8',
          '超清',
          'https://a/super.m3u8',
          '高清',
          'https://a/hd.m3u8',
        ],
      });
      expect(result.qualities, hasLength(3));
      expect(result.qualities.map((q) => q.name).toList(), ['RAW', '超清', '高清']);
      expect(result.qualities.map((q) => q.url).toList(), [
        'https://a/raw.m3u8',
        'https://a/super.m3u8',
        'https://a/hd.m3u8',
      ]);
      expect(result.playUrl, 'https://a/raw.m3u8', reason: 'RAW 优先语义不变');
      expect(result.qualityIndex, 0);
    });

    test('纯地址数组：不再误判成 name/url 配对，全部候选保留', () {
      final result = _parse({
        'url': ['https://a/1.m3u8', 'https://a/2.m3u8', 'https://a/3.m3u8'],
      });
      expect(result.qualities.map((q) => q.url).toList(), [
        'https://a/1.m3u8',
        'https://a/2.m3u8',
        'https://a/3.m3u8',
      ]);
      expect(
        result.qualities.every((q) => q.url.startsWith('http')),
        isTrue,
        reason: 'URL 不能被当作画质名称',
      );
      expect(result.playUrl, 'https://a/1.m3u8');
    });

    test('对象形态 {values:[{n,v}],position}：保留默认 position 选择', () {
      final result = _parse({
        'url': {
          'values': [
            {'n': '标清', 'v': 'https://a/sd.m3u8'},
            {'n': '超清', 'v': 'https://a/super.m3u8'},
          ],
          'position': 1,
        },
      });
      expect(result.qualities.map((q) => q.name).toList(), ['标清', '超清']);
      expect(result.playUrl, 'https://a/super.m3u8', reason: '默认取上游 position');
      expect(result.qualityIndex, 1);
    });

    test('对象数组 [{name,url}]：候选完整', () {
      final result = _parse({
        'url': [
          {'name': '高清', 'url': 'https://a/hd.m3u8'},
          {'name': '蓝光', 'url': 'https://a/4k.m3u8'},
        ],
      });
      expect(result.qualities.map((q) => q.name).toList(), ['高清', '蓝光']);
      expect(result.playUrl, 'https://a/hd.m3u8');
    });

    test('单字符串地址：单候选', () {
      final result = _parse({'url': 'https://a/single.m3u8'});
      expect(result.qualities.map((q) => q.url).toList(), [
        'https://a/single.m3u8',
      ]);
      expect(result.playUrl, 'https://a/single.m3u8');
      expect(result.qualityIndex, 0);
    });

    test('urls（复数）不是画质候选', () {
      final result = _parse({
        'urls': ['https://x/1'],
        'url': 'https://a/real.m3u8',
      });
      expect(result.qualities.map((q) => q.url).toList(), [
        'https://a/real.m3u8',
      ]);
    });

    test('命名缺失时按原顺序用可读序号，无效条目被过滤', () {
      final result = _parse({
        'url': ['', 'https://a/1.m3u8', '超清', 'https://a/2.m3u8'],
      });
      expect(result.qualities.map((q) => q.name).toList(), ['画质1', '超清']);
      expect(result.qualities.map((q) => q.url).toList(), [
        'https://a/1.m3u8',
        'https://a/2.m3u8',
      ]);
    });
  });

  group('PlaybackResolver 按 qualityIndex 决策', () {
    Site siteOf() => Site(
      key: 't',
      name: 't',
      api: 'https://t.example/api.php/provide/vod',
      type: 1,
    );

    test('默认（null）→ qualities[0]，headers 按所选 host 合并', () {
      final decision = PlaybackResolver.decide(
        PlaybackResolutionInput(
          site: siteOf(),
          episodeTarget: 'https://cdn-a/v/1.m3u8',
          flag: '线路1',
          qualities: [
            const PlaybackQuality(name: 'RAW', url: 'https://cdn-a/v/1.m3u8'),
            const PlaybackQuality(name: '超清', url: 'https://cdn-b/v/2.m3u8'),
          ],
        ),
      );
      expect(decision.action, PlaybackAction.direct);
      expect(decision.url, 'https://cdn-a/v/1.m3u8');
      expect(decision.qualityIndex, 0);
      expect(decision.qualities, hasLength(2));
    });

    test('显式 qualityIndex=1 → decision.url 为第二个候选且索引保留', () {
      final decision = PlaybackResolver.decide(
        PlaybackResolutionInput(
          site: siteOf(),
          episodeTarget: 'https://cdn-a/v/1.m3u8',
          qualities: [
            const PlaybackQuality(name: 'RAW', url: 'https://cdn-a/v/1.m3u8'),
            const PlaybackQuality(name: '超清', url: 'https://cdn-b/v/2.m3u8'),
          ],
          qualityIndex: 1,
        ),
      );
      expect(decision.url, 'https://cdn-b/v/2.m3u8');
      expect(decision.qualityIndex, 1);
      expect(decision.qualities.map((q) => q.url).toList(), [
        'https://cdn-a/v/1.m3u8',
        'https://cdn-b/v/2.m3u8',
      ]);
    });

    test('越界索引回退默认，不崩溃不串项', () {
      final decision = PlaybackResolver.decide(
        PlaybackResolutionInput(
          site: siteOf(),
          episodeTarget: 'https://cdn-a/v/1.m3u8',
          qualities: [
            const PlaybackQuality(name: 'RAW', url: 'https://cdn-a/v/1.m3u8'),
          ],
          qualityIndex: 7,
        ),
      );
      expect(decision.url, 'https://cdn-a/v/1.m3u8');
      expect(decision.qualityIndex, 0);
    });

    test('无候选时行为不变（qualityIndex 归零、qualities 空）', () {
      final decision = PlaybackResolver.decide(
        PlaybackResolutionInput(
          site: siteOf(),
          episodeTarget: 'https://cdn-a/v/1.m3u8',
        ),
      );
      expect(decision.qualities, isEmpty);
      expect(decision.qualityIndex, 0);
      expect(decision.url, 'https://cdn-a/v/1.m3u8');
    });
  });

  group('决策重建/透传保留候选', () {
    test('PlaybackDecision copyWith 保留 qualities/qualityIndex', () {
      const decision = PlaybackDecision(
        action: PlaybackAction.direct,
        url: 'https://a/1.m3u8',
        qualities: [
          PlaybackQuality(name: 'RAW', url: 'https://a/1.m3u8'),
          PlaybackQuality(name: '超清', url: 'https://a/2.m3u8'),
        ],
        qualityIndex: 1,
      );
      final copied = decision.copyWith(reason: 'proxied');
      expect(copied.qualities, hasLength(2));
      expect(copied.qualityIndex, 1);
      final copiedIndex = copied.copyWith(qualityIndex: 0);
      expect(
        copiedIndex.url,
        'https://a/1.m3u8',
        reason: 'copyWith 只换索引不换 url（url 由解析层负责）',
      );
    });

    test('SiteResult copyWith 保留 qualities/qualityIndex', () {
      const result = SiteResult(
        playUrl: 'https://a/1.m3u8',
        qualities: [PlaybackQuality(name: 'RAW', url: 'https://a/1.m3u8')],
        qualityIndex: 0,
      );
      final copied = result.copyWith(msg: 'ok');
      expect(copied.qualities, hasLength(1));
      expect(copied.qualityIndex, 0);
    });
  });
}

class _SourceQualityState extends AppState {
  _SourceQualityState({required super.paths, required this.context});

  final PlaybackSourceContext context;
  final oldProxied = Completer<void>();
  final releaseOld = Completer<void>();

  @override
  PlaybackSourceContext? playbackContextFor(String sourceKey) =>
      sourceKey == context.sourceKey ? context : null;

  @override
  Future<PlaybackDecision> proxyDecision(
    PlaybackDecision decision, {
    required String siteKey,
    bool Function()? isCurrent,
  }) async {
    final resolved = await super.proxyDecision(
      decision,
      siteKey: siteKey,
      isCurrent: isCurrent,
    );
    if (decision.qualityIndex == 0) {
      oldProxied.complete();
      await releaseOld.future;
    }
    return resolved;
  }
}
