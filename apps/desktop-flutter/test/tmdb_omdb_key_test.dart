import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/config_pages.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'phase5_sync_ui_test.dart' as fixture;

void main() {
  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tmdb-omdb-key-');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': p.join(temp.path, 'config'),
          'data': p.join(temp.path, 'data'),
          'cache': p.join(temp.path, 'cache'),
          'state': p.join(temp.path, 'logs'),
        },
      ),
      log: LogService(),
      androidBridgeService: fixture.FakeBridge(),
    );
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    await temp.delete(recursive: true);
  });

  /// `testWidgets` 的时钟是假的：真实文件 I/O 必须借 `runAsync` 窗口推进。
  Future<void> settleIo(WidgetTester tester, {int rounds = 90}) async {
    for (var round = 0; round < rounds; round++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 16)),
      );
    }
    await tester.pumpAndSettle();
  }

  test('redactedOmdbApiKey 只保留末 4 位', () {
    const key = 'abcdef1234567890';
    final redacted = const TmdbConfig(omdbApiKey: key).redactedOmdbApiKey;

    expect(redacted, '****7890');
    expect(redacted.contains(key), isFalse);
    expect(redacted.contains('abcdef'), isFalse);
  });

  test('omdbApiKey 非空时 toJson/fromJson 往返', () {
    const key = 'omdb-roundtrip-key';
    final json = const TmdbConfig(omdbApiKey: key).toJson();

    expect(json['omdbApiKey'], key);
    expect(TmdbConfig.fromJson(json).omdbApiKey, key);
    expect(const TmdbConfig().toJson().containsKey('omdbApiKey'), isFalse);
  });

  testWidgets('OMDB 输入框可掩码切换，保存后写入草稿配置', (tester) async {
    tester.view.physicalSize = const Size(1400, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: TmdbSettingsPage(state: state),
      ),
    );
    await tester.pumpAndSettle();

    final field = find.byKey(const ValueKey('tmdb-omdb-key'));
    expect(field, findsOneWidget);
    expect(tester.widget<TextField>(field).obscureText, isTrue);

    await tester.ensureVisible(
      find.byKey(const ValueKey('tmdb-omdb-key-toggle')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tmdb-omdb-key-toggle')));
    await tester.pump();
    expect(tester.widget<TextField>(field).obscureText, isFalse);

    const key = 'omdb-saved-key-1234';
    await tester.enterText(field, key);
    await tester.pump();

    await tester.ensureVisible(find.byKey(const ValueKey('tmdb-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tmdb-save')));
    await settleIo(tester);

    expect(state.tmdbConfig.omdbApiKey, key);
    expect(find.textContaining('omdb=****1234'), findsOneWidget);
  });
}
