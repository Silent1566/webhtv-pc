/// 弹幕库设置（`docs/phase9/design/02` §2）。
///
/// 默认关闭：未配置地址时不发任何请求，行为与 Phase 3–8 一致。
///
/// 多弹幕源（S1）：用户可配置多条源并行搜索，所以设置里存的是 [sources] 列表；
/// 旧的单地址 `apiUrl` 保留为**派生 getter**——S2/S3 迁移完成前，设置页、
/// 诊断页与持久化都还在读它，删掉会让整条链静默失效。
library;

/// 一条可配置的弹幕源。
///
/// [id] 是稳定标识（结果条目的 `libraryId`、按来源筛选、回写配置都靠它），
/// 不是给人看的；显示用 [name]。地址允许暂时非法（用户正在输入），
/// 合法性由 [isValidDanmakuApiUrl] 在真正发请求前判。
class DanmakuSourceConfig {
  const DanmakuSourceConfig({
    required this.id,
    required this.name,
    required this.url,
    this.enabled = true,
  });

  final String id;
  final String name;
  final String url;
  final bool enabled;

  /// 地址是否可用（http(s) 且 host 非空）。与 [enabled] 是两个独立事实。
  bool get isValid => isValidDanmakuApiUrl(url);

  DanmakuSourceConfig copyWith({String? name, String? url, bool? enabled}) =>
      DanmakuSourceConfig(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        enabled: enabled ?? this.enabled,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'url': url,
    'enabled': enabled,
  };

  /// 解析一条源；非法（非 Map，或没有 url）返回 null。
  ///
  /// 只看「有没有 url」而不看「url 是否合法」：用户填到一半就落盘的条目不该丢，
  /// 真发请求前还有 [isValidDanmakuApiUrl] 这一道闸。
  static DanmakuSourceConfig? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final url = raw['url'] is String ? (raw['url'] as String).trim() : '';
    if (url.isEmpty) return null;
    final id = raw['id'] is String ? (raw['id'] as String).trim() : '';
    final name = raw['name'] is String ? (raw['name'] as String).trim() : '';
    return DanmakuSourceConfig(
      // 缺 id/name 时用地址兜底：两者只是标识与显示文案，不值得为缺失丢掉整条源。
      id: id.isEmpty ? url : id,
      name: name.isEmpty ? url : name,
      url: url,
      enabled: raw['enabled'] is bool ? raw['enabled'] as bool : true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DanmakuSourceConfig &&
      other.id == id &&
      other.name == name &&
      other.url == url &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(id, name, url, enabled);

  @override
  String toString() =>
      'DanmakuSourceConfig($id, "$name", url="$url", enabled=$enabled)';
}

class DanmakuSettings {
  const DanmakuSettings({this.autoSearch = false, this.sources = const []});

  const DanmakuSettings.defaults() : this();

  /// 播放结果没有弹幕时是否自动搜索弹幕库。
  final bool autoSearch;

  /// 用户配置的弹幕源，顺序即搜索（以及合并结果）的顺序。
  final List<DanmakuSourceConfig> sources;

  /// 启用且地址可用的源。
  ///
  /// 过滤放在这里而不是每个调用点：否则「哪些源真的会被搜」会随调用点不同而不同。
  Iterable<DanmakuSourceConfig> get enabledSources => sources.where(
    (source) => source.enabled && isValidDanmakuApiUrl(source.url),
  );

  /// 兼容旧 API：第一条启用且合法的地址；没有则空串。
  String get apiUrl {
    for (final source in enabledSources) {
      return source.url.trim();
    }
    return '';
  }

  /// 兼容旧 API：有至少一条启用且地址可用的源。
  bool get hasLibrary => enabledSources.isNotEmpty;

  bool get isEnabled => autoSearch && hasLibrary;

  /// [apiUrl] 是给旧设置页/旧测试留的写入口：它写回「第一条启用的源」。
  ///
  /// 多源时代地址不是全局唯一字段，所以这里刻意不做花活：旧页面只有一个输入框，
  /// 它改的必然是当前在用的那一条。
  DanmakuSettings copyWith({
    bool? autoSearch,
    List<DanmakuSourceConfig>? sources,
    String? apiUrl,
  }) {
    final base = sources ?? this.sources;
    return DanmakuSettings(
      autoSearch: autoSearch ?? this.autoSearch,
      sources: apiUrl == null ? base : _withLegacyApiUrl(base, apiUrl),
    );
  }

  static List<DanmakuSourceConfig> _withLegacyApiUrl(
    List<DanmakuSourceConfig> current,
    String raw,
  ) {
    final value = raw.trim();
    final next = <DanmakuSourceConfig>[];
    var applied = false;
    for (final source in current) {
      if (applied || !source.enabled) {
        next.add(source);
        continue;
      }
      applied = true;
      // 清空地址 = 删掉这条源（旧页面把空串读作「未配置」）。
      if (value.isEmpty) continue;
      next.add(source.copyWith(url: value));
    }
    if (!applied && value.isNotEmpty) {
      // 还没有任何启用源：补一条与旧格式迁移同款的 legacy 源。
      next.insert(0, DanmakuSourceConfig(id: 'legacy', name: '默认', url: value));
    }
    return next;
  }

  Map<String, Object?> toJson() {
    final map = <String, Object?>{'autoSearch': autoSearch};
    if (sources.isNotEmpty) {
      map['sources'] = [for (final source in sources) source.toJson()];
    }
    // 兼容键：旧版本（以及 UiPreferencesStore 的既有断言）只会读 apiUrl。
    // 多写一个键的代价远小于「升级后地址看起来丢了」。
    final legacy = apiUrl;
    if (legacy.isNotEmpty) map['apiUrl'] = legacy;
    return map;
  }

  /// 解析设置；兼容旧格式 `{'autoSearch':true,'apiUrl':'http://x'}`。
  ///
  /// 有 sources 键就只认它（新格式权威，即使解析出空列表）；否则把旧 apiUrl
  /// 迁移成一条 legacy 源，避免升级后用户「地址还在但不再生效」。
  factory DanmakuSettings.fromJson(Object? raw) {
    final map = raw is Map ? raw : const {};
    final sources = <DanmakuSourceConfig>[];
    final parsedSources = map['sources'];
    if (parsedSources is List) {
      for (final item in parsedSources) {
        final source = DanmakuSourceConfig.fromJson(item);
        if (source != null) sources.add(source);
      }
    } else {
      final legacyUrl = map['apiUrl'] is String
          ? (map['apiUrl'] as String).trim()
          : '';
      if (legacyUrl.isNotEmpty) {
        sources.add(
          DanmakuSourceConfig(id: 'legacy', name: '默认', url: legacyUrl),
        );
      }
    }
    return DanmakuSettings(
      autoSearch: map['autoSearch'] is bool ? map['autoSearch'] as bool : false,
      sources: sources.isEmpty ? const [] : List.unmodifiable(sources),
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is! DanmakuSettings) return false;
    if (other.autoSearch != autoSearch ||
        other.sources.length != sources.length) {
      return false;
    }
    for (var index = 0; index < sources.length; index++) {
      if (other.sources[index] != sources[index]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(autoSearch, Object.hashAll(sources));

  @override
  String toString() => 'DanmakuSettings(auto=$autoSearch, sources=$sources)';
}

/// 弹幕库地址的来源（`docs/phase9/design/02` §2.3）。
///
/// 三档优先级对齐安卓 `DanmakuSetting.getConfiguredApiUrl()`：手填 > 站点配置
/// `danmaku` 字段 > 本地猫源内置服务。调用方只读 [ResolvedDanmakuSources]，
/// 不再各自拼地址——否则「站点配置到底生不生效」会随调用点不同而不同。
enum DanmakuApiSource { none, user, config, bundle }

/// 生效的弹幕源解析结果（多源版）。
class ResolvedDanmakuSources {
  const ResolvedDanmakuSources({required this.sources, required this.origin});

  /// 已过滤 enabled + http(s)+host + 按 url 去重、保序。
  final List<DanmakuSourceConfig> sources;

  final DanmakuApiSource origin;

  bool get isConfigured => sources.isNotEmpty;

  /// 给人看的来源名（设置页副标题、播放器提示用）。
  String get label => switch (origin) {
    DanmakuApiSource.user => '手填弹幕源',
    DanmakuApiSource.config => '站点配置 danmaku 字段',
    DanmakuApiSource.bundle => '本地猫源弹幕服务',
    DanmakuApiSource.none => '未配置',
  };

  @override
  String toString() => 'ResolvedDanmakuSources($label, ${sources.length} 条)';
}

/// 旧的单地址解析结果；由 [resolveDanmakuApi] 从 [ResolvedDanmakuSources] 派生。
class ResolvedDanmakuApi {
  const ResolvedDanmakuApi({required this.url, required this.source});

  /// 已 trim 的地址；[source] 为 [DanmakuApiSource.none] 时是空串。
  final String url;

  final DanmakuApiSource source;

  bool get isConfigured => url.trim().isNotEmpty;

  /// 给人看的来源名（设置页副标题、播放器提示用）。
  ///
  /// 与 [ResolvedDanmakuSources.label] 刻意不同：这一档文案被旧设置页/诊断页
  /// 直接显示，改动会连带改掉既有截图与测试基线。
  String get label => switch (source) {
    DanmakuApiSource.user => '手填地址',
    DanmakuApiSource.config => '站点配置 danmaku 字段',
    DanmakuApiSource.bundle => '本地猫源弹幕服务',
    DanmakuApiSource.none => '未配置',
  };

  @override
  String toString() => 'ResolvedDanmakuApi($label, url="$url")';
}

/// 地址是否可用：必须 http/https 且 host 非空（对齐安卓 `isValidApiUrl`）。
///
/// 非法候选只跳过、不报错：配置里写错一个地址不该让整条优先级链失效。
bool isValidDanmakuApiUrl(String? url) {
  final raw = url?.trim() ?? '';
  if (raw.isEmpty) return false;
  final uri = Uri.tryParse(raw);
  if (uri == null) return false;
  final scheme = uri.scheme.toLowerCase();
  return (scheme == 'http' || scheme == 'https') && uri.host.isNotEmpty;
}

/// 按「手填 > 站点配置 `danmaku` > 本地猫源」求当前生效的全部弹幕源。
ResolvedDanmakuSources resolveDanmakuSources({
  required DanmakuSettings settings,
  String? configDanmaku,
  String? bundleDanmaku,
}) {
  // 逐档显式列出而不是循环：优先级本身就是契约，读代码时要一眼看到顺序。
  final user = _uniqueValidSources(settings.enabledSources);
  if (user.isNotEmpty) {
    return ResolvedDanmakuSources(sources: user, origin: DanmakuApiSource.user);
  }

  // 站点配置的 danmaku 字段允许逗号分隔多个地址；中英文逗号都吃，
  // 避免只认半角导致整档静默失效。
  final configUrls = _uniqueValidUrls(
    (configDanmaku ?? '').split(RegExp(r'[,，]')),
  );
  if (configUrls.isNotEmpty) {
    return ResolvedDanmakuSources(
      sources: [
        for (var index = 0; index < configUrls.length; index++)
          DanmakuSourceConfig(
            id: 'config-${index + 1}',
            name: '站点配置 ${index + 1}',
            url: configUrls[index],
          ),
      ],
      origin: DanmakuApiSource.config,
    );
  }

  final bundleUrl = (bundleDanmaku ?? '').trim();
  if (isValidDanmakuApiUrl(bundleUrl)) {
    return ResolvedDanmakuSources(
      sources: [
        DanmakuSourceConfig(id: 'bundle', name: '本地猫源', url: bundleUrl),
      ],
      origin: DanmakuApiSource.bundle,
    );
  }

  return const ResolvedDanmakuSources(
    sources: [],
    origin: DanmakuApiSource.none,
  );
}

/// 按「手填 > 站点配置 `danmaku` > 本地猫源」求当前生效的弹幕库地址。
///
/// 兼容包装：取 [resolveDanmakuSources] 的首条，语义与多源之前完全一致。
ResolvedDanmakuApi resolveDanmakuApi({
  required DanmakuSettings settings,
  String? configDanmaku,
  String? bundleDanmaku,
}) {
  final resolved = resolveDanmakuSources(
    settings: settings,
    configDanmaku: configDanmaku,
    bundleDanmaku: bundleDanmaku,
  );
  if (!resolved.isConfigured) {
    return const ResolvedDanmakuApi(url: '', source: DanmakuApiSource.none);
  }
  return ResolvedDanmakuApi(
    url: resolved.sources.first.url,
    source: resolved.origin,
  );
}

/// 过滤出地址合法的源，并按 url 去重保序（先到者保留）。
List<DanmakuSourceConfig> _uniqueValidSources(
  Iterable<DanmakuSourceConfig> sources,
) {
  final seen = <String>{};
  final unique = <DanmakuSourceConfig>[];
  for (final source in sources) {
    final url = source.url.trim();
    if (!isValidDanmakuApiUrl(url)) continue;
    if (!seen.add(url)) continue;
    // 归一化到 trim 后的地址：后续 searchSources 直接拿它发请求。
    unique.add(source.copyWith(url: url));
  }
  return unique;
}

List<String> _uniqueValidUrls(Iterable<String> candidates) {
  final seen = <String>{};
  final unique = <String>[];
  for (final candidate in candidates) {
    final url = candidate.trim();
    if (!isValidDanmakuApiUrl(url)) continue;
    if (!seen.add(url)) continue;
    unique.add(url);
  }
  return unique;
}
