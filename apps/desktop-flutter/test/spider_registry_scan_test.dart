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

  /// 直连生成壳：运行时可被包装、目录里带 `loader.json`，因此要过口径准入。
  ///
  /// `generation` 为空表示口径字段缺失——这正是升级现场那 178 个目录的形状。
  String directShell(String dir, String key, {int? generation}) {
    final path = Directory(p.join(temp.path, 'direct', dir))
      ..createSync(recursive: true);
    File(p.join(path.path, 'loader.py')).writeAsStringSync('pass');
    File(p.join(path.path, 'loader.json')).writeAsStringSync('{}');
    File(p.join(path.path, 'spider.py')).writeAsStringSync('pass');
    final json = SpiderManifest(
      key: key,
      name: key,
      runtime: 'python-catvod',
      entry: 'spider.py',
      capabilities: const ['home', 'category', 'detail', 'search', 'play'],
    ).toJson();
    if (generation != null) json['shellGenerationVersion'] = generation;
    File(p.join(path.path, 'manifest.json')).writeAsStringSync(jsonEncode(json));
    return path.path;
  }

  test('legacy direct shells collapse into one summary line', () async {
    for (var i = 0; i < 3; i++) {
      directShell('abcd00000000000$i', 'legacy-$i');
    }

    await registry.scan();

    // 准入本身不变：三个旧口径壳都不许登记。
    expect(registry.spiders, isEmpty);
    // 每目录一行 WARNING 会把真正的错误埋掉，这台机器上是 178 行。
    expect(
      log.entries.where((entry) => entry.level == LogLevel.warning),
      isEmpty,
    );
    // 任何级别都只许有一行：落盘不按级别过滤，逐目录一行会原样进日志文件。
    final summary = log.entries
        .where((entry) => entry.message.contains('跳过'))
        .toList();
    expect(summary, hasLength(1));
    expect(summary.single.level, LogLevel.info);
    expect(summary.single.message, contains('3'));
  });

  test('a direct shell at the current generation registers without a summary',
      () async {
    directShell(
      'abcd00000000000a',
      'current-shell',
      generation: LocalSpider.directShellGenerationVersion,
    );

    await registry.scan();

    expect(registry.byKey('current-shell'), isNotNull);
    expect(
      log.entries.where((entry) => entry.message.contains('跳过')),
      isEmpty,
    );
  });
}
