import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/external_meta.dart';
import 'package:webhtv_pc/core/meta_pipeline.dart';
import 'package:webhtv_pc/core/meta_source.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';

void main() {
  test('crawler source has a stable key without external work or person identity', () {
    final source = MetaSourceKind.parse('source');
    expect(source, isNotNull);
    expect(source!.label, '爬虫源');
    expect(source.key, 'source');
    expect(source.isFallback, isFalse);
    expect(MetaPersonRef.of(source, 1), isNull);
    expect(MetaIdentity.of(source, TmdbMediaType.tv, 1), isNull);
    expect(MetaIdentity.parse('source:tv:1'), isNull);
  });

  test('legacy rules gain crawler fallback once without changing other order', () {
    final legacy = MetaPipeline.fromJson({
      'overview': {'mode': 'priority', 'order': ['bangumi', 'douban']},
      'photos': {'mode': 'aggregate', 'order': ['douban']},
    });
    final upgraded = legacy.withSourceFallbackAdded();
    expect(upgraded.orderOf(MetaField.overview).map((source) => source.key),
        ['bangumi', 'douban', 'source']);
    expect(upgraded.orderOf(MetaField.photos).map((source) => source.key), ['douban']);
    expect(upgraded.withSourceFallbackAdded().toJson(), upgraded.toJson());
    expect(MetaPipeline.supportsSource(MetaField.title), isTrue);
    expect(MetaPipeline.supportsSource(MetaField.photos), isFalse);
  });

  test('exactly ten resource fields default to crawler source last', () {
    const unsupported = {
      MetaField.rating, MetaField.photos, MetaField.comments,
      MetaField.personBiography, MetaField.personPhotos,
    };
    for (final field in MetaField.values) {
      final order = MetaPipeline.defaults.orderOf(field).map((source) => source.key);
      if (unsupported.contains(field)) {
        expect(order, isNot(contains('source')), reason: field.name);
      } else {
        expect(order.last, 'source', reason: field.name);
        expect(order.where((source) => source == 'source'), hasLength(1));
      }
    }
  });
}
