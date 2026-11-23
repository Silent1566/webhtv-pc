/// 更新服务单测（ADR-0015）：通道筛选、失败降级、下载校验与三种安装结局。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/app_update.dart';
import 'package:webhtv_pc/services/app_update_service.dart';

Map<String, Object?> assetJson(String name, {String? digest}) => {
  'name': name,
  'size': 12,
  'browser_download_url': 'https://downloads.test/$name',
  'digest': ?digest,
};

Map<String, Object?> releaseJson({
  required String tag,
  bool prerelease = false,
  bool draft = false,
  List<Map<String, Object?>> assets = const [],
}) => {
  'tag_name': tag,
  'name': tag,
  'body': 'release notes',
  'html_url': 'https://github.com/Silent1566/webhtv-pc/releases/tag/$tag',
  'published_at': '2026-11-23T08:30:00Z',
  'prerelease': prerelease,
  'draft': draft,
  'assets': assets,
};

AppRelease releaseOf(String tag, {List<AppReleaseAsset> assets = const []}) =>
    AppRelease(
      tag: tag,
      title: tag,
      body: '',
      pageUri: Uri.parse('https://example.test/$tag'),
      prerelease: AppUpdateChannel.fromTag(tag) == AppUpdateChannel.beta,
      draft: false,
      assets: assets,
      tagInfo: AppReleaseTag.tryParse(tag),
    );

void main() {
  final identity = AppUpdateIdentity(
    version: '0.1.0',
    tag: 'v0.1.0-202611231630',
  );

  test('稳定版通道过滤预发布与草稿，并挑出版本最新的一条', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/repos/Silent1566/webhtv-pc/releases');
      expect(request.headers['User-Agent'], isNotEmpty);
      return http.Response(
        jsonEncode([
          releaseJson(tag: 'v0.1.0-202611240900'),
          releaseJson(tag: 'v0.2.0-beta-202611231630', prerelease: true),
          releaseJson(tag: 'v0.3.0-202611231630', draft: true),
          releaseJson(tag: 'v0.2.0-202611231629'),
        ]),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final service = AppUpdateService(
      client: client,
      apiBaseUri: Uri.parse('https://api.test'),
      useStaticIndex: false,
      proxySettings: () => const AppUpdateProxySettings(enabled: false),
    );
    final check = await service.check(
      identity: identity,
      channel: AppUpdateChannel.stable,
    );
    expect(check.verdict, AppUpdateVerdict.updateAvailable);
    expect(check.release?.tag, 'v0.2.0-202611231629');
  });

  test('测试版通道允许预发布', () async {
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode([
          releaseJson(tag: 'v0.2.0-202611231629'),
          releaseJson(tag: 'v0.3.0-beta-202611231630', prerelease: true),
        ]),
        200,
      ),
    );
    final service = AppUpdateService(
      client: client,
      apiBaseUri: Uri.parse('https://api.test'),
      useStaticIndex: false,
      proxySettings: () => const AppUpdateProxySettings(enabled: false),
    );
    final check = await service.check(
      identity: identity,
      channel: AppUpdateChannel.beta,
    );
    expect(check.verdict, AppUpdateVerdict.updateAvailable);
    expect(check.release?.tag, 'v0.3.0-beta-202611231630');
  });

  test('开发构建给出 developmentBuild，但仍带最新发布供手动下载', () async {
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode([releaseJson(tag: 'v0.2.0-202611231629')]),
        200,
      ),
    );
    final service = AppUpdateService(
      client: client,
      apiBaseUri: Uri.parse('https://api.test'),
      useStaticIndex: false,
      proxySettings: () => const AppUpdateProxySettings(enabled: false),
    );
    final check = await service.check(
      identity: const AppUpdateIdentity(version: '0.1.0'),
      channel: AppUpdateChannel.stable,
    );
    expect(check.verdict, AppUpdateVerdict.developmentBuild);
    expect(check.release?.tag, 'v0.2.0-202611231629');
    expect(check.hasUpdate, isFalse);
  });

  test('已是最新时没有任何提示', () async {
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode([releaseJson(tag: 'v0.1.0-202611231630')]),
        200,
      ),
    );
    final service = AppUpdateService(
      client: client,
      apiBaseUri: Uri.parse('https://api.test'),
      useStaticIndex: false,
      proxySettings: () => const AppUpdateProxySettings(enabled: false),
    );
    final check = await service.check(
      identity: identity,
      channel: AppUpdateChannel.stable,
    );
    expect(check.verdict, AppUpdateVerdict.upToDate);
  });

  test('限流与坏响应都落成可读失败，而不是抛异常', () async {
    var service = AppUpdateService(
      client: MockClient((request) async => http.Response('rate limited', 403, headers: {'x-ratelimit-remaining': '0'})),
      apiBaseUri: Uri.parse('https://api.test'),
      useStaticIndex: false,
      proxySettings: () => const AppUpdateProxySettings(enabled: false),
    );
    var check = await service.check(
      identity: identity,
      channel: AppUpdateChannel.stable,
    );
    expect(check.verdict, AppUpdateVerdict.failed);
    expect(check.message, contains('限流'));

    service = AppUpdateService(
      client: MockClient((request) async => http.Response('not json', 200)),
      apiBaseUri: Uri.parse('https://api.test'),
      useStaticIndex: false,
      proxySettings: () => const AppUpdateProxySettings(enabled: false),
    );
    check = await service.check(
      identity: identity,
      channel: AppUpdateChannel.stable,
    );
    expect(check.verdict, AppUpdateVerdict.failed);
    expect(check.message, contains('JSON'));
  });

  test('下载按 SHA256SUMS 校验，命中后落到目标文件名', () async {
    final payload = utf8.encode('payload-bytes');
    final digest = sha256.convert(payload).toString();
    final asset = AppReleaseAsset(
      name: 'webhtv-pc-0.2.0-windows-x64.zip',
      size: payload.length,
      downloadUri: Uri.parse(
        'https://downloads.test/webhtv-pc-0.2.0-windows-x64.zip',
      ),
    );
    final client = MockClient((request) async {
      if (request.url.path.endsWith(appUpdateChecksumAssetName)) {
        final assetName = asset.name;
        final line = '$digest  $assetName\n';
        return http.Response(line, 200);
      }
      return http.Response.bytes(payload, 200);
    });
    final service = AppUpdateService(client: client);
    final temp = Directory.systemTemp.createTempSync('webhtv-update-dl-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final progress = <int>[];
    final download = await service.download(
      releaseOf(
        'v0.2.0-202611231630',
        assets: [
          asset,
          AppReleaseAsset(
            name: appUpdateChecksumAssetName,
            size: digest.length,
            downloadUri: Uri.parse(
              'https://downloads.test/$appUpdateChecksumAssetName',
            ),
          ),
        ],
      ),
      asset,
      destination: temp,
      onProgress: (received, total) => progress.add(received),
    );
    expect(download.sha256, digest);
    expect(download.file.readAsStringSync(), 'payload-bytes');
    expect(progress, isNotEmpty);
    expect(temp.listSync().map((entry) => p.basename(entry.path)).toList(), [
      asset.name,
    ], reason: '半成品 .part 必须被改名或删除，不能留在目录里');
  });

  test('摘要对不上就删掉文件并报错', () async {
    final payload = utf8.encode('payload-bytes');
    final asset = AppReleaseAsset(
      name: 'webhtv-pc-0.2.0-windows-x64.zip',
      size: payload.length,
      downloadUri: Uri.parse(
        'https://downloads.test/webhtv-pc-0.2.0-windows-x64.zip',
      ),
      sha256: 'f' * 64,
    );
    final service = AppUpdateService(
      client: MockClient((request) async => http.Response.bytes(payload, 200)),
    );
    final temp = Directory.systemTemp.createTempSync('webhtv-update-bad-');
    addTearDown(() => temp.deleteSync(recursive: true));
    await expectLater(
      service.download(
        releaseOf('v0.2.0-202611231630'),
        asset,
        destination: temp,
      ),
      throwsA(isA<AppUpdateException>()),
    );
    expect(temp.listSync(), isEmpty, reason: '校验失败的文件不能留在原地');
  });

  test('没有校验值的发布拒绝下载', () async {
    final asset = AppReleaseAsset(
      name: 'webhtv-pc-0.2.0-linux-x64.AppImage',
      size: 4,
      downloadUri: Uri.parse(
        'https://downloads.test/webhtv-pc-0.2.0-linux-x64.AppImage',
      ),
    );
    final service = AppUpdateService(
      client: MockClient((request) async => http.Response('nope', 200)),
    );
    final temp = Directory.systemTemp.createTempSync('webhtv-update-nosum-');
    addTearDown(() => temp.deleteSync(recursive: true));
    await expectLater(
      service.download(
        releaseOf('v0.2.0-202611231630'),
        asset,
        destination: temp,
      ),
      throwsA(isA<AppUpdateException>()),
    );
  });

  test('Linux AppImage：原地替换并保留 .old 回滚文件', () async {
    final work = Directory.systemTemp.createTempSync('webhtv-update-appimage-');
    addTearDown(() => work.deleteSync(recursive: true));
    final appImage = File(p.join(work.path, 'WebHTV-PC.AppImage'))
      ..writeAsStringSync('old-binary');
    final downloadFile = File(p.join(work.path, 'downloaded.AppImage'))
      ..writeAsStringSync('new-binary');
    final download = AppUpdateDownload(
      release: releaseOf('v0.2.0-202611231630'),
      asset: AppReleaseAsset(
        name: 'WebHTV-PC.AppImage',
        size: 10,
        downloadUri: Uri.parse('https://downloads.test/WebHTV-PC.AppImage'),
      ),
      file: downloadFile,
      sha256: 'a' * 64,
      size: 10,
    );
    final chmodCalls = <List<String>>[];
    final service = AppUpdateService(
      client: MockClient((request) async => http.Response('', 200)),
      processRunner: (executable, arguments) async {
        chmodCalls.add([executable, ...arguments]);
        return ProcessResult(0, 0, '', '');
      },
    );
    final result = await service.install(
      download,
      environment: AppUpdateInstallEnvironment(
        operatingSystem: 'linux',
        executablePath: appImage.path,
        updatesRoot: p.join(work.path, 'updates'),
        processId: 1,
        appImagePath: appImage.path,
      ),
    );
    expect(result.outcome, AppUpdateInstallOutcome.replacedAppImage);
    expect(result.ok, isTrue);
    expect(appImage.readAsStringSync(), 'new-binary');
    final backupBase = appImage.path;
    expect(
      File('$backupBase.old').readAsStringSync(),
      'old-binary',
      reason: '旧文件留着，新版启动失败还能换回来',
    );
    expect(chmodCalls.single.first, 'chmod');
    expect(chmodCalls.single, contains('755'));
  });

  test('Windows 便携包：写出换装脚本并启动它', () async {
    final work = Directory.systemTemp.createTempSync('webhtv-update-win-');
    addTearDown(() => work.deleteSync(recursive: true));
    final installRoot = Directory(
      p.join(work.path, 'WebHTV-PC-0.2.0-windows-x64'),
    )..createSync();
    final exe = p.join(installRoot.path, 'webhtv_pc.exe');
    final archive = File(p.join(work.path, 'update.zip'))
      ..writeAsBytesSync([1, 2, 3]);
    final download = AppUpdateDownload(
      release: releaseOf('v0.2.0-202611231630'),
      asset: AppReleaseAsset(
        name: 'webhtv-pc-0.2.0-windows-x64.zip',
        size: 3,
        downloadUri: Uri.parse(
          'https://downloads.test/webhtv-pc-0.2.0-windows-x64.zip',
        ),
      ),
      file: archive,
      sha256: 'b' * 64,
      size: 3,
    );
    final started = <(String, List<String>)>[];
    final service = AppUpdateService(
      client: MockClient((request) async => http.Response('', 200)),
      processStarter: (executable, arguments) async {
        started.add((executable, arguments));
      },
    );
    final result = await service.install(
      download,
      environment: AppUpdateInstallEnvironment(
        operatingSystem: 'windows',
        executablePath: exe,
        updatesRoot: p.join(work.path, 'updates'),
        processId: 4242,
      ),
    );
    expect(result.outcome, AppUpdateInstallOutcome.portableUpdatePrepared);
    expect(started.single.$1, 'powershell.exe');
    final scriptPath = result.scriptPath!;
    expect(File(scriptPath).existsSync(), isTrue);
    final script = File(scriptPath).readAsStringSync();
    expect(script, contains(r'$targetPid = 4242'));
    expect(script, contains('Rename-Item'));
    expect(script, contains('Move-Item'));
    expect(script, contains('Start-Process'));
    expect(script, contains(installRoot.path));
    expect(script, contains('webhtv_pc.exe'));
    expect(started.single.$2.last, scriptPath);
  });

  test('deb 等只能下载的形态：安装结论是 downloadedOnly', () async {
    final work = Directory.systemTemp.createTempSync('webhtv-update-manual-');
    addTearDown(() => work.deleteSync(recursive: true));
    final deb = File(p.join(work.path, 'webhtv-pc_0.2.0_amd64.deb'))
      ..writeAsBytesSync([1]);
    final download = AppUpdateDownload(
      release: releaseOf('v0.2.0-202611231630'),
      asset: AppReleaseAsset(
        name: 'webhtv-pc_0.2.0_amd64.deb',
        size: 1,
        downloadUri: Uri.parse('https://downloads.test/webhtv-pc.deb'),
      ),
      file: deb,
      sha256: 'c' * 64,
      size: 1,
    );
    final service = AppUpdateService(
      client: MockClient((request) async => http.Response('', 200)),
    );
    final result = await service.install(
      download,
      environment: AppUpdateInstallEnvironment(
        operatingSystem: 'linux',
        executablePath: '/opt/webhtv-pc/webhtv_pc',
        updatesRoot: p.join(work.path, 'updates'),
        processId: 7,
      ),
    );
    expect(result.outcome, AppUpdateInstallOutcome.downloadedOnly);
    expect(result.targetPath, deb.path);
    expect(result.needsRestart, isFalse);
  });
}
