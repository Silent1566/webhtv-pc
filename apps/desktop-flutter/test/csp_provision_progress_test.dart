/// 导入后自动安装 csp 站源：进度、安装中的站点文案与首页一次性补载。
///
/// 用户实测 2026-11-24：导入后界面只报「配置导入成功：93 个站点（可用 8 个）」
/// 与红字「缺少桌面 JVM 站源…」，而后台其实在装、约 90 秒后装完并自动出了首页。
/// 这些断言把「装的过程中界面必须如实说在装」钉住。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/ipc_protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/csp_jar_probe.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/spider_registry.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/config_pages.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/test_fonts.dart';

/// 全程离线的 AppState：站点请求一律 404，绝不碰真实 socket。
class _ProgressState extends AppState {
  _ProgressState(AppPaths paths)
    : super(
        paths: paths,
        log: LogService(),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );

  AppConfig? probeConfig;

  @override
  AppConfig? get effectiveConfig => probeConfig ?? super.effectiveConfig;

  int homeCalls = 0;
  final _pendingHomeLoads = <Future<void>>{};

  @override
  Future<void> loadHome(Site site) async {
    homeCalls++;
    final pending = super.loadHome(site);
    _pendingHomeLoads.add(pending);
    try {
      await pending;
    } finally {
      _pendingHomeLoads.remove(pending);
    }
  }
}

class _ObservedSites extends ListBase<Site> {
  _ObservedSites(this.site);
  final Site site;
  int reads = 0;
  @override
  int get length {
    reads++;
    return 1;
  }

  @override
  set length(int value) => throw UnsupportedError('read-only');
  @override
  Site operator [](int index) => site;
  @override
  void operator []=(int index, Site value) =>
      throw UnsupportedError('read-only');
}

Map<String, Object?> _site(String key) => {
  'key': key,
  'name': key,
  'type': 3,
  'api': 'csp_Demo',
};

const _jar = 'https://example.test/shared.jar';

Site _siteOf(String key) => Site(key: key, name: key, type: 3, api: 'csp_Demo');

/// 把进度直接种进状态层：widget 级用例只验证导入页确实在读它。
class _SeededProgressState extends _ProgressState {
  _SeededProgressState(super.paths);

  CspProvisionProgress seeded = const CspProvisionProgress();
  String? seededSummary;

  @override
  CspProvisionProgress get cspProvisionProgress => seeded;

  @override
  String? get cspProvisionSummary => seededSummary;
}

class _CaptureState extends _ProgressState {
  _CaptureState(super.paths) {
    debugCspProvisionOverride = (config, {onProgress, onEntry}) {
      progressCallback = onProgress;
      entryCallback = onEntry;
      if (!runnerStarted.isCompleted) runnerStarted.complete();
      return result.future;
    };
  }

  final Zone ioZone = Zone.current;
  final runnerStarted = Completer<void>();
  final imported = Completer<void>();
  final result = Completer<CspProbeReport>();
  void Function(ShellUnpackTick)? progressCallback;
  void Function(CspProbeEntry)? entryCallback;

  @override
  Future<void> get shellTargetsProbe => Future<void>.value();

  @override
  Future<bool> importConfig(String input, {String? displayName}) =>
      ioZone.run(() async {
        final fixture = jsonEncode({
          'name': '东篱',
          'spider': _jar,
          'sites': [
            ...List.generate(78, (i) => _site('dongli-$i')),
            ...List.generate(
              15,
              (i) => {
                'key': 'http-$i',
                'name': '在线站点 $i',
                'type': 1,
                'api': 'https://example.test/api',
              },
            ),
          ],
        });
        final ok = await super.importConfig(
          input == 'https://16151.kstore.space/' ? fixture : input,
          displayName: displayName,
        );
        if (!imported.isCompleted) imported.complete();
        return ok;
      });
}

class _CountCaptureState extends _CaptureState {
  _CountCaptureState(super.paths);
  @override
  Future<void> loadHome(Site site) async {
    if (homeCalls == 0) {
      await super.loadHome(site);
    } else {
      homeCalls++;
      seedListingForTest(const []);
    }
  }
}

class _LateDirectState extends AppState {
  _LateDirectState(AppPaths paths)
    : super(
        paths: paths,
        log: LogService(),
        httpClient: MockClient((_) async => http.Response('', 404)),
        jsSidecarHostPath: '${paths.dataDir}/host.js',
      ) {
    debugDirectProbeOverride = (_) {
      if (!directStarted.isCompleted) directStarted.complete();
      return directResult.future;
    };
    debugCspProvisionOverride = (_, {onProgress, onEntry}) {
      cspStarted.complete();
      return cspResult.future;
    };
  }

  final Zone ioZone = Zone.current;
  final imported = Completer<bool>();
  final cspStarted = Completer<void>();
  final directStarted = Completer<void>();
  final cspResult = Completer<CspProbeReport>();
  final directResult = Completer<Map<String, LocalSpider>>();

  @override
  Future<void> get shellTargetsProbe => Future<void>.value();

  @override
  Future<void> loadHome(Site site) async {}

  @override
  Future<bool> importConfig(String input, {String? displayName}) =>
      ioZone.run(() async {
        final ok = await super.importConfig(input, displayName: displayName);
        if (!imported.isCompleted) imported.complete(ok);
        return ok;
      });
}

class _ObservedDirectSpider extends LocalSpider {
  _ObservedDirectSpider(
    AppPaths paths,
    this.entryReads, {
    String key = 'direct',
  }) : super(
         manifest: SpiderManifest(
           key: key,
           name: 'JS',
           runtime: 'node-tvbox',
           entry: 'entry.js',
           capabilities: ['home'],
         ),
         manifestPath: '${paths.dataDir}/manifest.json',
         rootDir: paths.dataDir,
         entryPath: '${paths.dataDir}/entry.js',
       );

  final SendPort entryReads;

  @override
  bool get entryExists {
    entryReads.send(Isolate.current.hashCode);
    return super.entryExists;
  }
}

class _HeldDirectSpider extends _ObservedDirectSpider {
  _HeldDirectSpider(super.paths, super.entryReads, this.release)
    : super(key: 'other');

  final String release;

  @override
  bool get entryExists {
    final clock = Stopwatch()..start();
    while (!File(release).existsSync() && clock.elapsedMilliseconds < 20000) {
      sleep(const Duration(milliseconds: 10));
    }
    return super.entryExists;
  }
}

Future<void> _whenState(AppState state, bool Function() ready) async {
  final completed = Completer<void>();
  void check() {
    if (!completed.isCompleted && ready()) completed.complete();
  }

  state.addListener(check);
  try {
    check();
    await completed.future.timeout(const Duration(seconds: 10));
  } finally {
    state.removeListener(check);
  }
}

void main() {
  late Directory temp;
  late _ProgressState state;
  late List<AppConfig> runs;
  late Completer<CspProbeReport> report;
  void Function(ShellUnpackTick tick)? progressSink;
  void Function(CspProbeEntry entry)? entrySink;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('webhtv-csp-progress-');
    state = _ProgressState(
      AppPaths.resolve(
        overrides: {
          'config': temp.path,
          'data': temp.path,
          'cache': '${temp.path}/cache',
          'state': '${temp.path}/logs',
        },
      ),
    );
    runs = [];
    report = Completer<CspProbeReport>();
    progressSink = null;
    entrySink = null;
    state.debugCspProvisionOverride = (config, {onProgress, onEntry}) {
      runs.add(config);
      progressSink = onProgress;
      entrySink = onEntry;
      return report.future;
    };
  });

  tearDown(() async {
    state.dispose();
    if (!report.isCompleted) report.complete(const CspProbeReport());
    await Future.wait(state._pendingHomeLoads.toList());
    expect(state._pendingHomeLoads, isEmpty, reason: '删除临时目录前必须等首页补载结束');
    try {
      await temp.delete(recursive: true);
    } catch (_) {
      // 补载/安装的落盘可能还在收尾：临时目录删不掉不影响结论。
    }
  });

  Future<void> importSites(List<Map<String, Object?>> sites) async {
    expect(
      await state.importConfig(jsonEncode({'spider': _jar, 'sites': sites})),
      isTrue,
    );
    await Future<void>.delayed(Duration.zero);
  }

  List<int> jarBytes(Map<String, List<int>> files) {
    final archive = Archive();
    for (final entry in files.entries) {
      archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
    }
    return ZipEncoder().encode(archive);
  }

  /// 模拟后台真把站点装好：写 index.jar + probe.json（binding.entryFor 读它）。
  Future<void> installFixture(String key, {AppState? target}) async {
    final binding = CspJvmBinding(root: (target ?? state).cspRoot)
        .forConfig(AppConfig(spider: _jar, sites: [_siteOf(key)]));
    final dir = binding.directoryFor(key);
    await Directory(dir).create(recursive: true);
    await File(p.join(dir, 'index.jar')).writeAsBytes(
      jarBytes({
        'com/github/catvod/spider/Demo.class': [1],
      }),
    );
    await File(p.join(dir, 'probe.json')).writeAsString(
      jsonEncode({
        'siteKey': key,
        'sourceUrl': _jar,
        'sourceApi': 'csp_Demo',
        'installed': true,
        'outcome': 'installed',
      }),
    );
  }

  test('安装中 expose total/done/阶段，结束清空 provisioning 集合', () async {
    await importSites([_site('a'), _site('b'), _site('c')]);
    expect(runs, hasLength(1));

    final started = state.cspProvisionProgress;
    expect(started.active, isTrue);
    expect(started.total, 3, reason: 'total 必须是本轮 selected 站点数');
    expect(started.done, 0);
    expect(state.cspProvisionSummary, isNull);
    expect(state.debugProvisioningSiteKeys, {'a', 'b', 'c'});

    await Future<void>.delayed(Duration.zero);
    var notifications = 0;
    state.addListener(() => notifications++);

    progressSink!(
      const ShellUnpackTick(
        jarIndex: 0,
        jarCount: 3,
        jarUrl: _jar,
        fraction: 0.1,
        stage: '转译-dex',
        eta: Duration(seconds: 14),
      ),
    );
    expect(notifications, 1, reason: '阶段变更要通知一次');
    expect(state.cspProvisionProgress.stage, '转译-dex');
    progressSink!(
      const ShellUnpackTick(
        jarIndex: 0,
        jarCount: 3,
        jarUrl: _jar,
        fraction: 0.2,
        stage: '转译-dex',
        eta: Duration(seconds: 13),
      ),
    );
    expect(notifications, 1, reason: '同一阶段的 tick 不得每次都 notify');

    var done = 0;
    for (final key in ['a', 'b', 'c']) {
      entrySink!(
        CspProbeEntry(siteKey: key, outcome: CspProbeOutcome.installed),
      );
      done++;
      expect(state.cspProvisionProgress.done, done);
      expect(state.cspProvisionProgress.active, isTrue);
      expect(notifications, 1 + done, reason: '每个站点结论各通知一次');
    }

    report.complete(
      const CspProbeReport(
        entries: [
          CspProbeEntry(siteKey: 'a', outcome: CspProbeOutcome.installed),
          CspProbeEntry(siteKey: 'b', outcome: CspProbeOutcome.installed),
          CspProbeEntry(siteKey: 'c', outcome: CspProbeOutcome.installed),
        ],
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final finished = state.cspProvisionProgress;
    expect(finished.active, isFalse);
    expect(finished.done, 3);
    expect(finished.total, 3);
    expect(finished.installed, 3);
    expect(state.cspProvisionSummary, contains('已自动安装 3 个站源'));
    expect(state.debugProvisioningSiteKeys, isEmpty);
  });

  test('安装中站点文案是「正在自动安装」而不是「缺少桌面 JVM 站源」', () async {
    await importSites([_site('a'), _site('b'), _site('c')]);
    expect(state.debugProvisioningSiteKeys, contains('a'));
    final availability = state.siteAvailabilityOf(_siteOf('a'));
    expect(availability.available, isFalse);
    expect(availability.reason, contains('正在自动安装站源'));
    expect(availability.reason, isNot(contains('缺少桌面 JVM 站源')));

    report.complete(
      const CspProbeReport(
        entries: [
          CspProbeEntry(
            siteKey: 'a',
            outcome: CspProbeOutcome.rejected,
            message: '缺 native',
          ),
        ],
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(state.debugProvisioningSiteKeys, isEmpty);
    expect(state.cspProvisionProgress.rejected, 1, reason: '结束后的摘要仍要如实报拒绝数');
  });

  test('安装中 loadHome 不报错、不调 service，装完只补载一次', () async {
    await importSites([_site('a')]);
    expect(runs, hasLength(1));
    expect(state.lastError, isNull, reason: '真实导入的首轮首页也不得产生 missing jar');
    expect(state.contentPhase, LoadPhase.loading);
    expect(state.log.entries.any((e) => e.message.contains('首页加载失败')), isFalse);
    final before = state.homeCalls;

    await state.loadHome(_siteOf('a'));
    expect(state.homeCalls, before + 1);
    expect(state.lastError, isNull, reason: '安装中不得把「还没装好」写成错误');
    expect(state.contentPhase, LoadPhase.loading);
    expect(state.notice, contains('正在后台安装'));

    await installFixture('a');
    report.complete(
      const CspProbeReport(
        entries: [
          CspProbeEntry(siteKey: 'a', outcome: CspProbeOutcome.installed),
        ],
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(state.homeCalls, before + 2, reason: '装完自动补载首页一次');
    expect(state.lastError, isNull);

    await state.provisionCspJarsQuietly(state.effectiveConfig!);
    await Future<void>.delayed(Duration.zero);
    expect(state.homeCalls, before + 2, reason: '一次性补载不得重复触发');
  });

  test('调用自动安装立即进入 unknown 准备状态，不提前读取站点', () async {
    final observed = _ObservedSites(_siteOf('queued'));
    final config = AppConfig(spider: _jar, sites: observed);
    state.probeConfig = config;
    final pending = state.provisionCspJarsQuietly(config);
    expect(observed.reads, 0);
    expect(state.cspProvisionProgress.active, isTrue);
    expect(state.cspProvisionProgress.total, 0);
    expect(state.cspProvisionProgress.fraction, isNull);
    expect(state.cspProvisionProgress.label, contains('正在检查站源'));
    await Future<void>.delayed(Duration.zero);
    report.complete(const CspProbeReport());
    await pending;
    expect(state.cspProvisionProgress.active, isFalse);
  });

  test('真实导入从返回至安装完成都不产生 missing jar 或首页失败日志', () async {
    final errors = <String>[];
    state.addListener(() {
      if (state.lastError != null) errors.add(state.lastError!.message);
    });
    final ok = await state.importConfig(
      jsonEncode({
        'spider': _jar,
        'sites': [_site('a')],
      }),
    );
    expect(ok, isTrue);
    expect(state.lastError, isNull);
    expect(state.contentPhase, LoadPhase.loading);
    await Future<void>.delayed(Duration.zero);
    expect(runs, hasLength(1));
    expect(state.lastError, isNull);
    expect(errors, isEmpty);
    expect(state.log.entries.any((e) => e.message.contains('首页加载失败')), isFalse);
    await installFixture('a');
    entrySink!(
      const CspProbeEntry(siteKey: 'a', outcome: CspProbeOutcome.installed),
    );
    report.complete(
      const CspProbeReport(
        entries: [
          CspProbeEntry(siteKey: 'a', outcome: CspProbeOutcome.installed),
        ],
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(state.homeCalls, 2);
    expect(state.lastError, isNull);
    expect(errors, isEmpty);
  });

  for (final outcome in [
    CspProbeOutcome.failed,
    CspProbeOutcome.rejected,
    CspProbeOutcome.needsShellRuntime,
  ]) {
    test('真实导入结束 $outcome 后退出 loading 并展示真实原因', () async {
      await importSites([_site('a')]);
      expect(state.lastError, isNull);
      const message = '本次安装结论：需要手动处理';
      final entry = CspProbeEntry(
        siteKey: 'a',
        outcome: outcome,
        message: message,
      );
      entrySink!(entry);
      report.complete(CspProbeReport(entries: [entry]));
      await Future<void>.delayed(Duration.zero);
      expect(state.cspProvisionProgress.active, isFalse);
      expect(state.debugProvisioningSiteKeys, isEmpty);
      expect(state.contentPhase, LoadPhase.failed);
      expect(state.lastError?.message, contains(message));
      expect(state.homeCalls, 1, reason: '失败不得请求尚不存在的站源');
    });
  }

  test('runner 抛异常后清 queued 标记并退出 loading', () async {
    await importSites([_site('a')]);
    report.completeError(StateError('离线取回失败'));
    await Future<void>.delayed(Duration.zero);
    expect(state.cspProvisionProgress.active, isFalse);
    expect(state.debugProvisioningSiteKeys, isEmpty);
    expect(state.contentPhase, LoadPhase.failed);
    expect(state.lastError?.message, contains('离线取回失败'));
  });

  test('runner 无结论时也不能永久 loading', () async {
    await importSites([_site('a')]);
    report.complete(const CspProbeReport());
    await Future<void>.delayed(Duration.zero);
    expect(state.cspProvisionProgress.active, isFalse);
    expect(state.contentPhase, LoadPhase.failed);
    expect(state.lastError?.message, contains('自动探测'));
  });

  test('超过四个 URL 的选中站点退出 loading 并提示显式探测', () async {
    await importSites(
      List.generate(
        5,
        (i) => {..._site('s$i'), 'jar': 'https://example.test/$i.jar'},
      ),
    );
    await state.selectSite(
      Site(
        key: 's4',
        name: 's4',
        type: 3,
        api: 'csp_Demo',
        jar: 'https://example.test/4.jar',
      ),
    );
    expect(state.contentPhase, LoadPhase.failed);
    expect(state.lastError?.message, contains('前 4 个 jar'));
    report.complete(const CspProbeReport());
    await Future<void>.delayed(Duration.zero);
    expect(state.cspProvisionProgress.active, isFalse);
  });

  test('切到已经检查过的配置，旧 callback 与 finally 不得发布到新页面', () async {
    final checked = AppConfig(
      sites: [
        Site(
          key: 'http',
          name: 'http',
          type: 1,
          api: 'https://example.test/api',
        ),
      ],
    );
    state.probeConfig = checked;
    await state.provisionCspJarsQuietly(checked);
    state.probeConfig = null;
    await importSites([_site('a')]);
    final oldTick = progressSink!;
    final oldEntry = entrySink!;
    state.probeConfig = checked;
    await state.provisionCspJarsQuietly(checked);
    final progress = state.cspProvisionProgress;
    final summary = state.cspProvisionSummary;
    expect(progress.active, isFalse);
    expect(state.debugProvisioningSiteKeys, isEmpty);
    oldTick(
      const ShellUnpackTick(
        jarIndex: 0,
        jarCount: 1,
        jarUrl: _jar,
        fraction: .5,
        stage: '迟到旧阶段',
      ),
    );
    oldEntry(
      const CspProbeEntry(siteKey: 'a', outcome: CspProbeOutcome.installed),
    );
    report.complete(
      const CspProbeReport(
        entries: [
          CspProbeEntry(siteKey: 'a', outcome: CspProbeOutcome.installed),
        ],
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(state.cspProvisionProgress, progress);
    expect(state.cspProvisionSummary, summary);
    expect(state.debugProvisioningSiteKeys, isEmpty);
  });

  testWidgets('导入页在 active 时显示进度文案与进度条', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CspProvisionProgressLine(
            progress: const CspProvisionProgress(
              active: true,
              done: 12,
              total: 78,
              stage: '转译',
              installed: 11,
              label: '正在自动安装站源 12/78 · 转译 Android 站源',
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('正在自动安装站源 12/78'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      closeTo(12 / 78, 1e-9),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CspProvisionProgressLine(
            progress: const CspProvisionProgress(),
            summary: '已自动安装 78 个站源',
          ),
        ),
      ),
    );
    expect(find.text('已自动安装 78 个站源'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('0/N 工作动画未知，12/78 显示确定进度与可访问语义', (tester) async {
    const zero = CspProvisionProgress(
      active: true,
      total: 78,
      stage: '下载站源',
      label: '正在自动安装站源 0/78 · 下载站源',
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: CspProvisionProgressLine(progress: zero)),
      ),
    );
    var bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, isNull, reason: '首站下载/转译没有可信百分比，必须显示工作动画');
    expect(find.textContaining('0/78'), findsOneWidget);
    expect(bar.semanticsLabel, zero.label);
    expect(bar.semanticsValue, '正在准备站源');
    const progressing = CspProvisionProgress(
      active: true,
      done: 12,
      total: 78,
      label: '正在自动安装站源 12/78 · 转译 Android 站源',
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: CspProvisionProgressLine(progress: progressing)),
      ),
    );
    bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(12 / 78, 1e-9));
    expect(bar.semanticsLabel, progressing.label);
    expect(bar.semanticsValue, '15');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('失败导入且旧配置还在准备时，错误行不得附成功承诺', (tester) async {
    final old = _SeededProgressState(
      AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/bad-import',
          'data': '${temp.path}/bad-import',
          'cache': '${temp.path}/bad-import/cache',
          'state': '${temp.path}/bad-import/logs',
        },
      ),
    );
    addTearDown(old.dispose);
    old.seeded = const CspProvisionProgress(
      active: true,
      total: 78,
      label: '正在自动安装站源 0/78 · 下载站源',
    );
    tester.view.physicalSize = const Size(1297, 791);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: ConfigPage(state: old),
      ),
    );
    await tester.enterText(find.byType(TextField).last, 'not a configuration');
    await tester.runAsync(() async {
      await tester.tap(find.text('导入'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(old.lastError, isNotNull);
    final messages = tester
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '');
    expect(messages.any((text) => text.contains('完成后自动可用')), isFalse);
    expect(messages.any((text) => text.contains('准备完成后刷新可用状态')), isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  const directSite = {
    'key': 'direct',
    'name': 'JS',
    'type': 3,
    'api': 'https://example.test/entry.js',
  };

  Future<_LateDirectState> importDirectPage(
    WidgetTester tester, {
    bool withCsp = false,
    bool withOther = false,
  }) async {
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/late-direct',
        'data': '${temp.path}/late-direct',
        'cache': '${temp.path}/late-direct/cache',
        'state': '${temp.path}/late-direct/logs',
      },
    );
    final page = (await tester.runAsync(() async => _LateDirectState(paths)))!;
    addTearDown(() {
      page.dispose();
      if (!page.cspResult.isCompleted) {
        page.cspResult.complete(const CspProbeReport());
      }
      if (!page.directResult.isCompleted) page.directResult.complete({});
    });
    await tester.runAsync(() async {
      await Directory(paths.dataDir).create(recursive: true);
      await File('${paths.dataDir}/host.js').writeAsString('');
      await File('${paths.dataDir}/entry.js').writeAsString('');
    });
    tester.view.physicalSize = const Size(1297, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: ConfigPage(state: page),
      ),
    );
    await tester.enterText(
      find.byType(TextField).last,
      jsonEncode({
        if (withCsp) 'spider': _jar,
        'sites': [
          directSite,
          if (withOther) {...directSite, 'key': 'other'},
          if (withCsp) ...[
            {
              'key': 'http',
              'name': 'HTTP',
              'type': 1,
              'api': 'https://example.test/api',
            },
            _site('csp'),
          ],
        ],
      }),
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('导入'));
      await Future.wait([
        page.imported.future,
        page.directStarted.future,
        if (withCsp) page.cspStarted.future,
      ]).timeout(const Duration(seconds: 10));
    });
    expect(page.imported.isCompleted, isTrue);
    expect(await tester.runAsync(() => page.imported.future), isTrue);
    expect(page.cspStarted.isCompleted, withCsp);
    expect(page.directStarted.isCompleted, isTrue);
    await tester.pump();
    return page;
  }

  Future<List<int>> finishDirect(
    WidgetTester tester,
    _LateDirectState page,
  ) async {
    final reads = <int>[];
    final port = ReceivePort()..listen((event) => reads.add(event as int));
    addTearDown(port.close);
    final local = _ObservedDirectSpider(page.paths, port.sendPort);
    await tester.runAsync(() async {
      page.directResult.complete({'direct': local});
      await _whenState(
        page,
        () => page.siteItems.any(
          (item) => item.site.key == 'direct' && item.availability.available,
        ),
      );
      await page.pythonEnvironmentIdle;
    });
    await tester.pump();
    expect(page.debugDirectSpiders.keys, ['direct']);
    expect(reads, isNotEmpty);
    expect(reads, everyElement(isNot(Isolate.current.hashCode)));
    return reads;
  }

  testWidgets('CSP 已 settled 时直连随后成功仍刷新导入结果可用数', (tester) async {
    final page = await importDirectPage(tester, withCsp: true);
    expect(find.textContaining('可用 1 个'), findsOneWidget);
    await tester.runAsync(() async {
      page.cspResult.complete(const CspProbeReport());
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    final settled = page.cspProvisionProgress;
    expect(settled.active, isFalse);
    expect(find.textContaining('可用 1 个'), findsOneWidget);
    await finishDirect(tester, page);
    expect(page.cspProvisionProgress, settled);
    expect(page.usableSiteCount, 2);
    expect(find.textContaining('可用 2 个'), findsOneWidget);
    expect(find.textContaining('可用 1 个'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('纯直连无 CSP 工作时注册完成刷新结果，无关通知不重建或重复查盘', (tester) async {
    final page = await importDirectPage(tester);
    expect(find.textContaining('可用 0 个'), findsOneWidget);
    final settled = page.cspProvisionProgress;
    expect(settled.active, isFalse);
    expect(settled.total, 0);
    final reads = await finishDirect(tester, page);
    expect(page.cspProvisionProgress, settled);
    expect(page.usableSiteCount, 1);
    final result = find.textContaining('导入成功：1 个站点（可用 1 个）');
    expect(result, findsOneWidget);
    expect(find.textContaining('可用 0 个'), findsNothing);
    final rendered = tester.widget<Text>(result);
    final entryReads = reads.length;
    expect(entryReads, greaterThan(0));
    for (var i = 0; i < 10; i++) {
      page.seedListingForTest(const []);
      await tester.pump();
    }
    await tester.runAsync(() => page.pythonEnvironmentIdle);
    expect(tester.widget<Text>(result), same(rendered));
    expect(reads.length, entryReads, reason: '无关通知须复用站点表缓存，不能再次查入口文件');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('当前站就绪立即刷新导入结果，不等待其他站点后台查盘', (tester) async {
    final page = await importDirectPage(tester, withOther: true);
    final release = '${page.paths.dataDir}/release-other';
    final reads = ReceivePort()..listen((_) {});
    addTearDown(reads.close);
    try {
      await tester.runAsync(() async {
        final ready = _whenState(
          page,
          () => page.siteItems.first.availability.available,
        );
        page.directResult.complete({
          'direct': _ObservedDirectSpider(page.paths, reads.sendPort),
          'other': _HeldDirectSpider(page.paths, reads.sendPort, release),
        });
        await ready;
      });
      await tester.pump();
      expect(find.textContaining('导入成功：2 个站点（可用 1 个）'), findsOneWidget);
      expect(page.siteItems.last.availability.preparing, isTrue);
      expect(File(release).existsSync(), isFalse);
    } finally {
      await tester.runAsync(() async {
        await File(release).writeAsString('release');
        await page.pythonEnvironmentIdle;
      });
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('另一配置直连完成的通知不得改写旧导入成功结果', (tester) async {
    final page = await importDirectPage(tester);
    final original = page.config;
    final oldResult = find.textContaining('导入成功：1 个站点（可用 0 个）');
    expect(oldResult, findsOneWidget);
    await tester.runAsync(() async {
      expect(
        await page.importConfig(
          jsonEncode({
            'sites': [
              {...directSite, 'api': 'https://example.test/new.js'},
            ],
          }),
        ),
        isTrue,
      );
    });
    await tester.pump();
    expect(identical(page.config, original), isFalse);
    await finishDirect(tester, page);
    expect(page.usableSiteCount, 1);
    expect(oldResult, findsOneWidget);
    expect(find.textContaining('可用 1 个'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('安装完成后导入结果更新可用数而不是保留初始快照', (tester) async {
    final page = (await tester.runAsync(
      () async => _CountCaptureState(
        AppPaths.resolve(
          overrides: {
            'config': '${temp.path}/count',
            'data': '${temp.path}/count',
            'cache': '${temp.path}/count/cache',
            'state': '${temp.path}/count/logs',
          },
        ),
      ),
    ))!;
    addTearDown(() {
      page.dispose();
      if (!page.result.isCompleted) {
        page.result.complete(const CspProbeReport());
      }
    });
    tester.view.physicalSize = const Size(1297, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: ConfigPage(state: page),
      ),
    );
    await tester.enterText(
      find.byType(TextField).last,
      'https://16151.kstore.space/',
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('导入'));
      await Future.wait([page.imported.future, page.runnerStarted.future])
          .timeout(const Duration(seconds: 10));
    });
    expect(page.imported.isCompleted, isTrue);
    await tester.pump();
    expect(find.textContaining('可用 15 个'), findsOneWidget);
    await tester.runAsync(() async {
      for (var i = 0; i < 78; i++) {
        await installFixture('dongli-$i', target: page);
      }
      page.result.complete(
        CspProbeReport(
          entries: [
            for (var i = 0; i < 78; i++)
              CspProbeEntry(
                siteKey: 'dongli-$i',
                outcome: CspProbeOutcome.installed,
              ),
          ],
        ),
      );
      await _whenState(
        page,
        () => !page.cspProvisionProgress.active && page.usableSiteCount == 93,
      );
    });
    await tester.pump();
    await tester.pump();
    expect(page.cspProvisionProgress.active, isFalse);
    expect(find.textContaining('可用 93 个'), findsOneWidget);
    expect(find.textContaining('可用 15 个'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('After 真实东篱导入：名称 URL 成功结果行及 12/78', (tester) async {
    await tester.runAsync(() async {
      final cjk = firstExisting(cjkFontCandidates());
      if (cjk != null) {
        final bytes = await cjk.readAsBytes();
        for (final family in [
          'FixtureCJK',
          'Microsoft YaHei UI',
          'Microsoft YaHei',
          'Noto Sans CJK SC',
          'Roboto',
          'Ahem',
        ]) {
          await (FontLoader(
            family,
          )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
        }
      }
      await loadFixtureFonts();
    });
    final page = (await tester.runAsync(
      () async => _CaptureState(
        AppPaths.resolve(
          overrides: {
            'config': '${temp.path}/shot',
            'data': '${temp.path}/shot',
            'cache': '${temp.path}/shot/cache',
            'state': '${temp.path}/shot/logs',
          },
        ),
      ),
    ))!;
    addTearDown(() {
      page.dispose();
      if (!page.result.isCompleted) {
        page.result.complete(const CspProbeReport());
      }
    });
    tester.view.physicalSize = const Size(1297, 791);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final theme = buildAppTheme(Brightness.dark);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: theme.copyWith(
          textTheme: theme.textTheme.apply(
            fontFamily: 'FixtureCJK',
            fontFamilyFallback: const ['FixtureCJK'],
          ),
          primaryTextTheme: theme.primaryTextTheme.apply(
            fontFamily: 'FixtureCJK',
            fontFamilyFallback: const ['FixtureCJK'],
          ),
        ),
        home: RepaintBoundary(
          key: boundary,
          child: ConfigPage(state: page),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField).first, '东篱');
    await tester.enterText(
      find.byType(TextField).last,
      'https://16151.kstore.space/',
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('导入'));
      await Future.wait([page.imported.future, page.runnerStarted.future])
          .timeout(const Duration(seconds: 10));
    });
    expect(page.imported.isCompleted, isTrue);
    expect(page.runnerStarted.isCompleted, isTrue);
    await tester.pump();
    expect(page.config!.sites, hasLength(93));
    expect(page.cspProvisionProgress.total, 78);
    expect(page.cspProvisionProgress.done, 0);
    expect(page.lastError, isNull);
    expect(find.textContaining('导入成功：93 个站点'), findsOneWidget);
    expect(find.textContaining('站源正在后台准备'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      isNull,
    );
    page.progressCallback!(
      const ShellUnpackTick(
        jarIndex: 0,
        jarCount: 78,
        jarUrl: _jar,
        fraction: 0,
        stage: '转译 Android 站源',
      ),
    );
    for (var i = 0; i < 12; i++) {
      page.entryCallback!(
        CspProbeEntry(siteKey: 'dongli-$i', outcome: CspProbeOutcome.installed),
      );
    }
    await tester.pump();
    expect(find.textContaining('正在自动安装站源 12/78'), findsOneWidget);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 350));
    final resultText = tester.widget<Text>(find.textContaining('导入成功：93 个站点'));
    expect(resultText.style!.color, isNot(theme.colorScheme.error));
    expect(tester.takeException(), isNull);
    if (Platform.environment['CSP_PROGRESS_CAPTURE'] == '1') {
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 1);
        expect(image.width, 1297);
        expect(image.height, 791);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(
          'F:/temp/dongli-progress-ui/after-dongli-import-12of78-1297x791-dark.png',
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
        // ignore: avoid_print
        print('captured ${file.path} (${bytes.lengthInBytes} bytes)');
      });
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('导入页把安装进度画在导入按钮下方', (tester) async {
    final seeded = _SeededProgressState(
      AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/seeded',
          'data': '${temp.path}/seeded',
          'cache': '${temp.path}/seeded/cache',
          'state': '${temp.path}/seeded/logs',
        },
      ),
    );
    addTearDown(seeded.dispose);
    seeded.seeded = const CspProvisionProgress(
      active: true,
      done: 3,
      total: 78,
      stage: '转译',
      label: '正在自动安装站源 3/78 · 转译',
    );
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: ConfigPage(state: seeded),
      ),
    );
    await tester.pump();
    expect(find.textContaining('正在自动安装站源 3/78'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });
}
