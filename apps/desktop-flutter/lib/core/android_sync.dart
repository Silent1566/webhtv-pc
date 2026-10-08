/// 安卓同步的**纯逻辑**层（`docs/phase5/design/02`）。
///
/// 职责边界（`design/02` §2）：
/// - 安卓 `History` / `Backup` / `SyncOptions` 的 JSON 编解码；
/// - 历史字段映射（含毫秒直传与哨兵值过滤）；
/// - 反向映射（PC → 安卓，`cid=0`）；
/// - 新旧比较与合并裁决（P3：旧不覆盖新）；
/// - 删除标记裁决（`design/02` §4.5 的墓碑替代方案）；
/// - `SyncOptions` / `prefers` 白名单子集；
/// - 脱敏（片名与凭据不进日志）。
///
/// **不做**：网络请求、UI、数据库。那些属于
/// `sync_server.dart` / `sync_client.dart` / `storage.dart`。
///
/// ## 必须锁定的两条契约（写错即缺陷）
///
/// 1. **`position` / `duration` / `createTime` 都是毫秒，直传，不存在秒换算**
///    （`design/02` §3.4 表）。实现里出现 `/1000` 或 `*1000` 即是缺陷，
///    `tools/phase5/verify_reverse_checks.py` 的 #2 专门锁这一条。
/// 2. **合并裁决必须是"旧不覆盖新"**（`design/02` §4.4），
///    反向验证 #3 专门锁这一条。任何形式的 `DELETE FROM history` 前置清表
///    都是禁止的（P3）。
library;

import 'dart:convert';

import 'protocol.dart';

// ---------------------------------------------------------------------------
// 常量：字段名与白名单（集中定义，避免多处硬编码字符串漂移）
// ---------------------------------------------------------------------------

/// 安卓历史主键分隔符（`design/00` §3.6：`siteKey@@@vodId@@@cid`）。
const String androidHistoryKeySeparator = '@@@';

/// 请求体上限 8 MiB（`design/02` §4.3）。
const int syncMaxPayloadBytes = 8 * 1024 * 1024;

/// `type` 的合法取值（`design/02` §3.1）。
const Set<String> syncTypes = {'history', 'keep', 'backup'};

/// `mode` 的合法取值（`design/02` §3.2：`0`=发送、`1`=接收、`2`=都做）。
const Set<String> syncModes = {'0', '1', '2'};

/// PC 侧理解的 `prefers` 白名单（`design/02` §3.6）。
///
/// 只包含 PC **有对应语义**的键。`tmdb_model` 等 Android 专有键不在其中
/// —— 同步过去只会是无效设置。
const List<String> pcSettingsWhitelist = [
  'tmdb_enabled',
  'tmdb_config',
];

/// 含凭据的设置键：默认**不**同步，用户显式确认后才参与（P3、§19）。
const Set<String> pcSensitiveSettingsKeys = {'tmdb_config'};

// ---------------------------------------------------------------------------
// 哨兵值与单位归一化
// ---------------------------------------------------------------------------

/// 归一化安卓的毫秒时间字段（`design/02` §3.4）。
///
/// 必须过滤哨兵值：`opening` / `ending` 默认是
/// `C.TIME_UNSET = Long.MIN_VALUE(-9223372036854775808)`，PC 的 `int`
/// 放不下，直接透传会溢出成一个无意义的正数。
///
/// 返回 `null` 表示"没有这个值"，调用方应省略该字段而不是写 0。
int? normalizeAndroidMs(Object? raw) {
  final value = asInt(raw);
  if (value == null || value <= 0) return null;
  return value;
}

/// 判断是否为安卓哨兵值（`Long.MIN_VALUE`，`design/02` §3.4）。
bool isAndroidSentinel(Object? raw) {
  final value = asInt(raw);
  return value != null && value <= 0;
}

// ---------------------------------------------------------------------------
// 历史键
// ---------------------------------------------------------------------------

/// 拆开安卓历史主键 `siteKey@@@vodId@@@cid`（`design/02` §3.4）。
///
/// 容错规则（对齐实测数据）：
/// - `a@@@b@@@7` → `cid=7`；
/// - `a@@@b` → `cid=0`（缺段按 0）；
/// - `a` / 空串 / `@@@b`（缺 `siteKey` 或 `vodId`）→ 返回 `null`，
///   调用方把该条记为失败并跳过，**不得**猜造字段。
class AndroidHistoryKey {
  const AndroidHistoryKey({
    required this.siteKey,
    required this.vodId,
    required this.cid,
  });

  final String siteKey;
  final String vodId;
  final int cid;

  /// 解析失败返回 `null`。
  static AndroidHistoryKey? tryParse(Object? value) {
    final text = asString(value) ?? '';
    if (text.isEmpty) return null;
    final parts = text.split(androidHistoryKeySeparator);
    if (parts.length < 2) return null;
    final siteKey = parts[0].trim();
    final vodId = parts[1].trim();
    if (siteKey.isEmpty || vodId.isEmpty) return null;
    final cid = parts.length >= 3 ? (asInt(parts[2]) ?? 0) : 0;
    return AndroidHistoryKey(siteKey: siteKey, vodId: vodId, cid: cid);
  }

  @override
  String toString() => '$siteKey$androidHistoryKeySeparator$vodId'
      '$androidHistoryKeySeparator$cid';
}

// ---------------------------------------------------------------------------
// 历史记录（PC 侧规范形态）
// ---------------------------------------------------------------------------

/// 一条同步历史（`design/02` §3.4 的 PC 侧规范形态）。
///
/// 独立于 `storage.dart` 的 `PlaybackHistory`：后者带数据库自增 `id`，
/// 纯逻辑层不依赖数据库。
class SyncHistoryItem {
  const SyncHistoryItem({
    required this.siteKey,
    required this.vodId,
    required this.vodName,
    required this.flag,
    required this.episodeName,
    required this.episodeId,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAt,
    this.cid = 0,
    this.vodPic,
    this.openingMs,
    this.endingMs,
    this.raw = const {},
  });

  final String siteKey;
  final String vodId;

  /// 安卓 `vodName` → PC `vodName`（直传，空串保留）。
  final String vodName;

  /// 安卓 `vodFlag` → PC `flag`（直传，空串保留）。
  final String flag;

  /// 安卓 `vodRemarks` → PC `episodeName`（直传，空串保留）。
  final String episodeName;

  /// 安卓 `episodeUrl` → PC `episodeId`（PC 用它做集消歧）。
  final String episodeId;

  /// **毫秒**，直传（`design/02` §3.4）。
  final int positionMs;

  /// **毫秒**，直传。
  final int durationMs;

  /// 安卓 `createTime`，**毫秒**时间戳，直传。
  final int updatedAt;

  /// 安卓 `cid`。PC 无此概念，只保留在 [raw] 里（这里冗余保存便于反向映射）。
  final int cid;

  /// 安卓 `vodPic`（空串 → `null`）。
  final String? vodPic;

  /// 安卓 `opening`，已过滤哨兵值；`null` 表示无值。
  final int? openingMs;

  /// 安卓 `ending`，已过滤哨兵值；`null` 表示无值。
  final int? endingMs;

  /// 原始 JSON（保留 TMDB 字段、`scale`、`player` 等 PC 不落库的键，
  /// 避免往返同步时丢信息，`design/02` §3.4）。
  final Map<String, Object?> raw;

  /// 本地匹配键：`(siteKey, vodId, flag, episodeId)`（`design/02` §4.3 幂等键）。
  ///
  /// **不带 `cid`**：PC 没有 `cid` 概念，且安卓的 `cid` 会随配置重映射
  /// （`Backup.restoreConfig()`），把它当身份会让同一集在两端对不上。
  String get matchKey => '$siteKey\x00$vodId\x00$flag\x00$episodeId';

  /// 是否已播完：`position >= duration - 5000`（`design/02` §8 Q7）。
  ///
  /// `duration <= 0` 时**不算**播完 —— 这是"尚未取到时长"的形态，
  /// 与"看完了"语义不同。
  bool get completed => durationMs > 0 && positionMs >= durationMs - 5000;

  /// 从安卓 `History` JSON 解析（`design/02` §3.4）。
  ///
  /// 解析失败（缺 `key`、`key` 不成段、缺 `vodName`）返回 `null`，
  /// 由调用方计入失败明细 —— **不得**用空串猜造一条记录（P5）。
  static SyncHistoryItem? tryFromJson(Object? value) {
    final map = asMap(value);
    if (map.isEmpty) return null;
    final key = AndroidHistoryKey.tryParse(map['key']);
    if (key == null) return null;
    final vodName = asString(map['vodName']);
    if (vodName == null) return null;
    return SyncHistoryItem(
      siteKey: key.siteKey,
      vodId: key.vodId,
      vodName: vodName,
      // 空串保留（`design/02` §3.4 表：`vodFlag`/`vodRemarks` 直传）。
      flag: asString(map['vodFlag']) ?? '',
      episodeName: asString(map['vodRemarks']) ?? '',
      episodeId: asString(map['episodeUrl']) ?? '',
      positionMs: asInt(map['position']) ?? 0,
      durationMs: asInt(map['duration']) ?? 0,
      updatedAt: asInt(map['createTime']) ?? 0,
      cid: key.cid,
      // 空串 → null（`design/02` §3.4 表）。
      vodPic: (asString(map['vodPic']) ?? '').trim().isEmpty
          ? null
          : asString(map['vodPic']),
      openingMs: normalizeAndroidMs(map['opening']),
      endingMs: normalizeAndroidMs(map['ending']),
      raw: map,
    );
  }

  /// 由 PC 本地历史构造（`design/02` §3.5）。存储层用它把
  /// `PlaybackHistory` 映射进来，避免 `core` 依赖 `services`。
  factory SyncHistoryItem.fromLocal({
    required String siteKey,
    required String vodId,
    required String vodName,
    required String flag,
    required String episodeName,
    required String episodeId,
    required int positionMs,
    required int durationMs,
    required int updatedAt,
    String? vodPic,
  }) => SyncHistoryItem(
    siteKey: siteKey,
    vodId: vodId,
    vodName: vodName,
    flag: flag,
    episodeName: episodeName,
    episodeId: episodeId,
    positionMs: positionMs,
    durationMs: durationMs,
    updatedAt: updatedAt,
    vodPic: vodPic,
  );

  /// 反向映射成安卓 `History` JSON（`design/02` §3.5）。
  ///
  /// 两条必须遵守的规则：
  /// - `key` 的 `cid` 写 **0**：安卓的 `Backup.restoreConfig()` 会按
  ///   `source → 实际 cid` 重映射；写真实 cid 会指向错误的配置；
  /// - `opening` / `ending` **省略**：让安卓用自身默认哨兵值，
  ///   写 `null` 或 `-9223372036854775808` 都会让它的开跳片头逻辑出错。
  Map<String, Object?> toAndroidJson() => {
    'key': '$siteKey$androidHistoryKeySeparator$vodId'
        '${androidHistoryKeySeparator}0',
    'vodName': vodName,
    'vodPic': vodPic ?? '',
    'vodFlag': flag,
    'vodRemarks': episodeName,
    'episodeUrl': episodeId,
    'position': positionMs,
    'duration': durationMs,
    'createTime': updatedAt,
    // 固定 1.0（`design/02` §3.5 表的 `speed` 行）。
    'speed': 1.0,
  };

  /// 脱敏描述（`design/02` §7）：**不含片名、图片、播放地址**。
  ///
  /// 站点 key 与条数属于非敏感，写日志便于排障。
  String describe() =>
      'history(site=${siteKey.isEmpty ? '(空)' : siteKey}, vod=$vodId, '
      'position=$positionMs, duration=$durationMs, updated=$updatedAt)';

  @override
  String toString() => describe();
}

/// 解析失败明细（`design/02` §6：`syncPayloadInvalid` 要指出具体字段）。
class SyncFailure {
  const SyncFailure({required this.index, required this.reason});

  /// 在输入数组中的下标，便于对端定位。
  final int index;
  final String reason;

  @override
  String toString() => '#$index $reason';
}

/// `History[]` 的解析结果：成功条目 + 失败明细。
///
/// **失败必须可见**（P5）：不能把解析不了的条目静默丢弃后报"同步成功"。
class SyncHistoryParseResult {
  const SyncHistoryParseResult({
    required this.items,
    required this.failures,
  });

  final List<SyncHistoryItem> items;
  final List<SyncFailure> failures;

  int get total => items.length + failures.length;
  bool get hasFailures => failures.isNotEmpty;

  /// 逐条解析；整体不是数组时抛 [FormatException]。
  static SyncHistoryParseResult parse(Object? value) {
    final list = asList(value);
    final items = <SyncHistoryItem>[];
    final failures = <SyncFailure>[];
    for (var index = 0; index < list.length; index++) {
      final item = SyncHistoryItem.tryFromJson(list[index]);
      if (item == null) {
        failures.add(
          SyncFailure(index: index, reason: '缺少 key 或 key 不成段（无法定位记录）'),
        );
        continue;
      }
      items.add(item);
    }
    return SyncHistoryParseResult(items: items, failures: failures);
  }
}

// ---------------------------------------------------------------------------
// 合并裁决（`design/02` §4.4 / §4.5）
// ---------------------------------------------------------------------------

/// 合并动作。
enum SyncMergeAction {
  /// 本地无该条 → 插入。
  insert,

  /// 远端更新 → 覆盖本地。
  upsert,

  /// 跳过（幂等、旧不覆盖新、删除标记拦截）。
  skip,
}

/// 裁决结果（含理由，便于证据落盘与排障）。
class SyncMergeDecision {
  const SyncMergeDecision(this.action, this.reason);

  final SyncMergeAction action;
  final String reason;

  bool get isApplied => action != SyncMergeAction.skip;

  @override
  String toString() => '${action.name}: $reason';
}

/// 合并裁决（`design/02` §4.4 + §4.5）。
///
/// ```text
/// local == null:
///     删除标记 T 存在且 incoming.updatedAt <  T  → skip（不复活，§4.5）
///     否则                                        → insert
/// local != null:
///     incoming.updatedAt >  local.updatedAt       → upsert
///     incoming.updatedAt == local.updatedAt       → skip（幂等）
///     incoming.updatedAt <  local.updatedAt       → skip（旧不覆盖新）
/// ```
///
/// [localDeletedAt] 是本条在 PC 上被删除的时刻（毫秒）。**只在
/// `local == null` 时生效**：本地还有记录说明用户后来又看了，删除标记
/// 不应再拦截更新（`design/02` §4.5 的边界）。
SyncMergeDecision decideHistoryMerge({
  required SyncHistoryItem incoming,
  SyncHistoryItem? local,
  int? localDeletedAt,
}) {
  if (local == null) {
    if (localDeletedAt != null && incoming.updatedAt < localDeletedAt) {
      return const SyncMergeDecision(
        SyncMergeAction.skip,
        '本地已删除且远端记录更旧（不复活）',
      );
    }
    return const SyncMergeDecision(SyncMergeAction.insert, '本地无该条记录');
  }

  if (incoming.updatedAt > local.updatedAt) {
    return const SyncMergeDecision(SyncMergeAction.upsert, '远端记录更新');
  }
  if (incoming.updatedAt == local.updatedAt) {
    return const SyncMergeDecision(SyncMergeAction.skip, '时间戳相同（幂等）');
  }
  return const SyncMergeDecision(SyncMergeAction.skip, '本地记录更新（旧不覆盖新）');
}

/// 合并统计（`design/02` §4.3 / §6）。
///
/// 不变式：`applied + skipped + failed == total`。
/// 服务端**必须**把明细返回给对端，禁止折叠成"同步成功"（P5）。
class SyncMergeStats {
  const SyncMergeStats({
    required this.applied,
    required this.skipped,
    required this.failed,
    required this.total,
  });

  const SyncMergeStats.empty()
    : applied = 0,
      skipped = 0,
      failed = 0,
      total = 0;

  final int applied;
  final int skipped;
  final int failed;
  final int total;

  /// 明细未闭合即为实现缺陷（`design/03` §3.2 用例 18）。
  bool get isConsistent => applied + skipped + failed == total;

  Map<String, Object?> toJson() => {
    'applied': applied,
    'skipped': skipped,
    'failed': failed,
    'total': total,
  };

  /// 机器可校验的一行摘要（证据落盘用）。
  String describe() =>
      'applied=$applied skipped=$skipped failed=$failed total=$total '
      'consistent=$isConsistent';

  @override
  String toString() => describe();
}

/// 合并计划：裁决完成、可直接执行的写入清单。
///
/// 服务端与存储层消费它，这样"裁决"与"写库"解耦，纯逻辑层可全量覆盖
/// 5 种合并裁决（`design/03` §4.3）。
class SyncMergePlan {
  const SyncMergePlan({
    required this.inserts,
    required this.upserts,
    required this.skipped,
    required this.failures,
    required this.total,
  });

  /// 待插入（本地无该条）。
  final List<SyncHistoryItem> inserts;

  /// 待覆盖（远端更新）。
  final List<SyncHistoryItem> upserts;

  /// 被跳过的条数（幂等 / 旧不覆盖新 / 删除标记）。
  final int skipped;

  /// 解析失败的条目（`design/02` §6：必须计入 `failed`）。
  final List<SyncFailure> failures;

  /// 输入总条数。
  final int total;

  List<SyncHistoryItem> get applied => [...inserts, ...upserts];

  SyncMergeStats get stats => SyncMergeStats(
    applied: applied.length,
    skipped: skipped,
    failed: failures.length,
    total: total,
  );

  String describe() => stats.describe();
}

/// 裁决一批历史（`design/02` §4.4）。
///
/// [localByMatchKey]：本地已有记录，按 [SyncHistoryItem.matchKey] 索引。
/// [deletedAtByMatchKey]：本地删除标记（毫秒），用于阻止已删除记录被复活。
///
/// 注意：即使某条只是 `skip`，也**不会**删除本地数据；本函数不产生任何
/// 删除动作（P3：禁止 `DELETE FROM history` 作为合并前置步骤）。
SyncMergePlan buildHistoryMergePlan({
  required SyncHistoryParseResult parsed,
  required Map<String, SyncHistoryItem> localByMatchKey,
  Map<String, int> deletedAtByMatchKey = const {},
}) {
  final inserts = <SyncHistoryItem>[];
  final upserts = <SyncHistoryItem>[];
  var skipped = 0;

  for (final incoming in parsed.items) {
    final decision = decideHistoryMerge(
      incoming: incoming,
      local: localByMatchKey[incoming.matchKey],
      localDeletedAt: deletedAtByMatchKey[incoming.matchKey],
    );
    switch (decision.action) {
      case SyncMergeAction.insert:
        inserts.add(incoming);
      case SyncMergeAction.upsert:
        upserts.add(incoming);
      case SyncMergeAction.skip:
        skipped++;
    }
  }

  return SyncMergePlan(
    inserts: inserts,
    upserts: upserts,
    skipped: skipped,
    failures: parsed.failures,
    total: parsed.total,
  );
}

// ---------------------------------------------------------------------------
// SyncOptions（`design/02` §3.6）
// ---------------------------------------------------------------------------

/// PC 侧的 `SyncOptions` 子集。
///
/// 字段与安卓一致，但 PC **只发自己理解的子集**，其余**显式写 `false`**
/// —— 省略键会让安卓读到它自己的默认值（可能是 `true`），从而误判。
class SyncOptions {
  const SyncOptions({
    this.config = false,
    this.spider = false,
    this.search = false,
    this.history = true,
    this.keep = true,
    this.follow = false,
    this.webHome = false,
    this.settings = false,
    this.loginState = false,
    this.remoteRelay = false,
    this.mpvConfig = false,
    this.paths = '',
  });

  /// PC 默认子集：只同步历史与收藏（`design/02` §3.6 表）。
  static const SyncOptions pcDefault = SyncOptions();

  /// 含凭据的 `settings` 是否参与。
  final bool settings;

  final bool config;
  final bool spider;
  final bool search;
  final bool history;
  final bool keep;
  final bool follow;
  final bool webHome;
  final bool loginState;
  final bool remoteRelay;
  final bool mpvConfig;
  final String paths;

  /// 解析对端发来的 `options`，**强制收敛到 PC 子集**（`design/02` §3.6）。
  ///
  /// 对端（安卓）的 `config`/`spider`/`webHome` 等常为 `true`，PC 没有对应
  /// 语义，必须丢弃；`settings` 只在 [allowSettings] 为真时才接受
  /// （默认不同步含凭据的设置，P3）。
  factory SyncOptions.fromJson(Object? value, {bool allowSettings = false}) {
    final map = asMap(value);
    return SyncOptions(
      history: map.containsKey('history') ? asFlag(map['history']) : true,
      keep: map.containsKey('keep') ? asFlag(map['keep']) : true,
      settings: allowSettings && asFlag(map['settings']),
    );
  }

  /// 序列化为**全字段**（含显式 `false`），供 POST 表单使用。
  Map<String, Object?> toJson() => {
    'config': config,
    'spider': spider,
    'search': search,
    'history': history,
    'keep': keep,
    'follow': follow,
    'webHome': webHome,
    'settings': settings,
    'loginState': loginState,
    'remoteRelay': remoteRelay,
    'mpvConfig': mpvConfig,
    'paths': paths,
  };

  String get jsonText => jsonEncode(toJson());

  SyncOptions copyWith({bool? history, bool? keep, bool? settings}) =>
      SyncOptions(
        config: config,
        spider: spider,
        search: search,
        history: history ?? this.history,
        keep: keep ?? this.keep,
        follow: follow,
        webHome: webHome,
        settings: settings ?? this.settings,
        loginState: loginState,
        remoteRelay: remoteRelay,
        mpvConfig: mpvConfig,
        paths: paths,
      );
}

// ---------------------------------------------------------------------------
// Backup 的 prefers 白名单子集（`design/02` §3.6）
// ---------------------------------------------------------------------------

/// 从安卓 `Backup.prefers` 中取出的 PC 设置子集。
///
/// 白名单外的键（`tmdb_model`、`viewing_record_sync_*` 等）一律丢弃；
/// 含凭据的键（[pcSensitiveSettingsKeys]）默认丢弃，除非显式
/// [allowSensitive]（P3 + §19）。
class SyncSettings {
  const SyncSettings({
    required this.values,
    required this.skippedKeys,
    required this.sensitiveIncluded,
  });

  const SyncSettings.empty()
    : values = const {},
      skippedKeys = const [],
      sensitiveIncluded = false;

  /// 白名单内的键值（键名保留安卓原名，便于回传）。
  final Map<String, Object?> values;

  /// 被丢弃的键（白名单外或含凭据未开启），用于向用户披露（P5）。
  final List<String> skippedKeys;

  /// 本次是否包含含凭据的设置项。
  final bool sensitiveIncluded;

  bool get isEmpty => values.isEmpty;

  /// 从 `Backup` 顶层对象解析 `prefers`（`design/02` §3.6）。
  static SyncSettings fromBackup(
    Object? backup, {
    bool allowSensitive = false,
  }) {
    final prefers = asMap(asMap(backup)['prefers']);
    final values = <String, Object?>{};
    final skipped = <String>[];
    for (final entry in prefers.entries) {
      final key = entry.key;
      if (!pcSettingsWhitelist.contains(key)) {
        skipped.add(key);
        continue;
      }
      if (pcSensitiveSettingsKeys.contains(key) && !allowSensitive) {
        skipped.add(key);
        continue;
      }
      values[key] = entry.value;
    }
    return SyncSettings(
      values: values,
      skippedKeys: skipped,
      sensitiveIncluded: allowSensitive &&
          values.keys.any(pcSensitiveSettingsKeys.contains),
    );
  }

  Map<String, Object?> toJson() => {
    'values': values,
    'skipped': skippedKeys,
    'sensitiveIncluded': sensitiveIncluded,
  };

  /// 脱敏描述：只报键名与数量，**永不输出值**（可能含凭据，`design/02` §7）。
  String describe() =>
      'settings(keys=${values.keys.join(',')} '
      'sensitive=$sensitiveIncluded skipped=${skippedKeys.length})';

  @override
  String toString() => describe();
}

// ---------------------------------------------------------------------------
// 收藏（`Keep`，`design/02` §8 Q3）
// ---------------------------------------------------------------------------

/// `Keep.type` 的语义（上游 `KeepDao.getVod()/getLive()` 源码确认）：
/// `0` = 点播收藏，`1` = 直播收藏。
const int androidKeepTypeVod = 0;
const int androidKeepTypeLive = 1;

/// 一条同步收藏（`design/02` §8 Q3：`Keep` 映射简单，4 个有效字段）。
class SyncFavoriteItem {
  const SyncFavoriteItem({
    required this.kind,
    required this.siteKey,
    required this.targetId,
    required this.title,
    this.subtitle,
    required this.updatedAt,
    this.raw = const {},
  });

  /// PC 的收藏分类：`vod`（点播）或 `site`（上游的直播/站点收藏）。
  ///
  /// PC 没有直播收藏页面，因此 `type=1` 落到 `site` 级收藏
  /// （`targetId` 取站点 key），保留“用户收藏了什么”这个事实。
  final String kind;
  final String siteKey;
  final String targetId;
  final String title;
  final String? subtitle;

  /// 安卓 `createTime`（**毫秒**，直传，同历史）。
  final int updatedAt;

  final Map<String, Object?> raw;

  /// 本地匹配键：`(kind, siteKey, targetId)`，与 `favorites` 表的 `UNIQUE` 一致。
  String get matchKey => '$kind\x00$siteKey\x00$targetId';

  /// 从安卓 `Keep` JSON 解析（`design/02` §4.4 的同一套字段容错）。
  static SyncFavoriteItem? tryFromJson(Object? value) {
    final map = asMap(value);
    if (map.isEmpty) return null;
    final key = AndroidHistoryKey.tryParse(map['key']);
    if (key == null) return null;
    final type = asInt(map['type']) ?? androidKeepTypeVod;
    final siteName = asString(map['siteName']) ?? '';
    final vodName = asString(map['vodName']) ?? '';
    final isVod = type == androidKeepTypeVod;
    return SyncFavoriteItem(
      kind: isVod ? 'vod' : 'site',
      siteKey: key.siteKey,
      targetId: isVod ? key.vodId : key.siteKey,
      // 点播收藏用片名做标题；直播/站点收藏只有站点名。
      title: isVod ? vodName : (siteName.isEmpty ? key.siteKey : siteName),
      subtitle: isVod
          ? (siteName.isEmpty ? null : siteName)
          : (vodName.isEmpty ? null : vodName),
      updatedAt: asInt(map['createTime']) ?? 0,
      raw: map,
    );
  }

  /// 反向映射成安卓 `Keep` JSON（`describe` 脱敏口径同历史）。
  Map<String, Object?> toAndroidJson() => {
    'key': '$siteKey$androidHistoryKeySeparator$targetId'
        '${androidHistoryKeySeparator}0',
    'siteName': subtitle ?? '',
    'vodName': title,
    'createTime': updatedAt,
    // 点播收藏回写 0；站点级收藏回写 1（上游用 type 区分两张列表）。
    'type': kind == 'vod' ? androidKeepTypeVod : androidKeepTypeLive,
  };

  /// 脱敏描述：不含片名与站点名（同 `design/02` §7）。
  String describe() =>
      'keep(kind=$kind, site=$siteKey, updated=$updatedAt)';

  @override
  String toString() => describe();
}

/// `Keep[]` 的解析结果。
class SyncFavoriteParseResult {
  const SyncFavoriteParseResult({
    required this.items,
    required this.failures,
  });

  final List<SyncFavoriteItem> items;
  final List<SyncFailure> failures;

  int get total => items.length + failures.length;

  static SyncFavoriteParseResult parse(Object? value) {
    final list = asList(value);
    final items = <SyncFavoriteItem>[];
    final failures = <SyncFailure>[];
    for (var index = 0; index < list.length; index++) {
      final item = SyncFavoriteItem.tryFromJson(list[index]);
      if (item == null) {
        failures.add(
          SyncFailure(index: index, reason: '缺少 key 或 key 不成段（无法定位收藏）'),
        );
        continue;
      }
      items.add(item);
    }
    return SyncFavoriteParseResult(items: items, failures: failures);
  }
}

/// 收藏的合并裁决：与历史同一套“旧不覆盖新”（`design/02` §4.4）。
///
/// 收藏没有删除标记（本阶段不给收藏做墓碑，`design/02` §4.5 只针对历史）。
SyncMergeDecision decideFavoriteMerge({
  required SyncFavoriteItem incoming,
  int? localUpdatedAt,
}) {
  if (localUpdatedAt == null) {
    return const SyncMergeDecision(SyncMergeAction.insert, '本地无该收藏');
  }
  if (incoming.updatedAt > localUpdatedAt) {
    return const SyncMergeDecision(SyncMergeAction.upsert, '远端收藏更新');
  }
  if (incoming.updatedAt == localUpdatedAt) {
    return const SyncMergeDecision(SyncMergeAction.skip, '时间戳相同（幂等）');
  }
  return const SyncMergeDecision(SyncMergeAction.skip, '本地收藏更新（旧不覆盖新）');
}

/// 收藏的合并计划。
class SyncFavoriteMergePlan {
  const SyncFavoriteMergePlan({
    required this.inserts,
    required this.upserts,
    required this.skipped,
    required this.failures,
    required this.total,
  });

  final List<SyncFavoriteItem> inserts;
  final List<SyncFavoriteItem> upserts;
  final int skipped;
  final List<SyncFailure> failures;
  final int total;

  List<SyncFavoriteItem> get applied => [...inserts, ...upserts];

  SyncMergeStats get stats => SyncMergeStats(
    applied: applied.length,
    skipped: skipped,
    failed: failures.length,
    total: total,
  );

  String describe() => stats.describe();
}

/// 裁决一批收藏（`design/02` §4.4）。
SyncFavoriteMergePlan buildFavoriteMergePlan({
  required SyncFavoriteParseResult parsed,
  required Map<String, int> localUpdatedAtByKey,
}) {
  final inserts = <SyncFavoriteItem>[];
  final upserts = <SyncFavoriteItem>[];
  var skipped = 0;
  for (final incoming in parsed.items) {
    final decision = decideFavoriteMerge(
      incoming: incoming,
      localUpdatedAt: localUpdatedAtByKey[incoming.matchKey],
    );
    switch (decision.action) {
      case SyncMergeAction.insert:
        inserts.add(incoming);
      case SyncMergeAction.upsert:
        upserts.add(incoming);
      case SyncMergeAction.skip:
        skipped++;
    }
  }
  return SyncFavoriteMergePlan(
    inserts: inserts,
    upserts: upserts,
    skipped: skipped,
    failures: parsed.failures,
    total: parsed.total,
  );
}

// ---------------------------------------------------------------------------
// `/action?do=sync` 请求校验与路径构造
// ---------------------------------------------------------------------------

/// 校验结论：能直接翻译成 HTTP 状态码 + 对端可见的 message。
class SyncRequestCheck {
  const SyncRequestCheck.ok()
    : status = 200,
      message = null;

  const SyncRequestCheck.rejected(this.status, this.message);

  final int status;
  final String? message;

  bool get isOk => status == 200;

  @override
  String toString() => isOk ? 'ok' : '$status $message';
}

/// 校验 `POST /action?do=sync` 的 query 与表单（`design/02` §3.3）。
///
/// 顺序（结构 → 授权 → 载荷）：
/// 1. `type` 合法，否则 `400`；
/// 2. `mode` 合法，否则 `400`；
/// 3. 同步已开启，否则 `403`（P3）；
/// 4. 对端已授权，否则 `403`；
/// 5. 按 `type` 校验载荷（`history` 需 `config` 为非空合法 JSON 对象、
///    `targets` 为合法 JSON 数组）。
///
/// **返回 400 而不是像安卓那样静默 `return`**：安卓的静默返回让调用方
/// 以为同步成功；PC 必须让失败可见（P5）。
SyncRequestCheck validateSyncAction({
  required Map<String, String> params,
  required Map<String, String> form,
  required bool enabled,
  required bool peerAuthorized,
}) {
  if (!syncTypes.contains(params['type'])) {
    return SyncRequestCheck.rejected(
      400,
      'type 必须是 history/keep/backup 之一（收到 ${params['type'] ?? '(空)'}）',
    );
  }
  if (!syncModes.contains(params['mode'])) {
    return SyncRequestCheck.rejected(
      400,
      'mode 必须是 0/1/2 之一（收到 ${params['mode'] ?? '(空)'}）',
    );
  }
  if (!enabled) {
    return const SyncRequestCheck.rejected(
      403,
      '同步未开启（请在 WebHTV PC 设置中开启后重试）',
    );
  }
  if (!peerAuthorized) {
    return const SyncRequestCheck.rejected(403, '对端未授权');
  }

  switch (params['type']) {
    case 'history':
      final rawConfig = form['config'];
      if (rawConfig == null || rawConfig.trim().isEmpty) {
        return const SyncRequestCheck.rejected(400, 'config 不能为空');
      }
      final config = _tryDecodeJson(rawConfig);
      if (config is! Map) {
        return const SyncRequestCheck.rejected(400, 'config 必须是 JSON 对象');
      }
      final rawTargets = form['targets'];
      if (rawTargets == null || rawTargets.trim().isEmpty) {
        return const SyncRequestCheck.rejected(400, 'targets 必须是 JSON 数组');
      }
      if (_tryDecodeJson(rawTargets) is! List) {
        return const SyncRequestCheck.rejected(400, 'targets 必须是 JSON 数组');
      }
    case 'keep':
      final rawTargets = form['targets'];
      if (rawTargets == null || rawTargets.trim().isEmpty) {
        return const SyncRequestCheck.rejected(400, 'targets 必须是 JSON 数组');
      }
      if (_tryDecodeJson(rawTargets) is! List) {
        return const SyncRequestCheck.rejected(400, 'targets 必须是 JSON 数组');
      }
    case 'backup':
      final rawBackup = form['backup'];
      if (rawBackup == null || rawBackup.trim().isEmpty) {
        return const SyncRequestCheck.rejected(400, 'backup 不能为空');
      }
      if (_tryDecodeJson(rawBackup) is! Map) {
        return const SyncRequestCheck.rejected(400, 'backup 必须是 JSON 对象');
      }
  }
  return const SyncRequestCheck.ok();
}

Object? _tryDecodeJson(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}

/// 构造 `POST /action` 的路径与 query（`design/02` §3.2）。
///
/// `mode` 是**被请求方**视角：PC 推送给安卓时用 `mode=1`（"请接收"），
/// 请求安卓主动推给 PC 时用 `mode=0`。这条语义写错方向就反了，
/// 因此集中在这里一处构造，便于测试锁定。
String buildSyncActionPath({
  required String mode,
  required String type,
  bool force = false,
  String? deviceJson,
}) {
  if (!syncModes.contains(mode)) {
    throw ArgumentError.value(mode, 'mode', 'mode 必须是 0/1/2');
  }
  if (!syncTypes.contains(type)) {
    throw ArgumentError.value(type, 'type', 'type 必须是 history/keep/backup');
  }
  final query = <String, String>{
    'do': 'sync',
    'mode': mode,
    'type': type,
    if (force) 'force': 'true',
    if (deviceJson != null && deviceJson.isNotEmpty) 'device': deviceJson,
  };
  return '/action?${_encodeQuery(query)}';
}

String _encodeQuery(Map<String, String> query) => query.entries
    .map(
      (entry) =>
          '${Uri.encodeQueryComponent(entry.key)}='
          '${Uri.encodeQueryComponent(entry.value)}',
    )
    .join('&');
