import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/episode_aggregation.dart';
import 'package:webhtv_pc/core/episode_manual_match.dart';
import 'package:webhtv_pc/core/protocol.dart';

/// 线路集名：第1集 .. 第N集（聚合组与源顺序一一对应）。
List<String> numbered(int count) => [
  for (var i = 1; i <= count; i++) '第$i集',
];

List<EpisodeGroup> groupsOf(List<String> names) => EpisodeAggregation.build([
  for (var i = 0; i < names.length; i++)
    VodEpisode(name: names[i], url: 'url-$i'),
], scope: 'line');

EpisodeMatchTarget target(int season, int episode) =>
    EpisodeMatchTarget(seasonNumber: season, episodeNumber: episode);

EpisodeMatchAnchor anchor(
  int index,
  String name,
  int season,
  int episode, {
  bool spread = true,
}) => EpisodeMatchAnchor(
  sourceIndex: index,
  sourceName: name,
  seasonNumber: season,
  episodeNumber: episode,
  spread: spread,
);

void main() {
  test('顺延：锚点组之后逐组 +1，锚点之前不受影响', () {
    final groups = groupsOf(numbered(6));
    final targets = EpisodeManualMatch.resolve(
      groups: groups,
      anchors: [anchor(2, '第3集', 1, 3)],
      seasonEpisodeCounts: const {1: 6},
    );
    expect(targets.containsKey(0), isFalse);
    expect(targets.containsKey(1), isFalse);
    expect(targets[2], target(1, 3));
    expect(targets[3], target(1, 4));
    expect(targets[5], target(1, 6));
  });

  test('顺延到下一个锚点即让位', () {
    final groups = groupsOf(numbered(6));
    final targets = EpisodeManualMatch.resolve(
      groups: groups,
      anchors: [
        anchor(0, '第1集', 1, 1),
        anchor(3, '第4集', 1, 9),
      ],
      seasonEpisodeCounts: const {1: 20},
    );
    expect(targets[0], target(1, 1));
    expect(targets[2], target(1, 3));
    expect(targets[3], target(1, 9));
    expect(targets[5], target(1, 11));
  });

  test('仅此一集：spread=false 只绑锚点所在组', () {
    final groups = groupsOf(numbered(5));
    final targets = EpisodeManualMatch.resolve(
      groups: groups,
      anchors: [anchor(2, '第3集', 1, 3, spread: false)],
      seasonEpisodeCounts: const {1: 5},
    );
    expect(targets.length, 1);
    expect(targets[2], target(1, 3));
  });

  test('跨季顺延：本季集数用尽进下一季第 1 集', () {
    final groups = groupsOf(numbered(12));
    final targets = EpisodeManualMatch.resolve(
      groups: groups,
      anchors: [anchor(8, '第9集', 1, 9)],
      seasonEpisodeCounts: const {1: 10, 2: 10},
    );
    expect(targets[8], target(1, 9));
    expect(targets[9], target(1, 10));
    expect(targets[10], target(2, 1));
    expect(targets[11], target(2, 2));
  });

  test('季集数缺失时顺延到此为止，超出部分不绑定', () {
    final groups = groupsOf(numbered(6));
    final targets = EpisodeManualMatch.resolve(
      groups: groups,
      anchors: [anchor(2, '第3集', 1, 3)],
      seasonEpisodeCounts: const {},
    );
    expect(targets.length, 1);
    expect(targets[2], target(1, 3));
  });

  test('聚合组内所有版本共享同一目标', () {
    final groups = groupsOf(['第1集', '第1集', '第2集']);
    expect(groups.first.versions.length, 2);
    final targets = EpisodeManualMatch.resolve(
      groups: groups,
      anchors: [anchor(1, '第1集', 2, 5)],
      seasonEpisodeCounts: const {2: 10},
    );
    expect(targets[0], target(2, 5));
    expect(targets[1], target(2, 5));
    expect(targets[2], target(2, 6));
  });

  test('冲突允许并存，并能标出重复的源下标', () {
    final groups = groupsOf(numbered(4));
    final targets = EpisodeManualMatch.resolve(
      groups: groups,
      anchors: [
        anchor(0, '第1集', 1, 1, spread: false),
        anchor(2, '第3集', 1, 1, spread: false),
      ],
      seasonEpisodeCounts: const {1: 4},
    );
    expect(targets[0], target(1, 1));
    expect(targets[2], target(1, 1));
    expect(EpisodeManualMatch.duplicateIndexes(targets), {0, 2});
  });

  test('顺序变化后按源集名重定位', () {
    final reordered = groupsOf(['第1集', '第3集', '第2集', '第4集']);
    final dropped = <int>{};
    final anchors = EpisodeManualMatch.relocate(
      groups: reordered,
      anchors: [anchor(1, '第2集', 1, 2)],
      dropped: dropped,
    );
    expect(dropped, isEmpty);
    expect(anchors.single.sourceIndex, 2);
    expect(anchors.single.sourceName, '第2集');
    expect(anchors.single.episodeNumber, 2);
  });

  test('锚点对应的源集消失则丢弃并计入 dropped', () {
    final groups = groupsOf(['第1集', '第3集']);
    final dropped = <int>{};
    final anchors = EpisodeManualMatch.relocate(
      groups: groups,
      anchors: [anchor(1, '第2集', 1, 2)],
      dropped: dropped,
    );
    expect(anchors, isEmpty);
    expect(dropped, {1});
  });

  test('综艺判定只认类型集合，不认来源集名', () {
    expect(EpisodeManualMatch.isVariety(const ['真人秀']), isTrue);
    expect(EpisodeManualMatch.isVariety(const ['Talk']), isTrue);
    expect(EpisodeManualMatch.isVariety(const ['剧情', 'Drama']), isFalse);
    expect(EpisodeManualMatch.isVariety(const []), isFalse);
  });

  test('集号文案：综艺用「期」，多季带季号；非综艺沿用 S/E', () {
    expect(
      EpisodeManualMatch.unitLabel(
        variety: true,
        seasonNumber: 1,
        episodeNumber: 3,
        compact: true,
      ),
      '第3期',
    );
    expect(
      EpisodeManualMatch.unitLabel(
        variety: true,
        seasonNumber: 1,
        episodeNumber: 3,
      ),
      '第 3 期',
    );
    expect(
      EpisodeManualMatch.unitLabel(
        variety: true,
        seasonNumber: 2,
        episodeNumber: 3,
        compact: true,
      ),
      'S2 第3期',
    );
    expect(
      EpisodeManualMatch.unitLabel(
        variety: false,
        seasonNumber: 1,
        episodeNumber: 3,
      ),
      'S1E3',
    );
    expect(
      EpisodeManualMatch.unitLabel(
        variety: false,
        seasonNumber: -1,
        episodeNumber: 3,
      ),
      'E3',
    );
  });

  test('锚点 JSON 往返（spread 缺省视为顺延）', () {
    final source = anchor(4, '第5集', 2, 7, spread: false);
    final decoded = EpisodeMatchAnchor.fromJson(source.toJson());
    expect(decoded, source);
    final legacy = EpisodeMatchAnchor.fromJson({
      'sourceIndex': 1,
      'sourceName': '第2集',
      'seasonNumber': 1,
      'episodeNumber': 2,
    });
    expect(legacy!.spread, isTrue);
    expect(EpisodeMatchAnchor.listFromJson([source.toJson(), 'junk']), [
      source,
    ]);
  });
}
