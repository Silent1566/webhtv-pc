import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/ai_content/title_learning.dart';
import 'package:webhtv_pc/core/ai_content/title_resolution.dart';

void main() {
  group('片名规则先行', () {
    test('去掉清晰度/来源/集数/季数，抽出年份', () {
      final fields = parseTitleByRules('[4K] 繁花 The Bund S01E02 2023 官方蓝光');
      expect(fields.title, contains('繁花'));
      expect(fields.title, isNot(contains('4K')));
      expect(fields.title, isNot(contains('S01E02')));
      expect(fields.year, 2023);
      expect(fields.episodeLabel, 'S01E02');
    });

    test('中文集数标记被识别为剧集', () {
      final fields = parseTitleByRules('甄嬛传 第12集');
      expect(fields.title, contains('甄嬛传'));
      expect(fields.mediaTypeHint, TitleMediaTypeHint.tv);
      expect(fields.episodeLabel, contains('第12集'));
    });

    test('规则对空标题给出零置信度，不能当结论', () {
      final fields = parseTitleByRules('   ');
      expect(fields.title, isEmpty);
      expect(fields.ruleConfidence, 0);
    });

    test('干净片名规则置信度高，带集数标记略低', () {
      expect(parseTitleByRules('流浪地球 2019').ruleConfidence, 0.9);
      expect(parseTitleByRules('流浪地球 第3集').ruleConfidence, 0.85);
    });
  });

  group('片名决议（规则 → 学习 → AI 回退）', () {
    test('规则置信度足够时不调 AI', () {
      final resolution = decideTitleResolution(
        rawTitle: '流浪地球 2019',
        ruleFields: parseTitleByRules('流浪地球 2019'),
        learningHit: null,
        aiResolution: null,
      );
      expect(resolution.source, TitleResolutionSource.rule);
      expect(resolution.title, '流浪地球');
      expect(resolution.year, 2019);
      expect(resolution.confidence, greaterThanOrEqualTo(0.9));
    });

    test('规则低置信度时采用 AI 结果并标注来源', () {
      final ruleFields = parseTitleByRules('xx 未命名 720p');
      final resolution = decideTitleResolution(
        rawTitle: 'xx 未命名 720p',
        ruleFields: ruleFields,
        learningHit: null,
        aiResolution: const TitleAiCandidate(
          title: '真正的片名',
          year: 2022,
          mediaType: TitleMediaTypeHint.movie,
          confidence: 0.82,
        ),
      );
      expect(resolution.source, TitleResolutionSource.ai);
      expect(resolution.title, '真正的片名');
      expect(resolution.confidence, closeTo(0.82, 1e-9));
    });

    test('AI 置信度低于阈值时保留规则结果但标记低置信', () {
      final ruleFields = parseTitleByRules('模糊片名 xx');
      expect(ruleFields.ruleConfidence, lessThan(TitleResolution.minUsable));
      final resolution = decideTitleResolution(
        rawTitle: '模糊片名 xx',
        ruleFields: ruleFields,
        learningHit: null,
        aiResolution: const TitleAiCandidate(
          title: '另一个名字',
          confidence: 0.2,
        ),
      );
      expect(resolution.source, TitleResolutionSource.rule);
      expect(resolution.lowConfidence, isTrue);
      expect(resolution.confidence, lessThan(TitleResolution.minUsable));
    });

    test('学习命中优先于 AI', () {
      final resolution = decideTitleResolution(
        rawTitle: '[某站] 学过的片 e05',
        ruleFields: parseTitleByRules('[某站] 学过的片 e05'),
        learningHit: const TitleLearningHit(
          example: TitleLearningExample(
            rawTitle: '[某站] 学过的片 e05',
            resolvedTitle: '学过的片',
            year: 2018,
            mediaType: TitleMediaTypeHint.tv,
            siteKey: 'site1',
            vodId: 'v1',
            hitCount: 3,
            updatedAtMs: 0,
          ),
          score: 1.0,
        ),
        aiResolution: const TitleAiCandidate(title: '别的名字', confidence: 0.95),
      );
      expect(resolution.source, TitleResolutionSource.learning);
      expect(resolution.title, '学过的片');
      expect(resolution.year, 2018);
    });

    test('AI 输出解析：非法年份/超范围置信度被夹紧', () {
      final candidate = parseTitleAiOutput(
        '{"title":"解析片","year":"公元前","mediaType":"tv","confidence":3.7}',
      );
      expect(candidate, isNotNull);
      expect(candidate!.title, '解析片');
      expect(candidate.year, isNull);
      expect(candidate.mediaType, TitleMediaTypeHint.tv);
      expect(candidate.confidence, 1.0);
    });

    test('AI 输出没有片名时为 null', () {
      expect(parseTitleAiOutput('{"year":2020}'), isNull);
      expect(parseTitleAiOutput('没有 json'), isNull);
    });
  });

  group('片名缓存（30 天，含提示词版本）', () {
    test('30 天内有效，版本变化即失效', () {
      final generatedAt = DateTime(2026, 1, 1);
      expect(
        TitleResolutionCachePolicy.isFresh(
          generatedAtMs: generatedAt.millisecondsSinceEpoch,
          promptVersion: 3,
          currentVersion: 3,
          now: DateTime(2026, 1, 30),
        ),
        isTrue,
      );
      expect(
        TitleResolutionCachePolicy.isFresh(
          generatedAtMs: generatedAt.millisecondsSinceEpoch,
          promptVersion: 3,
          currentVersion: 4,
          now: DateTime(2026, 1, 2),
        ),
        isFalse,
      );
      expect(
        TitleResolutionCachePolicy.isFresh(
          generatedAtMs: generatedAt.millisecondsSinceEpoch,
          promptVersion: 3,
          currentVersion: 3,
          now: DateTime(2026, 2, 5),
        ),
        isFalse,
      );
    });

    test('key 区分原文与版本', () {
      final a = TitleResolutionCachePolicy.keyFor('片名', promptVersion: 1);
      final b = TitleResolutionCachePolicy.keyFor('片名', promptVersion: 2);
      expect(a, isNot(b));
      expect(TitleResolutionCachePolicy.ttl.inDays, 30);
    });
  });

  group('片名学习（500 例，5 条上下文）', () {
    TitleLearningCollection seed(int count) {
      var collection = TitleLearningCollection.empty();
      for (var i = 0; i < count; i++) {
        collection = collection.record(
          const TitleQuery(rawTitle: '模板', siteKey: 's', vodId: ''),
          TitleLearningExample(
            rawTitle: '某站 学习片$i 第1集',
            resolvedTitle: '学习片$i',
            year: 2000 + (i % 24),
            mediaType: TitleMediaTypeHint.tv,
            siteKey: 's',
            vodId: 'v$i',
            hitCount: 1,
            updatedAtMs: 1000 + i,
          ),
          now: DateTime(2026, 1, 1),
        );
      }
      return collection;
    }

    test('最多保留 500 例', () {
      final collection = seed(520);
      expect(collection.examples.length, 500);
    });

    test('同站同 id 命中给最高分；无关内容不命中', () {
      final collection = seed(3);
      final hits = collection.find(
        const TitleQuery(rawTitle: '某站 学习片1 第1集', siteKey: 's', vodId: 'v1'),
        limit: 5,
      );
      expect(hits, isNotEmpty);
      expect(hits.first.score, 1.0);
      expect(hits.first.example.resolvedTitle, '学习片1');

      final miss = collection.find(
        const TitleQuery(rawTitle: '完全不相关的标题'),
        limit: 5,
      );
      expect(miss, isEmpty);
    });

    test('返回条数不超过 5 条上下文', () {
      final collection = seed(30);
      final hits = collection.find(
        const TitleQuery(rawTitle: '某站 学习片 第1集'),
        limit: 5,
      );
      expect(hits.length, lessThanOrEqualTo(5));
      expect(TitleLearningCollection.maxItems, 500);
      expect(TitleLearningCollection.maxContexts, 5);
    });

    test('命中会累加 hitCount，JSON 往返保持', () {
      var collection = seed(1);
      collection = collection.record(
        const TitleQuery(rawTitle: '某站 学习片0 第1集', siteKey: 's', vodId: 'v0'),
        const TitleLearningExample(
          rawTitle: '某站 学习片0 第1集',
          resolvedTitle: '学习片0',
          siteKey: 's',
          vodId: 'v0',
          hitCount: 1,
          updatedAtMs: 9999,
        ),
        now: DateTime(2026, 1, 2),
      );
      expect(collection.examples.first.hitCount, 2);
      final restored = TitleLearningCollection.fromJson(collection.toJson());
      expect(restored.examples.first.hitCount, 2);
    });
  });
}
