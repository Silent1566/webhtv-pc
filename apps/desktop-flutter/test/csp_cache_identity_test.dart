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
import 'package:webhtv_pc/services/spider_process.dart';
import 'package:webhtv_pc/services/spider_registry.dart';

void main() {
  late Directory temp;
  late CspJvmBinding binding;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('csp-cache-identity-');
    binding = CspJvmBinding(root: p.join(temp.path, 'csp'));
  });

  tearDown(() => temp.deleteSync(recursive: true));

  String legacyJar(String segment) {
    final jar = File(p.join(binding.root, segment, 'index.jar'));
    jar.createSync(recursive: true);
    jar.writeAsBytesSync([1, 2, 3]);
    return jar.path;
  }

  void metadata(String segment, String filename, Object? value) {
    final file = File(p.join(binding.root, segment, filename));
    file.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(value));
  }

  /// 「别的 key 不得占用这条旧目录」这条断言依赖**文件系统是否区分大小写**：
  /// Windows 上 `csp_demo` 会解析到已存在的 `csp_Demo`（真实的别名风险），
  /// 而 Linux 上二者本来就是两个不同目录，拿小写形式比较会把正常结果判成失败。
  /// 所以精确路径在两个平台都比，忽略大小写的形式只在 Windows 比。
  void expectNotLegacyDirectory(String key, String legacyDirectory) {
    final resolved = binding.directoryFor(key);
    expect(resolved, isNot(legacyDirectory));
    if (Platform.isWindows) {
      expect(resolved.toLowerCase(), isNot(legacyDirectory.toLowerCase()));
    }
  }

  void expectContained(String path) {
    expect(p.isWithin(binding.root, path), isTrue);
    final segment = p.relative(path, from: binding.root);
    expect(p.split(segment), hasLength(1));
    expect(segment.length, lessThanOrEqualTo(120));
    expect(segment, matches(RegExp(r'^[A-Za-z0-9_.~\-]+$')));
    expect(segment.endsWith('.'), isFalse);
    expect(
      segment,
      isNot(
        matches(
          RegExp(
            r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$',
            caseSensitive: false,
          ),
        ),
      ),
    );
  }

  test('Chinese keys have distinct clean cache identities', () {
    expect(sanitizePathSegment('玩偶'), '__');
    expect(sanitizePathSegment('花卷'), '__');
    expect(binding.directoryFor('玩偶'), isNot(binding.directoryFor('花卷')));
  });

  test('wrong-site legacy manifest and probe never bind to requested key', () {
    final jar = legacyJar('__');
    metadata('__', 'manifest.json', {
      'key': '花卷',
      'config': {'className': 'AiNewHuaJuanGuard'},
    });
    metadata('__', 'intake.json', {'siteKey': '花卷'});
    metadata('__', 'probe.json', {'siteKey': '花卷', 'installed': true});
    final manifest = File(p.join(p.dirname(jar), 'manifest.json'));
    final original = manifest.readAsStringSync();

    expect(
      binding.entryFor('玩偶'),
      isNull,
      reason: '玩偶 must not load 花卷/AiNewHuaJuanGuard from __',
    );
    expect(CspJarProbe.recordFor(binding, '玩偶'), isNull);
    expect(binding.directoryFor('玩偶'), isNot(p.dirname(jar)));
    expect(binding.entryFor('花卷'), jar);
    expect(binding.directoryFor('花卷'), p.dirname(jar));
    expect(
      binding.entryFor('__'),
      isNull,
      reason: 'the literal legacy name does not own 花卷 either',
    );
    expect(manifest.readAsStringSync(), original);
    expect(File(jar).readAsBytesSync(), [1, 2, 3]);
  });

  test(
    'wrong legacy owner triggers clean probe reimport without modifying legacy',
    () async {
      final legacy = legacyJar('__');
      metadata('__', 'manifest.json', {'key': '花卷'});
      metadata('__', 'intake.json', {'siteKey': '花卷'});
      metadata('__', 'probe.json', {'siteKey': '花卷', 'installed': true});
      final before = {
        for (final file in Directory(
          p.dirname(legacy),
        ).listSync().whereType<File>())
          file.path: file.readAsBytesSync(),
      };
      final archive = Archive()
        ..addFile(ArchiveFile('Demo.class', 5, [0xca, 0xfe, 0xba, 0xbe, 1]));
      final bytes = ZipEncoder().encode(archive);
      var downloads = 0;
      final client = MockClient((request) async {
        downloads++;
        return http.Response.bytes(bytes, 200);
      });
      addTearDown(client.close);
      final probe = CspJarProbe(
        root: temp.path,
        binding: binding,
        client: client,
        shellRuntimeInstalled: () => false,
      );
      final config = AppConfig(
        name: 'cache identity',
        sites: [
          Site(
            key: '玩偶',
            name: '玩偶',
            type: SiteType.spider,
            api: 'csp_Demo',
            jar: 'https://example.test/demo.jar',
          ),
        ],
      );
      final report = await probe.materialize(config);
      expect(report.installed, 1);
      expect(downloads, 1);
      final canonical = binding.directoryFor('玩偶');
      expect(p.basename(canonical), matches(RegExp(r'^csp~[a-f0-9]{64}$')));
      expect(binding.entryFor('玩偶'), p.join(canonical, 'index.jar'));
      expect(
        (jsonDecode(File(p.join(canonical, 'manifest.json')).readAsStringSync())
            as Map)['key'],
        '玩偶',
      );
      expect(CspJarProbe.recordFor(binding, '玩偶')?['siteKey'], '玩偶');
      for (final entry in before.entries) {
        expect(File(entry.key).readAsBytesSync(), entry.value);
      }
      await probe.materialize(config);
      expect(downloads, 1, reason: 'the clean installed path remains stable');
    },
  );

  for (final filename in ['manifest.json', 'intake.json', 'probe.json']) {
    test('matching $filename owner permits lossy legacy reuse', () {
      final jar = legacyJar('__');
      metadata('__', filename, {
        filename == 'manifest.json' ? 'key' : 'siteKey': '花卷',
      });
      expect(binding.directoryFor('花卷'), p.dirname(jar));
      expect(binding.entryFor('花卷'), jar);
      expect(binding.entryFor('玩偶'), isNull);
    });
  }

  for (final invalid in <Object?>[
    null,
    [],
    {},
    {'siteKey': 7},
    {'siteKey': '玩偶'},
  ]) {
    test('lossy legacy rejects missing or invalid owner $invalid', () {
      final jar = legacyJar('__');
      if (invalid != null) metadata('__', 'intake.json', invalid);
      expect(binding.directoryFor('花卷'), isNot(p.dirname(jar)));
      expect(binding.entryFor('花卷'), isNull);
      expect(File(jar).existsSync(), isTrue);
    });
  }

  test('malformed or conflicting metadata cannot prove legacy ownership', () {
    final jar = legacyJar('__');
    metadata('__', 'manifest.json', {'key': '花卷'});
    final intake = File(p.join(p.dirname(jar), 'intake.json'));
    intake.writeAsStringSync('{broken');
    expect(binding.entryFor('花卷'), isNull);
    metadata('__', 'intake.json', {'siteKey': '玩偶'});
    expect(binding.entryFor('花卷'), isNull);
    expect(intake.readAsStringSync(), jsonEncode({'siteKey': '玩偶'}));
  });

  test(
    'owner-less legacy records do not contradict a proven manifest owner',
    () {
      final jar = legacyJar('__');
      metadata('__', 'manifest.json', {'key': '花卷'});
      metadata('__', 'intake.json', {'entry': 'index.jar'});
      metadata('__', 'probe.json', {'installed': true});
      expect(binding.entryFor('花卷'), jar);
      expect(binding.entryFor('玩偶'), isNull);
      metadata('__', 'probe.json', {'siteKey': '玩偶'});
      expect(binding.entryFor('花卷'), isNull);
    },
  );

  test('clean canonical cache takes precedence over matching legacy cache', () {
    final canonical = binding.directoryFor('花卷');
    final canonicalJar = File(p.join(canonical, 'index.jar'));
    canonicalJar.createSync(recursive: true);
    canonicalJar.writeAsBytesSync([9]);
    final legacy = legacyJar('__');
    metadata('__', 'manifest.json', {'key': '花卷'});
    expect(binding.directoryFor('花卷'), canonical);
    expect(binding.entryFor('花卷'), canonicalJar.path);
    expect(File(legacy).readAsBytesSync(), [1, 2, 3]);
  });

  test('lossy keys cannot alias literal sanitized names or hash-like keys', () {
    for (final pair in [
      ['花卷', '__'],
      ['csp_a/b', 'csp_a_b'],
      ['a\\b', 'a_b'],
      ['', '_'],
      ['.', '_'],
      ['..', '_'],
      ['csp~example', 'csp_example'],
    ]) {
      expect(
        binding.directoryFor(pair[0]).toLowerCase(),
        isNot(binding.directoryFor(pair[1]).toLowerCase()),
        reason: '$pair',
      );
    }
    final hashedSegment = p.basename(binding.directoryFor('花卷'));
    expect(hashedSegment, contains('~'));
    expect(
      binding.directoryFor(hashedSegment),
      isNot(binding.directoryFor('花卷')),
    );
  });

  test(
    'clean Windows case variants are distinct even on insensitive filesystems',
    () {
      final paths = [
        'demo',
        'Demo',
        'DEMO',
        'csp_Demo',
        'CSP_DEMO',
      ].map(binding.directoryFor).map((path) => path.toLowerCase()).toSet();
      expect(paths, hasLength(5));
    },
  );

  test('legacy exact spelling is usable but case variants cannot claim it', () {
    final jar = legacyJar('csp_Demo');
    expect(binding.entryFor('csp_Demo'), jar);
    expect(binding.entryFor('CSP_DEMO'), isNull);
    expect(binding.entryFor('csp_demo'), isNull);
    expectNotLegacyDirectory('csp_demo', p.dirname(jar));
  });

  test('existing lowercase legacy cache does not bind mixed-case keys', () {
    final jar = legacyJar('csp_demo');
    metadata('csp_demo', 'manifest.json', {'key': 'csp_demo'});
    expect(binding.entryFor('csp_demo'), jar);
    for (final key in ['csp_Demo', 'CSP_DEMO']) {
      expect(binding.entryFor(key), isNull);
      expectNotLegacyDirectory(key, p.dirname(jar));
    }
  });

  test('legacy directory links cannot claim an outside cache', () {
    final outside = Directory(p.join(temp.path, 'outside', '__'))
      ..createSync(recursive: true);
    File(p.join(outside.path, 'index.jar')).writeAsBytesSync([7]);
    final root = Directory(binding.root)..createSync();
    final link = Link(p.join(root.path, '__'));
    try {
      link.createSync(outside.path);
    } on FileSystemException {
      if (!Platform.isWindows) rethrow;
      final result = Process.runSync('cmd', [
        '/c',
        'mklink',
        '/J',
        link.path,
        outside.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout} ${result.stderr}');
    }
    try {
      metadata('__', 'manifest.json', {'key': '花卷'});
      expect(binding.entryFor('花卷'), isNull);
      expect(binding.directoryFor('花卷'), isNot(link.path));
      expect(File(p.join(outside.path, 'index.jar')).readAsBytesSync(), [7]);
    } finally {
      if (link.existsSync()) {
        link.deleteSync();
      } else if (Platform.isWindows) {
        final result = Process.runSync('cmd', ['/c', 'rmdir', link.path]);
        expect(result.exitCode, 0, reason: '${result.stdout} ${result.stderr}');
      }
    }
  });

  test('safe literal legacy owner cannot be claimed by a lossy key', () {
    final jar = legacyJar('csp_a_b');
    metadata('csp_a_b', 'manifest.json', {'key': 'csp_a_b'});
    expect(binding.entryFor('csp_a_b'), jar);
    expect(binding.entryFor('csp_a/b'), isNull);
    expect(binding.directoryFor('csp_a/b'), isNot(p.dirname(jar)));
  });

  test('legacy safe ASCII jars without manifest remain usable', () {
    for (final key in ['demo', 'csp_Demo', 'a-b.c_1']) {
      final jar = legacyJar(key);
      expect(binding.directoryFor(key), p.dirname(jar));
      expect(binding.entryFor(key), jar);
      expect(
        File(p.join(p.dirname(jar), 'manifest.json')).existsSync(),
        isFalse,
      );
    }
  });

  test('clean lowercase safe ASCII behavior is preserved', () {
    for (final key in ['demo', 'csp_demo', 'a-b.c_1', '_', '__']) {
      expect(binding.directoryFor(key), p.join(binding.root, key));
    }
  });

  test(
    'unsafe keys have deterministic bounded single-segment Windows paths',
    () {
      final keys = [
        '',
        '.',
        '..',
        '../outside',
        '..\\outside',
        '/',
        '\\',
        'C:\\outside',
        'C:/outside',
        'con',
        'CON',
        'con.txt',
        'prn',
        'aux',
        'nul',
        'COM1',
        'lpt9.log',
        'name.',
        'name ',
        '花卷',
        '玩偶',
        List.filled(1000, 'a').join(),
        List.filled(1000, '花').join(),
      ];
      final paths = <String>{};
      for (final key in keys) {
        final path = binding.directoryFor(key);
        expectContained(path);
        expect(CspJvmBinding(root: binding.root).directoryFor(key), path);
        expect(
          paths.add(path.toLowerCase()),
          isTrue,
          reason: 'duplicate for $key',
        );
      }
    },
  );
}
