/// Task5 · Task4 typed 片名结果到季集身份回退的桥接（红绿合同）。
///
/// 合同：只做适配与闸门，不重造片名 AI；弱信心不覆盖既有强匹配；不猜 TMDB ID
/// （回退只把清洗后的片名交给 TMDB 搜索，ID 只能由 TMDB 命中给出）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/ai_content/title_resolution.dart';
import 'package:webhtv_pc/services/ai_content_title_bridge.dart';
import 'package:webhtv_pc/services/ai_season_mapping_service.dart';
import 'package:webhtv_pc/services/tmdb_identity_service.dart';

void main() {
  group('AiContentTitleResolverAdapter（Task4 typed → Task5 注入点）', () {
    test('typed 结果带置信度映射；标题为空 → null', () async {
      final adapter = AiContentTitleResolverAdapter(
        resolveTyped: (query) async => TitleResolution(
          rawTitle: query.rawTitle,
          title: '进击的巨人',
          confidence: 0.86,
          year: 2013,
          mediaType: TitleMediaTypeHint.tv,
          source: TitleResolutionSource.rule,
        ),
      );
      final resolved = await adapter.resolve(
        const SeasonTitleQuery(rawTitle: '进击的巨人 第一季 1080P'),
      );
      expect(resolved, isNotNull);
      expect(resolved!.title, '进击的巨人');
      expect(resolved.confidence, 0.86);
      expect(resolved.mediaType, 'tv');
      expect(resolved.year, 2013);

      final empty = AiContentTitleResolverAdapter(
        resolveTyped: (query) async => TitleResolution(
          rawTitle: query.rawTitle,
          title: '   ',
          confidence: 0.9,
          source: TitleResolutionSource.ai,
        ),
      );
      expect(
        await empty.resolve(const SeasonTitleQuery(rawTitle: 'x')),
        isNull,
      );
    });

    test('typed resolver 返回 null → null（不抛、不猜）', () async {
      final adapter = AiContentTitleResolverAdapter(
        resolveTyped: (query) async => null,
      );
      expect(
        await adapter.resolve(const SeasonTitleQuery(rawTitle: 'x')),
        isNull,
      );
    });
  });

  group('identityFallbackRequest（弱不覆盖 / 不猜ID）', () {
    test('既有命中（无 searchKeyword 需求）→ 不产生回退请求', () {
      final result = identityFallbackRequest(
        rawTitle: '某剧 第一季',
        existingTmdbId: 99,
        existingIsManual: false,
        resolution: const SeasonTitleResolution(
          title: '某剧',
          confidence: 0.95,
        ),
      );
      expect(result, isNull);
    });

    test('无既有匹配 + 强信心 → 用清洗片名作为检索词', () {
      final result = identityFallbackRequest(
        rawTitle: '某剧 第一季',
        existingTmdbId: 0,
        existingIsManual: false,
        resolution: const SeasonTitleResolution(
          title: '某剧',
          confidence: 0.9,
        ),
      );
      expect(result, '某剧');
    });

    test('无既有匹配 + 弱信心 → 不回退', () {
      final result = identityFallbackRequest(
        rawTitle: '某剧 第一季',
        existingTmdbId: 0,
        existingIsManual: false,
        resolution: const SeasonTitleResolution(
          title: '某剧',
          confidence: 0.4,
        ),
      );
      expect(result, isNull);
    });

    test('无既有匹配 + resolver 缺失 → 不回退', () {
      expect(
        identityFallbackRequest(
          rawTitle: '某剧 第一季',
          existingTmdbId: 0,
          existingIsManual: false,
          resolution: null,
        ),
        isNull,
      );
    });

    test('manual 既有匹配 → 即使 resolver 强信心也不覆盖', () {
      expect(
        identityFallbackRequest(
          rawTitle: '某剧 第一季',
          existingTmdbId: 12,
          existingIsManual: true,
          resolution: const SeasonTitleResolution(title: '某剧', confidence: 1.0),
        ),
        isNull,
      );
    });

    test('R5 adapter→闸门→真实TmdbMatchRequest；String? vodYear未进入typed query', () async {
      const rawTitle = '某剧 第一季';
      TitleQuery? received;
      final adapter = AiContentTitleResolverAdapter(resolveTyped: (query) async {
        received = query;
        return TitleResolution(
          rawTitle: query.rawTitle, title: ' 某剧 ', confidence: 0.9,
          year: 2013, mediaType: TitleMediaTypeHint.tv,
          source: TitleResolutionSource.rule,
        );
      });
      final resolution = await adapter.resolve(
        const SeasonTitleQuery(rawTitle: rawTitle, vodYear: '2024'),
      );
      expect(received, isNotNull);
      expect(received!.rawTitle, rawTitle);
      expect(received!.siteKey, '');
      expect(received!.vodId, '');
      expect(received!.vodRemarks, '');
      expect(resolution!.title, '某剧');
      expect(resolution.confidence, 0.9);
      expect(resolution.year, 2013, reason: '输出年份来自typed resolver，不是vodYear输入');
      expect(resolution.mediaType, 'tv');
      final keyword = identityFallbackRequest(
        rawTitle: rawTitle, existingTmdbId: 0, existingIsManual: false,
        resolution: resolution,
      );
      expect(keyword, '某剧');
      final request = TmdbMatchRequest(
        siteKey: 's', vodId: 'v', sourceTitle: rawTitle,
        searchKeyword: keyword, vodName: '站点原名', vodYear: '2024',
      );
      expect(request.searchKeyword, '某剧');
      expect(request.sourceTitle, rawTitle);
      expect(request.vodYear, '2024');
      expect(request.matchSourceText, '某剧 某剧 第一季 站点原名');
      expect(identityFallbackRequest(
        rawTitle: rawTitle, existingTmdbId: 99, existingIsManual: false,
        resolution: resolution,
      ), isNull);
      expect(identityFallbackRequest(
        rawTitle: rawTitle, existingTmdbId: 0, existingIsManual: false,
        resolution: const SeasonTitleResolution(title: '某剧', confidence: 0.4),
      ), isNull);
    });
  });
}

