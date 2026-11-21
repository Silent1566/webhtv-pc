/// 「匹配元数据」对话框：整行就是按钮，行内要给出足够确认信息（对齐安卓候选行）。
///
/// 锁定的行为：
/// 1. 结果行没有「用这个」按钮，整行点击即应用并关闭；
/// 2. 每行给海报、年份、类型、集数、评分、原名、一行事实与简介；
/// 3. 三个来源（TMDB / 豆瓣 / Bangumi）走同一套行渲染。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:webhtv_pc/core/external_meta.dart';
import 'package:webhtv_pc/core/meta_source.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/bangumi_service.dart';
import 'package:webhtv_pc/services/douban_recommendation_service.dart';
import 'package:webhtv_pc/services/external_meta_service.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/meta_match_dialog.dart';
import 'package:webhtv_pc/ui/poster_image.dart';
import 'package:webhtv_pc/ui/theme.dart';

http.Response jsonResponse(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

final vod = Vod(
  vodId: 'v1',
  vodName: '漫长的季节',
  vodYear: '2023',
  extra: {'type_name': '国产剧'},
);

/// 豆瓣 suggest（列表级字段：标题 / 原名 / 年份 / 集数 / 封面，没有评分）。
const doubanSuggestion = [
  {
    'id': '35588177',
    'title': '漫长的季节',
    'sub_title': 'The Long Season',
    'episode': '12',
    'year': '2023',
    'type': 'tv',
    'img': 'https://img.example/douban-35588177.jpg',
  },
  {
    'id': '1292052',
    'title': '肖申克的救赎',
    'sub_title': '肖申克的救赎',
    'episode': '',
    'year': '1994',
    'type': 'movie',
    'img': '',
  },
];

/// 豆瓣 search/subjects（一次请求补全：评分 + card_subtitle）。
const doubanRichSearch = {
  'subjects': {
    'items': [
      {
        'target': {
          'id': '35588177',
          'title': '漫长的季节',
          'year': '2023',
          'cover_url': 'https://img.example/douban-cover.jpg',
          'rating': {'value': 9.4},
          'card_subtitle': '中国大陆 / 剧情 家庭 犯罪 / 辛爽 / 范伟 秦昊',
        },
      },
      {
        'target': {'id': 'badge-collection', 'title': '高分榜（没有数字 id，会被丢弃）'},
      },
    ],
  },
};

/// Bangumi 搜索：列表级就已经带评分 / 简介 / 原名 / 集数。
const bangumiSearch = {
  'data': [
    {
      'id': 187187,
      'type': 6,
      'name': 'Stranger Things',
      'name_cn': '怪奇物语',
      'date': '2016-07-15',
      'platform': '欧美剧',
      'eps': 8,
      'total_episodes': 8,
      'rating': {'score': 7.6, 'rank': 695, 'total': 567},
      'images': {'large': 'https://lain.bgm.tv/pic/cover/l/187187.jpg'},
      'summary': '小镇上的怪事。',
      'infobox': [
        {'key': '主演', 'value': '薇诺娜·瑞德、大卫·哈伯'},
        {'key': '导演', 'value': '达菲兄弟'},
      ],
    },
  ],
};

const tmdbItems = [
  TmdbItem(
    tmdbId: 85552,
    mediaType: TmdbMediaType.tv,
    title: '亢奋',
    subtitle: '2019 · 8.4',
    overview: '一群高中生在谎言与创伤中寻找自己。',
    posterUrl: 'https://image.tmdb.org/t/p/w500/euphoria.jpg',
    rating: 8.4,
    tmdbRating: 8.4,
  ),
];

DoubanRecommendationService doubanService() {
  final cache = Directory.systemTemp.createTempSync('meta-match-douban');
  addTearDown(() => cache.deleteSync(recursive: true));
  return DoubanRecommendationService(
    cacheDirectory: cache,
    delay: (_) async {},
    client: MockClient((request) async {
      if (request.url.path == '/j/subject_suggest') {
        return jsonResponse(doubanSuggestion);
      }
      if (request.url.path == '/rexxar/api/v2/search/subjects') {
        return jsonResponse(doubanRichSearch);
      }
      return jsonResponse({});
    }),
  );
}

BangumiService bangumiService() {
  // 不传 cacheDirectory：搜索本身不碰磁盘，widget 测试里的真实文件 I/O
  // 不在 fake async 的时钟里，会把搜索留在未完成状态。
  return BangumiService(
    delay: (_) async {},
    client: MockClient((request) async => jsonResponse(bangumiSearch)),
  );
}

/// 已配置的 TMDB 服务：详情返回一份 credits，供「候选行补演员」用。
TmdbService castTmdbService() => TmdbService(
  config: () => const TmdbConfig(apiKey: 'test-key'),
  client: MockClient((request) async {
    if (request.url.path.endsWith('/tv/85552')) {
      return jsonResponse({
        'id': 85552,
        'aggregate_credits': {
          'cast': [
            {'id': 1, 'name': '赞达亚'},
            {'id': 2, 'name': '亨特·莎弗'},
          ],
        },
      });
    }
    return jsonResponse({'results': []});
  }),
);

ExternalMetaService doubanMeta() =>
    ExternalMetaService(douban: doubanService());

ExternalMetaService bangumiMeta() =>
    ExternalMetaService(bangumi: bangumiService());

Future<AppState> makeState(
  WidgetTester tester,
  ExternalMetaService external, {
  TmdbService? tmdbService,
}) async {
  final dir = Directory.systemTemp.createTempSync('meta-match-dialog');
  addTearDown(() => dir.deleteSync(recursive: true));
  final state = AppState(
    paths: AppPaths.resolve(
      overrides: {
        'config': dir.path,
        'data': dir.path,
        'cache': '${dir.path}/cache',
        'state': '${dir.path}/state',
      },
    ),
    log: LogService(),
    tmdbService:
        tmdbService ??
        TmdbService(
          config: () => const TmdbConfig(),
          client: MockClient((_) async => jsonResponse({'results': []})),
        ),
    externalMetaService: external,
  );
  addTearDown(state.dispose);
  await tester.runAsync(state.bootstrap);
  return state;
}

Widget harness(Widget child, {GlobalKey? boundary}) {
  final theme = buildAppTheme(Brightness.dark);
  final app = MaterialApp(
    theme: theme.copyWith(
      textTheme: theme.textTheme.apply(fontFamily: 'FixtureCJK'),
    ),
    home: child,
  );
  return boundary == null ? app : RepaintBoundary(key: boundary, child: app);
}

Future<void> openDialog(
  WidgetTester tester, {
  required AppState state,
  List<TmdbItem>? tmdbResults,
  void Function(TmdbItem item)? onPickTmdb,
  TmdbIdentity? currentTmdb,
  GlobalKey? boundary,
}) async {
  await tester.pumpWidget(
    harness(
      Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              key: const ValueKey('open-dialog'),
              onPressed: () => showDialog<bool>(
                context: context,
                builder: (_) => MetaMatchDialog(
                  state: state,
                  vod: vod,
                  tmdbSearch: tmdbResults == null
                      ? null
                      : (keyword) async => tmdbResults,
                  onPickTmdb: onPickTmdb,
                  currentTmdb: currentTmdb,
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
      boundary: boundary,
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open-dialog')));
  await tester.pumpAndSettle();
}

Future<void> searchCurrentSource(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('meta-match-search')));
  await tester.pumpAndSettle();
}

/// 点行：钉住要落盘（settings.json），真实文件 I/O 不在 fake async 的时钟里。
/// 用 runAsync 放开真实事件循环，再 pump 掉对话框退场动画。
Future<void> tapRow(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey('meta-match-result-$key')));
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pumpAndSettle();
}

Finder inRow(String key, Finder matching) => find.descendant(
  of: find.byKey(ValueKey('meta-match-result-$key')),
  matching: matching,
);

Future<void> capture(GlobalKey boundary, String scenario) async {
  final phase = Platform.environment['META_MATCH_CAPTURE'];
  if (phase == null) return;
  final object = boundary.currentContext!.findRenderObject()!;
  final image = await (object as RenderRepaintBoundary).toImage(pixelRatio: 1);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('../../.local/meta-match-captures/$scenario-$phase.png');
  await file.parent.create(recursive: true);
  await file.writeAsBytes(png!.buffer.asUint8List());
  image.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final font = File('/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc');
    if (!font.existsSync()) return;
    final bytes = await font.readAsBytes();
    ByteData data() => ByteData.sublistView(bytes);
    // 显式应用的字体族给本文件自己的主题；Roboto 给组件主题里那些没有吃到
    // textTheme.apply 的样式（对话框标题 / chip / 按钮），否则截图里它们是
    // 测试默认字体 Ahem 的方框，看不出真实文案。
    await (FontLoader('FixtureCJK')..addFont(Future.value(data()))).load();
    await (FontLoader('Roboto')..addFont(Future.value(data()))).load();
  });

  void viewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('豆瓣候选行给出海报/年份/集数/评分/原名/事实，整行点击即钉住', (tester) async {
    viewport(tester);
    final state = await makeState(tester, doubanMeta());
    await openDialog(tester, state: state);
    await searchCurrentSource(tester);

    const key = 'douban:tv:35588177';
    expect(
      find.byKey(const ValueKey('meta-match-result-$key')),
      findsOneWidget,
    );
    expect(find.text('用这个'), findsNothing, reason: '行本身就是按钮，不再有独立按钮');
    expect(inRow(key, find.byType(PosterImage)), findsOneWidget);
    expect(inRow(key, find.text('2023 · 剧集 · 12 集')), findsOneWidget);
    expect(inRow(key, find.text('9.4')), findsOneWidget, reason: '评分来自一次补全请求');
    expect(inRow(key, find.text('原名：The Long Season')), findsOneWidget);
    expect(
      inRow(key, find.text('中国大陆 · 剧情 家庭 犯罪')),
      findsOneWidget,
      reason: 'card_subtitle 前两段留在事实行',
    );
    expect(
      inRow(key, find.text('主演：范伟 秦昊 · 导演：辛爽')),
      findsOneWidget,
      reason: 'card_subtitle 后两段拆成主创行',
    );
    expect(
      inRow('douban:movie:1292052', find.text('1994 · 电影')),
      findsOneWidget,
    );

    await tapRow(tester, key);
    expect(find.byType(MetaMatchDialog), findsNothing);
    expect(state.metaOverrides.of(vod.vodId)?.key, key);
  });

  testWidgets('Bangumi 候选行给出评分/原名/简介，点击同样生效', (tester) async {
    viewport(tester);
    final state = await makeState(tester, bangumiMeta());
    await openDialog(tester, state: state);
    await tester.tap(find.byKey(const ValueKey('meta-match-source-bangumi')));
    await tester.pumpAndSettle();
    await searchCurrentSource(tester);

    const key = 'bangumi:tv:187187';
    expect(inRow(key, find.byType(PosterImage)), findsOneWidget);
    expect(inRow(key, find.text('2016 · 剧集 · 8 集')), findsOneWidget);
    expect(inRow(key, find.text('7.6')), findsOneWidget);
    expect(inRow(key, find.text('原名：Stranger Things')), findsOneWidget);
    expect(
      inRow(key, find.text('主演：薇诺娜·瑞德、大卫·哈伯 · 导演：达菲兄弟')),
      findsOneWidget,
      reason: '主演/导演来自 infobox，不必再请求人物页',
    );
    expect(inRow(key, find.text('小镇上的怪事。')), findsOneWidget);

    await tapRow(tester, key);
    expect(find.byType(MetaMatchDialog), findsNothing);
    expect(state.metaOverrides.of(vod.vodId)?.key, key);
  });

  testWidgets('补全失败时候选行只显示列表级字段，不编评分', (tester) async {
    viewport(tester);
    final cache = Directory.systemTemp.createTempSync(
      'meta-match-douban-plain',
    );
    addTearDown(() => cache.deleteSync(recursive: true));
    final state = await makeState(
      tester,
      ExternalMetaService(
        douban: DoubanRecommendationService(
          cacheDirectory: cache,
          delay: (_) async {},
          client: MockClient((request) async {
            if (request.url.path == '/j/subject_suggest') {
              return jsonResponse(doubanSuggestion);
            }
            // 补全返回空表：模拟被限流/响应形状不认识。
            return jsonResponse({
              'subjects': {'items': []},
            });
          }),
        ),
      ),
    );
    await openDialog(tester, state: state);
    await searchCurrentSource(tester);

    const key = 'douban:tv:35588177';
    expect(inRow(key, find.text('2023 · 剧集 · 12 集')), findsOneWidget);
    expect(inRow(key, find.text('原名：The Long Season')), findsOneWidget);
    expect(
      inRow(key, find.byIcon(Icons.star_rounded)),
      findsNothing,
      reason: '没有评分就不画星等，不补占位也不编分数',
    );
    await tapRow(tester, key);
    expect(state.metaOverrides.of(vod.vodId)?.key, key);
  });

  testWidgets('已钉住的那条候选带「当前」标记', (tester) async {
    viewport(tester);
    final state = await makeState(tester, doubanMeta());
    final identity = MetaIdentity.of(
      MetaSourceKind.douban,
      TmdbMediaType.tv,
      35588177,
    )!;
    await tester.runAsync(() => state.pinMetaOverride(vod.vodId, identity));
    await openDialog(tester, state: state);
    await searchCurrentSource(tester);

    const key = 'douban:tv:35588177';
    expect(inRow(key, find.text('当前')), findsOneWidget);
    expect(inRow('douban:movie:1292052', find.text('当前')), findsNothing);
  });

  testWidgets('TMDB 候选行同样富信息，整行点击走 onPickTmdb', (tester) async {
    viewport(tester);
    final state = await makeState(tester, ExternalMetaService());
    TmdbItem? picked;
    await openDialog(
      tester,
      state: state,
      tmdbResults: tmdbItems,
      onPickTmdb: (item) => picked = item,
    );
    await searchCurrentSource(tester);

    const key = 'tmdb-85552';
    expect(inRow(key, find.byType(PosterImage)), findsOneWidget);
    expect(inRow(key, find.text('2019 · 剧集')), findsOneWidget);
    expect(inRow(key, find.text('8.4')), findsOneWidget);
    expect(inRow(key, find.text('一群高中生在谎言与创伤中寻找自己。')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('meta-match-result-$key')));
    await tester.pumpAndSettle();
    expect(picked, tmdbItems.first);
    expect(find.byType(MetaMatchDialog), findsNothing);
  });

  testWidgets('切换来源保留各自的搜索词与结果，切回来不用再搜一次', (tester) async {
    viewport(tester);
    final state = await makeState(tester, doubanMeta());
    await openDialog(tester, state: state, tmdbResults: tmdbItems);

    // TMDB 用「亢奋」搜一次（初始来源是 TMDB）。
    await tester.enterText(
      find.byKey(const ValueKey('meta-match-query')),
      '亢奋',
    );
    await searchCurrentSource(tester);
    expect(
      find.byKey(const ValueKey('meta-match-result-tmdb-85552')),
      findsOneWidget,
    );

    // 切到豆瓣：还没有结果，查询词先保留；搜一次。
    await tester.tap(find.byKey(const ValueKey('meta-match-source-douban')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('meta-match-result-douban:tv:35588177')),
      findsNothing,
    );
    await tester.enterText(
      find.byKey(const ValueKey('meta-match-query')),
      '漫长的季节',
    );
    await searchCurrentSource(tester);
    expect(
      find.byKey(const ValueKey('meta-match-result-douban:tv:35588177')),
      findsOneWidget,
    );

    // 切回 TMDB：结果与查询词都还原，不用重新搜索。
    await tester.tap(find.byKey(const ValueKey('meta-match-source-tmdb')));
    await tester.pumpAndSettle();
    expect(inRow('tmdb-85552', find.text('2019 · 剧集')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('meta-match-query')))
          .controller!
          .text,
      '亢奋',
    );

    // 再切回豆瓣：同样不点搜索也在。
    await tester.tap(find.byKey(const ValueKey('meta-match-source-douban')));
    await tester.pumpAndSettle();
    expect(inRow('douban:tv:35588177', find.text('9.4')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('meta-match-query')))
          .controller!
          .text,
      '漫长的季节',
    );
  });

  testWidgets('标出当前采用的 TMDB 条目，未采用的来源不标记', (tester) async {
    viewport(tester);
    final state = await makeState(tester, doubanMeta());
    const other = TmdbItem(
      tmdbId: 999,
      mediaType: TmdbMediaType.tv,
      title: '另一部剧',
      subtitle: '2020 · 7.0',
      rating: 7,
      tmdbRating: 7,
    );
    await openDialog(
      tester,
      state: state,
      tmdbResults: [tmdbItems.first, other],
      currentTmdb: tmdbItems.first.identity,
    );
    await searchCurrentSource(tester);
    expect(inRow('tmdb-85552', find.text('当前')), findsOneWidget);
    expect(inRow('tmdb-999', find.text('当前')), findsNothing);

    // 豆瓣没有被采用：搜到结果也不标「当前」，不把自动匹配猜的当成已采用。
    await tester.tap(find.byKey(const ValueKey('meta-match-source-douban')));
    await tester.pumpAndSettle();
    await searchCurrentSource(tester);
    expect(inRow('douban:tv:35588177', find.text('当前')), findsNothing);
  });

  testWidgets('TMDB 候选行用详情 credits 补出演员', (tester) async {
    viewport(tester);
    final state = await makeState(
      tester,
      ExternalMetaService(),
      tmdbService: castTmdbService(),
    );
    await openDialog(tester, state: state, tmdbResults: tmdbItems);
    await searchCurrentSource(tester);
    // 演员来自详情请求，搜索返回后才异步补上。
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(inRow('tmdb-85552', find.text('主演：赞达亚 / 亨特·莎弗')), findsOneWidget);
  });

  testWidgets('三来源截图', (tester) async {
    viewport(tester);
    final external = ExternalMetaService(
      douban: doubanService(),
      bangumi: bangumiService(),
    );
    final state = await makeState(
      tester,
      external,
      tmdbService: castTmdbService(),
    );
    final boundary = GlobalKey();
    await openDialog(
      tester,
      state: state,
      tmdbResults: tmdbItems,
      currentTmdb: tmdbItems.first.identity,
      boundary: boundary,
    );
    await tester.tap(find.byKey(const ValueKey('meta-match-source-douban')));
    await tester.pumpAndSettle();
    await searchCurrentSource(tester);
    await tester.runAsync(() => capture(boundary, 'douban'));
    await tester.tap(find.byKey(const ValueKey('meta-match-source-tmdb')));
    await tester.pumpAndSettle();
    await searchCurrentSource(tester);
    // 演员来自详情请求，等它补上再拍。
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.runAsync(() => capture(boundary, 'tmdb'));
    await tester.tap(find.byKey(const ValueKey('meta-match-source-bangumi')));
    await tester.pumpAndSettle();
    await searchCurrentSource(tester);
    await tester.runAsync(() => capture(boundary, 'bangumi'));
  }, skip: Platform.environment['META_MATCH_CAPTURE'] == null);
}
