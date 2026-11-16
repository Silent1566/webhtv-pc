/// 本地源管理页交互（任务 C）：全选/取消全选、修改时间与排序、在线 HTML 网址。
///
/// 纪律：
/// - 每个用例都在 `Directory.systemTemp` 下建**真实**源目录并真实扫描，
///   通过注入 temp 的 [AppPaths] 完全隔离，绝不读写 `%APPDATA%`；
/// - 断言的是页面真实渲染出来的控件状态与文本，不是替身；
/// - 在线地址只做字段校验与登记调用，用例内不联网、不执行任何被扫描文件。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/web_home_store.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/local_sources_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'local_source_sites_test.dart' show deleteTempWhenReleased;

AppPaths _tempPaths(Directory temp) => AppPaths.resolve(
  overrides: {
    'config': p.join(temp.path, 'config'),
    'data': p.join(temp.path, 'data'),
    'cache': p.join(temp.path, 'cache'),
    'state': p.join(temp.path, 'logs'),
  },
);

Finder _key(String key) => find.byKey(ValueKey<String>(key));

/// 真实文件 IO 的完成回调落在 fake-async zone 之外，必须借 `runAsync`
/// 让它跑完，再 `pump` 让 `setState` 的结果上屏。
Future<void> _settleIo(
  WidgetTester tester,
  bool Function() done, {
  int rounds = 200,
}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
    if (done()) return;
  }
}

/// 直接点击：视口由 [_pumpPage] 放大到能容纳整页，因此不需要 `ensureVisible`
/// （它会把目标滚到视口顶部，随后一帧的命中位置与渲染位置不一致，tap 会打空）。
Future<void> _tap(WidgetTester tester, String key) async {
  final finder = _key(key);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _pumpPage(
  WidgetTester tester,
  AppState state, {
  Size size = const Size(1000, 1600),
  ThemeData? theme,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // 每个用例的 AppState 都必须释放：否则它名下的定时器、日志与 sidecar
  // 回收会在 tearDown 删临时目录时还持有句柄（Windows 报 OS Error 32）。
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: LocalSourcesPage(state: state),
    ),
  );
  // 必须等首帧路由转场结束：转场期间 Navigator 会吸收指针，此时 tap 会静默打空。
  await tester.pumpAndSettle();
}

Future<void> _scan(
  WidgetTester tester,
  String folder, {
  required String expectKey,
  bool Function()? ready,
}) async {
  await tester.enterText(_key('local-sources-folder'), folder);
  await _tap(tester, 'local-sources-scan');
  await _settleIo(
    tester,
    () =>
        tester.widget<FilledButton>(_key('local-sources-scan')).onPressed !=
            null &&
        (ready?.call() ?? _key('candidate-$expectKey').evaluate().isNotEmpty),
  );
}

List<String?> _messageTexts(WidgetTester tester) => tester
    .widgetList<Text>(_key('local-sources-message'))
    .map((text) => text.data)
    .toList();

bool _messageContains(WidgetTester tester, String needle) =>
    _messageTexts(tester).any((data) => data != null && data.contains(needle));

String _selectionCount(WidgetTester tester) =>
    tester.widget<Text>(_key('local-sources-selection-count')).data!;

List<CheckboxListTile> _candidateTiles(WidgetTester tester) => tester
    .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
    .where(
      (tile) =>
          (tile.key as ValueKey<String>?)?.value.startsWith('candidate-') ??
          false,
    )
    .toList();

List<String> _candidateOrder(WidgetTester tester) =>
    _candidateTiles(tester)
        .map((tile) => (tile.key as ValueKey<String>).value)
        .toList();

class _ThrowingWebHomeState extends AppState {
  _ThrowingWebHomeState({required super.paths, required super.log});

  @override
  Future<bool> setWebHomeEnabled(String key, bool enabled) async {
    throw FileSystemException('测试保存失败');
  }

  @override
  Future<bool> removeWebHome(String key) async {
    throw FileSystemException('测试删除失败');
  }
}

class _ThrowingLocalRemovalState extends AppState {
  _ThrowingLocalRemovalState({required super.paths, required super.log});

  @override
  Future<bool> removeLocalSpider(String key) async {
    throw StateError('测试本地源删除异常');
  }
}

void main() {
  late Directory temp;
  late AppPaths paths;
  late AppState state;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('webhtv_local_page_');
    // 日志也必须落在 temp 内：`LogService` 未显式 open 时不得摸默认目录。
    LogService.logDirectoryOverride = p.join(temp.path, 'logs');
    paths = _tempPaths(temp);
    paths.ensureDirectories();
    state = AppState(paths: paths, log: LogService());
  });

  tearDown(() async {
    LogService.logDirectoryOverride = null;
    await deleteTempWhenReleased(temp);
  });

  Directory makeRoot(String name, {bool withCandidate = true}) {
    final root = Directory(p.join(temp.path, name));
    root.createSync(recursive: true);
    if (!withCandidate) return root;
    File(
      p.join(root.path, 'a.py'),
    ).writeAsStringSync('class Spider:\n    def home(self):\n        pass\n');
    File(p.join(root.path, 'b.js')).writeAsStringSync('function init(){}\n');
    final site = Directory(p.join(root.path, 'c'))..createSync(recursive: true);
    File(p.join(site.path, 'index.html'))
        .writeAsStringSync('<!doctype html><html><body>hi</body></html>');
    return root;
  }

  testWidgets('全选与取消全选只作用于当前扫描报告', (tester) async {
    final root = makeRoot('src');
    await _pumpPage(tester, state);
    await _scan(tester, root.path, expectKey: 'a');

    expect(_candidateTiles(tester).length, 3);
    expect(_selectionCount(tester), '已选 0 / 3');

    await _tap(tester, 'local-sources-select-all');
    expect(_selectionCount(tester), '已选 3 / 3');
    expect(
      _candidateTiles(tester).map((tile) => tile.value),
      everyElement(isTrue),
    );
    expect(find.text('导入所选（3）'), findsOneWidget);

    await _tap(tester, 'local-sources-select-all');
    expect(_selectionCount(tester), '已选 0 / 3');
    expect(
      _candidateTiles(tester).map((tile) => tile.value),
      everyElement(isFalse),
    );
    expect(find.text('导入所选（3）'), findsNothing);
  });

  testWidgets('部分选择显示计数，导入只导入勾选的候选', (tester) async {
    final root = makeRoot('partial');
    await _pumpPage(tester, state);
    await _scan(tester, root.path, expectKey: 'a');

    await _tap(tester, 'candidate-a');
    expect(_selectionCount(tester), '已选 1 / 3');
    expect(find.text('导入所选（1）'), findsOneWidget);

    // 部分选择态下点全选行＝一次清空全部，再勾回一条继续验证导入。
    await _tap(tester, 'local-sources-select-all');
    expect(_selectionCount(tester), '已选 0 / 3');
    await _tap(tester, 'candidate-a');
    expect(_selectionCount(tester), '已选 1 / 3');

    await _tap(tester, 'local-sources-import');
    await _settleIo(
      tester,
      () => _key('local-sources-result').evaluate().isNotEmpty,
    );

    expect(state.localSpiders.map((item) => item.key), <String>['a']);
    expect(state.webHomeSources, isEmpty);
    expect(
      tester.widget<Text>(_key('local-sources-result')).data,
      '导入结果：成功 1，失败 0',
    );
    expect(_selectionCount(tester), '已选 1 / 3');
    expect(tester.widget<CheckboxListTile>(_key('candidate-a')).value, isTrue);
    expect(_key('local-sources-import'), findsNothing);
  });

  testWidgets('重扫清理上一轮的勾选', (tester) async {
    final first = makeRoot('first');
    final second = makeRoot('second');
    File(p.join(second.path, 'a.py')).deleteSync();

    await _pumpPage(tester, state);
    await _scan(tester, first.path, expectKey: 'a');
    await _tap(tester, 'local-sources-select-all');
    expect(_selectionCount(tester), '已选 3 / 3');

    await _scan(
      tester,
      second.path,
      expectKey: 'b',
      // 上一轮的候选行同样叫 candidate-b，必须等候选数变成第二轮的 2 才算重扫完成。
      ready: () => _candidateTiles(tester).length == 2,
    );

    expect(_candidateTiles(tester).length, 2);
    expect(_selectionCount(tester), '已选 0 / 2');
    expect(find.text('导入所选（3）'), findsNothing);
  });

  testWidgets('重扫自动勾选已导入的 Python、JavaScript 和 HTML 源', (tester) async {
    final root = makeRoot('rescan');
    await tester.runAsync(() async {
      final report = await state.scanLocalSources(root.path);
      final result = await state.importLocalSources(report.candidates);
      expect(result.importedCount, 3);
      expect(result.rejectedCount, 0);
    });
    File(p.join(root.path, 'd.py')).writeAsStringSync('class Spider: pass');
    await _pumpPage(tester, state);
    await _scan(tester, root.path, expectKey: 'a');

    for (final key in ['a', 'b', 'c']) {
      expect(
        tester.widget<CheckboxListTile>(_key('candidate-$key')).value,
        isTrue,
        reason: key,
      );
      expect(_key('candidate-imported-$key'), findsOneWidget);
    }
    expect(tester.widget<CheckboxListTile>(_key('candidate-d')).value, isFalse);
    expect(_selectionCount(tester), '已选 3 / 4');
    expect(_key('local-sources-import'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('导入跳过已导入的勾选项，保留原文件与停用状态', (tester) async {
    final root = makeRoot('skipimported');
    await tester.runAsync(() async {
      final report = await state.scanLocalSources(root.path);
      final result = await state.importLocalSources(
        report.candidates.where((item) => item.key == 'a').toList(),
      );
      expect(result.importedCount, 1);
      await state.setLocalSourceEnabled('a', false);
    });
    final installed = File(p.join(state.spiderRoot, 'local', 'a', 'spider.py'));
    final before = installed.readAsBytesSync();
    await _pumpPage(tester, state);
    await _scan(tester, root.path, expectKey: 'a');
    expect(tester.widget<CheckboxListTile>(_key('candidate-a')).value, isTrue);
    await _tap(tester, 'candidate-b');
    expect(find.text('导入所选（1）'), findsOneWidget);
    await _tap(tester, 'local-sources-import');
    await _settleIo(
      tester,
      () => _key('local-sources-result').evaluate().isNotEmpty,
    );
    expect(
      tester.widget<Text>(_key('local-sources-result')).data,
      '导入结果：成功 1，失败 0',
    );
    expect(state.localSpiders.map((item) => item.key), ['a', 'b']);
    expect(installed.readAsBytesSync(), before);
    expect(state.localSourceEnabled('a'), isFalse);
    expect(state.webHomeSources, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已导入和未导入筛选保留勾选，全选只改变当前可见结果', (tester) async {
    final root = makeRoot('filter');
    final changedTime = DateTime(2024, 1, 1);
    for (final file in root.listSync(recursive: true).whereType<File>()) {
      file.setLastModifiedSync(changedTime);
    }
    await tester.runAsync(() async {
      final report = await state.scanLocalSources(root.path);
      await state.importLocalSources(
        report.candidates.where((item) => item.key == 'a').toList(),
      );
    });
    await _pumpPage(tester, state);
    await _scan(tester, root.path, expectKey: 'a');
    expect(find.text('全部 3'), findsOneWidget);
    expect(find.text('未导入 2'), findsOneWidget);
    expect(find.text('已导入 1'), findsOneWidget);
    await _tap(tester, 'local-sources-filter-unimported');
    expect(_candidateOrder(tester), ['candidate-b', 'candidate-c']);
    await _tap(tester, 'local-sources-select-all');
    expect(_selectionCount(tester), '已选 3 / 3 · 当前显示 2');
    await _tap(tester, 'local-sources-select-all');
    expect(_selectionCount(tester), '已选 1 / 3 · 当前显示 2');
    await _tap(tester, 'local-sources-filter-imported');
    expect(_candidateOrder(tester), ['candidate-a']);
    expect(tester.widget<CheckboxListTile>(_key('candidate-a')).value, isTrue);
    await _tap(tester, 'local-sources-filter-all');
    expect(_candidateTiles(tester).length, 3);
    expect(tester.widget<CheckboxListTile>(_key('candidate-b')).value, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('模糊搜索匹配名称 key 和路径，可清空搜索且无匹配时有提示', (tester) async {
    final root = makeRoot('search');
    File(p.join(root.path, 'csp_demo.py'))
        .writeAsStringSync('class Spider: pass');
    await _pumpPage(tester, state);
    await _scan(tester, root.path, expectKey: 'a');
    await _tap(tester, 'candidate-b');
    await tester.enterText(_key('local-sources-query'), 'CSPDEMO');
    await tester.pump();
    expect(_candidateOrder(tester), ['candidate-csp_demo']);
    await tester.enterText(_key('local-sources-query'), 'search js');
    await tester.pump();
    expect(_candidateOrder(tester), ['candidate-b']);
    expect(tester.widget<CheckboxListTile>(_key('candidate-b')).value, isTrue);
    expect(_selectionCount(tester), '已选 1 / 4 · 当前显示 1');
    await tester.enterText(_key('local-sources-query'), 'not-found');
    await tester.pump();
    expect(_candidateTiles(tester), isEmpty);
    expect(_key('local-sources-filter-empty'), findsOneWidget);
    await tester.tap(_key('local-sources-query-clear'));
    await tester.pumpAndSettle();
    expect(_candidateTiles(tester).length, 4);
    expect(tester.widget<CheckboxListTile>(_key('candidate-b')).value, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('重新载入后已导入项不重复计数或作为新增导入', (tester) async {
    final root = makeRoot('reload-imported');
    await _pumpPage(tester, state);
    await _scan(tester, root.path, expectKey: 'a');
    await _tap(tester, 'candidate-a');
    await tester.runAsync(() async {
      final report = await state.scanLocalSources(root.path);
      await state.importLocalSources(
        report.candidates.where((item) => item.key == 'a').toList(),
      );
    });
    await _tap(tester, 'local-sources-rescan');
    await _settleIo(
      tester,
      () =>
          tester.widget<FilledButton>(_key('local-sources-scan')).onPressed !=
          null,
    );
    expect(_selectionCount(tester), '已选 1 / 3');
    expect(_key('local-sources-import'), findsNothing);
    expect(
      tester.widget<CheckboxListTile>(_key('candidate-a')).onChanged,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('扫描后登记表损坏，导入失败可见且不写入源目录', (tester) async {
    final root = makeRoot('corrupt-import');
    await _pumpPage(tester, state);
    await _scan(tester, root.path, expectKey: 'a');
    await _tap(tester, 'candidate-a');
    final store = WebHomeStore(root: p.join(paths.configDir, 'webhome'));
    File(store.registryPath).parent.createSync(recursive: true);
    File(store.registryPath).writeAsStringSync('{broken');
    await _tap(tester, 'local-sources-import');
    await _settleIo(tester, () => _messageContains(tester, '导入失败'));
    expect(_messageContains(tester, '导入失败'), isTrue);
    expect(
      Directory(p.join(state.spiderRoot, 'local', 'a')).existsSync(),
      isFalse,
    );
    expect(
      tester.widget<FilledButton>(_key('local-sources-scan')).onPressed,
      isNotNull,
    );
    expect(_key('local-sources-import-state-error'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('已导入候选信息保持可读对比度：$brightness', (tester) async {
      final root = makeRoot('readable-imported');
      File(p.join(root.path, 'a.py'))
          .writeAsStringSync('print("fixture only")');
      await tester.runAsync(() async {
        final report = await state.scanLocalSources(root.path);
        await state.importLocalSources(
          report.candidates.where((item) => item.key == 'a').toList(),
        );
      });
      await _pumpPage(tester, state, theme: buildAppTheme(brightness));
      await _scan(tester, root.path, expectKey: 'a');
      for (final text in [
        find.text('a（a）'),
        find.textContaining('Python 爬虫 ·'),
        find.textContaining('未发现 Spider/create_spider'),
      ]) {
        final finder = find.descendant(of: _key('candidate-a'), matching: text);
        final paragraph = tester.renderObject<RenderParagraph>(finder);
        final background = Theme.of(tester.element(finder))
            .scaffoldBackgroundColor;
        final color = Color.alphaBlend(
          paragraph.text.style!.color!,
          background,
        );
        final foregroundLuminance = color.computeLuminance();
        final backgroundLuminance = background.computeLuminance();
        final bright = foregroundLuminance > backgroundLuminance
            ? foregroundLuminance
            : backgroundLuminance;
        final dark = foregroundLuminance < backgroundLuminance
            ? foregroundLuminance
            : backgroundLuminance;
        expect(
          (bright + 0.05) / (dark + 0.05),
          greaterThanOrEqualTo(4.5),
          reason: '已导入候选的文字信息不应因禁用勾选而变得难读',
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('候选行显示本地格式修改时间，默认最新优先且可切换、同时间稳定', (tester) async {
    final root = Directory(p.join(temp.path, 'times'))
      ..createSync(recursive: true);
    final older = DateTime(2024, 5, 6, 7, 8);
    final newest = DateTime(2025, 1, 2, 3, 4);
    for (final entry in <String, DateTime>{
      'zeta.py': newest,
      'alpha.py': older,
      'beta.py': older,
    }.entries) {
      final file = File(p.join(root.path, entry.key))
        ..writeAsStringSync('class Spider:\n    pass\n');
      file.setLastModifiedSync(entry.value);
    }

    await _pumpPage(tester, state);
    await _scan(tester, root.path, expectKey: 'zeta');

    expect(_candidateOrder(tester), <String>[
      'candidate-zeta',
      'candidate-alpha',
      'candidate-beta',
    ]);
    expect(
      tester.widget<Text>(_key('candidate-modified-zeta')).data,
      '最后修改：2025-01-02 03:04',
    );
    expect(
      tester.widget<Text>(_key('candidate-modified-alpha')).data,
      '最后修改：2024-05-06 07:08',
    );

    await _tap(tester, 'local-sources-sort-toggle');
    expect(_candidateOrder(tester), <String>[
      'candidate-alpha',
      'candidate-beta',
      'candidate-zeta',
    ]);
  });

  testWidgets('已导入源区分在线 URL、原文件时间与未知，不用导入时间冒充', (tester) async {
    final store = WebHomeStore(root: p.join(paths.configDir, 'webhome'));
    store.save(<WebHomeSource>[
      const WebHomeSource(
        key: 'remoteone',
        name: '在线站',
        entry: 'index.html',
        importedAt: '2026-01-01T00:00:00.000Z',
        entrySha256: '',
        remoteUrl: 'https://example.com/page',
      ),
      const WebHomeSource(
        key: 'localold',
        name: '旧本地站',
        entry: 'index.html',
        importedAt: '2026-02-02T00:00:00.000Z',
        entrySha256: 'x',
      ),
      const WebHomeSource(
        key: 'localknown',
        name: '有时间站',
        entry: 'index.html',
        importedAt: '2026-03-03T00:00:00.000Z',
        entrySha256: 'y',
        modifiedAt: '2024-05-06T07:08:00',
      ),
    ]);

    await _pumpPage(tester, state);
    await tester.pump();

    expect(
      tester.widget<Text>(_key('webhome-origin-remoteone')).data,
      'https://example.com/page',
    );
    expect(tester.widget<Text>(_key('webhome-time-remoteone')).data, '更新时间：未知');
    expect(
      tester.widget<Text>(_key('webhome-time-localold')).data,
      '原文件修改时间：未知',
    );
    expect(
      tester.widget<Text>(_key('webhome-time-localknown')).data,
      '原文件修改时间：2024-05-06 07:08',
    );
    expect(find.textContaining('2026-01-01'), findsNothing);
    expect(find.textContaining('2026-02-02'), findsNothing);
    expect(find.textContaining('2026-03-03'), findsNothing);
  });

  testWidgets('空扫描结果与空候选不报错', (tester) async {
    final root = Directory(p.join(temp.path, 'empty'))
      ..createSync(recursive: true);
    await _pumpPage(tester, state);
    await tester.enterText(_key('local-sources-folder'), root.path);
    await _tap(tester, 'local-sources-scan');
    await _settleIo(tester, () => _messageContains(tester, '没有找到可导入的源'));

    expect(
      tester.widget<Text>(_key('local-sources-message')).data,
      '没有找到可导入的源（支持 .py / .js / .html）',
    );
    expect(_candidateTiles(tester), isEmpty);
    expect(_key('local-sources-select-all'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('忙碌时禁用全选、逐条勾选与再次添加', (tester) async {
    final root = makeRoot('busy');
    await _pumpPage(tester, state);
    await _scan(tester, root.path, expectKey: 'a');

    // 重扫期间的 busy 帧：旧候选仍在屏幕上，但所有勾选与添加必须禁用。
    await tester.enterText(_key('local-sources-folder'), root.path);
    await tester.tap(_key('local-sources-scan'));
    await tester.pump();

    expect(
      tester
          .widget<CheckboxListTile>(_key('local-sources-select-all'))
          .onChanged,
      isNull,
    );
    expect(
      _candidateTiles(tester).map((tile) => tile.onChanged),
      everyElement(isNull),
    );
    expect(
      tester.widget<FilledButton>(_key('online-html-add')).onPressed,
      isNull,
    );

    await _settleIo(
      tester,
      () =>
          tester
              .widget<CheckboxListTile>(_key('local-sources-select-all'))
              .onChanged !=
          null,
    );
    expect(
      tester
          .widget<CheckboxListTile>(_key('local-sources-select-all'))
          .onChanged,
      isNotNull,
    );
    expect(
      tester.widget<FilledButton>(_key('online-html-add')).onPressed,
      isNotNull,
    );
  });

  testWidgets('在线 HTML：无效网址给出字段错误且不登记', (tester) async {
    await _pumpPage(tester, state);

    await tester.enterText(_key('online-html-url'), 'not a url');
    await _tap(tester, 'online-html-add');
    expect(find.text('请输入以 http:// 或 https:// 开头的有效网址'), findsOneWidget);
    expect(state.webHomeSources, isEmpty);

    await tester.enterText(_key('online-html-url'), 'ftp://example.com/x');
    await _tap(tester, 'online-html-add');
    expect(find.text('请输入以 http:// 或 https:// 开头的有效网址'), findsOneWidget);
    expect(state.webHomeSources, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('在线 HTML：有效网址与可选名称登记后可打开', (tester) async {
    await _pumpPage(tester, state);

    await tester.enterText(_key('online-html-url'), 'https://example.com/live');
    await tester.enterText(_key('online-html-name'), '示例台');
    await _tap(tester, 'online-html-add');
    await _settleIo(
      tester,
      () => state.webHomeSources.any((item) => item.isRemote),
    );

    final source = state.webHomeSources.single;
    expect(source.remoteUrl, 'https://example.com/live');
    expect(source.name, '示例台');
    expect(
      tester.widget<Text>(_key('webhome-time-${source.key}')).data,
      '更新时间：未知',
    );
    expect(
      tester.widget<Text>(_key('webhome-origin-${source.key}')).data,
      'https://example.com/live',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('在线 HTML：重复网址给出具体错误并还原忙碌状态', (tester) async {
    final store = WebHomeStore(root: p.join(paths.configDir, 'webhome'));
    store.save(<WebHomeSource>[
      const WebHomeSource(
        key: 'existing',
        name: '既有站',
        entry: 'index.html',
        importedAt: '2026-01-01T00:00:00.000Z',
        entrySha256: '',
        remoteUrl: 'https://example.com/page',
      ),
    ]);

    await _pumpPage(tester, state);
    await tester.enterText(_key('online-html-url'), 'https://example.com/page');
    await _tap(tester, 'online-html-add');
    await _settleIo(tester, () => _messageContains(tester, '添加失败'));

    final message = _messageTexts(tester)
        .firstWhere((data) => data != null && data.isNotEmpty)!;
    expect(message, matches(RegExp('已存在|已登记')));
    expect(state.webHomeSources.length, 1);
    expect(
      tester.widget<FilledButton>(_key('online-html-add')).onPressed,
      isNotNull,
    );
  });

  for (final throwsError in <bool>[false, true]) {
    for (final remove in <bool>[false, true]) {
      final operation = remove ? '删除' : '启停';
      final failure = throwsError ? 'throw' : 'false';
      testWidgets('$operation 返回 $failure 时可见失败且应用仍可操作', (tester) async {
        final store = WebHomeStore(root: p.join(paths.configDir, 'webhome'));
        store.save(<WebHomeSource>[
          const WebHomeSource(
            key: 'operation',
            name: '操作测试站',
            entry: 'index.html',
            importedAt: '2026-01-01T00:00:00.000Z',
            entrySha256: '',
            remoteUrl: 'https://example.com/operation',
          ),
        ]);
        // false 用真实登记被外部移除的场景；throw 只注入磁盘操作失败，页面与读取仍真实。
        final pageState = throwsError
            ? _ThrowingWebHomeState(paths: paths, log: LogService())
            : state;
        await _pumpPage(tester, pageState);
        if (!throwsError) store.save(<WebHomeSource>[]);

        if (remove) {
          await _tap(tester, 'webhome-remove-operation');
          await tester.pumpAndSettle();
          await tester.tap(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.widgetWithText(FilledButton, '删除'),
            ),
          );
          await tester.pumpAndSettle();
        } else {
          await _tap(tester, 'webhome-toggle-operation');
          await tester.pumpAndSettle();
        }

        expect(_messageContains(tester, '失败'), isTrue);
        if (throwsError) {
          expect(
            _messageContains(tester, remove ? '测试删除失败' : '测试保存失败'),
            isTrue,
          );
          expect(pageState.webHomeSources.single.enabled, isTrue);
          expect(_key('webhome-row-operation'), findsOneWidget);
        }
        expect(
          tester.widget<FilledButton>(_key('online-html-add')).onPressed,
          isNotNull,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final remove in <bool>[false, true]) {
    testWidgets('真实登记损坏后${remove ? '删除' : '启停'}失败可见且不导致页面崩溃', (tester) async {
      final source = await state.addOnlineWebHome(
        'https://example.com/corrupt',
      );
      final store = WebHomeStore(root: p.join(paths.configDir, 'webhome'));
      await _pumpPage(tester, state);
      // 在现有页面载入后破坏 temp 登记，覆盖操作抛错后再次 build 的真实读取路径。
      File(store.registryPath).writeAsStringSync('{"items":false}');
      if (remove) {
        await _tap(tester, 'webhome-remove-${source.key}');
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.widgetWithText(FilledButton, '删除'),
          ),
        );
      } else {
        await _tap(tester, 'webhome-toggle-${source.key}');
      }
      await tester.pumpAndSettle();
      expect(_messageContains(tester, '失败'), isTrue);
      expect(find.textContaining('登记表 items 必须是记录列表'), findsWidgets);
      expect(find.text('还没有本地源'), findsNothing);
      expect(
        tester.widget<FilledButton>(_key('online-html-add')).onPressed,
        isNotNull,
      );
      expect(File(store.registryPath).readAsStringSync(), '{"items":false}');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('损坏登记首次进入页面如实报错且仍可操作', (tester) async {
    final store = WebHomeStore(root: p.join(paths.configDir, 'webhome'));
    Directory(store.root).createSync(recursive: true);
    File(store.registryPath).writeAsStringSync('{"items":false}');
    await _pumpPage(tester, state);
    expect(find.textContaining('载入 HTML 源失败'), findsOneWidget);
    expect(find.textContaining('登记表 items 必须是记录列表'), findsOneWidget);
    expect(find.text('还没有本地源'), findsNothing);
    expect(
      tester.widget<FilledButton>(_key('online-html-add')).onPressed,
      isNotNull,
    );
    expect(File(store.registryPath).readAsStringSync(), '{"items":false}');
    expect(tester.takeException(), isNull);
  });

  testWidgets('在线源删除只移除登记，取消不删除，确认后刷新列表', (tester) async {
    final source = await state.addOnlineWebHome('https://example.com/remove');
    await _pumpPage(tester, state);
    await _tap(tester, 'webhome-remove-${source.key}');
    await tester.pumpAndSettle();
    expect(find.textContaining('只移除网址登记'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(state.webHomeSources, hasLength(1));

    await _tap(tester, 'webhome-remove-${source.key}');
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '删除'),
      ),
    );
    await tester.pumpAndSettle();
    expect(state.webHomeSources, isEmpty);
    expect(_key('webhome-row-${source.key}'), findsNothing);
    expect(
      tester.widget<FilledButton>(_key('online-html-add')).onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('启停成功保存并刷新开关，忙碌状态还原', (tester) async {
    final source = await state.addOnlineWebHome('https://example.com/toggle');
    await _pumpPage(tester, state);
    await _tap(tester, 'webhome-toggle-${source.key}');
    await tester.pumpAndSettle();
    expect(state.webHomeSources.single.enabled, isFalse);
    expect(
      tester.widget<Switch>(_key('webhome-toggle-${source.key}')).value,
      isFalse,
    );
    expect(
      tester.widget<TextButton>(_key('webhome-open-${source.key}')).onPressed,
      isNull,
    );
    expect(
      tester.widget<FilledButton>(_key('online-html-add')).onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  Future<void> importLocal(
    WidgetTester tester,
    String folder,
    String key,
  ) async {
    await _scan(tester, folder, expectKey: key);
    await _tap(tester, 'candidate-$key');
    await _tap(tester, 'local-sources-import');
    await _settleIo(
      tester,
      () => _key('localspider-row-$key').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Python/JS 行提供删除入口，仅说明删除本地源目录且取消不删', (tester) async {
    final root = makeRoot('localsafe');
    await _pumpPage(tester, state);
    await importLocal(tester, root.path, 'a');

    expect(_key('local-remove-a'), findsOneWidget);
    await _tap(tester, 'local-remove-a');
    await tester.pumpAndSettle();

    expect(find.textContaining('删除本地源目录'), findsOneWidget);
    expect(find.textContaining('撤销'), findsNothing);
    expect(find.textContaining('站点配置'), findsNothing);

    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(_key('localspider-row-a'), findsOneWidget);
    expect(state.localSpiders.map((item) => item.key), contains('a'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除本地源成功：确认后来源消失、目录清除且忙碌还原', (tester) async {
    final root = makeRoot('localdel');
    await _pumpPage(tester, state);
    await importLocal(tester, root.path, 'a');
    final spiderDir = Directory(p.join(state.spiderRoot, 'local', 'a'));
    expect(spiderDir.existsSync(), isTrue);

    await _tap(tester, 'local-remove-a');
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '删除'),
      ),
    );
    await tester.pump();
    expect(
      tester.widget<FilledButton>(_key('local-sources-scan')).onPressed,
      isNull,
    );
    await _settleIo(
      tester,
      () =>
          _key('localspider-row-a').evaluate().isEmpty &&
          tester.widget<FilledButton>(_key('local-sources-scan')).onPressed !=
              null,
    );

    expect(state.localSpiders.map((item) => item.key), isNot(contains('a')));
    expect(spiderDir.existsSync(), isFalse);
    expect(
      tester.widget<FilledButton>(_key('local-sources-scan')).onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除本地源失败时可见提示且不中断应用', (tester) async {
    final root = makeRoot('localfail');
    await _pumpPage(tester, state);
    await importLocal(tester, root.path, 'a');
    // 页面载入后从磁盘移除该源目录：删除请求会落到真实的安全拒绝分支。
    Directory(p.join(state.spiderRoot, 'local', 'a'))
        .deleteSync(recursive: true);

    await _tap(tester, 'local-remove-a');
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '删除'),
      ),
    );
    await _settleIo(tester, () => _messageContains(tester, '失败'));

    expect(_messageContains(tester, '失败'), isTrue);
    expect(
      tester.widget<FilledButton>(_key('local-sources-scan')).onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除 JavaScript 本地源成功且不影响相邻 Python 原文件', (tester) async {
    final root = makeRoot('localjs');
    await _pumpPage(tester, state);
    await importLocal(tester, root.path, 'b');
    final spiderDir = Directory(p.join(state.spiderRoot, 'local', 'b'));
    expect(spiderDir.existsSync(), isTrue);
    await _tap(tester, 'local-remove-b');
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '删除'),
      ),
    );
    await _settleIo(
      tester,
      () =>
          _key('localspider-row-b').evaluate().isEmpty &&
          tester.widget<FilledButton>(_key('local-sources-scan')).onPressed !=
              null,
    );
    expect(state.localSpiders.map((item) => item.key), isNot(contains('b')));
    expect(spiderDir.existsSync(), isFalse);
    expect(File(p.join(root.path, 'a.py')).existsSync(), isTrue);
    expect(File(p.join(root.path, 'b.js')).existsSync(), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除本地源异常反馈原因并保留源，finally还原可操作状态', (tester) async {
    final root = makeRoot('localthrow');
    final pageState = _ThrowingLocalRemovalState(
      paths: paths,
      log: LogService(),
    );
    await _pumpPage(tester, pageState);
    await importLocal(tester, root.path, 'a');
    await _tap(tester, 'local-remove-a');
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '删除'),
      ),
    );
    await tester.pumpAndSettle();
    expect(_messageContains(tester, '删除本地源失败'), isTrue);
    expect(_messageContains(tester, '测试本地源删除异常'), isTrue);
    expect(pageState.localSpiders.map((item) => item.key), contains('a'));
    expect(
      Directory(p.join(pageState.spiderRoot, 'local', 'a')).existsSync(),
      isTrue,
    );
    expect(
      tester.widget<IconButton>(_key('local-remove-a')).onPressed,
      isNotNull,
    );
    expect(
      tester.widget<FilledButton>(_key('online-html-add')).onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('忙碌时禁用本地源删除按钮', (tester) async {
    final root = makeRoot('localbusy');
    await _pumpPage(tester, state);
    await importLocal(tester, root.path, 'a');

    await tester.enterText(_key('local-sources-folder'), root.path);
    await tester.tap(_key('local-sources-scan'));
    await tester.pump();
    expect(tester.widget<IconButton>(_key('local-remove-a')).onPressed, isNull);

    await _settleIo(
      tester,
      () => tester.widget<IconButton>(_key('local-remove-a')).onPressed != null,
    );
    expect(
      tester.widget<IconButton>(_key('local-remove-a')).onPressed,
      isNotNull,
    );
  });

  // ---------------------------------------------------------------------
  // 四类源启停 + 已导入区批量管理（多选 / 批量启用 / 批量停用 / 批量删除）
  // ---------------------------------------------------------------------

  String batchCount(WidgetTester tester) =>
      tester.widget<Text>(_key('local-sources-batch-count')).data!;

  bool batchActionEnabled(WidgetTester tester, String key) {
    final widget = tester.widget(_key(key));
    if (widget is FilledButton) return widget.onPressed != null;
    if (widget is OutlinedButton) return widget.onPressed != null;
    if (widget is TextButton) return widget.onPressed != null;
    if (widget is IconButton) return widget.onPressed != null;
    throw StateError('批量按钮类型未知：${widget.runtimeType}');
  }

  List<Switch> spiderToggles(WidgetTester tester) =>
      tester.widgetList<Switch>(find.byType(Switch)).where((widget) {
        final key = (widget.key as ValueKey<String>?)?.value ?? '';
        return key.startsWith('local-toggle-');
      }).toList();

  testWidgets('Python/JS 行提供开关，状态取自 localSourceEnabled 且可双向切换', (tester) async {
    final root = makeRoot('localtoggle');
    await _pumpPage(tester, state);
    await importLocal(tester, root.path, 'a');

    expect(_key('local-toggle-a'), findsOneWidget);
    expect(state.localSourceEnabled('a'), isTrue);
    expect(tester.widget<Switch>(_key('local-toggle-a')).value, isTrue);
    expect(spiderToggles(tester).length, 1);

    await _tap(tester, 'local-toggle-a');
    await _settleIo(
      tester,
      () =>
          state.localSourceEnabled('a') == false &&
          tester.widget<Switch>(_key('local-toggle-a')).value == false,
    );
    expect(state.localSourceEnabled('a'), isFalse);
    expect(tester.widget<Switch>(_key('local-toggle-a')).value, isFalse);
    expect(tester.widget<Switch>(_key('local-toggle-a')).onChanged, isNotNull);
    expect(
      tester.widget<FilledButton>(_key('local-sources-scan')).onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);

    await _tap(tester, 'local-toggle-a');
    await _settleIo(
      tester,
      () =>
          state.localSourceEnabled('a') == true &&
          tester.widget<Switch>(_key('local-toggle-a')).value == true,
    );
    expect(state.localSourceEnabled('a'), isTrue);
    expect(tester.widget<Switch>(_key('local-toggle-a')).value, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('HTML 行开关沿用 webhome-toggle，且与 localSourceEnabled 同口径', (
    tester,
  ) async {
    final online = await state.addOnlineWebHome('https://example.com/unified');
    final toggle = 'webhome-toggle-${online.key}';
    await _pumpPage(tester, state);

    expect(_key(toggle), findsOneWidget);
    expect(state.localSourceEnabled(online.key), isTrue);
    expect(tester.widget<Switch>(_key(toggle)).value, isTrue);

    await _tap(tester, toggle);
    await _settleIo(
      tester,
      () =>
          state.localSourceEnabled(online.key) == false &&
          tester.widget<Switch>(_key(toggle)).value == false,
    );
    expect(state.localSourceEnabled(online.key), isFalse);
    expect(tester.widget<Switch>(_key(toggle)).value, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('批量管理：多选态、全选与计数正确，退出清空选择集', (tester) async {
    final root = makeRoot('batchselect');
    await _pumpPage(tester, state);
    await importLocal(tester, root.path, 'a');
    final online = await state.addOnlineWebHome('https://example.com/batch');
    final onlineCheck = 'local-batch-check-${online.key}';

    expect(_key('local-batch-check-a'), findsNothing);
    await _tap(tester, 'local-sources-batch');
    await tester.pumpAndSettle();

    expect(_key('local-batch-check-a'), findsOneWidget);
    expect(_key(onlineCheck), findsOneWidget);
    expect(batchCount(tester), '已选 0 / 2');

    // 未选中任何源时三个批量动作都 disabled。
    expect(batchActionEnabled(tester, 'local-sources-batch-enable'), isFalse);
    expect(batchActionEnabled(tester, 'local-sources-batch-disable'), isFalse);
    expect(batchActionEnabled(tester, 'local-sources-batch-delete'), isFalse);

    await _tap(tester, 'local-sources-batch-select-all');
    expect(batchCount(tester), '已选 2 / 2');
    expect(tester.widget<Checkbox>(_key('local-batch-check-a')).value, isTrue);
    expect(tester.widget<Checkbox>(_key(onlineCheck)).value, isTrue);
    expect(batchActionEnabled(tester, 'local-sources-batch-enable'), isTrue);

    await _tap(tester, 'local-sources-batch-select-all');
    expect(batchCount(tester), '已选 0 / 2');
    expect(tester.widget<Checkbox>(_key('local-batch-check-a')).value, isFalse);

    await _tap(tester, 'local-batch-check-a');
    expect(batchCount(tester), '已选 1 / 2');

    await _tap(tester, 'local-sources-batch-exit');
    await tester.pumpAndSettle();
    expect(_key('local-batch-check-a'), findsNothing);
    expect(_key('local-sources-batch-count'), findsNothing);
    expect(_key('local-sources-batch'), findsOneWidget);

    await _tap(tester, 'local-sources-batch');
    await tester.pumpAndSettle();
    expect(batchCount(tester), '已选 0 / 2');
    expect(tester.takeException(), isNull);
  });

  testWidgets('批量停用后两套源都停用、开关随之关闭，且仍停留在多选态', (tester) async {
    final root = makeRoot('batchdisable');
    await _pumpPage(tester, state);
    await importLocal(tester, root.path, 'a');
    final online = await state.addOnlineWebHome('https://example.com/off');
    final htmlToggle = 'webhome-toggle-${online.key}';

    await _tap(tester, 'local-sources-batch');
    await tester.pumpAndSettle();
    await _tap(tester, 'local-sources-batch-select-all');
    await _tap(tester, 'local-sources-batch-disable');
    await _settleIo(
      tester,
      () =>
          !state.localSourceEnabled('a') &&
          !state.localSourceEnabled(online.key) &&
          _messageContains(tester, '批量停用完成'),
    );

    expect(state.localSourceEnabled('a'), isFalse);
    expect(state.localSourceEnabled(online.key), isFalse);
    expect(tester.widget<Switch>(_key('local-toggle-a')).value, isFalse);
    expect(tester.widget<Switch>(_key(htmlToggle)).value, isFalse);
    expect(_messageContains(tester, '成功 2 / 2'), isTrue);
    expect(_messageContains(tester, '失败'), isFalse);

    // 不退出多选态，选择集保留。
    expect(batchCount(tester), '已选 2 / 2');
    expect(batchActionEnabled(tester, 'local-sources-batch-enable'), isTrue);
    expect(
      tester.widget<Checkbox>(_key('local-batch-check-a')).onChanged,
      isNotNull,
    );

    await _tap(tester, 'local-sources-batch-enable');
    await _settleIo(
      tester,
      () =>
          state.localSourceEnabled('a') &&
          state.localSourceEnabled(online.key) &&
          _messageContains(tester, '批量启用完成'),
    );
    expect(tester.widget<Switch>(_key('local-toggle-a')).value, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('批量删除：取消不删；确认后 py/js 与 HTML 各自走对应删除', (tester) async {
    final root = makeRoot('batchdelete');
    await _pumpPage(tester, state);
    await importLocal(tester, root.path, 'a');
    final online = await state.addOnlineWebHome('https://example.com/del');
    final spiderDir = Directory(p.join(state.spiderRoot, 'local', 'a'));

    await _tap(tester, 'local-sources-batch');
    await tester.pumpAndSettle();
    await _tap(tester, 'local-sources-batch-select-all');
    await _tap(tester, 'local-sources-batch-delete');
    await tester.pumpAndSettle();

    // 二次确认：取消不删除。
    expect(find.text('批量删除本地源'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(_key('localspider-row-a'), findsOneWidget);
    expect(_key('webhome-row-${online.key}'), findsOneWidget);
    expect(state.localSpiders.map((item) => item.key), contains('a'));
    expect(spiderDir.existsSync(), isTrue);
    expect(batchCount(tester), '已选 2 / 2');

    await _tap(tester, 'local-sources-batch-delete');
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '删除'),
      ),
    );
    await _settleIo(
      tester,
      () =>
          _key('localspider-row-a').evaluate().isEmpty &&
          _key('webhome-row-${online.key}').evaluate().isEmpty &&
          _messageContains(tester, '批量删除完成'),
    );

    expect(state.localSpiders.map((item) => item.key), isNot(contains('a')));
    expect(state.webHomeSources, isEmpty);
    expect(spiderDir.existsSync(), isFalse);
    expect(_messageContains(tester, '成功 2 / 2'), isTrue);
    // 已删除的 key 必须从选择集移除；源已全部删除，总数也随之归零。
    expect(batchCount(tester), '已选 0 / 0');
    expect(batchActionEnabled(tester, 'local-sources-batch-enable'), isFalse);
    expect(
      tester.widget<FilledButton>(_key('local-sources-scan')).onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('批量删除被拒时如实报出失败 key，不谎称成功', (tester) async {
    final root = makeRoot('batchreject');
    await _pumpPage(tester, state);
    await importLocal(tester, root.path, 'a');
    // 页面载入后从磁盘移走源目录：删除会落到真实的安全拒绝分支。
    Directory(p.join(state.spiderRoot, 'local', 'a'))
        .deleteSync(recursive: true);

    await _tap(tester, 'local-sources-batch');
    await tester.pumpAndSettle();
    await _tap(tester, 'local-batch-check-a');
    await _tap(tester, 'local-sources-batch-delete');
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '删除'),
      ),
    );
    await _settleIo(tester, () => _messageContains(tester, '批量删除完成'));

    expect(_messageContains(tester, '失败 1（a）'), isTrue);
    expect(_messageContains(tester, '成功 0 / 1'), isTrue);
    expect(
      tester.widget<FilledButton>(_key('local-sources-scan')).onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('批量动作在忙碌时全部 disabled，结束后还原', (tester) async {
    final root = makeRoot('batchbusy');
    await _pumpPage(tester, state);
    await importLocal(tester, root.path, 'a');

    await _tap(tester, 'local-sources-batch');
    await tester.pumpAndSettle();
    await _tap(tester, 'local-sources-batch-select-all');

    await tester.enterText(_key('local-sources-folder'), root.path);
    await tester.tap(_key('local-sources-scan'));
    await tester.pump();

    for (final key in <String>[
      'local-sources-batch-select-all',
      'local-sources-batch-enable',
      'local-sources-batch-disable',
      'local-sources-batch-delete',
      'local-sources-batch-exit',
    ]) {
      expect(batchActionEnabled(tester, key), isFalse, reason: '$key 应在忙碌时禁用');
    }
    expect(
      tester.widget<Checkbox>(_key('local-batch-check-a')).onChanged,
      isNull,
    );

    await _settleIo(
      tester,
      () => batchActionEnabled(tester, 'local-sources-batch-enable'),
    );
    expect(batchActionEnabled(tester, 'local-sources-batch-enable'), isTrue);
    expect(batchActionEnabled(tester, 'local-sources-batch-exit'), isTrue);
    expect(
      tester.widget<Checkbox>(_key('local-batch-check-a')).onChanged,
      isNotNull,
    );
  });

  testWidgets('窄窗批量态不溢出（480x640）', (tester) async {
    final root = makeRoot('narrowbatch');
    await _pumpPage(tester, state);
    await importLocal(tester, root.path, 'a');

    // 先在能容纳整页的视口完成导入，再缩到窄窗：窄窗里 ListView 只构建可见
    // 子项，已导入区必须先滚进来才能点；这里要验的是批量条本身的窄窗布局。
    tester.view.physicalSize = const Size(480, 640);
    await tester.pumpAndSettle();
    final pageScrollable = find.byWidgetPredicate(
      (widget) =>
          widget is Scrollable && widget.axisDirection == AxisDirection.down,
    );
    await tester.scrollUntilVisible(
      _key('local-sources-batch'),
      200,
      scrollable: pageScrollable,
    );
    await tester.pumpAndSettle();

    await _tap(tester, 'local-sources-batch');
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      _key('local-sources-batch-count'),
      200,
      scrollable: pageScrollable,
    );
    await _tap(tester, 'local-sources-batch-select-all');
    await tester.pumpAndSettle();

    expect(_key('local-sources-batch-count'), findsOneWidget);
    expect(batchCount(tester), '已选 1 / 1');
    expect(_key('local-batch-check-a'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('窄窗渲染不溢出', (tester) async {
    final root = makeRoot('narrow');
    await _pumpPage(tester, state, size: const Size(720, 520));
    expect(find.textContaining('本地文件导入仅支持 Windows'), findsOneWidget);
    await _scan(tester, root.path, expectKey: 'a');
    await tester.pumpAndSettle();

    // 窄窗下全选行、候选行、在线区域都真实渲染过；任何 overflow 都会被捕获。
    expect(_key('local-sources-select-all'), findsOneWidget);
    expect(_candidateTiles(tester), isNotEmpty);
    expect(tester.takeException(), isNull);
    final pageScrollable = find.byWidgetPredicate(
      (widget) =>
          widget is Scrollable && widget.axisDirection == AxisDirection.down,
    );
    expect(pageScrollable, findsOneWidget);
    await tester.scrollUntilVisible(
      _key('online-html-add'),
      200,
      scrollable: pageScrollable,
    );
    await tester.pumpAndSettle();
    expect(_key('online-html-url'), findsOneWidget);
    expect(_key('online-html-name'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
