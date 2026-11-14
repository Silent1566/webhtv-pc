import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/source_key.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/config_source_status.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/state/app_state.dart';

const cachedJson = <String, Object?>{
  'name': '缓存配置',
  'sites': [
    {
      'key': 'cached',
      'name': '缓存站点',
      'type': 1,
      'api': 'https://example.invalid/api',
    },
  ],
};

final class DelayedSourceIO extends IOOverrides {
  DelayedSourceIO(this.source);
  final File source;
  String get path => source.path;
  final entered = Completer<void>();
  final release = Completer<void>();
  final finished = Completer<void>();

  @override
  File createFile(String path) =>
      path == this.path ? DelayedSourceFile(this) : super.createFile(path);
}

class DelayedSourceFile extends Fake implements File {
  DelayedSourceFile(this.io);
  final DelayedSourceIO io;

  @override
  String get path => io.path;

  @override
  Future<bool> exists() => io.source.exists();

  @override
  Future<Uint8List> readAsBytes() => io.source.readAsBytes();

  @override
  File get absolute => io.source.absolute;

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async {
    io.entered.complete();
    await io.release.future;
    io.finished.complete();
    throw FileSystemException(
      'permission denied',
      io.path,
      const OSError('denied', 13),
    );
  }
}

void main() {
  late Directory root;
  late AppPaths paths;
  late File source;
  AppState? state;
  late int id;
  late ConfigRecord before;

  Future<void> seed({String? origin}) async {
    final db = AppDatabase.open(paths.databasePath).database!;
    try {
      id = db.saveConfig(
        name: '本地缓存',
        origin: origin ?? source.path,
        sourceKey: LocalSourceKey.of(origin ?? source.path),
        json: cachedJson,
        siteCount: 1,
      );
      before = db.activeConfig()!;
      db.upsertHistory(
        sourceKey: before.sourceKey,
        siteKey: 'cached',
        vodId: 'vod-1',
        vodName: '历史影片',
        flag: 'flag',
        episodeName: '第1集',
        episodeId: 'episode-1',
        positionMs: 12345,
        durationMs: 98765,
        updatedAt: 123456789,
      );
    } finally {
      db.dispose();
    }
  }

  AppState makeState() => state = AppState(
    paths: paths,
    httpClient: MockClient((_) async => http.Response('{"list":[]}', 200)),
  );

  Future<void> bootstrapWithWarning(AppState app) async {
    final warning = Completer<void>();
    void listener() {
      if (app.restoredConfigSourceStatus != null && !warning.isCompleted) {
        warning.complete();
      }
    }

    app.addListener(listener);
    try {
      await app.bootstrap();
      await warning.future.timeout(const Duration(seconds: 5));
    } finally {
      app.removeListener(listener);
    }
  }

  void expectHistoryUntouched(AppState app) {
    final history = app.database!.recentHistory().single;
    expect(history.positionMs, 12345);
    expect(history.durationMs, 98765);
    expect(history.updatedAt, 123456789);
    expect(history.vodId, 'vod-1');
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('source-restore-');
    paths = AppPaths.resolve(
      overrides: {
        'config': '${root.path}/config',
        'data': '${root.path}/data',
        'cache': '${root.path}/cache',
        'state': '${root.path}/state',
      },
    );
    await paths.ensureDirectories();
    source = File('${root.path}/source.json');
    await source.writeAsString(jsonEncode(cachedJson));
  });

  tearDown(() async {
    state?.dispose();
    await state?.pythonEnvironmentIdle;
    state = null;
    await root.delete(recursive: true);
  });

  test(
    'removed source bootstrap keeps cached config, history and timestamps',
    () async {
      await seed();
      await source.delete();
      final app = makeState();
      await bootstrapWithWarning(app);
      expect(app.hasConfig, isTrue);
      expect(app.config!.sites.single.key, 'cached');
      expect(app.activeRecord!.id, id);
      expect(app.configPhase, LoadPhase.ready);
      final ConfigSourceStatus status = app.restoredConfigSourceStatus!;
      expect(status.recordId, id);
      expect(status.availability, ConfigSourceAvailability.missing);
      expect(app.lastError, isNull);
      expect(app.database!.activeConfig()!.updatedAt, before.updatedAt);
      expectHistoryUntouched(app);
      await app.loadHome(app.config!.sites.single);
      expect(app.restoredConfigSourceStatus, same(status));
    },
  );

  test(
    'dismiss only hides warning and preserves cache, records and history',
    () async {
      await seed();
      await source.delete();
      final app = makeState();
      await bootstrapWithWarning(app);
      app.dismissRestoredConfigSourceWarning();
      expect(app.restoredConfigSourceStatus, isNull);
      expect(app.hasConfig, isTrue);
      expect(app.savedConfigs.single.id, id);
      expect(app.savedConfigs.single.updatedAt, before.updatedAt);
      expectHistoryUntouched(app);
    },
  );

  test(
    'failed refresh retains warning; restoring file and refresh clears it',
    () async {
      await seed();
      await source.delete();
      final app = makeState();
      await bootstrapWithWarning(app);
      expect(await app.refreshConfigRecord(id), isFalse);
      expect(app.restoredConfigSourceStatus, isNotNull);
      await source.writeAsString(jsonEncode(cachedJson));
      expect(await app.refreshConfigRecord(id), isTrue);
      expect(app.restoredConfigSourceStatus, isNull);
      expect(app.savedConfigs.single.id, id);
      expectHistoryUntouched(app);
    },
  );

  test('switch clears warning and unrelated refresh leaves it alone', () async {
    await seed();
    await source.delete();
    final app = makeState();
    await bootstrapWithWarning(app);
    final other = File('${root.path}/other.json');
    await other.writeAsString(jsonEncode(cachedJson));
    final otherId = app.database!.saveConfig(
      name: '其他',
      origin: other.path,
      json: cachedJson,
      makeActive: false,
    );
    expect(await app.refreshConfigRecord(otherId), isTrue);
    expect(app.restoredConfigSourceStatus, isNotNull);
    expect(await app.activateConfigRecord(otherId), isTrue);
    expect(app.restoredConfigSourceStatus, isNull);
    expect(app.activeRecord!.id, otherId);
  });

  test('disposed warned state never reads a closed database', () async {
    await seed();
    await source.delete();
    final app = makeState();
    await bootstrapWithWarning(app);
    app.dispose();
    await app.pythonEnvironmentIdle;
    state = null;
    expect(app.restoredConfigSourceStatus, isNull);
  });

  test(
    'delete warned record clears warning without deleting history',
    () async {
      await seed();
      await source.delete();
      final app = makeState();
      await bootstrapWithWarning(app);
      await app.deleteConfigRecord(id);
      expect(app.restoredConfigSourceStatus, isNull);
      expect(app.savedConfigs, isEmpty);
      expectHistoryUntouched(app);
    },
  );

  for (final origin in [
    'existing',
    'https://127.0.0.1:1/offline',
    'inline://json',
  ]) {
    test('bootstrap $origin source does not warn or fetch network', () async {
      await seed(origin: origin == 'existing' ? null : origin);
      final app = makeState();
      await app.bootstrap();
      await Future<void>(() {});
      expect(app.hasConfig, isTrue);
      expect(app.restoredConfigSourceStatus, isNull);
      expectHistoryUntouched(app);
    });
  }

  for (final change in [
    'none',
    'switch',
    'edit-origin',
    'refresh',
    'dismiss',
    'delete',
    'dispose',
  ]) {
    test(
      'late filesystem result with $change obeys warning lifecycle',
      () async {
        await seed();
        final io = DelayedSourceIO(source);
        final app = makeState();
        await IOOverrides.runWithIOOverrides(() async {
          await app.bootstrap();
          await io.entered.future.timeout(const Duration(seconds: 5));
          if (change == 'switch') {
            final otherId = app.database!.saveConfig(
              name: '其他',
              origin: 'inline://json',
              json: cachedJson,
              makeActive: false,
            );
            expect(await app.activateConfigRecord(otherId), isTrue);
          } else if (change == 'edit-origin') {
            app.database!.updateConfigIdentity(
              id,
              name: '新来源',
              origin: 'inline://json',
            );
          } else if (change == 'refresh') {
            expect(
              await app.refreshConfigRecord(id),
              isTrue,
              reason: '${app.lastError}',
            );
          } else if (change == 'delete') {
            await app.deleteConfigRecord(id);
          } else if (change == 'dismiss') {
            app.dismissRestoredConfigSourceWarning();
          } else if (change == 'dispose') {
            app.dispose();
            await app.pythonEnvironmentIdle;
            state = null;
          }
          io.release.complete();
          await io.finished.future;
          await Future<void>(() {});
          if (change == 'none') {
            expect(
              app.restoredConfigSourceStatus!.availability,
              ConfigSourceAvailability.unreadable,
            );
          } else {
            expect(app.restoredConfigSourceStatus, isNull);
          }
        }, io);
      },
    );
  }
}
