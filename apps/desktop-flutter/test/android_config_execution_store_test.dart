/// Android 执行绑定存储：版本 1 JSON、选择、原子提交与容错。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/android_config_execution.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/services/android_config_execution_store.dart';
import 'package:webhtv_pc/services/log_service.dart';

const String token32 = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const String hash64 =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

AndroidConfigExecutionBinding binding({
  String sourceKey = 'src-1',
  String profileConnectionKey = 'profile-1',
  String deviceUuid = 'device-1',
  String configHash = hash64,
  String snapshotToken = token32,
  int guestPort = 19000,
  String interfaceKey = 'site-key',
}) => AndroidConfigExecutionBinding(
  sourceKey: sourceKey,
  profileConnectionKey: profileConnectionKey,
  deviceUuid: deviceUuid,
  configHash: configHash,
  snapshotToken: snapshotToken,
  guestPort: guestPort,
  interfaceKey: interfaceKey,
);

void main() {
  late Directory tempDir;
  late String path;
  late LogService log;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('webhtv-exec-store-');
    path = p.join(tempDir.path, 'android_config_execution.json');
    log = LogService();
  });

  tearDown(() async {
    await log.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> writeState(Object? value) async {
    File(path).writeAsStringSync(jsonEncode(value));
  }

  test('missing file loads as an empty version 1 store', () async {
    final store = AndroidConfigExecutionStore(path: path, log: log);
    await store.load();
    expect(store.bindings, isEmpty);
    expect(store.enabledFor('src-1'), isNull);
  });

  test('put and load round-trip key/execution fields and selection', () async {
    final store = AndroidConfigExecutionStore(path: path, log: log);
    await store.load();
    await store.putBinding(binding(), enable: true);

    final decoded = jsonDecode(File(path).readAsStringSync()) as Map;
    expect(decoded['version'], 1);
    expect((decoded['bindings'] as List).single, binding().toJson());
    expect(decoded['selections'], {'src-1': 'profile-1'});

    final reloaded = AndroidConfigExecutionStore(path: path, log: log);
    await reloaded.load();
    expect(reloaded.bindings.single.toJson(), binding().toJson());
    expect(reloaded.enabledFor('src-1')!.toJson(), binding().toJson());
    expect(
      reloaded.forSourceProfile('src-1', 'profile-1')!.toJson(),
      binding().toJson(),
    );
    expect(reloaded.guestPortForProfile('profile-1'), 19000);
  });

  test('pending binding persists but cannot be enabled', () async {
    final store = AndroidConfigExecutionStore(path: path, log: log);
    await store.load();
    final pending = binding(interfaceKey: '');

    await expectLater(
      store.putBinding(pending, enable: true),
      throwsA(
        isA<AppError>().having(
          (error) => error.kind,
          'kind',
          AppErrorKind.storage,
        ),
      ),
    );
    expect(store.bindings, isEmpty);
    expect(store.enabledFor('src-1'), isNull);

    await store.putBinding(pending);
    expect(store.bindings.single.isReady, isFalse);
    expect(store.enabledFor('src-1'), isNull);
    expect(store.guestPortForProfile('profile-1'), 19000);
  });

  test(
    'one selected profile per source and completing a pending binding',
    () async {
      final store = AndroidConfigExecutionStore(path: path, log: log);
      await store.load();
      await store.putBinding(
        binding(profileConnectionKey: 'profile-1'),
        enable: true,
      );
      await store.putBinding(
        binding(profileConnectionKey: 'profile-2'),
        enable: true,
      );

      expect(store.enabledFor('src-1')!.profileConnectionKey, 'profile-2');
      expect(store.bindings.length, 2);
      expect(store.forSourceProfile('src-1', 'profile-1')!.isReady, isTrue);

      await store.putBinding(binding(interfaceKey: ''));
      await store.putBinding(binding(interfaceKey: 'site-key'), enable: true);
      expect(store.enabledFor('src-1')!.isReady, isTrue);
      final reloaded = AndroidConfigExecutionStore(path: path, log: log);
      await reloaded.load();
      expect(reloaded.enabledFor('src-1')!.profileConnectionKey, 'profile-1');
    },
  );

  test('rejects a second guest port for the same profile', () async {
    final store = AndroidConfigExecutionStore(path: path, log: log);
    await store.load();
    await store.putBinding(binding());

    await expectLater(
      store.putBinding(binding(sourceKey: 'src-2', guestPort: 19001)),
      throwsA(
        isA<AppError>().having(
          (error) => error.kind,
          'kind',
          AppErrorKind.storage,
        ),
      ),
    );
    expect(store.bindings.length, 1);
    expect(store.guestPortForProfile('profile-1'), 19000);
  });

  test('disable keeps binding token and port for reuse', () async {
    final store = AndroidConfigExecutionStore(path: path, log: log);
    await store.load();
    await store.putBinding(binding(), enable: true);
    await store.disable('src-1');

    expect(store.enabledFor('src-1'), isNull);
    final kept = store.forSourceProfile('src-1', 'profile-1')!;
    expect(kept.snapshotToken, token32);
    expect(kept.guestPort, 19000);
    final reloaded = AndroidConfigExecutionStore(path: path, log: log);
    await reloaded.load();
    expect(reloaded.enabledFor('src-1'), isNull);
    expect(reloaded.guestPortForProfile('profile-1'), 19000);

    await reloaded.putBinding(kept, enable: true);
    expect(reloaded.enabledFor('src-1')!.snapshotToken, token32);
    expect(reloaded.enabledFor('src-1')!.guestPort, 19000);
  });

  test('forget removes one profile and clears its selection', () async {
    final store = AndroidConfigExecutionStore(path: path, log: log);
    await store.load();
    await store.putBinding(binding(), enable: true);
    await store.putBinding(
      binding(sourceKey: 'src-2', profileConnectionKey: 'profile-2'),
    );
    await store.forget('src-1', 'profile-1');

    expect(store.forSourceProfile('src-1', 'profile-1'), isNull);
    expect(store.enabledFor('src-1'), isNull);
    expect(store.bindings.single.sourceKey, 'src-2');
    expect(store.guestPortForProfile('profile-1'), isNull);
  });

  test(
    'tolerant load keeps valid records and drops unknown selections',
    () async {
      final valid = binding().toJson();
      await writeState({
        'version': 1,
        'bindings': [
          valid,
          {'version': 1, 'broken': true},
          {...valid, 'deviceUuid': 'device-2'},
        ],
        'selections': {
          'src-1': 'profile-1',
          'src-missing': 'profile-1',
          'src-bad': 'profile-bad',
        },
      });

      final store = AndroidConfigExecutionStore(path: path, log: log);
      await store.load();
      expect(store.bindings.length, 1);
      expect(store.bindings.single.deviceUuid, 'device-2');
      expect(store.enabledFor('src-1')!.deviceUuid, 'device-2');
      expect(store.enabledFor('src-missing'), isNull);
      expect(store.enabledFor('src-bad'), isNull);
    },
  );

  test(
    'future schema version and corrupt JSON load empty without throwing',
    () async {
      await writeState({
        'version': 2,
        'bindings': [binding().toJson()],
        'selections': {'src-1': 'profile-1'},
      });
      final future = AndroidConfigExecutionStore(path: path, log: log);
      await future.load();
      expect(future.bindings, isEmpty);

      File(path).writeAsStringSync('{not-json');
      final corrupt = AndroidConfigExecutionStore(path: path, log: log);
      await corrupt.load();
      expect(corrupt.bindings, isEmpty);
      expect(corrupt.enabledFor('src-1'), isNull);
    },
  );

  test('profile guest port conflict on load keeps the first record', () async {
    await writeState({
      'version': 1,
      'bindings': [
        binding(sourceKey: 'src-1').toJson(),
        binding(sourceKey: 'src-2', guestPort: 19001).toJson(),
      ],
      'selections': {'src-1': 'profile-1', 'src-2': 'profile-1'},
    });
    final store = AndroidConfigExecutionStore(path: path, log: log);
    await store.load();
    expect(store.bindings.length, 1);
    expect(store.bindings.single.sourceKey, 'src-1');
    expect(store.guestPortForProfile('profile-1'), 19000);
    expect(store.enabledFor('src-1'), isNotNull);
    expect(store.enabledFor('src-2'), isNull);
  });

  test('failed commit preserves memory and the old file', () async {
    final store = AndroidConfigExecutionStore(path: path, log: log);
    await store.load();
    await store.putBinding(binding(), enable: true);
    final before = File(path).readAsStringSync();

    // Same-directory temp path occupied by a directory: temp write fails.
    // A delete-then-rename implementation would lose the old target here.
    final blocker = Directory('$path.tmp')..createSync();
    try {
      await expectLater(
        store.putBinding(binding(deviceUuid: 'device-2'), enable: true),
        throwsA(
          isA<AppError>().having(
            (error) => error.kind,
            'kind',
            AppErrorKind.storage,
          ),
        ),
      );
    } finally {
      blocker.deleteSync(recursive: true);
    }

    expect(store.bindings.single.deviceUuid, 'device-1');
    expect(File(path).readAsStringSync(), before);
    expect(File(path).existsSync(), isTrue);
    expect(Directory('$path.tmp').existsSync(), isFalse);
  });

  test('concurrent puts keep both bindings in memory and on disk', () async {
    final store = AndroidConfigExecutionStore(path: path, log: log);
    await store.load();

    final first = store.putBinding(binding(sourceKey: 'src-a'), enable: true);
    final second = store.putBinding(binding(sourceKey: 'src-b'), enable: true);
    await Future.wait([first, second]);

    expect(store.forSourceProfile('src-a', 'profile-1'), isNotNull);
    expect(store.forSourceProfile('src-b', 'profile-1'), isNotNull);
    expect(store.bindings.length, 2);
    expect(store.enabledFor('src-a'), isNotNull);
    expect(store.enabledFor('src-b'), isNotNull);

    final decoded = jsonDecode(File(path).readAsStringSync()) as Map;
    expect([
      for (final item in decoded['bindings'] as List)
        (item as Map)['sourceKey'],
    ], unorderedEquals(['src-a', 'src-b']));

    final reloaded = AndroidConfigExecutionStore(path: path, log: log);
    await reloaded.load();
    expect(reloaded.bindings.length, 2);
    expect(reloaded.enabledFor('src-b'), isNotNull);
  });

  test('concurrent put, disable and forget apply in call order', () async {
    final store = AndroidConfigExecutionStore(path: path, log: log);
    await store.load();
    await store.putBinding(binding(), enable: true);

    final flights = [
      store.putBinding(
        binding(sourceKey: 'src-2', profileConnectionKey: 'profile-2'),
      ),
      store.disable('src-1'),
      store.forget('src-1', 'profile-1'),
    ];
    await Future.wait(flights);

    // Call order decides commit order: src-2 lands first, then src-1 is disabled
    // and forgotten, so exactly one binding survives in memory and on disk.
    expect(store.bindings.map((item) => item.sourceKey), ['src-2']);
    expect(store.enabledFor('src-1'), isNull);
    expect(store.forSourceProfile('src-1', 'profile-1'), isNull);
    expect(store.guestPortForProfile('profile-1'), isNull);

    final decoded = jsonDecode(File(path).readAsStringSync()) as Map;
    expect(
      [
        for (final item in decoded['bindings'] as List)
          (item as Map)['sourceKey'],
      ],
      ['src-2'],
    );
    expect(decoded['selections'], isEmpty);

    final reloaded = AndroidConfigExecutionStore(path: path, log: log);
    await reloaded.load();
    expect(reloaded.bindings.map((item) => item.sourceKey), ['src-2']);
    expect(reloaded.enabledFor('src-1'), isNull);
  });

  test('a queued invalid mutation keeps its own error only', () async {
    final store = AndroidConfigExecutionStore(path: path, log: log);
    await store.load();

    final invalid = store.putBinding(binding(interfaceKey: ''), enable: true);
    final valid = store.putBinding(
      binding(sourceKey: 'src-2', profileConnectionKey: 'profile-2'),
    );
    await expectLater(
      invalid,
      throwsA(
        isA<AppError>().having(
          (error) => error.kind,
          'kind',
          AppErrorKind.storage,
        ),
      ),
    );
    await valid;
    expect(store.bindings.single.sourceKey, 'src-2');
    expect(store.bindings.single.isReady, isTrue);
  });

  test('a failed write does not poison the next mutation', () async {
    final store = AndroidConfigExecutionStore(path: path, log: log);
    await store.load();
    await store.putBinding(binding(), enable: true);
    final before = File(path).readAsStringSync();

    final blocker = Directory('$path.tmp')..createSync();
    try {
      await expectLater(
        store.putBinding(binding(deviceUuid: 'device-2'), enable: true),
        throwsA(
          isA<AppError>().having(
            (error) => error.kind,
            'kind',
            AppErrorKind.storage,
          ),
        ),
      );
    } finally {
      blocker.deleteSync(recursive: true);
    }
    expect(store.bindings.single.deviceUuid, 'device-1');
    expect(File(path).readAsStringSync(), before);

    await store.putBinding(
      binding(sourceKey: 'src-2', profileConnectionKey: 'profile-2'),
    );
    expect(store.bindings.length, 2);
    final reloaded = AndroidConfigExecutionStore(path: path, log: log);
    await reloaded.load();
    expect(reloaded.bindings.length, 2);
  });
}
