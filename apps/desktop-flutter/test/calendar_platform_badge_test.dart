/// 追剧日历条目右上角的播放平台徽标：TMDB 的 networks（腾讯视频 / 爱奇艺…），
/// 与站点/站源名无关。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/following.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/tmdb_media.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/following_air_time_service.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/services/tmdb_stores.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/following_calendar_page.dart';
import 'package:webhtv_pc/ui/following_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

/// 含站点 `s` / `甲站` 的最小配置：用例 e 用它证明站点名不参与徽标。
const String _configJson = '''
{
  "name": "平台徽标测试",
  "sites": [
    {"key": "s", "name": "甲站", "type": 1, "api": "http://127.0.0.1:1/api/type1/", "searchable": 0}
  ]
}
''';

/// 今天中午 12 点（只由年月日决定，任何时刻都落在今天内；
/// 理由见 `phase9_calendar_page_test.dart` 的 `_todayNoonMs`）。
int _todayNoonMs() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day, 12).millisecondsSinceEpoch;
}

void main() {
  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('webhtv-calendar-badge');
    state = AppState(paths: _paths(temp, 'webhtv'), log: LogService());
    await state.bootstrap();
  });

  tearDown(() {
    state.dispose();
    _remove(temp);
  });

  testWidgets('TMDB 未配置：页面照常渲染、无平台徽标、无异常', (tester) async {
    final item = follow(state);
    await pumpPage(tester, state);
    await tester.pump();

    expect(state.tmdbConfig.isReady, isFalse);
    expect(platformBadge(), findsNothing);
    expect(
      find.byKey(ValueKey('calendar-card-${item.identityKey}-S01E12')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    // 取台名在未配置 TMDB 时既不联网也不抛。
    expect(await state.followingNetworksFor([item]), isEmpty);
  });

  group('TMDB 台名（注入可记录的 TMDB 客户端）', () {
    late Directory tmdbTemp;
    late AppState tmdbState;
    late List<Uri> requests;
    late List<String> networkNames;

    setUp(() async {
      requests = [];
      networkNames = const [];
      tmdbTemp = Directory.systemTemp.createTempSync(
        'webhtv-calendar-badge-tmdb',
      );
      final client = MockClient((request) async {
        requests.add(request.url);
        return http.Response(
          jsonEncode({
            'id': 4242,
            'networks': [
              for (final name in networkNames) {'name': name},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      tmdbState = AppState(
        paths: _paths(tmdbTemp, 'webhtv'),
        log: LogService(),
        // 记录 TMDB 请求：服务自己 new 的 client 拿不到，只能从构造口注入。
        tmdbService: TmdbService(
          config: () => tmdbState.tmdbConfig,
          client: client,
        ),
      );
      await tmdbState.bootstrap();
      // 排期服务换成假实现：`requests` 里只留平台徽标自己的请求。
      tmdbState.attachFollowingAirTimeService(
        FollowingAirTimeService(
          isConfigured: () => true,
          resolveTmdbId: (_) async => 4242,
          fetchEpisodes: (_, _) async => const [],
        ),
      );
    });

    tearDown(() {
      tmdbState.dispose();
      _remove(tmdbTemp);
    });

    Future<void> configure(WidgetTester tester) async {
      await tester.runAsync(() async {
        expect(
          await tmdbState.saveTmdbConfig(
            const TmdbConfig(
              apiBase: 'http://127.0.0.1:1/3',
              apiKey: 'local-fake',
            ),
          ),
          isTrue,
        );
      });
    }

    /// 已落盘的剧集匹配：省掉身份搜索，直奔剧集详情。
    void saveMatch() {
      DatabaseTmdbMatchStore(
        database: tmdbState.database!,
        configId: tmdbState.tmdbConfigId,
      ).putAuto(
        siteKey: 's',
        vodId: 'v1',
        sourceTitle: '测试剧',
        matchedAt: 1,
        item: TmdbItem(tmdbId: 4242, mediaType: TmdbMediaType.tv, title: '测试剧'),
      );
    }

    /// 徽标依赖一次未 await 的后台取数：多推几帧把微任务链跑完。
    Future<void> settleBadge(WidgetTester tester) async {
      for (var i = 0; i < 8; i += 1) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    /// 打开日历（TMDB 已配置 + 已有匹配），等后台取台名落到位。
    Future<String> openCalendar(WidgetTester tester) async {
      await configure(tester);
      saveMatch();
      final item = follow(tmdbState);
      requests.clear();
      await pumpPage(tester, tmdbState);
      await settleBadge(tester);
      return item.identityKey;
    }

    /// 只数剧集详情：`/tv/4242`（排期取集是 `/tv/4242/season/{n}`）。
    int detailRequests() =>
        requests.where((uri) => uri.path.endsWith('/tv/4242')).length;

    testWidgets('a) networks 转中文显示名后以 " / " 连接，插在箭头左侧', (tester) async {
      networkNames = const ['Tencent Video', 'iQIYI'];
      final identity = await openCalendar(tester);

      final card = find.byKey(ValueKey('calendar-card-$identity-S01E12'));
      expect(card, findsOneWidget);
      expect(platformBadge(), findsOneWidget);
      expect(badgeText(tester), '腾讯视频 / 爱奇艺');
      expect(tester.getSize(platformBadge()).width, greaterThan(0));

      final arrow = find.descendant(
        of: card,
        matching: find.byIcon(Icons.chevron_right),
      );
      expect(
        tester.getRect(platformBadge()).right,
        lessThan(tester.getRect(arrow).left),
      );
      expect(
        tester.getCenter(platformBadge()).dy,
        closeTo(tester.getCenter(arrow).dy, 1),
      );
      // 主行仍是「内容 + 间距 + 徽标 + 间距 + 箭头」，既有元素一个不少。
      expect(mainRowOf(tester, card).children.length, 5);
      expect(tester.takeException(), isNull);
    });

    testWidgets('b) 长台名完整显示：不省略、不溢出', (tester) async {
      networkNames = const ['National Geographic Channel', 'Hunan Television'];
      await openCalendar(tester);

      expect(platformBadge(), findsOneWidget);
      // 未收录的英文名原样保留，卫视走中文映射。
      expect(badgeText(tester), 'National Geographic Channel / 湖南卫视');
      // 不再被 132 夹住。
      expect(tester.getSize(platformBadge()).width, greaterThan(132));
      // 真正判「省略号」：文本没有因为 maxLines 被截断。
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: platformBadge(), matching: find.byType(RichText)),
      );
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('c) networks 为空：无徽标，主行保持原结构', (tester) async {
      networkNames = const [];
      final identity = await openCalendar(tester);

      final card = find.byKey(ValueKey('calendar-card-$identity-S01E12'));
      expect(card, findsOneWidget);
      expect(platformBadge(), findsNothing);
      expect(
        find.descendant(of: card, matching: find.byIcon(Icons.chevron_right)),
        findsOneWidget,
      );
      // 徽标为空时主行仍是「内容 + 间距 + 箭头」，不留空隙。
      expect(mainRowOf(tester, card).children.length, 3);
      expect(tester.takeException(), isNull);
    });

    testWidgets('e) 站点能查到名字也不影响徽标：值只来自 networks', (tester) async {
      networkNames = const ['Tencent Video', 'iQIYI'];
      await configure(tester);
      await importConfig(tester, tmdbState, _configJson);
      // 顺序要紧：导入会切换生效配置记录，匹配结论按记录 id 隔离。
      saveMatch();
      final item = follow(tmdbState);
      requests.clear();
      await pumpPage(tester, tmdbState);
      await settleBadge(tester);

      expect(
        tmdbState.siteByKey(item.siteKey)?.name,
        '甲站',
        reason: '前提：这个 siteKey 确实能在配置里查到站点名',
      );
      expect(platformBadge(), findsOneWidget);
      expect(badgeText(tester), '腾讯视频 / 爱奇艺');
    });

    testWidgets('g) 列表视角显示同一个平台徽标（following-platform-*）', (tester) async {
      networkNames = const ['Hunan Television', 'Mango TV'];
      await configure(tester);
      saveMatch();
      final item = follow(tmdbState);
      requests.clear();
      await pumpListPage(tester, tmdbState);
      await settleBadge(tester);

      final badge = find.byKey(
        ValueKey('following-platform-${item.identityKey}'),
      );
      expect(badge, findsOneWidget, reason: '列表卡也要显示播放平台');
      expect(
        find.descendant(of: badge, matching: find.text('湖南卫视 / 芒果TV')),
        findsOneWidget,
      );
      // 站点名（甲站）不参与徽标。
      expect(find.text('甲站'), findsNothing);
      expect(tester.takeException(), isNull);
      expect(detailRequests(), 1, reason: '列表视角同样只打一次剧集详情');
    });

    testWidgets('h) 同一天同一部剧多集：平台徽标只出现在首条', (tester) async {
      networkNames = const ['Hunan Television', 'Mango TV'];
      await configure(tester);
      saveMatch();
      // 平台连更：两集同一天播出，当天会出现两张卡。
      final now = DateTime.now();
      final today =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      tmdbState.attachFollowingAirTimeService(
        FollowingAirTimeService(
          isConfigured: () => true,
          resolveTmdbId: (_) async => 4242,
          fetchEpisodes: (_, _) async => [
            TmdbEpisode(number: 1, title: '第一集', date: today),
            TmdbEpisode(number: 2, title: '第二集', date: today),
          ],
        ),
      );
      follow(tmdbState);
      await pumpPage(tester, tmdbState);
      await settleBadge(tester);

      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'calendar-card-',
              ),
        ),
        findsNWidgets(2),
        reason: '同一天两集各占一张卡',
      );
      expect(platformBadge(), findsOneWidget, reason: '平台是剧级信息：只在当天该剧首条出现一次');
      expect(tester.takeException(), isNull);
    });

    testWidgets('f) 打开日历打一次 /tv/{id}，同一集合重复 build 不重复打', (tester) async {
      networkNames = const ['Youku'];
      await openCalendar(tester);

      expect(badgeText(tester), '优酷');
      expect(detailRequests(), 1, reason: 'TMDB 已配置时每部追番取一次台名');

      // 判重键生效：追番集合没变就不再请求。
      tmdbState.notifyListeners();
      await tester.pump();
      await settleBadge(tester);
      expect(detailRequests(), 1, reason: '同一集合重复 build 必须复用已取到的台名');
      expect(tester.takeException(), isNull);
    });
  });
}

Following follow(
  AppState target, {
  String siteKey = 's',
  String siteName = '甲站',
}) {
  final item = target.followFromDetail(
    site: Site(
      key: siteKey,
      name: siteName,
      type: 4,
      api: 'http://127.0.0.1:1/vod',
    ),
    vod: Vod(vodId: 'v1', vodName: '测试剧'),
    flag: '线路一',
    sourceFlag: '线路一',
    releasedEpisode: 12,
  )!;
  final updated = item.copyWith(
    latestReleasedEpisode: 12,
    seasonReleasedEpisodes: 12,
    watchedEpisode: 0,
    readWatermarkEpisode: 0,
    nextAirAtMs: _todayNoonMs(),
    status: FollowingStatus.returning,
  );
  target.database!.upsertFollowing(updated);
  target.notifyListeners();
  return updated;
}

Future<void> importConfig(
  WidgetTester tester,
  AppState target,
  String json,
) async {
  await tester.runAsync(() async {
    expect(await target.importConfig(json), isTrue, reason: '配置导入应成功');
  });
}

Future<void> pumpPage(WidgetTester tester, AppState target) async {
  tester.view.physicalSize = const Size(1100, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      home: Scaffold(body: FollowingCalendarView(state: target)),
    ),
  );
  await tester.pump();
}

/// 追剧页（列表视角）：平台徽标在列表卡上也要出现，且与日历同一个组件。
Future<void> pumpListPage(WidgetTester tester, AppState target) async {
  tester.view.physicalSize = const Size(1100, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      home: Scaffold(body: FollowingPage(state: target)),
    ),
  );
  await tester.pump();
}

/// 卡片（`calendar-card-*`）里的平台徽标。
Finder platformBadge() => find.byWidgetPredicate(
  (widget) =>
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith('calendar-platform-'),
);

String badgeText(WidgetTester tester) => tester
    .widget<Text>(
      find.descendant(of: platformBadge(), matching: find.byType(Text)),
    )
    .data!;

/// 主行 = 含箭头的那一行。
Row mainRowOf(WidgetTester tester, Finder card) => tester
    .widgetList<Row>(find.descendant(of: card, matching: find.byType(Row)))
    .firstWhere(
      (row) => row.children.any(
        (child) => child is Icon && child.icon == Icons.chevron_right,
      ),
    );

AppPaths _paths(Directory root, String name) => AppPaths.resolve(
  overrides: {
    'config': '${root.path}${Platform.pathSeparator}$name',
    'data': '${root.path}${Platform.pathSeparator}$name',
    'cache': '${root.path}${Platform.pathSeparator}$name/cache',
    'state': '${root.path}${Platform.pathSeparator}$name/logs',
  },
);

void _remove(Directory root) {
  try {
    root.deleteSync(recursive: true);
  } catch (_) {}
}
