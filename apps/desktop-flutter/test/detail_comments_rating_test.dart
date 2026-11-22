/// 短评星级（用户反馈 2026-11-22）：10 分制 → 半星步进 → 五颗星图标。
///
/// 直接 pump [ExternalCommentsSection] 而不是整页：这几条断言只关心「一条短评
/// 怎么长」，拉整页进来会让每次失败都先落在网络 mock 上。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/external_detail_meta.dart';
import 'package:webhtv_pc/core/meta_source.dart';
import 'package:webhtv_pc/ui/detail_comments_section.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tokens.dart';

ExternalComment _comment({
  double rating = 0,
  double maxRating = 10,
  MetaSourceKind source = MetaSourceKind.douban,
  String text = '节奏慢但后劲足，范伟的表演撑住了整部剧。',
  String author = '江户川乱跑',
  int votes = 12,
  String date = '2023-04-23 21:10:00',
}) => ExternalComment(
  source: source,
  author: author,
  text: text,
  rating: rating,
  maxRating: maxRating,
  votes: votes,
  date: date,
);

/// 1280×950、暗色（主身份），与详情页的出图条件一致。
Future<void> _pump(WidgetTester tester, Widget section) async {
  tester.view.physicalSize = const Size(1280, 950);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: section,
        ),
      ),
    ),
  );
  await tester.pump();
}

/// 第 [i] 条评分行里的图标，按渲染顺序。
List<IconData?> _starsAt(WidgetTester tester, int i) => tester
    .widgetList<Icon>(
      find.descendant(
        of: find.byKey(ValueKey('detail-comment-rating-$i')),
        matching: find.byType(Icon),
      ),
    )
    .map((icon) => icon.icon)
    .toList();

String? _scoreAt(WidgetTester tester, int i) =>
    tester.widget<Text>(find.byKey(ValueKey('detail-comment-score-$i'))).data;

void main() {
  const full = Icons.star_rounded;
  const half = Icons.star_half_rounded;
  const empty = Icons.star_outline_rounded;

  group('模型：10 分制 → 半星步进', () {
    test('3.5/5 → 7', () {
      expect(_comment(rating: 3.5, maxRating: 5).ratingHalfStars, 7);
    });

    test('5/5 → 10', () {
      expect(_comment(rating: 5, maxRating: 5).ratingHalfStars, 10);
    });

    test('未评分 → 0', () {
      expect(_comment().ratingHalfStars, 0);
      expect(_comment(rating: 0, maxRating: 5).ratingHalfStars, 0);
    });

    test('12/10 超量纲 → clamp 到 10', () {
      expect(_comment(rating: 12, maxRating: 10).ratingHalfStars, 10);
    });
  });

  group('星级行', () {
    testWidgets('5/5 → 5 实心、0 空心、0 半星，分数 10.0', (tester) async {
      await _pump(
        tester,
        ExternalCommentsSection(
          page: ExternalCommentPage(comments: [_comment(rating: 5, maxRating: 5)]),
        ),
      );
      expect(_starsAt(tester, 0), [full, full, full, full, full]);
      expect(_scoreAt(tester, 0), '10.0');
    });

    testWidgets('4/5 → 4 实心 + 1 空心，无半星，分数 8.0', (tester) async {
      await _pump(
        tester,
        ExternalCommentsSection(
          page: ExternalCommentPage(comments: [_comment(rating: 4, maxRating: 5)]),
        ),
      );
      expect(_starsAt(tester, 0), [full, full, full, full, empty]);
      expect(_scoreAt(tester, 0), '8.0');
      // 分数只出现在星级行上，元信息行里不再重复一遍。
      expect(find.textContaining('/10'), findsNothing);
    });

    testWidgets('3.5/5 → 3 实心 + 1 半星 + 1 空心，分数 7.0', (tester) async {
      await _pump(
        tester,
        ExternalCommentsSection(
          page: ExternalCommentPage(comments: [_comment(rating: 3.5, maxRating: 5)]),
        ),
      );
      expect(_starsAt(tester, 0), [full, full, full, half, empty]);
      expect(_scoreAt(tester, 0), '7.0');
    });

    testWidgets('未评分 → 没有任何星，出现「未评分」', (tester) async {
      await _pump(
        tester,
        ExternalCommentsSection(page: ExternalCommentPage(comments: [_comment()])),
      );
      expect(find.byIcon(full), findsNothing);
      expect(find.byIcon(half), findsNothing);
      expect(find.byIcon(empty), findsNothing);
      expect(find.byKey(const ValueKey('detail-comment-unrated-0')), findsOneWidget);
      expect(find.text('未评分'), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-comment-score-0')), findsNothing);
    });

    testWidgets('四条短评的星级行 top 不同、left 完全相同（成列）', (tester) async {
      await _pump(
        tester,
        ExternalCommentsSection(
          page: ExternalCommentPage(
            comments: [
              _comment(rating: 5, maxRating: 5, text: '第一条'),
              _comment(rating: 4, maxRating: 5, text: '第二条'),
              _comment(rating: 3.5, maxRating: 5, text: '第三条'),
              _comment(rating: 2, maxRating: 5, text: '第四条'),
            ],
          ),
        ),
      );
      final tops = <double>[];
      final lefts = <double>[];
      for (var i = 0; i < 4; i++) {
        final finder = find.byKey(ValueKey('detail-comment-rating-$i'));
        expect(finder, findsOneWidget);
        final topLeft = tester.getTopLeft(finder);
        tops.add(topLeft.dy);
        lefts.add(topLeft.dx);
      }
      expect(tops.toSet().length, 4);
      expect(lefts.toSet().length, 1);
    });
  });

  group('既有行为不回退', () {
    testWidgets('区块头 / 同源只挂一个来源徽标', (tester) async {
      await _pump(
        tester,
        ExternalCommentsSection(
          page: ExternalCommentPage(
            comments: [
              _comment(rating: 5, maxRating: 5),
              _comment(rating: 4, maxRating: 5),
            ],
            total: 413365,
            hasMore: true,
          ),
        ),
      );
      expect(find.byKey(const ValueKey('detail-external-comments')), findsOneWidget);
      expect(find.textContaining('短评（2'), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-comments-source')), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-comment-source-douban')), findsNothing);
    });

    testWidgets('混源：逐条来源徽标，区块头不带徽标', (tester) async {
      await _pump(
        tester,
        ExternalCommentsSection(
          page: ExternalCommentPage(
            comments: [
              _comment(rating: 5, maxRating: 5),
              _comment(
                rating: 4,
                maxRating: 5,
                source: MetaSourceKind.bangumi,
                author: '冬天不冷',
              ),
            ],
          ),
          mixedSources: true,
        ),
      );
      expect(find.byKey(const ValueKey('detail-comments-source')), findsNothing);
      expect(find.byKey(const ValueKey('detail-comment-source-douban')), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-comment-source-bangumi')), findsOneWidget);
    });

    testWidgets('hasMore 时点「加载更多短评」会回调', (tester) async {
      var calls = 0;
      await _pump(
        tester,
        ExternalCommentsSection(
          page: ExternalCommentPage(comments: [_comment(rating: 4, maxRating: 5)], hasMore: true),
          onLoadMore: () => calls++,
        ),
      );
      final button = find.byKey(const ValueKey('detail-comments-more'));
      expect(button, findsOneWidget);
      expect(find.text('加载更多短评'), findsOneWidget);
      await tester.tap(button);
      await tester.pump();
      expect(calls, 1);
    });

    testWidgets('loadingMore 时按钮禁用且文案为「加载中…」', (tester) async {
      await _pump(
        tester,
        ExternalCommentsSection(
          page: ExternalCommentPage(comments: [_comment(rating: 4, maxRating: 5)], hasMore: true),
          loadingMore: true,
          onLoadMore: () {},
        ),
      );
      final button = find.byKey(const ValueKey('detail-comments-more'));
      expect(tester.widget<TextButton>(button).onPressed, isNull);
      expect(find.text('加载中…'), findsOneWidget);
      // 收掉转圈动画，别把活跃 ticker 留给下一个用例。
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('page.isEmpty → 什么都不渲染', (tester) async {
      await _pump(tester, const ExternalCommentsSection(page: ExternalCommentPage()));
      expect(find.byKey(const ValueKey('detail-external-comments')), findsNothing);
      expect(find.byType(Text), findsNothing);
    });
  });
}
