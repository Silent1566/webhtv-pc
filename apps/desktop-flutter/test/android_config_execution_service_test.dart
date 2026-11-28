import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/android_adb_profile.dart';
import 'package:webhtv_pc/core/android_bridge.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/android_adb_runtime.dart';
import 'package:webhtv_pc/services/android_bridge_service.dart';
import 'package:webhtv_pc/services/android_config_execution_service.dart';
import 'package:webhtv_pc/services/android_config_execution_store.dart';
import 'package:webhtv_pc/services/android_connection_store.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/pc_config_snapshot_server.dart';
import 'package:webhtv_pc/services/storage.dart';

/// 记录调用的真实运行时替身：只替换 ADB 边界，HTTP/快照/存储全部走真实实现。
class _FakeAdbRuntime extends AndroidAdbRuntime {
  _FakeAdbRuntime({
    required super.bridge,
    required super.log,
    required this.device,
  });

  final AndroidDevice device;
  final List<String> events = <String>[];
  final List<(String, int)> released = <(String, int)>[];
  final List<AndroidReverseLease> acquiredLeases = <AndroidReverseLease>[];
  final Map<int, ServerSocket> _proxies = <int, ServerSocket>{};
  final Map<int, int> _proxyTargets = <int, int>{};
  Completer<void>? connectGate;
  Object? connectFailure;
  Object? reverseFailure;
  Object? leaseReleaseFailure;
  bool Function()? publisherRunning;
  bool publisherRunningAtConnect = false;

  @override
  Future<AndroidDevice> connect(
    AndroidAdbProfile profile, {
    String? expectedUuid,
    bool launchAvd = false,
  }) async {
    events.add(
      'connect|${profile.connectionKey}|${expectedUuid ?? '-'}|$launchAvd',
    );
    publisherRunningAtConnect = publisherRunning?.call() ?? false;
    final gate = connectGate;
    if (gate != null) await gate.future;
    final failure = connectFailure;
    if (failure != null) throw failure;
    return device;
  }

  @override
  AndroidDevice? deviceForUuid(String uuid) =>
      uuid == device.uuid ? device : null;

  @override
  Future<AndroidReverseLease> acquireReverse(
    String uuid, {
    required int localPort,
    int guestPort = 0,
  }) async {
    events.add('reverse|$uuid|$localPort|$guestPort');
    final failure = reverseFailure;
    if (failure != null) throw failure;
    final created = !_proxyTargets.containsKey(guestPort);
    final port = await _forward(guestPort, localPort);
    final lease = _FakeReverseLease(this, uuid, port, created);
    acquiredLeases.add(lease);
    return lease;
  }

  Future<int> _forward(int guestPort, int localPort) async {
    if (_proxyTargets[guestPort] == localPort) return guestPort;
    if (_proxyTargets.containsKey(guestPort)) {
      throw StateError('reverse conflict');
    }
    final server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      guestPort,
    );
    final port = server.port;
    _proxies[port] = server;
    _proxyTargets[port] = localPort;
    server.listen((client) async {
      try {
        final upstream = await Socket.connect(
          InternetAddress.loopbackIPv4,
          localPort,
        );
        client.listen(
          upstream.add,
          onDone: upstream.destroy,
          onError: (_) => upstream.destroy(),
        );
        upstream.listen(
          client.add,
          onDone: client.destroy,
          onError: (_) => client.destroy(),
        );
      } catch (_) {
        client.destroy();
      }
    });
    return port;
  }

  Future<void> _releaseProxy(int guestPort) async {
    _proxyTargets.remove(guestPort);
    await _proxies.remove(guestPort)?.close();
  }

  @override
  Future<void> releaseReverse(String uuid, int guestPort) async {
    events.add('release|$uuid|$guestPort');
  }

  @override
  Future<void> disconnect(String uuid) async {
    events.add('disconnect|$uuid');
  }

  @override
  Future<void> close() async {
    events.add('runtime-close');
    for (final server in _proxies.values) {
      await server.close();
    }
    _proxies.clear();
    _proxyTargets.clear();
  }
}

class _FakeReverseLease implements AndroidReverseLease {
  _FakeReverseLease(this.runtime, this.uuid, this.guestPort, this.created);

  final _FakeAdbRuntime runtime;
  @override
  final String uuid;
  @override
  final int guestPort;
  @override
  final bool created;
  bool _released = false;

  @override
  Future<void> release() async {
    if (!created || _released) return;
    final failure = runtime.leaseReleaseFailure;
    if (failure != null) throw failure;
    _released = true;
    runtime.released.add((uuid, guestPort));
    runtime.events.add('lease-release|$uuid|$guestPort');
    await runtime._releaseProxy(guestPort);
  }
}

/// 真实的安卓 HTTP 端点：导入接口和 T4 网关。
class _Gateway {
  late HttpServer _server;
  final List<String> calls = <String>[];
  final List<String> importedUrls = <String>[];
  final List<String> snapshotBodies = <String>[];
  String interfaceKey = 'gateway-key';
  final Map<String, String> copies = {};
  final List<bool> receipts = [];
  int creations = 0;
  bool failFetch = false;
  bool failImportResponse = false;
  bool failAfterCatalogLoad = false;
  final Map<String, String> cachedCatalogNames = <String, String>{};
  void Function()? beforeImport;
  Completer<void>? importGate;
  List<String>? trace;
  bool created = true;
  bool active = false;
  List<String> siteKeys = <String>['alpha', 'beta'];
  String base = '';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${_server.port}';
    _server.listen(_handle);
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    calls.add('${request.method} ${request.uri}');
    if (request.method == 'POST' &&
        request.uri.path == '/manage/config/import') {
      final body = await utf8.decoder.bind(request).join();
      final fields = Uri.splitQueryString(body);
      final url = fields['url'] ?? '';
      trace?.add('import');
      await importGate?.future;
      beforeImport?.call();
      importedUrls.add(url);
      snapshotBodies.add(await _download(url));
      final isNew = !copies.containsKey(url);
      if (isNew) {
        creations++;
        copies[url] = creations == 1 ? interfaceKey : 'gateway-key-$creations';
      }
      cachedCatalogNames.remove(copies[url]);
      receipts.add(isNew);
      if (failImportResponse) {
        request.response.statusCode = 503;
        await request.response.close();
        return;
      }
      final payload = <String, Object?>{
        'code': 0,
        'data': <String, Object?>{
          'id': 1,
          'interfaceKey': copies[url],
          'url': url,
          'name': fields['name'] ?? '',
          'created': isNew,
          'active': active,
        },
      };
      await _json(request, payload);
      return;
    }
    if (request.method == 'GET' && request.uri.path == '/vod/api') {
      trace?.add('fetch');
      if (failFetch) {
        request.response.statusCode = 503;
        await request.response.close();
        return;
      }
      final key = request.uri.queryParameters['configKey'];
      final snapshotUrl = copies.entries
          .where((entry) => entry.value == key)
          .first
          .key;
      if (!cachedCatalogNames.containsKey(key)) {
        final body = jsonDecode(await _download(snapshotUrl)) as Map;
        cachedCatalogNames[key!] = body['name'] as String;
      }
      final catalogName = cachedCatalogNames[key];
      if (failAfterCatalogLoad) {
        request.response.statusCode = 503;
        await request.response.close();
        return;
      }
      final authority = request.requestedUri.authority;
      await _json(request, <String, Object?>{
        'name': catalogName,
        'sites': [
          for (final key in siteKeys)
            <String, Object?>{
              'key': key,
              'name': '站点 $key',
              'type': 4,
              'api': 'http://$authority/vod/api?key=$key',
            },
        ],
        'lives': <Object>[],
      });
      return;
    }
    request.response.statusCode = 404;
    await request.response.close();
  }

  Future<String> _download(String url) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return '';
      }
      return await utf8.decoder.bind(response).join();
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _json(HttpRequest request, Object? body) async {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }
}

class _Harness {
  _Harness._({
    required this.log,
    required this.bridge,
    required this.publisher,
    required this.store,
    required this.connections,
    required this.runtime,
    required this.gateway,
    required this.service,
    required this.temp,
    required this.record,
    required this.originalConfig,
    required this.profile,
  });

  static Future<_Harness> create() async {
    final root = Directory(
      p.join(
        Directory.current.path,
        '../../.superpowers/sdd/2026-11-24-pc-config-android-execution/orchestrator',
      ),
    );
    root.createSync(recursive: true);
    final temp = root.createTempSync('test-');
    final log = LogService();
    final gateway = _Gateway();
    await gateway.start();
    final bridge = AndroidBridgeService(log: log);
    final publisher = PcConfigSnapshotServer(log: log);
    final store = AndroidConfigExecutionStore(
      path: p.join(temp.path, 'android_execution.json'),
      log: log,
    );
    final device = AndroidDevice(
      uuid: 'uuid-1',
      name: '受控电视',
      reachableBase: gateway.base,
    );
    final runtime = _FakeAdbRuntime(bridge: bridge, log: log, device: device);
    final profile = AndroidAdbProfile(
      mode: AndroidAdbMode.avd,
      target: 'Pixel_Test',
    );
    final connections = AndroidConnectionStore(
      path: p.join(temp.path, 'connections.json'),
      log: log,
    );
    await connections.remember(profile, deviceUuid: 'uuid-1');
    final record = ConfigRecord(
      id: 25,
      name: 'PC 原配置',
      origin: 'https://pc.example/config.json',
      updatedAt: DateTime.utc(2026, 11, 24),
      siteCount: 2,
      liveCount: 0,
      sourceKey: 'local|https://pc.example/config.json',
      json: <String, Object?>{
        'name': 'PC 原配置',
        'spider': 'https://cdn.example/spider.jar;md5;abc123',
        'unknown': {
          'raw': [1, 'opaque', true],
        },
        'sites': <Object?>[
          <String, Object?>{
            'key': 'alpha',
            'name': '站点 alpha',
            'type': 3,
            'api': 'csp_Alpha',
            'ext': 'opaque-alpha',
            'futureField': {'raw': 'untouched'},
          },
          <String, Object?>{
            'key': 'beta',
            'name': '站点 beta',
            'type': 3,
            'api': 'csp_Beta',
            'ext': './rules/beta.json',
          },
        ],
      },
    );
    final originalConfig = parseConfigRecord(record.json);
    final service = AndroidConfigExecutionService(
      runtime: runtime,
      bridge: bridge,
      store: store,
      connections: connections,
      publisher: publisher,
      log: log,
    );
    return _Harness._(
      log: log,
      bridge: bridge,
      publisher: publisher,
      store: store,
      connections: connections,
      runtime: runtime,
      gateway: gateway,
      service: service,
      temp: temp,
      record: record,
      originalConfig: originalConfig,
      profile: profile,
    );
  }

  final LogService log;
  final AndroidBridgeService bridge;
  final PcConfigSnapshotServer publisher;
  final AndroidConfigExecutionStore store;
  final AndroidConnectionStore connections;
  final _FakeAdbRuntime runtime;
  final _Gateway gateway;
  final AndroidConfigExecutionService service;
  final Directory temp;
  final ConfigRecord record;
  final AppConfig originalConfig;
  final AndroidAdbProfile profile;

  ConfigRecord otherRecord() => ConfigRecord(
    id: 26,
    name: '第二份 PC 配置',
    origin: 'https://pc.example/two.json',
    updatedAt: DateTime.utc(2026, 11, 24),
    siteCount: 2,
    liveCount: 0,
    sourceKey: 'local|https://pc.example/two.json',
    json: record.json,
  );

  String joinedLogs() => log.entries.map((entry) => entry.message).join('\n');

  Future<void> dispose() async {
    try {
      await service.close();
    } catch (_) {}
    await runtime.close();
    bridge.close();
    await publisher.close();
    await gateway.close();
    log.dispose();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  }
}

void main() {
  test('concurrent runtimes isolate guest ports and preserve requested lease reuse', () async {
    final first = await _Harness.create();
    addTearDown(first.dispose);
    final second = await _Harness.create();
    addTearDown(second.dispose);
    final results = await Future.wait([
      for (final h in [first, second])
        h.service.prepare(
          sourceKey: h.record.sourceKey,
          record: h.record,
          originalConfig: h.originalConfig,
          profile: h.profile,
        ),
    ]);
    final firstPort = results[0].binding.guestPort;
    final secondPort = results[1].binding.guestPort;
    expect(firstPort, inInclusiveRange(1, 65535));
    expect(secondPort, inInclusiveRange(1, 65535));
    expect(firstPort, isNot(secondPort));
    expect(first.runtime._proxies[firstPort]?.port, firstPort);
    expect(second.runtime._proxies[secondPort]?.port, secondPort);

    final borrowed = await first.runtime.acquireReverse(
      'uuid-1',
      localPort: first.publisher.port,
      guestPort: firstPort,
    );
    expect(borrowed.created, isFalse);
    expect(borrowed.guestPort, firstPort);
    await borrowed.release();
    expect(first.runtime.released, isEmpty);
    expect(await _statusOf(first.gateway.importedUrls.single), HttpStatus.ok);
    await expectLater(
      first.runtime.acquireReverse(
        'uuid-1',
        localPort: second.publisher.port,
        guestPort: firstPort,
      ),
      throwsStateError,
    );

    await first.service.close();
    expect(first.runtime._proxies, isEmpty);
    expect(first.runtime.released, [('uuid-1', firstPort)]);
    expect(await _statusOf(second.gateway.importedUrls.single), HttpStatus.ok);
    final replacement = await first.runtime.acquireReverse(
      'uuid-1',
      localPort: second.publisher.port,
      guestPort: firstPort,
    );
    expect(replacement.created, isTrue);
    expect(replacement.guestPort, firstPort);
    expect(first.runtime._proxies[firstPort]?.port, firstPort);
    expect(
      await _statusOf(
        'http://127.0.0.1:$firstPort/${results[1].binding.snapshotToken}.json',
      ),
      HttpStatus.ok,
    );
    await replacement.release();
    await replacement.release();
    expect(first.runtime._proxies, isEmpty);
    expect(first.runtime.released, [
      ('uuid-1', firstPort),
      ('uuid-1', firstPort),
    ]);
    expect(await _statusOf(second.gateway.importedUrls.single), HttpStatus.ok);
  });

  test('prepare runs publisher, connect, reverse, import, fetch, overlay in order', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    final rawBefore = jsonEncode(h.record.json);
    h.runtime.publisherRunning = () => h.publisher.running;
    h.gateway.trace = h.runtime.events;
    h.gateway.beforeImport = () {
      final pending = h.store.bindings.single;
      expect(pending.isReady, isFalse);
      expect(pending.guestPort, h.runtime.acquiredLeases.single.guestPort);
      expect(h.store.enabledFor(h.record.sourceKey), isNull);
    };

    final result = await h.service.prepare(
      sourceKey: h.record.sourceKey,
      record: h.record,
      originalConfig: h.originalConfig,
      profile: h.profile,
    );

    expect(h.publisher.running, isTrue);
    expect(h.runtime.publisherRunningAtConnect, isTrue);
    expect(h.runtime.events, <String>[
      'connect|${h.profile.connectionKey}|-|false',
      'reverse|uuid-1|${h.publisher.port}|0',
      'import',
      'fetch',
    ]);
    expect(h.gateway.calls, <String>[
      'POST /manage/config/import',
      'GET /vod/api?ac=config&configKey=gateway-key',
    ]);
    expect(result.binding.isReady, isTrue);
    expect(result.binding.guestPort, inInclusiveRange(1, 65535));
    expect(result.binding.guestPort, h.runtime.acquiredLeases.single.guestPort);
    expect(result.binding.interfaceKey, 'gateway-key');
    expect(
      h.gateway.importedUrls.single,
      'http://127.0.0.1:${result.binding.guestPort}/${result.binding.snapshotToken}.json',
    );
    expect(h.gateway.snapshotBodies.single, contains('"alpha"'));
    expect(h.store.bindings.single.bindingKey, result.binding.bindingKey);
    expect(
      h.store.enabledFor(h.record.sourceKey)?.bindingKey,
      result.binding.bindingKey,
    );
    expect(result.overlay.sites.map((site) => site.key), <String>[
      'alpha',
      'beta',
    ]);
    expect(
      result.overlay.sites.every((site) => site.api.startsWith(h.gateway.base)),
      isTrue,
    );
    expect(result.overlay.sites.first.name, '站点 alpha');
    final body = jsonDecode(h.gateway.snapshotBodies.single) as Map;
    expect(body['spider'], 'https://cdn.example/spider.jar;md5;abc123');
    expect(body['unknown'], {
      'raw': [1, 'opaque', true],
    });
    expect((body['sites'] as List)[0], {
      'key': 'alpha',
      'name': '站点 alpha',
      'type': 3,
      'api': 'csp_Alpha',
      'ext': 'opaque-alpha',
      'futureField': {'raw': 'untouched'},
    });
    expect(
      (body['sites'] as List)[1]['ext'],
      'https://pc.example/rules/beta.json',
    );
    expect(h.originalConfig.sites.every((s) => s.type == 3), isTrue);
    expect(result.overlay.sites.every((s) => s.type == 4), isTrue);
    expect((h.record.json['sites'] as List)[1]['ext'], './rules/beta.json');
    expect(jsonEncode(h.record.json), rawBefore);
    expect(h.record.sourceKey, 'local|https://pc.example/config.json');
  });

  test('reconnect with a new local publisher port keeps token, guest port, URL and copy', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    final first = await h.service.prepare(
      sourceKey: h.record.sourceKey,
      record: h.record,
      originalConfig: h.originalConfig,
      profile: h.profile,
    );
    final firstPort = h.publisher.port;
    await h.service.close();

    // 模拟 PC 重启：存储从磁盘重新加载，发布器换一个新的本地端口。
    final store2 = AndroidConfigExecutionStore(
      path: p.join(h.temp.path, 'android_execution.json'),
      log: h.log,
    );
    await store2.load();
    expect(
      store2
          .forSourceProfile(h.record.sourceKey, h.profile.connectionKey)
          ?.snapshotToken,
      first.binding.snapshotToken,
    );
    final publisher2 = PcConfigSnapshotServer(log: h.log);
    final service2 = AndroidConfigExecutionService(
      runtime: h.runtime,
      bridge: h.bridge,
      store: store2,
      connections: h.connections,
      publisher: publisher2,
      log: h.log,
    );
    addTearDown(service2.close);
    addTearDown(publisher2.close);
    h.gateway.created = false;

    final second = await service2.prepare(
      sourceKey: h.record.sourceKey,
      record: h.record,
      originalConfig: h.originalConfig,
      profile: h.profile,
    );

    expect(publisher2.port, isNot(firstPort));
    expect(second.binding.snapshotToken, first.binding.snapshotToken);
    expect(second.binding.guestPort, first.binding.guestPort);
    expect(second.binding.interfaceKey, first.binding.interfaceKey);
    expect(second.binding.deviceUuid, first.binding.deviceUuid);
    expect(h.gateway.importedUrls.length, 2);
    expect(h.gateway.importedUrls[1], h.gateway.importedUrls[0]);
    expect(store2.bindings.length, 1);
    expect(
      h.runtime.events.last,
      'reverse|uuid-1|${publisher2.port}|${first.binding.guestPort}',
    );
    expect(
      h.runtime.events.last,
      isNot('reverse|uuid-1|$firstPort|${first.binding.guestPort}'),
    );
  });

  test(
    'refresh reuses token, URL and interface key without a second copy',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final first = await h.service.prepare(
        sourceKey: h.record.sourceKey,
        record: h.record,
        originalConfig: h.originalConfig,
        profile: h.profile,
      );
      h.gateway.created = false;
      final second = await h.service.refresh(
        first.binding,
        record: h.record,
        originalConfig: h.originalConfig,
      );

      expect(h.gateway.importedUrls.length, 2);
      expect(h.gateway.importedUrls[1], h.gateway.importedUrls[0]);
      expect(second.binding.snapshotToken, first.binding.snapshotToken);
      expect(second.binding.guestPort, first.binding.guestPort);
      expect(second.binding.interfaceKey, first.binding.interfaceKey);
      expect(h.store.bindings.length, 1);
      expect(h.store.bindings.single.interfaceKey, first.binding.interfaceKey);
      expect(
        h.runtime.events.where((event) => event.startsWith('reverse|')).length,
        2,
      );
    },
  );

  test('missing original site key rolls back reverse and snapshot and enables nothing', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    h.gateway.siteKeys = <String>['alpha'];

    await expectLater(
      h.service.prepare(
        sourceKey: h.record.sourceKey,
        record: h.record,
        originalConfig: h.originalConfig,
        profile: h.profile,
      ),
      throwsA(isA<FormatException>()),
    );

    expect(h.store.bindings.single.isReady, isFalse);
    expect(h.store.enabledFor(h.record.sourceKey), isNull);
    expect(h.runtime.released, isEmpty);
    final token = Uri.parse(h.gateway.importedUrls.single).pathSegments.last;
    expect(
      await _statusOf('http://127.0.0.1:${h.publisher.port}/$token'),
      HttpStatus.ok,
    );
  });

  test('empty interface key fails after the copy was created and keeps the reservation', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    h.gateway.interfaceKey = '';

    await expectLater(
      h.service.prepare(
        sourceKey: h.record.sourceKey,
        record: h.record,
        originalConfig: h.originalConfig,
        profile: h.profile,
      ),
      throwsA(anything),
    );
    // 设备已建副本：丢了收据也要留住预留，重试才复用同一个 URL。
    expect(h.gateway.creations, 1);
    expect(h.store.bindings.single.isReady, isFalse);
    expect(h.store.enabledFor(h.record.sourceKey), isNull);
    expect(h.runtime.released, isEmpty);
  });

  test('active import result fails and releases the reverse', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    h.gateway.active = true;

    await expectLater(
      h.service.prepare(
        sourceKey: h.record.sourceKey,
        record: h.record,
        originalConfig: h.originalConfig,
        profile: h.profile,
      ),
      throwsA(isA<AppError>()),
    );
    expect(h.store.bindings.single.isReady, isFalse);
    expect(h.store.enabledFor(h.record.sourceKey), isNull);
    expect(h.runtime.released, isEmpty);
  });

  test(
    'ensureReverse conflict propagates and nothing is imported or enabled',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      h.runtime.reverseFailure = AppError(
        AppErrorKind.storage,
        '设备端口已被别的本机端口占用',
      );

      await expectLater(
        h.service.prepare(
          sourceKey: h.record.sourceKey,
          record: h.record,
          originalConfig: h.originalConfig,
          profile: h.profile,
        ),
        throwsA(isA<AppError>()),
      );
      expect(h.gateway.calls, isEmpty);
      expect(h.store.bindings, isEmpty);
      expect(h.store.enabledFor(h.record.sourceKey), isNull);
      expect(h.runtime.released, isEmpty);
    },
  );

  test(
    'disable keeps binding, and re-enable reuses URL without a new copy',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final first = await h.service.prepare(
        sourceKey: h.record.sourceKey,
        record: h.record,
        originalConfig: h.originalConfig,
        profile: h.profile,
      );

      await h.service.disable(h.record.sourceKey);
      expect(h.store.enabledFor(h.record.sourceKey), isNull);
      expect(h.store.bindings.single.bindingKey, first.binding.bindingKey);

      h.gateway.created = false;
      final again = await h.service.prepare(
        sourceKey: h.record.sourceKey,
        record: h.record,
        originalConfig: h.originalConfig,
        profile: h.profile,
      );
      expect(again.binding.snapshotToken, first.binding.snapshotToken);
      expect(h.gateway.importedUrls.length, 2);
      expect(h.gateway.importedUrls[1], h.gateway.importedUrls[0]);
      expect(h.store.bindings.length, 1);
      expect(h.store.enabledFor(h.record.sourceKey), isNotNull);
    },
  );

  test(
    'forget releases the reverse only after the last binding for the profile',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final one = await h.service.prepare(
        sourceKey: h.record.sourceKey,
        record: h.record,
        originalConfig: h.originalConfig,
        profile: h.profile,
      );
      final other = h.otherRecord();
      final two = await h.service.prepare(
        sourceKey: other.sourceKey,
        record: other,
        originalConfig: parseConfigRecord(other.json),
        profile: h.profile,
      );
      expect(two.binding.guestPort, one.binding.guestPort);
      expect(h.store.bindings.length, 2);

      await h.service.forget(h.record.sourceKey, h.profile.connectionKey);
      expect(h.runtime.released, isEmpty);
      expect(h.store.bindings.length, 1);

      await h.service.forget(other.sourceKey, h.profile.connectionKey);
      expect(h.runtime.released, <(String, int)>[
        ('uuid-1', two.binding.guestPort),
      ]);
      expect(h.store.bindings, isEmpty);
    },
  );

  test(
    'concurrent prepare for the same source and profile coalesces',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final gate = Completer<void>();
      h.runtime.connectGate = gate;

      final first = h.service.prepare(
        sourceKey: h.record.sourceKey,
        record: h.record,
        originalConfig: h.originalConfig,
        profile: h.profile,
      );
      final second = h.service.prepare(
        sourceKey: h.record.sourceKey,
        record: h.record,
        originalConfig: h.originalConfig,
        profile: h.profile,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        h.runtime.events.where((event) => event.startsWith('connect|')).length,
        1,
      );
      gate.complete();
      final results = await Future.wait(<Future<AndroidConfigExecutionResult>>[
        first,
        second,
      ]);

      expect(identical(results[0], results[1]), isTrue);
      expect(h.gateway.importedUrls.length, 1);
      expect(h.store.bindings.length, 1);
    },
  );

  test('close releases owned reverses and closes the publisher without touching devices', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    final result = await h.service.prepare(
      sourceKey: h.record.sourceKey,
      record: h.record,
      originalConfig: h.originalConfig,
      profile: h.profile,
    );
    await h.service.close();

    expect(h.runtime.released, <(String, int)>[
      ('uuid-1', result.binding.guestPort),
    ]);
    expect(
      h.runtime.events.where((event) => event.startsWith('disconnect|')),
      isEmpty,
    );
    expect(h.publisher.running, isFalse);
  });

  test('failures never log the raw snapshot token or device URL', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    h.gateway.active = true;

    await expectLater(
      h.service.prepare(
        sourceKey: h.record.sourceKey,
        record: h.record,
        originalConfig: h.originalConfig,
        profile: h.profile,
      ),
      throwsA(isA<AppError>()),
    );
    final url = h.gateway.importedUrls.single;
    final token = Uri.parse(url).pathSegments.last.replaceAll('.json', '');
    final logs = h.joinedLogs();
    expect(logs, isNot(contains(token)));
    expect(logs, isNot(contains(url)));
    expect(
      logs,
      isNot(contains('${Uri.parse(url).port}/${token.substring(0, 8)}')),
    );
  });
  test('import succeeds then fetch fails: retry retains reservation and one Android copy', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    h.gateway.failFetch = true;
    await expectLater(
      h.service.prepare(
        sourceKey: h.record.sourceKey,
        record: h.record,
        originalConfig: h.originalConfig,
        profile: h.profile,
      ),
      throwsA(isA<AppError>()),
    );
    final pending = h.store.bindings.single;
    expect(pending.isReady, isFalse);
    expect(h.store.enabledFor(h.record.sourceKey), isNull);
    expect(h.gateway.creations, 1);
    h.gateway.failFetch = false;
    final result = await h.service.prepare(
      sourceKey: h.record.sourceKey,
      record: h.record,
      originalConfig: h.originalConfig,
      profile: h.profile,
    );
    expect(result.binding.snapshotToken, pending.snapshotToken);
    expect(result.binding.guestPort, pending.guestPort);
    expect(result.binding.interfaceKey, 'gateway-key');
    expect(h.gateway.importedUrls.toSet().length, 1);
    expect(h.gateway.receipts, [true, false]);
    expect(h.gateway.creations, 1);
  });

  test('lost import receipt after the device committed keeps one reservation and one URL', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    h.gateway.failImportResponse = true;
    await expectLater(
      h.service.prepare(
        sourceKey: h.record.sourceKey,
        record: h.record,
        originalConfig: h.originalConfig,
        profile: h.profile,
      ),
      throwsA(isA<AppError>()),
    );
    expect(h.gateway.creations, 1);
    final reserved = h.store.bindings.single;
    expect(reserved.isReady, isFalse);
    expect(h.store.enabledFor(h.record.sourceKey), isNull);
    expect(h.runtime.released, isEmpty);
    final url = h.gateway.importedUrls.single;
    expect(await _statusOf(url), HttpStatus.ok);

    h.gateway.failImportResponse = false;
    final result = await h.service.prepare(
      sourceKey: h.record.sourceKey,
      record: h.record,
      originalConfig: h.originalConfig,
      profile: h.profile,
    );
    expect(result.binding.snapshotToken, reserved.snapshotToken);
    expect(result.binding.guestPort, reserved.guestPort);
    expect(h.gateway.importedUrls.toSet(), <String>{url});
    expect(h.gateway.receipts, [true, false]);
    expect(h.gateway.creations, 1);
    expect(h.store.bindings.length, 1);
    expect(h.store.enabledFor(h.record.sourceKey), isNotNull);
  });

  test('pending store commit fails before Android row creation', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    final collision = Directory('${h.store.path}.tmp')..createSync();
    addTearDown(() {
      if (collision.existsSync()) collision.deleteSync();
    });
    await expectLater(
      h.service.prepare(
        sourceKey: h.record.sourceKey,
        record: h.record,
        originalConfig: h.originalConfig,
        profile: h.profile,
      ),
      throwsA(isA<AppError>()),
    );
    expect(h.gateway.creations, 0);
    expect(h.gateway.calls, isEmpty);
    expect(h.store.bindings, isEmpty);
    expect(
      h.runtime.acquiredLeases.single.guestPort,
      inInclusiveRange(1, 65535),
    );
    expect(h.runtime.released, [
      ('uuid-1', h.runtime.acquiredLeases.single.guestPort),
    ]);
  });

  test(
    'failed config B keeps successful config A reverse and publication',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final a = await h.service.prepare(
        sourceKey: h.record.sourceKey,
        record: h.record,
        originalConfig: h.originalConfig,
        profile: h.profile,
      );
      final before = await _bodyOf(h.gateway.importedUrls.single);
      h.gateway.failFetch = true;
      final b = h.otherRecord();
      await expectLater(
        h.service.prepare(
          sourceKey: b.sourceKey,
          record: b,
          originalConfig: parseConfigRecord(b.json),
          profile: h.profile,
        ),
        throwsA(isA<AppError>()),
      );
      expect(h.runtime.released, isEmpty);
      expect(await _bodyOf(h.gateway.importedUrls.first), before);
      expect(
        h.store.enabledFor(h.record.sourceKey)?.interfaceKey,
        a.binding.interfaceKey,
      );
      expect(h.store.enabledFor(b.sourceKey), isNull);
      expect(h.store.bindings.length, 2);
    },
  );

  test('changed payload failure after import fails closed instead of restoring the old body', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    final a = await h.service.prepare(
      sourceKey: h.record.sourceKey,
      record: h.record,
      originalConfig: h.originalConfig,
      profile: h.profile,
    );
    final url = h.gateway.importedUrls.single;
    h.gateway.failFetch = true;
    final changed = _changed(h.record);
    await expectLater(
      h.service.prepare(
        sourceKey: changed.sourceKey,
        record: changed,
        originalConfig: parseConfigRecord(changed.json),
        profile: h.profile,
      ),
      throwsA(isA<AppError>()),
    );
    // 设备侧可能已经拿到新正文：不恢复旧正文，也不声称旧选择仍然安全。
    expect(h.store.enabledFor(h.record.sourceKey), isNull);
    expect(h.store.bindings.single.interfaceKey, a.binding.interfaceKey);
    final after = jsonDecode(await _bodyOf(url)) as Map;
    expect(after['name'], 'Changed config');
    expect(h.runtime.released, isEmpty);
  });

  test('changed payload failure before import restores the old publication and selection', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    final a = await h.service.prepare(
      sourceKey: h.record.sourceKey,
      record: h.record,
      originalConfig: h.originalConfig,
      profile: h.profile,
    );
    final url = h.gateway.importedUrls.single;
    final before = await _bodyOf(url);
    h.runtime.reverseFailure = AppError(AppErrorKind.storage, '设备端口已被别的本机端口占用');
    final changed = _changed(h.record);
    await expectLater(
      h.service.prepare(
        sourceKey: changed.sourceKey,
        record: changed,
        originalConfig: parseConfigRecord(changed.json),
        profile: h.profile,
      ),
      throwsA(isA<AppError>()),
    );
    expect(
      h.store.enabledFor(h.record.sourceKey)?.bindingKey,
      a.binding.bindingKey,
    );
    expect(await _bodyOf(url), before);
    expect(h.gateway.importedUrls.length, 1);
    expect(h.runtime.released, isEmpty);
  });

  test(
    'refresh failure after import with a changed payload fails closed',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final a = await h.service.prepare(
        sourceKey: h.record.sourceKey,
        record: h.record,
        originalConfig: h.originalConfig,
        profile: h.profile,
      );
      final url = h.gateway.importedUrls.single;
      h.gateway.failFetch = true;
      final changed = _changed(h.record);
      await expectLater(
        h.service.refresh(
          a.binding,
          record: changed,
          originalConfig: parseConfigRecord(changed.json),
        ),
        throwsA(isA<AppError>()),
      );
      expect(h.store.enabledFor(h.record.sourceKey), isNull);
      final after = jsonDecode(await _bodyOf(url)) as Map;
      expect(after['name'], 'Changed config');
    },
  );

  for (final operation in <String>['prepare', 'refresh']) {
    test(
      '$operation clears selection when Android cached changed catalog before fetch receipt loss',
      () async {
        final h = await _Harness.create();
        addTearDown(h.dispose);
        final first = await h.service.prepare(
          sourceKey: h.record.sourceKey,
          record: h.record,
          originalConfig: h.originalConfig,
          profile: h.profile,
        );
        final url = h.gateway.importedUrls.single;
        final oldBody = jsonDecode(await _bodyOf(url)) as Map<String, dynamic>;
        final changed = _changed(h.record);
        h.gateway.failAfterCatalogLoad = true;
        await expectLater(
          operation == 'prepare'
              ? h.service.prepare(
                  sourceKey: changed.sourceKey,
                  record: changed,
                  originalConfig: parseConfigRecord(changed.json),
                  profile: h.profile,
                )
              : h.service.refresh(
                  first.binding,
                  record: changed,
                  originalConfig: parseConfigRecord(changed.json),
                ),
          throwsA(
            isA<AppError>().having(
              (error) => error.kind,
              'kind',
              AppErrorKind.bridgeUnreachable,
            ),
          ),
        );

        // Restoring the publisher alone cannot invalidate Android's loaded catalog.
        h.publisher.putSnapshot(first.binding.snapshotToken, oldBody);
        expect((jsonDecode(await _bodyOf(url)) as Map)['name'], 'PC 原配置');
        h.gateway.failAfterCatalogLoad = false;
        final catalogUrl = Uri.parse(h.gateway.base).replace(
          path: '/vod/api',
          queryParameters: <String, String>{
            'ac': 'config',
            'configKey': first.binding.interfaceKey,
          },
        );
        final catalog = jsonDecode(await _bodyOf(catalogUrl.toString())) as Map;
        expect(catalog['name'], 'Changed config');
        expect(h.gateway.importedUrls.toSet(), <String>{url});
        expect(h.gateway.creations, 1);
        expect(h.store.bindings.single.configHash, first.binding.configHash);
        expect(h.store.enabledFor(h.record.sourceKey), isNull);
        expect(h.joinedLogs(), isNot(contains(first.binding.snapshotToken)));
        expect(h.joinedLogs(), isNot(contains(url)));
      },
    );
  }

  test('same content failure preserves ready selection and copy key', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    final a = await h.service.prepare(
      sourceKey: h.record.sourceKey,
      record: h.record,
      originalConfig: h.originalConfig,
      profile: h.profile,
    );
    h.gateway.failAfterCatalogLoad = true;
    await expectLater(
      h.service.prepare(
        sourceKey: h.record.sourceKey,
        record: h.record,
        originalConfig: h.originalConfig,
        profile: h.profile,
      ),
      throwsA(isA<AppError>()),
    );
    expect(
      h.store.enabledFor(h.record.sourceKey)?.interfaceKey,
      a.binding.interfaceKey,
    );
    expect(h.store.bindings.single.isReady, isTrue);
    expect(h.runtime.released, isEmpty);
  });

  test(
    'conflicting concurrent payload fails rather than returning stale overlay',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      h.runtime.connectGate = Completer<void>();
      final first = h.service.prepare(
        sourceKey: h.record.sourceKey,
        record: h.record,
        originalConfig: h.originalConfig,
        profile: h.profile,
      );
      final changed = _changed(h.record);
      await expectLater(
        h.service.prepare(
          sourceKey: changed.sourceKey,
          record: changed,
          originalConfig: parseConfigRecord(changed.json),
          profile: h.profile,
        ),
        throwsA(isA<AppError>()),
      );
      h.runtime.connectGate!.complete();
      final result = await first;
      expect(result.overlay.name, 'PC 原配置');
      expect(h.gateway.importedUrls.length, 1);
    },
  );

  test('full restart reloads profile and binding; refresh resolves original relative ext', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    final a = await h.service.prepare(
      sourceKey: h.record.sourceKey,
      record: h.record,
      originalConfig: h.originalConfig,
      profile: h.profile,
    );
    await h.service.close();
    await h.runtime.close();
    final store = AndroidConfigExecutionStore(path: h.store.path, log: h.log);
    await store.load();
    final connections = AndroidConnectionStore(
      path: h.connections.path,
      log: h.log,
    );
    await connections.load();
    final publisher = PcConfigSnapshotServer(log: h.log);
    final runtime = _FakeAdbRuntime(
      bridge: h.bridge,
      log: h.log,
      device: h.runtime.device,
    );
    final service = AndroidConfigExecutionService(
      runtime: runtime,
      bridge: h.bridge,
      store: store,
      connections: connections,
      publisher: publisher,
      log: h.log,
    );
    addTearDown(() async {
      await service.close();
      await runtime.close();
      await publisher.close();
    });
    final changed = _changed(h.record);
    final result = await service.refresh(
      a.binding,
      record: changed,
      originalConfig: parseConfigRecord(changed.json),
    );
    expect(runtime.events.first, contains('|uuid-1|false'));
    expect(result.binding.snapshotToken, a.binding.snapshotToken);
    expect(result.binding.guestPort, a.binding.guestPort);
    expect(result.binding.interfaceKey, a.binding.interfaceKey);
    expect(h.gateway.importedUrls.toSet().length, 1);
    expect(h.gateway.receipts, [true, false]);
    final body = jsonDecode(h.gateway.snapshotBodies.last) as Map;
    expect(
      (body['sites'] as List)[1]['ext'],
      'https://pc.example/rules/beta.json',
    );
    expect((body['sites'] as List)[0]['api'], 'csp_Alpha');
    expect(body['unknown'], {
      'raw': [1, 'opaque', true],
    });
    expect(result.overlay.name, 'Changed config');
  });

  test(
    'changed payload after restart without cached body fails closed',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      await h.service.prepare(
        sourceKey: h.record.sourceKey,
        record: h.record,
        originalConfig: h.originalConfig,
        profile: h.profile,
      );
      await h.service.close();
      await h.runtime.close();
      final store = AndroidConfigExecutionStore(path: h.store.path, log: h.log);
      await store.load();
      final connections = AndroidConnectionStore(
        path: h.connections.path,
        log: h.log,
      );
      await connections.load();
      final publisher = PcConfigSnapshotServer(log: h.log);
      final runtime = _FakeAdbRuntime(
        bridge: h.bridge,
        log: h.log,
        device: h.runtime.device,
      );
      final service = AndroidConfigExecutionService(
        runtime: runtime,
        bridge: h.bridge,
        store: store,
        connections: connections,
        publisher: publisher,
        log: h.log,
      );
      addTearDown(() async {
        await service.close();
        await runtime.close();
        await publisher.close();
      });
      h.gateway.failFetch = true;
      final changed = _changed(h.record);
      await expectLater(
        service.prepare(
          sourceKey: changed.sourceKey,
          record: changed,
          originalConfig: parseConfigRecord(changed.json),
          profile: h.profile,
        ),
        throwsA(isA<AppError>()),
      );
      expect(store.enabledFor(h.record.sourceKey), isNull);
      expect(store.bindings.single.isReady, isTrue);
    },
  );

  test('forgotten profile and mismatched identity fail before publication or import', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    final a = await h.service.prepare(
      sourceKey: h.record.sourceKey,
      record: h.record,
      originalConfig: h.originalConfig,
      profile: h.profile,
    );
    final before = h.gateway.calls.length;
    await h.connections.forget(h.profile.connectionKey);
    expect(
      () => h.service.refresh(
        a.binding,
        record: h.record,
        originalConfig: h.originalConfig,
      ),
      throwsA(isA<AppError>()),
    );
    expect(
      () => h.service.prepare(
        sourceKey: 'wrong-source',
        record: h.record,
        originalConfig: h.originalConfig,
        profile: h.profile,
      ),
      throwsA(isA<AppError>()),
    );
    expect(h.gateway.calls.length, before);
    expect(h.gateway.creations, 1);
  });

  test(
    'close waits for in-flight operation then releases late acquired resources',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      h.runtime.connectGate = Completer<void>();
      final preparing = h.service.prepare(
        sourceKey: h.record.sourceKey,
        record: h.record,
        originalConfig: h.originalConfig,
        profile: h.profile,
      );
      var finished = false;
      final closing = h.service.close().then((_) {
        finished = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      h.runtime.connectGate!.complete();
      final result = await preparing;
      await closing;
      expect(h.publisher.running, isFalse);
      expect(h.runtime.released, [('uuid-1', result.binding.guestPort)]);
      await h.service.close();
      expect(h.runtime.released.length, 1);
    },
  );

  test('refresh while disabled never enables the binding', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    final a = await h.service.prepare(
      sourceKey: h.record.sourceKey,
      record: h.record,
      originalConfig: h.originalConfig,
      profile: h.profile,
    );
    await h.service.disable(h.record.sourceKey);
    await h.service.refresh(
      a.binding,
      record: h.record,
      originalConfig: h.originalConfig,
    );
    expect(h.store.enabledFor(h.record.sourceKey), isNull);
    expect(h.gateway.creations, 1);
  });

  test(
    'bridge source and local loopback executable references reject before I/O',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final bad = ConfigRecord(
        id: 99,
        name: 'bad',
        origin: h.record.origin,
        updatedAt: h.record.updatedAt,
        siteCount: 1,
        liveCount: 0,
        sourceKey: 'bridge|device|copy',
        json: h.record.json,
      );
      expect(
        () => h.service.prepare(
          sourceKey: bad.sourceKey,
          record: bad,
          originalConfig: h.originalConfig,
          profile: h.profile,
        ),
        throwsA(isA<AppError>()),
      );
      final local = _changed(
        h.record,
        json: {...h.record.json, 'spider': 'http://127.0.0.1:9980/spider.jar'},
      );
      expect(
        () => h.service.prepare(
          sourceKey: local.sourceKey,
          record: local,
          originalConfig: parseConfigRecord(local.json),
          profile: h.profile,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(h.publisher.running, isFalse);
      expect(h.runtime.events, isEmpty);
    },
  );

  test(
    'disable during a pending prepare leaves the source not enabled',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final gate = Completer<void>();
      h.runtime.connectGate = gate;
      final preparing = h.service.prepare(
        sourceKey: h.record.sourceKey,
        record: h.record,
        originalConfig: h.originalConfig,
        profile: h.profile,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        h.runtime.events.where((event) => event.startsWith('connect|')).length,
        1,
      );
      await h.service.disable(h.record.sourceKey);
      gate.complete();
      final result = await preparing;

      expect(result.binding.isReady, isTrue);
      expect(h.store.enabledFor(h.record.sourceKey), isNull);
      expect(h.store.bindings.single.isReady, isTrue);
      expect(h.runtime.released, <(String, int)>[
        ('uuid-1', result.binding.guestPort),
      ]);
      expect(h.joinedLogs(), contains('已准备但未启用'));
      expect(h.joinedLogs(), isNot(contains('Android 执行已启用')));
    },
  );

  test(
    'forget during a pending prepare does not enable the forgotten source',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final gate = Completer<void>();
      h.runtime.connectGate = gate;
      final preparing = h.service.prepare(
        sourceKey: h.record.sourceKey,
        record: h.record,
        originalConfig: h.originalConfig,
        profile: h.profile,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await h.service.forget(h.record.sourceKey, h.profile.connectionKey);
      gate.complete();
      final result = await preparing;

      expect(result.binding.isReady, isTrue);
      expect(h.store.enabledFor(h.record.sourceKey), isNull);
      expect(h.store.bindings, isEmpty);
      expect(h.joinedLogs(), contains('已准备但未启用'));
      expect(h.joinedLogs(), isNot(contains('Android 执行已启用')));
    },
  );

  for (final outcome in <String>[
    'completed',
    'prepare-failed',
    'refresh-failed',
  ]) {
    test(
      'late $outcome on profile A preserves newer profile B selection',
      () async {
        final h = await _Harness.create();
        addTearDown(h.dispose);
        AndroidConfigExecutionResult? original;
        if (outcome == 'refresh-failed') {
          original = await h.service.prepare(
            sourceKey: h.record.sourceKey,
            record: h.record,
            originalConfig: h.originalConfig,
            profile: h.profile,
          );
        }
        final gate = Completer<void>();
        h.runtime.connectGate = gate;
        final changed = _changed(h.record);
        final late = outcome == 'refresh-failed'
            ? h.service.refresh(
                original!.binding,
                record: changed,
                originalConfig: parseConfigRecord(changed.json),
              )
            : h.service.prepare(
                sourceKey: h.record.sourceKey,
                record: changed,
                originalConfig: parseConfigRecord(changed.json),
                profile: h.profile,
              );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        h.runtime.connectGate = null;
        final newerProfile = AndroidAdbProfile(
          mode: AndroidAdbMode.avd,
          target: 'Pixel_Newer',
        );
        final newer = await h.service.prepare(
          sourceKey: h.record.sourceKey,
          record: h.record,
          originalConfig: h.originalConfig,
          profile: newerProfile,
        );
        expect(
          h.store.enabledFor(h.record.sourceKey)?.bindingKey,
          newer.binding.bindingKey,
        );
        if (outcome != 'completed') {
          h.gateway.failFetch = true;
          final failure = expectLater(late, throwsA(isA<AppError>()));
          gate.complete();
          await failure;
        } else {
          gate.complete();
          await late;
        }

        expect(
          h.store.enabledFor(h.record.sourceKey)?.bindingKey,
          newer.binding.bindingKey,
        );
        final newerUrl = h.publisher.deviceUri(
          newer.binding.snapshotToken,
          newer.binding.guestPort,
        );
        expect(await _statusOf(newerUrl.toString()), HttpStatus.ok);
        expect(
          h.runtime.released,
          isNot(contains(('uuid-1', newer.binding.guestPort))),
        );
        expect(h.joinedLogs(), isNot(contains(newer.binding.snapshotToken)));
      },
    );
  }

  test(
    'forget before a lost import receipt removes the flight-owned pending row',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final gate = Completer<void>();
      h.runtime.connectGate = gate;
      h.gateway.failImportResponse = true;
      final preparing = h.service.prepare(
        sourceKey: h.record.sourceKey,
        record: h.record,
        originalConfig: h.originalConfig,
        profile: h.profile,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await h.service.forget(h.record.sourceKey, h.profile.connectionKey);
      final failure = expectLater(preparing, throwsA(isA<AppError>()));
      gate.complete();
      await failure;
      expect(h.store.bindings, isEmpty);
      expect(h.store.enabledFor(h.record.sourceKey), isNull);
    },
  );

  test('close during a pending prepare leaves no enabled binding and no activation claim', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    final gate = Completer<void>();
    h.runtime.connectGate = gate;
    final preparing = h.service.prepare(
      sourceKey: h.record.sourceKey,
      record: h.record,
      originalConfig: h.originalConfig,
      profile: h.profile,
    );
    var closed = false;
    final closing = h.service.close().then((_) {
      closed = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(closed, isFalse);
    gate.complete();
    final result = await preparing;
    await closing;

    expect(result.binding.isReady, isTrue);
    expect(h.store.enabledFor(h.record.sourceKey), isNull);
    expect(h.publisher.running, isFalse);
    final logs = h.joinedLogs();
    expect(logs, contains('已准备但未启用'));
    expect(logs, isNot(contains('Android 执行已启用')));
    expect(logs.split('Android 执行服务已关闭').length - 1, 1);
  });

  test('disable during a pending refresh keeps the transport and settles not enabled', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    final first = await h.service.prepare(
      sourceKey: h.record.sourceKey,
      record: h.record,
      originalConfig: h.originalConfig,
      profile: h.profile,
    );
    final gate = Completer<void>();
    h.gateway.importGate = gate;
    final refreshing = h.service.refresh(
      first.binding,
      record: h.record,
      originalConfig: h.originalConfig,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await h.service.disable(h.record.sourceKey);

    // 在途刷新还用着这条 reverse：停用不能把它从脚下抽走。
    expect(h.runtime.released, isEmpty);
    gate.complete();
    final result = await refreshing;
    expect(result.binding.isReady, isTrue);
    expect(h.store.enabledFor(h.record.sourceKey), isNull);
    expect(h.runtime.released, <(String, int)>[
      ('uuid-1', first.binding.guestPort),
    ]);
    // 迟到的刷新不得宣称已启用（准备阶段的那条「已启用」是用户改主意之前的）。
    expect(h.joinedLogs(), isNot(contains('enabled=true')));
  });

  test('disable as the only user releases the lease and removes the publication', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    final first = await h.service.prepare(
      sourceKey: h.record.sourceKey,
      record: h.record,
      originalConfig: h.originalConfig,
      profile: h.profile,
    );
    expect(await _statusOf(h.gateway.importedUrls.single), HttpStatus.ok);

    await h.service.disable(h.record.sourceKey);

    expect(h.store.enabledFor(h.record.sourceKey), isNull);
    expect(h.store.bindings.single.bindingKey, first.binding.bindingKey);
    expect(h.runtime.released, <(String, int)>[
      ('uuid-1', first.binding.guestPort),
    ]);
    expect(
      await _statusOf(
        'http://127.0.0.1:${h.publisher.port}/${first.binding.snapshotToken}.json',
      ),
      HttpStatus.notFound,
    );
  });

  test('disable while another source shares the profile keeps the lease and that source', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    final one = await h.service.prepare(
      sourceKey: h.record.sourceKey,
      record: h.record,
      originalConfig: h.originalConfig,
      profile: h.profile,
    );
    final other = h.otherRecord();
    final two = await h.service.prepare(
      sourceKey: other.sourceKey,
      record: other,
      originalConfig: parseConfigRecord(other.json),
      profile: h.profile,
    );
    expect(two.binding.guestPort, one.binding.guestPort);

    await h.service.disable(h.record.sourceKey);

    expect(h.runtime.released, isEmpty);
    expect(h.store.enabledFor(h.record.sourceKey), isNull);
    expect(
      h.store.enabledFor(other.sourceKey)?.bindingKey,
      two.binding.bindingKey,
    );
    expect(
      await _statusOf(
        'http://127.0.0.1:${h.publisher.port}/${two.binding.snapshotToken}.json',
      ),
      HttpStatus.ok,
    );
    expect(
      await _statusOf(
        'http://127.0.0.1:${h.publisher.port}/${one.binding.snapshotToken}.json',
      ),
      HttpStatus.notFound,
    );
  });

  test('re-enable after disable resurrects the same URL, token and guest port via refresh', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    final first = await h.service.prepare(
      sourceKey: h.record.sourceKey,
      record: h.record,
      originalConfig: h.originalConfig,
      profile: h.profile,
    );
    final url = h.gateway.importedUrls.single;
    await h.service.disable(h.record.sourceKey);
    final retained = h.store.forSourceProfile(
      h.record.sourceKey,
      h.profile.connectionKey,
    )!;

    final again = await h.service.refresh(
      retained,
      record: h.record,
      originalConfig: h.originalConfig,
    );

    expect(again.binding.snapshotToken, first.binding.snapshotToken);
    expect(again.binding.guestPort, first.binding.guestPort);
    expect(h.gateway.importedUrls.toSet(), <String>{url});
    expect(h.gateway.receipts, [true, false]);
    expect(h.gateway.creations, 1);
    expect(await _statusOf(url), HttpStatus.ok);
  });

  test(
    'close surfaces an unconfirmed reverse release instead of claiming success',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      await h.service.prepare(
        sourceKey: h.record.sourceKey,
        record: h.record,
        originalConfig: h.originalConfig,
        profile: h.profile,
      );
      h.runtime.leaseReleaseFailure = const SocketException(
        'reverse close failed',
      );

      await expectLater(
        h.service.close(),
        throwsA(
          isA<AppError>()
              .having(
                (error) => error.kind,
                'kind',
                AppErrorKind.bridgeUnreachable,
              )
              .having((error) => error.message, 'message', contains('手动')),
        ),
      );

      expect(h.publisher.running, isFalse);
      final logs = h.joinedLogs();
      expect(logs, contains('释放 reverse 失败'));
      expect(logs, isNot(contains('Android 执行服务已关闭（用户设备与 Android 副本未改动）')));
    },
  );
}

Future<int> _statusOf(String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

ConfigRecord _changed(ConfigRecord record, {Map<String, Object?>? json}) =>
    ConfigRecord(
      id: record.id,
      name: 'Changed config',
      origin: record.origin,
      updatedAt: record.updatedAt,
      siteCount: record.siteCount,
      liveCount: record.liveCount,
      sourceKey: record.sourceKey,
      contentType: record.contentType,
      json: json ?? {...record.json, 'name': 'Changed config'},
    );

Future<String> _bodyOf(String url) async {
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(Uri.parse(url))).close();
    return await utf8.decoder.bind(response).join();
  } finally {
    client.close(force: true);
  }
}
