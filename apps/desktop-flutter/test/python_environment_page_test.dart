/// 运行环境设置页（任务书 Task C）：状态呈现与四个操作的界面契约。
///
/// 纪律：
/// - 页面渲染的是**真实** [PythonEnvironmentPage]，只把「环境管理」这层外部
///   依赖换成 [AppState] 的子类替身（`pythonEnvironment*` 六个接口由 B 提供，
///   这里记录调用并返回可控结果）；文件选择器同样按页面公开的注入口替换，
///   不在用例里开真实系统对话框。
/// - 断言页面真实渲染出来的文字与控件状态；不篡改生产实现。
/// - 每个用例的目录都在 `Directory.systemTemp`，日志也指向 temp，
///   绝不写 `%APPDATA%`。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/python_environment.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/python_environment_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

/// 只替换「运行环境」这条外部依赖：其余 [AppState] 行为保持真实。
class _FakeEnvironmentState extends AppState {
  _FakeEnvironmentState({required super.paths, required super.log});

  PythonEnvironmentStatus? status;
  bool busy = false;
  String? operationError;

  int refreshCalls = 0;
  int repairCalls = 0;
  int restoreCalls = 0;
  final List<String> appliedPaths = <String>[];

  bool repairResult = true;
  bool customResult = true;
  bool restoreResult = true;
  Object? repairThrows;
  Object? refreshThrows;
  Object? customThrows;
  Object? restoreThrows;
  Future<void> Function()? refreshAction;
  Future<bool> Function()? repairAction;
  Future<bool> Function(String)? customAction;
  Future<bool> Function()? restoreAction;

  @override
  PythonEnvironmentStatus? get pythonEnvironmentStatus => status;

  @override
  bool get pythonEnvironmentBusy => busy;

  @override
  String? get pythonEnvironmentError => operationError;

  @override
  Future<void> refreshPythonEnvironment() async {
    refreshCalls++;
    if (refreshAction != null) return refreshAction!();
    final failure = refreshThrows;
    if (failure != null) throw failure;
  }

  @override
  Future<bool> repairPythonEnvironment() async {
    repairCalls++;
    if (repairAction != null) return repairAction!();
    final failure = repairThrows;
    if (failure != null) throw failure;
    return repairResult;
  }

  @override
  Future<bool> setCustomPythonExecutable(String executable) async {
    appliedPaths.add(executable);
    if (customAction != null) return customAction!(executable);
    final failure = customThrows;
    if (failure != null) throw failure;
    return customResult;
  }

  @override
  Future<bool> useDefaultPythonEnvironment() async {
    restoreCalls++;
    if (restoreAction != null) return restoreAction!();
    final failure = restoreThrows;
    if (failure != null) throw failure;
    return restoreResult;
  }
}

PythonEnvironmentStatus _status({
  String executable = '',
  String version = '',
  PythonEnvironmentSource source = PythonEnvironmentSource.missing,
  Map<String, bool> dependencies = const <String, bool>{},
  String? error,
}) => PythonEnvironmentStatus(
  executable: executable,
  version: version,
  source: source,
  dependencies: dependencies,
  error: error,
);

Finder _key(String key) => find.byKey(ValueKey<String>(key));

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(_key(key)).data ?? '';

const _operations = <String, String>{
  'refresh': '重新检测完成。',
  'repair': '离线修复完成，运行环境已重新准备。',
  'restore-default': '已恢复默认内置运行时。',
  'custom-apply': r'已切换自定义解释器：D:\candidate\python.exe',
};

void _pendingOperation(
  _FakeEnvironmentState state,
  String operation,
  Completer<bool> pending,
) {
  switch (operation) {
    case 'refresh':
      state.refreshAction = () async {
        await pending.future;
      };
    case 'repair':
      state.repairAction = () => pending.future;
    case 'restore-default':
      state.restoreAction = () => pending.future;
    case 'custom-apply':
      state.customAction = (_) => pending.future;
  }
}

int _operationCalls(_FakeEnvironmentState state, String operation) =>
    switch (operation) {
      'refresh' => state.refreshCalls,
      'repair' => state.repairCalls,
      'restore-default' => state.restoreCalls,
      'custom-apply' => state.appliedPaths.length,
      _ => throw ArgumentError(operation),
    };

String _candidate(WidgetTester tester) => tester
    .widget<TextField>(_key('python-environment-custom-path'))
    .controller!
    .text;

void _expectControls(WidgetTester tester, {required bool disabled}) {
  for (final operation in [..._operations.keys, 'pick']) {
    expect(
      tester
          .widget<ButtonStyleButton>(_key('python-environment-$operation'))
          .onPressed,
      disabled ? isNull : isNotNull,
      reason: operation,
    );
  }
}

void main() {
  late Directory temp;
  late AppPaths paths;
  late _FakeEnvironmentState state;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('webhtv_python_page_');
    LogService.logDirectoryOverride = p.join(temp.path, 'logs');
    paths = AppPaths.resolve(
      overrides: {
        'config': p.join(temp.path, 'config'),
        'data': p.join(temp.path, 'data'),
        'cache': p.join(temp.path, 'cache'),
        'state': p.join(temp.path, 'logs'),
      },
    );
    paths.ensureDirectories();
    state = _FakeEnvironmentState(paths: paths, log: LogService());
  });

  tearDown(() {
    state.dispose();
    LogService.logDirectoryOverride = null;
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    Size size = const Size(1000, 1600),
    Future<String?> Function()? pickExecutablePath,
    bool settle = true,
    AppState? pageState,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: PythonEnvironmentPage(
          state: pageState ?? state,
          pickExecutablePath: pickExecutablePath,
        ),
      ),
    );
    // 忙碌态的进度圈是无限动画：`pumpAndSettle` 永远等不到静止，只能推进帧。
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      160,
      scrollable: find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('未检测时如实说明没有状态，四个操作仍可用', (tester) async {
    await pumpPage(tester);

    expect(_key('python-environment-status'), findsOneWidget);
    expect(_text(tester, 'python-environment-status'), contains('尚未检测'));
    expect(find.textContaining('不联网'), findsOneWidget);
    for (final key in <String>[
      'python-environment-refresh',
      'python-environment-repair',
      'python-environment-custom-apply',
      'python-environment-restore-default',
    ]) {
      expect(
        tester.widget<ButtonStyleButton>(_key(key)).onPressed,
        isNotNull,
        reason: '$key 在非忙碌时必须可用',
      );
    }
    expect(_key('python-environment-status-error'), findsNothing);
  });

  testWidgets('内置环境显示路径、版本、来源与逐项依赖状态', (tester) async {
    state.status = _status(
      executable: r'C:\App\runtime\python\python.exe',
      version: '3.13.5',
      source: PythonEnvironmentSource.bundled,
      dependencies: <String, bool>{'requests': true, 'lxml': false},
    );
    await pumpPage(tester);

    expect(
      _text(tester, 'python-environment-path'),
      contains(r'C:\App\runtime\python\python.exe'),
    );
    expect(_text(tester, 'python-environment-version'), contains('3.13.5'));
    expect(_text(tester, 'python-environment-source'), '内置运行时');
    expect(
      _text(tester, 'python-environment-dependency-requests'),
      contains('可用'),
    );
    expect(_text(tester, 'python-environment-dependency-lxml'), contains('缺失'));
    expect(_key('python-environment-status-error'), findsNothing);
    expect(find.text('内置运行时'), findsOneWidget);
  });

  testWidgets('版本号原样来自状态，依赖齐备才判为可用', (tester) async {
    state.status = _status(
      executable: r'D:\WebHTV\runtime\python\python.exe',
      version: '3.12.11',
      source: PythonEnvironmentSource.bundled,
      dependencies: const <String, bool>{
        'requests': true,
        'Crypto': true,
        'lxml': true,
        'bs4': true,
      },
    );
    await pumpPage(tester);

    expect(_text(tester, 'python-environment-version'), '3.12.11');
    expect(_text(tester, 'python-environment-status'), '当前运行环境可用。');
    expect(_text(tester, 'python-environment-status'), isNot(contains('不可用')));
    for (final module in <String>['requests', 'Crypto', 'lxml', 'bs4']) {
      expect(
        _text(tester, 'python-environment-dependency-$module'),
        contains('可用'),
      );
    }
    expect(find.text('3.13.5'), findsNothing);
  });

  testWidgets('当前环境故障与操作失败分开显示，不混成一条', (tester) async {
    state.status = _status(
      source: PythonEnvironmentSource.missing,
      error: '内置包缺失：bundle.json 不存在',
    );
    state.operationError = '重新检测失败：拒绝访问';
    await pumpPage(tester);

    expect(_text(tester, 'python-environment-status-error'), contains('内置包缺失'));
    expect(
      _text(tester, 'python-environment-message'),
      contains('重新检测失败：拒绝访问'),
    );
    expect(
      _text(tester, 'python-environment-status-error'),
      isNot(contains('重新检测失败')),
    );
  });

  testWidgets('四个操作分别调用对应接口并给出可见结果', (tester) async {
    await pumpPage(tester);

    await tester.tap(_key('python-environment-refresh'));
    await tester.pumpAndSettle();
    expect(state.refreshCalls, 1);
    expect(_text(tester, 'python-environment-message'), contains('重新检测完成'));

    await tester.tap(_key('python-environment-repair'));
    await tester.pumpAndSettle();
    expect(state.repairCalls, 1);
    expect(_text(tester, 'python-environment-message'), contains('离线修复完成'));

    await tester.tap(_key('python-environment-restore-default'));
    await tester.pumpAndSettle();
    expect(state.restoreCalls, 1);
    expect(_text(tester, 'python-environment-message'), contains('已恢复默认内置运行时'));

    await tester.enterText(
      _key('python-environment-custom-path'),
      r'D:\tools\py\python.exe',
    );
    await tester.tap(_key('python-environment-custom-apply'));
    await tester.pumpAndSettle();
    expect(state.appliedPaths, <String>[r'D:\tools\py\python.exe']);
    expect(_text(tester, 'python-environment-message'), contains('已切换自定义解释器'));
  });

  testWidgets('自定义解释器被拒绝时不误报成功，仍显示旧解释器', (tester) async {
    state.status = _status(
      executable: r'C:\App\runtime\python\python.exe',
      version: '3.13.5',
      source: PythonEnvironmentSource.bundled,
      dependencies: const <String, bool>{'requests': true},
    );
    state.customResult = false;
    await pumpPage(tester);

    await tester.enterText(
      _key('python-environment-custom-path'),
      r'D:\broken\python.exe',
    );
    await tester.tap(_key('python-environment-custom-apply'));
    await tester.pumpAndSettle();

    final message = _text(tester, 'python-environment-message');
    expect(message, contains('未生效'));
    expect(message, contains(r'C:\App\runtime\python\python.exe'));
    expect(message, contains('保持不变'));
    expect(
      _text(tester, 'python-environment-path'),
      contains(r'C:\App\runtime\python\python.exe'),
    );
    expect(
      state.pythonEnvironmentStatus?.executable,
      isNot(contains('broken')),
    );
  });

  testWidgets('操作抛异常时显示具体原因并恢复可操作', (tester) async {
    state.repairThrows = StateError('测试磁盘只读');
    await pumpPage(tester);

    await tester.tap(_key('python-environment-repair'));
    await tester.pumpAndSettle();

    expect(_text(tester, 'python-environment-message'), contains('测试磁盘只读'));
    expect(
      tester
          .widget<ButtonStyleButton>(_key('python-environment-repair'))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('忙碌时四个操作与回车入口都不能重入', (tester) async {
    state.busy = true;
    await pumpPage(tester, settle: false);

    expect(_key('python-environment-busy'), findsOneWidget);
    for (final key in <String>[
      'python-environment-refresh',
      'python-environment-repair',
      'python-environment-custom-apply',
      'python-environment-restore-default',
      'python-environment-pick',
    ]) {
      expect(
        tester.widget<ButtonStyleButton>(_key(key)).onPressed,
        isNull,
        reason: '$key 在忙碌时必须禁用',
      );
    }

    await tester.enterText(
      _key('python-environment-custom-path'),
      r'D:\tools\py\python.exe',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(state.appliedPaths, isEmpty);
  });

  testWidgets('空路径与取消选择都不提交，旧解释器不被抢走', (tester) async {
    state.status = _status(
      executable: r'C:\App\runtime\python\python.exe',
      version: '3.13.5',
      source: PythonEnvironmentSource.bundled,
    );
    await pumpPage(tester, pickExecutablePath: () async => null);

    await tester.enterText(_key('python-environment-custom-path'), '   ');
    await tester.tap(_key('python-environment-custom-apply'));
    await tester.pumpAndSettle();
    expect(state.appliedPaths, isEmpty);
    expect(_text(tester, 'python-environment-message'), contains('请填写'));

    await tester.tap(_key('python-environment-pick'));
    await tester.pumpAndSettle();
    expect(state.appliedPaths, isEmpty);
    expect(
      tester
          .widget<TextField>(_key('python-environment-custom-path'))
          .controller!
          .text,
      isNot(contains('python.exe')),
    );
    expect(
      _text(tester, 'python-environment-path'),
      contains(r'C:\App\runtime\python\python.exe'),
    );
  });

  testWidgets('选择文件只填入候选路径，确认后才提交', (tester) async {
    await pumpPage(
      tester,
      pickExecutablePath: () async => r'D:\tools\py\python.exe',
    );

    await tester.tap(_key('python-environment-pick'));
    await tester.pumpAndSettle();
    expect(state.appliedPaths, isEmpty);
    expect(
      tester
          .widget<TextField>(_key('python-environment-custom-path'))
          .controller!
          .text,
      r'D:\tools\py\python.exe',
    );

    await tester.tap(_key('python-environment-custom-apply'));
    await tester.pumpAndSettle();
    expect(state.appliedPaths, <String>[r'D:\tools\py\python.exe']);
  });

  testWidgets('异常与失败都给出具体原因，且只有这五个动作、没有在线入口', (tester) async {
    state.status = _status(
      executable: r'C:\App\runtime\python\python.exe',
      version: '3.13.5',
      source: PythonEnvironmentSource.bundled,
    );
    state.refreshThrows = const SocketException('测试网络栈已禁用');
    state.restoreResult = false;
    await pumpPage(tester);

    await tester.tap(_key('python-environment-refresh'));
    await tester.pumpAndSettle();
    expect(_text(tester, 'python-environment-message'), contains('测试网络栈已禁用'));

    await tester.tap(_key('python-environment-restore-default'));
    await tester.pumpAndSettle();
    expect(_text(tester, 'python-environment-message'), contains('恢复默认运行环境失败'));

    await tester.enterText(
      _key('python-environment-custom-path'),
      r'D:\broken\python.exe',
    );
    await tester.tap(_key('python-environment-custom-apply'));
    await tester.pumpAndSettle();
    expect(state.appliedPaths, <String>[r'D:\broken\python.exe']);

    // 动作面必须是这五个：任何新增的「下载 / 在线更新」按钮都会让计数变化。
    const labels = <String>[
      '重新检测',
      '离线修复内置环境',
      '恢复默认内置运行时',
      '选择 python.exe',
      '使用自定义解释器',
    ];
    // `ButtonStyleButton` 是抽象基类，`find.byType` 只精确匹配运行时类型，
    // 所以这里按类型谓词数按钮。
    final buttons = find.byWidgetPredicate(
      (widget) => widget is ButtonStyleButton,
      description: '页面上的动作按钮',
    );
    expect(buttons, findsNWidgets(labels.length));
    for (final label in labels) {
      expect(
        find.descendant(of: buttons, matching: find.text(label)),
        findsOneWidget,
        reason: '$label 必须是页面上的真实动作',
      );
    }
    expect(find.textContaining('不联网、不下载'), findsOneWidget);
  });

  for (final source in [
    PythonEnvironmentSource.missing,
    PythonEnvironmentSource.bundled,
  ]) {
    testWidgets('非ready摘要精确区分missing与依赖降级 $source', (tester) async {
      state.status = _status(
        executable: source == PythonEnvironmentSource.missing
            ? ''
            : r'C:\old\python.exe',
        version: '3.14.10',
        source: source,
        dependencies: const {'requests': true, 'lxml': false},
        error: source == PythonEnvironmentSource.missing ? '发行包不存在' : null,
      );
      await pumpPage(tester);
      expect(
        _text(tester, 'python-environment-status'),
        source == PythonEnvironmentSource.missing
            ? '未检测到可用解释器，Python 站源暂时不能使用。'
            : '当前运行环境不可用，Python 站源暂时不能使用。',
      );
      expect(_text(tester, 'python-environment-status'), isNot('当前运行环境可用。'));
    });
  }

  testWidgets('repair false反馈具体服务原因且保留当前解释器', (tester) async {
    state.status = _status(
      executable: r'C:\old\python.exe',
      source: PythonEnvironmentSource.bundled,
    );
    state.repairAction = () async {
      state.operationError = '运行中的 Python 源使用此环境，拒绝修复';
      return false;
    };
    await pumpPage(tester);
    await tester.tap(_key('python-environment-repair'));
    await tester.pumpAndSettle();
    expect(_text(tester, 'python-environment-message'), contains('离线修复未成功'));
    expect(
      _text(tester, 'python-environment-message'),
      contains('运行中的 Python 源'),
    );
    expect(
      _text(tester, 'python-environment-message'),
      isNot(contains('修复完成')),
    );
    expect(_text(tester, 'python-environment-path'), r'C:\old\python.exe');
    _expectControls(tester, disabled: false);
  });

  for (final operation in ['custom-apply', 'restore-default']) {
    testWidgets('$operation throw具体反馈且保持旧解释器', (tester) async {
      state.status = _status(
        executable: r'C:\old\python.exe',
        source: PythonEnvironmentSource.bundled,
      );
      if (operation == 'custom-apply') {
        state.customThrows = StateError('自定义环境无法读取');
      } else {
        state.restoreThrows = StateError('默认环境校验失败');
      }
      await pumpPage(tester);
      await tester.enterText(
        _key('python-environment-custom-path'),
        r'D:\candidate\python.exe',
      );
      await tester.tap(_key('python-environment-$operation'));
      await tester.pumpAndSettle();
      expect(
        _text(tester, 'python-environment-message'),
        contains(operation == 'custom-apply' ? '自定义环境无法读取' : '默认环境校验失败'),
      );
      expect(
        _text(tester, 'python-environment-message'),
        isNot(contains('已切换')),
      );
      expect(
        _text(tester, 'python-environment-message'),
        isNot(contains('已恢复')),
      );
      expect(_text(tester, 'python-environment-path'), r'C:\old\python.exe');
      _expectControls(tester, disabled: false);
      expect(tester.takeException(), isNull);
    });
  }

  for (final operation in _operations.keys) {
    testWidgets('$operation 正常返回但getter报错时只显示失败不误报成功', (tester) async {
      state.status = _status(executable: r'C:\old\python.exe', error: '当前依赖缺失');
      final pending = Completer<bool>();
      _pendingOperation(state, operation, pending);
      await pumpPage(tester);
      await tester.enterText(
        _key('python-environment-custom-path'),
        r'D:\candidate\python.exe',
      );
      await tester.tap(_key('python-environment-$operation'));
      await tester.pump();
      state.operationError = '服务拒绝操作：Python 源运行中';
      pending.complete(true);
      await tester.pumpAndSettle();
      expect(
        _text(tester, 'python-environment-message'),
        contains('服务拒绝操作：Python 源运行中'),
      );
      expect(
        _text(tester, 'python-environment-message'),
        isNot(contains(_operations[operation]!)),
      );
      expect(_text(tester, 'python-environment-status-error'), '当前依赖缺失');
      expect(
        _text(tester, 'python-environment-status-error'),
        isNot(contains('运行中')),
      );
      expect(_text(tester, 'python-environment-path'), r'C:\old\python.exe');
      _expectControls(tester, disabled: false);
    });

    testWidgets('$operation pending封闭快速双击与回车，完成才恢复控件', (tester) async {
      final pending = Completer<bool>();
      _pendingOperation(state, operation, pending);
      await pumpPage(tester);
      await tester.enterText(
        _key('python-environment-custom-path'),
        r'D:\candidate\python.exe',
      );
      final callback = tester
          .widget<ButtonStyleButton>(_key('python-environment-$operation'))
          .onPressed!;
      callback();
      callback();
      // 下一帧按钮尚未改为disabled，回车和其它入口也必须由同步守卫拒绝。
      tester
          .widget<TextField>(_key('python-environment-custom-path'))
          .onSubmitted!(_candidate(tester));
      tester
          .widget<ButtonStyleButton>(_key('python-environment-repair'))
          .onPressed!();
      await tester.pump();
      _expectControls(tester, disabled: true);
      expect(_key('python-environment-busy'), findsOneWidget);
      expect(_operationCalls(state, operation), 1);
      expect(state.appliedPaths.length, operation == 'custom-apply' ? 1 : 0);
      expect(state.repairCalls, operation == 'repair' ? 1 : 0);
      pending.complete(true);
      await tester.pumpAndSettle();
      _expectControls(tester, disabled: false);
      expect(
        _text(tester, 'python-environment-message'),
        _operations[operation],
      );
    });
  }

  testWidgets('文件选择pending占互斥锁：帧前重复与环境操作及回车均拒绝', (tester) async {
    final pending = Completer<String?>();
    var picks = 0;
    await pumpPage(
      tester,
      pickExecutablePath: () {
        picks++;
        return pending.future;
      },
    );
    await tester.enterText(
      _key('python-environment-custom-path'),
      r'C:\draft\python.exe',
    );
    final pick = tester
        .widget<ButtonStyleButton>(_key('python-environment-pick'))
        .onPressed!;
    pick();
    pick();
    tester
        .widget<ButtonStyleButton>(_key('python-environment-repair'))
        .onPressed!();
    tester
        .widget<TextField>(_key('python-environment-custom-path'))
        .onSubmitted!(_candidate(tester));
    await tester.pump();
    _expectControls(tester, disabled: true);
    expect(picks, 1);
    expect(state.repairCalls, 0);
    expect(state.appliedPaths, isEmpty);
    pending.complete(r'D:\picked\python.exe');
    await tester.pumpAndSettle();
    expect(_candidate(tester), r'D:\picked\python.exe');
    expect(_text(tester, 'python-environment-message'), contains('候选路径'));
    expect(state.appliedPaths, isEmpty);
    _expectControls(tester, disabled: false);
  });

  testWidgets('选择器返回时外部busy则丢弃结果，不覆盖候选与服务反馈', (tester) async {
    final pending = Completer<String?>();
    await pumpPage(tester, pickExecutablePath: () => pending.future);
    await tester.enterText(
      _key('python-environment-custom-path'),
      r'C:\draft\python.exe',
    );
    await tester.tap(_key('python-environment-pick'));
    state.busy = true;
    state.operationError = '其它环境操作进行中';
    state.notifyListeners();
    pending.complete(r'D:\stale\python.exe');
    await tester.pump();
    expect(_candidate(tester), r'C:\draft\python.exe');
    expect(_text(tester, 'python-environment-message'), '其它环境操作进行中');
    _expectControls(tester, disabled: true);
    state.busy = false;
    state.notifyListeners();
    await tester.pumpAndSettle();
    _expectControls(tester, disabled: false);
  });

  testWidgets('选择器throw反馈具体错误且finally释放互斥', (tester) async {
    final pending = Completer<String?>();
    await pumpPage(tester, pickExecutablePath: () => pending.future);
    await tester.enterText(
      _key('python-environment-custom-path'),
      r'C:\draft\python.exe',
    );
    await tester.tap(_key('python-environment-pick'));
    await tester.pump();
    _expectControls(tester, disabled: true);
    pending.completeError(StateError('原生选择器不可用'));
    await tester.pumpAndSettle();
    expect(_text(tester, 'python-environment-message'), contains('原生选择器不可用'));
    expect(_candidate(tester), r'C:\draft\python.exe');
    _expectControls(tester, disabled: false);
    expect(tester.takeException(), isNull);
  });

  for (final operation in [..._operations.keys, 'pick']) {
    for (final result in ['success', 'false', 'throw']) {
      testWidgets('$operation $result A→B过期结果不污染新页面也不解新锁', (tester) async {
        state.status = _status(
          executable: r'C:\A\python.exe',
          source: PythonEnvironmentSource.custom,
        );
        final oldPending = Completer<bool>();
        final oldPick = Completer<String?>();
        if (operation != 'pick') {
          _pendingOperation(state, operation, oldPending);
        }
        final next = _FakeEnvironmentState(paths: paths, log: LogService());
        addTearDown(next.dispose);
        next.status = _status(
          executable: r'C:\B\python.exe',
          source: PythonEnvironmentSource.custom,
        );
        final nextPending = Completer<bool>();
        _pendingOperation(next, 'refresh', nextPending);
        await pumpPage(tester, pickExecutablePath: () => oldPick.future);
        await tester.enterText(
          _key('python-environment-custom-path'),
          r'D:\candidate\python.exe',
        );
        await tester.tap(_key('python-environment-$operation'));
        await tester.pump();
        await pumpPage(tester, pageState: next, settle: false);
        expect(_candidate(tester), r'C:\B\python.exe');
        expect(_key('python-environment-message'), findsNothing);
        expect(_text(tester, 'python-environment-path'), r'C:\B\python.exe');
        _expectControls(tester, disabled: false);
        state.status = _status(executable: r'C:\A-notify\python.exe');
        state.notifyListeners();
        await tester.pump();
        expect(_text(tester, 'python-environment-path'), r'C:\B\python.exe');
        await tester.tap(_key('python-environment-refresh'));
        await tester.pump();
        if (operation == 'pick') {
          if (result == 'throw') {
            oldPick.completeError(StateError('A选择异常'));
          } else {
            oldPick.complete(
              result == 'false' ? null : r'D:\A-picked\python.exe',
            );
          }
        } else {
          if (result == 'throw') {
            oldPending.completeError(StateError('A操作异常'));
          } else {
            oldPending.complete(result == 'success');
          }
        }
        await tester.pump();
        expect(_candidate(tester), r'C:\B\python.exe');
        expect(_key('python-environment-message'), findsNothing);
        _expectControls(tester, disabled: true);
        nextPending.complete(true);
        await tester.pumpAndSettle();
        expect(_text(tester, 'python-environment-message'), '重新检测完成。');
        expect(
          _text(tester, 'python-environment-message'),
          isNot(contains('A')),
        );
        _expectControls(tester, disabled: false);
        expect(tester.takeException(), isNull);
      });
    }

    for (final throws in [false, true]) {
      testWidgets('$operation pending卸载后${throws ? '异常' : '完成'}无回调泄漏', (
        tester,
      ) async {
        final pending = Completer<bool>();
        final picked = Completer<String?>();
        if (operation != 'pick') {
          _pendingOperation(state, operation, pending);
        }
        await pumpPage(tester, pickExecutablePath: () => picked.future);
        await tester.enterText(
          _key('python-environment-custom-path'),
          r'D:\candidate\python.exe',
        );
        await tester.tap(_key('python-environment-$operation'));
        await tester.pump();
        await tester.pumpWidget(const SizedBox());
        state.notifyListeners();
        if (operation == 'pick') {
          if (throws) {
            picked.completeError(StateError('卸载后选择失败'));
          } else {
            picked.complete(r'D:\picked\python.exe');
          }
        } else {
          if (throws) {
            pending.completeError(StateError('卸载后操作失败'));
          } else {
            pending.complete(true);
          }
        }
        await tester.pumpAndSettle();
        expect(find.byType(PythonEnvironmentPage), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('窄窗关键控件可达且不溢出，离线边界说明始终可见', (tester) async {
    state.status = _status(
      executable: r'C:\App\runtime\python\python.exe',
      version: '3.13.5',
      source: PythonEnvironmentSource.bundled,
      dependencies: const <String, bool>{'requests': true, 'lxml': true},
    );
    await pumpPage(tester, size: const Size(480, 700));

    for (final key in <String>[
      'python-environment-status',
      'python-environment-pick',
      'python-environment-custom-path',
      'python-environment-restore-default',
    ]) {
      await reveal(tester, _key(key));
      expect(_key(key), findsOneWidget, reason: '$key 在窄窗应可达');
    }
    expect(tester.takeException(), isNull);
    expect(find.textContaining('离线修复'), findsWidgets);
    expect(find.textContaining('不会删除专用运行环境'), findsOneWidget);
  });
}
