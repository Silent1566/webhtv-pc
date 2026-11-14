import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/app_paths.dart';

List<String> _directories(AppPaths paths) => [
  paths.configDir,
  paths.dataDir,
  paths.cacheDir,
  paths.logDir,
];

Map<String, String> _finalDirectories(String root) => {
  'config': p.join(root, 'config'),
  'data': p.join(root, 'data'),
  'cache': p.join(root, 'cache'),
  'state': p.join(root, 'logs'),
};

Map<String, String> _xdgRoots(String root) => {
  'xdgConfig': p.join(root, 'config'),
  'xdgData': p.join(root, 'data'),
  'xdgCache': p.join(root, 'cache'),
  'xdgState': p.join(root, 'state'),
};

// A child VM supplies controlled platform environment variables, without adding
// a test-only environment seam to AppPaths or changing the runner's profile.
Future<Map<String, dynamic>> _firstWrite(
  Directory temp,
  Map<String, String> overrides, {
  String flutterTest = 'true',
}) async {
  final script = File(p.join(temp.path, 'first_write.dart'));
  final service = File('lib/services/app_paths.dart').absolute.uri;
  await script.writeAsString('''
import 'dart:convert';
import 'dart:io';
import '$service';

Future<void> main(List<String> args) async {
  final overrides = Map<String, String>.from(jsonDecode(args.single) as Map);
  final paths = AppPaths.resolve(overrides: overrides, appName: 'guard-probe');
  final result = <String, Object?>{
    'directories': [paths.configDir, paths.dataDir, paths.cacheDir, paths.logDir],
  };
  try {
    result['failures'] = await paths.ensureDirectories();
    result['blocked'] = false;
  } on StateError catch (error) {
    result['blocked'] = true;
    result['message'] = error.toString();
  }
  print(jsonEncode(result));
}
''');
  final environment = Map<String, String>.of(Platform.environment)
    ..remove('USERPROFILE')
    ..addAll({
      'HOME': p.join(temp.path, 'mock-home'),
      'XDG_CONFIG_HOME': p.join(temp.path, 'mock-home', 'config'),
      'XDG_DATA_HOME': p.join(temp.path, 'mock-home', 'data'),
      'XDG_CACHE_HOME': p.join(temp.path, 'mock-home', 'cache'),
      'XDG_STATE_HOME': p.join(temp.path, 'mock-home', 'state'),
      'APPDATA': p.join(temp.path, 'mock-home', 'roaming'),
      'LOCALAPPDATA': p.join(temp.path, 'mock-home', 'local'),
      'TMPDIR': p.join(temp.path, 'process-tmp'),
      'FLUTTER_TEST': flutterTest,
    });
  await Directory(environment['TMPDIR']!).create(recursive: true);
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  final dart = flutterRoot == null
      ? Platform.resolvedExecutable
      : p.join(
          flutterRoot,
          'bin',
          'cache',
          'dart-sdk',
          'bin',
          Platform.isWindows ? 'dart.exe' : 'dart',
        );
  final process = await Process.run(
    dart,
    [
      '--packages=${File('.dart_tool/package_config.json').absolute.path}',
      script.path,
      jsonEncode(overrides),
    ],
    environment: environment,
    includeParentEnvironment: false,
    workingDirectory: temp.path,
  );
  expect(process.exitCode, 0, reason: '${process.stdout}\n${process.stderr}');
  return jsonDecode((process.stdout as String).trim()) as Map<String, dynamic>;
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('webhtv-path-isolation-');
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('the Flutter runner sets the first-write test flag', () {
    expect(Platform.environment['FLUTTER_TEST'], 'true');
  });

  test(
    'roaming/local roots cover every directory on POSIX and Windows',
    () async {
      final roaming = p.join(temp.path, 'roaming');
      final local = p.join(temp.path, 'local');
      final paths = AppPaths.resolve(
        overrides: {'roaming': roaming, 'local': local},
      );
      expect(_directories(paths), [
        p.join(roaming, 'webhtv-pc'),
        p.join(local, 'webhtv-pc'),
        p.join(local, 'webhtv-pc', 'cache'),
        p.join(local, 'webhtv-pc', 'logs'),
      ]);
      expect(await paths.ensureDirectories(), isEmpty);
      for (final directory in _directories(paths)) {
        expect(await Directory(directory).exists(), isTrue);
      }
    },
  );

  test('explicit XDG roots take precedence over roaming/local on POSIX', () {
    final roots = _xdgRoots(p.join(temp.path, 'xdg'));
    final paths = AppPaths.resolve(
      overrides: {
        'roaming': p.join(temp.path, 'roaming'),
        'local': p.join(temp.path, 'local'),
        ...roots,
      },
    );
    expect(_directories(paths), [
      p.join(roots['xdgConfig']!, 'webhtv-pc'),
      p.join(roots['xdgData']!, 'webhtv-pc'),
      p.join(roots['xdgCache']!, 'webhtv-pc'),
      p.join(roots['xdgState']!, 'webhtv-pc', 'logs'),
    ]);
  }, skip: Platform.isWindows);

  test('final directories take precedence over all root overrides', () async {
    final finals = _finalDirectories(p.join(temp.path, 'final'));
    final paths = AppPaths.resolve(
      overrides: {
        'roaming': p.join(temp.path, 'roaming'),
        'local': p.join(temp.path, 'local'),
        ..._xdgRoots(p.join(temp.path, 'xdg')),
        ...finals,
      },
    );
    expect(_directories(paths), finals.values.toList());
    expect(await paths.ensureDirectories(), isEmpty);
  });

  test('explicit XDG and final overrides survive macOS defaults', () {
    final roots = _xdgRoots(temp.path);
    final paths = AppPaths.resolve(overrides: roots);
    expect(_directories(paths), [
      p.join(roots['xdgConfig']!, 'webhtv-pc'),
      p.join(roots['xdgData']!, 'webhtv-pc'),
      p.join(roots['xdgCache']!, 'webhtv-pc'),
      p.join(roots['xdgState']!, 'webhtv-pc', 'logs'),
    ]);
  }, skip: !Platform.isMacOS);

  test('default resolution remains available for pure mocked construction', () {
    final paths = AppPaths.resolve();
    expect(_directories(paths), everyElement(isNotEmpty));
    expect(paths.databasePath, p.join(paths.dataDir, 'webhtv-pc.sqlite3'));
  });

  test(
    'default test profile fails closed before creating the mock HOME',
    () async {
      final result = await _firstWrite(temp, {});
      expect(result['blocked'], isTrue);
      expect(result['message'], contains('isolated'));
      expect(await Directory(p.join(temp.path, 'mock-home')).exists(), isFalse);
    },
  );

  final incompleteCases = <String, Map<String, String> Function(String)>{
    'partial final directories': (root) => {'config': p.join(root, 'config')},
    'partial Windows roots': (root) => {'roaming': p.join(root, 'roaming')},
    'local without config root': (root) => {'local': p.join(root, 'local')},
    'partial XDG roots': (root) => {'xdgData': p.join(root, 'data')},
    'empty final directory': (root) => {
      ..._finalDirectories(root),
      'state': '',
    },
    'whitespace final directory': (root) => {
      ..._finalDirectories(root),
      'state': '   ',
    },
    'misspelled final key': (root) => {
      'config': p.join(root, 'config'),
      'data': p.join(root, 'data'),
      'cache': p.join(root, 'cache'),
      'logs': p.join(root, 'logs'),
    },
    'unknown key even with complete profile': (root) => {
      ..._finalDirectories(root),
      'typo': p.join(root, 'typo'),
    },
    'relative final directory': (root) => {
      ..._finalDirectories(root),
      'state': 'relative-profile',
    },
  };
  for (final entry in incompleteCases.entries) {
    test('${entry.key} fails before any directory IO', () async {
      final explicit = p.join(temp.path, 'explicit');
      final result = await _firstWrite(temp, entry.value(explicit));
      expect(result['blocked'], isTrue);
      expect(result['message'], contains('isolated'));
      expect(await Directory(p.join(temp.path, 'mock-home')).exists(), isFalse);
      expect(await Directory(explicit).exists(), isFalse);
    });
  }

  final completeCases = <String, Map<String, String> Function(String)>{
    'final directories': _finalDirectories,
    'roaming/local roots': (root) => {
      'roaming': p.join(root, 'roaming'),
      'local': p.join(root, 'local'),
    },
    if (!Platform.isWindows) 'XDG roots': _xdgRoots,
    'mixed roots and final directories': (root) => {
      'roaming': p.join(root, 'roaming'),
      'data': p.join(root, 'data'),
      'cache': p.join(root, 'cache'),
      'state': p.join(root, 'logs'),
    },
  };
  for (final entry in completeCases.entries) {
    test('complete ${entry.key} allows isolated creation', () async {
      final explicit = p.join(temp.path, 'explicit');
      final result = await _firstWrite(temp, entry.value(explicit));
      expect(result['blocked'], isFalse);
      expect(result['failures'], isEmpty);
      for (final directory in result['directories'] as List<dynamic>) {
        expect(await Directory(directory as String).exists(), isTrue);
        expect(p.isWithin(explicit, directory), isTrue);
      }
      expect(await Directory(p.join(temp.path, 'mock-home')).exists(), isFalse);
    });
  }

  test(
    'non-test production defaults remain writable under the mock profile',
    () async {
      final result = await _firstWrite(temp, {}, flutterTest: 'false');
      final home = p.join(temp.path, 'mock-home');
      final expected = Platform.isWindows
          ? [
              p.join(home, 'roaming', 'guard-probe'),
              p.join(home, 'local', 'guard-probe'),
              p.join(home, 'local', 'guard-probe', 'cache'),
              p.join(home, 'local', 'guard-probe', 'logs'),
            ]
          : Platform.isMacOS
          ? [
              p.join(home, 'Library', 'Application Support', 'guard-probe'),
              p.join(home, 'Library', 'Application Support', 'guard-probe'),
              p.join(home, 'Library', 'Caches', 'guard-probe'),
              p.join(home, 'Library', 'Logs', 'guard-probe'),
            ]
          : [
              p.join(home, 'config', 'guard-probe'),
              p.join(home, 'data', 'guard-probe'),
              p.join(home, 'cache', 'guard-probe'),
              p.join(home, 'state', 'guard-probe', 'logs'),
            ];
      expect(result['directories'], expected);
      expect(result['blocked'], isFalse);
      expect(result['failures'], isEmpty);
      for (final directory in expected) {
        expect(await Directory(directory).exists(), isTrue);
      }
    },
  );
}
