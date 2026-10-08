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

import '../core/android_sync.dart';
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

  /// 当前 schema 版本。
  ///
  /// - `1` → `2`：Phase 4 新增四张 TMDB 表（`docs/phase4/design/03` §6.1）；
  /// - `2` → `3`：Phase 5 新增 `history_deletions` 删除标记表
  ///   （`docs/phase5/design/02` §4.5）。
  ///
  /// 两次升级都是**加法式**（`CREATE TABLE IF NOT EXISTS`）：旧库打开后
  /// 自动获得新表且不丢数据，无需分支式升级逻辑。
  static const int schemaVersion = 3;

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
    _migrateTmdb();
    _migrateSync();
    _db.execute(
      "INSERT INTO meta(key, value) VALUES('schema_version', '$schemaVersion') "
      'ON CONFLICT(key) DO UPDATE SET value=excluded.value;',
    );
  }

  /// Phase 5 · 删除标记表（`docs/phase5/design/02` §4.5）。
  ///
  /// 上游的删除墓碑同步仍是「待实现」，PC 侧本阶段只做**最小可行的墓碑
  /// 替代方案**：记录「我删过这条，删除时刻是 T」。远端再推来
  /// `updatedAt < T` 的旧记录时跳过插入，于是被删掉的记录**不会复活**。
  ///
  /// 为什么必须单独一张表：合并裁决（`design/02` §4.4）里
  /// `local == null` 的分支是**插入**——这正是「复活」的路径。
  /// 只有本地记得「我删过」，才能把它与「从没见过这条」区分开。
  ///
  /// 同样是加法式迁移，不需要分支升级逻辑。
  void _migrateSync() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS history_deletions (
        match_key TEXT PRIMARY KEY,
        site_key TEXT NOT NULL DEFAULT '',
        vod_id TEXT NOT NULL DEFAULT '',
        flag TEXT NOT NULL DEFAULT '',
        episode_id TEXT NOT NULL DEFAULT '',
        deleted_at INTEGER NOT NULL
      );
    ''');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_history_deletions_at '
      'ON history_deletions(deleted_at DESC);',
    );
  }

  /// Phase 4 · TMDB 元数据增强的四张新表（`docs/phase4/design/03` §6.1）。
  ///
  /// 全部为**加法式**新增：不改动任何既有表的列或主键，因此无需分支式迁移，
  /// 旧数据库打开后自动获得新表且不丢数据（§6.2）。
  void _migrateTmdb() {
    // 媒体匹配（`01` §2.3）
    _db.execute('''
      CREATE TABLE IF NOT EXISTS tmdb_matches (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        config_id INTEGER NOT NULL DEFAULT 0,
        site_key TEXT NOT NULL,
        vod_id TEXT NOT NULL,
        source_title TEXT NOT NULL DEFAULT '',
        scope TEXT NOT NULL,
        tmdb_id INTEGER NOT NULL,
        media_type TEXT NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        subtitle TEXT,
        overview TEXT,
        poster_url TEXT,
        backdrop_url TEXT,
        credit TEXT,
        rating REAL NOT NULL DEFAULT 0,
        original_language TEXT NOT NULL DEFAULT '',
        origin_country TEXT NOT NULL DEFAULT '',
        manual INTEGER NOT NULL DEFAULT 0,
        manual_titles TEXT,
        matched_at INTEGER NOT NULL,
        UNIQUE(config_id, site_key, vod_id, source_title, scope)
      );
    ''');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_tmdb_matches_identity '
      'ON tmdb_matches(config_id, media_type, tmdb_id);',
    );

    // 线路级季度绑定（`02` §5.1）
    _db.execute('''
      CREATE TABLE IF NOT EXISTS tmdb_season_bindings (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        config_id INTEGER NOT NULL DEFAULT 0,
        site_key TEXT NOT NULL,
        vod_id TEXT NOT NULL,
        source_title TEXT NOT NULL DEFAULT '',
        flag_key TEXT NOT NULL DEFAULT '',
        tmdb_id INTEGER NOT NULL,
        media_type TEXT NOT NULL DEFAULT 'tv',
        mode TEXT NOT NULL,
        season_number INTEGER,
        source_fingerprint TEXT NOT NULL DEFAULT '',
        source_episode_count INTEGER NOT NULL DEFAULT 0,
        tmdb_season_episode_count INTEGER NOT NULL DEFAULT 0,
        segments TEXT,
        version INTEGER NOT NULL DEFAULT 1,
        updated_at INTEGER NOT NULL,
        UNIQUE(config_id, site_key, vod_id, source_title, flag_key)
      );
    ''');

    // 季度→线路索引（`02` §5.5）
    _db.execute('''
      CREATE TABLE IF NOT EXISTS tmdb_route_bindings (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        config_id INTEGER NOT NULL DEFAULT 0,
        site_key TEXT NOT NULL,
        vod_id TEXT NOT NULL,
        flag_key TEXT NOT NULL,
        source_flag TEXT NOT NULL DEFAULT '',
        source_fingerprint TEXT NOT NULL DEFAULT '',
        tmdb_id INTEGER NOT NULL,
        media_type TEXT NOT NULL DEFAULT 'tv',
        scope_kind TEXT NOT NULL,
        season_numbers TEXT NOT NULL DEFAULT '',
        segments TEXT,
        updated_at INTEGER NOT NULL,
        UNIQUE(config_id, site_key, vod_id, flag_key)
      );
    ''');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_tmdb_route_identity '
      'ON tmdb_route_bindings(config_id, tmdb_id, media_type);',
    );

    // 季度进度（`02` §6.1）
    _db.execute('''
      CREATE TABLE IF NOT EXISTS tmdb_season_progress (
        config_id INTEGER NOT NULL DEFAULT 0,
        media_type TEXT NOT NULL DEFAULT 'tv',
        tmdb_id INTEGER NOT NULL,
        season_number INTEGER NOT NULL,
        episode_number INTEGER NOT NULL DEFAULT 0,
        position_ms INTEGER NOT NULL DEFAULT 0,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        source_flag TEXT NOT NULL DEFAULT '',
        source_episode_name TEXT NOT NULL DEFAULT '',
        source_episode_url TEXT NOT NULL DEFAULT '',
        source_history_key TEXT NOT NULL DEFAULT '',
        source_binding_key TEXT NOT NULL DEFAULT '',
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (config_id, media_type, tmdb_id, season_number)
      );
    ''');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_tmdb_season_progress_history '
      'ON tmdb_season_progress(config_id, source_history_key);',
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
    int? updatedAt,
    int? openingMs,
    int? endingMs,
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
        // 本地播放写入用 `now()`；同步写入必须用**远端的时间戳**
        // （`docs/phase5/design/02` §3.4：`createTime` 毫秒直传）。
        // 写成 `now()` 会让一条 2024 年的安卓记录看起来比本地所有记录都新，
        // 下一轮“旧不覆盖新”的裁决随之失真。
        updatedAt ?? DateTime.now().millisecondsSinceEpoch,
      ],
    );
    // 写入即意味着这条记录重新存在，删除标记不再有意义。
    // `openingMs` / `endingMs` 目前只用于本地播放器行为，不入本表
    // （PC 有独立的 open/end 设置），此处接收只为签名向后兼容与调用方对称。
    _forgetHistoryDeletion(
      SyncHistoryItem.fromLocal(
        siteKey: siteKey,
        vodId: vodId,
        vodName: vodName,
        flag: flag,
        episodeName: episodeName,
        episodeId: episodeId,
        positionMs: positionMs,
        durationMs: durationMs,
        updatedAt: updatedAt ?? DateTime.now().millisecondsSinceEpoch,
      ).matchKey,
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

  void deleteHistory(int id) {
    final rows = _db.select(
      'SELECT site_key, vod_id, flag, episode_id FROM history WHERE id = ?;',
      [id],
    );
    if (rows.isNotEmpty) _rememberDeletionOfRow(rows.first);
    _db.execute('DELETE FROM history WHERE id = ?;', [id]);
  }

  /// 清空历史：只删 history 表，不触碰 configs（§15.3）。
  ///
  /// 同时为每条被删记录留删除标记：否则用户「清空历史」后，安卓再推来
  /// 同一批旧记录就会把它们全部复活（`docs/phase5/design/02` §4.5）。
  /// 标记是**本地行为**，不改变清空本身的可见结果。
  void clearHistory() {
    for (final row in _db.select(
      'SELECT site_key, vod_id, flag, episode_id FROM history;',
    )) {
      _rememberDeletionOfRow(row);
    }
    _db.execute('DELETE FROM history;');
  }

  // -------------------------------------------------------------------------
  // Phase 5 · 同步合并与删除标记（`docs/phase5/design/02` §4.4 / §4.5）
  // -------------------------------------------------------------------------

  /// 本地历史索引：合并匹配键 → 记录（供 [buildHistoryMergePlan] 使用）。
  ///
  /// 匹配键是 `(siteKey, vodId, flag, episodeId)`，**不含 `cid`**
  /// （`design/02` §4.3）——这与 `history` 表的 `UNIQUE` 约束一致。
  Map<String, SyncHistoryItem> historySyncIndex() {
    final result = <String, SyncHistoryItem>{};
    for (final history in recentHistory(limit: 100000)) {
      final item = SyncHistoryItem.fromLocal(
        siteKey: history.siteKey,
        vodId: history.vodId,
        vodName: history.vodName,
        vodPic: history.vodPic,
        flag: history.flag,
        episodeName: history.episodeName,
        episodeId: history.episodeId,
        positionMs: history.positionMs,
        durationMs: history.durationMs,
        updatedAt: history.updatedAt,
      );
      result[item.matchKey] = item;
    }
    return result;
  }

  /// 删除标记索引：合并匹配键 → 删除时刻（毫秒）。
  Map<String, int> historyDeletionIndex() => {
    for (final row in _db.select(
      'SELECT match_key, deleted_at FROM history_deletions;',
    ))
      row['match_key'] as String: row['deleted_at'] as int,
  };

  /// 删除标记条数（证据与门禁用）。
  int get historyDeletionCount => count('history_deletions');

  /// 执行合并计划（`design/02` §4.4）。
  ///
  /// 行为约束（P3）：
  /// - **只增不改不删**：`skipped` 的条目不会导致任何 `DELETE`；
  /// - 写入使用**远端时间戳**（不用 `now()`），保住“旧不覆盖新”的判据；
  /// - 单条写入失败不回滚整批，只计入 `failed`（§4.3）；
  /// - 返回值的不变式必须是 `applied + skipped + failed == total`。
  SyncMergeStats applyHistoryMerge(SyncMergePlan plan) {
    var applied = 0;
    var failed = plan.failures.length;
    for (final item in plan.applied) {
      try {
        _writeSyncHistory(item);
        applied++;
      } catch (_) {
        failed++;
      }
    }
    return SyncMergeStats(
      applied: applied,
      skipped: plan.skipped,
      failed: failed,
      total: plan.total,
    );
  }

  /// 单条同步写入：时间戳用远端值，`completed` 按 PC 规则重算。
  void _writeSyncHistory(SyncHistoryItem item) {
    upsertHistory(
      siteKey: item.siteKey,
      vodId: item.vodId,
      vodName: item.vodName,
      vodPic: item.vodPic,
      flag: item.flag,
      episodeName: item.episodeName,
      episodeId: item.episodeId,
      positionMs: item.positionMs,
      durationMs: item.durationMs,
      completed: item.completed,
      updatedAt: item.updatedAt,
    );
  }

  void _rememberHistoryDeletion(
    String matchKey, {
    required String siteKey,
    required String vodId,
    required String flag,
    required String episodeId,
  }) {
    _db.execute(
      'INSERT INTO history_deletions(match_key, site_key, vod_id, flag, '
      'episode_id, deleted_at) VALUES(?,?,?,?,?,?) '
      'ON CONFLICT(match_key) DO UPDATE SET deleted_at=excluded.deleted_at;',
      [
        matchKey,
        siteKey,
        vodId,
        flag,
        episodeId,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  /// 为一行（删除前的）历史记下删除标记。
  void _rememberDeletionOfRow(Row row) {
    final siteKey = row['site_key'] as String;
    final vodId = row['vod_id'] as String;
    final flag = row['flag'] as String;
    final episodeId = row['episode_id'] as String;
    _rememberHistoryDeletion(
      SyncHistoryItem.fromLocal(
        siteKey: siteKey,
        vodId: vodId,
        vodName: '',
        flag: flag,
        episodeName: '',
        episodeId: episodeId,
        positionMs: 0,
        durationMs: 0,
        updatedAt: 0,
      ).matchKey,
      siteKey: siteKey,
      vodId: vodId,
      flag: flag,
      episodeId: episodeId,
    );
  }
  void _forgetHistoryDeletion(String matchKey) => _db.execute(
    'DELETE FROM history_deletions WHERE match_key = ?;',
    [matchKey],
  );

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
      'history_deletions',
      'favorites',
      'search_cache',
      'site_health',
      'spider_logs',
      'tmdb_matches',
      'tmdb_season_bindings',
      'tmdb_route_bindings',
      'tmdb_season_progress',
    ]) {
      result[table] =
          _db.select('SELECT COUNT(*) AS c FROM $table;').first['c'] as int;
    }
    return result;
  }

  // -------------------------------------------------------------------------
  // TMDB 元数据增强（§27）
  // -------------------------------------------------------------------------

  /// 读取匹配结论。`scope = 'entry'` 表示条目级键（`source_title` 为 `''`）。
  Row? findTmdbMatch({
    required int configId,
    required String siteKey,
    required String vodId,
    required String sourceTitle,
    required String scope,
  }) {
    final rows = _db.select(
      'SELECT * FROM tmdb_matches WHERE config_id=? AND site_key=? AND vod_id=? '
      'AND source_title=? AND scope=? LIMIT 1;',
      [configId, siteKey, vodId, sourceTitle, scope],
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// 写入匹配结论（按唯一键 upsert）。
  void upsertTmdbMatch({
    required int configId,
    required String siteKey,
    required String vodId,
    required String sourceTitle,
    required String scope,
    required int tmdbId,
    required String mediaType,
    required String title,
    String? subtitle,
    String? overview,
    String? posterUrl,
    String? backdropUrl,
    String? credit,
    double rating = 0,
    String originalLanguage = '',
    String originCountry = '',
    bool manual = false,
    List<String> manualTitles = const [],
    int? matchedAt,
  }) {
    _db.execute(
      'INSERT INTO tmdb_matches(config_id, site_key, vod_id, source_title, scope, '
      'tmdb_id, media_type, title, subtitle, overview, poster_url, backdrop_url, '
      'credit, rating, original_language, origin_country, manual, manual_titles, '
      'matched_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) '
      'ON CONFLICT(config_id, site_key, vod_id, source_title, scope) DO UPDATE SET '
      'tmdb_id=excluded.tmdb_id, media_type=excluded.media_type, '
      'title=excluded.title, subtitle=excluded.subtitle, overview=excluded.overview, '
      'poster_url=excluded.poster_url, backdrop_url=excluded.backdrop_url, '
      'credit=excluded.credit, rating=excluded.rating, '
      'original_language=excluded.original_language, '
      'origin_country=excluded.origin_country, manual=excluded.manual, '
      'manual_titles=excluded.manual_titles, matched_at=excluded.matched_at;',
      [
        configId,
        siteKey,
        vodId,
        sourceTitle,
        scope,
        tmdbId,
        mediaType,
        title,
        subtitle,
        overview,
        posterUrl,
        backdropUrl,
        credit,
        rating,
        originalLanguage,
        originCountry,
        manual ? 1 : 0,
        manualTitles.isEmpty ? null : manualTitles.join('\u0001'),
        matchedAt ?? DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  /// 删除某条目（含全部标题键）的匹配结论。
  int removeTmdbMatches({
    required int configId,
    required String siteKey,
    required String vodId,
  }) {
    _db.execute(
      'DELETE FROM tmdb_matches WHERE config_id=? AND site_key=? AND vod_id=?;',
      [configId, siteKey, vodId],
    );
    return _db.updatedRows;
  }

  /// 读取季度绑定。
  Row? findTmdbSeasonBinding({
    required int configId,
    required String siteKey,
    required String vodId,
    required String sourceTitle,
    required String flagKey,
  }) {
    final rows = _db.select(
      'SELECT * FROM tmdb_season_bindings WHERE config_id=? AND site_key=? '
      'AND vod_id=? AND source_title=? AND flag_key=? LIMIT 1;',
      [configId, siteKey, vodId, sourceTitle, flagKey],
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// 写入季度绑定（按唯一键 upsert）。
  void upsertTmdbSeasonBinding({
    required int configId,
    required String siteKey,
    required String vodId,
    required String sourceTitle,
    required String flagKey,
    required int tmdbId,
    required String mediaType,
    required String mode,
    int? seasonNumber,
    String sourceFingerprint = '',
    int sourceEpisodeCount = 0,
    int tmdbSeasonEpisodeCount = 0,
    String? segments,
    int version = 1,
    int? updatedAt,
  }) {
    _db.execute(
      'INSERT INTO tmdb_season_bindings(config_id, site_key, vod_id, source_title, '
      'flag_key, tmdb_id, media_type, mode, season_number, source_fingerprint, '
      'source_episode_count, tmdb_season_episode_count, segments, version, updated_at) '
      'VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) '
      'ON CONFLICT(config_id, site_key, vod_id, source_title, flag_key) DO UPDATE SET '
      'tmdb_id=excluded.tmdb_id, media_type=excluded.media_type, mode=excluded.mode, '
      'season_number=excluded.season_number, '
      'source_fingerprint=excluded.source_fingerprint, '
      'source_episode_count=excluded.source_episode_count, '
      'tmdb_season_episode_count=excluded.tmdb_season_episode_count, '
      'segments=excluded.segments, version=excluded.version, '
      'updated_at=excluded.updated_at;',
      [
        configId,
        siteKey,
        vodId,
        sourceTitle,
        flagKey,
        tmdbId,
        mediaType,
        mode,
        seasonNumber,
        sourceFingerprint,
        sourceEpisodeCount,
        tmdbSeasonEpisodeCount,
        segments,
        version,
        updatedAt ?? DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  /// 删除季度绑定（可指定线路；`flagKey` 为空时删除该条目的全部线路）。
  int removeTmdbSeasonBindings({
    required int configId,
    required String siteKey,
    required String vodId,
    String? sourceTitle,
    String? flagKey,
  }) {
    final clauses = <String>['config_id=?', 'site_key=?', 'vod_id=?'];
    final args = <Object?>[configId, siteKey, vodId];
    if (sourceTitle != null) {
      clauses.add('source_title=?');
      args.add(sourceTitle);
    }
    if (flagKey != null) {
      clauses.add('flag_key=?');
      args.add(flagKey);
    }
    _db.execute(
      'DELETE FROM tmdb_season_bindings WHERE ${clauses.join(" AND ")};',
      args,
    );
    return _db.updatedRows;
  }

  /// 读取线路绑定索引。
  Row? findTmdbRouteBinding({
    required int configId,
    required String siteKey,
    required String vodId,
    required String flagKey,
  }) {
    final rows = _db.select(
      'SELECT * FROM tmdb_route_bindings WHERE config_id=? AND site_key=? '
      'AND vod_id=? AND flag_key=? LIMIT 1;',
      [configId, siteKey, vodId, flagKey],
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// 写入线路绑定索引。
  void upsertTmdbRouteBinding({
    required int configId,
    required String siteKey,
    required String vodId,
    required String flagKey,
    required String sourceFlag,
    required String sourceFingerprint,
    required int tmdbId,
    required String mediaType,
    required String scopeKind,
    required String seasonNumbers,
    String? segments,
    int? updatedAt,
  }) {
    _db.execute(
      'INSERT INTO tmdb_route_bindings(config_id, site_key, vod_id, flag_key, '
      'source_flag, source_fingerprint, tmdb_id, media_type, scope_kind, '
      'season_numbers, segments, updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?) '
      'ON CONFLICT(config_id, site_key, vod_id, flag_key) DO UPDATE SET '
      'source_flag=excluded.source_flag, '
      'source_fingerprint=excluded.source_fingerprint, tmdb_id=excluded.tmdb_id, '
      'media_type=excluded.media_type, scope_kind=excluded.scope_kind, '
      'season_numbers=excluded.season_numbers, segments=excluded.segments, '
      'updated_at=excluded.updated_at;',
      [
        configId,
        siteKey,
        vodId,
        flagKey,
        sourceFlag,
        sourceFingerprint,
        tmdbId,
        mediaType,
        scopeKind,
        seasonNumbers,
        segments,
        updatedAt ?? DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  /// 删除线路绑定索引。
  int removeTmdbRouteBinding({
    required int configId,
    required String siteKey,
    required String vodId,
    required String flagKey,
  }) {
    _db.execute(
      'DELETE FROM tmdb_route_bindings WHERE config_id=? AND site_key=? '
      'AND vod_id=? AND flag_key=?;',
      [configId, siteKey, vodId, flagKey],
    );
    return _db.updatedRows;
  }

  /// 按 TMDB 身份 + 季度列出全部线路绑定（换源候选，`02` §5.5）。
  List<Row> tmdbRouteBindingsFor({
    required int configId,
    required int tmdbId,
    required String mediaType,
    required int seasonNumber,
  }) {
    // season_numbers 是 JSON 数组文本；用 LIKE 粗筛后在 Dart 侧精确判定。
    return _db.select(
      'SELECT * FROM tmdb_route_bindings WHERE config_id=? AND tmdb_id=? '
      'AND media_type=? ORDER BY updated_at DESC;',
      [configId, tmdbId, mediaType],
    );
  }

  /// 列出某配置下的**全部**线路绑定（容量淘汰用，`02` §5.5）。
  List<Row> tmdbRouteBindingsAll({required int configId}) => _db.select(
    'SELECT * FROM tmdb_route_bindings WHERE config_id=? ORDER BY updated_at ASC;',
    [configId],
  );

  /// 线路绑定索引容量上限（`02` §5.5）：超出时按 `updated_at` 淘汰最旧。
  int trimTmdbRouteBindings({int max = 512}) {
    final total =
        _db.select('SELECT COUNT(*) AS c FROM tmdb_route_bindings;').first['c']
            as int;
    if (total <= max) return 0;
    _db.execute(
      'DELETE FROM tmdb_route_bindings WHERE id IN ('
      'SELECT id FROM tmdb_route_bindings ORDER BY updated_at ASC LIMIT ?);',
      [total - max],
    );
    return _db.updatedRows;
  }

  /// 读取季度进度。
  Row? findTmdbSeasonProgress({
    required int configId,
    required String mediaType,
    required int tmdbId,
    required int seasonNumber,
  }) {
    final rows = _db.select(
      'SELECT * FROM tmdb_season_progress WHERE config_id=? AND media_type=? '
      'AND tmdb_id=? AND season_number=? LIMIT 1;',
      [configId, mediaType, tmdbId, seasonNumber],
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// 写入季度进度（主键覆盖，`02` §6.2）。
  void upsertTmdbSeasonProgress({
    required int configId,
    required String mediaType,
    required int tmdbId,
    required int seasonNumber,
    int episodeNumber = 0,
    int positionMs = 0,
    int durationMs = 0,
    String sourceFlag = '',
    String sourceEpisodeName = '',
    String sourceEpisodeUrl = '',
    String sourceHistoryKey = '',
    String sourceBindingKey = '',
    int? updatedAt,
  }) {
    _db.execute(
      'INSERT INTO tmdb_season_progress(config_id, media_type, tmdb_id, '
      'season_number, episode_number, position_ms, duration_ms, source_flag, '
      'source_episode_name, source_episode_url, source_history_key, '
      'source_binding_key, updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?) '
      'ON CONFLICT(config_id, media_type, tmdb_id, season_number) DO UPDATE SET '
      'episode_number=excluded.episode_number, position_ms=excluded.position_ms, '
      'duration_ms=excluded.duration_ms, source_flag=excluded.source_flag, '
      'source_episode_name=excluded.source_episode_name, '
      'source_episode_url=excluded.source_episode_url, '
      'source_history_key=excluded.source_history_key, '
      'source_binding_key=excluded.source_binding_key, '
      'updated_at=excluded.updated_at;',
      [
        configId,
        mediaType,
        tmdbId,
        seasonNumber,
        episodeNumber,
        positionMs,
        durationMs,
        sourceFlag,
        sourceEpisodeName,
        sourceEpisodeUrl,
        sourceHistoryKey,
        sourceBindingKey,
        updatedAt ?? DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  /// 列出某节目的全部季度进度（历史投影用，`02` §7.1）。
  List<Row> tmdbSeasonProgressFor({
    required int configId,
    required String mediaType,
    required int tmdbId,
  }) => _db.select(
    'SELECT * FROM tmdb_season_progress WHERE config_id=? AND media_type=? '
    'AND tmdb_id=? ORDER BY season_number ASC;',
    [configId, mediaType, tmdbId],
  );

  /// 删除单个季度进度（删除某季历史时使用，`02` §7.4）。
  int removeTmdbSeasonProgress({
    required int configId,
    required String mediaType,
    required int tmdbId,
    required int seasonNumber,
  }) {
    _db.execute(
      'DELETE FROM tmdb_season_progress WHERE config_id=? AND media_type=? '
      'AND tmdb_id=? AND season_number=?;',
      [configId, mediaType, tmdbId, seasonNumber],
    );
    return _db.updatedRows;
  }

  /// 删除整部节目的全部季度进度（「删除整部节目」二级操作，`02` §7.4）。
  int removeTmdbSeasonProgressForMedia({
    required int configId,
    required String mediaType,
    required int tmdbId,
  }) {
    _db.execute(
      'DELETE FROM tmdb_season_progress WHERE config_id=? AND media_type=? '
      'AND tmdb_id=?;',
      [configId, mediaType, tmdbId],
    );
    return _db.updatedRows;
  }

  /// 清空全部季度进度（「清空历史」使用；**保留**匹配与绑定，`03` §6.5）。
  int clearTmdbSeasonProgress() {
    _db.execute('DELETE FROM tmdb_season_progress;');
    return _db.updatedRows;
  }

  /// 列出某配置下的**全部**季度进度（历史投影，`02` §7.1）。
  List<Row> tmdbSeasonProgressAll({required int configId}) => _db.select(
    'SELECT * FROM tmdb_season_progress WHERE config_id=? '
    'ORDER BY updated_at DESC;',
    [configId],
  );

  /// 按关联的来源历史键查找季度进度（续播恢复用，`02` §6.3）。
  List<Row> tmdbSeasonProgressByHistory({
    required int configId,
    required String sourceHistoryKey,
  }) => _db.select(
    'SELECT * FROM tmdb_season_progress WHERE config_id=? AND '
    'source_history_key=? ORDER BY updated_at DESC;',
    [configId, sourceHistoryKey],
  );

  /// 原生 SQL 计数（健康度检查、集成测试使用）。
  int count(String table) =>
      _db.select('SELECT COUNT(*) AS c FROM $table;').first['c'] as int;

  /// `meta` 表中的 `schema_version` 值（迁移校验用）。
  String? get schemaVersionValue {
    final rows = _db.select(
      'SELECT value FROM meta WHERE key=?;',
      ['schema_version'],
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

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
