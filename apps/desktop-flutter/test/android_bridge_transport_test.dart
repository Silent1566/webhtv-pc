/// 已连接安卓环境 MVP · 桥接记录的内部传输标记（`configs.bridge_transport`）。
///
/// 两条合同：
/// 1. **存储层**：加法式加列（schema 12 → 13），旧行读回 `''` = 老 HTTP 桥接；
///    `'adb'` 只由管理型（runtime 拥有网关）导入写入。`source_key` 不动
///    （`parseSourceKey` 会把第 3 段之后折叠进 `interfaceKey`，加段就是改身份）。
/// 2. **状态层**：`SyncState.importSites` 把标记原样交给宿主，由宿主一次写库。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:webhtv_pc/core/android_bridge.dart';
import 'package:webhtv_pc/core/android_sources.dart';
import 'package:webhtv_pc/core/android_sync.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/push_parser.dart';
import 'package:webhtv_pc/core/source_key.dart';
import 'package:webhtv_pc/services/android_bridge_service.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/state/sync_state.dart';

/// v12（本 MVP 之前）`configs` 表的列：逐列手写，迁移只允许再加一列。
const List<String> v12ConfigColumns = [
  'id INTEGER PRIMARY KEY AUTOINCREMENT',
  'name TEXT NOT NULL',
  'origin TEXT NOT NULL',
  'content_type TEXT',
  'repository_index INTEGER',
  'repository_entries TEXT',
  'json TEXT NOT NULL',
  'site_count INTEGER NOT NULL DEFAULT 0',
  'live_count INTEGER NOT NULL DEFAULT 0',
  'is_active INTEGER NOT NULL DEFAULT 0',
  'updated_at INTEGER NOT NULL',
  "source_key TEXT NOT NULL DEFAULT ''",
  "bridge_device TEXT NOT NULL DEFAULT ''",
  "bridge_interface_key TEXT NOT NULL DEFAULT ''",
  "bridge_config_url TEXT NOT NULL DEFAULT ''",
  "etag TEXT NOT NULL DEFAULT ''",
  "last_modified TEXT NOT NULL DEFAULT ''",
  "content_hash TEXT NOT NULL DEFAULT ''",
  'last_checked_at INTEGER',
  'last_check_error TEXT',
];

/// 造一个 v12 库：老 `meta` + 老 `configs`（含一条老 HTTP 桥接记录）。
void createV12Database(String path) {
  final legacy = sqlite3.open(path);
  legacy.execute(
    'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);',
  );
  legacy.execute('CREATE TABLE configs (${v12ConfigColumns.join(', ')});');
  legacy.execute(
    'INSERT INTO configs(name, origin, content_type, json, site_count, '
    'live_count, is_active, updated_at, source_key, bridge_device, '
    'bridge_interface_key, bridge_config_url) VALUES(?,?,?,?,?,?,?,?,?,?,?,?);',
    [
      '旧桥接源',
      'http://192.168.50.9:9978',
      'android-t4-gateway',
      jsonEncode({'name': '旧桥接源', 'sites': <Object?>[]}),
      0,
      0,
      1,
      1700000000000,
      'bridge|legacy-uuid|legacy-key',
      'legacy-uuid',
      'legacy-key',
      'http://192.168.50.9:9978/vod/api?ac=config&configKey=legacy-key',
    ],
  );
  legacy.execute(
    "INSERT INTO meta(key, value) VALUES('schema_version', '12');",
  );
  legacy.close();
}

ConfigRecord recordWithSourceKey(AppDatabase db, String sourceKey) =>
    db.listConfigs().firstWhere((record) => record.sourceKey == sourceKey);

/// 支持传输标记的宿主：标记真实写进 SQLite，不 mock 数据库。
class TransportHost implements SyncStateHost, SyncBridgeTransportHost {
  TransportHost(this.database);

  final AppDatabase? database;

  /// 收到的标记（按调用顺序），用于断言「状态层有没有原样转发」。
  final List<String> markers = [];

  @override
  AppDatabase? get syncDatabase => database;

  @override
  List<SyncHistoryItem> syncHistoryItems({int limit = 2000}) => const [];

  @override
  List<SyncFavoriteItem> syncFavoriteItems({int limit = 2000}) => const [];

  @override
  List<String> syncSiteKeys({required bool all, int limit = 20}) => const [];

  @override
  String? syncConfigJson() => null;

  @override
  Future<void> applySyncedSettings(SyncSettings settings) async {}

  @override
  void notifySyncedDataChanged() {}

  @override
  Future<bool> onPushReceived(PushParsed parsed) async => false;

  @override
  Future<int?> saveBridgeConfig({
    required String name,
    required String origin,
    required AppConfig config,
    required List<String> diagnostics,
    String deviceUuid = '',
    String interfaceKey = '',
    String configUrl = '',
    String bridgeTransport = '',
  }) async {
    markers.add(bridgeTransport);
    return _save(
      database,
      name,
      origin,
      config,
      deviceUuid,
      interfaceKey,
      configUrl,
      bridgeTransport,
    );
  }
}

/// 只实现老接口的宿主（等价于本轮之前的 `AppState`）：必须照样编译、照样能用。
class LegacyHost implements SyncStateHost {
  LegacyHost(this.database);

  final AppDatabase? database;
  final List<String> savedOrigins = [];

  @override
  AppDatabase? get syncDatabase => database;

  @override
  List<SyncHistoryItem> syncHistoryItems({int limit = 2000}) => const [];

  @override
  List<SyncFavoriteItem> syncFavoriteItems({int limit = 2000}) => const [];

  @override
  List<String> syncSiteKeys({required bool all, int limit = 20}) => const [];

  @override
  String? syncConfigJson() => null;

  @override
  Future<void> applySyncedSettings(SyncSettings settings) async {}

  @override
  void notifySyncedDataChanged() {}

  @override
  Future<bool> onPushReceived(PushParsed parsed) async => false;

  @override
  Future<int?> saveBridgeConfig({
    required String name,
    required String origin,
    required AppConfig config,
    required List<String> diagnostics,
    String deviceUuid = '',
    String interfaceKey = '',
    String configUrl = '',
  }) async {
    savedOrigins.add(origin);
    return _save(
      database,
      name,
      origin,
      config,
      deviceUuid,
      interfaceKey,
      configUrl,
      '',
    );
  }
}

/// 两条宿主共用的一次落库（与 `AppState.saveBridgeConfig` 的写库形状一致）。
int? _save(
  AppDatabase? database,
  String name,
  String origin,
  AppConfig config,
  String deviceUuid,
  String interfaceKey,
  String configUrl,
  String bridgeTransport,
) {
  if (database == null) return null;
  final id = database.saveConfig(
    name: name,
    origin: origin,
    json: config.toJson(),
    contentType: 'android-t4-gateway',
    siteCount: config.sites.length,
    liveCount: config.lives.length,
    makeActive: false,
    sourceKey: BridgeSourceKey.of(
      deviceUuid: deviceUuid,
      interfaceKey: interfaceKey,
    ),
    bridgeDevice: deviceUuid,
    bridgeInterfaceKey: interfaceKey,
    bridgeConfigUrl: configUrl,
    bridgeTransport: bridgeTransport,
  );
  database.saveConfigSites(id, config.sites);
  return id;
}

/// 假桥接服务：只供数据，不碰网络（仓库既有的 fixture 用法）。
class FixtureBridge extends AndroidBridgeService {
  FixtureBridge() : super(log: LogService());

  static const AndroidDevice device = AndroidDevice(
    uuid: 'fake-android-uuid',
    name: '测试安卓设备',
    reachableBase: 'http://192.168.50.9:9978',
  );

  @override
  Future<AndroidDevice> probeDevice(String base) async => device;

  @override
  Future<AndroidSourceCatalog> fetchSources(String base) async =>
      AndroidSourceCatalog(
        sources: const [
          AndroidSource(
            interfaceKey: 'fake-source-key',
            name: '假源',
            url: 'http://192.168.50.9:9978/sub',
            active: true,
          ),
        ],
      );

  @override
  Future<List<LiveSource>> fetchLiveSources(String base) async => const [];

  @override
  Future<BridgeConversion> fetchGatewayConfig(
    String base, {
    String? selfBase,
    String? interfaceKey,
    void Function(BridgeStage stage)? onStage,
  }) async {
    onStage?.call(BridgeStage.converting);
    return BridgeConversion(
      config: AppConfig(
        name: '安卓桥接（fixture）',
        sites: [
          Site(
            key: 'csp_0',
            name: '站点0',
            type: SiteType.jsonApiBase64Ext,
            api: 'http://192.168.50.9:9978/0',
          ),
        ],
      ),
    );
  }
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('webhtv-bridge-transport-');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('存储层：schema 13 的 bridge_transport', () {
    test('schemaVersion 从 12 升到 13，新建库同样带这一列', () {
      expect(AppDatabase.schemaVersion, 13);
      final db = AppDatabase.inMemory();
      expect(db.schemaVersionValue, '13');
      db.dispose();
    });

    test('v12 旧库升级后老记录读回空串，桥接身份列不变', () {
      final path = p.join(tempDir.path, 'legacy-v12.sqlite3');
      createV12Database(path);

      final opened = AppDatabase.open(path);
      expect(opened.succeeded, isTrue, reason: opened.error);
      final db = opened.database!;
      expect(db.schemaVersionValue, '13');

      final legacy = db.listConfigs().single;
      expect(legacy.bridgeTransport, '');
      expect(legacy.sourceKey, 'bridge|legacy-uuid|legacy-key');
      expect(legacy.bridgeDevice, 'legacy-uuid');
      expect(legacy.bridgeInterfaceKey, 'legacy-key');
      expect(
        legacy.bridgeConfigUrl,
        'http://192.168.50.9:9978/vod/api?ac=config&configKey=legacy-key',
      );
      db.dispose();
    });

    test('同一库里 adb 记录写/读为 adb，老记录仍为空串，重开库不变', () {
      final path = p.join(tempDir.path, 'legacy-v12.sqlite3');
      createV12Database(path);

      final opened = AppDatabase.open(path);
      expect(opened.succeeded, isTrue, reason: opened.error);
      var db = opened.database!;
      db.saveConfig(
        name: '管理型源',
        origin: 'http://127.0.0.1:50001',
        json: {'name': '管理型源', 'sites': <Object?>[]},
        contentType: 'android-t4-gateway',
        sourceKey: 'bridge|adb-uuid|adb-key',
        bridgeDevice: 'adb-uuid',
        bridgeInterfaceKey: 'adb-key',
        bridgeConfigUrl:
            'http://127.0.0.1:50001/vod/api?ac=config&configKey=adb-key',
        bridgeTransport: 'adb',
        makeActive: false,
      );

      expect(
        recordWithSourceKey(db, 'bridge|adb-uuid|adb-key').bridgeTransport,
        'adb',
      );
      expect(
        recordWithSourceKey(
          db,
          'bridge|legacy-uuid|legacy-key',
        ).bridgeTransport,
        '',
      );
      // 主键/身份没被标记改写
      expect(
        recordWithSourceKey(db, 'bridge|adb-uuid|adb-key').sourceKey,
        'bridge|adb-uuid|adb-key',
      );
      db.dispose();

      final reopened = AppDatabase.open(path);
      expect(reopened.succeeded, isTrue, reason: reopened.error);
      db = reopened.database!;
      expect(
        recordWithSourceKey(db, 'bridge|adb-uuid|adb-key').bridgeTransport,
        'adb',
      );
      expect(
        recordWithSourceKey(
          db,
          'bridge|legacy-uuid|legacy-key',
        ).bridgeTransport,
        '',
      );
      db.dispose();
    });

    test('既有调用方不传标记时仍写空串（老语义不变）', () {
      final db = AppDatabase.inMemory();
      final id = db.saveConfig(
        name: '本机源',
        origin: 'http://192.168.1.9:9978',
        json: {'name': '本机源', 'sites': <Object?>[]},
      );
      expect(id, greaterThan(0));
      expect(db.listConfigs().single.bridgeTransport, '');
      db.dispose();
    });
  });

  group('状态层：SyncState 把标记交给宿主', () {
    late LogService log;
    late SyncState sync;

    SyncState build(SyncStateHost host) => sync = SyncState(
      log: log,
      host: host,
      settingsPath: p.join(tempDir.path, 'settings.json'),
      bridgeService: FixtureBridge(),
    );

    setUp(() {
      log = LogService();
    });

    tearDown(() async {
      sync.dispose();
      await log.dispose();
    });

    test('importSites(bridgeTransport: adb) 原样转发并真实落库', () async {
      final db = AppDatabase.inMemory();
      final host = TransportHost(db);
      final state = build(host);

      final ok = await state.importSites(
        'http://192.168.50.9:9978',
        bridgeTransport: 'adb',
      );

      expect(ok, isTrue);
      expect(host.markers, ['adb']);
      final record = db.listConfigs().single;
      expect(record.bridgeTransport, 'adb');
      // 身份语义不变：source_key 仍是 bridge|uuid|interfaceKey
      expect(record.sourceKey, 'bridge|fake-android-uuid|fake-source-key');
      db.dispose();
    });

    test('不传标记的导入（老 HTTP 桥接路径）写空串', () async {
      final db = AppDatabase.inMemory();
      final host = TransportHost(db);
      final state = build(host);

      final ok = await state.importSites('http://192.168.50.9:9978');

      expect(ok, isTrue);
      expect(host.markers, ['']);
      expect(db.listConfigs().single.bridgeTransport, '');
      db.dispose();
    });

    test('只实现老接口的宿主照样能用：标记丢弃、写库成功、日志说明原因', () async {
      final db = AppDatabase.inMemory();
      final host = LegacyHost(db);
      final state = build(host);

      final ok = await state.importSites(
        'http://192.168.50.9:9978',
        bridgeTransport: 'adb',
      );

      expect(ok, isTrue);
      expect(host.savedOrigins, ['http://192.168.50.9:9978']);
      expect(db.listConfigs().single.bridgeTransport, '');
      expect(
        log.entries.any(
          (entry) => entry.message.contains('SyncBridgeTransportHost'),
        ),
        isTrue,
        reason: '宿主不支持标记落库时必须留下可查的日志，而不是静默丢弃',
      );
      db.dispose();
    });
  });
}
