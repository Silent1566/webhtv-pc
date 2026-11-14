/// 观影报告 v2 固定 fixture。
///
/// 一份记录 + 元数据故事，同时供 UI 断言与 Before/After 截图使用：
/// 同一批记录、同一个「现在」、同一套主题与视口，两份截图才可比。
///
/// 故事要点（每条都在测试里被断言到）：
/// - 四个偏好维度都有真实数据：题材 / 地区 / 演员 / 导演；
/// - 地区覆盖 5 个真实不同地区（中国 / 美国 / 韩国 / 日本 / 英国）→ 探索者徽章；
/// - 三类站源：URL 型 sourceKey、本机配置文件路径型 sourceKey、空串（来源不明）；
/// - 电影 / 剧集 / 未知类型三种都有，未知不进类型统计；
/// - 有记录完全没有元数据（未知就是未知，不猜）；
/// - 中英文超长标题，用来验证截断/换行不压数值；
/// - 20 条记录跨两周、覆盖全部 7 个星期几与深夜/清晨/上午/下午/晚上。
library;

import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/core/viewing_metadata.dart';

/// 固定「现在」：2026-10-21（周三）12:00。
///
/// fixture 里的记录全部落在这之前的 2026-10-12（周一）—2026-10-21 之间，
/// 因此「全部 / 本周 / 最近7天 / 本月 / 本季度 / 本年 / 下半年」都有数据，
/// 「上半年」为空态，「全部」没有上一周期。
final DateTime viewingReportFixtureNow = DateTime(2026, 10, 21, 12);

const int _minuteMs = 60 * 1000;

/// URL 型 sourceKey：界面绝不能把它整条渲染出来。
const String fixtureUrlSourceKey =
    'https://tvbox.example.com/api.php/provide/vod/at/json';
const String fixtureFileSourceKey =
    r'C:\Users\demo\WebHTV\configs\my-tvbox.json';
const String fixtureCatSourceKey = 'https://cdn.example.net/cat.json';

PlaybackHistory _row({
  required int id,
  required String siteKey,
  String sourceKey = '',
  required String vodName,
  required String episodeName,
  required int positionMinutes,
  required int durationMinutes,
  required DateTime watchedAt,
  String vodId = '',
  String mediaType = '',
  int tmdbId = 0,
  String vodYear = '',
}) => PlaybackHistory(
  id: id,
  siteKey: siteKey,
  vodId: vodId.isEmpty ? vodName : vodId,
  vodName: vodName,
  flag: '线路一',
  episodeName: episodeName,
  episodeId: episodeName,
  positionMs: positionMinutes * _minuteMs,
  durationMs: durationMinutes * _minuteMs,
  updatedAt: watchedAt.millisecondsSinceEpoch,
  sourceKey: sourceKey,
  vodYear: vodYear,
  tmdbId: tmdbId,
  mediaType: mediaType,
);

/// 同一个「站源 + 来源」下的作品分组，便于阅读故事。
final List<PlaybackHistory> viewingReportFixtureRecords = <PlaybackHistory>[
  // ---- 站源 main（URL 型 sourceKey）：庆余年 · 流浪地球 ----
  _row(
    id: 101,
    siteKey: 'main',
    sourceKey: fixtureUrlSourceKey,
    vodName: '庆余年',
    vodId: 'qingyuannian',
    mediaType: 'tv',
    vodYear: '2019',
    episodeName: '第1集',
    positionMinutes: 42,
    durationMinutes: 45,
    watchedAt: DateTime(2026, 10, 12, 20, 15),
  ),
  _row(
    id: 102,
    siteKey: 'main',
    sourceKey: fixtureUrlSourceKey,
    vodName: '庆余年',
    vodId: 'qingyuannian',
    mediaType: 'tv',
    vodYear: '2019',
    episodeName: '第2集',
    positionMinutes: 45,
    durationMinutes: 45,
    watchedAt: DateTime(2026, 10, 12, 21, 5),
  ),
  _row(
    id: 103,
    siteKey: 'main',
    sourceKey: fixtureUrlSourceKey,
    vodName: '庆余年',
    vodId: 'qingyuannian',
    mediaType: 'tv',
    vodYear: '2019',
    episodeName: '第3集',
    positionMinutes: 40,
    durationMinutes: 45,
    watchedAt: DateTime(2026, 10, 17, 20, 0),
  ),
  _row(
    id: 104,
    siteKey: 'main',
    sourceKey: fixtureUrlSourceKey,
    vodName: '庆余年',
    vodId: 'qingyuannian',
    mediaType: 'tv',
    vodYear: '2019',
    episodeName: '第4集',
    positionMinutes: 44,
    durationMinutes: 45,
    watchedAt: DateTime(2026, 10, 19, 20, 30),
  ),
  _row(
    id: 105,
    siteKey: 'main',
    sourceKey: fixtureUrlSourceKey,
    vodName: '流浪地球',
    vodId: 'wandering-earth',
    mediaType: 'movie',
    vodYear: '2019',
    episodeName: '正片',
    positionMinutes: 120,
    durationMinutes: 125,
    watchedAt: DateTime(2026, 10, 13, 22, 40),
  ),
  _row(
    id: 106,
    siteKey: 'main',
    sourceKey: fixtureUrlSourceKey,
    vodName: '流浪地球',
    vodId: 'wandering-earth',
    mediaType: 'movie',
    vodYear: '2019',
    episodeName: '正片',
    positionMinutes: 125,
    durationMinutes: 125,
    watchedAt: DateTime(2026, 10, 20, 23, 10),
  ),

  // ---- 站源 local（本机配置文件路径型 sourceKey）：老友记 · 请回答1988 ----
  _row(
    id: 107,
    siteKey: 'local',
    sourceKey: fixtureFileSourceKey,
    vodName: '老友记',
    vodId: 'friends',
    mediaType: 'tv',
    vodYear: '1994',
    episodeName: 'S1E1',
    positionMinutes: 18,
    durationMinutes: 22,
    watchedAt: DateTime(2026, 10, 14, 8, 10),
  ),
  _row(
    id: 108,
    siteKey: 'local',
    sourceKey: fixtureFileSourceKey,
    vodName: '老友记',
    vodId: 'friends',
    mediaType: 'tv',
    vodYear: '1994',
    episodeName: 'S1E2',
    positionMinutes: 22,
    durationMinutes: 22,
    watchedAt: DateTime(2026, 10, 18, 9, 0),
  ),
  _row(
    id: 109,
    siteKey: 'local',
    sourceKey: fixtureFileSourceKey,
    vodName: '老友记',
    vodId: 'friends',
    mediaType: 'tv',
    vodYear: '1994',
    episodeName: 'S1E3',
    positionMinutes: 20,
    durationMinutes: 22,
    watchedAt: DateTime(2026, 10, 15, 7, 30),
  ),
  _row(
    id: 110,
    siteKey: 'local',
    sourceKey: fixtureFileSourceKey,
    vodName: '请回答1988',
    vodId: 'reply-1988',
    mediaType: 'tv',
    vodYear: '2015',
    episodeName: '第1集',
    positionMinutes: 80,
    durationMinutes: 90,
    watchedAt: DateTime(2026, 10, 14, 23, 30),
  ),
  _row(
    id: 111,
    siteKey: 'local',
    sourceKey: fixtureFileSourceKey,
    vodName: '请回答1988',
    vodId: 'reply-1988',
    mediaType: 'tv',
    vodYear: '2015',
    episodeName: '第2集',
    positionMinutes: 85,
    durationMinutes: 90,
    watchedAt: DateTime(2026, 10, 19, 9, 30),
  ),
  _row(
    id: 112,
    siteKey: 'local',
    sourceKey: fixtureFileSourceKey,
    vodName: '请回答1988',
    vodId: 'reply-1988',
    mediaType: 'tv',
    vodYear: '2015',
    episodeName: '第3集',
    positionMinutes: 70,
    durationMinutes: 90,
    watchedAt: DateTime(2026, 10, 19, 23, 50),
  ),

  // ---- 来源不明（sourceKey 空串）：千与千寻 · 超长英文名 ----
  _row(
    id: 113,
    siteKey: 'main',
    vodName: '千与千寻',
    vodId: 'spirited-away',
    mediaType: 'movie',
    vodYear: '2001',
    episodeName: '正片',
    positionMinutes: 118,
    durationMinutes: 125,
    watchedAt: DateTime(2026, 10, 15, 14, 0),
  ),
  _row(
    id: 114,
    siteKey: 'main',
    vodName: '千与千寻',
    vodId: 'spirited-away',
    mediaType: 'movie',
    vodYear: '2001',
    episodeName: '正片',
    positionMinutes: 40,
    durationMinutes: 125,
    watchedAt: DateTime(2026, 10, 20, 7, 0),
  ),
  _row(
    id: 115,
    siteKey: 'main',
    vodName: 'The Extraordinarily Long English Title of a Documentary About Deep Sea Creatures',
    vodId: 'deep-sea-doc',
    mediaType: 'movie',
    episodeName: 'Director Cut',
    positionMinutes: 60,
    durationMinutes: 96,
    watchedAt: DateTime(2026, 10, 17, 11, 0),
  ),
  _row(
    id: 116,
    siteKey: 'main',
    vodName: 'The Extraordinarily Long English Title of a Documentary About Deep Sea Creatures',
    vodId: 'deep-sea-doc',
    mediaType: 'movie',
    episodeName: 'Director Cut',
    positionMinutes: 96,
    durationMinutes: 96,
    watchedAt: DateTime(2026, 10, 21, 10, 20),
  ),

  // ---- 超长中文标题 ----
  _row(
    id: 117,
    siteKey: 'local',
    sourceKey: fixtureFileSourceKey,
    vodName: '我在人民广场吃着炸鸡顺便看完了这部四十八集的国产谍战大剧',
    vodId: 'long-cn',
    mediaType: 'tv',
    episodeName: '第7集',
    positionMinutes: 30,
    durationMinutes: 45,
    watchedAt: DateTime(2026, 10, 16, 19, 30),
  ),

  // ---- 完全未知来源（cat 配置）：元数据缺失，类型未知 ----
  _row(
    id: 118,
    siteKey: 'cat',
    sourceKey: fixtureCatSourceKey,
    vodName: '未知站源的综艺节目',
    vodId: 'unknown-1',
    episodeName: '第3期',
    positionMinutes: 20,
    durationMinutes: 45,
    watchedAt: DateTime(2026, 10, 18, 2, 15),
  ),
  _row(
    id: 119,
    siteKey: 'cat',
    sourceKey: fixtureCatSourceKey,
    vodName: '未知站源的综艺节目',
    vodId: 'unknown-1',
    episodeName: '第4期',
    positionMinutes: 15,
    durationMinutes: 40,
    watchedAt: DateTime(2026, 10, 18, 21, 0),
  ),
  _row(
    id: 120,
    siteKey: 'cat',
    sourceKey: fixtureCatSourceKey,
    vodName: '没抓到详情的短剧',
    vodId: 'unknown-2',
    episodeName: '第1集',
    positionMinutes: 5,
    durationMinutes: 30,
    watchedAt: DateTime(2026, 10, 21, 11, 15),
  ),
];

final Map<int, ViewingMetadata> viewingReportFixtureMetadata = {
  for (final id in [101, 102, 103, 104])
    id: const ViewingMetadata(
      genres: ['剧情', '古装'],
      areas: ['中国'],
      actors: ['张若昀', '李沁'],
      directors: ['孙皓'],
      mediaType: 'tv',
    ),
  for (final id in [105, 106])
    id: const ViewingMetadata(
      genres: ['科幻', '冒险'],
      areas: ['中国'],
      actors: ['吴京'],
      directors: ['郭帆'],
      mediaType: 'movie',
    ),
  for (final id in [107, 108, 109])
    id: const ViewingMetadata(
      genres: ['喜剧'],
      areas: ['美国'],
      actors: [
        'Jennifer Aniston — an extraordinarily long performer name',
        'Courteney Cox',
      ],
      directors: ['James Burrows'],
      mediaType: 'tv',
    ),
  for (final id in [110, 111, 112])
    id: const ViewingMetadata(
      genres: ['剧情', '家庭'],
      areas: ['韩国'],
      actors: ['朴宝剑', '李惠利'],
      directors: ['申元浩'],
      mediaType: 'tv',
    ),
  for (final id in [113, 114])
    id: const ViewingMetadata(
      genres: ['动画', '奇幻'],
      areas: ['日本'],
      actors: ['柊瑠美'],
      directors: ['宫崎骏'],
      mediaType: 'movie',
    ),
  for (final id in [115, 116])
    id: const ViewingMetadata(
      genres: ['纪录片'],
      areas: ['英国'],
      directors: [
        'A Very Long Director Name That Must Not Cover the Frequency Value',
      ],
      mediaType: 'movie',
    ),
  117: const ViewingMetadata(genres: ['悬疑'], areas: ['中国'], mediaType: 'tv'),
};
