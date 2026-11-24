import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/csp_jar_probe.dart';
import 'package:webhtv_pc/services/jar_intake.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/spider_registry.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/spider_page.dart';
import 'package:webhtv_pc/ui/shell_runtime_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

const _probeKey = ValueKey('csp-jar-probe');
const _progressKey = ValueKey('shell-unpack-progress');
const _closeKey = ValueKey('shell-unpack-progress-close');
const _privateUrl =
    'https://user:password@example.test/private.jar?token=secret';

// Only the slow service boundary is replaced: the real page/button/modal run.
class _HeldProbeState extends AppState {
  _HeldProbeState(AppPaths paths) : super(paths: paths, log: LogService());

  Completer<CspProbeReport>? _result;
  Completer<CspProbeReport> get result =>
      _result ??= Completer<CspProbeReport>();
  void Function(ShellUnpackTick)? onProgress;
  int calls = 0;

  @override
  Future<CspProbeReport> probeCspJars({
    void Function(ShellUnpackTick)? onProgress,
  }) {
    calls++;
    this.onProgress = onProgress;
    return result.future;
  }

  @override
  Future<List<LocalSpider>> rescanSpiders() async => const [];

  @override
  List<InstalledJar> get installedCspJars => const [];

  @override
  String get cspRoot => 'fixture/spiders/csp';

  @override
  bool get shellRuntimeInstalled => false;

  void tick({Duration? eta}) => onProgress?.call(
    ShellUnpackTick(
      jarIndex: 1,
      jarCount: 3,
      jarUrl: _privateUrl,
      fraction: 0.35,
      stage: '预转译 dex',
      eta: eta,
    ),
  );
}

Future<void> _pumpPage(
  WidgetTester tester,
  _HeldProbeState state, {
  GlobalKey? boundary,
  bool runtimePage = false,
}) async {
  tester.view.physicalSize = const Size(1303, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundary,
      child: MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: runtimePage
            ? ShellRuntimePage(state: state)
            : Scaffold(body: SpiderPage(state: state)),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _capture(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
) async {
  final directory = Platform.environment['AUTO_PROBE_CAPTURE'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final image =
        await (boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$directory/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  late Directory temp;
  late _HeldProbeState state;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('webhtv-auto-probe-ui-');
    state = _HeldProbeState(
      AppPaths.resolve(
        overrides: {
          'config': temp.path,
          'data': temp.path,
          'cache': '${temp.path}/cache',
          'state': '${temp.path}/logs',
        },
      ),
    );
  });

  tearDown(() async {
    state.dispose();
    await temp.delete(recursive: true);
  });

  for (final runtimePage in [false, true]) {
    final probeKey = runtimePage
        ? const ValueKey('shell-runtime-probe')
        : _probeKey;
    group(runtimePage ? '运行时重新探测' : '自动探测', () {
      testWidgets(
        'probe button shows live progress before completion and resets busy',
        (tester) async {
          final boundary = GlobalKey();
          await _pumpPage(
            tester,
            state,
            boundary: boundary,
            runtimePage: runtimePage,
          );
          await tester.tap(find.byKey(probeKey));
          await tester.pump();
          expect(find.byKey(_progressKey), findsOneWidget);
          expect(find.text('预计剩余：计算中…'), findsOneWidget);
          expect(state.result.isCompleted, isFalse);
          state.tick(eta: const Duration(seconds: 83));
          await tester.pump();
          expect(find.text('第 2/3 个站点'), findsOneWidget);
          expect(find.text('阶段：预转译 dex'), findsOneWidget);
          expect(find.text('35%'), findsOneWidget);
          expect(find.text('预计剩余：01:23'), findsOneWidget);
          expect(find.textContaining('secret'), findsNothing);
          expect(find.textContaining('example.test'), findsNothing);
          final button = tester.widget<ButtonStyleButton>(find.byKey(probeKey));
          expect(button.onPressed, isNull);
          await tester.pump(const Duration(seconds: 5));
          expect(find.text('已用时：00:05'), findsOneWidget);
          expect(find.text('35%'), findsOneWidget);
          state.tick();
          await tester.pump();
          expect(find.text('预计剩余：计算中…'), findsOneWidget);
          await tester.pump(const Duration(seconds: 314));
          expect(find.text('已用时：05:19'), findsOneWidget);
          expect(find.text('35%'), findsOneWidget);
          expect(find.text('预计剩余：计算中…'), findsOneWidget);
          await _capture(
            tester,
            boundary,
            '${runtimePage ? 'runtime-reprobe' : 'auto-probe'}-after-running-319s-dark-1303x800',
          );
          state.result.complete(const CspProbeReport());
          await tester.pump();
          await tester.pump();
          expect(find.byKey(_closeKey), findsOneWidget);
          await tester.tap(find.byKey(_closeKey));
          await tester.pumpAndSettle();
          expect(find.byKey(_progressKey), findsNothing);
          expect(
            tester.widget<ButtonStyleButton>(find.byKey(probeKey)).onPressed,
            isNotNull,
          );
          expect(
            find.textContaining(runtimePage ? '没有需要探测' : '没有需要自动探测'),
            findsOneWidget,
          );
        },
      );

      testWidgets(
        'same-frame duplicate activation cannot launch a second probe',
        (tester) async {
          await _pumpPage(tester, state, runtimePage: runtimePage);
          final press = tester
              .widget<ButtonStyleButton>(find.byKey(probeKey))
              .onPressed!;
          press();
          press();
          await tester.pump();
          expect(state.calls, 1);
          state.result.complete(const CspProbeReport());
          await tester.pump();
          await tester.pump();
          await tester.tap(find.byKey(_closeKey));
          await tester.pumpAndSettle();
        },
      );

      testWidgets(
        'unexpected error becomes dismissible outcome and clears busy',
        (tester) async {
          await _pumpPage(tester, state, runtimePage: runtimePage);
          await tester.tap(find.byKey(probeKey));
          await tester.pump();
          state.result.completeError(StateError('failed at $_privateUrl'));
          await tester.pump();
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(find.text(runtimePage ? '重新探测失败' : '自动探测失败'), findsOneWidget);
          expect(find.textContaining('secret'), findsNothing);
          expect(find.byKey(_closeKey), findsOneWidget);
          await tester.tap(find.byKey(_closeKey));
          await tester.pumpAndSettle();
          expect(
            tester.widget<ButtonStyleButton>(find.byKey(probeKey)).onPressed,
            isNotNull,
          );
          expect(
            find.textContaining(runtimePage ? '重新探测失败' : '自动探测失败'),
            findsOneWidget,
          );
        },
      );

      testWidgets('unmount with pending probe and late progress is safe', (
        tester,
      ) async {
        await _pumpPage(tester, state, runtimePage: runtimePage);
        await tester.tap(find.byKey(probeKey));
        await tester.pump();
        await tester.pumpWidget(const SizedBox.shrink());
        state.tick();
        state.result.complete(const CspProbeReport());
        await tester.pump();
        await tester.pump(const Duration(seconds: 3));
        expect(tester.takeException(), isNull);
      });

      testWidgets(
        'failed report retains outcome without leaking private addresses',
        (tester) async {
          await _pumpPage(tester, state, runtimePage: runtimePage);
          await tester.tap(find.byKey(probeKey));
          await tester.pump();
          state.result.complete(
            const CspProbeReport(
              entries: [
                CspProbeEntry(
                  siteKey: 'csp_fixture',
                  outcome: CspProbeOutcome.failed,
                  jarUrl: _privateUrl,
                  message: '取回失败：$_privateUrl token=secret',
                ),
              ],
            ),
          );
          await tester.pump();
          await tester.pump();
          await tester.tap(find.byKey(_closeKey));
          await tester.pumpAndSettle();
          expect(
            find.textContaining(runtimePage ? '探测完成：' : '自动探测完成：'),
            findsOneWidget,
          );
          expect(find.textContaining('失败 1 个'), findsOneWidget);
          expect(find.textContaining('secret'), findsNothing);
          expect(find.textContaining('password'), findsNothing);
          expect(find.textContaining('example.test'), findsNothing);
          expect(
            tester.widget<ButtonStyleButton>(find.byKey(probeKey)).onPressed,
            isNotNull,
          );
        },
      );
    });
  }

  testWidgets('controlled actual-button dark capture', (tester) async {
    await tester.runAsync(() async {
      final font = ByteData.sublistView(
        await File('C:/Windows/Fonts/msyh.ttc').readAsBytes(),
      );
      for (final family in [
        'Roboto',
        'Microsoft YaHei UI',
        'Microsoft YaHei',
      ]) {
        await (FontLoader(family)..addFont(Future.value(font))).load();
      }
      final icons = ByteData.sublistView(
        await File(
          'C:/Users/Maple/.puro/envs/webhtv/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ).readAsBytes(),
      );
      await (FontLoader('MaterialIcons')..addFont(Future.value(icons))).load();
    });
    final boundary = GlobalKey();
    await _pumpPage(tester, state, boundary: boundary);
    await tester.tap(find.byKey(_probeKey));
    await tester.pump();
    state.tick();
    await tester.pump(const Duration(seconds: 319));
    await tester.pump(const Duration(milliseconds: 250));
    await _capture(
      tester,
      boundary,
      Platform.environment['AUTO_PROBE_BASELINE'] == '1'
          ? 'before-running-319s-dark-1303x800'
          : 'after-running-319s-dark-1303x800',
    );
    state.result.complete(const CspProbeReport());
    await tester.pump();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: Platform.environment['AUTO_PROBE_CAPTURE'] == null);
}
