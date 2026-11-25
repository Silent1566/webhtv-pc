import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/ipc_protocol.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/spider_registry.dart';

void main() {
  late Directory temp;
  late LogService log;
  late SpiderManifestRegistry registry;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('spider-registry-scan-');
    log = LogService();
    registry = SpiderManifestRegistry(root: temp.path, log: log);
  });
  tearDown(() {
    log.dispose();
    temp.deleteSync(recursive: true);
  });

  String manifest(String relative, String key) {
    final dir = Directory(p.join(temp.path, relative))
      ..createSync(recursive: true);
    File(p.join(dir.path, 'spider.py')).writeAsStringSync('pass');
    final file = File(p.join(dir.path, 'manifest.json'));
    file.writeAsStringSync(
      jsonEncode(
        SpiderManifest(
          key: key,
          name: key,
          runtime: 'python',
          entry: 'spider.py',
          capabilities: const ['home', 'category', 'detail', 'search', 'play'],
        ).toJson(),
      ),
    );
    return file.path;
  }

  test('rescan preserves generated direct manifests', () async {
    final direct = manifest(
      p.join('direct', '1234567890abcdef'),
      'direct-source',
    );
    expect(await registry.register(direct), isNotNull);
    expect(registry.byKey('direct-source'), isNotNull);
    final first = await registry.scan();
    expect(first.map((spider) => spider.key), contains('direct-source'));
    expect(registry.byKey('direct-source')?.manifestPath, direct);
    expect((await registry.scan()).map((spider) => spider.key), [
      'direct-source',
    ]);
  });

  test('accounts storage is not interpreted as a Spider manifest', () async {
    File(p.join(temp.path, 'accounts.json'))
        .writeAsStringSync('{"accounts":{}}');
    manifest('demo', 'demo');
    expect((await registry.scan()).map((spider) => spider.key), ['demo']);
    expect(
      log.entries.where((entry) => entry.level == LogLevel.error),
      isEmpty,
    );
  });

  test(
    'local and root manifests keep priority over generated direct files',
    () async {
      final rootFile = manifest('root-source', 'same-root');
      final localFile = manifest(p.join('local', 'custom'), 'same-local');
      manifest(p.join('direct', 'aaaaaaaaaaaaaaaa'), 'same-root');
      manifest(p.join('direct', 'bbbbbbbbbbbbbbbb'), 'same-local');
      await registry.scan();
      expect(registry.byKey('same-root')?.manifestPath, rootFile);
      expect(registry.byKey('same-local')?.manifestPath, localFile);
    },
  );

  test(
    'scanner never traverses resources below a direct site directory',
    () async {
      manifest(p.join('direct', '1234567890abcdef'), 'direct-source');
      manifest(
        p.join('direct', '1234567890abcdef', 'resources', 'nested'),
        'not-imported',
      );
      await registry.scan();
      expect(registry.byKey('direct-source'), isNotNull);
      expect(registry.byKey('not-imported'), isNull);
    },
  );
}
