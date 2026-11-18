/// 追剧页共享的 TMDB 播出数据：每集真实播出时间、官方该季总集数、播放平台台名。
///
/// 宿主页（`FollowingPage`）持有唯一实例：列表卡（官方集数 / 下一集）与日历
/// （按日归集、进度分母、平台徽标）读同一份。判重按「追番身份集合」——集合不变就
/// 不重复请求（TMDB 侧另有 6h 缓存，见 `services/following_air_time_service.dart`）。
library;

import 'package:flutter/foundation.dart';

import '../core/following.dart';
import '../core/following_calendar.dart';
import '../services/following_air_time_service.dart';
import '../state/app_state.dart';

class FollowingAirData extends ChangeNotifier {
  FollowingAirData({required this.state});

  final AppState state;

  List<FollowingAirTime> airTimes = const [];
  List<FollowingSeasonTotal> seasonTotals = const [];
  Map<String, List<String>> networks = const {};

  String _airKey = '';
  String _networksKey = '';
  bool _disposed = false;

  /// 取数**发起时**也通知一次（`refresh` 里）。
  ///
  /// 视图把每次通知都当成一个分界：两次通知之间用户滚动过，就说明数据到达时不该
  /// 抢回列表位置（原判断写在日历页的 `_interactionVersion` 里，见
  /// `phase9_calendar_page_test`「加载期间手动滚动后数据就绪不抢回列表位置」）。

  /// 按当前追番集合刷新；集合没变直接返回。两个来源并行取（与原日历页一致）。
  Future<void> refresh(List<Following> items) async {
    final key = items.map((item) => item.identityKey).join(',');
    final loadAir = key != _airKey;
    final loadNetworks = key != _networksKey;
    if (!loadAir && !loadNetworks) return;
    _airKey = key;
    _networksKey = key;
    if (items.isEmpty) {
      airTimes = const [];
      seasonTotals = const [];
      networks = const {};
      _notify();
      return;
    }
    // 发起阶段先通知一次（见 [refresh] 上方的分界约定）。
    _notify();
    await Future.wait([
      if (loadNetworks) _guarded(() => _loadNetworks(items, key)),
      if (loadAir) _guarded(() => _loadAirTimes(key)),
    ]);
  }

  /// 取数失败（TMDB 未配置、状态未就绪、网络错误）只让摘要退回「未知」，不向外抛：
  /// 播出数据是增强项，不能把页面打开搞崩（`playback_entry_feedback_test` 里的
  /// AppState 就没有初始化 TMDB 存储）。
  Future<void> _guarded(Future<void> Function() load) async {
    try {
      await load();
    } catch (_) {
      // 保持空数据，界面按「未知」渲染。
    }
  }

  Future<void> _loadNetworks(List<Following> items, String key) async {
    final result = await state.followingNetworksFor(items);
    if (_disposed || key != _networksKey) return;
    networks = result;
    _notify();
  }

  Future<void> _loadAirTimes(String key) async {
    final times = await state.followingAirTimes();
    if (_disposed || key != _airKey) return;
    final totals = await state.followingSeasonTotals();
    if (_disposed || key != _airKey) return;
    airTimes = times;
    seasonTotals = totals;
    _notify();
  }

  /// 下一集的真实播出日（本地自然日 0:00）；没有未播的集返回 null。
  DateTime? nextAirDate(String identityKey, {int nowMs = 0}) {
    final now = nowMs > 0 ? nowMs : DateTime.now().millisecondsSinceEpoch;
    var next = 0;
    for (final air in airTimes) {
      if (air.identityKey != identityKey || air.airAtMs < now) continue;
      if (next == 0 || air.airAtMs < next) next = air.airAtMs;
    }
    if (next == 0) return null;
    final date = DateTime.fromMillisecondsSinceEpoch(next);
    return DateTime(date.year, date.month, date.day);
  }

  /// 集数行：**官方总集数永远显示**，本线路可播只在与之不同时补一句。
  ///
  /// 用户 2026-11-18 澄清：真实总集数不能因为「和线路一样」就省掉——线路断更/滞后时
  /// 它是唯一的真实口径。因此相同也显示（此时只报一个数，不会重复）；官方未知时返回
  /// 空串，卡片退回自己的「本线路可播 N 集」。
  String episodeLabelFor(Following item) {
    final total = officialTotal(item.identityKey);
    if (total <= 0) return '';
    final released = item.releasedEpisode;
    if (released <= 0 || released == total) return '官方共 $total 集';
    return '本线路可播 $released 集 · 官方共 $total 集';
  }

  /// 列表卡的补充摘要：只有「下一集 M月D日」（集数已在 [episodeLabelFor] 里）。
  String airSummaryFor(Following item, {int nowMs = 0}) {
    final next = nextAirDate(item.identityKey, nowMs: nowMs);
    if (next == null) return '';
    return '下一集 ${next.month}月${next.day}日';
  }

  /// 官方该季总集数；未知返回 0。
  int officialTotal(String identityKey) {
    for (final total in seasonTotals) {
      if (total.identityKey == identityKey) return total.totalEpisodes;
    }
    return 0;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
