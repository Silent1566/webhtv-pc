import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/ipc_protocol.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/services/spider_router.dart';
import 'package:webhtv_pc/services/spider_process.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/csp_jar_probe.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/spider_registry.dart';
import 'package:webhtv_pc/state/app_state.dart';

class _NoHomeState extends AppState {
  _NoHomeState(AppPaths paths)
    : super(
        paths: paths,
        log: LogService(),
        httpClient: MockClient((_) async => http.Response('', 404)),
      ) {
    debugCspProbeOverride = (_) async => const CspProbeReport();
  }

  @override
  Future<void> loadHome(Site site) async {}
}

class _ObservedLocal extends LocalSpider {
  _ObservedLocal(String root, String key, this.port)
    : super(
        manifest: SpiderManifest(
          key: key,
          name: key,
          runtime: 'jvm',
          entry: 'entry.jar',
          capabilities: const ['home', 'category', 'detail', 'search', 'play'],
        ),
        manifestPath: p.join(root, key, 'manifest.json'),
        rootDir: root,
        entryPath: p.join(root, 'entry.jar'),
      );

  final SendPort port;

  @override
  bool get entryExists {
    port.send((key, Isolate.current.hashCode));
    return super.entryExists;
  }
}

void main() {
  test('cached restore availability yields before probing and shares runtime work', () async {
    final temp = await Directory.systemTemp.createTemp('startup-runtime-');
    final paths = AppPaths.resolve(
      overrides: {
        'config': temp.path,
        'data': temp.path,
        'cache': p.join(temp.path, 'cache'),
        'state': p.join(temp.path, 'logs'),
      },
    );
    final seed = _NoHomeState(paths);
    var seedDisposed = false;
    _NoHomeState? restored;
    try {
      await seed.bootstrap();
      final sites = <Map<String, Object?>>[];
      for (var i = 0; i < 6; i++) {
        final key = 'cached-$i';
        final dir = Directory(p.join(temp.path, 'spiders', key))
          ..createSync(recursive: true);
        File(p.join(dir.path, 'spider.py')).writeAsStringSync('pass');
        File(p.join(dir.path, 'manifest.json')).writeAsStringSync(
          jsonEncode(
            SpiderManifest(
              key: key,
              name: key,
              runtime: 'python',
              entry: 'spider.py',
              capabilities: const [
                'home',
                'category',
                'detail',
                'search',
                'play',
              ],
            ).toJson(),
          ),
        );
        sites.add({
          'key': key,
          'name': key,
          'type': 3,
          'api': 'spider-local:$key',
        });
      }
      const shellUrl = 'https://example.test/pending-shell.jar';
      sites.add({
        'key': 'pending-shell',
        'name': 'pending-shell',
        'type': 3,
        'api': 'csp_Demo',
        'jar': shellUrl,
      });
      expect(await seed.importConfig(jsonEncode({'sites': sites})), isTrue);
      final shellDir = Directory(seed.cspDirectoryFor('pending-shell'))
        ..createSync(recursive: true);
      File(p.join(shellDir.path, 'probe.json')).writeAsStringSync(
        jsonEncode({
          'siteKey': 'pending-shell',
          'sourceUrl': shellUrl,
          'sourceApi': 'csp_Demo',
          'verdict': 'shellGuard',
          'outcome': 'needsShellRuntime',
          'summary': 'pending explicit unpack',
          'semanticsVersion': CspJarProbe.probeSemanticsVersion,
        }),
      );
      seed.dispose();
      seedDisposed = true;
      restored = _NoHomeState(paths);
      await restored.bootstrap();
      expect(restored.selectedSite?.key, 'cached-0');
      final marker = File(p.join(temp.path, 'probe-count.txt'));
      final shell = p.join(
        Platform.environment['SystemRoot'] ?? r'C:\Windows',
        'System32',
        'WindowsPowerShell',
        'v1.0',
        'powershell.exe',
      );
      final escaped = marker.path.replaceAll("'", "''");
      LocalSpiderCommand.preferPythonExecutable(
        shell,
        arguments: [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "Add-Content -LiteralPath '$escaped' -Value probe; Write-Output 'Python 3.13.0'",
        ],
      );
      final clock = Stopwatch()..start();
      final event = Completer<int>();
      Timer.run(() => event.complete(clock.elapsedMilliseconds));
      final items = restored.siteItems;
      final repeated = restored.siteItems;
      expect(items, hasLength(7));
      expect(repeated, hasLength(7));
      final eventMs = await event.future;
      // ignore: avoid_print
      print('availability event-loop delay=${eventMs}ms');
      expect(
        marker.existsSync(),
        isFalse,
        reason: 'availability must return to the event loop before a real subprocess probe runs',
      );
      final ready = Completer<void>();
      void check() {
        if (restored!.siteItems
                .where((item) => item.site.key != 'pending-shell')
                .every((item) => item.availability.available) &&
            !ready.isCompleted) {
          ready.complete();
        }
      }

      restored.addListener(check);
      check();
      await ready.future.timeout(const Duration(seconds: 15));
      restored.removeListener(check);
      expect(await marker.readAsLines(), [
        'probe',
      ], reason: 'one runtime probe for six sites');
      await restored.shellTargetsProbe;
      expect(restored.shellUnpackItems().single.jarUrl, shellUrl);
      expect(restored.pendingShellUnpackPrompt, isNull);
      expect(restored.siteItems.last.availability.available, isFalse);
    } finally {
      if (!seedDisposed) seed.dispose();
      restored?.dispose();
      if (restored != null) await restored.pythonEnvironmentIdle;
      LocalSpiderCommand.preferPythonExecutable(null, verified: true);
      LogService.logDirectoryOverride = null;
      await temp.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);

  test('configuration expansion during preflight prepares added sites without foreground load', () async {
    final temp = await Directory.systemTemp.createTemp('startup-expanded-');
    final state = _NoHomeState(
      AppPaths.resolve(
        overrides: {
          'config': temp.path,
          'data': temp.path,
          'cache': p.join(temp.path, 'cache'),
          'state': p.join(temp.path, 'logs'),
        },
      ),
    );
    try {
      await state.bootstrap();
      expect(
        await state.importConfig(
          jsonEncode({
            'sites': [
              {
                'key': 'original',
                'name': 'original',
                'type': 3,
                'api': 'spider-local:missing-original',
              },
            ],
          }),
        ),
        isTrue,
      );
      expect(
        await state.addInjectedSites(
          jsonEncode({
            'key': 'original',
            'name': 'original',
            'type': 3,
            'api': 'spider-local:missing-original',
          }),
        ),
        1,
      );
      expect(state.siteItems, hasLength(1));
      expect(
        await state.addInjectedSites(
          jsonEncode({
            'key': 'added',
            'name': 'added',
            'type': 3,
            'api': 'spider-local:missing-added',
          }),
        ),
        1,
      );
      final checking = state.siteItems;
      expect(checking, hasLength(2));
      final refreshed = Completer<void>();
      void onStateChanged() {
        final added = state.siteItems.last;
        if (!refreshed.isCompleted &&
            (added.availability.reason ?? '').contains('manifest 未注册')) {
          refreshed.complete();
        }
      }

      state.addListener(onStateChanged);
      try {
        await refreshed.future.timeout(const Duration(seconds: 3));
        expect(state.siteItems.last.availability.available, isFalse);
        expect(identical(state.siteItems, checking), isFalse);
      } finally {
        state.removeListener(onStateChanged);
      }
    } finally {
      state.dispose();
      await state.pythonEnvironmentIdle;
      LogService.logDirectoryOverride = null;
      await temp.delete(recursive: true);
    }
  });

  test('prepared commands survive runtime creation, missing runtime and stale completion', () async {
    final temp = await Directory.systemTemp.createTemp('startup-command-');
    final host = File(p.join(temp.path, 'host.py'))..writeAsStringSync('pass');
    final entry = File(p.join(temp.path, 'spider.py'))
      ..writeAsStringSync('pass');
    final local = LocalSpider(
      manifest: SpiderManifest(
        key: 'local',
        name: 'local',
        runtime: 'python',
        entry: 'spider.py',
        capabilities: const ['home', 'category', 'detail', 'search', 'play'],
      ),
      manifestPath: p.join(temp.path, 'manifest.json'),
      rootDir: temp.path,
      entryPath: entry.path,
    );
    final registry = SpiderManifestRegistry(
      root: temp.path,
      log: LogService(),
      initialSpiders: [local],
    );
    final supervisor = SpiderHostSupervisor(
      workRoot: p.join(temp.path, 'work'),
      log: LogService(),
    );
    final router = SpiderRouter(
      client: HttpApiClient(),
      globalHeaders: const [],
      registry: registry,
      supervisor: supervisor,
      hostPath: host.path,
    );
    final site = Site(
      key: 'local',
      name: 'local',
      type: 3,
      api: 'spider-local:local',
    );
    try {
      LocalSpiderCommand.preferPythonExecutable(
        'verified-python',
        verified: true,
      );
      await Future.wait([
        router.prepareAvailability([site]),
        router.prepareAvailability([site]),
      ]);
      expect(router.preparedAvailability(site)?.available, isTrue);
      expect(router.runtimeFor(site), isNot(isA<UnsupportedRuntime>()));
      LocalSpiderCommand.preferPythonExecutable(null, verified: true);
      router.invalidateRuntimes();
      await router.prepareAvailability([site]);
      expect(router.preparedAvailability(site)?.available, isFalse);
      expect(router.preparedAvailability(site)?.reason, contains('未安装'));
      router.invalidateRuntimes();
      final pending = router.prepareAvailability([site]);
      router.invalidateRuntimes();
      await pending;
      expect(
        router.preparedAvailability(site)?.available,
        isFalse,
        reason: 'preflight must finish with the current generation, even when missing',
      );
      router.invalidateRuntimes();
      final runtimeChanged = router.prepareAvailability([site]);
      LocalSpiderCommand.preferPythonExecutable(
        'new-verified-python',
        verified: true,
      );
      await runtimeChanged;
      expect(
        router.preparedAvailability(site)?.available,
        isTrue,
        reason: 'an in-flight Python generation change must be prepared before returning',
      );
      router.invalidateRuntimes();
      final disposed = router.prepareAvailability([site]);
      router.dispose();
      await disposed;
      expect(router.preparedAvailability(site), isNull);
    } finally {
      router.dispose();
      await router.availabilityIdle;
      await supervisor.shutdownAll();
      LocalSpiderCommand.preferPythonExecutable(null, verified: true);
      await temp.delete(recursive: true);
    }
  });

  test('stale JVM preflight never falls back on caller and shares concurrent site work', () async {
    final temp = await Directory.systemTemp.createTemp('startup-stale-jvm-');
    final events = ReceivePort();
    final observed = <(String, int)>[];
    final subscription = events.listen(
      (value) => observed.add(value as (String, int)),
    );
    File(p.join(temp.path, 'entry.jar')).writeAsBytesSync([1]);
    final first = _ObservedLocal(temp.path, 'first', events.sendPort);
    final second = _ObservedLocal(temp.path, 'second', events.sendPort);
    final router = SpiderRouter(
      client: HttpApiClient(),
      globalHeaders: const [],
      registry: SpiderManifestRegistry(
        root: temp.path,
        log: LogService(),
        initialSpiders: [first, second],
      ),
      jvmHostPath: p.join(temp.path, 'missing-host.jar'),
    );
    final site = Site(
      key: 'first',
      name: 'first',
      type: 3,
      api: 'spider-local:first',
    );
    final other = Site(
      key: 'second',
      name: 'second',
      type: 3,
      api: 'spider-local:second',
    );
    try {
      final pending = router.prepareAvailability([site]);
      router.invalidateRuntimes();
      await pending;
      router.runtimeFor(site);
      await Future<void>.delayed(Duration.zero);
      final caller = Isolate.current.hashCode;
      final callerReads = observed.where((event) => event.$2 == caller).length;
      // ignore: avoid_print
      print('stale JVM foreground classification reads=$callerReads');
      expect(
        callerReads,
        0,
        reason: 'awaited preflight must not allow runtimeFor to synchronously classify on the UI isolate',
      );
      expect(router.preparedAvailability(site)?.available, isFalse);
      expect(router.preparedAvailability(site)?.reason, contains('未安装'));
      expect(
        observed.where((event) => event.$1 == 'first'),
        hasLength(1),
        reason: 'obsolete generation exits after shared command prep, before any stale entry scan',
      );
      router.invalidateRuntimes();
      observed.clear();
      await Future.wait([
        router.prepareAvailability([site]),
        router.prepareAvailability([site]),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(
        observed.where((event) => event.$1 == 'first'),
        hasLength(1),
        reason: 'same-generation concurrent callers share the real classification scan',
      );
      await router.prepareAvailability([other]);
      expect(router.preparedAvailability(site), isNotNull);
      expect(
        router.preparedAvailability(other),
        isNotNull,
        reason: 'preflight covers the actual requested sites, not just a matching generation',
      );
    } finally {
      router.dispose();
      await router.availabilityIdle;
      await subscription.cancel();
      events.close();
      await temp.delete(recursive: true);
    }
  });

  test('shell discovery scans off the caller isolate and preserves grouped targets', () async {
    final temp = await Directory.systemTemp.createTemp('startup-shell-');
    final messages = ReceivePort();
    try {
      final binding = CspJvmBinding(root: p.join(temp.path, 'csp'));
      final sites = [
        for (var i = 0; i < 8; i++)
          Site(key: 'shell-$i', name: 'shell-$i', type: 3, api: 'csp_Demo'),
      ];
      for (final site in sites) {
        final dir = Directory(binding.directoryFor(site.key))
          ..createSync(recursive: true);
        File(p.join(dir.path, 'probe.json')).writeAsStringSync(
          jsonEncode({
            'sourceUrl': 'https://example.test/shell.jar',
            'verdict': 'shellGuard',
            'outcome': 'needsShellRuntime',
            'semanticsVersion': CspJarProbe.probeSemanticsVersion,
          }),
        );
      }
      final caller = Isolate.current.hashCode;
      final port = messages.sendPort;
      final probe = CspJarProbe(
        root: temp.path,
        binding: binding,
        shellRuntimeInstalled: () {
          port.send(Isolate.current.hashCode);
          return false;
        },
      );
      final targets = await probe.discoverShellTargets(
        AppConfig(spider: 'https://example.test/shell.jar', sites: sites),
      );
      final scannedOn = await messages.first;
      expect(
        scannedOn,
        isNot(caller),
        reason: 'shell filesystem/JAR scan belongs off the UI isolate',
      );
      expect(targets.single.siteKeys, hasLength(8));
      expect(targets.single.state, ShellTargetState.needsRuntime);
    } finally {
      messages.close();
      await temp.delete(recursive: true);
    }
  });
}
