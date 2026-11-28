import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/ad_rules.dart';
import 'package:webhtv_pc/core/proxy_policy.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/proxy_server.dart';

void main() {
  late LocalProxyServer proxy;
  late ProxySession session;
  late HttpClient client;
  late Uri playlist;
  late LogService log;
  late List<String> upstreamHits;
  late bool live;
  late bool private;
  Uri? redirect;
  late Map<String, String> manifestCacheControls;
  late bool partialManifest;
  late List<String?> originCredentials;
  late Map<String, String> manifests;
  late Future<void> Function(String path)? beforeManifest;

  const singleVariant =
      '#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-INDEPENDENT-SEGMENTS\n'
      '#EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS="avc1.64001f,mp4a.40.2",CLOSED-CAPTIONS=NONE\n'
      'vod/variant.m3u8\n';

  setUp(() async {
    upstreamHits = [];
    redirect = null;
    manifestCacheControls = {};
    partialManifest = false;
    originCredentials = [];
    manifests = {};
    beforeManifest = null;
    live = false;
    private = false;
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((request) async {
      final path = request.uri.path;
      upstreamHits.add(path);
      final response = request.response;
      if (manifestCacheControls[path] case final value?) {
        response.headers.set(HttpHeaders.cacheControlHeader, value);
      }
      if (path == '/next.m3u8') {
        originCredentials.addAll([
          request.headers.value(HttpHeaders.cookieHeader),
          request.headers.value(HttpHeaders.authorizationHeader),
          request.headers.value('x-origin-signature'),
        ]);
      }
      if (redirect case final uri?) {
        response.statusCode = HttpStatus.found;
        response.headers.set('location', uri.toString());
      } else if (path.endsWith('.m3u8')) {
        await beforeManifest?.call(path);
        if (partialManifest) {
          response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 0-99/200',
          );
        }
        response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        response.write(
          manifests[path] ??
              [
                '#EXTM3U',
                '#EXT-X-TARGETDURATION:5',
                for (var i = 0; i < 8; i++) ...['#EXTINF:5,', 's$i.ts'],
                if (!live) '#EXT-X-ENDLIST',
                '',
              ].join('\n'),
        );
      } else {
        response.headers.contentType = ContentType('video', 'mp2t');
        if (private) response.headers.set('cache-control', 'no-store');
        response.contentLength = 2;
        response.add([1, upstreamHits.where((hit) => hit == path).length]);
      }
      await response.close();
    });
    log = LogService();
    proxy = LocalProxyServer(
      log: log,
      policy: const ProxyTargetPolicy(allowLoopback: true),
    );
    await proxy.start();
    playlist = Uri.parse('http://127.0.0.1:${upstream.port}/next.m3u8');
    session = proxy.sessions.create(siteKey: 'test');
    client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await proxy.stop();
      await upstream.close(force: true);
    });
  });

  Future<void> warm({
    int durationMs = 40000,
    int startMs = 12000,
    bool immediateNext = true,
  }) async {
    expect(await proxy.inspectEpisodePrefetch(session, playlist), durationMs);
    final done = log.stream.firstWhere((e) => e.message.startsWith('预取窗口完成'));
    proxy.primeEpisodePrefetch(
      session,
      startMs: startMs,
      immediateNext: immediateNext,
    );
    await done.timeout(const Duration(seconds: 3));
  }

  test(
    'next episode reuses post-intro media after the normal manifest GET',
    () async {
      await warm();
      expect(upstreamHits, ['/next.m3u8', '/s2.ts', '/s3.ts', '/s4.ts']);
      proxy.cancelPrefetch(); // The current episode's skip-only cleanup is independent.
      expect(proxy.episodePrefetchReady(session), isTrue);
      proxy.finishEpisodePrefetch(session, keepCache: true);
      final response = await (await client.getUrl(
        Uri.parse(proxy.urlFor(session, playlist)),
      )).close();
      final manifest = await utf8.decoder.bind(response).join();
      final links = const LineSplitter()
          .convert(manifest)
          .where((line) => line.startsWith('http'));
      final segment = await (await client.getUrl(Uri.parse(links.elementAt(2))))
          .close();
      expect(await segment.expand((chunk) => chunk).toList(), [1, 1]);
      expect(upstreamHits.where((hit) => hit == '/s2.ts'), hasLength(1));
    },
  );

  test(
    'one master variant warms media on the heuristic-cleaned timeline',
    () async {
      manifests['/next.m3u8'] = singleVariant;
      manifests['/vod/variant.m3u8'] = [
        '#EXTM3U',
        '#EXT-X-TARGETDURATION:5',
        for (var i = 0; i < 8; i++) ...[
          if (i == 1) ...['#EXTINF:5,', '/ad/spot.ts'],
          '#EXTINF:5,',
          's$i.ts',
        ],
        '#EXT-X-ENDLIST',
        '',
      ].join('\n');
      proxy.setAdBlockHeuristic(true);
      var cleanEvents = 0;
      proxy.onAdBlockClean = (_, _) => cleanEvents++;

      await warm(startMs: 6000, immediateNext: false);
      expect(upstreamHits, ['/next.m3u8', '/vod/variant.m3u8', '/vod/s1.ts']);
      expect(proxy.episodePrefetchReady(session), isTrue);
      expect(proxy.adBlockSummaryFor(session.fingerprint), isNull);
      expect(proxy.mediaPlaylistFor(session.fingerprint), isNull);
      expect(cleanEvents, 0);
      proxy.finishEpisodePrefetch(session, keepCache: true);

      Future<String> getText(Uri url) async {
        final response = await (await client.getUrl(url)).close();
        expect(response.statusCode, HttpStatus.ok);
        return utf8.decoder.bind(response).join();
      }

      Iterable<Uri> links(String text) => const LineSplitter()
          .convert(text)
          .where((line) => line.startsWith('http'))
          .map(Uri.parse);

      final masterUrl = Uri.parse(proxy.urlFor(session, playlist));
      final master = await getText(masterUrl);
      final repeatedMaster = await client.getUrl(masterUrl);
      repeatedMaster.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
      final repeated = await repeatedMaster.close();
      expect(repeated.statusCode, HttpStatus.ok);
      expect(await utf8.decoder.bind(repeated).join(), master);
      final media = await getText(links(master).single);
      expect(links(media), hasLength(8));
      expect(proxy.adBlockSummaryFor(session.fingerprint)?.heuristic, isTrue);
      expect(cleanEvents, 1);
      final segment = await (await client.getUrl(links(media).elementAt(1)))
          .close();
      expect(await segment.expand((chunk) => chunk).toList(), [1, 1]);
      expect(upstreamHits, ['/next.m3u8', '/vod/variant.m3u8', '/vod/s1.ts']);
    },
  );

  for (final label in ['revalidation', 'rule change']) {
    test(
      'a $label discards the promoted playlist pair and refetches it',
      () async {
        manifests['/next.m3u8'] = singleVariant;
        await warm(startMs: 0, immediateNext: false);
        proxy.finishEpisodePrefetch(session, keepCache: true);
        final masterUrl = Uri.parse(proxy.urlFor(session, playlist));
        final request = await client.getUrl(masterUrl);
        if (label == 'rule change') {
          proxy.setAdBlockHeuristic(!proxy.adBlockHeuristic);
        } else {
          request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
        }
        final response = await request.close();
        expect(response.statusCode, HttpStatus.ok);
        final master = await utf8.decoder.bind(response).join();
        final variant = const LineSplitter()
            .convert(master)
            .firstWhere((line) => line.startsWith('http'));
        final media = await (await client.getUrl(Uri.parse(variant))).close();
        expect(media.statusCode, HttpStatus.ok);
        await media.drain<void>();
        expect(upstreamHits.where((p) => p == '/next.m3u8'), hasLength(2));
        expect(
          upstreamHits.where((p) => p == '/vod/variant.m3u8'),
          hasLength(2),
        );
      },
    );
  }

  test(
    'explicitly fresh episode bytes outlive the old local 45-second limit',
    () async {
      manifests['/next.m3u8'] = singleVariant;
      manifestCacheControls.addAll({
        for (final path in ['/next.m3u8', '/vod/variant.m3u8', '/vod/s0.ts'])
          path: 'max-age=120',
      });
      await warm(startMs: 0, immediateNext: false);
      expect(proxy.episodePrefetchReady(session), isTrue);
      await Future<void>.delayed(const Duration(seconds: 46));
      expect(proxy.episodePrefetchReady(session), isTrue);
      proxy.finishEpisodePrefetch(session, keepCache: true);
      final url = proxy.urlFor(session, playlist.replace(path: '/vod/s0.ts'));
      final response = await (await client.getUrl(Uri.parse(url))).close();
      expect(await response.expand((chunk) => chunk).toList(), [1, 1]);
      expect(upstreamHits.where((path) => path == '/vod/s0.ts'), hasLength(1));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('farther candidate warms one segment, not the whole episode', () async {
    await warm(startMs: 0, immediateNext: false);
    expect(upstreamHits, ['/next.m3u8', '/s0.ts']);
    expect(proxy.episodePrefetchReady(session), isTrue);
    proxy.finishEpisodePrefetch(session);
    expect(proxy.episodePrefetchReady(session), isFalse);
  });

  test(
    'a rule match suppresses heuristic cleanup on the preload timeline',
    () async {
      manifests['/next.m3u8'] = [
        '#EXTM3U',
        '#EXT-X-TARGETDURATION:5',
        for (var i = 0; i < 8; i++) ...[
          if (i == 1) ...[
            '#EXTINF:5,',
            'splice.ts',
            '#EXTINF:5,',
            '/ad/spot.ts',
          ],
          '#EXTINF:5,',
          's$i.ts',
        ],
        '#EXT-X-ENDLIST',
        '',
      ].join('\n');
      proxy.adRules = const AdRuleSet(
        hlsRules: [
          HlsAdRule(
            id: 'rule-splice',
            playlistHostSuffixes: ['127.0.0.1'],
            segmentUrlRegex: [r'/splice\.ts$'],
          ),
        ],
      );
      proxy.setAdBlockHeuristic(true);

      await warm(durationMs: 45000, startMs: 11000, immediateNext: false);
      expect(upstreamHits, ['/next.m3u8', '/s1.ts']);
      expect(proxy.episodePrefetchReady(session), isTrue);
      proxy.setAdBlockHeuristic(false);
      expect(proxy.episodePrefetchReady(session), isFalse);
    },
  );

  test('live manifest is not admitted', () async {
    live = true;
    expect(await proxy.inspectEpisodePrefetch(session, playlist), isNull);
    expect(proxy.episodePrefetchReady(session), isFalse);
    expect(upstreamHits, ['/next.m3u8']);
  });

  for (final (label, mediaPath) in [
    ('direct playlist', '/next.m3u8'),
    ('master playlist', '/next.m3u8'),
    ('variant playlist', '/vod/variant.m3u8'),
  ]) {
    test('expiry of the $label prevents promotion', () async {
      if (label != 'direct playlist') manifests['/next.m3u8'] = singleVariant;
      manifestCacheControls[mediaPath] = 'max-age=2';
      await warm(immediateNext: false);
      expect(proxy.episodePrefetchReady(session), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      expect(proxy.episodePrefetchReady(session), isFalse);
    });
  }

  for (final path in ['/next.m3u8', '/vod/variant.m3u8']) {
    test('no-store on $path prevents master episode inspection', () async {
      manifests['/next.m3u8'] = singleVariant;
      manifestCacheControls[path] = 'no-store';
      expect(await proxy.inspectEpisodePrefetch(session, playlist), isNull);
      expect(upstreamHits, [
        '/next.m3u8',
        if (path != '/next.m3u8') '/vod/variant.m3u8',
      ]);
    });
  }

  for (final (label, master) in [
    (
      'multiple variants',
      '$singleVariant#EXT-X-STREAM-INF:BANDWIDTH=500000\nsecond.m3u8\n',
    ),
    (
      'alternative audio',
      '$singleVariant#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Other",URI="audio.m3u8"\n',
    ),
    (
      'case-insensitive rendition tags',
      '$singleVariant#ext-x-media:TYPE=SUBTITLES,GROUP-ID="sub",NAME="Other",URI="sub.m3u8"\n',
    ),
    (
      'an unresolved rendition group',
      '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000,AUDIO="audio"\nvod/variant.m3u8\n',
    ),
    (
      'a self reference',
      '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nnext.m3u8\n',
    ),
    (
      'a non-HTTP variant URL',
      '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nfile:///variant.m3u8\n',
    ),
  ]) {
    test('a master with $label does not fetch the variant', () async {
      manifests['/next.m3u8'] = master;
      expect(await proxy.inspectEpisodePrefetch(session, playlist), isNull);
      expect(proxy.episodePrefetchReady(session), isFalse);
      expect(upstreamHits, ['/next.m3u8']);
    });
  }

  for (final (label, media) in [
    ('nested master', singleVariant),
    ('live variant', '#EXTM3U\n#EXTINF:5,\ns0.ts\n'),
    (
      'byte-range VOD',
      '#EXTM3U\n#EXTINF:5,\n#EXT-X-BYTERANGE:16@0\ns0.ts\n#EXT-X-ENDLIST\n',
    ),
    (
      'unsafe asset URI',
      '#EXTM3U\n#EXTINF:5,\nhttp://user@127.0.0.1/s0.ts\n#EXT-X-ENDLIST\n',
    ),
  ]) {
    test('a $label does not become an episode candidate', () async {
      manifests['/next.m3u8'] = singleVariant;
      manifests['/vod/variant.m3u8'] = media;
      expect(await proxy.inspectEpisodePrefetch(session, playlist), isNull);
      expect(upstreamHits, ['/next.m3u8', '/vod/variant.m3u8']);
    });
  }

  test(
    'an episode manifest can wait beyond the transfer timeout for foreground',
    () async {
      manifests['/next.m3u8'] = singleVariant;
      final foregroundEntered = Completer<void>();
      final releaseForeground = Completer<void>();
      beforeManifest = (path) async {
        if (path != '/current.m3u8') return;
        foregroundEntered.complete();
        await releaseForeground.future;
      };
      final current = proxy.sessions.create(siteKey: 'current');
      final response = client
          .getUrl(
            Uri.parse(
              proxy.urlFor(current, playlist.replace(path: '/current.m3u8')),
            ),
          )
          .then((request) => request.close())
          .then((res) => res.drain<void>());
      try {
        await foregroundEntered.future.timeout(const Duration(seconds: 3));
        final inspected = proxy.inspectEpisodePrefetch(session, playlist);
        await Future<void>.delayed(const Duration(milliseconds: 6200));
        expect(upstreamHits, ['/current.m3u8']);
        releaseForeground.complete();
        await response.timeout(const Duration(seconds: 3));
        expect(await inspected.timeout(const Duration(seconds: 3)), 40000);
        expect(upstreamHits, [
          '/current.m3u8',
          '/next.m3u8',
          '/vod/variant.m3u8',
        ]);
      } finally {
        if (!releaseForeground.isCompleted) releaseForeground.complete();
      }
    },
  );

  test('a started manifest transfer still has its own deadline', () async {
    final release = Completer<void>();
    beforeManifest = (path) => release.future;
    try {
      final inspected = runZoned(
        () => proxy.inspectEpisodePrefetch(session, playlist),
        zoneSpecification: ZoneSpecification(
          createTimer: (_, parent, zone, delay, callback) {
            return parent.createTimer(
              zone,
              delay == const Duration(seconds: 6)
                  ? const Duration(milliseconds: 300)
                  : delay,
              callback,
            );
          },
        ),
      );
      expect(await inspected.timeout(const Duration(seconds: 3)), isNull);
      expect(upstreamHits, ['/next.m3u8']);
      expect(
        log.entries.any((e) => e.message.contains('reason=transfer_timeout')),
        isTrue,
      );
    } finally {
      release.complete();
    }
  });

  test(
    'safe overlap allows manifests but not media bytes during foreground',
    () async {
      manifests['/next.m3u8'] = singleVariant;
      final entered = Completer<void>();
      final release = Completer<void>();
      beforeManifest = (path) async {
        if (path == '/current.m3u8') {
          entered.complete();
          await release.future;
        }
      };
      final current = proxy.sessions.create(siteKey: 'current');
      final url = proxy.urlFor(
        current,
        playlist.replace(path: '/current.m3u8'),
      );
      final foreground = client
          .getUrl(Uri.parse(url))
          .then((r) => r.close())
          .then((r) => r.drain<void>());
      try {
        await entered.future.timeout(const Duration(seconds: 3));
        final inspected = proxy.inspectEpisodePrefetch(session, playlist);
        expect(upstreamHits, ['/current.m3u8']);
        proxy.setEpisodePrefetchPaused(false, allowManifestOverlap: true);
        expect(await inspected.timeout(const Duration(seconds: 2)), 40000);
        final warmed = log.stream.firstWhere(
          (e) => e.message.startsWith('预取窗口完成'),
        );
        proxy.primeEpisodePrefetch(session, startMs: 0, immediateNext: false);
        expect(upstreamHits, [
          '/current.m3u8',
          '/next.m3u8',
          '/vod/variant.m3u8',
        ]);
        expect(proxy.episodePrefetchReady(session), isFalse);
        release.complete();
        await foreground.timeout(const Duration(seconds: 3));
        await warmed.timeout(const Duration(seconds: 3));
        expect(proxy.episodePrefetchReady(session), isTrue);
        expect(upstreamHits.last, '/vod/s0.ts');
      } finally {
        if (!release.isCompleted) release.complete();
        await foreground;
      }
    },
  );

  test(
    'multiple foreground preemptions do not exhaust manifest inspection',
    () async {
      manifests['/next.m3u8'] = singleVariant;
      final entered = List.generate(3, (_) => Completer<void>());
      final release = List.generate(3, (_) => Completer<void>());
      var attempts = 0;
      beforeManifest = (path) async {
        if (path != '/vod/variant.m3u8') return;
        final attempt = attempts++;
        if (attempt >= entered.length) return;
        entered[attempt].complete();
        await release[attempt].future;
      };
      final candidate = proxy.inspectEpisodePrefetch(session, playlist);
      final foreground = proxy.sessions.create(siteKey: 'current');
      try {
        for (var i = 0; i < entered.length; i++) {
          await entered[i].future.timeout(const Duration(seconds: 4));
          final url = proxy.urlFor(
            foreground,
            playlist.replace(path: '/current.ts'),
          );
          final response = await (await client.getUrl(Uri.parse(url)))
              .close()
              .timeout(const Duration(seconds: 3));
          expect(response.statusCode, HttpStatus.ok);
          await response.drain<void>();
          release[i].complete();
        }
        expect(await candidate.timeout(const Duration(seconds: 4)), 40000);
        expect(attempts, 4);
      } finally {
        for (final gate in release) {
          if (!gate.isCompleted) gate.complete();
        }
      }
    },
  );

  test('foreground requests preempt a speculative variant download', () async {
    manifests['/next.m3u8'] = singleVariant;
    final firstVariantHit = Completer<void>();
    final releaseFirstVariant = Completer<void>();
    beforeManifest = (path) async {
      if (path == '/vod/variant.m3u8' && !firstVariantHit.isCompleted) {
        firstVariantHit.complete();
        await releaseFirstVariant.future;
      }
    };
    final inspected = proxy.inspectEpisodePrefetch(session, playlist);
    try {
      await firstVariantHit.future.timeout(const Duration(seconds: 3));
      final foreground = proxy.sessions.create(siteKey: 'current');
      final url = proxy.urlFor(
        foreground,
        playlist.replace(path: '/current.ts'),
      );
      final response = await (await client.getUrl(Uri.parse(url)))
          .close()
          .timeout(const Duration(seconds: 3));
      expect(response.statusCode, HttpStatus.ok);
      await response.drain<void>();
      expect(await inspected, 40000);
      expect(upstreamHits, [
        '/next.m3u8',
        '/vod/variant.m3u8',
        '/current.ts',
        '/vod/variant.m3u8',
      ]);
    } finally {
      releaseFirstVariant.complete();
    }
  });

  test('partial HTTP representations are not inspected', () async {
    partialManifest = true;
    expect(await proxy.inspectEpisodePrefetch(session, playlist), isNull);
  });

  test(
    'master and variant inspection share the manifest byte budget',
    () async {
      final padding = 'a' * (150 * 1024);
      manifests['/next.m3u8'] = '$singleVariant#$padding\n';
      manifests['/vod/variant.m3u8'] =
          '#EXTM3U\n#$padding\n#EXTINF:5,\ns0.ts\n#EXT-X-ENDLIST\n';
      expect(await proxy.inspectEpisodePrefetch(session, playlist), isNull);
      expect(upstreamHits, ['/next.m3u8', '/vod/variant.m3u8']);
    },
  );

  test(
    'the variant does not start when the master exhausted the request quota',
    () async {
      session = proxy.sessions.create(siteKey: 'test', maxRequests: 1);
      manifests['/next.m3u8'] = singleVariant;
      expect(await proxy.inspectEpisodePrefetch(session, playlist), isNull);
      expect(upstreamHits, ['/next.m3u8']);
    },
  );

  test('a no-store segment never makes the candidate ready', () async {
    private = true;
    await warm();
    expect(proxy.episodePrefetchReady(session), isFalse);
  });

  for (final useMaster in [false, true]) {
    test(
      'cross-origin speculative HLS resources get no credentials (master=$useMaster)',
      () async {
        final cdn = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => cdn.close(force: true));
        final variant = playlist.replace(port: cdn.port, path: '/variant.m3u8');
        if (useMaster) {
          manifests['/next.m3u8'] =
              '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\n$variant\n';
        } else {
          redirect = variant;
        }
        final cdnCredentials = <List<String?>>[];
        cdn.listen((request) async {
          cdnCredentials.add([
            request.headers.value('cookie'),
            request.headers.value('authorization'),
            request.headers.value('x-api-key'),
            request.headers.value('x-origin-signature'),
          ]);
          if (request.uri.path.endsWith('.m3u8')) {
            request.response.headers.contentType = ContentType(
              'application',
              'vnd.apple.mpegurl',
            );
            request.response.write(
              '#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXTINF:5,\ns0.ts\n#EXT-X-ENDLIST\n',
            );
          } else {
            request.response.headers.contentType = ContentType('video', 'mp2t');
            request.response.add([1, 2]);
          }
          await request.response.close();
        });
        session = proxy.sessions.create(
          siteKey: 'test',
          cookie: 'session=fixture',
          authorization: 'Bearer fixture',
          extraHeaders: {
            'X-Api-Key': 'fixture',
            'X-Origin-Signature': 'site-signed',
          },
        );
        expect(await proxy.inspectEpisodePrefetch(session, playlist), 5000);
        final finished = log.stream.firstWhere(
          (e) => e.message.startsWith('预取窗口完成'),
        );
        proxy.primeEpisodePrefetch(session, startMs: 0, immediateNext: true);
        await finished.timeout(const Duration(seconds: 3));
        expect(originCredentials, [
          'session=fixture',
          'Bearer fixture',
          'site-signed',
        ]);
        expect(session.establishedOrigin, isNull);
        expect(session.derivedHosts, isEmpty);
        expect(proxy.episodePrefetchReady(session), isTrue);
        expect(cdnCredentials, [
          [null, null, null, null],
          [null, null, null, null],
        ]);
        if (useMaster) {
          final scoped = proxy.sessions.create(
            siteKey: 'scoped',
            allowedHosts: {playlist.authority},
          );
          expect(await proxy.inspectEpisodePrefetch(scoped, playlist), isNull);
          expect(cdnCredentials, hasLength(2));
        }
      },
    );
  }
}
