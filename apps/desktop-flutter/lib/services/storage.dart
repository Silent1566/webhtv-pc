/// SQLite 存储层（§15、§16）。
///
/// 表结构与设计文档 §16.2 对齐：`configs`、`sites`、`history`、`favorites`、
/// `search_cache`、`site_health`、`spider_logs`。
///
/// 约束：
/// - 数据库损坏或不可写时不得阻塞启动，调用方以“降级为无历史”的方式继续；
/// - 敏感 Header 不明文入库（§16.3）：站点 header 只保存键名与指纹；
/// - 数据库 schema 版本化，便于后续迁移。
library;

import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../core/app_error.dart';
import '../core/protocol.dart';

/// 播放历史（§15.1）。
class PlaybackHistory {
  const PlaybackHistory({
    required this.id,
    required this.siteKey,
    required this.vodId,
    required this.vodName,
    this.vodPic,
    required this.flag,
    required this.episodeName,
    required this.episodeId,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAt,
    this.completed = false,
  });

  final int id;
  final String siteKey;
  final String vodId;
  final String vodName;
  final String? vodPic;
  final String flag;
  final String episodeName;
  final String episodeId;
  final int positionMs;
  final int durationMs;
  final int updatedAt;
  final bool completed;

  double get progress {
    if (durationMs <= 0) return 0;
    final ratio = positionMs / durationMs;
    return ratio.clamp(0.0, 1.0);
  }

  int get progressPercent => (progress * 100).round();

  static PlaybackHistory fromRow(Row row) => PlaybackHistory(
    id: row['id'] as int,
    siteKey: row['site_key'] as String,
    vodId: row['vod_id'] as String,
    vodName: row['vod_name'] as String,
    vodPic: row['vod_pic'] as String?,
    flag: row['flag'] as String,
    episodeName: row['episode_name'] as String,
    episodeId: row['episode_id'] as String,
    positionMs: row['position_ms'] as int,
    durationMs: row['duration_ms'] as int,
    updatedAt: row['updated_at'] as int,
    completed: (row['completed'] as int) != 0,
  );
}

/// 收藏条目（§15.2）。
class FavoriteEntry {
  const FavoriteEntry({
    required this.id,
    required this.kind,
    required this.siteKey,
    required this.targetId,
    required this.title,
    this.subtitle,
    required this.updatedAt,
  });

  final int id;

  /// `site`、`vod` 或 `group`。
  final String kind;
  final String siteKey;
  final String targetId;
  final String title;
  final String? subtitle;
  final int updatedAt;

  static FavoriteEntry fromRow(Row row) => FavoriteEntry(
    id: row['id'] as int,
    kind: row['kind'] as String,
    siteKey: row['site_key'] as String,
    targetId: row['target_id'] as String,
    title: row['title'] as String,
    subtitle: row['subtitle'] as String?,
    updatedAt: row['updated_at'] as int,
  );
}

/// 配置记录（§7.5 “能记录配置名称、URL、更新时间、站点数、直播数”）。
class ConfigRecord {
  const ConfigRecord({
    required this.id,
    required this.name,
    required this.origin,
    required this.updatedAt,
    required this.siteCount,
    required this.liveCount,
    this.contentType,
    this.repositoryIndex,
    this.repositoryEntries = const [],
    this.json = const {},
    this.isActive = false,
  });

  final int id;
  final String name;
  final String origin;
  final DateTime updatedAt;
  final int siteCount;
  final int liveCount;
  final String? contentType;
  final int? repositoryIndex;
  final List<ConfigRepositoryEntry> repositoryEntries;

  /// 完整配置 JSON，用于重启后恢复（未知字段原样保留）。
  final Map<String, Object?> json;
  final bool isActive;

  AppConfig? get config => json.isEmpty ? null : _decode(json);

  static AppConfig? _decode(Map<String, Object?> value) {
    try {
      return parseConfigRecord(value);
    } catch (_) {
      return null;
    }
  }

  static ConfigRecord fromRow(Row row) {
    final rawJson = row['json'] as String?;
    final entriesRaw = row['repository_entries'] as String?;
    return ConfigRecord(
      id: row['id'] as int,
      name: row['name'] as String,
      origin: row['origin'] as String,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
      siteCount: row['site_count'] as int,
      liveCount: row['live_count'] as int,
      contentType: row['content_type'] as String?,
      repositoryIndex: row['repository_index'] as int?,
      repositoryEntries:
          entriesRaw == null || entriesRaw.isEmpty
          ? const []
          : (jsonDecode(entriesRaw) as List)
                .map(ConfigRepositoryEntry.fromJson)
                .whereType<ConfigRepositoryEntry>()
                .toList(),
      json: rawJson == null || rawJson.isEmpty
          ? const {}
          : (jsonDecode(rawJson) as Map).cast<String, Object?>(),
      isActive: (row['is_active'] as int? ?? 0) != 0,
    );
  }
}

/// 站点健康统计（§14.2）。
class SiteHealth {
  const SiteHealth({
    required this.siteKey,
    required this.homeOk,
    required this.homeTotal,
    required this.categoryOk,
    required this.categoryTotal,
    required this.detailOk,
    required this.detailTotal,
    required this.playOk,
    required this.playTotal,
    required this.avgLatencyMs,
    this.lastError,
    required this.updatedAt,
  });

  final String siteKey;
  final int homeOk;
  final int homeTotal;
  final int categoryOk;
  final int categoryTotal;
  final int detailOk;
  final int detailTotal;
  final int playOk;
  final int playTotal;
  final int avgLatencyMs;
  final String? lastError;
  final DateTime updatedAt;

  /// 成功率，无样本时返回 null（UI 显示“暂无数据”而不是 0%）。
  static double? rate(int ok, int total) => total == 0 ? null : ok / total;

  static SiteHealth fromRow(Row row) => SiteHealth(
    siteKey: row['site_key'] as String,
    homeOk: row['home_ok'] as int,
    homeTotal: row['home_total'] as int,
    categoryOk: row['category_ok'] as int,
    categoryTotal: row['category_total'] as int,
    detailOk: row['detail_ok'] as int,
    detailTotal: row['detail_total'] as int,
    playOk: row['play_ok'] as int,
    playTotal: row['play_total'] as int,
    avgLatencyMs: row['avg_latency_ms'] as int,
    lastError: row['last_error'] as String?,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
  );
}

/// 存储打开结果：失败时 [database] 为 null，调用方降级运行。
class StoreOpenResult {
  const StoreOpenResult({this.database, this.error});

  final AppDatabase? database;
  final String? error;

  bool get succeeded => database != null;
}

/// 数据库封装。
class AppDatabase {
  AppDatabase._(this._db);

  final Database _db;

  static const int schemaVersion = 1;

  /// 打开数据库；失败返回错误原因而不是抛出，保证启动不被阻塞（§16.3）。
  static StoreOpenResult open(String path) {
    try {
      final db = sqlite3.open(path);
      db.execute('PRAGMA journal_mode = WAL;');
      db.execute('PRAGMA foreign_keys = ON;');
      final instance = AppDatabase._(db);
      instance._migrate();
      return StoreOpenResult(database: instance);
    } catch (error) {
      return StoreOpenResult(error: '$error');
    }
  }

  /// 内存数据库，用于单元测试。
  static AppDatabase inMemory() {
    final db = sqlite3.openInMemory();
    final instance = AppDatabase._(db);
    instance._migrate();
    return instance;
  }

  void _migrate() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS configs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        origin TEXT NOT NULL,
        content_type TEXT,
        repository_index INTEGER,
        repository_entries TEXT,
        json TEXT NOT NULL,
        site_count INTEGER NOT NULL DEFAULT 0,
        live_count INTEGER NOT NULL DEFAULT 0,
        is_active INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS config_sites (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        config_id INTEGER NOT NULL REFERENCES configs(id) ON DELETE CASCADE,
        site_key TEXT NOT NULL,
        name TEXT NOT NULL,
        type INTEGER NOT NULL,
        header_key_names TEXT NOT NULL DEFAULT '',
        enabled INTEGER NOT NULL DEFAULT 1,
        last_used_at INTEGER,
        UNIQUE(config_id, site_key)
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        site_key TEXT NOT NULL,
        vod_id TEXT NOT NULL,
        vod_name TEXT NOT NULL,
        vod_pic TEXT,
        flag TEXT NOT NULL DEFAULT '',
        episode_name TEXT NOT NULL DEFAULT '',
        episode_id TEXT NOT NULL DEFAULT '',
        position_ms INTEGER NOT NULL DEFAULT 0,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        completed INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL,
        UNIQUE(site_key, vod_id, flag, episode_id)
      );
    ''');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_history_updated ON history(updated_at DESC);',
    );
    _db.execute('''
      CREATE TABLE IF NOT EXISTS favorites (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL,
        site_key TEXT NOT NULL,
        target_id TEXT NOT NULL,
        title TEXT NOT NULL,
        subtitle TEXT,
        updated_at INTEGER NOT NULL,
        UNIQUE(kind, site_key, target_id)
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS search_cache (
        keyword TEXT NOT NULL,
        site_key TEXT NOT NULL,
        payload TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (keyword, site_key)
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS site_health (
        site_key TEXT PRIMARY KEY,
        home_ok INTEGER NOT NULL DEFAULT 0,
        home_total INTEGER NOT NULL DEFAULT 0,
        category_ok INTEGER NOT NULL DEFAULT 0,
        category_total INTEGER NOT NULL DEFAULT 0,
        detail_ok INTEGER NOT NULL DEFAULT 0,
        detail_total INTEGER NOT NULL DEFAULT 0,
        play_ok INTEGER NOT NULL DEFAULT 0,
        play_total INTEGER NOT NULL DEFAULT 0,
        avg_latency_ms INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        updated_at INTEGER NOT NULL
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS spider_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        site_key TEXT NOT NULL,
        level TEXT NOT NULL,
        message TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );
    ''');
    _db.execute(
      "INSERT INTO meta(key, value) VALUES('schema_version', '$schemaVersion') "
      'ON CONFLICT(key) DO UPDATE SET value=excluded.value;',
    );
  }

  void dispose() => _db.close();

  // -------------------------------------------------------------------------
  // 配置
  // -------------------------------------------------------------------------

  /// 保存或更新配置记录。同一 `origin` 的重复导入按新版本覆盖（§7.5）。
  int saveConfig({
    required String name,
    required String origin,
    required Map<String, Object?> json,
    String? contentType,
    int? repositoryIndex,
    List<ConfigRepositoryEntry> repositoryEntries = const [],
    int siteCount = 0,
    int liveCount = 0,
    bool makeActive = true,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute('BEGIN IMMEDIATE;');
    try {
      final existing = _db.select(
        'SELECT id FROM configs WHERE origin = ? LIMIT 1;',
        [origin],
      );
      int id;
      if (existing.isNotEmpty) {
        id = existing.first['id'] as int;
        _db.execute(
          'UPDATE configs SET name=?, content_type=?, repository_index=?, '
          'repository_entries=?, json=?, site_count=?, live_count=?, '
          'updated_at=? WHERE id=?;',
          [
            name,
            contentType,
            repositoryIndex,
            repositoryEntries.isEmpty
                ? null
                : jsonEncode(
                    repositoryEntries.map((e) => e.toJson()).toList(),
                  ),
            jsonEncode(json),
            siteCount,
            liveCount,
            now,
            id,
          ],
        );
      } else {
        _db.execute(
          'INSERT INTO configs(name, origin, content_type, repository_index, '
          'repository_entries, json, site_count, live_count, is_active, '
          'updated_at) VALUES(?,?,?,?,?,?,?,?,0,?);',
          [
            name,
            origin,
            contentType,
            repositoryIndex,
            repositoryEntries.isEmpty
                ? null
                : jsonEncode(
                    repositoryEntries.map((e) => e.toJson()).toList(),
                  ),
            jsonEncode(json),
            siteCount,
            liveCount,
            now,
          ],
        );
        id = _db.lastInsertRowId;
      }
      if (makeActive) {
        _db.execute('UPDATE configs SET is_active = 0;');
        _db.execute('UPDATE configs SET is_active = 1 WHERE id = ?;', [id]);
      }
      _db.execute('COMMIT;');
      return id;
    } catch (error) {
      _db.execute('ROLLBACK;');
      throw AppError(
        AppErrorKind.storage,
        '保存配置记录失败',
        detail: '$error',
        cause: error,
      );
    }
  }

  List<ConfigRecord> listConfigs() {
    final rows = _db.select(
      'SELECT * FROM configs ORDER BY updated_at DESC;',
    );
    return rows.map(ConfigRecord.fromRow).toList();
  }

  ConfigRecord? activeConfig() {
    final rows = _db.select(
      'SELECT * FROM configs WHERE is_active = 1 ORDER BY updated_at DESC LIMIT 1;',
    );
    return rows.isEmpty ? null : ConfigRecord.fromRow(rows.first);
  }

  void activateConfig(int id) {
    _db.execute('BEGIN IMMEDIATE;');
    try {
      _db.execute('UPDATE configs SET is_active = 0;');
      _db.execute('UPDATE configs SET is_active = 1 WHERE id = ?;', [id]);
      _db.execute('COMMIT;');
    } catch (error) {
      _db.execute('ROLLBACK;');
      throw AppError(AppErrorKind.storage, '切换配置失败', cause: error);
    }
  }

  void deleteConfig(int id) {
    _db.execute('DELETE FROM config_sites WHERE config_id = ?;', [id]);
    _db.execute('DELETE FROM configs WHERE id = ?;', [id]);
  }

  /// 站点状态：只保存 header 键名，不保存值（§16.3 敏感 Header 不明文入库）。
  void saveConfigSites(int configId, Iterable<Site> sites) {
    _db.execute('DELETE FROM config_sites WHERE config_id = ?;', [configId]);
    final statement = _db.prepare(
      'INSERT OR REPLACE INTO config_sites(config_id, site_key, name, type, '
      'header_key_names, enabled) VALUES(?,?,?,?,?,1);',
    );
    try {
      for (final site in sites) {
        statement.execute([
          configId,
          site.key,
          site.name,
          site.type,
          site.header.keyNames.join(','),
        ]);
      }
    } finally {
      statement.close();
    }
  }

  List<Row> configSites(int configId) => _db.select(
    'SELECT * FROM config_sites WHERE config_id = ? ORDER BY id;',
    [configId],
  );

  // -------------------------------------------------------------------------
  // 历史
  // -------------------------------------------------------------------------

  void upsertHistory({
    required String siteKey,
    required String vodId,
    required String vodName,
    String? vodPic,
    required String flag,
    required String episodeName,
    required String episodeId,
    required int positionMs,
    required int durationMs,
    bool? completed,
  }) {
    final isCompleted =
        completed ??
        (durationMs > 0 && positionMs >= durationMs - 5000);
    _db.execute(
      'INSERT INTO history(site_key, vod_id, vod_name, vod_pic, flag, '
      'episode_name, episode_id, position_ms, duration_ms, completed, updated_at) '
      'VALUES(?,?,?,?,?,?,?,?,?,?,?) '
      'ON CONFLICT(site_key, vod_id, flag, episode_id) DO UPDATE SET '
      'vod_name=excluded.vod_name, vod_pic=excluded.vod_pic, '
      'episode_name=excluded.episode_name, position_ms=excluded.position_ms, '
      'duration_ms=excluded.duration_ms, completed=excluded.completed, '
      'updated_at=excluded.updated_at;',
      [
        siteKey,
        vodId,
        vodName,
        vodPic,
        flag,
        episodeName,
        episodeId,
        positionMs,
        durationMs,
        isCompleted ? 1 : 0,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  List<PlaybackHistory> recentHistory({int limit = 100}) => _db
      .select('SELECT * FROM history ORDER BY updated_at DESC LIMIT ?;', [limit])
      .map(PlaybackHistory.fromRow)
      .toList();

  /// 历史搜索：按片名与剧集名做包含匹配（§15.2）。
  ///
  /// 使用 `instr()` 而不是 `LIKE`：`instr` 是纯子串匹配，用户输入的 `%`、`_`、`\`
  /// 不会被当成通配符或转义符，也就不存在 LIKE 转义控制符写错的风险。
  List<PlaybackHistory> searchHistory(String keyword, {int limit = 100}) {
    return _db
        .select(
          'SELECT * FROM history '
          'WHERE instr(vod_name, ?) > 0 OR instr(episode_name, ?) > 0 '
          'ORDER BY updated_at DESC LIMIT ?;',
          [keyword, keyword, limit],
        )
        .map(PlaybackHistory.fromRow)
        .toList();
  }

  PlaybackHistory? findHistory({
    required String siteKey,
    required String vodId,
    String? flag,
    String? episodeId,
  }) {
    final rows = _db.select(
      'SELECT * FROM history WHERE site_key=? AND vod_id=? '
      'AND (? IS NULL OR flag = ?) AND (? IS NULL OR episode_id = ?) '
      'ORDER BY updated_at DESC LIMIT 1;',
      [siteKey, vodId, flag, flag, episodeId, episodeId],
    );
    return rows.isEmpty ? null : PlaybackHistory.fromRow(rows.first);
  }

  void deleteHistory(int id) =>
      _db.execute('DELETE FROM history WHERE id = ?;', [id]);

  /// 清空历史：只删 history 表，不触碰 configs（§15.3）。
  void clearHistory() => _db.execute('DELETE FROM history;');

  // -------------------------------------------------------------------------
  // 收藏
  // -------------------------------------------------------------------------

  void upsertFavorite({
    required String kind,
    required String siteKey,
    required String targetId,
    required String title,
    String? subtitle,
  }) {
    _db.execute(
      'INSERT INTO favorites(kind, site_key, target_id, title, subtitle, updated_at) '
      'VALUES(?,?,?,?,?,?) '
      'ON CONFLICT(kind, site_key, target_id) DO UPDATE SET '
      'title=excluded.title, subtitle=excluded.subtitle, '
      'updated_at=excluded.updated_at;',
      [
        kind,
        siteKey,
        targetId,
        title,
        subtitle,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  List<FavoriteEntry> listFavorites({String? kind}) => _db
      .select(
        kind == null
            ? 'SELECT * FROM favorites ORDER BY updated_at DESC;'
            : 'SELECT * FROM favorites WHERE kind = ? ORDER BY updated_at DESC;',
        kind == null ? [] : [kind],
      )
      .map(FavoriteEntry.fromRow)
      .toList();

  bool isFavorite({
    required String kind,
    required String siteKey,
    required String targetId,
  }) {
    final rows = _db.select(
      'SELECT 1 FROM favorites WHERE kind=? AND site_key=? AND target_id=? LIMIT 1;',
      [kind, siteKey, targetId],
    );
    return rows.isNotEmpty;
  }

  void removeFavorite({
    required String kind,
    required String siteKey,
    required String targetId,
  }) {
    _db.execute(
      'DELETE FROM favorites WHERE kind=? AND site_key=? AND target_id=?;',
      [kind, siteKey, targetId],
    );
  }

  // -------------------------------------------------------------------------
  // 搜索缓存与站点健康
  // -------------------------------------------------------------------------

  void cacheSearch({
    required String keyword,
    required String siteKey,
    required Object? payload,
    Duration ttl = const Duration(minutes: 10),
  }) {
    _db.execute(
      'INSERT INTO search_cache(keyword, site_key, payload, updated_at) '
      'VALUES(?,?,?,?) ON CONFLICT(keyword, site_key) DO UPDATE SET '
      'payload=excluded.payload, updated_at=excluded.updated_at;',
      [
        keyword,
        siteKey,
        jsonEncode(payload),
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  /// 读取仍在 [ttl] 内的搜索结果缓存。
  /// 搜索缓存 TTL 读取。`ttl` 非正数表示不使用缓存。
  Object? readSearchCache({
    required String keyword,
    required String siteKey,
    Duration ttl = const Duration(minutes: 10),
  }) {
    if (ttl <= Duration.zero) return null;
    final threshold = DateTime.now()
        .subtract(ttl)
        .millisecondsSinceEpoch;
    final rows = _db.select(
      'SELECT payload FROM search_cache WHERE keyword=? AND site_key=? '
      'AND updated_at >= ? LIMIT 1;',
      [keyword, siteKey, threshold],
    );
    if (rows.isEmpty) return null;
    return jsonDecode(rows.first['payload'] as String);
  }

  void purgeExpiredSearchCache({Duration ttl = const Duration(minutes: 10)}) {
    final threshold = DateTime.now()
        .subtract(ttl)
        .millisecondsSinceEpoch;
    _db.execute('DELETE FROM search_cache WHERE updated_at < ?;', [threshold]);
  }

  /// 记录一次站点调用结果（§14.2）。
  void recordHealth({
    required String siteKey,
    required HealthAction action,
    required bool success,
    int latencyMs = 0,
    String? error,
  }) {
    final column = action.name;
    _db.execute(
      'INSERT INTO site_health(site_key, ${column}_ok, ${column}_total, '
      'avg_latency_ms, last_error, updated_at) VALUES(?,?,?,?,?,?) '
      'ON CONFLICT(site_key) DO UPDATE SET '
      '${column}_ok = site_health.${column}_ok + excluded.${column}_ok, '
      '${column}_total = site_health.${column}_total + excluded.${column}_total, '
      'avg_latency_ms = (site_health.avg_latency_ms + excluded.avg_latency_ms) / 2, '
      'last_error = COALESCE(excluded.last_error, site_health.last_error), '
      'updated_at = excluded.updated_at;',
      [
        siteKey,
        success ? 1 : 0,
        1,
        latencyMs,
        error,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  List<SiteHealth> siteHealth() =>
      _db.select('SELECT * FROM site_health ORDER BY site_key;').map(SiteHealth.fromRow).toList();

  void recordSpiderLog({
    required String siteKey,
    required String level,
    required String message,
  }) {
    _db.execute(
      'INSERT INTO spider_logs(site_key, level, message, created_at) VALUES(?,?,?,?);',
      [siteKey, level, message, DateTime.now().millisecondsSinceEpoch],
    );
  }

  /// 便于测试与诊断：统计各表行数。
  Map<String, int> rowCounts() {
    final result = <String, int>{};
    for (final table in [
      'configs',
      'config_sites',
      'history',
      'favorites',
      'search_cache',
      'site_health',
      'spider_logs',
    ]) {
      result[table] =
          _db.select('SELECT COUNT(*) AS c FROM $table;').first['c'] as int;
    }
    return result;
  }

  /// 原生 SQL 计数（健康度检查、集成测试使用）。
  int count(String table) =>
      _db.select('SELECT COUNT(*) AS c FROM $table;').first['c'] as int;

  /// 删除数据目录后重建：关闭并重新打开同一路径由调用方负责。
  bool get isHealthy {
    try {
      _db.select('SELECT 1;');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 数据库文件路径（内存库返回 null）。
  String? get path {
    try {
      return _db.select('PRAGMA database_list;').isEmpty
          ? null
          : _db.select('PRAGMA database_list;').first['file'] as String?;
    } catch (_) {
      return null;
    }
  }
}

enum HealthAction { home, category, detail, play }

/// 从存储中的 JSON 恢复 [AppConfig]。
///
/// 复用配置文件解析路径，保证“导入 → 保存 → 恢复”与“重新导入”得到同样的模型，
/// 避免两套逻辑分叉。
AppConfig parseConfigRecord(Map<String, Object?> json) {
  final sites = <Site>[];
  for (final item in asList(json['sites'])) {
    final site = Site.fromJson(item);
    if (site != null) sites.add(site);
  }
  if (sites.isEmpty) {
    throw AppError(AppErrorKind.configInvalid, '恢复的配置没有可用站点');
  }
  final headers = <HeaderRule>[];
  for (final item in asList(json['headers'])) {
    final rule = HeaderRule.fromJson(item);
    if (rule != null) headers.add(rule);
  }
  final parses = <ParseEntry>[];
  for (final item in asList(json['parses'])) {
    final entry = ParseEntry.fromJson(item);
    if (entry != null) parses.add(entry);
  }
  final urls = <ConfigRepositoryEntry>[];
  for (final item in asList(json['urls'])) {
    final entry = ConfigRepositoryEntry.fromJson(item);
    if (entry != null) urls.add(entry);
  }
  final lives = <LiveSource>[];
  for (final item in asList(json['lives'])) {
    final source = LiveSource.fromJson(item);
    if (source != null) lives.add(source);
  }

  final known = <String>{
    'name',
    'spider',
    'sites',
    'parses',
    'flags',
    'lives',
    'doh',
    'proxy',
    'hosts',
    'headers',
    'rules',
    'hlsRules',
    'groupRules',
    'ads',
    'wallpaper',
    'logo',
    'notice',
    'home',
    'parse',
    'urls',
    'msg',
  };
  final extra = <String, Object?>{};
  for (final entry in json.entries) {
    if (!known.contains(entry.key)) extra[entry.key] = entry.value;
  }

  return AppConfig(
    name: asNonEmptyString(json['name']),
    spider: asNonEmptyString(json['spider']),
    sites: sites,
    parses: parses,
    flags: asList(json['flags']).map(asNonEmptyString).whereType<String>().toList(),
    lives: lives,
    doh: asList(json['doh']),
    proxy: asList(json['proxy']),
    hosts: asList(json['hosts']),
    headers: headers,
    rules: asList(json['rules']),
    hlsRules: asList(json['hlsRules']),
    groupRules: asList(json['groupRules']),
    ads: asList(json['ads']),
    wallpaper: asNonEmptyString(json['wallpaper']),
    logo: asNonEmptyString(json['logo']),
    notice: asNonEmptyString(json['notice']),
    home: asNonEmptyString(json['home']),
    parse: asNonEmptyString(json['parse']),
    urls: urls,
    msg: asNonEmptyString(json['msg']),
    hasMsgKey: json.containsKey('msg'),
    extra: extra,
  );
}

/// 删除缓存目录后可重建：清理搜索缓存与图片缓存目录（§16.3）。
Future<void> resetCacheDirectory(String cacheDir) async {
  final directory = Directory(cacheDir);
  if (await directory.exists()) {
    await directory.delete(recursive: true);
  }
  await directory.create(recursive: true);
}
