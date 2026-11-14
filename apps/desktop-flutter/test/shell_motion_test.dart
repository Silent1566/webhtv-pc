import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/app_motion.dart';
import 'package:webhtv_pc/ui/search_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

double _opacity(WidgetTester tester, Finder target) => tester
    .widgetList<FadeTransition>(
      find.ancestor(of: target, matching: find.byType(FadeTransition)),
    )
    .fold(1.0, (value, fade) => value * fade.opacity.value);

void main() {
  testWidgets('shell animation mounts each selected page exactly once', (
    tester,
  ) async {
    final initialized = <int>[];
    final disposed = <int>[];
    var selected = 0;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return AppShellTransition(
              sectionIndex: selected,
              child: _LifecyclePage(
                index: selected,
                initialized: initialized,
                disposed: disposed,
              ),
            );
          },
        ),
      ),
    );
    expect(initialized, [0]);
    expect(disposed, isEmpty);
    expect(
      _opacity(tester, find.byType(_LifecyclePage)),
      1,
      reason: '首次挂载不做空白入场',
    );
    update(() => selected = 1);
    await tester.pump();
    expect(initialized, [0, 1]);
    expect(disposed, [0]);
    for (final milliseconds in [16, 32, 64, 100]) {
      await tester.pump(Duration(milliseconds: milliseconds));
    }
    expect(initialized, [0, 1], reason: '动画帧不能重复初始化/启动页面副作用');
    update(() => selected = 2);
    await tester.pump();
    update(() => selected = 1);
    await tester.pump();
    expect(initialized, [0, 1, 2, 1]);
    expect(disposed, [0, 1, 2]);
    expect(find.byType(_LifecyclePage, skipOffstage: false), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 240));
    expect(initialized, [0, 1, 2, 1]);
    expect(disposed, [0, 1, 2]);
  });

  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('webhtv-shell-motion');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {'roaming': temp.path, 'local': temp.path},
      ),
      log: LogService(),
    );
    await state.bootstrap();
    await File(
      '${state.paths.configDir}${Platform.pathSeparator}usage-boundary-accepted',
    ).writeAsString('accepted');
  });
  tearDown(() async {
    state.dispose();
    await temp.delete(recursive: true);
  });

  Future<void> mount(
    WidgetTester tester, {
    bool disableAnimations = false,
    bool accessibleNavigation = false,
  }) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: disableAnimations,
            accessibleNavigation: accessibleNavigation,
          ),
          child: child!,
        ),
        home: AppShell(state: state, startup: const StartupArguments()),
      ),
    );
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 8)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byType(NavigationRail), findsOneWidget);
  }

  Future<void> select(WidgetTester tester, ShellSection section) async {
    tester
        .widget<NavigationRail>(find.byType(NavigationRail))
        .onDestinationSelected!(section.index);
    await tester.pump();
  }

  testWidgets(
    'shell switch is visible and moves only content within a stable shell',
    (tester) async {
      await mount(tester);
      final rail = tester.getRect(find.byType(NavigationRail));
      final manage = tester.getRect(
        find.byKey(const ValueKey('topbar-manage-config')),
      );
      await select(tester, ShellSection.settings);
      final target = find.byKey(const ValueKey('settings-theme-mode'));
      expect(target, findsOneWidget);
      final first = tester.getTopLeft(target);
      expect(_opacity(tester, target), allOf(greaterThan(0), lessThan(1)));
      await tester.pump(const Duration(milliseconds: 48));
      final middle = tester.getTopLeft(target);
      expect(middle.dx, lessThan(first.dx));
      expect(_opacity(tester, target), lessThan(1));
      await tester.pump(const Duration(milliseconds: 210));
      final end = tester.getTopLeft(target);
      expect(middle.dx, greaterThan(end.dx));
      expect(first.dy, end.dy, reason: '切页不改变净高度');
      expect(_opacity(tester, target), 1);
      expect(tester.getRect(find.byType(NavigationRail)), rail);
      expect(
        tester.getRect(find.byKey(const ValueKey('topbar-manage-config'))),
        manage,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rapid switches dispose leaving pages and keep input keys usable',
    (tester) async {
      await mount(tester);
      await select(tester, ShellSection.search);
      final original = tester.state(find.byType(SearchPage));
      final input = find.byKey(const ValueKey('search-input'));
      expect(input, findsOneWidget);
      await tester.enterText(input, '保留输入');
      await tester.pump();
      expect(original.mounted, isTrue, reason: '普通 rebuild 不能重挂页面');
      await select(tester, ShellSection.logs);
      expect(
        original.mounted,
        isFalse,
        reason: '离页立即销毁，不能因 outgoing 动画继续计时或请求',
      );
      expect(find.byType(SearchPage, skipOffstage: false), findsNothing);
      await tester.pump(const Duration(milliseconds: 24));
      await select(tester, ShellSection.search);
      final fresh = tester.state(find.byType(SearchPage));
      expect(fresh, isNot(same(original)));
      expect(input, findsOneWidget, reason: '动画期间不保留重复 key 的旧页');
      await tester.enterText(input, '立即可输入');
      expect(find.text('立即可输入'), findsOneWidget);
      await select(tester, ShellSection.settings);
      await select(tester, ShellSection.search);
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(SearchPage, skipOffstage: false), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-theme-mode'), skipOffstage: false),
        findsNothing,
      );
      expect(_opacity(tester, input), 1);
      expect(tester.widget<TextField>(input).focusNode!.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  for (final preference in ['disableAnimations', 'accessibleNavigation']) {
    testWidgets('$preference switches immediately without spatial motion', (
      tester,
    ) async {
      await mount(
        tester,
        disableAnimations: preference == 'disableAnimations',
        accessibleNavigation: preference == 'accessibleNavigation',
      );
      await select(tester, ShellSection.settings);
      final target = find.byKey(const ValueKey('settings-theme-mode'));
      final first = tester.getRect(target);
      expect(_opacity(tester, target), 1);
      await tester.pump(const Duration(milliseconds: 48));
      expect(tester.getRect(target), first);
      await select(tester, ShellSection.search);
      expect(find.byKey(const ValueKey('search-input')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-theme-mode'), skipOffstage: false),
        findsNothing,
      );
    });
  }
}

class _LifecyclePage extends StatefulWidget {
  const _LifecyclePage({
    required this.index,
    required this.initialized,
    required this.disposed,
  });
  final int index;
  final List<int> initialized;
  final List<int> disposed;

  @override
  State<_LifecyclePage> createState() => _LifecyclePageState();
}

class _LifecyclePageState extends State<_LifecyclePage> {
  @override
  void initState() {
    super.initState();
    widget.initialized.add(widget.index);
  }

  @override
  void dispose() {
    widget.disposed.add(widget.index);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Text('页面${widget.index}', key: const ValueKey('same-page-control'));
}
