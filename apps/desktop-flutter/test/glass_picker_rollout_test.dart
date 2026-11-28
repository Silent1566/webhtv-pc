import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/config_pages.dart';
import 'package:webhtv_pc/ui/danmaku_settings_page.dart';
import 'package:webhtv_pc/ui/subtitle_settings_page.dart';
import 'package:webhtv_pc/ui/glass_chrome.dart';
import 'package:webhtv_pc/ui/settings_detail_pages.dart';
import 'package:webhtv_pc/ui/startup_arguments.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/detail_test_seams.dart';
import 'support/test_fonts.dart';
import 'support/widget_settle.dart';

const _wallpaperUrl = 'https://fixture.test/picker-wallpaper.png';
const _viewport = Size(1072, 728);
const _phaseKey = 'GLASS_PICKER_CAPTURE_PHASE';
const _searchKey = ValueKey('site-search');
const _helper = '选择一个配置后，浏览与直播会改用它的站点。当前配置不会被删除。';

enum _Picker {
  site(SitePickerDialog, '站点：甲[影视]', '关闭'),
  config(ConfigSwitcherDialog, '配置：演示', '取消');

  const _Picker(this.type, this.entry, this.cancel);

  final Type type;
  final String entry;
  final String cancel;

  Finder get dialog => find.byType(type);
  Finder get surface => inside(
    find.byWidgetPredicate(
      (widget) => widget is Material && widget.type == MaterialType.card,
    ),
  );
  Finder inside(Finder matching) =>
      find.descendant(of: dialog, matching: matching);

  Future<void> open(WidgetTester tester) async {
    await tester.tap(
      find.descendant(of: find.byType(GlassTopBar), matching: find.text(entry)),
    );
    await settle(tester);
    expect(dialog, findsOneWidget);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.tap(inside(find.text(cancel)).hitTestable());
    await settle(tester);
    expect(dialog, findsNothing);
  }
}

void main() {
  late _PickerState state;
  late Directory temp;
  late int first;
  late int second;
  final phase = Platform.environment[_phaseKey];

  setUpAll(() async {
    await loadFixtureFonts();
    final cjk = firstExisting(cjkFontCandidates());
    if (phase != null) expectFontsAvailableOrSkip();
    if (cjk == null) return;
    final data = ByteData.sublistView(await cjk.readAsBytes());
    // Material component themes keep the app's Latin/CJK fallbacks even when
    // the fixture theme's textTheme uses FixtureCJK directly.
    for (final family in ['Roboto', 'Noto Sans CJK SC']) {
      await (FontLoader(family)..addFont(Future.value(data))).load();
    }
  });

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('webhtv-glass-pickers');
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/config',
        'data': '${temp.path}/data',
        'cache': '${temp.path}/cache',
        'state': '${temp.path}/state',
      },
    );
    state = _PickerState(paths: paths);
    await state.bootstrap();
    await File('${paths.configDir}/usage-boundary-accepted')
        .writeAsString('fixture');
    int seed(String name, String slug) => state.database!.saveConfig(
      name: name,
      origin: 'https://fixture.test/$slug.json',
      json: {
        'wallpaper': _wallpaperUrl,
        'sites': [
          {
            'key': 'alpha',
            'name': '甲[影视]',
            'type': 0,
            'api': 'https://fixture.test/alpha',
            'searchable': 1,
          },
          {
            'key': 'beta',
            'name': '乙[动画]',
            'type': 0,
            'api': 'https://fixture.test/beta',
            'searchable': 1,
          },
        ],
      },
      siteCount: 2,
      makeActive: false,
    );
    first = seed('演示', 'primary');
    second = seed('备用', 'backup');
    expect(await state.activateConfigRecord(first), isTrue);
    expect(state.selectedSite?.key, 'alpha');
  });

  tearDown(() async {
    state.dispose();
    await temp.delete(recursive: true);
  });

  Future<void> mount(
    WidgetTester tester,
    GlobalKey boundary, {
    required Brightness brightness,
    Size size = _viewport,
    bool nested = false,
    _WallpaperFrame? wallpaper,
    bool decodeWallpaper = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const provider = NetworkImage(_wallpaperUrl);
    final cache = PaintingBinding.instance.imageCache;
    final frame = wallpaper ?? _WallpaperFrame();
    cache.putIfAbsent(provider, () => frame);
    addTearDown(() => cache.evict(provider));
    if (decodeWallpaper) await frame.paint(tester, inverted: false);
    final theme = buildAppTheme(brightness);
    final fixtureTheme = theme.copyWith(
      textTheme: theme.textTheme.apply(fontFamily: 'FixtureCJK'),
    );
    const localBarrier = Color(0x310A1820);
    final shell = AppShell(state: state, startup: const StartupArguments());
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: nested ? buildAppTheme(Brightness.dark) : fixtureTheme,
          home: nested
              ? Navigator(
                  onGenerateRoute: (_) => MaterialPageRoute<void>(
                    builder: (_) => Theme(
                      data: fixtureTheme,
                      child: DialogTheme(
                        data: fixtureTheme.dialogTheme.copyWith(
                          barrierColor: localBarrier,
                        ),
                        child: shell,
                      ),
                    ),
                  ),
                )
              : shell,
        ),
      ),
    );
    await settle(tester);
  }

  testWidgets(
    'settings first frame and broken wallpaper do not move the form',
    (tester) async {
      final wallpaper = _WallpaperFrame();
      await mount(
        tester,
        GlobalKey(),
        brightness: Brightness.dark,
        wallpaper: wallpaper,
        decodeWallpaper: false,
        size: const Size(1024, 640),
      );
      Navigator.of(tester.element(find.byType(AppShell))).push<void>(
        MaterialPageRoute(builder: (_) => PlaybackOptionsPage(state: state)),
      );
      await settle(tester);
      final bar = find.byType(AppBar);
      final filter = find.descendant(
        of: bar,
        matching: find.byType(BackdropFilter),
      );
      final form = find.byType(ListView);
      final formRect = tester.getRect(form);
      final barRect = tester.getRect(bar);
      final back = find.descendant(of: bar, matching: find.byType(BackButton));
      expect(back.hitTestable(), findsOneWidget);
      expect(filter, findsOneWidget);
      await wallpaper.paint(tester, inverted: false);
      await settle(tester);
      expect(filter, findsOneWidget);
      expect(tester.getRect(form), formRect);
      expect(tester.getRect(bar), barRect);
      wallpaper.failDecode();
      await settle(tester);
      expect(filter, findsOneWidget);
      expect(tester.getRect(form), formRect);
      expect(tester.getRect(bar), barRect);
      expect(back.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('all opted-in common settings routes use one bar filter', (
    tester,
  ) async {
    await mount(
      tester,
      GlobalKey(),
      brightness: Brightness.dark,
      size: const Size(1024, 640),
    );
    final nav = Navigator.of(tester.element(find.byType(AppShell)));
    final pages = <Widget>[
      ConfigPage(state: state),
      PlaybackOptionsPage(state: state),
      SubtitleSettingsPage(state: state),
      DanmakuSettingsPage(state: state),
      LiveSettingsPage(state: state),
      TmdbSettingsPage(state: state),
      AndroidSettingsPage(state: state),
      OutboundProxyPage(state: state),
      DohSettingsPage(state: state),
    ];
    for (final page in pages) {
      nav.push<void>(MaterialPageRoute(builder: (_) => page));
      await settle(tester);
      final bar = find.byType(AppBar);
      expect(bar, findsOneWidget, reason: page.runtimeType.toString());
      expect(
        find.descendant(of: bar, matching: find.byType(BackdropFilter)),
        findsOneWidget,
        reason: page.runtimeType.toString(),
      );
      await tester.tap(
        find.descendant(of: bar, matching: find.byType(BackButton)),
      );
      await settle(tester);
      expect(bar, findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  for (final brightness in Brightness.values) {
    testWidgets('actual push dialog uses glass in ${brightness.name}', (
      tester,
    ) async {
      final boundary = GlobalKey();
      final wallpaper = _WallpaperFrame();
      await mount(
        tester,
        boundary,
        brightness: brightness,
        wallpaper: wallpaper,
      );
      await tester.tap(find.byKey(const ValueKey('topbar-push')));
      await settle(tester);
      final panel = find.byKey(const ValueKey('push-dialog'));
      expect(panel, findsOneWidget);
      final first = await _readFrame(
        tester,
        boundary,
        phase: Platform.environment['GLASS_PUSH_CAPTURE_PHASE'],
        fileStem: 'push-${brightness.name}',
        group: 'push-settings',
      );
      final filter = find.descendant(
        of: panel,
        matching: find.byType(BackdropFilter),
      );
      expect(filter, findsOneWidget);
      expect(
        ModalRoute.of(tester.element(panel))!.barrierColor,
        brightness == Brightness.dark
            ? const Color(0x8A000000)
            : const Color(0x2E000000),
      );
      final material = find
          .descendant(of: panel, matching: find.byType(ClipRRect))
          .first;
      final rect = tester.getRect(material);
      final label = find.textContaining('手机/安卓 App 经局域网');
      final labelContext = tester.element(label);
      final textStyle = tester.widget<Text>(label).style;
      final foreground =
          textStyle?.color ?? DefaultTextStyle.of(labelContext).style.color!;
      final probe = Offset(rect.right - 17, tester.getCenter(label).dy);
      await wallpaper.paint(tester, inverted: true);
      await settle(tester);
      final second = await _readFrame(tester, boundary);
      expect(
        _rgbDelta(first.pixel(probe), second.pixel(probe)),
        greaterThan(4),
      );
      for (final shot in [first, second]) {
        final values = [
          shot.pixel(probe).computeLuminance(),
          foreground.computeLuminance(),
        ]..sort();
        expect(
          (values.last + .05) / (values.first + .05),
          greaterThanOrEqualTo(4.5),
        );
      }
      await tester.tap(find.byKey(const ValueKey('push-dialog-close')));
      await settle(tester);
      expect(panel, findsNothing);
      expect(tester.takeException(), isNull);
    });

    for (final fromConfig in [true, false]) {
      final name = fromConfig ? 'management' : 'playback';
      testWidgets(
        'settings route $name samples wallpaper in ${brightness.name}',
        (tester) async {
          final boundary = GlobalKey();
          final wallpaper = _WallpaperFrame();
          await mount(
            tester,
            boundary,
            brightness: brightness,
            wallpaper: wallpaper,
          );
          if (fromConfig) {
            await _Picker.config.open(tester);
            await tester.tap(
              find.byKey(const ValueKey('config-switcher-manage')),
            );
          } else {
            Navigator.of(tester.element(find.byType(AppShell))).push<void>(
              MaterialPageRoute(
                builder: (_) => PlaybackOptionsPage(state: state),
              ),
            );
          }
          await settle(tester);
          final bar = find.byType(AppBar);
          final title = find.descendant(
            of: bar,
            matching: find.text(fromConfig ? '配置导入与管理' : '播放参数'),
          );
          expect(title, findsOneWidget);
          final first = await _readFrame(
            tester,
            boundary,
            phase: Platform.environment['GLASS_SETTINGS_CAPTURE_PHASE'],
            fileStem: '$name-${brightness.name}',
            group: 'push-settings',
          );
          expect(
            find.descendant(of: bar, matching: find.byType(BackdropFilter)),
            findsOneWidget,
          );
          final rect = tester.getRect(bar);
          final ink = Theme.of(tester.element(title)).colorScheme.onSurface;
          final probe = Offset(rect.width * .8, rect.center.dy);
          const bodyProbe = Offset(1054, 685);
          final firstTitleRect = tester.getRect(title);
          await wallpaper.paint(tester, inverted: true);
          await settle(tester);
          final second = await _readFrame(tester, boundary);
          expect(
            _rgbDelta(first.pixel(probe), second.pixel(probe)),
            greaterThan(10),
          );
          expect(
            _rgbDelta(second.pixel(bodyProbe), first.pixel(bodyProbe)),
            greaterThan(0),
            reason: 'full-route material now samples artwork beyond the AppBar',
          );
          expect(tester.getRect(title), firstTitleRect);
          for (final shot in [first, second]) {
            final values = [
              shot.pixel(probe).computeLuminance(),
              ink.computeLuminance(),
            ]..sort();
            expect(
              (values.last + .05) / (values.first + .05),
              greaterThanOrEqualTo(4.5),
            );
          }
          await tester.tap(
            find.descendant(of: bar, matching: find.byType(BackButton)),
          );
          await settle(tester);
          expect(title, findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final picker in _Picker.values) {
      testWidgets(
        'actual ${picker.name} picker takes clipped glass in ${brightness.name}',
        (tester) async {
          final boundary = GlobalKey();
          final frame = _WallpaperFrame();
          await mount(
            tester,
            boundary,
            brightness: brightness,
            wallpaper: frame,
          );
          await picker.open(tester);
          final surfaceRect = tester.getRect(picker.surface);
          final before = await _readFrame(
            tester,
            boundary,
            phase: phase,
            fileStem: '${picker.name}-${brightness.name}',
          );
          if (phase != null) {
            debugPrint('${picker.name}/${brightness.name} panel: $surfaceRect');
          }
          final filter = picker.inside(find.byType(BackdropFilter));
          expect(filter, findsOneWidget);
          final route = ModalRoute.of(tester.element(picker.dialog))!;
          expect(
            route.barrierColor,
            brightness == Brightness.dark
                ? const Color(0x8A000000)
                : const Color(0x2E000000),
          );
          final clip = picker.inside(
            find.byWidgetPredicate(
              (widget) => widget is ClipRRect && widget.child is BackdropFilter,
            ),
          );
          expect(clip, findsOneWidget);
          expect(tester.widget<ClipRRect>(clip).clipBehavior, isNot(Clip.none));
          expect(tester.getRect(filter), surfaceRect);
          expect(surfaceRect.left, greaterThan(0));
          expect(surfaceRect.top, greaterThan(0));
          expect(surfaceRect.right, lessThan(_viewport.width));
          expect(surfaceRect.bottom, lessThan(_viewport.height));

          await frame.paint(tester, inverted: true);
          await settle(tester);
          final changed = await _readFrame(tester, boundary);
          expect(tester.getRect(filter), surfaceRect);
          final panelSample = surfaceRect.topRight.translate(-36, 36);
          final backdropSample = const Offset(960, 680);
          final backdropDelta = _rgbDelta(
            before.pixel(backdropSample),
            changed.pixel(backdropSample),
          );
          final panelDelta = _rgbDelta(
            before.pixel(panelSample),
            changed.pixel(panelSample),
          );
          expect(
            backdropDelta,
            greaterThanOrEqualTo(8),
            reason: 'fixture must visibly change behind the dialog',
          );
          expect(
            panelDelta,
            greaterThanOrEqualTo(4),
            reason: 'a solid panel hides the backdrop change',
          );
          if (phase != null) {
            debugPrint(
              '  panel @ $panelSample: ${before.pixel(panelSample)} → '
              '${changed.pixel(panelSample)}; RGB Δ $panelDelta (backdrop Δ $backdropDelta)',
            );
          }
          final main = picker == _Picker.site ? '乙[动画]' : '备用';
          final supporting = picker == _Picker.site ? '影视' : _helper;
          for (final label in [main, supporting, picker.cancel]) {
            _checkContrast(
              tester,
              picker.inside(find.text(label)),
              surfaceRect,
              before,
              changed,
              report: phase != null,
            );
          }
        },
      );
    }

    testWidgets(
      'actual pickers remain keyboard and pointer operable in a narrow ${brightness.name} window',
      (tester) async {
        await mount(
          tester,
          GlobalKey(),
          brightness: brightness,
          size: const Size(600, 420),
        );
        await _Picker.site.open(tester);
        final siteRoute = ModalRoute.of(tester.element(_Picker.site.dialog));
        final search = _Picker.site.inside(find.byType(EditableText));
        expect(tester.widget<EditableText>(search).focusNode.hasFocus, isTrue);
        await _checkFocusLoop(tester, siteRoute);
        final movies = find.byKey(const ValueKey('site-group-影视'));
        expect(movies.hitTestable(), findsOneWidget);
        await tester.tap(movies);
        await settle(tester);
        expect(find.byKey(const ValueKey('site-option-beta')), findsNothing);
        await tester.tap(_Picker.site.inside(find.text('全部')));
        await settle(tester);
        await tester.enterText(find.byKey(_searchKey), '乙');
        await settle(tester);
        expect(find.byKey(const ValueKey('site-option-alpha')), findsNothing);
        final beta = find.byKey(const ValueKey('site-option-beta'));
        expect(beta.hitTestable(), findsOneWidget);
        await tester.tap(beta);
        await settle(tester);
        expect(_Picker.site.dialog, findsNothing);
        expect(state.selectedSite?.key, 'beta');

        await _Picker.config.open(tester);
        await _checkFocusLoop(
          tester,
          ModalRoute.of(tester.element(_Picker.config.dialog)),
        );
        expect(
          find.byKey(const ValueKey('config-switcher-manage')).hitTestable(),
          findsOneWidget,
        );
        await _Picker.config.close(tester);
        expect(state.activeRecord?.id, first);
        await _Picker.config.open(tester);
        await tester.tap(
          find.byKey(ValueKey('config-switch-option-$second')).hitTestable(),
        );
        await settle(tester);
        expect(_Picker.config.dialog, findsNothing);
        expect(state.activeRecord?.id, second);
      },
    );
  }

  testWidgets(
    'both pickers capture local theme, custom barrier, and root navigator',
    (tester) async {
      await mount(
        tester,
        GlobalKey(),
        brightness: Brightness.light,
        nested: true,
      );
      final shellContext = tester.element(find.byType(AppShell));
      final root = Navigator.of(shellContext, rootNavigator: true);
      for (final picker in _Picker.values) {
        await picker.open(tester);
        final dialogContext = tester.element(picker.dialog);
        final route = ModalRoute.of(dialogContext)!;
        expect(route, isA<DialogRoute<Object?>>());
        expect(route.navigator, same(root));
        expect(route.barrierColor, const Color(0x310A1820));
        expect(Theme.of(dialogContext).brightness, Brightness.light);
        await picker.close(tester);
      }
      expect(state.selectedSite?.key, 'alpha');
      expect(state.activeRecord?.id, first);
    },
  );
}

Future<void> _checkFocusLoop(
  WidgetTester tester,
  ModalRoute<dynamic>? route,
) async {
  expect(route?.traversalEdgeBehavior, TraversalEdgeBehavior.closedLoop);
  for (var i = 0; i < 12; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
      ModalRoute.of(FocusManager.instance.primaryFocus!.context!),
      same(route),
    );
  }
}

class _PickerState extends AppState {
  _PickerState({required super.paths})
    : super(
        log: MemoryOnlyLogService(),
        httpClient: MockClient((_) async => http.Response('{"list":[]}', 200)),
      );

  @override
  bool get externalMetaEnabled => false;

  @override
  Future<void> loadHome(Site site) async {}

  @override
  Future<void> startupConfigRefresh() async {}

  @override
  Future<void> maybeAutoCheckForUpdates() async {}
}

class _WallpaperFrame extends ImageStreamCompleter {
  void failDecode() => reportError(
    exception: StateError('fixture cannot decode wallpaper'),
    silent: true,
  );

  Future<void> paint(WidgetTester tester, {required bool inverted}) async {
    final image = (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      for (var i = 0; i < 16; i++) {
        final bright = (i >= 8) != inverted;
        canvas.drawRect(
          Rect.fromLTWH(i * 16, 0, 16, 174),
          Paint()
            ..color = bright
                ? (i.isEven ? Colors.white : const Color(0xFFFFDEB7))
                : (i.isEven ? Colors.black : const Color(0xFF20365A)),
        );
      }
      final picture = recorder.endRecording();
      try {
        return await picture.toImage(256, 174);
      } finally {
        picture.dispose();
      }
    }))!;
    setImage(ImageInfo(image: image));
  }
}

class _Frame {
  const _Frame(this.pixels, this.width);

  final ByteData pixels;
  final int width;

  Color pixel(Offset point) => Color(
    pixels.getUint32((point.dy.floor() * width + point.dx.floor()) * 4) >> 8 |
        0xFF000000,
  );
}

void _checkContrast(
  WidgetTester tester,
  Finder text,
  Rect surface,
  _Frame before,
  _Frame changed, {
  required bool report,
}) {
  final paragraph = tester.renderObject<RenderParagraph>(text);
  final span = paragraph.text;
  final box = paragraph
      .getBoxesForSelection(
        TextSelection(baseOffset: 0, extentOffset: span.toPlainText().length),
      )
      .first
      .toRect();
  // Sample the same line just before its first glyph, not the ink itself.
  final point = paragraph.localToGlobal(Offset(box.left - 5, box.center.dy));
  final ink = span.style!.color!;
  expect(surface.deflate(2).contains(point), isTrue);
  final colors = <Color>[];
  final ratios = <double>[];
  for (final frame in [before, changed]) {
    final backing = frame.pixel(point);
    colors.add(backing);
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        expect(
          _rgbDelta(
            frame.pixel(point.translate(dx.toDouble(), dy.toDouble())),
            backing,
          ),
          lessThanOrEqualTo(8),
          reason: '${span.toPlainText()} @ $point must be glyph-free',
        );
      }
    }
    final a = Color.alphaBlend(ink, backing).computeLuminance();
    final b = backing.computeLuminance();
    final ratio = a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
    ratios.add(ratio);
    expect(
      ratio,
      greaterThanOrEqualTo(4.5),
      reason: '${span.toPlainText()} ($ink on $backing) @ $point',
    );
  }
  if (report) {
    debugPrint(
      '  ${span.toPlainText()} @ (${point.dx.floor()}, ${point.dy.floor()}): '
      '$ink on $colors = ${ratios.map((ratio) => ratio.toStringAsFixed(2)).join(' / ')}',
    );
  }
}

int _rgbDelta(Color a, Color b) {
  final x = a.toARGB32();
  final y = b.toARGB32();
  return [0, 8, 16].fold(
    0,
    (sum, shift) => sum + (((x >> shift) & 255) - ((y >> shift) & 255)).abs(),
  );
}

Future<_Frame> _readFrame(
  WidgetTester tester,
  GlobalKey boundary, {
  String? phase,
  String? fileStem,
  String group = 'pickers',
}) async => (await tester.runAsync(() async {
  final render =
      boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await render.toImage(pixelRatio: 1);
  try {
    if (phase != null) {
      expect(phase, anyOf('before', 'after'));
      expect(fileStem, isNotNull);
      final file = File(
        '../../.local/glass-rollout-captures/$group/$fileStem-$phase.png',
      );
      await file.parent.create(recursive: true);
      await file.create(exclusive: true);
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await file.writeAsBytes(Uint8List.sublistView(png));
    }
    return _Frame(
      (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!,
      image.width,
    );
  } finally {
    image.dispose();
  }
}))!;
