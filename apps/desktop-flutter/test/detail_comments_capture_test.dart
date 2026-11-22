/// 详情页「短评」评分 Before/After 截图门禁（用户反馈 2026-11-22：
/// 评分只有一段 `8.0/10` 文本，得逐条读才能看出高低）。
///
/// 只在 `COMMENT_CAPTURE_PHASE` 非空时写 PNG（与
/// `detail_ratings_capture_test.dart` 同一套做法）：CI 上它只是一次普通渲染断言。
/// 前后两次在同一渲染路径、同一 fixture、同一视口、同一主题下出图，
/// 差异因此只可能来自短评区块本身。
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/douban_recommendation_service.dart';
import 'package:webhtv_pc/services/external_meta_service.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'external_metadata_service_test.dart' show response, subject, suggestion;

/// 六条短评覆盖全部星级取值：5 / 4 / 3 / 2 / 3.5（半星）与「未评分」。
const _interests = [
  {
    'comment': '节奏慢但后劲足，范伟的表演撑住了整部剧。看完那天晚上一个人坐了很久。',
    'create_time': '2023-04-23 21:10:00',
    'vote_count': 128,
    'rating': {'value': 5},
    'user': {'name': '江户川乱跑'},
  },
  {
    'comment': '十二集像一场漫长的告别，配乐一响就知道要出事。',
    'create_time': '2023-05-01 09:02:11',
    'vote_count': 12,
    'rating': {'value': 4},
    'user': {'name': '冬天不冷'},
  },
  {
    'comment': '前六集有点拖，后面才立起来。',
    'create_time': '2023-05-06 12:30:00',
    'vote_count': 4,
    'rating': {'value': 3},
    'user': {'name': '看剧不追星'},
  },
  {
    'comment': '我对这种慢热叙事没什么耐心，两集就弃了。',
    'create_time': '2023-05-09 08:15:00',
    'vote_count': 2,
    'rating': {'value': 2},
    'user': {'name': '快进区居民'},
  },
  {
    'comment': '摄影和剪辑都在线，剧本差一口气。',
    'create_time': '2023-05-10 20:08:00',
    'vote_count': 27,
    'rating': {'value': 3.5},
    'user': {'name': '灯下看片'},
  },
  {
    'comment': '还没看完，先留个位置。',
    'create_time': '2023-05-11 23:41:00',
    'vote_count': 0,
    'user': {'name': '半途而废'},
  },
];

Future<void> _capture(GlobalKey key, String scenario) async {
  final phase = Platform.environment['COMMENT_CAPTURE_PHASE'];
  if (phase == null) return;
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 1);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('../../.local/comment-captures/$scenario-$phase.png');
  await file.parent.create(recursive: true);
  await file.writeAsBytes(png!.buffer.asUint8List());
  image.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final font = File('/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc');
    final root =
        Platform.environment['FLUTTER_ROOT'] ??
        '/home/maple/tools/webhtv-linux-sdk/flutter-3.47.5';
    final icons = File(
      '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (icons.existsSync()) {
      await (FontLoader(
        'MaterialIcons',
      )..addFont(icons.readAsBytes().then(ByteData.sublistView))).load();
    }
    if (font.existsSync()) {
      await (FontLoader(
        'FixtureCJK',
      )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
    }
  });

  Future<AppState> makeState(WidgetTester tester) async {
    final dir = Directory.systemTemp.createTempSync('detail-comments-capture');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cache = Directory.systemTemp.createTempSync('detail-comments-cache');
    addTearDown(() => cache.deleteSync(recursive: true));
    final external = ExternalMetaService(
      douban: DoubanRecommendationService(
        cacheDirectory: cache,
        delay: (_) async {},
        client: MockClient((r) async {
          if (r.url.path == '/j/subject_suggest') return response(suggestion);
          if (r.url.path.endsWith('/credits')) return response({'items': []});
          if (r.url.path.endsWith('/photos')) {
            return response({'total': 0, 'photos': []});
          }
          if (r.url.path.endsWith('/interests')) {
            return response({'total': _interests.length, 'interests': _interests});
          }
          return response({...subject, 'cover': {}, 'cover_url': ''});
        }),
      ),
    );
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
      tmdbService: TmdbService(
        config: () => const TmdbConfig(),
        client: MockClient((_) async => response({'results': []})),
      ),
      externalMetaService: external,
    );
    addTearDown(state.dispose);
    await tester.runAsync(state.bootstrap);
    return state;
  }

  for (final width in [1280, 900]) {
    for (final brightness in Brightness.values) {
      testWidgets('capture comments $width ${brightness.name}', (tester) async {
        tester.view.physicalSize = Size(width.toDouble(), 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final state = await makeState(tester);
        final vod = Vod(
          vodId: 'comments-capture',
          vodName: '漫长的季节',
          vodYear: '2023',
          vodArea: '中国大陆',
          vodContent: '三个时间线交错，讲的是一桩旧案和一群人过不去的十几年。',
          extra: {'type_name': '国产剧'},
        );
        state.seedDetailForTest(vod: vod);
        final key = GlobalKey();
        final theme = buildAppTheme(brightness);
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              theme: theme.copyWith(
                textTheme: theme.textTheme.apply(fontFamily: 'FixtureCJK'),
              ),
              home: DetailPage(state: state, vod: vod),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final section = find.byKey(const ValueKey('detail-external-comments'));
        await tester.scrollUntilVisible(
          section,
          400,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        // 短评区块顶到视口上沿：前后两版都从同一起点出图。
        Scrollable.ensureVisible(
          tester.element(section),
          alignment: 0.04,
          duration: Duration.zero,
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('短评（6'), findsOneWidget);
        await tester.runAsync(() => _capture(key, 'comments-$width-${brightness.name}'));
        expect(tester.takeException(), isNull);
      });
    }
  }
}
