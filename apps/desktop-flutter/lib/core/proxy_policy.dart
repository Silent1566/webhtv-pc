/// 本地代理安全策略与 HLS 重写（设计文档 §11.1、§11.3、§11.3.1、§9.6）。
///
/// 本文件是纯逻辑层，不绑定端口、不做 IO，便于用单元测试逐条覆盖安全要求：
/// token 校验、目标 URL 白名单、内网/回环/云元数据拒绝、凭据同源传播、
/// HLS 清单重写与日志脱敏。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// 目标 URL 的判定结果。
class ProxyTargetDecision {
  const ProxyTargetDecision._(this.allowed, this.reason, this.code);

  const ProxyTargetDecision.allow() : this._(true, 'allowed', 200);

  const ProxyTargetDecision.deny(String reason, {int code = 403})
    : this._(false, reason, code);

  final bool allowed;
  final String reason;

  /// 拒绝时返回给客户端的 HTTP 状态码。
  final int code;

  @override
  String toString() => allowed ? 'allow' : 'deny($code $reason)';
}

/// 目标 URL 策略（§11.3「校验目标 URL 白名单」「不转发内网地址」）。
class ProxyTargetPolicy {
  const ProxyTargetPolicy({
    this.allowPrivate = false,
    this.allowLoopback = false,
    this.allowedHosts = const {},
    this.allowedSchemes = const ['http', 'https'],
    this.maxRedirects = 5,
  });

  /// 用户显式开启后允许私网目标（§11.3 第 4 条）。
  final bool allowPrivate;

  /// 用户显式授权的本地源（例如局域网内的自建媒体服务）。
  final bool allowLoopback;

  /// 站点授权的目标主机白名单；为空表示不做主机限制（仅做 IP 与 scheme 限制）。
  final Set<String> allowedHosts;

  final List<String> allowedSchemes;
  final int maxRedirects;

  /// 云元数据地址：即使在私网也不允许访问（§11.3.1）。
  static const Set<String> cloudMetadataHosts = {
    '169.254.169.254',
    'metadata.google.internal',
    'metadata.goog',
    '100.100.100.200',
  };

  /// 只做静态判定（scheme/host/字面 IP），不做 DNS 解析。
  ProxyTargetDecision evaluateStatic(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    if (!allowedSchemes.contains(scheme)) {
      return ProxyTargetDecision.deny('scheme 不受支持：$scheme');
    }
    final host = uri.host.toLowerCase();
    if (host.isEmpty) {
      return const ProxyTargetDecision.deny('缺少 host');
    }
    if (cloudMetadataHosts.contains(host)) {
      return const ProxyTargetDecision.deny('云元数据地址被拒绝');
    }
    if (allowedHosts.isNotEmpty && !_hostAllowed(host, uri.port)) {
      return ProxyTargetDecision.deny('主机不在授权列表：$host');
    }
    final literal = InternetAddress.tryParse(host);
    if (literal != null) return evaluateAddress(literal, host);
    if (_isLocalName(host)) {
      if (allowLoopback || allowPrivate) {
        return const ProxyTargetDecision.allow();
      }
      return ProxyTargetDecision.deny('本机主机名被拒绝：$host');
    }
    return const ProxyTargetDecision.allow();
  }

  /// DNS 解析后逐个地址复检（§11.3.1「每次 DNS 解析、连接和重定向后都重新校验」）。
  ProxyTargetDecision evaluateAddress(InternetAddress address, String host) {
    if (cloudMetadataHosts.contains(host.toLowerCase())) {
      return const ProxyTargetDecision.deny('云元数据地址被拒绝');
    }
    if (_isUnspecified(address)) {
      return ProxyTargetDecision.deny('未指定地址被拒绝：$host');
    }
    if (_isLoopback(address) && !allowLoopback) {
      return ProxyTargetDecision.deny('回环地址被拒绝：$host');
    }
    if (_isLinkLocal(address) && !allowPrivate && !allowLoopback) {
      return ProxyTargetDecision.deny('链路本地地址被拒绝：$host');
    }
    if (_isPrivate(address) && !allowPrivate && !allowLoopback) {
      return ProxyTargetDecision.deny('私网地址被拒绝：$host');
    }
    return const ProxyTargetDecision.allow();
  }

  /// 校验全部解析结果；任一地址被拒绝即整体拒绝（防 DNS 重绑定）。
  ProxyTargetDecision evaluateAll(List<InternetAddress> addresses, String host) {
    if (addresses.isEmpty) {
      return const ProxyTargetDecision.deny('DNS 未返回任何地址', code: 502);
    }
    for (final address in addresses) {
      final decision = evaluateAddress(address, host);
      if (!decision.allowed) return decision;
    }
    return const ProxyTargetDecision.allow();
  }

  bool _hostAllowed(String host, int port) {
    for (final entry in allowedHosts) {
      final normalized = entry.trim().toLowerCase();
      if (normalized.isEmpty) continue;
      final withPort = normalized.contains(':') && !normalized.startsWith('[');
      if (withPort) {
        final parts = normalized.split(':');
        final entryPort = int.tryParse(parts.last);
        final entryHost = parts.sublist(0, parts.length - 1).join(':');
        if (entryHost == host && (entryPort == null || entryPort == port)) {
          return true;
        }
        continue;
      }
      if (normalized == host || host.endsWith('.$normalized')) return true;
    }
    return false;
  }

  static bool _isLocalName(String host) =>
      host == 'localhost' ||
      host.endsWith('.localhost') ||
      host == 'localhost.localdomain';

  static bool _isUnspecified(InternetAddress address) {
    final bytes = address.rawAddress;
    if (bytes.every((byte) => byte == 0)) return true;
    // ::ffff:0.0.0.0 等价于 IPv4 any。
    if (bytes.length == 16 &&
        bytes.sublist(0, 10).every((byte) => byte == 0) &&
        bytes[10] == 0xff &&
        bytes[11] == 0xff) {
      return bytes.sublist(12).every((byte) => byte == 0);
    }
    return false;
  }

  static bool _isLoopback(InternetAddress address) {
    final bytes = address.rawAddress;
    if (bytes.length == 4) return bytes[0] == 127;
    if (bytes.length == 16) {
      if (bytes.sublist(0, 15).every((byte) => byte == 0) && bytes[15] == 1) {
        return true;
      }
      if (bytes.sublist(0, 10).every((byte) => byte == 0) &&
          bytes[10] == 0xff &&
          bytes[11] == 0xff) {
        return bytes[12] == 127;
      }
    }
    return false;
  }

  static bool _isLinkLocal(InternetAddress address) {
    final bytes = address.rawAddress;
    if (bytes.length == 4) {
      return bytes[0] == 169 && bytes[1] == 254;
    }
    // IPv6 fe80::/10
    return bytes.length == 16 &&
        bytes[0] == 0xfe &&
        (bytes[1] & 0xc0) == 0x80;
  }

  static bool _isPrivate(InternetAddress address) {
    final bytes = address.rawAddress;
    if (bytes.length == 4) {
      final a = bytes[0];
      final b = bytes[1];
      if (a == 10) return true;
      if (a == 172 && b >= 16 && b <= 31) return true;
      if (a == 192 && b == 168) return true;
      // 100.64.0.0/10 CGNAT：同样是运营商内网。
      if (a == 100 && b >= 64 && b <= 127) return true;
      return false;
    }
    if (bytes.length == 16) {
      // fc00::/7 唯一本地地址
      if ((bytes[0] & 0xfe) == 0xfc) return true;
      // IPv4-mapped ::ffff:a.b.c.d
      if (bytes.sublist(0, 10).every((byte) => byte == 0) &&
          bytes[10] == 0xff &&
          bytes[11] == 0xff) {
        return _isPrivate(
          InternetAddress.fromRawAddress(bytes.sublist(12)),
        );
      }
    }
    return false;
  }
}

/// 代理会话（§11.3.1「每次播放创建独立 sessionId 和高熵随机 token」）。
class ProxySession {
  ProxySession({
    required this.id,
    required this.token,
    required this.siteKey,
    required this.createdAt,
    required this.expiresAt,
    this.maxBytes = defaultMaxBytes,
    this.maxRequests = 4096,
    this.allowedHosts = const {},
    this.userAgent,
    this.referer,
    this.cookie,
    this.authorization,
    this.extraHeaders = const {},
  });

  /// 单会话累计字节上限默认值。
  ///
  /// 网盘点播是 GB 级**整文件**流（实测百度网盘单集 1882 MB），而非 HLS 小分片，
  /// 因此 512 MiB 这类小上限会把正常播放判成超限并返回 429。会话本身已由
  /// 高熵 token、站点绑定与短 TTL（默认 30 分钟）限定范围，64 GiB 既覆盖 4K 原盘，
  /// 又仍是有界上限（§11.3「限制单请求大小和总并发」）。
  static const int defaultMaxBytes = 64 * 1024 * 1024 * 1024;

  final String id;

  /// 高熵随机 token。只在 URL 中出现，不写入日志。
  final String token;

  final String siteKey;
  final DateTime createdAt;
  final DateTime expiresAt;

  /// 单会话累计字节上限，避免被当作无界下载器（§11.3「限制单请求大小和总并发」）。
  final int maxBytes;
  final int maxRequests;
  final Set<String> allowedHosts;

  int bytes = 0;
  int requests = 0;
  bool revoked = false;

  /// 会话内允许继承的 `User-Agent`；不得用于覆盖宿主的安全/诊断 Header（§11.3.1）。
  final String? userAgent;

  /// 站点要求注入的 `Referer`。
  final String? referer;

  /// 凭据只在同源传播（§11.3.1）。
  final String? cookie;
  final String? authorization;

  /// 站点声明的额外 Header（例如自定义签名头），同样仅同源传播。
  final Map<String, String> extraHeaders;

  /// 该会话已确立的来源（首次请求的目标 host:port），用于同源凭据传播。
  String? establishedOrigin;

  /// 重定向派生出的主机（同一播放请求的重定向目标，§11.3.1）。
  /// 302 到 CDN 是媒资分发常态（如百度 `d.pcs.baidu.com` → `appall01.baidupcs.com`），
  /// 这些主机需要被授权以继续代理 HLS 子清单/分片。
  final Set<String> derivedHosts = {};

  bool get expired => DateTime.now().isAfter(expiresAt);

  bool get usable => !revoked && !expired;

  /// 日志用指纹：只暴露 hash 前缀（§11.3.1）。
  String get fingerprint => ProxySessionManager.fingerprintOf(token);

  /// 记录一次请求；超限返回 false（调用方必须以 429 拒绝）。
  bool accountRequest(int contentLength) {
    requests += 1;
    if (requests > maxRequests) return false;
    bytes += contentLength <= 0 ? 0 : contentLength;
    return bytes <= maxBytes;
  }
}

/// 会话管理：创建、校验、撤销、过期清理。
class ProxySessionManager {
  ProxySessionManager({
    this.sessionTtl = const Duration(minutes: 30),
    Random? random,
  }) : _random = random ?? Random.secure();

  final Duration sessionTtl;
  final Random _random;
  final Map<String, ProxySession> _byToken = {};
  int _sequence = 0;

  List<ProxySession> get activeSessions =>
      _byToken.values.where((session) => session.usable).toList();

  int get sessionCount => _byToken.length;

  /// 创建会话。token 为 32 字节随机数据的高熵编码。
  ProxySession create({
    required String siteKey,
    Set<String> allowedHosts = const {},
    Duration? ttl,
    int maxBytes = ProxySession.defaultMaxBytes,
    int maxRequests = 4096,
    String? userAgent,
    String? referer,
    String? cookie,
    String? authorization,
    Map<String, String> extraHeaders = const {},
  }) {
    _sequence += 1;
    final token = _newToken();
    final now = DateTime.now();
    final session = ProxySession(
      id: 'proxy-${now.microsecondsSinceEpoch}-$_sequence',
      token: token,
      siteKey: siteKey,
      createdAt: now,
      expiresAt: now.add(ttl ?? sessionTtl),
      allowedHosts: allowedHosts,
      maxBytes: maxBytes,
      maxRequests: maxRequests,
      userAgent: userAgent,
      referer: referer,
      cookie: cookie,
      authorization: authorization,
      extraHeaders: extraHeaders,
    );
    _byToken[token] = session;
    return session;
  }

  ProxySession? byToken(String token) {
    if (token.isEmpty) return null;
    final session = _byToken[token];
    if (session == null) return null;
    if (!session.usable) {
      _byToken.remove(token);
      return null;
    }
    return session;
  }

  /// 撤销单个会话（停止播放、超时）。
  bool revoke(String token) {
    final session = _byToken.remove(token);
    if (session == null) return false;
    session.revoked = true;
    return true;
  }

  /// 撤销全部会话（应用退出）。重启后不得恢复旧 token（§11.3.1）。
  int revokeAll() {
    final count = _byToken.length;
    for (final session in _byToken.values) {
      session.revoked = true;
    }
    _byToken.clear();
    return count;
  }

  /// 清理过期会话；返回清理数量。
  int sweep() {
    final expired = _byToken.entries
        .where((entry) => !entry.value.usable)
        .map((entry) => entry.key)
        .toList();
    for (final token in expired) {
      _byToken.remove(token);
    }
    return expired.length;
  }

  String _newToken() {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// token 指纹：SHA-256 前 12 个十六进制字符。
  static String fingerprintOf(String token) {
    if (token.isEmpty) return '-';
    final digest = sha256.convert(utf8.encode(token)).toString();
    return digest.substring(0, 12);
  }
}

/// HLS 清单重写（§11.2「HLS 清单重写」「HLS 分片代理」）。
abstract final class HlsPlaylistRewriter {
  /// 需要重写的行前缀（分片、清单、加密密钥）。
  static const List<String> _tagPrefixes = [
    '#EXT-X-KEY:',
    '#EXT-X-MAP:',
    '#EXT-X-MEDIA:',
    '#EXT-X-PART:',
    '#EXT-X-PRELOAD-HINT:',
    '#EXT-X-SESSION-KEY:',
    '#EXT-X-STREAM-INF:',
    '#EXT-X-I-FRAME-STREAM-INF:',
  ];

  /// 重写清单中所有子资源 URL。
  ///
  /// [proxify] 把绝对 URL 转成代理 URL；返回 null 表示该目标不允许代理，
  /// 此时保留原 URL 而不是静默丢弃，调用方可从日志看到未重写项。
  static String rewrite(
    String body,
    Uri baseUri,
    String? Function(Uri target) proxify,
  ) {
    final buffer = StringBuffer();
    for (final rawLine in const LineSplitter().convert(body)) {
      buffer.writeln(_rewriteLine(rawLine, baseUri, proxify));
    }
    return buffer.toString();
  }

  static String _rewriteLine(
    String line,
    Uri baseUri,
    String? Function(Uri target) proxify,
  ) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return line;
    if (!trimmed.startsWith('#')) {
      // 裸 URI 行：分片或子清单。
      return _rewriteUri(trimmed, baseUri, proxify) ?? line;
    }
    final tag = _tagPrefixes.firstWhere(
      (prefix) => trimmed.toUpperCase().startsWith(prefix),
      orElse: () => '',
    );
    if (tag.isEmpty) return line;

    // 重写 URI="..." 属性。
    var rewritten = line;
    final pattern = RegExp(
      r'URI\s*=\s*"([^"]*)"',
      caseSensitive: false,
    );
    rewritten = rewritten.replaceAllMapped(pattern, (match) {
      final target = _resolve(match.group(1)!, baseUri);
      final proxied = target == null ? null : proxify(target);
      return proxied == null ? match.group(0)! : 'URI="$proxied"';
    });

    // STREAM-INF 的 URL 在下一行，无需在此处理。
    return rewritten;
  }

  static String? _rewriteUri(
    String value,
    Uri baseUri,
    String? Function(Uri target) proxify,
  ) {
    final target = _resolve(value, baseUri);
    if (target == null) return null;
    return proxify(target);
  }

  static Uri? _resolve(String value, Uri baseUri) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('data:')) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;
    if (uri.hasScheme) {
      return uri.isScheme('http') || uri.isScheme('https') ? uri : null;
    }
    return baseUri.resolveUri(uri);
  }

  /// 判断响应是否是需要重写的 HLS 清单。
  static bool looksLikePlaylist(String? contentType, String url) {
    final type = (contentType ?? '').toLowerCase();
    if (type.contains('mpegurl') || type.contains('vnd.apple')) return true;
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    return path.endsWith('.m3u8') || path.endsWith('.m3u');
  }
}

/// 需要跨 origin 移除的敏感 Header（§11.3.1）。
abstract final class SensitiveHeaders {
  static const Set<String> names = {
    'cookie',
    'authorization',
    'proxy-authorization',
    'x-api-key',
    'x-auth-token',
    'x-csrf-token',
  };

  static bool isSensitive(String name) =>
      names.contains(name.trim().toLowerCase());

  /// 按同源规则过滤：只有目标与来源同 origin 时才保留敏感 Header。
  static Map<String, String> filter({
    required Map<String, String> headers,
    required String origin,
    required String target,
  }) {
    if (origin == target) return Map.of(headers);
    return {
      for (final entry in headers.entries)
        if (!isSensitive(entry.key)) entry.key: entry.value,
    };
  }
}

/// 代理请求日志（§11.3.1「日志仅记录 token 指纹、目标主机、状态、字节数和耗时」）。
class ProxyLogRecord {
  const ProxyLogRecord({
    required this.tokenFingerprint,
    required this.targetHost,
    this.statusCode,
    this.bytes = 0,
    this.elapsed = Duration.zero,
    this.range,
    this.siteKey,
    this.note,
  });

  final String tokenFingerprint;
  final String targetHost;
  final int? statusCode;
  final int bytes;
  final Duration elapsed;
  final String? range;
  final String? siteKey;
  final String? note;

  String get line {
    final parts = <String>[
      'token=$tokenFingerprint',
      'host=$targetHost',
      if (statusCode != null) 'status=$statusCode',
      'bytes=$bytes',
      'elapsed=${elapsed.inMilliseconds}ms',
      if (range != null) 'range=$range',
      if (siteKey != null) 'site=$siteKey',
      if (note != null) 'note=$note',
    ];
    return parts.join(' ');
  }
}
