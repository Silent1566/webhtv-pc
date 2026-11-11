import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/ai_config.dart';
import 'package:webhtv_pc/core/ai_content/recommendation.dart';
import 'package:webhtv_pc/core/ai_content/recommendation_feedback.dart';

String payload(int count, {String titlePrefix = '片名'}) {
  final items = <String>[
    for (var i = 0; i < count; i++)
      '{"title":"$titlePrefix$i","year":${2000 + (i % 20)},'
          '"mediaType":"${i.isEven ? 'movie' : 'tv'}","reason":"理由$i"}',
  ];
  return '{"items":[${items.join(',')}]}';
}

AiConfig readyConfig() => const AiConfig(
  enabled: true,
  apiKey: 'k',
  endpoint: 'https://example.com/v1',
  model: 'm',
);

void main() {
  group('推荐输入（当前/历史/搜索）', () {
    test('数量夹到 12..24，默认 16', () {
      final low = RecommendationRequest(
        source: RecommendationSource.current,
        count: 3,
      );
      expect(low.clampedCount, 12);
      final high = RecommendationRequest(
        source: RecommendationSource.history,
        count: 99,
      );
      expect(high.clampedCount, 24);
      expect(
        const RecommendationRequest(source: RecommendationSource.search)
            .clampedCount,
        16,
      );
    });

    test('上下文最多 24 条，超出截断', () {
      final contexts = [
        for (var i = 0; i < 40; i++)
          WatchContextItem(
            title: '标题$i',
            mediaType: RecommendationMediaType.movie,
          ),
      ];
      final request = RecommendationRequest(
        source: RecommendationSource.history,
        contexts: contexts,
      );
      expect(request.contexts.length, 40);
      expect(request.trimmedContexts.length, 24);
    });

    test('三种输入都能构造提示词并声明数据不可信', () {
      for (final source in RecommendationSource.values) {
        final prompt = buildRecommendationPrompt(
          config: readyConfig(),
          request: RecommendationRequest(
            source: source,
            seed: const WatchContextItem(
              title: '信号',
              mediaType: RecommendationMediaType.tv,
            ),
          ),
        );
        expect(prompt, contains('不可信'));
        expect(prompt, contains('"seed"'));
        expect(prompt, contains(source.id));
        expect(prompt, contains('"items"'));
      }
    });
  });

  group('推荐输出解析（不可信 JSON）', () {
    test('12 条与 24 条都能解析', () {
      expect(parseRecommendationItems(payload(12)).length, 12);
      expect(parseRecommendationItems(payload(24)).length, 24);
    });

    test('超过 24 条截断到 24，脏数据被丢弃', () {
      final dirty =
          '{"items":['
          '{"title":"  ","year":2024,"mediaType":"movie","reason":"空标题"},'
          '{"title":"好片","year":"不是年份","mediaType":"film","reason":"x"},'
          '${[
            for (var i = 0; i < 30; i++)
              '{"title":"片$i","year":2020,"mediaType":"tv","reason":"r"}',
          ].join(',')}'
          ']}';
      final items = parseRecommendationItems(dirty);
      expect(items.length, 24);
      expect(items.first.title, '好片');
      expect(items.first.year, isNull);
      expect(items.first.mediaType, RecommendationMediaType.movie);
    });

    test('没有 JSON 对象时返回空列表，不抛异常', () {
      expect(parseRecommendationItems('模型说：今天天气不错'), isEmpty);
      expect(parseRecommendationItems(''), isEmpty);
    });

    test('理由过长截断，年份越界丢弃', () {
      final longReason = 'x' * 500;
      final text =
          '{"items":[{"title":"A","year":1200,"mediaType":"movie",'
          '"reason":"$longReason"}]}';
      final item = parseRecommendationItems(text).single;
      expect(item.year, isNull);
      expect(item.reason.length, lessThanOrEqualTo(80));
    });
  });

  group('负反馈过滤（200 条 / 90 天）', () {
    final now = DateTime(2026, 11, 10, 12);

    RecommendationFeedbackCollection withEntry({
      required String title,
      int? year,
      Duration age = Duration.zero,
    }) => RecommendationFeedbackCollection.empty().add(
      RecommendationFeedbackEntry(
        title: title,
        year: year,
        createdAtMs: now.subtract(age).millisecondsSinceEpoch,
      ),
      now: now,
    );

    test('命中的片名被过滤，其余保留', () {
      final feedback = withEntry(title: '不想看', year: 2024);
      final cards = [
        const RecommendationCard(
          title: '不想看',
          year: 2024,
          mediaType: RecommendationMediaType.movie,
          reason: 'r',
        ),
        const RecommendationCard(
          title: '想看',
          year: 2024,
          mediaType: RecommendationMediaType.movie,
          reason: 'r',
        ),
      ];
      final kept = filterRecommendationsByFeedback(cards, feedback, now: now);
      expect(kept.map((c) => c.title), ['想看']);
    });

    test('超过 90 天的负反馈自动失效', () {
      final feedback = withEntry(
        title: '旧片',
        age: const Duration(days: 91),
      );
      expect(feedback.entries, isEmpty);
      final kept = filterRecommendationsByFeedback(
        const [
          RecommendationCard(
            title: '旧片',
            mediaType: RecommendationMediaType.tv,
            reason: 'r',
          ),
        ],
        feedback,
        now: now,
      );
      expect(kept.length, 1);
    });

    test('最多保留 200 条，超出丢最旧', () {
      var collection = RecommendationFeedbackCollection.empty();
      for (var i = 0; i < 250; i++) {
        collection = collection.add(
          RecommendationFeedbackEntry(
            title: '片$i',
            createdAtMs: now
                .subtract(Duration(minutes: 250 - i))
                .millisecondsSinceEpoch,
          ),
          now: now,
        );
      }
      expect(collection.entries.length, 200);
      // 保留最新的：最后写入的片 249 一定在，最早写入的片 0 已被丢弃。
      expect(collection.entries.first.title, '片50');
      expect(collection.entries.last.title, '片249');
    });

    test('归一化后匹配：大小写/空格/标点差异仍算命中', () {
      final feedback = withEntry(title: 'The  Office');
      expect(feedback.matches('theoffice', null, null), isTrue);
    });

    test('JSON 往返保持条目', () {
      final feedback = withEntry(title: '往返', year: 2019);
      final restored = RecommendationFeedbackCollection.fromJson(
        feedback.toJson(),
      );
      expect(restored.entries.single.title, '往返');
      expect(restored.entries.single.year, 2019);
    });
  });

  group('TMDB 富集与降级卡', () {
    test('富集命中时填 tmdb 身份与海报', () {
      final card = RecommendationCard.fromItem(
        const RecommendationItem(
          title: '富集片',
          year: 2021,
          mediaType: RecommendationMediaType.tv,
          reason: 'r',
        ),
        enrichment: const RecommendationEnrichment(
          tmdbId: 42,
          mediaType: RecommendationMediaType.tv,
          posterUrl: 'https://img/p.jpg',
          overview: '简介',
          rating: 8.2,
        ),
      );
      expect(card.enriched, isTrue);
      expect(card.degraded, isFalse);
      expect(card.tmdbKey, 'tv:42');
      expect(card.posterUrl, 'https://img/p.jpg');
      expect(card.rating, 8.2);
    });

    test('没有富集结果时保留降级卡（片名卡）', () {
      final card = RecommendationCard.fromItem(
        const RecommendationItem(
          title: '降级片',
          mediaType: RecommendationMediaType.movie,
          reason: 'r',
        ),
      );
      expect(card.enriched, isFalse);
      expect(card.degraded, isTrue);
      expect(card.title, '降级片');
      expect(card.tmdbKey, isNull);
    });

    test('缓存与降级卡可 JSON 往返', () {
      final card = RecommendationCard.fromItem(
        const RecommendationItem(
          title: '往返片',
          year: 2020,
          mediaType: RecommendationMediaType.movie,
          reason: 'r',
        ),
        enrichment: const RecommendationEnrichment(
          tmdbId: 7,
          mediaType: RecommendationMediaType.movie,
        ),
      );
      final restored = RecommendationCard.fromJson(card.toJson());
      expect(restored, isNotNull);
      expect(restored!.title, '往返片');
      expect(restored.year, 2020);
      expect(restored.tmdbKey, 'movie:7');
    });
  });

  group('推荐缓存策略', () {
    test('key 区分输入来源与站点', () {
      final a = RecommendationCachePolicy.keyFor(
        const RecommendationRequest(
          source: RecommendationSource.current,
          siteKey: 's1',
        ),
      );
      final b = RecommendationCachePolicy.keyFor(
        const RecommendationRequest(
          source: RecommendationSource.search,
          siteKey: 's1',
        ),
      );
      expect(a, isNot(b));
    });

    test('7 天后过期，条目上限 128', () {
      expect(
        RecommendationCachePolicy.maxItems,
        128,
      );
      expect(RecommendationCachePolicy.maxFiles, 32);
      final fresh = DateTime(2026, 1, 8);
      expect(
        RecommendationCachePolicy.isFresh(
          generatedAtMs: DateTime(2026, 1, 1, 12).millisecondsSinceEpoch,
          now: fresh,
        ),
        isTrue,
      );
      expect(
        RecommendationCachePolicy.isFresh(
          generatedAtMs: DateTime(2026, 1, 1).millisecondsSinceEpoch,
          now: DateTime(2026, 1, 9),
        ),
        isFalse,
      );
    });
  });
}
