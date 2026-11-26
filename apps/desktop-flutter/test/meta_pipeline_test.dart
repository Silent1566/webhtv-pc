import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/meta_pipeline.dart';
import 'package:webhtv_pc/core/external_meta.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/meta_source.dart';

typedef Ctx = List<String>;

void main() {
  test('IMDb is enabled last for ratings and absent from other fields', () {
    final imdb = MetaSourceKind.parse('imdb');
    expect(imdb, isNotNull);
    expect(MetaPipeline.defaults.orderOf(MetaField.rating), [
      MetaSourceKind.tmdb,
      MetaSourceKind.douban,
      MetaSourceKind.bangumi,
      imdb,
    ]);
    expect(MetaPipeline.defaults.modeOf(MetaField.rating), MetaFieldMode.aggregate);
    for (final field in MetaField.values.where((f) => f != MetaField.rating)) {
      expect(MetaPipeline.defaults.orderOf(field), isNot(contains(imdb)));
    }
  });

  test('source capabilities preserve old fields and restrict IMDb to rating', () {
    const sourceFields = {
      MetaField.title, MetaField.overview, MetaField.poster, MetaField.backdrop,
      MetaField.cast, MetaField.crew, MetaField.genres, MetaField.countries,
      MetaField.languages, MetaField.releaseDate,
    };
    for (final field in MetaField.values) {
      expect(MetaPipeline.supports(MetaSourceKind.imdb, field), field == MetaField.rating);
      expect(MetaPipeline.supportsSource(field), sourceFields.contains(field));
      expect(MetaPipeline.supports(MetaSourceKind.source, field), sourceFields.contains(field));
      for (final kind in [MetaSourceKind.tmdb, MetaSourceKind.douban, MetaSourceKind.bangumi, MetaSourceKind.wikidata]) {
        expect(MetaPipeline.supports(kind, field), isTrue);
      }
    }
    expect(MetaSourceKind.values[2], MetaSourceKind.imdb);
    expect(MetaSourceKind.imdb.label, 'IMDb');
    expect(MetaSourceKind.imdb.key, 'imdb');
    expect(MetaSourceKind.imdb.isFallback, isFalse);
    expect(MetaPersonRef.of(MetaSourceKind.imdb, 123), isNull);
    expect(MetaIdentity.of(MetaSourceKind.imdb, TmdbMediaType.movie, 123), isNull);
  });

  test('IMDb parses only in ratings and toggles without changing other fields', () {
    final pipeline = MetaPipeline.fromJson({
      'rating': {'mode': 'aggregate', 'order': ['douban', 'imdb', 'imdb']},
      'title': {'mode': 'priority', 'order': ['imdb', 'bangumi']},
      'poster': {'order': ['imdb']},
    });
    expect(pipeline.orderOf(MetaField.rating), [MetaSourceKind.douban, MetaSourceKind.imdb]);
    expect(pipeline.orderOf(MetaField.title), [MetaSourceKind.bangumi]);
    expect(pipeline.orderOf(MetaField.poster), isNot(contains(MetaSourceKind.imdb)));
    expect(pipeline.toggleSource(MetaField.title, MetaSourceKind.imdb), same(pipeline));
    final off = pipeline.toggleSource(MetaField.rating, MetaSourceKind.imdb);
    expect(off.orderOf(MetaField.rating), [MetaSourceKind.douban]);
    expect(off.toggleSource(MetaField.rating, MetaSourceKind.imdb).orderOf(MetaField.rating),
      [MetaSourceKind.douban, MetaSourceKind.imdb]);
  });

  test('rating may disable its last source and preserve empty order on JSON round trip', () {
    final onlyImdb = MetaPipeline.fromJson({'rating': {'mode': 'aggregate', 'order': ['imdb']}});
    final off = onlyImdb.toggleSource(MetaField.rating, MetaSourceKind.imdb);
    expect(off.orderOf(MetaField.rating), isEmpty);
    expect(off.isDefault, isFalse);
    expect(MetaPipeline.fromJson(off.toJson()).orderOf(MetaField.rating), isEmpty);
    expect(off.toggleSource(MetaField.rating, MetaSourceKind.imdb).orderOf(MetaField.rating), [MetaSourceKind.imdb]);
    final person = MetaPipeline.fromJson({'personBiography': {'order': ['bangumi']}});
    expect(person.toggleSource(MetaField.personBiography, MetaSourceKind.bangumi).orderOf(MetaField.personBiography),
      MetaPipeline.defaults.orderOf(MetaField.personBiography));
    final title = MetaPipeline.fromJson({'title': {'order': ['tmdb']}});
    expect(title.toggleSource(MetaField.title, MetaSourceKind.tmdb).orderOf(MetaField.title), isEmpty);
  });

  test('old custom rating order is preserved without an IMDb migration', () {
    final old = MetaPipeline.fromJson({
      'rating': {'mode': 'priority', 'order': ['bangumi', 'douban']},
    });
    expect(old.orderOf(MetaField.rating), [MetaSourceKind.bangumi, MetaSourceKind.douban]);
    expect(old.modeOf(MetaField.rating), MetaFieldMode.priority);
    expect(old.toggleSource(MetaField.rating, MetaSourceKind.imdb).orderOf(MetaField.rating),
      [MetaSourceKind.bangumi, MetaSourceKind.douban, MetaSourceKind.imdb]);
    expect(MetaPipeline.fromJson({}).orderOf(MetaField.rating).last, MetaSourceKind.imdb);
  });

  test('默认：文本字段逐字段优先，照片与评论并行聚合', () {
    final pipeline = MetaPipeline.defaults;
    expect(pipeline.modeOf(MetaField.overview), MetaFieldMode.priority);
    expect(pipeline.modeOf(MetaField.cast), MetaFieldMode.priority);
    expect(pipeline.modeOf(MetaField.photos), MetaFieldMode.aggregate);
    expect(pipeline.modeOf(MetaField.comments), MetaFieldMode.aggregate);
    expect(pipeline.orderOf(MetaField.overview).first, MetaSourceKind.tmdb);
    expect(pipeline.orderOf(MetaField.overview)[1], MetaSourceKind.douban);
    expect(pipeline.isDefault, isTrue);
  });

  test('优先字段：TMDB 有值就不查后面的来源', () async {
    final asked = <MetaSourceKind>[];
    final value = await MetaPipelineResolver.resolvePriority<String>(
      pipeline: MetaPipeline.defaults,
      field: MetaField.overview,
      fetch: (source) async {
        asked.add(source);
        return source == MetaSourceKind.tmdb ? 'TMDB 简介' : '其它简介';
      },
    );
    expect(value, 'TMDB 简介');
    expect(asked, [MetaSourceKind.tmdb]);
  });

  test('优先字段：前面的来源为空才轮到下一个，全空返回 null', () async {
    final asked = <MetaSourceKind>[];
    final value = await MetaPipelineResolver.resolvePriority<String>(
      pipeline: MetaPipeline.defaults,
      field: MetaField.overview,
      fetch: (source) async {
        asked.add(source);
        return source == MetaSourceKind.bangumi ? 'Bangumi 简介' : '';
      },
    );
    expect(value, 'Bangumi 简介');
    // 命中 Bangumi 后不再查 Wikidata：优先字段「取到即停」。
    expect(asked, [
      MetaSourceKind.tmdb, MetaSourceKind.douban, MetaSourceKind.bangumi,
    ]);
    final none = await MetaPipelineResolver.resolvePriority<String>(
      pipeline: MetaPipeline.defaults,
      field: MetaField.overview,
      fetch: (_) async => '   ',
    );
    expect(none, isNull);
  });

  test('用户可把某个字段的来源顺序改成豆瓣优先', () async {
    final pipeline = MetaPipeline.defaults.withRule(
      MetaPipeline.defaults.ruleOf(MetaField.overview).copyWith(
        order: const [MetaSourceKind.douban, MetaSourceKind.tmdb],
      ),
    );
    final asked = <MetaSourceKind>[];
    await MetaPipelineResolver.resolvePriority<String>(
      pipeline: pipeline,
      field: MetaField.overview,
      fetch: (source) async { asked.add(source); return 'x'; },
    );
    expect(asked, [MetaSourceKind.douban]);
  });

  test('聚合字段：全部来源并行取并按顺序拼接去重', () async {
    final asked = <MetaSourceKind>[];
    final photos = await MetaPipelineResolver.resolveAggregate<String>(
      pipeline: MetaPipeline.defaults,
      field: MetaField.photos,
      dedupeKey: (url) => url,
      fetch: (source) async {
        asked.add(source);
        return switch (source) {
          MetaSourceKind.tmdb => ['a.jpg', 'b.jpg'],
          MetaSourceKind.douban => ['b.jpg', 'c.jpg'],
          MetaSourceKind.bangumi => ['d.jpg'],
          MetaSourceKind.wikidata || MetaSourceKind.source || MetaSourceKind.imdb => <String>[],
        };
      },
    );
    // 默认照片只聚合 TMDB + 豆瓣（用户决策 A：同类才混，不混横竖版）。
    expect(photos, ['a.jpg', 'b.jpg', 'c.jpg']);
    expect(asked.toSet(), {
      MetaSourceKind.tmdb, MetaSourceKind.douban,
    });
  });

  test('聚合可切回优先：只取第一个有结果的来源', () async {
    final pipeline = MetaPipeline.defaults.withRule(
      MetaPipeline.defaults.ruleOf(MetaField.photos).copyWith(
        mode: MetaFieldMode.priority,
      ),
    );
    final asked = <MetaSourceKind>[];
    final value = await MetaPipelineResolver.resolvePriority<List<String>>(
      pipeline: pipeline,
      field: MetaField.photos,
      fetch: (source) async {
        asked.add(source);
        return source == MetaSourceKind.douban ? ['d.jpg'] : <String>[];
      },
    );
    expect(value, ['d.jpg']);
    expect(asked, [MetaSourceKind.tmdb, MetaSourceKind.douban]);
  });

  test('持久化往返：非法值忽略，缺失字段回落到默认', () {
    final custom = MetaPipeline.defaults.withRule(
      MetaFieldRule(
        field: MetaField.comments,
        mode: MetaFieldMode.aggregate,
        order: const [MetaSourceKind.douban, MetaSourceKind.bangumi],
      ),
    );
    final restored = MetaPipeline.fromJson(custom.toJson());
    expect(restored.orderOf(MetaField.comments).last, MetaSourceKind.bangumi);
    expect(restored.orderOf(MetaField.overview), MetaPipeline.defaults.orderOf(MetaField.overview));

    final messy = MetaPipeline.fromJson({
      'overview': {'mode': 'nonsense', 'order': ['douban', 'aliens']},
      'unknownField': {'mode': 'priority'},
      'photos': {'mode': 'priority', 'order': <String>[]},
    });
    expect(messy.modeOf(MetaField.overview), MetaFieldMode.priority);
    expect(messy.orderOf(MetaField.overview), [MetaSourceKind.douban]);
    expect(messy.modeOf(MetaField.photos), MetaFieldMode.priority);
    expect(messy.orderOf(MetaField.photos), MetaPipeline.defaults.orderOf(MetaField.photos));
  });

  test('字段与模式的机器名稳定，中文文案可改', () {
    expect(MetaField.overview.key, 'overview');
    expect(MetaField.parse('photos'), MetaField.photos);
    expect(MetaField.parse('海报'), isNull);
    expect(MetaFieldMode.parse('aggregate'), MetaFieldMode.aggregate);
    expect(MetaFieldMode.priority.label, contains('优先'));
  });
}