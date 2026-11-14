/// Phase 7 · 身份解析注册表（`design/01` §3.2.1）。
///
/// 安卓的「远端同步源」在同步前会 `POST /api/playback/identity/resolve`，用
/// 三层地址键（`strict`/`endpoint`/`host`）+ 旧 URL 哈希换取**正式身份**
/// （`canonicalInterfaceKey`）。**服务端不参与算键**——键由安卓的
/// `PlaybackConfigIdentity.material()` 算好后提交，服务端只做匹配与登记。
///
/// 若 PC 不实现这两个端点，安卓拿到 404 后会把 `identityResolutionState`
/// **永久**写成 `unsupported`（`PlaybackIdentityResolver.java:65-67`）：
/// 同步功能看似可用，但跨设备身份匹配永久失效，用户可见状态是
/// 「服务端不支持自动身份匹配」。所以 `resolve` 不是可选项。
///
/// 与 Go 参考实现（`serverless/webhtv-remote-go/playback_identity.go`）的
/// 有意差异：
/// - **没有 interfaceKey 分区（space）**：Go 按 `(token, interfaceKey)` 分库
///   存储播放数据，`adopt` 时要跨分区迁移，因此会返回
///   `migrationRequired`/`resetSince`。PC 只有一份全局历史库（按
///   siteKey/vodId 定位，与 interfaceKey 无关），没有可迁移的空间，所以
///   这三项恒为 `false`/`""` —— 这是事实，不是省略。
/// - **不缓存 `X-WebHTV-Request-Id` 的响应**：Go 用请求级缓存实现重放幂等；
///   PC 的幂等是**结构性**的（同一请求重放时 `interfaceKey` 已登记 →
///   命中 `keep`，`canonicalInterfaceKey` 不变），且请求处理本身串行。
/// - **`matchedBy`/`matchedKeys` 返回真实值**：Go 的 `playbackIdentityResponse`
///   用 `if _, exists` 回填，导致这两项永远停在基线值（`none`/`[]`），
///   安卓的 `addAddressMatchAliases(result.matchedKeys)` 因此一直拿到空数组。
///   PC 按协议本意返回。
library;

import 'protocol.dart';

/// 身份协议版本（`PlaybackConfigIdentity.IDENTITY_SCHEMA`）。
const String playbackIdentitySchema = 'webhtv.playback.identity.v1';

/// 地址匹配算法版本（`PlaybackConfigIdentity.ADDRESS_MATCH_VERSION`）。
const int playbackIdentityAddressMatchVersion = 1;

/// 每类键的上限（对齐 Go `parsePlaybackIdentityInput`：超过即 400）。
const int playbackIdentityMaxKeys = 32;

/// 键长度上限（对齐 Go `playbackValidIdentityKey`）。
const int playbackIdentityMaxKeyLength = 128;

/// 5 项能力声明（`design/01` §3.2.1 硬约束 3）。
///
/// [playbackSync] 单独暴露：它取决于「向安卓推送」是否开启，
/// 不能写死 `true`——能力声明与实际行为不一致就是 P5 禁止的伪装。
Map<String, Object?> playbackIdentityCapabilities({bool playbackSync = true}) => {
  'playbackSync': playbackSync,
  'identityResolve': true,
  'identityAliases': true,
  'legacyUrlHashMigration': true,
  'identityMerge': true,
};

/// 键是否合法：小写 `[a-z0-9._:-]`、长度 1..128（Go 同款）。
///
/// 为什么必须校验而不是照收：这些键会被当**映射键**存进注册表，
/// 也用于日志。放开字符集意味着任意 HTTP 头内容都能进本地状态文件。
bool isValidPlaybackIdentityKey(String value) {
  if (value.isEmpty || value.length > playbackIdentityMaxKeyLength) {
    return false;
  }
  for (final unit in value.codeUnits) {
    final isLower = unit >= 0x61 && unit <= 0x7a; // a-z
    final isDigit = unit >= 0x30 && unit <= 0x39; // 0-9
    if (isLower || isDigit) continue;
    if (unit == 0x2e || unit == 0x5f || unit == 0x3a || unit == 0x2d) {
      continue; // . _ : -
    }
    return false;
  }
  return true;
}

/// 规范化键：trim + 小写；非法返回 `null`（调用方必须回 400）。
String? normalizePlaybackIdentityKey(Object? raw) {
  final text = (raw is String ? raw : '').trim().toLowerCase();
  return isValidPlaybackIdentityKey(text) ? text : null;
}

/// `configType` 归一化（`PlaybackConfigIdentity.configType()` 同款）。
///
/// 只有 `vod` / `live` / `wall` 三种，未知一律落 `vod`。
String normalizePlaybackConfigType(Object? raw) {
  switch ((raw is String ? raw : '').trim().toLowerCase()) {
    case '1' || 'live':
      return 'live';
    case '2' || 'wall':
      return 'wall';
    default:
      return 'vod';
  }
}

/// 一次身份解析请求（`design/01` §3.2.1 的请求体）。
class PlaybackIdentityInput {
  const PlaybackIdentityInput({
    required this.configType,
    required this.interfaceKey,
    required this.strictAddressKeys,
    required this.endpointMatchKeys,
    required this.hostMatchKeys,
    required this.legacyConfigKeys,
    required this.sourceDataState,
    this.schema = playbackIdentitySchema,
    this.operation = 'resolve',
    this.confirm = false,
  });

  final String schema;
  final String operation;
  final String configType;

  /// 客户端声明的身份键（正式键或临时 UUID）。
  final String interfaceKey;

  final List<String> strictAddressKeys;
  final List<String> endpointMatchKeys;
  final List<String> hostMatchKeys;
  final List<String> legacyConfigKeys;

  /// `empty` / `has_data` / `unknown`：客户端**本地**是否已有该源的数据。
  ///
  /// 这个字段决定 `adopt` 与 `confirm_required` 的分岔：本地已有数据时
  /// 直接换身份会让两批记录混在一起，必须让用户确认（`design/01` §3.2.1）。
  final String sourceDataState;

  /// 用户已明确确认合并（安卓暂不发送，保留协议能力）。
  final bool confirm;

  /// 解析请求体；返回 `null` 表示请求非法（调用方回 400 `invalid`）。
  ///
  /// [headerInterfaceKey] 是 `X-WebHTV-Config-Key` 兜底（Go 同款）：
  /// 部分客户端把身份键放在头里而不是体里。
  static PlaybackIdentityInput? parse(
    Map<String, Object?> body, {
    String? headerInterfaceKey,
  }) {
    final schema =
        asNonEmptyString(body['schema']) ?? playbackIdentitySchema;
    final operation =
        (asNonEmptyString(body['operation']) ?? 'resolve').toLowerCase();
    final rawState = (asNonEmptyString(body['sourceDataState']) ?? '')
        .toLowerCase();
    final state = rawState == 'empty' || rawState == 'has_data'
        ? rawState
        : 'unknown';
    final interfaceKey = normalizePlaybackIdentityKey(
      asNonEmptyString(body['interfaceKey']) ?? headerInterfaceKey,
    );
    if (interfaceKey == null) return null;

    final strict = _keys(body['strictAddressKeys']);
    final endpoint = _keys(body['endpointMatchKeys']);
    final host = _keys(body['hostMatchKeys']);
    final legacy = _keys(body['legacyConfigKeys']);
    if (strict == null || endpoint == null || host == null || legacy == null) {
      return null;
    }

    return PlaybackIdentityInput(
      schema: schema,
      operation: operation,
      configType: normalizePlaybackConfigType(body['configType']),
      interfaceKey: interfaceKey,
      strictAddressKeys: strict,
      endpointMatchKeys: endpoint,
      hostMatchKeys: host,
      legacyConfigKeys: legacy,
      sourceDataState: state,
      confirm: asFlag(body['confirm']),
    );
  }

  /// 键数组：超长或含非法键 → `null`（400），不静默丢弃。
  ///
  /// 静默丢弃是危险的：客户端以为「这个键已登记」，服务端却当它不存在，
  /// 下一次解析就会新建出第二个身份。
  static List<String>? _keys(Object? raw) {
    final values = asList(raw);
    if (values.length > playbackIdentityMaxKeys) return null;
    final result = <String>[];
    for (final value in values) {
      if (value is! String || value.trim().isEmpty) continue;
      final key = normalizePlaybackIdentityKey(value);
      if (key == null) return null;
      if (!result.contains(key)) result.add(key);
    }
    return result;
  }
}

/// 一条正式身份的登记项（`design/01` §3.2.1 的服务端状态）。
class PlaybackIdentityRecord {
  PlaybackIdentityRecord({
    required this.canonicalInterfaceKey,
    List<String>? strictAddressKeys,
    List<String>? endpointMatchKeys,
    List<String>? hostMatchKeys,
    List<String>? legacyConfigKeys,
    this.createdAt = 0,
    this.updatedAt = 0,
  }) : strictAddressKeys = strictAddressKeys ?? <String>[],
       endpointMatchKeys = endpointMatchKeys ?? <String>[],
       hostMatchKeys = hostMatchKeys ?? <String>[],
       legacyConfigKeys = legacyConfigKeys ?? <String>[];

  final String canonicalInterfaceKey;
  List<String> strictAddressKeys;
  List<String> endpointMatchKeys;
  List<String> hostMatchKeys;
  List<String> legacyConfigKeys;
  final int createdAt;
  int updatedAt;

  /// 登记本次请求带来的所有键（上限 32/类，对齐 Go `playbackPushKeys`）。
  void addKeys(PlaybackIdentityInput input, {required int nowMs}) {
    updatedAt = nowMs;
    strictAddressKeys = _push(strictAddressKeys, input.strictAddressKeys);
    endpointMatchKeys = _push(endpointMatchKeys, input.endpointMatchKeys);
    hostMatchKeys = _push(hostMatchKeys, input.hostMatchKeys);
    legacyConfigKeys = _push(legacyConfigKeys, input.legacyConfigKeys);
  }

  /// 某个键属于哪一类（登记别名时要用，Go `playbackIdentityKeyKind` 同款）。
  String kindOf(String key) {
    if (strictAddressKeys.contains(key)) return 'strict';
    if (endpointMatchKeys.contains(key)) return 'endpoint';
    if (hostMatchKeys.contains(key)) return 'host';
    return 'legacy';
  }

  bool hasKey(String key, String kind) => switch (kind) {
    'strict' => strictAddressKeys.contains(key),
    'endpoint' => endpointMatchKeys.contains(key),
    'host' => hostMatchKeys.contains(key),
    _ => legacyConfigKeys.contains(key),
  };

  Map<String, Object?> toJson() => {
    'canonicalInterfaceKey': canonicalInterfaceKey,
    'strictAddressKeys': strictAddressKeys,
    'endpointMatchKeys': endpointMatchKeys,
    'hostMatchKeys': hostMatchKeys,
    'legacyConfigKeys': legacyConfigKeys,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
  };

  static PlaybackIdentityRecord? fromJson(Object? value) {
    final map = asMap(value);
    final canonical = normalizePlaybackIdentityKey(
      asNonEmptyString(map['canonicalInterfaceKey']),
    );
    if (canonical == null) return null;
    List<String> keys(String field) => [
      for (final item in asList(map[field])) ?normalizePlaybackIdentityKey(item),
    ];
    return PlaybackIdentityRecord(
      canonicalInterfaceKey: canonical,
      strictAddressKeys: keys('strictAddressKeys'),
      endpointMatchKeys: keys('endpointMatchKeys'),
      hostMatchKeys: keys('hostMatchKeys'),
      legacyConfigKeys: keys('legacyConfigKeys'),
      createdAt: asInt(map['createdAt']) ?? 0,
      updatedAt: asInt(map['updatedAt']) ?? 0,
    );
  }

  static List<String> _push(List<String> values, List<String> additions) {
    final result = [...values];
    for (final key in additions) {
      if (result.length >= playbackIdentityMaxKeys) break;
      if (!result.contains(key)) result.add(key);
    }
    return result;
  }
}

/// 键 → 正式身份的别名（`design/01` §3.2.1 的 `identityAliases` 能力）。
class PlaybackIdentityAlias {
  const PlaybackIdentityAlias({
    required this.canonicalInterfaceKey,
    required this.kind,
  });

  final String canonicalInterfaceKey;
  final String kind;

  Map<String, Object?> toJson() => {
    'canonicalInterfaceKey': canonicalInterfaceKey,
    'kind': kind,
  };
}

/// 一次解析的结论（`action` 语义见 `design/01` §3.2.1 的表）。
class PlaybackIdentityResolution {
  const PlaybackIdentityResolution({
    required this.action,
    this.canonicalInterfaceKey = '',
    this.matchedBy = 'none',
    this.matchedKeys = const [],
    this.candidates = const [],
    this.error,
  });

  /// `create` / `keep` / `adopt` / `merge` / `confirm_required` / `conflict`。
  final String action;
  final String canonicalInterfaceKey;
  final String matchedBy;
  final List<String> matchedKeys;
  final List<String> candidates;
  final String? error;

  /// 是否需要写注册表（`confirm_required` / `conflict` 都不改状态）。
  bool get mutates =>
      action == 'create' || action == 'keep' || action == 'adopt' || action == 'merge';

  Map<String, Object?> toExtra() => {
    'canonicalInterfaceKey': canonicalInterfaceKey,
    'matchedBy': matchedBy,
    'matchedKeys': matchedKeys,
    if (candidates.isNotEmpty) 'candidates': candidates,
    if (error != null) 'error': error,
  };
}

/// 身份注册表（按 `configType` 隔离，见 [PlaybackIdentityStore]）。
class PlaybackIdentityRegistry {
  PlaybackIdentityRegistry();

  /// 身份代际：每次**成功变更**后 +1（客户端用它判断是否落到了新身份）。
  int epoch = 0;
  int updatedAt = 0;

  final Map<String, PlaybackIdentityRecord> identities = {};
  final Map<String, PlaybackIdentityAlias> aliases = {};

  /// `interfaceKey` 已登记时的正式身份（键本身或别名指向）。
  String? boundCanonical(String interfaceKey) {
    if (identities.containsKey(interfaceKey)) return interfaceKey;
    return aliases[interfaceKey]?.canonicalInterfaceKey;
  }

  /// 给定一批键，返回命中的正式身份集合（升序，便于断言）。
  List<String> candidates(List<String> keys, String kind) {
    final seen = <String>{};
    for (final key in keys) {
      final alias = aliases[key];
      if (alias != null) seen.add(alias.canonicalInterfaceKey);
      for (final entry in identities.entries) {
        if (entry.value.hasKey(key, kind)) seen.add(entry.key);
      }
    }
    final result = seen.toList()..sort();
    return result;
  }

  /// 登记别名；已指向别的正式身份时**不覆盖**（先到先得，Go 同款）。
  ///
  /// 不覆盖的原因：覆盖会让先前那台设备下次解析时被"抢走"身份，
  /// 而它本地数据仍挂在旧身份下。
  void addAlias(String key, String canonical, String kind) {
    if (key.isEmpty || !identities.containsKey(canonical)) return;
    final current = aliases[key];
    if (current != null && current.canonicalInterfaceKey != canonical) return;
    aliases[key] = PlaybackIdentityAlias(
      canonicalInterfaceKey: canonical,
      kind: kind,
    );
  }

  Map<String, Object?> toJson() => {
    'epoch': epoch,
    'updatedAt': updatedAt,
    'identities': {
      for (final entry in identities.entries) entry.key: entry.value.toJson(),
    },
    'aliases': {
      for (final entry in aliases.entries) entry.key: entry.value.toJson(),
    },
  };

  static PlaybackIdentityRegistry fromJson(Object? value) {
    final map = asMap(value);
    final registry = PlaybackIdentityRegistry()
      ..epoch = asInt(map['epoch']) ?? 0
      ..updatedAt = asInt(map['updatedAt']) ?? 0;
    for (final entry in asMap(map['identities']).entries) {
      final record = PlaybackIdentityRecord.fromJson(entry.value);
      if (record == null) continue;
      registry.identities[record.canonicalInterfaceKey] = record;
    }
    for (final entry in asMap(map['aliases']).entries) {
      final key = normalizePlaybackIdentityKey(entry.key);
      final alias = asMap(entry.value);
      final canonical = normalizePlaybackIdentityKey(
        asNonEmptyString(alias['canonicalInterfaceKey']),
      );
      if (key == null || canonical == null) continue;
      // 指向不存在的身份（文件被手改过）一律丢弃，避免脏别名把
      // 后续解析引到空身份上。
      if (!registry.identities.containsKey(canonical)) continue;
      registry.aliases[key] = PlaybackIdentityAlias(
        canonicalInterfaceKey: canonical,
        kind: asNonEmptyString(alias['kind']) ?? 'interface',
      );
    }
    return registry;
  }
}

/// 选身份的纯函数（Go `playbackChooseIdentity` 同款判定顺序）。
///
/// 顺序很重要：`strict` → `endpoint` → `legacy`，前一层无命中才降级，
/// 因为它们的区分度依次下降。`host` 只作为**弱线索**，必须用户确认。
PlaybackIdentityResolution choosePlaybackIdentity(
  PlaybackIdentityRegistry registry,
  PlaybackIdentityInput input,
) {
  final bound = registry.boundCanonical(input.interfaceKey);

  var strong = registry.candidates(input.strictAddressKeys, 'strict');
  var matchedBy = 'strictAddressKey';
  var matchedKeys = input.strictAddressKeys;
  if (strong.isEmpty) {
    strong = registry.candidates(input.endpointMatchKeys, 'endpoint');
    matchedBy = 'endpointMatchKey';
    matchedKeys = input.endpointMatchKeys;
  }
  if (strong.isEmpty) {
    strong = registry.candidates(input.legacyConfigKeys, 'legacy');
    matchedBy = 'legacyConfigKey';
    matchedKeys = input.legacyConfigKeys;
  }

  if (bound != null) {
    // 身份键已登记，却给出了指向**另一个**正式身份的地址线索：
    // 两个不同身份声称同一地址，服务端不能替用户选边。
    if (strong.isNotEmpty && (strong.length != 1 || strong.single != bound)) {
      return PlaybackIdentityResolution(
        action: 'conflict',
        matchedBy: matchedBy,
        matchedKeys: matchedKeys,
        candidates: strong,
        error: 'Submitted interface is bound to a different identity',
      );
    }
    return PlaybackIdentityResolution(
      action: 'keep',
      canonicalInterfaceKey: bound,
      matchedBy: 'interfaceKey',
    );
  }

  if (strong.length > 1) {
    // 同一批地址线索命中多个身份：合并会静默把两份历史搅在一起。
    return PlaybackIdentityResolution(
      action: 'conflict',
      matchedBy: matchedBy,
      matchedKeys: matchedKeys,
      candidates: strong,
      error: 'Address clues belong to multiple identities',
    );
  }
  if (strong.length == 1) {
    final canonical = strong.single;
    if (input.sourceDataState != 'empty') {
      if (input.confirm) {
        return PlaybackIdentityResolution(
          action: 'merge',
          canonicalInterfaceKey: canonical,
          matchedBy: matchedBy,
          matchedKeys: matchedKeys,
        );
      }
      return PlaybackIdentityResolution(
        action: 'confirm_required',
        canonicalInterfaceKey: canonical,
        matchedBy: matchedBy,
        matchedKeys: matchedKeys,
        candidates: strong,
        error: 'Existing source data requires explicit merge confirmation',
      );
    }
    return PlaybackIdentityResolution(
      action: 'adopt',
      canonicalInterfaceKey: canonical,
      matchedBy: matchedBy,
      matchedKeys: matchedKeys,
    );
  }

  final weak = registry.candidates(input.hostMatchKeys, 'host');
  if (weak.length == 1 && input.confirm) {
    return PlaybackIdentityResolution(
      action: 'merge',
      canonicalInterfaceKey: weak.single,
      matchedBy: 'hostMatchKey',
      matchedKeys: input.hostMatchKeys,
    );
  }
  if (weak.isNotEmpty) {
    return PlaybackIdentityResolution(
      action: 'confirm_required',
      matchedBy: 'hostMatchKey',
      matchedKeys: input.hostMatchKeys,
      candidates: weak,
      error: 'Host-only match requires confirmation',
    );
  }
  return PlaybackIdentityResolution(
    action: 'create',
    canonicalInterfaceKey: input.interfaceKey,
  );
}

/// 响应基座（Go `playbackIdentityResponse` 同款字段）。
///
/// [extra] **整体覆盖**基线值——这是与 Go 的差异点（Go 用 `if _, exists`
/// 回填，导致 `matchedBy`/`matchedKeys` 永远是基线值）。
Map<String, Object?> playbackIdentityResponse(
  String action,
  PlaybackIdentityInput input, {
  Map<String, Object?> extra = const {},
  bool playbackSync = true,
}) => {
  'ok': action != 'conflict' && action != 'invalid' && action != 'unavailable',
  'schema': playbackIdentitySchema,
  'identityProtocol': playbackIdentitySchema,
  'addressMatchVersion': playbackIdentityAddressMatchVersion,
  'action': action,
  'canonicalInterfaceKey': '',
  'sourceInterfaceKey': input.interfaceKey,
  'matchedBy': 'none',
  'matchedKeys': const <String>[],
  'migrationRequired': false,
  'migrationDone': false,
  'resetSince': false,
  'nextSince': '',
  'identityEpoch': '',
  'capabilities': playbackIdentityCapabilities(playbackSync: playbackSync),
  ...extra,
};

/// 身份注册表 + 解析入口（状态层持有，负责落盘）。
///
/// 按 `configType` 分注册表：安卓的 `vod`/`live`/`wall` 是三个独立配置空间，
/// 混在一起会让直播源的键命中点播身份（[normalizePlaybackConfigType] 保证
/// 键空间只有三种）。
class PlaybackIdentityStore {
  PlaybackIdentityStore({this.onChanged, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// 注册表变更后的回调（状态层据此落盘）。
  ///
  /// 只在**成功变更**时触发；`conflict`/`confirm_required` 不改状态、不落盘。
  final void Function()? onChanged;

  final DateTime Function() _clock;
  final Map<String, PlaybackIdentityRegistry> _registries = {};

  PlaybackIdentityRegistry registryFor(Object? configType) =>
      _registries.putIfAbsent(
        normalizePlaybackConfigType(configType),
        PlaybackIdentityRegistry.new,
      );

  /// 处理一次解析请求（`design/01` §3.2.1）。
  ///
  /// 返回的记录里的 `statusCode` 直接用作 HTTP 状态码：
  /// `conflict` → 409，其余 → 200，非法请求由调用方先行拦下（400）。
  ({int statusCode, Map<String, Object?> body}) resolve(
    PlaybackIdentityInput input,
  ) {
    final registry = registryFor(input.configType);
    final resolution = choosePlaybackIdentity(registry, input);

    if (resolution.action == 'conflict') {
      return (
        statusCode: 409,
        body: playbackIdentityResponse(
          'conflict',
          input,
          extra: resolution.toExtra(),
        ),
      );
    }
    if (resolution.action == 'confirm_required') {
      return (
        statusCode: 200,
        body: playbackIdentityResponse(
          'confirm_required',
          input,
          extra: resolution.toExtra(),
        ),
      );
    }

    final canonical = resolution.canonicalInterfaceKey;
    final now = _clock().millisecondsSinceEpoch;
    final record = registry.identities[canonical] ??=
        PlaybackIdentityRecord(
          canonicalInterfaceKey: canonical,
          createdAt: now,
        );
    record.addKeys(input, nowMs: now);
    if ((resolution.action == 'adopt' || resolution.action == 'merge') &&
        input.interfaceKey != canonical) {
      registry.addAlias(input.interfaceKey, canonical, 'interface');
    }
    // 登记所有键的别名：下次同一地址从**另一台**设备来解析时，
    // 才能在 strict/endpoint 命中同一条身份。
    for (final key in [
      ...record.strictAddressKeys,
      ...record.endpointMatchKeys,
      ...record.hostMatchKeys,
      ...record.legacyConfigKeys,
    ]) {
      registry.addAlias(key, canonical, record.kindOf(key));
    }
    registry.epoch += 1;
    registry.updatedAt = now;
    onChanged?.call();

    return (
      statusCode: 200,
      body: playbackIdentityResponse(
        resolution.action,
        input,
        extra: resolution.toExtra()..addAll({
          'identityEpoch': '${registry.epoch}',
        }),
      ),
    );
  }

  Map<String, Object?> toJson() => {
    for (final entry in _registries.entries) entry.key: entry.value.toJson(),
  };

  static PlaybackIdentityStore fromJson(
    Object? value, {
    void Function()? onChanged,
    DateTime Function()? clock,
  }) {
    final store = PlaybackIdentityStore(onChanged: onChanged, clock: clock);
    for (final entry in asMap(value).entries) {
      store._registries[normalizePlaybackConfigType(entry.key)] =
          PlaybackIdentityRegistry.fromJson(entry.value);
    }
    return store;
  }
}

/// `GET /api/playback/sync/status` 的响应体（`design/01` §3.2.1）。
///
/// 安卓本身**不调用**这个端点（它只按同步 URL 推导 `identity/resolve`），
/// 它存在两个理由：第三方/调试能读到能力声明；`design/04` 的 6c 门禁要求
/// `capabilities.identityResolve = true` 可断言。
Map<String, Object?> buildPlaybackSyncStatus({
  required String configKey,
  required bool playbackSyncEnabled,
  required int items,
  required int tombstones,
  required int nextSince,
  required String endpoint,
  String identityEpoch = '',
}) => {
  'ok': true,
  'configKey': configKey,
  'identityProtocol': playbackIdentitySchema,
  'addressMatchVersion': playbackIdentityAddressMatchVersion,
  'capabilities': playbackIdentityCapabilities(playbackSync: playbackSyncEnabled),
  'items': items,
  'tombstones': tombstones,
  'nextSince': '$nextSince',
  // PC 的历史库不做时间窗清理（`design/01` §4.3 只要求删除墓碑传播），
  // 因此这里如实报 `0`，而不是抄 Go 的 `90`——报一个不存在的保留期
  // 会让第三方客户端以为数据会过期。
  'retentionDays': 0,
  'endpoint': endpoint,
  'identityEpoch': identityEpoch,
};
