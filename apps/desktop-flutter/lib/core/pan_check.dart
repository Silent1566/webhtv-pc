/// 网盘分享链接检测的纯逻辑（`docs/phase9/README.md` P1-8）。
///
/// 与安卓 `DriveCheckService` 对齐的部分：
/// - 五态结果：`ok` / `bad` / `locked` / `unsupported` / `uncertain`；
/// - 按网盘类型归一化链接、抽取提取码；
/// - 结果带 TTL 缓存（成功 1h、失效 6h、需提取码 12h、不支持 24h、不确定 30min）。
///
/// **不做**各网盘私有接口的逆向适配：那需要逐家实测且随时会失效，PC 端只做
/// 「链接形态识别 + 通用可达性/页面特征判定」，无法判定时如实返回 `uncertain`。
library;

/// 网盘类型。
enum PanDiskType {
  baidu('baidu', '百度网盘'),
  quark('quark', '夸克网盘'),
  aliyun('aliyun', '阿里云盘'),
  uc('uc', 'UC 网盘'),
  pan123('123pan', '123 网盘'),
  tianyi('tianyi', '天翼云盘'),
  unknown('unknown', '未知网盘');

  const PanDiskType(this.id, this.label);

  final String id;
  final String label;
}

/// 检测状态。
enum PanCheckState {
  ok('ok', '有效'),
  bad('bad', '失效'),
  locked('locked', '需要提取码'),
  unsupported('unsupported', '不支持'),
  uncertain('uncertain', '无法判定');

  const PanCheckState(this.id, this.label);

  final String id;
  final String label;

  static PanCheckState fromId(Object? raw) {
    final value = raw is String ? raw.trim().toLowerCase() : '';
    for (final state in values) {
      if (state.id == value) return state;
    }
    return PanCheckState.uncertain;
  }

  /// 缓存有效期（与安卓一致）。
  Duration get ttl => switch (this) {
    PanCheckState.ok => const Duration(hours: 1),
    PanCheckState.unsupported => const Duration(hours: 24),
    PanCheckState.bad => const Duration(hours: 6),
    PanCheckState.locked => const Duration(hours: 12),
    PanCheckState.uncertain => const Duration(minutes: 30),
  };
}

/// 一次检测结果。
class PanCheckResult {
  const PanCheckResult({
    required this.url,
    required this.diskType,
    required this.state,
    required this.summary,
    required this.checkedAt,
    this.normalizedUrl = '',
    this.fromCache = false,
  });

  final String url;
  final String normalizedUrl;
  final PanDiskType diskType;
  final PanCheckState state;
  final String summary;
  final int checkedAt;
  final bool fromCache;

  int get expiresAt => checkedAt + state.ttl.inMilliseconds;

  bool isExpiredAt(DateTime now) =>
      now.millisecondsSinceEpoch >= expiresAt;

  PanCheckResult copyWith({bool? fromCache, int? checkedAt}) => PanCheckResult(
    url: url,
    normalizedUrl: normalizedUrl,
    diskType: diskType,
    state: state,
    summary: summary,
    checkedAt: checkedAt ?? this.checkedAt,
    fromCache: fromCache ?? this.fromCache,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'url': url,
    'normalizedUrl': normalizedUrl,
    'diskType': diskType.id,
    'state': state.id,
    'summary': summary,
    'checkedAt': checkedAt,
  };

  factory PanCheckResult.fromJson(Object? raw) {
    final map = raw is Map ? raw : const {};
    final diskType = PanDiskType.values.firstWhere(
      (type) => type.id == (map['diskType'] is String ? map['diskType'] : ''),
      orElse: () => PanDiskType.unknown,
    );
    return PanCheckResult(
      url: map['url'] is String ? map['url'] as String : '',
      normalizedUrl: map['normalizedUrl'] is String
          ? map['normalizedUrl'] as String
          : '',
      diskType: diskType,
      state: PanCheckState.fromId(map['state']),
      summary: map['summary'] is String ? map['summary'] as String : '',
      checkedAt: map['checkedAt'] is num
          ? (map['checkedAt'] as num).toInt()
          : 0,
    );
  }

  @override
  String toString() =>
      'PanCheckResult(${diskType.id}, ${state.id}, "$summary")';
}

/// 解析后的分享链接信息。
class PanShareLink {
  const PanShareLink({
    required this.url,
    required this.diskType,
    this.shareId = '',
    this.password = '',
  });

  final String url;
  final PanDiskType diskType;
  final String shareId;
  final String password;

  bool get isUnknown => diskType == PanDiskType.unknown;

  /// 归一化链接：去掉 fragment、去掉 `pwd` 之外的噪声参数；
  /// 百度/夸克/UC 有提取码时补 `pwd=`。
  String get normalizedUrl {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return url.trim();
    final query = <String, String>{...uri.queryParameters};
    if (password.isNotEmpty &&
        (diskType == PanDiskType.baidu ||
            diskType == PanDiskType.quark ||
            diskType == PanDiskType.uc)) {
      query.putIfAbsent('pwd', () => password);
    }
    final filtered = <String, String>{
      for (final entry in query.entries)
        if (!_noiseKeys.contains(entry.key.toLowerCase())) entry.key: entry.value,
    };
    return uri
        .replace(queryParameters: filtered.isEmpty ? null : filtered, fragment: '')
        .toString();
  }

  static const Set<String> _noiseKeys = {
    'entry',
    'from',
    'share_token',
    'sharetype',
    'channel',
  };
}

final Map<PanDiskType, List<RegExp>> _sharePatterns = {
  PanDiskType.baidu: [RegExp(r'pan\.baidu\.com/s/([A-Za-z0-9_\-]+)')],
  PanDiskType.quark: [RegExp(r'pan\.quark\.cn/s/([A-Za-z0-9_\-]+)')],
  PanDiskType.aliyun: [
    RegExp(r'(?:www\.)?(?:aliyundrive|alipan)\.com/s/([A-Za-z0-9_\-]+)'),
  ],
  PanDiskType.uc: [RegExp(r'drive\.uc\.cn/s/([A-Za-z0-9_\-]+)')],
  PanDiskType.pan123: [
    RegExp(r'123(?:\d{3})?\.(?:com|cn)/s/([A-Za-z0-9_\-]+)'),
    RegExp(r'(?:www\.)?123pan\.(?:com|cn)/s/([A-Za-z0-9_\-]+)'),
  ],
  PanDiskType.tianyi: [
    RegExp(r'cloud\.189\.cn/t/([A-Za-z0-9_\-]+)'),
    RegExp(r'cloud\.189\.cn/web/share\?code=([A-Za-z0-9_\-]+)'),
  ],
};

final RegExp _passwordPattern = RegExp(
  r'(?:pwd|password|提取码|访问码)\s*[=:：]?\s*([A-Za-z0-9]{4,8})',
);

/// 从文本/链接里解析分享信息。
///
/// 支持：
/// - 纯链接；
/// - 链接 + `提取码: abcd`；
/// - 链接里带 `?pwd=abcd`。
PanShareLink parsePanShareLink(String raw) {
  final text = raw.trim();
  if (text.isEmpty) {
    return const PanShareLink(url: '', diskType: PanDiskType.unknown);
  }
  final lower = text.toLowerCase();
  for (final entry in _sharePatterns.entries) {
    for (final pattern in entry.value) {
      final match = pattern.firstMatch(lower);
      if (match == null) continue;
      final shareId = match.group(1) ?? '';
      final uri = Uri.tryParse(text);
      final fromQuery = uri?.queryParameters['pwd'] ?? '';
      final fromText = _passwordPattern.firstMatch(text)?.group(1) ?? '';
      return PanShareLink(
        url: text,
        diskType: entry.key,
        shareId: shareId,
        password: (fromQuery.isNotEmpty ? fromQuery : fromText).trim(),
      );
    }
  }
  return PanShareLink(url: text, diskType: PanDiskType.unknown);
}

/// 有 TTL 的结果缓存（内存；上限 [maxEntries]）。
class PanCheckCache {
  PanCheckCache({this.maxEntries = 300});

  final int maxEntries;
  final Map<String, PanCheckResult> _entries = {};

  int get length => _entries.length;

  PanCheckResult? get(String key, {DateTime? now}) {
    final cached = _entries[key];
    if (cached == null) return null;
    if (cached.isExpiredAt(now ?? DateTime.now())) {
      _entries.remove(key);
      return null;
    }
    return cached.copyWith(fromCache: true);
  }

  void put(String key, PanCheckResult result) {
    _entries[key] = result;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  void clear() => _entries.clear();
}

/// 依据 HTTP 结果与页面文本判定状态。
///
/// 规则刻意保守：**只有明确信号才判 bad/locked**，其余一律 uncertain——
/// 把「页面改版」误报成「链接失效」比不报更糟。
PanCheckState classifyPanCheck({
  required PanDiskType diskType,
  required int statusCode,
  required String body,
}) {
  if (diskType == PanDiskType.unknown) return PanCheckState.unsupported;
  final text = body.toLowerCase();

  // 明确的鉴权/失效信号优先。
  if (_containsAny(text, ['提取码', '访问码', '请输入密码', '密码错误', 'passcode'])) {
    return PanCheckState.locked;
  }
  if (statusCode == 404 || statusCode == 410) return PanCheckState.bad;
  if (_containsAny(text, [
    '链接不存在',
    '分享已失效',
    '分享已取消',
    '已过期',
    '违规',
    '被删除',
    'share not found',
    'sharelink',
  ])) {
    return PanCheckState.bad;
  }
  if (statusCode >= 200 && statusCode < 400) {
    // 页面正常 + 有文件/分享特征。
    if (_containsAny(text, ['文件', '分享', 'file', 'share'])) {
      return PanCheckState.ok;
    }
    return PanCheckState.uncertain;
  }
  if (statusCode == 401 || statusCode == 403) return PanCheckState.locked;
  return PanCheckState.uncertain;
}

bool _containsAny(String text, List<String> needles) =>
    needles.any((needle) => text.contains(needle.toLowerCase()));
