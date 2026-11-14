/// 详情页评分与外链的状态（纯状态层，不含 UI）。
///
/// 两个详情页（站点详情页与纯 TMDB 页）共用：都把「一次评分查询」交给它，
/// 由它负责去重、陈旧响应丢弃与 loading/failed 标记。
///
/// 为什么不是每个页面各写一份 `setState`：评分请求是**网络 + 缓存**的异步流，
/// 用户在两部作品之间来回切换时，先到后到的响应会互相覆盖——这正是详情页
/// 其他区域历史上踩过的坑（幂等键 / generation 令牌）。集中在一处只需修一次。
library;

import 'package:flutter/foundation.dart';

import '../core/detail_ratings.dart';
import '../services/detail_rating_service.dart';

/// 外部评分 + 静态外链的一体化状态。
///
/// 具名参数绑定到私有字段，无法用初始化形参（与 detail_recommendation_state.dart
/// 同一写法）。
// ignore_for_file: prefer_initializing_formals
class DetailRatingsController extends ChangeNotifier {
  DetailRatingsController({
    required DetailRatingService service,
    required String Function() omdbApiKey,
  }) : _service = service,
       _omdbApiKey = omdbApiKey;

  final DetailRatingService _service;

  /// OMDb Key 在运行时才定（设置页保存后无需重建控制器）。
  final String Function() _omdbApiKey;

  DetailRatings _ratings = const DetailRatings();
  DetailRatingRequest? _request;
  int _generation = 0;
  bool _disposed = false;

  DetailRatings get ratings => _ratings;

  /// 当前查询的幂等键（空 = 还没开始）。
  String get requestKey => _request?.cacheKey ?? '';

  /// 用一份新请求重置区块：静态外链**立刻**可点，分值随请求补齐。
  void begin(DetailRatingRequest request) {
    _request = request;
    _generation++;
    _ratings = DetailRatingRules.build(
      request: request,
      loading: !request.isEmpty,
    );
    notifyListeners();
  }

  /// 发起（或跳过）评分查询。
  ///
  /// 空请求（既无标题也无 IMDb id）直接结束 loading：没有任何东西可查，
  /// 保持转圈只会让用户等一个永远不会来的结果。
  Future<void> load() async {
    final request = _request;
    if (_disposed || request == null) return;
    final generation = _generation;
    if (request.isEmpty) {
      _ratings = _ratings.copyWith(loading: false);
      notifyListeners();
      return;
    }
    DetailRatingValues values = DetailRatingValues.empty;
    var failed = false;
    try {
      values = await _service.fetch(request, omdbApiKey: _omdbApiKey());
    } catch (_) {
      // `DetailRatingService.fetch` 自己的契约是不抛，这里再兜一层：
      // 评分是增强信息，任何异常都不许打断详情页。
      failed = true;
    }
    if (_disposed || generation != _generation) return;
    _ratings = DetailRatingRules.build(
      request: request,
      values: values,
      failed: failed,
    );
    notifyListeners();
  }

  /// 清空（离开详情、或身份换成另一部作品时调用）。
  void reset() {
    _request = null;
    _generation++;
    _ratings = const DetailRatings();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    // 页面关掉后没人再等这次评分：取消还在等限速间隔的请求。不这么做，
    // 豆瓣那 750ms 的 Timer 会挂到测试结束，`flutter_test` 直接判失败
    // （「A Timer is still pending even after the widget tree was disposed」）。
    _service.cancelPending();
    super.dispose();
  }
}
