/// `csp_*` 配置声明 jar 的自动探测（方案 3、`docs/reference/win-box-borrowings.md` §12.9）。
///
/// 覆盖点：
/// - 桌面 jar（无 dex / 无 .so / 入口类存在）→ 自动装入 `<csp>/<key>/`；
/// - **可转译 dex**（含 `classes.dex`、**无**原生库）→ 落盘 + 导入期预转译，
///   CLI 结论写进 `intake.json` 的 `dexTranslation`；
/// - 含**原生库**（dex + `lib/*.so`）的 Android jar → **不落盘**，但结论写进
///   `probe.json`，站点列表显示程序已试过的真实原因（不再是「请自己放 jar」）；
/// - 同一 URL 被多个站点共用时只下载一次（AT 有 90+ 站点共用 spring.jar）；
/// - 取回失败有冷却期，静态结论永久生效（重下也是同一结论）；
/// - 已导入的站点不被覆盖；
/// - 全程不启动 JVM、不加载类：预转译钩子一律注入假实现（`fakeDex`）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/csp_jar_probe.dart';
import 'package:webhtv_pc/services/dex_translate.dart';
import 'package:webhtv_pc/services/jar_intake.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/spider_registry.dart';
import 'package:webhtv_pc/services/spider_router.dart';

/// 当前修复口径的产物记录样本：presence 判定要求版本/类数/两个 SHA 都在。
Map<String, Object?> dexRecord({int? version, int classCount = 1227}) => <String, Object?>{
  'sourceSha256': 'fake-sha256',
  'bundleSha256': 'fake-sha256',
  'classCount': classCount,
  'repairVersion': version ?? DexTranslate.repairVersion,
};
void main() {
  late Directory tempRoot;
  late LogService log;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('webhtv-csp-probe');
    log = LogService();
  });

  tearDown(() async {
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {}
  });

  Site cspSite(String api, {String? key, String? jar}) => Site(
    key: key ?? api,
    name: api,
    type: 3,
    api: api,
    jar: jar,
    searchable: true,
  );

  AppConfig configOf(List<Site> sites, {String? spider}) =>
      AppConfig(name: 'csp 探测测试', sites: sites, spider: spider);

  /// 计数器：断言「同一 URL 只下一次」。
  late List<String> downloads;

  /// 假预转译的调用记录（断言「落盘后确实转译了一次」）。
  late List<String> translated;

  /// 假的预转译钩子：**绝不起 JVM**（真实 CLI 由 DexTranslate 的端到端脚本覆盖）。
  Future<Map<String, Object?>> Function({
    required String siteDir,
    required String archive,
  })
  fakeDex({bool ok = true, String stage = 'dex-转译', String message = '假的失败'}) {
    return ({required String siteDir, required String archive}) async {
      translated.add(archive);
      if (!ok) {
        return <String, Object?>{
          'ok': false,
          'stage': stage,
          'message': message,
        };
      }
      return <String, Object?>{
        'ok': true,
        'bundle': 'index.jar',
        'classCount': 1227,
        'cached': false,
        'sourceSha256': 'fake-sha256',
        'archive': archive,
      };
    };
  }

  /// 假预转译（**落盘版**）：记账之后真的把 `dexBundles/classes.jar` 写出来。
  ///
  /// 为什么要落盘：装配期预转译有没有产物，只能由文件系统证明；而幂等分支的判据
  /// 也正是这个文件（与运行期 DexNative 的约定一致）。
  Future<Map<String, Object?>> Function({
    required String siteDir,
    required String archive,
  })
  fakeDexWriting() {
    return ({required String siteDir, required String archive}) async {
      translated.add(archive);
      final bundle = File(p.join(siteDir, 'dexBundles', 'classes.jar'));
      await bundle.create(recursive: true);
      await bundle.writeAsBytes(const [0x50, 0x4b, 0x03, 0x04], flush: true);
      await File(p.join(siteDir, 'dexBundles', 'intake-dex.json'))
          .writeAsString(jsonEncode(dexRecord()), flush: true);
      return <String, Object?>{'ok': true, 'bundle': 'classes.jar'};
    };
  }

  CspJarProbe probeWith(
    http.Client client, {
    Future<Map<String, Object?>> Function({
      required String siteDir,
      required String archive,
    })?
    dexTranslate,
    Future<Map<String, Object?>> Function({
      required String shellJar,
      required String outJar,
    })?
    shellUnpack,
    // 缺省按**未安装**解包运行时处理：探测只读状态、绝不下载，测试也不需要真
    // 的 18 个 unidbg jar 存在。
    bool Function()? shellRuntimeInstalled,
  }) => CspJarProbe(
    root: p.join(tempRoot.path, 'spiders'),
    binding: CspJvmBinding(root: p.join(tempRoot.path, 'spiders', 'csp')),
    log: log,
    client: client,
    dexTranslate: dexTranslate ?? fakeDex(),
    shellUnpack: shellUnpack,
    shellRuntimeInstalled: shellRuntimeInstalled ?? (() => false),
  );

  CspJvmBinding binding() =>
      CspJvmBinding(root: p.join(tempRoot.path, 'spiders', 'csp'));

  Future<Uint8List> desktopJar() async {
    final file = File(p.join(tempRoot.path, 'desktop.jar'));
    await _writeZip(file, {
      'Metadata.class': const [0xca, 0xfe, 0xba, 0xbe, 0x01],
      'Demo.class': const [0xca, 0xfe, 0xba, 0xbe, 0x02],
    });
    return file.readAsBytes();
  }

  /// 可转译 dex：含 classes.dex，**不含**任何原生库。
  Future<Uint8List> dexOnlyJar() async {
    final file = File(p.join(tempRoot.path, 'dex-only.jar'));
    await _writeZip(file, {
      'classes.dex': const [0x64, 0x65, 0x78, 0x0a, 0x30, 0x33, 0x35],
      'META-INF/MANIFEST.MF': const [0x4d, 0x61],
    });
    return file.readAsBytes();
  }

  /// 不可转译：dex + 原生库（预转译解决不了 lib/*.so，必须继续拒绝落盘）。
  Future<Uint8List> nativeJar() async {
    final file = File(p.join(tempRoot.path, 'native.jar'));
    await _writeZip(file, {
      'classes.dex': const [0x64, 0x65, 0x78, 0x0a, 0x30, 0x33, 0x35],
      'lib/arm64-v8a/libnative.so': const [0x7f, 0x45, 0x4c, 0x46],
    });
    return file.readAsBytes();
  }

  /// 加固壳 jar：`dex + assets/*.so + assets/*.guard`（wex 形态）。
  Future<Uint8List> shellJar() async {
    final file = File(p.join(tempRoot.path, 'shell.jar'));
    await _writeZip(file, {
      'classes.dex': const [0x64, 0x65, 0x78, 0x0a, 0x30, 0x33, 0x35],
      'assets/wexshinidie.guard': const [1, 2, 3],
      'assets/libwex.so': const [0x7f, 0x45, 0x4c, 0x46],
    });
    return file.readAsBytes();
  }

  /// 假解包：把 payload 写到 `outJar`（含 dex + assets/*.so + 指定类名）。
  Future<Map<String, Object?>> Function({
    required String shellJar,
    required String outJar,
  })
  fakeUnpack({
    List<String> classes = const [
      'com/github/catvod/spider/NewDouBan.class',
    ],
    bool ok = true,
    String stage = '',
    String message = '',
    void Function()? onCall,
  }) {
    return ({required String shellJar, required String outJar}) async {
      onCall?.call();
      if (!ok) {
        return <String, Object?>{
          'ok': false,
          'stage': stage,
          'message': message,
        };
      }
      await _writeZip(File(outJar), {
        'classes.dex': const [0x64, 0x65, 0x78, 0x0a, 0x30, 0x33, 0x35],
        'assets/libwex.so': const [0x7f, 0x45, 0x4c, 0x46],
        for (final name in classes) name: const [0xca, 0xfe],
      });
      return <String, Object?>{
        'ok': true,
        'payload': outJar,
        'sha256': 'payload-sha256',
        'bytes': 2048,
        'recipe': 'wex-guard',
        'asset': 'assets/wexshinidie.guard',
        'elapsedMs': 1234,
      };
    };
  }

  setUp(() {
    downloads = [];
    translated = [];
  });

  test('桌面 jar 自动装入缓存目录，站点转为可用', () async {
    final bytes = await desktopJar();
    final probe = probeWith(
      MockClient((request) async {
        downloads.add(request.url.toString());
        return http.Response.bytes(bytes, 200);
      }),
    );

    final report = await probe.materialize(
      configOf([cspSite('csp_Demo', jar: 'https://example.test/jar/demo.jar')]),
    );

    expect(report.installed, 1);
    expect(report.entries.single.outcome, CspProbeOutcome.installed);
    expect(downloads, hasLength(1));

    final entryPath = binding().entryFor('csp_Demo');
    expect(entryPath, isNotNull);
    expect(File(entryPath!).existsSync(), isTrue);
    expect(CspJvmBinding.isAndroidJar(entryPath), isFalse);

    final record = JarIntake.probeRecord(binding().directoryFor('csp_Demo'));
    expect(record, isNotNull);
    expect(record!['installed'], isTrue);
    expect(record['verdict'], JarVerdict.desktopReady.name);
  });

  test('含 classes.dex 且无原生库的 jar 落盘并预转译，结论写进 intake.json', () async {
    final bytes = await dexOnlyJar();
    final probe = probeWith(
      MockClient((request) async {
        downloads.add(request.url.toString());
        return http.Response.bytes(bytes, 200);
      }),
    );

    final report = await probe.materialize(
      configOf([
        cspSite('csp_PianDan', jar: 'https://example.test/jar/spring.jar'),
      ]),
    );

    // 新语义：可转译 dex 属于 installable，不再算 rejected。
    expect(report.installed, 1);
    expect(report.rejected, 0);
    expect(
      report.entries.single.inspection?.verdict,
      JarVerdict.translatableDex,
    );

    // 落盘 + 预转译都发生了：入口就位，钩子被调用一次。
    expect(binding().entryFor('csp_PianDan'), isNotNull);
    expect(translated, hasLength(1));
    expect(translated.single, endsWith('index.jar'));

    final intake = JarIntake.intakeRecord(
      binding().directoryFor('csp_PianDan'),
    );
    expect(intake, isNotNull);
    expect(intake!['verdict'], JarVerdict.translatableDex.name);
    final translation = intake['dexTranslation'];
    expect(translation, isA<Map<String, Object?>>());
    expect((translation as Map)['ok'], isTrue);
    expect(translation['classCount'], 1227);
    expect(translation['cached'], false);

    final record = JarIntake.probeRecord(binding().directoryFor('csp_PianDan'));
    expect(record!['verdict'], JarVerdict.translatableDex.name);
    expect(record['installed'], isTrue);
  });

  test('预转译失败不回滚落盘，只记一条 warning', () async {
    final bytes = await dexOnlyJar();
    final probe = probeWith(
      MockClient((request) async => http.Response.bytes(bytes, 200)),
      dexTranslate: fakeDex(ok: false, stage: 'dex-转译', message: 'boom'),
    );

    final report = await probe.materialize(
      configOf([cspSite('csp_Demo', jar: 'https://example.test/spring.jar')]),
    );

    // 分工：ok 只表示落盘；转译失败单独记录，不回滚已就位的入口。
    expect(report.installed, 1);
    expect(binding().entryFor('csp_Demo'), isNotNull);
    final intake = JarIntake.intakeRecord(binding().directoryFor('csp_Demo'));
    expect((intake!['dexTranslation'] as Map)['ok'], isFalse);
    expect(
      log.entries.any(
        (entry) =>
            entry.level == LogLevel.warning &&
            entry.message.contains('已落盘但预转译失败') &&
            entry.message.contains('dex-转译'),
      ),
      isTrue,
    );
  });

  test('含原生库（dex + lib/*.so）的 jar 不落盘，只写结论并回显到站点列表', () async {
    final bytes = await nativeJar();
    final probe = probeWith(
      MockClient((request) async {
        downloads.add(request.url.toString());
        return http.Response.bytes(bytes, 200);
      }),
    );

    final report = await probe.materialize(
      configOf([
        cspSite('csp_PianDan', jar: 'https://example.test/jar/spring.jar'),
      ]),
    );

    expect(report.rejected, 1);
    expect(report.installed, 0);
    expect(report.entries.single.inspection?.verdict, JarVerdict.nativeLibrary);

    // 纪律：含原生库的入口永不落盘——目录里只允许有 probe.json 结论，
    // 不得出现 index.jar / classes 这类可被 JVM 加载的入口；也不该触发预转译。
    expect(binding().entryFor('csp_PianDan'), isNull);
    expect(translated, isEmpty);
    final dir = Directory(binding().directoryFor('csp_PianDan'));
    final names = dir.existsSync()
        ? dir.listSync().map((e) => p.basename(e.path)).toList()
        : <String>[];
    expect(names, ['probe.json']);

    final record = JarIntake.probeRecord(binding().directoryFor('csp_PianDan'));
    expect(record!['verdict'], JarVerdict.nativeLibrary.name);
    expect('${record['summary']}', contains('原生库'));

    final router = SpiderRouter(
      client: HttpApiClient(),
      globalHeaders: const [],
      cspBinding: binding(),
    );
    final availability = router.classifySite(
      cspSite('csp_PianDan', jar: 'https://example.test/jar/spring.jar'),
    );
    expect(availability.available, isFalse);
    expect(availability.reason, contains('自动检测失败'));
    expect(availability.reason, contains('原生库'));
  });

  test('多个站点共用一个 URL 时只下载一次', () async {
    final bytes = await dexOnlyJar();
    final probe = probeWith(
      MockClient((request) async {
        downloads.add(request.url.toString());
        return http.Response.bytes(bytes, 200);
      }),
    );

    final report = await probe.materialize(
      configOf([
        cspSite('csp_A', jar: 'https://example.test/jar/spring.jar'),
        cspSite('csp_B', jar: 'https://example.test/jar/spring.jar'),
        cspSite('csp_C', jar: 'https://example.test/jar/spring.jar'),
      ]),
    );

    expect(report.entries, hasLength(3));
    expect(downloads, hasLength(1));
  });

  test('顶层 spider 字段也算配置声明的 jar', () async {
    final bytes = await desktopJar();
    final probe = probeWith(
      MockClient((request) async => http.Response.bytes(bytes, 200)),
    );

    final report = await probe.materialize(
      configOf([cspSite('csp_Demo')], spider: 'https://example.test/s.jar'),
    );

    expect(report.installed, 1);
  });

  test('取回失败记录失败原因，冷却期内不重复请求', () async {
    final probe = probeWith(
      MockClient((request) async {
        downloads.add(request.url.toString());
        return http.Response('nope', 500);
      }),
    );

    final config = configOf([
      cspSite('csp_Demo', jar: 'https://example.test/dead.jar'),
    ]);
    final first = await probe.materialize(config);
    expect(first.failed, 1);
    expect(first.entries.single.message, contains('取回失败'));

    final record = JarIntake.probeRecord(binding().directoryFor('csp_Demo'));
    expect(record!['verdict'], 'fetchFailed');

    // 第二轮：同一 URL 在冷却期内，不得再打一遍死链。
    final second = await probe.materialize(config);
    expect(second.entries.single.outcome, CspProbeOutcome.rejected);
    expect(downloads, hasLength(1));
  });

  test('静态结论永久生效：已判 nativeLibrary 后不再重下', () async {
    final bytes = await nativeJar();
    final probe = probeWith(
      MockClient((request) async {
        downloads.add(request.url.toString());
        return http.Response.bytes(bytes, 200);
      }),
    );
    final config = configOf([
      cspSite('csp_Demo', jar: 'https://example.test/spring.jar'),
    ]);

    await probe.materialize(config);
    await probe.materialize(config);
    expect(downloads, hasLength(1));
  });

  test('已导入的站点跳过探测，不下载也不覆盖', () async {
    final bytes = await desktopJar();
    final targetDir = binding().directoryFor('csp_Demo');
    final staged = File(p.join(tempRoot.path, 'manual.jar'));
    await staged.writeAsBytes(bytes, flush: true);
    final manual = await JarIntake.install(
      sourcePath: staged.path,
      targetDir: targetDir,
      siteKey: 'csp_Demo',
    );
    expect(manual.ok, isTrue);

    final probe = probeWith(
      MockClient((request) async {
        downloads.add(request.url.toString());
        return http.Response.bytes(bytes, 200);
      }),
    );
    final report = await probe.materialize(
      configOf([cspSite('csp_Demo', jar: 'https://example.test/demo.jar')]),
    );

    expect(report.entries.single.outcome, CspProbeOutcome.skippedInstalled);
    expect(downloads, isEmpty);
  });

  test('已有自己运行时的站点（CatVod 壳）不参与 JVM 探测', () async {
    // AT 的顶层 spider 指向 spring.jar；壳站点的 api 只是壳名 csp_PyProxy，
    // 没有「声明 jar」的语义，若被 effectiveJar 兜到就会白下一份 spring.jar。
    final probe = probeWith(
      MockClient((request) async {
        downloads.add(request.url.toString());
        return http.Response('x', 200);
      }),
    );
    final report = await probe.materialize(
      configOf([
        Site(
          key: 'py',
          name: 'PyProxy',
          type: 3,
          api: 'csp_PyProxy',
          ext: {'loader': 'https://example.test/Atvp.py?v=1'},
        ),
      ], spider: 'https://example.test/spring.jar'),
    );

    expect(report.isEmpty, isTrue);
    expect(downloads, isEmpty);
  });

  test('配置里没有 csp_ 站点时不做任何事', () async {
    final probe = probeWith(
      MockClient((request) async {
        downloads.add(request.url.toString());
        return http.Response('x', 200);
      }),
    );
    final report = await probe.materialize(
      configOf([
        Site(key: 'http', name: 'http', type: 4, api: 'https://x.test/api'),
      ]),
    );

    expect(report.isEmpty, isTrue);
    expect(downloads, isEmpty);
  });

  group('JarSourceSpec：TVBox 的 ;md5; 后缀', () {
    test('解析 URL 与 md5', () {
      final spec = JarSourceSpec.parse(
        'http://192.168.50.50:3000/custom_spider.jar?token=abc;md5;'
        'cc3b3d2ddf389338b62eccd4a938b610',
      );
      expect(spec, isNotNull);
      expect(
        spec!.url,
        'http://192.168.50.50:3000/custom_spider.jar?token=abc',
      );
      expect(spec.md5, 'cc3b3d2ddf389338b62eccd4a938b610');
    });

    test('非 http(s) 或空值不接受', () {
      expect(JarSourceSpec.parse(null), isNull);
      expect(JarSourceSpec.parse('  '), isNull);
      expect(JarSourceSpec.parse(r'C:\\spiders\\a.jar'), isNull);
    });

    test('md5 不匹配**不再拒绝**：按内容继续判定并装好', () async {
      // 用户原话：「能下载但 md5 不符，这个不校验」。
      // TVBox 生态里服务端重新打包却不更新配置的 md5 极常见，按它拒绝
      // 只会丢掉本来能用的入口；真正判据是 JarIntake 的静态检测。
      final bytes = await desktopJar();
      final probe = probeWith(
        MockClient((request) async => http.Response.bytes(bytes, 200)),
      );
      final report = await probe.materialize(
        configOf([
          cspSite(
            'csp_Demo',
            jar:
                'https://example.test/demo.jar;md5;'
                '00000000000000000000000000000000',
          ),
        ]),
      );

      expect(report.installed, 1);
      expect(report.rejected, 0);
      expect(binding().entryFor('csp_Demo'), isNotNull);
      final record = JarIntake.probeRecord(binding().directoryFor('csp_Demo'));
      expect(record!['declaredMd5'], '00000000000000000000000000000000');
      expect(record['actualMd5'], isNot('00000000000000000000000000000000'));
      expect(record['verdict'], isNot('checksumMismatch'));
      expect('${record['summary']}', contains('已忽略'));
    });

    test('旧版本写下的 checksumMismatch 结论立即失效并重下', () async {
      final bytes = await desktopJar();
      final downloads = <String>[];
      final probe = probeWith(
        MockClient((request) async {
          downloads.add(request.url.toString());
          return http.Response.bytes(bytes, 200);
        }),
      );
      // 模拟旧版本留下的结论。
      await JarIntake.writeProbe(binding().directoryFor('csp_Demo'), {
        'siteKey': 'csp_Demo',
        'sourceUrl': 'https://example.test/demo.jar',
        'declaredMd5': 'cc3b3d2ddf389338b62eccd4a938b610',
        'fetchedAt': DateTime.now().toIso8601String(),
        'verdict': 'checksumMismatch',
        'summary': '配置声明的 md5 与实际内容不一致',
      });

      final report = await probe.materialize(
        configOf([
          cspSite(
            'csp_Demo',
            jar:
                'https://example.test/demo.jar;md5;'
                'cc3b3d2ddf389338b62eccd4a938b610',
          ),
        ]),
      );

      expect(downloads, hasLength(1), reason: '旧结论不得阻止重新取回');
      expect(report.installed, 1);
      expect(binding().entryFor('csp_Demo'), isNotNull);
    });

    test('旧口径写下的 androidJar 结论立即失效：P1-2 前含 dex 的 jar 现在可转译', () async {
      final bytes = await dexOnlyJar();
      final downloads = <String>[];
      final probe = probeWith(
        MockClient((request) async {
          downloads.add(request.url.toString());
          return http.Response.bytes(bytes, 200);
        }),
        dexTranslate: ({required siteDir, required archive}) async => {
          'ok': true,
          'classCount': 1227,
          'cached': false,
        },
      );
      // 模拟 P1-2 之前留下的结论：当时含 classes.dex 一律判 androidJar。
      // 该结论没有 semanticsVersion，按新口径必须失效，否则站点永久卡在不可用。
      await JarIntake.writeProbe(binding().directoryFor('csp_Demo'), {
        'siteKey': 'csp_Demo',
        'sourceUrl': 'https://example.test/demo.jar',
        'declaredMd5': null,
        'fetchedAt': DateTime.now().toIso8601String(),
        'verdict': 'androidJar',
        'entryCount': 2,
        'summary': '该入口是 Android 站源（内含 classes.dex），JVM 无法加载。',
        'installed': false,
      });

      final report = await probe.materialize(
        configOf([cspSite('csp_Demo', jar: 'https://example.test/demo.jar')]),
      );

      expect(downloads, hasLength(1), reason: '旧口径结论不得阻止重新取回');
      expect(
        report.installed,
        1,
        reason: '按新口径含 dex 且无原生库的入口应落盘并预转译',
      );
      expect(binding().entryFor('csp_Demo'), isNotNull);
      final record = JarIntake.probeRecord(
        binding().directoryFor('csp_Demo'),
      );
      expect(record?['semanticsVersion'], CspJarProbe.probeSemanticsVersion);
    });

    test('新结论写入 semanticsVersion，保证后续判定口径变更能识别', () async {
      final bytes = await nativeJar();
      final probe = probeWith(
        MockClient((request) async => http.Response.bytes(bytes, 200)),
      );

      await probe.materialize(
        configOf([cspSite('csp_Demo', jar: 'https://example.test/demo.jar')]),
      );

      final record = JarIntake.probeRecord(
        binding().directoryFor('csp_Demo'),
      );
      expect(record?['semanticsVersion'], CspJarProbe.probeSemanticsVersion);
      expect(record?['verdict'], JarVerdict.nativeLibrary.name);
    });
  });

  group('加固壳解包链路', () {
    test('needsShellRuntime：未安装解包运行时 → 只报结论，不下载、不落盘', () async {
      final bytes = await shellJar();
      var unpackCalls = 0;
      final probe = probeWith(
        MockClient((request) async => http.Response.bytes(bytes, 200)),
        shellRuntimeInstalled: () => false,
        shellUnpack: fakeUnpack(onCall: () => unpackCalls++),
      );

      final report = await probe.materialize(
        configOf([
          cspSite('csp_NewDouBanGuard', jar: 'https://example.test/shell.jar'),
        ]),
      );

      expect(report.needsShellRuntime, 1);
      expect(report.unpacked, 0);
      expect(unpackCalls, 0, reason: '缺运行时不能白起一次模拟器');
      expect(binding().entryFor('csp_NewDouBanGuard'), isNull);
      final dir = binding().directoryFor('csp_NewDouBanGuard');
      final record = JarIntake.probeRecord(dir);
      expect(record?['outcome'], CspProbeOutcome.needsShellRuntime.name);
      expect(record?['verdict'], JarVerdict.shellGuard.name);
      expect('${record?['summary']}', contains(CspJarProbe.shellRuntimeSizeLabel));
      expect(
        File(p.join(tempRoot.path, 'spiders', 'probe-cache', 'shell'))
            .existsSync(),
        isFalse,
        reason: '没解包就不该创建 payload 缓存目录',
      );
    });

    test('unpackFailed：解包卡在 native-注册 → 结论带阶段、不落盘', () async {
      final bytes = await shellJar();
      final probe = probeWith(
        MockClient((request) async => http.Response.bytes(bytes, 200)),
        shellRuntimeInstalled: () => true,
        shellUnpack: fakeUnpack(
          ok: false,
          stage: 'native-注册',
          message: '未找到 libwex.so',
        ),
      );

      final report = await probe.materialize(
        configOf([
          cspSite('csp_NewDouBanGuard', jar: 'https://example.test/shell.jar'),
        ]),
      );

      expect(report.unpackFailed, 1);
      expect(binding().entryFor('csp_NewDouBanGuard'), isNull);
      final dir = binding().directoryFor('csp_NewDouBanGuard');
      final record = JarIntake.probeRecord(dir);
      expect(record?['outcome'], CspProbeOutcome.unpackFailed.name);
      expect(record?['shellStage'], 'native-注册');
      expect('${record?['summary']}', contains('native-注册'));
      expect('${record?['summary']}', contains('未找到 libwex.so'));
    });

    test('解包成功：壳 jar 作入口 + payload.jar 同目录，manifest 写壳入口类', () async {
      final bytes = await shellJar();
      var unpackCalls = 0;
      final probe = probeWith(
        MockClient((request) async => http.Response.bytes(bytes, 200)),
        shellRuntimeInstalled: () => true,
        shellUnpack: fakeUnpack(onCall: () => unpackCalls++),
      );

      final report = await probe.materialize(
        configOf([
          cspSite('csp_NewDouBanGuard', jar: 'https://example.test/shell.jar'),
        ]),
      );

      expect(unpackCalls, 1);
      expect(report.unpacked, 1);
      final dir = binding().directoryFor('csp_NewDouBanGuard');
      expect(binding().entryFor('csp_NewDouBanGuard'), isNotNull);

      // 入口必须是**壳 jar**：payload 里没有壳类，拿它当入口必然 ClassNotFound（code=3）。
      final entry = File(p.join(dir, 'index.jar'));
      expect(await entry.readAsBytes(), bytes, reason: 'index.jar 必须是壳 jar');
      final payloadFile = File(p.join(dir, 'payload.jar'));
      expect(
        payloadFile.existsSync(),
        isTrue,
        reason: '解包产物要落在壳 jar 同目录，宿主 DexNative 才找得到',
      );
      expect(await payloadFile.readAsBytes(), isNot(bytes));

      // 壳与 payload 各转译进自己的目录：两者都是 classes.dex，共用会互相顶掉。
      expect(
        translated.where((archive) => archive.endsWith('index.jar')),
        isNotEmpty,
        reason: '壳 jar 要转译进 <站点>/dexBundles/',
      );
      expect(
        translated.where((archive) => archive.endsWith('payload.jar')),
        isNotEmpty,
        reason: 'payload 要转译进 <站点>/${CspJarProbe.payloadDexDirName}/',
      );

      final intake = JarIntake.intakeRecord(dir);
      expect(intake?['className'], 'com.github.catvod.spider.NewDouBanGuard');
      expect(intake?['unpackedPayload'], isTrue);
      expect(intake?['verdict'], JarVerdict.translatableDex.name);
      expect(intake?['shellEntry'], isTrue, reason: 'intake 记录要对齐真实装配');
      expect(intake?['payloadSha256'], 'payload-sha256');
      final manifest =
          jsonDecode(File(p.join(dir, 'manifest.json')).readAsStringSync())
              as Map<String, Object?>;
      expect(
        (manifest['config'] as Map<String, Object?>)['className'],
        'com.github.catvod.spider.NewDouBanGuard',
        reason: '入口是壳类；payload 的真实现由宿主 DexNative 在运行期解析',
      );
      final record = JarIntake.probeRecord(dir)!;
      expect(record['outcome'], CspProbeOutcome.unpacked.name);
      expect(record['verdict'], JarVerdict.translatableDex.name);
      final shellPayload = record['shellPayload'] as Map<String, Object?>;
      expect(shellPayload['sha256'], 'payload-sha256');
      expect(shellPayload['bytes'], 2048);
      expect(shellPayload['recipe'], 'wex-guard');
      expect(shellPayload['asset'], 'assets/wexshinidie.guard');
    });

    test('payload 预转译：产物落在 payload-dex/dexBundles/classes.jar', () async {
      final bytes = await shellJar();
      final calls = <String, String>{};
      Future<Map<String, Object?>> translate({
        required String siteDir,
        required String archive,
      }) async {
        calls[archive] = siteDir;
        // 与真实 DexTranslate 一致：产物写进 <siteDir>/dexBundles/classes.jar。
        final bundle = File(p.join(siteDir, 'dexBundles', 'classes.jar'));
        await bundle.create(recursive: true);
        await bundle.writeAsBytes(const [0x50, 0x4b, 0x03, 0x04], flush: true);
        return <String, Object?>{'ok': true, 'bundle': 'classes.jar'};
      }

      final report = await probeWith(
        MockClient((request) async => http.Response.bytes(bytes, 200)),
        shellRuntimeInstalled: () => true,
        shellUnpack: fakeUnpack(),
        dexTranslate: translate,
      ).materialize(
        configOf([
          cspSite('csp_NewDouBanGuard', jar: 'https://example.test/shell.jar'),
        ]),
      );

      expect(report.unpacked, 1);
      final dir = binding().directoryFor('csp_NewDouBanGuard');
      // 运行期 DexNative 就按这个路径取现成产物。缺了它，5-9 s 的 dex2jar 会挤进
      // 侧车握手窗口，去撞作业对象的内存上限（表现为 stderr 空、退出码 1）。
      expect(
        File(
          p.join(
            dir,
            CspJarProbe.payloadDexDirName,
            'dexBundles',
            'classes.jar',
          ),
        ).existsSync(),
        isTrue,
      );
      // 壳与 payload **各转各的目录**：payload 的产物必须与 DexNative 的约定同址。
      expect(
        calls[p.join(dir, 'payload.jar')],
        p.join(dir, CspJarProbe.payloadDexDirName),
      );
      expect(calls[p.join(dir, 'index.jar')], dir);
    });

    test('预转译抛错不影响装配：装配照旧成功，probe.json 记 installed/unpacked', () async {
      final bytes = await shellJar();
      final report = await probeWith(
        MockClient((request) async => http.Response.bytes(bytes, 200)),
        shellRuntimeInstalled: () => true,
        shellUnpack: fakeUnpack(),
        dexTranslate: ({required String siteDir, required String archive}) async {
          throw StateError('dex2jar 挂了');
        },
      ).materialize(
        configOf([
          cspSite('csp_NewDouBanGuard', jar: 'https://example.test/shell.jar'),
        ]),
      );

      // 预转译只是「把 5-9 s 挪到导入期」，运行期 DexNative 还有自译兜底：
      // 因此它失败只能记 warning，绝不能把装配一起判死。
      expect(report.unpacked, 1);
      expect(report.failed, 0);
      final dir = binding().directoryFor('csp_NewDouBanGuard');
      expect(binding().entryFor('csp_NewDouBanGuard'), isNotNull);
      expect(File(p.join(dir, 'payload.jar')).existsSync(), isTrue);
      final record = JarIntake.probeRecord(dir)!;
      expect(record['outcome'], CspProbeOutcome.unpacked.name);
      expect(record['installed'], isTrue);
    });

    test('payload-dex 已存在就不重复转译（幂等，payload 转译 0 次）', () async {
      const siteKey = 'csp_NewDouBanGuard';
      final dir = binding().directoryFor(siteKey);
      // 上一次装配留下的产物：字节内容不是一次真转译会写出来的东西，被重写就能看出来。
      final prior = File(
        p.join(dir, CspJarProbe.payloadDexDirName, 'dexBundles', 'classes.jar'),
      );
      await prior.create(recursive: true);
      await prior.writeAsBytes(const [1, 2, 3], flush: true);
      await File(p.join(dir, CspJarProbe.payloadDexDirName, 'dexBundles', 'intake-dex.json'))
          .writeAsString(jsonEncode(dexRecord()), flush: true);

      final bytes = await shellJar();
      final report = await probeWith(
        MockClient((request) async => http.Response.bytes(bytes, 200)),
        shellRuntimeInstalled: () => true,
        shellUnpack: fakeUnpack(),
        dexTranslate: fakeDexWriting(),
      ).materialize(
        configOf([cspSite(siteKey, jar: 'https://example.test/shell.jar')]),
      );

      expect(report.unpacked, 1);
      expect(
        translated.where((archive) => archive.endsWith('payload.jar')),
        isEmpty,
        reason: 'payload-dex 已就位还重跑 dex2jar，就是白等 5-9 s',
      );
      // 壳没有这层幂等（壳 jar 换了而产物还在 = 入口类过期），所以壳仍然转译一次。
      expect(
        translated.where((archive) => archive.endsWith('index.jar')),
        hasLength(1),
      );
      expect(await prior.readAsBytes(), const [1, 2, 3]);
    });

    test('payload-dex 记录是旧修复口径时重新转译（旧产物不能当成已就位）', () async {
      const siteKey = 'csp_NewDouBanGuard';
      final dir = binding().directoryFor(siteKey);
      final bundle = File(
        p.join(dir, CspJarProbe.payloadDexDirName, 'dexBundles', 'classes.jar'),
      );
      await bundle.create(recursive: true);
      await bundle.writeAsBytes(const [1, 2, 3], flush: true);
      await File(p.join(dir, CspJarProbe.payloadDexDirName, 'dexBundles', 'intake-dex.json'))
          .writeAsString(jsonEncode(dexRecord(version: 3)), flush: true);

      final bytes = await shellJar();
      final report = await probeWith(
        MockClient((request) async => http.Response.bytes(bytes, 200)),
        shellRuntimeInstalled: () => true,
        shellUnpack: fakeUnpack(),
        dexTranslate: fakeDexWriting(),
      ).materialize(
        configOf([cspSite(siteKey, jar: 'https://example.test/shell.jar')]),
      );

      expect(
        translated.where((archive) => archive.endsWith('payload.jar')),
        hasLength(1),
        reason: '旧口径产物带着已修的误译，复用等于让用户永远撞同一个崩溃',
      );
      expect(report.unpacked, 1, reason: '需要重译只是再转一次，不是永久失败');
    });
    test('壳入口装配不看 payload 类名：对不上也按壳类名装（猜错只会变成 code=3）', () async {
      final bytes = await shellJar();
      final probe = probeWith(
        MockClient((request) async => http.Response.bytes(bytes, 200)),
        shellRuntimeInstalled: () => true,
        shellUnpack: fakeUnpack(classes: const ['a/b/Other.class']),
      );

      final report = await probe.materialize(
        configOf([
          cspSite('csp_NewDouBanGuard', jar: 'https://example.test/shell.jar'),
        ]),
      );

      expect(report.unpacked, 1);
      final dir = binding().directoryFor('csp_NewDouBanGuard');
      expect(
        JarIntake.intakeRecord(dir)?['className'],
        'com.github.catvod.spider.NewDouBanGuard',
        reason: 'App 侧只写壳入口类；payload 里叫什么都不影响装配',
      );
      expect(File(p.join(dir, 'payload.jar')).existsSync(), isTrue);
      expect(
        await File(p.join(dir, 'index.jar')).readAsBytes(),
        bytes,
        reason: '入口仍然是壳 jar',
      );
    });

    test('入口类名解析：api 去 csp_ 保留 Guard，壳入口再补包名', () {
      expect(
        CspJarProbe.entryClassNameOf(cspSite('csp_WexHanXiaoQuanGuard')),
        'WexHanXiaoQuanGuard',
        reason: '裸名照旧按 api 推导；payload 的真实现由宿主 DexNative 解析',
      );
      expect(
        CspJarProbe.qualifyClassName('WexHanXiaoQuanGuard'),
        'com.github.catvod.spider.WexHanXiaoQuanGuard',
        reason: '壳入口写 manifest 前补包名（省掉宿主的裸类名回退）',
      );
      expect(
        CspJarProbe.qualifyClassName('com.github.catvod.spider.Demo'),
        'com.github.catvod.spider.Demo',
        reason: '已是全限定名不再重复补包名',
      );
    });

    test('同一壳 jar 只解包一次：第二个站点命中 payload 缓存', () async {
      final bytes = await shellJar();
      var unpackCalls = 0;
      final probe = probeWith(
        MockClient((request) async => http.Response.bytes(bytes, 200)),
        shellRuntimeInstalled: () => true,
        shellUnpack: fakeUnpack(onCall: () => unpackCalls++),
      );

      final report = await probe.materialize(
        configOf([
          cspSite('csp_SiteA', jar: 'https://example.test/shell.jar'),
          cspSite('csp_SiteB', jar: 'https://example.test/shell.jar'),
        ]),
      );

      expect(unpackCalls, 1, reason: 'payload 按壳 jar 的 SHA-256 缓存');
      expect(report.unpacked, 2);
      // 共享缓存只省「解包」，每个站点仍要有自己的 payload.jar 与壳入口（站点目录互相独立）。
      for (final key in ['csp_SiteA', 'csp_SiteB']) {
        final dir = binding().directoryFor(key);
        expect(File(p.join(dir, 'payload.jar')).existsSync(), isTrue);
        expect(
          JarIntake.intakeRecord(dir)?['className'],
          'com.github.catvod.spider.${key.substring(4)}',
          reason: '每个站点写自己的壳入口类名（api 去 csp_）',
        );
      }
    });

    test('needsShellRuntime 不是永久结论：装好运行时的下一轮会重试解包', () async {
      final bytes = await shellJar();
      // 先按「未安装」跑一轮，写下 needsShellRuntime。
      await probeWith(
        MockClient((request) async => http.Response.bytes(bytes, 200)),
        shellRuntimeInstalled: () => false,
        shellUnpack: fakeUnpack(),
      ).materialize(
        configOf([
          cspSite('csp_NewDouBanGuard', jar: 'https://example.test/shell.jar'),
        ]),
      );
      expect(
        JarIntake.probeRecord(
          binding().directoryFor('csp_NewDouBanGuard'),
        )?['outcome'],
        CspProbeOutcome.needsShellRuntime.name,
      );

      // 装上运行时后：同一份配置必须重新取回并真的解包，而不是被旧结论挡掉。
      final downloads = <String>[];
      final report = await probeWith(
        MockClient((request) async {
          downloads.add(request.url.toString());
          return http.Response.bytes(bytes, 200);
        }),
        shellRuntimeInstalled: () => true,
        shellUnpack: fakeUnpack(),
      ).materialize(
        configOf([
          cspSite('csp_NewDouBanGuard', jar: 'https://example.test/shell.jar'),
        ]),
      );

      expect(downloads, hasLength(1), reason: '旧结论不得阻止重试');
      expect(report.unpacked, 1);
    });

    test('probeSemanticsVersion 升到 5：装配口径变更后旧结论必须失效', () async {
      // 4 → 5 的原因：加固壳站点改为「壳 jar 作入口 + payload.jar 同目录」
      // （此前把解包产物直接当入口——壳类不在 payload 里，站点必然 code=3）。
      expect(CspJarProbe.probeSemanticsVersion, 5);
      final bytes = await shellJar();
      final probe = probeWith(
        MockClient((request) async => http.Response.bytes(bytes, 200)),
        shellRuntimeInstalled: () => false,
        shellUnpack: fakeUnpack(),
      );
      await probe.materialize(
        configOf([
          cspSite('csp_NewDouBanGuard', jar: 'https://example.test/shell.jar'),
        ]),
      );
      final record = JarIntake.probeRecord(
        binding().directoryFor('csp_NewDouBanGuard'),
      );
      expect(record?['semanticsVersion'], 5);
    });

    test('旧口径装好的壳站点会按新装配重装，不用用户手删目录', () async {
      const url = 'https://example.test/shell.jar';
      const siteKey = 'csp_NewDouBanGuard';
      final dir = binding().directoryFor(siteKey);
      await Directory(dir).create(recursive: true);
      // 模拟 4 口径留下的目录：index.jar 是 payload（壳类不在里面），probe.json 是旧版本。
      await File(p.join(dir, 'index.jar')).writeAsBytes(const [1, 2, 3], flush: true);
      await JarIntake.writeProbe(dir, {
        'siteKey': siteKey,
        'sourceUrl': url,
        'semanticsVersion': 4,
        'verdict': JarVerdict.translatableDex.name,
        'outcome': CspProbeOutcome.unpacked.name,
        'summary': '已解包并导入（payload 3 字节）',
        'installed': true,
        'shellPayload': {'sha256': 'payload-sha256', 'bytes': 2048},
      });
      expect(binding().entryFor(siteKey), isNotNull, reason: '前提：目录里已有入口');

      final bytes = await shellJar();
      final report = await probeWith(
        MockClient((request) async => http.Response.bytes(bytes, 200)),
        shellRuntimeInstalled: () => true,
        shellUnpack: fakeUnpack(),
      ).materialize(configOf([cspSite(siteKey, jar: url)]));

      expect(
        report.unpacked,
        1,
        reason: '旧装配不是「已装好」：必须重装成壳入口，否则站点永远 code=3',
      );
      expect(
        await File(p.join(dir, 'index.jar')).readAsBytes(),
        bytes,
        reason: '重装后入口是壳 jar',
      );
      expect(File(p.join(dir, 'payload.jar')).existsSync(), isTrue);
      expect(
        (jsonDecode(File(p.join(dir, 'manifest.json')).readAsStringSync())
                as Map<String, Object?>)['config'],
        {'className': 'com.github.catvod.spider.NewDouBanGuard'},
      );
    });
  });

  group('加固壳目标（多选解包）', () {
    const shellUrlA = 'https://example.test/shell-a.jar';
    const shellUrlB = 'https://example.test/shell-b.jar';
    const shellUrlC = 'https://example.test/shell-c.jar';

    /// 造一个加固壳 jar：`pad` 让不同 jar 的**长度**可区分（假解包按长度决定成败）。
    Future<Uint8List> shellJarAt(String name, {int pad = 3}) async {
      final file = File(p.join(tempRoot.path, name));
      await _writeZip(file, {
        'classes.dex': const [0x64, 0x65, 0x78, 0x0a, 0x30, 0x33, 0x35],
        'assets/wexshinidie.guard': List<int>.filled(pad, 1),
        'assets/libwex.so': const [0x7f, 0x45, 0x4c, 0x46],
      });
      return file.readAsBytes();
    }

    /// 按 URL 返回不同字节：多选测试需要「不同的壳 jar 内容」。
    MockClient jarsClient(Map<String, Uint8List> byUrl, {List<String>? calls}) =>
        MockClient((request) async {
          final url = request.url.toString();
          calls?.add(url);
          final bytes = byUrl[url];
          if (bytes == null) return http.Response('missing', 404);
          return http.Response.bytes(bytes, 200);
        });

    Future<void> writePayload(String outJar, List<String> classes) => _writeZip(
      File(outJar),
      {
        'classes.dex': const [0x64, 0x65, 0x78, 0x0a, 0x30, 0x33, 0x35],
        'assets/libwex.so': const [0x7f, 0x45, 0x4c, 0x46],
        for (final name in classes) name: const [0xca, 0xfe],
      },
    );

    test('同一 jar 多站点聚合成一条 target（siteKeys 去重、排序稳定）', () async {
      final shellBytes = await shellJar();
      final desktopBytes = await desktopJar();
      final config = configOf([
        cspSite('csp_Zeta', jar: 'https://example.test/shell.jar'),
        cspSite('csp_Alpha', jar: 'https://example.test/shell.jar'),
        cspSite('csp_Alpha', jar: 'https://example.test/shell.jar'),
        cspSite('csp_Middle', jar: 'https://example.test/shell.jar'),
        cspSite('csp_Desk', jar: 'https://example.test/desktop.jar'),
      ]);
      final byUrl = {
        'https://example.test/shell.jar': shellBytes,
        'https://example.test/desktop.jar': desktopBytes,
      };
      // 先探测一次：本地暂存 jar 与 probe.json 是列举的**唯一**证据来源。
      await probeWith(
        jarsClient(byUrl),
        shellRuntimeInstalled: () => false,
      ).materialize(config);

      final calls = <String>[];
      final targets = await probeWith(
        jarsClient(byUrl, calls: calls),
        shellRuntimeInstalled: () => false,
      ).discoverShellTargets(config);

      expect(targets, hasLength(1), reason: '非加固壳的 jar 不列举');
      final target = targets.single;
      expect(target.jarUrl, 'https://example.test/shell.jar');
      expect(target.siteKeys, [
        'csp_Alpha',
        'csp_Middle',
        'csp_Zeta',
      ], reason: '同一 URL 的多个站点合成一条，去重且排序稳定');
      expect(target.state, ShellTargetState.needsRuntime);
      expect(target.jarSha256, isNotNull);
      expect(target.payloadSha256, isNull);
      expect(calls, isEmpty, reason: '列举不得触发任何下载');
    });

    test('运行时未安装：全部 needsRuntime，不创建 payload 目录、不调解包', () async {
      final bytes = await shellJar();
      const url = 'https://example.test/shell.jar';
      final config = configOf([
        cspSite('csp_Alpha', jar: url),
        cspSite('csp_Beta', jar: url),
      ]);
      var unpackCalls = 0;
      final probe = probeWith(
        jarsClient({url: bytes}),
        shellRuntimeInstalled: () => false,
        shellUnpack: fakeUnpack(onCall: () => unpackCalls++),
      );

      await probe.materialize(config);
      final targets = await probe.discoverShellTargets(config);
      expect(targets.single.state, ShellTargetState.needsRuntime);

      final report = await probe.unpackSelected(config, jarUrls: {url});
      expect(report.entries, hasLength(2));
      expect(report.needsShellRuntime, 2);
      expect(report.unpacked, 0);
      expect(unpackCalls, 0, reason: '缺运行时不能白起一次模拟器');
      expect(binding().entryFor('csp_Alpha'), isNull);
      expect(binding().entryFor('csp_Beta'), isNull);
      expect(
        Directory(
          p.join(tempRoot.path, 'spiders', 'probe-cache', 'shell'),
        ).existsSync(),
        isFalse,
        reason: '没解包就不该创建 payload 缓存目录',
      );
    });

    test('多选：只解包选中的两个 jar，单 jar 失败不影响另一个', () async {
      final bytesA = await shellJarAt('shell-a.jar', pad: 3);
      final bytesB = await shellJarAt('shell-b.jar', pad: 7);
      final bytesC = await shellJarAt('shell-c.jar', pad: 11);
      final config = configOf([
        cspSite('csp_Alpha', jar: shellUrlA),
        cspSite('csp_Beta', jar: shellUrlA),
        cspSite('csp_Gamma', jar: shellUrlB),
        cspSite('csp_Delta', jar: shellUrlC),
      ]);
      final byUrl = {shellUrlA: bytesA, shellUrlB: bytesB, shellUrlC: bytesC};
      // 先探测：三个壳 jar 落进本地暂存（运行时未安装 → 全部 needsRuntime）。
      await probeWith(
        jarsClient(byUrl),
        shellRuntimeInstalled: () => false,
      ).materialize(config);

      final unpackedSizes = <int>[];
      final probe = probeWith(
        jarsClient(byUrl),
        shellRuntimeInstalled: () => true,
        shellUnpack: ({required String shellJar, required String outJar}) async {
          final size = File(shellJar).lengthSync();
          unpackedSizes.add(size);
          if (size == bytesB.length) {
            return <String, Object?>{
              'ok': false,
              'stage': 'native-注册',
              'message': '假的失败',
            };
          }
          await writePayload(outJar, const [
            'com/github/catvod/spider/Alpha.class',
            'com/github/catvod/spider/Beta.class',
          ]);
          return <String, Object?>{
            'ok': true,
            'payload': outJar,
            'sha256': 'payload-sha',
            'bytes': 512,
            'recipe': 'wex-guard',
            'asset': 'assets/wexshinidie.guard',
          };
        },
      );

      final report = await probe.unpackSelected(
        config,
        jarUrls: {shellUrlA, shellUrlB},
      );

      expect(unpackedSizes, hasLength(2), reason: '只解包选中的两个 jar');
      expect(unpackedSizes, isNot(contains(bytesC.length)));
      expect(report.unpacked, 2, reason: 'jar A 名下两个站点都装好');
      expect(report.unpackFailed, 1, reason: 'jar B 的失败只记在它自己名下');
      expect(binding().entryFor('csp_Alpha'), isNotNull);
      expect(binding().entryFor('csp_Beta'), isNotNull);
      expect(binding().entryFor('csp_Gamma'), isNull);
      expect(binding().entryFor('csp_Delta'), isNull, reason: '未选中的 jar 不安装');
      expect(
        Directory(binding().directoryFor('csp_Delta'))
            .listSync()
            .map((entity) => p.basename(entity.path))
            .toList(),
        ['probe.json'],
        reason: '未选中的站点只有上一轮的探测结论，没有任何落盘入口',
      );
      expect(
        JarIntake.probeRecord(binding().directoryFor('csp_Delta'))?['outcome'],
        CspProbeOutcome.needsShellRuntime.name,
        reason: '未选中的 jar 结论不得被多选解包改写',
      );
      expect(
        Directory(
          p.join(
            tempRoot.path,
            'spiders',
            'probe-cache',
            'shell',
            sha256.convert(bytesC).toString(),
          ),
        ).existsSync(),
        isFalse,
        reason: '未选中的 jar 连 payload 都不该解',
      );
      final gamma = JarIntake.probeRecord(binding().directoryFor('csp_Gamma'));
      expect(gamma?['outcome'], CspProbeOutcome.unpackFailed.name);
      expect(gamma?['shellStage'], 'native-注册');
      final alpha = JarIntake.probeRecord(binding().directoryFor('csp_Alpha'));
      expect(alpha?['outcome'], CspProbeOutcome.unpacked.name);
      expect(alpha?['verdict'], JarVerdict.translatableDex.name);
    });

    test('进度：每 jar 开始 + 每阶段回调，fraction 单调不减，ETA 按阶段权重外推', () async {
      final bytesA = await shellJarAt('shell-a.jar', pad: 3);
      final bytesB = await shellJarAt('shell-b.jar', pad: 7);
      final config = configOf([
        cspSite('csp_Alpha', jar: shellUrlA),
        cspSite('csp_Beta', jar: shellUrlB),
      ]);
      final byUrl = {shellUrlA: bytesA, shellUrlB: bytesB};
      await probeWith(
        jarsClient(byUrl),
        shellRuntimeInstalled: () => false,
      ).materialize(config);

      final ticks = <ShellUnpackTick>[];
      final probe = probeWith(
        jarsClient(byUrl),
        shellRuntimeInstalled: () => true,
        shellUnpack: ({required String shellJar, required String outJar}) async {
          // 解包是真耗时动作：这里睡一小会，才能验证「ETA 会算上未开始的 jar」。
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await writePayload(outJar, const [
            'com/github/catvod/spider/Alpha.class',
            'com/github/catvod/spider/Beta.class',
          ]);
          return <String, Object?>{
            'ok': true,
            'payload': outJar,
            'sha256': 'payload-sha',
            'bytes': 512,
          };
        },
      );

      final report = await probe.unpackSelected(
        config,
        jarUrls: {shellUrlA, shellUrlB},
        onProgress: ticks.add,
      );

      expect(report.unpacked, 2);
      expect(ticks, isNotEmpty);
      expect(ticks.every((tick) => tick.jarCount == 2), isTrue);
      expect(ticks.map((tick) => tick.jarIndex).toSet(), {0, 1});

      // 每个 jar 开始都有一条 tick；首个事件不是 0（与 sidecar 的含当前阶段权重同口径）。
      expect(ticks.first.stage, 'shell-读取');
      expect(ticks.first.jarIndex, 0);
      expect(ticks.first.fraction, greaterThan(0));
      expect(ticks.first.fraction, lessThan(0.1));
      for (final index in [0, 1]) {
        expect(
          ticks.any((tick) => tick.jarIndex == index && tick.stage == 'shell-读取'),
          isTrue,
          reason: '每个 jar 开始都要回调',
        );
      }

      // 每个阶段至少一次（阶段名与 CLI 的 STAGES 一字不差）。
      for (final stage in [
        'recipe-识别',
        'emulator-启动',
        '解包-调用',
        'payload-校验',
        'payload-落盘',
      ]) {
        expect(
          ticks.any((tick) => tick.stage == stage),
          isTrue,
          reason: '缺少阶段 $stage 的回调',
        );
      }

      // 数据太薄不给 ETA；中间阶段给 ETA。
      expect(ticks.first.eta, isNull, reason: '只有「读取」的数据太薄，ETA 必须是 null');
      final identify = ticks.firstWhere((tick) => tick.stage == 'recipe-识别');
      expect(identify.eta, isNull, reason: '刚认出配方时同样太薄');
      final started = ticks.firstWhere((tick) => tick.stage == 'emulator-启动');
      expect(started.eta, isNotNull, reason: '中间阶段必须给出 ETA');
      final mid = ticks.firstWhere((tick) => tick.stage == '解包-调用');
      expect(mid.eta, isNotNull, reason: '中间阶段必须给出 ETA');
      expect(mid.fraction, greaterThan(0));

      // 跨 jar：第一个 jar 落盘时后面还有一整个 jar 没开始，ETA 不能归零。
      final firstJarStore = ticks.firstWhere(
        (tick) => tick.jarIndex == 0 && tick.stage == 'payload-落盘',
      );
      expect(
        firstJarStore.eta,
        isNotNull,
        reason: '最后一个阶段也要给出 ETA',
      );
      expect(
        firstJarStore.eta! > Duration.zero,
        isTrue,
        reason: '未开始的 jar 要按已完成 jar 的耗时折算进总体剩余',
      );
      expect(ticks.last.eta, Duration.zero, reason: '最后一个 jar 收尾时剩余为 0');

      for (var i = 1; i < ticks.length; i++) {
        expect(
          ticks[i].fraction,
          greaterThanOrEqualTo(ticks[i - 1].fraction),
          reason: 'fraction 不得倒退',
        );
      }
      expect(ticks.last.fraction, 1.0);
    });

    test('payload 命中缓存时不再调解包（runner 调用次数为 0）', () async {
      final bytes = await shellJar();
      const url = 'https://example.test/shell.jar';
      final urlSha = sha256.convert(utf8.encode(url)).toString();
      final staged = File(
        p.join(
          tempRoot.path,
          'spiders',
          'probe-cache',
          '${urlSha.substring(0, 16)}.jar',
        ),
      );
      await staged.create(recursive: true);
      await staged.writeAsBytes(bytes, flush: true);
      final jarSha = sha256.convert(bytes).toString();
      final payload = File(
        p.join(
          tempRoot.path,
          'spiders',
          'probe-cache',
          'shell',
          jarSha,
          'payload.jar',
        ),
      );
      await payload.create(recursive: true);
      await writePayload(payload.path, const [
        'com/github/catvod/spider/Alpha.class',
      ]);

      final config = configOf([cspSite('csp_Alpha', jar: url)]);
      final targets = await probeWith(
        jarsClient({url: bytes}),
        shellRuntimeInstalled: () => true,
      ).discoverShellTargets(config);
      expect(targets.single.state, ShellTargetState.unpacked);
      expect(targets.single.jarSha256, jarSha);
      expect(targets.single.payloadSha256, isNotNull);

      var unpackCalls = 0;
      final probe = probeWith(
        jarsClient({url: bytes}),
        shellRuntimeInstalled: () => true,
        shellUnpack: fakeUnpack(onCall: () => unpackCalls++),
      );
      final report = await probe.unpackSelected(config, jarUrls: {url});
      expect(unpackCalls, 0, reason: 'payload 已缓存：不重复起模拟器');
      expect(report.unpacked, 1);
      expect(binding().entryFor('csp_Alpha'), isNotNull);

      // 装好之后再列举：状态推进到 installed（UI 据此收起「解包」按钮）。
      final after = await probe.discoverShellTargets(config);
      expect(after.single.state, ShellTargetState.installed);
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
