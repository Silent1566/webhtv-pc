import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/external_detail_meta.dart';
import 'package:webhtv_pc/core/external_meta.dart';
import 'package:webhtv_pc/core/meta_pipeline.dart';
import 'package:webhtv_pc/core/meta_source.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';

void main() {
  test('malformed unsupported source is normalized and explicitly empty work order survives roundtrip', () {
    final pipeline = MetaPipeline.fromJson({
      'rating': {
        'order': ['source', 'bangumi'],
      },
      'title': {'order': []},
    });
    expect(pipeline.orderOf(MetaField.rating), [MetaSourceKind.bangumi]);
    expect(
      MetaPipeline.fromJson(pipeline.toJson()).orderOf(MetaField.title),
      isEmpty,
    );
  });

  test('configured default title uses external title without changing original Vod', () {
    final vod = Vod(vodId: 'local', vodName: 'Original resource');
    final external = ExternalDetailMeta.douban(
      identity: MetaIdentity.of(
        MetaSourceKind.douban,
        TmdbMediaType.movie,
        12,
      )!,
      subject: {'title': 'Provider title'},
    )!;
    expect(external.forSource(vod).title, 'Provider title');
    expect(vod.vodName, 'Original resource');
    final sourceFirst = MetaPipeline.defaults.withRule(
      MetaPipeline.defaults.ruleOf(MetaField.title).copyWith(
        order: [MetaSourceKind.source, MetaSourceKind.douban],
      ),
    );
    expect(external.forSource(vod, pipeline: sourceFirst).title, 'Original resource');
  });

  test('legacy reordered rules gain last source once and explicit removal survives reload', () async {
    final dir = Directory.systemTemp.createTempSync('crawler-rules');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/settings.json');
    file.writeAsStringSync(
      jsonEncode({
        'ui': {
          'metaPipeline': {
            'title': {
              'mode': 'aggregate',
              'order': ['bangumi', 'douban'],
            },
            'rating': {
              'mode': 'priority',
              'order': ['bangumi'],
            },
          },
        },
        'custom': 42,
      }),
    );
    final store = UiPreferencesStore(path: file.path);
    await store.load();
    expect(store.metaPipeline.orderOf(MetaField.title), [
      MetaSourceKind.bangumi,
      MetaSourceKind.douban,
      MetaSourceKind.source,
    ]);
    expect(
      (jsonDecode(file.readAsStringSync()) as Map)['ui']['metaPipelineVersion'],
      1,
      reason: 'loading legacy rules completes the migration once',
    );
    expect(store.metaPipeline.modeOf(MetaField.title), MetaFieldMode.aggregate);
    expect(store.metaPipeline.orderOf(MetaField.rating), [
      MetaSourceKind.bangumi,
    ]);
    await store.rememberMetaPipeline(
      store.metaPipeline.toggleSource(MetaField.title, MetaSourceKind.source),
    );
    final reopened = UiPreferencesStore(path: file.path);
    await reopened.load();
    expect(reopened.metaPipeline.orderOf(MetaField.title), [
      MetaSourceKind.bangumi,
      MetaSourceKind.douban,
    ]);
    expect((jsonDecode(file.readAsStringSync()) as Map)['custom'], 42);
  });

  test('all-default preferences serialize migration version before explicit removal', () async {
    final dir = Directory.systemTemp.createTempSync('crawler-default-rules');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/settings.json');
    final store = UiPreferencesStore(path: file.path);
    await store.load();
    await store.rememberMetaPipeline(MetaPipeline.defaults);
    final ui = (jsonDecode(file.readAsStringSync()) as Map)['ui'] as Map;
    expect(ui['metaPipelineVersion'], 1);
    await store.rememberMetaPipeline(
      store.metaPipeline.toggleSource(
        MetaField.overview,
        MetaSourceKind.source,
      ),
    );
    final reopened = UiPreferencesStore(path: file.path);
    await reopened.load();
    expect(
      reopened.metaPipeline.orderOf(MetaField.overview),
      isNot(contains(MetaSourceKind.source)),
    );
  });
  test('legacy migration preserves unknown UI entries pipeline fields and rule extras', () async {
    final dir = Directory.systemTemp.createTempSync('crawler-preserve-migration');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/settings.json');
    final futureOption = {'nested': [true, 7, 'keep']};
    final futureField = {'mode': 'future-mode', 'order': ['future-provider'], 'opaque': 9};
    file.writeAsStringSync(jsonEncode({'ui': {
      'futureOption': futureOption,
      'metaPipeline': {
        'futureField': futureField,
        'title': {'mode': 'aggregate', 'order': ['bangumi', 'douban'], 'futureRuleOption': {'keep': 1}},
        'rating': {'mode': 'priority', 'order': ['bangumi'], 'futureRatingOption': true},
      },
    }, 'other': {'keep': 42}}));
    final store = UiPreferencesStore(path: file.path);
    await store.load();
    final root = jsonDecode(file.readAsStringSync()) as Map;
    final ui = root['ui'] as Map;
    final rules = ui['metaPipeline'] as Map;
    expect(ui['futureOption'], futureOption);
    expect(rules['futureField'], futureField);
    expect(rules['title'], {'mode': 'aggregate', 'order': ['bangumi', 'douban', 'source'], 'futureRuleOption': {'keep': 1}});
    expect(rules['rating'], {'mode': 'priority', 'order': ['bangumi'], 'futureRatingOption': true});
    expect(ui['metaPipelineVersion'], 1);
    expect(root['other'], {'keep': 42});
    final once = file.readAsStringSync();
    await UiPreferencesStore(path: file.path).load();
    expect(file.readAsStringSync(), once, reason: 'a completed migration must not write a second time');
  });

  test('failed migration leaves legacy file intact and retries safely on next load', () async {
    final dir = Directory.systemTemp.createTempSync('crawler-retry-migration');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/settings.json');
    final legacy = jsonEncode({'ui': {'futureOption': 'keep', 'metaPipeline': {
      'title': {'order': ['douban'], 'futureRuleOption': true}, 'futureField': {'keep': 3},
    }}});
    file.writeAsStringSync(legacy);
    final blocker = Directory('${file.path}.ui.tmp')..createSync();
    final store = UiPreferencesStore(path: file.path);
    await store.load();
    expect(store.loaded, isTrue);
    expect(store.metaPipeline.orderOf(MetaField.title), [MetaSourceKind.douban, MetaSourceKind.source]);
    expect(file.readAsStringSync(), legacy, reason: 'failed migration cannot destroy the existing file');
    blocker.deleteSync();
    await store.load();
    final ui = (jsonDecode(file.readAsStringSync()) as Map)['ui'] as Map;
    expect(ui['futureOption'], 'keep');
    expect(ui['metaPipelineVersion'], 1);
    expect(ui['metaPipeline']['futureField'], {'keep': 3});
    expect(ui['metaPipeline']['title']['futureRuleOption'], isTrue);
    expect(ui['metaPipeline']['title']['order'], ['douban', 'source']);
  });

}
