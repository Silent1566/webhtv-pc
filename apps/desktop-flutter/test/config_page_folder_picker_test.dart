import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/config_pages.dart';
import 'package:webhtv_pc/ui/glass_dialog.dart';
import 'package:webhtv_pc/ui/glass_widgets.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/test_fonts.dart';

void main() {
  late Directory tempDir;
  late AppState state;
  late FilePickerPlatform originalPicker;
  late _DirectoryPicker picker;

  setUp(() async {
    originalPicker = FilePickerPlatform.instance;
    picker = _DirectoryPicker();
    FilePickerPlatform.instance = picker;
    tempDir = await Directory.systemTemp.createTemp('webhtv-config-folder-');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${tempDir.path}/config',
          'data': '${tempDir.path}/data',
          'cache': '${tempDir.path}/cache',
          'state': '${tempDir.path}/state',
        },
      ),
      log: LogService(),
    );
    await state.bootstrap();
  });

  tearDown(() async {
    FilePickerPlatform.instance = originalPicker;
    state.dispose();
    await tempDir.delete(recursive: true);
  });

  Finder input() => find.widgetWithText(TextField, '配置 URL / 本地路径 / JSON 文本');

  Future<void> openPage(
    WidgetTester tester, {
    Size size = const Size(1280, 950),
    Brightness brightness = Brightness.dark,
    GlobalKey? boundary,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final theme = buildAppTheme(brightness);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: boundary == null
              ? theme
              : theme.copyWith(
                  textTheme: theme.textTheme.apply(fontFamily: 'FixtureCJK'),
                  primaryTextTheme: theme.primaryTextTheme.apply(
                    fontFamily: 'FixtureCJK',
                  ),
                  appBarTheme: theme.appBarTheme.copyWith(
                    titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
                      fontFamily: 'FixtureCJK',
                    ),
                  ),
                  inputDecorationTheme: theme.inputDecorationTheme.copyWith(
                    labelStyle: theme.inputDecorationTheme.labelStyle?.copyWith(
                      fontFamily: 'FixtureCJK',
                    ),
                    hintStyle: theme.inputDecorationTheme.hintStyle?.copyWith(
                      fontFamily: 'FixtureCJK',
                    ),
                  ),
                  filledButtonTheme: FilledButtonThemeData(
                    style: theme.filledButtonTheme.style?.copyWith(
                      textStyle: WidgetStatePropertyAll(
                        theme.textTheme.labelLarge?.copyWith(
                          fontFamily: 'FixtureCJK',
                        ),
                      ),
                    ),
                  ),
                  outlinedButtonTheme: OutlinedButtonThemeData(
                    style: theme.outlinedButtonTheme.style?.copyWith(
                      textStyle: WidgetStatePropertyAll(
                        theme.textTheme.labelLarge?.copyWith(
                          fontFamily: 'FixtureCJK',
                        ),
                      ),
                    ),
                  ),
                ),
          home: ConfigPage(state: state),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String label) async {
    await tester.tap(find.text('选择本地文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets('本地选择统一为一个入口，文件与文件夹均在菜单内', (tester) async {
    await openPage(tester);
    expect(find.text('选择文件夹'), findsNothing);
    await tester.tap(find.text('选择本地文件'));
    await tester.pumpAndSettle();
    expect(find.text('选择文件（JSON / ZIP）'), findsOneWidget);
    expect(find.text('选择文件夹（猫源包）'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('选择文件夹（猫源包）'),
        matching: find.byType(GlassPane),
      ),
      findsNWidgets(2),
    );
    expect(find.byType(MenuItemButton), findsNWidgets(2));
    expect(find.text('输入本地配置文件路径'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('系统文件选择填入 ZIP 路径而不自动导入', (tester) async {
    picker.file = _PickedFile('/tmp/共享/dist (3).zip');
    await openPage(tester);
    await choose(tester, '选择文件（JSON / ZIP）');
    await tester.pumpAndSettle();
    // 平台无关：站点代码取的是 PlatformFile.path（即 uri.toFilePath()），
    // Windows 上 POSIX 字面量会变成反斜杠形式，直接比字面量只会在 POSIX 通过。
    expect(
      tester.widget<TextField>(input()).controller!.text,
      Uri.file('/tmp/共享/dist (3).zip').toFilePath(),
    );
    expect(state.savedConfigs, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('所选文件没有本地路径时保留输入并提示重新选择', (tester) async {
    picker.file = _PickedFile.uri(
      Uri.parse('https://example.test/config.json'),
    );
    await openPage(tester);
    await tester.enterText(input(), '/tmp/original.json');
    await choose(tester, '选择文件（JSON / ZIP）');
    await tester.pumpAndSettle();
    expect(find.textContaining('请选择本地文件'), findsOneWidget);
    expect(
      tester.widget<TextField>(input()).controller!.text,
      '/tmp/original.json',
    );
    expect(state.savedConfigs, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('取消系统文件选择保留原输入', (tester) async {
    await openPage(tester);
    await tester.enterText(input(), '/tmp/config.json');
    await choose(tester, '选择文件（JSON / ZIP）');
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(input()).controller!.text,
      '/tmp/config.json',
    );
    expect(state.savedConfigs, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选择系统文件夹后保留完整路径，点击导入前不执行配置', (tester) async {
    picker.pick = () async => '/tmp/猫源 本地包 (3)';
    await openPage(tester);

    await choose(tester, '选择文件夹（猫源包）');
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(input()).controller!.text,
      '/tmp/猫源 本地包 (3)',
    );
    expect(state.config, isNull);
    expect(state.savedConfigs, isEmpty);
    expect(find.byType(GlassAlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('取消系统文件夹选择不覆盖原输入', (tester) async {
    await openPage(tester);
    await tester.enterText(input(), 'https://example.test/config.json');

    await choose(tester, '选择文件夹（猫源包）');
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(input()).controller!.text,
      'https://example.test/config.json',
    );
    expect(state.savedConfigs, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('系统选择器失败可见报错并保留手动输入', (tester) async {
    picker.pick = () async => throw PlatformException(
      code: 'unavailable',
      message: 'native dialog unavailable',
    );
    await openPage(tester);
    await tester.enterText(input(), '/tmp/原猫源包');

    await choose(tester, '选择文件夹（猫源包）');
    await tester.pumpAndSettle();

    expect(find.textContaining('无法打开本地选择器'), findsOneWidget);
    expect(find.textContaining('手动输入'), findsOneWidget);
    expect(tester.widget<TextField>(input()).controller!.text, '/tmp/原猫源包');
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '选择本地文件'))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('文件夹选择期间禁止重复选择和并发导入', (tester) async {
    final pending = Completer<String?>();
    picker.pick = () => pending.future;
    await openPage(tester);

    await choose(tester, '选择文件夹（猫源包）');

    for (final label in ['选择本地文件', '使用仓库 fixture']) {
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, label))
            .onPressed,
        isNull,
        reason: label,
      );
    }
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '导入'))
          .onPressed,
      isNull,
    );

    pending.complete(null);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '导入'))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('选择器返回前离开页面不会更新已释放控件', (tester) async {
    final pending = Completer<String?>();
    picker.pick = () => pending.future;
    await openPage(tester);
    await choose(tester, '选择文件夹（猫源包）');

    await tester.pumpWidget(const SizedBox());
    pending.complete('/tmp/猫源');
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(state.savedConfigs, isEmpty);
  });

  final captureDir = Platform.environment['CONFIG_FOLDER_CAPTURE_DIR'];
  if (captureDir != null) {
    for (final variant in [
      (
        name: 'desktop-dark',
        size: const Size(1280, 950),
        brightness: Brightness.dark,
      ),
      (
        name: 'narrow-light',
        size: const Size(780, 950),
        brightness: Brightness.light,
      ),
    ]) {
      testWidgets('capture import page ${variant.name}', (tester) async {
        await tester.runAsync(() async {
          for (final family in [
            'FixtureCJK',
            'Microsoft YaHei UI',
            'Microsoft YaHei',
            'Noto Sans CJK SC',
          ]) {
            await loadFixtureFonts(cjkFamily: family);
          }
        });
        final boundary = GlobalKey();
        await openPage(
          tester,
          size: variant.size,
          brightness: variant.brightness,
          boundary: boundary,
        );
        expect(tester.takeException(), isNull);
        Future<void> saveCapture(String suffix) async {
          await tester.runAsync(() async {
            final render =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await render.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File('$captureDir/${variant.name}$suffix.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        await saveCapture('');
        await tester.tap(find.text('选择本地文件'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await saveCapture('-menu');
      });
    }
  }
}

final class _PickedFile extends PlatformFile {
  _PickedFile(String path) : uri = Uri.file(path);
  _PickedFile.uri(this.uri);

  @override
  final Uri uri;

  @override
  String get name => uri.pathSegments.last;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _DirectoryPicker extends FilePickerPlatform {
  Future<String?> Function() pick = () async => null;
  PlatformFile? file;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    return file;
  }

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) {
    return pick();
  }
}
