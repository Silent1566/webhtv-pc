/// 已连接安卓环境 MVP · 状态层契约（AppState）。
///
/// 本套用例只替换「进程 / socket / HTTP」三类外部边界：真实的
/// AndroidAdbRuntime（自有 ADB 服务 + 转发租约）、真实的 SyncState.importSites
/// 导入链路、真实的 SQLite 与设置文件、真实的本地代理与回环 HTTP。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/android_adb_profile.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/android_adb_runtime.dart';
import 'package:webhtv_pc/services/android_bridge_service.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/proxy_server.dart';
import 'package:webhtv_pc/state/app_state.dart';

import 'android_adb_runtime_fixtures.dart';
import 'support/temp_dirs.dart';

const String _deviceUuid = 'uuid-managed-0001';
const String _target = '10.0.2.2:5555';
const String _interfaceKey = 'managed-source';

/// 手写的管理型源标识（bridge|uuid|interfaceKey）。
const String _sourceKey = 'bridge|$_deviceUuid|$_interfaceKey';

http.Response _json(Object? body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// 受控 T4 网关（HTTP 边界）：应答桥接链路真正会用的端点。
class _GatewayHttp {
  String uuid = _deviceUuid;

  /// 第 N 次（含）起的 /device 一律 404：让运行时探测成功、导入时的补探测失败。
  int failDeviceFrom = 0;

  /// 第 2 次（含）起的 /device 报另一台设备：证明导入按 expectedUuid 拦下。
  String? uuidAfterFirstCall;
  int deviceCalls = 0;
  final List<Uri> requests = <Uri>[];
  final List<String> authorities = <String>[];

  http.Client get client => MockClient((request) async {
    requests.add(request.url);
    authorities.add(request.url.authority);
    switch (request.url.path) {
      case '/device':
        deviceCalls++;
        if (failDeviceFrom > 0 && deviceCalls >= failDeviceFrom) {
          return http.Response('not found', 404);
        }
        final reported = uuidAfterFirstCall != null && deviceCalls >= 2
            ? uuidAfterFirstCall!
            : uuid;
        return http.Response(
          deviceJson(uuid: reported, name: '受控设备'),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      case '/manage/configs':
        return _json({
          'items': [
            {
              'type': 0,
              'name': '受控源',
              'url': 'https://sub.example.test/a.json',
              'interfaceKey': _interfaceKey,
              'active': true,
              'time': 1700000000000,
            },
          ],
        });
      case '/vod/api':
        // 站点主机必须是「本次请求的主机:端口」：网关转换会做主机一致性校验。
        final authority = request.url.authority;
        return _json({
          'sites': [
            {
              'key': 'managed-site',
              'name': '受控站点',
              'type': '4',
              'api': 'http://$authority/vod/api?key=managed-site',
              'searchable': 1,
            },
          ],
          'lives': <Object>[],
        });
    }
    return http.Response('not found', 404);
  });
}

/// 受控 SDK 进程 + 受控 ADB 服务协议。
class _Harness {
  _Harness(this.log);

  final LogService log;
  final FakeProcessHost processes = FakeProcessHost();
  final _GatewayHttp gateway = _GatewayHttp();

  /// 下一次连接时自有 ADB 服务是否拒绝 host:connect。
  bool failConnect = false;

  /// 自有服务夹具本次连接的第一个转发端口（网关用掉它，第二个转发端口 = +1）。
  ///
  /// 端到端媒体用例把真实上游绑在 firstForwardPort + 1，于是 adb 夹具报出的
  /// 「媒体转发端口」正好指向那个上游。
  int? firstForwardPort;

  FakeAdbServer? adb;
  int _serverIndex = 0;

  late final AndroidBridgeService bridge = AndroidBridgeService(
    log: log,
    timeout: const Duration(seconds: 3),
    client: gateway.client,
  );

  late final AndroidAdbRuntime runtime = AndroidAdbRuntime(
    bridge: bridge,
    log: log,
    processes: processes,
    commandTimeout: const Duration(milliseconds: 500),
    connectTimeout: const Duration(seconds: 3),
  );

  void installOwnedServer() {
    processes.onStart = (executable, arguments, environment) async {
      final port = int.parse(arguments[1].substring(4));
      final bound = await FakeAdbServer.bind(port: port);
      bound.failConnect = failConnect;
      bound.nextPort = firstForwardPort ?? 34000 + (++_serverIndex) * 10;
      adb = bound;
      return FakeProcess.detached(
        onKill: () async {
          await bound.close();
        },
      );
    };
  }
}

AndroidAdbProfile _networkProfile() =>
    AndroidAdbProfile(mode: AndroidAdbMode.network, target: _target);

void main() {
  late Directory tempDir;
  late LogService log;
  late _Harness harness;
  late AppState state;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-adb-state');
    log = LogService();
    harness = _Harness(log)..installOwnedServer();
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${tempDir.path}/webhtv-pc',
          'data': '${tempDir.path}/webhtv-pc',
          'cache': '${tempDir.path}/webhtv-pc/cache',
          'state': '${tempDir.path}/webhtv-pc/logs',
        },
      ),
      log: log,
      androidBridgeService: harness.bridge,
      androidAdbRuntime: harness.runtime,
    );
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    await deleteTempDirBestEffort(tempDir);
  });

  Future<void> connectAndActivate() async {
    await state.connectAndroidEnvironment(_networkProfile());
    await state.activateConfigRecord(state.configs.single.id);
  }

  group('管理型导入', () {
    test('连接既有环境后按管理型（adb）导入；换本机端口仍是一条记录', () async {
      final profile = _networkProfile();
      final device = await state.connectAndroidEnvironment(profile);

      expect(device.uuid, _deviceUuid);
      expect(device.reachableBase, startsWith('http://127.0.0.1:'));
      expect(
        state.androidConnections.map((record) => record.connectionKey),
        <String>[profile.connectionKey],
      );
      expect(state.androidConnections.single.deviceUuid, _deviceUuid);

      final imported = state.configs.single;
      expect(imported.bridgeTransport, 'adb');
      expect(imported.sourceKey, _sourceKey);
      expect(imported.bridgeDevice, _deviceUuid);
      expect(imported.origin, device.reachableBase);
      final firstRecordId = imported.id;
      final firstOrigin = imported.origin;

      await harness.runtime.disconnect(_deviceUuid);
      final ok = await state.reconnectAndroidEnvironment(profile.connectionKey);
      expect(ok, isTrue);

      final refreshed = state.configs.single;
      expect(refreshed.id, firstRecordId, reason: '同一来源不能长成第二条记录');
      expect(refreshed.sourceKey, _sourceKey);
      expect(refreshed.bridgeTransport, 'adb');
      expect(refreshed.origin, isNot(firstOrigin), reason: '必须用新端口，绝不复用旧端口');
      expect(refreshed.origin, startsWith('http://127.0.0.1:'));
      expect(
        state.androidConnections.map((record) => record.connectionKey),
        <String>[profile.connectionKey],
      );
    });

    test('连接失败：抛 AppError（带运行时原因），且不留下任何管理型记录', () async {
      harness.failConnect = true;

      await expectLater(
        state.connectAndroidEnvironment(_networkProfile()),
        throwsA(
          isA<AppError>()
              .having(
                (error) => error.message,
                'message',
                contains('ADB 服务拒绝了请求'),
              )
              .having(
                (error) => error.kind,
                'kind',
                AppErrorKind.bridgeUnreachable,
              ),
        ),
      );
      expect(state.androidConnections, isEmpty);
      expect(state.configs, isEmpty);
      expect(state.savedConfigs, isEmpty);
    });

    test('重连沿用已保存的描述，并在设备换了之后按 expectedUuid 拒绝', () async {
      final profile = _networkProfile();
      final key = profile.connectionKey;
      await state.connectAndroidEnvironment(profile);
      await harness.runtime.disconnect(_deviceUuid);

      expect(await state.reconnectAndroidEnvironment(key), isTrue);
      expect(harness.adb!.requests, isNotEmpty);
      expect(
        harness.adb!.requests,
        contains('host:connect:$_target'),
        reason: '重连必须用保存的描述，而不是缓存的端口',
      );
      expect(state.configs.single.bridgeTransport, 'adb');

      await harness.runtime.disconnect(_deviceUuid);
      harness.gateway.uuid = 'uuid-other-device';
      await expectLater(
        state.reconnectAndroidEnvironment(key),
        throwsA(
          isA<AppError>().having(
            (error) => error.message,
            'message',
            contains('不一致'),
          ),
        ),
      );
      expect(state.androidConnections.single.deviceUuid, _deviceUuid);
      expect(state.configs.single.bridgeTransport, 'adb');
    });

    test('忘记已保存的连接描述不影响已导入的管理型记录', () async {
      final profile = _networkProfile();
      await state.connectAndroidEnvironment(profile);
      await state.forgetAndroidConnection(profile.connectionKey);
      expect(state.androidConnections, isEmpty);
      expect(state.configs.single.bridgeTransport, 'adb');
    });

    test('导入探测失败：管理型拒绝用地址当设备身份（不留身份分叉）', () async {
      // 第 1 次 /device 是运行时的网关探测；第 2 次是导入链路自己的补探测。
      harness.gateway.failDeviceFrom = 2;

      await expectLater(
        state.connectAndroidEnvironment(_networkProfile()),
        throwsA(isA<AppError>()),
      );
      expect(state.configs, isEmpty, reason: '没有真实 uuid 就不许落管理型记录');
      expect(
        state.savedConfigs.where(
          (record) => record.sourceKey.startsWith('bridge|http://'),
        ),
        isEmpty,
        reason: '绝不能出现 bridge|http://127.0.0.1:<port>|key 这种身份分叉',
      );
    });

    test('导入探测到的 UUID 与连接时证明的不一致：拒绝导入', () async {
      // 运行时探测看到 uuid-managed-0001；导入链路的补探测看到另一台。
      harness.gateway.uuidAfterFirstCall = 'uuid-impostor';

      await expectLater(
        state.connectAndroidEnvironment(_networkProfile()),
        throwsA(
          isA<AppError>().having(
            (error) => error.message,
            'message',
            contains('不一致'),
          ),
        ),
      );
      expect(state.configs, isEmpty);
    });
  });

  group('播放/代理路由', () {
    test('解析器按本次播放的实际逻辑起点构造：只授权 guest 5000', () async {
      await connectAndActivate();
      final record = state.activeRecord!;
      final media = Uri.parse('http://127.0.0.1:5000/media/movie.m3u8');

      final resolver = state.managedPlaybackResolverFor(media, record: record);
      expect(resolver, isNotNull);
      final mapped = await resolver!(media);
      expect(mapped, isA<int>());
      expect(mapped, greaterThan(0));

      // 别的 guest 端口（含历史前提里那个 9978）不在本次逻辑起点内。
      expect(
        await resolver(Uri.parse('http://127.0.0.1:5001/media/movie.m3u8')),
        isNull,
      );
      expect(
        await resolver(Uri.parse('http://127.0.0.1:9978/vod/api?key=x')),
        isNull,
      );
      expect(
        await resolver(Uri.parse('https://127.0.0.1:5000/media/movie.m3u8')),
        isNull,
      );
      expect(
        state.managedPlaybackResolverFor(
          Uri.parse('https://cdn.example.test/a.m3u8'),
          record: record,
        ),
        isNull,
      );
      expect(
        state.managedPlaybackResolverFor(
          Uri.parse('http://user:pass@127.0.0.1:5000/a.m3u8'),
          record: record,
        ),
        isNull,
      );
    });

    test('已退役网关失败关闭：仍交给运行时，绝不回退到本机端口', () async {
      await connectAndActivate();
      final record = state.activeRecord!;
      final gateway = Uri.parse(record.origin);
      expect(harness.runtime.recognizesGateway(gateway), isTrue);
      final media = Uri.parse('http://127.0.0.1:5000/media/movie.m3u8');
      expect(
        state.managedPlaybackResolverFor(media, record: record),
        isNotNull,
      );

      await harness.runtime.disconnect(_deviceUuid);

      final retired = state.managedPlaybackResolverFor(media, record: record);
      expect(retired, isNotNull, reason: '已退役网关必须失败关闭，而不是退回普通策略');
      expect(harness.runtime.recognizesGateway(gateway), isTrue);
      await expectLater(retired!(media), throwsA(isA<AppError>()));
    });

    test('跨配置：生效是老记录时，管理型播放上下文仍绑到它自己的设备', () async {
      final legacyId = state.syncDatabase!.saveConfig(
        name: '老 HTTP 记录 B',
        origin: 'https://b.example.test/a.json',
        json: const {
          'sites': [
            {
              'key': 'legacy-site',
              'name': '老站点',
              'type': 0,
              'api': 'https://b.example.test/',
            },
          ],
        },
        siteCount: 1,
        liveCount: 0,
        sourceKey: 'local|https://b.example.test/a.json',
      );
      await state.activateConfigRecord(legacyId);
      expect(state.activeRecord?.bridgeTransport, '');

      await state.connectAndroidEnvironment(_networkProfile());
      final managed = state.configs.firstWhere(
        (record) => record.bridgeTransport == 'adb',
      );
      final context = state.playbackContextFor(managed.sourceKey);
      expect(context, isNotNull);

      // 播放上下文来自管理型 A → 用 A，而不是生效的老记录 / 默认端口。
      final originRecord = state.managedRecordForPlaybackService(
        context!.service,
      );
      expect(originRecord?.id, managed.id);
      expect(originRecord?.bridgeTransport, 'adb');
      expect(state.managedRecordForPlaybackService(state.siteService), isNull);
      expect(state.managedRecordForPlaybackService(null), isNull);

      final media = Uri.parse('http://127.0.0.1:5000/media/movie.m3u8');
      final resolver = state.managedPlaybackResolverFor(
        media,
        record: originRecord,
      );
      expect(resolver, isNotNull);
      expect(await resolver!(media), isA<int>());
      expect(state.activeRecord?.id, legacyId, reason: '导入不得切换生效配置');
    });

    test('普通目标：无 Header / 私网 / 云元数据仍直连，可代理目标普通会话', () async {
      await state.startProxy(port: 0);

      Future<void> staysDirect(String url) async {
        final decision = PlaybackDecision(
          action: PlaybackAction.direct,
          url: url,
          headers: HeaderMap({'user-agent': 'Player/1'}),
        );
        final out = await state.proxyDecision(decision, siteKey: 'legacy');
        expect(out.url, url, reason: '普通目标必须保持原判：$url');
      }

      await staysDirect('http://127.0.0.1:9978/media/movie.m3u8');
      await staysDirect('http://192.168.1.5/media/movie.mp4');
      await staysDirect('http://169.254.169.254/latest/meta-data/');

      final noHeader = PlaybackDecision(
        action: PlaybackAction.direct,
        url: 'https://cdn.example.test/movie.m3u8',
      );
      expect(
        (await state.proxyDecision(noHeader, siteKey: 'legacy')).url,
        noHeader.url,
      );

      final ordinary = PlaybackDecision(
        action: PlaybackAction.direct,
        url: 'https://cdn.example.test/movie.m3u8',
        headers: HeaderMap({'user-agent': 'Player/1'}),
      );
      final proxied = await state.proxyDecision(ordinary, siteKey: 'legacy');
      expect(proxied.url, startsWith(state.proxyBaseUrl));
      final token = proxied.url!.split('/p/')[1].split('/').first;
      expect(state.proxySessions.byToken(token)!.targetResolver, isNull);
    });

    test('端到端：guest 5000 的媒体与 MPD 子资源经会话映射，别的 guest 端口被拒', () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => upstream.close(force: true));
      final hits = <String>[];
      upstream.listen((request) async {
        hits.add(request.uri.path);
        final response = request.response;
        if (request.uri.path.endsWith('.mpd')) {
          response.headers.set('content-type', 'application/dash+xml');
          response.write(
            '<?xml version="1.0"?>'
            '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" '
            'mediaPresentationDuration="PT2S"><Period>'
            '<AdaptationSet mimeType="video/mp4">'
            '<Representation id="v1" bandwidth="1000">'
            '<SegmentTemplate '
            'initialization="http://127.0.0.1:5000/seg/init.mp4" '
            'media="http://127.0.0.1:5000/seg/\$Number\$.m4s" '
            'startNumber="1"/>'
            '</Representation></AdaptationSet></Period></MPD>',
          );
        } else {
          response.headers.set('content-type', 'video/mp4');
          response.add(List<int>.filled(8, 7));
        }
        await response.close();
      });
      // 网关转发用掉 firstForwardPort，媒体转发（guest 5000）正好指向真实上游。
      harness.firstForwardPort = upstream.port - 1;

      await connectAndActivate();
      await state.startProxy(port: 0);
      final record = state.activeRecord!;
      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      Future<HttpClientResponse> get(String url) async {
        final request = await client.getUrl(Uri.parse(url));
        return request.close();
      }

      final media = Uri.parse('http://127.0.0.1:5000/media/movie.mp4');
      final proxied = await state.proxyManagedDecision(
        PlaybackDecision(
          action: PlaybackAction.direct,
          url: media.toString(),
          headers: HeaderMap({'user-agent': 'ManagedPlayer/1'}),
        ),
        siteKey: record.sourceKey,
        managedResolver: state.managedPlaybackResolverFor(
          media,
          record: record,
        )!,
      );
      expect(proxied.url, startsWith(state.proxyBaseUrl));

      final top = await get(proxied.url!);
      expect(top.statusCode, 200);
      expect(await top.transform(utf8.decoder).join(), hasLength(8));
      expect(hits, contains('/media/movie.mp4'));

      // 同一 token 指向别的 guest 端口：不受控 → 普通策略拒绝（403），不打上游。
      final token = proxied.url!.split('/p/')[1].split('/').first;
      final foreign =
          '${state.proxyBaseUrl}/p/$token/'
          '${LocalProxyServer.encodeTarget(Uri.parse('http://127.0.0.1:5001/evil.m4s'))}';
      final denied = await get(foreign);
      expect(denied.statusCode, 403);
      expect(hits, isNot(contains('/evil.m4s')));

      // MPD 子资源走同一个受控会话（guest 5000 → 上游）。
      final mpd = Uri.parse('http://127.0.0.1:5000/dash/manifest.mpd');
      final mpdProxied = await state.proxyManagedDecision(
        PlaybackDecision(
          action: PlaybackAction.direct,
          url: mpd.toString(),
          headers: HeaderMap({'user-agent': 'ManagedPlayer/1'}),
        ),
        siteKey: record.sourceKey,
        managedResolver: state.managedPlaybackResolverFor(mpd, record: record)!,
      );
      final manifest = await get(mpdProxied.url!);
      expect(manifest.statusCode, 200);
      final body = await manifest.transform(utf8.decoder).join();
      // MPD 子资源（guest 5000）必须被改写成同一个会话地址，而不是原样留给播放器。
      final child =
          RegExp(r'initialization="([^"]+)"').firstMatch(body)?.group(1) ?? '';
      expect(
        child,
        startsWith(state.proxyBaseUrl),
        reason: 'MPD 子资源没走会话：$body',
      );
      final childResponse = await get(child);
      expect(childResponse.statusCode, 200);
      await childResponse.drain<void>();
      expect(hits, contains('/seg/init.mp4'));

      final template =
          RegExp(r'media="([^"]+)"').firstMatch(body)?.group(1) ?? '';
      final mpdToken = mpdProxied.url!.split('/p/')[1].split('/').first;
      expect(template, startsWith('${state.proxyBaseUrl}/p/$mpdToken/d/'));
      expect(template, contains(r'$Number$.m4s'));
      final segment = template.replaceAll(r'$Number$', '1');
      final segmentResponse = await get(segment);
      expect(segmentResponse.statusCode, 200);
      expect(
        await segmentResponse.fold<int>(
          0,
          (size, chunk) => size + chunk.length,
        ),
        8,
      );
      expect(hits, contains('/seg/1.m4s'));
      expect(
        harness.adb!.forwards.where((row) => row[2] == '5000'),
        hasLength(1),
        reason: '初始化与媒体分片必须复用同一 SDK 会话的 guest 5000 转发',
      );
    });

    test('管理型记录：老 AndroidPlaybackBridge 必须不挂；老 HTTP 记录原样', () async {
      await connectAndActivate();
      expect(state.activeRecord?.bridgeTransport, 'adb');
      expect(state.siteService!.playbackBridge, isNull);
      expect(
        state
            .playbackContextFor(state.activeRecord!.sourceKey)!
            .service
            .playbackBridge,
        isNull,
      );

      final legacyId = state.syncDatabase!.saveConfig(
        name: '老 HTTP 记录',
        origin: 'https://example.test/a.json',
        json: const {
          'sites': [
            {
              'key': 'legacy-site',
              'name': '老站点',
              'type': 0,
              'api': 'https://example.test/',
            },
          ],
        },
        siteCount: 1,
        liveCount: 0,
        sourceKey: 'local|https://example.test/a.json',
      );
      await state.activateConfigRecord(legacyId);
      expect(state.activeRecord?.bridgeTransport, '');
      expect(state.siteService!.playbackBridge, isNotNull);
      expect(
        state
            .playbackContextFor(state.activeRecord!.sourceKey)!
            .service
            .playbackBridge,
        isNotNull,
      );
    });

    test('端口变化后：当前站点服务指向新网关，记录 id/sourceKey/选中站点不变', () async {
      await connectAndActivate();
      final before = state.activeRecord!;
      final beforeSite = state.selectedSite?.key;
      expect(beforeSite, isNotNull);

      await harness.runtime.disconnect(_deviceUuid);
      expect(await state.refreshConfigRecord(before.id), isTrue);

      final after = state.activeRecord!;
      expect(after.id, before.id);
      expect(after.sourceKey, _sourceKey);
      expect(after.bridgeTransport, 'adb');
      expect(after.origin, isNot(before.origin));
      expect(state.selectedSite?.key, beforeSite);

      final api = Uri.parse(state.siteService!.appConfig.sites.single.api);
      expect(
        api.authority,
        Uri.parse(after.origin).authority,
        reason: '当前站点服务必须指向新的网关端口（不能停在旧快照）',
      );
    });

    test('会话消失但描述还在：激活/刷新先自动重连刷新（不需要先手动连）', () async {
      await connectAndActivate();
      final record = state.activeRecord!;
      final beforeOrigin = record.origin;

      await harness.runtime.disconnect(_deviceUuid);
      expect(await state.refreshConfigRecord(record.id), isTrue);
      expect(state.activeRecord!.origin, isNot(beforeOrigin));
      expect(state.activeRecord!.bridgeTransport, 'adb');

      await harness.runtime.disconnect(_deviceUuid);
      expect(await state.activateConfigRecord(record.id), isTrue);
      expect(state.activeRecord!.id, record.id);
      expect(state.siteService!.playbackBridge, isNull);
    });

    test('会话消失且描述已被忘记：激活/刷新显式失败，绝不请求旧端口', () async {
      await connectAndActivate();
      final record = state.activeRecord!;
      final oldAuthority = Uri.parse(record.origin).authority;
      await harness.runtime.disconnect(_deviceUuid);
      await state.forgetAndroidConnection(
        state.androidConnections.single.connectionKey,
      );
      final requestsBefore = harness.gateway.requests.length;

      expect(await state.refreshConfigRecord(record.id), isFalse);
      expect(state.lastError?.message, contains('重新连接已保存的安卓环境'));
      expect(await state.activateConfigRecord(record.id), isFalse);
      expect(state.lastError?.message, contains('重新连接已保存的安卓环境'));

      expect(
        harness.gateway.authorities.skip(requestsBefore),
        isNot(contains(oldAuthority)),
        reason: '没有描述时绝不能拿记录里的旧回环端口去探测',
      );
      expect(state.savedConfigs.single.bridgeTransport, 'adb');
      expect(state.savedConfigs.single.origin, record.origin);
    });
  });
  group('连接描述的落盘失败', () {
    /// 让 android_connections.json 变成一个目录：原子写（写 .tmp → rename）必然
    /// 失败。这是受控的文件系统边界，不碰权限、也不碰用户的真实配置目录。
    void breakStore() {
      final path = '${state.paths.configDir}/android_connections.json';
      final file = File(path);
      if (file.existsSync()) file.renameSync('$path.bak');
      Directory(path).createSync(recursive: true);
    }

    test('连接成功但描述落盘失败：报存储错误，不导入、不留管理型记录', () async {
      breakStore();

      await expectLater(
        state.connectAndroidEnvironment(_networkProfile()),
        throwsA(
          isA<AppError>()
              .having((error) => error.kind, 'kind', AppErrorKind.storage)
              .having((error) => error.message, 'message', contains('连接描述')),
        ),
      );
      expect(state.androidConnections, isEmpty);
      expect(state.configs, isEmpty, reason: '描述没落盘就不许导入/标记管理型');
      expect(state.savedConfigs, isEmpty);
    });

    test('重连时描述落盘失败：报存储错误，原记录与旧端点保持可用', () async {
      final profile = _networkProfile();
      await state.connectAndroidEnvironment(profile);
      final before = state.configs.single;
      await harness.runtime.disconnect(_deviceUuid);
      breakStore();

      await expectLater(
        state.reconnectAndroidEnvironment(profile.connectionKey),
        throwsA(
          isA<AppError>().having(
            (error) => error.kind,
            'kind',
            AppErrorKind.storage,
          ),
        ),
      );
      expect(state.configs.single.origin, before.origin, reason: '落盘失败不许改已有记录');
      expect(state.configs.single.bridgeTransport, 'adb');
      expect(
        state.androidConnections.map((record) => record.connectionKey),
        contains(profile.connectionKey),
        reason: '内存里仍保有描述，用户还能再连',
      );
    });

    test('忘记时落盘失败：报存储错误，不谎称已忘记', () async {
      final profile = _networkProfile();
      await state.connectAndroidEnvironment(profile);
      final key = profile.connectionKey;
      breakStore();

      await expectLater(
        state.forgetAndroidConnection(key),
        throwsA(
          isA<AppError>().having(
            (error) => error.kind,
            'kind',
            AppErrorKind.storage,
          ),
        ),
      );
      expect(
        state.androidConnections.map((record) => record.connectionKey),
        contains(key),
        reason: '记录还在就不许报「已忘记」',
      );
    });
  });
}
