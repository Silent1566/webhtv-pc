/// TMDB 线路选择器（`docs/phase4/design/03` §5.7）。
///
/// 对齐安卓 `TmdbProxy.RouteSelector`：排序键「冷却 → 延迟 → 原始顺序」、
/// 失败 30 秒冷却、延迟 10 分钟过期。时钟注入，因此时间语义可以被钉住。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/tmdb_route_selector.dart';

void main() {
  late DateTime now;
  late TmdbRouteSelector selector;
  const candidates = ['a', 'b', 'c'];

  setUp(() {
    now = DateTime(2026, 11, 21, 12);
    selector = TmdbRouteSelector(clock: () => now);
  });

  test('没有任何测量时保持候选的原始顺序', () {
    expect(selector.order(TmdbRouteKind.api, candidates), candidates);
    expect(selector.preferred(TmdbRouteKind.image, candidates), 'a');
  });

  test('按实测延迟升序，未测速的排在测过的后面', () {
    selector.success(TmdbRouteKind.api, 'c', const Duration(milliseconds: 100));
    selector.success(TmdbRouteKind.api, 'b', const Duration(milliseconds: 400));
    expect(selector.order(TmdbRouteKind.api, candidates), ['c', 'b', 'a']);
  });

  test('失败进入 30 秒冷却：冷却中的排到最后，冷却后恢复按延迟排', () {
    selector.success(TmdbRouteKind.api, 'a', const Duration(milliseconds: 10));
    selector.failure(TmdbRouteKind.api, 'a');
    expect(selector.isCooling(TmdbRouteKind.api, 'a'), isTrue);
    expect(selector.preferred(TmdbRouteKind.api, candidates), 'b');

    now = now.add(const Duration(seconds: 31));
    expect(selector.isCooling(TmdbRouteKind.api, 'a'), isFalse);
    expect(selector.preferred(TmdbRouteKind.api, candidates), 'a');
  });

  test('成功会解除冷却', () {
    selector.failure(TmdbRouteKind.image, 'b');
    expect(selector.preferred(TmdbRouteKind.image, candidates), 'a');
    selector.success(TmdbRouteKind.image, 'b', const Duration(milliseconds: 5));
    expect(selector.preferred(TmdbRouteKind.image, candidates), 'b');
  });

  test('延迟数据 10 分钟后过期，等于没测过（回到原始顺序）', () {
    selector.success(TmdbRouteKind.image, 'c', const Duration(milliseconds: 1));
    expect(selector.order(TmdbRouteKind.image, candidates).first, 'c');
    now = now.add(const Duration(minutes: 11));
    expect(selector.order(TmdbRouteKind.image, candidates), candidates);
    expect(selector.latencyOf(TmdbRouteKind.image, 'c'), isNull);
  });

  test('API 与图片各自独立计健康', () {
    selector.failure(TmdbRouteKind.api, 'a');
    expect(selector.preferred(TmdbRouteKind.api, candidates), 'b');
    expect(selector.preferred(TmdbRouteKind.image, candidates), 'a');
  });

  test('每次记账都会推进 version（供调用方缓存解析结果）', () {
    final before = selector.version;
    selector.success(TmdbRouteKind.api, 'a', Duration.zero);
    expect(selector.version, greaterThan(before));
    final afterSuccess = selector.version;
    selector.failure(TmdbRouteKind.api, 'a');
    expect(selector.version, greaterThan(afterSuccess));
    final afterFailure = selector.version;
    selector.clear();
    expect(selector.version, greaterThan(afterFailure));
    expect(selector.order(TmdbRouteKind.api, candidates), candidates);
  });
}
