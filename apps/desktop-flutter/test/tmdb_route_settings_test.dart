/// TMDB 设置页的线路选择（内置预设 / 自定义）与「测试图片线路」。
///
/// 这一层是 UI 契约，四条各自的钉子：
/// 1. 内置预设必须真的落到 `state.tmdbUserConfig` 与 `settings.json`——只改下拉
///    不改配置等于没换线路；图片线路还必须把后景一起换掉（否则详情页背景照旧
///    走打不开的官方图床）。
/// 2. 手打自定义地址仍然是即时保存（既有语义不能被下拉吃掉）。
/// 3. 手改 settings.json 成任何未知地址都不能让下拉断言崩溃（要显示「自定义…」）。
/// 4. 「测试图片线路」把 `testTmdbImageRoute()` 的返回句显示出来，地址一变就清掉。
/// 5. 「自动」是**哨兵落盘、读取时解析**：settings.json 里必须是 `auto`，
///    输入框里必须是解析后的具体地址（摆字面量 `auto` 等于让用户去手打它）。
/// 6. 「当前实际线路」一行与「重新测速」只对自动线路成立：非自动时不写「自动」
///    后缀、也不出现测速按钮。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/tmdb_route.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/config_pages.dart';

import 'settings_immediate_forms_test.dart'
    show isolatedState, settleWrites, openForm;

/// pages.dev 反代的图片线路值（不含 `/t/p/<尺寸>`）。
const String _proxyImageRoute =
    'https://jsnzkpg4.pages.dev/https://image.tmdb.org';

/// 图片线路下拉里那条反代的标签。
///
/// 从 [tmdbImageRoutes] 取而不是再抄一份字符串：标签里带域名（线路重命名过
/// 一次），测试要钉的是「选中的是这条线路」，不是某个字面量。
String get proxyImageLabel =>
    tmdbImageRoutes.firstWhere((option) => option.value == _proxyImageRoute).label;

/// 测试用 AppState：关掉启动时的自动线路预热测速。
///
/// `warmAutoRoutes` 是 state 自带的测试开关。此刻它是**按构造必需的**：
/// `AppState` 构造函数在读配置前就按自动图片线路决定要不要预热，而配置 store
/// 要到 `bootstrap()` 才初始化（`lib/state/app_state.dart:406`，本 brief 边界
/// 之外）。关掉预热后构造函数不碰 store，设置页行为不受影响。
AppState _testState(AppPaths paths, LogService log) => AppState(
  paths: paths,
  log: log,
  warmAutoRoutes: false,
  externalPlayerDetector: () => const [],
);

Future<AppState> routeState(
  WidgetTester tester, {
  AppState Function(AppPaths, LogService)? create,
}) => isolatedState(tester, create: create ?? _testState);

Future<void> reach(
  WidgetTester tester,
  String key, {
  double delta = 300,
}) async {
  final target = find.byKey(ValueKey(key));
  await tester.scrollUntilVisible(
    target,
    delta,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(target);
  await tester.pump();
}

/// 下拉当前**显示**的选项文案（从 `DropdownButton.value` 反查候选）。
String routeLabel(WidgetTester tester, String key) {
  final button = tester.widget<DropdownButton<String>>(
    find.byKey(ValueKey(key)),
  );
  final item = button.items!.firstWhere((item) => item.value == button.value);
  return (item.child as Text).data!;
}

/// 打开线路下拉并点中某一项。
Future<void> pickRoute(
  WidgetTester tester,
  String key,
  String label,
) async {
  await reach(tester, key);
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await settleWrites(tester);
}

Map<String, dynamic> _settingsTmdb(AppState state) {
  final root =
      jsonDecode(File(state.paths.settingsPath).readAsStringSync())
          as Map<String, dynamic>;
  return (root['tmdb'] as Map).cast<String, dynamic>();
}

/// 只接管图片线路探测：不碰真实网络，返回句由用例控制。
class _RouteProbeState extends AppState {
  _RouteProbeState(AppPaths paths, LogService log)
    : super(
        paths: paths,
        log: log,
        warmAutoRoutes: false,
        externalPlayerDetector: () => const [],
      );

  int imageProbes = 0;
  Completer<String>? probe;

  @override
  Future<String> testTmdbImageRoute() {
    imageProbes++;
    return (probe = Completer<String>()).future;
  }
}

/// 只接管「重新测速」：不碰真实网络，返回句由用例控制。
class _RespeedState extends AppState {
  _RespeedState(AppPaths paths, LogService log)
    : super(
        paths: paths,
        log: log,
        warmAutoRoutes: false,
        externalPlayerDetector: () => const [],
      );

  int respeedCalls = 0;
  Completer<String>? respeed;

  @override
  Future<String> refreshTmdbAutoRoutes() {
    respeedCalls++;
    return (respeed = Completer<String>()).future;
  }
}

void main() {
  testWidgets('图片线路预设同时切换海报与后景并落盘 settings.json', (tester) async {
    final state = await routeState(tester);
    final proxy = tmdbImageRoutes.firstWhere(
      (option) => option.value == _proxyImageRoute,
    );
    await openForm(tester, TmdbSettingsPage(state: state));

    await pickRoute(tester, 'tmdb-image-route', proxy.label);

    expect(state.tmdbUserConfig.imageBase, '$_proxyImageRoute/t/p/w342');
    expect(state.tmdbUserConfig.backdropBase, '$_proxyImageRoute/t/p/w1280');
    final tmdb = _settingsTmdb(state);
    expect(tmdb['imageBase'], '$_proxyImageRoute/t/p/w342');
    expect(tmdb['backdropBase'], '$_proxyImageRoute/t/p/w1280');

    // 输入框回填归一后的地址：用户看到的必须是真正生效的那条。
    await reach(tester, 'tmdb-image-base');
    final input = tester.widget<TextField>(
      find.byKey(const ValueKey('tmdb-image-base')),
    );
    expect(input.controller!.text, '$_proxyImageRoute/t/p/w342');
    expect(input.decoration!.helperText, proxy.note);
    expect(routeLabel(tester, 'tmdb-image-route'), proxy.label);
    expect(tester.takeException(), isNull);
  });

  testWidgets('API 预设提交归一化后的地址（补 /3）', (tester) async {
    final state = await routeState(tester);
    final backup = tmdbApiRoutes.firstWhere(
      (option) => option.value == 'https://api.themoviedb.org',
    );
    await openForm(tester, TmdbSettingsPage(state: state));

    await pickRoute(tester, 'tmdb-api-route', backup.label);

    expect(state.tmdbUserConfig.apiBase, 'https://api.themoviedb.org/3');
    expect(_settingsTmdb(state)['apiBase'], 'https://api.themoviedb.org/3');
    await reach(tester, 'tmdb-api-base');
    final input = tester.widget<TextField>(
      find.byKey(const ValueKey('tmdb-api-base')),
    );
    expect(input.controller!.text, 'https://api.themoviedb.org/3');
    expect(input.decoration!.helperText, backup.note);
    expect(routeLabel(tester, 'tmdb-api-route'), backup.label);
    expect(tester.takeException(), isNull);
  });

  testWidgets('手打自定义地址仍然即时保存，下拉回到「自定义…」', (tester) async {
    final state = await routeState(tester);
    await openForm(tester, TmdbSettingsPage(state: state));
    await reach(tester, 'tmdb-api-base');
    await tester.enterText(
      find.byKey(const ValueKey('tmdb-api-base')),
      'https://example.test/3',
    );
    await settleWrites(tester);

    expect(state.tmdbUserConfig.apiBase, 'https://example.test/3');
    expect(_settingsTmdb(state)['apiBase'], 'https://example.test/3');
    await reach(tester, 'tmdb-api-route');
    expect(routeLabel(tester, 'tmdb-api-route'), '自定义…');
    final input = tester.widget<TextField>(
      find.byKey(const ValueKey('tmdb-api-base')),
    );
    // 自定义地址没有内置线路说明，helperText 只属于预设。
    expect(input.decoration!.helperText, isNull);

    // 手打图片地址：输入框原样保留用户打的串，后景必须同线路跟着换。
    await reach(tester, 'tmdb-image-base');
    await tester.enterText(
      find.byKey(const ValueKey('tmdb-image-base')),
      'https://images.example.test/w342',
    );
    await settleWrites(tester);

    expect(state.tmdbUserConfig.imageBase, 'https://images.example.test/w342');
    expect(
      state.tmdbUserConfig.backdropBase,
      'https://images.example.test/t/p/w1280',
    );
    final tmdb = _settingsTmdb(state);
    expect(tmdb['imageBase'], 'https://images.example.test/w342');
    expect(tmdb['backdropBase'], 'https://images.example.test/t/p/w1280');
  });

  testWidgets('点「自定义…」后下拉立即显示自定义，地址不变', (tester) async {
    final state = await routeState(tester);
    final official = tmdbImageRoutes.firstWhere(
      (option) => option.value == 'https://images.tmdb.org',
    );
    await openForm(tester, TmdbSettingsPage(state: state));
    // 先落到一条官方预设，确保「自定义…」前的下拉显示的是线路名。
    await pickRoute(tester, 'tmdb-image-route', official.label);
    final base = state.tmdbUserConfig.imageBase;
    final backdrop = state.tmdbUserConfig.backdropBase;
    final saved = _settingsTmdb(state)['imageBase'];

    await pickRoute(tester, 'tmdb-image-route', '自定义…');

    // 下拉立刻停在「自定义…」，但配置与磁盘一个字节都没动。
    expect(routeLabel(tester, 'tmdb-image-route'), '自定义…');
    expect(state.tmdbUserConfig.imageBase, base);
    expect(state.tmdbUserConfig.backdropBase, backdrop);
    expect(_settingsTmdb(state)['imageBase'], saved);

    // 手打未知地址后仍是「自定义…」（瞬态标志已清，反查自然落到哨兵）。
    await reach(tester, 'tmdb-image-base');
    await tester.enterText(
      find.byKey(const ValueKey('tmdb-image-base')),
      'https://images.example.test/t/p/w342',
    );
    await settleWrites(tester);
    await reach(tester, 'tmdb-image-route', delta: -300);
    expect(routeLabel(tester, 'tmdb-image-route'), '自定义…');
    expect(state.tmdbUserConfig.imageBase, 'https://images.example.test/t/p/w342');
  });

  testWidgets('手改 settings.json 成未知地址：下拉显示「自定义…」且不抛断言', (
    tester,
  ) async {
    final boot = await routeState(tester);
    final file = File(boot.paths.settingsPath);
    final root = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    // 新装的 settings.json 里还没有 tmdb 段（TMDB 从未保存过）。
    final tmdb = (root['tmdb'] is Map)
        ? (root['tmdb'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    tmdb['apiBase'] = 'https://api.example.test/3';
    tmdb['imageBase'] = 'https://images.example.test/t/p/w342';
    tmdb['backdropBase'] = 'https://images.example.test/t/p/w1280';
    root['tmdb'] = tmdb;
    file.writeAsStringSync(jsonEncode(root));

    final state = AppState(
      paths: boot.paths,
      log: LogService(),
      warmAutoRoutes: false,
      externalPlayerDetector: () => const [],
    );
    addTearDown(state.dispose);
    await tester.runAsync(state.bootstrap);
    expect(state.tmdbUserConfig.apiBase, 'https://api.example.test/3');
    expect(state.tmdbUserConfig.imageBase, 'https://images.example.test/t/p/w342');

    await openForm(tester, TmdbSettingsPage(state: state));
    await reach(tester, 'tmdb-api-route');
    expect(tester.takeException(), isNull);
    expect(routeLabel(tester, 'tmdb-api-route'), '自定义…');
    await reach(tester, 'tmdb-image-route');
    expect(routeLabel(tester, 'tmdb-image-route'), '自定义…');
    expect(tester.takeException(), isNull);
  });

  testWidgets('「测试图片线路」显示返回句，地址变化后清掉旧结果', (tester) async {
    final state =
        (await routeState(tester, create: _RouteProbeState.new))
            as _RouteProbeState;
    await openForm(tester, TmdbSettingsPage(state: state));
    await reach(tester, 'tmdb-image-test');
    await tester.tap(find.byKey(const ValueKey('tmdb-image-test')));
    await tester.pump();
    expect(state.imageProbes, 1);
    // 请求进行中禁用按钮，不重复发请求。
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('tmdb-image-test')),
          )
          .onPressed,
      isNull,
    );

    const sentence = '图片线路 images.tmdb.org 正常：HTTP 200 · 37.5 KB · 1.23s';
    state.probe!.complete(sentence);
    await tester.pump();
    await reach(tester, 'tmdb-image-test-result');
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('tmdb-image-test-result')),
          )
          .data,
      sentence,
    );

    // 换线路必须清掉旧结论：否则用户会拿旧线路的结果判断新线路。
    await pickRoute(tester, 'tmdb-image-route', proxyImageLabel);
    expect(find.byKey(const ValueKey('tmdb-image-test-result')), findsNothing);
    expect(state.imageProbes, 1);
  });

  testWidgets('图片「自动」：配置只存哨兵 auto，输入框显示解析后的具体地址', (tester) async {
    final state = await routeState(tester);
    final auto = tmdbImageRoutes.first;
    expect(auto.value, tmdbAutoRoute);
    await openForm(tester, TmdbSettingsPage(state: state));

    await pickRoute(tester, 'tmdb-image-route', auto.label);

    // 落盘与用户配置都只有哨兵：自动线路换线不改配置。
    expect(state.tmdbUserConfig.imageBase, 'auto');
    expect(state.tmdbUserConfig.backdropBase, 'auto');
    final tmdb = _settingsTmdb(state);
    expect(tmdb['imageBase'], 'auto');
    expect(tmdb['backdropBase'], 'auto');

    // 真正拼图用的是解析结果（海报 w342 / 后景 w1280 走同一条线路）。
    final resolved = state.tmdbConfig.imageBase;
    expect(resolved, isNot('auto'));
    expect(resolved.endsWith('/t/p/w342'), isTrue);
    expect(state.tmdbConfig.backdropBase.endsWith('/t/p/w1280'), isTrue);

    await reach(tester, 'tmdb-image-base');
    final input = tester.widget<TextField>(
      find.byKey(const ValueKey('tmdb-image-base')),
    );
    expect(input.controller!.text, resolved);
    expect(input.decoration!.helperText, auto.note);
    expect(routeLabel(tester, 'tmdb-image-route'), auto.label);
    expect(tester.takeException(), isNull);
  });

  testWidgets('API「自动」：配置存哨兵 auto，服务层读取仍是 auto（选路在请求时）', (
    tester,
  ) async {
    final state = await routeState(tester);
    final auto = tmdbApiRoutes.first;
    expect(auto.value, tmdbAutoRoute);
    await openForm(tester, TmdbSettingsPage(state: state));

    await pickRoute(tester, 'tmdb-api-route', auto.label);

    expect(state.tmdbUserConfig.apiBase, 'auto');
    expect(_settingsTmdb(state)['apiBase'], 'auto');
    // API 不做地址解析：候选在每次请求时按延迟/冷却挑。
    expect(state.tmdbConfig.apiBase, 'auto');

    final status = state.tmdbRouteStatus();
    expect(status.apiAuto, isTrue);
    expect(status.apiBase, isNot('auto'));
    expect(status.apiBase.endsWith('/3'), isTrue);
    await reach(tester, 'tmdb-api-base');
    final input = tester.widget<TextField>(
      find.byKey(const ValueKey('tmdb-api-base')),
    );
    expect(input.controller!.text, status.apiBase);
    expect(input.decoration!.helperText, auto.note);
    expect(routeLabel(tester, 'tmdb-api-route'), auto.label);
    expect(tester.takeException(), isNull);
  });

  testWidgets('「当前实际线路」行：自动时带「自动」后缀，非自动时只有主机', (tester) async {
    final state = await routeState(tester);
    await openForm(tester, TmdbSettingsPage(state: state));

    String statusText() => tester
        .widget<Text>(find.byKey(const ValueKey('tmdb-route-status')))
        .data!;

    // 默认就是自动线路：先固定两条线路，才谈得上「非自动」的形态。
    await pickRoute(
      tester,
      'tmdb-api-route',
      tmdbApiRoutes.firstWhere((o) => o.value == 'https://api.tmdb.org').label,
    );
    await pickRoute(
      tester,
      'tmdb-image-route',
      tmdbImageRoutes
          .firstWhere((o) => o.value == 'https://images.tmdb.org')
          .label,
    );
    await reach(tester, 'tmdb-route-status');
    expect(statusText(), contains('当前 API：'));
    expect(statusText(), contains(state.tmdbRouteStatus().apiHost));
    expect(statusText(), contains(state.tmdbRouteStatus().imageHost));
    // 非自动：不写「自动」，也不把哨兵漏到界面上。
    expect(statusText(), isNot(contains('自动')));
    expect(statusText(), isNot(contains('auto')));

    await pickRoute(tester, 'tmdb-image-route', tmdbImageRoutes.first.label);

    await reach(tester, 'tmdb-route-status');
    expect(statusText(), contains('自动'));
    // 自动时显示的是解析后的主机，不是字面量 auto。
    expect(statusText(), contains(state.tmdbRouteStatus().imageHost));
    expect(statusText(), isNot(contains('图片：auto')));
  });

  testWidgets('「重新测速」只在图片自动时出现，结论写在图片测试结果那一行', (tester) async {
    final state =
        (await routeState(tester, create: _RespeedState.new))
            as _RespeedState;
    await openForm(tester, TmdbSettingsPage(state: state));

    // 默认是自动线路；先固定一条——固定线路没有「测速择优」这回事，没有入口。
    await pickRoute(
      tester,
      'tmdb-image-route',
      tmdbImageRoutes
          .firstWhere((o) => o.value == 'https://images.tmdb.org')
          .label,
    );
    await reach(tester, 'tmdb-image-test');
    expect(find.byKey(const ValueKey('tmdb-route-respeed')), findsNothing);

    await pickRoute(tester, 'tmdb-image-route', tmdbImageRoutes.first.label);
    await reach(tester, 'tmdb-route-respeed');
    expect(find.byKey(const ValueKey('tmdb-route-respeed')), findsOneWidget);
    expect(find.text('重新测速'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tmdb-route-respeed')));
    await tester.pump();
    expect(state.respeedCalls, 1);
    // 测速中禁用：两次并发测速只会让延迟数字打架。
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('tmdb-route-respeed')),
          )
          .onPressed,
      isNull,
    );

    const sentence = '自动线路已测速：images.tmdb.org · 812 ms';
    state.respeed!.complete(sentence);
    await tester.pump();
    await settleWrites(tester);

    await reach(tester, 'tmdb-image-test-result');
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('tmdb-image-test-result')),
          )
          .data,
      sentence,
    );
    // 复用同一个结果 key：不新增第二个结果行。
    expect(find.byKey(const ValueKey('tmdb-image-test-result')), findsOneWidget);
    // 刷新后输入框仍显示解析后的地址。
    await reach(tester, 'tmdb-image-base', delta: -300);
    final input = tester.widget<TextField>(
      find.byKey(const ValueKey('tmdb-image-base')),
    );
    expect(input.controller!.text, state.tmdbConfig.imageBase);
    expect(input.controller!.text, isNot('auto'));
  });

  testWidgets('页面初始化：配置本来就是自动时，输入框直接显示解析后的地址', (tester) async {
    final boot = await routeState(tester);
    final file = File(boot.paths.settingsPath);
    final root = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final tmdb = (root['tmdb'] is Map)
        ? (root['tmdb'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    tmdb['apiBase'] = 'auto';
    tmdb['imageBase'] = 'auto';
    tmdb['backdropBase'] = 'auto';
    root['tmdb'] = tmdb;
    file.writeAsStringSync(jsonEncode(root));

    final state = AppState(
      paths: boot.paths,
      log: LogService(),
      warmAutoRoutes: false,
      externalPlayerDetector: () => const [],
    );
    addTearDown(state.dispose);
    await tester.runAsync(state.bootstrap);
    expect(state.tmdbUserConfig.imageBase, 'auto');
    expect(state.tmdbConfig.imageBase, isNot('auto'));

    await openForm(tester, TmdbSettingsPage(state: state));

    // 打开页面就显示解析后的地址：哨兵只存在于配置与磁盘里。
    final image = tester.widget<TextField>(
      find.byKey(const ValueKey('tmdb-image-base')),
    );
    expect(image.controller!.text, state.tmdbConfig.imageBase);
    expect(image.controller!.text.endsWith('/t/p/w342'), isTrue);
    final api = tester.widget<TextField>(
      find.byKey(const ValueKey('tmdb-api-base')),
    );
    expect(api.controller!.text, isNot('auto'));
    expect(api.controller!.text.endsWith('/3'), isTrue);

    await reach(tester, 'tmdb-route-status');
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('tmdb-route-status')))
          .data,
      contains('自动'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('自动时手打地址＝离开自动：存具体地址，「重新测速」随之消失', (tester) async {
    final state = await routeState(tester);
    await openForm(tester, TmdbSettingsPage(state: state));
    await pickRoute(tester, 'tmdb-image-route', tmdbImageRoutes.first.label);
    expect(state.tmdbUserConfig.imageBase, 'auto');
    await reach(tester, 'tmdb-route-respeed');
    // 离开自动要两条线路都固定：只要还剩一条自动，状态行就该保留「自动」。
    await pickRoute(
      tester,
      'tmdb-api-route',
      tmdbApiRoutes.firstWhere((o) => o.value == 'https://api.tmdb.org').label,
    );

    await reach(tester, 'tmdb-image-base', delta: -300);
    await tester.enterText(
      find.byKey(const ValueKey('tmdb-image-base')),
      'https://images.example.test/t/p/w342',
    );
    await settleWrites(tester);

    // 手打等于离开自动：地址原样存下来，后景跟到同一线路。
    expect(state.tmdbUserConfig.imageBase, 'https://images.example.test/t/p/w342');
    expect(_settingsTmdb(state)['imageBase'], 'https://images.example.test/t/p/w342');
    await reach(tester, 'tmdb-image-test');
    expect(find.byKey(const ValueKey('tmdb-route-respeed')), findsNothing);
    await reach(tester, 'tmdb-route-status', delta: -300);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('tmdb-route-status')))
          .data,
      isNot(contains('自动')),
    );
  });
}
