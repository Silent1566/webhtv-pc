import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/csp_jar_probe.dart';
import 'package:webhtv_pc/services/jar_intake.dart';
import 'package:webhtv_pc/services/spider_registry.dart';
import 'package:webhtv_pc/services/spider_router.dart';

class _CountingBinding extends CspJvmBinding {
  _CountingBinding({required super.root});
  int lookups = 0;
  @override
  String directoryFor(String siteKey) {
    lookups++;
    return super.directoryFor(siteKey);
  }
}

void main() {
  late Directory temp;
  late CspJvmBinding binding;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('csp-source-binding-');
    binding = CspJvmBinding(root: p.join(temp.path, 'csp'));
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Site site({String key = 'Douban', String api = 'csp_Douban', String? jar}) =>
      Site(key: key, name: key, type: 3, api: api, jar: jar);
  AppConfig config(String url, {Site? entry}) =>
      AppConfig(sites: [entry ?? site()], spider: url);

  List<int> desktopJar(String className) {
    final archive = Archive()
      ..addFile(
        ArchiveFile('com/github/catvod/spider/$className.class', 1, [1]),
      );
    return ZipEncoder().encode(archive);
  }

  void installRecord(String dir, String key, {String? source, String? api}) {
    final file = File(p.join(dir, 'index.jar'));
    file.createSync(recursive: true);
    file.writeAsBytesSync(desktopJar('Douban'));
    File(p.join(dir, 'manifest.json')).writeAsStringSync(
      jsonEncode({
        'key': key,
        'config': {'className': 'com.github.catvod.spider.Douban'},
      }),
    );
    if (source != null) {
      File(p.join(dir, 'probe.json')).writeAsStringSync(
        jsonEncode({
          'siteKey': key,
          'sourceUrl': source,
          'sourceApi': ?api,
          'installed': true,
          'verdict': 'desktopReady',
        }),
      );
    }
  }

  test(
    'same display key in different jar sources has separate cache paths',
    () {
      final first = binding.forConfig(config('https://first.test/spider.jar'));
      final second = binding.forConfig(
        config('https://second.test/spider.jar'),
      );
      expect(
        first.directoryFor('Douban'),
        isNot(second.directoryFor('Douban')),
      );
      expect(p.isWithin(binding.root, first.directoryFor('Douban')), isTrue);
      expect(
        p.split(p.relative(first.directoryFor('Douban'), from: binding.root)),
        hasLength(1),
      );
    },
  );

  test(
    'different csp classes in the same source do not share a display-key cache',
    () {
      final first = binding.forConfig(config('https://source.test/spider.jar'));
      final second = binding.forConfig(
        config('https://source.test/spider.jar', entry: site(api: 'csp_Bili')),
      );
      expect(
        first.directoryFor('Douban'),
        isNot(second.directoryFor('Douban')),
      );
    },
  );

  test('checksum decoration does not create another cache source', () {
    final plain = binding.forConfig(config('https://source.test/spider.jar'));
    final decorated = binding.forConfig(
      config(
        'https://source.test/spider.jar;md5;0123456789abcdef0123456789abcdef',
      ),
    );
    expect(plain.directoryFor('Douban'), decorated.directoryFor('Douban'));
  });

  test('per-site jar takes precedence over the global spider', () {
    final own = binding.forConfig(
      config(
        'https://global.test/spider.jar',
        entry: site(jar: 'https://own.test/spider.jar'),
      ),
    );
    final equivalent = binding.forConfig(config('https://own.test/spider.jar'));
    final global = binding.forConfig(config('https://global.test/spider.jar'));
    expect(own.directoryFor('Douban'), equivalent.directoryFor('Douban'));
    expect(own.directoryFor('Douban'), isNot(global.directoryFor('Douban')));
  });

  test('legacy automatic cache is reused only for its declared source', () {
    final legacy = binding.directoryFor('Douban');
    installRecord(
      legacy,
      'Douban',
      source: 'https://first.test/spider.jar',
      api: 'csp_Douban',
    );
    final installedBytes = File(p.join(legacy, 'index.jar')).readAsBytesSync();
    final first = binding.forConfig(config('https://first.test/spider.jar'));
    final second = binding.forConfig(config('https://second.test/spider.jar'));
    final otherClass = binding.forConfig(
      config('https://first.test/spider.jar', entry: site(api: 'csp_Bili')),
    );
    expect(first.entryFor('Douban'), p.join(legacy, 'index.jar'));
    expect(second.entryFor('Douban'), isNull);
    expect(otherClass.entryFor('Douban'), isNull);
    expect(
      File(p.join(legacy, 'index.jar')).readAsBytesSync(),
      installedBytes,
    );
  });

  test('manual import is preserved as an explicit override', () async {
    final legacy = binding.directoryFor('Douban');
    installRecord(legacy, 'Douban');
    var downloads = 0;
    final c = config('https://new.test/spider.jar');
    final scoped = binding.forConfig(c);
    final probe = CspJarProbe(
      root: temp.path,
      binding: scoped,
      client: MockClient((request) async {
        downloads++;
        return http.Response.bytes(desktopJar('Douban'), 200);
      }),
    );
    final report = await probe.materialize(c);
    expect(scoped.entryFor('Douban'), p.join(legacy, 'index.jar'));
    expect(report.entries.single.outcome, CspProbeOutcome.skippedInstalled);
    expect(downloads, 0);
  });

  test('reusing an old cache repairs a key-derived entry class', () async {
    final legacy = binding.directoryFor('金牌影视');
    installRecord(legacy, '金牌影视', source: 'https://new.test/spider.jar');
    final manifest = File(p.join(legacy, 'manifest.json'));
    final raw = jsonDecode(manifest.readAsStringSync()) as Map<String, Object?>;
    raw['config'] = {'className': 'com.github.catvod.spider.金牌影视'};
    manifest.writeAsStringSync(jsonEncode(raw));

    final c = config(
      'https://new.test/spider.jar',
      entry: site(key: '金牌影视', api: 'csp_Glod'),
    );
    final scoped = binding.forConfig(c);
    final probe = CspJarProbe(
      root: temp.path,
      binding: scoped,
      client: MockClient(
        (request) async => http.Response.bytes(desktopJar('Glod'), 200),
      ),
    );
    final report = await probe.materialize(c);

    expect(report.entries.single.outcome, CspProbeOutcome.skippedInstalled);
    final launch = jsonDecode(
      File(p.join(legacy, 'manifest.json')).readAsStringSync(),
    ) as Map<String, Object?>;
    expect(
      (launch['config'] as Map)['className'],
      'com.github.catvod.spider.Glod',
    );
  });

  test(
    'manual entry class is never rewritten during automatic probing',
    () async {
      final legacy = binding.directoryFor('Douban');
      installRecord(legacy, 'Douban');
      final file = File(p.join(legacy, 'manifest.json'));
      final raw = jsonDecode(file.readAsStringSync()) as Map;
      (raw['config'] as Map)['className'] = 'manual.HandPicked';
      file.writeAsStringSync(jsonEncode(raw));
      final before = file.readAsStringSync();
      final c = config('https://source.test/spider.jar');
      final probe = CspJarProbe(
        root: temp.path,
        binding: binding.forConfig(c),
        client: MockClient(
          (request) async => http.Response.bytes(desktopJar('Douban'), 200),
        ),
      );
      await probe.materialize(c);
      expect(file.readAsStringSync(), before);
    },
  );

  test(
    'router repairs a legacy automatic class without requiring a download',
    () {
      final legacy = binding.directoryFor('金牌影视');
      installRecord(legacy, '金牌影视', source: 'https://source.test/spider.jar');
      final file = File(p.join(legacy, 'manifest.json'));
      final raw = jsonDecode(file.readAsStringSync()) as Map;
      (raw['config'] as Map)['className'] = 'com.github.catvod.spider.金牌影视';
      file.writeAsStringSync(jsonEncode(raw));
      final c = config(
        'https://source.test/spider.jar',
        entry: site(key: '金牌影视', api: 'csp_Glod'),
      );
      final scoped = binding.forConfig(c);
      SpiderRouter.cspLocalSpider(
        site: c.sites.single,
        entryPath: scoped.entryFor('金牌影视')!,
        binding: scoped,
      );
      final after = jsonDecode(file.readAsStringSync()) as Map;
      expect(
        (after['config'] as Map)['className'],
        'com.github.catvod.spider.Glod',
      );
    },
  );

  test(
    'shell guard is never unpacked without an explicit user action',
    () async {
      final archive = Archive()
        ..addFile(ArchiveFile('classes.dex', 4, [0x64, 0x65, 0x78, 0x0a]))
        ..addFile(ArchiveFile('assets/wexshinidie.guard', 3, [1, 2, 3]));
      final shellBytes = ZipEncoder().encode(archive);
      var unpackCalls = 0;
      final c = config('https://shell.test/guard.jar');
      final scoped = binding.forConfig(c);
      final probe = CspJarProbe(
        root: temp.path,
        binding: scoped,
        client: MockClient(
          (request) async => http.Response.bytes(shellBytes, 200),
        ),
        shellRuntimeInstalled: () => true,
        allowShellUnpack: false,
        shellUnpack: ({required shellJar, required outJar}) async {
          unpackCalls++;
          return {'ok': true, 'stage': 'invoke'};
        },
      );
      final report = await probe.materialize(c);

      expect(unpackCalls, 0, reason: '自动安装不得自己起 unidbg');
      expect(report.entries.single.outcome, CspProbeOutcome.needsShellRuntime);
      expect(report.entries.single.message, contains('显式动作'));
    },
  );

  test(
    'new source installs beside the old one and records the api class',
    () async {
      final old = binding.directoryFor('金牌影视');
      installRecord(
        old,
        '金牌影视',
        source: 'https://old.test/spider.jar',
        api: 'csp_Douban',
      );
      final oldBytes = File(p.join(old, 'index.jar')).readAsBytesSync();
      final c = config(
        'https://new.test/spider.jar',
        entry: site(key: '金牌影视', api: 'csp_Glod'),
      );
      final scoped = binding.forConfig(c);
      final probe = CspJarProbe(
        root: temp.path,
        binding: scoped,
        client: MockClient(
          (request) async => http.Response.bytes(desktopJar('Glod'), 200),
        ),
      );
      final report = await probe.materialize(c);
      expect(report.installed, 1);
      expect(File(p.join(old, 'index.jar')).readAsBytesSync(), oldBytes);
      final dir = scoped.directoryFor('金牌影视');
      final launch = jsonDecode(
        File(p.join(dir, 'manifest.json')).readAsStringSync(),
      ) as Map;
      expect(
        (launch['config'] as Map)['className'],
        'com.github.catvod.spider.Glod',
      );
      expect(JarIntake.probeRecord(dir)?['sourceApi'], 'csp_Glod');
      expect(scoped.entryFor('金牌影视'), p.join(dir, 'index.jar'));
    },
  );

  test(
    'classification does not repeatedly resolve an installed cache directory',
    () {
      installRecord(binding.directoryFor('Douban'), 'Douban');
      final counting = _CountingBinding(root: binding.root);
      final router = SpiderRouter(
        client: HttpApiClient(),
        globalHeaders: const [],
        cspBinding: counting,
      );
      router.classifySite(site());
      expect(counting.lookups, lessThanOrEqualTo(2));
    },
  );

  test('an active retry takes precedence over historical failure evidence', () {
    final c = config('https://retry.test/spider.jar');
    final scoped = binding.forConfig(c);
    final dir = scoped.directoryFor('Douban');
    final record = File(p.join(dir, 'probe.json'))..createSync(recursive: true);
    record.writeAsStringSync(
      jsonEncode({
        'siteKey': 'Douban',
        'sourceUrl': 'https://retry.test/spider.jar',
        'installed': false,
        'outcome': 'failed',
        'verdict': 'fetchFailed',
        'summary': 'previous download failed',
      }),
    );
    final router = SpiderRouter(
      client: HttpApiClient(),
      globalHeaders: const [],
      cspBinding: scoped,
    );
    router.setProvisioningSiteKeys({'Douban'});
    final preparing = router.classifySite(site());
    expect(preparing.available, isFalse);
    expect(preparing.reason, contains('正在自动安装'));
    expect(preparing.reason, isNot(contains('自动检测失败')));
    router.setProvisioningSiteKeys(const {});
    expect(
      router.classifySite(site()).reason,
      contains('previous download failed'),
    );
  });

  test(
    'router rebinding rejects a foreign-source cache and advances revision',
    () {
      final legacy = binding.directoryFor('Douban');
      installRecord(
        legacy,
        'Douban',
        source: 'https://old.test/spider.jar',
        api: 'csp_Douban',
      );
      final router = SpiderRouter(
        client: HttpApiClient(),
        globalHeaders: const [],
        cspBinding: binding,
      );
      final before = router.siteRevision;
      router.setCspConfig(config('https://new.test/spider.jar'));
      expect(router.cspBinding?.entryFor('Douban'), isNull);
      expect(router.classifySite(site()).available, isFalse);
      expect(router.siteRevision, greaterThan(before));
    },
  );
}
