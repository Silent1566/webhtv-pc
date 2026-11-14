import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../core/karaoke/karaoke.dart';
import '../../core/karaoke/midi_parser.dart';
import 'track_providers.dart';
import 'track_transport.dart';

/// 媒体身份：轨与当前媒体绑定，换媒体不得串轨/串分。
class KaraokeMedia {
  const KaraokeMedia({
    required this.key,
    required this.url,
    required this.title,
    required this.artist,
    required this.durationMs,
    this.headers = const {},
  });
  final String key, url, title, artist;
  final int durationMs;
  final Map<String, String> headers;
  bool get isEmpty =>
      key.isEmpty && url.isEmpty && title.isEmpty && artist.isEmpty;
  String get keyword =>
      title.trim().isNotEmpty ? stripExtension(title) : stripExtension(key);
  KaraokeMedia copyWith({
    String? key,
    String? url,
    String? title,
    String? artist,
    int? durationMs,
  }) => KaraokeMedia(
    key: key ?? this.key,
    url: url ?? this.url,
    title: title ?? this.title,
    artist: artist ?? this.artist,
    durationMs: durationMs ?? this.durationMs,
    headers: headers,
  );
  String get legacySignature =>
      md5.convert(utf8.encode('$key|$url|$durationMs')).toString();
}

class KaraokeUserDataException implements Exception {
  const KaraokeUserDataException(
    this.message, {
    this.originalDataRestored = true,
    this.recoveryDirectory,
  });
  final String message;
  final bool originalDataRestored;
  final String? recoveryDirectory;
  @override
  String toString() => message;
}

class KaraokeImportResult {
  const KaraokeImportResult({
    required this.success,
    this.track,
    this.source = '',
    this.error = '',
  });
  factory KaraokeImportResult.ok(KaraokeTrack track, String source) =>
      KaraokeImportResult(success: true, track: track, source: source);
  factory KaraokeImportResult.fail(String error) =>
      KaraokeImportResult(success: false, error: error);
  final bool success;
  final KaraokeTrack? track;
  final String source, error;
}

/// 评分轨仓库：生成轨/用户导入/远程导入的持久化、检索、备份导出导入与缓存重建。
///
/// 目录约定（`<root>/tracks`）：
/// - `<sig>.txt` 用户导入或远程导入的正式轨
/// - `<sig>.user.txt` 用户数据（备份必须带走）
/// - `<sig>.generated-pitch.txt` BasicPitch 生成轨（缓存，可重建）
/// - `<sig>.generated.txt` 兜底生成轨（缓存，可重建）
class KaraokeTrackRepository {
  KaraokeTrackRepository(
    this.dataDirectory, {
    KaraokeTransport? transport,
    Directory? cacheDirectory,
    List<KaraokeTrackProvider>? providers,
  }) : transport = transport ?? HttpKaraokeTransport(),
       cacheDirectory = cacheDirectory ?? dataDirectory,
       providers =
           providers ??
           const [
             KaraokeGithubProvider(),
             KaraokeUsdbProvider(),
             KaraokeUltrastarEsProvider(),
           ];
  static const int maxRemoteBytes = 512 * 1024;
  static const int maxTrackBytes = 512 * 1024;
  static const int maxMidiBytes = 2 * 1024 * 1024;
  static const Duration searchCacheTtl = Duration(minutes: 10);

  final Directory dataDirectory;
  final Directory cacheDirectory;
  final KaraokeTransport transport;
  final List<KaraokeTrackProvider> providers;
  final Map<String, (DateTime, List<KaraokeSearchResult>)> _searchCache = {};
  /// 失效令牌：只在用户显式清除/替换/清搜索缓存时递增，用于作废在途请求。
  int _generation = 0;

  /// 写入计数：每次成功落盘递增，只用于 load 判断扫描期间是否发生过写入。
  ///
  /// 与 [_generation] 分开是必须的：以前成功写入也递增失效令牌，导致并发
  /// 无关操作被误判为「过期」——`importUrl(a)` 与 `importUrl(b)` 并发时第二个
  /// 会假取消，搜索期间的任意成功写入会让搜索结果被静默丢弃。
  int _writes = 0;
  final _requests = <KaraokeCancellation>{};
  Future<void> _mutation = Future.value();
  Future<T> _serial<T>(Future<T> Function() operation) {
    final next = _mutation.then((_) => operation());
    _mutation = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  void _invalidatePending() {
    _generation++;
    for (final token in _requests.toList()) token.cancel();
  }

  KaraokeCancellation _requestToken(KaraokeCancellation? external) {
    final token = KaraokeCancellation();
    if (external?.isCancelled ?? false) token.cancel();
    external?.whenCancelled.then((_) => token.cancel());
    _requests.add(token);
    return token;
  }

  Directory get trackDirectory =>
      Directory('${dataDirectory.path}${Platform.pathSeparator}tracks');
  Directory get cacheTrackDirectory =>
      Directory('${cacheDirectory.path}${Platform.pathSeparator}tracks');

  /// 缓存失效令牌：每次 clearCache/导入都自增，过期结果不得再应用。
  int get generation => _generation;

  String signatureOf(KaraokeMedia media) {
    final name = normalizeSearchText(stripExtension(media.title));
    final singer = normalizeSearchText(media.artist);
    if (name.isEmpty && singer.isEmpty)
      return media.key.isEmpty
          ? media.legacySignature
          : md5.convert(utf8.encode('karaoke-v2|key|${media.key}')).toString();
    return md5.convert(utf8.encode('karaoke-v2|meta|$name|$singer')).toString();
  }

  File _primary(String signature) =>
      File('${trackDirectory.path}${Platform.pathSeparator}$signature.txt');
  File _user(String signature) => File(
    '${trackDirectory.path}${Platform.pathSeparator}$signature.user.txt',
  );
  File _generated(String signature) => File(
    '${cacheTrackDirectory.path}${Platform.pathSeparator}$signature.generated.txt',
  );
  File _generatedPitch(String signature) => File(
    '${cacheTrackDirectory.path}${Platform.pathSeparator}$signature.generated-pitch.txt',
  );

  Future<KaraokeTrack?> load(KaraokeMedia media) async {
    // 失效令牌看显式清除，写入计数看扫描期间是否发生过落盘——两者必须分开。
    final epoch = _generation;
    final epochVersion = _writes;
    final signatures = [signatureOf(media), media.legacySignature].toSet();
    for (final signature in signatures) {
      for (final file in [_primary(signature), _user(signature)]) {
        final track = await _readTrack(file);
        if (track != null) return track;
      }
    }
    final local = _localMediaFile(media.url);
    if (local != null && await local.exists()) {
      final bases = {
        stripExtension(local.uri.pathSegments.last),
        stripExtension(media.title),
      };
      for (final base in bases) {
        if (base.isEmpty ||
            base.contains('/') ||
            base.contains('\\') ||
            base == '.' ||
            base == '..')
          continue;
        for (final suffix in [
          '.ultrastar.txt',
          '.karaoke.txt',
          '.usdx.txt',
          '.txt',
        ]) {
          final parsed = await _readTrack(
            File('${local.parent.path}${Platform.pathSeparator}$base$suffix'),
          );
          if (parsed != null) return parsed;
        }
      }
    }
    for (final signature in signatures) {
      for (final file in [_generatedPitch(signature), _generated(signature)]) {
        final track = await _readTrack(file);
        if (track != null) return track;
      }
    }
    KaraokeTrack? best;
    File? bestFile;
    var bestScore = 79;
    DateTime? bestModified;
    for (final dir in {trackDirectory.path, cacheTrackDirectory.path}) {
      final directory = Directory(dir);
      if (!await directory.exists()) continue;
      await for (final entry in directory.list(followLinks: false)) {
        if (entry is! File || !entry.path.endsWith('.txt')) continue;
        final track = await _readTrack(entry);
        if (track == null) continue;
        final score = _matchScore(media, track);
        final modified = await entry.lastModified();
        if (score > bestScore ||
            score == bestScore &&
                score >= 80 &&
                (bestModified == null || modified.isAfter(bestModified))) {
          best = track;
          bestFile = entry;
          bestScore = score;
          bestModified = modified;
        }
      }
    }
    if (best != null && bestFile != null && epochVersion == _writes) {
      final signature = signatureOf(media);
      final target = bestFile.path.endsWith('.generated-pitch.txt')
          ? _generatedPitch(signature)
          : bestFile.path.endsWith('.generated.txt')
          ? _generated(signature)
          : _primary(signature);
      try {
        await _writeTrack(
          target,
          'migrated',
          await bestFile.readAsString(),
          expectedGeneration: epoch,
        );
      } catch (_) {}
    }
    return best;
  }

  File? _localMediaFile(String url) {
    if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(url)) return File(url);
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme.isEmpty)
      return url.isEmpty ? null : File(url);
    if (uri.scheme == 'file') {
      try {
        return File.fromUri(uri);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  int _matchScore(KaraokeMedia media, KaraokeTrack track) {
    final title = normalizeSearchText(stripExtension(media.title)),
        artist = normalizeSearchText(media.artist);
    final t = normalizeSearchText(stripExtension(track.title)),
        a = normalizeSearchText(track.artist);
    bool related(String x, String y) =>
        x.isNotEmpty &&
        y.isNotEmpty &&
        (x == y || x.contains(y) || y.contains(x));
    return (related(title, t) ? 60 : 0) +
        (related(artist, a) ? 45 : 0) +
        (related(title, a) ? 40 : 0) +
        (related(artist, t) ? 25 : 0) +
        (related(artist + title, a + t) ? 30 : 0);
  }

  Future<KaraokeTrack?> _readTrack(File file) async {
    try {
      if (!await file.exists() || await file.length() > maxTrackBytes)
        return null;
      final text = utf8.decode(await file.readAsBytes(), allowMalformed: false);
      if (!UltraStarParser.looksLikeUltraStar(text)) return null;
      final track = UltraStarParser.parseStrict(text);
      return track.hasScoredNotes ? track : null;
    } catch (_) {
      return null;
    }
  }

  Future<KaraokeImportResult> importText(
    KaraokeMedia media,
    String name,
    String text,
  ) async {
    final signature = signatureOf(media);
    return _writeTrack(_primary(signature), name, text);
  }

  Future<KaraokeImportResult> _writeTrack(
    File target,
    String name,
    String text, {
    int? expectedGeneration,
    KaraokeCancellation? cancellation,
  }) => _serial(() async {
    void checkCurrent() {
      cancellation?.throwIfCancelled();
      if (expectedGeneration != null && expectedGeneration != _generation)
        throw const KaraokeCancelled();
    }

    checkCurrent();
    if (text.trim().isEmpty) return KaraokeImportResult.fail('empty track');
    if (utf8.encode(text).length > maxTrackBytes)
      return KaraokeImportResult.fail('track too large');
    if (!UltraStarParser.looksLikeUltraStar(text))
      return KaraokeImportResult.fail('not ultrastar');
    KaraokeTrack track;
    try {
      track = UltraStarParser.parseStrict(text);
    } catch (_) {
      return KaraokeImportResult.fail('invalid track numbers');
    }
    if (!track.hasScoredNotes)
      return KaraokeImportResult.fail('no scored notes');
    await target.parent.create(recursive: true);
    checkCurrent();
    final temporary = File('${target.path}.tmp');
    try {
      await temporary.writeAsBytes(
        utf8.encode(text.replaceAll('\r\n', '\n')),
        flush: true,
      );
      checkCurrent();
      await temporary.rename(target.path);
      _writes++;
      return KaraokeImportResult.ok(track, name);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  });
  Future<KaraokeImportResult> importFile(
    KaraokeMedia media,
    String name,
    List<int> bytes,
  ) async {
    if (bytes.isEmpty) return KaraokeImportResult.fail('empty file');
    if (bytes.length > maxMidiBytes)
      return KaraokeImportResult.fail('file too large');
    try {
      final text = MidiKaraokeParser.looksLikeMidi(bytes)
          ? MidiKaraokeParser.toUltraStar(name, bytes)
          : utf8.decode(bytes, allowMalformed: false);
      return await importText(media, name, text);
    } catch (error) {
      return KaraokeImportResult.fail('$error');
    }
  }

  /// 生成轨（BasicPitch）导入为缓存文件；不覆盖用户正式轨。
  Future<KaraokeImportResult> importGenerated(
    KaraokeMedia media,
    KaraokePitchTrack pitchTrack,
  ) async {
    final target = _generatedPitch(signatureOf(media));
    return _writeTrack(target, 'generated', pitchTrack.text);
  }

  Future<KaraokeImportResult> importUrl(
    KaraokeMedia media,
    Uri uri, {
    KaraokeCancellation? cancellation,
  }) async {
    final epoch = _generation;
    final token = _requestToken(cancellation);
    try {
      final text = await fetchTrackText(uri, cancellation: token, media: media);
      token.throwIfCancelled();
      return await _writeTrack(
        _primary(signatureOf(media)),
        'remote track',
        text,
        expectedGeneration: epoch,
        cancellation: token,
      );
    } on KaraokeCancelled {
      return KaraokeImportResult.fail('cancelled');
    } on KaraokeTrackException catch (e) {
      return KaraokeImportResult.fail(e.message);
    } catch (_) {
      return KaraokeImportResult.fail('track import failed');
    } finally {
      _requests.remove(token);
    }
  }

  Future<String> fetchTrackText(
    Uri input, {
    KaraokeCancellation? cancellation,
    KaraokeMedia? media,
  }) async {
    final value = input.toString();
    final marker = value.indexOf('@Cookie=');
    var cookie = marker < 0
        ? ''
        : Uri.decodeComponent(value.substring(marker + 8));
    var uri = Uri.parse(marker < 0 ? value : value.substring(0, marker));
    final namedId = KaraokeUsdbProvider.parseUsdbId(uri.toString());
    if (namedId.isNotEmpty && (uri.scheme.isEmpty || uri.scheme == 'usdb'))
      uri = Uri.parse('https://usdb.animux.de/?link=detail&id=$namedId');
    if (uri.host == 'github.com' &&
        uri.pathSegments.length >= 5 &&
        uri.pathSegments[2] == 'blob') {
      uri = Uri(
        scheme: 'https',
        host: 'raw.githubusercontent.com',
        pathSegments: [
          uri.pathSegments[0],
          uri.pathSegments[1],
          ...uri.pathSegments.skip(3),
        ],
      );
    } else if (uri.path.contains('/-/blob/'))
      uri = uri.replace(path: uri.path.replaceFirst('/-/blob/', '/-/raw/'));
    if (cookie.isEmpty &&
        media != null &&
        Uri.tryParse(media.url)?.host == uri.host)
      cookie = media.headers['Cookie'] ?? media.headers['cookie'] ?? '';
    if (cookie.contains('\r') || cookie.contains('\n'))
      throw const KaraokeTrackException('invalid authentication');
    final remote = CheckedKaraokeTransport(
      transport,
      cancellation: cancellation,
      cookie: cookie,
      cookieHost: uri.host,
      allowTrackBody: true,
    );
    final id = uri.host == 'usdb.animux.de'
        ? KaraokeUsdbProvider.parseUsdbId(uri.toString())
        : '';
    if (id.isNotEmpty) {
      final detail = (await remote.get(
        Uri.parse('https://usdb.animux.de/?link=detail&id=$id'),
      )).checkedText();
      final notes = (await remote.get(
        Uri.parse(
          'https://usdb.animux.de/view.php?id=$id&database1=deluxe_songs',
        ),
      )).checkedText();
      return KaraokeUsdbProvider.buildTrackText(detail, notes);
    }
    return (await remote.get(uri)).checkedText(allowTrackBody: true);
  }

  Future<List<KaraokeSearchResult>> search(
    String keyword, {
    KaraokeCancellation? cancellation,
  }) async {
    final query = keyword.trim();
    if (query.length < 2) return const [];
    final key = normalizeSearchText(query);
    final cached = _searchCache[key];
    if (cached != null && DateTime.now().difference(cached.$1) < searchCacheTtl)
      return cached.$2;
    final epoch = _generation;
    final token = _requestToken(cancellation);
    final results = <KaraokeSearchResult>[];
    var failed = false;
    try {
      final remote = CheckedKaraokeTransport(transport, cancellation: token);
      for (final provider in providers) {
        token.throwIfCancelled();
        try {
          final found = await provider.search(query, remote);
          token.throwIfCancelled();
          if (epoch != _generation) throw const KaraokeCancelled();
          for (final result in found) {
            final uri = Uri.tryParse(result.url);
            if (uri == null ||
                !['http', 'https'].contains(uri.scheme) ||
                result.title.isEmpty ||
                results.any((r) => r.url == result.url))
              continue;
            results.add(result);
          }
        } on KaraokeCancelled {
          rethrow;
        } catch (_) {
          failed = true;
        }
      }
      if (epoch != _generation) throw const KaraokeCancelled();
      if (!failed)
        _searchCache[key] = (DateTime.now(), List.unmodifiable(results));
      return results;
    } on KaraokeCancelled {
      return const [];
    } finally {
      _requests.remove(token);
    }
  }

  void clearSearchCache() {
    _invalidatePending();
    _searchCache.clear();
  }

  Future<bool> clearBinding(KaraokeMedia media) {
    _invalidatePending();
    return _serial(() => _clearBinding(media));
  }

  Future<bool> _clearBinding(KaraokeMedia media) async {
    var deleted = false;
    for (final signature in {signatureOf(media), media.legacySignature}) {
      for (final file in [
        _primary(signature),
        _user(signature),
        _generatedPitch(signature),
        _generated(signature),
      ]) {
        if (await file.exists()) {
          await file.delete();
          deleted = true;
        }
      }
    }
    File? matching;
    var bestScore = 79;
    DateTime? newest;
    for (final path in {trackDirectory.path, cacheTrackDirectory.path}) {
      final dir = Directory(path);
      if (!await dir.exists()) continue;
      await for (final entry in dir.list(followLinks: false)) {
        if (entry is! File || !entry.path.endsWith('.txt')) continue;
        final track = await _readTrack(entry);
        if (track == null) continue;
        final score = _matchScore(media, track),
            modified = await entry.lastModified();
        if (score > bestScore ||
            score == bestScore &&
                score >= 80 &&
                (newest == null || modified.isAfter(newest))) {
          matching = entry;
          bestScore = score;
          newest = modified;
        }
      }
    }
    if (matching != null) {
      await matching.delete();
      deleted = true;
    }
    _writes++;
    return deleted;
  }

  /// 只清可重建缓存，用户数据与正式轨保留。
  Future<bool> clearCache() {
    _invalidatePending();
    return _serial(_clearCache);
  }

  Future<bool> _clearCache() async {
    var success = true;
    for (final directory in {trackDirectory.path, cacheTrackDirectory.path}) {
      final dir = Directory(directory);
      if (!await dir.exists()) continue;
      await for (final entry in dir.list()) {
        if (entry is! File) continue;
        final name = entry.path.split(Platform.pathSeparator).last;
        if (!name.endsWith('.generated.txt') &&
            !name.endsWith('.generated-pitch.txt'))
          continue;
        try {
          await entry.delete();
        } catch (_) {
          success = false;
        }
      }
    }
    _writes++;
    clearSearchCache();
    return success;
  }

  static final _userFileName = RegExp(r'^[a-f0-9]{32}(?:\.user)?\.txt$');

  static bool _isUserFile(String name) => _userFileName.hasMatch(name);

  String _validateUserTrack(String name, List<int> bytes) {
    if (!_isUserFile(name))
      throw KaraokeUserDataException('unsafe user track name: $name');
    if (bytes.isEmpty || bytes.length > maxTrackBytes)
      throw KaraokeUserDataException('invalid track size: $name');
    if (bytes.any((byte) => byte < 0 || byte > 255))
      throw KaraokeUserDataException('invalid byte value: $name');
    String text;
    try {
      text = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw KaraokeUserDataException('invalid UTF8: $name');
    }
    try {
      if (!UltraStarParser.looksLikeUltraStar(text) ||
          !UltraStarParser.parseStrict(text).hasScoredNotes) {
        throw KaraokeUserDataException('invalid scoring track: $name');
      }
    } catch (error) {
      if (error is KaraokeUserDataException) rethrow;
      throw KaraokeUserDataException('invalid scoring track: $name ($error)');
    }
    return text;
  }

  /// 用户正式轨清单；生成缓存不属于用户备份集合。
  Future<List<String>> listUserData() async {
    if (!await trackDirectory.exists()) return const [];
    final names = <String>[];
    await for (final entry in trackDirectory.list(followLinks: false)) {
      if (entry is File) {
        final name = entry.path.split(Platform.pathSeparator).last;
        if (_isUserFile(name)) names.add(name);
      }
    }
    return names..sort();
  }

  /// 备份导出保留用户轨原始字节，不过滤坏轨以免回滚前静默丢失用户数据。
  Future<Map<String, List<int>>> exportUserData() async {
    final output = <String, List<int>>{};
    for (final name in await listUserData()) {
      final file = File('${trackDirectory.path}${Platform.pathSeparator}$name');
      output[name] = await file.readAsBytes();
    }
    return output;
  }

  /// merge 保留旧语义；replace 完整验证后精确替换，失败抛类型化错误。
  Future<({int restored, int skipped})> importUserData(
    Map<String, List<int>> data, {
    bool replace = false,
  }) async {
    if (replace) {
      for (final entry in data.entries)
        _validateUserTrack(entry.key, entry.value);
      _invalidatePending();
      return _serial(() => _replaceUserData(data));
    }
    var restored = 0;
    var skipped = 0;
    for (final entry in data.entries) {
      try {
        final text = _validateUserTrack(entry.key, entry.value);
        final target = File(
          '${trackDirectory.path}${Platform.pathSeparator}${entry.key}',
        );
        await _writeTrack(target, entry.key, text);
        restored++;
      } on KaraokeUserDataException {
        skipped++;
      }
    }
    return (restored: restored, skipped: skipped);
  }

  Future<({int restored, int skipped})> _replaceUserData(
    Map<String, List<int>> data,
  ) async {
    final validated = <String, List<int>>{};
    for (final entry in data.entries) {
      _validateUserTrack(entry.key, entry.value);
      validated[entry.key] = List<int>.of(entry.value);
    }
    // 暂存含未变的缓存；两次同卷 rename 交换，提交失败恢复原目录。
    Directory? transaction;
    Directory? previous;
    var movedOriginal = false;
    var originalDataRestored = true;
    try {
      await dataDirectory.create(recursive: true);
      transaction = await dataDirectory.createTemp('.karaoke-restore-');
      final staged = await Directory(
        '${transaction.path}${Platform.pathSeparator}staged',
      ).create();
      previous = Directory(
        '${transaction.path}${Platform.pathSeparator}previous',
      );
      if (await trackDirectory.exists()) {
        await for (final entry in trackDirectory.list(followLinks: false)) {
          final name = entry.path.split(Platform.pathSeparator).last;
          if (entry is! File)
            throw KaraokeUserDataException(
              'unexpected track directory entry: $name',
            );
          if (!_isUserFile(name))
            await entry.copy('${staged.path}${Platform.pathSeparator}$name');
        }
      }
      for (final entry in validated.entries) {
        await File('${staged.path}${Platform.pathSeparator}${entry.key}')
            .writeAsBytes(entry.value, flush: true);
      }
      if (await trackDirectory.exists()) {
        await trackDirectory.rename(previous.path);
        movedOriginal = true;
      }
      try {
        await staged.rename(trackDirectory.path);
      } catch (_) {
        if (movedOriginal) {
          try {
            await previous.rename(trackDirectory.path);
            movedOriginal = false;
          } catch (_) {
            originalDataRestored = false;
          }
        }
        rethrow;
      }
      _writes++;
      movedOriginal = false;
      return (restored: validated.length, skipped: 0);
    } catch (error) {
      throw KaraokeUserDataException(
        'user track replacement failed: $error',
        originalDataRestored: originalDataRestored,
        recoveryDirectory: originalDataRestored ? null : previous?.path,
      );
    } finally {
      if (transaction != null && !movedOriginal) {
        try {
          await transaction.delete(recursive: true);
        } on FileSystemException {
          // 已提交/已回滚；清理失败不反转成功，目录仅残留可清理暂存。
        }
      }
    }
  }

  /// 供 UI 列举：全部绑定轨（不含缓存与备份临时文件）。
  Future<List<String>> listBindings() async {
    if (!await trackDirectory.exists()) return const [];
    final names = <String>[];
    await for (final entry in trackDirectory.list()) {
      if (entry is! File) continue;
      final name = entry.path.split(Platform.pathSeparator).last;
      if (name.endsWith('.txt') && !name.endsWith('.tmp')) names.add(name);
    }
    names.sort();
    return names;
  }
}
