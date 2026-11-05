import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/tmdb_detail_model.dart';
import 'package:webhtv_pc/core/tmdb_media.dart';

void main() {
  group('TmdbEpisodeCards 用原始线路下标推断缺号集', () {
    test('倒序且集名无集号：集号取原始线路位置（3,2,1）', () {
      final cards = TmdbEpisodeCards.build(
        sourceNames: const ['下', '中', '上'],
        metadataByNumber: const <int, TmdbEpisode>{},
        sourceIndices: const [2, 1, 0],
      );
      expect(cards.map((card) => card.number).toList(), [3, 2, 1]);
      expect(cards.map((card) => card.title).toList(), ['下', '中', '上']);
    });

    test('集名自带集号时仍以源集号为准，不受 sourceIndices 影响', () {
      final cards = TmdbEpisodeCards.build(
        sourceNames: const ['第9集', '下'],
        metadataByNumber: const <int, TmdbEpisode>{},
        sourceIndices: const [0, 2],
      );
      expect(cards[0].number, 9, reason: '源集号优先');
      expect(cards[1].number, 3, reason: '缺号集回退原始线路位置 2 + 1');
    });
  });
}
