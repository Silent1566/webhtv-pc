import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, CachingAssetBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/lut.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/lut_store.dart';
import 'package:webhtv_pc/ui/lut_picker_sheet.dart';

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

List<int> cubeBytes({String title = 'Test'}) {
  final buffer = StringBuffer('TITLE "$title"\nLUT_3D_SIZE 2\n');
  for (var i = 0; i < 8; i++) {
    buffer.writeln('0.0 0.0 0.0');
  }
  return utf8.encode(buffer.toString());
}

void main() {
  late Directory root;
  late AppPaths paths;

  setUp(() {
    root = Directory.systemTemp.createTempSync('webhtv_lut_ui_test');
    paths = AppPaths.resolve(
      overrides: {
        'config': p.join(root.path, 'config'),
        'data': p.join(root.path, 'data'),
        'cache': p.join(root.path, 'cache'),
        'state': p.join(root.path, 'state'),
      },
    );
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  LutStore buildStore({http.Client? client}) => LutStore(
    paths: paths,
    bundle: _MemoryBundle(const <String, List<int>>{}),
    httpClient: client ?? MockClient((_) async => http.Response('', 404)),
  );

  testWidgets('列出 13 个内置预设并标出当前项', (tester) async {
    final store = buildStore();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LutPickerSheet(
            store: store,
            currentPath: '',
            currentPresetId: 'utopia',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('LUT 滤镜'), findsOneWidget);
    // 只有当前项带对勾。
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    // 未启用时不显示「清除 LUT」。
    expect(find.text('清除 LUT'), findsNothing);
    expect(find.text('33³'), findsWidgets);

    // ListView 懒挂载：屏幕外的条目根本不在树上，必须滚过去才算看过。
    for (final preset in builtinLutPresets) {
      await tester.scrollUntilVisible(
        find.text(preset.name),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(preset.name), findsOneWidget);
    }
  });

  testWidgets('选中内置预设后把结果交回调用方', (tester) async {
    final store = buildStore();
    LutPickerResult? captured;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  captured = await showModalBottomSheet<LutPickerResult>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => LutPickerSheet(
                      store: store,
                      currentPath: '',
                      currentPresetId: '',
                    ),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('赛博朋克'), findsOneWidget);

    await tester.tap(find.text('赛博朋克'));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.cleared, isFalse);
    expect(captured!.preset!.id, 'cyberpunk');
    expect(captured!.preset!.isBundled, isTrue);
  });

  testWidgets('已启用时提供清除入口并回传 cleared', (tester) async {
    final store = buildStore();
    LutPickerResult? captured;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  captured = await showModalBottomSheet<LutPickerResult>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => LutPickerSheet(
                      store: store,
                      currentPath: '/tmp/current.cube',
                      currentPresetId: '',
                    ),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('清除 LUT'), findsOneWidget);

    await tester.tap(find.text('清除 LUT'));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.cleared, isTrue);
    expect(captured!.preset, isNull);
  });

  testWidgets('在线搜索列出仓库，再列出 .cube', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path.contains('/search/repositories')) {
        return http.Response(
          jsonEncode({
            'items': [
              {
                'name': 'luts',
                'owner': {'login': 'someone'},
                'default_branch': 'main',
                'description': 'free luts',
                'stargazers_count': 7,
              },
            ],
          }),
          200,
        );
      }
      if (request.url.path.contains('/git/trees/')) {
        return http.Response(
          jsonEncode({
            'tree': [
              {'type': 'blob', 'path': 'looks/cine.cube'},
            ],
          }),
          200,
        );
      }
      return http.Response('', 404);
    });
    final store = buildStore(client: client);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LutPickerSheet(
            store: store,
            currentPath: '',
            currentPresetId: '',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 在线分区在列表下方，先滚到可见再操作。
    await tester.scrollUntilVisible(
      find.byType(TextField),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).decoration?.border,
      isNull,
      reason: 'LUT search must defer normal/focused/error border state to the theme',
    );
    await tester.enterText(find.byType(TextField), 'film');
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('someone/luts'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('someone/luts'), findsOneWidget);

    await tester.tap(find.text('someone/luts'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('looks/cine.cube'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('looks/cine.cube'), findsOneWidget);
  });
}
