import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/meta_pipeline.dart';
import 'package:webhtv_pc/core/meta_source.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';

void main() {
  late Directory directory;
  late File file;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('imdb-prefs-migration');
    file = File('${directory.path}/settings.json');
  });
  tearDown(() => directory.deleteSync(recursive: true));

  Map readUi() => (jsonDecode(file.readAsStringSync()) as Map)['ui'] as Map;

  for (final legacyVersion in [0, 1]) {
    for (final mode in ['aggregate', 'priority']) {
      test(
        '$mode rating appends IMDb once with legacy version $legacyVersion',
        () async {
          final order = mode == 'aggregate'
              ? ['tmdb', 'douban', 'bangumi']
              : ['bangumi', 'douban'];
          file.writeAsStringSync(
            jsonEncode({
              'ui': {
                'metaPipelineVersion': legacyVersion,
                'metaPipeline': {
                  'rating': {'mode': mode, 'order': order},
                },
              },
            }),
          );
          final store = UiPreferencesStore(path: file.path);

          await store.load();

          expect(store.metaPipeline.modeOf(MetaField.rating).key, mode);
          expect(
            store.metaPipeline
                .orderOf(MetaField.rating)
                .map((source) => source.key),
            [...order, 'imdb'],
          );
          final ui = readUi();
          expect(ui['imdbRatingVersion'], 1);
          expect(ui['metaPipelineVersion'], legacyVersion);
          expect(ui['metaPipeline']['rating'], {
            'mode': mode,
            'order': [...order, 'imdb'],
          });
          final once = file.readAsStringSync();
          final reopened = UiPreferencesStore(path: file.path);
          await reopened.load();
          expect(file.readAsStringSync(), once);
          expect(
            reopened.metaPipeline.ruleOf(MetaField.rating),
            store.metaPipeline.ruleOf(MetaField.rating),
          );
        },
      );
    }
  }

  for (final marker in [1, 2]) {
    test(
      'marker $marker preserves manually disabled IMDb across restarts',
      () async {
        final before = jsonEncode({
          'ui': {
            'metaPipelineVersion': 1,
            'imdbRatingVersion': marker,
            'metaPipeline': {
              'rating': {
                'mode': 'priority',
                'order': ['bangumi', 'douban'],
              },
            },
          },
        });
        file.writeAsStringSync(before);

        final store = UiPreferencesStore(path: file.path);
        await store.load();
        await UiPreferencesStore(path: file.path).load();

        expect(
          store.metaPipeline.modeOf(MetaField.rating),
          MetaFieldMode.priority,
        );
        expect(store.metaPipeline.orderOf(MetaField.rating), [
          MetaSourceKind.bangumi,
          MetaSourceKind.douban,
        ]);
        expect(file.readAsStringSync(), before);
      },
    );
  }

  test(
    'existing IMDb keeps its position while completing the marker',
    () async {
      final before = jsonEncode({
        'ui': {
          'metaPipelineVersion': 1,
          'metaPipeline': {
            'rating': {
              'mode': 'priority',
              'order': ['bangumi', 'imdb', 'douban'],
            },
          },
        },
      });
      file.writeAsStringSync(before);
      final store = UiPreferencesStore(path: file.path);

      await store.load();

      expect(store.metaPipeline.orderOf(MetaField.rating), [
        MetaSourceKind.bangumi,
        MetaSourceKind.imdb,
        MetaSourceKind.douban,
      ]);
      expect(readUi()['metaPipeline']['rating'], {
        'mode': 'priority',
        'order': ['bangumi', 'imdb', 'douban'],
      });
      expect(readUi()['imdbRatingVersion'], 1);
      final once = file.readAsStringSync();
      await UiPreferencesStore(path: file.path).load();
      expect(file.readAsStringSync(), once);
    },
  );

  test(
    'startup patch preserves unknown root UI field and rule extensions',
    () async {
      final unknownRoot = {
        'keep': [1, true, 'root'],
      };
      final unknownUi = {
        'nested': {'keep': 'ui'},
      };
      final futureField = {
        'mode': 'future',
        'order': ['future-provider'],
      };
      final ratingOption = {
        'nested': [42, false],
      };
      file.writeAsStringSync(
        jsonEncode({
          'futureRoot': unknownRoot,
          'ui': {
            'futureUi': unknownUi,
            'metaPipeline': {
              'futureField': futureField,
              'title': {
                'mode': 'aggregate',
                'order': ['douban'],
                'titleOption': 'keep',
              },
              'rating': {
                'mode': 'priority',
                'order': ['bangumi', 'douban'],
                'ratingOption': ratingOption,
              },
            },
          },
        }),
      );
      final store = UiPreferencesStore(path: file.path);

      await store.load();

      final root = jsonDecode(file.readAsStringSync()) as Map;
      final ui = root['ui'] as Map;
      final rules = ui['metaPipeline'] as Map;
      expect(root['futureRoot'], unknownRoot);
      expect(ui['futureUi'], unknownUi);
      expect(rules['futureField'], futureField);
      expect(rules['title'], {
        'mode': 'aggregate',
        'order': ['douban', 'source'],
        'titleOption': 'keep',
      });
      expect(rules['rating'], {
        'mode': 'priority',
        'order': ['bangumi', 'douban', 'imdb'],
        'ratingOption': ratingOption,
      });
      expect(ui['metaPipelineVersion'], 1);
      expect(ui['imdbRatingVersion'], 1);
    },
  );

  test('rating patch retains unknown order entries and raw mode', () async {
    file.writeAsStringSync(
      jsonEncode({
        'ui': {
          'metaPipelineVersion': 1,
          'metaPipeline': {
            'rating': {
              'mode': 'future-mode',
              'order': ['future-provider', 'bangumi', 7, 'douban'],
              'ratingOption': true,
            },
          },
        },
      }),
    );
    final store = UiPreferencesStore(path: file.path);

    await store.load();

    expect(store.metaPipeline.orderOf(MetaField.rating), [
      MetaSourceKind.bangumi,
      MetaSourceKind.douban,
      MetaSourceKind.imdb,
    ]);
    expect(readUi()['metaPipeline']['rating'], {
      'mode': 'future-mode',
      'order': ['future-provider', 'bangumi', 7, 'douban', 'imdb'],
      'ratingOption': true,
    });
    expect(readUi()['imdbRatingVersion'], 1);
  });

  test(
    'explicit empty rating survives loads with and without IMDb marker',
    () async {
      for (final hasMarker in [false, true]) {
        final before = jsonEncode({
          'futureRoot': true,
          'ui': {
            if (hasMarker) 'imdbRatingVersion': 1,
            'metaPipeline': {
              'rating': {'mode': 'priority', 'order': []},
            },
            'futureUi': {'keep': 1},
          },
        });
        file.writeAsStringSync(before);

        for (var restart = 0; restart < 2; restart++) {
          final store = UiPreferencesStore(path: file.path);
          await store.load();

          expect(store.metaPipeline.orderOf(MetaField.rating), isEmpty);
          expect(
            store.metaPipeline.modeOf(MetaField.rating),
            MetaFieldMode.priority,
          );
          expect(file.readAsStringSync(), before);
        }
      }
    },
  );

  final noRatingRules = <String, Object?>{
    'missing': null,
    'invalid pipeline': 'invalid',
    'empty pipeline': <String, Object?>{},
    'invalid rating': {'rating': 'invalid'},
    'missing order': {
      'rating': {'mode': 'priority'},
    },
    'invalid order': {
      'rating': {'order': 'bangumi'},
    },
    'unknown sources': {
      'rating': {
        'order': ['future-provider'],
      },
    },
    'unsupported source': {
      'rating': {
        'order': ['source'],
      },
    },
  };
  for (final entry in noRatingRules.entries) {
    test(
      '${entry.key} uses IMDb defaults without rewriting settings',
      () async {
        final before = jsonEncode({
          'futureRoot': true,
          'ui': {
            if (entry.value != null) 'metaPipeline': entry.value,
            'futureUi': {'keep': 1},
          },
        });
        file.writeAsStringSync(before);
        final store = UiPreferencesStore(path: file.path);

        await store.load();

        expect(store.metaPipeline.orderOf(MetaField.rating), [
          MetaSourceKind.tmdb,
          MetaSourceKind.douban,
          MetaSourceKind.bangumi,
          MetaSourceKind.imdb,
        ]);
        expect(file.readAsStringSync(), before);
      },
    );
  }

  test(
    'all-default normal persistence writes marker and removal survives restart',
    () async {
      final store = UiPreferencesStore(path: file.path);
      await store.load();
      expect(file.existsSync(), isFalse);

      expect(await store.rememberSite('site'), isTrue);

      final ui = readUi();
      expect(ui['imdbRatingVersion'], 1);
      expect(ui['metaPipelineVersion'], 1);
      expect(ui.containsKey('metaPipeline'), isFalse);
      expect(
        await store.rememberMetaPipeline(
          store.metaPipeline.toggleSource(
            MetaField.rating,
            MetaSourceKind.imdb,
          ),
        ),
        isTrue,
      );
      final reopened = UiPreferencesStore(path: file.path);
      await reopened.load();
      expect(reopened.metaPipeline.orderOf(MetaField.rating), [
        MetaSourceKind.tmdb,
        MetaSourceKind.douban,
        MetaSourceKind.bangumi,
      ]);
      expect(readUi()['imdbRatingVersion'], 1);
    },
  );

  test(
    'failed startup write leaves file and marker unchanged then retries',
    () async {
      final before = jsonEncode({
        'futureRoot': 'keep',
        'ui': {
          'metaPipelineVersion': 1,
          'futureUi': true,
          'metaPipeline': {
            'rating': {
              'mode': 'priority',
              'order': ['bangumi', 'douban'],
              'ratingOption': {'keep': 1},
            },
          },
        },
      });
      file.writeAsStringSync(before);
      final blocker = Directory('${file.path}.ui.tmp')..createSync();
      final store = UiPreferencesStore(path: file.path);

      await store.load();

      expect(store.loaded, isTrue);
      expect(file.readAsStringSync(), before);
      expect(readUi().containsKey('imdbRatingVersion'), isFalse);
      expect(store.metaPipeline.orderOf(MetaField.rating), [
        MetaSourceKind.bangumi,
        MetaSourceKind.douban,
        MetaSourceKind.imdb,
      ]);
      blocker.deleteSync();
      await store.load();
      expect(readUi()['imdbRatingVersion'], 1);
      expect(readUi()['metaPipelineVersion'], 1);
      expect(readUi()['futureUi'], isTrue);
      expect(readUi()['metaPipeline']['rating'], {
        'mode': 'priority',
        'order': ['bangumi', 'douban', 'imdb'],
        'ratingOption': {'keep': 1},
      });
      expect(
        (jsonDecode(file.readAsStringSync()) as Map)['futureRoot'],
        'keep',
      );
    },
  );
}
