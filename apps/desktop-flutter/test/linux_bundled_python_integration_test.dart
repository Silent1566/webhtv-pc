@Tags(['external'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/python_environment.dart';
import 'package:webhtv_pc/services/spider_registry.dart';
import 'package:webhtv_pc/state/app_state.dart';

import 'python_environment_test.dart' show isolatedPaths;

void main() {
  final bundle = p.normalize(
    p.join(Directory.current.path, '..', '..', 'runtime', 'python'),
  );
  final available =
      File(p.join(bundle, 'bundle.json')).existsSync() &&
      File(p.join(bundle, 'python-runtime.zip')).existsSync();
  final requiredBundle =
      Platform.environment['WEBHTV_REQUIRE_BUNDLED_PYTHON'] == '1';
  test(
    'Linux first CatVod use automatically prepares bundled Python with no system interpreter',
    () async {
      expect(
        available,
        isTrue,
        reason: 'Linux release verification requires runtime/python; prepare the locked bundle first.',
      );
      final root = Directory.systemTemp.createTempSync('linux_bundled_native_');
      final install = Directory(
        p.join(root.path, 'install', 'runtime', 'python'),
      )..createSync(recursive: true);
      final names = ['python-runtime.zip', 'bundle.json'];
      for (final name in names) {
        File(p.join(bundle, name)).copySync(p.join(install.path, name));
        expect(
          (await Process.run('/bin/chmod', [
            '444',
            p.join(install.path, name),
          ])).exitCode,
          0,
        );
      }
      expect(
        (await Process.run('/bin/chmod', ['555', install.path])).exitCode,
        0,
      );
      final before = {
        for (final name in names)
          name: sha256
              .convert(File(p.join(install.path, name)).readAsBytesSync())
              .toString(),
      };
      final paths = isolatedPaths(root);
      final environment = PythonEnvironment(
        paths: paths,
        bundleDirectory: install.path,
        systemCandidates: const [],
        processEnvironment: {
          'PATH': '',
          'TMPDIR': root.path,
          'PYTHONHOME': p.join(root.path, 'foreign-python-home'),
          'PYTHONPATH': p.join(root.path, 'foreign-python-path'),
          'PYTHONUSERBASE': p.join(root.path, 'foreign-python-user-base'),
        },
      );
      final state = AppState(paths: paths, pythonEnvironment: environment);
      addTearDown(() async {
        await state.stopSpider('local');
        await state.pythonEnvironmentIdle;
        state.dispose();
        LocalSpiderCommand.preferPythonExecutable(null);
        expect(p.isWithin(root.path, install.path), isTrue);
        await Process.run('/bin/chmod', ['-R', 'u+w', install.path]);
        root.deleteSync(recursive: true);
      });
      final sources = Directory(p.join(root.path, 'sources'))..createSync();
      File(p.join(sources.path, 'local.py')).writeAsStringSync(
        'from base.spider import Spider as Base\n'
        'import os,shutil,requests,Crypto,lxml.etree,bs4\n'
        'assert os.environ.get("PATH")==""\n'
        'assert all(shutil.which(x) is None for x in ("python","python3","py"))\n'
        'class Spider(Base):\n'
        ' def homeContent(self,filter):\n'
        '  return {"list":[{"vod_id":"native-linux","vod_name":"Linux bundled native"}]}\n',
      );
      await state.bootstrap();
      await state.importConfig('{"sites":[]}');
      expect(state.pythonEnvironmentStatus, isNull);
      final scan = await state.scanLocalSources(sources.path);
      expect(scan.candidates, hasLength(1));
      expect(
        (await state.importLocalSources(scan.candidates)).importedCount,
        1,
      );
      await state.selectSite(state.siteItems.single.site);
      expect(
        state.pythonEnvironmentStatus?.ready,
        isTrue,
        reason:
            '${state.pythonEnvironmentError} / ${state.pythonEnvironmentStatus?.error}',
      );
      expect(
        state.pythonEnvironmentStatus!.source,
        PythonEnvironmentSource.bundled,
      );
      expect(state.pythonEnvironmentStatus!.version, '3.14.10');
      final executable = state.pythonEnvironmentStatus!.executable;
      expect(executable, endsWith('/bin/python3'));
      expect(p.isWithin(paths.dataDir, executable), isTrue);
      expect(
        File(p.join(paths.configDir, 'python-environment.json')).existsSync(),
        isFalse,
      );
      expect(state.lastError, isNull);
      expect(state.homeResult!.list.single.vodName, 'Linux bundled native');
      for (final name in names) {
        expect(
          sha256
              .convert(File(p.join(install.path, name)).readAsBytesSync())
              .toString(),
          before[name],
        );
      }
      expect(
        await state.repairPythonEnvironment(),
        isFalse,
        reason: 'Do not replace an active sidecar environment.',
      );
      await state.stopSpider('local');
      final restarted = PythonEnvironment(
        paths: paths,
        bundleDirectory: install.path,
        systemCandidates: const [],
        processEnvironment: {'PATH': ''},
      );
      await restarted.refresh();
      expect(restarted.status!.ready, isTrue, reason: restarted.error);
      expect(restarted.status!.executable, executable);
      await state.resetCache();
      expect(File(executable).existsSync(), isTrue);
      expect(
        (await Process.run(
          executable,
          ['-B', '-c', 'import requests,Crypto,lxml.etree,bs4;print("OK")'],
          environment: {'PATH': ''},
          includeParentEnvironment: false,
        )).exitCode,
        0,
      );
      expect(
        (await Process.run('/bin/chmod', [
          '644',
          p.join(install.path, 'python-runtime.zip'),
        ])).exitCode,
        0,
      );
      File(p.join(install.path, 'python-runtime.zip'))
          .writeAsBytesSync([1, 2, 3]);
      expect(await state.repairPythonEnvironment(), isFalse);
      expect(state.pythonEnvironmentStatus!.executable, executable);
      expect(File(executable).existsSync(), isTrue);
      stdout.writeln(
        jsonEncode({
          'native': 'PASS',
          'version': state.pythonEnvironmentStatus!.version,
          'automaticFirstUse': true,
          'systemPython': false,
          'readOnlyBundleUnchanged': true,
          'restartAndCachePreserved': true,
          'failedRepairPreservedOldRuntime': true,
        }),
      );
    },
    skip: !Platform.isLinux
        ? 'Linux native scenario'
        : !available && !requiredBundle
        ? 'No Linux offline bundle in this developer checkout'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
