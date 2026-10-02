/// 猫源 bundle（CatPawOpen 的 `index.js`）的下载、校验与本地缓存。
///
/// 参考实现：`Silent1566/webhtv@beta` 的
/// `app/src/main/java/com/fongmi/android/tv/node/NodeBundle.java`。
///
/// 用户填的是 `.../index.js.md5`——那个地址返回 32 位校验值，真正的 bundle 在去掉
/// `.md5` 后缀的地址上。每次启动只拉几十字节的 md5 比对，命中就用本地缓存，
/// 不重复下载 1.6 MB 的 bundle。
///
/// 本地包（用户自己解压出来的 `index.js` + `index.config.js` 目录，或还没解压的 zip）
/// 走同一套缓存判定，只是把「下载」换成「复制/解压」、把远端 md5 换成文件的实际 md5。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../core/app_error.dart';
import '../core/protocol.dart';

/// bundle 安装结果：成功时 [error] 为空，磁盘上 `index.js`/`index.config.js` 可用。
class CatBundleResult {
  const CatBundleResult({this.error, required this.bundleDir});

  final String? error;
  final String bundleDir;

  bool get ok => error == null;

  String get entryPath => p.join(bundleDir, 'index.js');
  String get configPath => p.join(bundleDir, 'index.config.js');
}

/// 猫源 bundle 的下载/校验/缓存（§9.7、§9.8）。
class CatBundle {
  CatBundle({
    required this.rootDir,
    HttpClient? httpClient,
    this.metadataTimeout = const Duration(seconds: 3),
    this.downloadTimeout = const Duration(seconds: 60),
    this.maxEntryBytes = 32 * 1024 * 1024,
  }) : _client = httpClient ?? HttpClient() {
    _client.connectionTimeout = downloadTimeout;
  }

  /// bundle 运行目录（产品路径下建议 `<dataDir>/catbundle`）。
  final String rootDir;

  /// md5 校验值只有 32 字节，但走默认超时会把复用判定拖成几十秒的黑屏。
  final Duration metadataTimeout;
  final Duration downloadTimeout;
  final int maxEntryBytes;

  final HttpClient _client;

  static const String _suffix = '.md5';
  static const String marker = 'index.js.md5';
  static const String configMarker = 'index.config.js.md5';
  static const String sourceStamp = 'source.key';
  static const int _maxMetadataBytes = 4096;

  /// 自行跟随重定向的上限（加速镜像 302 → 真实源）。
  static const int maxRedirects = 5;

  void close() => _client.close(force: true);

  /// 去掉 `.md5` 后缀，得到真正的 bundle 地址。
  static String bundleUrl(String url) {
    final trimmed = url.trim();
    final lower = trimmed.toLowerCase();
    return lower.endsWith(_suffix)
        ? trimmed.substring(0, trimmed.length - _suffix.length)
        : trimmed;
  }

  /// 补上 `.md5` 后缀，得到校验值地址。
  static String md5Url(String url) {
    final trimmed = url.trim();
    final lower = trimmed.toLowerCase();
    return lower.endsWith(_suffix) ? trimmed : '$trimmed$_suffix';
  }

  /// 配套的 `index.config.js` 地址（与 `index.js` 同目录）。
  static String configUrl(String url) {
    final bundle = bundleUrl(url);
    final slash = bundle.lastIndexOf('/');
    return slash < 0 ? bundle : '${bundle.substring(0, slash + 1)}index.config.js';
  }

  /// 去掉 `.md5` 后缀的 `index.config.js.md5` 地址。
  static String configMd5Url(String url) => md5Url(configUrl(url));

  static bool isRemote(String url) {
    final value = url.trim().toLowerCase();
    return value.startsWith('http://') || value.startsWith('https://');
  }

  static bool isMd5(String? value) {
    if (value == null) return false;
    final trimmed = value.trim();
    if (trimmed.length != 32) return false;
    return RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(trimmed);
  }

  /// 单个 bundle 的落地目录（去掉 `.md5` 的地址 → 稳定目录名）。
  String dirFor(String url) {
    final identity = md5.convert(utf8.encode(bundleUrl(url))).toString();
    return p.join(rootDir, identity);
  }

  /// 确保 bundle 已就绪并返回安装结果。可通过 [onProgress] 汇报进度（UI 用）。
  Future<CatBundleResult> ensure(
    String url, {
    void Function(String message)? onProgress,
  }) async {
    final dir = dirFor(url);
    await Directory(dir).create(recursive: true);
    await _sweep(dir);

    // 与 sourceKey 的 root 必须一致，否则指纹和安装会指向不同文件。
    final local = await _localDir(url);
    if (local != null) return _ensureLocal(dir, local);
    final zip = await _localZip(url);
    if (zip != null) return _ensureZip(dir, zip);
    if (!isRemote(url)) {
      return CatBundleResult(
        bundleDir: dir,
        error: '猫源地址无法访问，本地包可能已被移动：$url',
      );
    }
    return _ensureRemote(dir, url, onProgress: onProgress);
  }

  // ---------------------------------------------------------------------------
  // 本地包
  // ---------------------------------------------------------------------------

  /// 若 URL 指向一个本地目录（含 `index.js`）则返回它。
  ///
  /// 只要求 `index.js`：缺 `index.config.js` 时由 [_ensureLocal] 报出可定位错误
  /// （「本地包缺少 index.config.js」），而不是让调用方落入「地址不可访问」的兜底。
  Future<String?> _localDir(String url) async {
    final path = _localPath(url);
    if (path == null) return null;
    final dir = Directory(path);
    if (!await dir.exists()) return null;
    if (await File(p.join(path, 'index.js')).exists()) {
      return path;
    }
    return null;
  }

  /// 若 URL 指向一个本地 zip（内含 `index.js.md5` 标记）则返回它。
  Future<String?> _localZip(String url) async {
    final path = _localPath(url);
    if (path == null) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    // 只认能解析出 `index.js.md5` 标记的 zip，避免把任意压缩包当猫源包。
    try {
      final markerValue = await _readZipEntry(file, CatBundle.marker);
      return isMd5(markerValue) ? path : null;
    } catch (_) {
      return null;
    }
  }

  String? _localPath(String url) {
    var value = url.trim();
    if (value.isEmpty || isRemote(value)) return null;
    final lower = value.toLowerCase();
    if (lower.startsWith('file://')) {
      value = value.substring(7);
    } else if (lower.startsWith('file:/')) {
      value = value.substring(6);
    }
    return value;
  }

  Future<CatBundleResult> _ensureLocal(String dir, String source) async {
    final bundle = File(p.join(source, 'index.js'));
    final config = File(p.join(source, 'index.config.js'));
    if (!await bundle.exists() || await bundle.length() == 0) {
      return CatBundleResult(bundleDir: dir, error: '本地包缺少 index.js，请选择整个包（zip 或解压后的文件夹）');
    }
    if (!await config.exists() || await config.length() == 0) {
      return CatBundleResult(bundleDir: dir, error: '本地包缺少 index.config.js');
    }
    if (_sameFile(bundle.path, p.join(dir, 'index.js')) ||
        _sameFile(config.path, p.join(dir, 'index.config.js'))) {
      return CatBundleResult(bundleDir: dir, error: '本地包不能指向 Node 运行目录');
    }

    final staging = await _stagingDir(dir);
    try {
      final preparedBundle = await _prepareFile(bundle, File(p.join(staging, 'index.js')));
      final preparedConfig = await _prepareFile(config, File(p.join(staging, 'index.config.js')));
      // 目录形态只在标记与内容不一致时告警，不阻断：解压出来的目录是用户可写的，
      // 改 index.config.js 换站点、魔改 index.js 都是本地包的正常用法，marker 不会跟着更新。
      final key = 'local:${preparedBundle.md5}:${preparedConfig.md5}';
      return await _install(dir, preparedBundle, preparedConfig, key);
    } catch (error) {
      return CatBundleResult(bundleDir: dir, error: _message(error));
    } finally {
      await _cleanup(staging);
    }
  }

  Future<CatBundleResult> _ensureZip(String dir, String zipPath) async {
    final staging = await _stagingDir(dir);
    try {
      final expectedBundle = (await _readZipEntry(File(zipPath), marker))?.trim() ?? '';
      if (!isMd5(expectedBundle)) {
        return CatBundleResult(bundleDir: dir, error: '本地包 index.js.md5 无效');
      }
      final expectedConfig =
          (await _readZipEntry(File(zipPath), configMarker))?.trim() ?? '';
      if (expectedConfig.isNotEmpty && !isMd5(expectedConfig)) {
        return CatBundleResult(bundleDir: dir, error: '本地包 index.config.js.md5 无效');
      }
      final preparedBundle = await _extractZipEntry(
        File(zipPath), 'index.js', File(p.join(staging, 'index.js')), expectedBundle,
      );
      final preparedConfig = await _extractZipEntry(
        File(zipPath), 'index.config.js', File(p.join(staging, 'index.config.js')), expectedConfig,
      );
      // zip 形态保持硬校验（压缩包内容用户改不了，不符就是包损坏）。
      final key = 'local-zip:${preparedBundle.md5}:${preparedConfig.md5}';
      return await _install(dir, preparedBundle, preparedConfig, key);
    } catch (error) {
      return CatBundleResult(bundleDir: dir, error: '本地包解压失败: ${_message(error)}');
    } finally {
      await _cleanup(staging);
    }
  }

  // ---------------------------------------------------------------------------
  // 远端包
  // ---------------------------------------------------------------------------

  Future<CatBundleResult> _ensureRemote(
    String dir,
    String url, {
    void Function(String message)? onProgress,
  }) async {
    // 校验值在 **.md5** 地址上（`index.js.md5` / `index.config.js.md5`，各 32 字节）；
    // 去掉 `.md5` 的地址是真正的 bundle（1~10 MB JS 源码）。这里必须取 `.md5`，
    // 否则会把 JS 源码当校验值 → `isMd5` 判假 → 误报「校验值不可用，且没有本地缓存」。
    final expectedBundle = await _remoteMd5(md5Url(bundleUrl(url)));
    final expectedConfig = await _remoteMd5(configMd5Url(url));
    final key = _remoteSourceKey(url, expectedBundle, expectedConfig);
    // 两个校验值缺任何一个都算不出完整身份，此时只能靠已装好的缓存服务，不能下载未校验内容。
    if (!isMd5(expectedBundle) || !isMd5(expectedConfig)) {
      return _ensureRemoteOffline(dir, url);
    }

    final cached = await _remoteCacheState(dir, url, expectedBundle, expectedConfig);
    if (cached[0] && cached[1]) {
      await _refreshSourceKey(dir, key);
      return CatBundleResult(bundleDir: dir);
    }

    onProgress?.call('下载猫源 bundle');
    final staging = await _stagingDir(dir);
    try {
      final preparedBundle = cached[0]
          ? await _prepareFile(File(p.join(dir, 'index.js')), File(p.join(staging, 'index.js')))
          : await _download(bundleUrl(url), File(p.join(staging, 'index.js')), expectedBundle);
      final preparedConfig = cached[1]
          ? await _prepareFile(File(p.join(dir, 'index.config.js')), File(p.join(staging, 'index.config.js')))
          : await _download(configUrl(url), File(p.join(staging, 'index.config.js')), expectedConfig);
      return await _install(dir, preparedBundle, preparedConfig, key);
    } catch (error) {
      return CatBundleResult(bundleDir: dir, error: _message(error));
    } finally {
      await _cleanup(staging);
    }
  }

  /// 校验值不全（断网、404、返回 HTML）时的降级：继续用已经装好、且确实属于这个地址的
  /// 缓存，绝不下载未校验的内容。没有可用缓存才报错。
  Future<CatBundleResult> _ensureRemoteOffline(String dir, String url) async {
    final installed = await _read(p.join(dir, sourceStamp));
    if (!_installedIsRemoteOf(installed, url)) {
      return CatBundleResult(bundleDir: dir, error: '猫源校验值不可用，且没有该地址的本地缓存：$url');
    }
    final digests = _installedDigests(installed);
    final bundleCached = await _isCached(dir, 'index.js', marker, installed, digests[0]);
    final configCached = await _isCached(dir, 'index.config.js', configMarker, installed, digests[1]);
    if (bundleCached && configCached) {
      return CatBundleResult(bundleDir: dir);
    }
    return CatBundleResult(bundleDir: dir, error: '猫源校验值不可用，本地缓存也不完整，无法安全启动：$url');
  }

  /// 逐个文件判定远端缓存是否可用，返回 `[bundle, config]`。
  ///
  /// 归属和内容要分开判：**不能**把本次算出的复合来源键（含两个文件的指纹）当成单个
  /// 文件的缓存键。那样「服务端只改了 index.config.js」会连 index.js 一起判失效，
  /// 每次配置更新都重下整包。
  Future<List<bool>> _remoteCacheState(
    String dir,
    String url,
    String expectedBundle,
    String expectedConfig,
  ) async {
    final installed = await _read(p.join(dir, sourceStamp));
    if (!_installedIsRemoteOf(installed, url)) return [false, false];
    return [
      await _isCached(dir, 'index.js', marker, installed, expectedBundle),
      await _isCached(dir, 'index.config.js', configMarker, installed, expectedConfig),
    ];
  }

  /// 判断某个文件是否命中缓存：先确认归属（source.key），再比内容校验值。
  Future<bool> _isCached(
    String dir,
    String name,
    String stampName,
    String installed,
    String expected,
  ) async {
    if (!isMd5(expected)) return false;
    final file = File(p.join(dir, name));
    if (!await file.exists() || await file.length() == 0) return false;
    final stamp = (await _read(p.join(dir, stampName))).trim();
    if (stamp.toLowerCase() != expected.toLowerCase()) return false;
    // 交叉校验：stamp 必须与安装时已校验过的摘要一致，避免手改 stamp 骗过缓存。
    final digests = _installedDigests(installed);
    if (name == 'index.js') return stamp.toLowerCase() == digests[0].toLowerCase();
    return stamp.toLowerCase() == digests[1].toLowerCase();
  }

  /// 两个文件都命中缓存、但落盘的来源键不是当前身份时，就地补齐。
  Future<bool> _refreshSourceKey(String dir, String key) async {
    if (key.isEmpty) return false;
    final current = await _read(p.join(dir, sourceStamp));
    if (key == current) return false;
    final digests = _installedDigests(key);
    final stamp = (await _read(p.join(dir, marker))).trim();
    final configStamp = (await _read(p.join(dir, configMarker))).trim();
    if (stamp.toLowerCase() != digests[0].toLowerCase()) return false;
    if (configStamp.toLowerCase() != digests[1].toLowerCase()) return false;
    await _writeAtomic(p.join(dir, sourceStamp), key);
    return true;
  }

  /// 发一个 GET 请求（自行处理重定向与 userinfo 凭据）。
  ///
  /// 两处必须统一，才能同时满足远端猫源的两种现实写法：
  /// 1. **userinfo 凭据**：`HttpClient` 不会解码 URI userinfo 的百分号编码，
  ///    密码里的 `%3A` 会被字面发出导致 401；这里改成解码后显式设 `Authorization`
  ///    头，并把 URI 里的 userinfo 去掉（[basicAuthHeader]/[uriWithoutUserInfo]）。
  /// 2. **加速镜像 302**：`ghfast.top` 一类地址会 302 到真实源；`followRedirects=false`
  ///    会把 302 当成失败。重定向由我们自己跟（上限 [maxRedirects]），
  ///    且**跨主机时不带 Authorization**，避免把凭据泄给镜像站。
  Future<HttpClientResponse> _openGet(
    String url,
    Duration timeout, {
    String accept = '*/*',
  }) async {
    var uri = Uri.parse(url);
    final auth = basicAuthHeader(uri);
    var sendAuth = auth != null;
    uri = uriWithoutUserInfo(uri);

    for (var hop = 0; hop <= maxRedirects; hop++) {
      final request = await _client.getUrl(uri).timeout(timeout);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, accept);
      if (sendAuth && auth != null) {
        request.headers.set(HttpHeaders.authorizationHeader, auth);
      }
      final response = await request.close().timeout(timeout);
      final status = response.statusCode;
      if (status < 300 || status >= 400) return response;

      final location = response.headers.value(HttpHeaders.locationHeader);
      await response.drain<void>();
      if (location == null || location.isEmpty) {
        throw const _BundleException('猫源地址重定向缺少 Location 头');
      }
      final next = uri.resolve(location);
      final scheme = next.scheme.toLowerCase();
      if (scheme != 'http' && scheme != 'https') {
        throw _BundleException('猫源地址重定向到不支持的协议：$scheme');
      }
      // 跨主机（含换端口）时丢弃凭据：加速镜像不应拿到原始账号密码。
      if (next.host != uri.host || next.port != uri.port) sendAuth = false;
      uri = next;
    }
    throw _BundleException('猫源地址重定向超过 $maxRedirects 次');
  }

  /// 读取 32 字节校验值；任何失败都返回空串（调用方按「校验值不可用」降级）。
  Future<String> _remoteMd5(String url) async {
    try {
      final response = await _openGet(url, metadataTimeout, accept: 'text/plain,*/*');
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        return '';
      }
      if (response.headers.contentLength > _maxMetadataBytes) {
        await response.drain<void>();
        return '';
      }
      final bytes = await _readBounded(response, _maxMetadataBytes);
      final value = utf8.decode(bytes, allowMalformed: true).trim();
      return isMd5(value) ? value : '';
    } catch (_) {
      return '';
    }
  }

  Future<_PreparedFile> _download(String url, File target, String expected) async {
    if (!isMd5(expected)) throw const _BundleException('bundle 校验值不可用');
    final response = await _openGet(url, downloadTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>();
      throw _BundleException('bundle 下载失败 HTTP ${response.statusCode}');
    }
    final actual = await _copyAndDigest(response, target, limit: maxEntryBytes);
    if (actual.toLowerCase() != expected.toLowerCase()) {
      throw const _BundleException('bundle 校验失败');
    }
    return _PreparedFile(target: target, md5: actual);
  }

  // ---------------------------------------------------------------------------
  // 安装
  // ---------------------------------------------------------------------------

  /// 正式文件只在准备完成后替换，失败时恢复旧缓存。
  Future<CatBundleResult> _install(
    String dir,
    _PreparedFile bundle,
    _PreparedFile config,
    String sourceKey,
  ) async {
    final bundleTarget = File(p.join(dir, 'index.js'));
    final configTarget = File(p.join(dir, 'index.config.js'));
    final bundleBackup = File(p.join(dir, 'index.js.bak'));
    final configBackup = File(p.join(dir, 'index.config.js.bak'));
    await _deleteQuietly(bundleBackup);
    await _deleteQuietly(configBackup);

    var bundleReplaced = false;
    var configReplaced = false;
    try {
      if (await bundleTarget.exists()) await bundleTarget.rename(bundleBackup.path);
      bundleReplaced = true;
      await bundle.target.rename(bundleTarget.path);
      if (await configTarget.exists()) await configTarget.rename(configBackup.path);
      configReplaced = true;
      await config.target.rename(configTarget.path);

      await _writeAtomic(p.join(dir, marker), bundle.md5);
      await _writeAtomic(p.join(dir, configMarker), config.md5);
      await _writeAtomic(p.join(dir, sourceStamp), sourceKey);
      await _deleteQuietly(bundleBackup);
      await _deleteQuietly(configBackup);
      return CatBundleResult(bundleDir: dir);
    } catch (error) {
      // 回滚：把备份放回去，保证旧缓存仍可用（「失败不影响其他站点」）。
      if (bundleReplaced && await bundleBackup.exists()) {
        await _deleteQuietly(bundleTarget);
        await bundleBackup.rename(bundleTarget.path);
      }
      if (configReplaced && await configBackup.exists()) {
        await _deleteQuietly(configTarget);
        await configBackup.rename(configTarget.path);
      }
      await _deleteQuietly(bundleBackup);
      await _deleteQuietly(configBackup);
      return CatBundleResult(bundleDir: dir, error: '猫源 bundle 安装失败: ${_message(error)}');
    }
  }

  /// 清掉上次被杀进程留下的 staging 目录。
  ///
  /// 换源时会强杀子进程，正在 install 的 finally 不会执行，残留最多可达几十 MB。
  /// backup 残留一律丢弃、不尝试当恢复点：那份内容是否完整无从判断，而丢掉最多多下一次，
  /// 认错了却会把损坏的 bundle 当有效缓存跑起来。
  Future<void> _sweep(String dir) async {
    final directory = Directory(dir);
    if (!await directory.exists()) return;
    await for (final entity in directory.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (name.startsWith('.stage-')) {
        await _cleanup(entity.path);
      } else if (name.endsWith('.tmp') || name.endsWith('.bak')) {
        await _deleteQuietly(File(entity.path));
      }
    }
  }

  Future<String> _stagingDir(String dir) async {
    final staging = p.join(dir, '.stage-${DateTime.now().microsecondsSinceEpoch}');
    await Directory(staging).create(recursive: true);
    return staging;
  }

  // ---------------------------------------------------------------------------
  // 指纹与工具
  // ---------------------------------------------------------------------------

  /// 远端来源身份：`remote:<bundleUrl>:<bundleMd5>:<configMd5>`。
  ///
  /// 含内容指纹，服务端原地更新 bundle（URL 不变、md5 变了）时能正确判定为换源。
  static String _remoteSourceKey(String url, String bundleMd5, String configMd5) {
    if (!isMd5(bundleMd5) || !isMd5(configMd5)) return '';
    return 'remote:${bundleUrl(url)}:${bundleMd5.toLowerCase()}:${configMd5.toLowerCase()}';
  }

  static bool _installedIsRemoteOf(String installed, String url) {
    final prefix = 'remote:${bundleUrl(url)}:';
    return installed.startsWith(prefix);
  }

  /// 从已安装的来源键里取出安装时已校验过的两个 md5，用于离线交叉校验。
  static List<String> _installedDigests(String installed) {
    if (!installed.startsWith('local:') && !installed.startsWith('local-zip:')) {
      final parts = installed.split(':');
      if (parts.length >= 4) return [parts[parts.length - 2], parts[parts.length - 1]];
      return ['', ''];
    }
    final rest = installed.substring(installed.indexOf(':') + 1);
    final parts = rest.split(':');
    if (parts.length == 2) return [parts[0], parts[1]];
    return ['', ''];
  }

  Future<_PreparedFile> _prepareFile(File source, File target) async {
    final stream = source.openRead();
    final actual = await _copyAndDigest(stream, target, limit: maxEntryBytes);
    return _PreparedFile(target: target, md5: actual);
  }

  Future<_PreparedFile> _extractZipEntry(
    File zip,
    String name,
    File target,
    String expected,
  ) async {
    final bytes = await _readZipBytes(zip, name);
    if (bytes == null) throw _BundleException('本地包缺少 $name');
    if (bytes.length > maxEntryBytes) throw _BundleException('本地包 $name 超过大小限制');
    await target.writeAsBytes(bytes, flush: true);
    final actual = md5.convert(bytes).toString();
    if (isMd5(expected) && expected.toLowerCase() != actual.toLowerCase()) {
      throw _BundleException('本地包 $name 校验失败');
    }
    return _PreparedFile(target: target, md5: actual);
  }

  Future<String> _copyAndDigest(
    Stream<List<int>> source,
    File target, {
    required int limit,
  }) async {
    final sink = target.openWrite();
    final chunks = <List<int>>[];
    var total = 0;
    try {
      await for (final chunk in source) {
        total += chunk.length;
        if (total > limit) {
          throw const _BundleException('bundle 超过大小限制');
        }
        chunks.add(chunk);
        sink.add(chunk);
      }
      await sink.flush();
      return md5.convert(chunks.expand((c) => c).toList()).toString();
    } finally {
      await sink.close();
    }
  }

  Future<Uint8List> _readBounded(HttpClientResponse response, int limit) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
      if (builder.length > limit) break;
    }
    return builder.takeBytes();
  }

  Future<String> _read(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return '';
      return await file.readAsString();
    } catch (_) {
      return '';
    }
  }

  Future<void> _writeAtomic(String path, String content) async {
    final temp = File('$path.tmp');
    await temp.writeAsString(content, flush: true);
    await temp.rename(path);
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> _cleanup(String? path) async {
    if (path == null) return;
    try {
      final dir = Directory(path);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  static bool _sameFile(String a, String b) {
    return p.normalize(p.absolute(a)).toLowerCase() ==
        p.normalize(p.absolute(b)).toLowerCase();
  }

  static String _message(Object error) {
    if (error is _BundleException) return error.message;
    if (error is AppError) return error.message;
    if (error is FileSystemException) return error.osError?.message ?? error.message;
    return '$error';
  }

  // ---------------------------------------------------------------------------
  // 极简 zip 读取（只读 STORED/DEFLATE 条目，避免为单一用途引入完整解压依赖）
  // ---------------------------------------------------------------------------

  Future<String?> _readZipEntry(File zip, String name) async {
    final bytes = await _readZipBytes(zip, name);
    if (bytes == null) return null;
    return utf8.decode(bytes, allowMalformed: true);
  }

  Future<Uint8List?> _readZipBytes(File zip, String name) async {
    final reader = _ZipReader(await zip.readAsBytes());
    return reader.read(name);
  }
}

class _PreparedFile {
  const _PreparedFile({required this.target, required this.md5});

  final File target;
  final String md5;
}

class _BundleException implements Exception {
  const _BundleException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 极简 zip 解析：遍历 central directory，只解出所需条目。
///
/// 猫源本地包只有一个极小的需求——读出 `index.js`、`index.config.js` 与两个
/// `.md5` 标记，因此不引入完整解压依赖，直接按 ZIP 规范读 central directory，
/// 只支持 STORED(0) 与 DEFLATE(8) 两种压缩方法（所有常见 zip 工具都用这两种）。
class _ZipReader {
  _ZipReader(this.bytes);

  final Uint8List bytes;

  Uint8List? read(String name) {
    final entry = _findEntry(name);
    if (entry == null) return null;
    final data = bytes.sublist(entry.dataStart, entry.dataStart + entry.compressedSize);
    switch (entry.method) {
      case 0:
        return Uint8List.fromList(data);
      case 8:
        return Uint8List.fromList(ZLibDecoder(raw: true).convert(data));
      default:
        throw _BundleException('本地包使用了不支持的压缩方法 ${entry.method}');
    }
  }

  _ZipEntry? _findEntry(String name) {
    final eocd = _findEndOfCentralDirectory();
    if (eocd == null) return null;
    final count = _u16(eocd + 10);
    var offset = _u32(eocd + 16);
    for (var i = 0; i < count; i++) {
      if (offset + 46 > bytes.length) return null;
      if (_u32(offset) != 0x02014b50) return null;
      final method = _u16(offset + 10);
      final compressedSize = _u32(offset + 20);
      final nameLength = _u16(offset + 28);
      final extraLength = _u16(offset + 30);
      final commentLength = _u16(offset + 32);
      final localOffset = _u32(offset + 42);
      final entryName = utf8.decode(
        bytes.sublist(offset + 46, offset + 46 + nameLength),
        allowMalformed: true,
      );
      if (entryName == name) {
        if (localOffset + 30 > bytes.length) return null;
        if (_u32(localOffset) != 0x04034b50) return null;
        final localNameLength = _u16(localOffset + 26);
        final localExtraLength = _u16(localOffset + 28);
        final dataStart = localOffset + 30 + localNameLength + localExtraLength;
        return _ZipEntry(
          method: method,
          compressedSize: compressedSize,
          dataStart: dataStart,
        );
      }
      offset += 46 + nameLength + extraLength + commentLength;
    }
    return null;
  }

  int? _findEndOfCentralDirectory() {
    // EOCD 至少 22 字节；注释最长 65535，从尾部向前找签名。
    final start = bytes.length - 22;
    for (var i = start; i >= 0 && i > start - 65536; i--) {
      if (i + 4 > bytes.length) continue;
      if (_u32(i) == 0x06054b50) return i;
    }
    return null;
  }

  int _u16(int offset) => bytes[offset] | (bytes[offset + 1] << 8);

  int _u32(int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
}

class _ZipEntry {
  const _ZipEntry({
    required this.method,
    required this.compressedSize,
    required this.dataStart,
  });

  final int method;
  final int compressedSize;
  final int dataStart;
}
