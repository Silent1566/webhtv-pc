/// 更新子系统的事实层单测（ADR-0015）。
///
/// 这里锁的是「什么算更新」与「该装哪个文件」：这两条判据一旦漂移，用户会被
/// 引到错误的方向（把旧包当新包、或永远看不到新版本），而界面测试看不出来。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_update.dart';

AppRelease releaseOf(
  String tag, {
  bool prerelease = false,
  bool draft = false,
  List<AppReleaseAsset> assets = const [],
  DateTime? publishedAt,
}) => AppRelease(
  tag: tag,
  title: tag,
  body: 'notes',
  pageUri: Uri.parse('https://example.test/$tag'),
  publishedAt: publishedAt,
  prerelease: prerelease,
  draft: draft,
  assets: assets,
  tagInfo: AppReleaseTag.tryParse(tag),
);

AppReleaseAsset assetOf(String name, {String? sha256, int size = 1024}) =>
    AppReleaseAsset(
      name: name,
      size: size,
      downloadUri: Uri.parse('https://download.test/$name'),
      sha256: sha256,
    );

void main() {
  group('发布 tag', () {
    test('稳定版与测试版都解析出版本名、通道与构建时间戳', () {
      final stable = AppReleaseTag.tryParse('v0.2.0-202611231630')!;
      expect(stable.versionName, '0.2.0');
      expect(stable.channel, AppUpdateChannel.stable);
      expect(stable.builtAt, DateTime.utc(2026, 11, 23, 16, 30));

      final beta = AppReleaseTag.tryParse('v0.2.0-beta-202611231630')!;
      expect(beta.versionName, '0.2.0');
      expect(beta.channel, AppUpdateChannel.beta);
    });

    test('不是流水线形态的 tag 一律解析失败', () {
      for (final raw in [
        '',
        'latest',
        'v1.0',
        'v1.0.0',
        'v1.0.0-beta',
        'v1.0.0-beta-2026',
        '1.0.0-202613231630',
      ]) {
        expect(AppReleaseTag.tryParse(raw), isNull, reason: raw);
      }
    });

    test('版本名（三段数字）比较', () {
      expect(compareAppVersionNames('0.1.0', '0.1.0'), 0);
      expect(compareAppVersionNames('0.10.0', '0.9.9'), greaterThan(0));
      expect(compareAppVersionNames('1.0.0', '0.99.99'), greaterThan(0));
      expect(compareAppVersionNames('', '0.0.1'), lessThan(0));
      expect(compareAppVersionNames('0.1', '0.1.0'), 0);
    });
  });

  group('是否更新', () {
    const current = AppUpdateIdentity(
      version: '0.1.0',
      tag: 'v0.1.0-202611231630',
    );

    test('版本名更大即更新', () {
      expect(releaseOf('v0.2.0-202611010000').isNewerThan(current), isTrue);
    });

    test('同名版本按构建时间戳比较：更晚才算更新', () {
      expect(releaseOf('v0.1.0-202611240900').isNewerThan(current), isTrue);
      expect(
        releaseOf('v0.1.0-202611231630').isNewerThan(current),
        isFalse,
        reason: '同一个 tag 就是自己',
      );
      expect(releaseOf('v0.1.0-202611010000').isNewerThan(current), isFalse);
    });

    test('版本名更旧的发布永远不算更新', () {
      expect(
        releaseOf('v0.0.9-202612310000').isNewerThan(current),
        isFalse,
        reason: '时间戳再新也不能盖过版本名',
      );
    });

    test('开发构建与草稿都不算自动更新', () {
      expect(
        releaseOf('v0.2.0-202611010000')
            .isNewerThan(const AppUpdateIdentity(version: '0.1.0')),
        isFalse,
      );
      expect(
        releaseOf('v0.2.0-202611010000', draft: true).isNewerThan(current),
        isFalse,
      );
    });

    test('开发构建没有 tag 时通道回落稳定版', () {
      const identity = AppUpdateIdentity(version: '0.1.0');
      expect(identity.isReleaseBuild, isFalse);
      expect(identity.channel, AppUpdateChannel.stable);
    });
  });

  group('资产选择', () {
    final assets = [
      assetOf('webhtv-pc-0.2.0-windows-x64.zip'),
      assetOf('webhtv-pc-0.2.0-linux-x64.AppImage'),
      assetOf('webhtv-pc-0.2.0-linux-x64.deb'),
      assetOf(appUpdateChecksumAssetName),
    ];
    final release = releaseOf('v0.2.0-202611231630', assets: assets);

    test('Windows 选便携 zip', () {
      expect(
        release.preferredAsset(operatingSystem: 'windows')?.name,
        'webhtv-pc-0.2.0-windows-x64.zip',
      );
    });

    test('Linux 在 AppImage 运行形态下选 AppImage', () {
      expect(
        release
            .preferredAsset(operatingSystem: 'linux', runningAsAppImage: true)
            ?.name,
        'webhtv-pc-0.2.0-linux-x64.AppImage',
      );
    });

    test('Linux 不是 AppImage 运行形态时优先 deb', () {
      expect(
        release.preferredAsset(operatingSystem: 'linux')?.name,
        'webhtv-pc-0.2.0-linux-x64.deb',
      );
    });

    test('Linux 找不到 AppImage 时退回 deb', () {
      final debOnly = releaseOf(
        'v0.2.0-202611231630',
        assets: [assetOf('webhtv-pc-0.2.0-linux-x64.deb')],
      );
      expect(
        debOnly.preferredAsset(operatingSystem: 'linux')?.name,
        'webhtv-pc-0.2.0-linux-x64.deb',
      );
    });

    test('没有产物时返回 null，不猜一个文件', () {
      final empty = releaseOf('v0.2.0-202611231630');
      expect(empty.preferredAsset(operatingSystem: 'windows'), isNull);
      expect(empty.preferredAsset(operatingSystem: 'macos'), isNull);
      expect(empty.checksumAsset, isNull);
    });
  });

  group('校验文件', () {
    const sha =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

    test('解析 CRLF 与星号前缀，摘要统一小写', () {
      final text =
          '$sha  webhtv-pc-0.2.0-windows-x64.zip\r\n'
          'ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789 *webhtv-pc-0.2.0-linux-x64.AppImage\r\n';
      final parsed = parseSha256Sums(text);
      expect(parsed['webhtv-pc-0.2.0-windows-x64.zip'], sha);
      expect(
        parsed['webhtv-pc-0.2.0-linux-x64.AppImage'],
        'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
        reason: '摘要大小写不该影响比对',
      );
    });

    test('坏行与注释被跳过，不编造值', () {
      final parsed = parseSha256Sums(
        '# comment\nnot-a-hash  file.zip\n$sha\n\n',
      );
      expect(parsed, isEmpty);
    });
  });

  group('偏好', () {
    test('JSON 往返保留开关、通道、时间与失败原因', () {
      final original = AppUpdatePreferences(
        autoCheck: true,
        channel: AppUpdateChannel.beta,
        lastCheckedAt: DateTime.utc(2026, 11, 23, 16, 30),
        lastCheckError: 'HTTP 403',
      );
      final restored = AppUpdatePreferences.fromJson(original.toJson());
      expect(restored, original);
    });

    test('未知通道与坏时间回落默认值', () {
      final restored = AppUpdatePreferences.fromJson({
        'autoCheck': 'yes',
        'channel': 'nightly',
        'lastCheckedAt': 'not-a-date',
      });
      expect(restored.autoCheck, isFalse);
      expect(restored.channel, AppUpdateChannel.stable);
      expect(restored.lastCheckedAt, isNull);
      expect(restored.lastCheckError, isNull);
    });

    test('24 小时闸门：关着不查、到期才查', () {
      final now = DateTime.utc(2026, 11, 23, 16, 30);
      expect(
        const AppUpdatePreferences().shouldAutoCheck(now),
        isFalse,
        reason: '默认关闭',
      );
      expect(
        const AppUpdatePreferences(autoCheck: true).shouldAutoCheck(now),
        isTrue,
        reason: '从没查过',
      );
      expect(
        AppUpdatePreferences(
          autoCheck: true,
          lastCheckedAt: now.subtract(const Duration(hours: 23)),
        ).shouldAutoCheck(now),
        isFalse,
      );
      expect(
        AppUpdatePreferences(
          autoCheck: true,
          lastCheckedAt: now.subtract(const Duration(hours: 25)),
        ).shouldAutoCheck(now),
        isTrue,
      );
    });

    test('copyWith 能清空可空字段', () {
      final value = AppUpdatePreferences(
        autoCheck: true,
        lastCheckedAt: DateTime.utc(2026, 11, 23),
        lastCheckError: 'boom',
      );
      final cleared = value.copyWith(lastCheckedAt: null, lastCheckError: null);
      expect(cleared.lastCheckedAt, isNull);
      expect(cleared.lastCheckError, isNull);
      expect(cleared.autoCheck, isTrue);
    });
  });
}
