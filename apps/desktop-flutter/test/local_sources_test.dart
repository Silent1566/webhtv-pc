/// 本地爬虫源：扫描 → 预览 → 导入 → 持久化。
///
/// 覆盖的关键行为：
/// - 扫描**只读**文件：不执行、不联网，超大文件与依赖目录计入 skipped；
/// - Python / JavaScript 源落 `spiders/local/<key>/` 并被 manifest 注册表识别；
/// - CatVod 壳的 `.py` 生成 `spider.py` 适配入口（与远端直连导入同一套模板）；
/// - HTML 源落 `webhome/<key>/` 并在登记表里可启停、可删除；
/// - 同名 key 一律拒绝，绝不静默覆盖既有源。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/local_source_import.dart';
import 'package:webhtv_pc/services/local_spider_scanner.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/spider_registry.dart';
import 'package:webhtv_pc/services/web_home_store.dart';
import 'package:webhtv_pc/state/app_state.dart';

AppPaths tempPaths(Directory temp) => AppPaths.resolve(
  overrides: {
    'config': '${temp.path}${Platform.pathSeparator}config',
    'data': '${temp.path}${Platform.pathSeparator}data',
    'cache': '${temp.path}${Platform.pathSeparator}cache',
    'state': '${temp.path}${Platform.pathSeparator}logs',
  },
);

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('webhtv_local_sources_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  group('扫描', () {
    test('识别 py/js/html，跳过依赖目录与超大文件', () async {
      final root = Directory('${temp.path}${Platform.pathSeparator}src');
      root.createSync(recursive: true);
      File('${root.path}${Platform.pathSeparator}a.py')
          .writeAsStringSync('class Spider:\n    def home(self):\n        pass\n');
      File('${root.path}${Platform.pathSeparator}b.js')
          .writeAsStringSync('function init(){}\n');
      final siteDir = Directory('${root.path}${Platform.pathSeparator}c');
      siteDir.createSync(recursive: true);
      File(
        '${siteDir.path}${Platform.pathSeparator}index.html',
      ).writeAsStringSync('<!doctype html><html><body>hi</body></html>');

      final dependency = Directory(
        '${root.path}${Platform.pathSeparator}node_modules',
      );
      dependency.createSync(recursive: true);
      File(
        '${dependency.path}${Platform.pathSeparator}x.py',
      ).writeAsStringSync('class Spider:\n    pass\n');

      File('${root.path}${Platform.pathSeparator}huge.py').writeAsBytesSync(
        List<int>.filled(3 * 1024 * 1024, 0x20),
      );

      final report = await const LocalSpiderScanner().scan(root.path);

      expect(report.candidates.length, 3);
      expect(report.truncated, isFalse);
      final byKey = {
        for (final candidate in report.candidates) candidate.key: candidate,
      };
      expect(byKey['a']!.kind, LocalSourceKind.python);
      expect(byKey['a']!.suggestedRuntime, 'python');
      expect(byKey['b']!.kind, LocalSourceKind.javaScript);
      expect(byKey['b']!.suggestedRuntime, 'node-tvbox');
      expect(byKey['c']!.kind, LocalSourceKind.webHome);
      expect(byKey['c']!.entryName, 'index.html');

      expect(report.skipped.any((item) => item.contains('node_modules')), isTrue);
      expect(report.skipped.any((item) => item.contains('huge.py')), isTrue);
    });

    test('哈希稳定，二次扫描结果一致', () async {
      final root = Directory('${temp.path}${Platform.pathSeparator}src2');
      root.createSync(recursive: true);
      File(
        '${root.path}${Platform.pathSeparator}a.py',
      ).writeAsStringSync('class Spider:\n    def home(self):\n        pass\n');

      final first = await const LocalSpiderScanner().scan(root.path);
      final second = await const LocalSpiderScanner().scan(root.path);
      expect(first.candidates.single.sha256, second.candidates.single.sha256);
    });

    test('文件夹不存在时如实返回跳过原因', () async {
      final report = await const LocalSpiderScanner().scan(
        '${temp.path}${Platform.pathSeparator}missing',
      );
      expect(report.candidates, isEmpty);
      expect(report.skipped.single, contains('文件夹不存在'));
    });
  });

  group('导入', () {
    late SpiderManifestRegistry registry;
    late WebHomeStore store;
    late LocalSourceImporter importer;

    setUp(() {
      final spiders = '${temp.path}${Platform.pathSeparator}spiders';
      registry = SpiderManifestRegistry(root: spiders, log: LogService());
      store = WebHomeStore(
        root: '${temp.path}${Platform.pathSeparator}webhome',
      );
      importer = LocalSourceImporter(
        spiderRoot: spiders,
        registry: registry,
        webHomeStore: store,
        log: LogService(),
      );
    });

    Future<LocalScanReport> scanFixture({String python = ''}) async {
      final root = Directory('${temp.path}${Platform.pathSeparator}src');
      root.createSync(recursive: true);
      File('${root.path}${Platform.pathSeparator}a.py').writeAsStringSync(
        python.isEmpty ? 'class Spider:\n    def home(self):\n        pass\n' : python,
      );
      File(
        '${root.path}${Platform.pathSeparator}b.js',
      ).writeAsStringSync('function init(){}\n');
      final siteDir = Directory('${root.path}${Platform.pathSeparator}c');
      siteDir.createSync(recursive: true);
      File(
        '${siteDir.path}${Platform.pathSeparator}index.html',
      ).writeAsStringSync('<!doctype html><html><body>hi</body></html>');
      return const LocalSpiderScanner().scan(root.path);
    }

    test('三类源各自落地，注册表与登记表都能看到', () async {
      final report = await scanFixture();

      final result = await importer.importSelected(report.candidates);

      expect(result.importedCount, 3);
      expect(result.rejectedCount, 0);

      final keys = registry.spiders.keys.toSet();
      expect(keys, containsAll(<String>['a', 'b']));
      expect(
        registry.spiders['a']!.manifest.runtime,
        'python',
      );
      expect(registry.spiders['b']!.manifest.runtime, 'node-tvbox');

      final webHome = store.list();
      expect(webHome.length, 1);
      expect(webHome.single.key, 'c');
      expect(webHome.single.enabled, isTrue);
      expect(
        File(
          '${store.directoryFor('c')}${Platform.pathSeparator}index.html',
        ).existsSync(),
        isTrue,
      );
    });

    test('CatVod 壳生成 spider.py 适配入口', () async {
      final report = await scanFixture(
        python: 'class Spider:\n    def homeContent(self, filter):\n'
            '        return {}\n',
      );
      final candidate = report.candidates.firstWhere(
        (item) => item.key == 'a',
      );
      expect(candidate.looksCatVod, isTrue);

      final result = await importer.importSelected([candidate]);

      expect(result.importedCount, 1);
      final spider = registry.spiders['a']!;
      expect(spider.manifest.runtime, 'python-catvod');
      expect(spider.manifest.entry, 'spider.py');
      expect(
        File(
          '${spider.rootDir}${Platform.pathSeparator}loader.py',
        ).existsSync(),
        isTrue,
      );
    });

    test('同名 key 再次导入被拒绝，既有源不被覆盖', () async {
      final report = await scanFixture();
      await importer.importSelected(report.candidates);

      final again = await importer.importSelected(report.candidates);

      expect(again.importedCount, 0);
      expect(again.rejectedCount, 3);
      expect(again.rejected.first.message, contains('已存在同名源'));
    });

    test('webHome 可停用与删除', () async {
      final report = await scanFixture();
      await importer.importSelected(report.candidates);

      expect(store.setEnabled('c', false), isTrue);
      expect(store.byKey('c')!.enabled, isFalse);

      expect(store.remove('c'), isTrue);
      expect(store.list(), isEmpty);
      expect(Directory(store.directoryFor('c')).existsSync(), isFalse);
    });
  });

  group('AppState 接入', () {
    test('扫描并导入后，AppState 同时暴露本地 Spider 与 webHome 源', () async {
      final paths = tempPaths(temp);
      paths.ensureDirectories();
      final state = AppState(paths: paths, log: LogService());

      final sourceDir = Directory(
        '${temp.path}${Platform.pathSeparator}fixture',
      );
      sourceDir.createSync(recursive: true);
      File(
        '${sourceDir.path}${Platform.pathSeparator}a.py',
      ).writeAsStringSync('class Spider:\n    def home(self):\n        pass\n');
      final siteDir = Directory(
        '${sourceDir.path}${Platform.pathSeparator}c',
      );
      siteDir.createSync(recursive: true);
      File(
        '${siteDir.path}${Platform.pathSeparator}index.html',
      ).writeAsStringSync('<!doctype html><html><body>hi</body></html>');

      final report = await state.scanLocalSources(sourceDir.path);
      expect(report.candidates.length, 2);
      expect(state.lastLocalScanFolder, sourceDir.path);

      final result = await state.importLocalSources(report.candidates);
      expect(result.importedCount, 2);
      expect(state.localSpiders.map((item) => item.key), contains('a'));
      expect(state.webHomeSources.map((item) => item.key), contains('c'));
      expect(
        Directory(state.webHomeDirectory('c')).existsSync(),
        isTrue,
      );

      await state.setWebHomeEnabled('c', false);
      expect(state.webHomeSources.single.enabled, isFalse);

      await state.removeWebHome('c');
      expect(state.webHomeSources, isEmpty);
    });
  });
}
