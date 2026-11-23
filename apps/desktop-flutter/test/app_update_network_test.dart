import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_update.dart';

void main() {
  final releaseUri = Uri.parse(
    'https://github.com/Silent1566/webhtv-pc/releases/download/v0.2.0-202611231630/webhtv-pc-0.2.0-windows-x64.zip',
  );

  test(
    'proxy retries retain the original public asset and direct fallback',
    () {
      const settings = AppUpdateProxySettings();
      expect(settings.routesFor(releaseUri).map((u) => u.toString()).toList(), [
        'https://gh-proxy.com/https://github.com/Silent1566/webhtv-pc/releases/download/v0.2.0-202611231630/webhtv-pc-0.2.0-windows-x64.zip',
        releaseUri.toString(),
      ]);
      expect(
        settings.routesFor(releaseUri, proxyFirst: false).first,
        releaseUri,
      );
    },
  );

  test(
    'disabled proxy and non-project or credential URLs never get rewritten',
    () {
      expect(
        const AppUpdateProxySettings(enabled: false).routesFor(releaseUri),
        [releaseUri],
      );
      for (final url in [
        'https://api.github.com/repos/Silent1566/webhtv-pc/releases',
        'https://github.com/other/repo/releases/download/v1/asset.zip',
        'https://example.test/asset.zip',
        'https://gh-proxy.com/https://github.com/Silent1566/webhtv-pc/releases/download/v1/a.zip',
        'http://github.com/Silent1566/webhtv-pc/releases/download/v1/a.zip',
        'https://token@github.com/Silent1566/webhtv-pc/releases/download/v1/a.zip',
        'https://github.com/Silent1566/webhtv-pc/releases/download/v1/a.zip?token=secret',
      ]) {
        final uri = Uri.parse(url);
        expect(const AppUpdateProxySettings().routesFor(uri), [
          uri,
        ], reason: url);
      }
    },
  );

  test(
    'proxy URL validation rejects credentials, queries and insecure bases',
    () {
      for (final input in [
        '',
        'http://proxy.example/',
        'https://user:secret@proxy.example/',
        'https://proxy.example/?token=secret',
        'https://proxy.example/#anchor',
        'https://proxy.example:99999/',
        'https://proxy.example/a b/',
        'https://proxy.example/../',
      ]) {
        expect(
          AppUpdateProxySettings.normalizeBaseUrl(input),
          isNull,
          reason: input,
        );
      }
      expect(
        AppUpdateProxySettings.normalizeBaseUrl(
          ' https://proxy.example/cache ',
        ),
        'https://proxy.example/cache/',
      );
    },
  );

  test(
    'check cache metadata never turns failed check into installable update',
    () {
      final result = AppUpdateCheck(
        verdict: AppUpdateVerdict.failed,
        identity: const AppUpdateIdentity(version: '0.1.0'),
        checkedAt: DateTime.utc(2026, 11, 23),
        fromCache: true,
        cachedAt: DateTime.utc(2026, 11, 22),
        retryAt: DateTime.utc(2026, 11, 23, 1),
        source: '缓存',
      );
      expect(result.hasUpdate, isFalse);
      expect(result.failed, isTrue);
      expect(result.fromCache, isTrue);
    },
  );

  test(
    'legacy preferences gain proxy defaults without enabling auto checks',
    () {
      final settings = AppUpdatePreferences.fromJson({'channel': 'beta'});
      expect(settings.autoCheck, isFalse);
      expect(settings.channel, AppUpdateChannel.beta);
      expect(settings.toJson()['githubProxy'], {
        'enabled': true,
        'baseUrl': 'https://gh-proxy.com/',
      });
    },
  );

  test(
    'disabled custom proxy survives JSON round trip and unrelated changes',
    () {
      final settings = AppUpdatePreferences.fromJson({
        'autoCheck': false,
        'githubProxy': {
          'enabled': false,
          'baseUrl': 'https://cache.example/path',
        },
      });
      expect(settings.copyWith(autoCheck: true).toJson()['githubProxy'], {
        'enabled': false,
        'baseUrl': 'https://cache.example/path/',
      });
    },
  );

  test('unsafe proxy config cannot silently route downloads', () {
    final settings = AppUpdatePreferences.fromJson({
      'githubProxy': {
        'enabled': true,
        'baseUrl': 'https://user:secret@example.test/',
      },
    });
    final json = settings.toJson()['githubProxy'] as Map?;
    expect(json?['enabled'], isFalse);
  });
}
