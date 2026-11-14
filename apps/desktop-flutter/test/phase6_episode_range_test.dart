/// 选集区间分组（`docs/phase6/design/03` §4.1）。
///
/// 逐条移植上游 `EpisodeRangePolicy`（`F:/Workspace/webhtv` 的
/// `app/src/main/java/com/fongmi/android/tv/ui/helper/EpisodeRangePolicy.java`）。
/// 倒序的 `remainder` 语义**不是**"反转区间顺序"的等价写法，必须锁死——
/// 它是唯一让「倒序分组的集号边界」与正序保持一致的做法。
///
/// **与上游的一处有意偏离**（已在 `episode_range.dart` 的注释里注明）：
/// 上游 `groupSize` 内部**不**套用 `CARD_PAGE_MAX_SIZE`，50 的上限由调用方
/// 通过 `maxGroupSize` 传入；本实现按 `design/03` §4.1 的「再与
/// `cardPageMaxSize`（50）取 min」**压在 `groupSize` 内**——
/// 因为本轮 UI 从不传 `maxGroupSize`，不压就会让 500 集剧集每页 100 集，
/// 违反 design §1 的「每页上限 50」与验收 C9。
///
/// **锚点用例**：`build(38, 0, true)` 与上游自己的单测
/// （`EpisodeRangePolicyTest.build_preservesGroupBoundariesInReverseMode`）
/// **逐字一致**——它同时锁住「≤60 集每页 20」「余数段落在最前」「倒序标签方向」。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/episode_range.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/ui/tmdb_widgets.dart';

void main() {
  group('分组阶梯（defaultGroupSize，逐条对齐上游）', () {
    test('≤60 → 20', () {
      expect(EpisodeRangePolicy.defaultGroupSize(1), 20);
      expect(EpisodeRangePolicy.defaultGroupSize(60), 20);
    });

    test('>60 且 ≤300 → 40', () {
      expect(EpisodeRangePolicy.defaultGroupSize(61), 40);
      expect(EpisodeRangePolicy.defaultGroupSize(300), 40);
    });

    test('>300 且 ≤500 → 50', () {
      expect(EpisodeRangePolicy.defaultGroupSize(301), 50);
      expect(EpisodeRangePolicy.defaultGroupSize(500), 50);
    });

    test('>500 且 ≤1000 → 100', () {
      expect(EpisodeRangePolicy.defaultGroupSize(501), 100);
      expect(EpisodeRangePolicy.defaultGroupSize(1000), 100);
    });

    test('>1000 且 ≤1500 → 150', () {
      expect(EpisodeRangePolicy.defaultGroupSize(1001), 150);
      expect(EpisodeRangePolicy.defaultGroupSize(1500), 150);
    });

    test('>1500 且 ≤2500 → 200', () {
      expect(EpisodeRangePolicy.defaultGroupSize(1501), 200);
      expect(EpisodeRangePolicy.defaultGroupSize(2500), 200);
    });

    test('>2500 → 300', () {
      expect(EpisodeRangePolicy.defaultGroupSize(2501), 300);
      expect(EpisodeRangePolicy.defaultGroupSize(9999), 300);
    });

    // 这条是 brief 的**事实性错误**的钉子：brief 写 `groupSize(1000) == 50`，
    // 而 1000 的阶梯值是 100。上游 `groupSize` 内部不压上限，50 由调用方传。
    // 钉住阶梯值本身，防止把两者混为一谈后「顺手」改错阶梯。
    test('阶梯值本身不受上限影响（1000 → 100，不是 50）', () {
      expect(
        EpisodeRangePolicy.defaultGroupSize(1000),
        100,
        reason: '阶梯是阶梯；50 的上限是 groupSize 的事，两者不能混为一谈',
      );
    });
  });

  group('每页上限（cardPageMaxSize = 50）', () {
    test('groupSize 把阶梯值与上限取 min', () {
      // 400 集：阶梯 50，上限 50 → 50。
      expect(EpisodeRangePolicy.groupSize(400), 50);
      // 1000 集：阶梯 100，被上限压到 50（等价于调用方传 50）。
      expect(EpisodeRangePolicy.groupSize(1000), 50);
      // 2501 集：阶梯 300，仍被压到 50。
      expect(EpisodeRangePolicy.groupSize(2501), 50);
    });

    test('小剧集不被上限抬高（60 → 20）', () {
      expect(EpisodeRangePolicy.groupSize(60), 20);
      expect(EpisodeRangePolicy.groupSize(70), 40);
    });

    test('maxGroupSize 参数进一步压低', () {
      expect(EpisodeRangePolicy.groupSize(400, 10), 10);
    });

    test('maxGroupSize 为 0 表示不额外限制', () {
      expect(EpisodeRangePolicy.groupSize(400, 0), 50);
    });

    test('maxGroupSize 不会把每页抬到 0 或负数', () {
      expect(EpisodeRangePolicy.groupSize(400, -5), 50);
    });

    test('cardPageMaxSize 常量是 50（对齐上游）', () {
      expect(EpisodeRangePolicy.cardPageMaxSize, 50);
    });
  });

  group('build：正序', () {
    test('400 集 → 8 个区间，每段 50', () {
      final ranges = EpisodeRangePolicy.build(400, 0, false);
      expect(ranges.length, 8);
      expect(ranges.first.start, 0);
      expect(ranges.first.end, 50);
      expect(ranges.last.start, 350);
      expect(ranges.last.end, 400);
    });

    test('标签是 1-based 的闭区间', () {
      final ranges = EpisodeRangePolicy.build(400, 0, false);
      expect(ranges.first.label, '1-50');
      expect(ranges.last.label, '351-400');
    });

    test('单集区间标签不带连字符', () {
      final ranges = EpisodeRangePolicy.build(1, 0, false);
      expect(ranges.single.label, '1');
    });

    test('选中集决定哪个区间被标记', () {
      final ranges = EpisodeRangePolicy.build(400, 120, false);
      final selected = ranges.where((r) => r.selected).toList();
      expect(selected.length, 1);
      expect(selected.single.start, 100);
      expect(selected.single.end, 150);
      expect(selected.single.label, '101-150');
    });

    test('size 为 0 → 空列表', () {
      expect(EpisodeRangePolicy.build(0, 0, false), isEmpty);
    });
  });

  group('build：倒序（remainder 落在最前）', () {
    // **锚点**：与上游单测
    // `build_preservesGroupBoundariesInReverseMode` 逐字一致。
    // 38 集、每段 20 → 正序边界 1-20 / 21-38；倒序必须保持**同一集号边界**：
    // 38-21 / 20-1，且余数段（18 集）落在**最前**。
    test('38 集：余数段落在最前，且边界与正序一致（上游锚点）', () {
      final ranges = EpisodeRangePolicy.build(38, 0, true);
      expect(ranges.length, 2);
      expect(ranges[0].label, '38-21');
      expect(ranges[0].start, 0);
      expect(ranges[0].end, 18);
      expect(ranges[1].label, '20-1');
      expect(ranges[1].start, 18);
      expect(ranges[1].end, 38);
    });

    test('50 集（整除）：区间与正序同样多，标签反向', () {
      final ranges = EpisodeRangePolicy.build(50, 0, true);
      expect(ranges.length, 3);
      expect(ranges[0].start, 0);
      expect(ranges[0].end, 10);
      expect(ranges[0].label, '50-41');
      expect(ranges[1].label, '40-21');
      expect(ranges[2].label, '20-1');
      expect(ranges[2].end, 50);
    });

    // 这三条是 brief 的**事实性错误**的钉子：brief 用「70/80 集每段 20」推算
    // （得到 4 个区间），但 70/80 的阶梯值是 **40**，`20` 只适用于 ≤60 集。
    test('70 集：每段 40（不是 20）→ 2 个区间', () {
      final ranges = EpisodeRangePolicy.build(70, 0, true);
      expect(
        ranges.length,
        2,
        reason: 'defaultGroupSize(70) == 40，brief 的「4 个区间」误用了每段 20',
      );
      expect(ranges[0].label, '70-41');
      expect(ranges[0].start, 0);
      expect(ranges[0].end, 30);
      expect(ranges[1].label, '40-1');
      expect(ranges[1].start, 30);
      expect(ranges[1].end, 70);
    });

    test('80 集（整除）：每段 40 → 2 个区间，标签 80-41 / 40-1', () {
      final ranges = EpisodeRangePolicy.build(80, 0, true);
      expect(ranges.length, 2);
      expect(ranges[0].label, '80-41');
      expect(ranges[0].start, 0);
      expect(ranges[0].end, 40);
      expect(ranges[1].label, '40-1');
      expect(ranges[1].start, 40);
      expect(ranges[1].end, 80);
    });

    test('120 集：每段 40 → 3 个区间（上游锚点之二）', () {
      final ranges = EpisodeRangePolicy.build(120, 0, true);
      expect(ranges.length, 3);
      expect(ranges[0].label, '120-81');
      expect(ranges[1].label, '80-41');
      expect(ranges[2].label, '40-1');
      expect(ranges[2].end, 120);
    });

    test('倒序时选中区间按列表下标判定', () {
      // 50 集、每段 20 → 区间0=[0,10)、区间1=[10,30)、区间2=[30,50)。
      expect(EpisodeRangePolicy.build(50, 3, true).first.selected, isTrue);
      expect(EpisodeRangePolicy.build(50, 15, true)[1].selected, isTrue);
      expect(EpisodeRangePolicy.build(50, 35, true)[2].selected, isTrue);
    });

    // brief 写 `build(70,15,true)` → `ranges[1].selected`；实际 gs=40 ⇒ 段0=[0,30)。
    test('70 集倒序：下标 15 落在第 0 段（gs=40）', () {
      expect(
        EpisodeRangePolicy.build(70, 15, true).first.selected,
        isTrue,
        reason: 'gs=40 ⇒ 段0=[0,30)，下标 15 在其中；brief 误按每段 20 推算',
      );
    });
  });

  group('build：兜底选中', () {
    test('没有任何区间被选中时，第一个被标记', () {
      // selectedIndex 越界（-1）→ 没有区间包含它 → 兜底第一个。
      final ranges = EpisodeRangePolicy.build(40, -1, false);
      expect(ranges.first.selected, isTrue);
      expect(ranges.where((r) => r.selected).length, 1);
    });

    test('越界的大下标同样兜底第一个', () {
      final ranges = EpisodeRangePolicy.build(40, 9999, false);
      expect(ranges.first.selected, isTrue);
      expect(ranges.where((r) => r.selected).length, 1);
    });
  });

  group('slice', () {
    test('按 [start, end) 切片', () {
      final items = List.generate(10, (i) => i);
      final range = EpisodeRange(
        label: '3-5',
        start: 2,
        end: 5,
        selected: true,
      );
      expect(EpisodeRangePolicy.slice(items, range), [2, 3, 4]);
    });

    test('越界时夹到合法范围，不抛异常', () {
      final items = List.generate(3, (i) => i);
      final range = EpisodeRange(
        label: '1-10',
        start: 0,
        end: 10,
        selected: true,
      );
      expect(EpisodeRangePolicy.slice(items, range), [0, 1, 2]);
    });

    test('空列表 → 空结果', () {
      final range = EpisodeRange(
        label: '1-10',
        start: 0,
        end: 10,
        selected: true,
      );
      expect(EpisodeRangePolicy.slice(<int>[], range), isEmpty);
    });

    test('区间起点越界（大于长度）→ 空结果，不抛异常', () {
      final items = List.generate(3, (i) => i);
      final range = EpisodeRange(
        label: '99-100',
        start: 99,
        end: 100,
        selected: true,
      );
      expect(EpisodeRangePolicy.slice(items, range), isEmpty);
    });
  });

  group('selectedPosition', () {
    test('返回被标记区间的下标', () {
      final ranges = EpisodeRangePolicy.build(400, 120, false);
      expect(EpisodeRangePolicy.selectedPosition(ranges), 2);
    });

    test('空列表 → 0', () {
      expect(EpisodeRangePolicy.selectedPosition(const []), 0);
    });
  });

  group('segmentIndex / segmentStart', () {
    test('按固定段长取段号与段首', () {
      expect(EpisodeRangePolicy.segmentIndex(100, 25, 20), 1);
      expect(EpisodeRangePolicy.segmentStart(100, 25, 20), 20);
      expect(EpisodeRangePolicy.segmentIndex(100, 99, 20), 4);
    });

    test('上游锚点：segmentStart(131, 82, 40) == 80', () {
      expect(EpisodeRangePolicy.segmentStart(131, 82, 40), 80);
      expect(EpisodeRangePolicy.segmentIndex(131, 82, 40), 2);
    });

    test('越界与零段长不抛异常', () {
      expect(EpisodeRangePolicy.segmentIndex(0, 5, 20), 0);
      expect(EpisodeRangePolicy.segmentIndex(10, 99, 20), 0);
      expect(EpisodeRangePolicy.segmentStart(10, -3, 0), 0);
    });

    test('上游锚点：越界选中被夹住', () {
      expect(EpisodeRangePolicy.segmentIndex(0, -1, 40), 0);
      expect(EpisodeRangePolicy.segmentIndex(131, -1, 40), 0);
      expect(EpisodeRangePolicy.segmentIndex(131, 999, 40), 3);
    });
  });

  group('withSelected', () {
    test('只改 selected，其余字段不变', () {
      const range = EpisodeRange(label: '1-20', start: 0, end: 20, selected: false);
      final next = range.withSelected(true);
      expect(next.label, '1-20');
      expect(next.start, 0);
      expect(next.end, 20);
      expect(next.selected, isTrue);
      expect(range.selected, isFalse, reason: '原对象不可变');
    });
  });

  group('季度过滤为空时回退全部集（design/03 §5.2）', () {
    VodEpisode episodeOf(String name) =>
        VodEpisode(name: name, url: 'http://x/$name');

    test('过滤结果非空时按季度过滤', () {
      final episodes = [
        episodeOf('第1季第1集'),
        episodeOf('第2季第1集'),
      ];
      final result = TmdbEpisodeRenderPolicy.filter(
        episodes: episodes,
        availableSeasons: const [1, 2],
        selectedSeason: 1,
        seasonOf: (episode) => episode.name.startsWith('第2季') ? 2 : 1,
      );
      expect(result.length, 1);
      expect(result.single.name, '第1季第1集');
    });

    test('过滤结果为空时回退全部集，不显示空白', () {
      final episodes = [
        episodeOf('第1季第1集'),
        episodeOf('第1季第2集'),
      ];
      final result = TmdbEpisodeRenderPolicy.filter(
        episodes: episodes,
        availableSeasons: const [1, 2],
        selectedSeason: 2,
        // 全部集都判为 S1 → 选 S2 时过滤结果为空。
        seasonOf: (_) => 1,
      );
      expect(
        result.length,
        2,
        reason: '宁可显示"可能不对季"的集，也不能显示空白（不丢集纪律）',
      );
    });

    test('availableSeasons 为空时返回全部', () {
      final episodes = [episodeOf('第1集')];
      final result = TmdbEpisodeRenderPolicy.filter(
        episodes: episodes,
        availableSeasons: const [],
        selectedSeason: 1,
        seasonOf: (_) => -1,
      );
      expect(result.length, 1);
    });

    // 未分类的集（season < 0）永远保留（`02` §9.4「不丢集」）。
    test('未分类的集永远保留', () {
      final episodes = [
        episodeOf('已分类'),
        episodeOf('未分类'),
      ];
      final result = TmdbEpisodeRenderPolicy.filter(
        episodes: episodes,
        availableSeasons: const [1, 2],
        selectedSeason: 1,
        seasonOf: (e) => e.name == '未分类' ? -1 : 1,
      );
      expect(result.length, 2);
    });

    // 回退时**不得**丢掉顺序与同一性（不是重新排序，是原列表）。
    test('回退时返回的仍是原列表实例（顺序与同一性不变）', () {
      final episodes = [
        episodeOf('第1季第1集'),
        episodeOf('第1季第2集'),
      ];
      final result = TmdbEpisodeRenderPolicy.filter(
        episodes: episodes,
        availableSeasons: const [1, 2],
        selectedSeason: 2,
        seasonOf: (_) => 1,
      );
      expect(identical(result, episodes), isTrue);
    });

    test('空输入 + 非空季度 → 仍是空（不抛异常）', () {
      expect(
        TmdbEpisodeRenderPolicy.filter(
          episodes: const [],
          availableSeasons: const [1],
          selectedSeason: 1,
          seasonOf: (_) => 1,
        ),
        isEmpty,
      );
    });
  });
}
