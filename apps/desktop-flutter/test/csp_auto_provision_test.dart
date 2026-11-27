import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/ipc_protocol.dart';
import 'package:webhtv_pc/services/spider_registry.dart';
import 'package:webhtv_pc/services/spider_router.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/csp_jar_probe.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

class _OfflineState extends AppState {
  _OfflineState(AppPaths paths)
    : super(
        paths: paths,
        log: LogService(),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );

  AppConfig? probeConfig;

  @override
  AppConfig? get effectiveConfig => probeConfig ?? super.effectiveConfig;

  bool runFirstHome = false;
  int homeCalls = 0;

  @override
  Future<void> loadHome(Site site) async {
    homeCalls++;
    if (runFirstHome && homeCalls == 1) await super.loadHome(site);
  }
}

class _ObservedSites extends ListBase<Site> {
  _ObservedSites(this.site);
  final Site site;
  int reads = 0;
  @override
  int get length {
    reads++;
    return 1;
  }

  @override
  set length(int value) => throw UnsupportedError('read-only');
  @override
  Site operator [](int index) => site;
  @override
  void operator []=(int index, Site value) =>
      throw UnsupportedError('read-only');
}

Map<String, Object?> _site(String key, {String? api, String? jar}) => {
  'key': key,
  'name': key,
  'type': 3,
  'api': api ?? 'csp_Demo',
  'jar': ?jar,
};

const _jar = 'https://example.test/shared.jar';

void main() {
  late Directory temp;
  late _OfflineState state;
  late List<AppConfig> runs;
  late List<Completer<CspProbeReport>> results;
  late List<AppConfig> directRuns;
  late List<Completer<Map<String, LocalSpider>>> directResults;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('webhtv-csp-auto-');
    state = _OfflineState(
      AppPaths.resolve(
        overrides: {
          'config': temp.path,
          'data': temp.path,
          'cache': '${temp.path}/cache',
          'state': '${temp.path}/logs',
        },
      ),
    );
    runs = [];
    results = [];
    directRuns = [];
    directResults = [];
    state.debugDirectReadyTimeout = const Duration(milliseconds: 10);
    state.debugDirectProbeOverride = (config) {
      directRuns.add(config);
      final result = Completer<Map<String, LocalSpider>>();
      directResults.add(result);
      return result.future;
    };
    state.debugCspProbeOverride = (config) {
      runs.add(config);
      final result = Completer<CspProbeReport>();
      results.add(result);
      return result.future;
    };
  });

  tearDown(() async {
    state.dispose();
    for (final result in results) {
      if (!result.isCompleted) result.complete(const CspProbeReport());
    }
    for (final result in directResults) {
      if (!result.isCompleted) result.complete({});
    }
    await state.pythonEnvironmentIdle;
    await temp.delete(recursive: true);
  });

  Future<void> importSites(List<Map<String, Object?>> sites) async {
    expect(
      await state.importConfig(jsonEncode({'spider': _jar, 'sites': sites})),
      isTrue,
    );
    await Future<void>.delayed(Duration.zero);
  }

  test('without csp sites no background installer starts', () async {
    await importSites([_site('http', api: 'https://example.test/api')]);
    expect(runs, isEmpty);
  });

  test('already installed csp sites do not trigger provisioning', () async {
    final dir = Directory(state.cspDirectoryFor('installed'));
    await dir.create(recursive: true);
    await File('${dir.path}/index.jar').writeAsBytes([1]);
    await importSites([_site('installed')]);
    expect(runs, isEmpty);
  });

  test('direct csp js sites do not trigger JVM provisioning', () async {
    await importSites([_site('direct', api: 'csp_Direct.js')]);
    expect(runs, isEmpty);
  });

  test(
    'import returns while installing and completion sums reports once',
    () async {
      await importSites(List.generate(7, (i) => _site('site-$i')));
      expect(runs, hasLength(1));
      expect(results.single.isCompleted, isFalse);
      expect(runs.single.sites, hasLength(7));
      var notifications = 0;
      state.addListener(() => notifications++);
      results.single.complete(
        const CspProbeReport(
          entries: [
            CspProbeEntry(
              siteKey: 'site-0',
              outcome: CspProbeOutcome.installed,
            ),
            CspProbeEntry(
              siteKey: 'site-1',
              outcome: CspProbeOutcome.installed,
            ),
            CspProbeEntry(siteKey: 'site-2', outcome: CspProbeOutcome.unpacked),
            CspProbeEntry(siteKey: 'site-3', outcome: CspProbeOutcome.rejected),
            CspProbeEntry(siteKey: 'site-4', outcome: CspProbeOutcome.failed),
            CspProbeEntry(
              siteKey: 'site-5',
              outcome: CspProbeOutcome.unpackFailed,
            ),
            CspProbeEntry(
              siteKey: 'site-6',
              outcome: CspProbeOutcome.needsShellRuntime,
            ),
          ],
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(notifications, 1);
      expect(
        state.log.entries.last.message,
        contains('已装 3 个、拒绝 1、失败 2、需解包运行时 1'),
      );
      expect(state.log.entries.last.level, LogLevel.warning);
    },
  );

  test('same config stays single flight even after completion', () async {
    await importSites([_site('missing')]);
    final config = state.config!;
    await state.provisionCspJarsQuietly(config);
    await state.provisionCspJarsQuietly(config);
    expect(runs, hasLength(1));
    results.single.complete(const CspProbeReport());
    await Future<void>.delayed(Duration.zero);
    await state.provisionCspJarsQuietly(config);
    expect(runs, hasLength(1));
  });

  test('only first four distinct remote jars are provisioned', () async {
    await importSites([
      _site(
        'one',
        jar: 'https://example.test/1.jar;md5;aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ),
      _site('two', jar: 'https://example.test/2.jar'),
      _site('three', jar: 'https://example.test/3.jar'),
      _site('four', jar: 'https://example.test/4.jar'),
      _site('five', jar: 'https://example.test/5.jar'),
      _site('one-again', jar: 'https://example.test/1.jar'),
      _site('six', jar: 'https://example.test/6.jar'),
    ]);
    expect(runs, hasLength(1));
    expect(runs.single.sites.map((site) => site.key), [
      'one',
      'two',
      'three',
      'four',
      'one-again',
    ]);
    expect(
      runs.single.sites
          .map(
            (site) => site.effectiveJar(runs.single.spider)!.split(';').first,
          )
          .toSet(),
      {
        'https://example.test/1.jar',
        'https://example.test/2.jar',
        'https://example.test/3.jar',
        'https://example.test/4.jar',
      },
    );
    expect(
      state.log.entries.any(
        (entry) =>
            entry.level == LogLevel.info &&
            entry.message.contains('其余请用站点页自动探测') &&
            entry.message.contains('2 个'),
      ),
      isTrue,
    );
  });

  test(
    'old config completion cannot notify or report into new config',
    () async {
      await importSites([_site('old')]);
      // Drain availability notifications, leaving the mocked installers pending.
      await state.pythonEnvironmentIdle;
      await importSites([_site('new')]);
      await state.pythonEnvironmentIdle;
      expect(runs, hasLength(2));
      var notifications = 0;
      state.addListener(() => notifications++);
      final logCount = state.log.entries.length;
      results.first.complete(
        const CspProbeReport(
          entries: [
            CspProbeEntry(siteKey: 'old', outcome: CspProbeOutcome.installed),
          ],
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(notifications, 0);
      expect(state.log.entries, hasLength(logCount));
      results.last.complete(const CspProbeReport());
      await Future<void>.delayed(Duration.zero);
      expect(notifications, 1);
    },
  );

  test(
    'runner failures are logged and notify without escaping import',
    () async {
      await importSites([_site('missing')]);
      var notifications = 0;
      state.addListener(() => notifications++);
      results.single.completeError(StateError('offline failure'));
      await Future<void>.delayed(Duration.zero);
      expect(notifications, 1);
      expect(state.lastError, isNull);
      expect(state.log.entries.last.level, LogLevel.warning);
      expect(
        state.log.entries.last.message,
        contains('已装 0 个、拒绝 0、失败 1、需解包运行时 0'),
      );
    },
  );
  test(
    'a cache from a different jar source does not suppress auto install',
    () async {
      final dir = Directory(state.cspDirectoryFor('old-cache'));
      await dir.create(recursive: true);
      await File('${dir.path}/index.jar').writeAsBytes([1]);
      await File('${dir.path}/probe.json').writeAsString(
        jsonEncode({
          'siteKey': 'old-cache',
          'sourceUrl': 'https://old.test/spider.jar',
          'sourceApi': 'csp_Demo',
          'installed': true,
        }),
      );
      await importSites([_site('old-cache')]);
      expect(runs, hasLength(1));
      expect(await File('${dir.path}/index.jar').readAsBytes(), [1]);
    },
  );

  LocalSpider local(String key) => LocalSpider(
    manifest: SpiderManifest(
      key: key,
      name: key,
      runtime: 'node-tvbox',
      entry: 'entry.js',
      capabilities: ['home'],
    ),
    manifestPath: '${temp.path}/manifest.json',
    rootDir: temp.path,
    entryPath: '${temp.path}/entry.js',
  );

  test(
    'new configuration can register while old registration is still pending',
    () async {
      await importSites([
        _site('old-direct', api: 'https://example.test/old.js'),
      ]);
      await importSites([
        _site('new-direct', api: 'https://example.test/new.js'),
      ]);
      expect(directRuns, hasLength(2));
      directResults.last.complete({'new-direct': local('new-direct')});
      await Future<void>.delayed(Duration.zero);
      expect(state.debugDirectSpiders.keys, ['new-direct']);
      directResults.first.complete({'old-direct': local('old-direct')});
      await Future<void>.delayed(Duration.zero);
      expect(state.debugDirectSpiders.keys, ['new-direct']);
    },
  );

  test(
    'startup and manual registration share the same pending installer',
    () async {
      await importSites([
        _site('direct', api: 'https://example.test/direct.js'),
      ]);
      final first = state.registerDirectSpiders();
      final second = state.registerDirectSpiders();
      await Future<void>.delayed(Duration.zero);
      expect(directRuns, hasLength(1));
      directResults.single.complete({'direct': local('direct')});
      expect(await first, 1);
      expect(await second, 1);
      await Future<void>.delayed(Duration.zero);
      expect(directRuns, hasLength(1));
    },
  );

  test('original-source adapter shares the pending installer with active registration', () async {
    await importSites([_site('direct', api: 'https://example.test/direct.js')]);
    final router = SpiderRouter(
      client: HttpApiClient(),
      globalHeaders: const [],
    );
    final pending = state.debugRegisterDirectSpidersFor(
      state.effectiveConfig!,
      router,
    );
    await Future<void>.delayed(Duration.zero);
    expect(directRuns, hasLength(1));
    directResults.single.complete({'direct': local('direct')});
    await pending;
    expect(router.directSpiders.keys, ['direct']);
  });

  test('registration finishing after home timeout retries current home exactly once', () async {
    state.runFirstHome = true;
    await importSites([_site('direct', api: 'https://example.test/direct.js')]);
    expect(state.homeCalls, 1);
    expect(
      state.lastError,
      isNull,
      reason: 'yield timeout is not a terminal registration failure',
    );
    expect(state.contentPhase, LoadPhase.loading);
    expect(
      state.log.entries.any((entry) => entry.message.contains('直连站源注册超时')),
      isTrue,
    );
    directResults.single.complete({'direct': local('direct')});
    await Future<void>.delayed(Duration.zero);
    expect(state.homeCalls, 2);
    await Future<void>.delayed(Duration.zero);
    expect(state.homeCalls, 2);
  });

  test(
    'late old registration never retries a new configuration home',
    () async {
      state.runFirstHome = true;
      await importSites([
        _site('old-direct', api: 'https://example.test/old.js'),
      ]);
      await importSites([
        _site('new-direct', api: 'https://example.test/new.js'),
      ]);
      final before = state.homeCalls;
      directResults.first.complete({'old-direct': local('old-direct')});
      await Future<void>.delayed(Duration.zero);
      expect(state.homeCalls, before);
    },
  );
  List<int> jarBytes(Map<String, List<int>> files) {
    final archive = Archive();
    for (final entry in files.entries) {
      archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
    }
    return ZipEncoder().encode(archive);
  }

  Future<String> installFixture(
    String key,
    String url, {
    String api = 'csp_Demo',
  }) async {
    final config = AppConfig(
      spider: url,
      sites: [Site(key: key, name: key, type: 3, api: api)],
    );
    final binding = CspJvmBinding(root: state.cspRoot).forConfig(config);
    final dir = binding.directoryFor(key);
    await Directory(dir).create(recursive: true);
    await File(p.join(dir, 'index.jar')).writeAsBytes(
      jarBytes({
        'com/github/catvod/spider/Demo.class': [1],
      }),
    );
    await File(p.join(dir, 'probe.json')).writeAsString(
      jsonEncode({
        'siteKey': key,
        'sourceUrl': url,
        'sourceApi': api,
        'installed': true,
        'outcome': 'installed',
      }),
    );
    return dir;
  }

  test(
    'background probe never calls shell unpack even with runtime installed',
    () async {
      var unpackCalls = 0;
      final completed = Completer<void>();
      state.debugCspProbeOverride = null;
      state.debugCspProbeFactoryOverride = (binding, allowShellUnpack) =>
          CspJarProbe(
            root: p.dirname(state.cspRoot),
            binding: binding,
            log: state.log,
            allowShellUnpack: allowShellUnpack,
            client: MockClient(
              (_) async => http.Response.bytes(
                jarBytes({
                  'classes.dex': [0x64, 0x65, 0x78, 0x0a, 0x30, 0x33, 0x35],
                  'assets/wexshinidie.guard': [1, 2, 3],
                  'assets/libwex.so': [0x7f, 0x45, 0x4c, 0x46],
                }),
                200,
              ),
            ),
            shellRuntimeInstalled: () => true,
            shellUnpack:
                ({required String shellJar, required String outJar}) async {
                  unpackCalls++;
                  return {'ok': false, 'message': 'must remain user initiated'};
                },
          );
      state.addListener(() {
        if (state.log.entries.any(
              (entry) => entry.message.startsWith('CSP 自动安装：已装'),
            ) &&
            !completed.isCompleted) {
          completed.complete();
        }
      });
      await importSites([_site('shell')]);
      await completed.future;
      expect(unpackCalls, 0);
      final summary = state.log.entries.lastWhere(
        (entry) => entry.message.startsWith('CSP 自动安装：已装'),
      );
      expect(summary.message, contains('需解包运行时 1'));
      // Explicit manual probe keeps unpacking enabled, so the spy proves the seam is live.
      await state.probeCspJars();
      expect(unpackCalls, 1);
    },
  );

  test('CSP installation recovers current home exactly once', () async {
    state.runFirstHome = true;
    await importSites([_site('csp-home')]);
    expect(state.homeCalls, 1);
    expect(state.lastError, isNull);
    expect(state.contentPhase, LoadPhase.loading);
    expect(
      state.log.entries.where((entry) => entry.message.contains('首页加载失败')),
      isEmpty,
    );
    await installFixture('csp-home', _jar);
    results.single.complete(
      const CspProbeReport(
        entries: [
          CspProbeEntry(
            siteKey: 'csp-home',
            outcome: CspProbeOutcome.installed,
          ),
        ],
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(state.homeCalls, 2);
    await state.provisionCspJarsQuietly(state.effectiveConfig!);
    await Future<void>.delayed(Duration.zero);
    expect(state.homeCalls, 2);
  });

  test('CSP management reads only current source and deletes selected source directory', () async {
    final oldDir = await installFixture('managed', 'https://old.test/old.jar');
    final currentDir = await installFixture('managed', _jar);
    await importSites([_site('managed')]);
    expect(state.cspDirectoryFor('managed'), currentDir);
    expect(state.cspProbeRecordFor('managed')?['sourceUrl'], _jar);
    expect(state.installedCspJars.map((item) => item.directory), [currentDir]);
    expect(state.installedCspJars.single.siteKey, 'managed');
    final selected = state.installedCspJars.single;
    expect(
      await state.removeCspJar(selected.siteKey, directory: selected.directory),
      isTrue,
    );
    expect(Directory(currentDir).existsSync(), isFalse);
    expect(Directory(oldDir).existsSync(), isTrue);
  });

  test(
    'CSP key deletion resolves current source instead of legacy cache',
    () async {
      final oldDir = await installFixture(
        'remove-key',
        'https://old.test/old.jar',
      );
      final currentDir = await installFixture('remove-key', _jar);
      await importSites([_site('remove-key')]);
      expect(
        await state.removeCspJar('remove-key'),
        isTrue,
        reason: state.log.entries.map((entry) => entry.message).join('\n'),
      );
      expect(Directory(currentDir).existsSync(), isFalse);
      expect(Directory(oldDir).existsSync(), isTrue);
    },
  );

  test('provisioning yields before touching the site list', () async {
    await importSites([_site('http', api: 'https://example.test/api')]);
    final sites = _ObservedSites(
      Site(key: 'observed', name: 'observed', type: 3, api: 'csp_Demo'),
    );
    final config = AppConfig(spider: _jar, sites: sites);
    state.probeConfig = config;
    final pending = state.provisionCspJarsQuietly(config);
    expect(sites.reads, 0);
    await Future<void>.delayed(Duration.zero);
    expect(runs, hasLength(1));
    results.single.complete(const CspProbeReport());
    await pending;
  });

  test('URL cap reports deferred sites and ignores invalid jar URLs', () async {
    await importSites([
      _site('invalid', jar: 'not-a-url'),
      _site('one', jar: 'https://example.test/1.jar'),
      _site('two', jar: 'https://example.test/2.jar'),
      _site('three', jar: 'https://example.test/3.jar'),
      _site('four', jar: 'https://example.test/4.jar'),
      _site('five-a', jar: 'https://example.test/5.jar'),
      _site('five-b', jar: 'https://example.test/5.jar'),
      _site('five-c', jar: 'https://example.test/5.jar'),
    ]);
    expect(runs.single.sites.map((site) => site.key), [
      'one',
      'two',
      'three',
      'four',
    ]);
    expect(
      state.log.entries.any(
        (entry) =>
            entry.message.contains('剩余 3 个站点') &&
            entry.message.contains('其余请用站点页自动探测'),
      ),
      isTrue,
    );
  });
}
