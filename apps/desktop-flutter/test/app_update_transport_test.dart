import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/app_update.dart';
import 'package:webhtv_pc/services/app_update_service.dart';

const identity = AppUpdateIdentity(
  version: '0.1.0',
  tag: 'v0.1.0-202611231630',
);
const noProxy = AppUpdateProxySettings(enabled: false);
final now = DateTime.utc(2026, 11, 23, 12);
final apiUri = Uri.parse(
  'https://api.github.com/repos/Silent1566/webhtv-pc/releases?per_page=30',
);
final proxyIndex = AppUpdateProxySettings.defaults
    .routesFor(appUpdateIndexUri)
    .first;
final body = jsonEncode([
  {'tag_name': 'update-channel', 'assets': []},
  {'tag_name': 'v0.2.0-202611231630', 'assets': []},
]);

Future<AppUpdateCheck> check(AppUpdateService service) =>
    service.check(identity: identity, channel: AppUpdateChannel.stable);
Directory tempDir() {
  final dir = Directory.systemTemp.createTempSync('update-transport-');
  addTearDown(() => dir.deleteSync(recursive: true));
  return dir;
}

AppRelease release(List<AppReleaseAsset> assets) => AppRelease(
  tag: 'v0.2.0-202611231630',
  title: '',
  body: '',
  pageUri: appUpdateIndexUri,
  prerelease: false,
  draft: false,
  assets: assets,
);
AppReleaseAsset package(
  List<int> bytes, {
  Uri? uri,
  int? size,
  bool withDigest = true,
}) => AppReleaseAsset(
  name: 'update.zip',
  size: size ?? bytes.length,
  downloadUri:
      uri ??
      Uri.parse(
        'https://github.com/Silent1566/webhtv-pc/releases/download/v0.2.0-202611231630/update.zip',
      ),
  sha256: withDigest ? sha256.convert(bytes).toString() : null,
);
http.StreamedResponse streamed(
  String text,
  int code, {
  Map<String, String> headers = const {},
}) => http.StreamedResponse(
  Stream.value(utf8.encode(text)),
  code,
  headers: headers,
);

void main() {
  test('default static index succeeds without any API request', () async {
    final requests = <Uri>[];
    final service = AppUpdateService(
      client: MockClient((request) async {
        requests.add(request.url);
        return http.Response(body, 200);
      }),
    );
    final result = await check(service);
    expect(result.hasUpdate, isTrue);
    expect(result.release?.tag, 'v0.2.0-202611231630');
    expect(requests, [appUpdateIndexUri]);
    expect(result.source, isNotEmpty);
  });

  test('malformed static direct and proxy fall through to API once', () async {
    final requests = <Uri>[];
    final service = AppUpdateService(
      client: MockClient((request) async {
        requests.add(request.url);
        return http.Response(
          request.url == apiUri ? body : '<html>blocked</html>',
          200,
        );
      }),
    );
    expect((await check(service)).hasUpdate, isTrue);
    expect(requests, [appUpdateIndexUri, proxyIndex, apiUri]);
  });

  test('direct static error uses proxy success without API', () async {
    final requests = <Uri>[];
    final service = AppUpdateService(
      client: MockClient((request) async {
        requests.add(request.url);
        return http.Response(
          request.url == appUpdateIndexUri ? 'unavailable' : body,
          request.url == appUpdateIndexUri ? 502 : 200,
        );
      }),
    );
    expect((await check(service)).hasUpdate, isTrue);
    expect(requests, [appUpdateIndexUri, proxyIndex]);
  });

  for (final invalid in [
    '[]',
    '[{}]',
    '[{"tag_name":"update-channel"}]',
    '[{"tag_name":"random"}]',
    '<html/>',
    '{',
  ]) {
    test('invalid metadata never becomes latest: $invalid', () async {
      final service = AppUpdateService(
        client: MockClient((_) async => http.Response(invalid, 200)),
      );
      final result = await check(service);
      expect(result.failed, isTrue);
      expect(result.hasUpdate, isFalse);
    });
  }

  test(
    'static index without normal releases falls back to API instead of latest',
    () async {
      final requests = <Uri>[];
      final service = AppUpdateService(
        client: MockClient((request) async {
          requests.add(request.url);
          return http.Response(request.url == apiUri ? body : '[]', 200);
        }),
      );
      final result = await check(service);
      expect(result.hasUpdate, isTrue);
      expect(result.source, 'GitHub API');
      expect(requests.last, apiUri);
    },
  );

  test(
    'cold restart revalidates persisted body with source validators',
    () async {
      final dir = tempDir();
      final first = AppUpdateService(
        cacheDirectory: dir,
        clock: () => now,
        proxySettings: () => noProxy,
        client: MockClient(
          (_) async => http.Response(
            body,
            200,
            headers: {
              'etag': '"direct"',
              'last-modified': 'Mon, 23 Nov 2026 11:00:00 GMT',
            },
          ),
        ),
      );
      expect((await check(first)).hasUpdate, isTrue);
      final seen = <http.Request>[];
      final second = AppUpdateService(
        cacheDirectory: dir,
        clock: () => now.add(const Duration(days: 1)),
        proxySettings: () => noProxy,
        client: MockClient((r) async {
          seen.add(r);
          return http.Response('', 304);
        }),
      );
      final result = await check(second);
      expect(result.hasUpdate, isTrue);
      expect(result.fromCache, isTrue);
      expect(result.cachedAt, now);
      expect(seen.single.url, appUpdateIndexUri);
      expect(seen.single.headers['if-none-match'], '"direct"');
      expect(
        seen.single.headers['if-modified-since'],
        'Mon, 23 Nov 2026 11:00:00 GMT',
      );
    },
  );

  test('ETag is never forwarded from direct static to proxy or API', () async {
    final dir = tempDir();
    final first = AppUpdateService(
      cacheDirectory: dir,
      client: MockClient(
        (_) async => http.Response(body, 200, headers: {'etag': '"direct"'}),
      ),
    );
    await check(first);
    final seen = <http.Request>[];
    final second = AppUpdateService(
      cacheDirectory: dir,
      client: MockClient((r) async {
        seen.add(r);
        return http.Response(
          r.url == apiUri ? body : '',
          r.url == apiUri ? 200 : 503,
        );
      }),
    );
    expect((await check(second)).hasUpdate, isTrue);
    expect(seen.map((r) => r.url), [appUpdateIndexUri, proxyIndex, apiUri]);
    expect(seen[0].headers['if-none-match'], '"direct"');
    expect(seen[1].headers['if-none-match'], isNull);
    expect(seen[2].headers['if-none-match'], isNull);
  });

  test(
    'offline cached release retains failed verdict and age/source',
    () async {
      final dir = tempDir();
      await check(
        AppUpdateService(
          cacheDirectory: dir,
          clock: () => now,
          client: MockClient((_) async => http.Response(body, 200)),
        ),
      );
      final result = await check(
        AppUpdateService(
          cacheDirectory: dir,
          clock: () => now.add(const Duration(days: 10)),
          client: MockClient(
            (_) async => throw const SocketException('offline'),
          ),
        ),
      );
      expect(result.failed, isTrue);
      expect(result.hasUpdate, isFalse);
      expect(result.fromCache, isTrue);
      expect(result.release?.tag, 'v0.2.0-202611231630');
      expect(result.cachedAt, now);
      expect(result.source, isNotEmpty);
      expect(result.message, contains('缓存'));
    },
  );

  test(
    'cache disk failure cannot discard a successful network result',
    () async {
      final root = tempDir();
      final file = File('${root.path}/not-a-directory')
        ..writeAsStringSync('occupied');
      final result = await check(
        AppUpdateService(
          cacheDirectory: Directory(file.path),
          client: MockClient((_) async => http.Response(body, 200)),
        ),
      );
      expect(result.hasUpdate, isTrue);
    },
  );

  test('304 without matching cached body is a failure', () async {
    final result = await check(
      AppUpdateService(client: MockClient((_) async => http.Response('', 304))),
    );
    expect(result.failed, isTrue);
    expect(result.fromCache, isFalse);
  });

  for (final code in [403, 429]) {
    test(
      'rate evidence HTTP $code persists cooldown but still tries static',
      () async {
        final dir = tempDir();
        var apiCalls = 0;
        final first = AppUpdateService(
          useStaticIndex: false,
          cacheDirectory: dir,
          clock: () => now,
          client: MockClient((_) async {
            apiCalls++;
            return http.Response(
              '{"message":"rate limit exceeded"}',
              code,
              headers: {'retry-after': '120', 'x-ratelimit-remaining': '0'},
            );
          }),
        );
        final initial = await check(first);
        expect(initial.failed, isTrue);
        expect(initial.retryAt, now.add(const Duration(seconds: 120)));
        expect(initial.message, contains('限流'));
        final requests = <Uri>[];
        final next = AppUpdateService(
          cacheDirectory: dir,
          clock: () => now.add(const Duration(seconds: 1)),
          client: MockClient((r) async {
            requests.add(r.url);
            if (r.url == apiUri) apiCalls++;
            return http.Response('offline', 503);
          }),
        );
        final result = await check(next);
        expect(result.failed, isTrue);
        expect(apiCalls, 1);
        expect(requests, [appUpdateIndexUri, proxyIndex]);
        expect(result.retryAt, initial.retryAt);
        expect(result.message, contains('503'));
        expect(result.message, contains('限流'));
      },
    );
  }

  test(
    'ordinary forbidden is distinct from primary and secondary rate limits',
    () async {
      final service = AppUpdateService(
        useStaticIndex: false,
        client: MockClient(
          (_) async => http.Response('{"message":"Forbidden"}', 403),
        ),
      );
      final result = await check(service);
      expect(result.failed, isTrue);
      expect(result.retryAt, isNull);
      expect(result.message, contains('403'));
      expect(result.message, isNot(contains('限流')));
    },
  );

  test('primary reset and secondary default cooldown are recognized', () async {
    final reset = now.add(const Duration(minutes: 5));
    final primary = await check(
      AppUpdateService(
        useStaticIndex: false,
        clock: () => now,
        client: MockClient(
          (_) async => http.Response(
            '',
            403,
            headers: {
              'x-ratelimit-remaining': '0',
              'x-ratelimit-reset': '${reset.millisecondsSinceEpoch ~/ 1000}',
            },
          ),
        ),
      ),
    );
    expect(primary.retryAt, reset);
    final secondary = await check(
      AppUpdateService(
        useStaticIndex: false,
        clock: () => now,
        client: MockClient(
          (_) async => http.Response(
            '{"message":"You have exceeded a secondary rate limit"}',
            403,
          ),
        ),
      ),
    );
    expect(secondary.retryAt, now.add(const Duration(seconds: 60)));
  });

  test(
    'HTTP-date Retry-After and expired cooldown allow one API retry',
    () async {
      final dir = tempDir();
      final first = await check(
        AppUpdateService(
          useStaticIndex: false,
          cacheDirectory: dir,
          clock: () => now,
          client: MockClient(
            (_) async => http.Response(
              '',
              429,
              headers: {'retry-after': 'Mon, 23 Nov 2026 12:02:00 GMT'},
            ),
          ),
        ),
      );
      expect(first.retryAt, now.add(const Duration(minutes: 2)));
      var calls = 0;
      final result = await check(
        AppUpdateService(
          useStaticIndex: false,
          cacheDirectory: dir,
          clock: () => now.add(const Duration(minutes: 3)),
          client: MockClient((_) async {
            calls++;
            return http.Response(body, 200);
          }),
        ),
      );
      expect(result.hasUpdate, isTrue);
      expect(calls, 1);
    },
  );

  test(
    'metadata body is capped and source attempts have a total route timeout',
    () async {
      var cancelled = 0;
      final requests = <Uri>[];
      final service = AppUpdateService(
        timeout: const Duration(milliseconds: 30),
        client: MockClient.streaming((r, _) async {
          requests.add(r.url);
          if (r.url == appUpdateIndexUri) {
            return streamed('x' * (2 * 1024 * 1024 + 1), 200);
          }
          if (r.url == proxyIndex) {
            final controller = StreamController<List<int>>(
              onCancel: () {
                cancelled++;
              },
            );
            final timer = Timer.periodic(
              const Duration(milliseconds: 3),
              (_) => controller.add([32]),
            );
            controller.onCancel = () {
              timer.cancel();
              cancelled++;
            };
            return http.StreamedResponse(controller.stream, 200);
          }
          return streamed(body, 200);
        }),
      );
      final result = await check(service);
      expect(result.hasUpdate, isTrue);
      expect(requests, [appUpdateIndexUri, proxyIndex, apiUri]);
      expect(cancelled, 1);
    },
  );

  test('settings callback is captured once for every check', () async {
    var snapshots = 0;
    final routes = <Uri>[];
    final service = AppUpdateService(
      proxySettings: () {
        snapshots++;
        return AppUpdateProxySettings.defaults;
      },
      client: MockClient((r) async {
        routes.add(r.url);
        return http.Response(
          r.url == proxyIndex ? body : '',
          r.url == proxyIndex ? 200 : 503,
        );
      }),
    );
    expect((await check(service)).hasUpdate, isTrue);
    expect(snapshots, 1);
    expect(routes, [appUpdateIndexUri, proxyIndex]);
  });

  for (final failure in [
    'http',
    'hash',
    'size',
    'length',
    'stream',
    'idle',
    'html',
  ]) {
    test(
      'proxy $failure failure closes and removes partial before direct package',
      () async {
        final dir = tempDir();
        final bytes = utf8.encode('verified-package');
        final asset = package(bytes);
        final requests = <Uri>[];
        var cancelled = false;
        final service = AppUpdateService(
          timeout: const Duration(milliseconds: 30),
          client: MockClient.streaming((r, _) async {
            requests.add(r.url);
            if (r.url == asset.downloadUri) {
              expect(File('${dir.path}/update.zip.part').existsSync(), isFalse);
              if (failure == 'stream' || failure == 'idle') {
                expect(cancelled, isTrue);
              }
              return http.StreamedResponse(
                Stream.value(bytes),
                200,
                contentLength: bytes.length,
              );
            }
            if (failure == 'http') return streamed('failed', 502);
            if (failure == 'html') {
              return streamed('<html>not a package</html>', 200);
            }
            if (failure == 'hash') {
              return http.StreamedResponse(
                Stream.value(List.filled(bytes.length, 0)),
                200,
              );
            }
            if (failure == 'size') {
              return http.StreamedResponse(Stream.value(bytes.sublist(1)), 200);
            }
            if (failure == 'length') {
              return http.StreamedResponse(
                Stream.value(bytes),
                200,
                contentLength: bytes.length + 1,
              );
            }
            final controller = StreamController<List<int>>();
            controller.onListen = () {
              controller.add([1]);
              if (failure == 'stream') {
                controller.addError(const SocketException('stream failed'));
              }
            };
            controller.onCancel = () {
              cancelled = true;
            };
            return http.StreamedResponse(controller.stream, 200);
          }),
        );
        final result = await service.download(
          release([asset]),
          asset,
          destination: dir,
        );
        expect(result.file.readAsBytesSync(), bytes);
        expect(result.sha256, sha256.convert(bytes).toString());
        expect(
          requests,
          AppUpdateProxySettings.defaults.routesFor(asset.downloadUri),
        );
        expect(dir.listSync().length, 1);
      },
    );
  }

  test(
    'checksum proxy failure falls back direct and expected hash stays fixed',
    () async {
      final dir = tempDir();
      final bytes = utf8.encode('verified-package');
      final asset = package(bytes, withDigest: false);
      final sums = AppReleaseAsset(
        name: appUpdateChecksumAssetName,
        size: 0,
        downloadUri: asset.downloadUri.resolve(appUpdateChecksumAssetName),
      );
      final requests = <Uri>[];
      var snapshots = 0;
      final service = AppUpdateService(
        proxySettings: () {
          snapshots++;
          return AppUpdateProxySettings.defaults;
        },
        client: MockClient((r) async {
          requests.add(r.url);
          if (r.url.path.endsWith(appUpdateChecksumAssetName)) {
            return http.Response(
              r.url.host == 'github.com'
                  ? '${sha256.convert(bytes)}  update.zip'
                  : '<html/>',
              200,
            );
          }
          if (r.url.host != 'github.com') {
            return http.Response.bytes(List.filled(bytes.length, 0), 200);
          }
          return http.Response.bytes(bytes, 200);
        }),
      );
      final result = await service.download(
        release([asset, sums]),
        asset,
        destination: dir,
      );
      expect(result.file.readAsBytesSync(), bytes);
      expect(snapshots, 1);
      expect(requests, [
        ...AppUpdateProxySettings.defaults.routesFor(sums.downloadUri),
        ...AppUpdateProxySettings.defaults.routesFor(asset.downloadUri),
      ]);
    },
  );

  for (final mode in ['disabled', 'non-project', 'already-proxied', 'api']) {
    test('$mode package bypasses proxy', () async {
      final bytes = utf8.encode('verified-package');
      final uri = switch (mode) {
        'non-project' => Uri.parse(
          'https://github.com/other/repo/releases/download/v1/update.zip',
        ),
        'already-proxied' => Uri.parse(
          'https://gh-proxy.com/https://github.com/Silent1566/webhtv-pc/releases/download/v1/update.zip',
        ),
        'api' => apiUri,
        _ => null,
      };
      final asset = package(bytes, uri: uri);
      final requests = <Uri>[];
      final service = AppUpdateService(
        proxySettings: () =>
            mode == 'disabled' ? noProxy : AppUpdateProxySettings.defaults,
        client: MockClient((r) async {
          requests.add(r.url);
          return http.Response.bytes(bytes, 200);
        }),
      );
      await service.download(release([asset]), asset, destination: tempDir());
      expect(requests, [asset.downloadUri]);
    });
  }

  test('size is enforced even when candidate hash matches and every failed route is cleaned', () async {
    final bytes = utf8.encode('verified-package');
    final asset = package(bytes, size: bytes.length + 1);
    final dir = tempDir();
    var calls = 0;
    final service = AppUpdateService(
      client: MockClient((_) async {
        calls++;
        return http.Response.bytes(bytes, 200);
      }),
    );
    await expectLater(
      service.download(release([asset]), asset, destination: dir),
      throwsA(isA<AppUpdateException>()),
    );
    expect(calls, 2);
    expect(dir.listSync(), isEmpty);
  });

  test('metadata send timeout aborts request before direct fallback', () async {
    var aborted = false;
    final service = AppUpdateService(
      timeout: const Duration(milliseconds: 20),
      client: MockClient.streaming((request, _) async {
        if (request.url == appUpdateIndexUri) {
          if (request is! http.Abortable || request.abortTrigger == null) {
            await Future<void>.delayed(const Duration(milliseconds: 40));
            return streamed('', 503);
          }
          await request.abortTrigger;
          aborted = true;
          throw http.RequestAbortedException();
        }
        expect(aborted, isTrue);
        return streamed(body, 200);
      }),
    );
    expect((await check(service)).hasUpdate, isTrue);
    expect(aborted, isTrue);
  });

  test(
    'primary exhausted headers on successful API response persist cooldown',
    () async {
      final dir = tempDir();
      final reset = now.add(const Duration(minutes: 5));
      await check(
        AppUpdateService(
          useStaticIndex: false,
          cacheDirectory: dir,
          clock: () => now,
          client: MockClient(
            (_) async => http.Response(
              body,
              200,
              headers: {
                'x-ratelimit-remaining': '0',
                'x-ratelimit-reset': '${reset.millisecondsSinceEpoch ~/ 1000}',
              },
            ),
          ),
        ),
      );
      var calls = 0;
      final result = await check(
        AppUpdateService(
          useStaticIndex: false,
          cacheDirectory: dir,
          clock: () => now,
          client: MockClient((_) async {
            calls++;
            return http.Response(body, 200);
          }),
        ),
      );
      expect(calls, 0);
      expect(result.failed, isTrue);
      expect(result.fromCache, isTrue);
      expect(result.retryAt, reset);
    },
  );

  test(
    'HTML candidate is rejected even when bad release metadata hashes HTML',
    () async {
      final bytes = utf8.encode('<!doctype html><html>gateway page</html>');
      final asset = package(bytes);
      final dir = tempDir();
      final service = AppUpdateService(
        client: MockClient((_) async => http.Response.bytes(bytes, 200)),
      );
      await expectLater(
        service.download(release([asset]), asset, destination: dir),
        throwsA(isA<AppUpdateException>()),
      );
      expect(dir.listSync(), isEmpty);
    },
  );

  test('noneligible metadata index bypasses proxy and never exposes query in errors', () async {
    final index = Uri.parse(
      'https://metadata.example.test/releases.json?private=secret',
    );
    final routes = <Uri>[];
    final result = await check(
      AppUpdateService(
        indexUri: index,
        client: MockClient((r) async {
          routes.add(r.url);
          throw http.ClientException('failed ${r.url}');
        }),
      ),
    );
    expect(result.failed, isTrue);
    expect(routes, [index, apiUri]);
    expect(result.message, isNot(contains('secret')));
  });

  test('proxy cache survives restart with only its own validators', () async {
    final dir = tempDir();
    await check(
      AppUpdateService(
        cacheDirectory: dir,
        clock: () => now,
        client: MockClient(
          (r) async => http.Response(
            r.url == proxyIndex ? body : '',
            r.url == proxyIndex ? 200 : 503,
            headers: r.url == proxyIndex ? {'etag': '"proxy"'} : {},
          ),
        ),
      ),
    );
    final seen = <http.Request>[];
    final result = await check(
      AppUpdateService(
        cacheDirectory: dir,
        clock: () => now.add(const Duration(minutes: 1)),
        client: MockClient((r) async {
          seen.add(r);
          return http.Response('', r.url == proxyIndex ? 304 : 503);
        }),
      ),
    );
    expect(result.hasUpdate, isTrue);
    expect(result.fromCache, isTrue);
    expect(result.cachedAt, now);
    expect(seen.length, 2);
    expect(seen[0].headers['if-none-match'], isNull);
    expect(seen[1].headers['if-none-match'], '"proxy"');
    expect(
      dir.listSync().map((f) => f.path.endsWith('.tmp')),
      everyElement(isFalse),
    );
  });

  test('corrupt disk cache and invalid revalidation body cannot fabricate a release', () async {
    final dir = tempDir();
    File('${dir.path}/releases-cache.json').writeAsStringSync('{');
    expect(
      (await check(
        AppUpdateService(
          cacheDirectory: dir,
          client: MockClient((_) async => http.Response(body, 200)),
        ),
      )).hasUpdate,
      isTrue,
    );
    File('${dir.path}/releases-cache.json').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'entries': {
          '$appUpdateIndexUri': {
            'body': '[]',
            'savedAt': now.toIso8601String(),
            'etag': '"broken"',
          },
        },
        'cooldowns': {},
      }),
    );
    final result = await check(
      AppUpdateService(
        cacheDirectory: dir,
        client: MockClient(
          (r) async =>
              http.Response('', r.url == appUpdateIndexUri ? 304 : 503),
        ),
      ),
    );
    expect(result.failed, isTrue);
    expect(result.release, isNull);
    expect(result.fromCache, isFalse);
  });

  test('changing proxy routes never reuses old proxy body or ETag', () async {
    final dir = tempDir();
    await check(
      AppUpdateService(
        cacheDirectory: dir,
        client: MockClient(
          (r) async => http.Response(
            r.url == proxyIndex ? body : '',
            r.url == proxyIndex ? 200 : 503,
            headers: {'etag': '"old-proxy"'},
          ),
        ),
      ),
    );
    final seen = <http.Request>[];
    final result = await check(
      AppUpdateService(
        cacheDirectory: dir,
        proxySettings: () =>
            const AppUpdateProxySettings(baseUrl: 'https://ghfast.top/'),
        client: MockClient((r) async {
          seen.add(r);
          return http.Response('', 503);
        }),
      ),
    );
    expect(result.failed, isTrue);
    expect(result.release, isNull);
    expect(
      seen,
      everyElement(
        predicate<http.Request>((r) => !r.headers.containsKey('if-none-match')),
      ),
    );
  });

  test('API 304 exhausted headers also persist rate cooldown', () async {
    final dir = tempDir();
    final reset = now.add(const Duration(minutes: 5));
    await check(
      AppUpdateService(
        useStaticIndex: false,
        cacheDirectory: dir,
        clock: () => now,
        client: MockClient(
          (_) async => http.Response(body, 200, headers: {'etag': '"api"'}),
        ),
      ),
    );
    final revalidated = await check(
      AppUpdateService(
        useStaticIndex: false,
        cacheDirectory: dir,
        clock: () => now,
        client: MockClient(
          (_) async => http.Response(
            '',
            304,
            headers: {
              'x-ratelimit-remaining': '0',
              'x-ratelimit-reset': '${reset.millisecondsSinceEpoch ~/ 1000}',
            },
          ),
        ),
      ),
    );
    expect(revalidated.hasUpdate, isTrue);
    var calls = 0;
    final offline = await check(
      AppUpdateService(
        useStaticIndex: false,
        cacheDirectory: dir,
        clock: () => now,
        client: MockClient((_) async {
          calls++;
          return http.Response(body, 200);
        }),
      ),
    );
    expect(calls, 0);
    expect(offline.failed, isTrue);
    expect(offline.retryAt, reset);
  });

  test('client ownership only closes explicitly owned injected clients', () {
    final owned = TrackingClient();
    final borrowed = TrackingClient();
    AppUpdateService(client: owned, ownsClient: true).close();
    AppUpdateService(client: borrowed).close();
    expect(owned.closed, isTrue);
    expect(borrowed.closed, isFalse);
    borrowed.close();
  });
}

class TrackingClient extends MockClient {
  TrackingClient() : super((_) async => http.Response('', 200));
  bool closed = false;
  @override
  void close() {
    closed = true;
    super.close();
  }
}
