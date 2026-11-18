import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/meta_pipeline.dart';
import 'package:webhtv_pc/core/meta_source.dart';

typedef Ctx = List<String>;

void main() {
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
          MetaSourceKind.wikidata => <String>[],
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