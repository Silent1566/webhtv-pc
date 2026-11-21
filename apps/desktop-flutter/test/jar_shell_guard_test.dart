import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/jar_intake.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/spider_registry.dart';
import 'package:webhtv_pc/services/spider_router.dart';

int _findEocd(List<int> bytes) {
  for (var offset = bytes.length - 22; offset >= 0; offset--) {
    if (bytes[offset] == 0x50 &&
        bytes[offset + 1] == 0x4b &&
        bytes[offset + 2] == 0x05 &&
        bytes[offset + 3] == 0x06) {
      return offset;
    }
  }
  return -1;
}

List<int> _le16(int value) => [value & 0xff, (value >> 8) & 0xff];

List<int> _le32(int value) => [
  value & 0xff,
  (value >> 8) & 0xff,
  (value >> 16) & 0xff,
  (value >> 24) & 0xff,
];

void main() {
  late Directory root;
  setUp(
    () async => root = await Directory.systemTemp.createTemp('webhtv-guard-'),
  );
  tearDown(() async => root.delete(recursive: true));
  File jar(Map<String, List<int>> entries, {String name = 'input.jar'}) {
    final archive = Archive();
    for (final entry in entries.entries) {
      archive.add(ArchiveFile(entry.key, entry.value.length, entry.value));
    }
    return File(p.join(root.path, name))
      ..writeAsBytesSync(ZipEncoder().encode(archive));
  }

  /// 手写 zip：可让中央目录声明的大小与实际数据不一致，模拟恶意/损坏 jar。
  File lyingZip({
    required String name,
    required int declaredSize,
    required List<int> actual,
    bool symlink = false,
    String entryName = 'classes.dex',
  }) {
    final builder = BytesBuilder();
    final nameBytes = utf8.encode(entryName);
    final crc = getCrc32(actual);
    final offset = builder.length;
    builder.add(_le32(0x04034b50));
    builder.add(_le16(20));
    builder.add(_le16(0));
    builder.add(_le16(0)); // stored
    builder.add(_le16(0));
    builder.add(_le16(0));
    builder.add(_le32(crc));
    builder.add(_le32(declaredSize));
    builder.add(_le32(declaredSize));
    builder.add(_le16(nameBytes.length));
    builder.add(_le16(0));
    builder.add(nameBytes);
    builder.add(actual);
    final centralStart = builder.length;
    builder.add(_le32(0x02014b50));
    builder.add(_le16(symlink ? 0x0314 : 20));
    builder.add(_le16(20));
    builder.add(_le16(0));
    builder.add(_le16(0));
    builder.add(_le16(0));
    builder.add(_le16(0));
    builder.add(_le32(crc));
    builder.add(_le32(declaredSize));
    builder.add(_le32(declaredSize));
    builder.add(_le16(nameBytes.length));
    builder.add(_le16(0));
    builder.add(_le16(0));
    builder.add(_le16(0));
    builder.add(_le16(0));
    builder.add(_le32(symlink ? 0xa0000000 : 0));
    builder.add(_le32(offset));
    builder.add(nameBytes);
    final centralSize = builder.length - centralStart;
    builder.add(_le32(0x06054b50));
    builder.add(_le16(0));
    builder.add(_le16(0));
    builder.add(_le16(1));
    builder.add(_le16(1));
    builder.add(_le32(centralSize));
    builder.add(_le32(centralStart));
    builder.add(_le16(0));
    return File(p.join(root.path, name))..writeAsBytesSync(builder.takeBytes());
  }

  List<int> dex(String marker) =>
      utf8.encode('dex\n035\u0000Lfixture/$marker;\u0000');

  for (final marker in ['DemoDexNative', 'BaseSpiderGuard', 'AowuShinidie']) {
    test('无 so 的 $marker dex 入口不得被承诺可转译', () {
      final source = jar({
        'classes.dex': dex(marker),
        'assets/payload.bin': [1, 2, 3],
      });
      final result = JarIntake.inspectPath(source.path);
      expect(result.verdict.name, 'shellGuard');
      expect(result.installable, isFalse);
      expect(result.summary, contains('加固壳'));
    });
  }
  test('声明大小与实际不符的 dex 必须按真实读取量计预算', () {
    final source = lyingZip(
      name: 'lying.jar',
      declaredSize: 1,
      actual: utf8.encode('x' * (36 * 1024 * 1024)),
    );
    final result = JarIntake.inspectPath(source.path);
    expect(result.installable, isFalse);
    expect(result.verdict, JarVerdict.androidJar);
  });
  test('符号链接条目不得让检测跳过，直接拒绝', () {
    final source = lyingZip(
      name: 'symlink.jar',
      declaredSize: 1,
      actual: utf8.encode('payload'),
      symlink: true,
      entryName: 'assets/x.bin',
    );
    final result = JarIntake.inspectPath(source.path);
    expect(result.installable, isFalse);
    expect(result.note, contains('符号链接'));
  });
  test('中央目录被截断时不能乐观放行（防 5 万条目绕过拒绝）', () {
    final source = lyingZip(
      name: 'truncated.jar',
      declaredSize: 1,
      actual: utf8.encode('x'),
    );
    final bytes = source.readAsBytesSync();
    // 把 EOCD 里的条目总数改成比实际更多，模拟「清单不完整」。
    final eocd = _findEocd(bytes);
    expect(eocd, greaterThan(0));
    bytes[eocd + 10] = 2;
    source.writeAsBytesSync(bytes);
    final result = JarIntake.inspectPath(source.path);
    expect(result.installable, isFalse);
    expect(result.note, contains('不完整'));
  });

  test('没有 payload.bin 的 dex 壳入口同样拒绝', () {
    final source = jar({'classes.dex': dex('DemoDexNative')});
    expect(JarIntake.inspectPath(source.path).installable, isFalse);
  });
  test('多 dex 的次级入口也扫描，目录形态也适用', () {
    final directory = Directory(p.join(root.path, 'classes'))..createSync();
    File(p.join(directory.path, 'classes.dex'))
        .writeAsBytesSync(dex('Ordinary'));
    File(p.join(directory.path, 'classes2.dex'))
        .writeAsBytesSync(dex('BaseSpiderGuard'));
    final result = JarIntake.inspectPath(directory.path);
    expect(result.verdict.name, 'shellGuard');
  });
  test('assets 下的 guard 资源可识别，普通 bin 资源不能误拒', () {
    final guarded = jar({
      'fixture/Demo.class': [0xca, 0xfe],
      'assets/demo.guard': [1],
    });
    expect(JarIntake.inspectPath(guarded.path).verdict.name, 'shellGuard');
    final normal = jar({
      'classes.dex': dex('Ordinary'),
      'assets/data.bin': [1],
    }, name: 'normal.jar');
    expect(
      JarIntake.inspectPath(normal.path).verdict,
      JarVerdict.translatableDex,
    );
  });
  test('标记出现在非 dex 资源或说明字符串里不能误拒正常入口', () {
    final source = jar({
      'classes.dex': utf8.encode(
        'dex\n035\u0000Docs mention DexNative support',
      ),
      'README.txt': dex('BaseSpiderGuard'),
      'assets/data.bin': dex('DemoDexNative'),
    });
    expect(
      JarIntake.inspectPath(source.path).verdict,
      JarVerdict.translatableDex,
    );
  });
  test('加固壳优先于原生库：dex 标记 + lib/*.so 判 shellGuard', () {
    // wex 这类入口是「dex + assets/*.so + assets/*.guard」：壳特征必须先判，
    // 否则用户看到的是「含原生库」——和他手里的 jar 对不上，也没有下一步。
    final source = jar({
      'classes.dex': dex('DemoDexNative'),
      'lib/x.so': [0x7f],
    });
    final result = JarIntake.inspectPath(source.path);
    expect(result.verdict, JarVerdict.shellGuard);
    expect(result.installable, isFalse);
    expect(result.nativeEntries, isNotEmpty, reason: '原生库条目仍要如实记录');
  });
  test('没有壳特征时原生库拒绝优先级不变', () {
    final source = jar({
      'classes.dex': dex('Ordinary'),
      'lib/x.so': [0x7f],
    });
    expect(
      JarIntake.inspectPath(source.path).verdict,
      JarVerdict.nativeLibrary,
    );
  });
  test('dex + assets/*.so + assets/*.guard 判 shellGuard，文案点名壳资源与 ARM 解包桥', () {
    final source = jar({
      'classes.dex': dex('Ordinary'),
      'assets/wexshinidie.guard': [1, 2, 3],
      'assets/libwex.so': [0x7f, 0x45, 0x4c, 0x46],
    });
    final result = JarIntake.inspectPath(source.path);
    expect(result.verdict, JarVerdict.shellGuard);
    expect(result.installable, isFalse);
    expect(result.shellEntries, contains('assets/wexshinidie.guard'));
    expect(result.summary, contains('assets/wexshinidie.guard'));
    expect(result.summary, contains('ARM 解包桥'));
  });
  test('单 dex 超预算不能在未检查情况下承诺可转译', () {
    final source = jar({'classes.dex': Uint8List(32 * 1024 * 1024 + 1)});
    final result = JarIntake.inspectPath(source.path);
    expect(result.installable, isFalse);
    expect(result.summary, contains('预算'));
  });
  test('多个 dex 共用累计预算，目录也受预算限制', () {
    final directory = Directory(p.join(root.path, 'large'))..createSync();
    final bytes = Uint8List(17 * 1024 * 1024);
    File(p.join(directory.path, 'classes.dex')).writeAsBytesSync(bytes);
    File(p.join(directory.path, 'classes2.dex')).writeAsBytesSync(bytes);
    final result = JarIntake.inspectPath(directory.path);
    expect(result.installable, isFalse);
    expect(result.summary, contains('预算'));
  });
  test('拒绝壳导入，不调用转译器、不覆盖上次可用入口', () async {
    final good = jar({
      'fixture/Demo.class': [0xca, 0xfe],
    }, name: 'good.jar');
    final target = p.join(root.path, 'csp', 'csp_Demo');
    expect(
      (await JarIntake.install(
        sourcePath: good.path,
        targetDir: target,
        siteKey: 'csp_Demo',
        log: LogService(),
      )).ok,
      isTrue,
    );
    final saved = File(p.join(target, 'index.jar')).readAsBytesSync();
    final guarded = jar({'classes.dex': dex('DemoDexNative')});
    var calls = 0;
    final result = await JarIntake.install(
      sourcePath: guarded.path,
      targetDir: target,
      siteKey: 'csp_Demo',
      log: LogService(),
      translateDex: ({required String siteDir, required String archive}) async {
        calls++;
        return {'ok': true};
      },
    );
    expect(result.ok, isFalse);
    expect(calls, 0);
    expect(File(p.join(target, 'index.jar')).readAsBytesSync(), saved);
  });
  test('旧缓存壳站点在 router 中也拒绝，文案不给假成功', () {
    final binding = CspJvmBinding(root: p.join(root.path, 'csp'));
    final target = Directory(binding.directoryFor('csp_Demo'))
      ..createSync(recursive: true);
    final source = jar({'classes.dex': dex('DemoDexNative')});
    source.copySync(p.join(target.path, 'index.jar'));
    final client = HttpApiClient();
    addTearDown(client.close);
    final router = SpiderRouter(
      client: client,
      globalHeaders: const [],
      registry: SpiderManifestRegistry(
        root: p.join(root.path, 'spiders'),
        log: LogService(),
      ),
      hostPath: '',
      cspBinding: binding,
    );
    final result = router.classifySite(
      Site(key: 'csp_Demo', name: 'Demo', type: 3, api: 'csp_Demo'),
    );
    expect(result.available, isFalse);
    expect(result.reason, contains('加固壳'));
  });
}
