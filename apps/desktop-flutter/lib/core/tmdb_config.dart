/// TMDB 配置归一化与站点策略（`docs/phase4/design/03` §5、`01` §6）。
///
/// 这一层是**纯逻辑**：不依赖 Flutter，也不依赖 `dart:io`。
///
/// 上游对应实现：`bean/TmdbConfig`（308 行）、`setting/TmdbSitePolicy`。
///
/// 关键契约：
/// - `sanitize()` 的 13 条归一化规则顺序固定（`03` §5.2）。
/// - 站点策略判定顺序固定为 7 步（`01` §6.1），**不可调换**。
/// - 括号归一（`「」【】〔〕［］` → `[]`）必须实现，否则猫源默认规则一条也匹配不上。
/// - `[书]` 与 `[小说]`、`[漫]` 与 `[漫画]` **不可互换**（子串包含语义）。
library;

// ---------------------------------------------------------------------------
// 默认值（`03` §5.1）
// ---------------------------------------------------------------------------

const String tmdbDefaultApiBase = 'https://api.tmdb.org/3';
const String tmdbDefaultImageHost = 'https://images.tmdb.org';
const String tmdbDefaultImageBase = 'https://images.tmdb.org/t/p/w342';

/// 后景（详情页全屏背景）默认尺寸。
///
/// 用 `w1280` 而不是 `w780`：TMDB 官方后景尺寸只有 `w300/w780/w1280/original`
/// 四档，`w780` 在 1300+ 宽的窗口里被拉满会明显发虚（用户反馈 2026-10-10：
/// 「清晰度不够没有选原画吗？」）。实测同一张后景：`w780` 48KB、`w1280` 121KB、
/// `original` 983KB——`w1280` 在清晰度与流量之间最划算；用户想要更高清可在
/// 设置里自己改成 `original`。
const String tmdbDefaultBackdropSize = 'w1280';
const String tmdbDefaultBackdropBase =
    'https://images.tmdb.org/t/p/$tmdbDefaultBackdropSize';
const String tmdbDefaultLanguage = 'zh-CN';

/// 默认不富集 TMDB 的站点规则（`01` §6.2）。
///
/// 非影视内容（音频/有声/小说/漫画/短剧/画）加上配置类站点。
///
/// **注意**：`[书]` 与 `[小说]`、`[漫]` 与 `[漫画]` 不可互替——匹配是子串包含，
/// `[书]` 命中 `[书]xxx` 但不命中 `[小说]xxx`，因为 `[小说]` 里 `[书` 后面跟的是
/// `说` 而非 `]`。`配置` 不带括号，纯文本子串匹配。
const List<String> tmdbDefaultDisabledRules = [
  '[音]',
  '[听]',
  '[书]',
  '[漫]',
  '[短]',
  '[设]',
  '[画]',
  '[漫画]',
  '[小说]',
  '配置',
  '[配]',
];

final RegExp _imageSizeSuffix = RegExp(r'/(?:w\d+|h\d+|original)$');
final RegExp _ipLikeHost = RegExp(r'^\d+\.\d+\.\d+\.\d+(:\d+)?$');

// ---------------------------------------------------------------------------
// 归一化辅助（`03` §5.2）
// ---------------------------------------------------------------------------

String _trimOr(String? value, String fallback) {
  final text = (value ?? '').trim();
  return text.isEmpty ? fallback : text;
}

String _trimTrailingSlash(String value) {
  var text = value.trim();
  while (text.endsWith('/')) {
    text = text.substring(0, text.length - 1);
  }
  return text;
}

bool _isHttpUrl(String value) =>
    value.startsWith('http://') || value.startsWith('https://');

/// `looksLikeHost`：含 `.` 或 `localhost` 或 IP 形态，且不含 `://`、空格，不以 `/` 开头。
bool _looksLikeHost(String value) {
  final text = _trimTrailingSlash(value);
  if (text.isEmpty || text.contains('://') || text.contains(' ') ||
      text.startsWith('/')) {
    return false;
  }
  final slash = text.indexOf('/');
  final host = slash < 0 ? text : text.substring(0, slash);
  return host.contains('.') ||
      host.toLowerCase() == 'localhost' ||
      _ipLikeHost.hasMatch(host);
}

String _ensureHttpScheme(String value) {
  if (value.isEmpty || _isHttpUrl(value)) return value;
  if (_looksLikeHost(value)) return 'https://${value.trim()}';
  return value;
}

String _joinUrl(String base, String path) =>
    '${_trimTrailingSlash(base)}/$path';

String _stripImageSize(String value) {
  var image = _trimTrailingSlash(value);
  while (_imageSizeSuffix.hasMatch(image)) {
    image = image.substring(0, image.lastIndexOf('/'));
    image = _trimTrailingSlash(image);
  }
  return image;
}

bool _isImageHost(String value) {
  final image = _trimTrailingSlash(value);
  return image.endsWith('/t/p') ||
      image == tmdbDefaultImageHost ||
      image.endsWith('.tmdb.org') ||
      _isHttpUrl(image) ||
      _looksLikeHost(image);
}

String _imageBaseOf(String value, String size) {
  final image = _stripImageSize(value);
  if (image.endsWith('/t/p')) return _joinUrl(image, size);
  return _joinUrl(_joinUrl(image, 't/p'), size);
}

String _normalizeApiBase(String value) {
  final api = _ensureHttpScheme(_trimTrailingSlash(value));
  if (api.endsWith('/3')) return api;
  return _joinUrl(api, '3');
}

String _normalizeImageInput(String value) {
  if (value.isEmpty) return value;
  return _ensureHttpScheme(value.trim());
}

/// access token 形态判定：以 `.` 分成 ≥ 3 段（JWT）。
bool _isAccessToken(String value) =>
    value.trim().split('.').length >= 3;

List<String> _cleanList(List<String>? values) {
  final result = <String>[];
  if (values == null) return result;
  for (final value in values) {
    final item = value.trim();
    if (item.isNotEmpty && !result.contains(item)) result.add(item);
  }
  return result;
}

List<String> _mergeList(List<String> first, List<String> second) {
  final result = <String>[];
  for (final value in [...first, ...second]) {
    if (value.isNotEmpty && !result.contains(value)) result.add(value);
  }
  return result;
}

/// 括号写法归一（`01` §6.2）。
///
/// 同一分类标记在不同源里写作 `[音]`、`「音」`、`【音】`——猫源全用全角角括号，
/// TVBox 配置多用半角。一条规则该把这些写法都覆盖住，否则默认规则一条也匹配不上。
String normalizeBrackets(String value) => value
    .replaceAll('「', '[')
    .replaceAll('」', ']')
    .replaceAll('【', '[')
    .replaceAll('】', ']')
    .replaceAll('〔', '[')
    .replaceAll('〕', ']')
    .replaceAll('［', '[')
    .replaceAll('］', ']');

/// 子串包含匹配（归一后小写）。
bool _matches(List<String> rules, String value) {
  if (rules.isEmpty || value.isEmpty) return false;
  final target = normalizeBrackets(value).toLowerCase();
  for (final rule in rules) {
    final normalized = normalizeBrackets(rule.trim()).toLowerCase();
    if (normalized.isEmpty) continue;
    if (target.contains(normalized)) return true;
  }
  return false;
}

/// 精确匹配（归一后忽略大小写）。
bool _matchesExact(List<String> rules, String value) {
  if (rules.isEmpty || value.isEmpty) return false;
  final target = normalizeBrackets(value).trim();
  for (final rule in rules) {
    final normalized = normalizeBrackets(rule.trim());
    if (normalized.isEmpty) continue;
    if (target.toLowerCase() == normalized.toLowerCase()) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// TmdbConfig
// ---------------------------------------------------------------------------

/// TMDB 配置（`03` §5.1）。字段与上游 `TmdbConfig` 逐字段对齐。
class TmdbConfig {
  const TmdbConfig({
    this.enabled = true,
    this.apiBase = tmdbDefaultApiBase,
    this.apiKey = '',
    this.accessToken = '',
    this.omdbApiKey = '',
    this.language = tmdbDefaultLanguage,
    this.imageBase = tmdbDefaultImageBase,
    this.backdropBase = tmdbDefaultBackdropBase,
    this.enabledSites = const [],
    this.disabledSites = tmdbDefaultDisabledRules,
    this.allowedSites = const [],
    this.excludeKeywordsConfigured = true,
    this.smartMatch = true,
    this.heuristicSeasonGuessing = true,
    this._compatExcludeKeywords = const [],
  });

  final bool enabled;
  final String apiBase;
  final String apiKey;
  final String accessToken;

  /// 保留字段；PC 端**不发起** OMDB 请求（`00` §4.3）。
  final String omdbApiKey;
  final String language;
  final String imageBase;
  final String backdropBase;
  final List<String> enabledSites;
  final List<String> disabledSites;
  final List<String> allowedSites;
  final bool excludeKeywordsConfigured;
  final bool smartMatch;
  final bool heuristicSeasonGuessing;

  /// 兼容旧版字段 `excludeKeywords` / `exclude` / `blockedKeywords` /
  /// `skipKeywords`，在 [sanitize] 第 10 步合并进 `disabledSites`。
  final List<String> _compatExcludeKeywords;

  /// 是否已配置凭据且总开关开启（`03` §5.2）。
  bool get isReady =>
      enabled && (accessToken.trim().isNotEmpty || apiKey.trim().isNotEmpty);

  /// 是否存在任何站点规则（`01` §6）。
  bool get hasSiteRules =>
      enabledSites.isNotEmpty ||
      allowedSites.isNotEmpty ||
      disabledSites.isNotEmpty;

  /// API 主机（去掉末尾 `/3` 与斜杠），供设置页展示。
  String get apiHost {
    var api = _trimTrailingSlash(
      apiBase.isEmpty ? tmdbDefaultApiBase : apiBase,
    );
    if (api.endsWith('/3')) api = api.substring(0, api.length - 2);
    return _trimTrailingSlash(api);
  }

  /// 图片主机（去掉尺寸段与 `/t/p`）。
  String get imageHost {
    var base = _stripImageSize(
      imageBase.isEmpty ? tmdbDefaultImageBase : imageBase,
    );
    if (base.endsWith('/t/p')) base = base.substring(0, base.length - 4);
    base = _trimTrailingSlash(base);
    if (_isHttpUrl(base)) return base;
    final withScheme = _ensureHttpScheme(base);
    return _isHttpUrl(withScheme) ? withScheme : tmdbDefaultImageHost;
  }

  /// 站点是否允许被 TMDB 富集（`01` §6.1 的 7 步判定）。
  bool isSiteEnabled(String key, String name) {
    // 1. 黑名单精确命中 → 禁用（优先级最高）
    if (_matchesExact(disabledSites, key) ||
        _matchesExact(disabledSites, name)) {
      return false;
    }
    // 2. 白名单精确命中 → 启用
    if (_matchesExact(allowedSites, key) ||
        _matchesExact(allowedSites, name)) {
      return true;
    }
    // 3. 启用规则精确命中 → 启用
    if (_matchesExact(enabledSites, key) ||
        _matchesExact(enabledSites, name)) {
      return true;
    }
    // 4. 黑名单子串命中 → 禁用
    if (_matches(disabledSites, key) || _matches(disabledSites, name)) {
      return false;
    }
    // 5. 启用规则为空 → 允许
    if (enabledSites.isEmpty) return true;
    // 6. 启用规则子串命中 → 允许
    if (_matches(enabledSites, key) || _matches(enabledSites, name)) {
      return true;
    }
    // 7. 否则拒绝
    return false;
  }

  /// 从 JSON 构造并归一化（`03` §5.2）。无法解析时返回默认配置。
  static TmdbConfig fromJson(Object? value) {
    if (value is! Map) return const TmdbConfig();
    return TmdbConfig.fromMap(value.cast<Object?, Object?>());
  }

  /// 从 Map 构造并归一化。兼容上游全部别名键。
  static TmdbConfig fromMap(Map<Object?, Object?> map) {
    String pick(List<String> keys) {
      for (final key in keys) {
        final raw = map[key];
        if (raw is String && raw.trim().isNotEmpty) return raw.trim();
        if (raw is num || raw is bool) return raw.toString();
      }
      return '';
    }

    List<String>? pickList(List<String> keys) {
      for (final key in keys) {
        final raw = map[key];
        if (raw is List) {
          return raw
              .map((item) => item is String ? item.trim() : '$item'.trim())
              .where((item) => item.isNotEmpty)
              .toList();
        }
      }
      return null;
    }

    bool pickBool(String key, bool fallback) {
      final raw = map[key];
      if (raw is bool) return raw;
      if (raw is num) return raw != 0;
      if (raw is String) {
        final text = raw.trim().toLowerCase();
        if (text == 'true' || text == '1') return true;
        if (text == 'false' || text == '0') return false;
      }
      return fallback;
    }

    return TmdbConfig(
      enabled: pickBool('enabled', true),
      apiBase: pick(['apiBase', 'api_base']),
      apiKey: pick(['apiKey', 'apikey', 'api_key', 'tmdbApiKey', 'key']),
      accessToken: pick([
        'accessToken',
        'token',
        'readAccessToken',
        'bearerToken',
      ]),
      omdbApiKey: pick(['omdbApiKey', 'omdbKey', 'imdbApiKey']),
      language: pick(['language']),
      imageBase: pick(['imageBase', 'image_base']),
      backdropBase: pick(['backdropBase', 'backdrop_base']),
      enabledSites:
          pickList(['enabledSites', 'siteKeys', 'sites', 'matchSites']) ??
          const [],
      disabledSites: pickList(['disabledSites']) ?? const [],
      allowedSites:
          pickList(['allowedSites', 'includeSites', 'whitelistSites']) ??
          const [],
      excludeKeywordsConfigured: map.containsKey('excludeKeywordsConfigured') &&
          pickBool('excludeKeywordsConfigured', false),
      smartMatch: pickBool('smartMatch', true),
      heuristicSeasonGuessing: pickBool('heuristicSeasonGuessing', true),
      compatExcludeKeywords:
          pickList([
            'excludeKeywords',
            'exclude',
            'blockedKeywords',
            'skipKeywords',
          ]) ??
          const [],
    ).sanitize();
  }

  /// 13 条归一化规则（`03` §5.2）。顺序固定，不可调换。
  TmdbConfig sanitize() {
    // 1. apiBase
    final api = _normalizeApiBase(_trimOr(apiBase, tmdbDefaultApiBase));

    // 2/3. apiKey 与 accessToken
    final key = _trimOr(apiKey, '');
    var token = _trimOr(accessToken, '');
    if (token.isNotEmpty && token == key && !_isAccessToken(token)) {
      token = '';
    }

    // 4. language
    final lang = _trimOr(language, tmdbDefaultLanguage);

    // 5/6/7/8. 图片基址
    var image = _normalizeImageInput(_trimOr(imageBase, tmdbDefaultImageBase));
    var backdrop = _normalizeImageInput(_trimOr(backdropBase, ''));
    if (backdrop.isEmpty && _isImageHost(image)) {
      backdrop = _imageBaseOf(image, tmdbDefaultBackdropSize);
    }
    if (_isImageHost(image)) image = _imageBaseOf(image, 'w342');
    backdrop = _trimOr(backdrop, tmdbDefaultBackdropBase);
    if (_isImageHost(backdrop) && !backdrop.contains('/t/p/')) {
      backdrop = _imageBaseOf(backdrop, tmdbDefaultBackdropSize);
    }
    // 存量配置升级：早期默认是 `w780`（仅 780px 宽），全屏铺开必然发虚
    // （用户反馈 2026-10-10：「清晰度不够没有选原画吗？」）。TMDB 官方后景尺寸
    // 只有 w300/w780/w1280/original 四档，`w780` 是最容易让人误以为“没选原画”的
    // 那一档，因此把**官方图床上的 w780 后景**自动升到 w1280；用户显式指定的
    // 其它尺寸（含 original、w300）与自建图床一律不动。
    if (backdrop.contains('images.tmdb.org/t/p/w780')) {
      backdrop = backdrop.replaceFirst('/w780', '/$tmdbDefaultBackdropSize');
    }

    // 9/10/11/12/13. 站点规则
    final cleanEnabled = _cleanList(enabledSites);
    final cleanDisabled = _mergeList(
      _cleanList(_compatExcludeKeywords),
      _cleanList(disabledSites),
    );
    final cleanAllowed = _cleanList(allowedSites);
    final excludeConfigured =
        excludeKeywordsConfigured || cleanDisabled.isNotEmpty;
    final finalDisabled = (!excludeConfigured && cleanDisabled.isEmpty)
        ? List<String>.from(tmdbDefaultDisabledRules)
        : cleanDisabled;

    return TmdbConfig(
      enabled: enabled,
      apiBase: api,
      apiKey: key,
      accessToken: token,
      omdbApiKey: _trimOr(omdbApiKey, ''),
      language: lang,
      imageBase: image,
      backdropBase: backdrop,
      enabledSites: List.unmodifiable(cleanEnabled),
      disabledSites: List.unmodifiable(finalDisabled),
      allowedSites: List.unmodifiable(cleanAllowed),
      excludeKeywordsConfigured: excludeConfigured,
      smartMatch: smartMatch,
      heuristicSeasonGuessing: heuristicSeasonGuessing,
    );
  }

  /// 序列化。`includeCredentials = false` 时**不写出**任何凭据（`03` §5.5）。
  Map<String, Object?> toJson({bool includeCredentials = true}) => {
    'enabled': enabled,
    'apiBase': apiBase,
    if (includeCredentials) 'apiKey': apiKey,
    if (includeCredentials) 'accessToken': accessToken,
    if (includeCredentials && omdbApiKey.isNotEmpty) 'omdbApiKey': omdbApiKey,
    'language': language,
    'imageBase': imageBase,
    'backdropBase': backdropBase,
    'enabledSites': enabledSites,
    'disabledSites': disabledSites,
    'allowedSites': allowedSites,
    'excludeKeywordsConfigured': excludeKeywordsConfigured,
    'smartMatch': smartMatch,
    'heuristicSeasonGuessing': heuristicSeasonGuessing,
  };

  TmdbConfig copyWith({
    bool? enabled,
    String? apiBase,
    String? apiKey,
    String? accessToken,
    String? omdbApiKey,
    String? language,
    String? imageBase,
    String? backdropBase,
    List<String>? enabledSites,
    List<String>? disabledSites,
    List<String>? allowedSites,
    bool? excludeKeywordsConfigured,
    bool? smartMatch,
    bool? heuristicSeasonGuessing,
  }) {
    return TmdbConfig(
      enabled: enabled ?? this.enabled,
      apiBase: apiBase ?? this.apiBase,
      apiKey: apiKey ?? this.apiKey,
      accessToken: accessToken ?? this.accessToken,
      omdbApiKey: omdbApiKey ?? this.omdbApiKey,
      language: language ?? this.language,
      imageBase: imageBase ?? this.imageBase,
      backdropBase: backdropBase ?? this.backdropBase,
      enabledSites: enabledSites ?? this.enabledSites,
      disabledSites: disabledSites ?? this.disabledSites,
      allowedSites: allowedSites ?? this.allowedSites,
      excludeKeywordsConfigured:
          excludeKeywordsConfigured ?? this.excludeKeywordsConfigured,
      smartMatch: smartMatch ?? this.smartMatch,
      heuristicSeasonGuessing:
          heuristicSeasonGuessing ?? this.heuristicSeasonGuessing,
    );
  }

  /// 重置为默认禁用规则（`04` §10.2「重置默认规则」）。
  TmdbConfig withDefaultDisabledRules() => copyWith(
    disabledSites: List<String>.from(tmdbDefaultDisabledRules),
    excludeKeywordsConfigured: true,
  );

  /// 凭据脱敏后的展示串（`03` §5.4）。
  ///
  /// 只保留末 4 位，其余替换为 `*`；长度 ≤ 4 时全部替换。
  String get redactedApiKey => redactCredential(apiKey);
  String get redactedAccessToken => redactCredential(accessToken);

  @override
  String toString() =>
      'TmdbConfig(ready=$isReady enabled=$enabled lang=$language '
      'enabledSites=${enabledSites.length} '
      'disabledSites=${disabledSites.length} '
      'allowedSites=${allowedSites.length})';
}

/// 凭据脱敏（`03` §5.4）：只保留末 4 位。
String redactCredential(String? value) {
  final text = (value ?? '').trim();
  if (text.isEmpty) return '';
  if (text.length <= 4) return '****';
  return '****${text.substring(text.length - 4)}';
}
