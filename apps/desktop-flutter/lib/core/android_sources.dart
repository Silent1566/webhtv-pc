/// 安卓侧配置清单（`/manage/configs`）的**纯逻辑**解析层。
///
/// 为什么需要：T4 网关（`/vod/api?ac=config`）只服务**设备当前激活**的那份
/// 点播配置，而安卓上通常存着好几个源。要「把安卓版的所有源都拉过来并支持
/// 切换」，就必须先拿到这份清单，再用 `interfaceKey` 逐个取站点。
///
/// 为什么用 `interfaceKey` 而不是配置地址：`url` 会变（用户改订阅地址、地址
/// 别名重写），而 `interfaceKey` 由安卓 `Config.ensureInterfaceKey()` 生成后
/// 稳定不变，且 `/manage/configs` 与 `/vod/api?ac=config&configKey=` 都用它。
///
/// **不做**：网络请求、UI、数据库（那些属于 services/ 与状态层）。
library;

import 'protocol.dart';

/// 安卓 `Config.type` 的影视配置（本文件只关心这一类）。
const int androidSourceTypeVod = 0;

/// 直播配置（直播源由 `fetchLiveSources` 单独取，不走本清单）。
const int androidSourceTypeLive = 1;

/// 壁纸配置。
const int androidSourceTypeWall = 2;

/// 安卓设备上的一个点播源。
class AndroidSource {
  const AndroidSource({
    required this.interfaceKey,
    required this.name,
    required this.url,
    this.active = false,
    this.updatedAtMs = 0,
  });

  /// 稳定标识（安卓 `Config.ensureInterfaceKey()`）。
  final String interfaceKey;

  /// 用户可见名称；设备未命名时为空串。
  final String name;

  /// 该源在安卓上的配置地址（订阅 URL / 本地路径）。
  final String url;

  /// 是否安卓当前激活的源。
  final bool active;

  /// 安卓侧时间戳（毫秒），用于同 `interfaceKey` 去重时取最新。
  final int updatedAtMs;

  /// 展示名：无名称时回退到主机名，再回退到标识前缀。
  String get displayName {
    if (name.isNotEmpty) return name;
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.isNotEmpty) return host;
    return shortKey;
  }

  /// 标识前 8 位（日志与诊断用；完整标识可能很长且含随机性）。
  String get shortKey =>
      interfaceKey.length <= 8 ? interfaceKey : interfaceKey.substring(0, 8);

  Map<String, Object?> toJson() => {
    'interfaceKey': interfaceKey,
    'name': name,
    'url': url,
    'active': active,
    'time': updatedAtMs,
  };

  /// 从 `/manage/configs` 的单项解析；无法定位的条目返回 `null`。
  static AndroidSource? fromJson(
    Object? value, {
    List<String>? diagnostics,
  }) {
    final map = asMap(value);
    final type = asInt(map['type']) ?? androidSourceTypeVod;
    if (type != androidSourceTypeVod) {
      diagnostics?.add('跳过非点播配置（type=$type）');
      return null;
    }
    final url = asNonEmptyString(map['url']);
    if (url == null) {
      diagnostics?.add('跳过缺少 url 的点播配置');
      return null;
    }
    final key = asNonEmptyString(map['interfaceKey']);
    if (key == null) {
      diagnostics?.add(
        '跳过缺少 interfaceKey 的点播配置（安卓版本过旧，无法按源定位）',
      );
      return null;
    }
    return AndroidSource(
      interfaceKey: key,
      name: asNonEmptyString(map['name']) ?? '',
      url: url,
      active: asFlag(map['active']),
      updatedAtMs: asInt(map['time']) ?? 0,
    );
  }
}

/// 一次清单拉取的结果：源列表 + 需要告诉用户的诊断。
class AndroidSourceCatalog {
  const AndroidSourceCatalog({
    this.sources = const [],
    this.diagnostics = const [],
  });

  final List<AndroidSource> sources;

  /// 用户可见说明（跳过的条目、去重结果等）。空表示一切正常。
  final List<String> diagnostics;

  bool get isEmpty => sources.isEmpty;

  bool get isNotEmpty => sources.isNotEmpty;

  /// 安卓当前激活的源（清单里没有 `active` 时为 `null`）。
  AndroidSource? get active {
    for (final source in sources) {
      if (source.active) return source;
    }
    return null;
  }

  AndroidSource? byInterfaceKey(String? interfaceKey) {
    final key = interfaceKey?.trim() ?? '';
    if (key.isEmpty) return null;
    for (final source in sources) {
      if (source.interfaceKey == key) return source;
    }
    return null;
  }
}

/// 解析 `/manage/configs` 的响应。
///
/// [base] 只用于诊断文案（标明是哪台设备）。
///
/// **只保留 `type=0`**：直播（`type=1`）与壁纸（`type=2`）不在桥接源列表里，
/// 直播源由 `AndroidBridgeService.fetchLiveSources` 单独取回。
///
/// 同一 `interfaceKey` 出现多次时保留 `time` 最大的一条（安卓 `configs()`
/// 会把「当前配置」再追加一次，直接使用会出现重复条目）。
AndroidSourceCatalog parseAndroidSources(
  Object? decoded, {
  required String base,
}) {
  final diagnostics = <String>[];
  final map = asMap(decoded);
  final items = map['items'];
  if (items is! List) {
    diagnostics.add('设备返回的配置清单格式不正确（缺少 items 数组）');
    return AndroidSourceCatalog(diagnostics: diagnostics);
  }

  final ordered = <String, AndroidSource>{};
  var dropped = 0;
  final localDrops = <String>[];
  for (final item in items) {
    final source = AndroidSource.fromJson(item, diagnostics: localDrops);
    if (source == null) {
      dropped++;
      continue;
    }
    final existing = ordered[source.interfaceKey];
    if (existing == null) {
      ordered[source.interfaceKey] = source;
      continue;
    }
    if (source.updatedAtMs >= existing.updatedAtMs) {
      ordered[source.interfaceKey] = source;
    }
  }

  if (dropped > 0) {
    // 相同的跳过原因只报一次，避免清单里 20 个坏条目刷 20 行日志。
    final reasons = localDrops.toSet();
    diagnostics.add('已跳过 $dropped 个不可用配置：${reasons.join('、')}');
  }
  if (ordered.isEmpty) {
    diagnostics.add('安卓设备上没有可用的点播配置（$base）');
  }
  return AndroidSourceCatalog(
    sources: ordered.values.toList(growable: false),
    diagnostics: diagnostics,
  );
}
