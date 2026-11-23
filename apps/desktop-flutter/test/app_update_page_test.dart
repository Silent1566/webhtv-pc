/// 「软件更新」明细页的 widget 测试（ADR-0015）。
///
/// 这一套锁四件事：
/// 1. 页面**构建不联网**（打开、重建一个请求都不发），只有点「检查更新」与
///    壳层首帧后的自动检查会真的请求；
/// 2. 规格里的 key 与文案都在，状态文本覆盖四种检查结论；
/// 3. 自动检查开关与通道切换真的落盘 settings.json 的 update 段；
/// 4. 480x640 / 1440x900 x 暗亮都不溢出（发布说明另有 240 高度上限）。
///
/// 所有网络与进程动作都由 [_FakeUpdateService] 接管：本套件零真实 I/O。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_update.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/app_update_service.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/app_update_page.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/settings_layout.dart';
import 'package:webhtv_pc/ui/startup_arguments.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/toast.dart';

import 'support/settings_navigation.dart';
import 'support/settings_row_navigation.dart';

const String _tag = 'v0.1.0-202611240900';
const String _localTag = 'v0.1.0-202611231630';
const int _assetSize = 4 * 1024 * 1024;

AppReleaseAsset _asset(String name) => AppReleaseAsset(
  name: name,
  size: _assetSize,
  downloadUri: Uri.parse('https://downloads.test/$name'),
  sha256: 'a' * 64,
);

/// 一条覆盖三种桌面平台的发布：选哪个资产由 Platform.operatingSystem 决定，
/// 因此四个文件名都要在，测试才能在任一平台跑。
AppRelease _release({
  String tag = _tag,
  String body = '修复若干问题。',
  DateTime? publishedAt,
}) => AppRelease(
  tag: tag,
  title: tag,
  body: body,
  pageUri: Uri.parse(
    'https://github.com/Silent1566/webhtv-pc/releases/tag/$tag',
  ),
  publishedAt: publishedAt ?? DateTime.utc(2026, 11, 24, 1, 30),
  prerelease: false,
  draft: false,
  assets: [
    _asset('webhtv-pc-windows-x64.zip'),
    _asset('webhtv-pc-linux-x64.AppImage'),
    _asset('webhtv-pc-linux-x64.deb'),
    _asset('webhtv-pc-macos-arm64.zip'),
  ],
  tagInfo: AppReleaseTag.tryParse(tag),
);

AppUpdateCheck _check(
  AppUpdateVerdict verdict, {
  AppRelease? release,
  String? message,
}) => AppUpdateCheck(
  verdict: verdict,
  identity: const AppUpdateIdentity(version: '0.1.0', tag: _localTag),
  checkedAt: DateTime.utc(2026, 11, 24, 2),
  release: release,
  message: message,
);

/// 接管 check / download / install 的假服务：不会碰 socket、不会起进程。
class _FakeUpdateService extends AppUpdateService {
  _FakeUpdateService({required this.result});

  AppUpdateCheck result;

  /// 下载要抛出的失败原因（null = 成功）。
  String? downloadError;

  int checkCalls = 0;
  int downloadCalls = 0;
  int installCalls = 0;
  AppUpdateChannel? lastChannel;

  /// 非 null 时 check 停在这里，用来观察「检查中」的界面。
  Completer<AppUpdateCheck>? pendingCheck;

  /// 非 null 时 download 停在这里，用来观察下载进度。
  Completer<void>? pendingDownload;

  AppUpdateInstallResult installResult = const AppUpdateInstallResult(
    outcome: AppUpdateInstallOutcome.downloadedOnly,
    message: '已下载更新包，需要由系统安装器完成安装。',
  );

  @override
  Future<AppUpdateCheck> check({
    required AppUpdateIdentity identity,
    required AppUpdateChannel channel,
  }) async {
    checkCalls++;
    lastChannel = channel;
    final pending = pendingCheck;
    if (pending != null) return pending.future;
    return result;
  }

  @override
  Future<AppUpdateDownload> download(
    AppRelease release,
    AppReleaseAsset asset, {
    required Directory destination,
    void Function(int received, int? total)? onProgress,
  }) async {
    downloadCalls++;
    // 半个包就到：进度条必须在这个时刻显示中间态而不是等下载结束才跳。
    onProgress?.call(asset.size ~/ 2, asset.size);
    final pending = pendingDownload;
    if (pending != null) await pending.future;
    final failure = downloadError;
    if (failure != null) throw AppUpdateException(failure);
    onProgress?.call(asset.size, asset.size);
    return AppUpdateDownload(
      release: release,
      asset: asset,
      file: File('${destination.path}/${asset.name}'),
      sha256: 'a' * 64,
      size: asset.size,
    );
  }

  @override
  Future<AppUpdateInstallResult> install(
    AppUpdateDownload download, {
    required AppUpdateInstallEnvironment environment,
  }) async {
    installCalls++;
    return installResult;
  }
}

void main() {
  late Directory temp;
  late AppState state;
  late _FakeUpdateService service;

  setUp(() async {
    dismissAllToasts();
    temp = Directory.systemTemp.createTempSync('webhtv-update-page-');
    service = _FakeUpdateService(
      result: _check(AppUpdateVerdict.updateAvailable, release: _release()),
    );
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/config',
          'data': '${temp.path}/data',
          'cache': '${temp.path}/cache',
          'state': '${temp.path}/logs',
        },
      ),
      log: LogService(),
      externalPlayerDetector: () => const [],
      updateService: service,
    );
    await state.bootstrap();
  });

  tearDown(() {
    dismissAllToasts();
    state.dispose();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Map<String, Object?> readSettings() {
    final file = File(state.paths.settingsPath);
    if (!file.existsSync()) return const {};
    return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  }

  Map<String, Object?> updateSection() {
    final raw = readSettings()['update'];
    return raw is Map ? raw.cast<String, Object?>() : const {};
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    Brightness brightness = Brightness.dark,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness),
        home: AppUpdatePage(state: state),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final target = find.byKey(ValueKey(key));
    expect(target, findsOneWidget, reason: '缺少控件：$key');
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pump();
  }

  /// 规格要求页面里必须存在的 key（除按状态出现的三个）。
  const alwaysKeys = <String>[
    'settings-update-auto-check',
    'settings-update-channel-stable',
    'settings-update-channel-beta',
    'settings-update-check',
    'settings-update-status',
    'settings-update-install',
    'settings-update-release-page',
  ];

  testWidgets(
    'GitHub proxy defaults on; presets and validated custom address save immediately',
    (tester) async {
      await pumpPage(tester);
      final toggle = find.byKey(
        const ValueKey('settings-update-proxy-enabled'),
      );
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      expect(find.textContaining('第三方'), findsWidgets);
      expect(find.textContaining('失败'), findsWidgets);
      await tapKey(tester, 'settings-update-proxy-url');
      await tester.pumpAndSettle();
      expect(find.text('gh-proxy.com'), findsOneWidget);
      await tester.tap(find.text('ghfast.top'));
      await tester.pumpAndSettle();
      expect(
        state.updatePreferences.githubProxy.baseUrl,
        'https://ghfast.top/',
      );
      await tapKey(tester, 'settings-update-proxy-url');
      await tester.pumpAndSettle();
      await tester.tap(find.text('自定义 HTTPS 地址'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'http://unsafe.example');
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('请输入 HTTPS'), findsOneWidget);
      expect(
        state.updatePreferences.githubProxy.baseUrl,
        'https://ghfast.top/',
      );
      await tester.enterText(
        find.byType(TextField),
        'https://custom.example/proxy',
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        state.updatePreferences.githubProxy.baseUrl,
        'https://custom.example/proxy/',
      );
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'settings-update-proxy-enabled');
      await tester.pumpAndSettle();
      final proxy = updateSection()['githubProxy'] as Map;
      expect(proxy['enabled'], isFalse);
      expect(proxy['baseUrl'], 'https://custom.example/proxy/');
      expect(service.checkCalls, 0);
    },
  );

  testWidgets('proxy save failure keeps switch unchanged and shows recovery', (
    tester,
  ) async {
    await pumpPage(tester);
    final settings = File(state.paths.settingsPath);
    expect(settings.path.startsWith(temp.path), isTrue);
    if (settings.existsSync()) settings.deleteSync();
    Directory(settings.path).createSync();
    await tapKey(tester, 'settings-update-proxy-enabled');
    await tester.pumpAndSettle();
    expect(state.updatePreferences.githubProxy.enabled, isTrue);
    expect(toastCenter.toasts.last.message, contains('保存失败'));
    expect(toastCenter.toasts.last.kind, ToastKind.error);
  });

  testWidgets(
    'failed cached release renders source age retry hints without fresh install',
    (tester) async {
      service.result = AppUpdateCheck(
        verdict: AppUpdateVerdict.failed,
        identity: const AppUpdateIdentity(version: '0.1.0', tag: _localTag),
        checkedAt: DateTime.utc(2026, 11, 24, 2),
        release: _release(),
        fromCache: true,
        cachedAt: DateTime.utc(2026, 11, 22, 2),
        retryAt: DateTime.utc(2026, 11, 24, 3),
        source: '静态索引',
        message: '连接失败；仅显示历史缓存，请稍后重试',
      );
      await state.checkForUpdates();
      await pumpPage(tester);
      expect(
        find.byKey(const ValueKey('settings-update-source')),
        findsOneWidget,
      );
      final hint = tester.widget<Text>(
        find.byKey(const ValueKey('settings-update-cache-hint')),
      );
      expect(hint.data, contains('2 天'));
      expect(hint.data, contains('仅供参考'));
      expect(
        find.byKey(const ValueKey('settings-update-retry-at')),
        findsOneWidget,
      );
      expect(find.text('缓存版本（仅供参考）'), findsOneWidget);
      expect(find.textContaining('发现新版本'), findsNothing);
      final install = tester.widget<FilledButton>(
        find.byKey(const ValueKey('settings-update-install')),
      );
      expect(install.onPressed, isNull);
      expect(service.checkCalls, 1);
    },
  );

  testWidgets('checking disables channel and proxy controls', (tester) async {
    await pumpPage(tester);
    service.pendingCheck = Completer<AppUpdateCheck>();
    final pending = state.checkForUpdates();
    await tester.pump();
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('settings-update-channel-beta')),
          )
          .onSelected,
      isNull,
    );
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey('settings-update-proxy-enabled')),
          )
          .onChanged,
      isNull,
    );
    expect(
      tester
          .widget<ListTile>(
            find.byKey(const ValueKey('settings-update-proxy-url')),
          )
          .onTap,
      isNull,
    );
    service.pendingCheck!.complete(service.result);
    await pending;
    await tester.pumpAndSettle();
  });

  testWidgets('构建不发请求；key 齐全；有可用版本才允许安装', (tester) async {
    await pumpPage(tester);

    // 打开、重建、滚动都不该发请求：本进程到此刻一次 check 也没有。
    expect(service.checkCalls, 0, reason: '页面构建期间不得发起更新检查');
    for (final key in alwaysKeys) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: '缺少 $key');
    }
    expect(find.text('未检查过'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-update-new-version')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('settings-update-notes')), findsNothing);
    expect(
      find.byKey(const ValueKey('settings-update-progress')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('settings-update-result')), findsNothing);

    // 没有可用版本时下载并安装禁用；发布页是兜底入口，永远可点。
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('settings-update-install')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('settings-update-release-page')),
          )
          .onPressed,
      isNotNull,
    );

    // 用户点击才是唯一的请求来源。
    await tapKey(tester, 'settings-update-check');
    await tester.pumpAndSettle();
    expect(service.checkCalls, 1);
    expect(find.text('发现新版本 $_tag'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-update-new-version')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('settings-update-notes')), findsOneWidget);
    expect(find.text('修复若干问题。'), findsOneWidget);
    expect(find.textContaining('通道：稳定版'), findsOneWidget);
    expect(find.textContaining('发布于 2026-11-24'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('settings-update-install')),
          )
          .onPressed,
      isNotNull,
      reason: '有可用版本后安装按钮必须可点',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('空通道展示尚未发布而非已是最新，并禁用安装', (tester) async {
    await pumpPage(tester);
    for (final channel in AppUpdateChannel.values) {
      await state.setUpdateChannel(channel);
      service.result = _check(
        AppUpdateVerdict.upToDate,
        message: '发布通道里还没有可见的版本',
      );
      await state.checkForUpdates();
      await tester.pump();
      final status = tester.widget<Text>(
        find.byKey(const ValueKey('settings-update-status')),
      );
      expect(status.data, '发布通道里还没有可见的版本');
      expect(AppUpdatePage.summary(state), '当前 v0.1.0 · 该通道暂无发布版本');
      expect(find.textContaining('已是最新'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('settings-update-install')),
            )
            .onPressed,
        isNull,
      );
      expect(
        find.byKey(const ValueKey('settings-update-new-version')),
        findsNothing,
      );
    }
    service.result = _check(AppUpdateVerdict.upToDate);
    await state.checkForUpdates();
    await tester.pump();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('settings-update-status')))
          .data,
      '该通道暂无发布版本',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('状态文本覆盖四种结论，摘要与页面同源', (tester) async {
    await pumpPage(tester);
    expect(find.text('未检查过'), findsOneWidget);

    service.result = _check(AppUpdateVerdict.upToDate, release: _release());
    await state.checkForUpdates();
    await tester.pump();
    expect(find.text('已是最新（$_tag）'), findsOneWidget);
    expect(AppUpdatePage.summary(state), '当前 v0.1.0 · 已是最新');
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('settings-update-install')),
          )
          .onPressed,
      isNull,
      reason: '已是最新时不该重复下载同一个包',
    );

    service.result = _check(
      AppUpdateVerdict.updateAvailable,
      release: _release(),
    );
    await state.checkForUpdates();
    await tester.pump();
    expect(find.text('发现新版本 $_tag'), findsOneWidget);
    expect(AppUpdatePage.summary(state), '可更新到 $_tag');

    service.result = _check(
      AppUpdateVerdict.developmentBuild,
      release: _release(),
    );
    await state.checkForUpdates();
    await tester.pump();
    expect(find.text('当前为开发构建，不参与通道比较'), findsOneWidget);
    expect(AppUpdatePage.summary(state), '当前 v0.1.0 · 开发构建');
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('settings-update-install')),
          )
          .onPressed,
      isNotNull,
      reason: '开发构建需要手动装一次发布包才能进入更新通道',
    );

    service.result = _check(
      AppUpdateVerdict.failed,
      message: '查询发布信息被限流（HTTP 429）',
    );
    await state.checkForUpdates();
    await tester.pump();
    expect(find.text('检查失败：查询发布信息被限流（HTTP 429）'), findsOneWidget);
    expect(AppUpdatePage.summary(state), '上次检查失败：查询发布信息被限流（HTTP 429）');
    expect(tester.takeException(), isNull);
  });

  test('维护分类摘要五档（含开发构建与未检查）', () {
    String summaryWith({
      required bool isReleaseBuild,
      required AppUpdateCheck? check,
      String? lastCheckError,
    }) => AppUpdatePage.summaryOf(
      version: '0.1.0',
      isReleaseBuild: isReleaseBuild,
      check: check,
      lastCheckError: lastCheckError,
    );

    expect(summaryWith(isReleaseBuild: true, check: null), '当前 v0.1.0 · 未检查');
    expect(
      summaryWith(
        isReleaseBuild: true,
        check: _check(AppUpdateVerdict.upToDate, release: _release()),
      ),
      '当前 v0.1.0 · 已是最新',
    );
    expect(
      summaryWith(
        isReleaseBuild: true,
        check: _check(AppUpdateVerdict.updateAvailable, release: _release()),
      ),
      '可更新到 $_tag',
    );
    expect(
      summaryWith(
        isReleaseBuild: true,
        check: _check(AppUpdateVerdict.failed, message: '超时'),
      ),
      '上次检查失败：超时',
    );
    expect(
      summaryWith(isReleaseBuild: true, check: null, lastCheckError: '超时'),
      '上次检查失败：超时',
    );
    expect(summaryWith(isReleaseBuild: false, check: null), '当前 v0.1.0 · 开发构建');
    expect(
      AppUpdatePage.summary(state).endsWith('开发构建'),
      isTrue,
      reason: '测试里这份构建没有 APP_TAG，摘要必须说清它是开发构建',
    );
  });

  testWidgets('检查进行中：按钮禁用并显示「正在检查…」', (tester) async {
    await pumpPage(tester);
    service.pendingCheck = Completer<AppUpdateCheck>();

    await tapKey(tester, 'settings-update-check');
    expect(find.text('正在检查…'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('settings-update-check')),
          )
          .onPressed,
      isNull,
      reason: '检查在飞时按钮必须禁用（避免连点发出第二个请求）',
    );

    service.pendingCheck!.complete(
      _check(AppUpdateVerdict.updateAvailable, release: _release()),
    );
    service.pendingCheck = null;
    await tester.pumpAndSettle();
    expect(find.text('检查更新'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('settings-update-check')),
          )
          .onPressed,
      isNotNull,
    );
    expect(service.checkCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('下载并安装：进度可见、成功通知、已下载后只安装', (tester) async {
    await pumpPage(tester);
    await tapKey(tester, 'settings-update-check');
    await tester.pumpAndSettle();

    service.pendingDownload = Completer<void>();
    await tapKey(tester, 'settings-update-install');
    final progress = find.byKey(const ValueKey('settings-update-progress'));
    expect(progress, findsOneWidget, reason: '下载中必须出现进度条');
    expect(
      tester.widget<LinearProgressIndicator>(progress).value,
      closeTo(0.5, 0.001),
      reason: '半包时应显示中间进度，而不是不确定态',
    );
    expect(find.text('正在下载…'), findsOneWidget);
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('settings-update-channel-beta')),
          )
          .onSelected,
      isNull,
    );
    await state.setUpdateChannel(AppUpdateChannel.beta);
    expect(state.updatePreferences.channel, AppUpdateChannel.stable);
    expect(
      await state.setUpdateGithubProxy(
        const AppUpdateProxySettings(enabled: false),
      ),
      isFalse,
    );
    final checksBefore = service.checkCalls;
    await state.checkForUpdates();
    expect(service.checkCalls, checksBefore);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('settings-update-install')),
          )
          .onPressed,
      isNull,
    );

    service.pendingDownload!.complete();
    service.pendingDownload = null;
    await tester.pumpAndSettle();

    expect(service.downloadCalls, 1);
    expect(service.installCalls, 1);
    expect(
      find.byKey(const ValueKey('settings-update-progress')),
      findsNothing,
    );
    expect(
      find.text(service.installResult.message!),
      findsOneWidget,
      reason: '安装结果必须留在页面文本里',
    );
    expect(toastCenter.toasts.last.kind, ToastKind.success);
    expect(toastCenter.toasts.last.message, '更新已下载并校验通过');

    // 已下载过再点：不再下载，只重试安装。
    await tapKey(tester, 'settings-update-install');
    await tester.pumpAndSettle();
    expect(service.downloadCalls, 1, reason: '已下载的包不该再下载一次');
    expect(service.installCalls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('下载失败：原因留在页面文本，通知是错误态', (tester) async {
    await pumpPage(tester);
    await tapKey(tester, 'settings-update-check');
    await tester.pumpAndSettle();

    service.downloadError = 'SHA-256 校验失败，文件已删除';
    await tapKey(tester, 'settings-update-install');
    await tester.pumpAndSettle();

    expect(service.installCalls, 0, reason: '下载失败不得进入安装');
    final result = find.byKey(const ValueKey('settings-update-result'));
    expect(result, findsOneWidget);
    expect(tester.widget<Text>(result).data, 'SHA-256 校验失败，文件已删除');
    expect(toastCenter.toasts.last.kind, ToastKind.error);
    expect(tester.takeException(), isNull);
  });

  testWidgets('自动检查与通道真的落盘 settings.json 的 update 段', (tester) async {
    await pumpPage(tester);
    expect(updateSection()['autoCheck'], isNull);

    final autoCheck = find.byKey(const ValueKey('settings-update-auto-check'));
    await tester.tap(autoCheck);
    await settleSettingsIo(tester);
    expect(tester.widget<SwitchListTile>(autoCheck).value, isTrue);
    await waitForRealIo(tester, () => updateSection()['autoCheck'] == true);
    expect(updateSection()['autoCheck'], isTrue);
    expect(updateSection()['channel'], 'stable');

    await tapKey(tester, 'settings-update-channel-beta');
    await settleSettingsIo(tester);
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('settings-update-channel-beta')),
          )
          .selected,
      isTrue,
    );
    await waitForRealIo(tester, () => updateSection()['channel'] == 'beta');
    expect(updateSection()['channel'], 'beta');

    // 下一次检查必须用新通道（通道只是偏好，真正生效在请求参数上）。
    await tapKey(tester, 'settings-update-check');
    await tester.pumpAndSettle();
    expect(service.lastChannel, AppUpdateChannel.beta);

    // 再切回稳定版：写盘与通道都要跟着回去（「永远写 beta」的实现会露馅）。
    await tapKey(tester, 'settings-update-channel-stable');
    await settleSettingsIo(tester);
    await waitForRealIo(tester, () => updateSection()['channel'] == 'stable');
    expect(updateSection()['channel'], 'stable');
    expect(tester.takeException(), isNull);
  });

  testWidgets('设置「维护」里的入口行摘要与页面同源，点击进入本页', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(body: SettingsPage(state: state)),
      ),
    );
    await tester.pumpAndSettle();

    await selectSettingsCategory(tester, 'maintenance');
    await revealCategoryRow(
      tester,
      category: 'maintenance',
      rowKey: 'settings-update-open',
    );
    expect(
      tester.widget(find.byKey(const ValueKey('settings-update-open'))),
      isA<SettingsNavRow>(),
      reason: '入口必须是「进入下一级」的行，而不是内联控件',
    );
    final subtitle = find.byKey(const ValueKey('settings-update-summary'));
    expect(subtitle, findsOneWidget);
    expect(
      tester.widget<Text>(subtitle).data,
      AppUpdatePage.summary(state),
      reason: '行摘要必须与页面同源（同一份状态、同一套文案）',
    );

    await tester.tap(find.byKey(const ValueKey('settings-update-open')));
    await pumpSettingsSettled(tester);
    expect(find.widgetWithText(AppBar, '软件更新'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-update-auto-check')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('壳层首帧后自动检查：右下角提示一次，动作直达本页', (tester) async {
    // 造一份「上次检查早已过期」的偏好：开关打开，但 lastCheckedAt 为空
    // （切一次通道会把上次检查时间清掉，这正是真实的「换通道后重新查」）。
    await state.setUpdateAutoCheck(true);
    await state.checkForUpdates();
    await state.setUpdateChannel(AppUpdateChannel.beta);
    await state.setUpdateChannel(AppUpdateChannel.stable);
    state.clearUpdateNotice();
    final callsBefore = service.checkCalls;

    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: AppShell(state: state, startup: const StartupArguments()),
      ),
    );
    // 有界收敛：启动期的真实 I/O 与后台刷新不等价于 pumpAndSettle 能推完。
    for (var round = 0; round < 20; round++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 8)),
      );
    }

    expect(
      service.checkCalls,
      greaterThan(callsBefore),
      reason: '壳层首帧之后必须真的自动检查一次（闸门已过期）',
    );
    final notice = toastCenter.toasts.last;
    expect(notice.message, '发现新版本 $_tag');
    expect(notice.detail, '点「查看」打开软件更新');
    expect(notice.action?.label, '查看');

    // 动作必须真的把用户送到「软件更新」页，而不是只切个分类。
    notice.action!.onPressed();
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, '软件更新'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    for (final size in const [Size(480, 640), Size(1440, 900)]) {
      testWidgets('有新版本时不溢出 ${brightness.name} '
          '${size.width.toInt()}x${size.height.toInt()}', (tester) async {
        // 长发布说明 + 更新可用：最挤的一种状态（说明区封顶 240）。
        service.result = _check(
          AppUpdateVerdict.updateAvailable,
          release: _release(body: List.filled(80, '修复若干问题与体验改进。').join('\n')),
        );
        await state.checkForUpdates();
        await pumpPage(tester, size: size, brightness: brightness);
        expect(tester.takeException(), isNull, reason: '$size 溢出');

        // 注：发布说明的正文（settings-update-notes）按设计高于视口，
        // 它的约束由下面那条 240 上限断言负责，这里只检查外层控件。
        for (final key in [...alwaysKeys, 'settings-update-new-version']) {
          tester
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position
              .jumpTo(0);
          await tester.pumpAndSettle();
          final target = find.byKey(ValueKey(key));
          await tester.scrollUntilVisible(
            target,
            160,
            scrollable: find.byType(Scrollable).first,
          );
          expect(target, findsOneWidget, reason: '$key 在 $size 下不存在');
          await tester.ensureVisible(target);
          await tester.pumpAndSettle();
          final rect = tester.getRect(target);
          expect(rect.left, greaterThanOrEqualTo(0), reason: key);
          expect(rect.right, lessThanOrEqualTo(size.width), reason: key);
          expect(rect.top, greaterThanOrEqualTo(0), reason: key);
          expect(rect.bottom, lessThanOrEqualTo(size.height), reason: key);
        }

        // 说明区高度上限：80 行正文不得把「下载并安装」挤出几屏之外。
        final notes = find.byKey(const ValueKey('settings-update-notes'));
        expect(notes, findsOneWidget);
        final notesScroll = find
            .ancestor(of: notes, matching: find.byType(SingleChildScrollView))
            .first;
        expect(tester.getSize(notesScroll).height, lessThanOrEqualTo(240.0));
        final install = find.byKey(const ValueKey('settings-update-install'));
        await tester.ensureVisible(install);
        await tester.pumpAndSettle();
        final installRect = tester.getRect(install);
        expect(installRect.width, lessThanOrEqualTo(size.width));
        expect(installRect.left, greaterThanOrEqualTo(0));
        expect(tester.takeException(), isNull, reason: '$size 溢出');
      });
    }
  }
}
