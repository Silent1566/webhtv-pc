import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/ai_integration.dart';

void main() {
  test(
    'confirmed AI bindings mark only bound files and preserve source identity',
    () {
      final first = VodEpisode(
        name: '文件甲',
        url: 'original-a',
        extra: {'custom': 'kept'},
      );
      final skipped = VodEpisode(name: '花絮', url: 'original-extra');
      final line = VodPlayLine(flag: '线路', episodes: [first, skipped]);
      final bound = applyAiEpisodeBindings(line, const {
        0: (season: 1, episode: 2),
      });
      expect(bound.episodes.first.extra['episode_identity_confirmed'], isTrue);
      expect(bound.episodes.first.extra['tmdb_season_number'], 1);
      expect(bound.episodes.first.extra['tmdb_episode_number'], 2);
      expect(bound.episodes.first.extra['custom'], 'kept');
      expect(bound.episodes.first.name, '文件甲');
      expect(bound.episodes.first.url, 'original-a');
      expect(bound.episodes.last, same(skipped));
      expect(bound.episodes.last.extra['episode_identity_confirmed'], isNull);
      expect(first.extra['episode_identity_confirmed'], isNull);
    },
  );
}
