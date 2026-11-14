/// TMDB 文件缓存与 TTL 判定（`docs/phase4/design/03` §3）。
///
/// 上游对应实现：`TmdbService` 的 `cacheFile` / `readFirstCache` / `writeCache`
/// 与 `<cacheDir>/tmdb/<type>_<md5>.json` 布局。
///
/// 关键契约（`03` §3.3）：
/// - 新鲜命中（`age <= ttl`）直接返回；
/// - 网络失败时回退到**任意陈旧缓存**（不看 TTL）；
/// - 目录不可写时**降级为不缓存**，不抛异常、不影响主流程；
/// - 写缓存失败不影响返回值。
///
/// 年龄判定用**写入时记录的 `__savedAt`** 与可注入的时钟比较，
/// 而不是文件 mtime——后者受文件系统与同步影响，不可靠也不可测。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// 缓存类型 → 键前缀（`03` §3.1）。
abstract final class TmdbCacheType {
  static const String configuration = 'configuration';
  static const String search = 'search';
  static const String detail = 'detail';
  static const String season = 'season';
  static const String episode = 'episode';
  static const String person = 'person';
  static const String videos = 'videos';
  static const String cnSeason = 'cnSeason';
}

/// TTL 常量（`03` §3.1，与上游逐一对齐）。
abstract final class TmdbTtl {
  static const Duration detail = Duration(days: 7);
  static const Duration search = Duration(days: 1);
  static const Duration person = Duration(days: 7);
  static const Duration season = Duration(days: 3);

  /// 详情含未播集信息时的短 TTL（`03` §3.3）。
  static const Duration detailWithNextEpisode = Duration(days: 1);
  static const Duration cnOnAirSeason = Duration(days: 1);
  static const Duration videos = Duration(hours: 6);
  static const Duration videosEmpty = Duration(minutes: 30);

  /// 鉴权失败冷却（`03` §3.4）。
  static const Duration authCooldown = Duration(minutes: 5);
}

/// 写入缓存时使用的内部时间戳字段名。
const String tmdbCacheSavedAtField = '__savedAt';

/// 一次缓存读取的结果，带来源标记供诊断（`03` §8）。
class TmdbCacheHit {
  const TmdbCacheHit({
    required this.payload,
    required this.source,
    required this.age,
  });

  final Map<String, Object?> payload;

  /// `cache`（新鲜命中）或 `stale-cache`（陈旧兜底）。
  final String source;
  final Duration age;

  bool get isStale => source == 'stale-cache';
}

/// TMDB 文件缓存。
///
/// 目录布局：`<root>/tmdb/<type>_<md5(key)>.json`。
class TmdbCache {
  TmdbCache({
    required this.cacheDir,
    this.maxFileBytes = 8 * 1024 * 1024,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// `AppPaths.cacheDir`。为空表示禁用缓存（全部降级为不缓存）。
  final String? cacheDir;

  /// 单文件上限（`03` §6.4）：超过则拒绝写入并记日志。
  final int maxFileBytes;

  final DateTime Function() _clock;

  /// 缓存目录是否可用。目录创建失败时为 `false`，此后所有读写都降级。
  bool? _available;

  /// 最近一次失败原因（诊断用）。
  String? lastError;

  /// 目录路径（`<cacheDir>/tmdb`）。`cacheDir` 为空时返回 `null`。
  String? get directory {
    final root = cacheDir;
    if (root == null || root.isEmpty) return null;
    return '$root${Platform.pathSeparator}tmdb';
  }

  /// 缓存文件路径。目录不可用时返回 `null`。
  String? filePath(String type, String key) {
    final dir = directory;
    if (dir == null) return null;
    final digest = md5.convert(utf8.encode(key)).toString();
    return '$dir${Platform.pathSeparator}${type}_$digest.json';
  }

  /// 确保目录存在。任何失败都返回 `false` 并记 [lastError]（`03` §6.4）。
  bool ensureDirectory() {
    final existing = _available;
    if (existing != null) return existing;
    final dir = directory;
    if (dir == null) {
      _available = false;
      lastError = 'cacheDir 未配置';
      return false;
    }
    try {
      final directoryHandle = Directory(dir);
      if (!directoryHandle.existsSync()) {
        directoryHandle.createSync(recursive: true);
      }
      _available = true;
      return true;
    } catch (error) {
      _available = false;
      lastError = '缓存目录不可写：$error';
      return false;
    }
  }

  /// 读取新鲜缓存（`age <= ttl`）。未命中或目录不可用时返回 `null`。
  TmdbCacheHit? readFresh(String type, String key, Duration ttl) =>
      _read(type, key, ttl);

  /// 读取任意缓存（**不看 TTL**），用于网络失败时的陈旧兜底。
  TmdbCacheHit? readAny(String type, String key) => _read(type, key, null);

  /// 按顺序尝试多个键，返回第一个新鲜命中（`03` §3.2 的回退键）。
  ///
  /// **陈旧命中必须跳过**，否则会绕过网络请求与刷新语义（§3.3）。
  TmdbCacheHit? readFirstFresh(
    String type,
    List<String> keys,
    Duration Function(Map<String, Object?> payload)? ttlOf,
    Duration fallbackTtl,
  ) {
    for (final key in keys) {
      final payload = _readPayload(type, key);
      if (payload == null) continue;
      final hit = _hitFor(payload, ttlOf?.call(payload) ?? fallbackTtl);
      if (hit != null && !hit.isStale) return hit;
    }
    return null;
  }

  /// 按顺序尝试多个键，返回第一个**任意**命中（陈旧兜底）。
  TmdbCacheHit? readFirstAny(String type, List<String> keys) {
    for (final key in keys) {
      final payload = _readPayload(type, key);
      if (payload == null) continue;
      final hit = _hitFor(payload, null);
      if (hit != null) return hit;
    }
    return null;
  }

  /// 写入缓存。失败不影响调用方（`03` §6.4）。
  ///
  /// 返回是否写入成功。
  bool write(String type, String key, Map<String, Object?> payload) {
    if (!ensureDirectory()) return false;
    final path = filePath(type, key);
    if (path == null) return false;
    try {
      final stored = Map<String, Object?>.from(payload)
        ..[tmdbCacheSavedAtField] = _clock().millisecondsSinceEpoch;
      final body = jsonEncode(stored);
      final bytes = utf8.encode(body);
      if (bytes.length > maxFileBytes) {
        lastError = '缓存超过单文件上限（${bytes.length} > $maxFileBytes）';
        return false;
      }
      File(path).writeAsStringSync(body, flush: false);
      return true;
    } catch (error) {
      lastError = '写缓存失败：$error';
      return false;
    }
  }

  /// 删除整个 TMDB 缓存目录（「重置缓存」，`03` §6.5）。
  bool clear() {
    final dir = directory;
    if (dir == null) return false;
    try {
      final handle = Directory(dir);
      if (handle.existsSync()) handle.deleteSync(recursive: true);
      _available = null;
      return true;
    } catch (error) {
      lastError = '清理缓存失败：$error';
      return false;
    }
  }

  /// 当前缓存文件数（诊断/测试用）。
  int fileCount() {
    final dir = directory;
    if (dir == null) return 0;
    try {
      final handle = Directory(dir);
      if (!handle.existsSync()) return 0;
      return handle
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.json'))
          .length;
    } catch (_) {
      return 0;
    }
  }

  TmdbCacheHit? _read(String type, String key, Duration? ttl) {
    final payload = _readPayload(type, key);
    if (payload == null) return null;
    return _hitFor(payload, ttl);
  }

  Map<String, Object?>? _readPayload(String type, String key) {
    if (!ensureDirectory()) return null;
    final path = filePath(type, key);
    if (path == null) return null;
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return null;
      return decoded.cast<String, Object?>();
    } catch (error) {
      lastError = '读缓存失败：$error';
      return null;
    }
  }

  TmdbCacheHit? _hitFor(Map<String, Object?> payload, Duration? ttl) {
    final savedAt = payload[tmdbCacheSavedAtField];
    final age = savedAt is int
        ? Duration(
            milliseconds:
                _clock().millisecondsSinceEpoch - savedAt,
          )
        : Duration.zero;
    final isFresh = ttl == null || age <= ttl;
    final body = Map<String, Object?>.from(payload)
      ..remove(tmdbCacheSavedAtField);
    return TmdbCacheHit(
      payload: body,
      source: isFresh ? 'cache' : 'stale-cache',
      age: age,
    );
  }
}
