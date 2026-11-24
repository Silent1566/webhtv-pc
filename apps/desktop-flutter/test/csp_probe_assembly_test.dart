import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/ipc_protocol.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/unidbg_runtime.dart';
import 'package:webhtv_pc/services/csp_jar_probe.dart';
import 'package:webhtv_pc/services/dex_translate.dart';
import 'package:webhtv_pc/services/jar_intake.dart';
import 'package:webhtv_pc/services/spider_registry.dart';

List<int> jar(Map<String, List<int>> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return ZipEncoder().encode(archive);
}

void main() {
  late Directory temp;
  late CspJvmBinding binding;
  const url = 'https://example.test/current.jar';
  final shell = jar({
    'classes.dex': [100, 101, 120],
    'assets/test.guard': [1],
    'lib/arm64-v8a/libtest.so': [1],
  });
  final payload = jar({
    'classes.dex': [100, 101, 120],
  });
  final config = AppConfig(
    name: 'assembly',
    sites: [
      for (var i = 0; i < 3; i++)
        Site(
          key: 'site-$i',
          name: 'site-$i',
          api: 'csp_DemoGuard',
          type: 3,
          jar: url,
        ),
    ],
  );
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('webhtv-assembly-');
    binding = CspJvmBinding(root: p.join(temp.path, 'csp'));
  });
  tearDown(() async => temp.delete(recursive: true));

  Future<Map<String, Object?>> unpack({
    required String shellJar,
    required String outJar,
  }) async {
    await File(outJar).writeAsBytes(payload);
    return {
      'ok': true,
      'sha256': sha256.convert(payload).toString(),
      'bytes': payload.length,
    };
  }

  Future<Map<String, Object?>> strictTranslate({
    required String siteDir,
    required String archive,
  }) async {
    if (!Directory(siteDir).existsSync()) {
      return {'ok': false, 'stage': 'dex-读取', 'message': '站点目录不存在：$siteDir'};
    }
    final dir = Directory(p.join(siteDir, 'dexBundles'))
      ..createSync(recursive: true);
    final bundle = File(p.join(dir.path, 'classes.jar'))
      ..writeAsBytesSync([1, 2, 3]);
    final record = <String, Object?>{
      'ok': true,
      'repairVersion': DexTranslate.repairVersion,
      'classCount': 1,
      'sourceSha256': sha256
          .convert(File(archive).readAsBytesSync())
          .toString(),
      'bundleSha256': sha256.convert(bundle.readAsBytesSync()).toString(),
      'bundle': bundle.path,
    };
    File(p.join(dir.path, 'intake-dex.json'))
        .writeAsStringSync(jsonEncode(record));
    return record;
  }

  CspJarProbe probe({
    Future<Map<String, Object?>> Function({
      required String shellJar,
      required String outJar,
    })?
    runner,
    Future<Map<String, Object?>> Function({
      required String siteDir,
      required String archive,
    })?
    translate,
    http.Client? client,
  }) => CspJarProbe(
    root: temp.path,
    binding: binding,
    shellRuntimeInstalled: () => true,
    client: client ?? MockClient((_) async => http.Response.bytes(shell, 200)),
    shellUnpack: runner ?? unpack,
    dexTranslate: translate ?? strictTranslate,
  );

  test('creates exact payload-dex siteDir before CLI precondition', () async {
    final report = await probe().materialize(config);
    expect(report.unpacked, 3);
    for (final site in config.sites) {
      final dir = binding.directoryFor(site.key);
      expect(
        File(p.join(dir, 'dexBundles', 'classes.jar')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(dir, 'payload-dex', 'dexBundles', 'classes.jar'))
            .existsSync(),
        isTrue,
        reason: 'DexIntakeCli requires the exact siteDir to exist',
      );
    }
  });

  test(
    'later same SHA success repairs earlier timeout without third unpack',
    () async {
      var calls = 0;
      final report = await probe(
        runner: ({required shellJar, required outJar}) async {
          if (++calls == 1) {
            return {'ok': false, 'stage': '解包-调用', 'message': 'timeout'};
          }
          return unpack(shellJar: shellJar, outJar: outJar);
        },
      ).materialize(config);
      expect(calls, 2);
      expect(report.unpackFailed, 0);
      expect(report.unpacked, 3);
      expect(
        JarIntake.probeRecord(binding.directoryFor('site-0'))?['outcome'],
        'unpacked',
      );
    },
  );

  test('same SHA repeated failure is bounded to two emulations', () async {
    var calls = 0;
    final report = await probe(
      runner: ({required shellJar, required outJar}) async {
        calls++;
        return {'ok': false, 'stage': '解包-调用', 'message': 'timeout'};
      },
    ).materialize(config);
    expect(calls, 2);
    expect(report.unpackFailed, 3);
  });

  test('provenance matched staged shell and payload recover offline', () async {
    final first = probe(
      runner: ({required shellJar, required outJar}) async => {
        'ok': false,
        'stage': '解包-调用',
      },
    );
    await first.materialize(
      AppConfig(name: 'one', sites: [config.sites.first]),
    );
    final shellSha = sha256.convert(shell).toString();
    final cache = File(
      p.join(temp.path, 'probe-cache', 'shell', shellSha, 'payload.jar'),
    );
    await cache.writeAsBytes(payload);
    var downloads = 0;
    final report = await probe(
      client: MockClient((_) async {
        downloads++;
        return http.Response('', 503);
      }),
      runner: ({required shellJar, required outJar}) async =>
          throw StateError('must not unpack'),
    ).materialize(AppConfig(name: 'one', sites: [config.sites.first]));
    expect(downloads, 0);
    expect(report.unpacked, 1);
  });

  test(
    'deferred translation is explicit without inventing fully ready success',
    () async {
      final report = await probe(
        translate: ({required siteDir, required archive}) async => {
          'ok': false,
          'stage': 'dex-转译',
          'message': 'fixture failure',
        },
      ).materialize(config);
      expect(
        report.unpacked,
        3,
        reason: 'load-time fallback is an existing contract',
      );
      for (final entry in report.entries) {
        expect(entry.message, contains('预转译未完成'));
        final record = JarIntake.probeRecord(
          binding.directoryFor(entry.siteKey),
        );
        expect(record?['pretranslationDeferred'], isTrue);
        expect(record?['pretranslationReasons'], isNotEmpty);
      }
    },
  );

  test('shared artifact translates each content only once', () async {
    final calls = <String, int>{};
    final report = await probe(
      translate: ({required siteDir, required archive}) async {
        final hash = sha256.convert(File(archive).readAsBytesSync()).toString();
        calls.update(hash, (n) => n + 1, ifAbsent: () => 1);
        return strictTranslate(siteDir: siteDir, archive: archive);
      },
    ).materialize(config);
    expect(report.unpacked, 3);
    expect(calls.values, everyElement(1));
    expect(calls, hasLength(2));
  });

  test('automatic progress is monotonic honest and observer safe', () async {
    final ticks = <ShellUnpackTick>[];
    final report = await probe().materialize(
      config,
      onProgress: (tick) {
        ticks.add(tick);
        if (tick.fraction == 1) {
          for (final site in config.sites) {
            expect(
              File(p.join(binding.directoryFor(site.key), 'payload.jar'))
                  .existsSync(),
              isTrue,
            );
          }
        }
        throw StateError('observer failure');
      },
    );
    expect(report.unpacked, 3);
    expect(ticks.first.fraction, 0);
    expect(ticks.first.eta, isNull);
    expect(ticks.last.fraction, 1);
    final assembly = ticks.where((tick) => tick.stage == '装配-翻译').toList();
    expect(assembly, isNotEmpty);
    expect(
      assembly.every((tick) => tick.eta == null && tick.fraction < 1),
      isTrue,
    );
    // Measured site rate must produce a real estimate once a site has finished.
    // 最后一条「站点-完成」已经没有剩余工作，如实不报估算；只看还有后续的边界。
    final afterFirstSite = ticks.where(
      (tick) => tick.stage == '站点-完成' && tick.jarIndex + 1 < tick.jarCount,
    );
    expect(afterFirstSite, isNotEmpty);
    expect(
      afterFirstSite.every((tick) => tick.eta != null),
      isTrue,
      reason: 'per-site measured rate is available after one site',
    );
    for (var i = 1; i < ticks.length; i++) {
      expect(ticks[i].fraction, greaterThanOrEqualTo(ticks[i - 1].fraction));
    }
    final cached = <ShellUnpackTick>[];
    await probe().materialize(config, onProgress: cached.add);
    expect(cached.first.fraction, 0);
    expect(cached.last.fraction, 1);
    final empty = <ShellUnpackTick>[];
    await probe().materialize(
      AppConfig(name: 'empty', sites: []),
      onProgress: empty.add,
    );
    expect(empty.last.fraction, 1);
  });

  test('cached success repairs missing installation without network', () async {
    await probe().materialize(
      AppConfig(name: 'one', sites: [config.sites.first]),
    );
    await File(p.join(binding.directoryFor('site-0'), 'index.jar')).delete();
    var downloads = 0;
    final report = await probe(
      client: MockClient((_) async {
        downloads++;
        return http.Response('', 503);
      }),
    ).materialize(AppConfig(name: 'one', sites: [config.sites.first]));
    expect(report.unpacked, 1);
    expect(binding.entryFor('site-0'), isNotNull);
    expect(downloads, 0);
  });

  test(
    'real current shell materialize CLI and installed-class host smoke',
    () async {
      final scratch = Platform.environment['WEBHTV_ASSEMBLY_SMOKE_ROOT'];
      if (scratch == null) return;
      final root = Directory(scratch)..createSync(recursive: true);
      final shellPath = Platform.environment['WEBHTV_ASSEMBLY_SHELL']!;
      final bytes = File(shellPath).readAsBytesSync();
      expect(
        sha256.convert(bytes).toString(),
        'b37ece698e1e4b084a903076ce0c227546b226ade7eb971952b49218d7d53cbe',
      );
      final installed = CspJvmBinding(root: p.join(root.path, 'csp'));
      final current = AppConfig(
        name: 'isolated',
        sites: [
          Site(
            key: '初中课堂',
            name: '初中课堂',
            type: 3,
            api: 'csp_BiliGuard',
            jar: url,
          ),
        ],
      );
      LogService.logDirectoryOverride = p.join(root.path, 'logs');
      final log = LogService();
      final clock = Stopwatch()..start();
      var heartbeats = 0;
      var previousHeartbeatMs = 0;
      var maxGapMs = 0;
      final heartbeat = Timer.periodic(const Duration(milliseconds: 20), (_) {
        final now = clock.elapsedMilliseconds;
        final gap = now - previousHeartbeatMs;
        if (gap > maxGapMs) maxGapMs = gap;
        previousHeartbeatMs = now;
        heartbeats++;
      });
      addTearDown(heartbeat.cancel);
      final probe = CspJarProbe(
        root: root.path,
        binding: installed,
        log: log,
        client: MockClient((_) async => http.Response.bytes(bytes, 200)),
        unidbgRuntime: UnidbgRuntime(
          dirProvider: () => Directory(
            p.join(Platform.environment['LOCALAPPDATA']!, 'webhtv-pc'),
          ),
        ),
      );
      final report = await probe.materialize(
        current,
        onProgress: (tick) => debugPrint(
          'SMOKE_TICK elapsed=${clock.elapsedMilliseconds}ms stage=${tick.stage} fraction=${tick.fraction} eta=${tick.eta}',
        ),
      );
      debugPrint(
        'SMOKE_REPORT elapsed=${clock.elapsedMilliseconds}ms unpacked=${report.unpacked} failed=${report.unpackFailed}',
      );
      for (final entry in log.entries) {
        debugPrint(entry.message);
      }
      debugPrint(
        'SMOKE_OUTCOME ${report.entries.map((e) => e.outcome.name).toList()}',
      );
      expect(
        report.unpacked,
        1,
        reason: 'opt-in smoke requires fresh cold scratch',
      );
      debugPrint('SMOKE_HEARTBEAT count=$heartbeats maxGap=${maxGapMs}ms');
      final site = installed.directoryFor(current.sites.single.key);
      for (final path in ['dexBundles', 'payload-dex/dexBundles']) {
        expect(File(p.join(site, path, 'classes.jar')).existsSync(), isTrue);
        final record = jsonDecode(
          File(p.join(site, path, 'intake-dex.json')).readAsStringSync(),
        ) as Map;
        debugPrint(
          'SMOKE_BUNDLE dir=$path classes=${record['classCount']} repairVersion=${record['repairVersion']} sourceSha=${record['sourceSha256']} bundleSha=${record['bundleSha256']}',
        );
        expect(
          DexTranslate.recordUsable(p.join(site, path, 'intake-dex.json')),
          isTrue,
        );
      }
      final actualPayload = File(p.join(site, 'payload.jar'));
      expect(
        sha256.convert(actualPayload.readAsBytesSync()).toString(),
        '371ebdd75efb8ae76ebecffb07ed5d2a6e99e195c1a01e6523e2c5075f7a8d7a',
      );
      expect(JarIntake.probeRecord(site)?['pretranslationDeferred'], isFalse);
      debugPrint(
        'SMOKE_ARTIFACT site=$site payloadSha=${sha256.convert(actualPayload.readAsBytesSync())}',
      );
      final hostClock = Stopwatch()..start();
      final manifestPath = p.join(site, 'manifest.json');
      final registry = SpiderManifestRegistry(root: root.path, log: log);
      final spider = await registry.register(manifestPath);
      expect(spider, isNotNull);
      final command = LocalSpiderCommand.resolve(
        spider: spider!,
        hostPath: '',
        jvmHostPath: defaultJvmSidecarHostPath(),
        log: log,
      );
      expect(command, isNotNull);
      expect(
        command!.arguments.where((arg) => arg == '-noverify'),
        hasLength(1),
      );
      debugPrint(
        'SMOKE_HOST_COMMAND executable=${command.executable} arguments=${command.arguments}',
      );
      final host = await Process.start(command.executable, command.arguments);
      final out = host.stdout.transform(utf8.decoder).join();
      final err = host.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      host.stdin.add(
        IpcFrameCodec.encode({
          'jsonrpc': '2.0',
          'id': 'smoke-init',
          'method': 'initialize',
          'params': {
            'abi': 'webhtv-ipc-v1',
            'abiMajor': 1,
            'abiMinor': 0,
            'siteKey': '初中课堂',
            'extend': '',
          },
        }),
      );
      await host.stdin.close();
      try {
        final exit = await host.exitCode.timeout(const Duration(seconds: 15));
        final stdout = await out;
        final stderr = await err;
        File(p.join(root.path, 'host-stdout.txt')).writeAsStringSync(stdout);
        File(p.join(root.path, 'host-stderr.txt')).writeAsStringSync(stderr);
        debugPrint(
          'SMOKE_HOST elapsed=${hostClock.elapsedMilliseconds}ms exit=$exit stdout=$stdout stderr=${stderr.length > 1800 ? stderr.substring(stderr.length - 1800) : stderr}',
        );
        expect(exit, 0);
        expect(stdout, contains('webhtv-ipc-v1'));
        expect(stdout, isNot(contains('"error"')));
        final nativeStages = log.entries
            .where((entry) => entry.message.startsWith('加固壳解包阶段'))
            .length;
        final warmClock = Stopwatch()..start();
        final warm = await probe.materialize(current);
        expect(warm.entries.single.outcome, CspProbeOutcome.skippedInstalled);
        expect(
          log.entries
              .where((entry) => entry.message.startsWith('加固壳解包阶段'))
              .length,
          nativeStages,
        );
        debugPrint(
          'SMOKE_WARM elapsed=${warmClock.elapsedMilliseconds}ms outcome=${warm.entries.single.outcome.name} newUnpackStages=0',
        );
      } finally {
        host.kill();
        await host.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () => -1,
        );
        log.dispose();
        LogService.logDirectoryOverride = null;
      }
    },
    skip: !Platform.environment.containsKey('WEBHTV_ASSEMBLY_SMOKE_ROOT'),
    timeout: const Timeout(Duration(seconds: 230)),
  );
}
