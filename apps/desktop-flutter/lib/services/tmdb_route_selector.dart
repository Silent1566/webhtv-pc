/// TMDB 线路健康与排序（对齐安卓 `TmdbProxy.RouteSelector`）。
///
/// 这一层是**纯逻辑**：不依赖 Flutter、`dart:io` 与 `http`，时钟可注入，
/// 因此「30 秒冷却 / 10 分钟健康 TTL / 延迟排序」都能被单测钉住。
///
/// 语义与安卓一致：
/// - 排序键依次是「是否冷却中 → 延迟 → 原始顺序」；
/// - 失败只影响该线路 30 秒（冷却），成功后立即解除；
/// - 延迟超过 10 分钟视为过期（未测速的线路按原始顺序排在后面）；
/// - 「自动」只是读取时的解析结果，**不落盘**——配置里存的永远是 `auto`。
library;

/// 线路种类。API 与图片各自独立计健康。
enum TmdbRouteKind { api, image }

/// 一条线路的健康状态。
class _RouteHealth {
  Duration? latency;
  DateTime? checkedAt;
  DateTime? failureUntil;
}

/// 线路选择器。
class TmdbRouteSelector {
  TmdbRouteSelector({
    DateTime Function()? clock,
    this.failureCooldown = const Duration(seconds: 30),
    this.healthTtl = const Duration(minutes: 10),
  }) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// 失败后的冷却时长（冷却期内的线路排到最后）。
  final Duration failureCooldown;

  /// 延迟数据的保鲜期，过期等于「没测过」。
  final Duration healthTtl;

  final Map<String, _RouteHealth> _health = {};
  int _version = 0;

  /// 变更代数。调用方（如 `AppState`）可据此缓存解析结果，避免每次 build 重排。
  int get version => _version;

  /// 按健康度排序后的候选（不修改入参）。
  List<String> order(TmdbRouteKind kind, List<String> candidates) {
    final now = _clock();
    final ordered = candidates.toList();
    final originalIndex = <String, int>{
      for (var i = 0; i < ordered.length; i++) ordered[i]: i,
    };
    ordered.sort((a, b) {
      final coolingA = isCooling(kind, a) ? 1 : 0;
      final coolingB = isCooling(kind, b) ? 1 : 0;
      if (coolingA != coolingB) return coolingA - coolingB;
      final latencyA = _latencyMillis(kind, a, now);
      final latencyB = _latencyMillis(kind, b, now);
      if (latencyA != latencyB) return latencyA.compareTo(latencyB);
      return (originalIndex[a] ?? 0).compareTo(originalIndex[b] ?? 0);
    });
    return ordered;
  }

  /// 当前最优线路；候选为空时返回空串。
  String preferred(TmdbRouteKind kind, List<String> candidates) {
    final ordered = order(kind, candidates);
    return ordered.isEmpty ? '' : ordered.first;
  }

  /// 记录一次成功（含耗时）。成功后解除该线路的冷却。
  void success(TmdbRouteKind kind, String route, Duration latency) {
    if (route.isEmpty) return;
    final health = _healthOf(kind, route);
    health
      ..latency = latency
      ..checkedAt = _clock()
      ..failureUntil = null;
    _version++;
  }

  /// 记录一次失败：该线路进入冷却。
  void failure(TmdbRouteKind kind, String route) {
    if (route.isEmpty) return;
    final health = _healthOf(kind, route);
    health
      ..failureUntil = _clock().add(failureCooldown)
      ..checkedAt = _clock();
    _version++;
  }

  /// 该线路是否在冷却期。
  bool isCooling(TmdbRouteKind kind, String route) {
    final until = _health[_key(kind, route)]?.failureUntil;
    return until != null && until.isAfter(_clock());
  }

  /// 已知延迟；未测速或已过期返回 `null`。
  Duration? latencyOf(TmdbRouteKind kind, String route) {
    final health = _health[_key(kind, route)];
    final latency = health?.latency;
    final checkedAt = health?.checkedAt;
    if (latency == null || checkedAt == null) return null;
    if (_clock().difference(checkedAt) > healthTtl) return null;
    return latency;
  }

  void clear() {
    _health.clear();
    _version++;
  }

  // -------------------------------------------------------------------------
  // 内部
  // -------------------------------------------------------------------------

  int _latencyMillis(TmdbRouteKind kind, String route, DateTime now) {
    final health = _health[_key(kind, route)];
    final latency = health?.latency;
    final checkedAt = health?.checkedAt;
    if (latency == null || checkedAt == null) return 1 << 30;
    if (now.difference(checkedAt) > healthTtl) return 1 << 30;
    return latency.inMilliseconds;
  }

  _RouteHealth _healthOf(TmdbRouteKind kind, String route) =>
      _health.putIfAbsent(_key(kind, route), _RouteHealth.new);

  String _key(TmdbRouteKind kind, String route) => '${kind.name}|$route';
}
