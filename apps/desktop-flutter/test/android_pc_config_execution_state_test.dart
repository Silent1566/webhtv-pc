import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/app_error.dart';

import 'android_pc_config_execution_fixtures.dart';

void main() {
  late PcExecutionFixture f;
  setUp(() async {
    final root = Directory(
      '../../.superpowers/sdd/2026-11-24-pc-config-android-execution/proxy-octet-hls/run2/state-fixture',
    );
    if (root.existsSync()) root.deleteSync(recursive: true);
    root.createSync(recursive: true);
    f = PcExecutionFixture(root);
    await f.boot();
  });
  tearDown(() => f.close());

  Future<_PublicPlayerFixture> publicFixture() async {
    await f.close();
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => origin.close(force: true));
    origin.listen((request) async {
      request.response.headers.contentType = ContentType.binary;
      if (request.uri.path == '/manifest') {
        request.response.write(
          '#EXTM3U\n#EXT-X-TARGETDURATION:1\n'
          '#EXTINF:1,\nhttp://93.184.216.34/segment.ts\n'
          '#EXTINF:1,\nhttp://1.1.1.1/cdn.ts\n#EXT-X-ENDLIST\n',
        );
      } else {
        request.response.add([0, 0, 0, 24, 102, 116, 121, 112]);
      }
      await request.response.close();
    });
    final fixture = _PublicPlayerFixture(f.root);
    f = fixture;
    await HttpOverrides.runWithHttpOverrides(
      () => fixture.boot(),
      PcExecutionProxyOverrides(origin.port),
    );
    return fixture;
  }

  for (final anotherActive in [false, true]) {
    test(
      'Android original public HLS retains source A provenance while B active=$anotherActive',
      () async {
        await publicFixture();
        await f.state.runConfigOnAndroid(f.recordId, f.profile.connectionKey);
        final original = f.state.savedConfigs.single;
        if (anotherActive) {
          final second = f.state.database!.saveConfig(
            name: 'PC B',
            origin: 'https://second.test/a.json',
            sourceKey: 'local|https://second.test/a.json',
            json: const {
              'sites': [
                {
                  'key': 'ordinary',
                  'name': 'PC',
                  'type': 0,
                  'api': 'https://second.test/',
                },
              ],
            },
            makeActive: false,
          );
          expect(await f.state.activateConfigRecord(second), isTrue);
        }
        final out = await f.state.resolvePlaybackForSource(
          sourceKey: pcExecutionSource,
          siteKey: anotherActive ? 'csp_A' : 'csp_B',
          episodeTarget: 'public-media',
          flag: '线路甲',
        );
        expect(out, isNotNull, reason: f.state.lastError?.logLine);
        expect(out!.url, startsWith(f.state.proxyBaseUrl));
        final session = f.state.proxySessions.byToken(
          Uri.parse(out.url!).pathSegments[1],
        )!;
        expect(session.targetResolver, isNull, reason: '公网媒体不需要 ADB origin 映射');
        expect(session.inspectPlaylistContent, isTrue);
        expect(session.allowedHosts, isEmpty);
        if (!anotherActive) {
          expect(session.userAgent, isNull);
          expect(session.referer, isNull, reason: '即使没有播放头，来源检查也必须强制走代理');
        }
        final client = HttpOverrides.runWithHttpOverrides(
          () => HttpClient(),
          PcExecutionHttpOverrides(),
        );
        try {
          final response = await (await client.getUrl(Uri.parse(out.url!)))
              .close();
          expect(response.statusCode, 200);
          expect(
            response.headers.contentType?.mimeType,
            'application/vnd.apple.mpegurl',
          );
          final body = await utf8.decoder.bind(response).join();
          final children = RegExp(r'https?://[^\s"<>]+')
              .allMatches(body)
              .map((m) => m.group(0)!)
              .toList();
          expect(children, hasLength(2));
          expect(body, isNot(contains('93.184.216.34')));
          expect(body, isNot(contains('1.1.1.1')));
          for (final url in children) {
            expect(Uri.parse(url).pathSegments.take(2), ['p', session.token]);
            final child = await (await client.getUrl(Uri.parse(url))).close();
            expect(child.statusCode, 200);
            expect(await child.fold<int>(0, (n, chunk) => n + chunk.length), 8);
          }
        } finally {
          client.close(force: true);
        }
        final stored = f.state.savedConfigs.firstWhere(
          (r) => r.id == original.id,
        );
        expect(stored.id, original.id);
        expect(stored.json, original.json);
        expect(stored.sourceKey, original.sourceKey);
        expect(
          f.state.playbackContextFor(pcExecutionSource)!.service.playbackBridge,
          isNull,
        );
        if (anotherActive) {
          expect(f.state.activeSourceKey, 'local|https://second.test/a.json');
        }
      },
    );
  }

  test(
    'public inspection provenance does not fall back to denied private media',
    () async {
      final public = await publicFixture();
      await f.state.runConfigOnAndroid(f.recordId, f.profile.connectionKey);
      public.mediaUrl = 'http://192.168.50.3/manifest';
      await expectLater(
        f.state.resolvePlaybackForSource(
          sourceKey: pcExecutionSource,
          siteKey: 'csp_B',
          episodeTarget: 'denied-media',
        ),
        throwsA(isA<AppError>()),
      );
      expect(f.state.proxySessionFingerprint, isNull);
    },
  );

  test('retired Android source cannot use late public playback', () async {
    final public = await publicFixture();
    await f.state.runConfigOnAndroid(f.recordId, f.profile.connectionKey);
    public.beforePlay = () => f.state.runConfigOnPc(f.recordId);
    final out = await f.state.resolvePlaybackForSource(
      sourceKey: pcExecutionSource,
      siteKey: 'csp_A',
      episodeTarget: 'late-media',
    );
    expect(out, isNull);
    expect(f.state.proxySessionFingerprint, isNull);
  });

  test('disconnected Android source cannot use late public playback', () async {
    final public = await publicFixture();
    await f.state.runConfigOnAndroid(f.recordId, f.profile.connectionKey);
    public.beforePlay = () => f.runtime.disconnect('pc-execution-device');
    final out = await f.state.resolvePlaybackForSource(
      sourceKey: pcExecutionSource,
      siteKey: 'csp_A',
      episodeTarget: 'late-media',
    );
    expect(out, isNull);
    expect(f.state.proxySessionFingerprint, isNull);
  });

  test('valid saved JSON executes with HTML transport MIME without rewriting metadata', () async {
    final original = f.state.savedConfigs.firstWhere((r) => r.id == f.recordId);
    f.state.database!.saveConfig(
      name: original.name,
      origin: original.origin,
      json: original.json,
      sourceKey: original.sourceKey,
      contentType: 'text/html',
      siteCount: original.siteCount,
      makeActive: false,
    );
    await f.state.runConfigOnAndroid(f.recordId, f.profile.connectionKey);
    final stored = f.state.savedConfigs.firstWhere((r) => r.id == f.recordId);
    expect(stored.contentType, 'text/html');
    expect(stored.json, original.json);
    expect(stored.sourceKey, original.sourceKey);
    expect(f.state.effectiveConfig!.sites.every((s) => s.type == 4), isTrue);
  });

  Future<void> waitForPendingImport() async {
    for (var attempt = 0; attempt < 200; attempt++) {
      if (f.store.bindings.isNotEmpty && f.servers.isNotEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('真实服务没有到达已预留绑定的导入阶段');
  }

  test('PC choice during pending import never reactivates the original record or caches its late overlay', () async {
    f.importGate = Completer<void>();
    final pending = f.state.runConfigOnAndroid(
      f.recordId,
      f.profile.connectionKey,
    );
    await waitForPendingImport();
    await f.state.runConfigOnPc(f.recordId);
    f.importGate!.complete();
    await pending;
    expect(
      f.state.androidExecutionForRecord(f.state.savedConfigs.single),
      isNull,
    );
    expect(f.state.activeRecord, isNull, reason: '迟到的准备不得激活用户已取消的记录');
    expect(f.state.effectiveConfig, isNull);
    expect(
      f.state.playbackContextFor(pcExecutionSource)!.config.sites.first.type,
      3,
    );
    expect(f.state.savedConfigs.single.json, pcExecutionRaw);
    expect(f.store.bindings.single.isReady, isTrue, reason: '保留稳定副本元数据，但不得启用');
  });

  test('explicit selection of another PC record during prepare wins over late Android activation', () async {
    final second = f.state.database!.saveConfig(
      name: '最新选择',
      origin: 'https://second.test/a.json',
      sourceKey: 'local|https://second.test/a.json',
      json: const {
        'sites': [
          {
            'key': 'ordinary',
            'name': '普通',
            'type': 0,
            'api': 'https://second.test/',
          },
        ],
      },
      makeActive: false,
    );
    f.importGate = Completer<void>();
    final pending = f.state.runConfigOnAndroid(
      f.recordId,
      f.profile.connectionKey,
    );
    await waitForPendingImport();
    expect(await f.state.activateConfigRecord(second), isTrue);
    f.importGate!.complete();
    await pending;
    expect(f.state.activeRecord!.id, second);
    expect(f.state.activeSourceKey, 'local|https://second.test/a.json');
    expect(f.state.effectiveConfig!.sites.single.type, 0);
    expect(f.state.selectedSite!.key, 'ordinary');
    expect(
      f.state.savedConfigs.firstWhere((r) => r.id == f.recordId).json,
      pcExecutionRaw,
    );
  });

  test('failed selected refresh clears cached context and never resumes through PC JAR fallback', () async {
    await f.state.runConfigOnAndroid(f.recordId, f.profile.connectionKey);
    final oldService = f.state.playbackContextFor(pcExecutionSource)!.service;
    f.missingKey = true;
    await expectLater(
      f.state.refreshAndroidConfigExecution(f.recordId),
      throwsA(isA<AppError>()),
    );
    expect(
      f.state.androidExecutionForRecord(f.state.savedConfigs.single),
      isNotNull,
    );
    expect(f.state.effectiveConfig, isNull);
    expect(f.state.siteService, isNull);
    expect(f.state.playbackContextFor(pcExecutionSource), isNull);
    expect(f.state.lastError, isNotNull);
    final outcome = await f.state.resolvePlaybackForSource(
      sourceKey: pcExecutionSource,
      siteKey: 'csp_A',
      episodeTarget: 'guest-episode',
    );
    expect(outcome, isNull);
    expect(f.state.siteService, isNot(same(oldService)));
    expect(f.requests.where((uri) => uri.path.endsWith('.jar')), isEmpty);
    expect(f.state.savedConfigs.single.json, pcExecutionRaw);
  });

  test('disable during a selected refresh keeps the latest desktop service after refresh completes', () async {
    await f.state.runConfigOnAndroid(f.recordId, f.profile.connectionKey);
    f.importGate = Completer<void>();
    final pending = f.state.refreshAndroidConfigExecution(f.recordId);
    // Let the actual SDK/service reach the HTTP import barrier.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await f.state.runConfigOnPc(f.recordId);
    final desktopService = f.state.siteService;
    f.importGate!.complete();
    await pending;
    expect(f.state.androidExecutionForRecord(f.state.activeRecord!), isNull);
    expect(f.state.effectiveConfig!.sites.first.type, 3);
    expect(
      f.state.siteService,
      same(desktopService),
      reason: '迟到的刷新不能覆盖用户已切回的桌面服务',
    );
    expect(
      f.state.playbackContextFor(pcExecutionSource)!.config.sites.first.type,
      3,
    );
    expect(f.state.savedConfigs.single.json, pcExecutionRaw);
  });

  test(
    'delete while preparing cannot restore the deleted original PC record',
    () async {
      f.importGate = Completer<void>();
      final pending = f.state.runConfigOnAndroid(
        f.recordId,
        f.profile.connectionKey,
      );
      await waitForPendingImport();
      final deletion = f.state.deleteConfigRecord(f.recordId);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      f.importGate!.complete();
      await deletion;
      await pending;
      expect(f.state.savedConfigs, isEmpty);
      expect(f.state.activeRecord, isNull);
      expect(f.state.effectiveConfig, isNull);
      expect(f.state.playbackContextFor(pcExecutionSource), isNull);
    },
  );

  test('failed changed-payload execution remains unavailable until an explicit PC choice even if backend clears selection', () async {
    await f.state.runConfigOnAndroid(f.recordId, f.profile.connectionKey);
    final changed = {...pcExecutionRaw, 'notice': 'new original payload'};
    f.state.database!.saveConfig(
      name: '原 PC 配置',
      origin: 'https://pc.example.test/config/original.json',
      json: changed,
      sourceKey: pcExecutionSource,
      makeActive: true,
    );
    f.missingKey = true;
    await expectLater(
      f.state.runConfigOnAndroid(f.recordId, f.profile.connectionKey),
      throwsA(isA<AppError>()),
    );
    expect(f.state.effectiveConfig, isNull, reason: '失败后不能因后端清除选择而静默回退 PC JAR');
    expect(f.state.siteService, isNull);
    expect(f.state.playbackContextFor(pcExecutionSource), isNull);
    expect(
      f.state.androidExecutionLabelForRecord(f.state.savedConfigs.single),
      contains('重试'),
    );
    expect(f.state.savedConfigs.single.json, changed);
    await f.state.runConfigOnPc(f.recordId);
    expect(f.state.effectiveConfig!.sites.first.type, 3);
    expect(f.state.siteService!.playbackBridge, isNotNull);
    expect(f.state.savedConfigs.single.json, changed);
  });
  test('run overlays original CSP keys without changing original SQLite identity or raw fields', () async {
    final before = f.state.savedConfigs.single;
    await f.state.runConfigOnAndroid(f.recordId, f.profile.connectionKey);
    final after = f.state.savedConfigs.single;
    expect(after.id, before.id);
    expect(after.origin, before.origin);
    expect(after.json, before.json);
    expect(after.sourceKey, pcExecutionSource);
    expect(after.bridgeTransport, '');
    expect(after.bridgeInterfaceKey, '');
    expect(f.state.config!.sites.first.type, 3);
    expect(f.state.effectiveConfig!.sites.map((site) => site.key), [
      'csp_A',
      'csp_B',
    ]);
    expect(f.state.effectiveConfig!.sites.map((site) => site.type), [4, 4]);
    expect(f.state.effectiveConfig!.sites.first.name, '原站点甲');
    expect(f.state.effectiveConfig!.flags, ['线路甲', '线路乙']);
    expect(f.state.siteService!.playbackBridge, isNull);
    final binding = f.state.androidExecutionForRecord(after)!;
    expect(binding.interfaceKey, 'copied-source-1');
    expect(
      jsonDecode(f.state.syncConfigJson()!)['configKey'],
      binding.interfaceKey,
    );
    expect(f.state.activeSourceKey, pcExecutionSource);
    expect(f.snapshots.first['unknown'], {'literal': 'keep me'});
    expect(
      (f.snapshots.first['sites'] as List).first['jar'],
      'https://pc.example.test/config/source.jar',
    );
  });

  test('disable restores PC and reenable reuses the same nonactive copy URL and interfaceKey', () async {
    await f.state.runConfigOnAndroid(f.recordId, f.profile.connectionKey);
    final binding = f.state.androidExecutionForRecord(f.state.activeRecord!)!;
    await f.state.runConfigOnPc(f.recordId);
    expect(f.state.androidExecutionForRecord(f.state.activeRecord!), isNull);
    expect(f.state.effectiveConfig!.sites.first.type, 3);
    expect(f.state.siteService!.playbackBridge, isNotNull);
    await f.state.runConfigOnAndroid(f.recordId, f.profile.connectionKey);
    final restored = f.state.androidExecutionForRecord(f.state.activeRecord!)!;
    expect(restored.snapshotToken, binding.snapshotToken);
    expect(restored.guestPort, binding.guestPort);
    expect(restored.interfaceKey, binding.interfaceKey);
    expect(f.copies, hasLength(1));
    expect(f.state.savedConfigs, hasLength(1));
  });

  test('execution context while another PC config is active uses its original gateway and source identity', () async {
    await f.state.runConfigOnAndroid(f.recordId, f.profile.connectionKey);
    final originalContext = f.state.playbackContextFor(pcExecutionSource)!;
    final second = f.state.database!.saveConfig(
      name: '另一配置',
      origin: 'https://second.test/a.json',
      sourceKey: 'local|https://second.test/a.json',
      json: const {
        'sites': [
          {
            'key': 'ordinary',
            'name': '普通',
            'type': 0,
            'api': 'https://second.test/',
          },
        ],
      },
      makeActive: false,
    );
    await f.state.activateConfigRecord(second);
    final context = f.state.playbackContextFor(pcExecutionSource)!;
    expect(context.config.sites.first.type, 4);
    expect(context.service.playbackBridge, isNull);
    final out = await f.state.resolvePlaybackForSource(
      sourceKey: pcExecutionSource,
      siteKey: 'csp_A',
      episodeTarget: 'guest-episode',
      flag: '线路甲',
    );
    expect(out, isNotNull, reason: f.state.lastError?.logLine);
    expect(out!.url, startsWith(f.state.proxyBaseUrl));
    expect(f.state.activeRecord!.id, second);
    expect(context.sourceKey, originalContext.sourceKey);
    expect(
      f.state.savedConfigs.firstWhere((r) => r.id == f.recordId).json,
      pcExecutionRaw,
    );
  });

  test('fresh reconnect invalidates old context gateway while preserving original source', () async {
    await f.state.runConfigOnAndroid(f.recordId, f.profile.connectionKey);
    final old = f.state.playbackContextFor(pcExecutionSource)!;
    await f.runtime.disconnect('pc-execution-device');
    expect(f.state.playbackContextFor(pcExecutionSource), isNull);
    await f.state.refreshAndroidConfigExecution(f.recordId);
    final fresh = f.state.playbackContextFor(pcExecutionSource)!;
    expect(fresh.service, isNot(same(old.service)));
    expect(fresh.config.sites.first.api, isNot(old.config.sites.first.api));
    expect(f.copies, hasLength(1));
    expect(f.state.activeSourceKey, pcExecutionSource);
  });

  test('forgotten profile and wrong UUID fail closed without changing original row', () async {
    await f.state.runConfigOnAndroid(f.recordId, f.profile.connectionKey);
    final before = f.state.savedConfigs.single;
    await f.runtime.disconnect('pc-execution-device');
    f.uuid = 'other-device';
    await expectLater(
      f.state.refreshAndroidConfigExecution(f.recordId),
      throwsA(isA<AppError>()),
    );
    expect(f.state.effectiveConfig, isNull);
    expect(f.state.savedConfigs.single.json, before.json);
    await f.state.forgetAndroidConnection(f.profile.connectionKey);
    await expectLater(
      f.state.refreshAndroidConfigExecution(f.recordId),
      throwsA(isA<AppError>()),
    );
    expect(f.state.savedConfigs.single.sourceKey, pcExecutionSource);
  });

  test(
    'missing T4 key or reverse conflict never enable a partial overlay',
    () async {
      f.missingKey = true;
      await expectLater(
        f.state.runConfigOnAndroid(f.recordId, f.profile.connectionKey),
        throwsA(anything),
      );
      expect(
        f.state.androidExecutionForRecord(f.state.savedConfigs.single),
        isNull,
      );
      expect(f.state.savedConfigs.single.json, pcExecutionRaw);
      f.missingKey = false;
      f.reverseConflict = true;
      await f.runtime.disconnect('pc-execution-device');
      await expectLater(
        f.state.runConfigOnAndroid(f.recordId, f.profile.connectionKey),
        throwsA(isA<AppError>()),
      );
      expect(f.state.savedConfigs.single.bridgeTransport, '');
    },
  );

  test('refresh publishes changed original raw snapshot at stable URL without rewriting it as T4', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(f.original));
      await request.response.close();
    });
    final origin = 'http://pc.example.test/config/original.json';
    f.state.database!.updateConfigIdentity(
      f.recordId,
      name: '原 PC 配置',
      origin: origin,
      sourceKey: 'local|$origin',
    );
    f.state.dispose();
    await f.state.androidExecutionShutdown;
    f.runtime = f.newRuntime();
    await HttpOverrides.runWithHttpOverrides(
      () => f.boot(seed: false),
      PcExecutionProxyOverrides(server.port),
    );
    await f.state.runConfigOnAndroid(f.recordId, f.profile.connectionKey);
    final binding = f.state.androidExecutionForRecord(f.state.activeRecord!)!;
    f.original = {...pcExecutionRaw, 'notice': 'updated original'};
    expect(
      await f.state.refreshConfigRecord(f.recordId),
      isTrue,
      reason: f.state.lastError?.logLine,
    );
    expect(f.snapshots.last['notice'], 'updated original');
    expect(f.imports.toSet(), hasLength(1));
    expect(
      f.state.androidExecutionForRecord(f.state.activeRecord!)!.interfaceKey,
      binding.interfaceKey,
    );
    expect(f.state.config!.sites.first.type, 3);
    expect(f.state.effectiveConfig!.sites.first.type, 4);
  });

  test(
    'delete forgets bindings and own resources but not Android copies',
    () async {
      await f.state.runConfigOnAndroid(f.recordId, f.profile.connectionKey);
      await f.state.deleteConfigRecord(f.recordId);
      expect(f.store.bindings, isEmpty);
      expect(f.state.savedConfigs, isEmpty);
      expect(f.copies, hasLength(1));
      expect(f.servers.last.reverseRows, isEmpty);
    },
  );
}

class _PublicPlayerFixture extends PcExecutionFixture {
  _PublicPlayerFixture(super.root);
  Future<void> Function()? beforePlay;
  String mediaUrl = 'http://93.184.216.34/manifest';
  late final http.Client _publicClient = _PublicPlayerClient(
    super.client,
    this,
  );
  @override
  http.Client get client => _publicClient;
}

class _PublicPlayerClient extends http.BaseClient {
  _PublicPlayerClient(this.inner, this.fixture);
  final http.Client inner;
  final _PublicPlayerFixture fixture;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path == '/vod/api' &&
        request.url.queryParameters.containsKey('play')) {
      await fixture.beforePlay?.call();
      return http.StreamedResponse(
        Stream.value(
          utf8.encode(jsonEncode({'parse': 0, 'url': fixture.mediaUrl})),
        ),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return inner.send(request);
  }

  @override
  void close() => inner.close();
}
