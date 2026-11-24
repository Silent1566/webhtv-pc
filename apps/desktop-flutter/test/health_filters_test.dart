import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/site_self_check_panel.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'site_self_check_panel_test.dart' show HealthState, serviceFor;
import 'site_self_check_test.dart' show ProbeRouter, ProbeRuntime;

SiteHealth health(
  String key, {
  required int homeOk,
  required int homeTotal,
  int categoryOk = 0,
  int categoryTotal = 0,
  int detailOk = 0,
  int detailTotal = 0,
  int playOk = 0,
  int playTotal = 0,
  String? lastError,
}) => SiteHealth(
  siteKey: key,
  homeOk: homeOk,
  homeTotal: homeTotal,
  categoryOk: categoryOk,
  categoryTotal: categoryTotal,
  detailOk: detailOk,
  detailTotal: detailTotal,
  playOk: playOk,
  playTotal: playTotal,
  avgLatencyMs: 100,
  lastError: lastError,
  updatedAt: DateTime(2026, 11, 24),
);

class FilterHealthState extends HealthState {
  FilterHealthState(super.current, this.records);
  final List<SiteHealth> records;

  @override
  List<SiteHealth> siteHealth() => records;
}

Widget page(FilterHealthState state) => MaterialApp(
  theme: buildAppTheme(Brightness.dark),
  home: SiteHealthPage(state: state),
);

Future<void> search(WidgetTester tester, String text) async {
  await tester.enterText(
    find.byKey(const ValueKey('health-filter-name')),
    text,
  );
  await tester.pumpAndSettle();
}

Future<void> pick(WidgetTester tester, String dropdownKey, String label) async {
  await tester.tap(find.byKey(ValueKey(dropdownKey)));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'health history filters by fuzzy name and cumulative success/failure',
    (tester) async {
      final sites = [
        Site(
          key: 'alpha',
          name: 'Alpha 电影站',
          type: 1,
          api: 'https://a.invalid',
        ),
        Site(key: 'beta', name: 'Beta 剧集站', type: 1, api: 'https://b.invalid'),
        Site(
          key: 'gamma',
          name: 'Gamma 综艺站',
          type: 1,
          api: 'https://c.invalid',
        ),
        Site(
          key: 'delta',
          name: 'Delta 无记录',
          type: 1,
          api: 'https://d.invalid',
        ),
      ];
      final state = FilterHealthState(serviceFor(ProbeRuntime(), sites), [
        health(
          'alpha',
          homeOk: 2,
          homeTotal: 2,
          categoryOk: 1,
          categoryTotal: 2,
        ),
        health(
          'beta',
          homeOk: 0,
          homeTotal: 3,
          categoryOk: 0,
          categoryTotal: 0,
        ),
        health(
          'gamma',
          homeOk: 1,
          homeTotal: 1,
          categoryOk: 1,
          categoryTotal: 1,
        ),
      ]);
      addTearDown(state.dispose);
      await tester.pumpWidget(page(state));

      expect(find.text('Alpha 电影站'), findsOneWidget);
      expect(find.text('Beta 剧集站'), findsOneWidget);
      expect(find.text('Gamma 综艺站'), findsOneWidget);
      expect(find.text('显示 3 / 3 条记录'), findsOneWidget);

      await search(tester, 'ALPHA');
      expect(find.text('Alpha 电影站'), findsOneWidget);
      expect(find.text('Beta 剧集站'), findsNothing);
      expect(find.text('显示 1 / 3 条记录'), findsOneWidget);
      await search(tester, '');

      await pick(tester, 'health-filter-home', '有失败');
      expect(find.text('Beta 剧集站'), findsOneWidget);
      expect(find.text('Alpha 电影站'), findsNothing);
      expect(find.text('Gamma 综艺站'), findsNothing);
      expect(find.text('显示 1 / 3 条记录'), findsOneWidget);
      await pick(tester, 'health-filter-home', '全部成功');
      expect(find.text('Alpha 电影站'), findsOneWidget);
      expect(find.text('Gamma 综艺站'), findsOneWidget);
      expect(find.text('Beta 剧集站'), findsNothing);
      expect(find.text('显示 2 / 3 条记录'), findsOneWidget);
      await pick(tester, 'health-filter-category', '暂无数据');
      expect(find.text('没有匹配的站点记录。'), findsOneWidget);
      expect(find.text('显示 0 / 3 条记录'), findsOneWidget);
      await pick(tester, 'health-filter-category', '全部状态');
      await pick(tester, 'health-filter-home', '全部状态');

      await pick(tester, 'health-filter-category', '有成功');
      expect(find.text('Gamma 综艺站'), findsOneWidget);
      expect(find.text('Beta 剧集站'), findsNothing);
      await pick(tester, 'health-filter-category', '暂无数据');
      expect(find.text('Beta 剧集站'), findsOneWidget);
      expect(find.text('Alpha 电影站'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('health-filter-reset')));
      await tester.pumpAndSettle();
      expect(find.text('显示 3 / 3 条记录'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'health history empty result is explicit and reset restores rows',
    (tester) async {
      final state = FilterHealthState(
        serviceFor(ProbeRuntime(), [
          Site(
            key: 'alpha',
            name: 'Alpha 电影站',
            type: 1,
            api: 'https://a.invalid',
          ),
        ]),
        [health('alpha', homeOk: 1, homeTotal: 1)],
      );
      addTearDown(state.dispose);
      await tester.pumpWidget(page(state));
      await search(tester, '不存在');
      expect(find.textContaining('没有匹配的站点'), findsOneWidget);
      expect(find.byKey(const ValueKey('health-filter-reset')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('health-filter-reset')));
      await tester.pumpAndSettle();
      expect(find.text('Alpha 电影站'), findsOneWidget);
    },
  );

  testWidgets(
    'manual check filters result rows by conclusion and stage outcome',
    (tester) async {
      final runtime = ProbeRuntime();
      runtime.onHome = (site, _) async {
        if (site.key == 'bad') {
          throw AppError(AppErrorKind.siteNetwork, '首页失败');
        }
        return SiteResult(
          classes: const [VodClass(typeId: '1', typeName: '电影')],
          list: [Vod(vodId: 'v', vodName: '作品')],
        );
      };
      runtime.onCategory = (site, _, _) async {
        if (site.key == 'empty') {
          return const SiteResult();
        }
        return SiteResult(
          list: [Vod(vodId: 'v', vodName: '作品')],
        );
      };
      final sites = [
        Site(key: 'ok', name: 'Alpha 正常站', type: 1, api: 'https://a.invalid'),
        Site(key: 'bad', name: 'Beta 首页失败站', type: 1, api: 'https://b.invalid'),
        Site(
          key: 'empty',
          name: 'Gamma 分类空站',
          type: 1,
          api: 'https://c.invalid',
        ),
        Site(key: 'missing', name: 'Delta 运行时缺失', type: 3, api: 'csp_fixture'),
      ];
      final router = ProbeRouter(runtime, unavailable: {'missing'});
      addTearDown(router.dispose);
      final service = SiteService(
        appConfig: AppConfig(sites: sites),
        router: router,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [SiteSelfCheckPanel(service: service, sites: sites)],
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('self-check-select-all')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('self-check-start')));
      await tester.pumpAndSettle();
      expect(find.text('本批次已结束 · 4 / 4 站完成'), findsOneWidget);

      await tester.ensureVisible(
        find.byKey(const ValueKey('self-check-filter-name')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('self-check-filter-name')),
        'beta',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('self-check-result-bad')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('self-check-result-ok')), findsNothing);
      expect(find.text('显示 1 / 4 站'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('self-check-filter-name')),
        '',
      );
      await tester.pumpAndSettle();

      await pick(tester, 'self-check-filter-home', '失败');
      expect(
        find.byKey(const ValueKey('self-check-result-bad')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('self-check-result-ok')), findsNothing);
      expect(find.text('显示 1 / 4 站'), findsOneWidget);
      await pick(tester, 'self-check-filter-home', '成功');
      expect(
        find.byKey(const ValueKey('self-check-result-ok')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('self-check-result-empty')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('self-check-result-bad')), findsNothing);
      expect(find.text('显示 2 / 4 站'), findsOneWidget);
      await pick(tester, 'self-check-filter-home', '全部状态');

      await pick(tester, 'self-check-filter-category', '空内容');
      expect(
        find.byKey(const ValueKey('self-check-result-bad')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('self-check-result-empty')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('self-check-result-ok')), findsNothing);
      expect(find.text('显示 2 / 4 站'), findsOneWidget);
      await pick(tester, 'self-check-filter-category', '未检查');
      expect(
        find.byKey(const ValueKey('self-check-result-missing')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('self-check-result-bad')), findsNothing);
      expect(find.text('显示 1 / 4 站'), findsOneWidget);
      await pick(tester, 'self-check-filter-category', '全部状态');

      await pick(tester, 'self-check-filter-status', '内容检查通过');
      expect(
        find.byKey(const ValueKey('self-check-result-ok')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('self-check-result-empty')),
        findsNothing,
      );
      expect(find.text('显示 1 / 4 站'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('self-check-filter-reset')));
      await tester.pumpAndSettle();
      expect(find.text('显示 4 / 4 站'), findsOneWidget);
      for (final key in ['ok', 'bad', 'empty', 'missing']) {
        expect(find.byKey(ValueKey('self-check-result-$key')), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('manual filter never mutates selection or retry scope', (
    tester,
  ) async {
    final runtime = ProbeRuntime();
    runtime.onHome = (_, _) async => SiteResult(
      classes: const [VodClass(typeId: '1', typeName: '电影')],
      list: [Vod(vodId: 'home', vodName: '首页内容')],
    );
    final service = serviceFor(runtime, [
      Site(key: 'ok', name: 'Alpha 正常站', type: 1, api: 'https://a.invalid'),
      Site(key: 'bad', name: 'Beta 失败站', type: 1, api: 'https://b.invalid'),
    ]);
    runtime.onCategory = (site, _, _) async {
      if (site.key == 'bad') throw AppError(AppErrorKind.siteNetwork, '分类失败');
      return SiteResult(
        list: [Vod(vodId: 'v', vodName: '作品')],
      );
    };
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SiteSelfCheckPanel(
                service: service,
                sites: service.appConfig.sites,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('self-check-select-all')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('self-check-start')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('self-check-filter-name')),
    );
    await tester.enterText(
      find.byKey(const ValueKey('self-check-filter-name')),
      'alpha',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('self-check-result-bad')), findsNothing);
    await tester.ensureVisible(find.byKey(const ValueKey('self-check-retry')));
    await tester.tap(find.byKey(const ValueKey('self-check-retry')));
    await tester.pumpAndSettle();
    expect(runtime.homes.where((key) => key == 'bad'), hasLength(2));
    expect(runtime.homes.where((key) => key == 'ok'), hasLength(1));
    await tester.tap(find.byKey(const ValueKey('self-check-filter-reset')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('self-check-result-bad')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
