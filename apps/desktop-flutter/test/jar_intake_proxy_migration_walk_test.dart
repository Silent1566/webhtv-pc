/// 启动迁移：把存量 csp/*/manifest.json 里 jvm 站源的授权补齐（ADR-0003）。
///
/// 这一层必须真读真写临时目录：纯函数测过之后，仍要证明「目录扫描 + 落盘」这条
/// 链路能把文件改对——上一版把它挂在后台探测里，探测没跑就等于没迁移（实测）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/jar_intake.dart';

void main() {
  late Directory temp;
  late String root;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('jar-proxy-migrate');
    root = p.join(temp.path, 'spiders');
  });

  tearDown(() => temp.deleteSync(recursive: true));

  String writeManifest(String site, Map<String, Object?> manifest) {
    final dir = Directory(p.join(root, 'csp', site))..createSync(recursive: true);
    final file = File(p.join(dir.path, 'manifest.json'));
    file.writeAsStringSync(jsonEncode(manifest));
    return file.path;
  }

  Map<String, Object?> manifest(String runtime, bool localProxy) => {
    'key': 'k',
    'runtime': runtime,
    'capabilities': ['home', 'play'],
    'permissions': {'network': true, 'localProxy': localProxy},
  };

  test('jvm 站源的 manifest 被就地补上授权，非 jvm 原样不动', () {
    final jvm = writeManifest('a', manifest('jvm', false));
    final py = writeManifest('b', manifest('python-catvod', false));
    final before = File(py).readAsStringSync();

    expect(JarIntake.ensureJvmLocalProxy(root: root), 1);

    final migrated = jsonDecode(File(jvm).readAsStringSync()) as Map;
    expect((migrated['permissions'] as Map)['localProxy'], isTrue);
    expect(migrated['capabilities'], contains('proxy'));
    expect(File(py).readAsStringSync(), before, reason: '非 jvm 站源一个字都不许改');
  });

  test('再跑一次不重复改写（幂等）', () {
    writeManifest('a', manifest('jvm', false));
    expect(JarIntake.ensureJvmLocalProxy(root: root), 1);
    expect(JarIntake.ensureJvmLocalProxy(root: root), 0);
  });

  test('坏 manifest 不阻断其它站点迁移', () {
    final broken = Directory(p.join(root, 'csp', 'broken'))..createSync(recursive: true);
    File(p.join(broken.path, 'manifest.json')).writeAsStringSync('{not json');
    final jvm = writeManifest('a', manifest('jvm', false));
    expect(JarIntake.ensureJvmLocalProxy(root: root), 1);
    expect(
      ((jsonDecode(File(jvm).readAsStringSync()) as Map)['permissions'] as Map)['localProxy'],
      isTrue,
    );
  });
}
