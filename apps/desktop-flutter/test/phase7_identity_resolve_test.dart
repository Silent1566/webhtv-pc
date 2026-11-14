/// Phase 7 · 身份解析与能力声明端点（`docs/phase7/design/01` §3.2.1、
/// `design/04` 6b/6c）。
///
/// 用**真实 HTTP**（起真 `SyncServer`，用真 `HttpClient` 当安卓），
/// 因此本文件**不得出现 `testWidgets`**——否则真实请求会被 mock 拦截。
///
/// 为什么这个套件必须存在：安卓拿不到 `identity/resolve` 的 200 响应时，
/// 会把 `identityResolutionState` **永久**写成 `unsupported`
/// （`PlaybackIdentityResolver.java:65-67`）。失败态是无声的——同步照样跑，
/// 只是跨设备身份匹配永久失效。所以四态 + 幂等都要有断言。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/android_sync.dart';
import 'package:webhtv_pc/core/playback_identity.dart';
import 'package:webhtv_pc/core/realtime_sync.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/sync_server.dart';

/// 起一个真实 SyncServer，返回已启动的实例。
Future<SyncServer> startServer({
  PlaybackIdentityStore? identityStore,
  bool enabled = true,
  bool peerAuthorized = true,
  bool pullEnabled = true,
  String? pullToken,
  SyncPlaybackCounts counts = (items: 0, tombstones: 0, nextSince: 0),
}) async {
  final server = SyncServer(
    log: LogService(),
    host: SyncServerHost(
      deviceUuid: 'pc-uuid-test',
      deviceName: 'WebHTV PC',
      isEnabled: () => enabled,
      isPeerAuthorized: (_) => peerAuthorized,
      onHistory: (_, {String sourceKey = ''}) async =>
          const SyncMergeStats.empty(),
      onKeep: (_) async => const SyncMergeStats.empty(),
      onBackup: (_, _) async => const SyncSettings.empty(),
      realtimePull: pullEnabled
          ? ({required int since, required int limit}) => const SyncPullBatch(
              items: [],
              deletions: [],
              nextSince: 0,
              hasMore: false,
            )
          : null,
      pullToken: pullToken,
      playbackIdentity: identityStore ?? PlaybackIdentityStore(),
      playbackCounts: () => counts,
    ),
    startPort: 0,
    endPort: 0,
    bindAddress: '127.0.0.1',
  );
  await server.start();
  return server;
}

/// 发请求，返回 (状态码, 解析后的 JSON, content-type)。
Future<({int status, Map<String, Object?> json, String? contentType})> send(
  int port,
  String path, {
  String method = 'POST',
  Object? body,
  Map<String, String> headers = const {},
}) async {
  final client = HttpClient();
  try {
    final uri = Uri.parse('http://127.0.0.1:$port$path');
    final request = method == 'GET'
        ? await client.getUrl(uri)
        : await client.postUrl(uri);
    headers.forEach(request.headers.set);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      decoded = null;
    }
    return (
      status: response.statusCode,
      json: decoded is Map
          ? decoded.map((key, value) => MapEntry('$key', value))
          : <String, Object?>{'raw': text},
      contentType: response.headers.contentType?.mimeType,
    );
  } finally {
    client.close();
  }
}

/// 一次安卓风格的解析请求体（`PlaybackIdentityResolver.request()` 同形态）。
Map<String, Object?> resolveBody({
  String interfaceKey = 'local-provisional-uuid',
  String configType = 'vod',
  List<String> strict = const [],
  List<String> endpoint = const [],
  List<String> host = const [],
  List<String> legacy = const [],
  String sourceDataState = 'empty',
  bool? confirm,
  String schema = playbackIdentitySchema,
  String operation = 'resolve',
}) => {
  'schema': schema,
  'operation': operation,
  'configType': configType,
  'interfaceKey': interfaceKey,
  'strictAddressKeys': strict,
  'endpointMatchKeys': endpoint,
  'hostMatchKeys': host,
  'legacyConfigKeys': legacy,
  'sourceDataState': sourceDataState,
  'confirm': ?confirm,
  'client': 'android',
  'appVersion': '5.6.0',
};

void main() {
  group('6b · 身份解析四态（真实 HTTP）', () {
    late SyncServer server;
    late PlaybackIdentityStore store;

    setUp(() async {
      store = PlaybackIdentityStore();
      server = await startServer(identityStore: store);
    });

    tearDown(() async => server.stop());

    test('首次提交 → create，canonical 就是提交的身份键', () async {
      final response = await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(strict: ['a' * 64]),
      );
      expect(response.status, 200);
      expect(response.contentType, 'application/json');
      expect(response.json['action'], 'create');
      expect(
        response.json['canonicalInterfaceKey'],
        'local-provisional-uuid',
      );
      expect(response.json['ok'], isTrue);
    });

    test('同一身份键再次提交 → keep（幂等）', () async {
      await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(strict: ['a' * 64]),
      );
      final second = await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(strict: ['a' * 64]),
      );
      expect(second.json['action'], 'keep');
      expect(second.json['matchedBy'], 'interfaceKey');
      expect(second.json['canonicalInterfaceKey'], 'local-provisional-uuid');
    });

    test('另一台设备命中同一 strict 键且本地无数据 → adopt', () async {
      await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(interfaceKey: 'device-a', strict: ['s' * 64]),
      );
      final second = await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(interfaceKey: 'device-b', strict: ['s' * 64]),
      );
      expect(second.json['action'], 'adopt');
      expect(second.json['canonicalInterfaceKey'], 'device-a');
      expect(second.json['matchedBy'], 'strictAddressKey');
      // 安卓会拿 matchedKeys 去 addAddressMatchAliases —— 必须是真值，
      // 不能像 Go 参考实现那样被基线值覆盖成空数组。
      expect(second.json['matchedKeys'], ['s' * 64]);
    });

    test('本地已有数据时命中 → confirm_required（不静默换身份）', () async {
      await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(interfaceKey: 'device-a', strict: ['s' * 64]),
      );
      final second = await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(
          interfaceKey: 'device-b',
          strict: ['s' * 64],
          sourceDataState: 'has_data',
        ),
      );
      expect(second.status, 200);
      expect(second.json['action'], 'confirm_required');
      expect(second.json['canonicalInterfaceKey'], 'device-a');
      expect(second.json['candidates'], ['device-a']);
      // confirm_required 不改状态：device-b 仍未被绑定。
      expect(store.registryFor('vod').boundCanonical('device-b'), isNull);
    });

    test('confirm=true 时同一线索 → merge', () async {
      await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(interfaceKey: 'device-a', strict: ['s' * 64]),
      );
      final second = await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(
          interfaceKey: 'device-b',
          strict: ['s' * 64],
          sourceDataState: 'has_data',
          confirm: true,
        ),
      );
      expect(second.json['action'], 'merge');
      expect(second.json['canonicalInterfaceKey'], 'device-a');
      expect(store.registryFor('vod').boundCanonical('device-b'), 'device-a');
    });

    test('身份键已绑定却指向另一个身份 → conflict 409', () async {
      await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(interfaceKey: 'device-a', strict: ['s' * 64]),
      );
      await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(interfaceKey: 'device-b', strict: ['t' * 64]),
      );
      // device-a 现在给出只属于 device-b 的线索。
      final conflict = await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(interfaceKey: 'device-a', strict: ['t' * 64]),
      );
      expect(conflict.status, 409);
      expect(conflict.json['action'], 'conflict');
      expect(conflict.json['ok'], isFalse);
      expect(conflict.json['candidates'], ['device-b']);
    });

    test('同一批线索命中多个身份 → conflict（合并会搅混历史）', () async {
      await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(interfaceKey: 'device-a', strict: ['s1' * 32]),
      );
      await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(interfaceKey: 'device-b', strict: ['s2' * 32]),
      );
      final conflict = await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(
          interfaceKey: 'device-c',
          strict: ['s1' * 32, 's2' * 32],
        ),
      );
      expect(conflict.status, 409);
      expect(conflict.json['candidates'], ['device-a', 'device-b']);
    });

    test('只有 host 弱匹配 → confirm_required（不替用户决定）', () async {
      await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(interfaceKey: 'device-a', host: ['h' * 64]),
      );
      final second = await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(interfaceKey: 'device-b', host: ['h' * 64]),
      );
      expect(second.json['action'], 'confirm_required');
      expect(second.json['matchedBy'], 'hostMatchKey');
    });

    test('endpoint 层线索在 strict 缺失时生效', () async {
      await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(interfaceKey: 'device-a', endpoint: ['e' * 64]),
      );
      final second = await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(interfaceKey: 'device-b', endpoint: ['e' * 64]),
      );
      expect(second.json['action'], 'adopt');
      expect(second.json['matchedBy'], 'endpointMatchKey');
    });

    test('legacy URL 哈希线索在 strict/endpoint 缺失时生效', () async {
      await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(interfaceKey: 'device-a', legacy: ['l' * 64]),
      );
      final second = await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(interfaceKey: 'device-b', legacy: ['l' * 64]),
      );
      expect(second.json['matchedBy'], 'legacyConfigKey');
    });

    test('同一把键从不同层提交也能命中（别名跨 kind 生效）', () async {
      // 为何要有别名表：同一地址在不同客户端版本里可能被判成不同层
      // （旧版只算 legacy URL 哈希，新版算 strict）。只按「同层匹配」
      // 会让升级后的设备认不出旧身份，于是新造一个 → 历史分家。
      await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(interfaceKey: 'device-a', legacy: ['x' * 64]),
      );
      final second = await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(interfaceKey: 'device-b', strict: ['x' * 64]),
      );
      expect(second.json['action'], 'adopt');
      expect(second.json['canonicalInterfaceKey'], 'device-a');
    });

    test('configType 隔离：live 的键不会命中 vod 身份', () async {
      await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(interfaceKey: 'device-a', strict: ['s' * 64]),
      );
      final live = await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(
          interfaceKey: 'device-b',
          configType: 'live',
          strict: ['s' * 64],
        ),
      );
      expect(live.json['action'], 'create');
    });

    test('identityEpoch 随成功变更递增（客户端据此判断换了身份）', () async {
      final first = await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(interfaceKey: 'device-a', strict: ['s' * 64]),
      );
      final second = await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(interfaceKey: 'device-a', strict: ['s' * 64]),
      );
      expect(int.parse('${first.json['identityEpoch']}'), 1);
      expect(int.parse('${second.json['identityEpoch']}'), 2);
    });

    test('别名路由 /playback/identity/resolve 同样可用', () async {
      final response = await send(
        server.port,
        '/playback/identity/resolve',
        body: resolveBody(),
      );
      expect(response.status, 200);
    });

    test('GET → 405（安卓只发 POST）', () async {
      final response = await send(
        server.port,
        '/api/playback/identity/resolve',
        method: 'GET',
      );
      expect(response.status, 405);
    });
  });

  group('6b · 非法请求', () {
    late SyncServer server;

    setUp(() async => server = await startServer());
    tearDown(() async => server.stop());

    test('体不是 JSON 对象 → 400 action=invalid', () async {
      final response = await send(
        server.port,
        '/api/playback/identity/resolve',
        body: const ['not', 'a', 'map'],
      );
      expect(response.status, 400);
      expect(response.json['action'], 'invalid');
      expect(response.json['ok'], isFalse);
    });

    test('非法身份键（空格/斜杠/超长）→ 400', () async {
      for (final key in ['Has Space', 'k' * 200, 'x/y']) {
        final response = await send(
          server.port,
          '/api/playback/identity/resolve',
          body: resolveBody(interfaceKey: key),
        );
        expect(response.status, 400, reason: 'interfaceKey=$key 应被拒绝');
        expect(response.json['action'], 'invalid');
      }
    });

    test('大写身份键被规范化而不是拒绝（与 Go 同口径）', () async {
      final response = await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(interfaceKey: 'ABCDEF-UUID'),
      );
      expect(response.status, 200);
      expect(response.json['canonicalInterfaceKey'], 'abcdef-uuid');
    });

    test('非法地址键 → 400（不静默丢弃）', () async {
      final response = await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(strict: ['ok-key', 'BAD KEY']),
      );
      expect(response.status, 400);
      expect(response.json['error'], contains('invalid'));
    });

    test('键数组超过 32 项 → 400', () async {
      final response = await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(
          strict: [for (var i = 0; i < 33; i++) 'k$i'],
        ),
      );
      expect(response.status, 400);
    });

    test('schema 不匹配 → 400 Unsupported identity request', () async {
      final response = await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(schema: 'webhtv.playback.identity.v0'),
      );
      expect(response.status, 400);
      expect(response.json['action'], 'invalid');
      expect(response.json['error'], contains('Unsupported'));
    });

    test('operation 非 resolve → 400', () async {
      final response = await send(
        server.port,
        '/api/playback/identity/resolve',
        body: resolveBody(operation: 'merge'),
      );
      expect(response.status, 400);
    });

    test('X-WebHTV-Config-Key 作为身份键兜底（Go 同款）', () async {
      final response = await send(
        server.port,
        '/api/playback/identity/resolve',
        body: {
          'schema': playbackIdentitySchema,
          'operation': 'resolve',
          'configType': 'vod',
          'sourceDataState': 'empty',
        },
        headers: {'X-WebHTV-Config-Key': 'from-header-key'},
      );
      expect(response.status, 200);
      expect(response.json['canonicalInterfaceKey'], 'from-header-key');
    });
  });

  group('6b/6c · 鉴权与未接线', () {
    test('注册表未接线 → 404（安卓进入旧服务端兼容模式）', () async {
      final server = await startServer(identityStore: null);
      // startServer 会兜底建一个空 store，这里手工拼一个不注入的实例。
      await server.stop();
      final bare = SyncServer(
        log: LogService(),
        host: SyncServerHost(
          deviceUuid: 'pc-uuid-test',
          deviceName: 'WebHTV PC',
          isEnabled: () => true,
          isPeerAuthorized: (_) => true,
          onHistory: (_, {String sourceKey = ''}) async =>
          const SyncMergeStats.empty(),
          onKeep: (_) async => const SyncMergeStats.empty(),
          onBackup: (_, _) async => const SyncSettings.empty(),
        ),
        startPort: 0,
        endPort: 0,
        bindAddress: '127.0.0.1',
      );
      await bare.start();
      try {
        final response = await send(
          bare.port,
          '/api/playback/identity/resolve',
          body: resolveBody(),
        );
        expect(response.status, 404);
      } finally {
        await bare.stop();
      }
    });

    test('配置 token 时不匹配 → 403', () async {
      final server = await startServer(pullToken: 'secret');
      try {
        final response = await send(
          server.port,
          '/api/playback/identity/resolve',
          body: resolveBody(),
          headers: {'X-WebHTV-Token': 'wrong'},
        );
        expect(response.status, 403);
      } finally {
        await server.stop();
      }
    });

    test('配置 token 时匹配 → 200', () async {
      final server = await startServer(pullToken: 'secret');
      try {
        final response = await send(
          server.port,
          '/api/playback/identity/resolve',
          body: resolveBody(),
          headers: {'X-WebHTV-Token': 'secret'},
        );
        expect(response.status, 200);
      } finally {
        await server.stop();
      }
    });

    test('未配置 token 且对端未授权 → 403', () async {
      final server = await startServer(peerAuthorized: false);
      try {
        final response = await send(
          server.port,
          '/api/playback/identity/resolve',
          body: resolveBody(),
        );
        expect(response.status, 403);
      } finally {
        await server.stop();
      }
    });

    test('同步服务未开启 → 403 且文案说明是服务未开启', () async {
      final server = await startServer(enabled: false);
      try {
        final response = await send(
          server.port,
          '/api/playback/identity/resolve',
          body: resolveBody(),
        );
        expect(response.status, 403);
        expect('${response.json['raw']}', contains('同步服务未开启'));
      } finally {
        await server.stop();
      }
    });

    test('拉取关闭时身份解析仍可用（不返回播放数据，拒绝反而留后遗症）', () async {
      final server = await startServer(pullEnabled: false);
      try {
        final response = await send(
          server.port,
          '/api/playback/identity/resolve',
          body: resolveBody(),
        );
        expect(response.status, 200);
      } finally {
        await server.stop();
      }
    });
  });

  group('6c · sync/status 能力声明', () {
    late SyncServer server;

    tearDown(() async => server.stop());

    test('声明 identityResolve 等 5 项能力', () async {
      server = await startServer();
      final response = await send(
        server.port,
        '/api/playback/sync/status',
        method: 'GET',
      );
      expect(response.status, 200);
      expect(response.contentType, 'application/json');
      final capabilities =
          response.json['capabilities']! as Map<String, Object?>;
      expect(capabilities['identityResolve'], isTrue);
      expect(capabilities['identityAliases'], isTrue);
      expect(capabilities['legacyUrlHashMigration'], isTrue);
      expect(capabilities['identityMerge'], isTrue);
      expect(capabilities['playbackSync'], isTrue);
    });

    test('如实报告 items/tombstones/nextSince', () async {
      server = await startServer(
        counts: (items: 7, tombstones: 2, nextSince: 1699999999999),
      );
      final response = await send(
        server.port,
        '/api/playback/sync/status',
        method: 'GET',
      );
      expect(response.json['items'], 7);
      expect(response.json['tombstones'], 2);
      expect(response.json['nextSince'], '1699999999999');
    });

    test('拉取关闭时 playbackSync=false（不谎报能力）', () async {
      server = await startServer(pullEnabled: false);
      final response = await send(
        server.port,
        '/api/playback/sync/status',
        method: 'GET',
      );
      final capabilities =
          response.json['capabilities']! as Map<String, Object?>;
      expect(capabilities['playbackSync'], isFalse);
      expect(capabilities['identityResolve'], isTrue);
    });

    test('endpoint 随请求路径/头回显（第三方客户端据此拼接）', () async {
      server = await startServer();
      final response = await send(
        server.port,
        '/api/playback/sync/status',
        method: 'GET',
        headers: {'X-WebHTV-Config-Key': 'my-site-key'},
      );
      expect(response.json['configKey'], 'my-site-key');
      expect('${response.json['endpoint']}', endsWith('/api/playback/sync'));
      expect('${response.json['endpoint']}', startsWith('http://127.0.0.1:'));
      expect(response.json['identityProtocol'], playbackIdentitySchema);
    });

    test('别名路由 /playback/sync/status 的 endpoint 不带 /api 前缀', () async {
      server = await startServer();
      final response = await send(
        server.port,
        '/playback/sync/status',
        method: 'GET',
      );
      expect('${response.json['endpoint']}', endsWith('/playback/sync'));
      expect('${response.json['endpoint']}', isNot(contains('/api/')));
    });

    test('POST → 405', () async {
      server = await startServer();
      final response = await send(
        server.port,
        '/api/playback/sync/status',
        body: const {},
      );
      expect(response.status, 405);
    });
  });

  group('纯逻辑 · 键校验与解析', () {
    test('合法键：小写字母/数字/._:-', () {
      expect(isValidPlaybackIdentityKey('abc123'), isTrue);
      expect(isValidPlaybackIdentityKey('a.b_c:d-e'), isTrue);
      expect(isValidPlaybackIdentityKey('550e8400-e29b-41d4-a716-446655440000'),
          isTrue);
      expect(isValidPlaybackIdentityKey('a' * 128), isTrue);
    });

    test('非法键：大写/空格/斜杠/超长/空', () {
      expect(isValidPlaybackIdentityKey('ABC'), isFalse);
      expect(isValidPlaybackIdentityKey('a b'), isFalse);
      expect(isValidPlaybackIdentityKey('a/b'), isFalse);
      expect(isValidPlaybackIdentityKey('a' * 129), isFalse);
      expect(isValidPlaybackIdentityKey(''), isFalse);
    });

    test('normalize 会 trim + 小写', () {
      expect(normalizePlaybackIdentityKey('  ABC  '), 'abc');
      expect(normalizePlaybackIdentityKey(42), isNull);
    });

    test('configType 归一化覆盖数字与未知值', () {
      expect(normalizePlaybackConfigType('1'), 'live');
      expect(normalizePlaybackConfigType('2'), 'wall');
      expect(normalizePlaybackConfigType('vod'), 'vod');
      expect(normalizePlaybackConfigType('nope'), 'vod');
      expect(normalizePlaybackConfigType(null), 'vod');
    });

    test('sourceDataState 未知值落 unknown（不当作 empty 静默 adopt）', () {
      final input = PlaybackIdentityInput.parse({
        'interfaceKey': 'k',
        'sourceDataState': 'weird',
      });
      expect(input?.sourceDataState, 'unknown');
    });

    test('键数组去重且保序', () {
      final input = PlaybackIdentityInput.parse({
        'interfaceKey': 'k',
        'strictAddressKeys': ['b', 'a', 'b'],
      });
      expect(input?.strictAddressKeys, ['b', 'a']);
    });
  });

  group('纯逻辑 · 注册表落盘', () {
    test('toJson/fromJson 往返保留身份、别名与 epoch', () {
      final store = PlaybackIdentityStore();
      store.resolve(
        PlaybackIdentityInput.parse({
          'interfaceKey': 'device-a',
          'strictAddressKeys': ['s' * 64],
        })!,
      );
      final restored = PlaybackIdentityStore.fromJson(
        jsonDecode(jsonEncode(store.toJson())),
      );
      final registry = restored.registryFor('vod');
      expect(registry.epoch, 1);
      expect(registry.boundCanonical('device-a'), 'device-a');
      expect(registry.boundCanonical('s' * 64), 'device-a');
    });

    test('别名指向不存在的身份时被丢弃（手改文件不会引出空身份）', () {
      final restored = PlaybackIdentityStore.fromJson({
        'vod': {
          'epoch': 1,
          'identities': <String, Object?>{},
          'aliases': {
            'k': {'canonicalInterfaceKey': 'gone', 'kind': 'strict'},
          },
        },
      });
      expect(restored.registryFor('vod').aliases, isEmpty);
    });

    test('onChanged 只在成功变更时触发', () {
      var changes = 0;
      final store = PlaybackIdentityStore(onChanged: () => changes++);
      final input = PlaybackIdentityInput.parse({
        'interfaceKey': 'device-a',
        'strictAddressKeys': ['s' * 64],
        'sourceDataState': 'has_data',
      })!;
      // 首次 create → 变更
      store.resolve(input);
      expect(changes, 1);
      // 已绑定 → keep，仍然写注册表（刷新键/时间戳）
      store.resolve(input);
      expect(changes, 2);
    });

    test('confirm_required 不改状态也不触发落盘', () {
      var changes = 0;
      final store = PlaybackIdentityStore(onChanged: () => changes++);
      store.resolve(
        PlaybackIdentityInput.parse({
          'interfaceKey': 'device-a',
          'strictAddressKeys': ['s' * 64],
        })!,
      );
      final before = changes;
      final result = store.resolve(
        PlaybackIdentityInput.parse({
          'interfaceKey': 'device-b',
          'strictAddressKeys': ['s' * 64],
          'sourceDataState': 'has_data',
        })!,
      );
      expect(result.body['action'], 'confirm_required');
      expect(changes, before);
    });
  });
}
