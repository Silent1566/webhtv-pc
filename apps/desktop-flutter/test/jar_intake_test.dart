/// T3（`csp_*`）桌面 JAR 站源静态检测与导入的单测（ADR-0002、
/// docs/reference/win-box-borrowings.md §12.6.4 验收口径）。
///
/// 覆盖点：
/// - 含 `classes.dex`、**无原生库** → `translatableDex`，可落盘并在导入期预转译；
/// - 含 `classes.dex` **且**含 `lib/**.so` → `nativeLibrary`（原生库拒绝优先于 dex），
///   拒绝且**不落盘**（验收① ②）；
/// - 桌面 jar（无 dex、无 .so、入口类存在）→ 落盘 `index.jar`，站点转为可用（验收③）；
/// - 损坏 / 非 zip → 明确失败且不覆盖既有文件（验收④）；
/// - 移除后回到「缺少桌面 JVM 站源」（验收⑤）；
/// - 全程不启动 JVM、不执行站源代码（验收⑥）：转译走 `translateDex` 注入的假实现；
/// - 文件内容里只是**出现** `classes.dex` 字样（不是 zip 条目）→ 不得误判（验收⑦）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/jar_intake.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/spider_registry.dart';
import 'package:webhtv_pc/services/spider_router.dart';

void main() {
  late Directory tempRoot;
  late String cspRoot;
  late LogService log;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('webhtv-jar-intake');
    cspRoot = p.join(tempRoot.path, 'spiders', 'csp');
    log = LogService();
  });

  tearDown(() async {
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {}
  });

  group('静态检测：结论分级', () {
    test('含 classes.dex 且无原生库的 jar 判为 translatableDex，可安装', () async {
      final jar = File(p.join(tempRoot.path, 'android.jar'));
      await _writeZip(jar, {
        'classes.dex': const [0x64, 0x65, 0x78],
        'AndroidManifest.xml': const [0x01],
      });

      final inspection = JarIntake.inspectPath(jar.path, expectedClass: 'Demo');
      expect(inspection.verdict, JarVerdict.translatableDex);
      expect(inspection.installable, isTrue);
      expect(inspection.dexEntries, contains('classes.dex'));
      expect(inspection.summary, contains('可在导入时转译'));
    });

    test('含 classes.dex 的**类目录**同样判为 translatableDex（旧实现漏判）', () async {
      final dir = Directory(p.join(tempRoot.path, 'android-classes'))
        ..createSync(recursive: true);
      File(p.join(dir.path, 'classes.dex')).writeAsBytesSync(const [0x64]);
      File(p.join(dir.path, 'Demo.class')).writeAsBytesSync(const [0xca, 0xfe]);

      final inspection = JarIntake.inspectPath(dir.path, expectedClass: 'Demo');
      expect(inspection.verdict, JarVerdict.translatableDex);
      expect(inspection.installable, isTrue);
      // 与站点页共用同一判定：可转译的 dex 不再算「不可转译的 Android jar」。
      expect(CspJvmBinding.isAndroidJar(dir.path), isFalse);
    });

    test('dex 与原生库并存时判为 nativeLibrary（原生库拒绝优先于 dex）', () async {
      final jar = File(p.join(tempRoot.path, 'android-native.jar'));
      await _writeZip(jar, {
        'classes.dex': const [0x64, 0x65, 0x78],
        'lib/arm64-v8a/libx.so': const [0x7f, 0x45, 0x4c, 0x46],
      });

      final inspection = JarIntake.inspectPath(jar.path, expectedClass: 'Demo');
      expect(inspection.verdict, JarVerdict.nativeLibrary);
      expect(inspection.installable, isFalse);
      expect(inspection.dexEntries, isNotEmpty);
      expect(inspection.nativeEntries, contains('lib/arm64-v8a/libx.so'));
      expect(inspection.summary, contains('原生库'));
    });

    test('桌面 jar（无 dex、无原生库）判为 desktopReady，并识别入口类', () async {
      final jar = File(p.join(tempRoot.path, 'desktop.jar'));
      await _writeZip(jar, {
        'fixture/FixtureSpider.class': const [0xca, 0xfe, 0xba, 0xbe],
        'fixture/Fixtures.class': const [0x01, 0x02],
      });

      final inspection =
          JarIntake.inspectPath(jar.path, expectedClass: 'FixtureSpider');
      expect(inspection.verdict, JarVerdict.desktopReady);
      expect(inspection.installable, isTrue);
      expect(inspection.entryClassFound, isTrue);
      expect(inspection.classEntries.length, 2);
    });

    test('入口类缺失时仍可安装，但结论里点名可能 ClassNotFound', () async {
      final jar = File(p.join(tempRoot.path, 'wrong-entry.jar'));
      await _writeZip(jar, {
        'other/OtherSpider.class': const [0xca, 0xfe],
      });

      final inspection = JarIntake.inspectPath(jar.path, expectedClass: 'Demo');
      expect(inspection.verdict, JarVerdict.desktopReady);
      expect(inspection.entryClassFound, isFalse);
      expect(inspection.summary, contains('ClassNotFound'));
    });

    test('含原生库（.so）判为 nativeLibrary，且不可安装', () async {
      final jar = File(p.join(tempRoot.path, 'native.jar'));
      await _writeZip(jar, {
        'lib/arm64-v8a/libspider.so': const [0x7f, 0x45, 0x4c, 0x46],
        'fixture/Demo.class': const [0xca, 0xfe],
      });

      final inspection = JarIntake.inspectPath(jar.path, expectedClass: 'Demo');
      expect(inspection.verdict, JarVerdict.nativeLibrary);
      expect(inspection.installable, isFalse);
      expect(inspection.nativeEntries, contains('lib/arm64-v8a/libspider.so'));
    });

    test('没有任何 class 条目时判为 missingEntryClass', () async {
      final jar = File(p.join(tempRoot.path, 'empty.jar'));
      await _writeZip(jar, {
        'AndroidManifest.xml': const [0x01, 0x02],
      });

      final inspection = JarIntake.inspectPath(jar.path);
      expect(inspection.verdict, JarVerdict.missingEntryClass);
      expect(inspection.installable, isFalse);
    });

    test('.java 源码入口判为 sourceReady（不由 csp 绑定承接）', () async {
      final file = File(p.join(tempRoot.path, 'Demo.java'))
        ..writeAsStringSync('class Demo {}');
      final inspection = JarIntake.inspectPath(file.path, expectedClass: 'Demo');
      expect(inspection.verdict, JarVerdict.sourceReady);
      expect(inspection.installable, isFalse);
    });

    test('损坏 / 非 zip 文件判为 malformed，不抛异常', () async {
      final file = File(p.join(tempRoot.path, 'broken.jar'))
        ..writeAsStringSync('这不是 zip');
      final inspection = JarIntake.inspectPath(file.path);
      expect(inspection.verdict, JarVerdict.malformed);
      expect(inspection.installable, isFalse);
    });

    test('路径不存在时判为 missingSource', () {
      final inspection = JarIntake.inspectPath(
        p.join(tempRoot.path, 'nope.jar'),
      );
      expect(inspection.verdict, JarVerdict.missingSource);
    });

    test('只是内容里出现 classes.dex 字样（非 zip 条目）不得误判（验收⑦）', () async {
      final jar = File(p.join(tempRoot.path, 'mention.jar'));
      await _writeZip(jar, {
        'fixture/Demo.class': utf8.encode('常量化字符串 classes.dex 出现在 data 段里'),
      });

      final inspection = JarIntake.inspectPath(jar.path, expectedClass: 'Demo');
      expect(inspection.verdict, JarVerdict.desktopReady);
      expect(inspection.dexEntries, isEmpty);
      expect(CspJvmBinding.isAndroidJar(jar.path), isFalse);
    });
  });

  group('导入 / 回滚', () {
    test('含原生库的入口被拒绝且**不落盘**（验收①②）', () async {
      final jar = File(p.join(tempRoot.path, 'android.jar'));
      await _writeZip(jar, {
        'classes.dex': const [0x64],
        'lib/armeabi-v7a/libspider.so': const [0x7f, 0x45, 0x4c, 0x46],
      });
      final target = p.join(cspRoot, 'csp_Demo');

      final result = await JarIntake.install(
        sourcePath: jar.path,
        targetDir: target,
        siteKey: 'csp_Demo',
        log: log,
      );

      expect(result.ok, isFalse);
      expect(result.error, contains('原生库'));
      expect(
        Directory(target).existsSync(),
        isFalse,
        reason: '被拒绝的入口不得留下任何文件',
      );
    });

    test('损坏文件被拒绝，且不覆盖已导入的桌面 jar（验收④）', () async {
      final good = File(p.join(tempRoot.path, 'good.jar'));
      await _writeZip(good, {
        'fixture/Demo.class': const [0xca, 0xfe],
      });
      final target = p.join(cspRoot, 'csp_Demo');
      final installed = await JarIntake.install(
        sourcePath: good.path,
        targetDir: target,
        siteKey: 'csp_Demo',
        log: log,
      );
      expect(installed.ok, isTrue);
      final before = File(p.join(target, 'index.jar')).readAsBytesSync();

      final broken = File(p.join(tempRoot.path, 'broken.jar'))
        ..writeAsStringSync('not a zip');
      final rejected = await JarIntake.install(
        sourcePath: broken.path,
        targetDir: target,
        siteKey: 'csp_Demo',
        log: log,
      );
      expect(rejected.ok, isFalse);
      expect(
        File(p.join(target, 'index.jar')).readAsBytesSync(),
        before,
        reason: '失败不得覆盖既有入口',
      );
    });

    test('桌面 jar 导入后 entryFor 能定位、移除后回到「缺少桌面 JVM 站源」（验收③⑤）', () async {
      final jar = File(p.join(tempRoot.path, 'desktop.jar'));
      await _writeZip(jar, {
        'fixture/Demo.class': const [0xca, 0xfe],
      });
      final binding = CspJvmBinding(root: cspRoot);
      final site = Site(key: 'csp_Demo', name: 'Demo', type: 3, api: 'csp_Demo');
      final router = SpiderRouter(
        client: HttpApiClient(),
        globalHeaders: const [],
        registry: SpiderManifestRegistry(
          root: p.join(tempRoot.path, 'spiders'),
          log: log,
        ),
        hostPath: '',
        cspBinding: binding,
      );

      final before = router.classifySite(site);
      expect(before.available, isFalse);
      expect(before.reason, contains('classes.dex'));

      final result = await JarIntake.install(
        sourcePath: jar.path,
        targetDir: binding.directoryFor('csp_Demo'),
        siteKey: 'csp_Demo',
        log: log,
      );
      expect(result.ok, isTrue);
      expect(File(p.join(result.targetPath!, 'index.jar')).existsSync(), isTrue);
      expect(binding.entryFor('csp_Demo'), isNotNull);
      expect(
        CspJvmBinding.isAndroidJar(binding.entryFor('csp_Demo')!),
        isFalse,
        reason: '桌面 jar 不得被判为 Android 站源',
      );

      expect(
        await JarIntake.remove(targetDir: binding.directoryFor('csp_Demo'), log: log),
        isTrue,
      );
      final after = router.classifySite(site);
      expect(after.available, isFalse);
      expect(after.reason, contains('classes.dex'));
    });

    test('导入写出 intake.json 记录来源与 SHA-256（可回滚、可诊断）', () async {
      final jar = File(p.join(tempRoot.path, 'desktop.jar'));
      await _writeZip(jar, {
        'fixture/Demo.class': const [0xca, 0xfe],
      });
      final target = p.join(cspRoot, 'csp_Demo');

      await JarIntake.install(
        sourcePath: jar.path,
        targetDir: target,
        siteKey: 'csp_Demo',
        log: log,
      );

      final record = JarIntake.intakeRecord(target);
      expect(record, isNotNull);
      expect(record!['siteKey'], 'csp_Demo');
      expect(record['className'], 'Demo');
      expect(record['entry'], 'index.jar');
      expect(record['verdict'], JarVerdict.desktopReady.name);
      expect((record['sourceSha256']! as String).length, 64);
    });

    test('导入必须写出可启动的 manifest.json（缺失会让 JVM 宿主以退出码 2 结束）', () async {
      final jar = File(p.join(tempRoot.path, 'launch.jar'));
      await _writeZip(jar, {
        'fixture/Demo.class': const [0xca, 0xfe],
      });
      final target = p.join(cspRoot, 'csp_Launch');

      await JarIntake.install(
        sourcePath: jar.path,
        targetDir: target,
        siteKey: 'csp_Launch',
        log: log,
      );

      final manifest = File(p.join(target, 'manifest.json'));
      expect(manifest.existsSync(), isTrue, reason: '缺 manifest 会导致 code=2');
      final decoded =
          jsonDecode(manifest.readAsStringSync()) as Map<String, Object?>;
      // 与 SpiderManifest.problems 的校验对齐：abi 必须是 webhtv-ipc-v1、key 非空。
      expect(decoded['abi'], 'webhtv-ipc-v1');
      expect(decoded['key'], 'csp_Launch');
      expect(decoded['runtime'], 'jvm');
      expect(decoded['entry'], 'index.jar');
    });

    test('ensureLaunchManifest 自愈旧导入：补写缺失的 manifest 且不覆盖已有内容', () async {
      final target = p.join(cspRoot, 'csp_Legacy');
      await Directory(target).create(recursive: true);
      File(p.join(target, 'index.jar')).writeAsBytesSync(const [0x50, 0x4b]);

      expect(File(p.join(target, 'manifest.json')).existsSync(), isFalse);
      JarIntake.ensureLaunchManifest(targetDir: target, siteKey: 'csp_Legacy');

      final manifest = File(p.join(target, 'manifest.json'));
      expect(manifest.existsSync(), isTrue);
      expect(
        (jsonDecode(manifest.readAsStringSync())
            as Map<String, Object?>)['key'],
        'csp_Legacy',
      );

      // 已有内容不得被覆盖（避免每次判定都产生写入）。
      manifest.writeAsStringSync('{"abi":"webhtv-ipc-v1","key":"csp_Manual"}');
      JarIntake.ensureLaunchManifest(targetDir: target, siteKey: 'csp_Legacy');
      expect(
        (jsonDecode(manifest.readAsStringSync())
            as Map<String, Object?>)['key'],
        'csp_Manual',
      );
    });

    test('ensureLaunchManifest 对没有入口的目录不生成 manifest', () async {
      final target = p.join(cspRoot, 'csp_Empty');
      await Directory(target).create(recursive: true);

      JarIntake.ensureLaunchManifest(targetDir: target, siteKey: 'csp_Empty');

      expect(File(p.join(target, 'manifest.json')).existsSync(), isFalse);
    });

    test('类目录入口导入为 classes/ 目录，entryFor 能定位', () async {
      final source = Directory(p.join(tempRoot.path, 'classes-src'))
        ..createSync(recursive: true);
      Directory(p.join(source.path, 'fixture')).createSync(recursive: true);
      File(p.join(source.path, 'fixture', 'Demo.class'))
        .writeAsBytesSync(const [0xca, 0xfe]);
      final target = p.join(cspRoot, 'csp_Demo');

      final result = await JarIntake.install(
        sourcePath: source.path,
        targetDir: target,
        siteKey: 'csp_Demo',
        log: log,
      );
      expect(result.ok, isTrue, reason: result.error ?? '');
      expect(Directory(p.join(target, 'classes')).existsSync(), isTrue);
      expect(File(p.join(target, 'index.jar')).existsSync(), isFalse);
      expect(CspJvmBinding(root: cspRoot).entryFor('csp_Demo'), isNotNull);
    });

    test('describeInstalled 回显已导入条目及其结论', () async {
      final jar = File(p.join(tempRoot.path, 'desktop.jar'));
      await _writeZip(jar, {
        'fixture/Demo.class': const [0xca, 0xfe],
      });
      await JarIntake.install(
        sourcePath: jar.path,
        targetDir: p.join(cspRoot, 'csp_Demo'),
        siteKey: 'csp_Demo',
        log: log,
      );

      final installed = JarIntake.describeInstalled(cspRoot);
      expect(installed.length, 1);
      expect(installed.single.siteKey, 'csp_Demo');
      expect(installed.single.inspection.verdict, JarVerdict.desktopReady);
      expect(JarIntake.installedSiteKeys(cspRoot), ['csp_Demo']);
    });

    test('remove 对不存在的目录返回 false 而不抛异常', () async {
      expect(
        await JarIntake.remove(targetDir: p.join(cspRoot, 'csp_None'), log: log),
        isFalse,
      );
    });
  });

  group('导入期预转译（translateDex 注入）', () {
    Future<File> dexJar() async {
      final jar = File(p.join(tempRoot.path, 'android.jar'));
      await _writeZip(jar, {
        'classes.dex': const [0x64, 0x65, 0x78],
      });
      return jar;
    }

    test('转译成功：落盘成功，结论写进 intake.json 的 dexTranslation', () async {
      final jar = await dexJar();
      final target = p.join(cspRoot, 'csp_Demo');
      String? seenSiteDir;
      String? seenArchive;

      final result = await JarIntake.install(
        sourcePath: jar.path,
        targetDir: target,
        siteKey: 'csp_Demo',
        log: log,
        translateDex: ({required String siteDir, required String archive}) async {
          seenSiteDir = siteDir;
          seenArchive = archive;
          return {
            'ok': true,
            'bundle': 'dex-bundle',
            'classCount': 1227,
            'cached': false,
            'sourceSha256': 'a' * 64,
          };
        },
      );

      expect(result.ok, isTrue, reason: result.error ?? '');
      expect(result.inspection!.verdict, JarVerdict.translatableDex);
      expect(result.dexTranslation?['ok'], isTrue);
      expect(File(p.join(target, 'index.jar')).existsSync(), isTrue);
      expect(seenSiteDir, target);
      expect(seenArchive, p.join(target, 'index.jar'));

      final record = JarIntake.intakeRecord(target)!;
      final translation = record['dexTranslation']! as Map<String, Object?>;
      expect(translation['ok'], isTrue);
      expect(translation['classCount'], 1227);
    });

    test('转译失败：ok 仍为 true（落盘成功），dexTranslation 记录失败原因', () async {
      final jar = await dexJar();
      final target = p.join(cspRoot, 'csp_Demo');

      final result = await JarIntake.install(
        sourcePath: jar.path,
        targetDir: target,
        siteKey: 'csp_Demo',
        log: log,
        translateDex: ({required String siteDir, required String archive}) async {
          return {'ok': false, 'stage': 'dex-转译', 'message': 'boom'};
        },
      );

      expect(result.ok, isTrue, reason: '落盘成功就不算导入失败');
      expect(result.dexTranslation?['ok'], isFalse);
      expect(result.dexTranslation?['stage'], 'dex-转译');
      expect(File(p.join(target, 'index.jar')).existsSync(), isTrue);

      final record = JarIntake.intakeRecord(target)!;
      final translation = record['dexTranslation']! as Map<String, Object?>;
      expect(translation['ok'], isFalse);
      expect(translation['stage'], 'dex-转译');
    });

    test('转译抛异常：install 不抛，结论兜底为 ok:false', () async {
      final jar = await dexJar();
      final target = p.join(cspRoot, 'csp_Demo');

      final result = await JarIntake.install(
        sourcePath: jar.path,
        targetDir: target,
        siteKey: 'csp_Demo',
        log: log,
        translateDex: ({required String siteDir, required String archive}) async {
          throw Exception('jvm 不可用');
        },
      );

      expect(result.ok, isTrue);
      expect(result.dexTranslation?['ok'], isFalse);
      expect('${result.dexTranslation?['message']}', contains('jvm 不可用'));
      expect(JarIntake.intakeRecord(target)!['dexTranslation'], isNotNull);
    });

    test('省略 translateDex：跳过转译，dexTranslation 为 null 且仍能落盘', () async {
      final jar = await dexJar();
      final target = p.join(cspRoot, 'csp_Demo');

      final result = await JarIntake.install(
        sourcePath: jar.path,
        targetDir: target,
        siteKey: 'csp_Demo',
        log: log,
      );

      expect(result.ok, isTrue, reason: result.error ?? '');
      expect(result.dexTranslation, isNull);
      expect(File(p.join(target, 'index.jar')).existsSync(), isTrue);
      expect(JarIntake.intakeRecord(target)!.containsKey('dexTranslation'), isFalse);
    });
  });
}

/// 写一个 stored（不压缩）zip：条目名与内容都可控，CRC 正确，可被 archive 解析。
Future<void> _writeZip(File file, Map<String, List<int>> entries) async {
  final builder = BytesBuilder();
  final central = <List<int>>[];
  entries.forEach((name, data) {
    final nameBytes = utf8.encode(name);
    final offset = builder.length;
    final crc = getCrc32(data);
    builder.add(_le32(0x04034b50));
    builder.add(_le16(20));
    builder.add(_le16(0));
    builder.add(_le16(0)); // method = stored
    builder.add(_le16(0));
    builder.add(_le16(0));
    builder.add(_le32(crc));
    builder.add(_le32(data.length));
    builder.add(_le32(data.length));
    builder.add(_le16(nameBytes.length));
    builder.add(_le16(0));
    builder.add(nameBytes);
    builder.add(data);
    central.add([
      ..._le32(0x02014b50),
      ..._le16(20),
      ..._le16(20),
      ..._le16(0),
      ..._le16(0),
      ..._le16(0),
      ..._le16(0),
      ..._le32(crc),
      ..._le32(data.length),
      ..._le32(data.length),
      ..._le16(nameBytes.length),
      ..._le16(0),
      ..._le16(0),
      ..._le16(0),
      ..._le16(0),
      ..._le32(0),
      ..._le32(offset),
      ...nameBytes,
    ]);
  });
  final centralStart = builder.length;
  for (final record in central) {
    builder.add(record);
  }
  final centralSize = builder.length - centralStart;
  builder.add(_le32(0x06054b50));
  builder.add(_le16(0));
  builder.add(_le16(0));
  builder.add(_le16(central.length));
  builder.add(_le16(central.length));
  builder.add(_le32(centralSize));
  builder.add(_le32(centralStart));
  builder.add(_le16(0));
  await file.writeAsBytes(builder.takeBytes());
}

List<int> _le16(int value) => [value & 0xff, (value >> 8) & 0xff];

List<int> _le32(int value) => [
  value & 0xff,
  (value >> 8) & 0xff,
  (value >> 16) & 0xff,
  (value >> 24) & 0xff,
];