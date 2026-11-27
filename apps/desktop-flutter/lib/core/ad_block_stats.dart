/// 去广告统计与日志（安卓 `AdBlockStats`/`AdBlockStatsStore`/`AdBlockLog`/`AdBlockLogFilter` 的 PC 化）。
///
/// 三条与安卓一致的口径，别在别的文件里重新发明：
/// - 保留期是**条数**：最多 1000 条，新记录插到最前、超出逐出最旧；没有时间淘汰；
/// - 每次清洗**不做节流**：一次清洗删掉几段就记几条，不按秒、不按站点合并；
/// - 计数（总数/站点/规则/管线）只增不减，`reset()` 才归零。
///
/// 本文件是纯模型：不碰文件、不依赖 Flutter，便于用固定样本穷举脏数据。
library;

/// 保留的拦截日志条数（与安卓一致：只按条数滚动，没有时间淘汰）。
const int kMaxAdBlockLogs = 1000;

/// 拦截提示的文案（安卓 `HlsAdblockNotice` 口径）。
///
/// 时长先四舍五入到 0.1 秒；不足 60 秒写「X.Y 秒」，满 60 秒改写分钟。
/// 没有可显示的时长（0/非有限/取整为 0）就只报段数——宁可不写，也不写「0.0 秒」。
/// 没有任何段被删时返回 null，调用方据此**不提示**。
String? adBlockNoticeMessage({
  required int segments,
  required double durationSec,
}) {
  if (segments <= 0) return null;
  final head = '已跳过 $segments 个广告片段';
  if (!durationSec.isFinite || durationSec <= 0) return head;
  final tenths = (durationSec * 10).round();
  if (tenths <= 0) return head;
  if (tenths < 600) return '$head，总广告时长 ${(tenths / 10).toStringAsFixed(1)} 秒';
  final minutes = tenths ~/ 600;
  final rest = tenths % 600;
  if (rest == 0) return '$head，总广告时长 $minutes 分钟';
  return '$head，总广告时长 $minutes 分 ${(rest / 10).round()} 秒';
}

/// 拦截统计的磁盘文件名（数据目录根部）。
const String adBlockStatsFileName = 'ad_block_stats.json';

/// 一条拦截日志：一次清洗里删掉的**一段**广告。
class AdBlockLog {
  AdBlockLog({
    required this.blockedAt,
    this.siteKey = '',
    this.siteName = '',
    this.siteDomain = '',
    this.pipeline = '',
    this.adDomain = '',
    this.ruleId = '',
    this.vodName = '',
    this.lineName = '',
    this.episodeName = '',
    this.segmentStartSeconds = 0,
    this.segmentDurationSeconds = 0,
  });

  /// 记账时刻（`DateTime.now().millisecondsSinceEpoch`）。
  final int blockedAt;
  final String siteKey;
  final String siteName;
  final String siteDomain;

  /// 命中本次清洗的管线（`proxy`/`direct` 等），用于按管线看拦截分布。
  final String pipeline;

  /// 广告分片所在主机（来自 `AdRemovedSegment.host`）。
  final String adDomain;
  final String ruleId;
  final String vodName;
  final String lineName;
  final String episodeName;

  /// 分片在清单里的起始秒与时长（相加得到起止区间）。
  final double segmentStartSeconds;
  final double segmentDurationSeconds;

  double get segmentEndSeconds => segmentStartSeconds + segmentDurationSeconds;

  /// 键名与字段同名，方便与安卓的 JSON 字段一一对照。
  Map<String, Object?> toJson() => <String, Object?>{
    'blockedAt': blockedAt,
    'siteKey': siteKey,
    'siteName': siteName,
    'siteDomain': siteDomain,
    'pipeline': pipeline,
    'adDomain': adDomain,
    'ruleId': ruleId,
    'vodName': vodName,
    'lineName': lineName,
    'episodeName': episodeName,
    'segmentStartSeconds': segmentStartSeconds,
    'segmentDurationSeconds': segmentDurationSeconds,
  };

  /// 容错解析：任何脏字段按缺省处理，绝不抛异常。
  factory AdBlockLog.fromJson(Object? raw) {
    final map = raw is Map ? raw : const {};
    return AdBlockLog(
      blockedAt: _asInt(map['blockedAt']),
      siteKey: _asString(map['siteKey']),
      siteName: _asString(map['siteName']),
      siteDomain: _asString(map['siteDomain']),
      pipeline: _asString(map['pipeline']),
      adDomain: _asString(map['adDomain']),
      ruleId: _asString(map['ruleId']),
      vodName: _asString(map['vodName']),
      lineName: _asString(map['lineName']),
      episodeName: _asString(map['episodeName']),
      segmentStartSeconds: _asDouble(map['segmentStartSeconds']),
      segmentDurationSeconds: _asDouble(map['segmentDurationSeconds']),
    );
  }
}

/// 一次清洗发生在哪个站点/哪条线路/哪一集：日志每条都带上，页面才筛得动。
class AdBlockContext {
  const AdBlockContext({
    this.siteKey = '',
    this.siteName = '',
    this.siteDomain = '',
    this.pipeline = '',
    this.vodName = '',
    this.lineName = '',
    this.episodeName = '',
  });

  final String siteKey;
  final String siteName;
  final String siteDomain;
  final String pipeline;
  final String vodName;
  final String lineName;
  final String episodeName;
}

/// 去广告统计：四类计数 + 最近 [kMaxAdBlockLogs] 条日志。
class AdBlockStats {
  AdBlockStats({
    this.totalBlocked = 0,
    this.blockedDurationSeconds = 0,
    Map<String, int>? siteBlocked,
    Map<String, int>? ruleCounts,
    Map<String, int>? pipelineCounts,
    List<AdBlockLog>? blockLogs,
    this.lastResetAt = 0,
  }) : siteBlocked = siteBlocked ?? <String, int>{},
       ruleCounts = ruleCounts ?? <String, int>{},
       pipelineCounts = pipelineCounts ?? <String, int>{},
       blockLogs = blockLogs ?? <AdBlockLog>[];

  /// 空统计（文件缺失、读坏、或还没记过）。
  factory AdBlockStats.empty() => AdBlockStats();

  /// 保留条数上限：测试与 store 共用一个口径。
  static const int maxLogs = kMaxAdBlockLogs;

  int totalBlocked;

  /// 按站点（`siteKey`，缺席时退到站名/域名）累计的拦截段数。
  Map<String, int> siteBlocked;

  /// 按规则 id 累计的拦截段数（`ads` 主机命中与 HLS 规则同表统计）。
  Map<String, int> ruleCounts;
  Map<String, int> pipelineCounts;

  /// 最近的拦截日志：**最前的是最新的一条**。
  List<AdBlockLog> blockLogs;

  int lastResetAt;

  /// 命中总时长（秒，**终身累计**）。
  ///
  /// 不能由 [blockLogs] 求和得出：日志按条数滚动，删除的旧日志会把时长一起带走，
  /// 页面上的「拦截总时长」旁边是终身总量，两把尺子迟早对不上。旧文件没有这个
  /// 字段时按「当时还留着的明细之和」迁移，这是唯一可得的近似。
  double blockedDurationSeconds;

  /// 只统计仍留在 [blockLogs] 里的时长（诊断用：判断明细覆盖了多少历史）。
  double get retainedDurationSeconds {
    var sum = 0.0;
    for (final log in blockLogs) {
      sum += log.segmentDurationSeconds;
    }
    return sum;
  }

  /// 深拷贝：落盘失败要能整份回滚，不能把半改的计数留在内存里。
  AdBlockStats copy() => AdBlockStats(
    totalBlocked: totalBlocked,
    blockedDurationSeconds: blockedDurationSeconds,
    siteBlocked: Map<String, int>.of(siteBlocked),
    ruleCounts: Map<String, int>.of(ruleCounts),
    pipelineCounts: Map<String, int>.of(pipelineCounts),
    blockLogs: List<AdBlockLog>.of(blockLogs),
    lastResetAt: lastResetAt,
  );

  /// 展示用的时间倒序视图。
  ///
  /// [blockLogs] 的插入顺序就是时间顺序，但读回的文件可能被手改或跨版本写成乱序，
  /// 所以页面排序不依赖插入顺序，宁可每次排一遍（上限 1000 条）。
  List<AdBlockLog> get logsByTimeDescending {
    final sorted = List<AdBlockLog>.of(blockLogs);
    sorted.sort((a, b) => b.blockedAt.compareTo(a.blockedAt));
    return sorted;
  }

  /// 按站点 Top（段数降序，同数按 key 升序保证确定性）。
  List<MapEntry<String, int>> topSites({int limit = 5}) =>
      _top(siteBlocked, limit);

  /// 按规则 Top。
  List<MapEntry<String, int>> topRules({int limit = 5}) =>
      _top(ruleCounts, limit);

  /// 记一批新日志：插到最前、累加四类计数、超出上限逐出最旧。
  void addAll(Iterable<AdBlockLog> logs) {
    final batch = logs.toList(growable: false);
    if (batch.isEmpty) return;
    totalBlocked += batch.length;
    for (final log in batch) {
      if (log.segmentDurationSeconds.isFinite) {
        blockedDurationSeconds += log.segmentDurationSeconds;
      }
      final site = log.siteKey.isNotEmpty
          ? log.siteKey
          : log.siteName.isNotEmpty
          ? log.siteName
          : log.siteDomain.isNotEmpty
          ? log.siteDomain
          : '未知站点';
      siteBlocked[site] = (siteBlocked[site] ?? 0) + 1;
      final rule = log.ruleId.isEmpty ? '未知规则' : log.ruleId;
      ruleCounts[rule] = (ruleCounts[rule] ?? 0) + 1;
      final pipeline = log.pipeline.isEmpty ? '未知管线' : log.pipeline;
      pipelineCounts[pipeline] = (pipelineCounts[pipeline] ?? 0) + 1;
    }
    blockLogs.insertAll(0, batch);
    if (blockLogs.length > maxLogs) {
      blockLogs.removeRange(maxLogs, blockLogs.length);
    }
  }

  /// 清空四类计数与日志，并刷新 [lastResetAt]。
  void reset() {
    totalBlocked = 0;
    blockedDurationSeconds = 0;
    siteBlocked.clear();
    ruleCounts.clear();
    pipelineCounts.clear();
    blockLogs.clear();
    lastResetAt = DateTime.now().millisecondsSinceEpoch;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'totalBlocked': totalBlocked,
    'blockedDurationSeconds': blockedDurationSeconds,
    'siteBlocked': siteBlocked,
    'ruleCounts': ruleCounts,
    'pipelineCounts': pipelineCounts,
    'blockLogs': [for (final log in blockLogs) log.toJson()],
    'lastResetAt': lastResetAt,
  };

  /// 容错解析：字段级降级 + 最外层兜底，任何输入都返回一份可用的统计。
  static AdBlockStats fromJson(Object? raw) {
    final map = raw is Map ? raw : const {};
    try {
      // 读盘也守 1000 条不变式：文件可能被手改或由更早的版本写出。
      final logs = [
        for (final item in _asList(map['blockLogs']))
          if (item is Map) AdBlockLog.fromJson(item),
      ];
      logs.sort((a, b) => b.blockedAt.compareTo(a.blockedAt));
      final retained = logs.length > maxLogs ? logs.sublist(0, maxLogs) : logs;
      final storedDuration = _asDouble(map['blockedDurationSeconds']);
      return AdBlockStats(
        totalBlocked: _asInt(map['totalBlocked']),
        // 旧文件没有终身时长：退到「当时还留着的明细之和」，其余无从得知。
        blockedDurationSeconds: storedDuration > 0
            ? storedDuration
            : retained.fold<double>(
                0,
                (sum, log) => sum + log.segmentDurationSeconds,
              ),
        siteBlocked: _counterMap(map['siteBlocked']),
        ruleCounts: _counterMap(map['ruleCounts']),
        pipelineCounts: _counterMap(map['pipelineCounts']),
        blockLogs: retained,
        lastResetAt: _asInt(map['lastResetAt']),
      );
    } catch (_) {
      // 统计是诊断设施：读坏一份文件最多丢历史，绝不能把页面或启动拖垮。
      return AdBlockStats.empty();
    }
  }

  static List<MapEntry<String, int>> _top(Map<String, int> counts, int limit) {
    final entries = counts.entries
        .where((entry) => entry.value > 0)
        .toList(growable: false);
    entries.sort((a, b) {
      final byCount = b.value.compareTo(a.value);
      return byCount != 0 ? byCount : a.key.compareTo(b.key);
    });
    return entries.length > limit ? entries.sublist(0, limit) : entries;
  }
}

/// 日志表筛选：五个文本条件，**同列多值 OR、跨列 AND**。
///
/// 多值为什么用逗号分隔而不是空格：站点名本身就带空格（`A 站`），按空格切会把
/// 一个条件切成两个，于是「筛 A 站」永远筛不出东西。
class AdBlockLogFilter {
  const AdBlockLogFilter({
    this.siteName = const [],
    this.siteDomain = const [],
    this.rule = const [],
    this.adDomain = const [],
    this.pipeline = const [],
    this.ruleLabelOf,
  });

  /// 把页面上的五个文本框翻成 token 列表（trim + 小写 + 去空）。
  factory AdBlockLogFilter.fromQuery({
    String siteName = '',
    String siteDomain = '',
    String rule = '',
    String adDomain = '',
    String pipeline = '',
    String Function(String ruleId)? ruleLabelOf,
  }) => AdBlockLogFilter(
    siteName: _tokens(siteName),
    siteDomain: _tokens(siteDomain),
    rule: _tokens(rule),
    adDomain: _tokens(adDomain),
    pipeline: _tokens(pipeline),
    ruleLabelOf: ruleLabelOf,
  );

  static const AdBlockLogFilter empty = AdBlockLogFilter();

  /// 站点名列；空列表表示该列不限。
  final List<String> siteName;
  final List<String> siteDomain;

  /// 规则列：匹配规则 id（展示名由页面的 `ruleName` 回调翻译）。
  final List<String> rule;
  final List<String> adDomain;
  final List<String> pipeline;

  /// 规则 id → 展示名。表格里显示的是名字，用户照着名字打字也必须筛得出来；
  /// 纯模型拿不到命名表，所以由调用方注入。
  final String Function(String ruleId)? ruleLabelOf;

  bool get isEmpty =>
      siteName.isEmpty &&
      siteDomain.isEmpty &&
      rule.isEmpty &&
      adDomain.isEmpty &&
      pipeline.isEmpty;

  bool matches(AdBlockLog log) =>
      _hits(siteName, log.siteName) &&
      _hits(siteDomain, log.siteDomain) &&
      _hitsAny(rule, [log.ruleId, ruleLabelOf?.call(log.ruleId) ?? '']) &&
      _hits(adDomain, log.adDomain) &&
      _hits(pipeline, log.pipeline);

  /// 保序过滤：页面拿到的已经是时间倒序，过滤不该再动顺序。
  List<AdBlockLog> apply(Iterable<AdBlockLog> logs) => [
    for (final log in logs)
      if (matches(log)) log,
  ];

  /// 同一条记录的多个可匹配文本（如规则 id 与展示名）：任一文本命中任一 token 即可。
  static bool _hitsAny(List<String> tokens, List<String> values) {
    if (tokens.isEmpty) return true;
    final usable = [
      for (final value in values)
        if (value.trim().isNotEmpty) value,
    ];
    if (usable.isEmpty) return true;
    for (final value in usable) {
      if (_hits(tokens, value)) return true;
    }
    return false;
  }

  /// 同列多个 token：任一命中即通过；没有有效 token 则视为不设限。
  ///
  /// 手搓 [AdBlockLogFilter] 可能塞进空串（`['  ']`），按「不设限」处理才不会
  /// 因为一个空输入框把整张表筛空。
  static bool _hits(List<String> tokens, String value) {
    final active = [
      for (final token in tokens)
        if (token.trim().isNotEmpty) token.trim(),
    ];
    if (active.isEmpty) return true;
    final target = value.toLowerCase();
    for (final token in active) {
      if (target.contains(token)) return true;
    }
    return false;
  }

  static List<String> _tokens(String raw) => [
    for (final part in raw.split(RegExp(r'[,，]')))
      if (part.trim().isNotEmpty) part.trim().toLowerCase(),
  ];
}

int _asInt(Object? raw) {
  if (raw is num) return raw.isFinite ? raw.toInt() : 0;
  if (raw is String) return int.tryParse(raw.trim()) ?? 0;
  return 0;
}

double _asDouble(Object? raw) {
  // double.tryParse 认得 "NaN"/"Infinity"：放进来会让整份统计再也写不出去
  // （jsonEncode 拒绝非有限数），所以两条分支都只接受有限值。
  final value = raw is num
      ? raw.toDouble()
      : raw is String
      ? double.tryParse(raw.trim())
      : null;
  return value != null && value.isFinite ? value : 0;
}

String _asString(Object? raw) => raw is String ? raw.trim() : '';

List<Object?> _asList(Object? raw) => raw is List ? raw : const [];

/// 计数表：非字符串 key、非正数、脏值一律丢弃。
Map<String, int> _counterMap(Object? raw) {
  if (raw is! Map) return <String, int>{};
  final counts = <String, int>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    if (key is! String || key.trim().isEmpty) continue;
    final value = _asInt(entry.value);
    if (value <= 0) continue;
    counts[key.trim()] = value;
  }
  return counts;
}
