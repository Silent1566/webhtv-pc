/// 三家 provider 的注册表 + 并行查询 + 内存缓存（对齐安卓
/// `IntroSkipService` 的 `isCacheableResponse` 语义）。
///
/// 分工：provider 只解析，这里只调度——绝不折算，缓存里存的也是未折算的原始段
/// （同一集换了线路、时长不同时能复用同一份缓存，折算推迟到读取时按当次时长做）。
library;

import 'package:http/http.dart' as http;

import '../../core/skip_plan.dart';
import 'introdb_provider.dart';
import 'provider.dart';
import 'theintrodb_provider.dart';
import 'todb_provider.dart';

/// 全部 provider；顺序即查询顺序，也是 [IntroSkipLookupResult.segments] 的追加
/// 顺序（同分段的取舍最终由 `SkipPlan` 的去重规则决定，顺序只影响可读性）。
const List<IntroSkipProvider> _allProviders = <IntroSkipProvider>[
  IntroDbProvider(),
  TheIntroDbProvider(),
  TodbProvider(),
];

/// 按数据源位筛出本次要查询的 provider（`SkipSourceBits.defaults` 三家全开）。
List<IntroSkipProvider> buildIntroSkipProviders(int sources) {
  final result = <IntroSkipProvider>[];
  for (final provider in _allProviders) {
    if (SkipSourceBits.enabled(sources, provider.id)) result.add(provider);
  }
  return result;
}

/// 一次并行查询的结果。
class IntroSkipLookupResult {
  const IntroSkipLookupResult({
    required this.segments,
    required this.cacheable,
  });

  /// 空结果，且**不可缓存**：默认值是「没查完」，可缓存必须是证据。
  static const IntroSkipLookupResult unknown = IntroSkipLookupResult(
    segments: <RawSkipSegment>[],
    cacheable: false,
  );

  /// 未折算的原始段（可能含多家/多版本的重复段）。
  final List<RawSkipSegment> segments;

  /// 这次结果是否代表「这集确定查完了」：为真才会写进缓存。
  ///
  /// 只要有一家没答上来（超时/非 2xx/坏 JSON）就是假——把半份结果缓存下来，
  /// 那家恢复正常后也再没机会补上。
  final bool cacheable;

  bool get isEmpty => segments.isEmpty;

  bool get isNotEmpty => segments.isNotEmpty;

  @override
  String toString() =>
      'IntroSkipLookupResult(${segments.length} segments, '
      'cacheable=$cacheable)';
}

/// 内存 LRU：键是 [SkipQuery.cacheKey]，值是**未折算**的原始段。
///
/// 只做进程内缓存：重启后要重查一遍是可接受的代价，落盘反而会让过期数据长期
/// 生效（远端标记会被人不断修正）。
class IntroSkipCache {
  IntroSkipCache({this.capacity = 128});

  /// 条目上限；`<= 0` 表示不缓存。
  final int capacity;

  /// Dart 的 Map 保持插入顺序：末尾即最近使用，淘汰从头开始，所以不必再引
  /// `dart:collection` 的 LinkedHashMap（它本来就是同一个实现）。
  final Map<String, List<RawSkipSegment>> _entries =
      <String, List<RawSkipSegment>>{};

  /// 当前条目数（测试与诊断用）。
  int get length => _entries.length;

  /// 读一条；命中即刷新为最近使用。未命中返回 null。
  List<RawSkipSegment>? get(String key) {
    final hit = _entries.remove(key);
    if (hit == null) return null;
    _entries[key] = hit;
    return hit;
  }

  /// 写一条；超出 [capacity] 时淘汰最久未使用的。
  void put(String key, List<RawSkipSegment> segments) {
    if (capacity <= 0) return;
    _entries.remove(key);
    _entries[key] = List<RawSkipSegment>.unmodifiable(segments);
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  void clear() => _entries.clear();
}

/// 并行查一集：总超时 [timeout]，单家失败不影响其他家。
///
/// [cache] 命中即直接返回（可缓存：它本来就只装查完的结果）；本次结果可缓存时
/// 顺手写入。
Future<IntroSkipLookupResult> lookupIntroSkip({
  required SkipQuery query,
  required List<IntroSkipProvider> providers,
  http.Client? client,
  Duration timeout = const Duration(seconds: 5),
  IntroSkipCache? cache,
}) async {
  // 没有任何查询条件不是失败，是确定的「查不了」：直接给出可缓存的空结果，
  // 免得每一集都白打一轮请求。
  if (!query.canLookup) {
    return const IntroSkipLookupResult(
      segments: <RawSkipSegment>[],
      cacheable: true,
    );
  }
  final cached = cache?.get(query.cacheKey);
  if (cached != null) {
    return IntroSkipLookupResult(segments: cached, cacheable: true);
  }
  if (providers.isEmpty) return IntroSkipLookupResult.unknown;

  final owned = client ?? http.Client();
  final clock = Stopwatch()..start();
  try {
    final outcomes = await Future.wait(
      providers.map(
        (provider) => _fetchOne(provider, query, owned, timeout, clock),
      ),
    );
    var completed = 0;
    var failed = false;
    final segments = <RawSkipSegment>[];
    for (final outcome in outcomes) {
      if (outcome == null) {
        failed = true;
        continue;
      }
      completed++;
      segments.addAll(outcome);
    }
    final cacheable = completed == providers.length && !failed;
    if (cacheable) cache?.put(query.cacheKey, segments);
    return IntroSkipLookupResult(
      segments: List<RawSkipSegment>.unmodifiable(segments),
      cacheable: cacheable,
    );
  } finally {
    clock.stop();
    // 注入的 client 由调用方拥有生命周期，这里只关自己开的那一个。
    if (client == null) owned.close();
  }
}

/// 单家查询：把超时/网络/解析异常一律折成 null（= 这家没答上来）。
///
/// [clock] 让各家共用同一个总预算，而不是每家各等一份超时：并行发起时分摊下来
/// 等于最大 5s，但某家同步阻塞时也不会让总时长翻倍。
Future<List<RawSkipSegment>?> _fetchOne(
  IntroSkipProvider provider,
  SkipQuery query,
  http.Client client,
  Duration total,
  Stopwatch clock,
) async {
  final spent = clock.elapsed;
  final budget = spent >= total ? Duration.zero : total - spent;
  try {
    return await provider.fetch(query, client: client).timeout(budget);
  } catch (_) {
    return null;
  }
}
