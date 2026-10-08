/// 安卓 T4 网关桥接的**纯逻辑**层（`docs/phase5/design/01`）。
///
/// 职责边界（`design/01` §2）：
/// - 设备 JSON 解析（[AndroidDevice]）；
/// - 网关地址规范化（[normalizeBase]）；
/// - T4 配置 → [AppConfig] 转换（[convertGatewayConfig]）；
/// - 响应主机一致性校验（P2）；
/// - 站点保真（[BridgeConversion] 的统计与诊断）。
///
/// **不做**：网络请求、UI、数据库。那些属于
/// `lib/services/android_bridge_service.dart` 与状态层。
///
/// 核心契约（`design/00` §4 P2）：真实网关用**请求的 `Host` 头**现算每个站点的
/// `api` 地址（实测：同一请求改 `Host`，地址随之变化）。因此调用方必须传入
/// PC 视角的**可达地址**，本模块负责校验响应主机与它一致。
library;

import 'dart:convert';

import 'app_error.dart';
import 'config_parser.dart';
import 'http_api.dart';
import 'protocol.dart';

/// 安卓设备的默认服务起始端口（`Server.start()` 从 9978 顺序探测到 9998）。
const int androidDefaultPort = 9978;
const int androidPortRangeEnd = 9998;

/// 一个已识别的安卓设备（`design/01` §4.3）。
///
/// [reachableBase] 与 [reportedIp] **必须分开**：
/// - [reachableBase] 是 PC 视角真正能连上的地址（局域网 IP，或 `adb forward`
///   后的回环地址）；
/// - [reportedIp] 是设备自己上报的地址（`/device` 的 `ip` 字段），在模拟器
///   NAT 场景下 PC 可能**不可达**。
///
/// 实测：设备上报 `http://172.16.1.4:9978`，而 PC 只能经
/// `adb forward tcp:19978 tcp:9978` 得到 `127.0.0.1:19978`。
class AndroidDevice {
  const AndroidDevice({
    required this.uuid,
    required this.name,
    required this.reachableBase,
    this.reportedIp = '',
    this.type = 0,
    this.serial = '',
    this.wlan = '',
    this.eth = '',
    this.time = 0,
  });

  /// 唯一标识，来自 `/device` 的 `uuid`。相等性**只比它**（对齐上游
  /// `Device.equals`），这样同一设备经不同 `adb forward` 端口被添加两次时
  /// 会被识别为同一台。
  final String uuid;
  final String name;

  /// PC 视角的可达基址（规范化后，无尾随 `/`）。
  final String reachableBase;

  /// 设备自报地址，仅用于展示与诊断，**不得**用作请求地址。
  final String reportedIp;

  /// `0`=Leanback(TV)、`1`=Mobile、`2`=DLNA。
  final int type;
  final String serial;
  final String wlan;
  final String eth;
  final int time;

  /// 设备类型文案。
  String get typeLabel => switch (type) {
    0 => '电视',
    1 => '手机/平板',
    2 => '投屏设备',
    _ => '未知设备',
  };

  /// 是否为「应用对端」（可被同步）——对齐上游 `Device.isApp()`。
  bool get isApp => type == 0 || type == 1;

  /// 脱敏后的设备标识，只保留前 4 位（`design/01` §7）。
  String get maskedUuid =>
      uuid.length <= 4 ? '****' : '${uuid.substring(0, 4)}****';
  /// 从 `/device` 响应解析（`design/01` §4.3）。
  ///
  /// [reachableBase] 由调用方提供（PC 视角可达地址），不来自响应。
  /// 响应缺少 `uuid` 或不是合法设备对象时抛 [AppErrorKind.bridgeNotAndroid]。
  static AndroidDevice fromJson(
    Object? value, {
    required String reachableBase,
  }) {
    final map = asMap(value);
    final uuid = asNonEmptyString(map['uuid']);
    final name = asNonEmptyString(map['name']);
    if (uuid == null || name == null) {
      throw AppError(
        AppErrorKind.bridgeNotAndroid,
        '该地址不是 WebHTV 安卓服务',
        detail: '响应缺少 uuid/name 字段',
      );
    }
    return AndroidDevice(
      uuid: uuid,
      name: name,
      reachableBase: normalizeBase(reachableBase),
      reportedIp: asString(map['ip']) ?? '',
      type: asInt(map['type']) ?? 0,
      serial: asString(map['serial']) ?? '',
      wlan: asString(map['wlan']) ?? '',
      eth: asString(map['eth']) ?? '',
      time: asInt(map['time']) ?? 0,
    );
  }

  /// 只比 `uuid`（对齐上游 `Device.equals`）。
  @override
  bool operator ==(Object other) =>
      other is AndroidDevice && other.uuid == uuid;

  @override
  int get hashCode => uuid.hashCode;

  @override
  String toString() =>
      'AndroidDevice($name $maskedUuid @ $reachableBase type=$type)';
}

/// 把用户输入或扫描结果规范化成一个可用的基址（`design/01` §4.2）。
///
/// 规则：
/// 1. 缺 scheme → 补 `http://`；
/// 2. 带路径 → **只取 scheme + host + port**（网关路径由实现拼接）；
/// 3. 缺端口 → 默认 [androidDefaultPort]；
/// 4. 尾随 `/` → 去掉；
/// 5. `localhost` **保留原样**（合法回环地址，与 `127.0.0.1` 等价，不强行改写）。
///
/// 只接受 `http`/`https`，其他 scheme 抛 [AppErrorKind.bridgeUnreachable]。
String normalizeBase(String input) {
  var text = input.trim();
  if (text.isEmpty) {
    throw AppError(AppErrorKind.bridgeUnreachable, '设备地址不能为空');
  }
  if (!text.contains('://')) text = 'http://$text';
  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty) {
    throw AppError(
      AppErrorKind.bridgeUnreachable,
      '设备地址无法解析',
      detail: input,
    );
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw AppError(
      AppErrorKind.bridgeUnreachable,
      '设备地址协议不受支持（仅允许 http/https）',
      detail: uri.scheme,
    );
  }
  final port = uri.hasPort ? uri.port : androidDefaultPort;
  return '${uri.scheme}://${uri.host}:$port';
}

/// 规范化结果的 `host:port` 部分，用于主机一致性比较。
String hostPortOf(String base) {
  final uri = Uri.parse(normalizeBase(base));
  return '${uri.host}:${uri.port}';
}

/// 是否为回环主机（`127.0.0.0/8`、`localhost`、`::1`）。
bool isLoopbackHost(String host) {
  final lower = host.toLowerCase();
  if (lower == 'localhost' || lower == '::1' || lower == '[::1]') return true;
  final parts = lower.split('.');
  return parts.length == 4 && parts.first == '127';
}

/// 站点地址主机被修正的诊断（`design/01` §5.3 第二种情形）。
class BridgeHostRewrite {
  const BridgeHostRewrite({
    required this.siteKey,
    required this.from,
    required this.to,
  });

  final String siteKey;
  final String from;
  final String to;
}

/// 转换结果：配置 + 诊断（`design/01` §5）。
class BridgeConversion {
  const BridgeConversion({
    required this.config,
    this.diagnostics = const [],
    this.hostRewrites = const [],
    this.skippedSites = const [],
    this.ignoredTopLevelFields = const [],
  });

  final AppConfig config;

  /// 用户可见的说明（跳过站点、主机修正、忽略字段等）。
  final List<String> diagnostics;

  /// 主机被修正的站点（P2 第二种情形）。
  final List<BridgeHostRewrite> hostRewrites;

  /// 被跳过的站点 key（非 `type=4`、或指向 PC 自己）。
  final List<String> skippedSites;

  /// 被忽略的顶层字段（`spider`/`lives` 等，`design/01` §3.2）。
  final List<String> ignoredTopLevelFields;

  /// 导入的站点数。
  int get siteCount => config.sites.length;

  /// 是否有站点被跳过或字段被忽略（UI 需要提示用户）。
  bool get hasNotes =>
      diagnostics.isNotEmpty ||
      skippedSites.isNotEmpty ||
      ignoredTopLevelFields.isNotEmpty;
}

/// 把 T4 网关的配置 JSON 转成 PC 可用的 [AppConfig]（`design/01` §5）。
///
/// [jsonText] 是 `/vod/api?ac=config` 的响应原文；
/// [reachableBase] 是 PC 视角的**可达地址**，用于 P2 主机一致性校验。
///
/// [selfBase] 是 PC 自己正在监听的地址（可选）。命中时对应站点被跳过
/// （`design/00` P4 自引用防护）。
///
/// 抛出的错误类别：
/// - [AppErrorKind.configInvalid] / [AppErrorKind.configMsg]：来自配置解析；
/// - [AppErrorKind.bridgeNoGateway]：响应是配置仓库（T4 网关不返回仓库）；
/// - [AppErrorKind.bridgeEmptySites]：没有可用站点；
/// - [AppErrorKind.bridgeHostMismatch]：站点主机既非请求主机也非回环；
/// - [AppErrorKind.bridgeSelfReference]：目标就是 PC 自己。
BridgeConversion convertGatewayConfig({
  required String jsonText,
  required String reachableBase,
  String? selfBase,
}) {
  final base = normalizeBase(reachableBase);
  final expectedHostPort = hostPortOf(base);
  final selfHostPort = selfBase == null ? null : hostPortOf(selfBase);

  if (selfHostPort != null && selfHostPort == expectedHostPort) {
    throw AppError(
      AppErrorKind.bridgeSelfReference,
      '不能把本机自己当作安卓设备',
      detail: base,
    );
  }

  // `msg` 语义（§7.4.3）必须优先识别：它表示**配置级失败**，与“站点为空”不同。
  // 注意不能用 `parseConfigDocument` 的结果做这个判定 —— 它会在 `sites` 为空时
  // 先抛 `configInvalid`，把 `msg` 和 `bridgeEmptySites` 都掩盖掉。
  final probe = _probeTopLevel(jsonText);
  if (probe.containsKey('msg')) {
    final message = asNonEmptyString(probe['msg']);
    throw AppError(
      AppErrorKind.configMsg,
      message ?? '配置未提供错误详情（msg 为空）',
      detail: 'msg',
    );
  }

  // §7.4.2 的仓库识别：T4 网关**不**返回配置仓库。这里必须在解析器之前判定，
  // 否则空 `sites` 会被解析器当成 `configInvalid`。
  final repositoryEntries = asList(probe['urls']);
  if (repositoryEntries.isNotEmpty && asList(probe['sites']).isEmpty) {
    throw AppError(
      AppErrorKind.bridgeNoGateway,
      '该地址返回的是配置仓库，不是 T4 网关配置',
      detail: base,
    );
  }

  // 空站点必须在解析器之前判定，否则会被它当作 `configInvalid`。
  if (probe.containsKey('sites') && asList(probe['sites']).isEmpty) {
    throw AppError(
      AppErrorKind.bridgeEmptySites,
      '安卓设备上尚未加载任何点播配置，没有可导入的站点',
      detail: base,
    );
  }

  final document = parseConfigDocument(jsonText);

  if (document.isRepository || document.config == null) {
    throw AppError(
      AppErrorKind.bridgeNoGateway,
      '该地址返回的是配置仓库，不是 T4 网关配置',
      detail: base,
    );
  }

  final source = document.config!;
  final raw = document.raw;
  final diagnostics = <String>[];
  final rewrites = <BridgeHostRewrite>[];
  final skipped = <String>[];
  final sites = <Site>[];

  for (final site in source.sites) {
    if (site.type != SiteType.jsonApiBase64Ext) {
      skipped.add(site.key);
      diagnostics.add('跳过非 T4 站点 ${site.key}（type=${site.type}）');
      continue;
    }
    final resolved = _resolveSiteApi(
      site: site,
      expectedHostPort: expectedHostPort,
      base: base,
      selfHostPort: selfHostPort,
      rewrites: rewrites,
      skipped: skipped,
      diagnostics: diagnostics,
    );
    if (resolved == null) continue;
    sites.add(resolved);
  }

  if (sites.isEmpty) {
    throw AppError(
      AppErrorKind.bridgeEmptySites,
      '安卓设备上尚未加载任何点播配置，没有可导入的站点',
      detail: '$base（响应含 ${source.sites.length} 个条目，可用 0 个）',
    );
  }

  // P2（`design/01` §5.3 第二种情形）：主机修正必须是**用户可见**的。
  // 静默修正会让用户在排障时看到“站点地址与设备不符”却毫无线索。
  if (rewrites.isNotEmpty) {
    diagnostics.insert(
      0,
      '已修正 ${rewrites.length} 个站点地址的主机（原为回环地址，'
      '已改为本次请求的可达地址 $expectedHostPort）',
    );
  }

  // 顶层字段：T4 网关不转发 Android 的 spider/lives（`design/01` §3.2）。
  final ignored = <String>[];
  for (final field in const ['spider', 'lives']) {
    final value = raw[field];
    final hasContent = switch (value) {
      null => false,
      String() => value.trim().isNotEmpty,
      List() => value.isNotEmpty,
      Map() => value.isNotEmpty,
      _ => true,
    };
    if (hasContent) {
      ignored.add(field);
      diagnostics.add('忽略顶层字段 $field（T4 网关不转发，Android 侧自行使用）');
    }
  }

  final config = source.copyWith(
    sites: sites,
    name: source.name ?? '安卓桥接（${Uri.parse(base).host}）',
  );

  return BridgeConversion(
    config: config,
    diagnostics: diagnostics,
    hostRewrites: rewrites,
    skippedSites: skipped,
    ignoredTopLevelFields: ignored,
  );
}

/// 校验并（必要时）修正单个站点的 `api` 主机（`design/01` §5.3）。
///
/// 三种情形：
/// - 响应主机 = 请求主机 → 保留原样；
/// - 响应主机是回环，请求主机**不是**回环 → 重写为请求主机 + 记诊断；
/// - 其他（指向第三方） → 抛 [AppErrorKind.bridgeHostMismatch]。
///
/// 返回 `null` 表示该站点应被跳过（自引用）。
Site? _resolveSiteApi({
  required Site site,
  required String expectedHostPort,
  required String base,
  required String? selfHostPort,
  required List<BridgeHostRewrite> rewrites,
  required List<String> skipped,
  required List<String> diagnostics,
}) {
  final api = site.api.trim();
  if (api.isEmpty) {
    skipped.add(site.key);
    diagnostics.add('跳过无 api 的站点 ${site.key}');
    return null;
  }
  final uri = Uri.tryParse(api);
  if (uri == null || uri.host.isEmpty) {
    skipped.add(site.key);
    diagnostics.add('跳过 api 无法解析的站点 ${site.key}');    return null;
  }

  final siteHostPort = '${uri.host}:${uri.hasPort ? uri.port : androidDefaultPort}';

  // P4：站点指向 PC 自己 → 跳过该站点（不因单个站点否定整份配置）。
  if (selfHostPort != null && siteHostPort == selfHostPort) {
    skipped.add(site.key);
    diagnostics.add('跳过指向本机的站点 ${site.key}');
    return null;
  }

  if (siteHostPort == expectedHostPort) return site;

  if (isLoopbackHost(uri.host)) {
    // 第二种情形：中间层把 Host 改写成了回环。path 与 query 完全正确，
    // 只有主机需要修正，因此重写是信息完备的（`design/01` §5.3）。
    final rewritten = Uri.parse(base).replace(
      path: uri.path,
      query: uri.hasQuery ? uri.query : null,
    );
    rewrites.add(
      BridgeHostRewrite(siteKey: site.key, from: siteHostPort, to: rewritten.authority),
    );
    return Site(
      key: site.key,
      name: site.name,
      type: site.type,
      api: rewritten.toString(),
      jar: site.jar,
      ext: site.ext,
      header: site.header,
      timeoutSeconds: site.timeoutSeconds,
      searchable: site.searchable,
      changeable: site.changeable,
      quickSearch: site.quickSearch,
      filterable: site.filterable,
      categories: site.categories,
      style: site.style,
      hide: site.hide,
      indexs: site.indexs,
      extra: site.extra,
    );
  }

  throw AppError(
    AppErrorKind.bridgeHostMismatch,
    '安卓返回的站点地址不属于该设备，已拒绝导入',
    detail: '站点 ${site.key} 指向 ${uri.host}，期望 $expectedHostPort',
  );
}

/// 站点保真报告（`design/01` §5.4 的机器可校验形式）。
///
/// 用于单测与集成测试断言「导入后站点集合与响应完全一致」。
class SiteFidelityReport {
  const SiteFidelityReport({
    required this.expectedKeys,
    required this.actualKeys,
    required this.expectedNames,
    required this.actualNames,
    required this.mismatchedApiPaths,
    required this.flagMismatches,
  });

  final List<String> expectedKeys;
  final List<String> actualKeys;
  final List<String> expectedNames;
  final List<String> actualNames;

  /// `api` 的 path+query 不一致的站点 key（主机允许被修正）。
  final List<String> mismatchedApiPaths;

  /// 标志位不一致的站点 key。
  final List<String> flagMismatches;

  bool get isFidelityOk =>
      _sameSet(expectedKeys, actualKeys) &&
      _sameSet(expectedNames, actualNames) &&
      mismatchedApiPaths.isEmpty &&
      flagMismatches.isEmpty;

  String get summary =>
      'sites=${actualKeys.length} keys-ok=${_sameSet(expectedKeys, actualKeys)} '
      'names-ok=${_sameSet(expectedNames, actualNames)} '
      'api-path-mismatch=${mismatchedApiPaths.length} '
      'flag-mismatch=${flagMismatches.length}';

  static bool _sameSet(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    final left = [...a]..sort();
    final right = [...b]..sort();
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }
}

/// 比较 T4 响应与转换结果，产出保真报告。
///
/// 只比较**期望被保留**的站点（非 `type=4` 与被跳过的站点不参与），
/// 因此调用方需传入 [skippedSites] 以对齐两侧集合。
SiteFidelityReport checkSiteFidelity({
  required AppConfig source,
  required BridgeConversion conversion,
  List<String> skippedSites = const [],
}) {
  final skip = skippedSites.toSet();
  final expected = source.sites
      .where((site) => site.type == SiteType.jsonApiBase64Ext)
      .where((site) => !skip.contains(site.key))
      .toList();
  final actual = conversion.config.sites;

  final actualByKey = {for (final site in actual) site.key: site};
  final pathMismatch = <String>[];
  final flagMismatch = <String>[];

  for (final site in expected) {
    final other = actualByKey[site.key];
    if (other == null) continue;
    if (_apiPathQuery(site.api) != _apiPathQuery(other.api)) {
      pathMismatch.add(site.key);
    }
    if (site.searchable != other.searchable ||
        site.quickSearch != other.quickSearch ||
        site.filterable != other.filterable) {
      flagMismatch.add(site.key);
    }
  }

  return SiteFidelityReport(
    expectedKeys: expected.map((site) => site.key).toList(),
    actualKeys: actual.map((site) => site.key).toList(),
    expectedNames: expected.map((site) => site.name).toList(),
    actualNames: actual.map((site) => site.name).toList(),
    mismatchedApiPaths: pathMismatch,
    flagMismatches: flagMismatch,
  );
}

/// `api` 的 path + query（主机与端口之外的部分），用于保真比较。
String _apiPathQuery(String api) {
  final uri = Uri.tryParse(api);
  if (uri == null) return api;
  return '${uri.path}?${uri.query}';
}

/// 宽松探测顶层 JSON 字段。
///
/// 用于在 `parseConfigDocument` **之前**区分三种语义不同的失败：
/// `msg`（配置级失败）、`urls` 仓库（不是 T4 网关）、空 `sites`（无站点）。
/// 解析失败时返回空表，把错误留给 `parseConfigDocument` 报出它自己的
/// `configInvalid` 详情。
Map<String, Object?> _probeTopLevel(String jsonText) {
  try {
    final decoded = jsonDecode(jsonText);
    if (decoded is Map) return asMap(decoded);
  } on FormatException {
    // 交给 parseConfigDocument 报错。
  }
  return const {};
}
