/// 直连 `.js` / `.py` 站点的自动注册（`docs/phase9/README.md` P1-7）。
///
/// 安卓允许站点 `api` 直接指向一个 JS/Python 文件；PC 端此前要求用户手工写
/// `spider-local:` manifest。这里把「下载 → 落盘 → 生成 manifest → 注册」自动化，
/// 复用同一套 `webhtv-ipc-v1` sidecar（不新增运行时）。
///
/// 另有第三种形态 [DirectSpiderKind.catVod]：安卓生态里大量站点 `api` 只写壳名
/// （如 `csp_PyProxy`），真正的 Python 蜘蛛地址在 `ext.loader` 里。这类站点
/// 下载 `loader.py` 后生成一个 CatVod 壳入口 `spider.py`，由 sidecar 里的
/// `webhtv_catvod.py` 把 CatVod 语义方法适配成 `webhtv-ipc-v1` 宿主契约。
///
/// `.py` 直连站点如果本身就是 CatVod 壳（探测规则见 [looksLikeCatVodShell]），
/// 也会生成同样的入口，`runtime` 记 `python-catvod`；`.js` 站点的 `runtime`
/// 记 `node-tvbox`（TVBox 保真沙箱）。
///
/// 安全与正确性：
/// - 只接受 `http(s)`；
/// - 单文件上限 [maxBytes]（默认 2 MiB），超限拒绝；
/// - 落盘后记录 SHA-256；已存在且哈希一致时**不重复下载**；
/// - 下载/写盘/注册失败只记日志并跳过该站点，不影响其他站点与启动；
/// - 仍然是不可信代码：只在独立 sidecar 中执行，主进程不加载。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../core/ipc_protocol.dart';
import '../core/protocol.dart';
import 'log_service.dart';
import 'spider_registry.dart';

class DirectSpiderRegistrar {
  DirectSpiderRegistrar({
    required this.root,
    required this.registry,
    this.log,
    http.Client? client,
    this.maxBytes = 2 * 1024 * 1024,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client();

  /// Spider 根目录；自动注册的产物放在 `<root>/direct/<hash>/`。
  final String root;
  final SpiderManifestRegistry registry;
  final int maxBytes;
  final Duration timeout;

  final LogService? log;
  final http.Client _client;

  /// 扫描配置里的直连 js/py 站点并完成注册。
  ///
  /// 返回「站点 key → LocalSpider」；失败/不支持的站点不出现在结果里。
  Future<Map<String, LocalSpider>> materialize(AppConfig config) async {
    final result = <String, LocalSpider>{};
    for (final site in config.sites) {
      final kind = directSpiderKind(site);
      if (kind == null) continue;
      try {
        final local = await _materializeSite(site, kind);
        if (local != null) result[site.key] = local;
      } catch (error) {
        log?.warning(
          '直连站源注册失败 site=${site.key} api=${redactUrl(site.api)} $error',
          scope: 'spider',
        );
      }
    }
    if (result.isNotEmpty) {
      log?.info('直连站源已注册 ${result.length} 个', scope: 'spider');
    }
    return result;
  }

  Future<LocalSpider?> _materializeSite(Site site, DirectSpiderKind kind) async {
    if (kind == DirectSpiderKind.catVod) {
      return _materializeCatVod(site);
    }
    final api = site.api.trim();
    final uri = Uri.tryParse(api);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    // 目录键必须带上站点 key：同一份配置里几十上百个站点的 api 完全一样（如
    // `Atvp.py?v=t4-direct-v1`），只有 `ext` 不同；只用 api 做键会让它们全落到
    // 同一个目录，manifest 互相覆盖、注册表按 key 覆盖 `_spiders`，最后只剩一个
    // 站点能用。口径与 `_materializeCatVod` 完全一致。
    final digest = sha256.convert(utf8.encode('${site.key}\n$api')).toString();
    final dir = Directory(p.join(root, 'direct', digest.substring(0, 16)));
    await dir.create(recursive: true);
    final manifestPath = p.join(dir.path, 'manifest.json');

    if (kind == DirectSpiderKind.js) {
      return _materializeJs(site, uri, dir, manifestPath);
    }
    return _materializePy(site, uri, dir, manifestPath);
  }

  /// `.js` 直连站点：下载物本身就是入口，运行时交给 TVBox 保真沙箱。
  ///
  /// `runtime` 写 `node-tvbox`（`node*` 前缀由分发层按前缀识别，见
  /// `spider_registry.dart` 的 `runtime.startsWith('node')`）。
  Future<LocalSpider?> _materializeJs(
    Site site,
    Uri uri,
    Directory dir,
    String manifestPath,
  ) async {
    final previousSha256 = await _recordedEntrySha256(manifestPath);
    final entrySha256 = await _syncEntry(
      uri: uri,
      path: p.join(dir.path, 'spider.js'),
      recordedSha256: previousSha256,
    );
    if (entrySha256 == null) return null;
    await _writeManifest(
      manifestPath,
      site: site,
      runtime: 'node-tvbox',
      entry: 'spider.js',
      entrySha256: entrySha256,
    );
    return registry.register(manifestPath);
  }

  /// `.py` 直连站点：下载物先落 `loader.py`，再按内容决定要不要包 CatVod 壳。
  ///
  /// 只有包壳时才写 `loader.json`：它是分发层的目录标记（`spider_registry.dart`
  /// 的 `isCatVodShell` 见到它就改挑「带 requests/Crypto/lxml」的解释器），给
  /// 不包壳的站点写它，等于把一个本来能跑的解释器换成要求依赖的那个。
  /// 判定规则与理由见 [looksLikeCatVodShell]。
  Future<LocalSpider?> _materializePy(
    Site site,
    Uri uri,
    Directory dir,
    String manifestPath,
  ) async {
    final loaderFile = File(p.join(dir.path, 'loader.py'));
    final metaFile = File(p.join(dir.path, 'loader.json'));
    final entryPath = p.join(dir.path, _catVodEntryName);

    // 复用判定：`loader.py` 的哈希对上「上次写下的任一哈希」就不再下载。
    // - 包过壳的目录记在 `loader.json` 的 `loaderSha256`；
    // - 没包壳的目录记在 manifest 的 `entrySha256`（下载物就是入口本体）；
    // - 升级前的旧目录（下载物直接落在 `spider.py`、没有 `loader.py`）两者都对
    //   不上，只多下载这一次。
    final metaSha256 = _nonEmpty((await _readJson(metaFile))['loaderSha256']);
    final manifestSha256 = await _recordedEntrySha256(manifestPath);
    final existingSha256 = await _fileSha256(loaderFile);
    final reusable = existingSha256 != null &&
        (existingSha256 == metaSha256 || existingSha256 == manifestSha256);

    final List<int> bytes;
    if (reusable) {
      bytes = await loaderFile.readAsBytes();
    } else {
      final downloaded = await _download(uri);
      if (downloaded == null) return null;
      await loaderFile.writeAsBytes(downloaded, flush: true);
      bytes = downloaded;
    }
    final loaderSha256 = sha256.convert(bytes).toString();

    if (!looksLikeCatVodShell(utf8.decode(bytes, allowMalformed: true))) {
      // 原生 WebHTV 蜘蛛：下载物就是入口，行为与改造前完全一致。
      await File(entryPath).writeAsBytes(bytes, flush: true);
      if (await metaFile.exists()) await metaFile.delete();
      await _writeManifest(
        manifestPath,
        site: site,
        runtime: 'python',
        entry: _catVodEntryName,
        entrySha256: loaderSha256,
      );
      return registry.register(manifestPath);
    }

    await metaFile.writeAsString(
      jsonEncode({'loaderUrl': uri.toString(), 'loaderSha256': loaderSha256}),
      flush: true,
    );
    await _writeShellEntry(entryPath);
    await _writeManifest(
      manifestPath,
      site: site,
      runtime: 'python-catvod',
      entry: _catVodEntryName,
      entrySha256: sha256.convert(utf8.encode(_catVodEntry)).toString(),
    );
    return registry.register(manifestPath);
  }

  /// 保证 [path] 是 [uri] 的最新内容，返回其 SHA-256；下载失败返回 null。
  ///
  /// 文件已存在且哈希等于 [recordedSha256]（本注册器上次写下的值）时不重下。
  Future<String?> _syncEntry({
    required Uri uri,
    required String path,
    required String? recordedSha256,
  }) async {
    final file = File(path);
    final existing = await _fileSha256(file);
    if (existing != null && existing == recordedSha256) return existing;
    final bytes = await _download(uri);
    if (bytes == null) return null;
    await file.writeAsBytes(bytes, flush: true);
    return sha256.convert(bytes).toString();
  }

  /// 读 manifest 里记录的入口哈希（`hashes.entrySha256`，见 `toJson`）。
  Future<String?> _recordedEntrySha256(String manifestPath) async {
    final json = await _readJson(File(manifestPath));
    if (json.isEmpty) return null;
    return _nonEmpty(SpiderManifest.fromJson(json).entrySha256);
  }

  Future<String?> _fileSha256(File file) async {
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return null;
    return sha256.convert(bytes).toString();
  }

  /// 写 CatVod 壳入口；内容一致时不重写。
  Future<void> _writeShellEntry(String entryPath) async {
    final entry = File(entryPath);
    if (await entry.exists()) {
      // 上一轮可能是没包壳的原始 py 字节（不保证是合法 UTF-8），用容错解码比对，
      // 别为了一次比较把整站判失败。
      final existing = utf8.decode(
        await entry.readAsBytes(),
        allowMalformed: true,
      );
      if (existing == _catVodEntry) return;
    }
    await entry.writeAsString(_catVodEntry, flush: true);
  }

  Future<void> _writeManifest(
    String manifestPath, {
    required Site site,
    required String runtime,
    required String entry,
    required String entrySha256,
  }) async {
    final manifest = SpiderManifest(
      key: site.key,
      name: site.name,
      runtime: runtime,
      entry: entry,
      capabilities: const ['home', 'category', 'detail', 'search', 'play'],
      entrySha256: entrySha256,
    );
    await File(manifestPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
      flush: true,
    );
  }

  /// CatVod 壳（api 只写壳名、真正地址在 ext.loader）。
  ///
  /// 目录键必须带上站点 key：同一份配置里几十个站点的 api 完全一样（如
  /// `csp_PyProxy`），只用 api 做键会互相覆盖。
  Future<LocalSpider?> _materializeCatVod(Site site) async {
    final loaderUrl = catVodLoaderUrl(site);
    if (loaderUrl == null) return null;
    final uri = Uri.tryParse(loaderUrl);
    if (uri == null) return null;

    final digest = sha256
        .convert(utf8.encode('${site.key}\n$loaderUrl'))
        .toString();
    final dir = Directory(p.join(root, 'direct', digest.substring(0, 16)));
    await dir.create(recursive: true);

    final loaderPath = p.join(dir.path, 'loader.py');
    final metaPath = p.join(dir.path, 'loader.json');
    final entryPath = p.join(dir.path, _catVodEntryName);
    final manifestPath = p.join(dir.path, 'manifest.json');

    final loaderFile = File(loaderPath);
    String? loaderHash;
    if (await loaderFile.exists()) {
      final existing = await loaderFile.readAsBytes();
      if (existing.isNotEmpty) {
        loaderHash = sha256.convert(existing).toString();
      }
    }
    String? recordedHash;
    final metaFile = File(metaPath);
    if (await metaFile.exists()) {
      try {
        final meta = jsonDecode(await metaFile.readAsString());
        if (meta is Map) recordedHash = meta['loaderSha256'] as String?;
      } catch (_) {
        recordedHash = null;
      }
    }
    if (loaderHash == null || loaderHash != recordedHash) {
      final bytes = await _download(uri);
      if (bytes == null) return null;
      await loaderFile.writeAsBytes(bytes, flush: true);
      loaderHash = sha256.convert(bytes).toString();
    }
    await metaFile.writeAsString(
      jsonEncode({'loaderUrl': loaderUrl, 'loaderSha256': loaderHash}),
      flush: true,
    );

    final entry = File(entryPath);
    if (!await entry.exists() || await entry.readAsString() != _catVodEntry) {
      await entry.writeAsString(_catVodEntry, flush: true);
    }

    final hash = sha256.convert(utf8.encode(_catVodEntry)).toString();
    final manifest = SpiderManifest(
      key: site.key,
      name: site.name,
      runtime: 'python-catvod',
      entry: _catVodEntryName,
      capabilities: const ['home', 'category', 'detail', 'search', 'play'],
      entrySha256: hash,
    );
    await File(manifestPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
      flush: true,
    );
    return registry.register(manifestPath);
  }

  Future<List<int>?> _download(Uri uri) async {
    try {
      final response = await _client.get(uri).timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        log?.warning(
          '直连站源下载失败 HTTP ${response.statusCode} url=${redactUrl(uri.toString())}',
          scope: 'spider',
        );
        return null;
      }
      if (response.bodyBytes.length > maxBytes) {
        log?.warning(
          '直连站源超过上限 ${response.bodyBytes.length}>$maxBytes url=${redactUrl(uri.toString())}',
          scope: 'spider',
        );
        return null;
      }
      return response.bodyBytes;
    } catch (error) {
      log?.warning(
        '直连站源下载异常 url=${redactUrl(uri.toString())} $error',
        scope: 'spider',
      );
      return null;
    }
  }
}

enum DirectSpiderKind { js, py, catVod }

/// CatVod 壳入口文件名（下载的原始蜘蛛是 loader.py，这个是生成的适配入口）。
const String _catVodEntryName = 'spider.py';

/// 生成的 CatVod 壳入口：把下载来的 loader.py 包成宿主 `create_spider` 契约。
///
/// `root` 取本文件所在目录，避免依赖 sidecar 的工作目录。
const String _catVodEntry = '''
"""由 WebHTV PC 自动生成，请勿手改（重新导入站点时会覆盖）。"""

from pathlib import Path

from webhtv_catvod import create_catvod_spider


def create_spider(manifest=None):
    return create_catvod_spider(
        manifest,
        entry="loader.py",
        root=str(Path(__file__).resolve().parent),
    )
''';

/// [catVodShellEntrySource] 的对外只读副本。
///
/// 本地文件夹导入（`local_source_import.dart`）遇到 CatVod 壳时也要生成同一个
/// 壳入口；共用一份模板，避免两处模板漂移导致「远端导入能跑、本地导入不能跑」。
const String catVodShellEntrySource = _catVodEntry;

/// 从 `ext` 里取 CatVod 壳地址（`ext.loader`）。
///
/// 安卓生态里这类站点的 `api` 只是壳名（如 `csp_PyProxy`），真正的 Python
/// 蜘蛛地址在 `ext.loader`。`ext` 可能是对象，也可能是 JSON 字符串，还可能
/// 是 Base64 过的 JSON——三种都认。取不到、或不是 http(s) 时返回 null。
String? catVodLoaderUrl(Site site) {
  final ext = site.ext;
  if (ext == null) return null;
  Object? decoded = ext;
  if (ext is String) {
    final text = ext.trim();
    if (text.isEmpty) return null;
    decoded = _tryJson(text) ?? _tryJson(_tryBase64(text) ?? '');
  }
  if (decoded is! Map) return null;
  final loader = decoded['loader'];
  if (loader is! String) return null;
  final url = loader.trim();
  if (url.isEmpty) return null;
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return url;
}

/// 读一个 JSON 对象；文件不存在、解析失败或内容不是对象时返回空表。
Future<Map<String, Object?>> _readJson(File file) async {
  if (!await file.exists()) return const <String, Object?>{};
  try {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is Map<String, Object?>) return decoded;
  } catch (_) {
    // 半写坏的文件当作没有记录：最多多下载一次。
  }
  return const <String, Object?>{};
}

/// 只接受非空字符串，其余（null / 空串 / 非字符串）统一返回 null。
String? _nonEmpty(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

/// CatVod 语义方法名（`webhtv_catvod.py` 的 `SHELL_TO_CATVOD` 右列）。
final RegExp _catVodMethodPattern = RegExp(
  r'def\s+(homeContent|homeVideoContent|categoryContent|detailContent'
  r'|searchContent|playerContent)\s*\(',
);

/// 判断下载来的 `.py` 是不是 CatVod 壳（**只做文本探测，绝不执行**）。
///
/// 为什么不无条件包壳：两套 ABI 共用 `Spider` 这个名字，方法名却完全不同——
/// WebHTV 宿主按 `home`/`category`/`search` 调用（`host.py` 的 `build_spider`
/// 只认 `create_spider(manifest)` 或 `Spider` 类），CatVod 壳写的是
/// `homeContent`/`categoryContent`/`searchContent`。而
/// `webhtv_catvod.create_catvod_spider` 只会 `getattr(module, "Spider")`，
/// 拿不到就 `raise ValueError(f"CatVod 壳未导出 Spider 类：{entry_path.name}")`
/// （`sidecars/spider-host-python/webhtv_catvod.py:334-336`），**没有**回退到
/// `create_spider` 的分支。所以包壳并不幂等：把 WebHTV 风格的 py 源包起来，
/// `CatVodSpider` 会去找 `homeContent` 而目标只有 `home`，站点直接不可用。
///
/// 因此按内容判断，三条同时成立才包壳：
/// 1. 定义了至少一个 `*Content` CatVod 方法（壳的语义面）；
/// 2. 有 `class Spider`（`create_catvod_spider` 需要它）；
/// 3. 没有导出 `create_spider`（那是 WebHTV 宿主原生 ABI，不需要壳）。
///
/// 实测样例：订阅里 91 个 py 站点指向的 `Atvp.py` 三条全中——`class
/// Spider(HostSpider)`、`def homeContent` 等六个 `*Content` 方法、无
/// `create_spider`，且模块顶层 `import requests` / `Crypto` / `lxml`，正需要
/// 包壳后才会挑中带依赖的解释器。
bool looksLikeCatVodShell(String source) {
  if (source.contains('create_spider')) return false;
  if (!source.contains('class Spider')) return false;
  return _catVodMethodPattern.hasMatch(source);
}

Object? _tryJson(String text) {
  try {
    return jsonDecode(text);
  } catch (_) {
    return null;
  }
}

String? _tryBase64(String text) {
  try {
    return utf8.decode(base64.decode(text));
  } catch (_) {
    return null;
  }
}

/// 判定站点形态；非受支持形态返回 null。
///
/// 顺序即优先级：显式 `.js`/`.py` 后缀 > CatVod 壳（`ext.loader`）。
DirectSpiderKind? directSpiderKind(Site site) {
  if (site.type != 3) return null;
  final api = site.api.trim().toLowerCase();
  if (api.isEmpty) return null;
  if (api.endsWith('.js') || api.contains('.js?')) return DirectSpiderKind.js;
  if (api.endsWith('.py') || api.contains('.py?')) return DirectSpiderKind.py;
  if (catVodLoaderUrl(site) != null) return DirectSpiderKind.catVod;
  return null;
}
