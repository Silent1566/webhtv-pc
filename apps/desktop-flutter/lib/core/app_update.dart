/// 应用更新的事实层（ADR-0015）。
///
/// 这里只放**纯函数与数据**：版本身份、发布记录、资产选择、检查结论、偏好。
/// 为什么单独一层：
/// - 「有没有新版本」「该装哪个文件」是可以穷举的判据，混进 HTTP 客户端或页面
///   就只能靠人眼验收；
/// - 不 import Flutter / dart:io，单测不需要真实窗口、网络或平台。
///
/// 发布事实（2026-11 现状，来自 docs/release/windows.md 与
/// .github/workflows/desktop-release.yml）：
/// - 版本名唯一来源是 pubspec.yaml 的 version:，发布 tag 形如
///   「v0.1.0-202611231630」（stable）或「v0.1.0-beta-202611231630」（beta）；
/// - **同一个版本名会被反复发版**（tag 只有时间戳区分），所以「版本名更大」不是
///   唯一的「更新」判据，同名时还要比构建时间戳（见 [AppRelease.isNewerThan]）；
/// - 每个 Release 都带 SHA256SUMS.txt 与 release-info.json，安装包按
///   -windows-x64.zip / -linux-x64.AppImage / -linux-x64.deb 命名。
library;

import 'app_update_network.dart';
export 'app_update_network.dart';

/// 唯一的发布仓库（与 README 的下载入口一致）。
const String appUpdateRepository = 'Silent1566/webhtv-pc';
const String appUpdateIndexAssetName = 'releases.json';
const String appUpdateIndexTag = 'update-channel';
final Uri appUpdateIndexUri = Uri.parse(
  'https://github.com/$appUpdateRepository/releases/download/'
  '$appUpdateIndexTag/$appUpdateIndexAssetName',
);

/// GitHub REST API 根地址（单测用它换成假服务器）。
const String appUpdateApiBaseUrl = 'https://api.github.com';

/// 仓库 Releases 页面：手动下载与「打开发布页」的兜底入口。
final Uri appUpdateReleasePageUri = Uri.parse(
  'https://github.com/$appUpdateRepository/releases',
);

/// 检查更新请求的 User-Agent。GitHub API 要求非空 UA。
const String appUpdateUserAgent = 'webhtv-pc-update-check';

/// 发布产物里的校验文件：安装包 SHA-256 的唯一来源。
const String appUpdateChecksumAssetName = 'SHA256SUMS.txt';

/// 自动检查的最短间隔。
///
/// 启动时自动检查只在这条间隔之外才真的打网络：GitHub 未认证请求按 IP
/// 限流（60 次/小时），而「每次启动都查」对「有没有新版本」几乎没有增益。
const Duration appUpdateCheckInterval = Duration(hours: 24);

/// 更新通道。
///
/// 值（stable / beta）直接落 settings.json，不要用 name 之外的拼法。
enum AppUpdateChannel {
  stable('稳定版'),
  beta('测试版');

  const AppUpdateChannel(this.label);

  /// 界面文案。
  final String label;

  /// 落盘值：非法/缺失一律回落到 [stable]。
  static AppUpdateChannel fromValue(Object? raw) {
    final value = raw is String ? raw.trim().toLowerCase() : '';
    return value == beta.name ? beta : stable;
  }

  /// 从发布 tag 推断通道：v0.1.0-beta-202611231630 是测试版。
  static AppUpdateChannel fromTag(String tag) =>
      tag.toLowerCase().contains('-beta-') ? beta : stable;

  /// 当前值是哪个枚举（供序列化使用）。
  String get value => name;
}

/// 解析后的发布 tag。
///
/// 只接受发布流水线实际生成的两种形态；解析失败返回 null，由调用方把这条
/// 发布当作「不可比较」（仍然能在页面上打开，但不会被判成更新）。
class AppReleaseTag {
  const AppReleaseTag({
    required this.raw,
    required this.versionName,
    required this.channel,
    required this.builtAt,
  });

  /// 「v0.1.0-202611231630」/「v0.1.0-beta-202611231630」。
  static final RegExp _pattern = RegExp(
    r'^v?(\d+\.\d+\.\d+)(?:-([A-Za-z][A-Za-z0-9]*))?-(\d{12})$',
  );

  static AppReleaseTag? tryParse(String raw) {
    final text = raw.trim();
    final match = _pattern.firstMatch(text);
    if (match == null) return null;
    final stamp = match.group(3)!;
    final year = int.parse(stamp.substring(0, 4));
    final month = int.parse(stamp.substring(4, 6));
    final day = int.parse(stamp.substring(6, 8));
    final hour = int.parse(stamp.substring(8, 10));
    final minute = int.parse(stamp.substring(10, 12));
    if (month < 1 ||
        month > 12 ||
        day < 1 ||
        day > 31 ||
        hour > 23 ||
        minute > 59) {
      return null;
    }
    final channelToken = match.group(2)?.toLowerCase();
    return AppReleaseTag(
      raw: text,
      versionName: match.group(1)!,
      channel: channelToken == AppUpdateChannel.beta.name
          ? AppUpdateChannel.beta
          : AppUpdateChannel.stable,
      // 只用于排序/比较，不做绝对时间展示：tag 是 Asia/Shanghai 的
      // yyyyMMddHHmm，两个 tag 之间比大小与真实时区无关。展示一律用
      // Release 的 publishedAt。
      builtAt: DateTime.utc(year, month, day, hour, minute),
    );
  }

  final String raw;
  final String versionName;
  final AppUpdateChannel channel;

  /// 构建时间戳（见 [_pattern] 的注释：只用于比较）。
  final DateTime builtAt;

  @override
  String toString() => raw;
}

/// 本机这份构建的身份。
///
/// tag 由 CI 用 --dart-define=APP_TAG=「v0.1.0-202611231630」注入；本地/开发构建
/// 是空串——**开发构建不参与通道比较**，否则「开发版比发布版新」这类判断
/// 会把用户引到错误的方向。
class AppUpdateIdentity {
  const AppUpdateIdentity({required this.version, this.tag = ''});

  /// pubspec.yaml 的版本名（appVersion）。
  final String version;

  /// 发布 tag；空串 = 开发构建。
  final String tag;

  AppReleaseTag? get parsedTag => AppReleaseTag.tryParse(tag);

  /// 是否是一次发布构建（有可解析的 tag）。
  bool get isReleaseBuild => parsedTag != null;

  /// 构建所属通道；开发构建按稳定版展示（它不参与筛选）。
  AppUpdateChannel get channel => parsedTag?.channel ?? AppUpdateChannel.stable;

  @override
  String toString() => tag.isEmpty ? '$version (dev)' : '$version ($tag)';
}

/// 版本名比较：语义化三段数字，缺失/非法一律当 0。
///
/// 返回负数表示 [a] 更旧、0 相同、正数表示 [a] 更新。
int compareAppVersionNames(String a, String b) {
  final left = _versionParts(a);
  final right = _versionParts(b);
  for (var index = 0; index < 3; index++) {
    if (left[index] != right[index]) {
      return left[index] < right[index] ? -1 : 1;
    }
  }
  return 0;
}

List<int> _versionParts(String raw) {
  final parts = <int>[];
  for (final token in raw.trim().split('.')) {
    parts.add(int.tryParse(token) ?? 0);
    if (parts.length == 3) break;
  }
  while (parts.length < 3) {
    parts.add(0);
  }
  return parts;
}

/// 一个可下载的发布资产。
class AppReleaseAsset {
  const AppReleaseAsset({
    required this.name,
    required this.size,
    required this.downloadUri,
    this.sha256,
  });

  final String name;

  /// 字节数；未知为 0（GitHub API 总是给，测试/降级路径可能没有）。
  final int size;

  final Uri downloadUri;

  /// 摘要（十六进制小写）。API 直接给出的 sha256 优先；没有就要读
  /// SHA256SUMS.txt，两者都没有时**拒绝安装**（见 ADR-0015）。
  final String? sha256;

  @override
  String toString() => '$name ($size B)';
}

/// 一条 GitHub Release。
class AppRelease {
  const AppRelease({
    required this.tag,
    required this.title,
    required this.body,
    required this.pageUri,
    required this.prerelease,
    required this.draft,
    required this.assets,
    this.tagInfo,
    this.publishedAt,
  });

  /// tag 字符串；可能是流水线之外的形态（解析失败时 [tagInfo] 为 null）。
  final String tag;
  final String title;
  final String body;
  final Uri pageUri;
  final DateTime? publishedAt;
  final bool prerelease;
  final bool draft;
  final List<AppReleaseAsset> assets;

  /// 解析成功的 tag；null = 这条发布没有可比较的版本身份。
  final AppReleaseTag? tagInfo;

  String get versionName => tagInfo?.versionName ?? '';

  /// 通道：tag 解析失败时用预发布标记兜底。
  AppUpdateChannel get channel =>
      tagInfo?.channel ??
      (prerelease ? AppUpdateChannel.beta : AppUpdateChannel.stable);

  /// 可比较的构建时间：先用 tag 时间戳（与本地同一口径），没有就用发布时间。
  DateTime? get buildTime => tagInfo?.builtAt ?? publishedAt;

  AppReleaseAsset? get checksumAsset => _assetNamed(appUpdateChecksumAssetName);

  AppReleaseAsset? _assetNamed(String name) {
    for (final asset in assets) {
      if (asset.name == name) return asset;
    }
    return null;
  }

  /// 该装哪个文件。
  ///
  /// Linux 两种发行形态的判据是环境而不是喜好：AppImage 运行时有 APPIMAGE
  /// 环境变量，此时自替换是安全的；否则只能给 .deb 让用户用系统安装器
  /// （deb 自更新需要包管理器权限，本应用不做提权）。
  AppReleaseAsset? preferredAsset({
    required String operatingSystem,
    bool runningAsAppImage = false,
  }) {
    AppReleaseAsset? pick(String suffix) {
      for (final asset in assets) {
        if (asset.name.endsWith(suffix)) return asset;
      }
      return null;
    }

    switch (operatingSystem) {
      case 'windows':
        return pick('-windows-x64.zip');
      case 'linux':
        if (runningAsAppImage) {
          final appImage = pick('-linux-x64.AppImage');
          if (appImage != null) return appImage;
        }
        // 不是 AppImage 运行形态（deb 或解包运行）：优先给 deb，交给系统安装器；
        // 只有发布里没有 deb 时才退回 AppImage 让用户手动替换。
        return pick('-linux-x64.deb') ?? pick('-linux-x64.AppImage');
      case 'macos':
        return pick('-macos-arm64.zip') ?? pick('-macos-x64.zip');
      default:
        return null;
    }
  }

  /// 相对本机这份构建是否更新。
  ///
  /// 判据顺序（两条都必须成立才算更新）：
  /// 1. 版本名不更旧；
  /// 2. 版本名相同则构建时间更晚（同名版本会按 commit 时间反复发版）。
  ///
  /// 开发构建（没有 tag）永远不算「可自动更新」，由
  /// [AppUpdateCheck] 单独给出 [AppUpdateVerdict.developmentBuild]。
  bool isNewerThan(AppUpdateIdentity current) {
    if (draft) return false;
    final currentTag = current.parsedTag;
    if (currentTag == null) return false;
    final byVersion = compareAppVersionNames(
      versionName,
      currentTag.versionName,
    );
    if (byVersion != 0) return byVersion > 0;
    final remoteBuiltAt = buildTime;
    if (remoteBuiltAt == null) return false;
    return remoteBuiltAt.isAfter(currentTag.builtAt);
  }

  @override
  String toString() => 'AppRelease($tag)';
}

/// 一次检查的结论。
enum AppUpdateVerdict {
  /// 发现有更新的发布。
  updateAvailable,

  /// 已是最新。
  upToDate,

  /// 本机是开发构建：不参与通道比较，但仍展示最新发布（供手动下载）。
  developmentBuild,

  /// 检查失败（网络/限流/响应不可解析）。
  failed,
}

/// 一次检查的完整结果。
class AppUpdateCheck {
  const AppUpdateCheck({
    required this.verdict,
    required this.identity,
    required this.checkedAt,
    this.release,
    this.message,
    this.fromCache = false,
    this.cachedAt,
    this.retryAt,
    this.source,
  });

  final AppUpdateVerdict verdict;
  final AppUpdateIdentity identity;
  final DateTime checkedAt;

  /// 通道里最新的一条发布；失败时为 null。
  final AppRelease? release;

  /// 失败原因（[AppUpdateVerdict.failed] 才有值）。
  final String? message;

  /// 304 复用或离线回退；失败回退仍为 failed，不允许按旧缓存安装。
  final bool fromCache;
  final DateTime? cachedAt;
  final DateTime? retryAt;
  final String? source;

  bool get hasUpdate => verdict == AppUpdateVerdict.updateAvailable;

  bool get failed => verdict == AppUpdateVerdict.failed;

  @override
  String toString() {
    final verdictName = verdict.name;
    return 'AppUpdateCheck($verdictName, release=$release)';
  }
}

/// 更新偏好：settings.json 的 update 段。
class AppUpdatePreferences {
  const AppUpdatePreferences({
    this.autoCheck = false,
    this.channel = AppUpdateChannel.stable,
    this.githubProxy = AppUpdateProxySettings.defaults,
    this.lastCheckedAt,
    this.lastCheckError,
  });

  /// 默认：不自动检查、稳定版通道。
  ///
  /// 自动检查默认关闭是隐私与测试两方面的同一决定：应用在用户没点头之前
  /// 不该为了自己的版本去访问第三方服务；单测里的 AppState 因此也不会
  /// 意外打网络。
  static const AppUpdatePreferences defaults = AppUpdatePreferences();

  final bool autoCheck;
  final AppUpdateChannel channel;
  final AppUpdateProxySettings githubProxy;
  final DateTime? lastCheckedAt;
  final String? lastCheckError;

  static const Object _unset = Object();

  AppUpdatePreferences copyWith({
    bool? autoCheck,
    AppUpdateChannel? channel,
    AppUpdateProxySettings? githubProxy,
    Object? lastCheckedAt = _unset,
    Object? lastCheckError = _unset,
  }) => AppUpdatePreferences(
    autoCheck: autoCheck ?? this.autoCheck,
    channel: channel ?? this.channel,
    githubProxy: githubProxy ?? this.githubProxy,
    lastCheckedAt: identical(lastCheckedAt, _unset)
        ? this.lastCheckedAt
        : lastCheckedAt as DateTime?,
    lastCheckError: identical(lastCheckError, _unset)
        ? this.lastCheckError
        : lastCheckError as String?,
  );

  /// 启动时该不该真的查一次。
  bool shouldAutoCheck(DateTime now) {
    if (!autoCheck) return false;
    final last = lastCheckedAt;
    if (last == null) return true;
    return now.difference(last) >= appUpdateCheckInterval;
  }

  Map<String, Object?> toJson() => {
    'autoCheck': autoCheck,
    'channel': channel.value,
    'githubProxy': githubProxy.toJson(),
    if (lastCheckedAt != null)
      'lastCheckedAt': lastCheckedAt!.toIso8601String(),
    if (lastCheckError != null && lastCheckError!.isNotEmpty)
      'lastCheckError': lastCheckError,
  };

  static AppUpdatePreferences fromJson(Object? raw) {
    if (raw is! Map) return defaults;
    final autoCheck = raw['autoCheck'];
    final lastCheckedAt = raw['lastCheckedAt'];
    final lastCheckError = raw['lastCheckError'];
    return AppUpdatePreferences(
      autoCheck: autoCheck == true,
      channel: AppUpdateChannel.fromValue(raw['channel']),
      githubProxy: AppUpdateProxySettings.fromJson(raw['githubProxy']),
      lastCheckedAt: lastCheckedAt is String
          ? DateTime.tryParse(lastCheckedAt)
          : null,
      lastCheckError: lastCheckError is String && lastCheckError.isNotEmpty
          ? lastCheckError
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppUpdatePreferences &&
      other.autoCheck == autoCheck &&
      other.channel == channel &&
      other.githubProxy == githubProxy &&
      other.lastCheckedAt == lastCheckedAt &&
      other.lastCheckError == lastCheckError;

  @override
  int get hashCode => Object.hash(
    autoCheck,
    channel,
    githubProxy,
    lastCheckedAt,
    lastCheckError,
  );

  @override
  String toString() {
    final channelName = channel.name;
    return 'AppUpdatePreferences(auto=$autoCheck, channel=$channelName, '
        'last=$lastCheckedAt, error=$lastCheckError)';
  }
}

/// 安装方式：决定「点下下载并安装之后到底发生什么」。
enum AppUpdateInstallKind {
  /// Linux AppImage 自替换（新文件校验通过后原子换掉当前 AppImage）。
  replaceAppImage,

  /// Windows 便携包：解到更新目录，由退出后运行的脚本整目录换装。
  replacePortableWindows,

  /// 只能下载：交给系统安装器（deb）或用户手动解压。
  manual,
}

/// 从 SHA256SUMS.txt 文本里读出「文件名 → 小写十六进制摘要」。
///
/// 格式与 package_*.py / .ps1 生成的一致：一行「摘要 + 两个空格 + 文件名」，
/// 允许 * 前缀与 CRLF。
/// 无法解析的行直接跳过——校验文件是外部输入，坏一行不该让整次检查失败，
/// 但也不会给坏行编一个值。
Map<String, String> parseSha256Sums(String text) {
  final result = <String, String>{};
  for (final rawLine in text.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final match = RegExp(r'^([0-9a-fA-F]{64})\s+[*]?(.+)$').firstMatch(line);
    if (match == null) continue;
    result[match.group(2)!.trim()] = match.group(1)!.toLowerCase();
  }
  return result;
}

/// 人类可读的字节数（更新页与日志共用）。
String formatAppUpdateBytes(int bytes) {
  if (bytes <= 0) return '未知大小';
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) {
    final text = kb.toStringAsFixed(kb < 10 ? 1 : 0);
    return '$text KB';
  }
  final mb = kb / 1024;
  if (mb < 1024) {
    final text = mb.toStringAsFixed(mb < 10 ? 1 : 0);
    return '$text MB';
  }
  final gb = (mb / 1024).toStringAsFixed(2);
  return '$gb GB';
}
