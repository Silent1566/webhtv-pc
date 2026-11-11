import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/detail_recommendation.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/recommendation_feedback_store.dart';
import 'package:webhtv_pc/state/detail_recommendation_state.dart';

RecommendationEntry entry(int id, [String? title]) => RecommendationEntry(
  item: TmdbItem(
    tmdbId: id,
    mediaType: TmdbMediaType.movie,
    title: title ?? 'item$id',
  ),
  source: RecommendationSource.tmdb,
);
const seed = RecommendationSeed(
  title: 'current',
  tmdbId: 1,
  mediaType: TmdbMediaType.movie,
);
void main() {
  test(
    'last lease cancels pending TMDB before history requests start',
    () async {
      final directory = await Directory.systemTemp.createTemp('tmdb_lease_');
      final started = Completer<void>();
      final response = Completer<http.Response>();
      final requests = <String>[];
      final service = TmdbService(
        config: () => const TmdbConfig(apiKey: 'test-key'),
        client: MockClient((request) async {
          requests.add(request.url.path);
          if (request.url.path.endsWith('/movie/1')) {
            if (!started.isCompleted) started.complete();
            return response.future;
          }
          return http.Response(
            jsonEncode({
              'id': 2,
              'title': 'watched',
              'recommendations': {'results': []},
              'similar': {'results': []},
              'results': [],
            }),
            200,
          );
        }),
      );
      final dependencies = DetailRecommendationDependencies.fromServices(
        service: service,
        cacheDirectory: directory,
      );
      addTearDown(() async {
        dependencies.close();
        service.close();
        await directory.delete(recursive: true);
      });
      final loaders = dependencies.acquire();
      final pending = loaders[RecommendationRow.tmdb]!(
        const RecommendationRequest(
          current: seed,
          history: [
            RecommendationSeed(
              title: 'watched',
              tmdbId: 2,
              mediaType: TmdbMediaType.movie,
            ),
          ],
        ),
      ).then<Object>((value) => value, onError: (Object error) => error);
      await started.future;
      dependencies.release();
      final countAtRelease = requests.length;
      response.complete(
        http.Response(
          jsonEncode({
            'id': 1,
            'title': 'current',
            'recommendations': {'results': []},
            'similar': {'results': []},
          }),
          200,
        ),
      );
      final result = await pending;
      expect(result, isA<TmdbCancelledException>());
      expect(requests.length, countAtRelease);
      expect(requests.any((path) => path.endsWith('/movie/2')), isFalse);
      // A new lease recreates providers, not the shared feedback store.
      dependencies.feedback.block('keep-blocked');
      final feedback = dependencies.feedback;
      dependencies.acquire();
      expect(dependencies.feedback, same(feedback));
      expect(dependencies.feedback.blockedTitles, contains('keepblocked'));
      dependencies.release();
    },
  );

  test(
    'independent failure paging duplicate guard and cross-row feedback',
    () async {
      final feedback = RecommendationFeedbackStore();
      final gate = Completer<RecommendationPage>();
      var calls = 0;
      final state = DetailRecommendationState(
        feedback: feedback,
        loaders: {
          RecommendationRow.related: (request) async {
            calls++;
            if (request.offset > 0) return gate.future;
            return RecommendationPage(
              items: [entry(2), entry(2)],
              nextOffset: 12,
              hasMore: true,
            );
          },
          RecommendationRow.tmdb: (request) async =>
              throw StateError('network'),
          RecommendationRow.douban: (request) async =>
              RecommendationPage(items: [entry(3, 'item2')]),
        },
      );
      await state.refresh(current: seed);
      expect(state.row(RecommendationRow.related).items, hasLength(1));
      expect(state.row(RecommendationRow.tmdb).error, isNotNull);
      expect(state.row(RecommendationRow.douban).items, hasLength(1));
      final pending = state.loadMore(RecommendationRow.related);
      await state.loadMore(RecommendationRow.related);
      expect(calls, 2);
      feedback.block('item2');
      expect(state.row(RecommendationRow.related).items, isEmpty);
      expect(state.row(RecommendationRow.douban).items, isEmpty);
      gate.complete(
        RecommendationPage(items: [entry(2), entry(4)], nextOffset: 24),
      );
      await pending;
      expect(
        state.row(RecommendationRow.related).items.map((e) => e.item.title),
        ['item4'],
      );
      state.dispose();
      feedback.dispose();
    },
  );
  test(
    'history fingerprint refresh stale generation and dispose safe',
    () async {
      final old = Completer<RecommendationPage>();
      var calls = 0;
      final state = DetailRecommendationState(
        feedback: RecommendationFeedbackStore(),
        loaders: {
          RecommendationRow.related: (request) async {
            calls++;
            if (calls == 1) return old.future;
            return RecommendationPage(items: [entry(3)]);
          },
        },
      );
      final pending = state.refresh(current: seed);
      await state.refresh(
        current: seed,
        history: const [RecommendationSeed(title: 'watched')],
      );
      old.complete(RecommendationPage(items: [entry(2)]));
      await pending;
      expect(state.row(RecommendationRow.related).items.single.item.tmdbId, 3);
      await state.refresh(
        current: seed,
        history: const [RecommendationSeed(title: 'watched')],
      );
      expect(calls, 2);
      state.dispose();
      await state.loadMore(RecommendationRow.related);
    },
  );
  test(
    'sourceOnly skips personal network but passes embedded detail to related',
    () async {
      var calls = 0;
      final state = DetailRecommendationState(
        feedback: RecommendationFeedbackStore(),
        loaders: {
          for (final row in RecommendationRow.values)
            row: (request) async {
              calls++;
              expect(request.sourceOnly, true);
              expect(request.pageSize, 12);
              return const RecommendationPage();
            },
        },
      );
      await state.refresh(
        current: seed,
        sourceOnly: true,
        detail: const {'recommendations': []},
      );
      expect(calls, 1);
      state.dispose();
    },
  );

  test('late in-flight completion after dispose never notifies', () async {
    final gate = Completer<RecommendationPage>();
    final state = DetailRecommendationState(
      feedback: RecommendationFeedbackStore(),
      loaders: {RecommendationRow.related: (r) => gate.future},
    );
    final pending = state.refresh(current: seed);
    var lateNotifications = 0;
    state.addListener(() => lateNotifications++);
    state.dispose();
    gate.complete(RecommendationPage(items: [entry(2)]));
    await pending;
    expect(lateNotifications, 0);
  });

  test(
    'embedded mode refresh changes only related sourceOnly routing',
    () async {
      final requests = <RecommendationRow, List<bool>>{
        for (final row in RecommendationRow.values) row: [],
      };
      final state = DetailRecommendationState(
        feedback: RecommendationFeedbackStore(),
        loaders: {
          for (final row in RecommendationRow.values)
            row: (r) async {
              requests[row]!.add(r.sourceOnly);
              return RecommendationPage(items: [entry(2)]);
            },
        },
      );
      await state.refresh(current: seed);
      await state.refresh(current: seed, embeddedRelated: true);
      expect(requests[RecommendationRow.related], [false, true]);
      expect(requests[RecommendationRow.tmdb], [false, false]);
      expect(requests[RecommendationRow.douban], [false, false]);
      state.dispose();
    },
  );
}
