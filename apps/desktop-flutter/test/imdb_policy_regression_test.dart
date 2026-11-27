import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/detail_ratings.dart';
import 'package:webhtv_pc/services/detail_rating_service.dart';
import 'package:webhtv_pc/services/imdb_rating_service.dart';
import 'package:webhtv_pc/services/omdb_service.dart';

const _request = DetailRatingRequest(title: 'Fixture', imdbId: 'tt34852924');
http.Response _rating() => http.Response(
  jsonEncode({
    'data': {
      'title': {
        'ratingsSummary': {'aggregateRating': 7.6, 'voteCount': 1234},
      },
    },
  }),
  200,
);

void main() {
  test(
    'OMDb-only cache separates enabled state even without a direct IMDb client',
    () async {
      var enabled = true;
      var requests = 0;
      final omdb = OmdbService(
        client: MockClient((_) async {
          requests++;
          return http.Response(
            jsonEncode({
              'Response': 'True',
              'imdbRating': '7.6',
              'imdbVotes': '1234',
              'Metascore': '82',
            }),
            200,
          );
        }),
      );
      final service = DetailRatingService(
        omdb: omdb,
        imdbEnabled: () => enabled,
      );
      addTearDown(service.close);
      addTearDown(omdb.close);
      expect((await service.fetch(_request, omdbApiKey: 'key')).imdb, '7.6');
      enabled = false;
      final off = await service.fetch(_request, omdbApiKey: 'key');
      expect(off.imdb, isEmpty);
      expect(off.imdbVotes, isEmpty);
      expect(off.metacritic, '82/100');
      enabled = true;
      expect((await service.fetch(_request, omdbApiKey: 'key')).imdb, '7.6');
      expect(requests, 2);
    },
  );

  test(
    'disabling during an in-flight IMDb request filters its late score',
    () async {
      var enabled = true;
      final gate = Completer<http.Response>();
      final started = Completer<void>();
      final imdb = ImdbRatingService(
        client: MockClient((_) {
          started.complete();
          return gate.future;
        }),
      );
      final service = DetailRatingService(
        imdb: imdb,
        imdbEnabled: () => enabled,
      );
      addTearDown(service.close);
      addTearDown(imdb.close);
      final pending = service.fetch(_request, omdbApiKey: '');
      await started.future;
      enabled = false;
      gate.complete(_rating());
      final off = await pending;
      expect(off.imdb, isEmpty);
      expect(off.imdbVotes, isEmpty);
      enabled = true;
      expect((await service.fetch(_request, omdbApiKey: '')).imdb, '7.6');
    },
  );
}
