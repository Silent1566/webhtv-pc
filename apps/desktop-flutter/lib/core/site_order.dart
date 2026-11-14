/// 站点列表的本地治理：健康排序偏好 + 手动顺序 + 屏蔽。
///
/// 三条规则**互不覆写**：
/// - **健康排序**（[SiteOrderSettings.healthSort]）：只影响搜索/换源时的先后；
/// - **手动顺序**（[SiteListOverrides.order]）：用户在站点选择器里排出来的顺序，
///   按配置分别保存；未排过的站点保持配置顺序追加在后（新增站点不会插队）；
/// - **屏蔽**（[SiteListOverrides.blocked]）：从**站点选择器**里隐去、且不参与搜索/换源的
///   站点（诊断页与 AI 源名仍会显示它，当前正在使用的站点也照常可用）。
///
/// 手动顺序与屏蔽都只是**本地覆盖**，不写回配置文件：配置文件仍是站点集合的唯一
/// 事实来源，换配置/重导配置都不会把用户的排序或屏蔽写进别人的文件。
library;

class SiteOrderSettings {
  const SiteOrderSettings({this.healthSort = false});

  const SiteOrderSettings.defaults() : this();

  /// 搜索/换源是否优先使用健康的站点。
  final bool healthSort;

  SiteOrderSettings copyWith({bool? healthSort}) =>
      SiteOrderSettings(healthSort: healthSort ?? this.healthSort);

  Map<String, Object?> toJson() => <String, Object?>{'healthSort': healthSort};

  factory SiteOrderSettings.fromJson(Object? raw) {
    final map = raw is Map ? raw : const {};
    return SiteOrderSettings(
      healthSort: map['healthSort'] is bool
          ? map['healthSort'] as bool
          : false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SiteOrderSettings && other.healthSort == healthSort;

  @override
  int get hashCode => healthSort.hashCode;

  @override
  String toString() => 'SiteOrderSettings(healthSort=$healthSort)';
}

/// 一份配置下的站点列表覆盖：手动顺序 + 屏蔽集合。
///
/// 语义对齐安卓 `SiteOrderStore` / `SiteBlockSetting`：
/// - 按配置作用域分别保存，不跨配置共享；
/// - 顺序里允许出现配置里已不存在的 key（站点被删），读取时忽略；
/// - 屏蔽集合同理，站点改名/删除时残留的 key 不影响界面。
class SiteListOverrides {
  const SiteListOverrides({
    this.order = const <String>[],
    this.blocked = const <String>{},
  });

  static const SiteListOverrides empty = SiteListOverrides();

  /// 手动顺序（站点 key，按用户排定的先后）。
  final List<String> order;

  /// 被屏蔽的站点 key。
  final Set<String> blocked;

  bool get hasOrder => order.isNotEmpty;

  bool get hasBlocked => blocked.isNotEmpty;

  bool get isEmpty => order.isEmpty && blocked.isEmpty;

  bool isBlocked(String key) => blocked.contains(key);

  /// 只有显式存在的项才写：缺席 = 从未设置过（与设置文件「缺席即默认」同一口径）。
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    if (order.isNotEmpty) json['order'] = order;
    if (blocked.isNotEmpty) json['blocked'] = (blocked.toList()..sort());
    return json;
  }

  factory SiteListOverrides.fromJson(Object? raw) {
    final map = raw is Map ? raw : const {};
    return SiteListOverrides(
      order: normalizeSiteKeys(map['order']),
      blocked: normalizeSiteKeys(map['blocked']).toSet(),
    );
  }

  SiteListOverrides copyWith({List<String>? order, Set<String>? blocked}) =>
      SiteListOverrides(
        order: order ?? this.order,
        blocked: blocked ?? this.blocked,
      );

  @override
  bool operator ==(Object other) {
    if (other is! SiteListOverrides) return false;
    if (other.order.length != order.length ||
        other.blocked.length != blocked.length) {
      return false;
    }
    for (var i = 0; i < order.length; i++) {
      if (other.order[i] != order[i]) return false;
    }
    return other.blocked.containsAll(blocked);
  }

  @override
  int get hashCode =>
      Object.hash(order.join('\u0000'), Object.hashAllUnordered(blocked));

  @override
  String toString() =>
      'SiteListOverrides(order=$order, blocked=${blocked.length} 项)';
}

/// 归一化站点 key 列表：丢掉非字符串/空白/重复项，保持先后。
///
/// 设置文件是用户可编辑的：类型不符或脏数据必须静默跳过，不能让整个列表作废。
List<String> normalizeSiteKeys(Object? raw) {
  if (raw is! Iterable) return const <String>[];
  final seen = <String>{};
  final result = <String>[];
  for (final item in raw) {
    if (item is! String) continue;
    final key = item.trim();
    if (key.isEmpty || !seen.add(key)) continue;
    result.add(key);
  }
  return result;
}

/// 按用户排定的手动顺序重排 [keys]。
///
/// - [savedOrder] 里存在的 key 按它的先后排在前面；
/// - 其余 key（新增站点、或从未排序过的站点）保持 [keys] 的原顺序追加在后；
/// - 顺序里已失效的 key 直接忽略。
///
/// 稳定性是硬要求：同一份输入必须给出同一份输出，否则站点列表每次打开都会抖。
List<String> orderSiteKeysByManual({
  required List<String> keys,
  required List<String> savedOrder,
}) {
  if (savedOrder.isEmpty || keys.length <= 1) return List<String>.of(keys);
  final index = <String, int>{
    for (var i = 0; i < savedOrder.length; i++) savedOrder[i]: i,
  };
  final indexed = keys.indexed.toList();
  indexed.sort((a, b) {
    final left = index[a.$2];
    final right = index[b.$2];
    if (left == null && right == null) return a.$1.compareTo(b.$1);
    if (left == null) return 1;
    if (right == null) return -1;
    return left.compareTo(right);
  });
  return [for (final entry in indexed) entry.$2];
}

/// 按健康度重排站点 key；[scores] 缺失表示该站点没有样本。
///
/// 稳定性：分数相同（或都没有样本）时保持传入顺序；不返回缺失的 key。
List<String> orderSiteKeysByHealth({
  required List<String> keys,
  required bool enabled,
  required Map<String, double> scores,
}) {
  if (!enabled || keys.length <= 1) return List<String>.of(keys);
  final indexed = keys.indexed.toList();
  indexed.sort((a, b) {
    final scoreA = scores[a.$2];
    final scoreB = scores[b.$2];
    if (scoreA == null && scoreB == null) return a.$1.compareTo(b.$1);
    if (scoreA == null) return 1;
    if (scoreB == null) return -1;
    final byScore = scoreB.compareTo(scoreA);
    return byScore != 0 ? byScore : a.$1.compareTo(b.$1);
  });
  return [for (final entry in indexed) entry.$2];
}
