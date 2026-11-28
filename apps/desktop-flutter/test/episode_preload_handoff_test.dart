import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:webhtv_pc/core/proxy_policy.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/proxy_server.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/player_controller.dart';

import 'support/libmpv_guard.dart';

class _LoopbackTestHttp extends HttpOverrides {}

class _ObservedHttpClient extends http.BaseClient {
  final _client = http.Client();
  final nextAborted = Completer<void>();

  void _noticeAbort(Object error) {
    if (error is http.RequestAbortedException && !nextAborted.isCompleted) {
      nextAborted.complete();
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.queryParameters['play'] != 'next') {
      return _client.send(request);
    }
    final http.StreamedResponse response;
    try {
      response = await _client.send(request);
    } catch (error) {
      _noticeAbort(error);
      rethrow;
    }
    return http.StreamedResponse(
      response.stream.handleError((Object error, StackTrace stack) {
        _noticeAbort(error);
        Error.throwWithStackTrace(error, stack);
      }),
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _client.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final nativeUnavailable = libmpvUnavailableReason;
  if (nativeUnavailable == null) {
    MediaKit.ensureInitialized(
      libmpv: Platform.environment['WEBHTV_TEST_LIBMPV'],
    );
  }
  late AppState app;
  late LogService log;
  late HttpClient client;
  late String base;
  late List<String> hits;
  late List<int>? media;
  final hostJar = File('../../sidecars/spider-host-jvm/host.jar').absolute;
  late bool headerless;
  late bool master;
  late bool stallNext;
  late Completer<void> playbackStalled;
  late _ObservedHttpClient siteClient;
  late Completer<void> releaseStall;

  setUp(() async {
    final previousHttp = HttpOverrides.current;
    HttpOverrides.global = _LoopbackTestHttp();
    addTearDown(() => HttpOverrides.global = previousHttp);
    hits = [];
    media = null;
    headerless = false;
    master = false;
    stallNext = false;
    playbackStalled = Completer<void>();
    siteClient = _ObservedHttpClient();
    releaseStall = Completer<void>();
    final directory = await Directory.systemTemp.createTemp('episode-handoff-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      final res = request.response;
      final path = request.uri.path;
      hits.add(path);
      if (path == '/config-jvm') {
        res.headers.contentType = ContentType.json;
        res.write(
          jsonEncode({
            'sites': [
              {
                'key': 'fixture-jvm',
                'name': 'Fixture JVM',
                'type': 3,
                'api': 'spider-local:preload-jvm',
              },
            ],
          }),
        );
      } else if (path == '/api') {
        res.headers.contentType = ContentType.json;
        final target = request.uri.queryParameters['play'];
        if (target == 'next' && stallNext) {
          stallNext = false;
          res.write('{');
          await res.flush();
          playbackStalled.complete();
          await releaseStall.future;
          try {
            await res.close();
          } catch (_) {}
          return;
        }
        res.write(
          jsonEncode(
            target == null
                ? {'class': [], 'list': []}
                : {
                    'parse': 0,
                    'url': '$base/$target.m3u8',
                    if (!headerless) 'header': {'User-Agent': 'fixture'},
                  },
          ),
        );
      } else if (master && path == '/next.m3u8') {
        res.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        res.write(
          '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1200000\nnext-media.m3u8\n',
        );
      } else if (path.endsWith('.m3u8')) {
        res.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        res.write(
          [
            '#EXTM3U',
            if (media == null) ...[
              '#EXT-X-TARGETDURATION:5',
              '#EXTINF:5,',
              'first.ts',
              '#EXTINF:5,',
              'second.ts',
              '#EXTINF:5,',
              'third.ts',
            ] else ...[
              '#EXT-X-TARGETDURATION:6',
              for (var i = 0; i < 4; ++i) ...[
                if (i != 0) '#EXT-X-DISCONTINUITY',
                '#EXTINF:6,',
                '${path.substring(0, path.length - 5)}/s$i.ts',
              ],
            ],
            '#EXT-X-ENDLIST',
            '',
          ].join('\n'),
        );
      } else {
        res.headers.contentType = ContentType('video', 'mp2t');
        final bytes = media ?? [1, 2, 3];
        res.contentLength = bytes.length;
        res.add(bytes);
      }
      await res.close();
    });
    log = LogService();
    final proxy = LocalProxyServer(
      log: log,
      policy: const ProxyTargetPolicy(allowLoopback: true),
    );
    app = AppState(
      log: log,
      proxyServer: proxy,
      jvmSidecarHostPath: hostJar.path,
      httpClient: siteClient,
      paths: AppPaths.resolve(
        overrides: {
          'config': '${directory.path}/config',
          'data': '${directory.path}/data',
          'cache': '${directory.path}/cache',
          'state': '${directory.path}/state',
        },
      ),
    );
    client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      if (!releaseStall.isCompleted) releaseStall.complete();
      app.dispose();
      await server.close(force: true);
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        /* Windows native store can close asynchronously. */
      }
    });
    await app.bootstrap();
    expect(
      await app.importConfig(
        jsonEncode({
          'sites': [
            {
              'key': 'fixture',
              'name': 'Fixture',
              'type': 4,
              'api': '$base/api',
            },
            {
              'key': 'second-site',
              'name': 'Second fixture',
              'type': 4,
              'api': '$base/api',
            },
            {
              'key': 'fixture-jvm',
              'name': 'Same key, wrong runtime',
              'type': 4,
              'api': '$base/api',
            },
          ],
        }),
      ),
      isTrue,
    );
    expect(
      await app.setPlayerOptions(app.playerOptions.copyWith(preloadNext: true)),
      isTrue,
    );
  });

  EpisodePreload? prepare(String name) => app.prepareEpisodePreload(
    currentMediaUrl: app.lastDecision!.url!,
    siteKey: 'fixture',
    episodeTarget: name,
    flag: 'line',
    vodId: 'series',
    immediateNext: true,
    isCurrent: () => true,
    startAt: (lengthMs) async {
      expect(lengthMs, 15000);
      return 5000;
    },
  );

  test(
    'only promotion swaps the token and reuses next-episode media',
    () async {
      final active = (await app.resolvePlayback(episodeTarget: 'active'))!;
      final before = app.proxySessionFingerprint;
      final releaseOld = app.captureProxySessionRelease(active.url!);
      final warmed = log.stream.firstWhere(
        (e) => e.message.startsWith('预取窗口完成'),
      );
      final lease = prepare('next')!;
      await lease.prepared;
      await warmed.timeout(const Duration(seconds: 3));
      expect(app.lastDecision, same(active));
      expect(app.proxySessionFingerprint, before);
      expect(hits.where((path) => path == '/first.ts'), isEmpty);

      final handoff = app.takeEpisodePreload(lease)!;
      expect(handoff.startMs, 5000);
      expect(app.lastDecision, same(handoff.decision));
      expect(app.proxySessionFingerprint, isNot(before));
      releaseOld();
      expect(app.proxySessionFingerprint, isNotNull);
      expect(app.takeEpisodePreload(lease), isNull);
      final manifest = await (await client.getUrl(
        Uri.parse(handoff.decision.url!),
      )).close();
      final lines = const LineSplitter().convert(
        await utf8.decoder.bind(manifest).join(),
      );
      final segment = Uri.parse(
        lines.where((s) => s.startsWith('http')).elementAt(1),
      );
      final body = await (await client.getUrl(segment)).close();
      expect(await body.expand((bytes) => bytes).toList(), [1, 2, 3]);
      expect(hits.where((path) => path == '/second.ts'), hasLength(1));
      expect(hits.where((path) => path == '/api'), isNotEmpty);
    },
  );

  test(
    'a canonical playing site can preload without becoming the selected site',
    () async {
      final selected = app.selectedSite!;
      final other = app.siteInActiveSource('second-site')!;
      final active = (await app.resolvePlayback(
        siteOverride: other,
        episodeTarget: 'active',
      ))!;
      final warmed = log.stream.firstWhere(
        (event) => event.message.startsWith('预取窗口完成'),
      );
      final lease = app.prepareEpisodePreload(
        currentMediaUrl: active.url!,
        siteKey: other.key,
        episodeTarget: 'next',
        flag: 'line',
        vodId: 'series',
        immediateNext: true,
        isCurrent: () => true,
        startAt: (_) async => 0,
      );
      expect(lease, isNotNull);
      await lease!.prepared;
      await warmed.timeout(const Duration(seconds: 3));
      expect(app.episodePreloadReady(lease), isTrue);
      expect(app.selectedSite, same(selected));
      expect(app.lastDecision, same(active));
    },
  );

  test(
    'a candidate never borrows a different site that only shares the key',
    () async {
      final other = Site(
        key: 'fixture',
        name: 'Other',
        type: 4,
        api: '$base/api',
      );
      expect(
        (await app.resolvePlayback(
          siteOverride: other,
          episodeTarget: 'active',
        ))?.url,
        isNotNull,
      );
      expect(
        prepare('next'),
        isNull,
        reason: 'Playing another site must not preload for the selected one',
      );
      expect(
        log.entries.any(
          (e) => e.message.contains('reason=playback_context_mismatch'),
        ),
        isTrue,
      );
    },
  );

  test(
    'manual cache clear drops pending and promoted bytes, not foreground media',
    () async {
      Future<EpisodePreload> warmCandidate() async {
        final warmed = log.stream.firstWhere(
          (e) => e.message.startsWith('预取窗口完成'),
        );
        final candidate = prepare('next')!;
        await candidate.prepared;
        await warmed.timeout(const Duration(seconds: 3));
        expect(app.episodePreloadReady(candidate), isTrue);
        return candidate;
      }

      Future<String> fetch(String url) async {
        final response = await (await client.getUrl(Uri.parse(url))).close();
        expect(response.statusCode, HttpStatus.ok);
        return utf8.decoder.bind(response).join();
      }

      final current = (await app.resolvePlayback(episodeTarget: 'active'))!;
      final pending = await warmCandidate();
      await app.resetCache();
      expect(app.episodePreloadReady(pending), isFalse);
      expect(await fetch(current.url!), startsWith('#EXTM3U'));

      final handoff = app.takeEpisodePreload(await warmCandidate())!;
      final before = hits.where((path) => path == '/second.ts').length;
      await app.resetCache();
      final manifest = await fetch(handoff.decision.url!);
      final segment = const LineSplitter()
          .convert(manifest)
          .where((line) => line.startsWith('http'))
          .elementAt(1);
      await fetch(segment);
      expect(hits.where((path) => path == '/second.ts'), hasLength(before + 1));
    },
  );

  test('a foreground resolution invalidates in-flight candidates', () async {
    await app.resolvePlayback(episodeTarget: 'active');
    final lease = prepare('next')!;
    final replacement = await app.resolvePlayback(episodeTarget: 'other');
    await lease.prepared;
    expect(app.takeEpisodePreload(lease), isNull);
    expect(app.lastDecision, same(replacement));
    expect(app.proxySessions.activeSessions, hasLength(1));
  });

  test(
    'a ready farther candidate stays ready after the next episode is taken',
    () async {
      await app.resolvePlayback(episodeTarget: 'active');
      Future<EpisodePreload> warmed(String target) async {
        final done = log.stream.firstWhere(
          (e) => e.message.startsWith('预取窗口完成'),
        );
        final lease = prepare(target)!;
        await lease.prepared;
        await done.timeout(const Duration(seconds: 3));
        return lease;
      }

      final next = await warmed('next');
      final later = await warmed('later');
      expect(app.takeEpisodePreload(next, followup: later), isNotNull);
      expect(app.episodePreloadReady(later), isTrue);
      expect(app.takeEpisodePreload(later), isNotNull);
      expect(app.proxySessions.activeSessions, hasLength(1));
    },
  );

  test('an opted-in but unproxied current stream does not speculate', () async {
    headerless = true;
    final decision = await app.resolvePlayback(episodeTarget: 'active');
    expect(decision?.url, '$base/active.m3u8');
    expect(prepare('next'), isNull);
  });

  test(
    'foreground fallback cancels the earlier HTTP playback lookup',
    () async {
      await app.resolvePlayback(episodeTarget: 'active');
      stallNext = true;
      final pending = prepare('next')!;
      await playbackStalled.future.timeout(
        const Duration(seconds: 6),
        onTimeout: () => fail('speculative lookup did not reach the fixture'),
      );
      final chosen = await app.resolvePlayback(episodeTarget: 'next');
      await pending.prepared.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('cancelled candidate did not settle'),
      );
      expect(chosen?.url, isNotNull);
      expect(app.takeEpisodePreload(pending), isNull);
      await siteClient.nextAborted.future.timeout(
        const Duration(seconds: 6),
        onTimeout: () =>
            fail('IOClient did not observe RequestAbortedException'),
      );
    },
  );

  for (final (fromHistory, stoppedOwner) in [
    (false, false),
    (true, false),
    (true, true),
  ]) {
    test(
      'real JVM master HLS transfers media and assets (original source: $fromHistory, stopped owner: $stoppedOwner)',
      () async {
        master = true;
        final initialConfig = app.activeRecord!;
        final spider = Directory('${app.paths.configDir}/spiders/preload-jvm');
        await spider.create(recursive: true);
        await File('${spider.path}/manifest.json').writeAsString(
          jsonEncode({
            'abi': 'webhtv-ipc-v1',
            'key': 'preload-jvm',
            'name': 'Preload JVM fixture',
            'runtime': 'jvm',
            'entry': 'PreloadFixtureSpider.java',
            'capabilities': [
              'home',
              'category',
              'detail',
              'search',
              'play',
              'proxy',
            ],
            'permissions': {'network': true, 'localProxy': true},
            'config': {'className': 'fixture.PreloadFixtureSpider'},
          }),
        );
        await File('${spider.path}/PreloadFixtureSpider.java')
            .writeAsString(_preloadFixtureSpider);
        expect(
          (await app.rescanSpiders()).map((spider) => spider.key),
          contains('preload-jvm'),
        );
        expect(await app.importConfig('$base/config-jvm'), isTrue);
        await app.selectSite(app.config!.sites.single);
        final originalKey = fromHistory ? app.activeSourceKey : '';
        if (fromHistory) {
          expect(await app.activateConfigRecord(initialConfig.id), isTrue);
          expect(app.siteInActiveSource('fixture-jvm')?.api, '$base/api');
        }
        final activeKey = app.activeSourceKey;
        final selected = app.selectedSite;
        final currentUrl = '$base/active.m3u8';
        final nextUrl = '$base/next.m3u8';
        final active = (await (fromHistory
            ? app.resolvePlaybackForSource(
                sourceKey: originalKey,
                siteKey: 'fixture-jvm',
                episodeTarget: currentUrl,
              )
            : app.resolvePlayback(episodeTarget: currentUrl)))!;
        if (fromHistory) {
          expect(
            app.prepareEpisodePreload(
              currentMediaUrl: active.url!,
              sourceKey: activeKey,
              siteKey: 'fixture-jvm',
              episodeTarget: nextUrl,
              flag: 'line',
              vodId: 'series',
              immediateNext: true,
              isCurrent: () => true,
              startAt: (_) async => 0,
            ),
            isNull,
          );
        }
        final oldRelease = app.captureProxySessionRelease(active.url!);
        final activeAsset = active.danmaku.single.url;
        if (stoppedOwner) {
          expect(app.spiderSupervisor.hostFor('fixture-jvm'), isNotNull);
          await app.spiderSupervisor.stop('fixture-jvm');
          expect(app.spiderSupervisor.hostFor('fixture-jvm'), isNull);
          final current = await (await client.getUrl(Uri.parse(active.url!)))
              .close();
          expect(current.statusCode, HttpStatus.ok);
          await current.drain<void>();
        }
        final warmed = log.stream.firstWhere(
          (e) => e.message.startsWith('预取窗口完成'),
        );
        Timer? candidateExpiry;
        void Function()? finishPreparationBudget;
        var starting = true;
        final lease = runZoned(
          () => app.prepareEpisodePreload(
            currentMediaUrl: active.url!,
            sourceKey: originalKey,
            siteKey: 'fixture-jvm',
            episodeTarget: nextUrl,
            flag: 'line',
            vodId: 'series',
            immediateNext: true,
            isCurrent: () => true,
            startAt: (_) async => 5000,
          ),
          zoneSpecification: ZoneSpecification(
            createTimer: (_, parent, zone, delay, callback) {
              final timer = parent.createTimer(zone, delay, callback);
              if (starting && delay == const Duration(seconds: 45)) {
                candidateExpiry = timer;
                finishPreparationBudget = callback;
              }
              return timer;
            },
          ),
        );
        starting = false;
        expect(
          candidateExpiry?.isActive,
          isTrue,
          reason: 'Unused JVM precache needs a bounded lease',
        );
        expect(lease, isNotNull);
        await lease!.prepared;
        expect(
          hits,
          contains('/next-media.m3u8'),
          reason: log.entries
              .map((e) => e.message)
              .toList()
              .reversed
              .take(12)
              .join('\n'),
        );
        await warmed.timeout(const Duration(seconds: 5));
        Future<String> fetch(Uri target) async {
          final r = await (await client.getUrl(target)).close();
          expect(r.statusCode, HttpStatus.ok);
          return utf8.decoder.bind(r).join();
        }

        expect(app.lastDecision, same(active));
        if (!stoppedOwner) {
          expect(await fetch(Uri.parse(activeAsset)), currentUrl);
        } else {
          // A completed candidate is no longer subject to its preparation deadline.
          finishPreparationBudget!();
          expect(app.episodePreloadReady(lease), isTrue);
        }
        final handoff = app.takeEpisodePreload(lease)!;
        expect(app.activeSourceKey, activeKey);
        expect(app.selectedSite, same(selected));
        expect(candidateExpiry!.isActive, isFalse);
        oldRelease();
        final nextAsset = Uri.parse(handoff.decision.danmaku.single.url);
        expect(nextAsset.port, isNot(Uri.parse(activeAsset).port));
        expect(await fetch(nextAsset), nextUrl);
        Iterable<String> links(String text) => const LineSplitter()
            .convert(text)
            .where((line) => line.startsWith('http'));
        final masterText = await fetch(Uri.parse(handoff.decision.url!));
        final mediaText = await fetch(Uri.parse(links(masterText).single));
        final segment = await (await client.getUrl(
          Uri.parse(links(mediaText).elementAt(1)),
        )).close();
        expect(await segment.expand((bytes) => bytes).toList(), [1, 2, 3]);
        expect(hits.where((path) => path == '/second.ts'), hasLength(1));
      },
      tags: ['external'],
      skip: !hostJar.existsSync() || Platform.environment['JAVA_HOME'] == null,
    );
  }

  for (final useMaster in [false, true]) {
    test(
      'native player opens after the intro and reuses the warmed HLS segment (master: $useMaster)',
      () async {
        master = useMaster;
        final segment = master ? '/next-media/s1.ts' : '/next/s1.ts';
        media = await File('../../packages/test-fixtures/media/segment-000.ts')
            .readAsBytes();
        final active = (await app.resolvePlayback(episodeTarget: 'active'))!;
        final done = log.stream.firstWhere(
          (e) => e.message.startsWith('预取窗口完成'),
        );
        final preload = app.prepareEpisodePreload(
          currentMediaUrl: active.url!,
          siteKey: 'fixture',
          episodeTarget: 'next',
          flag: 'line',
          vodId: 'series',
          immediateNext: true,
          isCurrent: () => true,
          startAt: (ms) async => 6000,
        )!;
        await preload.prepared;
        await done.timeout(const Duration(seconds: 3));
        expect(hits.where((path) => path == segment), hasLength(1));
        expect(app.lastDecision, same(active));
        final handoff = app.takeEpisodePreload(preload)!;
        // Same sequence as PlayerPage._beginMediaTransition after handoff.
        app.clearAiAdApplication();
        final player = Player();
        final native = player.platform! as NativePlayer;
        await native.setProperty('ao', 'null');
        await native.setProperty('vo', 'null');
        final controller = PlayerController(player: player);
        native.isVideoControllerAttached = false;
        addTearDown(() async {
          final released = Completer<void>();
          native.release.add(() async => released.complete());
          controller.dispose();
          await released.future.timeout(const Duration(seconds: 8));
        });
        final result = await controller.open(
          handoff.decision.url!,
          startAt: Duration(milliseconds: handoff.startMs),
          awaitFirstFrame: false,
          timeout: const Duration(seconds: 10),
        );
        expect(result.succeeded, isTrue, reason: result.summary);
        expect(
          hits.where((path) => path == '/next.m3u8'),
          hasLength(1),
          reason: log.entries
              .map((e) => e.message)
              .toList()
              .reversed
              .take(20)
              .join('\n'),
        );
        if (master) {
          expect(
            hits.where((path) => path == '/next-media.m3u8'),
            hasLength(1),
          );
        }
        expect(
          double.parse(await native.getProperty('time-pos')),
          inInclusiveRange(5.9, 12),
        );
        expect(hits.where((path) => path == segment), hasLength(1));
      },
      skip: nativeUnavailable,
    );
  }
}

const _preloadFixtureSpider = r'''
package fixture;
import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import webhtv.spider.Spider;
import webhtv.spider.CallContext;

public final class PreloadFixtureSpider extends Spider {
  private String media;
  public List<String> capabilities() { return List.of("home", "category", "detail", "search", "play", "proxy"); }
  protected Map<String, Object> homeContent(boolean filter, CallContext context) {
    return Map.of("class", List.of(), "list", List.of());
  }
  protected Map<String, Object> playerContent(String flag, String id, List<String> vipFlags, CallContext context) {
    media = id;
    return Map.of("url", id, "parse", 0, "format", "application/vnd.apple.mpegurl",
        "header", Map.of("User-Agent", "fixture"),
        "danmaku", List.of(Map.of("name", "fixture", "url", "http://127.0.0.1:9978/proxy?do=asset")));
  }
  public Object[] proxy(Map<String, String> params, CallContext context) {
    return new Object[]{200, "text/plain", new ByteArrayInputStream(media.getBytes(StandardCharsets.UTF_8))};
  }
}
''';
