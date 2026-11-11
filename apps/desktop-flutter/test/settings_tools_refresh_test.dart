import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/ai_assist.dart';
import 'package:webhtv_pc/core/ai_config.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/pan_check.dart';
import 'package:webhtv_pc/services/ai_assist_service.dart';
import 'package:webhtv_pc/services/ai_completion_client.dart';
import 'package:webhtv_pc/services/pan_check_service.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/ai_assist_page.dart';
import 'package:webhtv_pc/ui/backup_page.dart';
import 'package:webhtv_pc/ui/config_pages.dart';
import 'package:webhtv_pc/ui/injected_sites_page.dart';
import 'package:webhtv_pc/ui/pan_check_page.dart';
import 'package:webhtv_pc/ui/settings_layout.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/toast.dart';

import 'phase5_sync_ui_test.dart' as fixture;

// Reject unsafe paths before bootstrap can access storage.
void _requireIsolatedPaths(AppPaths paths, Directory temp) {
  for (final dir in [
    paths.configDir,
    paths.dataDir,
    paths.cacheDir,
    paths.logDir,
  ]) {
    expect(
      p.isWithin(temp.path, dir),
      isTrue,
      reason: 'Test directory must remain beneath its owned temp directory',
    );
  }
}

void main() {
  late Directory temp;
  late AppState state;
  var stateCreated = false;
  late fixture.FakeBridge bridge;

  setUp(() async {
    stateCreated = false;
    temp = await Directory.systemTemp.createTemp('settings-tools-refresh-');
    bridge = fixture.FakeBridge();
    final paths = AppPaths.resolve(
      overrides: {
        'config': p.join(temp.path, 'config'),
        'data': p.join(temp.path, 'data'),
        'cache': p.join(temp.path, 'cache'),
        'state': p.join(temp.path, 'logs'),
      },
    );
    _requireIsolatedPaths(paths, temp);
    state = AppState(
      paths: paths,
      log: LogService(),
      androidBridgeService: bridge,
    );
    stateCreated = true;
    await state.bootstrap();
  });

  tearDown(() async {
    dismissAllToasts();
    if (stateCreated) state.dispose();
    await temp.delete(recursive: true);
  });

  Future<void> open(
    WidgetTester tester,
    Widget page,
    Size size,
    Brightness brightness,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(theme: buildAppTheme(brightness), home: page),
    );
    await tester.pumpAndSettle();
  }

  Future<void> reach(WidgetTester tester, String key) async {
    final target = find.byKey(ValueKey(key));
    await tester.scrollUntilVisible(
      target,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(target.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  }

  for (final size in [const Size(400, 900), const Size(1200, 900)]) {
    for (final brightness in Brightness.values) {
      final variant = '${size.width} / ${brightness.name}';
      testWidgets('TMDB 字段与维护操作可达且凭据可切换：$variant', (tester) async {
        await open(tester, TmdbSettingsPage(state: state), size, brightness);
        await reach(tester, 'tmdb-api-key');
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('tmdb-api-key')))
              .obscureText,
          isTrue,
        );
        await tester.tap(find.byKey(const ValueKey('tmdb-api-key-toggle')));
        await tester.pump();
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('tmdb-api-key')))
              .obscureText,
          isFalse,
        );
        await reach(tester, 'tmdb-reset-rules');
        await reach(tester, 'tmdb-save');
        await reach(tester, 'tmdb-test');
      });

      testWidgets('安卓接入字段、同步授权与手动操作可达：$variant', (tester) async {
        bridge.probeFailure = AppError(
          AppErrorKind.bridgeUnreachable,
          '离线fixture：设备不可达',
        );
        await tester.runAsync(() => state.syncState.probe('example.test:9978'));
        await open(tester, AndroidSettingsPage(state: state), size, brightness);
        expect(state.syncState.lastError, isNotNull);
        expect(find.byKey(const ValueKey('android-error')), findsOneWidget);
        await reach(tester, 'android-device-input');
        final input = find.byKey(const ValueKey('android-device-input'));
        await tester.enterText(input, '');
        await tester.pump();
        final inputFocus = tester
            .widget<EditableText>(
              find.descendant(of: input, matching: find.byType(EditableText)),
            )
            .focusNode;
        expect(inputFocus.hasFocus, isTrue);
        expect(FocusManager.instance.primaryFocus, same(inputFocus));
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(inputFocus.hasFocus, isFalse);
        expect(
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<FilledButton>()
              ?.key,
          const ValueKey('android-device-add'),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(state.syncState.lastError, isNull);
        expect(find.byKey(const ValueKey('android-error')), findsNothing);
        await reach(tester, 'android-scan');
        await reach(tester, 'android-sync-server');
        expect(
          tester
              .widget<SwitchListTile>(
                find.byKey(const ValueKey('android-sync-server')),
              )
              .value,
          isFalse,
        );
        await reach(tester, 'realtime-manual-push-settings');
      });

      testWidgets('备份恢复保持禁用与重置确认：$variant', (tester) async {
        await open(tester, BackupPage(state: state), size, brightness);
        await reach(tester, 'backup-restore');
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('backup-restore')),
              )
              .onPressed,
          isNull,
        );
        await reach(tester, 'backup-reset');
        await tester.tap(find.byKey(const ValueKey('backup-reset')));
        await tester.pumpAndSettle();
        expect(find.text('重置全部本地数据？'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(find.text('重置全部本地数据？'), findsNothing);
        final output = File('${temp.path}/layout-fixture.zip');
        await reach(tester, 'backup-output-path');
        await tester.enterText(
          find.byKey(const ValueKey('backup-output-path')),
          output.path,
        );
        await reach(tester, 'backup-create');
        await tester.tap(find.byKey(const ValueKey('backup-create')));
        final message = find.byKey(const ValueKey('backup-message'));
        for (var round = 0; round < 90 && message.evaluate().isEmpty; round++) {
          await tester.pump(const Duration(milliseconds: 16));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 16)),
          );
        }
        await tester.pumpAndSettle();
        await reach(tester, 'backup-message');
        expect(output.existsSync(), isTrue);
        expect(
          tester.widget<SelectableText>(message).data,
          contains(output.path),
        );
        expect(
          find.ancestor(of: message, matching: find.byType(SettingsSection)),
          findsNothing,
        );
        expect(find.text('操作结果'), findsOneWidget);
      });

      testWidgets('注入空态与添加弹窗可达：$variant', (tester) async {
        await open(tester, InjectedSitesPage(state: state), size, brightness);
        expect(find.text('站点注入'), findsOneWidget);
        expect(find.text('添加与管理'), findsOneWidget);
        expect(find.text('还没有注入站点'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('injected-sites-add')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('injected-sites-input')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('injected-sites-input')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('网盘空输入反馈与重检操作可达：$variant', (tester) async {
        await open(tester, PanCheckPage(state: state), size, brightness);
        expect(find.byKey(const ValueKey('pan-check-empty')), findsOneWidget);
        await reach(tester, 'pan-check-refresh');
        await tester.tap(find.byKey(const ValueKey('pan-check-run')));
        await tester.pumpAndSettle();
        expect(find.text('请先粘贴至少一条分享链接'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('AI 全部任务可选择且未配置时不能外发：$variant', (tester) async {
        await open(tester, AiAssistPage(state: state), size, brightness);
        expect(find.byKey(const ValueKey('ai-assist-empty')), findsOneWidget);
        final selector = find.byKey(const ValueKey('ai-assist-task'));
        await tester.ensureVisible(selector);
        await tester.tap(find.text('广告分片判定'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<SegmentedButton<AiAssistTask>>(selector).selected,
          {AiAssistTask.adSegmentReview},
        );
        await reach(tester, 'ai-assist-run');
        expect(
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('ai-assist-run')))
              .onPressed,
          isNull,
        );
      });
    }
  }

  testWidgets('窄窗网盘检测忙碌、结果及强制重检均使用本地fixture', (tester) async {
    final service = _PanFixture();
    addTearDown(service.close);
    await open(
      tester,
      PanCheckPage(state: state, service: service),
      const Size(400, 900),
      Brightness.dark,
    );
    await tester.enterText(
      find.byKey(const ValueKey('pan-check-input')),
      'https://pan.quark.cn/s/fixture',
    );
    await tester.tap(find.byKey(const ValueKey('pan-check-run')));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('pan-check-run')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('pan-check-refresh')),
          )
          .onPressed,
      isNull,
    );
    service.finish();
    await tester.pumpAndSettle();
    expect(find.textContaining('本地判定：无法判定'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await reach(tester, 'pan-check-refresh');
    await tester.tap(find.byKey(const ValueKey('pan-check-refresh')));
    await tester.pumpAndSettle();
    expect(find.textContaining('本地强制重检'), findsOneWidget);
  });

  testWidgets('窄窗设备卡片与授权对端保留导入、推送及撤销入口', (tester) async {
    await tester.runAsync(() async {
      await state.syncState.probe('192.168.50.9:9978');
      await state.syncState.authorizePeer(state.syncState.devices.single);
    });
    await open(
      tester,
      AndroidSettingsPage(state: state),
      const Size(400, 900),
      Brightness.dark,
    );
    await reach(tester, 'android-import');
    await reach(tester, 'android-sync-push-now');
    await reach(tester, 'sync-peer-revoke-fake-android-uuid');
    expect(tester.takeException(), isNull);
  });

  testWidgets('注入弹窗正常autofocus时Esc关闭不访问已释放控制器', (tester) async {
    await open(
      tester,
      InjectedSitesPage(state: state),
      const Size(400, 900),
      Brightness.dark,
    );
    await tester.tap(find.byKey(const ValueKey('injected-sites-add')));
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('injected-sites-input'));
    final editable = tester.widget<EditableText>(
      find.descendant(of: input, matching: find.byType(EditableText)),
    );
    expect(editable.focusNode.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(input, findsNothing);
    expect(state.injectedSites, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('注入弹窗正常autofocus确认使用本地JSON且保留成功结果', (tester) async {
    await open(
      tester,
      InjectedSitesPage(state: state),
      const Size(400, 900),
      Brightness.light,
    );
    await tester.tap(find.byKey(const ValueKey('injected-sites-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('injected-sites-input')),
      '{"key":"dialog-fixture","name":"本地弹窗确认fixture","type":1,"api":"https://example.test/api"}',
    );
    await tester.tap(find.text('识别并添加'));
    for (var round = 0; round < 90; round++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 16)),
      );
      if (state.injectedSites.isNotEmpty &&
          tester
                  .widget<FilledButton>(
                    find.byKey(const ValueKey('injected-sites-add')),
                  )
                  .onPressed !=
              null) {
        break;
      }
    }
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('injected-sites-input')), findsNothing);
    expect(state.injectedSites.single.key, 'dialog-fixture');
    expect(find.text('本地弹窗确认fixture'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄窗AI忙碌与错误保持真实且任务切换清除结果', (tester) async {
    final client = _AiFixture();
    final service = AiAssistService(
      config: const AiConfig(
        enabled: true,
        protocol: AiProtocol.openAiChat,
        endpoint: 'https://example.test/v1/chat/completions',
        apiKey: 'fixture',
        model: 'fixture',
      ),
      client: client,
    );
    await open(
      tester,
      AiAssistPage(state: state, service: service),
      const Size(400, 900),
      Brightness.dark,
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai-assist-input')),
      '测试输入',
    );
    await reach(tester, 'ai-assist-run');
    await tester.tap(find.byKey(const ValueKey('ai-assist-run')));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('ai-assist-run')))
          .onPressed,
      isNull,
    );
    client.pending.complete(
      const AiCompletionResult(
        ok: false,
        statusCode: 503,
        text: '',
        message: '本地fixture：服务不可用',
      ),
    );
    await tester.pumpAndSettle();
    await reach(tester, 'ai-assist-error');
    expect(find.textContaining('服务不可用'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('ai-assist-task')));
    await tester.tap(find.text('日志诊断'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-assist-error')), findsNothing);
    await reach(tester, 'ai-assist-empty');
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄窗注入列表保留开关、删除确认与取消结果', (tester) async {
    await tester.runAsync(
      () => state.addInjectedSites(
        '{"key":"fixture-long-key","name":"本地fixture注入站点名称用于窄窗换行",'
        '"type":1,"api":"https://example.test/api"}',
      ),
    );
    await open(
      tester,
      InjectedSitesPage(state: state),
      const Size(400, 900),
      Brightness.light,
    );
    expect(find.text('本地fixture注入站点名称用于窄窗换行'), findsOneWidget);
    expect(
      tester
          .widget<Switch>(
            find.byKey(const ValueKey('injected-site-toggle-fixture-long-key')),
          )
          .value,
      isTrue,
    );
    await tester.tap(
      find.byKey(const ValueKey('injected-site-remove-fixture-long-key')),
    );
    await tester.pumpAndSettle();
    expect(find.text('删除注入站点'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(state.injectedSites, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}

class _PanFixture extends PanCheckService {
  final pending = Completer<List<PanCheckResult>>();
  String url = '';

  @override
  Future<List<PanCheckResult>> checkAll(
    List<String> links, {
    bool forceRefresh = false,
  }) async {
    url = links.single;
    if (forceRefresh) return [_result('本地强制重检')];
    return pending.future;
  }

  PanCheckResult _result(String summary) => PanCheckResult(
    url: url,
    diskType: PanDiskType.quark,
    state: PanCheckState.uncertain,
    summary: summary,
    checkedAt: 1,
  );

  void finish() => pending.complete([_result('本地判定：无法判定')]);
}

class _AiFixture extends AiCompletionClient {
  final pending = Completer<AiCompletionResult>();

  @override
  Future<AiCompletionResult> complete({
    required AiConfig config,
    required String prompt,
    Duration? timeout,
    AiCancellationToken? cancellationToken,
    String task = 'ai',
  }) => pending.future;
}
