/// 更新链路的公开 GitHub 下载代理配置；与系统出站代理独立。
const String defaultAppUpdateProxyUrl = 'https://gh-proxy.com/';
const List<String> appUpdateProxyPresets = [
  defaultAppUpdateProxyUrl,
  'https://ghfast.top/',
];

class AppUpdateProxySettings {
  const AppUpdateProxySettings({
    this.enabled = true,
    this.baseUrl = defaultAppUpdateProxyUrl,
  });

  static const defaults = AppUpdateProxySettings();
  final bool enabled;
  final String baseUrl;

  static String? normalizeBaseUrl(String input) {
    final text = input.trim();
    if (text.isEmpty ||
        RegExp(r'[\s\\\x00-\x1f\x7f]|%(?![0-9a-fA-F]{2})').hasMatch(text) ||
        RegExp(r'(^|/)\.{1,2}(/|$)').hasMatch(text)) {
      return null;
    }
    try {
      final uri = Uri.parse(text);
      if (uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.port <= 0 ||
          uri.port > 65535) {
        return null;
      }
      if (uri.pathSegments.any((part) => part == '..' || part == '.')) {
        return null;
      }
      return text.endsWith('/') ? text : '$text/';
    } on FormatException {
      return null;
    }
  }

  /// 仅本项目的公开 Release 资产可重写；API、凭据地址和其它来源直接通过。
  List<Uri> routesFor(Uri original, {bool proxyFirst = true}) {
    final normalized = normalizeBaseUrl(baseUrl);
    if (!enabled || normalized == null || !_eligible(original)) {
      return [original];
    }
    final proxy = Uri.parse('$normalized$original');
    if (proxy == original) return [original];
    return proxyFirst ? [proxy, original] : [original, proxy];
  }

  static bool _eligible(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host.toLowerCase() == 'github.com' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment &&
      (uri.path.startsWith('/Silent1566/webhtv-pc/releases/download/') ||
          uri.path.startsWith(
            '/Silent1566/webhtv-pc/releases/latest/download/',
          ));

  static AppUpdateProxySettings fromJson(Object? raw) {
    if (raw is! Map) return defaults;
    final value = raw['baseUrl'];
    final normalized = value == null
        ? defaultAppUpdateProxyUrl
        : value is String
        ? normalizeBaseUrl(value)
        : null;
    return AppUpdateProxySettings(
      enabled: raw['enabled'] != false && normalized != null,
      baseUrl: normalized ?? defaultAppUpdateProxyUrl,
    );
  }

  AppUpdateProxySettings copyWith({bool? enabled, String? baseUrl}) =>
      AppUpdateProxySettings.fromJson({
        'enabled': enabled ?? this.enabled,
        'baseUrl': baseUrl ?? this.baseUrl,
      });

  Map<String, Object?> toJson() => {
    'enabled': enabled && normalizeBaseUrl(baseUrl) != null,
    'baseUrl': normalizeBaseUrl(baseUrl) ?? defaultAppUpdateProxyUrl,
  };

  @override
  bool operator ==(Object other) =>
      other is AppUpdateProxySettings &&
      other.enabled == enabled &&
      other.baseUrl == baseUrl;

  @override
  int get hashCode => Object.hash(enabled, baseUrl);
}
