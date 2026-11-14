import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_detail_model.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/tmdb_media.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/ui/tmdb_detail_page.dart';
import 'package:webhtv_pc/ui/tmdb_detail_view.dart';
import 'package:webhtv_pc/ui/tmdb_episode_detail.dart';

const _tv = TmdbItem(tmdbId: 42, mediaType: TmdbMediaType.tv, title: '剧名');
const _card = TmdbEpisodeCard(
  number: 7,
  seasonNumber: 3,
  title: '完整基础标题',
  date: '2025-03-04',
  runtime: 44,
  rating: 8.2,
);

Map<String, Object?> _episode() => {
  'id': 307,
  'episode_number': 7,
  'season_number': 3,
  'name': '完整单集标题',
  'air_date': '2025-03-05',
  'runtime': 46,
  'vote_average': 9.1,
  'overview': '当集完整简介',
  'still_path': '/cover.jpg',
  'images': {
    'stills': [
      {'file_path': '/one.jpg', 'width': 1280, 'height': 720},
      {'file_path': '/two.jpg', 'width': 1280, 'height': 720},
    ],
    'backdrops': [
      {'file_path': '/wrong-series.jpg', 'width': 1280, 'height': 720},
    ],
  },
  'guest_stars': [
    {'id': 88, 'name': '客串演员', 'character': '客串角色'},
  ],
};

TmdbService _service(
  Future<http.Response> Function(http.Request) respond, {
  bool ready = true,
}) => TmdbService(
  config: () => TmdbConfig(
    apiKey: ready ? 'test-key' : '',
    imageBase: 'https://images.test/w500',
    backdropBase: 'https://images.test/w1280',
  ),
  client: MockClient(respond),
);

http.Response _json(Map<String, Object?> body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

Future<void> _open(
  WidgetTester tester, {
  TmdbEpisodeCard card = _card,
  String sourceName = '原始源站文件名',
  TmdbItem? item = _tv,
  TmdbService? service,
  Future<TmdbItem?> Function()? resolveItem,
  String actionLabel = '播放',
  VoidCallback? onAction,
  ValueChanged<TmdbPerson>? onPersonTap,
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showTmdbEpisodeDetails(
              context,
              card: card,
              sourceName: sourceName,
              item: item,
              service: service,
              resolveItem: resolveItem,
              actionLabel: actionLabel,
              onAction: onAction,
              onPersonTap: onPersonTap,
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _reveal(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

void main() {
  for (final size in const [
    Size(1440, 900),
    Size(1280, 640),
    Size(1410, 600),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('全屏详情覆盖窗口并支持返回：$size / $brightness', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await _open(
          tester,
          brightness: brightness,
          card: const TmdbEpisodeCard(
            number: 7,
            seasonNumber: 3,
            title: '全屏详情标题',
            stillUrl: 'https://images.test/w1280/cover.jpg',
          ),
        );
        await tester.pumpAndSettle();
        final page = find.byKey(const ValueKey('tmdb-episode-details'));
        expect(tester.widget(page), isA<Scaffold>());
        expect(tester.getRect(page), Offset.zero & size);
        expect(find.byType(Dialog), findsNothing);
        expect(ModalRoute.of(tester.element(page)), isA<PageRoute<void>>());
        expect(find.byTooltip('返回').hitTestable(), findsOneWidget);
        final cover = tester.getRect(
          find.byKey(const ValueKey('tmdb-episode-cover')),
        );
        final title = tester.getRect(
          find.byKey(const ValueKey('tmdb-episode-title')),
        );
        expect(cover.width / cover.height, closeTo(16 / 9, 0.01));
        expect(title.left, greaterThan(cover.right));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(page, findsNothing);
        expect(find.text('打开').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('错误季集响应不会覆盖基础身份或带入错误媒体', (tester) async {
    await _open(
      tester,
      service: _service(
        (_) async =>
            _json({..._episode(), 'season_number': 1, 'episode_number': 1}),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('完整基础标题'), findsOneWidget);
    expect(find.textContaining('S3E7'), findsOneWidget);
    expect(find.text('暂无简介'), findsOneWidget);
    expect(find.byKey(const ValueKey('tmdb-episode-photo-0')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空单集响应与空影片响应保留基础内容', (tester) async {
    await _open(tester, service: _service((_) async => _json({'id': 307})));
    await tester.pumpAndSettle();
    expect(find.text('完整基础标题'), findsOneWidget);
    expect(find.text('暂无简介'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await _open(
      tester,
      item: const TmdbItem(
        tmdbId: 60,
        mediaType: TmdbMediaType.movie,
        title: '基础影片',
        subtitle: '2020-06-07',
      ),
      service: _service((_) async => _json({'id': 60})),
    );
    await tester.pumpAndSettle();
    expect(find.text('基础影片'), findsOneWidget);
    expect(find.textContaining('2020-06-07'), findsOneWidget);
    expect(find.text('暂无简介'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('媒体控件键盘聚焦可见，Enter 不误触播放', (tester) async {
    var actions = 0;
    await _open(
      tester,
      service: _service((_) async => _json(_episode())),
      onAction: () => actions++,
    );
    await tester.pumpAndSettle();
    await _reveal(tester, find.byKey(const ValueKey('tmdb-episode-cover')));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    final ring = tester.widget<Container>(
      find.byKey(const ValueKey('tmdb-episode-cover-focus')),
    );
    final decoration = ring.foregroundDecoration! as BoxDecoration;
    final border = decoration.border! as Border;
    expect(
      border.top.color,
      Theme.of(tester.element(find.byKey(const ValueKey('tmdb-episode-cover'))))
          .colorScheme
          .primary,
    );
    expect(border.top.width, greaterThan(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(TmdbPhotoViewerDialog), findsOneWidget);
    expect(actions, 0);
  });

  testWidgets('首屏立即保留完整基础内容，关闭不会播放', (tester) async {
    final pending = Completer<http.Response>();
    var actions = 0;
    final service = _service((_) => pending.future);
    await _open(tester, service: service, onAction: () => actions++);
    expect(find.text('完整基础标题'), findsOneWidget);
    expect(find.text('原始名称：原始源站文件名'), findsOneWidget);
    expect(find.textContaining('S3E7'), findsOneWidget);
    expect(find.textContaining('2025-03-04'), findsOneWidget);
    expect(find.textContaining('44 分钟'), findsOneWidget);
    expect(find.textContaining('8.2'), findsOneWidget);
    expect(find.text('暂无简介'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    pending.complete(_json(_episode()));
    await tester.pumpAndSettle();
    expect(actions, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('准确请求当前季集一次，完整详情与当集媒体加载', (tester) async {
    final paths = <String>[];
    final service = _service((request) async {
      paths.add(request.url.path);
      return _json(_episode());
    });
    var resolves = 0;
    await _open(
      tester,
      service: service,
      resolveItem: () async {
        resolves++;
        return const TmdbItem(
          tmdbId: 99,
          mediaType: TmdbMediaType.tv,
          title: '错误剧',
        );
      },
    );
    await tester.pumpAndSettle();
    expect(paths, ['/3/tv/42/season/3/episode/7']);
    expect(resolves, 0);
    expect(find.textContaining('完整单集标题'), findsOneWidget);
    expect(find.text('当集完整简介'), findsOneWidget);
    expect(find.textContaining('2025-03-05'), findsOneWidget);
    expect(find.textContaining('46 分钟'), findsOneWidget);
    expect(find.textContaining('9.1'), findsOneWidget);
    expect(find.byKey(const ValueKey('tmdb-episode-photo-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('tmdb-episode-photo-1')), findsOneWidget);
    expect(find.text('客串演员'), findsOneWidget);
    await tester.pumpWidget(tester.widget(find.byType(MaterialApp)));
    await tester.pumpAndSettle();
    expect(paths.length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('封面和第二张剧照均可打开现有大图查看器', (tester) async {
    await _open(tester, service: _service((_) async => _json(_episode())));
    await tester.pumpAndSettle();
    await _reveal(tester, find.byKey(const ValueKey('tmdb-episode-cover')));
    await tester.tap(find.byKey(const ValueKey('tmdb-episode-cover')));
    await tester.pumpAndSettle();
    expect(find.byType(TmdbPhotoViewerDialog), findsOneWidget);
    expect(
      tester
          .widget<TmdbPhotoViewerDialog>(find.byType(TmdbPhotoViewerDialog))
          .viewer
          .currentUrl,
      'https://images.test/w1280/cover.jpg',
    );
    Navigator.of(tester.element(find.byType(TmdbPhotoViewerDialog))).pop();
    await tester.pumpAndSettle();
    await _reveal(tester, find.byKey(const ValueKey('tmdb-episode-photo-1')));
    await tester.tap(find.byKey(const ValueKey('tmdb-episode-photo-1')));
    await tester.pumpAndSettle();
    final viewer = tester
        .widget<TmdbPhotoViewerDialog>(find.byType(TmdbPhotoViewerDialog))
        .viewer;
    expect(viewer.currentUrl, 'https://images.test/w1280/two.jpg');
    expect(viewer.urls, [
      'https://images.test/w1280/one.jpg',
      'https://images.test/w1280/two.jpg',
      'https://images.test/w1280/cover.jpg',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('人物回调只在明确点击时执行', (tester) async {
    TmdbPerson? tapped;
    var actions = 0;
    await _open(
      tester,
      service: _service((_) async => _json(_episode())),
      onPersonTap: (person) => tapped = person,
      onAction: () => actions++,
    );
    await tester.pumpAndSettle();
    expect(tapped, isNull);
    await _reveal(tester, find.text('客串演员'));
    await tester.tap(find.text('客串演员'));
    await tester.pumpAndSettle();
    expect(tapped?.personId, 88);
    expect(find.byType(TmdbPersonPage), findsNothing);
    expect(actions, 0);
  });

  testWidgets('默认人物页可进入人物作品的 TMDB 详情', (tester) async {
    final service = _service((request) async {
      if (request.url.path.contains('/person/')) {
        return _json({
          'id': 88,
          'name': '客串演员',
          'biography': '人物简介',
          'combined_credits': {
            'cast': [
              {
                'id': 66,
                'media_type': 'movie',
                'title': '人物作品',
                'character': '主演',
              },
            ],
          },
        });
      }
      if (request.url.path.contains('/movie/')) {
        return _json({'id': 66, 'title': '人物作品', 'overview': '作品简介'});
      }
      return _json(_episode());
    });
    await _open(tester, service: service);
    await tester.pumpAndSettle();
    await _reveal(tester, find.text('客串演员'));
    await tester.tap(find.text('客串演员'));
    await tester.pumpAndSettle();
    expect(find.byType(TmdbPersonPage), findsOneWidget);
    await _reveal(
      tester,
      find.byKey(const ValueKey('tmdb-person-work-movie:66')),
    );
    await tester.tap(find.byKey(const ValueKey('tmdb-person-work-movie:66')));
    await tester.pumpAndSettle();
    expect(find.byType(TmdbDetailPage), findsOneWidget);
    expect(find.text('人物作品'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('缺少 item 时解析一次且首屏不等待匹配', (tester) async {
    final match = Completer<TmdbItem?>();
    var resolves = 0;
    final paths = <String>[];
    await _open(
      tester,
      item: null,
      service: _service((request) async {
        paths.add(request.url.path);
        return _json(_episode());
      }),
      resolveItem: () {
        resolves++;
        return match.future;
      },
    );
    expect(find.text('完整基础标题'), findsOneWidget);
    expect(paths, isEmpty);
    match.complete(_tv);
    await tester.pumpAndSettle();
    expect(resolves, 1);
    expect(paths, ['/3/tv/42/season/3/episode/7']);
    expect(find.text('当集完整简介'), findsOneWidget);
  });

  testWidgets('匹配返回前关闭，不继续加载媒体', (tester) async {
    final match = Completer<TmdbItem?>();
    final paths = <String>[];
    await _open(
      tester,
      item: null,
      service: _service((request) async {
        paths.add(request.url.path);
        return _json(_episode());
      }),
      resolveItem: () => match.future,
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    match.complete(_tv);
    await tester.pumpAndSettle();
    expect(paths, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final card in [
    const TmdbEpisodeCard(number: 7, title: '未知季度', seasonNumber: 0),
    const TmdbEpisodeCard(number: 0, title: '未知集号', seasonNumber: 3),
    const TmdbEpisodeCard(number: 7, title: '负值季度', seasonNumber: -1),
  ]) {
    testWidgets('${card.title}不冒充第一季或最新集', (tester) async {
      final paths = <String>[];
      await _open(
        tester,
        card: card,
        service: _service((request) async {
          paths.add(request.url.path);
          return _json(_episode());
        }),
      );
      await tester.pumpAndSettle();
      expect(paths, isEmpty);
      expect(find.text(card.title), findsOneWidget);
      expect(find.text('暂无简介'), findsOneWidget);
      expect(find.textContaining('S1E'), findsNothing);
      expect(find.textContaining('E0'), findsNothing);
      if (card.number <= 0) {
        expect(find.textContaining('集号未知'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('未配置时保留基础数据且零网络请求', (tester) async {
    var requests = 0;
    await _open(
      tester,
      service: _service((_) async {
        requests++;
        return _json(_episode());
      }, ready: false),
    );
    await tester.pumpAndSettle();
    expect(requests, 0);
    expect(find.text('完整基础标题'), findsOneWidget);
    expect(find.text('暂无简介'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有 service 或没有匹配都可正常关闭', (tester) async {
    await _open(tester, item: null);
    await tester.pumpAndSettle();
    expect(find.text('暂无简介'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await _open(
      tester,
      item: null,
      service: _service((_) async => _json(_episode())),
      resolveItem: () async => null,
    );
    await tester.pumpAndSettle();
    expect(find.text('完整基础标题'), findsOneWidget);
    expect(find.text('暂无简介'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('请求失败与匹配异常不清空基础内容', (tester) async {
    await _open(
      tester,
      service: _service((_) async => http.Response('fail', 500)),
    );
    await tester.pumpAndSettle();
    expect(find.text('完整基础标题'), findsOneWidget);
    expect(find.text('暂无简介'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await _open(
      tester,
      item: null,
      service: _service((_) async => _json(_episode())),
      resolveItem: () async => throw StateError('match failed'),
    );
    await tester.pumpAndSettle();
    expect(find.text('完整基础标题'), findsOneWidget);
    expect(find.text('暂无简介'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('电影按影片身份请求，首屏及影片元数据不伪装成单集', (tester) async {
    const movie = TmdbItem(
      tmdbId: 60,
      mediaType: TmdbMediaType.movie,
      title: '完整电影名',
      overview: '电影基础简介',
      tmdbRating: 7.3,
    );
    final pending = Completer<http.Response>();
    final paths = <String>[];
    await _open(
      tester,
      item: movie,
      service: _service((request) {
        paths.add(request.url.path);
        return pending.future;
      }),
    );
    expect(find.text('完整电影名'), findsOneWidget);
    expect(find.text('电影基础简介'), findsOneWidget);
    expect(find.textContaining('S3E7'), findsNothing);
    pending.complete(
      _json({
        'id': 60,
        'title': '完整电影名',
        'release_date': '2024-02-03',
        'runtime': 120,
        'vote_average': 8.8,
        'overview': '电影完整简介',
        'images': {
          'backdrops': [
            {'file_path': '/movie.jpg', 'width': 1280, 'height': 720},
          ],
        },
        'credits': {
          'cast': [
            {'id': 88, 'name': '电影演员'},
          ],
        },
      }),
    );
    await tester.pumpAndSettle();
    expect(paths, ['/3/movie/60']);
    expect(find.text('电影完整简介'), findsOneWidget);
    expect(find.textContaining('120 分钟'), findsOneWidget);
    expect(find.textContaining('2024-02-03'), findsOneWidget);
    expect(find.text('演员'), findsOneWidget);
    expect(find.text('电影演员'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('动作仅显式点击一次，动作后关闭弹窗', (tester) async {
    var actions = 0;
    await _open(tester, onAction: () => actions++, actionLabel: '搜索站源');
    await tester.pumpAndSettle();
    expect(actions, 0);
    await tester.tap(find.byKey(const ValueKey('tmdb-episode-action')));
    await tester.pumpAndSettle();
    expect(actions, 1);
    expect(find.byKey(const ValueKey('tmdb-episode-details')), findsNothing);
  });

  testWidgets('小窗口长标题源名与简介可滚动，关闭始终可达', (tester) async {
    tester.view.physicalSize = const Size(320, 280);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final title = List.filled(30, '完整标题').join();
    final source = List.filled(30, '原始源名').join();
    final overview = List.filled(100, '很长的简介').join();
    await _open(
      tester,
      card: TmdbEpisodeCard(
        number: 7,
        seasonNumber: 3,
        title: title,
        overview: overview,
      ),
      sourceName: source,
      onAction: () {},
      actionLabel: List.filled(20, '长动作').join(),
    );
    await tester.pumpAndSettle();
    expect(find.text(title), findsOneWidget);
    expect(find.text('原始名称：$source'), findsOneWidget);
    expect(find.text(overview), findsOneWidget);
    expect(tester.takeException(), isNull);
    final scroll = tester.widget<SingleChildScrollView>(
      find.byKey(const ValueKey('tmdb-episode-scroll')),
    );
    expect(scroll.controller!.position.maxScrollExtent, greaterThan(0));
    await tester.drag(
      find.byKey(const ValueKey('tmdb-episode-scroll')),
      const Offset(0, -150),
    );
    await tester.pumpAndSettle();
    expect(scroll.controller!.offset, greaterThan(0));
    expect(find.byTooltip('返回').hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
