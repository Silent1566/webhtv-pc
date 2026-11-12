/// 详情页区块节奏门禁（用户反馈 2026-11-12：「各行上下的间距乱七八糟」）。
///
/// 只锁一件事：**区块之间只有一种间距**。它由下一个区块的 `SectionHeader`
/// （上 24 / 下 10）承担，区块自己**不得**再补一条 `SizedBox` 或一条 `Divider`
/// ——两边都加得到 48、漏加得到 0，这正是同一页里间距忽大忽小的来源。
///
/// 台账（2026-11-12 定稿）：
/// - 线路 → 选集：10（线路是选集的上下文，不是独立区块）；
/// - 选集 → 剧照 → 海报 → 演职人员 → 制作团队 → 相关视频 → 外部链接：24；
/// - 区块之间**没有**分隔线（深色底上那是一条亮线，看起来像内容被撕开）。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/detail_ratings.dart';
import 'package:webhtv_pc/core/episode_range.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_detail_model.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/tmdb_media.dart';
import 'package:webhtv_pc/ui/detail_ratings_section.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tmdb_detail_view.dart';
import 'package:webhtv_pc/ui/tmdb_widgets.dart';
import 'package:webhtv_pc/ui/tokens.dart';

import 'support/test_fonts.dart';

const _poster = 'https://fixture.test/poster.png';
const _still = 'https://fixture.test/still.png';

/// 区块头到自身内容的下内边距（`SectionHeader` / 选集头 / 线路条共用）。
const _headerBottom = 10.0;

const _request = DetailRatingRequest(
  tmdbId: 1399,
  title: '节奏样例',
  year: 2024,
  mediaType: TmdbMediaType.tv,
  imdbId: 'tt1234567',
);

TmdbDetailData _data() => const TmdbDetailData(
  tmdbId: 1399,
  title: '节奏样例',
  overview: '用于量区块间距的固定夹具。',
  posterUrl: _poster,
  photoUrls: [_still, _still],
  // 长度 > 1 才渲染「海报」区块。
  posterUrls: [_poster, _poster],
  cast: [
    TmdbPerson(personId: 1, name: '演员甲'),
    TmdbPerson(personId: 2, name: '演员乙'),
  ],
  creatorTeam: [TmdbPerson(personId: 3, name: '导演甲', subtitle: '导演')],
  rating: 8.4,
);

const _videos = [
  TmdbVideo(id: 'v1', key: 'k1', site: 'YouTube', name: '预告片', type: 'Trailer'),
  TmdbVideo(id: 'v2', key: 'k2', site: 'YouTube', name: '幕后', type: 'Featurette'),
];

List<VodPlayLine> _lines() => [
  VodPlayLine(
    flag: '高清线路',
    episodes: [VodEpisode(name: '第1集', url: 'https://fixture.test/1.mp4')],
  ),
];

List<TmdbEpisodeCard> _cards() => [
  TmdbEpisodeCard(number: 1, title: '第1集', runtime: 45),
  TmdbEpisodeCard(number: 2, title: '第2集', runtime: 45),
];

/// 区间分组（>1 时才渲染区间条，正是用户反馈「分组按钮离卡片太远」的那一块）。
const _ranges = [
  EpisodeRange(label: '1', start: 0, end: 1, selected: true),
  EpisodeRange(label: '2', start: 1, end: 2, selected: false),
];

Widget _page({Key? captureKey}) {
  final theme = buildAppTheme(Brightness.dark);
  return MaterialApp(
    theme: theme.copyWith(
      textTheme: theme.textTheme.apply(fontFamily: 'FixtureCJK'),
    ),
    home: RepaintBoundary(
      key: captureKey,
      child: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TmdbLineSelector(
                  lines: _lines(),
                  selectedFlag: '高清线路',
                  episodeCounts: const {'高清线路': 1},
                  onChanged: (_) {},
                  onSwapSource: () {},
                ),
                // 与站点页的真实组合一致：区块头 + 带区间条的卡片条。
                TmdbEpisodeHeader(
                  episodeCount: 2,
                  reversed: false,
                  gridMode: false,
                  onToggleReversed: () {},
                  onToggleGridMode: () {},
                ),
                TmdbEpisodeStrip(
                  key: const ValueKey('rhythm-episode-section'),
                  cards: _cards(),
                  keyPrefix: 'rhythm-episode',
                  ranges: _ranges,
                  rangeIndex: 0,
                  onRangeChanged: (_) {},
                ),
                TmdbDetailSections(
                  data: _data(),
                  videos: _videos,
                  onPersonTap: (_) {},
                  onRecommendationTap: (_) {},
                  onOpenVideo: (url) async => true,
                  onCopyVideo: (url) async {},
                ),
                DetailRatingsSection(
                  request: _request,
                  keyPrefix: 'rhythm-ratings',
                  onOpen: (url) async => true,
                  onCopy: (url) async {},
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// 下沿到上沿：就是「两个区块之间露出来的那条缝」。
double _gap(WidgetTester tester, Finder above, Finder below) =>
    tester.getRect(below).top - tester.getRect(above).bottom;

/// 区块标题的**文字**（不是那个带内边距的 `Padding` 外框）。
///
/// 必须量文字：`SectionHeader` 的 24 上留白在 `Padding` **里面**，量外框只会
/// 得到 0，量文字才是眼睛看到的那条缝（= 24）。
Finder _title(String key) => find
    .descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text))
    .first;

Future<void> _pump(WidgetTester tester, {Key? captureKey, double height = 2000}) async {
  tester.view.physicalSize = Size(1280, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_page(captureKey: captureKey));
  // 图片按网络加载（`PosterImage` 自带 errorBuilder 占位），等它们落地。
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await loadFixtureFonts();
    reportFixtureFonts();
  });

  testWidgets('区块之间没有分隔线（2026-11-12 用户反馈）', (tester) async {
    await _pump(tester);
    expect(tester.takeException(), isNull);
    expect(
      find.byType(Divider),
      findsNothing,
      reason: '深色底上的 Divider 是一条亮线，会把「选集 / 剧照」「推荐 / 外部链接」切成两段',
    );
  });

  testWidgets('区块间距统一：线路 → 选集 24，标题 → 内容 10', (tester) async {
    await _pump(tester);

    final lineSelector = find.byKey(const ValueKey('tmdb-line-selector'));
    final episodeHeader = find.byKey(const ValueKey('tmdb-episode-header'));
    final episodeStrip = find.byKey(const ValueKey('rhythm-episode-section'));
    final photosWall = find.byKey(const ValueKey('tmdb-photo-wall')).first;
    final postersWall = find.byKey(const ValueKey('tmdb-photo-wall')).last;
    final peopleWall = find.byKey(const ValueKey('tmdb-people-wall'));
    final crewWall = find.byKey(const ValueKey('tmdb-crew-wall'));
    final lastVideo = find.byKey(const ValueKey('tmdb-video-YouTube|k2'));

    // 线路条与选集头都**自带**下内边距（10），所以两者外框之间必然是 0：
    // 视觉上的那条缝就是它们自己的 padding。这里直接锁 padding 值。
    expect(
      tester.widget<Padding>(lineSelector).padding,
      const EdgeInsets.only(bottom: AppSpace.xl),
      reason: '线路 → 选集是**两个**区块，缝与其它区块一致为 24',
    );
    // 线路条 → 选集标题：24（线路的内容是它自己的 chip 行）。
    expect(
      _gap(tester, find.byKey(const ValueKey('tmdb-line-高清线路')), find.text('选集 · 2 集')),
      closeTo(AppSpace.xl, 1.0),
      reason: '线路 chip → 选集标题',
    );
    // 选集标题 → 内容：10（区块头到自身内容的下 10）。
    expect(
      _gap(tester, find.text('选集 · 2 集'), episodeStrip),
      closeTo(_headerBottom, 1.0),
      reason: '选集标题 → 区间条（视图顶部）',
    );
    // 区间 chip → 卡片：4（条高已收紧到 chip 高度，不再被 48 的点击区撑开）。
    expect(
      _gap(
        tester,
        find.byKey(const ValueKey('rhythm-episode-range-0')),
        find.byKey(const ValueKey('rhythm-episode-0')),
      ),
      closeTo(AppSpace.xs, 1.5),
      reason: '区间按钮 → 卡片',
    );
    expect(
      tester.widget<Padding>(episodeHeader).padding,
      const EdgeInsets.only(bottom: _headerBottom),
      reason: '选集头 → 卡片：与 SectionHeader 的下 10 同一口径',
    );
    // 容差 1px：文字高度由排版引擎给出，可能有亚像素差。
    void expectGap(Finder above, Finder below, String reason) => expect(
      _gap(tester, above, below),
      closeTo(AppSpace.xl, 1.0),
      reason: reason,
    );

    expectGap(episodeStrip, _title('tmdb-section-photos'), '选集 → 剧照');
    expectGap(photosWall, _title('tmdb-section-posters'), '剧照 → 海报');
    expectGap(postersWall, _title('tmdb-section-people'), '海报 → 演职人员');
    expectGap(peopleWall, _title('tmdb-section-crew'), '演职人员 → 制作团队');
    expectGap(crewWall, _title('tmdb-section-videos'), '制作团队 → 相关视频');
    expectGap(lastVideo, _title('rhythm-ratings-section'), '相关视频 → 外部链接');
  });

  testWidgets('区间条 → 卡片不吃 MediaQuery 内边距（AppBar 下的 56px）', (tester) async {
    // 详情页在 AppBar 下，`MediaQuery.padding.top` 是 56。垂直、无 controller 的
    // GridView 是 primary 滚动视图，会把这段 padding 当成自己的内边距——区间条与
    // 第一行卡片之间就会凭空多出 56px（用户 2026-11-12 反馈「间隔太大」）。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(padding: EdgeInsets.only(top: 56)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TmdbEpisodeStrip(
                  cards: _cards(),
                  keyPrefix: 'pad',
                  ranges: _ranges,
                  rangeIndex: 0,
                  onRangeChanged: (_) {},
                  gridMode: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      _gap(
        tester,
        find.byKey(const ValueKey('pad-range-0')),
        find.byKey(const ValueKey('pad-0')),
      ),
      closeTo(AppSpace.xs, 0.5),
      reason: '区间 chip → 第一行卡片只隔 4：GridView 必须 padding zero + primary false',
    );
  });

  testWidgets('状态条只写季度，不再重复评分', (tester) async {
    expect(
      tmdbStatusSummary(title: '剧名', isTv: true, selectedSeason: 1),
      'TMDB · 剧名 · 第 1 季',
    );
    expect(
      tmdbStatusSummary(title: '剧名', isTv: true, selectedSeason: 0),
      'TMDB · 剧名 · 特别篇',
    );
    expect(
      tmdbStatusSummary(title: '剧名', isTv: false, selectedSeason: 2),
      'TMDB · 剧名',
      reason: '电影没有季度',
    );
    expect(
      tmdbStatusSummary(title: '剧名', isTv: true, selectedSeason: -1),
      'TMDB · 剧名 · 季度待定',
      reason: '季度未确定时不写假季度，但也不能装作季度不存在',
    );
  });

  testWidgets('capture 节奏整页', (tester) async {
    final capture = Platform.environment['DETAIL_RHYTHM_CAPTURE'] ?? '';
    final boundary = GlobalKey();
    // 只截「线路 / 选集 / 卡片」这一段，方便和用户反馈的局部截图对照。
    await _pump(tester, captureKey: boundary, height: 440);
    if (capture.isEmpty) return;
    await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('../../.local/detail-rhythm/rhythm-dark.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  });
}
