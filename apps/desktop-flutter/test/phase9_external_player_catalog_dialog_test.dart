import 'dart:async';
import 'dart:io';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/external_player.dart';
import 'package:webhtv_pc/ui/external_player_picker_dialog.dart';
import 'package:webhtv_pc/ui/theme.dart';

void main() {
  late Directory directory;
  late List<ExternalPlayer> players;
  late String first;
  late String second;
  late String third;
  late int saves;
  late String? original;
  late String? result;
  late bool closed;
  late bool saveSucceeds;
  late bool saveThrows;
  late int loads;
  late bool loadThrows;
  Completer<bool>? pendingSave;
  const captureKey = ValueKey('catalog-capture');

  setUp(() {
    directory = Directory.systemTemp.createTempSync('webhtv-catalog-dialog-');
    first = (File(
      '${directory.path}${Platform.pathSeparator}first.exe',
    )..createSync()).path;
    second = (File(
      '${directory.path}${Platform.pathSeparator}second.exe',
    )..createSync()).path;
    third = (File(
      '${directory.path}${Platform.pathSeparator}third.exe',
    )..createSync()).path;
    players = [
      ExternalPlayer(name: 'PotPlayer', executable: first),
      ExternalPlayer(name: 'PotPlayer', executable: second),
    ];
    saves = 0;
    loads = 0;
    original = null;
    result = null;
    closed = false;
    saveSucceeds = true;
    saveThrows = false;
    loadThrows = false;
    pendingSave = null;
  });
  tearDown(() => directory.deleteSync(recursive: true));

  Future<void> open(WidgetTester tester, {String? selectedPath}) async {
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showDialog<String>(
                    context: context,
                    builder: (_) => ExternalPlayerPickerDialog(
                      selectedPath: selectedPath,
                      loadPlayers: () async {
                        loads++;
                        if (loadThrows) throw StateError('fixture load failed');
                        return List.of(players);
                      },
                      savePlayer:
                          ({
                            String? originalExecutable,
                            required String name,
                            required String executable,
                          }) async {
                            saves++;
                            original = originalExecutable;
                            if (saveThrows) {
                              throw StateError('fixture write failed');
                            }
                            if (pendingSave != null) return pendingSave!.future;
                            if (!saveSucceeds) return false;
                            final index = players.indexWhere(
                              (player) =>
                                  player.executable == originalExecutable,
                            );
                            final value = ExternalPlayer(
                              name: name,
                              executable: executable,
                            );
                            if (index < 0) {
                              players.add(value);
                            } else {
                              players[index] = value;
                            }
                            return true;
                          },
                    ),
                  );
                  closed = true;
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
  }

  Finder nameField() => find.widgetWithText(TextField, '播放器名称');
  Finder pathField() => find.widgetWithText(TextField, '可执行文件路径');
  Future<void> fill(WidgetTester tester, String name, String path) async {
    await tester.enterText(nameField(), name);
    await tester.enterText(pathField(), path);
  }

  testWidgets('同名不同路径显示编号，编辑保留基础名称', (tester) async {
    await open(tester, selectedPath: first);
    expect(find.text('PotPlayer #1'), findsOneWidget);
    expect(find.text('PotPlayer #2'), findsOneWidget);
    expect(find.text(first), findsOneWidget);
    expect(find.text(second), findsOneWidget);
    await tester.tap(find.byTooltip('编辑播放器').first);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(nameField()).controller!.text, 'PotPlayer');
    expect(tester.widget<TextField>(pathField()).controller!.text, first);
  });

  testWidgets('新增只保存不使用，再打开从载入列表保留条目', (tester) async {
    await open(tester);
    await tester.tap(find.text('新增播放器'));
    await tester.pumpAndSettle();
    await fill(tester, '我的播放器', third);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('我的播放器'), findsOneWidget);
    expect(find.text(third), findsOneWidget);
    expect(saves, 1);
    expect(original, isNull);
    expect(loads, 2);
    expect(closed, isFalse);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('我的播放器'), findsOneWidget);
  });

  testWidgets('编辑名称和路径更新实际列表，再编辑传当前路径', (tester) async {
    await open(tester, selectedPath: first);
    await tester.tap(find.byTooltip('编辑播放器').first);
    await tester.pumpAndSettle();
    await fill(tester, '我的 PotPlayer', third);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(original, first);
    expect(find.text('我的 PotPlayer'), findsOneWidget);
    expect(find.text(third), findsOneWidget);
    expect(find.text(first), findsNothing);
    expect(find.text('PotPlayer #2'), findsNothing);
    expect(closed, isFalse);
    await tester.tap(find.byTooltip('编辑播放器').first);
    await tester.pumpAndSettle();
    await tester.enterText(nameField(), '第二次编辑');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(original, third);
    expect(players.length, 2);
    await tester.tap(find.text('使用'));
    await tester.pumpAndSettle();
    expect(result, third);
    expect(tester.takeException(), isNull);
  });

  testWidgets('取消编辑丢弃草稿，取消选择返回 null', (tester) async {
    await open(tester, selectedPath: first);
    await tester.tap(find.byTooltip('编辑播放器').first);
    await tester.pumpAndSettle();
    await fill(tester, '草稿', third);
    await tester.tap(find.text('取消编辑'));
    await tester.pumpAndSettle();
    expect(saves, 0);
    expect(find.text('PotPlayer #1'), findsOneWidget);
    await tester.tap(find.text('PotPlayer #2'));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(result, isNull);
    expect(tester.takeException(), isNull);
  });

  for (final throws in [false, true]) {
    testWidgets('保存${throws ? '抛异常' : '返回 false'}保留编辑器和草稿', (tester) async {
      saveSucceeds = false;
      saveThrows = throws;
      await open(tester);
      await tester.tap(find.byTooltip('编辑播放器').first);
      await tester.pumpAndSettle();
      await fill(tester, '草稿名称', third);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.textContaining('保存失败'), findsOneWidget);
      expect(tester.widget<TextField>(nameField()).controller!.text, '草稿名称');
      expect(tester.widget<TextField>(pathField()).controller!.text, third);
      expect(find.text('保存'), findsOneWidget);
      expect(find.text('使用'), findsNothing);
      expect(closed, isFalse);
      expect(loads, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('空名称、无效路径和脚本无法保存，无效所选文件不能使用', (tester) async {
    await open(tester, selectedPath: first);
    await tester.tap(find.text('新增播放器'));
    await tester.pumpAndSettle();
    await fill(tester, '', third);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('请输入播放器名称'), findsOneWidget);
    await fill(tester, '新播放器', '${directory.path}/missing.exe');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('文件不存在'), findsOneWidget);
    if (Platform.isWindows) {
      final script = File('${directory.path}/script.cmd')..createSync();
      await fill(tester, '脚本', script.path);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.textContaining('不支持脚本'), findsOneWidget);
    }
    expect(saves, 0);
    await tester.tap(find.text('取消编辑'));
    await tester.pumpAndSettle();
    File(first).deleteSync();
    await tester.tap(find.text('使用'));
    await tester.pumpAndSettle();
    expect(find.textContaining('文件不存在'), findsOneWidget);
    expect(closed, isFalse);
  });

  testWidgets('载入失败不允许使用，重试后显示真实列表', (tester) async {
    loadThrows = true;
    await open(tester, selectedPath: first);
    expect(find.textContaining('列表加载失败'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '使用'))
          .onPressed,
      isNull,
    );
    loadThrows = false;
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();
    expect(find.text('PotPlayer #1'), findsOneWidget);
  });

  testWidgets('保存成功但重新载入失败，重试不新增且保持所选新路径', (tester) async {
    await open(tester, selectedPath: first);
    await tester.tap(find.byTooltip('编辑播放器').first);
    await tester.pumpAndSettle();
    await fill(tester, '更新后的名称', third);
    loadThrows = true;
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已保存'), findsOneWidget);
    expect(nameField(), findsOneWidget);
    loadThrows = false;
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(original, third);
    expect(players.length, 2);
    await tester.tap(find.text('使用'));
    await tester.pumpAndSettle();
    expect(result, third);
  });

  testWidgets('保存后载入失败，取消编辑不能使用旧列表，重试取实际路径', (tester) async {
    await open(tester, selectedPath: first);
    await tester.tap(find.byTooltip('编辑播放器').first);
    await tester.pumpAndSettle();
    await fill(tester, '已保存的新名称', third);
    loadThrows = true;
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消编辑'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '使用'))
          .onPressed,
      isNull,
    );
    expect(find.text(first), findsNothing);
    loadThrows = false;
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();
    expect(find.text(third), findsOneWidget);
    await tester.tap(find.text('使用'));
    await tester.pumpAndSettle();
    expect(result, third);
  });

  for (final throwsOnRetry in [true, false]) {
    testWidgets(
      '保存刷新失败后再次保存${throwsOnRetry ? '抛异常' : '返回 false'}，取消和重载失败不能解除旧列表禁用',
      (tester) async {
        await open(tester, selectedPath: first);
        await tester.tap(find.byTooltip('编辑播放器').first);
        await tester.pumpAndSettle();
        await fill(tester, '已经保存的新名称', third);
        loadThrows = true;
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        expect(find.textContaining('已保存'), findsOneWidget);
        expect(players.first.executable, third);
        saveThrows = throwsOnRetry;
        saveSucceeds = false;
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        expect(loads, 2);
        expect(saves, 2);
        expect(original, third);
        expect(find.textContaining('保存失败'), findsOneWidget);
        expect(
          tester.widget<TextField>(nameField()).controller!.text,
          '已经保存的新名称',
        );
        expect(tester.widget<TextField>(pathField()).controller!.text, third);
        await tester.tap(find.text('取消编辑'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '使用'))
              .onPressed,
          isNull,
        );
        expect(find.text(first), findsNothing);
        expect(closed, isFalse);
        expect(result, isNull);
        await tester.tap(find.text('重新加载'));
        await tester.pumpAndSettle();
        expect(loads, 3);
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '使用'))
              .onPressed,
          isNull,
        );
        expect(find.text(first), findsNothing);
        loadThrows = false;
        await tester.tap(find.text('重新加载'));
        await tester.pumpAndSettle();
        expect(loads, 4);
        expect(find.text(third), findsOneWidget);
        expect(find.text(first), findsNothing);
        await tester.tap(find.text('使用'));
        await tester.pumpAndSettle();
        expect(result, third);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final completesSuccessfully in [false, true]) {
    testWidgets('保存等待中关闭选择框，完成为 $completesSuccessfully 时退场安全', (tester) async {
      pendingSave = Completer<bool>();
      await open(tester);
      await tester.tap(find.text('新增播放器'));
      await tester.pumpAndSettle();
      await fill(tester, '新播放器', third);
      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      pendingSave!.complete(completesSuccessfully);
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(closed, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  Future<void> loadCaptureFonts(WidgetTester tester) async {
    if (Platform.environment['EXTERNAL_PLAYER_VISUAL_DIR'] == null) return;
    await tester.runAsync(() async {
      for (final font in {
        'Roboto': 'C:/Windows/Fonts/segoeui.ttf',
        'Microsoft YaHei UI': 'C:/Windows/Fonts/msyh.ttc',
        'MaterialIcons': 'C:/dev/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        final loader = FontLoader(font.key);
        loader.addFont(
          File(font.value).readAsBytes().then(ByteData.sublistView),
        );
        await loader.load();
      }
    });
  }

  Future<void> capture(WidgetTester tester, String name) async {
    final output = Platform.environment['EXTERNAL_PLAYER_VISUAL_DIR'];
    if (output == null) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(captureKey),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$output${Platform.pathSeparator}$name.png')
          .writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final size in [const Size(1024, 640), const Size(1440, 900)]) {
    testWidgets(
      '尺寸 ${size.width.toInt()}x${size.height.toInt()} 长列表路径与编辑操作可达',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        await loadCaptureFonts(tester);
        final longFolder = Directory(
          '${directory.path}/${List.filled(8, 'long-path').join('-')}',
        )..createSync();
        final longFile = File('${longFolder.path}/last-player.exe')
          ..createSync();
        players.addAll([
          for (var index = 0; index < 12; index++)
            ExternalPlayer(
              name: '播放器 $index',
              executable: index == 11
                  ? longFile.path
                  : (File(
                      '${directory.path}/player-$index.exe',
                    )..createSync()).path,
            ),
        ]);
        await open(tester, selectedPath: second);
        expect(find.text('PotPlayer #1'), findsOneWidget);
        expect(find.text('PotPlayer #2'), findsOneWidget);
        expect(
          tester.widget<AlertDialog>(find.byType(AlertDialog)).elevation ?? 0,
          0,
        );
        await capture(
          tester,
          'task-2-${size.width.toInt()}x${size.height.toInt()}-list',
        );
        await tester.scrollUntilVisible(
          find.text('播放器 11'),
          250,
          scrollable: find.descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          ),
        );
        await tester.pumpAndSettle();
        final lastRow = find.ancestor(
          of: find.text('播放器 11'),
          matching: find.byType(ListTile),
        );
        final pathText = tester.widget<Text>(find.text(longFile.path));
        expect(pathText.maxLines, isNull);
        expect(pathText.overflow, isNot(TextOverflow.ellipsis));
        await tester.tap(
          find.descendant(of: lastRow, matching: find.byType(IconButton)),
        );
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(pathField()).controller!.text,
          longFile.path,
        );
        await capture(
          tester,
          'task-2-${size.width.toInt()}x${size.height.toInt()}-editor',
        );
        final screen = Offset.zero & size;
        expect(screen.contains(tester.getCenter(find.text('保存'))), isTrue);
        expect(screen.contains(tester.getCenter(find.text('取消编辑'))), isTrue);
        await tester.tap(find.text('取消编辑'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(result, isNull);
      },
    );
  }

  testWidgets('键盘 Tab 可达编辑按钮，Escape 取消不保存', (tester) async {
    await open(tester, selectedPath: first);
    for (var step = 0; step < 12; step++) {
      if (FocusManager.instance.primaryFocus?.context?.widget is IconButton) {
        break;
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(nameField(), findsOneWidget);
    await tester.enterText(nameField(), '未保存');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(result, isNull);
    expect(saves, 0);
    expect(tester.takeException(), isNull);
  });
}
