/// 更新检查、下载与安装（ADR-0015）。
///
/// 三件事各归各层：
/// - 判据（哪个版本更新、该装哪个文件、校验文件怎么读）在 core/app_update.dart；
/// - 网络与磁盘动作在这里；
/// - 「什么时候检查、装完怎么提示」在 AppState 与更新页。
///
/// 硬边界：
/// - **没有校验值就不下载**：只信 Release 里发布的 SHA-256（API 的 digest 或
///   SHA256SUMS.txt）。TLS 之外没有签名通道，这条拒绝是唯一的防线；
/// - 安装永远由用户点击触发，从不静默替换正在运行的程序；
/// - 失败一律返回结构化结果或抛 [AppUpdateException]，不把半成品留在原地。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../core/app_update.dart';

/// 更新链路的失败（文案可直接给用户看）。
class AppUpdateException implements Exception {
  const AppUpdateException(this.message);

  final String message;

  @override
  String toString() => 'AppUpdateException: $message';
}

/// 已下载并通过 SHA-256 校验的更新包。
class AppUpdateDownload {
  const AppUpdateDownload({
    required this.release,
    required this.asset,
    required this.file,
    required this.sha256,
    required this.size,
  });

  final AppRelease release;
  final AppReleaseAsset asset;
  final File file;

  /// 实际算出的十六进制摘要（与期望值一致才会构造出这个对象）。
  final String sha256;

  final int size;
}

/// 安装的三种结局。
enum AppUpdateInstallOutcome {
  /// AppImage 已被原地替换；重启后生效。
  replacedAppImage,

  /// Windows 便携包：换装脚本已启动，退出应用后自动完成。
  portableUpdatePrepared,

  /// 只下载成功：安装交给系统安装器或用户手动处理。
  downloadedOnly,

  /// 失败（文件没动或已回滚）。
  failed,
}

/// 一次安装动作的结果。
class AppUpdateInstallResult {
  const AppUpdateInstallResult({
    required this.outcome,
    this.message,
    this.targetPath,
    this.scriptPath,
    this.logPath,
  });

  final AppUpdateInstallOutcome outcome;

  /// 面向用户的说明（成功与失败都写）。
  final String? message;

  /// 最终生效的路径：AppImage 自身 / 下载到的安装包。
  final String? targetPath;

  /// Windows 换装脚本路径（排障用）。
  final String? scriptPath;

  /// 换装日志路径（排障用）。
  final String? logPath;

  bool get ok => outcome != AppUpdateInstallOutcome.failed;

  bool get needsRestart => outcome == AppUpdateInstallOutcome.replacedAppImage;
}

/// 安装环境：把平台事实显式传进来，安装逻辑才可单测。
class AppUpdateInstallEnvironment {
  const AppUpdateInstallEnvironment({
    required this.operatingSystem,
    required this.executablePath,
    required this.updatesRoot,
    required this.processId,
    this.appImagePath,
  });

  /// dart:io 的 Platform.operatingSystem。
  final String operatingSystem;

  /// dart:io 的 Platform.resolvedExecutable。
  final String executablePath;

  /// 下载与暂存目录（cacheDir 下的 updates）。
  final String updatesRoot;

  /// dart:io 的 pid：Windows 换装脚本要等它退出。
  final int processId;

  /// AppImage 运行时由 APPIMAGE 环境变量给出；其它形态为 null。
  final String? appImagePath;

  /// 便携包所在的目录（Windows 换装要整目录替换它）。
  String get installRoot => File(executablePath).parent.path;

  /// 这次安装该走哪条路。
  AppUpdateInstallKind get installKind {
    if (operatingSystem == 'linux' && (appImagePath ?? '').isNotEmpty) {
      return AppUpdateInstallKind.replaceAppImage;
    }
    if (operatingSystem == 'windows') {
      return AppUpdateInstallKind.replacePortableWindows;
    }
    return AppUpdateInstallKind.manual;
  }
}

/// 启动外部进程的注入点（单测不真的起 PowerShell）。
typedef AppUpdateProcessStarter = Future<void> Function(
  String executable,
  List<String> arguments,
);

/// 运行 chmod 等工具的注入点。
typedef AppUpdateProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// GitHub Releases 客户端。
class AppUpdateService {
  AppUpdateService({
    http.Client? client,
    Uri? apiBaseUri,
    this.userAgent = appUpdateUserAgent,
    this.timeout = const Duration(seconds: 20),
    DateTime Function()? clock,
    AppUpdateProcessStarter? processStarter,
    AppUpdateProcessRunner? processRunner,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _apiBaseUri = apiBaseUri ?? Uri.parse(appUpdateApiBaseUrl),
       _clock = clock ?? DateTime.now,
       _startProcess =
           processStarter ??
           ((executable, arguments) async {
             await Process.start(
               executable,
               arguments,
               mode: ProcessStartMode.detached,
             );
           }),
       _runProcess =
           processRunner ??
           ((executable, arguments) => Process.run(executable, arguments));

  final String userAgent;
  final Duration timeout;

  final http.Client _client;
  final bool _ownsClient;
  final Uri _apiBaseUri;
  final DateTime Function() _clock;
  final AppUpdateProcessStarter _startProcess;
  final AppUpdateProcessRunner _runProcess;

  /// 发布页（手动下载的兜底入口）。
  Uri get releasePageUri =>
      Uri.parse('https://github.com/$appUpdateRepository/releases');

  Map<String, String> get _headers => {
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': userAgent,
  };

  /// 查一次发布通道。**永不抛异常**：失败落成 [AppUpdateVerdict.failed]。
  Future<AppUpdateCheck> check({
    required AppUpdateIdentity identity,
    required AppUpdateChannel channel,
  }) async {
    final checkedAt = _clock();
    AppUpdateCheck failure(String message) => AppUpdateCheck(
      verdict: AppUpdateVerdict.failed,
      identity: identity,
      checkedAt: checkedAt,
      message: message,
    );
    try {
      final uri = _apiBaseUri.replace(
        path: '/repos/$appUpdateRepository/releases',
        queryParameters: const {'per_page': '30'},
      );
      final response = await _client
          .get(uri, headers: _headers)
          .timeout(timeout);
      if (response.statusCode != 200) {
        return failure(_httpMessage('查询发布信息', response.statusCode));
      }
      final releases = _parseReleases(response.body);
      final newest = _newestRelease([
        for (final release in releases)
          if (_matchesChannel(release, channel)) release,
      ]);
      if (newest == null) {
        return AppUpdateCheck(
          verdict: AppUpdateVerdict.upToDate,
          identity: identity,
          checkedAt: checkedAt,
          message: '发布通道里还没有可见的版本',
        );
      }
      if (!identity.isReleaseBuild) {
        return AppUpdateCheck(
          verdict: AppUpdateVerdict.developmentBuild,
          identity: identity,
          checkedAt: checkedAt,
          release: newest,
        );
      }
      return AppUpdateCheck(
        verdict: newest.isNewerThan(identity)
            ? AppUpdateVerdict.updateAvailable
            : AppUpdateVerdict.upToDate,
        identity: identity,
        checkedAt: checkedAt,
        release: newest,
      );
    } on TimeoutException {
      return failure('连接更新服务超时，请稍后再试');
    } on AppUpdateException catch (error) {
      return failure(error.message);
    } on Object catch (error) {
      return failure('检查更新失败：$error');
    }
  }

  /// 下载并校验 [asset]。
  ///
  /// 校验值取 API 的 digest；没有就现取 SHA256SUMS.txt；两者都没有时拒绝下载。
  Future<AppUpdateDownload> download(
    AppRelease release,
    AppReleaseAsset asset, {
    required Directory destination,
    void Function(int received, int? total)? onProgress,
  }) async {
    final expected = await _expectedSha256(release, asset);
    if (expected == null || expected.isEmpty) {
      throw const AppUpdateException(
        '这次发布没有提供 SHA-256 校验值，已拒绝下载安装。'
        '可以打开 Release 页面手动核对文件。',
      );
    }
    final safeName = p.basename(asset.name);
    if (safeName.isEmpty || safeName == '.' || safeName == '..') {
      throw const AppUpdateException('发布资产文件名不合法');
    }
    await destination.create(recursive: true);
    final target = File(p.join(destination.path, safeName));
    final part = File('${target.path}.part');
    if (part.existsSync()) part.deleteSync();

    final request = http.Request('GET', asset.downloadUri)
      ..headers.addAll(const {'User-Agent': appUpdateUserAgent});
    final streamed = await _client.send(request).timeout(timeout);
    if (streamed.statusCode != 200) {
      throw AppUpdateException(_httpMessage('下载更新包', streamed.statusCode));
    }
    final total =
        streamed.contentLength ?? (asset.size > 0 ? asset.size : null);
    final fileSink = part.openWrite();
    final digestAccumulator = _DigestAccumulator();
    final digestSink = sha256.startChunkedConversion(digestAccumulator);
    var received = 0;
    try {
      await for (final chunk in streamed.stream.timeout(timeout)) {
        fileSink.add(chunk);
        digestSink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await fileSink.flush();
      await fileSink.close();
      digestSink.close();
    } on Object catch (error) {
      try {
        await fileSink.close();
      } on Object {
        // 已经坏了，关不上也不影响下面的清理。
      }
      if (part.existsSync()) part.deleteSync();
      throw AppUpdateException('下载中断：$error');
    }

    final actual = digestAccumulator.digest?.toString();
    if (actual == null || actual != expected) {
      if (part.existsSync()) part.deleteSync();
      throw AppUpdateException(
        'SHA-256 校验失败（期望 $expected，实际 ${actual ?? '未知'}），文件已删除',
      );
    }
    if (target.existsSync()) target.deleteSync();
    part.renameSync(target.path);
    onProgress?.call(received, total ?? received);
    return AppUpdateDownload(
      release: release,
      asset: asset,
      file: target,
      sha256: actual,
      size: received,
    );
  }

  /// 按平台执行安装。任何一步失败都会回滚或保持文件原样。
  Future<AppUpdateInstallResult> install(
    AppUpdateDownload download, {
    required AppUpdateInstallEnvironment environment,
  }) async {
    try {
      await Directory(environment.updatesRoot).create(recursive: true);
      switch (environment.installKind) {
        case AppUpdateInstallKind.replaceAppImage:
          return await _replaceAppImage(download, environment);
        case AppUpdateInstallKind.replacePortableWindows:
          return await _preparePortableWindows(download, environment);
        case AppUpdateInstallKind.manual:
          return _manual(download);
      }
    } on AppUpdateException catch (error) {
      return AppUpdateInstallResult(
        outcome: AppUpdateInstallOutcome.failed,
        message: error.message,
      );
    } on Object catch (error) {
      return AppUpdateInstallResult(
        outcome: AppUpdateInstallOutcome.failed,
        message: '安装失败：$error',
      );
    }
  }

  /// 发布页地址（UI 直接打开）。
  Uri releasePageFor(AppRelease? release) => release?.pageUri ?? releasePageUri;

  void close() {
    if (_ownsClient) _client.close();
  }

  // --- 内部 ---

  AppUpdateInstallResult _manual(AppUpdateDownload download) {
    final name = download.asset.name;
    final message = name.endsWith('.deb')
        ? '已下载 $name。当前是 deb 安装形态，请交给系统安装器完成安装'
              '（应用不会自动提权）。'
        : '已下载 $name。当前运行形态不支持应用内替换：AppImage 请退出后'
              '用它替换原文件并重启，其它形态请按发行说明手动安装。';
    return AppUpdateInstallResult(
      outcome: AppUpdateInstallOutcome.downloadedOnly,
      message: message,
      targetPath: download.file.path,
    );
  }

  Future<AppUpdateInstallResult> _replaceAppImage(
    AppUpdateDownload download,
    AppUpdateInstallEnvironment environment,
  ) async {
    final appImagePath = environment.appImagePath ?? '';
    final appImage = File(appImagePath);
    if (!appImage.existsSync()) {
      return AppUpdateInstallResult(
        outcome: AppUpdateInstallOutcome.failed,
        message: '找不到当前运行的 AppImage（$appImagePath），无法原地更新',
      );
    }
    final directory = appImage.parent.path;
    final stagedPath = p.join(directory, '.${p.basename(appImagePath)}.new');
    final staged = File(stagedPath);
    if (staged.existsSync()) staged.deleteSync();
    await download.file.copy(stagedPath);

    final chmod = await _runProcess('chmod', ['755', stagedPath]);
    if (chmod.exitCode != 0) {
      if (staged.existsSync()) staged.deleteSync();
      return AppUpdateInstallResult(
        outcome: AppUpdateInstallOutcome.failed,
        message: '设置新 AppImage 可执行权限失败（chmod 退出码 ${chmod.exitCode}）',
      );
    }

    final backup = File('$appImagePath.old');
    if (backup.existsSync()) backup.deleteSync();
    try {
      appImage.renameSync(backup.path);
    } on Object catch (error) {
      if (staged.existsSync()) staged.deleteSync();
      return AppUpdateInstallResult(
        outcome: AppUpdateInstallOutcome.failed,
        message: '无法替换当前 AppImage（目录可能只读）：$error',
      );
    }
    try {
      staged.renameSync(appImagePath);
    } on Object catch (error) {
      backup.renameSync(appImagePath);
      if (staged.existsSync()) staged.deleteSync();
      return AppUpdateInstallResult(
        outcome: AppUpdateInstallOutcome.failed,
        message: '写入新 AppImage 失败，已回滚：$error',
      );
    }
    return AppUpdateInstallResult(
      outcome: AppUpdateInstallOutcome.replacedAppImage,
      message: '已替换为 ${download.release.tag}，重启后生效（旧文件保留为 $appImagePath.old）',
      targetPath: appImagePath,
    );
  }

  Future<AppUpdateInstallResult> _preparePortableWindows(
    AppUpdateDownload download,
    AppUpdateInstallEnvironment environment,
  ) async {
    final tagToken = _safeToken(download.release.tag);
    final workDir = p.join(environment.updatesRoot, tagToken);
    await Directory(workDir).create(recursive: true);
    final staging = p.join(workDir, 'payload');
    final scriptPath = p.join(workDir, 'apply-update.ps1');
    final logPath = p.join(workDir, 'update.log');
    final script = buildPortableUpdateScript(
      processId: environment.processId,
      installRoot: environment.installRoot,
      exeName: p.basename(environment.executablePath),
      archivePath: download.file.path,
      stagingDir: staging,
      scriptLogPath: logPath,
    );
    File(scriptPath).writeAsStringSync(script);
    try {
      await _startProcess('powershell.exe', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        scriptPath,
      ]);
    } on Object catch (error) {
      return AppUpdateInstallResult(
        outcome: AppUpdateInstallOutcome.failed,
        message: '无法启动换装脚本：$error',
      );
    }
    final tag = download.release.tag;
    return AppUpdateInstallResult(
      outcome: AppUpdateInstallOutcome.portableUpdatePrepared,
      message:
          '新版本已校验并准备好。退出应用后会自动替换为 $tag 并重新启动；'
          '旧目录保留为 <安装目录>.webhtv-old 以便回滚。日志：$logPath',
      targetPath: environment.installRoot,
      scriptPath: scriptPath,
      logPath: logPath,
    );
  }

  Future<String?> _expectedSha256(
    AppRelease release,
    AppReleaseAsset asset,
  ) async {
    final direct = asset.sha256?.trim().toLowerCase();
    if (direct != null && RegExp(r'^[0-9a-f]{64}$').hasMatch(direct)) {
      return direct;
    }
    final checksumAsset = release.checksumAsset;
    if (checksumAsset == null) return null;
    try {
      final response = await _client
          .get(checksumAsset.downloadUri, headers: _headers)
          .timeout(timeout);
      if (response.statusCode != 200) return null;
      return parseSha256Sums(response.body)[asset.name];
    } on Object {
      return null;
    }
  }

  AppRelease? _newestRelease(List<AppRelease> releases) {
    AppRelease? newest;
    for (final release in releases) {
      if (newest == null) {
        newest = release;
        continue;
      }
      final byVersion = compareAppVersionNames(
        release.versionName,
        newest.versionName,
      );
      if (byVersion > 0) {
        newest = release;
        continue;
      }
      if (byVersion < 0) continue;
      final candidateTime = release.buildTime;
      final newestTime = newest.buildTime;
      if (candidateTime == null) continue;
      if (newestTime == null || candidateTime.isAfter(newestTime)) {
        newest = release;
      }
    }
    return newest;
  }

  bool _matchesChannel(AppRelease release, AppUpdateChannel channel) {
    if (channel == AppUpdateChannel.beta) return true;
    if (release.prerelease) return false;
    if (AppUpdateChannel.fromTag(release.tag) == AppUpdateChannel.beta) {
      return false;
    }
    final info = release.tagInfo;
    return info == null || info.channel == AppUpdateChannel.stable;
  }

  List<AppRelease> _parseReleases(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const AppUpdateException('更新服务返回的内容不是合法 JSON');
    }
    if (decoded is! List) {
      throw const AppUpdateException('更新服务返回的不是发布列表');
    }
    final releases = <AppRelease>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      if (item['draft'] == true) continue;
      final tag = _asString(item['tag_name']);
      if (tag.isEmpty) continue;
      final assets = <AppReleaseAsset>[];
      final rawAssets = item['assets'];
      if (rawAssets is List) {
        for (final rawAsset in rawAssets) {
          if (rawAsset is! Map) continue;
          final name = _asString(rawAsset['name']);
          final url = _asString(rawAsset['browser_download_url']);
          if (name.isEmpty || url.isEmpty) continue;
          final uri = Uri.tryParse(url);
          if (uri == null) continue;
          final digest = _asString(rawAsset['digest']);
          final sha = digest.startsWith('sha256:')
              ? digest.substring('sha256:'.length).toLowerCase()
              : null;
          assets.add(
            AppReleaseAsset(
              name: name,
              size: _asInt(rawAsset['size']),
              downloadUri: uri,
              sha256: sha,
            ),
          );
        }
      }
      final page = Uri.tryParse(_asString(item['html_url']));
      final name = _asString(item['name']);
      releases.add(
        AppRelease(
          tag: tag,
          title: name.isEmpty ? tag : name,
          body: _asString(item['body']),
          pageUri: page ?? releasePageUri,
          publishedAt: DateTime.tryParse(_asString(item['published_at'])),
          prerelease: item['prerelease'] == true,
          draft: false,
          assets: assets,
          tagInfo: AppReleaseTag.tryParse(tag),
        ),
      );
    }
    return releases;
  }

  String _httpMessage(String action, int statusCode) {
    if (statusCode == 403 || statusCode == 429) {
      return '$action被限流（HTTP $statusCode），请稍后再试';
    }
    if (statusCode == 404) {
      return '$action失败：找不到发布（HTTP 404）';
    }
    return '$action失败：HTTP $statusCode';
  }

  String _safeToken(String value) {
    final token = value.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_');
    return token.isEmpty ? 'update' : token;
  }

  static String _asString(Object? value) => value is String ? value : '';

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return 0;
  }
}

/// 把摘要分块喂进去的小收集器（crypto 的分块 API 需要一个 Sink）。
class _DigestAccumulator implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest data) {
    digest = data;
  }

  @override
  void close() {}
}

/// 生成 Windows 便携包的换装脚本。
///
/// 为什么用「退出后再整目录换装」而不是覆盖文件：
/// - 正在运行的 exe/dll 在 Windows 上不能可靠覆盖；
/// - 整目录 rename 是原子的：先备份旧目录，把解出来的 payload 移到原位，
///   启动失败还能把旧目录改回来；
/// - 脚本本身放在更新目录（安装目录之外），所以它不会被自己换掉。
///
/// 脚本约定：等待本进程退出（最多 10 分钟）→ 解包 → 校验 exe → 换装 →
/// 启动新版本 → 成功才删旧目录；任一步失败都把旧目录还原。
String buildPortableUpdateScript({
  required int processId,
  required String installRoot,
  required String exeName,
  required String archivePath,
  required String stagingDir,
  required String scriptLogPath,
}) {
  String quote(String value) => "'${value.replaceAll("'", "''")}'";
  const template = r'''$ErrorActionPreference = 'Stop'
$logPath = {{LOG}}
function Write-Log([string]$text) {
  try { Add-Content -LiteralPath $logPath -Value ((Get-Date).ToString('s') + ' ' + $text) } catch {}
}
$targetPid = {{PID}}
$installRoot = {{INSTALL_ROOT}}
$exeName = {{EXE_NAME}}
$archive = {{ARCHIVE}}
$staging = {{STAGING}}

Write-Log 'waiting for WebHTV PC to exit'
$deadline = (Get-Date).AddMinutes(10)
while (Get-Process -Id $targetPid -ErrorAction SilentlyContinue) {
  if ((Get-Date) -gt $deadline) {
    Write-Log 'timeout waiting for exit; abort without touching files'
    exit 2
  }
  Start-Sleep -Milliseconds 500
}

if (-not (Test-Path -LiteralPath $installRoot)) {
  Write-Log 'installRoot missing; abort'
  exit 3
}
if (-not (Test-Path -LiteralPath $archive)) {
  Write-Log 'downloaded archive missing; abort'
  exit 1
}
if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
New-Item -ItemType Directory -Force -Path $staging | Out-Null
Write-Log 'extracting archive'
$tar = Get-Command tar.exe -ErrorAction SilentlyContinue
if ($tar) {
  & $tar.Source -xf $archive -C $staging
} else {
  Expand-Archive -LiteralPath $archive -DestinationPath $staging -Force
}
$exe = Get-ChildItem -LiteralPath $staging -Recurse -Filter $exeName -File | Select-Object -First 1
if (-not $exe) {
  Write-Log 'extracted payload has no target exe; abort'
  exit 5
}
$payloadRoot = Split-Path -Parent $exe.FullName
$backup = $installRoot + '.webhtv-old'
if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
Write-Log ('swapping install root to ' + $payloadRoot)
try {
  Rename-Item -LiteralPath $installRoot -NewName (Split-Path -Leaf $backup)
} catch {
  Write-Log ('rename old install failed: ' + $_.Exception.Message)
  exit 6
}
try {
  Move-Item -LiteralPath $payloadRoot -Destination $installRoot
} catch {
  Write-Log ('move new payload failed: ' + $_.Exception.Message + '; rolling back')
  try { Rename-Item -LiteralPath $backup -NewName (Split-Path -Leaf $installRoot) } catch {}
  exit 7
}
Write-Log 'swap done; starting new version'
try {
  Start-Process -FilePath (Join-Path $installRoot $exeName) -WorkingDirectory $installRoot
} catch {
  Write-Log ('start failed: ' + $_.Exception.Message + '; rolling back')
  if (Test-Path -LiteralPath $installRoot) { Remove-Item -LiteralPath $installRoot -Recurse -Force }
  try { Rename-Item -LiteralPath $backup -NewName (Split-Path -Leaf $installRoot) } catch {}
  exit 8
}
Write-Log 'update completed'
exit 0
''';
  return template
      .replaceAll('{{LOG}}', quote(scriptLogPath))
      .replaceAll('{{PID}}', processId.toString())
      .replaceAll('{{INSTALL_ROOT}}', quote(installRoot))
      .replaceAll('{{EXE_NAME}}', quote(exeName))
      .replaceAll('{{ARCHIVE}}', quote(archivePath))
      .replaceAll('{{STAGING}}', quote(stagingDir));
}
