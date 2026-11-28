/// 手动网盘账号条目的桌面入口门禁。
///
/// 钉的是四件事：
/// 1. JVM 标记条目在真正**进入详情之前**就换成账号配置页——不加载详情、不碰站源。
/// 2. 取消/返回/清除确认取消都不落盘；保存与清除才写应用级账号文件。
/// 3. 输入框默认遮蔽、错误提示不回显内容、重复提交只写一次。
/// 4. 普通影片与不合法的标记条目仍然走原来的详情路径。
///
/// 时序注意：账号读写是**真实文件 IO**。`pumpAndSettle` 只推进帧与假定时器，
/// 不推进真实 IO 完成，所以等待读写落地必须让出真实事件循环（`runAsync`）再泵帧，
/// 见 [settle]。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/spider_account.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/services/spider_account_store.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/glass_dialog.dart';
import 'package:webhtv_pc/ui/spider_account_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/detail_test_seams.dart';
import 'support/temp_dirs.dart';
import 'support/test_fonts.dart';

/// 纯内存 store：只记录界面交给它的值。
///
/// 为什么 widget 用例不碰真 store：SpiderAccountStore 的写入要拿跨进程文件锁，
/// 那个锁在 testWidgets 的假异步区里永远不完成（真实 app 没有这个问题）。
/// 界面层的期望因此是「原样转发 + 状态/提示正确」；真 store 的落盘、规范化与
/// 拒绝规则由文件末尾的普通 test（真文件、真 event loop）单独钉住。
class _RecordingStore implements SpiderAccountStore {
  _RecordingStore(this.path);

  @override
  final String path;
  int reads = 0;
  int saves = 0;
  int clears = 0;
  bool failReads = false;
  bool failSaves = false;
  Completer<void>? saveGate;
  SpiderAccountStoreException? saveException;
  final Map<SpiderAccountProvider, String> values = {};

  void seed(SpiderAccountProvider provider, String value) {
    values[provider] = value;
  }

  @override
  Future<String?> read(SpiderAccountProvider provider) async {
    reads++;
    if (failReads) throw const SpiderAccountStoreException('读取失败');
    return values[provider];
  }

  @override
  Future<void> save(SpiderAccountProvider provider, String value) async {
    saves++;
    final gate = saveGate;
    if (gate != null) await gate.future;
    final rejected = saveException;
    if (rejected != null) throw rejected;
    if (failSaves) throw const SpiderAccountStoreException('写入失败');
    values[provider] = value;
  }

  @override
  Future<void> clear(SpiderAccountProvider provider) async {
    clears++;
    values[provider] = '';
  }
}

/// AppState 只替换「账号存储」和「详情加载」两个缝：
/// 详情加载被计数而不发请求，于是「不加载影片」是可断言的零，而不是靠文本推断。
class _TestState extends AppState with ExternalMetaOff {
  _TestState({
    required super.paths,
    required super.log,
    required this.spiderStore,
  });

  final SpiderAccountStore spiderStore;
  int detailLoads = 0;
  int categoryRefreshes = 0;
  bool failRefresh = false;

  @override
  SpiderAccountStore get spiderAccounts => spiderStore;

  @override
  Future<void> loadDetail(
    Vod vod, {
    SiteService? serviceOverride,
    Site? siteOverride,
  }) async {
    detailLoads++;
  }

  @override
  Future<void> refreshSpiderAccountCategory() async {
    categoryRefreshes++;
    if (failRefresh) throw const SpiderAccountRefreshException();
  }
}

/// 视觉证据单独跑：
///
/// 已知限制：本机无头环境里 `RepaintBoundary.toImage` 会挂住（两次尝试都在这一步
/// 停住，没有产出 PNG），所以默认跳过，绝不让它拖住行为套件。

/// 截图路径要真正产出 PNG（`toImage`），在 CI/无头环境里它可能卡住整个套件。
/// 默认只跑行为用例，需要出图时显式：
///   WEBHTV_CAPTURE_UI=1 flutter test test/spider_account_page_test.dart
final bool _captureEnabled = Platform.environment['WEBHTV_CAPTURE_UI'] == '1';

/// 真 store 集成用例：默认不跑。
///
/// 它要在 testWidgets 里真的写文件（跨进程文件锁），在没有真实事件循环的环境
/// 里可能卡死；行为套件不能被它拖住，所以显式开关：
///   WEBHTV_REAL_STORE_UI=1 flutter test test/spider_account_page_test.dart
final bool _realStoreEnabled =
    Platform.environment['WEBHTV_REAL_STORE_UI'] == '1';

void main() {
  late Directory temp;
  late _RecordingStore store;
  late _TestState state;
  late String accountPath;

  _TestState stateWith(SpiderAccountStore accountStore) => _TestState(
    paths: AppPaths.resolve(
      overrides: {
        'config': p.join(temp.path, 'config'),
        'data': p.join(temp.path, 'data'),
        'cache': p.join(temp.path, 'cache'),
        'state': p.join(temp.path, 'state'),
      },
    ),
    log: MemoryOnlyLogService(),
    spiderStore: accountStore,
  );

  // 字体必须在 setUpAll 里加载：FontLoader 走平台通道，放进 testWidgets 的假异步区会一直不返回。
  setUpAll(() async {
    // 主题的 CJK 走 familyFallback；测试环境没有系统字体，必须按同一个族名加载，
    // 否则截图里全是豆腐块（这不是产品缺陷，是截图前提）。
    if (_captureEnabled) {
      await loadFixtureFonts(cjkFamily: 'Microsoft YaHei UI');
    }
  });

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('webhtv-spider-account-ui');
    accountPath = p.join(temp.path, 'spiders', 'accounts.json');
    store = _RecordingStore(accountPath);
    state = stateWith(store);
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    await deleteTempDirBestEffort(temp);
  });

  /// 让真实文件 IO 有机会完成，再推进帧（两件事都要做）。
  Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
    await tester.pump();
    for (var round = 0; round < rounds; round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle(
      const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
  }

  Vod markerVod(String id, String provider, String operation) => Vod(
    vodId: id,
    vodName: '账号配置',
    extra: {
      VodAccountActionKey: {
        'version': 1,
        'provider': provider,
        'operation': operation,
      },
    },
  );

  Map<String, Object?> readAccounts() =>
      jsonDecode(File(accountPath).readAsStringSync()) as Map<String, Object?>;

  Map<String, String> readValues() {
    final values = readAccounts()['values'];
    return (values as Map).cast<String, String>();
  }

  /// 已保存的值既不能出现在文案里，也不能出现在输入框内容里。
  void expectNoSecretRendered(WidgetTester tester, String secret) {
    final rendered = <String>[
      ...tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data ?? ''),
      ...tester
          .widgetList<EditableText>(find.byType(EditableText))
          .map((field) => field.controller.text),
    ];
    expect(
      rendered.where((text) => text.contains(secret)),
      isEmpty,
      reason: '已保存的值不得出现在界面上（含输入框）',
    );
  }

  /// 输入框里的内容本来就在输入框里；这里只钉「文案不得回显它」。
  void expectSecretNotEchoedByCopy(WidgetTester tester, String secret) {
    final copy = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data ?? '')
        .toList();
    expect(
      copy.where((text) => text.contains(secret)),
      isEmpty,
      reason: '错误/提示文案不得回显输入内容',
    );
  }

  /// 从一个宿主页 push 详情页，返回才能被真实验证（根路由 pop 不掉）。
  Future<void> pumpRoutedDetail(
    WidgetTester tester,
    Vod vod, {
    AppState? appState,
  }) async {
    final pageState = appState ?? state;
    tester.view.physicalSize = const Size(1308, 798);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => DetailPage(state: pageState, vod: vod),
                  ),
                ),
                child: const Text('打开条目'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开条目'));
    await settle(tester);
  }

  Future<void> openEditor(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('spider-account-edit')));
    await settle(tester);
  }

  Future<void> typeSecret(WidgetTester tester, String value) async {
    await tester.enterText(
      find.byKey(const ValueKey('spider-account-secret')),
      value,
    );
    await tester.pump();
  }

  Future<void> tapSave(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('spider-account-save')));
    await settle(tester);
  }

  Future<void> pumpAccountPage(
    WidgetTester tester,
    SpiderAccountAction action,
  ) async {
    tester.view.physicalSize = const Size(1308, 798);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: SpiderAccountPage(state: state, action: action),
      ),
    );
    await settle(tester);
  }

  Finder inDialog(Finder matching) =>
      find.descendant(of: find.byType(GlassAlertDialog), matching: matching);

  // 存储层契约：真 store、普通 test（不经过 testWidgets 的假异步区）。
  group('真 store 落盘契约', () {
    test('保存合成 Cookie 写出预期的应用级 JSON', () async {
      final real = SpiderAccountStore(path: accountPath);
      await real.save(
        SpiderAccountProvider.quark,
        '  Cookie: synthetic=abc; token=xyz  ',
      );
      expect(readAccounts()['version'], 1);
      expect(readValues(), {'Wex_quark_cookie': 'synthetic=abc; token=xyz'});
    });

    test('清除写空字符串墓碑而不是删键', () async {
      final real = SpiderAccountStore(path: accountPath);
      await real.save(SpiderAccountProvider.baidu, 'synthetic=tomb');
      await real.clear(SpiderAccountProvider.baidu);
      expect(readValues().containsKey('Wex_baidu_cookie'), isTrue);
      expect(readValues()['Wex_baidu_cookie'], '');
      expect(await real.read(SpiderAccountProvider.baidu), '');
    });

    test('换行与超长被 store 拒绝，消息不带内容', () async {
      final real = SpiderAccountStore(path: accountPath);
      await expectLater(
        real.save(SpiderAccountProvider.quark, 'synthetic=a\nsynthetic=b'),
        throwsA(
          isA<SpiderAccountStoreException>().having(
            (error) => error.message,
            'message',
            '账号内容不能包含换行',
          ),
        ),
      );
      await expectLater(
        real.save(SpiderAccountProvider.quark, 'x' * 33000),
        throwsA(
          isA<SpiderAccountStoreException>().having(
            (error) => error.message,
            'message',
            '账号内容超过大小上限',
          ),
        ),
      );
      expect(File(accountPath).existsSync(), isFalse);
    });
  });
  testWidgets('标记条目先进入账号配置页，影片详情一次都不加载', (tester) async {
    await pumpRoutedDetail(tester, markerVod('quarkmanual', 'quark', 'edit'));

    expect(find.byType(SpiderAccountPage), findsOneWidget);
    expect(
      find.byKey(const ValueKey('spider-account-scan-only')),
      findsNothing,
      reason: '普通手动条目不标扫码提示',
    );
    expect(find.text('未配置'), findsOneWidget);
    expect(
      find.textContaining('还没有应用级 Cookie'),
      findsOneWidget,
      reason: '状态标签与它的解释都要在',
    );
    expect(state.detailLoads, 0, reason: '账号条目不得调用 loadDetail，也就不会发站源/TMDB 请求');
  });

  testWidgets('未配置时点编辑进入输入框；取消不写文件也不离开', (tester) async {
    await pumpRoutedDetail(tester, markerVod('quarkmanual', 'quark', 'edit'));
    await openEditor(tester);

    expect(find.byType(GlassAlertDialog), findsOneWidget);
    // 提交之前就要看到后果：这是应用级共享值，不是某个站源的私有设置。
    expect(inDialog(find.textContaining('应用级共享')), findsOneWidget);
    expect(inDialog(find.textContaining('Wex_quark_cookie')), findsOneWidget);
    await typeSecret(tester, 'synthetic=fixture');
    await tester.tap(find.byKey(const ValueKey('spider-account-cancel')));
    await settle(tester);

    expect(store.saves, 0);
    expect(File(accountPath).existsSync(), isFalse);
    expect(store.clears, 0);
    expect(find.byType(SpiderAccountPage), findsOneWidget);
    expect(state.detailLoads, 0);
  });

  testWidgets('保存写入预期的应用级 JSON、刷新分类后返回', (tester) async {
    await pumpRoutedDetail(tester, markerVod('quarkmanual', 'quark', 'edit'));
    await openEditor(tester);
    await typeSecret(tester, '  Cookie: synthetic=abc; token=xyz  ');
    await tapSave(tester);

    expect(store.saves, 1);
    // 界面原样转发；规范化与落盘由 store 负责（见文件末尾的真 store 用例）。
    expect(
      store.values[SpiderAccountProvider.quark],
      '  Cookie: synthetic=abc; token=xyz  ',
    );
    expect(File(accountPath).existsSync(), isFalse);
    expect(state.categoryRefreshes, 1);
    expect(find.byType(SpiderAccountPage), findsNothing, reason: '写成功后返回上一层');
    expect(state.detailLoads, 0);
    expectNoSecretRendered(tester, 'synthetic=abc');
  });

  testWidgets('清除要自己的确认：保留不动值，确认写空值墓碑', (tester) async {
    store.seed(SpiderAccountProvider.quark, 'synthetic=keep');
    await pumpRoutedDetail(tester, markerVod('quarkclear', 'quark', 'clear'));
    expect(find.text('已配置'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('spider-account-clear')));
    await settle(tester);
    expect(find.text('清除夸克账号？'), findsOneWidget);
    expect(inDialog(find.textContaining('兼容站源生效')), findsOneWidget);
    expect(inDialog(find.textContaining('不会回退到站源旧的本地值')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('spider-account-clear-cancel')));
    await settle(tester);

    expect(store.clears, 0);
    expect(
      await store.read(SpiderAccountProvider.quark),
      'synthetic=keep',
      reason: '取消清除必须保留原值',
    );

    await tester.tap(find.byKey(const ValueKey('spider-account-clear')));
    await settle(tester);
    await tester.tap(
      find.byKey(const ValueKey('spider-account-clear-confirm')),
    );
    await settle(tester);

    expect(store.clears, 1);
    expect(
      await store.read(SpiderAccountProvider.quark),
      '',
      reason: '确认清除写出空值墓碑',
    );
    expect(state.categoryRefreshes, 1);
    expect(state.detailLoads, 0);
    expectNoSecretRendered(tester, 'synthetic=keep');
  });

  testWidgets('保存进行中重复点保存只写一次', (tester) async {
    store.saveGate = Completer<void>();
    await pumpRoutedDetail(tester, markerVod('baidumanual', 'baidu', 'edit'));
    await openEditor(tester);
    await typeSecret(tester, 'synthetic=dup');
    await tester.tap(find.byKey(const ValueKey('spider-account-save')));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('spider-account-save')),
      warnIfMissed: false,
    );
    await tester.pump();

    expect(store.saves, 1);
    store.saveGate!.complete();
    await settle(tester);
    expect(store.saves, 1);
    expect(store.values[SpiderAccountProvider.baidu], 'synthetic=dup');
  });

  testWidgets('超长内容被拒，提示不回显输入', (tester) async {
    await pumpRoutedDetail(tester, markerVod('quarkmanual', 'quark', 'edit'));
    await openEditor(tester);

    final overlong = 'synthetic=${'x' * 33000}';
    await typeSecret(tester, overlong);
    await tapSave(tester);

    expect(find.text('内容超过 32768 字节上限'), findsOneWidget);
    expect(store.saves, 0);
    expectSecretNotEchoedByCopy(tester, 'synthetic=');
    expect(File(accountPath).existsSync(), isFalse);
  });

  testWidgets('存储层拒绝换行时，界面只给脱敏提示', (tester) async {
    // 单行遮蔽输入框会把换行滤掉，所以真实的换行拒绝来自 store；
    // 这里钉的是「UI 把这个拒绝原样、脱敏地转述，且不回显内容」。
    store.saveException = const SpiderAccountStoreException('账号内容不能包含换行');
    await pumpRoutedDetail(tester, markerVod('quarkmanual', 'quark', 'edit'));
    await openEditor(tester);
    await typeSecret(tester, 'synthetic=crlf');
    await tapSave(tester);

    expect(find.text('保存失败：账号内容不能包含换行'), findsOneWidget);
    expect(store.saves, 1);
    expectSecretNotEchoedByCopy(tester, 'synthetic=crlf');
    expect(File(accountPath).existsSync(), isFalse);
  });

  testWidgets('内容默认遮蔽，显示是一次显式动作', (tester) async {
    await pumpRoutedDetail(tester, markerVod('quarkmanual', 'quark', 'edit'));
    await openEditor(tester);

    TextField field() => tester.widget<TextField>(
      find.byKey(const ValueKey('spider-account-secret')),
    );
    expect(field().obscureText, isTrue);

    await tester.tap(find.byKey(const ValueKey('spider-account-reveal')));
    await tester.pump();
    expect(field().obscureText, isFalse);

    await tester.tap(find.byKey(const ValueKey('spider-account-reveal')));
    await tester.pump();
    expect(field().obscureText, isTrue);
  });

  testWidgets('保存失败留在输入框里，可直接重试', (tester) async {
    store.failSaves = true;
    await pumpRoutedDetail(tester, markerVod('quarkmanual', 'quark', 'edit'));
    await openEditor(tester);
    await typeSecret(tester, 'synthetic=retry');
    await tapSave(tester);

    expect(find.text('保存失败：写入失败'), findsOneWidget);
    expect(store.saves, 1);
    expect(File(accountPath).existsSync(), isFalse);

    store.failSaves = false;
    await tapSave(tester);
    expect(store.saves, 2);
    expect(store.values[SpiderAccountProvider.quark], 'synthetic=retry');
    expectNoSecretRendered(tester, 'synthetic=retry');
  });

  testWidgets('刷新失败不回滚已保存的值，并如实提示', (tester) async {
    state.failRefresh = true;
    await pumpRoutedDetail(tester, markerVod('quarkmanual', 'quark', 'edit'));
    await openEditor(tester);
    await typeSecret(tester, 'synthetic=refresh');
    await tapSave(tester);

    expect(store.values[SpiderAccountProvider.quark], 'synthetic=refresh');
    expect(state.categoryRefreshes, 1);
    expect(find.byKey(const ValueKey('spider-account-notice')), findsOneWidget);
    expect(find.textContaining('保存成功，刷新未完成'), findsOneWidget);
    expect(find.byType(SpiderAccountPage), findsOneWidget);
    expectNoSecretRendered(tester, 'synthetic=refresh');
  });

  testWidgets('状态读取失败给重试，且不显示任何已保存内容', (tester) async {
    store.seed(SpiderAccountProvider.quark, 'synthetic=secret-value');
    store.failReads = true;
    await pumpRoutedDetail(tester, markerVod('quarkmanual', 'quark', 'edit'));
    expect(find.textContaining('暂时无法读取当前状态'), findsOneWidget);
    expectNoSecretRendered(tester, 'synthetic=secret-value');

    store.failReads = false;
    await tester.tap(find.byKey(const ValueKey('spider-account-status-retry')));
    await settle(tester);
    expect(find.text('已配置'), findsOneWidget);
    expectNoSecretRendered(tester, 'synthetic=secret-value');
  });

  testWidgets('保存进行中整页卸载不抛 Navigator/setState 异常', (tester) async {
    store.saveGate = Completer<void>();
    await pumpRoutedDetail(tester, markerVod('quarkmanual', 'quark', 'edit'));
    await openEditor(tester);
    await typeSecret(tester, 'synthetic=unmount');
    await tester.tap(find.byKey(const ValueKey('spider-account-save')));
    await tester.pump();

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();
    // store 是纯内存的：只要让被挂起的 save 完成，看有没有迟到 setState/Navigator。
    store.saveGate!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
  });

  testWidgets('普通影片仍然加载详情', (tester) async {
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: DetailPage(
          state: state,
          vod: Vod(vodId: '1001', vodName: '普通电影'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(state.detailLoads, 1);
    expect(find.byType(SpiderAccountPage), findsNothing);
  });

  testWidgets('伪造/错配的标记仍按普通条目处理', (tester) async {
    final forged = Vod(
      vodId: 'quarkmanual',
      vodName: '普通条目',
      extra: {
        VodAccountActionKey: {
          'version': 1,
          'provider': 'baidu',
          'operation': 'edit',
        },
      },
    );
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: DetailPage(state: state, vod: forged),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(SpiderAccountPage), findsNothing);
    expect(state.detailLoads, 1);
    expect(store.saves, 0);
  });

  testWidgets('真 store 集成：界面保存后账号 JSON 落地（runAsync 驱动）', (tester) async {
    final realState = stateWith(SpiderAccountStore(path: accountPath));
    addTearDown(realState.dispose);
    await realState.bootstrap();

    await pumpRoutedDetail(
      tester,
      markerVod('quarkmanual', 'quark', 'edit'),
      appState: realState,
    );
    await openEditor(tester);
    await typeSecret(tester, 'synthetic=fixture');
    await tester.tap(find.byKey(const ValueKey('spider-account-save')));
    await tester.pump();

    // 真实文件 IO 需要真实事件循环：runAsync 让出控制权，pump 再推进后续帧。
    for (var round = 0; round < 60; round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
      if (File(accountPath).existsSync()) break;
    }

    expect(readValues()['Wex_quark_cookie'], 'synthetic=fixture');
    expect(realState.categoryRefreshes, 1);
    expect(realState.detailLoads, 0);
  }, skip: !_realStoreEnabled);

  testWidgets('扫码/注册条目明说桌面端不可用，手动入口仍在', (tester) async {
    await pumpAccountPage(
      tester,
      const SpiderAccountAction(
        provider: SpiderAccountProvider.quark,
        operation: SpiderAccountOperation.edit,
        scanOnly: true,
      ),
    );

    expect(
      find.byKey(const ValueKey('spider-account-scan-only')),
      findsOneWidget,
    );
    expect(find.textContaining('不能完成扫码或注册'), findsOneWidget);
    expect(find.textContaining('手动填写的 Cookie 是支持的路径'), findsOneWidget);
    expect(find.byKey(const ValueKey('spider-account-edit')), findsOneWidget);
    expect(find.byKey(const ValueKey('spider-account-clear')), findsOneWidget);
  });

  testWidgets('普通手动条目没有扫码提示', (tester) async {
    await pumpAccountPage(
      tester,
      const SpiderAccountAction(
        provider: SpiderAccountProvider.baidu,
        operation: SpiderAccountOperation.edit,
      ),
    );

    expect(
      find.byKey(const ValueKey('spider-account-scan-only')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('spider-account-edit')), findsOneWidget);
  });

  testWidgets('扫码条目 ID 经 DetailPage 进入账号页并标注不可用', (tester) async {
    await pumpRoutedDetail(tester, markerVod('quark', 'quark', 'edit'));

    expect(find.byType(SpiderAccountPage), findsOneWidget);
    expect(
      find.byKey(const ValueKey('spider-account-scan-only')),
      findsOneWidget,
    );
    expect(state.detailLoads, 0);
  });

  testWidgets('受控 After 截图：暗色配置页 + 遮蔽的合成凭据', (tester) async {
    tester.view.physicalSize = const Size(1308, 798);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    store.seed(SpiderAccountProvider.quark, 'synthetic=fixture-only');
    final capture = GlobalKey();

    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: DetailPage(
            state: state,
            vod: markerVod('quarkmanual', 'quark', 'edit'),
          ),
        ),
      ),
    );
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('spider-account-edit')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    await typeSecret(tester, 'synthetic=fixture-only');
    await tester.pumpAndSettle(
      const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );

    final boundary =
        capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File(
        '../../.probe/manual-account-ui/after-spider-account-edit-1308x798.png',
      );
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    });

    expectSecretNotEchoedByCopy(tester, 'synthetic=');
  }, skip: !_captureEnabled);
  // 出图用法：WEBHTV_CAPTURE_UI=1 flutter test test/spider_account_page_test.dart
  // 默认跳过，截图路径不会拖住行为套件。
}
