import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/session_recovery.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/session_recovery_store.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/advanced_settings_page.dart';
import 'package:webhtv_pc/ui/recovery_banner.dart';
import 'package:webhtv_pc/ui/theme.dart';

AppPaths tempPaths(Directory temp) => AppPaths.resolve(
  overrides: {
    'config': '${temp.path}${Platform.pathSeparator}config',
    'data': '${temp.path}${Platform.pathSeparator}data',
    'cache': '${temp.path}${Platform.pathSeparator}cache',
    'state': '${temp.path}${Platform.pathSeparator}logs',
  },
);

void main() {
  group('隐身模式（P2-8）', () {
    late Directory temp;
    late String settingsPath;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('webhtv-incognito');
      settingsPath = '${temp.path}${Platform.pathSeparator}settings.json';
    });

    tearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    Map<String, Object?> readRaw() {
      final file = File(settingsPath);
      if (!file.existsSync()) return const {};
      return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    }

    test('偏好：默认不写盘，开启写 true，关闭删除键', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(store.incognito, isFalse);
      expect(store.hasExplicitIncognito, isFalse);

      await store.rememberIncognito(true);
      expect(readRaw()['incognito'], isTrue);
      final reloaded = UiPreferencesStore(path: settingsPath);
      await reloaded.load();
      expect(reloaded.incognito, isTrue);

      await reloaded.rememberIncognito(false);
      expect(readRaw().containsKey('incognito'), isFalse);
    });

    test('隐身开启：recordProgress 不落库；关闭后恢复写入', () async {
      final state = AppState(paths: tempPaths(temp), log: LogService());
      addTearDown(state.dispose);
      await state.bootstrap();
      final vod = Vod(vodId: 'v1', vodName: '测试剧');

      await state.setIncognito(true);
      state.recordProgress(
        vod: vod,
        flag: '线路一',
        episodeName: 'E1',
        episodeId: 'E1',
        position: const Duration(seconds: 30),
        duration: const Duration(minutes: 40),
      );
      expect(state.recentHistory(), isEmpty, reason: '隐身模式不得写历史');

      await state.setIncognito(false);
      state.recordProgress(
        vod: vod,
        flag: '线路一',
        episodeName: 'E1',
        episodeId: 'E1',
        position: const Duration(seconds: 30),
        duration: const Duration(minutes: 40),
      );
      expect(state.recentHistory(), hasLength(1));
    });

    test('隐身开启：搜索关键词不落盘（仅本次会话内存）', () async {
      final state = AppState(paths: tempPaths(temp), log: LogService());
      addTearDown(state.dispose);
      await state.bootstrap();

      await state.setIncognito(true);
      await state.searchAll('关键词', timeout: const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final stateSettings = File(state.paths.settingsPath);
      var raw = stateSettings.existsSync()
          ? jsonDecode(stateSettings.readAsStringSync()) as Map<String, Object?>
          : <String, Object?>{};
      final ui = raw['ui'] is Map ? raw['ui'] as Map : const {};
      expect(ui.containsKey('searchKeywords'), isFalse, reason: '隐身不得持久化搜索');

      await state.setIncognito(false);
      await state.searchAll('关键词2', timeout: const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      raw = stateSettings.existsSync()
          ? jsonDecode(stateSettings.readAsStringSync()) as Map<String, Object?>
          : <String, Object?>{};
      final ui2 = raw['ui'] is Map ? raw['ui'] as Map : const {};
      expect(ui2['searchKeywords'], contains('关键词2'));
    });
  });

  group('会话恢复存储（P2-8）', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('webhtv-recovery');
    });

    tearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('begin/read/end：标记往返与正常退出清理', () {
      final store = SessionRecoveryStore(
        dataDir: temp.path,
        now: () => DateTime(2026, 10, 22, 9),
      );
      store.beginSession(appVersion: '0.1.0', pid: 42);
      final marker = store.readMarker();
      expect(marker, isNotNull);
      expect(marker!.pid, 42);
      expect(marker.appVersion, '0.1.0');
      expect(
        marker.startedAtMs,
        DateTime(2026, 10, 22, 9).millisecondsSinceEpoch,
      );

      store.endSessionCleanly();
      expect(store.readMarker(), isNull);
    });

    test('播放上下文更新保留 pid/startedAt，只换 playback', () {
      final store = SessionRecoveryStore(
        dataDir: temp.path,
        now: () => DateTime(2026, 10, 22, 9),
      );
      store.beginSession(appVersion: '0.1.0', pid: 42);
      final before = store.readMarker()!;
      store.updatePlayback(
        SessionPlaybackContext(
          siteKey: 's',
          vodId: 'v',
          vodName: '剧',
          flag: '线路一',
          episodeName: 'E2',
          episodeId: 'E2',
          positionMs: 60000,
          durationMs: 2400000,
          updatedAtMs: 123,
        ),
        appVersion: '0.1.0',
      );
      final after = store.readMarker()!;
      expect(after.pid, 42);
      expect(after.startedAtMs, before.startedAtMs);
      expect(after.playback!.episodeName, 'E2');
      expect(after.playback!.positionMs, 60000);
    });

    test('崩溃日志有界（超出 64KiB 保留尾部）', () {
      final store = SessionRecoveryStore(dataDir: temp.path);
      for (var i = 0; i < 40; i++) {
        store.appendCrash('第$i条 ${'x' * 3000}');
      }
      final log = store.readCrashLog();
      expect(log, isNotNull);
      expect(log!.length, lessThanOrEqualTo(crashLogFileMaxChars + 2));
      expect(log, contains('第39条'));
      store.clearCrashLog();
      expect(store.readCrashLog(), isNull);
    });

    test('损坏的标记文件当不存在，不抛异常', () {
      final store = SessionRecoveryStore(dataDir: temp.path);
      File(store.markerPath)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('not json');
      expect(store.readMarker(), isNull);
    });
  });

  group('AppState 崩溃检测与恢复（P2-8）', () {
    late Directory temp;
    late AppPaths paths;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('webhtv-recovery-state');
      paths = tempPaths(temp);
    });

    tearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    void writeForeignMarker({int pid = 999999}) {
      final store = SessionRecoveryStore(dataDir: paths.dataDir);
      store.beginSession(appVersion: '0.1.0', pid: pid);
      store.updatePlayback(
        SessionPlaybackContext(
          siteKey: 's',
          vodId: 'v',
          vodName: '剧',
          flag: '线路一',
          episodeName: 'E1',
          episodeId: 'E1',
          positionMs: 5000,
          durationMs: 2400000,
          updatedAtMs: 1,
        ),
        appVersion: '0.1.0',
        pid: pid,
      );
    }

    test('上次是别的 pid → 暴露 pendingRecovery；忽略后删除标记', () async {
      writeForeignMarker();
      final state = AppState(paths: paths, log: LogService());
      addTearDown(state.dispose);
      await state.bootstrap();

      expect(state.pendingRecovery, isNotNull);
      expect(state.pendingRecovery!.playback!.vodId, 'v');
      await state.dismissRecovery();
      expect(state.pendingRecovery, isNull);
      expect(state.sessionRecovery!.readMarker(), isNull);
    });

    test('标记 pid 是自己 → 不算崩溃（同进程重复 bootstrap）', () async {
      final first = AppState(paths: paths, log: LogService());
      await first.bootstrap();
      first.dispose();
      // 不调用 endSessionCleanly：模拟同一进程里第二次 bootstrap。
      final second = AppState(paths: paths, log: LogService());
      addTearDown(second.dispose);
      await second.bootstrap();
      expect(second.pendingRecovery, isNull);
    });

    test('recordProgress 更新崩溃恢复上下文；正常退出删除标记', () async {
      final state = AppState(paths: paths, log: LogService());
      addTearDown(state.dispose);
      await state.bootstrap();

      state.recordProgress(
        vod: Vod(vodId: 'v9', vodName: '剧九'),
        flag: '线路二',
        episodeName: 'E3',
        episodeId: 'E3',
        position: const Duration(minutes: 12),
        duration: const Duration(minutes: 45),
      );
      final marker = state.sessionRecovery!.readMarker();
      expect(marker?.playback, isNotNull);
      expect(marker!.playback!.vodId, 'v9');
      expect(marker.playback!.positionMs, 12 * 60 * 1000);
      expect(marker.playback!.flag, '线路二');

      state.endSessionCleanly();
      expect(state.sessionRecovery!.readMarker(), isNull);
    });
  });

  group('崩溃恢复横幅', () {
    testWidgets('显示文案与三个动作，回调可触发', (tester) async {
      final marker = SessionMarker(
        version: SessionMarker.formatVersion,
        pid: 999999,
        startedAtMs: DateTime(2026, 10, 22, 8).millisecondsSinceEpoch,
        appVersion: '0.1.0',
        playback: const SessionPlaybackContext(
          siteKey: 's',
          vodId: 'v',
          vodName: '剧',
          flag: '线路一',
          episodeName: 'E1',
          episodeId: 'E1',
          positionMs: 1000,
          durationMs: 2000,
          updatedAtMs: 1,
        ),
      );
      SessionPlaybackContext? resumed;
      var dismissed = false;
      tester.view.physicalSize = const Size(1200, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(
            body: RecoveryBanner(
              marker: marker,
              hasCrashLog: true,
              onResume: (value) => resumed = value,
              onShowLog: () {},
              onDismiss: () => dismissed = true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('recovery-banner-text')), findsOneWidget);
      expect(find.textContaining('上次运行未正常退出'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('recovery-resume')));
      expect(resumed?.vodId, 'v');
      await tester.tap(find.byKey(const ValueKey('recovery-dismiss')));
      expect(dismissed, isTrue);
      expect(find.byKey(const ValueKey('recovery-show-log')), findsOneWidget);
    });
  });

  group('高级设置入口（L2）', () {
    late Directory temp;
    late AppState state;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('webhtv-privacy-settings');
      state = AppState(paths: tempPaths(temp), log: LogService());
      await state.bootstrap();
    });

    tearDown(() {
      state.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    testWidgets('隐身与 DoH 区块可达，并能改开关', (tester) async {
      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: AdvancedSettingsPage(state: state),
        ),
      );
      await tester.pump();

      final scrollable = find.byType(Scrollable).first;
      for (final key in const [
        'settings-incognito',
        'settings-doh-enabled',
        'settings-doh-endpoint',
        'settings-doh-cache',
      ]) {
        final finder = find.byKey(ValueKey(key));
        await tester.scrollUntilVisible(finder, 200, scrollable: scrollable);
        expect(finder, findsOneWidget, reason: '高级设置缺少区块：$key');
      }

      // 逐个滚过去之后视口停在 DoH 区块：本页新增「长按画面倍速」一行后更长，
      // 隐身开关已被滚出视口（`tap` 会打在窗口外）。点之前先把它滚回来。
      final incognito = find.byKey(const ValueKey('settings-incognito'));
      await tester.scrollUntilVisible(
        incognito,
        -200,
        scrollable: scrollable,
      );
      await tester.ensureVisible(incognito);
      await tester.pumpAndSettle();
      await tester.tap(incognito);
      await tester.pumpAndSettle();
      expect(state.incognito, isTrue);

      final dohEnabled = find.byKey(const ValueKey('settings-doh-enabled'));
      await tester.ensureVisible(dohEnabled);
      await tester.pumpAndSettle();
      await tester.tap(dohEnabled);
      await tester.pumpAndSettle();
      expect(state.dohSettings.enabled, isTrue);
    });
  });
}
