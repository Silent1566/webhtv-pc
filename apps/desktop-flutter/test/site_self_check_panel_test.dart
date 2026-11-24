import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/services/spider_router.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/site_self_check_panel.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'site_self_check_test.dart'
    show ProbeRouter, ProbeRuntime, site, content;

Widget panel(
  SiteService? service, {
  List<Site>? sites,
  Brightness brightness = Brightness.light,
}) => MaterialApp(
  theme: buildAppTheme(brightness),
  home: Scaffold(
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SiteSelfCheckPanel(
          service: service,
          sites: sites ?? service?.appConfig.sites ?? const [],
        ),
      ],
    ),
  ),
);
SiteService serviceFor(ProbeRuntime runtime, List<Site> sites) {
  final router = ProbeRouter(runtime);
  addTearDown(router.dispose);
  return SiteService(
    appConfig: AppConfig(sites: sites),
    router: router,
  );
}

class HealthState extends AppState {
  HealthState(this.current);
  SiteService current;
  @override
  SiteService get siteService => current;
  @override
  List<SiteListItem> get siteItems => [
    for (final s in current.appConfig.sites)
      SiteListItem(
        site: s,
        availability: const SiteAvailability(
          available: true,
          runtimeName: 'fixture',
        ),
      ),
  ];
  @override
  List<SiteHealth> siteHealth() => const [];
  void replace(SiteService next) {
    current = next;
    notifyListeners();
  }
}

void main() {
  testWidgets(
    'health page preserves history and reacts to notified configuration change',
    (tester) async {
      final runtime = ProbeRuntime();
      final gate = Completer<SiteResult>();
      runtime.onHome = (_, _) => gate.future;
      final state = HealthState(serviceFor(runtime, [site('a')]));
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: SiteHealthPage(state: state),
        ),
      );
      expect(find.text('逐站明细'), findsOneWidget);
      expect(find.textContaining('还没有调用记录'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('site-health-self-check-open')),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('self-check-select-all')),
      );
      await tester.tap(find.byKey(const ValueKey('self-check-select-all')));
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const ValueKey('self-check-start')),
      );
      await tester.tap(find.byKey(const ValueKey('self-check-start')));
      await tester.pump();
      expect(runtime.homes, ['a']);
      final next = ProbeRuntime();
      state.replace(serviceFor(next, [site('b')]));
      await tester.pump();
      expect(runtime.signals.single.isCancelled, isTrue);
      expect(next.homes, isEmpty);
      expect(find.byKey(const ValueKey('self-check-site-b')), findsOneWidget);
      gate.complete(content());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('self-check-result-a')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('no config and no sites give recoverable empty states', (
    tester,
  ) async {
    await tester.pumpWidget(panel(null));
    expect(find.textContaining('请先导入'), findsOneWidget);
    final service = serviceFor(ProbeRuntime(), []);
    await tester.pumpWidget(panel(service));
    expect(find.textContaining('没有可选择的站点'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('self-check-start')))
          .onPressed,
      isNull,
    );
  });

  testWidgets(
    'manual select and run only, running locks selection, cancel and rerun',
    (tester) async {
      final runtime = ProbeRuntime();
      final gate = Completer<SiteResult>();
      runtime.onHome = (_, _) => gate.future;
      final service = serviceFor(runtime, [site('a'), site('b'), site('c')]);
      await tester.pumpWidget(panel(service));
      expect(runtime.homes, isEmpty);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('self-check-start')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('self-check-select-all')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('self-check-start')));
      await tester.pump();
      expect(runtime.homes.length, 2);
      expect(find.textContaining('0 / 3'), findsOneWidget);
      expect(find.textContaining('计入站点健康页的历史调用统计'), findsOneWidget);
      expect(find.textContaining('口径不同'), findsOneWidget);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('self-check-site-a')),
            )
            .onChanged,
        isNull,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('self-check-cancel')),
      );
      await tester.tap(find.byKey(const ValueKey('self-check-cancel')));
      await tester.pump();
      expect(runtime.signals.every((s) => s.isCancelled), isTrue);
      expect(find.text('本批次已结束 · 3 / 3 站完成'), findsOneWidget);
      expect(find.byKey(const ValueKey('self-check-retry')), findsOneWidget);
      runtime.onHome = (_, _) async => content();
      await tester.tap(find.byKey(const ValueKey('self-check-retry')));
      await tester.pumpAndSettle();
      expect(find.text('有限可用'), findsNWidgets(3));
      gate.complete(const SiteResult());
      await tester.pumpAndSettle();
      expect(find.text('有限可用'), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'service identity change cancels old batch and clears old selection/results',
    (tester) async {
      final old = ProbeRuntime();
      final gate = Completer<SiteResult>();
      old.onHome = (_, _) => gate.future;
      await tester.pumpWidget(panel(serviceFor(old, [site('old')])));
      await tester.tap(find.byKey(const ValueKey('self-check-select-all')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('self-check-start')));
      await tester.pump();
      final next = ProbeRuntime();
      await tester.pumpWidget(panel(serviceFor(next, [site('new')])));
      await tester.pump();
      expect(old.signals.single.isCancelled, isTrue);
      expect(next.homes, isEmpty);
      gate.complete(content());
      await tester.pumpAndSettle();
      expect(find.text('站点 old'), findsNothing);
      expect(find.byKey(const ValueKey('self-check-result-old')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'disposal cancels in flight work and late errors cannot update widget',
    (tester) async {
      final runtime = ProbeRuntime();
      final gate = Completer<SiteResult>();
      runtime.onHome = (_, _) => gate.future;
      await tester.pumpWidget(panel(serviceFor(runtime, [site('a')])));
      await tester.tap(find.byKey(const ValueKey('self-check-select-all')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('self-check-start')));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      expect(runtime.signals.single.isCancelled, isTrue);
      gate.completeError(StateError('late'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'scope is explicit and capped at 100 even with a larger configuration',
    (tester) async {
      final runtime = ProbeRuntime();
      final sites = List.generate(102, (i) => site('$i'));
      await tester.pumpWidget(panel(serviceFor(runtime, sites)));
      await tester.tap(find.byKey(const ValueKey('self-check-select-all')));
      await tester.pump();
      expect(find.textContaining('已选 100 / 102'), findsOneWidget);
      expect(runtime.homes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
