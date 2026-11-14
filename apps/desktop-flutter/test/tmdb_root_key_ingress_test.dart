import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/config_parser.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/services/storage.dart';

const secret = 'subscription-secret-123456789';
Map<String, Object?> fixture(Object? key) => {
  'tmdb_api_key': key,
  'sites': [
    {'key': 'a', 'name': 'A', 'type': 0, 'api': 'http://127.0.0.1:1/api'},
  ],
  'custom': {'keep': true},
};
void main() {
  test(
    'root credential is transient and stripped from raw config and record',
    () {
      final document = parseConfigDocument(jsonEncode(fixture(' $secret ')));
      expect(document.raw.containsKey('tmdb_api_key'), isFalse);
      expect(jsonEncode(document.config!.toJson()), isNot(contains(secret)));
      expect((document as dynamic).tmdbApiKeyCandidate, secret);
      expect(document.raw['custom'], {'keep': true});
      expect(
        jsonEncode(parseConfigRecord(fixture(secret)).toJson()),
        isNot(contains(secret)),
      );
    },
  );
  test(
    'TMDB settings parser remains alias-only and never ingests root field',
    () {
      expect(TmdbConfig.fromMap({'tmdb_api_key': 'manual-alias'}).apiKey, '');
      expect(
        TmdbConfig.fromMap({'apiKey': 'preferred', 'tmdb_api_key': secret})
            .apiKey,
        'preferred',
      );
    },
  );
  test('invalid and duplicate root fields never yield a candidate', () {
    final values = <Object?>[
      null,
      1234567890123456,
      true,
      'short',
      'a' * 257,
      'space between-123456',
      'é' * 20,
      'tab\tinside-12345678',
      '\u007f' * 20,
    ];
    for (final value in values) {
      final document = parseConfigDocument(jsonEncode(fixture(value)));
      expect(document.raw.containsKey('tmdb_api_key'), isFalse);
      expect((document as dynamic).tmdbApiKeyCandidate, '');
    }
    final base = jsonEncode(fixture(secret));
    final duplicate = base.replaceFirst(
      '{',
      '{"tmdb_\\u0061pi_key":"other-secret-123456",',
    );
    expect((parseConfigDocument(duplicate) as dynamic).tmdbApiKeyCandidate, '');
    final nested = fixture(secret)..['custom'] = {'tmdb_api_key': 'nested'};
    expect(
      (parseConfigDocument(jsonEncode(nested)) as dynamic).tmdbApiKeyCandidate,
      secret,
    );
    for (final key in ['a' * 16, 'a' * 256]) {
      expect(
        (parseConfigDocument(
          jsonEncode(fixture(key)),
        ) as dynamic).tmdbApiKeyCandidate,
        key,
      );
    }
  });
  test(
    'malformed JSON exception and diagnostics contain no credential source',
    () {
      try {
        parseConfigDocument('{"tmdb_api_key":"$secret", bad');
        fail('malformed configuration must fail');
      } on AppError catch (error) {
        expect(error.kind, AppErrorKind.configInvalid);
        expect(error.cause.toString(), isNot(contains(secret)));
        expect(error.logLine, isNot(contains(secret)));
        expect(error.toString(), isNot(contains(secret)));
      }
    },
  );
  test('malformed JSON without root field keeps parse failure classification and offset', () {
    try {
      parseConfigDocument('{"sites": [ bad');
      fail('malformed configuration must fail');
    } on AppError catch (error) {
      expect(error.kind, AppErrorKind.configInvalid);
      expect(error.message, 'JSON 解析失败');
      expect(error.detail, contains('offset='));
      expect(error.logLine, contains('JSON 解析失败'));
    }
  });
  test(
    'escaped malformed root field never exposes source in format exception',
    () {
      final malformed = '{"tmdb_api_key":"$secret", bad'.replaceAll(
        'tmdb_api_key',
        r'\u0074mdb_api_key',
      );
      try {
        parseConfigDocument(malformed);
        fail('malformed JSON must fail');
      } on AppError catch (error) {
        expect(error.cause.toString().contains(secret), isFalse);
        expect(error.logLine.contains(secret), isFalse);
      }
    },
  );
  test('storage strips root key even when bypassing document parser', () {
    final database = AppDatabase.inMemory();
    addTearDown(database.dispose);
    final id = database.saveConfig(
      name: 'A',
      origin: 'https://example.test/a',
      json: fixture(secret),
    );
    expect(
      jsonEncode(database.listConfigs().single.json),
      isNot(contains(secret)),
    );
    database.refreshConfigContent(
      id,
      json: fixture(secret),
      siteCount: 1,
      liveCount: 0,
    );
    expect(jsonEncode(database.activeConfig()!.json), isNot(contains(secret)));
  });
  test('legacy persisted root credential is removed from raw backup', () {
    final temp = Directory.systemTemp.createTempSync('tmdb-legacy-root-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final path = '${temp.path}/legacy.sqlite3';
    final initial = AppDatabase.open(path).database!;
    final id = initial.saveConfig(
      name: 'legacy',
      origin: 'https://example.test/legacy',
      json: fixture(null),
    );
    initial.dispose();
    final raw = sqlite3.open(path);
    raw.execute('UPDATE configs SET json=? WHERE id=?', [
      jsonEncode(fixture(secret)),
      id,
    ]);
    raw.close();
    final reopened = AppDatabase.open(path).database!;
    addTearDown(reopened.dispose);
    expect(jsonEncode(reopened.activeConfig()!.json), isNot(contains(secret)));
    final backup = '${temp.path}/backup.sqlite3';
    reopened.backupTo(backup);
    expect(
      utf8
          .decode(File(backup).readAsBytesSync(), allowMalformed: true)
          .contains(secret),
      isFalse,
    );
  });
}
