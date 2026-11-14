/// 选集区间分组、切片与选中定位（`docs/phase6/design/03` §4.1）。
///
/// 纯逻辑层：不依赖 Flutter，也不依赖 `services/`、`ui/`。
/// 理由与 `hot_rank_layout.dart`、`history_view.dart` 一致——阶梯分组与
/// **倒序的 `remainder` 语义**是本轮最容易写错的算法，必须在无窗口环境下锁死。
///
/// 逐条移植上游 `EpisodeRangePolicy`
/// （`webhtv/默影视` 的 `app/src/main/java/com/fongmi/android/tv/ui/helper/
/// EpisodeRangePolicy.java`），并用上游自己的单测（`EpisodeRangePolicyTest`）
/// 作为锚点核对。
///
/// ## 与上游的一处**有意偏离**
///
/// 上游 `groupSize` 内部**不**套用 `CARD_PAGE_MAX_SIZE`
/// （`static int groupSize(int size, int maxGroupSize) { ...
/// if (maxGroupSize > 0) ... }`），50 的上限由**调用方**传入
/// （`VideoActivity`、`EpisodeListDialog` 都是
/// `EpisodeRangePolicy.CARD_PAGE_MAX_SIZE`）。
///
/// 本实现按 `design/03` §4.1 的「再与 `cardPageMaxSize`（50）取 min」
/// **把上限压在 [EpisodeRangePolicy.groupSize] 内**。理由：本轮 UI 从不传
/// `maxGroupSize`，不压就会让 500 集剧集每页 100 集（阶梯值），直接违反
/// `design/03` §1 的「每页上限 50」与验收 C9（400 集 → 8 个区间）。
///
/// 两者在**实际调用路径**上等价（上游调用方总是传 50），差异只在
/// 「不传 `maxGroupSize` 时 API 的默认行为」。
library;

/// 一个选集区间（一段连续的集）。
///
/// [start] 含、[end] 不含（半开区间），对应 `VodPlayLine.episodes` 的**列表下标**；
/// [label] 是**展示用**的真实集号区间（如 `1-20`、`21`），与列表下标无关——
/// 正序时两者数值接近，倒序时标签是反的（见 [EpisodeRangePolicy.build]）。
class EpisodeRange {
  const EpisodeRange({
    required this.label,
    required this.start,
    required this.end,
    required this.selected,
  });

  /// 真实集号区间文案。单集时是 `"21"`，多集时是 `"1-20"`。
  final String label;

  /// 起始列表下标（含）。
  final int start;

  /// 结束列表下标（**不含**）。
  final int end;

  /// 是否为当前选中区间。
  final bool selected;

  /// 复制并改选中态（对齐上游 `Range.withSelected`）。
  EpisodeRange withSelected(bool selected) => EpisodeRange(
    label: label,
    start: start,
    end: end,
    selected: selected,
  );
}

/// 区间分组策略（对齐上游 `EpisodeRangePolicy`）。
abstract final class EpisodeRangePolicy {
  /// 每页集数的**硬上限**（对齐上游 `CARD_PAGE_MAX_SIZE`）。
  static const int cardPageMaxSize = 50;

  /// 生效的每页集数。
  ///
  /// = `min(defaultGroupSize(size), cardPageMaxSize)`，再受 [maxGroupSize]
  /// 进一步压低（`> 0` 时才生效，对齐上游 `if (maxGroupSize > 0)`）。
  /// 结果至少为 1，避免除零。
  static int groupSize(int size, [int maxGroupSize = 0]) {
    var group = defaultGroupSize(size);
    if (group > cardPageMaxSize) group = cardPageMaxSize;
    if (maxGroupSize > 0 && maxGroupSize < group) group = maxGroupSize;
    return group < 1 ? 1 : group;
  }

  /// 阶梯分组（逐条对齐上游 `defaultGroupSize`）。
  ///
  /// **注意**：这里返回的是**阶梯值本身**，不含 [cardPageMaxSize] 封顶——
  /// 封顶是 [groupSize] 的职责。两者不能混为一谈（1000 集的阶梯值是 100，
  /// 而生效每页是 50）。
  static int defaultGroupSize(int size) {
    if (size <= 60) return 20;
    if (size > 2500) return 300;
    if (size > 1500) return 200;
    if (size > 1000) return 150;
    if (size > 500) return 100;
    if (size > 300) return 50;
    return 40;
  }

  /// 分组。
  ///
  /// [reverse] 为真时**不**只是把区间顺序倒过来：余数段会落在**最前**，
  /// 使「集号边界」与正序一致（对齐列表尾部）。上游注释原文：
  /// 「Reverse keeps the same episode-number group boundaries as forward order,
  /// so the partial group lands first (chunks align to the end of the list).」
  ///
  /// 末尾兜底：若没有任何区间包含 [selectedIndex]（例如越界），
  /// 把**第一个**区间标记为选中（对齐上游 `ranges.set(0, ...)`）。
  static List<EpisodeRange> build(
    int size,
    int selectedIndex,
    bool reverse, [
    int maxGroupSize = 0,
  ]) {
    final ranges = <EpisodeRange>[];
    if (size <= 0) return ranges;
    final group = groupSize(size, maxGroupSize);
    final count = (size / group).ceil();
    final remainder = size % group;
    for (var i = 0; i < count; i++) {
      final int start;
      final int end;
      if (reverse && remainder != 0) {
        start = i == 0 ? 0 : remainder + (i - 1) * group;
        end = i == 0 ? remainder : (start + group).clamp(0, size);
      } else {
        start = i * group;
        end = (start + group).clamp(0, size);
      }
      // 标签按**原始集号**方向算：倒序时 near-0 的下标对应大集号。
      final labelStart = reverse ? size - start : start + 1;
      final labelEnd = reverse ? size - end + 1 : end;
      final single = labelStart == labelEnd;
      ranges.add(
        EpisodeRange(
          label: single ? '$labelStart' : '$labelStart-$labelEnd',
          start: start,
          end: end,
          selected: selectedIndex >= start && selectedIndex < end,
        ),
      );
    }
    // 兜底：没有任何区间被标记时，第一个被标记。
    if (!ranges.any((range) => range.selected)) {
      ranges[0] = ranges[0].withSelected(true);
    }
    return ranges;
  }

  /// 按 `[start, end)` 切片。越界夹到合法范围，不抛异常。
  static List<T> slice<T>(List<T> items, EpisodeRange range) {
    if (items.isEmpty) return const [];
    final start = range.start.clamp(0, items.length);
    final end = range.end.clamp(start, items.length);
    return items.sublist(start, end);
  }

  /// 被标记区间的下标；无标记或空列表则 0。
  static int selectedPosition(List<EpisodeRange> ranges) {
    if (ranges.isEmpty) return 0;
    for (var i = 0; i < ranges.length; i++) {
      if (ranges[i].selected) return i;
    }
    return 0;
  }

  /// 固定段长下的段号（对齐上游 `segmentIndex`）。
  ///
  /// `size <= 0` → 0；段长至少 1；选中下标夹到 `[0, size-1]`。
  static int segmentIndex(int size, int selectedIndex, int segmentSize) {
    if (size <= 0) return 0;
    final safeSegment = segmentSize < 1 ? 1 : segmentSize;
    final safeIndex = selectedIndex.clamp(0, size - 1);
    return safeIndex ~/ safeSegment;
  }

  /// 固定段长下的段首下标（对齐上游 `segmentStart`）。
  static int segmentStart(int size, int selectedIndex, int segmentSize) =>
      segmentIndex(size, selectedIndex, segmentSize) *
      (segmentSize < 1 ? 1 : segmentSize);
}
