import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';

void main() {
  test('Vod exposes parsed source identity without altering raw extra', () {
    final raw = <String, Object?>{
      'schema': 1,
      'id': 42,
      'media_type': 'movie',
      'detail': {'title': 'Source'},
    };
    final vod = Vod(vodId: 'site-1', vodName: 'Site', extra: {'tmdb': raw});
    final dynamic dynamicVod = vod;
    expect(dynamicVod.tmdb.identity.key, 'movie:42');
    expect(vod.toJson()['tmdb'], same(raw));
  });
}
