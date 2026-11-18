/// 详情页 hero 标签行的「播放平台」chip：口径是 TMDB `networks`（播出平台），
/// 不是爬虫站源名。
///
/// 两处调用点（站点详情页 / 纯 TMDB 详情页）都把 [TmdbDetailData.networks] 交给
/// `playbackPlatformLabel`，本文件锁住渲染口径：有台名才出现 chip、在最前面、
/// 文案取中文显示名、没有台名时整块不渲染。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/playback_platform.dart';
import 'package:webhtv_pc/core/tmdb_detail_model.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/ui/common.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tmdb_detail_view.dart';

const String _imageBase = 'https://images.tmdb.org/t/p/w342';
const String _backdropBase = 'https://images.tmdb.org/t/p/w780';

const ValueKey<String> _platformKey = ValueKey('tmdb-detail-platform');

/// 站点页与纯 TMDB 页共用的详情数据：台名来自 `networks`，顺序即 fixture 顺序。
TmdbDetailData _detailWithNetworks() => TmdbDetailData.fromDetail(
  {
    'id': 1,
    'name': '示例剧集',
    'first_air_date': '2024-03-01',
    'episode_run_time': [45],
    'number_of_seasons': 1,
    'number_of_episodes': 12,
    'genres': [
      {'id': 18, 'name': '剧情'},
    ],
    'production_countries': [
      {'iso_3166_1': 'CN', 'name': '中国'},
    ],
    'spoken_languages': [
      {'iso_639_1': 'zh', 'name': '普通话'},
    ],
    'status': 'Returning Series',
    'networks': [
      {'id': 521, 'name': 'CCTV-8'},
      {'id': 1419, 'name': 'Youku'},
      {'id': 1024, 'name': 'Tencent Video'},
    ],
  },
  imageBase: _imageBase,
  backdropBase: _backdropBase,
);

/// 按详情页的真实约束渲染头部：宽度决定 `compact`（< 720），高度给确定值。
Future<void> _pumpHeader(
  WidgetTester tester, {
  required TmdbDetailData data,
  required String platformLabel,
  double width = 1200,
  String? metadataBadge,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(
            width: width,
            height: 400,
            child: TmdbDetailHeader(
              data: data,
              platformLabel: platformLabel,
              metadataBadge: metadataBadge,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Finder _chipText(String label) =>
    find.descendant(of: find.byKey(_platformKey), matching: find.text(label));

void main() {
  group('播放平台 chip 的内容口径（TMDB networks）', () {
    testWidgets('有台名时出现 chip，文案取中文显示名（最多两个，/ 连接）', (tester) async {
      final data = _detailWithNetworks();
      expect(data.networks, ['CCTV-8', 'Youku']);
      await _pumpHeader(
        tester,
        data: data,
        platformLabel: playbackPlatformLabel(networks: data.networks),
      );

      expect(find.byKey(_platformKey), findsOneWidget);
      // Youku → 优酷（display name），CCTV-8 未收录原样。
      expect(_chipText('CCTV-8 / 优酷'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(_platformKey),
          matching: find.byIcon(Icons.live_tv_outlined),
        ),
        findsOneWidget,
      );
    });

    testWidgets('没有台名时整块不渲染（含 fromItem）', (tester) async {
      const data = TmdbDetailData(title: '无平台');
      expect(data.networks, isEmpty);
      await _pumpHeader(
        tester,
        data: data,
        platformLabel: playbackPlatformLabel(networks: data.networks),
      );
      expect(find.byKey(_platformKey), findsNothing);

      final fromItem = TmdbDetailData.fromItem(
        const TmdbItem(tmdbId: 9, mediaType: TmdbMediaType.tv, title: '元数据快照'),
      );
      expect(fromItem.networks, isEmpty);
      await _pumpHeader(
        tester,
        data: fromItem,
        platformLabel: playbackPlatformLabel(networks: fromItem.networks),
      );
      expect(find.byKey(_platformKey), findsNothing);
    });

    test('fromDetail 解析台名，fromItem 为空', () {
      expect(_detailWithNetworks().networks, ['CCTV-8', 'Youku']);
      expect(const TmdbDetailData().networks, isEmpty);
      expect(
        playbackPlatformLabel(networks: _detailWithNetworks().networks),
        'CCTV-8 / 优酷',
      );
    });
  });

  group('播放平台 chip 的位置与上限', () {
    testWidgets('平台 chip 排在标签行最前面', (tester) async {
      final data = _detailWithNetworks();
      await _pumpHeader(
        tester,
        data: data,
        platformLabel: playbackPlatformLabel(networks: data.networks),
      );

      final chips = tester.widgetList<TagChip>(find.byType(TagChip)).toList();
      expect(chips.first.keyValue, 'tmdb-detail-platform');
      expect(
        tester.getTopLeft(find.byKey(_platformKey)).dx,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('tmdb-detail-year'))).dx,
        ),
      );
    });

    testWidgets('宽屏上限 9：新增平台 chip 不把「状态」挤出去', (tester) async {
      final data = _detailWithNetworks();
      await _pumpHeader(
        tester,
        data: data,
        platformLabel: playbackPlatformLabel(networks: data.networks),
        metadataBadge: '元数据季度 · 不可直接播放',
      );

      // 平台 + 年份 + 时长 + 季集数 + 类型 + 地区 + 语言 + 状态 + 徽标 = 9。
      expect(find.byKey(_platformKey), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-detail-status')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('tmdb-only-metadata-badge')),
        findsOneWidget,
      );
      expect(find.byType(TagChip), findsNWidgets(9));
    });

    testWidgets('窄屏上限 6：平台 chip 仍在，「状态」排在第 6 之后被裁掉', (tester) async {
      final data = _detailWithNetworks();
      await _pumpHeader(
        tester,
        data: data,
        platformLabel: playbackPlatformLabel(networks: data.networks),
        width: 600,
      );

      expect(find.byKey(_platformKey), findsOneWidget);
      expect(find.byType(TagChip), findsNWidgets(6));
      expect(find.byKey(const ValueKey('tmdb-detail-status')), findsNothing);
    });
  });
}
