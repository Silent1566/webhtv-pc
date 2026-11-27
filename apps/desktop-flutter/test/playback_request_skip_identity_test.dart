import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/playback_request.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/tmdb_playback.dart';

void main() {
  const identity = TmdbPlaybackIdentity(
    tmdbId: 1,
    mediaType: TmdbMediaType.tv,
    seasonNumber: 1,
    episodeNumber: 3,
  );
  const request = PlaybackRequest(
    url: 'https://fixture.test/A.mp4',
    title: 'fixture',
    siteKey: 'fixture',
    vodId: 'A',
    vodName: 'fixture',
    episodeName: 'E3',
    flag: 'line',
    tmdb: identity,
  );

  test('copyWith omission still clears identity for callers choosing a new episode', () {
    expect(request.copyWith(episodeName: 'unmatched').tmdb, isNull);
  });

  test(
    'same-media playhead copy preserves identity only when explicitly passed',
    () {
      final copied = request.copyWith(
        tmdb: request.tmdb,
        startPosition: const Duration(seconds: 750),
        clearResumeSeed: true,
      );
      expect(copied.tmdb, same(identity));
      expect(copied.startPosition, const Duration(seconds: 750));
    },
  );

  test(
    'explicit null remains a valid identity clear on episode replacement',
    () {
      expect(request.copyWith(tmdb: null, episodeName: 'unknown').tmdb, isNull);
    },
  );
}
