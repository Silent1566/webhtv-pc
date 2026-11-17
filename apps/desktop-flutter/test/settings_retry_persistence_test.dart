import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';

void main() {
  for (final kind in ['danmaku', 'proxy', 'doh', 'following', 'subtitles']) {
    test(
      '$kind equivalent retry reports real persistence and saves after recovery',
      () async {
        final temp = Directory.systemTemp.createTempSync('settings-retry-');
        final path = '${temp.path}/settings.json';
        final blocked = Directory(path)..createSync();
        final store = UiPreferencesStore(path: path);
        addTearDown(() => temp.deleteSync(recursive: true));
        final value = kind == 'proxy'
            ? 'http://127.0.0.1:7890'
            : 'https://example.test/retry';
        Future<bool> remember(UiPreferencesStore target) => switch (kind) {
          'danmaku' => target.rememberDanmakuSettings(
            target.danmakuSettings.copyWith(apiUrl: value),
          ),
          'proxy' => target.rememberOutboundProxy(
            target.outboundProxy.copyWith(defaultProxyUrl: value),
          ),
          'following' => target.rememberFollowingSettings(
            target.followingSettings.copyWith(intervalMinutes: 60),
          ),
          'subtitles' => target.rememberSubtitleSettings(
            target.subtitleSettings.copyWith(httpEndpoint: value),
          ),
          _ => target.rememberDohSettings(
            target.dohSettings.copyWith(url: value),
          ),
        };
        expect(await remember(store), isFalse);
        expect(await remember(store), isFalse);
        expect(blocked.absolute.path, File(path).absolute.path);
        expect(blocked.absolute.path, startsWith('${temp.absolute.path}/'));
        blocked.deleteSync();
        expect(await remember(store), isTrue);
        expect(File(path).existsSync(), isTrue);
        final reloaded = UiPreferencesStore(path: path);
        await reloaded.load();
        final restored = switch (kind) {
          'danmaku' => reloaded.danmakuSettings.apiUrl,
          'proxy' => reloaded.outboundProxy.defaultProxyUrl,
          'following' => reloaded.followingSettings.intervalMinutes,
          'subtitles' => reloaded.subtitleSettings.httpEndpoint,
          _ => reloaded.dohSettings.url,
        };
        expect(restored, kind == 'following' ? 60 : value);
      },
    );
  }
}
