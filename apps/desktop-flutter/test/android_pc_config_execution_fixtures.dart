import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/android_adb_profile.dart';
import 'package:webhtv_pc/services/android_adb_runtime.dart';
import 'package:webhtv_pc/services/android_bridge_service.dart';
import 'package:webhtv_pc/services/android_config_execution_store.dart';
import 'package:webhtv_pc/services/android_connection_store.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/pc_config_snapshot_server.dart';
import 'package:webhtv_pc/state/app_state.dart';

import 'android_adb_runtime_fixtures.dart';
import 'support/temp_dirs.dart';

const pcExecutionSource = 'local|https://pc.example.test/config/original.json';
const pcExecutionRaw = <String, Object?>{
  'spider': 'https://pc.example.test/jars/spider.jar',
  'flags': ['线路甲', '线路乙'],
  'unknown': {'literal': 'keep me'},
  'sites': [
    {
      'key': 'csp_A',
      'name': '原站点甲',
      'type': 3,
      'api': 'csp_A',
      'jar': './source.jar',
      'ext': './rules.json',
      'searchable': 1,
      'header': {'Referer': 'https://pc.example.test/'},
    },
    {
      'key': 'csp_B',
      'name': '原站点乙',
      'type': 3,
      'api': 'csp_B',
      'searchable': 1,
    },
  ],
};

/// Only process/ADB socket and HTTP boundaries are substituted. State, runtime,
/// publisher, execution service and SQLite are their real implementations.
class PcExecutionFixture {
  PcExecutionFixture(Directory root) : root = root.absolute;
  final Directory root;
  final log = LogService();
  final processes = FakeProcessHost();
  final servers = <FakeAdbServer>[];
  final imports = <String>[];
  final snapshots = <Map<String, Object?>>[];
  final copies = <String, String>{};
  final requests = <Uri>[];
  String uuid = 'pc-execution-device';
  bool missingKey = false;
  bool reverseConflict = false;
  Completer<void>? importGate;
  Map<String, Object?> original = pcExecutionRaw;
  late final profile = AndroidAdbProfile(
    mode: AndroidAdbMode.network,
    target: '192.0.2.8:5555',
  );
  late final paths = AppPaths.resolve(
    overrides: {
      'config': '${root.path}/config',
      'data': '${root.path}/data',
      'cache': '${root.path}/cache',
      'state': '${root.path}/logs',
    },
  );
  late final publisher = PcConfigSnapshotServer(log: log);
  late final store = AndroidConfigExecutionStore(
    path: '${paths.configDir}/android_config_executions.json',
    log: log,
  );
  late final http.Client client = MockClient((request) async {
    requests.add(request.url);
    http.Response json(Object value) => http.Response(
      jsonEncode(value),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
    if (request.url.host == 'pc.example.test') return json(original);
    if (request.url.path == '/device') {
      return json({
        'uuid': uuid,
        'name': '已保存测试环境',
        'type': 0,
        'ip': '127.0.0.1',
      });
    }
    if (request.url.path == '/manage/config/import') {
      await importGate?.future;
      final fields = Uri.splitQueryString(request.body);
      final url = fields['url']!;
      imports.add(url);
      // Simulate adbd reverse at the socket boundary: device HTTP reaches the
      // actual loopback snapshot publisher's port, preserving the token path.
      final uri = Uri.parse(url);
      final row = servers.last.reverseRows.firstWhere(
        (row) => row[0] == '${uri.port}',
      );
      final transport = HttpOverrides.runWithHttpOverrides(
        () => HttpClient(),
        PcExecutionHttpOverrides(),
      );
      String body;
      try {
        final response = await (await transport.getUrl(
          uri.replace(port: int.parse(row[1])),
        )).close();
        body = await utf8.decoder.bind(response).join();
      } finally {
        transport.close(force: true);
      }
      final snapshot = (jsonDecode(body) as Map).cast<String, Object?>();
      snapshots.add(snapshot);
      final created = !copies.containsKey(url);
      copies.putIfAbsent(url, () => 'copied-source-${copies.length + 1}');
      return json({
        'code': 0,
        'data': {
          'id': copies.length,
          'interfaceKey': copies[url],
          'url': url,
          'name': fields['name'],
          'created': created,
          'active': false,
        },
      });
    }
    if (request.url.path == '/vod/api') {
      if (request.url.queryParameters['ac'] == 'config') {
        return json({
          'sites': [
            for (final key in [
              'csp_A',
              if (!missingKey) 'csp_B',
              'android-extra',
            ])
              {
                'key': key,
                'name': '安卓名称',
                'type': 4,
                'api': 'http://${request.url.authority}/vod/api?key=$key',
              },
          ],
        });
      }
      if (request.url.queryParameters.containsKey('play')) {
        return json({
          'parse': 0,
          'url': 'http://127.0.0.1:5000/movie.mp4',
          'header': {'User-Agent': 'PCExecution'},
        });
      }
      return json({
        'class': [
          {'type_id': '1', 'type_name': '电影'},
        ],
        'list': [
          {'vod_id': 'v1', 'vod_name': '测试影片', 'vod_pic': ''},
        ],
      });
    }
    return http.Response('not found', 404);
  });
  late final bridge = AndroidBridgeService(log: log, client: client);
  AndroidAdbRuntime newRuntime() => AndroidAdbRuntime(
    bridge: bridge,
    log: log,
    processes: processes,
    commandTimeout: const Duration(seconds: 2),
    connectTimeout: const Duration(seconds: 5),
  );
  late AndroidAdbRuntime runtime = newRuntime();
  late AppState state;
  int recordId = 0;
  bool closed = false;

  Future<void> boot({bool saveConnection = true, bool seed = true}) async {
    processes.onStart = (executable, arguments, environment) async {
      final server = await FakeAdbServer.bind(
        port: int.parse(arguments[1].substring(4)),
      );
      server.nextPort = 35000 + servers.length * 10;
      server.reverseForwardFails = reverseConflict;
      servers.add(server);
      return FakeProcess.detached(onKill: server.close);
    };
    if (saveConnection) {
      final connections = AndroidConnectionStore(
        path: '${paths.configDir}/$androidConnectionsFileName',
        log: log,
      );
      await connections.remember(
        profile,
        deviceUuid: 'pc-execution-device',
        name: '已保存测试环境',
      );
    }
    state = AppState(
      paths: paths,
      log: log,
      androidBridgeService: bridge,
      androidAdbRuntime: runtime,
      androidExecutionStore: store,
      httpClient: client,
      warmAutoRoutes: false,
    );
    await state.bootstrap();
    if (seed) {
      recordId = state.database!.saveConfig(
        name: '原 PC 配置',
        origin: 'https://pc.example.test/config/original.json',
        json: pcExecutionRaw,
        sourceKey: pcExecutionSource,
        siteCount: 2,
        makeActive: false,
      );
    } else {
      recordId = state.savedConfigs.first.id;
    }
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    state.dispose();
    await state.androidExecutionShutdown;
    client.close();
    await deleteTempDirBestEffort(root);
  }
}

class PcExecutionHttpOverrides extends HttpOverrides {}

class PcExecutionProxyOverrides extends HttpOverrides {
  PcExecutionProxyOverrides(this.port);
  final int port;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..findProxy = (_) => 'PROXY 127.0.0.1:$port';
}
