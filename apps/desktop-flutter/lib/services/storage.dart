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
import '../core/danmaku_match.dart';
import '../core/following.dart';
import '../core/protocol.dart';
import '../core/site_injection.dart';
import '../core/skip_segments.dart';
import '../core/source_key.dart';
import '../core/subtitle_provider.dart';

/// 归一化媒体类型：只认 `movie` / `tv`，其余回空串。
///
/// 对齐安卓 `History.normalizeMediaType` 的收敛方向——不认识的类型**不参与**
/// TMDB 聚合，避免电影与剧集命名空间里相同的数字 ID 被误合并。
String normalizeMediaTypeValue(String? raw) {
  final value = (raw ?? '').trim().toLowerCase();
  return value == 'movie' || value == 'tv' ? value : '';
}

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
    this.sourceKey = '',
    this.vodYear = '',
    this.tmdbId = 0,
    this.mediaType = '',
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

  /// 记录归属的播放源（见 core/source_key.dart）。
  ///
  /// 空串表示「迁移前/来源不明」：查询时对所有源可见，
  /// 保证升级后既有历史不凭空消失；下一次写入会重写成具体源。
  final String sourceKey;

  /// 作品年份（可空串）。用于同名聚合的年份消歧，见
  /// `core/history_grouping.dart`。
  final String vodYear;

  /// TMDB 数字 ID；0 = 未绑定（迁移前的旧行一律为 0，不回填猜测）。
  final int tmdbId;

  /// `movie` / `tv`；空串 = 未绑定。
  final String mediaType;

  /// 是否带可用的 TMDB 身份（ID 与类型都齐）。
  bool get hasTmdbIdentity =>
      tmdbId > 0 && (mediaType == 'movie' || mediaType == 'tv');

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
    sourceKey: (row['source_key'] as String?) ?? '',
    vodYear: (row['vod_year'] as String?) ?? '',
    tmdbId: (row['tmdb_id'] as int?) ?? 0,
    mediaType: (row['media_type'] as String?) ?? '',
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
    this.sourceKey = '',
    this.bridgeDevice = '',
    this.bridgeInterfaceKey = '',
    this.bridgeConfigUrl = '',
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

  /// 播放源身份（见 core/source_key.dart）。
  /// 桥接源形如 `bridge|<deviceUuid>|<interfaceKey>`，本机源形如 `local|<origin>`。
  final String sourceKey;

  /// 桥接设备地址（仅桥接源非空）。
  final String bridgeDevice;

  /// 安卓端 Config.interfaceKey（仅桥接源非空；空值表示旧协议记录）。
  final String bridgeInterfaceKey;

  /// 该源在安卓端的真实配置地址（/vod/api?ac=config&configKey=...）。
  ///
  /// 推送历史必须发这个值：空值表示不知道该源的安卓地址，
  /// 宁可不推送也不能发设备网关地址——安卓 Config.find 查不到就会 insert，
  /// 凭空多出一行「桥接源」。
  final String bridgeConfigUrl;

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
      sourceKey: (row['source_key'] as String?) ?? '',
      bridgeDevice: (row['bridge_device'] as String?) ?? '',
      bridgeInterfaceKey: (row['bridge_interface_key'] as String?) ?? '',
      bridgeConfigUrl: (row['bridge_config_url'] as String?) ?? '',
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
  ///   （`docs/phase5/design/02` §4.5）；
  /// - `3` → `4`：Phase 9 新增 `skip_segments`（片头片尾）、`subtitle_match`
  ///   与 `danmaku_match`（字幕/弹幕匹配记忆），见 `docs/phase9/design/01`–`02`；
  /// - `4` → `5`：Phase 9 站点注入（`injected_sites`），见 `README.md` P1-2；
  /// - `5` → `6`：Phase 9 追番（`following`），见 `README.md` P2-1；
  /// - `6` → `7`：播放源身份（`source_key`）。`configs` 加法式加列；
  ///   `history` 与 `history_deletions` 需要**重建表**——唯一键要从
  ///   `(site_key, …)` 扩成 `(source_key, site_key, …)`，而 SQLite 不能
  ///   `ALTER` 唯一约束。重建前先留 `history_backup_v6` 底表。
  /// - `7` → `8`：历史同名聚合所需的作品身份（`vod_year`、`tmdb_id`、
  ///   `media_type`）。**纯加法式**：三列默认值分别是空串 / 0 / 空串，
  ///   旧行升级后一律「身份未知」，聚合时自然回退到按片名分组。
  ///
  /// 除 v7 的两张表之外，升级都是**加法式**（`CREATE TABLE IF NOT EXISTS` 或
  /// `ALTER TABLE ADD COLUMN`）：旧库打开后自动获得新表/新列且不丢数据，
  /// 无需分支式升级逻辑。
  static const int schemaVersion = 8;

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
        source_key TEXT NOT NULL DEFAULT '',
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
        vod_year TEXT NOT NULL DEFAULT '',
        tmdb_id INTEGER NOT NULL DEFAULT 0,
        media_type TEXT NOT NULL DEFAULT '',
        UNIQUE(source_key, site_key, vod_id, flag, episode_id)
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
    _migratePlaybackExtras();
    _migrateSiteInjection();
    _migrateFollowing();
    _migrateSources();
    _migrateHistoryIdentity();
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
        source_key TEXT NOT NULL DEFAULT '',
        match_key TEXT NOT NULL,
        site_key TEXT NOT NULL DEFAULT '',
        vod_id TEXT NOT NULL DEFAULT '',
        flag TEXT NOT NULL DEFAULT '',
        episode_id TEXT NOT NULL DEFAULT '',
        deleted_at INTEGER NOT NULL,
        PRIMARY KEY(source_key, match_key)
      );
    ''');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_history_deletions_at '
      'ON history_deletions(deleted_at DESC);',
    );
  }

  /// Phase 9 · 播放增强的三张表（`docs/phase9/design/01`–`02`）。
  ///
  /// - `skip_segments`：按「影片」保存片头/片尾标记（不是按集：同一部剧各集
  ///   的片头片尾通常一致，按集存会让用户逐集标记）；
  /// - `subtitle_match` / `danmaku_match`：按「站点 + 影片 + 集名」记住用户
  ///   手动选择，避免每次播放都重新搜索。
  ///
  /// 全部加法式，不改既有表。
  void _migratePlaybackExtras() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS skip_segments (
        site_key TEXT NOT NULL,
        vod_id TEXT NOT NULL,
        opening_ms INTEGER,
        ending_ms INTEGER,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY(site_key, vod_id)
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS subtitle_match (
        site_key TEXT NOT NULL,
        vod_id TEXT NOT NULL,
        episode_name TEXT NOT NULL,
        provider_id TEXT NOT NULL,
        asset_id TEXT NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        language TEXT NOT NULL DEFAULT '',
        url TEXT NOT NULL DEFAULT '',
        updated_at INTEGER NOT NULL,
        PRIMARY KEY(site_key, vod_id, episode_name)
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS danmaku_match (
        site_key TEXT NOT NULL,
        vod_id TEXT NOT NULL,
        episode_name TEXT NOT NULL,
        provider_id TEXT NOT NULL,
        entry_id TEXT NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        episode TEXT NOT NULL DEFAULT '',
        url TEXT NOT NULL DEFAULT '',
        updated_at INTEGER NOT NULL,
        PRIMARY KEY(site_key, vod_id, episode_name)
      );
    ''');
  }

  /// Phase 9 · 站点注入表（`README.md` P1-2）。
  ///
  /// 注入站点与用户导入的配置**分开存放**：配置记录保持原样，注入在读取时合并，
  /// 删除注入即恢复原配置，不会污染导出/同步的配置 JSON。
  void _migrateSiteInjection() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS injected_sites (
        key TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        type INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        json TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');
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

  /// Phase 9 · 追番表（`docs/phase9/README.md` P2-1）。
  ///
  /// 主键 `(series_key, season)`：同一部剧的不同季各自一条。
  /// `has_update` / `unwatched` 不落库，由模型按水位实时算，避免两处漂移。
  void _migrateFollowing() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS following (
        series_key TEXT NOT NULL,
        season INTEGER NOT NULL DEFAULT 0,
        site_key TEXT NOT NULL,
        vod_id TEXT NOT NULL,
        vod_name TEXT NOT NULL,
        vod_pic TEXT,
        flag TEXT NOT NULL DEFAULT '',
        source_flag TEXT NOT NULL DEFAULT '',
        tracked_season INTEGER NOT NULL DEFAULT 0,
        latest_released_season INTEGER NOT NULL DEFAULT 0,
        latest_released_episode INTEGER NOT NULL DEFAULT 0,
        season_released_episodes INTEGER NOT NULL DEFAULT 0,
        season_total_episodes INTEGER NOT NULL DEFAULT 0,
        watched_episode INTEGER NOT NULL DEFAULT 0,
        read_watermark INTEGER NOT NULL DEFAULT 0,
        last_notified_episode INTEGER NOT NULL DEFAULT 0,
        last_notified_at INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT '',
        next_air_at INTEGER NOT NULL DEFAULT 0,
        next_check_at INTEGER NOT NULL DEFAULT 0,
        failure_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT NOT NULL DEFAULT '',
        latest_episode_name TEXT NOT NULL DEFAULT '',
        latest_episode_target TEXT NOT NULL DEFAULT '',
        metadata_updated_at INTEGER NOT NULL DEFAULT 0,
        last_checked_at INTEGER NOT NULL DEFAULT 0,
        enabled INTEGER NOT NULL DEFAULT 1,
        notify_enabled INTEGER NOT NULL DEFAULT 1,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY(series_key, season)
      );
    ''');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_following_next_check '
      'ON following(next_check_at ASC);',
    );
  }

  /// 6 → 7 · 播放源身份（`source_key`）。
  ///
  /// ## 为什么要重建 `history`
  ///
  /// 桥接多个源之后，两个源可以有**同名 `site_key`**（T4 站点 key 由源自己
  /// 定义，跨源不唯一）。旧的 `UNIQUE(site_key, vod_id, flag, episode_id)`
  /// 会让两个源的同一条记录互相覆盖——用户会看到「在看 A 源，B 源的进度被改了」。
  ///
  /// 唯一键必须变成 `(source_key, site_key, vod_id, flag, episode_id)`，
  /// 而 SQLite 无法 `ALTER` 唯一约束，只能「建新表 → 搬数据 → 换名」。
  ///
  /// ## 为什么先留底表
  ///
  /// `DROP TABLE` 之后数据就只剩一份。先 `CREATE TABLE history_backup_v6`
  /// 把 V6 的行原样存下来，迁移半途失败也能人工取证/回填。
  ///
  /// 全部步骤幂等：按 `PRAGMA table_info` 判断，重复打开旧库不会重复重建。
  void _migrateSources() {
    _addConfigColumn('source_key', "TEXT NOT NULL DEFAULT ''");
    _addConfigColumn('bridge_device', "TEXT NOT NULL DEFAULT ''");
    _addConfigColumn('bridge_interface_key', "TEXT NOT NULL DEFAULT ''");
    _addConfigColumn('bridge_config_url', "TEXT NOT NULL DEFAULT ''");
    _rebuildHistoryWithSourceKey();
    _rebuildHistoryDeletionsWithSourceKey();
  }

  /// 加法式加列：列已存在则跳过（`ALTER TABLE` 不能重复执行）。
  void _addConfigColumn(String name, String declaration) {
    final columns = _columnsOf('configs');
    if (columns.contains(name)) return;
    _db.execute('ALTER TABLE configs ADD COLUMN $name $declaration;');
  }

  Set<String> _columnsOf(String table) => _db
      .select('PRAGMA table_info($table);')
      .map((row) => row['name'] as String)
      .toSet();

  /// `history` 重建：唯一键加入 `source_key`。
  void _rebuildHistoryWithSourceKey() {
    if (_columnsOf('history').contains('source_key')) return;
    _db.execute('BEGIN IMMEDIATE;');
    try {
      _db.execute('CREATE TABLE history_backup_v6 AS SELECT * FROM history;');
      _db.execute('''
        CREATE TABLE history_v7 (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          source_key TEXT NOT NULL DEFAULT '',
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
          UNIQUE(source_key, site_key, vod_id, flag, episode_id)
        );
      ''');
      _db.execute('''
        INSERT INTO history_v7(
          id, source_key, site_key, vod_id, vod_name, vod_pic, flag,
          episode_name, episode_id, position_ms, duration_ms, completed,
          updated_at)
        SELECT id, '', site_key, vod_id, vod_name, vod_pic, flag,
          episode_name, episode_id, position_ms, duration_ms, completed,
          updated_at
        FROM history;
      ''');
      _db.execute('DROP TABLE history;');
      _db.execute('ALTER TABLE history_v7 RENAME TO history;');
      // `DROP TABLE` 会连带删掉旧索引，重建一次。
      _db.execute(
        'CREATE INDEX IF NOT EXISTS idx_history_updated '
        'ON history(updated_at DESC);',
      );
      _db.execute('COMMIT;');
    } catch (error) {
      _db.execute('ROLLBACK;');
      throw AppError(
        AppErrorKind.storage,
        '升级历史表（按源隔离）失败',
        detail: '$error',
        cause: error,
      );
    }
  }

  /// `history_deletions` 重建：删除墓碑也必须按源隔离。
  ///
  /// 不隔离的话，在 A 源删掉一条记录会连 B 源同 key 的记录一起挡住
  /// （墓碑键是 `siteKey\0vodId\0flag\0episodeId`，不含源）。
  void _rebuildHistoryDeletionsWithSourceKey() {
    if (_columnsOf('history_deletions').contains('source_key')) return;
    _db.execute('BEGIN IMMEDIATE;');
    try {
      _db.execute('''
        CREATE TABLE history_deletions_v7 (
          source_key TEXT NOT NULL DEFAULT '',
          match_key TEXT NOT NULL,
          site_key TEXT NOT NULL DEFAULT '',
          vod_id TEXT NOT NULL DEFAULT '',
          flag TEXT NOT NULL DEFAULT '',
          episode_id TEXT NOT NULL DEFAULT '',
          deleted_at INTEGER NOT NULL,
          PRIMARY KEY(source_key, match_key)
        );
      ''');
      _db.execute('''
        INSERT INTO history_deletions_v7(
          source_key, match_key, site_key, vod_id, flag, episode_id,
          deleted_at)
        SELECT '', match_key, site_key, vod_id, flag, episode_id, deleted_at
        FROM history_deletions;
      ''');
      _db.execute('DROP TABLE history_deletions;');
      _db.execute('ALTER TABLE history_deletions_v7 RENAME TO history_deletions;');
      _db.execute(
        'CREATE INDEX IF NOT EXISTS idx_history_deletions_at '
        'ON history_deletions(deleted_at DESC);',
      );
      _db.execute('COMMIT;');
    } catch (error) {
      _db.execute('ROLLBACK;');
      throw AppError(
        AppErrorKind.storage,
        '升级删除标记表（按源隔离）失败',
        detail: '$error',
        cause: error,
      );
    }
  }

  /// 7 → 8 · 历史同名聚合所需的作品身份（`vod_year` / `tmdb_id` / `media_type`）。
  ///
  /// ## 为什么是加法式而不是重建表
  ///
  /// 唯一键不需要变：聚合是**读视图**（`core/history_grouping.dart` 把多行
  /// 投影成一张卡），写入仍然是「每集一条记录」。重建表只会白白承担搬迁风险。
  ///
  /// ## 为什么旧行不回填
  ///
  /// 旧行确实没法可靠回填：历史表里没有 `tmdbId`，而按片名去反查 TMDB 属于
  /// 「猜」——安卓 §18 明确要求「不根据展示标题猜测回填」。这些行升级后
  /// 保持 `tmdb_id = 0`，聚合时走片名分组；用户下次播放到该作品时，
  /// 由播放器写入真实 TMDB 身份，那张卡自动升级为 TMDB 聚合。
  void _migrateHistoryIdentity() {
    _addHistoryColumn('vod_year', "TEXT NOT NULL DEFAULT ''");
    _addHistoryColumn('tmdb_id', 'INTEGER NOT NULL DEFAULT 0');
    _addHistoryColumn('media_type', "TEXT NOT NULL DEFAULT ''");
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_history_tmdb '
      'ON history(media_type, tmdb_id);',
    );
  }

  /// 加法式加列：列已存在则跳过（`ALTER TABLE` 不能重复执行）。
  void _addHistoryColumn(String name, String declaration) {
    final columns = _columnsOf('history');
    if (columns.contains(name)) return;
    _db.execute('ALTER TABLE history ADD COLUMN $name $declaration;');
  }
  // -------------------------------------------------------------------------
  // 追番（Phase 9 P2-1）
  // -------------------------------------------------------------------------

  List<Following> followings() => _db
      .select('SELECT * FROM following ORDER BY updated_at DESC;')
      .map(_followingFromRow)
      .toList();

  Following? following(String seriesKey, int season) {
    final rows = _db.select(
      'SELECT * FROM following WHERE series_key=? AND season=?;',
      [seriesKey, season],
    );
    return rows.isEmpty ? null : _followingFromRow(rows.first);
  }

  Following? followingByVod(String siteKey, String vodId) {
    final rows = _db.select(
      'SELECT * FROM following WHERE site_key=? AND vod_id=? '
      'ORDER BY season ASC LIMIT 1;',
      [siteKey, vodId],
    );
    return rows.isEmpty ? null : _followingFromRow(rows.first);
  }

  void upsertFollowing(Following item) {
    _db.execute(
      'INSERT INTO following('
      'series_key, season, site_key, vod_id, vod_name, vod_pic, flag, '
      'source_flag, tracked_season, latest_released_season, '
      'latest_released_episode, season_released_episodes, '
      'season_total_episodes, watched_episode, read_watermark, '
      'last_notified_episode, last_notified_at, status, next_air_at, '
      'next_check_at, failure_count, last_error, metadata_updated_at, '
      'last_checked_at, enabled, notify_enabled, created_at, updated_at, '
      'latest_episode_name, latest_episode_target'
      ') VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) '
      'ON CONFLICT(series_key, season) DO UPDATE SET '
      'site_key=excluded.site_key, vod_id=excluded.vod_id, '
      'vod_name=excluded.vod_name, vod_pic=excluded.vod_pic, '
      'flag=excluded.flag, source_flag=excluded.source_flag, '
      'tracked_season=excluded.tracked_season, '
      'latest_released_season=excluded.latest_released_season, '
      'latest_released_episode=excluded.latest_released_episode, '
      'season_released_episodes=excluded.season_released_episodes, '
      'season_total_episodes=excluded.season_total_episodes, '
      'watched_episode=excluded.watched_episode, '
      'read_watermark=excluded.read_watermark, '
      'last_notified_episode=excluded.last_notified_episode, '
      'last_notified_at=excluded.last_notified_at, status=excluded.status, '
      'next_air_at=excluded.next_air_at, next_check_at=excluded.next_check_at, '
      'failure_count=excluded.failure_count, last_error=excluded.last_error, '
      'metadata_updated_at=excluded.metadata_updated_at, '
      'last_checked_at=excluded.last_checked_at, enabled=excluded.enabled, '
      'notify_enabled=excluded.notify_enabled, created_at=excluded.created_at, '
      'latest_episode_name=excluded.latest_episode_name, '
      'latest_episode_target=excluded.latest_episode_target, '
      'updated_at=excluded.updated_at;',
      [
        item.seriesKey,
        item.season,
        item.siteKey,
        item.vodId,
        item.vodName,
        item.vodPic,
        item.flag,
        item.sourceFlag,
        item.trackedSeason,
        item.latestReleasedSeason,
        item.latestReleasedEpisode,
        item.seasonReleasedEpisodes,
        item.seasonTotalEpisodes,
        item.watchedEpisode,
        item.readWatermarkEpisode,
        item.lastNotifiedEpisode,
        item.lastNotifiedAtMs,
        item.status,
        item.nextAirAtMs,
        item.nextCheckAtMs,
        item.failureCount,
        item.lastError,
        item.metadataUpdatedAtMs,
        item.lastCheckedAtMs,
        item.enabled ? 1 : 0,
        item.notifyEnabled ? 1 : 0,
        item.createdAtMs,
        item.updatedAtMs,
        item.latestEpisodeName,
        item.latestEpisodeTarget,
      ],
    );
  }

  void deleteFollowing(String seriesKey, int season) {
    _db.execute(
      'DELETE FROM following WHERE series_key=? AND season=?;',
      [seriesKey, season],
    );
  }

  int followingCount() =>
      _db.select('SELECT COUNT(*) AS c FROM following;').first['c'] as int;

  static Following _followingFromRow(Row row) => Following(
    seriesKey: row['series_key'] as String,
    season: row['season'] as int,
    siteKey: row['site_key'] as String,
    vodId: row['vod_id'] as String,
    vodName: row['vod_name'] as String,
    vodPic: row['vod_pic'] as String?,
    flag: row['flag'] as String? ?? '',
    sourceFlag: row['source_flag'] as String? ?? '',
    trackedSeason: row['tracked_season'] as int? ?? 0,
    latestReleasedSeason: row['latest_released_season'] as int? ?? 0,
    latestReleasedEpisode: row['latest_released_episode'] as int? ?? 0,
    seasonReleasedEpisodes: row['season_released_episodes'] as int? ?? 0,
    seasonTotalEpisodes: row['season_total_episodes'] as int? ?? 0,
    watchedEpisode: row['watched_episode'] as int? ?? 0,
    readWatermarkEpisode: row['read_watermark'] as int? ?? 0,
    lastNotifiedEpisode: row['last_notified_episode'] as int? ?? 0,
    lastNotifiedAtMs: row['last_notified_at'] as int? ?? 0,
    status: FollowingStatus.normalize(row['status'] as String?),
    nextAirAtMs: row['next_air_at'] as int? ?? 0,
    nextCheckAtMs: row['next_check_at'] as int? ?? 0,
    failureCount: row['failure_count'] as int? ?? 0,
    lastError: row['last_error'] as String? ?? '',
    metadataUpdatedAtMs: row['metadata_updated_at'] as int? ?? 0,
    lastCheckedAtMs: row['last_checked_at'] as int? ?? 0,
    latestEpisodeName: row['latest_episode_name'] as String? ?? '',
    latestEpisodeTarget: row['latest_episode_target'] as String? ?? '',
    enabled: (row['enabled'] as int? ?? 1) != 0,
    notifyEnabled: (row['notify_enabled'] as int? ?? 1) != 0,
    createdAtMs: row['created_at'] as int? ?? 0,
    updatedAtMs: row['updated_at'] as int? ?? 0,
  );

  void dispose() => _db.close();

  /// 生成一致性快照（SQLite `VACUUM INTO`）。
  ///
  /// 直接复制正在写入的 `.sqlite3` 可能拿到半个事务；`VACUUM INTO`
  /// 由 SQLite 自己保证快照一致。目标文件必须不存在，这里先删。
  void backupTo(String path) {
    final target = File(path);
    if (target.existsSync()) target.deleteSync();
    final escaped = path.replaceAll("'", "''");
    _db.execute("VACUUM INTO '$escaped';");
  }

  // -------------------------------------------------------------------------
  // 配置
  // -------------------------------------------------------------------------

  /// 保存或更新配置记录。
  ///
  /// ## 去重键：优先 `source_key`，退化为 `origin`
  ///
  /// 单机源（`local|<origin>`）的 `origin` 就是配置地址，天然唯一。
  /// **桥接源不行**：同一台安卓设备上的多个源 `origin` 全是设备网关地址，
  /// 按 `origin` 去重会让第二个源覆盖掉第一个——用户看到「导入后只有最后一个
  /// 源」。所以调用方给出了 [sourceKey] 时按它去重，未给出时才退回旧语义（§7.5）。
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
    String sourceKey = '',
    String bridgeDevice = '',
    String bridgeInterfaceKey = '',
    String bridgeConfigUrl = '',
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.execute('BEGIN IMMEDIATE;');
    try {
      final existing = _existingConfigIdForWrite(
        sourceKey: sourceKey,
        origin: origin,
      );
      int id;
      if (existing != null) {
        id = existing;
        _db.execute(
          'UPDATE configs SET name=?, origin=?, content_type=?, '
          'repository_index=?, repository_entries=?, json=?, site_count=?, '
          'live_count=?, updated_at=?, '
          // 空 `source_key` 不清掉已有的值：本机源以前存过空串，后来补上了
          // `local|<origin>`，任何一次「按 origin 覆盖写」都不该把这层身份抹回去。
          'source_key=COALESCE(NULLIF(?, \'\'), source_key), '
          'bridge_device=?, '
          'bridge_interface_key=?, bridge_config_url=? WHERE id=?;',
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
            sourceKey,
            bridgeDevice,
            bridgeInterfaceKey,
            bridgeConfigUrl,
            id,
          ],
        );
      } else {
        _db.execute(
          'INSERT INTO configs(name, origin, content_type, repository_index, '
          'repository_entries, json, site_count, live_count, is_active, '
          'updated_at, source_key, bridge_device, bridge_interface_key, '
          'bridge_config_url) VALUES(?,?,?,?,?,?,?,?,0,?,?,?,?,?);',
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
            sourceKey,
            bridgeDevice,
            bridgeInterfaceKey,
            bridgeConfigUrl,
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

  /// 写入前的去重查找：给出 [sourceKey] 时按它查，否则按 [origin] 查。
  ///
  /// 为什么本机源还要多看一眼 `origin`：老记录的 `source_key` 是空串，光按
  /// `source_key` 查会把「重新导入同一份配置」变成**新增一条**，用户会在配置
  /// 列表里看到两份一样的源。
  ///
  /// **桥接源绝不按 origin 回退**：同一台设备上的多个源 origin 全是设备网关
  /// 地址，按它兜底会让第二个源覆盖掉第一个（`saveConfig` 注释里记过的坑）。
  int? _existingConfigIdForWrite({
    required String sourceKey,
    required String origin,
  }) {
    if (sourceKey.isNotEmpty) {
      final byKey = _db.select(
        'SELECT id FROM configs WHERE source_key = ? LIMIT 1;',
        [sourceKey],
      );
      if (byKey.isNotEmpty) return byKey.first['id'] as int;
      if (!parseSourceKey(sourceKey).isLocal) return null;
    }
    final byOrigin = _db.select(
      'SELECT id FROM configs WHERE origin = ? LIMIT 1;',
      [origin],
    );
    return byOrigin.isEmpty ? null : byOrigin.first['id'] as int;
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

  /// 只改名称/地址，不碰配置内容（`json`、站点数、更新时间都不动）。
  ///
  /// 为什么不复用 [saveConfig]：那个方法按 `source_key`/`origin` 去重，
  /// 改地址时会**查不到原记录**而新插一条，等于用户改个地址就多出一份配置。
  /// 编辑是「就地修改这一条」，必须按主键 id 直达。
  ///
  /// [origin] 为 null 表示只改名。改地址必须调用方先验证成功再传——
  /// 这里不做网络请求，也不回滚，写完就是新的真相。
  void updateConfigIdentity(
    int id, {
    required String name,
    String? origin,
    String? sourceKey,
  }) {
    _db.execute('BEGIN IMMEDIATE;');
    try {
      if (origin == null) {
        _db.execute('UPDATE configs SET name=? WHERE id=?;', [name, id]);
      } else {
        _db.execute(
          'UPDATE configs SET name=?, origin=?, source_key=? '
          'WHERE id=?;',
          [name, origin, sourceKey ?? LocalSourceKey.of(origin), id],
        );
      }
      _db.execute('COMMIT;');
    } catch (error) {
      _db.execute('ROLLBACK;');
      throw AppError(
        AppErrorKind.storage,
        '更新配置记录失败',
        detail: '$error',
        cause: error,
      );
    }
  }

  /// 用重新拉取到的内容覆盖同一条记录（刷新）。
  ///
  /// 与 [saveConfig] 的区别同样是「按 id 直达」：刷新是让**现有这条**记录
  /// 换上最新内容，绝不能因为地址变了就另起一条，否则用户每刷新一次列表就
  /// 长一条。`updated_at` 由这里统一刷新，调用方不必自己算时间。
  void refreshConfigContent(
    int id, {
    required Map<String, Object?> json,
    required int siteCount,
    required int liveCount,
    String? contentType,
    String? origin,
    String? sourceKey,
  }) {
    _db.execute('BEGIN IMMEDIATE;');
    try {
      _db.execute(
        'UPDATE configs SET json=?, site_count=?, live_count=?, '
        'content_type=?, origin=COALESCE(?, origin), '
        'source_key=COALESCE(?, source_key), updated_at=? WHERE id=?;',
        [
          jsonEncode(json),
          siteCount,
          liveCount,
          contentType,
          origin,
          sourceKey,
          DateTime.now().millisecondsSinceEpoch,
          id,
        ],
      );
      _db.execute('COMMIT;');
    } catch (error) {
      _db.execute('ROLLBACK;');
      throw AppError(
        AppErrorKind.storage,
        '保存刷新结果失败',
        detail: '$error',
        cause: error,
      );
    }
  }

  /// 按 `source_key` 查配置记录（桥接源的身份查询）。
  ///
  /// ## 为什么还要按 `origin` 兜底
  ///
  /// 早期版本导入**本机配置**时没有写 `source_key`（那一列是加法式加的），
  /// 但历史行的 `source_key` 一直是按「本机源 = `local|<origin>`」推导写入的。
  /// 于是老数据上 `configs.source_key` 是空串、历史里却是 `local|http://…`，
  /// 两边永远对不上——用户看到的表现就是来源标成「其他来源」、点进去还被告知
  /// 「原播放源已删除」（用户 2026-11 反馈）。
  ///
  /// 所以这里在精确查询落空后，用 `local|<origin>` 反解 origin 再查一次。
  /// 只对**本机源**这样做：桥接源多个配置共用一个设备 origin，按 origin 兜底
  /// 会把它们混成一个（那正是 `saveConfig` 注释里记过的坑）。
  ConfigRecord? configBySourceKey(String sourceKey) {
    final key = sourceKey.trim();
    if (key.isEmpty) return null;
    final rows = _db.select(
      'SELECT * FROM configs WHERE source_key = ? LIMIT 1;',
      [key],
    );
    if (rows.isNotEmpty) return ConfigRecord.fromRow(rows.first);
    final parsed = parseSourceKey(key);
    if (!parsed.isLocal) return null;
    final byOrigin = _db.select(
      'SELECT * FROM configs WHERE origin = ? LIMIT 1;',
      [parsed.origin],
    );
    return byOrigin.isEmpty ? null : ConfigRecord.fromRow(byOrigin.first);
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
    String sourceKey = '',
    String vodYear = '',
    int tmdbId = 0,
    String mediaType = '',
  }) {
    final isCompleted =
        completed ??
        (durationMs > 0 && positionMs >= durationMs - 5000);
    // 迁移前的记录 `source_key` 为空串（对所有源可见）。首次以具体源写回时
    // 把它**收编**为该源的行，而不是新增一行——否则用户升级后会看到两条
    // 一模一样的记录。收编后旧的空串墓碑也要清掉，否则它会挡住这条记录。
    if (sourceKey.isNotEmpty) {
      _adoptLegacyHistoryRow(
        sourceKey: sourceKey,
        siteKey: siteKey,
        vodId: vodId,
        flag: flag,
        episodeId: episodeId,
      );
    }
    _db.execute(
      'INSERT INTO history(source_key, site_key, vod_id, vod_name, vod_pic, '
      'flag, episode_name, episode_id, position_ms, duration_ms, completed, '
      'updated_at, vod_year, tmdb_id, media_type) '
      'VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) '
      'ON CONFLICT(source_key, site_key, vod_id, flag, episode_id) DO UPDATE SET '
      'vod_name=excluded.vod_name, vod_pic=excluded.vod_pic, '
      'episode_name=excluded.episode_name, position_ms=excluded.position_ms, '
      'duration_ms=excluded.duration_ms, completed=excluded.completed, '
      'updated_at=excluded.updated_at, '
      // 身份列只在**本次拿到真实值**时覆盖：同步来的记录不带 TMDB 身份，
      // 若无条件覆盖会把播放器刚写好的身份抹掉（那张卡会从 TMDB 聚合退回片名聚合）。
      'vod_year=CASE WHEN excluded.vod_year = \'\' THEN history.vod_year '
      'ELSE excluded.vod_year END, '
      'tmdb_id=CASE WHEN excluded.tmdb_id = 0 THEN history.tmdb_id '
      'ELSE excluded.tmdb_id END, '
      'media_type=CASE WHEN excluded.media_type = \'\' THEN history.media_type '
      'ELSE excluded.media_type END;',
      [
        sourceKey,
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
        vodYear.trim(),
        tmdbId,
        // 只认 movie / tv：留个坏值进来会让聚合键分裂成第三种命名空间。
        normalizeMediaTypeValue(mediaType),
      ],
    );
    // 写入即意味着这条记录重新存在，删除标记不再有意义。
    // `openingMs` / `endingMs` 目前只用于本地播放器行为，不入本表
    // （PC 有独立的 open/end 设置），此处接收只为签名向后兼容与调用方对称。
    final matchKey = SyncHistoryItem.fromLocal(
      siteKey: siteKey,
      vodId: vodId,
      vodName: vodName,
      flag: flag,
      episodeName: episodeName,
      episodeId: episodeId,
      positionMs: positionMs,
      durationMs: durationMs,
      updatedAt: updatedAt ?? DateTime.now().millisecondsSinceEpoch,
    ).matchKey;
    _forgetHistoryDeletion(matchKey, sourceKey: sourceKey);
    // 收编后空串墓碑同样失效（见上）。
    if (sourceKey.isNotEmpty) _forgetHistoryDeletion(matchKey);
  }

  /// 把迁移前的空 `source_key` 行收编为 [sourceKey]（见 [upsertHistory]）。
  void _adoptLegacyHistoryRow({
    required String sourceKey,
    required String siteKey,
    required String vodId,
    required String flag,
    required String episodeId,
  }) {
    _db.execute(
      'UPDATE history SET source_key = ? WHERE source_key = \'\' '
      'AND site_key = ? AND vod_id = ? AND flag = ? AND episode_id = ?;',
      [sourceKey, siteKey, vodId, flag, episodeId],
    );
  }

  /// 最近历史。
  ///
  /// [sourceKey] 为空 = 全局视图（所有源）；非空 = 只看该源。
  /// 默认视图里的「当前源」由 UI 层从当前激活配置推导后传进来——
  /// 存储层不猜「哪个源是当前源」，否则同一份数据在两种上下文里会有两种含义。
  ///
  /// 空 `source_key` 行（迁移前的老记录、实时同步写入的记录）**只**出现在
  /// 全局视图里：按源隔离时把它们放进来，用户会在「当前来源」下看到一堆
  /// 无法归属的「来源未知」卡片，而这正是用户 2026-10-28 反馈的缺陷。
  /// 严格过滤的代价是老记录暂时从按源视图消失——全局视图仍然可见，且它
  /// 一旦被播放或被 `_adoptLegacyHistoryRow` 收编就自动归属到具体源。
  List<PlaybackHistory> recentHistory({int limit = 100, String sourceKey = ''}) =>
      _db
          .select(
            'SELECT * FROM history WHERE (? = \'\' OR source_key = ?) '
            'ORDER BY updated_at DESC LIMIT ?;',
            [sourceKey, sourceKey, limit],
          )
          .map(PlaybackHistory.fromRow)
          .toList();

  /// 某部剧的全部播放历史（追番「已看集数」回写用，最新在前）。
  ///
  /// 不按 `source_key` 过滤：追番本身没有源的概念，同一部剧的历史可能分散在
  /// 多个源下，只看当前源会让已看集数凭空变少。
  List<PlaybackHistory> historyForVod({
    required String siteKey,
    required String vodId,
  }) => _db
      .select(
        'SELECT * FROM history WHERE site_key=? AND vod_id=? '
        'ORDER BY updated_at DESC;',
        [siteKey, vodId],
      )
      .map(PlaybackHistory.fromRow)
      .toList();

  /// 历史行数（[sourceKey] 为空 = 全部；非空 = 只数该源）。
  ///
  /// 用途只有一个：「当前来源」为空时，页面上要能说清**是不是真的没历史**。
  /// 没有这个计数就只能写「暂无播放记录」，而按源严格过滤后它常常是假话
  /// （全部来源里明明有一屏）。
  int historyCount({String sourceKey = ''}) => _db.select(
    'SELECT COUNT(*) AS c FROM history WHERE (? = \'\' OR source_key = ?);',
    [sourceKey, sourceKey],
  ).first['c'] as int;

  /// 归属不到任何源的历史行数（`source_key = ''`）。
  ///
  /// 这些行是迁移前的老记录和实时同步时判不出来源的记录，**只**出现在
  /// 全局视图里（见 [recentHistory]）。空态要用它说清「当前来源为空」到底
  /// 是没记录，还是记录在但归属不到源。
  int unclaimedHistoryCount() => _db.select(
    'SELECT COUNT(*) AS c FROM history WHERE source_key = \'\';',
  ).first['c'] as int;

  /// 历史搜索：按片名与剧集名做包含匹配（§15.2）。
  ///
  /// 使用 `instr()` 而不是 `LIKE`：`instr` 是纯子串匹配，用户输入的 `%`、`_`、`\`
  /// 不会被当成通配符或转义符，也就不存在 LIKE 转义控制符写错的风险。
  List<PlaybackHistory> searchHistory(
    String keyword, {
    int limit = 100,
    String sourceKey = '',
  }) {
    return _db
        .select(
          'SELECT * FROM history '
          'WHERE (? = \'\' OR source_key = ?) '
          'AND (instr(vod_name, ?) > 0 OR instr(episode_name, ?) > 0) '
          'ORDER BY updated_at DESC LIMIT ?;',
          [sourceKey, sourceKey, keyword, keyword, limit],
        )
        .map(PlaybackHistory.fromRow)
        .toList();
  }

  /// 查询某条历史（续播用）。
  ///
  /// ## 为什么要集名兜底
  ///
  /// `history.episode_id` 有**两种互不兼容的语义**（同一列，看写入方）：
  ///
  /// | 写入方 | `episode_id` 存的值 |
  /// | --- | --- |
  /// | 本地播放（`player_page.dart`） | **站点入口 URL**（`episodeTarget`） |
  /// | 同步落库（`_writeSyncHistory`） | 安卓 `episodeId` = **episodeUrl 的 SHA-256** |
  ///
  /// 而续播查询传的是站点入口 URL，于是同步来的记录 `WHERE episode_id = ?`
  /// **永远命不中** → 用户实报「手动拉取的历史点开从头开始播」。
  ///
  /// ## 匹配顺序（只有两级，且都要求“对得上”而不是“猜”）
  ///
  /// 1. **`episode_id` 精确命中**：语义与旧实现完全一致；
  /// 2. **`episode_name` 精确命中**（仅当给了 [episodeName] 且第 1 步落空）。
  ///
  /// ## 为什么**没有**「唯一记录」兜底
  ///
  /// 曾实现过“同剧同线路只剩一条记录就用它”。但那是**错续播**：
  /// 用户点开第 5 集（而库内只有第 3 集的记录）时，会把他送到第 3 集的
  /// 进度上。既有用例 `phase2_resume_test` 的
  /// 「按 flag 与 episodeId 精确匹配，不同剧集互不串扰」明确锁住了这条：
  /// 查不存在的集必须回 `null`。
  ///
  /// 取舍依据：`design/01` §4.1——**宁可不续播，不可错续播**。
  /// 集名对不上时，从 0 开始是安全失败；续到别的集是数据损坏级体验。
  PlaybackHistory? findHistory({
    required String siteKey,
    required String vodId,
    String? flag,
    String? episodeId,
    String? episodeName,
    String sourceKey = '',
  }) {
    // ── 第 1 步：精确（旧行为，语义不变；sourceKey 为空则不按源过滤） ──
    final exact = _db.select(
      'SELECT * FROM history WHERE site_key=? AND vod_id=? '
      'AND (? = \'\' OR source_key = ?) '
      'AND (? IS NULL OR flag = ?) AND (? IS NULL OR episode_id = ?) '
      'ORDER BY updated_at DESC LIMIT 1;',
      [siteKey, vodId, sourceKey, sourceKey, flag, flag, episodeId, episodeId],
    );
    if (exact.isNotEmpty) return PlaybackHistory.fromRow(exact.first);

    // 第 2 步只在「给了 episodeId 但没命中 + 有集名可依据」时起作用。
    // 未给 episodeId 时保持旧行为（上面第 1 步已按 flag 取最新一条）。
    if (episodeId == null) return null;
    final name = (episodeName ?? '').trim();
    if (name.isEmpty) return null;

    // ── 第 2 步：按集名兜底（同步记录的 episode_id 是哈希，只能靠集名对上） ──
    final byName = _db.select(
      'SELECT * FROM history WHERE site_key=? AND vod_id=? '
      'AND (? = \'\' OR source_key = ?) '
      'AND (? IS NULL OR flag = ?) AND episode_name = ? '
      'ORDER BY updated_at DESC LIMIT 1;',
      [siteKey, vodId, sourceKey, sourceKey, flag, flag, name],
    );
    return byName.isEmpty ? null : PlaybackHistory.fromRow(byName.first);
  }

  void deleteHistory(int id) {
    final rows = _db.select(
      'SELECT source_key, site_key, vod_id, flag, episode_id '
      'FROM history WHERE id = ?;',
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
  void clearHistory({String sourceKey = ''}) {
    final rows = sourceKey.isEmpty
        ? _db.select(
            'SELECT source_key, site_key, vod_id, flag, episode_id '
            'FROM history;',
          )
        : _db.select(
            'SELECT source_key, site_key, vod_id, flag, episode_id '
            'FROM history WHERE source_key = ? OR source_key = \'\';',
            [sourceKey],
          );
    for (final row in rows) {
      _rememberDeletionOfRow(row);
    }
    if (sourceKey.isEmpty) {
      _db.execute('DELETE FROM history;');
      return;
    }
    _db.execute(
      'DELETE FROM history WHERE source_key = ? OR source_key = \'\';',
      [sourceKey],
    );
  }

  // -------------------------------------------------------------------------
  // Phase 5 · 同步合并与删除标记（`docs/phase5/design/02` §4.4 / §4.5）
  // -------------------------------------------------------------------------

  /// 本地历史索引：合并匹配键 → 记录（供 [buildHistoryMergePlan] 使用）。
  ///
  /// 匹配键是 `(siteKey, vodId, flag, episodeId)`，**不含 `cid`**
  /// （`design/02` §4.3）——这与 `history` 表的 `UNIQUE` 约束一致。
  Map<String, SyncHistoryItem> historySyncIndex({String sourceKey = ''}) {
    final result = <String, SyncHistoryItem>{};
    for (final history in recentHistory(limit: 100000, sourceKey: sourceKey)) {
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
  Map<String, int> historyDeletionIndex({String sourceKey = ''}) => {
    for (final row in sourceKey.isEmpty
        ? _db.select(
            'SELECT match_key, deleted_at FROM history_deletions;',
          )
        : _db.select(
            'SELECT match_key, deleted_at FROM history_deletions '
            'WHERE source_key = ? OR source_key = \'\';',
            [sourceKey],
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
  SyncMergeStats applyHistoryMerge(SyncMergePlan plan, {String sourceKey = ''}) {
    var applied = 0;
    var failed = plan.failures.length;
    for (final item in plan.applied) {
      try {
        _writeSyncHistory(item, sourceKey: sourceKey);
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
  void _writeSyncHistory(SyncHistoryItem item, {String sourceKey = ''}) {
    upsertHistory(
      sourceKey: sourceKey,
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
    String sourceKey = '',
  }) {
    _db.execute(
      'INSERT INTO history_deletions(source_key, match_key, site_key, vod_id, '
      'flag, episode_id, deleted_at) VALUES(?,?,?,?,?,?,?) '
      'ON CONFLICT(source_key, match_key) DO UPDATE SET '
      'deleted_at=excluded.deleted_at;',
      [
        sourceKey,
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
    final sourceKey = (row['source_key'] as String?) ?? '';
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
      sourceKey: sourceKey,
    );
  }

  void _forgetHistoryDeletion(String matchKey, {String sourceKey = ''}) =>
      _db.execute(
        'DELETE FROM history_deletions WHERE source_key = ? AND match_key = ?;',
        [sourceKey, matchKey],
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
    int? updatedAt,
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
        // 本地收藏用 `now()`；同步写入必须用远端 `createTime`
        // （同 `upsertHistory` 的理由，`docs/phase5/design/02` §3.4）。
        updatedAt ?? DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  /// 收藏索引：合并匹配键 → 本地 `updated_at`（供
  /// [buildFavoriteMergePlan] 使用）。
  Map<String, int> favoriteSyncIndex() => {
    for (final row in _db.select(
      'SELECT kind, site_key, target_id, updated_at FROM favorites;',
    ))
      '${row['kind']}\x00${row['site_key']}\x00${row['target_id']}':
          row['updated_at'] as int,
  };

  /// 执行收藏合并计划（`design/02` §4.4：“旧不覆盖新”）。
  SyncMergeStats applyFavoriteMerge(SyncFavoriteMergePlan plan) {
    var applied = 0;
    var failed = plan.failures.length;
    for (final item in plan.applied) {
      try {
        upsertFavorite(
          kind: item.kind,
          siteKey: item.siteKey,
          targetId: item.targetId,
          title: item.title,
          subtitle: item.subtitle,
          updatedAt: item.updatedAt,
        );
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
      'skip_segments',
      'subtitle_match',
      'danmaku_match',
      'injected_sites',
      'following',
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

  /// 跨配置读取 TMDB 缓存里的海报地址。
  ///
  /// 为什么忽略 [configId]：历史记录可能属于**非生效配置**（桥接源、被切换
  /// 掉的源），而 `DatabaseTmdbMatchStore` 被 `config_id` 绑在生效配置上，
  /// 读不到那些行。补图的场景只关心「这张图有没有」，不关心它当初属于哪份
  /// 配置，所以这里不按配置收窄——按 `manual` 优先、再按新到旧取第一条。
  String? tmdbPosterUrlAcrossConfigs({
    required String siteKey,
    required String vodId,
  }) {
    final rows = _db.select(
      'SELECT poster_url FROM tmdb_matches WHERE site_key=? AND vod_id=? '
      "AND poster_url IS NOT NULL AND TRIM(poster_url)<>'' "
      'ORDER BY manual DESC, matched_at DESC LIMIT 1;',
      [siteKey, vodId],
    );
    if (rows.isEmpty) return null;
    final poster = (rows.first['poster_url'] as String?)?.trim();
    return (poster == null || poster.isEmpty) ? null : poster;
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

  // -------------------------------------------------------------------------
  // Phase 9 · 站点注入（`README.md` P1-2）
  // -------------------------------------------------------------------------

  List<InjectedSiteEntry> injectedSites() {
    return _db
        .select('SELECT * FROM injected_sites ORDER BY updated_at DESC;')
        .map((row) {
          try {
            return InjectedSiteEntry.fromRow(row);
          } catch (_) {
            return null;
          }
        })
        .whereType<InjectedSiteEntry>()
        .toList();
  }

  void upsertInjectedSite(InjectedSiteEntry entry) {
    _db.execute(
      'INSERT INTO injected_sites(key, name, type, enabled, json, updated_at) '
      'VALUES(?,?,?,?,?,?) '
      'ON CONFLICT(key) DO UPDATE SET name=excluded.name, type=excluded.type, '
      'enabled=excluded.enabled, json=excluded.json, '
      'updated_at=excluded.updated_at;',
      [
        entry.key,
        entry.site.name,
        entry.site.type,
        entry.enabled ? 1 : 0,
        jsonEncode(entry.site.toJson()),
        entry.updatedAt,
      ],
    );
  }

  void deleteInjectedSite(String key) {
    _db.execute('DELETE FROM injected_sites WHERE key=?;', [key]);
  }

  // -------------------------------------------------------------------------
  // Phase 9 · 片头片尾标记 / 字幕与弹幕匹配记忆（`docs/phase9/design/01`–`02`）
  // -------------------------------------------------------------------------

  /// 读取某部影片的片头/片尾标记；没有记录时返回空。
  SkipSegments skipSegmentsFor({
    required String siteKey,
    required String vodId,
  }) {
    final rows = _db.select(
      'SELECT opening_ms, ending_ms FROM skip_segments '
      'WHERE site_key=? AND vod_id=? LIMIT 1;',
      [siteKey, vodId],
    );
    if (rows.isEmpty) return const SkipSegments.none();
    final row = rows.first;
    return SkipSegments.fromMs(
      openingMs: row['opening_ms'],
      endingMs: row['ending_ms'],
    );
  }

  /// 写入/覆盖片头片尾标记。传 null 表示清除该侧标记。
  void upsertSkipSegments({
    required String siteKey,
    required String vodId,
    int? introEndMs,
    int? outroStartMs,
    int? updatedAt,
  }) {
    final intro = _positiveOrNull(introEndMs);
    final outro = _positiveOrNull(outroStartMs);
    if (intro == null && outro == null) {
      deleteSkipSegments(siteKey: siteKey, vodId: vodId);
      return;
    }
    _db.execute(
      'INSERT INTO skip_segments(site_key, vod_id, opening_ms, ending_ms, updated_at) '
      'VALUES(?,?,?,?,?) '
      'ON CONFLICT(site_key, vod_id) DO UPDATE SET '
      'opening_ms=excluded.opening_ms, ending_ms=excluded.ending_ms, '
      'updated_at=excluded.updated_at;',
      [
        siteKey,
        vodId,
        intro,
        outro,
        updatedAt ?? DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  /// 删除某部影片的标记。
  void deleteSkipSegments({required String siteKey, required String vodId}) {
    _db.execute(
      'DELETE FROM skip_segments WHERE site_key=? AND vod_id=?;',
      [siteKey, vodId],
    );
  }

  /// 读写字幕匹配记忆（键：站点 + 影片 + 集名）。
  SubtitleMatchRecord? subtitleMatchFor({
    required String siteKey,
    required String vodId,
    required String episodeName,
  }) {
    final rows = _db.select(
      'SELECT * FROM subtitle_match WHERE site_key=? AND vod_id=? '
      'AND episode_name=? LIMIT 1;',
      [siteKey, vodId, episodeName],
    );
    return rows.isEmpty ? null : SubtitleMatchRecord.fromRow(rows.first);
  }

  void upsertSubtitleMatch(SubtitleMatchRecord record) {
    _db.execute(
      'INSERT INTO subtitle_match(site_key, vod_id, episode_name, provider_id, '
      'asset_id, title, language, url, updated_at) VALUES(?,?,?,?,?,?,?,?,?) '
      'ON CONFLICT(site_key, vod_id, episode_name) DO UPDATE SET '
      'provider_id=excluded.provider_id, asset_id=excluded.asset_id, '
      'title=excluded.title, language=excluded.language, url=excluded.url, '
      'updated_at=excluded.updated_at;',
      [
        record.siteKey,
        record.vodId,
        record.episodeName,
        record.providerId,
        record.assetId,
        record.title,
        record.language,
        record.url,
        record.updatedAt,
      ],
    );
  }

  void deleteSubtitleMatch({
    required String siteKey,
    required String vodId,
    required String episodeName,
  }) {
    _db.execute(
      'DELETE FROM subtitle_match WHERE site_key=? AND vod_id=? '
      'AND episode_name=?;',
      [siteKey, vodId, episodeName],
    );
  }

  /// 读写弹幕匹配记忆。
  DanmakuMatchRecord? danmakuMatchFor({
    required String siteKey,
    required String vodId,
    required String episodeName,
  }) {
    final rows = _db.select(
      'SELECT * FROM danmaku_match WHERE site_key=? AND vod_id=? '
      'AND episode_name=? LIMIT 1;',
      [siteKey, vodId, episodeName],
    );
    return rows.isEmpty ? null : DanmakuMatchRecord.fromRow(rows.first);
  }

  void upsertDanmakuMatch(DanmakuMatchRecord record) {
    _db.execute(
      'INSERT INTO danmaku_match(site_key, vod_id, episode_name, provider_id, '
      'entry_id, title, episode, url, updated_at) VALUES(?,?,?,?,?,?,?,?,?) '
      'ON CONFLICT(site_key, vod_id, episode_name) DO UPDATE SET '
      'provider_id=excluded.provider_id, entry_id=excluded.entry_id, '
      'title=excluded.title, episode=excluded.episode, url=excluded.url, '
      'updated_at=excluded.updated_at;',
      [
        record.siteKey,
        record.vodId,
        record.episodeName,
        record.providerId,
        record.entryId,
        record.title,
        record.episode,
        record.url,
        record.updatedAt,
      ],
    );
  }

  void deleteDanmakuMatch({
    required String siteKey,
    required String vodId,
    required String episodeName,
  }) {
    _db.execute(
      'DELETE FROM danmaku_match WHERE site_key=? AND vod_id=? '
      'AND episode_name=?;',
      [siteKey, vodId, episodeName],
    );
  }

  static int? _positiveOrNull(int? value) =>
      value == null || value <= 0 ? null : value;

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
