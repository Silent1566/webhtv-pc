import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show ByteData, CachingAssetBundle, LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/lut.dart';
import 'package:webhtv_pc/core/player_options.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/lut_store.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/glass_dialog.dart';
import 'package:webhtv_pc/ui/lut_presets_page.dart';

AppPaths tempPaths(Directory temp) => AppPaths.resolve(
  overrides: {
    'config': p.join(temp.path, 'config'),
    'data': p.join(temp.path, 'data'),
    'cache': p.join(temp.path, 'cache'),
    'state': p.join(temp.path, 'state'),
  },
);

class _MemoryBundle extends CachingAssetBundle {
  _MemoryBundle(this.files);

  final Map<String, List<int>> files;

  @override
  Future<ByteData> load(String key) async {
    final bytes = files[key];
    if (bytes == null) throw FlutterError('Unable to load asset: $key');
    return ByteData.sublistView(Uint8List.fromList(bytes));
  }
}

/// 组件测试里不碰磁盘：真实 file I/O 在 fake-async 区里不会完成，pumpAndSettle
/// 会一直等。落盘本身已由 resolveLutSelection 那组用例覆盖，这里只验接线。
class _FakeStore extends LutStore {
  _FakeStore({required super.paths});

  final downloads = <String>[];

  @override
  Future<List<LutPreset>> listUserPresets() async => const [];

  @override
  Future<LutPreset> download(String url) async {
    downloads.add(url);
    return const LutPreset(
      path: '/downloaded/film.cube',
      name: 'Film',
      size: 2,
    );
  }

  @override
  Future<String> materialize(LutPreset preset) async =>
      '/fake/${preset.isBundled ? preset.id : lutIdFromPath(preset.path)}.cube';
}

class _LutSettingsState extends AppState {
  _LutSettingsState({required super.paths, required this.lutStore});

  @override
  final _FakeStore lutStore;

  @override
  bool get aiReady => false;

  final writes = <PlayerOptions>[];

  @override
  Future<bool> setPlayerOptions(PlayerOptions options) async {
    writes.add(options);
    return true;
  }
}

List<int> cube() {
  final buffer = StringBuffer('TITLE "T"\nLUT_3D_SIZE 2\n');
  for (var i = 0; i < 8; i++) {
    buffer.writeln('0 0 0');
  }
  return utf8.encode(buffer.toString());
}

void main() {
  late Directory temp;
  late AppPaths paths;
  late LutStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('webhtv-lut-page');
    paths = tempPaths(temp);
    store = LutStore(
      paths: paths,
      bundle: _MemoryBundle({
        for (final preset in builtinLutPresets) preset.path: cube(),
      }),
    );
  });

  tearDown(() {
    store.dispose();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  group('副标题摘要', () {
    test('未启用写「未启用」', () {
      expect(LutPresetsPage.summary(const PlayerOptions()), '未启用');
    });

    test('内置项写名字与尺寸', () {
      const options = PlayerOptions(
        lutPath: '/cache/lut/utopia.cube',
        lutPresetId: 'utopia',
      );
      expect(LutPresetsPage.summary(options), '当前：乌托邦 · 33³');
    });

    test('用户文件没有 id 时退回文件名', () {
      const options = PlayerOptions(lutPath: '/luts/my_look.cube');
      expect(LutPresetsPage.summary(options), '当前：my_look');
    });
  });

  group('resolveLutSelection', () {
    test('内置项落盘到 cacheDir/lut 并记住 id', () async {
      final next = await resolveLutSelection(
        current: const PlayerOptions(),
        preset: builtinLutPresets.first,
        store: store,
      );
      expect(next.lutPresetId, builtinLutPresets.first.id);
      expect(
        next.lutPath,
        p.join(
          paths.cacheDir,
          'lut',
          '${builtinLutPresets.first.id}.cube',
        ),
      );
      expect(File(next.lutPath).existsSync(), isTrue);
    });

    test('用户项原样写入路径、清空 preset id', () async {
      final file = File(p.join(paths.dataDir, 'lut', 'mine.cube'));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(cube());
      final next = await resolveLutSelection(
        current: const PlayerOptions(lutPath: '/old.cube', lutPresetId: 'x'),
        preset: LutPreset(path: file.path, name: 'Mine', size: 2),
        store: store,
      );
      expect(next.lutPath, file.path);
      expect(next.lutPresetId, isEmpty);
    });

    test('保留其它字段', () async {
      final next = await resolveLutSelection(
        current: const PlayerOptions(hardwareDecoding: false, autoNext: false),
        preset: builtinLutPresets.first,
        store: store,
      );
      expect(next.hardwareDecoding, isFalse);
      expect(next.autoNext, isFalse);
    });

    test('资源缺失时抛出 store 的异常，不改参数', () async {
      final broken = LutStore(
        paths: paths,
        bundle: _MemoryBundle(const <String, List<int>>{}),
      );
      await expectLater(
        resolveLutSelection(
          current: const PlayerOptions(),
          preset: builtinLutPresets.first,
          store: broken,
        ),
        throwsA(isA<LutStoreException>()),
      );
      broken.dispose();
    });
  });

  for (final action in ['Cancel', 'Escape', 'Download']) {
    testWidgets('Settings LUT link stays usable while dismissing via $action', (
      tester,
    ) async {
      final fake = _FakeStore(paths: paths);
      final state = _LutSettingsState(paths: paths, lutStore: fake);
      addTearDown(fake.dispose);
      addTearDown(state.dispose);
      await tester.pumpWidget(MaterialApp(home: SettingsPage(state: state)));
      await tester.tap(
        find.byKey(const ValueKey('settings-category-playback')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-lut-open')));
      await tester.pumpAndSettle();

      final entry = find.text('从链接导入…');
      await tester.ensureVisible(entry);
      await tester.pumpAndSettle();
      await tester.tap(entry);
      await tester.pumpAndSettle();

      final dialog = find.byType(GlassAlertDialog, skipOffstage: false);
      final field = find.descendant(
        of: dialog,
        matching: find.byType(EditableText, skipOffstage: false),
      );
      final route = ModalRoute.of(tester.element(dialog))!;
      final fieldFocus = tester.widget<EditableText>(field).focusNode;
      expect(fieldFocus.hasPrimaryFocus, isTrue);
      const url = 'https://example.invalid/film.cube';
      await tester.enterText(field, url);
      await tester.pump();
      expect(tester.takeException(), isNull);

      if (action == 'Escape') {
        final visited = <FocusNode>{fieldFocus};
        for (var i = 0; i < 3; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          final focused = FocusManager.instance.primaryFocus!;
          expect(ModalRoute.of(focused.context!), same(route));
          visited.add(focused);
        }
        expect(visited, hasLength(3));
        expect(fieldFocus.hasPrimaryFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      } else {
        await tester.tap(find.text(action == 'Cancel' ? '取消' : '下载'));
      }
      final errors = <String>[];
      final reverseFrames = <(int, double)>[];
      final onError = FlutterError.onError!;
      FlutterError.onError = (details) {
        errors.add('${details.exceptionAsString()}\n${details.stack}');
        onError(details);
      };
      try {
        await tester.pump();
        for (final millis in [16, 32]) {
          await tester.pump(Duration(milliseconds: millis));
          reverseFrames.add((field.evaluate().length, route.animation!.value));
          tester.takeException();
        }
        await tester.pumpAndSettle();
        tester.takeException();
      } finally {
        FlutterError.onError = onError;
      }
      expect(errors, isEmpty, reason: '$action while reversing');
      for (final (fields, progress) in reverseFrames) {
        expect(fields, 1);
        expect(progress, allOf(greaterThan(0), lessThan(1)));
      }
      expect(field, findsNothing);
      expect(fieldFocus.hasFocus, isFalse);
      final page = find.byType(LutPresetsPage);
      expect(page, findsOneWidget);
      if (action == 'Escape') {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final focused = FocusManager.instance.primaryFocus!;
        expect(
          ModalRoute.of(focused.context!),
          same(ModalRoute.of(tester.element(page))),
        );
        expect(tester.takeException(), isNull);
      }
      if (action == 'Download') {
        expect(fake.downloads, [url]);
        expect(state.writes.single.lutPath, '/fake/film.cube');
        expect(state.writes.single.lutPresetId, isEmpty);
        expect(find.text('清除 LUT'), findsOneWidget);
      } else {
        expect(fake.downloads, isEmpty);
        expect(state.writes, isEmpty);
      }
    });
  }

  group('明细页', () {
    Future<void> pump(
      WidgetTester tester, {
      PlayerOptions options = const PlayerOptions(),
      void Function(PlayerOptions)? onChanged,
    }) async {
      final fake = _FakeStore(paths: paths);
      addTearDown(fake.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: LutPresetsPage(
            store: fake,
            options: options,
            onChanged: onChanged ?? (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('列出 13 个内置预设', (tester) async {
      await pump(tester);
      for (final preset in builtinLutPresets) {
        await tester.scrollUntilVisible(
          find.byKey(ValueKey('lut-browser-builtin-${preset.id}')),
          160,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text(preset.name), findsOneWidget);
      }
    });

    testWidgets('已启用时显示清除入口与当前项', (tester) async {
      await pump(
        tester,
        options: const PlayerOptions(
          lutPath: '/cache/lut/utopia.cube',
          lutPresetId: 'utopia',
        ),
      );
      expect(find.text('清除 LUT'), findsOneWidget);
      // 当前项打勾：桶里唯一的 check_circle。
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });

    testWidgets('未启用时不显示清除入口', (tester) async {
      await pump(tester);
      expect(find.text('清除 LUT'), findsNothing);
    });

    testWidgets('点内置项后回写新参数', (tester) async {
      PlayerOptions? written;
      await pump(tester, onChanged: (value) => written = value);

      // 取列表里第一个（乌托邦）：它无需滚动就在首屏，点击不会因为
      // AppBar 遮挡或滚动动画而落空；滚动路径由上面「列出 13 个」那条覆盖。
      final key = ValueKey('lut-browser-builtin-${builtinLutPresets.first.id}');
      await tester.ensureVisible(find.byKey(key));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(key));
      await tester.pumpAndSettle();

      expect(written, isNotNull);
      expect(written!.lutPresetId, builtinLutPresets.first.id);
      expect(written!.lutPath, '/fake/${builtinLutPresets.first.id}.cube');
      // 页面自己也应该切到「已启用」形态。
      expect(find.text('清除 LUT'), findsOneWidget);
    });
  });
}
