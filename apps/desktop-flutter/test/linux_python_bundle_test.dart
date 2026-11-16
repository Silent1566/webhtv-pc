import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/python_environment.dart';

import 'python_environment_test.dart' show isolatedPaths;

String bundleFixture(
  Directory root, {
  String platform = 'linux-x64',
  String entry = 'bin/python3',
}) {
  final directory = Directory(p.join(root.path, 'install', 'runtime', 'python'))
    ..createSync(recursive: true);
  final bytes = utf8.encode('interpreter fixture');
  final archive = Archive()..add(ArchiveFile(entry, bytes.length, bytes));
  final zip = ZipEncoder().encode(archive);
  File(p.join(directory.path, 'python-runtime.zip')).writeAsBytesSync(zip);
  File(p.join(directory.path, 'bundle.json')).writeAsStringSync(
    jsonEncode({
      'schemaVersion': 1,
      'platform': platform,
      'pythonVersion': '3.14.10',
      'archive': 'python-runtime.zip',
      'archiveSha256': sha256.convert(zip).toString(),
      'probeModules': ['requests', 'Crypto', 'lxml', 'bs4'],
      'packages': [
        {'name': 'requests', 'version': '2.34.2'},
      ],
      'files': [
        {
          'path': entry,
          'size': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
        },
      ],
    }),
  );
  return directory.path;
}

PythonEnvironmentStatus readyFixture(
  String executable,
  List<String> arguments,
  PythonEnvironmentSource source,
  Map<String, String>? environment,
) => PythonEnvironmentStatus(
  executable: executable,
  version: '3.14.10',
  source: source,
  dependencies: const {
    'requests': true,
    'Crypto': true,
    'lxml': true,
    'bs4': true,
  },
);

void main() {
  test('Linux offline bundle installs an executable interpreter in dataDir and survives restart', () async {
    final root = Directory.systemTemp.createTempSync('linux_python_bundle_');
    addTearDown(() => root.deleteSync(recursive: true));
    final paths = isolatedPaths(root);
    final bundle = bundleFixture(root);
    final environment = PythonEnvironment(
      paths: paths,
      bundleDirectory: bundle,
      systemCandidates: const [],
      probe: readyFixture,
    );
    expect(await environment.repair(), isTrue, reason: environment.error);
    final executable = environment.status!.executable;
    expect(executable, endsWith('/bin/python3'));
    expect(p.isWithin(paths.dataDir, executable), isTrue);
    expect(File(executable).statSync().mode & 0x1ff, 0x1c0);
    final restarted = PythonEnvironment(
      paths: paths,
      bundleDirectory: bundle,
      systemCandidates: const [],
      probe: readyFixture,
    );
    await restarted.refresh();
    expect(restarted.status!.ready, isTrue, reason: restarted.error);
    expect(restarted.status!.executable, executable);
  }, skip: !Platform.isLinux);

  test(
    'Linux rejects a Windows bundle before running its interpreter',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'linux_python_wrong_os_',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      var probes = 0;
      final environment = PythonEnvironment(
        paths: isolatedPaths(root),
        bundleDirectory: bundleFixture(
          root,
          platform: 'windows-x64',
          entry: 'python.exe',
        ),
        systemCandidates: const [],
        probe: (executable, arguments, source, environment) {
          probes++;
          return readyFixture(executable, arguments, source, environment);
        },
      );
      expect(await environment.repair(), isFalse);
      expect(probes, 0);
    },
    skip: !Platform.isLinux,
  );
}
