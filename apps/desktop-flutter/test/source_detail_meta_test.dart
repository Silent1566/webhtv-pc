import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/source_detail_meta.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/tmdb_detail_view.dart' show TmdbPersonPage;
import 'package:webhtv_pc/ui/theme.dart';

const _overview = '来源接口简介：TMDB 未匹配时仍显示。';
const _year = '2024';
const _area = '中国大陆';
const _language = '汉语普通话';
const _genres = '来源类型,来源类型二,来源类型三,来源类型四';
const _actors = '张三, 李四，王五 / 赵六';
const _directors = '王导演 / 李导演';

class _ImageClient implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _ImageRequest();
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _ImageRequest implements HttpClientRequest {
  @override
  final HttpHeaders headers = _ImageHeaders();
  @override
  Future<HttpClientResponse> close() async => _ImageResponse();
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _ImageHeaders implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _ImageResponse extends Stream<List<int>> implements HttpClientResponse {
  final bytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  );
  @override
  int get statusCode => 200;
  @override
  int get contentLength => bytes.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<void> _loadFonts() async {
  final font = File('/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc');
  if (font.existsSync()) {
    await (FontLoader(
      'FixtureCJK',
    )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
  }
  final root =
      Platform.environment['FLUTTER_ROOT'] ?? '.local/linux-build/flutter';
  final icons = File(
    '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(icons.readAsBytes().then(ByteData.sublistView))).load();
  }
}

Vod _sourceVod() => Vod(
  vodId: 'source-meta-vod',
  vodName: '来源影视条目',
  vodContent: _overview,
  vodPic: 'https://fixture.test/poster.png',
  vodRemarks: '更新至第8集',
  vodYear: _year,
  vodArea: _area,
  vodDirector: _directors,
  vodActor: _actors,
  vodPlayFrom: '线路一',
  vodPlayUrl: r'第1集$https://fixture.test/1.m3u8',
  extra: {'type_name': _genres, 'vod_lang': _language},
);

void main() {
  test(
    'maps separators, caps genres and people, and keeps roles display-only',
    () {
      final data = sourceDetailMeta(
        Vod(
          vodId: 'meta',
          vodName: '来源标题',
          vodContent: '来源简介',
          vodPic: 'poster',
          vodYear: '2024',
          vodArea: '中国大陆/美国，英国',
          vodDirector: '导演甲、导演乙|导演丙',
          vodActor: '张三, 李四，王五 / 赵六、钱七|孙八',
          extra: {'type_name': '剧情,爱情，古装/悬疑、纪录|动作', 'vod_lang': '汉语普通话/粤语，英语'},
        ),
      );
      expect(data.title, '来源标题');
      expect(data.overview, '来源简介');
      expect(data.posterUrl, 'poster');
      expect(data.backdropUrls, ['poster']);
      expect(data.releaseDate, '2024');
      expect(data.yearLabel, '2024');
      expect(data.genres, ['剧情', '爱情', '古装']);
      expect(data.countries, ['中国大陆', '美国', '英国']);
      expect(data.languages, ['汉语普通话', '粤语', '英语']);
      expect(data.cast.map((person) => person.name), [
        '张三',
        '李四',
        '王五',
        '赵六',
        '钱七',
        '孙八',
      ]);
      expect(data.cast.every((person) => person.subtitle == '演员'), isTrue);
      expect(data.cast.every((person) => person.profileUrl == null), isTrue);
      expect(data.creators, isEmpty);
      expect(data.creatorTeam.map((person) => person.name), [
        '导演甲',
        '导演乙',
        '导演丙',
      ]);
      expect(data.creatorTeam.every((p) => p.subtitle == '导演'), isTrue);
      expect(data.directors, ['导演甲', '导演乙', '导演丙']);
      expect(data.allPeople.map((person) => person.name), [
        '张三',
        '李四',
        '王五',
        '赵六',
        '钱七',
        '孙八',
      ]);
      final ids = [
        ...data.cast.map((person) => person.personId),
        ...data.creatorTeam.map((person) => person.personId),
      ];
      expect(ids.toSet(), hasLength(ids.length));
      expect(ids.every((id) => id < 0), isTrue);
      expect(data.rating, 0);
      expect(data.tagline, isEmpty);
      expect(data.originalTitle, isEmpty);
    },
  );
  test('uses vod_class fallback and leaves missing source fields empty', () {
    final data = sourceDetailMeta(
      Vod(
        vodId: 'meta-empty',
        vodName: '只有标题',
        vodYear: '  ',
        extra: const {'type_name': '  ', 'vod_class': '喜剧|家庭'},
      ),
    );
    expect(data.releaseDate, isEmpty);
    expect(data.yearLabel, isEmpty);
    expect(data.genres, ['喜剧', '家庭']);
    expect(data.countries, isEmpty);
    expect(data.languages, isEmpty);
    expect(data.cast, isEmpty);
    expect(data.creators, isEmpty);
    expect(data.creatorTeam, isEmpty);
    expect(data.directors, isEmpty);
    expect(data.overview, isNull);
    expect(data.posterUrl, isNull);
    expect(data.backdropUrls, isEmpty);
    expect(data.rating, 0);
    expect(data.tagline, isEmpty);
  });
  test('caps actor and director lists at twenty without inventing entries', () {
    final actors = List.generate(25, (index) => '演员${index + 1}').join(',');
    final directors = List.generate(25, (index) => '导演${index + 1}').join('、');
    final data = sourceDetailMeta(
      Vod(
        vodId: 'meta-cap',
        vodName: '上限',
        vodActor: actors,
        vodDirector: directors,
        extra: const {'type_name': '剧情,剧情,  ,爱情'},
      ),
    );
    expect(data.cast, hasLength(20));
    expect(data.directors, hasLength(20));
    expect(data.creatorTeam, hasLength(20));
    expect(data.creatorTeam.every((person) => person.subtitle == '导演'), isTrue);
    expect(data.cast.first.name, '演员1');
    expect(data.cast.last.name, '演员20');
    expect(data.genres, ['剧情', '爱情']);
  });

  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(_loadFonts);

  setUp(() {
    debugNetworkImageHttpClientProvider = () => _ImageClient();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  tearDown(() => debugNetworkImageHttpClientProvider = null);

  testWidgets('source-only source detail shows interface chips and actors', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final temp = Directory.systemTemp.createTempSync('webhtv-source-meta');
    addTearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    const config = TmdbConfig(apiKey: 'fixture-key');
    final tmdbClient = MockClient(
      (request) async => http.Response(
        jsonEncode({'results': []}),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ),
    );
    final state = AppState(
      tmdbService: TmdbService(config: () => config, client: tmdbClient),
      paths: AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/webhtv-pc',
          'data': '${temp.path}/webhtv-pc',
          'cache': '${temp.path}/webhtv-pc/cache',
          'state': '${temp.path}/webhtv-pc/logs',
        },
      ),
      log: LogService(),
    );
    addTearDown(state.dispose);
    await tester.runAsync(state.bootstrap);
    await tester.runAsync(() => state.saveTmdbConfig(config));
    final vod = _sourceVod();
    await state.tmdb.loadForVod(vod, siteKey: 'fixture-site');
    expect(state.tmdb.matchResult, isA<TmdbMatchMiss>());
    state.seedDetailForTest(vod: vod);
    final boundary = GlobalKey();
    final theme = buildAppTheme(Brightness.dark);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          theme: theme.copyWith(
            textTheme: theme.textTheme.apply(fontFamily: 'FixtureCJK'),
          ),
          home: DetailPage(state: state, vod: vod),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    debugNetworkImageHttpClientProvider = null;
    final phase = Platform.environment['SOURCE_META_CAPTURE'] ?? '';
    if (phase.isNotEmpty) {
      await tester.pump();
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('../../.local/tmdb-overview/source-meta-$phase.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    expect(find.byKey(const ValueKey('tmdb-detail-year')), findsOneWidget);
    expect(find.text(_year), findsOneWidget);
    expect(find.byKey(const ValueKey('tmdb-detail-genres')), findsOneWidget);
    expect(find.text('来源类型 / 来源类型二 / 来源类型三'), findsOneWidget);
    expect(find.text('来源类型四'), findsNothing);
    expect(find.byKey(const ValueKey('tmdb-detail-countries')), findsOneWidget);
    expect(find.text(_area), findsOneWidget);
    expect(find.byKey(const ValueKey('tmdb-detail-languages')), findsOneWidget);
    expect(find.text(_language), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('tmdb-section-people')),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tmdb-section-people')), findsOneWidget);
    expect(find.text('演职人员（4）'), findsOneWidget);
    for (final name in ['张三', '李四', '王五', '赵六']) {
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('tmdb-people-wall')),
          matching: find.text(name),
        ),
        findsOneWidget,
      );
    }
    for (final name in ['王导演', '李导演']) {
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('tmdb-people-wall')),
          matching: find.text(name),
        ),
        findsNothing,
      );
    }
    expect(find.text('演员'), findsWidgets);
    final peoplePhase =
        Platform.environment['SOURCE_META_PEOPLE_CAPTURE'] ?? '';
    if (peoplePhase.isNotEmpty) {
      await tester.pump();
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(
          '../../.local/tmdb-overview/source-meta-people-$peoplePhase.png',
        );
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('tmdb-section-crew')),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('制作团队（2）'), findsOneWidget);
    for (final name in ['王导演', '李导演']) {
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('tmdb-crew-wall')),
          matching: find.text(name),
        ),
        findsOneWidget,
      );
    }
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('tmdb-crew-wall')),
        matching: find.text('张三'),
      ),
      findsNothing,
    );
    expect(find.text('导演'), findsWidgets);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('tmdb-crew-wall')),
        matching: find.text('王导演'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TmdbPersonPage), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('matched TMDB metadata replaces source-only chips and people', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final temp = Directory.systemTemp.createTempSync(
      'webhtv-source-meta-match',
    );
    addTearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    const config = TmdbConfig(apiKey: 'fixture-key');
    final tmdbClient = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'id': 42,
          'title': 'TMDB作品',
          'overview': 'TMDB 简介',
          'release_date': '2023-01-01',
          'vote_average': 8.0,
          'runtime': 100,
          'genres': [
            {'id': 1, 'name': 'TMDB类型'},
          ],
          'origin_country': ['美国'],
          'spoken_languages': [
            {'name': '英语', 'iso_639_1': 'en'},
          ],
          'credits': {
            'cast': [
              {'id': 1, 'name': 'TMDB演员'},
            ],
            'crew': [],
          },
          'created_by': [
            {'id': 2, 'name': 'TMDB导演'},
          ],
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final state = AppState(
      tmdbService: TmdbService(config: () => config, client: tmdbClient),
      paths: AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/webhtv-pc',
          'data': '${temp.path}/webhtv-pc',
          'cache': '${temp.path}/webhtv-pc/cache',
          'state': '${temp.path}/webhtv-pc/logs',
        },
      ),
      log: LogService(),
    );
    addTearDown(state.dispose);
    await tester.runAsync(state.bootstrap);
    await tester.runAsync(() => state.saveTmdbConfig(config));
    final vod = Vod(
      vodId: 'source-meta-matched',
      vodName: '来源影视条目',
      vodContent: _overview,
      vodYear: _year,
      vodArea: _area,
      vodDirector: _directors,
      vodActor: _actors,
      extra: {'type_name': _genres, 'vod_lang': _language},
    );
    final identity = TmdbIdentity.of(TmdbMediaType.movie, 42)!;
    await state.tmdb.loadForVod(
      vod,
      siteKey: 'fixture-site',
      knownIdentity: identity,
    );
    expect(state.tmdb.hasMatch, isTrue);
    expect(state.tmdb.detailData?.title, 'TMDB作品');
    state.seedDetailForTest(vod: vod);
    final theme = buildAppTheme(Brightness.dark);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme.copyWith(
          textTheme: theme.textTheme.apply(fontFamily: 'FixtureCJK'),
        ),
        home: DetailPage(state: state, vod: vod),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    debugNetworkImageHttpClientProvider = null;
    expect(find.text('2023'), findsOneWidget);
    expect(find.text('来源类型 / 来源类型二 / 来源类型三'), findsNothing);
    expect(find.text('TMDB类型'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('tmdb-section-people')),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('TMDB演员'), findsOneWidget);
    expect(find.text('TMDB导演'), findsOneWidget);
    for (final sourceName in ['张三', '王导演']) {
      expect(find.text(sourceName), findsNothing);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
