import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/tmdb_config_store.dart';
import 'package:webhtv_pc/state/app_state.dart';

import 'tmdb_root_key_ingress_test.dart' as root;

void main() {
  late Directory temp;
  late AppState state;
  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tmdb-subscription-');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/config',
          'data': '${temp.path}/data',
          'cache': '${temp.path}/cache',
          'state': '${temp.path}/logs',
        },
      ),
      log: LogService(),
    );
    await state.bootstrap();
  });
  tearDown(() {
    state.dispose();
    temp.deleteSync(recursive: true);
  });
  Future<int> importKey(String key, String name) async {
    expect(
      await state.importConfig(
        jsonEncode(root.fixture(key)),
        displayName: name,
      ),
      isTrue,
    );
    return state.activeRecord!.id;
  }

  Future<int> importFileKey(String key, String name, String fileName) async {
    final file = File('${temp.path}/$fileName')
      ..writeAsStringSync(jsonEncode(root.fixture(key)));
    expect(await state.importConfig(file.path, displayName: name), isTrue);
    return state.activeRecord!.id;
  }

  test('successful import makes effective readiness, settings and exports remain manual', () async {
    await importKey(root.secret, 'A');
    expect(state.tmdbConfig.isReady, isTrue);
    expect(state.tmdbConfig.apiKey, root.secret);
    expect((state as dynamic).tmdbUserConfig.apiKey, '');
    expect(jsonEncode(state.activeRecord!.json), isNot(contains(root.secret)));
    expect(
      jsonEncode(await state.exportSyncedSettings(allowSensitive: true)),
      isNot(contains(root.secret)),
    );
    expect(
      state.log.entries.map((entry) => entry.line).join(),
      isNot(contains(root.secret)),
    );
    await state.saveTmdbConfig(state.tmdbConfig.copyWith(language: 'en-US'));
    expect(
      File(state.paths.settingsPath).readAsStringSync(),
      isNot(contains(root.secret)),
    );
    expect(state.tmdbConfig.apiKey, root.secret);
    expect(state.tmdbConfig.language, 'en-US');
  });
  test(
    'manual API key and token win; disabled flag never auto enables',
    () async {
      await state.saveTmdbConfig(const TmdbConfig(apiKey: 'manual-key'));
      await importKey(root.secret, 'A');
      expect(state.tmdbConfig.apiKey, 'manual-key');
      await state.saveTmdbConfig(const TmdbConfig(accessToken: 'a.b.c'));
      expect(state.tmdbConfig.accessToken, 'a.b.c');
      expect(state.tmdbConfig.apiKey, '');
      await state.saveTmdbConfig(const TmdbConfig(enabled: false));
      expect(state.tmdbConfig.enabled, isFalse);
      expect(state.tmdbConfig.isReady, isFalse);
      expect(state.tmdbConfig.apiKey, root.secret);
      await state.saveTmdbConfig(
        const TmdbConfig(enabled: false, apiKey: 'manual-disabled-key'),
      );
      expect(state.tmdbConfig.apiKey, 'manual-disabled-key');
      expect(state.tmdbConfig.enabled, isFalse);
    },
  );
  test('failed import retains usable key; switching, delete and restart discard it', () async {
    final a = await importFileKey(root.secret, 'A', 'a.json');
    expect(
      await state.importConfig('{"tmdb_api_key":"different-secret-123", bad'),
      isFalse,
    );
    expect(state.tmdbConfig.apiKey, root.secret);
    final b = await importFileKey('second-subscription-secret', 'B', 'b.json');
    expect(await state.activateConfigRecord(a), isTrue);
    expect(state.tmdbConfig.apiKey, '');
    await state.activateConfigRecord(b);
    expect(state.tmdbConfig.apiKey, '');
    await importKey(root.secret, 'C');
    await state.deleteConfigRecord(state.activeRecord!.id);
    expect(state.tmdbConfig.apiKey, '');
    await importKey(root.secret, 'D');
    final restarted = AppState(paths: state.paths, log: LogService());
    addTearDown(restarted.dispose);
    await restarted.bootstrap();
    expect(restarted.tmdbConfig.apiKey, '');
  });
  test('active address edit refresh accepts key only after successful validated import', () async {
    final a = await importFileKey(root.secret, 'A', 'edit-a.json');
    final next = File('${temp.path}/edit-b.json')
      ..writeAsStringSync(
        jsonEncode(root.fixture('edited-subscription-secret')),
      );
    expect(
      await state.editConfigRecord(a, name: 'edited', origin: next.path),
      isTrue,
    );
    expect(state.tmdbConfig.apiKey, 'edited-subscription-secret');
    expect(state.activeRecord!.id, a);
  });
  test('effective snapshot serialization and delayed settings save never persist subscription key', () async {
    await importFileKey(root.secret, 'A', 'snapshot-a.json');
    final snapshot = state.tmdbConfig;
    expect(jsonEncode(snapshot.toJson()), isNot(contains(root.secret)));
    final tokenDraft = snapshot.copyWith(accessToken: 'manual.bearer.token');
    expect(jsonEncode(tokenDraft.toJson()), isNot(contains(root.secret)));
    expect(tokenDraft.userSettings.accessToken, 'manual.bearer.token');
    for (final laundered in [
      snapshot.copyWith(accessToken: snapshot.apiKey),
      snapshot.copyWith(apiKey: snapshot.apiKey),
      snapshot.copyWith(apiKey: '', accessToken: snapshot.apiKey),
      snapshot.copyWith(omdbApiKey: snapshot.apiKey),
      snapshot
          .copyWith(apiKey: 'different-user-key')
          .copyWith(accessToken: snapshot.apiKey),
    ]) {
      expect(jsonEncode(laundered.toJson()), isNot(contains(root.secret)));
      expect(
        jsonEncode(laundered.userSettings.toJson()),
        isNot(contains(root.secret)),
      );
    }
    for (final draft in [
      snapshot.copyWith(apiKey: ' ${snapshot.apiKey} '),
      snapshot.copyWith(accessToken: ' ${snapshot.apiKey} '),
    ]) {
      final sanitized = draft.sanitize();
      expect(jsonEncode(sanitized.toJson()), isNot(contains(root.secret)));
      expect(
        jsonEncode(sanitized.userSettings.toJson()),
        isNot(contains(root.secret)),
      );
    }
    const userOwned = TmdbConfig(
      apiKey: 'user-owned-api-key',
      accessToken: 'user-owned-token',
      omdbApiKey: 'user-owned-omdb-key',
    );
    expect(userOwned.toJson()['apiKey'], 'user-owned-api-key');
    expect(userOwned.toJson()['accessToken'], 'user-owned-token');
    expect(userOwned.toJson()['omdbApiKey'], 'user-owned-omdb-key');
    expect(userOwned.userSettings.toJson(), userOwned.toJson());
    await importFileKey('another-subscription-secret', 'B', 'snapshot-b.json');
    await state.saveTmdbConfig(snapshot.copyWith(language: 'en-US'));
    expect(
      File(state.paths.settingsPath).readAsStringSync(),
      isNot(contains(root.secret)),
    );
    expect(state.tmdbUserConfig.apiKey, '');
  });
  test('data swap clears subscription credential even when restored record reuses id/source', () async {
    final id = await importFileKey(root.secret, 'swap-A', 'swap-a.json');
    expect(state.tmdbConfig.apiKey, root.secret);
    final backupPath = '${temp.path}/swap-backup.zip';
    final created = await state.createBackup(outputPath: backupPath);
    expect(created.ok, isTrue, reason: created.message);
    expect(await state.restoreBackup(backupPath), isNull);
    expect(state.activeRecord?.id, id);
    expect(state.tmdbConfig.apiKey, '');
    final next = File('${temp.path}/swap-next.json')
      ..writeAsStringSync(
        jsonEncode(root.fixture('post-swap-subscription-secret')),
      );
    expect(await state.importConfig(next.path), isTrue);
    expect(state.tmdbConfig.apiKey, 'post-swap-subscription-secret');
  });
  test(
    'malformed settings errors never log credential-bearing source text',
    () async {
      final file = File('${temp.path}/broken-settings.json')
        ..writeAsStringSync('{"tmdb":{"apiKey":"${root.secret}"}, bad');
      final log = LogService();
      final store = TmdbConfigStore(path: file.path, log: log);
      await store.load();
      expect(
        log.entries.map((entry) => entry.line).join(),
        isNot(contains(root.secret)),
      );
    },
  );
  test('default TMDB service authenticates with current effective subscription key', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requested = Completer<Uri>();
    server.listen((request) async {
      if (!requested.isCompleted) requested.complete(request.uri);
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        '{"images":{"base_url":"https://images.tmdb.org/"}}',
      );
      await request.response.close();
    });
    await state.saveTmdbConfig(
      TmdbConfig(apiBase: 'http://127.0.0.1:${server.port}/3'),
    );
    await importKey(root.secret, 'service');
    expect(await state.testTmdbConnection(), contains('连接正常'));
    expect((await requested.future).queryParameters['api_key'], root.secret);
  });
  test(
    'late refresh after scope switch cannot reapply old credential or config',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final arrived = Completer<HttpRequest>();
      var requests = 0;
      server.listen((request) async {
        if (requests++ == 0) {
          request.response.write(jsonEncode(root.fixture(root.secret)));
          await request.response.close();
        } else if (!arrived.isCompleted) {
          arrived.complete(request);
        }
      });
      expect(
        await state.importConfig('http://127.0.0.1:${server.port}/a'),
        isTrue,
      );
      final a = state.activeRecord!.id;
      final refresh = state.refreshConfigRecord(a);
      final request = await arrived.future;
      final b = await importFileKey(
        'new-config-secret-12345',
        'B',
        'refresh-b.json',
      );
      request.response.write(
        jsonEncode(root.fixture('late-refresh-secret-12345')),
      );
      await request.response.close();
      expect(await refresh, isFalse);
      expect(state.activeRecord!.id, b);
      expect(state.tmdbConfig.apiKey, 'new-config-secret-12345');
    },
  );
  test('late URL import cannot replace newer config or credential', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requestArrived = Completer<HttpRequest>();
    server.listen(requestArrived.complete);
    addTearDown(() => server.close(force: true));
    final old = state.importConfig('http://127.0.0.1:${server.port}/old');
    final request = await requestArrived.future;
    final current = await importKey(root.secret, 'current');
    request.response.write(jsonEncode(root.fixture('late-import-secret-1234')));
    await request.response.close();
    expect(await old, isFalse);
    expect(state.activeRecord!.id, current);
    expect(state.tmdbConfig.apiKey, root.secret);
  });
}
