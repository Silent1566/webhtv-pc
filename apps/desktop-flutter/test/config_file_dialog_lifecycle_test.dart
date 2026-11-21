import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/config_pages.dart';

Finder get _dialogField => find.descendant(
  of: find.byType(AlertDialog),
  matching: find.byType(TextField),
);

class _ImportRecordingState extends AppState {
  _ImportRecordingState({required super.paths}) : super(log: LogService());

  String? importedPath;

  @override
  Future<bool> importConfig(String input, {String? displayName}) async {
    importedPath = input;
    return false;
  }
}

void main() {
  late Directory tempDir;
  late _ImportRecordingState state;
  late String configPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-dialog-lifecycle-');
    configPath = '${tempDir.path}/config.json';
    state = _ImportRecordingState(
      paths: AppPaths.resolve(
        overrides: {
          'config': tempDir.path,
          'data': tempDir.path,
          'cache': '${tempDir.path}/cache',
          'state': '${tempDir.path}/state',
        },
      ),
    );
  });

  tearDown(() async {
    state.dispose();
    await tempDir.delete(recursive: true);
  });

  Future<void> mount(WidgetTester tester, {Widget? home}) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: home ?? ConfigPage(state: state)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('选择本地文件'));
    await tester.pumpAndSettle();
  }

  Future<void> finishTransition(WidgetTester tester) async {
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(AlertDialog), findsNothing);
  }

  testWidgets(
    'local config dialog keeps its controller alive during cancel transition',
    (tester) async {
      await mount(tester);
      await open(tester);
      await tester.enterText(_dialogField, configPath);
      await tester.tap(find.text('取消'));
      await finishTransition(tester);
      expect(state.config, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final submit in ['confirm', 'enter']) {
    testWidgets(
      'local config dialog $submit submits typed path without transition errors',
      (tester) async {
        await mount(tester);
        await open(tester);
        await tester.enterText(_dialogField, '  $configPath  ');
        if (submit == 'confirm') {
          await tester.tap(find.text('确定'));
        } else {
          await tester.testTextInput.receiveAction(TextInputAction.done);
        }
        await finishTransition(tester);
        expect(state.importedPath, configPath);
        final input = tester.widgetList<TextField>(find.byType(TextField)).last;
        expect(input.controller!.text, configPath);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'local config dialog pop preserves page inputs and reopens with a fresh controller',
    (tester) async {
      await mount(tester);
      final pageFields = tester
          .widgetList<TextField>(find.byType(TextField))
          .toList();
      await tester.enterText(find.byType(TextField).first, 'keep name');
      await tester.enterText(find.byType(TextField).last, 'keep source');
      await open(tester);
      final firstController = tester
          .widget<TextField>(_dialogField)
          .controller!;
      await tester.enterText(_dialogField, 'discard path');
      final dialogContext = tester.element(find.byType(AlertDialog));
      Navigator.of(dialogContext).pop();
      await finishTransition(tester);
      await open(tester);
      final reopened = tester.widget<TextField>(_dialogField).controller!;
      expect(identical(firstController, reopened), isFalse);
      expect(reopened.text, isEmpty);
      await tester.tap(find.text('取消'));
      await finishTransition(tester);
      expect(pageFields.first.controller!.text, 'keep name');
      expect(pageFields.last.controller!.text, 'keep source');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'local config dialog survives parent rebuild and rapid reopen during exit',
    (tester) async {
      late StateSetter rebuild;
      var revision = 0;
      await mount(
        tester,
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return ConfigPage(state: state, key: const ValueKey('page'));
          },
        ),
      );
      final reopen = tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '选择本地文件'))
          .onPressed!;
      for (var cycle = 0; cycle < 3; cycle++) {
        if (cycle == 0) {
          await open(tester);
        }
        await tester.enterText(_dialogField, 'typed $cycle');
        rebuild(() => revision++);
        await tester.pump();
        expect(
          tester.widget<TextField>(_dialogField).controller!.text,
          'typed $cycle',
        );
        await tester.tap(find.text('取消'));
        await tester.pump();
        expect(tester.takeException(), isNull);
        if (cycle < 2) {
          // Exercise the real opener before the previous overlay has finished exiting.
          reopen();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(
            tester.widget<TextField>(_dialogField).controller!.text,
            isEmpty,
          );
        } else {
          await finishTransition(tester);
        }
      }
      expect(revision, 3);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'local config dialog can confirm after its parent route is removed',
    (tester) async {
      late MaterialPageRoute<void> pageRoute;
      await mount(
        tester,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                pageRoute = MaterialPageRoute<void>(
                  builder: (_) => ConfigPage(state: state),
                );
                Navigator.of(context).push(pageRoute);
              },
              child: const Text('config route'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('config route'));
      await tester.pumpAndSettle();
      await open(tester);
      await tester.enterText(_dialogField, configPath);
      Navigator.of(tester.element(find.byType(AlertDialog)))
          .removeRoute(pageRoute);
      await tester.pumpAndSettle();
      expect(find.byType(ConfigPage), findsNothing);
      await tester.tap(find.text('确定'));
      await finishTransition(tester);
      expect(
        state.importedPath,
        isNull,
        reason: 'a removed page must not import or write to its disposed input',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
