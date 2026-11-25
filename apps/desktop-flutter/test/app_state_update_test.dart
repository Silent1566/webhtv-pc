/// AppState 的更新接线单测（ADR-0015）：结果投影、偏好落盘、自动检查闸门、
/// 下载与安装的状态机。网络与进程全部由 [_FakeUpdateService] 接管。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/app_update.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/app_update_service.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

AppRelease releaseOf(String tag) => AppRelease(
  tag: tag,
  title: tag,
  body: 'notes',
  pageUri: Uri.parse('https://example.test/$tag'),
  prerelease: false,
  draft: false,
  assets: [
    AppReleaseAsset(
      name: 'webhtv-pc-0.2.0-linux-x64.AppImage',
      size: 10,
      downloadUri: Uri.parse('https://download.test/app.AppImage'),
      sha256: 'a' * 64,
    ),
    AppReleaseAsset(
      name: 'webhtv-pc-0.2.0-windows-x64.zip',
      size: 10,
      downloadUri: Uri.parse('https://download.test/app.zip'),
      sha256: 'a' * 64,
    ),
  ],
  tagInfo: AppReleaseTag.tryParse(tag),
);

class _FakeUpdateService extends AppUpdateService {
  AppUpdateVerdict verdict = AppUpdateVerdict.upToDate;
  AppRelease? release;
  String? failure;
  AppUpdateException? downloadFailure;
  int checks = 0;
  int downloads = 0;
  int installs = 0;
  AppUpdateChannel? lastChannel;
  Completer<void>? pendingCheck;

  @override
  Future<AppUpdateCheck> check({
    required AppUpdateIdentity identity,
    required AppUpdateChannel channel,
  }) async {
    checks++;
    lastChannel = channel;
    await pendingCheck?.future;
    return AppUpdateCheck(
      verdict: verdict,
      identity: identity,
      // 用相对当前时间的结果：写死日期会让「24 小时内不再查」在几天后自然过期。
      checkedAt: DateTime.now().toUtc(),
      release: release,
      message: failure,
    );
  }

  @override
  Future<AppUpdateDownload> download(
    AppRelease release,
    AppReleaseAsset asset, {
    required Directory destination,
    void Function(int received, int? total)? onProgress,
  }) async {
    downloads++;
    if (downloadFailure != null) throw downloadFailure!;
    onProgress?.call(5, 10);
    final file = File(p.join(destination.path, asset.name))
      ..createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]);
    return AppUpdateDownload(
      release: release,
      asset: asset,
      file: file,
      sha256: 'a' * 64,
      size: 3,
    );
  }

  @override
  Future<AppUpdateInstallResult> install(
    AppUpdateDownload download, {
    required AppUpdateInstallEnvironment environment,
  }) async {
    installs++;
    return const AppUpdateInstallResult(
      outcome: AppUpdateInstallOutcome.replacedAppImage,
      message: '已替换为 v0.2.0',
      targetPath: '/tmp/WebHTV-PC.AppImage',
    );
  }
}

void main() {
  late Directory temp;
  late AppState state;
  late _FakeUpdateService fake;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('webhtv-update-state-');
    fake = _FakeUpdateService();
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': p.join(temp.path, 'config'),
          'data': p.join(temp.path, 'data'),
          'cache': p.join(temp.path, 'cache'),
          'state': p.join(temp.path, 'logs'),
        },
      ),
      log: LogService(),
      externalPlayerDetector: () => const [],
      updateService: fake,
    );
    await state.bootstrap();
  });

  tearDown(() {
    state.dispose();
    temp.deleteSync(recursive: true);
  });

  Map<String, Object?> readSettings() =>
      jsonDecode(File(state.paths.settingsPath).readAsStringSync())
          as Map<String, Object?>;

  test(
    'production service uses live update proxy callback and metadata cache',
    () async {
      final requests = <Uri>[];
      final client = MockClient((request) async {
        requests.add(request.url);
        return request.url == appUpdateIndexUri
            ? http.Response('offline', 503)
            : http.Response(
                jsonEncode([
                  {'tag_name': 'v0.2.0-202611231630', 'assets': []},
                ]),
                200,
              );
      });
      await http.runWithClient(() async {
        final production = AppState(
          paths: AppPaths.resolve(
            overrides: {
              'config': p.join(temp.path, 'production-config'),
              'data': p.join(temp.path, 'production-data'),
              'cache': p.join(temp.path, 'production-cache'),
              'state': p.join(temp.path, 'production-logs'),
            },
          ),
          log: LogService(),
          externalPlayerDetector: () => const [],
        );
        try {
          await production.bootstrap();
          requests.clear();
          const custom = AppUpdateProxySettings(
            baseUrl: 'https://custom.example/prefix/',
          );
          expect(await production.setUpdateGithubProxy(custom), isTrue);
          expect((await production.checkForUpdates()).failed, isFalse);
          expect(requests, [
            appUpdateIndexUri,
            custom.routesFor(appUpdateIndexUri).first,
          ]);
          final metadata = Directory(
            p.join(production.paths.cacheDir, 'updates', 'metadata'),
          );
          expect(metadata.existsSync(), isTrue);
          expect(metadata.listSync(), isNotEmpty);
          requests.clear();
          const alternative = AppUpdateProxySettings(
            baseUrl: 'https://ghfast.top/',
          );
          expect(await production.setUpdateGithubProxy(alternative), isTrue);
          await production.checkForUpdates();
          expect(requests, [
            appUpdateIndexUri,
            alternative.routesFor(appUpdateIndexUri).first,
          ]);
        } finally {
          production.dispose();
        }
      }, () => client);
    },
  );

  test(
    'GitHub proxy validates and persists without changing other settings',
    () async {
      final root = readSettings()..['unrelated'] = {'keep': true};
      File(state.paths.settingsPath).writeAsStringSync(jsonEncode(root));
      expect(
        await state.setUpdateGithubProxy(
          const AppUpdateProxySettings(
            baseUrl: 'https://mirror.example/prefix',
          ),
        ),
        isTrue,
      );
      expect(
        state.updatePreferences.githubProxy.baseUrl,
        'https://mirror.example/prefix/',
      );
      expect(readSettings()['unrelated'], {'keep': true});
      final update = readSettings()['update'] as Map;
      expect(update['githubProxy'], {
        'enabled': true,
        'baseUrl': 'https://mirror.example/prefix/',
      });
      expect(
        await state.setUpdateGithubProxy(
          const AppUpdateProxySettings(
            enabled: false,
            baseUrl: 'https://mirror.example/prefix/',
          ),
        ),
        isTrue,
      );
      expect(state.updatePreferences.githubProxy.enabled, isFalse);
      expect(
        await state.setUpdateGithubProxy(
          const AppUpdateProxySettings(baseUrl: 'http://unsafe.example'),
        ),
        isFalse,
      );
      expect(state.updatePreferences.githubProxy.enabled, isFalse);
      expect(fake.checks, 0);
    },
  );

  test(
    'GitHub proxy disk failure does not pretend settings were saved',
    () async {
      final previous = state.updatePreferences;
      final settings = File(state.paths.settingsPath);
      expect(settings.path.startsWith(temp.path), isTrue);
      if (settings.existsSync()) settings.deleteSync();
      Directory(settings.path).createSync();
      expect(
        await state.setUpdateGithubProxy(
          const AppUpdateProxySettings(enabled: false),
        ),
        isFalse,
      );
      expect(state.updatePreferences, previous);
    },
  );

  test(
    'busy check refuses channel and proxy changes until its verdict lands',
    () async {
      fake.pendingCheck = Completer<void>();
      fake.verdict = AppUpdateVerdict.updateAvailable;
      fake.release = releaseOf('v0.2.0-202611231630');
      final pending = state.checkForUpdates();
      await state.setUpdateChannel(AppUpdateChannel.beta);
      final saved = await state.setUpdateGithubProxy(
        const AppUpdateProxySettings(enabled: false),
      );
      fake.pendingCheck!.complete();
      await pending;
      expect(saved, isFalse);
      expect(state.updatePreferences.channel, AppUpdateChannel.stable);
      expect(state.updatePreferences.githubProxy.enabled, isTrue);
      expect(state.updateCheck?.release?.tag, 'v0.2.0-202611231630');
      await state.setUpdateChannel(AppUpdateChannel.beta);
      expect(state.updateCheck, isNull);
      expect(state.updateNotice, isNull);
    },
  );

  test(
    'a new release identity invalidates previously downloaded package',
    () async {
      fake.verdict = AppUpdateVerdict.updateAvailable;
      fake.release = releaseOf('v0.2.0-202611231630');
      await state.checkForUpdates();
      await state.downloadUpdate();
      expect(state.updateDownload, isNotNull);
      fake.release = releaseOf('v0.3.0-202611241630');
      await state.checkForUpdates();
      expect(state.updateDownload, isNull);
      await state.downloadAndInstallUpdate();
      expect(fake.downloads, 2);
      expect(state.updateDownload?.release.tag, 'v0.3.0-202611241630');
    },
  );

  test(
    'failed cached release cannot download or reuse an old package',
    () async {
      fake.verdict = AppUpdateVerdict.updateAvailable;
      fake.release = releaseOf('v0.2.0-202611231630');
      await state.checkForUpdates();
      await state.downloadUpdate();
      fake.verdict = AppUpdateVerdict.failed;
      fake.failure = '离线，仅供参考';
      await state.checkForUpdates();
      expect(await state.downloadAndInstallUpdate(), isNull);
      expect(fake.installs, 0);
      expect(fake.downloads, 1);
    },
  );

  test('bootstrap 读到默认偏好：不自动检查、稳定版、没有检查结果', () {
    expect(state.updatePreferences.autoCheck, isFalse);
    expect(state.updatePreferences.channel, AppUpdateChannel.stable);
    expect(state.updateCheck, isNull);
    expect(state.appUpdateIdentity.isReleaseBuild, isFalse);
  });

  test('手动检查：结果进状态、发一次性提示、上次检查时间落盘', () async {
    fake.verdict = AppUpdateVerdict.updateAvailable;
    fake.release = releaseOf('v0.2.0-202611231630');
    final check = await state.checkForUpdates();
    expect(check.hasUpdate, isTrue);
    expect(state.updateCheck?.release?.tag, 'v0.2.0-202611231630');
    expect(state.updateNotice, 'v0.2.0-202611231630');
    expect(fake.lastChannel, AppUpdateChannel.stable);
    final update = readSettings()['update'] as Map<String, Object?>;
    expect(update['lastCheckedAt'], isNotNull);
    expect(update['lastCheckError'], isNull);

    state.clearUpdateNotice();
    expect(state.updateNotice, isNull);
  });

  test('重复点击只发一次请求', () async {
    final first = state.checkForUpdates();
    final second = state.checkForUpdates();
    expect(identical(first, second), isTrue);
    await first;
    expect(fake.checks, 1);
  });

  test('自动检查：关闭时一个请求都不发，打开立即查一次，24 小时内不再查', () async {
    await state.maybeAutoCheckForUpdates();
    expect(fake.checks, 0);

    await state.setUpdateAutoCheck(true);
    await state.checkForUpdates();
    expect(fake.checks, 1);
    expect(state.updatePreferences.autoCheck, isTrue);

    await state.maybeAutoCheckForUpdates();
    expect(fake.checks, 1, reason: '刚查过，24 小时闸门应拦住');
  });

  test('检查失败写进偏好与状态，不再当成「已是最新」', () async {
    fake.verdict = AppUpdateVerdict.failed;
    fake.failure = '被限流（HTTP 403）';
    final check = await state.checkForUpdates();
    expect(check.failed, isTrue);
    expect(state.updateCheck?.message, contains('限流'));
    expect(state.updateNotice, isNull);
    final update = readSettings()['update'] as Map<String, Object?>;
    expect(update['lastCheckError'], contains('限流'));
  });

  test('切换通道清掉上次结果并落盘', () async {
    fake.verdict = AppUpdateVerdict.updateAvailable;
    fake.release = releaseOf('v0.2.0-202611231630');
    await state.checkForUpdates();
    expect(state.updateCheck, isNotNull);

    await state.setUpdateChannel(AppUpdateChannel.beta);
    expect(state.updatePreferences.channel, AppUpdateChannel.beta);
    expect(state.updateCheck, isNull);
    final update = readSettings()['update'] as Map<String, Object?>;
    expect(update['channel'], 'beta');
  });

  test('下载并安装：进度、结果与状态机都可见', () async {
    fake.verdict = AppUpdateVerdict.updateAvailable;
    fake.release = releaseOf('v0.2.0-202611231630');
    await state.checkForUpdates();

    final result = await state.downloadAndInstallUpdate();
    expect(fake.downloads, 1);
    expect(fake.installs, 1);
    expect(result?.outcome, AppUpdateInstallOutcome.replacedAppImage);
    expect(state.updateInstallResult?.message, contains('已替换'));
    expect(state.updateDownloading, isFalse);
    expect(state.updateInstalling, isFalse);
    expect(state.updateDownload?.size, 3);
  });

  test('下载失败：原因进状态，不留下安装结果', () async {
    fake.verdict = AppUpdateVerdict.updateAvailable;
    fake.release = releaseOf('v0.2.0-202611231630');
    fake.downloadFailure = const AppUpdateException('没有校验值');
    await state.checkForUpdates();

    final result = await state.downloadAndInstallUpdate();
    expect(result, isNull);
    expect(state.updateDownload, isNull);
    expect(state.updateDownloadError, '没有校验值');
  });
}
