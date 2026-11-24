import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/ipc_protocol.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/sidecar_runtime.dart';
import 'package:webhtv_pc/services/spider_process.dart';
import 'package:webhtv_pc/services/spider_registry.dart';

import '../fixture_support.dart';

const searchCancelBound = Duration(seconds: 8);

class SearchCancelHarness {
  late Directory root;
  late HttpServer server;
  late SpiderHostSupervisor supervisor;
  late LocalSpider spider;
  late Site site;
  final log = LogService();
  final frames = <Map<String, dynamic>>[];
  final sent = <String>[];
  final observations = <Map<String, dynamic>>[];
  final gates = <String, HttpRequest>{};
  final _changes = StreamController<void>.broadcast(sync: true);

  String get base => 'http://127.0.0.1:${server.port}';
  String get source => p.join(
    Directory.current.path,
    'test',
    'support',
    'search_cancel_host.py',
  );
  LocalSpiderCommand command({bool gateInit = false}) => LocalSpiderCommand(
    executable: '/usr/bin/python3',
    arguments: [source, base, if (gateInit) '--gate-init'],
  );

  Future<void> start() async {
    root = await Directory.systemTemp.createTemp('webhtv-search-cancel-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path.startsWith('/gate/')) {
        gates[request.uri.path.substring(6)] = request;
      } else {
        final body = jsonDecode(
          await utf8.decoder.bind(request).join(),
        ) as Map<String, dynamic>;
        if (request.uri.path == '/frame') frames.add(body);
        if (request.uri.path == '/observed') observations.add(body);
        if (request.uri.path == '/sent') sent.add(body['id'] as String);
        request.response.write('{}');
        await request.response.close();
      }
      _changes.add(null);
    });
    supervisor = SpiderHostSupervisor(
      workRoot: p.join(root.path, 'work'),
      log: log,
    );
    final manifest = SpiderManifest(
      key: 'search-cancel',
      name: 'Search cancellation fixture',
      runtime: 'python-3',
      entry: p.basename(source),
      capabilities: const ['home', 'category', 'detail', 'search', 'play'],
      permissions: const SpiderPermissions(network: true),
      limits: const SpiderLimits(concurrency: 4),
    );
    final manifestFile = File(p.join(root.path, 'manifest.json'));
    await manifestFile.writeAsString(jsonEncode(manifest.toJson()));
    spider = LocalSpider(
      manifest: manifest,
      manifestPath: manifestFile.path,
      rootDir: root.path,
      entryPath: source,
    );
    site = Site(
      key: manifest.key,
      name: manifest.name,
      type: 3,
      api: 'spider-local:search-cancel',
      searchable: true,
      ext: jsonEncode({'base': base}),
    );
  }

  SidecarRuntime runtime({bool gateInit = false}) => SidecarRuntime(
    site: site,
    spider: spider,
    command: command(gateInit: gateInit),
    supervisor: supervisor,
    log: log,
  );

  Future<SpiderHost> host({bool actualHost = false}) {
    final launch = actualHost
        ? LocalSpiderCommand.resolve(
            spider: spider,
            hostPath: p.join(
              repositoryRoot.path,
              'sidecars',
              'spider-host-python',
              'host.py',
            ),
          )!
        : command();
    return supervisor.ensureRunning(
      siteKey: site.key,
      executable: launch.executable,
      arguments: launch.arguments,
      manifest: spider.manifest,
      extend: jsonEncode({'base': base}),
    );
  }

  Future<void> until(bool Function() predicate) async {
    if (predicate()) return;
    await _changes.stream
        .firstWhere((_) => predicate())
        .timeout(searchCancelBound);
  }

  Future<Map<String, dynamic>> searchFrame(String keyword) async {
    bool matches(Map<String, dynamic> frame) =>
        frame['method'] == 'search' &&
        (frame['params'] as Map)['keyword'] == keyword;
    await until(() => frames.any(matches));
    final frame = frames.firstWhere(matches);
    await until(() => gates.containsKey(frame['id']));
    return frame;
  }

  Future<void> reply(String id, {String title = 'survivor'}) async {
    await until(() => gates.containsKey(id));
    final request = gates.remove(id)!;
    request.response.write(
      jsonEncode({
        'list': [
          {'vod_id': id, 'vod_name': title},
        ],
      }),
    );
    await request.response.close();
  }

  Future<void> close() async {
    for (final id in gates.keys.toList()) {
      await reply(id);
    }
    await supervisor.shutdownAll().timeout(searchCancelBound);
    await server.close(force: true);
    await _changes.close();
    await root.delete(recursive: true);
  }
}
