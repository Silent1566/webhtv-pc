import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/external_player.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/player_context_menu.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/toast.dart';

import 'support/player_page_harness.dart';

class _PickerAppState extends AppState {
  _PickerAppState({
    required super.paths,
    required super.log,
    required super.externalPlayerDetector,
  });

  bool rejectSelection = false;

  @override
  Future<bool> setExternalPlayerPath(String? path) async {
    if (rejectSelection) return false;
    return super.setExternalPlayerPath(path);
  }
}

class _FakeProcess implements Process {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> openExternalPicker(WidgetTester tester) async {
  await tester.tapAt(const Offset(300, 260), buttons: kSecondaryButton);
  await settlePlayerPage(tester, times: 2);
  final menu = tester.widget<PlayerContextMenu>(find.byType(PlayerContextMenu));
  final action = menu.sections
      .firstWhere((section) => section.title == '播放')
      .items
      .firstWhere((item) => item.id == 'external_player');
  action.onSelect!();
  await settlePlayerPage(tester, times: 2);
}

void main() {
  late Directory directory;
  late AppState app;
  late String first;
  late String second;
  late String third;
  late List<ExternalPlayer> scanned;
  late List<String> launches;
  late List<String> arguments;
  late bool launchFails;
  late Completer<void> launchCompleted;

  tearDown(dismissAllToasts);
  setUp(() {
    directory = Directory.systemTemp.createTempSync('webhtv-picker-page-');
    String exe(String filename) => (File(
      '${directory.path}${Platform.pathSeparator}$filename',
    )..createSync()).path;
    first = exe('first.exe');
    second = exe('second.exe');
    third = exe('third.exe');
    scanned = [
      ExternalPlayer(name: 'PotPlayer', executable: first),
      ExternalPlayer(name: 'PotPlayer', executable: second),
    ];
    launches = [];
    arguments = [];
    launchFails = false;
    launchCompleted = Completer<void>();
  });

  Future<void> pump(WidgetTester tester, {String? preset}) async {
    final paths = AppPaths.resolve(
      overrides: {'roaming': directory.path, 'local': directory.path},
    );
    app = _PickerAppState(
      paths: paths,
      log: LogService(),
      externalPlayerDetector: () => scanned,
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    addTearDown(app.dispose);
    await tester.runAsync(() async {
      await app.bootstrap();
      if (preset != null) await app.setExternalPlayerPath(preset);
    });
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    installMediaKitMocks(tester);
    installWindowManagerMocks(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(
          body: PlayerPage(
            state: app,
            request: const PlaybackRequest(
              url: 'http://127.0.0.1:9/never.m3u8',
              title: '示例剧集',
              siteKey: 'fixture',
              vodId: 'demo-1',
              vodName: '示例剧集',
              episodeName: 'E3',
              flag: '线路一',
            ),
            externalPlayerStarter: (executable, args) async {
              launches.add(executable);
              launchCompleted.complete();
              arguments.addAll(args);
              if (launchFails) throw StateError('fixture launch failed');
              return _FakeProcess();
            },
          ),
        ),
      ),
    );
    await settlePlayerPage(tester);
  }

  Finder row(String path) =>
      find.ancestor(of: find.text(path), matching: find.byType(ListTile));
  Future<void> save(WidgetTester tester) async {
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '保存'),
    );
    await tester.runAsync(
      () => (button.onPressed! as Future<void> Function())(),
    );
    await settlePlayerPage(tester, times: 2);
  }

  Future<void> fill(WidgetTester tester, String name, String path) async {
    await tester.enterText(find.widgetWithText(TextField, '播放器名称'), name);
    await tester.enterText(find.widgetWithText(TextField, '可执行文件路径'), path);
  }

  Future<void> use(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, '使用'));
    await tester.runAsync(
      () => launchCompleted.future.timeout(const Duration(seconds: 5)),
    );
    await settlePlayerPage(tester, times: 3);
  }

  testWidgets('已有有效播放器路径时每次外调仍要求选择', (tester) async {
    await pump(tester, preset: first);
    for (var attempt = 0; attempt < 2; attempt++) {
      await openExternalPicker(tester);
      expect(find.widgetWithText(AlertDialog, '外部播放器'), findsOneWidget);
      expect(tester.widget<ListTile>(row(first)).selected, isTrue);
      expect(find.text('PotPlayer #1'), findsOneWidget);
      expect(find.text('PotPlayer #2'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await settlePlayerPage(tester, times: 2);
      expect(find.byType(AlertDialog), findsNothing);
      expect(app.externalPlayerPath, first);
      expect(launches, isEmpty);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('确认另一个程序后下次只预选新路径，仍显示选择框', (tester) async {
    await pump(tester, preset: first);
    await openExternalPicker(tester);
    await tester.tap(row(second));
    await use(tester);
    expect(app.externalPlayerPath, second);
    expect(launches, [second]);
    expect(arguments, ['http://127.0.0.1:9/never.m3u8']);
    await openExternalPicker(tester);
    expect(find.widgetWithText(AlertDialog, '外部播放器'), findsOneWidget);
    expect(tester.widget<ListTile>(row(second)).selected, isTrue);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await settlePlayerPage(tester, times: 2);
    expect(launches, [second]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('取消另一个播放器的选择不会覆盖上次路径或启动', (tester) async {
    await pump(tester, preset: first);
    await openExternalPicker(tester);
    await tester.tap(row(second));
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await settlePlayerPage(tester, times: 2);
    expect(app.externalPlayerPath, first);
    expect(launches, isEmpty);
    await openExternalPicker(tester);
    expect(tester.widget<ListTile>(row(first)).selected, isTrue);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await settlePlayerPage(tester, times: 2);
  });

  testWidgets('新增保存接 AppState，取消选择后重新打开条目仍在且没有外调', (tester) async {
    await pump(tester);
    await openExternalPicker(tester);
    await tester.tap(find.text('新增播放器'));
    await settlePlayerPage(tester, times: 2);
    await fill(tester, '自定义播放器', third);
    await save(tester);
    expect(find.text('自定义播放器'), findsOneWidget);
    expect(find.text(third), findsOneWidget);
    expect(app.externalPlayerPath, isNull);
    expect(launches, isEmpty);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await settlePlayerPage(tester, times: 2);
    await openExternalPicker(tester);
    expect(find.text('自定义播放器'), findsOneWidget);
    expect(launches, isEmpty);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await settlePlayerPage(tester, times: 2);
  });

  testWidgets('扫描条目编辑姓名及路径不复活原条目，保存不启动', (tester) async {
    await pump(tester, preset: first);
    await openExternalPicker(tester);
    await tester.tap(
      find.descendant(of: row(first), matching: find.byType(IconButton)),
    );
    await settlePlayerPage(tester, times: 2);
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '播放器名称'))
          .controller!
          .text,
      'PotPlayer',
    );
    await fill(tester, '用户改名', third);
    await save(tester);
    expect(find.text('用户改名'), findsOneWidget);
    expect(find.text(first), findsNothing);
    expect(tester.widget<ListTile>(row(third)).selected, isTrue);
    expect(launches, isEmpty);
    expect(app.externalPlayerPath, third);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await settlePlayerPage(tester, times: 2);
    await openExternalPicker(tester);
    expect(find.text(first), findsNothing);
    expect(find.text('用户改名'), findsOneWidget);
    expect(launches, isEmpty);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await settlePlayerPage(tester, times: 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('重复路径由数据层拒绝并保留编辑草稿，取消编辑无持久化', (tester) async {
    await pump(tester, preset: first);
    await openExternalPicker(tester);
    await tester.tap(
      find.descendant(of: row(first), matching: find.byType(IconButton)),
    );
    await settlePlayerPage(tester, times: 2);
    await fill(tester, '重复草稿', second);
    await save(tester);
    expect(find.textContaining('保存失败'), findsOneWidget);
    expect(find.widgetWithText(TextField, '播放器名称'), findsOneWidget);
    expect(launches, isEmpty);
    await tester.tap(find.text('取消编辑'));
    await settlePlayerPage(tester, times: 2);
    expect(find.text('PotPlayer #1'), findsOneWidget);
    expect(app.externalPlayerPath, first);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await settlePlayerPage(tester, times: 2);
  });

  testWidgets('失效路径不能使用且不改变上次路径，不调用启动器', (tester) async {
    await pump(tester, preset: first);
    File(first).deleteSync();
    await openExternalPicker(tester);
    await tester.tap(find.widgetWithText(FilledButton, '使用'));
    await settlePlayerPage(tester, times: 2);
    expect(find.textContaining('文件不存在'), findsOneWidget);
    expect(app.externalPlayerPath, first);
    expect(launches, isEmpty);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await settlePlayerPage(tester, times: 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('记录选择失败不启动，也不覆盖上次路径', (tester) async {
    await pump(tester, preset: first);
    (app as _PickerAppState).rejectSelection = true;
    await openExternalPicker(tester);
    await tester.tap(row(second));
    await tester.tap(find.widgetWithText(FilledButton, '使用'));
    await settlePlayerPage(tester, times: 3);
    expect(app.externalPlayerPath, first);
    expect(launches, isEmpty);
    expect(
      toastCenter.toasts.any((toast) => toast.message.contains('播放器选择保存失败')),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('启动失败不进入外部播放中状态，仍可再次选择', (tester) async {
    launchFails = true;
    await pump(tester, preset: first);
    await openExternalPicker(tester);
    await use(tester);
    expect(launches, [first]);
    expect(find.byTooltip('外部播放器播放中'), findsNothing);
    await openExternalPicker(tester);
    expect(find.widgetWithText(AlertDialog, '外部播放器'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await settlePlayerPage(tester, times: 2);
    expect(launches, [first]);
    expect(tester.takeException(), isNull);
  });
}
