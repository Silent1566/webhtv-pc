/// LUT 预设仓库（docs/phase9/design/01 §6）。
///
/// 三件事：
/// 1. **落盘**——内置预设是 Flutter asset，mpv 的 lut3d 只吃真实文件路径，
///    所以播放前先把它写到 cacheDir/lut 下的 ID.cube（幂等，按字节数复用）；
/// 2. **本地**——用户自己的 .cube 放 dataDir/lut，可导入、可删除；
/// 3. **在线**——从任意直链下载，或经 GitHub 公开 API 搜索后下载。
///
/// 所有落盘都先过 parseCube 再进目录：**不是** 3D .cube 的文件绝不会出现在
/// 列表里，避免用户点了之后才在播放页看到报错。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../core/lut.dart';
import 'app_paths.dart';

/// 仓库层的失败。带 [code] 让界面能区分「限流」和「文件不合法」。
class LutStoreException implements Exception {
  const LutStoreException(this.message, {this.code = 'lut_error'});

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// GitHub 搜索结果里的一个仓库。
class LutRepoHit {
  const LutRepoHit({
    required this.owner,
    required this.repo,
    required this.branch,
    required this.description,
    required this.stars,
  });

  final String owner;
  final String repo;

  /// 默认分支，拼 raw.githubusercontent.com 链接时要用。
  final String branch;
  final String description;
  final int stars;

  String get fullName => '$owner/$repo';

  /// 给界面看的副标题：星标 + 描述（描述截断，避免撑爆一行）。
  String get subtitle {
    final trimmed = description.trim();
    final text = trimmed.isEmpty ? '（无描述）' : trimmed;
    final shown = text.length > 60 ? '${text.substring(0, 60)}…' : text;
    return '\u2605 $stars · $shown';
  }
}

/// LUT 预设仓库。
class LutStore {
  LutStore({required this.paths, http.Client? httpClient, AssetBundle? bundle})
    : _http = httpClient ?? http.Client(),
      _bundle = bundle ?? rootBundle;

  /// GitHub 的未授权额度：核心接口 60 次/小时，搜索 10 次/分钟。
  /// 这里只做「超了就明说」，不排队也不重试——重试只会更快地把额度烧光。
  static const String _githubApi = 'https://api.github.com';
  static const String _userAgent = 'webhtv-pc';

  /// 单个请求的超时。GitHub 与裸链都可能长时间挂起。
  static const Duration _requestTimeout = Duration(seconds: 20);

  final AppPaths paths;
  final http.Client _http;
  final AssetBundle _bundle;

  /// 用户预设目录（dataDir/lut）。
  String get userDirectory => p.join(paths.dataDir, 'lut');

  /// 内置预设落地目录（cacheDir/lut）。被清掉也能按 id 重新生成。
  String get cacheDirectory => p.join(paths.cacheDir, 'lut');

  // ------------------------------------------------------------ 内置预设

  /// 把 [preset] 落成一个 mpv 能读的绝对路径。
  ///
  /// 内置项：rootBundle 读字节 → 写缓存（已存在且字节数相同就直接复用）。
  /// 用户项：只校验存在，不改动文件。
  Future<String> materialize(LutPreset preset) async {
    if (!preset.isBundled) {
      final file = File(preset.path);
      if (!await file.exists()) {
        throw const LutStoreException('LUT 文件已不存在，请重新选择', code: 'lut_missing');
      }
      return file.path;
    }

    final target = File(p.join(cacheDirectory, '${preset.id}.cube'));
    try {
      final data = await _bundle.load(preset.path);
      final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      if (bytes.isEmpty) {
        throw LutStoreException('内置 LUT 资源为空：${preset.path}', code: 'lut_asset_empty');
      }
      if (await target.exists() && await target.length() == bytes.length) {
        return target.path;
      }
      await target.parent.create(recursive: true);
      // 先写临时文件再 rename：中途失败不会留下半截 .cube 被下次误复用。
      final staging = File('${target.path}.tmp');
      await staging.writeAsBytes(bytes, flush: true);
      await staging.rename(target.path);
      return target.path;
    } on LutStoreException {
      rethrow;
    } on FlutterError catch (error) {
      throw LutStoreException(
        '内置 LUT 读取失败：${describeLutError(error)}',
        code: 'lut_asset_missing',
      );
    } catch (error) {
      throw LutStoreException(
        '内置 LUT 落盘失败：${describeLutError(error)}',
        code: 'lut_write_failed',
      );
    }
  }

  // -------------------------------------------------------------- 用户目录

  /// 列出 dataDir/lut 下可用的用户预设（按名字排序）。
  ///
  /// 这里**只读文件头**（前 8 KiB）取 TITLE 与 LUT_3D_SIZE：一个 33³ 的 .cube
  /// 有 3.5 万行，为了列表把每个文件整读一遍会在百兆目录里卡住。
  /// 真正会不会被拒，仍然由应用时的 parseCube 决定。
  Future<List<LutPreset>> listUserPresets() async {
    final dir = Directory(userDirectory);
    if (!await dir.exists()) return const <LutPreset>[];
    final presets = <LutPreset>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      if (!entity.path.toLowerCase().endsWith('.cube')) continue;
      final header = await _readHeader(entity);
      final stem = lutIdFromPath(entity.path);
      presets.add(
        LutPreset(
          id: stem,
          path: entity.path,
          name: header.name.isNotEmpty ? header.name : stem,
          size: header.size,
          source: LutSource.user,
        ),
      );
    }
    presets.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return presets;
  }

  /// 把本地文件 [sourcePath] 导入用户目录。
  ///
  /// 先整读 + parseCube 校验，再落盘——顺序反过来的话，用户会在列表里
  /// 看到一个点开就报错的条目。
  Future<LutPreset> importFile(String sourcePath) async {
    final trimmed = sourcePath.trim();
    final file = File(trimmed);
    if (!await file.exists()) {
      throw const LutStoreException('文件不存在', code: 'lut_missing');
    }
    if (await file.length() > lutFileBytesLimit) {
      throw LutStoreException(
        'LUT 文件超过 ${lutFileBytesLimit >> 20} MiB',
        code: 'lut_too_large',
      );
    }
    return _persistCube(
      await file.readAsBytes(),
      preferredName: lutIdFromPath(trimmed),
      fallbackPath: trimmed,
    );
  }

  /// 从任意 http(s) 直链下载并入库。
  Future<LutPreset> download(String url) async {
    final trimmed = url.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const LutStoreException('只支持 http/https 链接', code: 'lut_bad_url');
    }
    final preferred = lutIdFromPath(uri.path);
    return _persistCube(
      await _fetchBytes(uri),
      preferredName: preferred.isEmpty ? '在线 LUT' : preferred,
      fallbackPath: trimmed,
    );
  }

  /// 删除一个用户预设。内置项拒绝删除（它由安装包管理）。
  Future<void> deleteUserPreset(LutPreset preset) async {
    if (preset.isBundled) {
      throw const LutStoreException('内置预设不能删除', code: 'lut_bundled');
    }
    final file = File(preset.path);
    if (await file.exists()) await file.delete();
  }

  // ---------------------------------------------------------------- 在线搜索

  /// 用 GitHub 公开 API 搜「带 .cube 的仓库」。
  ///
  /// 为什么不是网页搜索：GitHub 的仓库搜索**不需要 token**就能用，返回结构化
  /// JSON，而且能顺着 tree 接口精确列出仓库里的 .cube——比爬网页稳。
  /// 代价是未授权额度只有 60 次/小时，所以结果按 star 排序、只取前 [limit] 个。
  Future<List<LutRepoHit>> searchRepositories(String query, {int limit = 8}) async {
    final keyword = query.trim().isEmpty ? 'LUT' : query.trim();
    final uri = Uri.parse(
      '$_githubApi/search/repositories'
      '?q=${Uri.encodeQueryComponent('$keyword LUT')}'
      '&sort=stars&order=desc&per_page=$limit',
    );
    final body = await _getJson(uri);
    final items = body['items'];
    if (items is! List) return const <LutRepoHit>[];
    final hits = <LutRepoHit>[];
    for (final item in items) {
      if (item is! Map) continue;
      final owner = item['owner'];
      final name = item['name'];
      if (owner is! Map || name is! String) continue;
      final login = owner['login'];
      if (login is! String) continue;
      final branch = item['default_branch'];
      final description = item['description'];
      final stars = item['stargazers_count'];
      hits.add(
        LutRepoHit(
          owner: login,
          repo: name,
          branch: branch is String && branch.trim().isNotEmpty ? branch.trim() : 'main',
          description: description is String ? description : '',
          stars: stars is num ? stars.toInt() : 0,
        ),
      );
    }
    return hits;
  }

  /// 列出仓库里所有 .cube 的相对路径（按路径排序，最多 [limit] 条）。
  Future<List<String>> listCubePaths(LutRepoHit hit, {int limit = 120}) async {
    final uri = Uri.parse(
      '$_githubApi/repos/${hit.owner}/${hit.repo}/git/trees/'
      '${Uri.encodeComponent(hit.branch)}?recursive=1',
    );
    final body = await _getJson(uri);
    final tree = body['tree'];
    if (tree is! List) return const <String>[];
    final paths = <String>[];
    for (final node in tree) {
      if (node is! Map) continue;
      if (node['type'] != 'blob') continue;
      final path = node['path'];
      if (path is! String) continue;
      if (!path.toLowerCase().endsWith('.cube')) continue;
      paths.add(path);
      if (paths.length >= limit) break;
    }
    paths.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return paths;
  }

  /// 从仓库下载一个 .cube 并入库。
  Future<LutPreset> downloadFromRepo(LutRepoHit hit, String path) async {
    final encoded = path.split('/').map(Uri.encodeComponent).join('/');
    final uri = Uri.parse(
      'https://raw.githubusercontent.com/'
      '${hit.owner}/${hit.repo}/${Uri.encodeComponent(hit.branch)}/$encoded',
    );
    final name = lutIdFromPath(path);
    return _persistCube(
      await _fetchBytes(uri),
      preferredName: name.isEmpty ? hit.fullName : name,
      fallbackPath: path,
    );
  }

  // ---------------------------------------------------------------- 内部实现

  /// 校验 + 写入用户目录，返回入库后的预设。
  Future<LutPreset> _persistCube(
    Uint8List bytes, {
    required String preferredName,
    required String fallbackPath,
  }) async {
    if (bytes.isEmpty) {
      throw const LutStoreException('文件为空', code: 'lut_empty');
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    // 不传 displayName：那是「显式改名」的口子，会盖掉文件里的 TITLE。
    // 导入/下载时 TITLE 更可信（它就是作者写的名字），文件名只做兜底。
    final parsed = parseCube(text, path: fallbackPath, source: LutSource.user);
    if (!parsed.ok) {
      throw LutStoreException(
        parsed.error ?? '文件不是有效的 3D .cube',
        code: 'lut_invalid',
      );
    }
    final dir = Directory(userDirectory);
    await dir.create(recursive: true);
    final stem = preferredName.trim().isEmpty
        ? parsed.preset!.name
        : preferredName;
    final safe = _sanitizeName(stem);
    final target = await _uniquePath(p.join(dir.path, '$safe.cube'));
    await File(target).writeAsBytes(bytes, flush: true);
    return LutPreset(
      id: lutIdFromPath(target),
      path: target,
      name: parsed.preset!.name,
      size: parsed.preset!.size,
      source: LutSource.user,
    );
  }

  /// 同名文件不覆盖：film.cube 已存在就写 film (2).cube。
  Future<String> _uniquePath(String candidate) async {
    if (!await File(candidate).exists()) return candidate;
    final dir = p.dirname(candidate);
    final stem = p.basenameWithoutExtension(candidate);
    for (var index = 2; index < 1000; index++) {
      final next = p.join(dir, '$stem ($index).cube');
      if (!await File(next).exists()) return next;
    }
    // 1000 个重名说明目录已经不可信了，宁可覆盖也不死循环。
    return p.join(dir, '$stem (overflow).cube');
  }

  /// 文件名里去掉 Windows 与 POSIX 都不接受的字符。
  String _sanitizeName(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    if (cleaned.isEmpty) return 'lut';
    return cleaned.length > 80 ? cleaned.substring(0, 80) : cleaned;
  }

  /// 读前 8 KiB 取 TITLE / LUT_3D_SIZE；读不到就给空名 + 尺寸 0。
  Future<_CubeHeader> _readHeader(File file) async {
    try {
      final handle = await file.open();
      try {
        final bytes = await handle.read(8192);
        final text = utf8.decode(bytes, allowMalformed: true);
        var name = '';
        var size = 0;
        for (final raw in text.split(RegExp(r'\r?\n'))) {
          final line = raw.trim();
          if (line.isEmpty || line.startsWith('#')) continue;
          final upper = line.toUpperCase();
          if (upper.startsWith('TITLE')) {
            name = _stripQuotes(line.substring(5).trim());
            continue;
          }
          if (upper.startsWith('LUT_3D_SIZE')) {
            final value = int.tryParse(line.substring(11).trim());
            if (value != null && value >= 2 && value <= maxLutSize) size = value;
          }
          if (name.isNotEmpty && size > 0) break;
        }
        return _CubeHeader(name: name, size: size);
      } finally {
        await handle.close();
      }
    } catch (_) {
      return const _CubeHeader(name: '', size: 0);
    }
  }

  String _stripQuotes(String raw) {
    if (raw.length >= 2) {
      final first = raw[0];
      final last = raw[raw.length - 1];
      if ((first == '"' || first == "'") && first == last) {
        return raw.substring(1, raw.length - 1);
      }
    }
    return raw;
  }

  /// JSON GET（GitHub API）。
  Future<Map<String, Object?>> _getJson(Uri uri) async {
    final response = await _send(
      uri,
      headers: const {
        'Accept': 'application/vnd.github+json',
        'User-Agent': _userAgent,
      },
    );
    if (response.statusCode == 403 || response.statusCode == 429) {
      throw const LutStoreException(
        'GitHub 接口已限流（未授权额度 60 次/小时），请稍后再试或改用「从链接导入」',
        code: 'lut_rate_limited',
      );
    }
    if (response.statusCode == 404) {
      throw const LutStoreException('仓库或分支不存在', code: 'lut_not_found');
    }
    if (response.statusCode != 200) {
      throw LutStoreException(
        'GitHub 返回 HTTP ${response.statusCode}',
        code: 'lut_http_${response.statusCode}',
      );
    }
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, Object?>) return decoded;
      if (decoded is Map) return decoded.cast<String, Object?>();
      throw const LutStoreException('GitHub 返回的不是 JSON 对象', code: 'lut_bad_json');
    } on FormatException {
      throw const LutStoreException('GitHub 返回的不是合法 JSON', code: 'lut_bad_json');
    }
  }

  /// 取二进制内容：先看 Content-Length，再按实际字节拦一次。
  Future<Uint8List> _fetchBytes(Uri uri) async {
    final response = await _send(uri, headers: const {'User-Agent': _userAgent});
    if (response.statusCode == 403 || response.statusCode == 429) {
      throw const LutStoreException('下载被拒（可能触发限流），请稍后再试', code: 'lut_rate_limited');
    }
    if (response.statusCode != 200) {
      throw LutStoreException(
        '下载失败：HTTP ${response.statusCode}',
        code: 'lut_http_${response.statusCode}',
      );
    }
    final declared = response.headers['content-length'];
    final declaredLength = declared == null ? null : int.tryParse(declared.trim());
    if (declaredLength != null && declaredLength > lutFileBytesLimit) {
      throw LutStoreException(
        '文件超过 ${lutFileBytesLimit >> 20} MiB，已拒绝下载',
        code: 'lut_too_large',
      );
    }
    if (response.bodyBytes.length > lutFileBytesLimit) {
      throw LutStoreException(
        '文件超过 ${lutFileBytesLimit >> 20} MiB，已拒绝下载',
        code: 'lut_too_large',
      );
    }
    return response.bodyBytes;
  }

  Future<http.Response> _send(Uri uri, {required Map<String, String> headers}) async {
    try {
      return await _http.get(uri, headers: headers).timeout(_requestTimeout);
    } on TimeoutException {
      throw const LutStoreException('网络超时', code: 'lut_timeout');
    } on http.ClientException catch (error) {
      throw LutStoreException('网络错误：${describeLutError(error)}', code: 'lut_network');
    } on SocketException catch (error) {
      throw LutStoreException('网络不可用：${describeLutError(error)}', code: 'lut_network');
    }
  }

  /// 释放内部的 [http.Client]。注入的客户端由调用方负责关闭。
  void dispose() => _http.close();
}

class _CubeHeader {
  const _CubeHeader({required this.name, required this.size});

  final String name;
  final int size;
}
