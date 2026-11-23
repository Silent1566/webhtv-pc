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
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../core/app_update.dart';
import 'app_update_cache.dart';

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
    Uri? indexUri,
    this.useStaticIndex = true,
    Directory? cacheDirectory,
    AppUpdateProxySettings Function()? proxySettings,
    bool ownsClient = false,
    this.userAgent = appUpdateUserAgent,
    this.timeout = const Duration(seconds: 20),
    DateTime Function()? clock,
    AppUpdateProcessStarter? processStarter,
    AppUpdateProcessRunner? processRunner,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null || ownsClient,
       _indexUri = indexUri ?? appUpdateIndexUri,
       _cache = AppUpdateMetadataCache(cacheDirectory),
       _proxySettings =
           proxySettings ?? (() => AppUpdateProxySettings.defaults),
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
  final Uri _indexUri;
  final bool useStaticIndex;
  final AppUpdateMetadataCache _cache;
  final AppUpdateProxySettings Function() _proxySettings;
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
    final checkedAt = _clock().toUtc();
    final deadline = Stopwatch()..start();
    final errors = <String>[];
    DateTime? retryAt;
    final sources = <({Uri uri, String label, bool api})>[];
    AppUpdateCheck result({
      AppRelease? release,
      bool failed = false,
      bool fromCache = false,
      DateTime? cachedAt,
      String? source,
    }) => AppUpdateCheck(
      verdict: failed
          ? AppUpdateVerdict.failed
          : release == null
          ? AppUpdateVerdict.upToDate
          : !identity.isReleaseBuild
          ? AppUpdateVerdict.developmentBuild
          : release.isNewerThan(identity)
          ? AppUpdateVerdict.updateAvailable
          : AppUpdateVerdict.upToDate,
      identity: identity,
      checkedAt: checkedAt,
      release: release,
      message: failed
          ? '${errors.join('；')}${fromCache ? '；仅显示旧缓存（${cachedAt?.toIso8601String()}），请联网重新检查后再安装' : ''}'
          : release == null
          ? '发布通道里还没有可见的版本'
          : null,
      fromCache: fromCache,
      cachedAt: cachedAt,
      retryAt: retryAt,
      source: source,
    );
    AppRelease? newest(List<AppRelease> releases) => _newestRelease([
      for (final release in releases)
        if (_matchesChannel(release, channel)) release,
    ]);
    try {
      final settings = _proxySettings();
      if (useStaticIndex) {
        for (final uri in settings.routesFor(_indexUri, proxyFirst: false)) {
          sources.add((
            uri: uri,
            label: uri == _indexUri ? '静态索引' : '静态索引（代理）',
            api: false,
          ));
        }
      }
      final api = _apiBaseUri.replace(
        path: '/repos/$appUpdateRepository/releases',
        queryParameters: const {'per_page': '30'},
      );
      sources.add((uri: api, label: 'GitHub API', api: true));
      await _cache.load().timeout(_checkRemaining(deadline));
      final active = sources.map((source) => source.uri.toString()).toSet();
      _cache.entries.removeWhere((key, _) => !active.contains(key));
      retryAt = _cache.cooldowns[api.toString()];
      if (retryAt != null && !retryAt.isAfter(_clock().toUtc())) {
        _cache.cooldowns.remove(api.toString());
        retryAt = null;
      }
      for (final source in sources) {
        if (source.api && retryAt != null) {
          errors.add('GitHub API 限流冷却中，请在 ${retryAt.toIso8601String()} 后重试');
          continue;
        }
        final remaining = _checkRemaining(deadline);
        if (remaining <= Duration.zero) {
          errors.add('检查更新超时');
          break;
        }
        final cached = _cache.entries[source.uri.toString()];
        try {
          final response = await _readResponse(
            source.uri,
            headers: {
              ..._headers,
              if (cached?.etag != null) 'If-None-Match': cached!.etag!,
              if (cached?.lastModified != null)
                'If-Modified-Since': cached!.lastModified!,
            },
            limit: _shorter(
              _shorter(timeout, const Duration(seconds: 6)),
              remaining,
            ),
          );
          if (response.statusCode == 304) {
            if (cached == null) throw const AppUpdateException('304 响应没有对应的缓存');
            if (source.api) {
              retryAt = _rateLimitUntil(response);
              if (retryAt != null) {
                _cache.cooldowns[source.uri.toString()] = retryAt;
                await _saveCache(deadline);
              }
            }
            return result(
              release: newest(_parseReleases(cached.body)),
              fromCache: true,
              cachedAt: cached.savedAt,
              source: source.label,
            );
          }
          if (response.statusCode != 200) {
            final limitedUntil = source.api ? _rateLimitUntil(response) : null;
            if (limitedUntil != null) {
              retryAt = limitedUntil;
              _cache.cooldowns[source.uri.toString()] = limitedUntil;
              await _saveCache(deadline);
              throw AppUpdateException(
                '查询发布信息被限流（HTTP ${response.statusCode}），请在 ${limitedUntil.toIso8601String()} 后重试',
              );
            }
            throw AppUpdateException(
              _httpMessage('查询发布信息', response.statusCode),
            );
          }
          final releases = _parseReleases(response.body);
          // 静态索引是生成物：合法 JSON 但没有任何可比较的发布，说明引发生成失败/
          // 被截断，不能据此回答「已是最新」，应继续走代理与 API 兜底。
          if (releases.isEmpty && !source.api) {
            throw const AppUpdateException('静态索引里没有可用的发布记录');
          }
          _cache.entries[source.uri.toString()] = AppUpdateCacheEntry(
            body: response.body,
            savedAt: _clock().toUtc(),
            etag: response.headers['etag'],
            lastModified: response.headers['last-modified'],
          );
          if (source.api) {
            retryAt = _rateLimitUntil(response);
            if (retryAt == null) {
              _cache.cooldowns.remove(source.uri.toString());
            } else {
              _cache.cooldowns[source.uri.toString()] = retryAt;
            }
          }
          await _saveCache(deadline);
          return result(release: newest(releases), source: source.label);
        } on Object catch (error) {
          errors.add('${source.label}：${_transportMessage(error)}');
        }
      }
    } on Object catch (error) {
      errors.add(_transportMessage(error));
    }
    if (errors.isEmpty) errors.add('检查更新失败');
    final cachedSources = [...sources]
      ..sort(
        (a, b) => (_cache.entries[b.uri.toString()]?.savedAt ?? DateTime(0))
            .compareTo(
              _cache.entries[a.uri.toString()]?.savedAt ?? DateTime(0),
            ),
      );
    for (final source in cachedSources) {
      final cached = _cache.entries[source.uri.toString()];
      if (cached == null) continue;
      try {
        return result(
          release: newest(_parseReleases(cached.body)),
          failed: true,
          fromCache: true,
          cachedAt: cached.savedAt,
          source: source.label,
        );
      } on AppUpdateException {
        _cache.entries.remove(source.uri.toString());
      }
    }
    return result(failed: true);
  }

  Duration _checkRemaining(Stopwatch watch) {
    final remaining = const Duration(seconds: 24) - watch.elapsed;
    return remaining > Duration.zero ? remaining : Duration.zero;
  }

  static Duration _shorter(Duration a, Duration b) => a < b ? a : b;

  Future<void> _saveCache(Stopwatch deadline) async {
    try {
      await _cache.save().timeout(_checkRemaining(deadline));
    } on Object {
      // A disk timeout does not invalidate successfully validated metadata.
    }
  }

  String _transportMessage(Object error) {
    if (error is AppUpdateException) return error.message;
    if (error is TimeoutException) return '连接更新服务超时，请稍后再试';
    if (error is FormatException) return '更新服务返回的内容格式错误';
    if (error is FileSystemException) return '更新文件读写失败，请检查磁盘空间与权限';
    return '网络连接失败，请检查网络后重试';
  }

  DateTime? _rateLimitUntil(http.Response response) {
    final code = response.statusCode;
    final headers = response.headers;
    if (code != 403 && code != 429 && headers['x-ratelimit-remaining'] != '0') {
      return null;
    }
    final body = response.body.toLowerCase();
    if (code != 429 &&
        headers['x-ratelimit-remaining'] != '0' &&
        !headers.containsKey('retry-after') &&
        !body.contains('rate limit') &&
        !body.contains('secondary rate') &&
        !body.contains('abuse detection')) {
      return null;
    }
    final now = _clock().toUtc();
    DateTime? retry;
    final after = headers['retry-after'];
    if (after != null) {
      final seconds = int.tryParse(after);
      if (seconds != null && seconds >= 0) {
        retry = now.add(Duration(seconds: seconds));
      } else {
        try {
          retry = HttpDate.parse(after).toUtc();
        } on FormatException {
          /* Invalid server hint; use reset or default. */
        }
      }
    }
    final reset = int.tryParse(headers['x-ratelimit-reset'] ?? '');
    if (reset != null) {
      final resetAt = DateTime.fromMillisecondsSinceEpoch(
        reset * 1000,
        isUtc: true,
      );
      if (retry == null || resetAt.isAfter(retry)) retry = resetAt;
    }
    return retry != null && retry.isAfter(now)
        ? retry
        : now.add(const Duration(seconds: 60));
  }

  Future<http.StreamedResponse> _send(
    Uri uri,
    Map<String, String> headers,
    Duration limit,
  ) async {
    var expired = false;
    final abort = Completer<void>();
    final pending = _client.send(
      http.AbortableRequest('GET', uri, abortTrigger: abort.future)
        ..headers.addAll(headers),
    );
    unawaited(
      pending.then((response) async {
        if (expired) await response.stream.listen(null).cancel();
      }, onError: (Object _) {}),
    );
    try {
      return await pending.timeout(limit);
    } on TimeoutException {
      expired = true;
      abort.complete();
      rethrow;
    }
  }

  Future<http.Response> _readResponse(
    Uri uri, {
    required Map<String, String> headers,
    required Duration limit,
  }) async {
    final watch = Stopwatch()..start();
    final response = await _send(uri, headers, limit);
    final iterator = StreamIterator(response.stream);
    final bytes = BytesBuilder(copy: false);
    try {
      while (true) {
        final remaining = limit - watch.elapsed;
        if (remaining <= Duration.zero) {
          throw TimeoutException('metadata deadline');
        }
        if (!await iterator.moveNext().timeout(remaining)) break;
        if (bytes.length + iterator.current.length > 2 * 1024 * 1024) {
          throw const AppUpdateException('更新信息超过 2 MiB 上限');
        }
        bytes.add(iterator.current);
      }
      return http.Response.bytes(
        bytes.takeBytes(),
        response.statusCode,
        headers: {
          ...response.headers,
          'content-type': 'application/json; charset=utf-8',
        },
      );
    } finally {
      await iterator.cancel();
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
    final settings = _proxySettings();
    final expected = await _expectedSha256(release, asset, settings);
    if (expected == null || expected.isEmpty) {
      throw const AppUpdateException(
        '这次发布没有提供 SHA-256 校验值，已拒绝下载安装。可以打开 Release 页面手动核对文件。',
      );
    }
    final safeName = p.basename(asset.name);
    if (safeName.isEmpty || safeName == '.' || safeName == '..') {
      throw const AppUpdateException('发布资产文件名不合法');
    }
    await destination.create(recursive: true);
    final target = File(p.join(destination.path, safeName));
    final part = File('${target.path}.part');
    final errors = <String>[];
    for (final route in settings.routesFor(asset.downloadUri)) {
      try {
        if (await part.exists()) await part.delete();
        return await _downloadCandidate(
          release,
          asset,
          route,
          expected,
          target,
          part,
          onProgress,
        );
      } on Object catch (error) {
        errors.add(
          '${route == asset.downloadUri ? '直连' : '代理'}：${_transportMessage(error)}',
        );
      } finally {
        if (await part.exists()) await part.delete();
      }
    }
    throw AppUpdateException(errors.join('；'));
  }

  Future<AppUpdateDownload> _downloadCandidate(
    AppRelease release,
    AppReleaseAsset asset,
    Uri uri,
    String expected,
    File target,
    File part,
    void Function(int received, int? total)? onProgress,
  ) async {
    final response = await _send(uri, {'User-Agent': userAgent}, timeout);
    if (response.statusCode != 200) {
      await response.stream.listen(null).cancel();
      throw AppUpdateException(_httpMessage('下载更新包', response.statusCode));
    }
    final contentLength = response.contentLength;
    if (asset.size > 0 &&
        contentLength != null &&
        contentLength != asset.size) {
      await response.stream.listen(null).cancel();
      throw const AppUpdateException('更新包大小与发布信息不符');
    }
    final total = asset.size > 0 ? asset.size : contentLength;
    final fileSink = part.openWrite();
    final digestAccumulator = _DigestAccumulator();
    final digestSink = sha256.startChunkedConversion(digestAccumulator);
    var received = 0;
    final prefix = <int>[];
    try {
      await for (final chunk in response.stream.timeout(timeout)) {
        received += chunk.length;
        if ((asset.size > 0 && received > asset.size) ||
            (contentLength != null && received > contentLength)) {
          throw const AppUpdateException('更新包超过声明大小');
        }
        if (prefix.length < 512) prefix.addAll(chunk.take(512 - prefix.length));
        fileSink.add(chunk);
        digestSink.add(chunk);
        onProgress?.call(received, total);
      }
      await fileSink.flush();
      await fileSink.close();
    } finally {
      digestSink.close();
      try {
        await fileSink.close();
      } on Object {
        /* Preserve the original transfer error. */
      }
    }
    if ((asset.size > 0 && received != asset.size) ||
        (contentLength != null && received != contentLength)) {
      throw const AppUpdateException('更新包不完整，实际大小与声明大小不符');
    }
    if (RegExp(
      r'^\s*(?:<!doctype\s+html|<html|<head|<body)',
      caseSensitive: false,
    ).hasMatch(latin1.decode(prefix))) {
      throw const AppUpdateException('更新服务返回了 HTML 页面而非更新包');
    }
    final actual = digestAccumulator.digest?.toString();
    if (actual == null || actual != expected) {
      throw AppUpdateException(
        'SHA-256 校验失败（期望 $expected，实际 ${actual ?? '未知'}），文件已删除',
      );
    }
    if (await target.exists()) await target.delete();
    await part.rename(target.path);
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
    AppUpdateProxySettings settings,
  ) async {
    final direct = asset.sha256?.trim().toLowerCase();
    if (direct != null && RegExp(r'^[0-9a-f]{64}$').hasMatch(direct)) {
      return direct;
    }
    final checksumAsset = release.checksumAsset;
    if (checksumAsset == null) return null;
    for (final uri in settings.routesFor(checksumAsset.downloadUri)) {
      try {
        final response = await _readResponse(
          uri,
          headers: {'User-Agent': userAgent},
          limit: _shorter(timeout, const Duration(seconds: 6)),
        );
        if (response.statusCode != 200) continue;
        final digest = parseSha256Sums(response.body)[asset.name];
        if (digest != null) return digest;
      } on Object {
        // Invalid checksum candidates get the same single direct fallback.
      }
    }
    return null;
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
      if (tag == appUpdateIndexTag || AppReleaseTag.tryParse(tag) == null) {
        continue;
      }
      final assets = <AppReleaseAsset>[];
      final rawAssets = item['assets'];
      if (rawAssets is List) {
        for (final rawAsset in rawAssets) {
          if (rawAsset is! Map) continue;
          final name = _asString(rawAsset['name']);
          final url = _asString(rawAsset['browser_download_url']);
          if (name.isEmpty || url.isEmpty) continue;
          final uri = Uri.tryParse(url);
          if (uri == null ||
              !uri.hasAuthority ||
              (uri.scheme != 'https' && uri.scheme != 'http') ||
              uri.userInfo.isNotEmpty) {
            continue;
          }
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
    if (releases.isEmpty) throw const AppUpdateException('更新服务没有返回有效的普通发布');
    return releases;
  }

  String _httpMessage(String action, int statusCode) {
    if (statusCode == 429) {
      return '$action被限流（HTTP $statusCode），请稍后再试';
    }
    if (statusCode == 403) return '$action被拒绝访问（HTTP 403），请检查网络或访问权限';
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
