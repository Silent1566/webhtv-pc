import 'dart:io';
import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/python_environment.dart';
import 'package:webhtv_pc/services/spider_process.dart';
import 'package:webhtv_pc/services/spider_registry.dart';
import 'package:webhtv_pc/state/app_state.dart';

import 'python_environment_test.dart'
    show isolatedPaths, fixtureBundle, fixtureProbe;

Future<String> treeFingerprint(String root) => Isolate.run(() {
  final files =
      Directory(root)
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return sha256
      .convert(
        utf8.encode(
          files
              .map(
                (file) =>
                    '${p.relative(file.path, from: root)}:${sha256.convert(file.readAsBytesSync())}',
              )
              .join('\n'),
        ),
      )
      .toString();
});

void main() {
  test('AppState settings switch synchronizes default resolver and preserves runtime across real cache reset', () async {
    final root = Directory.systemTemp.createTempSync('bundled_state_');
    final env = PythonEnvironment(
      paths: isolatedPaths(root),
      bundleDirectory: fixtureBundle(root),
      probe: fixtureProbe,
      systemCandidates: const [],
    );
    final state = AppState(paths: env.paths, pythonEnvironment: env);
    addTearDown(() {
      state.dispose();
      LocalSpiderCommand.preferPythonExecutable(null);
      root.deleteSync(recursive: true);
    });
    expect(await state.repairPythonEnvironment(), isTrue);
    final exe = state.pythonEnvironmentStatus!.executable;
    expect(SidecarRuntimeResolver.resolve('python')!.executable, exe);
    await state.resetCache();
    expect(File(exe).existsSync(), isTrue);
    expect(state.pythonEnvironmentStatus!.ready, isTrue);
  });
  test('real bundled CatVod home without PATH or system launcher', () async {
    final bundle = p.normalize(
      p.join(Directory.current.path, '..', '..', 'runtime', 'python'),
    );
    if (!File(p.join(bundle, 'bundle.json')).existsSync()) {
      markTestSkipped(
        'Task A native bundle not available; temp schema tests are not native proof',
      );
      return;
    }
    final root = Directory.systemTemp.createTempSync('bundled_native_');
    final readOnlyBundle = Directory(
      p.join(root.path, 'install', 'runtime', 'python'),
    )..createSync(recursive: true);
    for (final name in ['python-runtime.zip', 'bundle.json']) {
      File(p.join(bundle, name)).copySync(p.join(readOnlyBundle.path, name));
    }
    final identity = Platform.environment['USERNAME']!;
    expect(p.isWithin(root.path, readOnlyBundle.path), isTrue);
    final deny = Process.runSync('icacls', [
      readOnlyBundle.path,
      '/deny',
      '$identity:(OI)(CI)(WD,AD,WEA,WA)',
    ]);
    expect(deny.exitCode, 0, reason: '${deny.stdout}${deny.stderr}');
    expect(
      () =>
          File(p.join(readOnlyBundle.path, 'write-proof'))
              .writeAsStringSync('denied'),
      throwsA(isA<FileSystemException>()),
    );
    final env = PythonEnvironment(
      paths: isolatedPaths(root),
      bundleDirectory: readOnlyBundle.path,
      systemCandidates: const [],
      processEnvironment: {
        'PATH': '',
        'SystemRoot': Platform.environment['SystemRoot']!,
        'TEMP': root.path,
        'TMP': root.path,
      },
    );
    final state = AppState(paths: env.paths, pythonEnvironment: env);
    addTearDown(() async {
      await state.stopSpider('local');
      state.dispose();
      LocalSpiderCommand.preferPythonExecutable(null);
      final restore = Process.runSync('icacls', [
        readOnlyBundle.path,
        '/remove:d',
        identity,
        '/t',
      ]);
      expect(restore.exitCode, 0, reason: '${restore.stdout}${restore.stderr}');
      root.deleteSync(recursive: true);
    });
    final source = Directory(p.join(root.path, 'sources'))..createSync();
    File(p.join(source.path, 'local.py')).writeAsStringSync(
      'from base.spider import Spider as Base\nimport requests,Crypto,lxml,bs4,os,shutil\n'
      'assert os.environ.get("PATH")==""\nassert shutil.which("python") is None\nassert shutil.which("py") is None\n'
      'class Spider(Base):\n def homeContent(self,filter):\n  return {"list":[{"vod_id":"native","vod_name":"bundled native"}]}\n',
    );
    await state.bootstrap();
    await state.importConfig('{"sites":[]}');
    final report = await state.scanLocalSources(source.path);
    expect(
      (await state.importLocalSources(report.candidates)).importedCount,
      1,
    );
    await state.selectSite(state.siteItems.single.site);
    expect(
      state.pythonEnvironmentStatus?.ready,
      isTrue,
      reason:
          '${state.pythonEnvironmentError} / ${state.pythonEnvironmentStatus?.error}',
    );
    expect(state.lastError, isNull);
    expect(
      state.pythonEnvironmentStatus!.source,
      PythonEnvironmentSource.bundled,
    );
    expect(state.homeResult!.list.single.vodName, 'bundled native');
    expect(await state.repairPythonEnvironment(), isFalse);
    expect(state.pythonEnvironmentError, contains('正在运行'));
    expect(await state.useDefaultPythonEnvironment(), isFalse);
    final old = state.pythonEnvironmentStatus!.executable;
    await state.stopSpider('local');
    expect(await state.repairPythonEnvironment(), isTrue);
    expect(File(old).existsSync(), isTrue);
    final currentRoot = p.dirname(state.pythonEnvironmentStatus!.executable);
    final customRoot = Directory(p.join(root.path, 'user-custom'))
      ..createSync();
    for (final file in Directory(
      currentRoot,
    ).listSync(recursive: true, followLinks: false).whereType<File>()) {
      final target = File(
        p.join(customRoot.path, p.relative(file.path, from: currentRoot)),
      );
      target.parent.createSync(recursive: true);
      file.copySync(target.path);
    }
    final fingerprint = await treeFingerprint(customRoot.path);
    final custom = p.join(customRoot.path, 'python.exe');
    expect(
      await state.setCustomPythonExecutable(custom),
      isTrue,
      reason: state.pythonEnvironmentError,
    );
    await state.loadHome(state.siteItems.single.site);
    expect(state.lastError, isNull);
    expect(
      state.pythonEnvironmentStatus!.source,
      PythonEnvironmentSource.custom,
    );
    expect(state.homeResult!.list.single.vodName, 'bundled native');
    await state.stopSpider('local');
    final restart = PythonEnvironment(
      paths: env.paths,
      bundleDirectory: readOnlyBundle.path,
      systemCandidates: const [],
      processEnvironment: env.processEnvironment,
    );
    await restart.refresh();
    expect(restart.status!.ready, isTrue);
    expect(restart.status!.executable, custom);
    expect(restart.status!.source, PythonEnvironmentSource.custom);
    expect(
      await restart.setCustom(p.join(root.path, 'missing', 'python.exe')),
      isFalse,
    );
    expect(restart.status!.executable, custom);
    expect(await treeFingerprint(customRoot.path), fingerprint);
    expect(await state.useDefaultPythonEnvironment(), isTrue);
    expect(
      state.pythonEnvironmentStatus!.source,
      PythonEnvironmentSource.bundled,
    );
    stdout.writeln(
      'NATIVE PASS: ${state.pythonEnvironmentStatus!.version}; PATH empty; no launcher; readonly install; custom fingerprint $fingerprint; temp ${root.path}',
    );
    await state.resetCache();
    expect(
      File(state.pythonEnvironmentStatus!.executable).existsSync(),
      isTrue,
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}
