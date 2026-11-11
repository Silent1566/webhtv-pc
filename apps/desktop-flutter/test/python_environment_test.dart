import 'dart:convert';
import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/following.dart';
import 'package:webhtv_pc/services/node_runtime.dart';

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/python_environment.dart';
import 'package:webhtv_pc/services/spider_process.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/services/app_paths.dart';

import 'local_catvod_runtime_test.dart' show availablePython;

AppPaths isolatedPaths(Directory root) => AppPaths.resolve(
  overrides: {
    'config': p.join(root.path, 'config'),
    'data': p.join(root.path, 'data'),
    'cache': p.join(root.path, 'cache'),
    'state': p.join(root.path, 'logs'),
  },
);
String fixtureBundle(
  Directory root, {
  String path = 'python.exe',
  bool link = false,
  bool wrongHash = false,
  bool wrongSize = false,
  bool badZip = false,
}) {
  final dir = Directory(p.join(root.path, 'install', 'runtime', 'python'))
    ..createSync(recursive: true);
  final bytes = utf8.encode('fixture executable');
  final file = ArchiveFile(path, bytes.length, bytes);
  if (link) {
    file.mode = 0xa1ff;
    file.symbolicLink = '../outside';
  }
  final zip = badZip ? [1, 2, 3] : ZipEncoder().encode(Archive()..add(file));
  File(p.join(dir.path, 'python-runtime.zip')).writeAsBytesSync(zip);
  File(p.join(dir.path, 'bundle.json')).writeAsStringSync(
    jsonEncode({
      'schemaVersion': 1,
      'pythonVersion': '3.13.17',
      'platform': 'windows-x64',
      'archive': 'python-runtime.zip',
      'archiveSha256': sha256.convert(zip).toString(),
      'probeModules': ['requests', 'Crypto', 'lxml', 'bs4'],
      'packages': [
        {'name': 'requests', 'version': '2.32.0'},
      ],
      'files': [
        {
          'path': path,
          'size': wrongSize ? bytes.length + 1 : bytes.length,
          'sha256': wrongHash ? '0' * 64 : sha256.convert(bytes).toString(),
        },
      ],
    }),
  );
  return dir.path;
}

PythonEnvironmentStatus fixtureProbe(
  String executable,
  List<String> args,
  PythonEnvironmentSource source,
  Map<String, String>? environment,
) => PythonEnvironmentStatus(
  executable: executable,
  version: '3.13.17',
  source: source,
  dependencies: const {
    'requests': true,
    'Crypto': true,
    'lxml': true,
    'bs4': true,
  },
);

class PendingPythonEnvironment extends PythonEnvironment {
  PendingPythonEnvironment(AppPaths paths, {this.releaseStatus})
    : super(paths: paths);
  @override
  Future<void> get idle => gate.future;
  final PythonEnvironmentStatus? releaseStatus;
  final gate = Completer<void>();
  final started = Completer<void>();
  @override
  Future<void> refresh() async {
    busy = true;
    if (!started.isCompleted) started.complete();
    await gate.future;
    status =
        releaseStatus ??
        const PythonEnvironmentStatus(error: 'controlled missing runtime');
    busy = false;
  }
}

Future<AppState> pendingState(
  Directory root,
  PendingPythonEnvironment env, {
  Future<http.Response> Function(http.Request)? responder,
  String source =
      'class Spider:\n def homeContent(self, filter):\n  return {"list":[]}\n',
}) async {
  final state = AppState(
    paths: env.paths,
    pythonEnvironment: env,
    httpClient: MockClient(
      responder ??
          (request) async => http.Response(
            '{"list":[{"vod_id":"new","vod_name":"new"}]}',
            200,
            headers: {'content-type': 'application/json'},
          ),
    ),
  );
  await state.bootstrap();
  await state.importConfig(
    '{"sites":[{"key":"old-site","name":"old","type":3,"api":"spider-local:local"},{"key":"new-site","name":"new","type":1,"api":"http://unused.invalid/api"}]}',
  );
  final sources = Directory(p.join(root.path, 'sources'))..createSync();
  File(p.join(sources.path, 'local.py')).writeAsStringSync(source);
  final scan = await state.scanLocalSources(sources.path);
  await state.importLocalSources(scan.candidates);
  await env.started.future;
  return state;
}

void main() {
  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('python_environment_');
  });
  tearDown(() => root.deleteSync(recursive: true));
  test(
    'final normal HTTP home still loads its own first category automatically',
    () async {
      final requests = <Uri>[];
      final state = AppState(
        paths: isolatedPaths(root),
        httpClient: MockClient((request) async {
          requests.add(request.url);
          return http.Response(
            request.url.queryParameters.containsKey('t')
                ? '{"list":[{"vod_id":"B-category","vod_name":"B-category"}]}'
                : '{"class":[{"type_id":"B-type","type_name":"B"}],"list":[]}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(() async {
        state.dispose();
        await state.pythonEnvironmentIdle;
      });
      await state.bootstrap();
      await state.importConfig(
        '{"sites":[{"key":"b","name":"B","type":1,"api":"http://unused.invalid/api"}]}',
      );
      requests.clear();
      await state.loadHome(state.selectedSite!);
      expect(state.homeResult!.classes.single.typeId, 'B-type');
      expect(state.selectedTypeId, 'B-type');
      expect(state.categoryResult!.list.single.vodId, 'B-category');
      expect(
        requests.where((uri) => uri.queryParameters['t'] == 'B-type'),
        hasLength(1),
      );
      expect(state.lastError, isNull);
    },
  );
  test(
    'final N3 pointer recovery preserves a pre-existing backup collision too',
    () async {
      final env = PythonEnvironment(
        paths: isolatedPaths(root),
        bundleDirectory: fixtureBundle(root),
        probe: fixtureProbe,
        systemCandidates: const [],
        clock: () => DateTime.fromMicrosecondsSinceEpoch(12345),
      );
      expect(await env.repair(), isTrue);
      final pointer = File(
        p.join(env.paths.dataDir, 'runtime', 'python', 'active.json'),
      )..writeAsStringSync('{broken pointer');
      final existing = File('${pointer.path}.invalid-12345')
        ..writeAsStringSync('earlier pointer backup');
      await env.refresh();
      expect(env.error, isNotNull);
      expect(await env.repair(), isTrue, reason: env.error);
      expect(existing.readAsStringSync(), 'earlier pointer backup');
      expect(
        pointer.parent
            .listSync()
            .whereType<File>()
            .where((file) => file.path.contains('.invalid-'))
            .any((file) => file.readAsStringSync() == '{broken pointer'),
        isTrue,
      );
    },
  );
  test(
    'final N3 metadata recovery cannot overwrite pre-existing invalid backup',
    () async {
      final paths = isolatedPaths(root);
      final env = PythonEnvironment(
        paths: paths,
        bundleDirectory: fixtureBundle(root),
        probe: fixtureProbe,
        systemCandidates: const [],
        clock: () => DateTime.fromMicrosecondsSinceEpoch(12345),
      );
      final custom = File(p.join(root.path, 'custom.exe'))
        ..writeAsStringSync('owned');
      final prefs = File(p.join(paths.configDir, 'python-environment.json'))
        ..parent.createSync(recursive: true);
      prefs.writeAsStringSync('{corrupt original');
      final collision = File('${prefs.path}.invalid-12345')
        ..writeAsStringSync('existing backup bytes');
      await env.refresh();
      expect(env.error, isNotNull);
      expect(await env.setCustom(custom.path), isTrue, reason: env.error);
      expect(collision.readAsStringSync(), 'existing backup bytes');
      final backups = prefs.parent
          .listSync()
          .whereType<File>()
          .where((file) => file.path.contains('.invalid-'))
          .toList();
      expect(
        backups.any((file) => file.readAsStringSync() == '{corrupt original'),
        isTrue,
      );
      expect(jsonDecode(prefs.readAsStringSync()), {'custom': custom.path});
    },
  );
  test('final N1 old Python home cannot replace HTTP home or send its class to HTTP site', () async {
    var python = availablePython();
    PythonEnvironmentStatus? realStatus;
    if (python == null) {
      final prepared = PythonEnvironment(
        paths: isolatedPaths(root),
        systemCandidates: const [],
      );
      expect(await prepared.repair(), isTrue, reason: prepared.error);
      python = prepared.status!.executable;
      realStatus = prepared.status;
    }
    final env = PendingPythonEnvironment(
      isolatedPaths(root),
      releaseStatus:
          realStatus ??
          fixtureProbe(python, const [], PythonEnvironmentSource.custom, null),
    );
    final requests = <Uri>[];
    final state = await pendingState(
      root,
      env,
      source: 'class Spider:\n def homeContent(self, filter):\n  return {"class":[{"type_id":"A-type","type_name":"A"}],"list":[]}\n',
      responder: (request) async {
        requests.add(request.url);
        return http.Response(
          '{"list":[{"vod_id":"B","vod_name":"B"}]}',
          200,
          headers: {'content-type': 'application/json'},
        );
      },
    );
    addTearDown(() async {
      if (!env.gate.isCompleted) env.gate.complete();
      await state.stopSpider('local');
      state.dispose();
      await state.pythonEnvironmentIdle;
    });
    final old = state.siteItems
        .firstWhere((i) => i.site.key == 'old-site')
        .site;
    final b = state.siteItems.firstWhere((i) => i.site.key == 'new-site').site;
    final pending = state.loadHome(old);
    await state.selectSite(b);
    expect(state.homeResult!.list.single.vodId, 'B');
    env.gate.complete();
    await pending;
    expect(
      requests.where((uri) => uri.queryParameters['t'] == 'A-type'),
      isEmpty,
    );
    expect(state.homeResult!.list.single.vodId, 'B');
    expect(state.selectedTypeId, isNull);
    expect(state.lastError, isNull);
  }, timeout: const Timeout(Duration(minutes: 3)));
  test('final N2 false launcher switch and async discovery never invoke synchronous enumeration', () async {
    var syncCalls = 0;
    var asyncCalls = 0;
    ProcessResult syncRunner(String executable, List<String> arguments) {
      syncCalls++;
      return ProcessResult(0, 0, '', '');
    }

    SidecarRuntimeResolver.pythonCandidates(
      queryLauncher: false,
      launcherExecutable: 'fake-py',
      synchronousLauncherRunner: syncRunner,
    );
    expect(syncCalls, 0);
    await SidecarRuntimeResolver.pythonCandidatesAsync(
      launcherExecutable: 'fake-py',
      synchronousLauncherRunner: syncRunner,
      launcherRunner: (exe, args) async {
        asyncCalls++;
        return ProcessResult(0, 0, '', '');
      },
    );
    expect(syncCalls, 0);
    expect(asyncCalls, 1);
    SidecarRuntimeResolver.pythonCandidates(
      queryLauncher: true,
      launcherExecutable: 'fake-py',
      synchronousLauncherRunner: syncRunner,
    );
    expect(syncCalls, 1);
  });
  test(
    'review timed-out launcher cannot strand manager operation gate',
    () async {
      final env = PythonEnvironment(
        paths: isolatedPaths(root),
        bundleDirectory: p.join(root.path, 'missing-bundle'),
        probe: fixtureProbe,
        launcherRunner: (exe, args) => Completer<ProcessResult>().future,
        launcherTimeout: const Duration(milliseconds: 10),
      );
      await env.refresh().timeout(const Duration(seconds: 2));
      await env.idle;
      expect(env.busy, isFalse);
      final custom = File(p.join(root.path, 'selected.exe'))
        ..writeAsStringSync('selected');
      expect(await env.setCustom(custom.path), isTrue, reason: env.error);
    },
  );
  test('review idle Future remains pending until preparation finishes even after dispose', () async {
    final env = PendingPythonEnvironment(isolatedPaths(root));
    final state = AppState(paths: env.paths, pythonEnvironment: env);
    final pending = state.refreshPythonEnvironment();
    await env.started.future;
    var finished = false;
    final idle = state.pythonEnvironmentIdle.then((_) => finished = true);
    state.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    env.gate.complete();
    await pending;
    await idle;
    expect(finished, isTrue);
  });
  test(
    'review non-Python host.py argument does not acquire a Python lease',
    () async {
      final env = PythonEnvironment(
        paths: isolatedPaths(root),
        bundleDirectory: fixtureBundle(root),
        probe: fixtureProbe,
        systemCandidates: const [],
      );
      final node = NodeRuntimeResolver.resolve()!;
      final process = await SidecarProcess.start(
        SidecarLaunchSpec(
          siteKey: 'node-argument',
          executable: node.executable,
          arguments: const ['-e', 'process.stdin.resume()', 'host.py'],
          workingDirectory: p.join(root.path, 'work'),
          logFile: p.join(root.path, 'node.log'),
        ),
      );
      try {
        expect(await env.repair(), isTrue, reason: env.error);
        expect(process.isRunning, isTrue);
      } finally {
        await process.killTree();
        await process.done;
      }
    },
  );
  test('review launcher enumeration is bounded even when injected command never completes', () async {
    final candidates = await SidecarRuntimeResolver.pythonCandidatesAsync(
      launcherExecutable: 'fake-py',
      pathCandidates: const [],
      launcherRunner: (exe, args) => Completer<ProcessResult>().future,
      launcherTimeout: const Duration(milliseconds: 10),
    ).timeout(const Duration(milliseconds: 200));
    expect(candidates, isEmpty);
  });
  test(
    'review disposed swapProbe cannot dispatch after pending preparation',
    () async {
      final env = PendingPythonEnvironment(isolatedPaths(root));
      final state = await pendingState(root, env);
      final pending = state.swapProbe(siteKey: 'old-site', vodId: 'old');
      state.dispose();
      env.gate.complete();
      expect(await pending, isEmpty);
    },
  );
  test('review historical Python playback waits readiness in otherwise non-Python context', () async {
    final env = PendingPythonEnvironment(isolatedPaths(root));
    final state = await pendingState(root, env);
    addTearDown(state.dispose);
    state.database!.saveConfig(
      name: 'history',
      origin: 'fixture-history.json',
      sourceKey: 'history-source',
      makeActive: false,
      json: {
        'sites': [
          {
            'key': 'history-site',
            'name': 'history',
            'type': 3,
            'api': 'spider-local:local',
          },
        ],
      },
    );
    var completed = false;
    final pending = state
        .resolvePlaybackForSource(
          sourceKey: 'history-source',
          siteKey: 'history-site',
          episodeTarget: 'opaque-episode',
          flag: 'line',
          vodId: 'old',
        )
        .then(
          (value) {
            completed = true;
            return value;
          },
          onError: (Object e) {
            completed = true;
            return null;
          },
        );
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    env.gate.complete();
    await pending;
  });
  test('review following Python detail waits readiness', () async {
    final env = PendingPythonEnvironment(isolatedPaths(root));
    final state = await pendingState(root, env);
    addTearDown(state.dispose);
    final item = Following(
      seriesKey: 'series',
      season: 0,
      siteKey: 'old-site',
      vodId: 'old',
      vodName: 'old',
      flag: 'line',
      sourceFlag: 'line',
      trackedSeason: 0,
      latestReleasedSeason: 0,
      latestReleasedEpisode: 0,
      seasonReleasedEpisodes: 0,
      watchedEpisode: 0,
      readWatermarkEpisode: 0,
      lastNotifiedEpisode: 0,
      status: FollowingStatus.returning,
      createdAtMs: 1,
      updatedAtMs: 1,
    );
    state.database!.upsertFollowing(item);
    var completed = false;
    final pending = state.checkFollowing(item).then((value) {
      completed = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    env.gate.complete();
    await pending;
  });
  for (final kind in ['json', 'map', 'read']) {
    test(
      'review corrupt pointer $kind refresh reports then repair preserves bytes and recovers',
      () async {
        final env = PythonEnvironment(
          paths: isolatedPaths(root),
          bundleDirectory: fixtureBundle(root),
          probe: fixtureProbe,
          systemCandidates: const [],
        );
        expect(await env.repair(), isTrue);
        final old = env.status!.executable;
        final pointer = File(
          p.join(env.paths.dataDir, 'runtime', 'python', 'active.json'),
        );
        if (kind != 'read') {
          pointer.writeAsStringSync(kind == 'json' ? '{bad' : '[]');
        }
        final original = pointer.readAsBytesSync();
        final identity = Platform.environment['USERNAME']!;
        if (kind == 'read') {
          expect(
            Process.runSync('icacls', [
              pointer.path,
              '/deny',
              '$identity:(RD)',
            ]).exitCode,
            0,
          );
        }
        try {
          await env.refresh();
          expect(env.error, isNotNull);
          expect(await env.repair(), isTrue, reason: env.error);
        } finally {
          if (kind == 'read') {
            Process.runSync('icacls', [
              pointer.parent.path,
              '/remove:d',
              identity,
              '/t',
            ]);
          }
        }
        expect(File(old).existsSync(), isTrue);
        expect(jsonDecode(pointer.readAsStringSync()), isA<Map>());
        final backups = pointer.parent
            .listSync()
            .whereType<File>()
            .where((f) => f.path.contains('.invalid-'))
            .toList();
        expect(backups, isNotEmpty);
        expect(backups.last.readAsBytesSync(), original);
      },
    );
    test(
      'review corrupt preference $kind does not permanently block explicit custom or default',
      () async {
        final env = PythonEnvironment(
          paths: isolatedPaths(root),
          bundleDirectory: fixtureBundle(root),
          probe: fixtureProbe,
          systemCandidates: const [],
        );
        expect(await env.repair(), isTrue);
        final custom = File(p.join(root.path, 'custom.exe'))
          ..writeAsStringSync('owned');
        final prefs =
            File(p.join(env.paths.configDir, 'python-environment.json'))
              ..parent.createSync(recursive: true)
              ..writeAsStringSync(
                kind == 'json'
                    ? '{bad'
                    : kind == 'map'
                    ? '[]'
                    : '{}',
              );
        final original = prefs.readAsBytesSync();
        final identity = Platform.environment['USERNAME']!;
        if (kind == 'read') {
          expect(
            Process.runSync('icacls', [
              prefs.path,
              '/deny',
              '$identity:(RD)',
            ]).exitCode,
            0,
          );
        }
        try {
          await env.refresh();
          expect(env.error, isNotNull);
          expect(await env.setCustom(custom.path), isTrue, reason: env.error);
        } finally {
          if (kind == 'read') {
            Process.runSync('icacls', [
              prefs.parent.path,
              '/remove:d',
              identity,
              '/t',
            ]);
          }
        }
        expect(env.status!.executable, custom.path);
        final backups = prefs.parent
            .listSync()
            .whereType<File>()
            .where((f) => f.path.contains('.invalid-'))
            .toList();
        expect(backups, isNotEmpty);
        expect(backups.last.readAsBytesSync(), original);
        prefs.writeAsStringSync('{broken again');
        await env.refresh();
        expect(env.error, isNotNull);
        expect(await env.useDefault(), isTrue, reason: env.error);
        expect(env.status!.source, PythonEnvironmentSource.bundled);
        expect(custom.readAsStringSync(), 'owned');
      },
    );
  }
  test(
    'review linked bundle manifest is rejected rather than followed',
    () async {
      final bundle = fixtureBundle(root);
      final env = PythonEnvironment(
        paths: isolatedPaths(root),
        bundleDirectory: bundle,
        probe: fixtureProbe,
        systemCandidates: const [],
      );
      expect(await env.repair(), isTrue);
      final manifest = File(p.join(bundle, 'bundle.json'));
      final target = p.join(root.path, 'outside-manifest.json');
      manifest.renameSync(target);
      final bytes = File(target).readAsBytesSync();
      final link = Link(manifest.path)..createSync(target);
      try {
        expect(await env.repair(), isFalse);
        expect(env.error, contains('链接'));
      } finally {
        link.deleteSync();
      }
      expect(File(target).readAsBytesSync(), bytes);
    },
  );
  test(
    'review old pending Python detail cannot seize newer HTTP detail',
    () async {
      final env = PendingPythonEnvironment(isolatedPaths(root));
      final state = await pendingState(root, env);
      addTearDown(state.dispose);
      final old = state.siteItems
          .firstWhere((i) => i.site.key == 'old-site')
          .site;
      final newer = state.siteItems
          .firstWhere((i) => i.site.key == 'new-site')
          .site;
      final pending = state.loadDetail(
        Vod(vodId: 'old', vodName: 'old'),
        siteOverride: old,
      );
      await state.loadDetail(
        Vod(vodId: 'new', vodName: 'new'),
        siteOverride: newer,
      );
      expect(state.selectedVod!.vodId, 'new');
      env.gate.complete();
      await pending;
      expect(state.selectedVod!.vodId, 'new');
      expect(state.detailResult!.list.single.vodId, 'new');
    },
  );
  test(
    'review old pending Python category cannot seize newer site category',
    () async {
      final env = PendingPythonEnvironment(isolatedPaths(root));
      final state = await pendingState(root, env);
      addTearDown(state.dispose);
      final newer = state.siteItems
          .firstWhere((i) => i.site.key == 'new-site')
          .site;
      final pending = state.loadCategory('old-type');
      await state.selectSite(newer);
      await state.loadCategory('new-type');
      expect(state.selectedTypeId, 'new-type');
      env.gate.complete();
      await pending;
      expect(state.selectedTypeId, 'new-type');
      expect(state.categoryResult!.list.single.vodId, 'new');
    },
  );
  test('successful environment changes invalidate cached historical-source routers too', () async {
    final env = PythonEnvironment(
      paths: isolatedPaths(root),
      bundleDirectory: fixtureBundle(root),
      probe: fixtureProbe,
      systemCandidates: const [],
    );
    final state = AppState(paths: env.paths, pythonEnvironment: env);
    addTearDown(state.dispose);
    await state.bootstrap();
    state.database!.saveConfig(
      name: 'historical',
      origin: 'fixture.json',
      json: {
        'sites': [
          {
            'key': 'history',
            'name': 'history',
            'type': 1,
            'api': 'http://unused.invalid',
          },
        ],
      },
      makeActive: false,
      sourceKey: 'historical-fixture',
    );
    final context = state.playbackContextFor('historical-fixture')!;
    final site = context.config.sites.single;
    final before = context.service.router.runtimeFor(site);
    expect(await state.repairPythonEnvironment(), isTrue);
    expect(identical(before, context.service.router.runtimeFor(site)), isFalse);
  });
  test(
    'operation limits and complete archive hash are enforced before prepare',
    () async {
      final bundle = fixtureBundle(root);
      final env = PythonEnvironment(
        paths: isolatedPaths(root),
        bundleDirectory: bundle,
        probe: fixtureProbe,
        systemCandidates: const [],
      );
      expect(await env.repair(), isTrue);
      final old = env.status!.executable;
      final manifestFile = File(p.join(bundle, 'bundle.json'));
      final manifest =
          jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
      manifest['archiveSha256'] = '0' * 64;
      manifestFile.writeAsStringSync(jsonEncode(manifest));
      expect(await env.repair(), isFalse);
      expect(env.error, contains('ZIP SHA256'));
      fixtureBundle(root);
      final zip = File(p.join(bundle, 'python-runtime.zip'))
          .openSync(mode: FileMode.append);
      zip.truncateSync(64 * 1024 * 1024 + 1);
      zip.closeSync();
      expect(await env.repair(), isFalse);
      expect(env.error, contains('64MiB'));
      fixtureBundle(root);
      final oversized =
          jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
      (oversized['files'] as List).first['size'] = 128 * 1024 * 1024 + 1;
      manifestFile.writeAsStringSync(jsonEncode(oversized));
      expect(await env.repair(), isFalse);
      expect(env.error, contains('128MiB'));
      fixtureBundle(root);
      final many =
          jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
      many['files'] = List.filled(10001, {
        'path': 'python.exe',
        'size': 0,
        'sha256': '0' * 64,
      });
      manifestFile.writeAsStringSync(jsonEncode(many));
      expect(await env.repair(), isFalse);
      expect(env.error, contains('文件数'));
      expect(env.status!.executable, old);
      expect(File(old).existsSync(), isTrue);
    },
  );
  test('native junction root cannot escape software data directory', () async {
    final outside = Directory(p.join(root.path, 'outside'))..createSync();
    final marker = File(p.join(outside.path, 'marker'))
      ..writeAsStringSync('untouched');
    final paths = isolatedPaths(root);
    Directory(p.join(paths.dataDir, 'runtime')).createSync(recursive: true);
    final junction = p.join(paths.dataDir, 'runtime', 'python');
    expect(p.isWithin(root.path, junction), isTrue);
    final result = Process.runSync('cmd', [
      '/d',
      '/c',
      'mklink',
      '/J',
      junction,
      outside.path,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    try {
      final env = PythonEnvironment(
        paths: paths,
        bundleDirectory: fixtureBundle(root),
        probe: fixtureProbe,
        systemCandidates: const [],
      );
      expect(await env.repair(), isFalse);
      expect(env.error, contains('链接'));
      expect(marker.readAsStringSync(), 'untouched');
      expect(outside.listSync(), hasLength(1));
    } finally {
      expect(p.isWithin(root.path, junction), isTrue);
      final removed = Process.runSync('cmd', ['/d', '/c', 'rmdir', junction]);
      expect(removed.exitCode, 0, reason: '${removed.stdout}${removed.stderr}');
    }
  });
  test('failed config commit keeps selected custom interpreter and configuration bytes', () async {
    final env = PythonEnvironment(
      paths: isolatedPaths(root),
      bundleDirectory: fixtureBundle(root),
      probe: fixtureProbe,
      systemCandidates: const [],
    );
    final one = File(p.join(root.path, 'one.exe'))..writeAsStringSync('one');
    final two = File(p.join(root.path, 'two.exe'))..writeAsStringSync('two');
    expect(await env.setCustom(one.path), isTrue);
    final prefs = File(p.join(env.paths.configDir, 'python-environment.json'));
    final bytes = prefs.readAsBytesSync();
    final identity = Platform.environment['USERNAME']!;
    expect(p.isWithin(root.path, prefs.path), isTrue);
    expect(
      Process.runSync('icacls', [
        prefs.path,
        '/deny',
        '$identity:(DE)',
      ]).exitCode,
      0,
    );
    try {
      expect(await env.setCustom(two.path), isFalse);
      expect(env.error, contains('rename'));
      expect(env.status!.executable, one.path);
      expect(prefs.readAsBytesSync(), bytes);
      expect(one.readAsStringSync(), 'one');
      expect(two.readAsStringSync(), 'two');
    } finally {
      expect(
        Process.runSync('icacls', [prefs.path, '/remove:d', identity]).exitCode,
        0,
      );
    }
  });
  test('dispose during async prepare cannot notify dead state or strand operation gate', () async {
    final env = PythonEnvironment(
      paths: isolatedPaths(root),
      bundleDirectory: fixtureBundle(root),
      systemCandidates: const [],
      probe: (exe, args, source, environment) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return fixtureProbe(exe, args, source, environment);
      },
    );
    final state = AppState(paths: env.paths, pythonEnvironment: env);
    final pending = state.repairPythonEnvironment();
    state.dispose();
    expect(await pending, isTrue);
    expect(env.busy, isFalse);
    expect(await env.repair(), isTrue);
  });
  test('live processes reject transitions without kill and release last-user lease on exit', () async {
    final env = PythonEnvironment(
      paths: isolatedPaths(root),
      bundleDirectory: fixtureBundle(root),
      probe: fixtureProbe,
      systemCandidates: const [],
    );
    expect(await env.repair(), isTrue);
    final old = env.status!.executable;
    final executable = File(p.join(root.path, 'python.exe'));
    File(p.join(Platform.environment['SystemRoot']!, 'System32', 'cmd.exe'))
        .copySync(executable.path);
    SidecarLaunchSpec spec(String key) => SidecarLaunchSpec(
      siteKey: key,
      executable: executable.path,
      arguments: const ['/d', '/q', '/c', 'set /p ignored='],
      workingDirectory: p.join(root.path, key),
      logFile: p.join(root.path, 'logs', '$key.log'),
    );
    final one = await SidecarProcess.start(spec('one'));
    final two = await SidecarProcess.start(spec('two'));
    try {
      expect(await env.repair(), isFalse);
      expect(await env.setCustom(executable.path), isFalse);
      expect(await env.useDefault(), isFalse);
      expect(env.error, contains('正在运行'));
      expect(env.status!.executable, old);
      expect(one.isRunning && two.isRunning, isTrue);
      await one.killTree();
      await one.done;
      expect(await env.repair(), isFalse);
      expect(two.isRunning, isTrue);
    } finally {
      await one.killTree();
      await two.killTree();
      await Future.wait([one.done, two.done]);
    }
    expect(await env.repair(), isTrue);
  });
  test('concurrent start, failed launch and non-Python process do not leak or steal leases', () async {
    final env = PythonEnvironment(
      paths: isolatedPaths(root),
      bundleDirectory: fixtureBundle(root),
      probe: fixtureProbe,
      systemCandidates: const [],
    );
    final executable = File(p.join(root.path, 'python.exe'));
    final cmd = p.join(
      Platform.environment['SystemRoot']!,
      'System32',
      'cmd.exe',
    );
    File(cmd).copySync(executable.path);
    SidecarLaunchSpec spec(String key, String exe) => SidecarLaunchSpec(
      siteKey: key,
      executable: exe,
      arguments: const ['/d', '/q', '/c', 'set /p ignored='],
      workingDirectory: p.join(root.path, key),
      logFile: p.join(root.path, 'logs', '$key.log'),
    );
    final pending = env.repair();
    await expectLater(
      SidecarProcess.start(spec('blocked', executable.path)),
      throwsStateError,
    );
    expect(await pending, isTrue);
    await expectLater(
      SidecarProcess.start(
        spec('bad', p.join(root.path, 'missing', 'python.exe')),
      ),
      throwsA(isA<ProcessException>()),
    );
    expect(await env.repair(), isTrue);
    final nonPython = await SidecarProcess.start(spec('cmd', cmd));
    try {
      expect(await env.repair(), isTrue);
      expect(nonPython.isRunning, isTrue);
    } finally {
      await nonPython.killTree();
      await nonPython.done;
    }
    expect(await env.useDefault(), isTrue);
  });
  test('stage-ready and native atomic-rename failures preserve old bytes and pointer', () async {
    final bundle = fixtureBundle(root);
    final env = PythonEnvironment(
      paths: isolatedPaths(root),
      bundleDirectory: bundle,
      probe: fixtureProbe,
      systemCandidates: const [],
    );
    expect(await env.repair(), isTrue);
    final old = env.status!.executable;
    final oldBytes = File(old).readAsBytesSync();
    final failing = PythonEnvironment(
      paths: env.paths,
      bundleDirectory: bundle,
      systemCandidates: const [],
      probe: (exe, args, source, environment) => PythonEnvironmentStatus(
        executable: exe,
        error: 'stage rejected',
        source: source,
      ),
    );
    expect(await failing.repair(), isFalse);
    expect(File(old).readAsBytesSync(), oldBytes);
    final pointer = File(
      p.join(env.paths.dataDir, 'runtime', 'python', 'active.json'),
    );
    final pointerBytes = pointer.readAsBytesSync();
    final identity = Platform.environment['USERNAME']!;
    expect(p.isWithin(root.path, pointer.path), isTrue);
    final denied = Process.runSync('icacls', [
      pointer.path,
      '/deny',
      '$identity:(DE)',
    ]);
    expect(denied.exitCode, 0, reason: '${denied.stdout}${denied.stderr}');
    try {
      expect(await env.repair(), isFalse);
      expect(env.error, contains('rename'));
      expect(env.status!.executable, old);
    } finally {
      final restored = Process.runSync('icacls', [
        pointer.path,
        '/remove:d',
        identity,
      ]);
      expect(
        restored.exitCode,
        0,
        reason: '${restored.stdout}${restored.stderr}',
      );
    }
    expect(pointer.readAsBytesSync(), pointerBytes);
    expect(File(old).readAsBytesSync(), oldBytes);
  });
  test(
    'refresh with broken persisted custom does not seize bundled default',
    () async {
      final env = PythonEnvironment(
        paths: isolatedPaths(root),
        bundleDirectory: fixtureBundle(root),
        probe: fixtureProbe,
        systemCandidates: const [],
      );
      expect(await env.repair(), isTrue);
      final custom = File(p.join(root.path, 'custom.exe'))
        ..writeAsStringSync('custom');
      expect(await env.setCustom(custom.path), isTrue);
      final config = File(
        p.join(env.paths.configDir, 'python-environment.json'),
      );
      final saved = config.readAsStringSync();
      custom.deleteSync();
      final restart = PythonEnvironment(
        paths: env.paths,
        bundleDirectory: env.bundleDirectory,
        systemCandidates: const [],
      );
      await restart.refresh();
      expect(restart.status!.source, PythonEnvironmentSource.custom);
      expect(restart.status!.ready, isFalse);
      expect(config.readAsStringSync(), saved);
    },
  );
  test('public status and six settings interfaces are statically callable', () {
    final state = AppState(paths: isolatedPaths(root));
    addTearDown(state.dispose);
    expect(state.pythonEnvironmentStatus, isNull);
    expect(state.pythonEnvironmentBusy, isFalse);
    expect(state.pythonEnvironmentError, isNull);
    final Future<void> Function() refresh = state.refreshPythonEnvironment;
    final Future<bool> Function() repair = state.repairPythonEnvironment;
    final Future<bool> Function(String) custom =
        state.setCustomPythonExecutable;
    final Future<bool> Function() defaults = state.useDefaultPythonEnvironment;
    expect([refresh, repair, custom, defaults], hasLength(4));
    expect(const PythonEnvironmentStatus().ready, isFalse);
    expect(
      const PythonEnvironmentStatus(
        executable: 'x',
        version: '3',
        source: PythonEnvironmentSource.custom,
      ).ready,
      isFalse,
    );
  });
  test(
    'offline bundle prepared in dataDir and cache removal preserves it',
    () async {
      final env = PythonEnvironment(
        paths: isolatedPaths(root),
        bundleDirectory: fixtureBundle(root),
        probe: fixtureProbe,
        systemCandidates: const [],
      );
      expect(await env.repair(), isTrue);
      final exe = env.status!.executable;
      expect(env.status!.ready, isTrue);
      expect(p.isWithin(env.paths.dataDir, exe), isTrue);
      Directory(env.paths.cacheDir).createSync(recursive: true);
      Directory(env.paths.cacheDir).deleteSync(recursive: true);
      expect(File(exe).existsSync(), isTrue);
      await env.refresh();
      expect(env.status!.executable, exe);
    },
  );
  for (final kind in [
    'hash',
    'size',
    'zip',
    'path',
    'absolute',
    'reserved',
    'link',
  ]) {
    test(
      'invalid $kind bundle preserves valid old runtime and root boundaries',
      () async {
        final bundle = fixtureBundle(root);
        final env = PythonEnvironment(
          paths: isolatedPaths(root),
          bundleDirectory: bundle,
          probe: fixtureProbe,
          systemCandidates: const [],
        );
        expect(await env.repair(), isTrue);
        final old = env.status!.executable;
        fixtureBundle(
          root,
          wrongHash: kind == 'hash',
          wrongSize: kind == 'size',
          badZip: kind == 'zip',
          path: kind == 'path'
              ? '../outside'
              : kind == 'absolute'
              ? 'C:/outside'
              : kind == 'reserved'
              ? 'CON.txt'
              : 'python.exe',
          link: kind == 'link',
        );
        expect(await env.repair(), isFalse);
        expect(env.error, isNotNull);
        expect(env.status!.executable, old);
        expect(File(old).existsSync(), isTrue);
        expect(File(p.join(root.path, 'outside')).existsSync(), isFalse);
      },
    );
  }
  test(
    'custom persistence, invalid choice rollback and default restore',
    () async {
      final bundle = fixtureBundle(root);
      final env = PythonEnvironment(
        paths: isolatedPaths(root),
        bundleDirectory: bundle,
        probe: fixtureProbe,
        systemCandidates: const [],
      );
      expect(await env.repair(), isTrue);
      final custom = File(p.join(root.path, 'custom', 'python.exe'))
        ..parent.createSync(recursive: true);
      custom.writeAsStringSync('user-owned');
      expect(await env.setCustom(custom.path), isTrue);
      expect(await env.setCustom(p.join(root.path, 'missing.exe')), isFalse);
      expect(env.status!.executable, custom.path);
      final restart = PythonEnvironment(
        paths: env.paths,
        bundleDirectory: bundle,
        probe: fixtureProbe,
        systemCandidates: const [],
      );
      await restart.refresh();
      expect(restart.status!.source, PythonEnvironmentSource.custom);
      expect(await restart.useDefault(), isTrue);
      expect(restart.status!.source, PythonEnvironmentSource.bundled);
      expect(custom.readAsStringSync(), 'user-owned');
    },
  );
  test(
    'overlapping operations reject without overwriting pending valid selection',
    () async {
      final env = PythonEnvironment(
        paths: isolatedPaths(root),
        bundleDirectory: fixtureBundle(root),
        probe: fixtureProbe,
        systemCandidates: const [],
      );
      final pending = env.repair();
      expect(env.busy, isTrue);
      expect(await env.useDefault(), isFalse);
      expect(await pending, isTrue);
      expect(env.busy, isFalse);
    },
  );
}
