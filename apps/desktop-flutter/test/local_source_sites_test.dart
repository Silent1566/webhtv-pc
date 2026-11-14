/// 本地导入源在选择站点列表中的可见性、重启恢复与 HTML 打开路径。
///
/// 覆盖的关键行为（每一项都对应一条“用户看不见导入结果”的真实断点）：
/// - 导入 py/js/html 后 **立即** 出现在 `siteItems` 与 `effectiveConfig` 里；
/// - 用户没有任何配置时，本地源依然可选；
/// - 重启（新 AppState 实例 + bootstrap）后仍能读到本地注册；
/// - 旧的**根级** manifest 扫描路径不回归，`local/` 只多一层、不递归整棵树；
/// - 同 key 冲突时有稳定明确的取舍（root 优先、用户配置优先），并如实报告；
/// - HTML 条目不假称可搜索爬虫、可停用可删除，且选择它**不走** `loadHome`；
/// - 原始配置（配置记录）不被本地源污染。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/python_environment.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/state/local_site_sources.dart';
import 'package:webhtv_pc/services/spider_registry.dart';

AppPaths tempPaths(Directory temp) => AppPaths.resolve(
  overrides: {
    'config': '${temp.path}${Platform.pathSeparator}config',
    'data': '${temp.path}${Platform.pathSeparator}data',
    'cache': '${temp.path}${Platform.pathSeparator}cache',
    'state': '${temp.path}${Platform.pathSeparator}logs',
  },
);

Directory sub(Directory parent, String child) => Directory(join(parent, child));

/// 删除用例的临时目录。
///
/// Windows 上「谁也没再打开这个文件」≠「句柄已经还给系统」：`AppState.dispose()`
/// 是同步的，它名下的 sidecar 进程回收、日志刷盘、以及 Python 运行时准备都可能
/// 还在跑，而 CI runner 的实时扫描也会短暂持有刚写过的文件。此时递归删除会报
/// `OS Error 32`（另一个进程正在使用该文件）。这里只做**有界重试**：最多
/// 10 秒（100 次 × 100ms）。重试用尽仍失败就原样抛出——既不用 try/catch 吞掉
/// 失败，也不改动任何断言。
Future<void> deleteTempWhenReleased(Directory temp) async {
  const attempts = 100;
  for (var attempt = 1; attempt <= attempts; attempt++) {
    if (!temp.existsSync()) return;
    try {
      temp.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      if (attempt == attempts) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

String join(Directory dir, String name) =>
    '${dir.path}${Platform.pathSeparator}$name';

/// 写一个合法 manifest（含入口文件），模拟用户手工放在 `spiders/` 下的源。
void writeManifest(
  Directory dir,
  String key, {
  String name = '',
  String runtime = 'python',
  String entry = 'spider.py',
}) {
  dir.createSync(recursive: true);
  File(join(dir, entry)).writeAsStringSync('# $key\n');
  File(join(dir, 'manifest.json')).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'key': key,
      'name': name.isEmpty ? key : name,
      'runtime': runtime,
      'entry': entry,
      'capabilities': const ['home', 'category', 'detail', 'search', 'play'],
    }),
  );
}

/// 待导入的文件夹：`a.py`、`b.js`、`c/index.html`。
Directory writeCandidates(Directory temp, {String name = 'src'}) {
  final root = Directory(join(temp, name))..createSync(recursive: true);
  File(join(root, 'a.py'))
      .writeAsStringSync('class Spider:\n    def home(self):\n        pass\n');
  File(join(root, 'b.js')).writeAsStringSync('function init(){}\n');
  final site = Directory(join(root, 'c'))..createSync(recursive: true);
  File(join(site, 'index.html'))
      .writeAsStringSync('<!doctype html><html><body>hi</body></html>');
  return root;
}

/// 一份普通 JSON 配置：一个远端站点 `base`，用来验证“配置仍在 + 本地追加”。
const String configWithBase =
    '{"name":"t","sites":[{"key":"base","name":"Base","type":1,'
    '"api":"http://example.com/api"}]}';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('webhtv_local_site_sites_');
    LogService.logDirectoryOverride = join(temp, 'logs');
  });

  tearDown(() => deleteTempWhenReleased(temp));

  group('选择列表中可见', () {
    test(
      '导入 py/js 后立即出现在 siteItems 与 effectiveConfig，并沿用 spider-local: 路由',
      () async {
        final state = AppState(paths: tempPaths(temp), log: LogService());
        addTearDown(state.dispose);
        await state.bootstrap();
        await crateConfig(state);
        final root = writeCandidates(temp);

        final report = await state.scanLocalSources(root.path);
        final result = await state.importLocalSources(report.candidates);
        expect(result.importedCount, 3);

        expect(
          state.effectiveConfig!.sites.map((site) => site.key),
          containsAll(<String>['base', 'a', 'b']),
        );
        final items = {for (final item in state.siteItems) item.site.key: item};
        expect(items['a']!.site.api, 'spider-local:a');
        expect(items['b']!.site.api, 'spider-local:b');
        expect(items['a']!.site.searchable, isTrue);
      },
    );

    test('没有任何配置时本地源依然可选', () async {
      final state = AppState(paths: tempPaths(temp), log: LogService());
      addTearDown(state.dispose);
      final root = writeCandidates(temp);

      final report = await state.scanLocalSources(root.path);
      final result = await state.importLocalSources(report.candidates);
      expect(result.importedCount, 3);

      expect(state.effectiveConfig, isNotNull);
      expect(
        state.siteItems.map((item) => item.site.key),
        containsAll(<String>['a', 'b', 'c']),
      );
    });

    test('重启恢复：新实例 bootstrap 后仍能看到本地源', () async {
      final paths = tempPaths(temp);
      final first = AppState(paths: paths, log: LogService());
      final root = writeCandidates(temp);
      final report = await first.scanLocalSources(root.path);
      await first.importLocalSources(report.candidates);
      first.dispose();

      final second = AppState(paths: paths, log: LogService());
      addTearDown(second.dispose);
      await second.bootstrap();

      expect(
        second.siteItems.map((item) => item.site.key),
        containsAll(<String>['a', 'b', 'c']),
      );
    });
  });

  group('spiders/ 扫描', () {
    test('根级 manifest 仍在，local/ 只多一层，root 与 local 同 key 时 root 优先', () async {
      final paths = tempPaths(temp);
      final spiders = Directory(join(Directory(paths.configDir), 'spiders'));
      // 旧路径一：根部第一层目录。
      writeManifest(Directory(join(spiders, 'legacy')), 'legacy');
      // 旧路径二：根部直接放的 .json。
      File(join(spiders, 'rootonly.json')).writeAsStringSync(
        jsonEncode({
          'key': 'rootonly',
          'name': 'rootonly',
          'runtime': 'python',
          'entry': 'spider.py',
          'capabilities': const [
            'home',
            'category',
            'detail',
            'search',
            'play',
          ],
        }),
      );
      // 新路径：`local/<key>/manifest.json`（导入器写出的形态）。
      writeManifest(sub(sub(spiders, 'local'), 'localpy'), 'localpy');
      // 同 key：root 已有 `dup`，local 层又有一个 `dup` —— 必须保留 root 的那个。
      writeManifest(Directory(join(spiders, 'dup')), 'dup', name: 'root-dup');
      writeManifest(
        sub(sub(spiders, 'local'), 'dup'),
        'dup',
        name: 'local-dup',
      );

      final state = AppState(paths: paths, log: LogService());
      addTearDown(state.dispose);
      await state.bootstrap();

      final keys = state.spiderRegistry.spiders.keys.toSet();
      expect(
        keys,
        containsAll(<String>['legacy', 'rootonly', 'localpy', 'dup']),
      );
      expect(state.spiderRegistry.byKey('dup')!.manifest.name, 'root-dup');

      final siteKeys = state.siteItems.map((item) => item.site.key).toSet();
      expect(siteKeys, contains('localpy'), reason: 'local/ 下的导入源成为可选站点');
      expect(
        siteKeys.intersection({'legacy', 'rootonly', 'dup'}),
        isEmpty,
        reason: '根级 manifest 是被配置按 key 引用的存在，不自动变成站点',
      );
    });
  });

  group('冲突策略', () {
    test('无配置与有配置都去重跨形态本地key并记录拒绝', () {
      final sites = [
        Site(key: 'dup', type: 3, name: 'py', api: 'spider-local:dup'),
        Site(key: 'dup', type: 3, name: 'html', api: 'web-home:dup'),
      ];
      for (final base in [null, AppConfig()]) {
        final merged = mergeLocalSourceSites(base, sites);
        expect(merged.config.sites, hasLength(1));
        expect(merged.config.sites.single.name, 'py');
        expect(merged.rejectedKeys, ['dup']);
      }
    });

    // 此契约只验证注册表/磁盘/配置，不能让 importConfig 自动加载首页时
    // 意外准备真实 Python。原生起停仍由“真实运行中sidecar”和 bundled 测试覆盖。
    for (final probeDelay in [Duration.zero, const Duration(seconds: 1)]) {
      final suffix = probeDelay == Duration.zero ? '' : '（Python探针延迟1秒）';
      test('本地导入不能覆盖root路由，当前及重新扫描均保持root$suffix', () async {
        final paths = tempPaths(temp);
        AppState routingState() {
          final state = AppState(
            paths: paths,
            log: LogService(),
            pythonEnvironment: LocalSourceTestPythonEnvironment(
              paths: paths,
              probeDelay: probeDelay,
            ),
          );
          addTearDown(() async {
            state.dispose();
            await state.pythonEnvironmentIdle;
          });
          return state;
        }

        addTearDown(() => LocalSpiderCommand.preferPythonExecutable(null));
        final state = routingState();
        final root = sub(Directory(state.spiderRoot), 'a');
        writeManifest(root, 'a', name: 'root-a');
        final manifest = File(join(root, 'manifest.json'));
        final bytes = manifest.readAsBytesSync();
        await state.bootstrap();
        await state.reloadLocalSources();
        expect(
          await state.importConfig(
            '{"sites":[{"key":"configured","name":"root","type":3,"api":"spider-local:a"}]}',
          ),
          isTrue,
        );
        final report = await state.scanLocalSources(writeCandidates(temp).path);
        final picked = report.candidates.where((c) => c.key == 'a').toList();
        expect(picked, hasLength(1));
        final result = await state.importLocalSources(picked);
        expect(result.importedCount, 0);
        expect(result.rejectedCount, 1);
        expect(result.rejected.single.message, contains('占用'));
        expect(state.spiderRegistry.byKey('a')!.rootDir, root.path);
        expect(
          sub(sub(Directory(state.spiderRoot), 'local'), 'a').existsSync(),
          isFalse,
        );
        expect(manifest.readAsBytesSync(), bytes);
        expect(state.effectiveConfig!.sites.single.api, 'spider-local:a');
        await state.reloadLocalSources();
        expect(state.spiderRegistry.byKey('a')!.rootDir, root.path);
        expect(
          await state.spiderRegistry.register(manifest.path),
          isNotNull,
          reason: '同路径合法重注册',
        );
        final duplicate = sub(temp, 'duplicate');
        writeManifest(duplicate, 'a');
        expect(
          await state.spiderRegistry.register(join(duplicate, 'manifest.json')),
          isNull,
        );
        expect(state.spiderRegistry.byKey('a')!.rootDir, root.path);
        expect(
          state.pythonEnvironmentStatus?.source,
          PythonEnvironmentSource.missing,
        );
        expect(state.spiderRuntimeStatuses(), isEmpty);
        final restarted = routingState();
        await restarted.bootstrap();
        await restarted.pythonEnvironmentIdle;
        expect(restarted.spiderRegistry.byKey('a')!.rootDir, root.path);
        expect(restarted.effectiveConfig!.sites.single.api, 'spider-local:a');
        expect(restarted.spiderRuntimeStatuses(), isEmpty);
        expect(manifest.readAsBytesSync(), bytes);
      });
    }

    test('跨HTML与Spider命名空间导入双向拒绝，批次内也拒绝', () async {
      final state = AppState(paths: tempPaths(temp), log: LogService());
      addTearDown(state.dispose);
      final pyDir = sub(temp, 'py')..createSync();
      File(join(pyDir, 'c.py')).writeAsStringSync('class Spider: pass');
      final py = (await state.scanLocalSources(pyDir.path)).candidates.single;
      final html = (await state.scanLocalSources(writeCandidates(temp).path))
          .candidates
          .firstWhere((c) => c.key == 'c');
      final first = await state.importLocalSources([py, html]);
      expect(first.importedCount, 1);
      expect(first.rejectedCount, 1);
      expect(first.rejected.single.message, contains('占用'));
      expect(await state.removeLocalSpider('c'), isTrue);
      expect((await state.importLocalSources([html])).importedCount, 1);
      final reverse = await state.importLocalSources([py]);
      expect(reverse.rejectedCount, 1);
      expect(reverse.rejected.single.message, contains('占用'));
    });
    test('本地 key 与用户配置同 key 时不覆盖配置，且如实报告被拒 key', () async {
      final state = AppState(paths: tempPaths(temp), log: LogService());
      addTearDown(state.dispose);
      await crateConfig(state, key: 'dup');
      final root = writeCandidates(temp);
      final report = await state.scanLocalSources(root.path);
      final only = report.candidates.where((item) => item.key == 'a').toList();
      // 把候选改名成与配置同 key 的 `dup`：目录名即 key。
      final renamed = Directory(join(temp, 'dup-src'))
        ..createSync(recursive: true);
      File(
        join(renamed, 'dup.py'),
      ).writeAsStringSync('class Spider:\n    def home(self):\n        pass\n');
      final dupReport = await state.scanLocalSources(renamed.path);
      await state.importLocalSources([...only, ...dupReport.candidates]);

      final items = {for (final item in state.siteItems) item.site.key: item};
      expect(
        items['dup']!.site.api,
        'http://example.com/dup',
        reason: '用户配置里的 dup 必须胜出，本地源不得覆盖它',
      );
      expect(state.localSourceConflicts, contains('dup'));
    });
  });

  group('HTML 源', () {
    test('可选择、不假称可搜索爬虫，停用后隐藏、删除后消失', () async {
      final state = AppState(paths: tempPaths(temp), log: LogService());
      addTearDown(state.dispose);
      final root = writeCandidates(temp);
      final report = await state.scanLocalSources(root.path);
      await state.importLocalSources(report.candidates);

      var items = {for (final item in state.siteItems) item.site.key: item};
      expect(items['c']!.site.api, startsWith('web-home:'));
      expect(items['c']!.site.searchable, isFalse);
      expect(items['c']!.availability.available, isTrue);
      expect(items['c']!.availability.runtimeName, contains('HTML'));

      await state.setWebHomeEnabled('c', false);
      items = {for (final item in state.siteItems) item.site.key: item};
      expect(items.containsKey('c'), isFalse);

      await state.setWebHomeEnabled('c', true);
      await state.removeWebHome('c');
      items = {for (final item in state.siteItems) item.site.key: item};
      expect(items.containsKey('c'), isFalse);
    });

    test('识别接缝：只有启用的 HTML 源能被找到，py 站点为 null', () async {
      final state = AppState(paths: tempPaths(temp), log: LogService());
      addTearDown(state.dispose);
      final root = writeCandidates(temp);
      final report = await state.scanLocalSources(root.path);
      await state.importLocalSources(report.candidates);
      final items = {for (final item in state.siteItems) item.site.key: item};

      expect(state.webHomeSourceForSite(items['c']!.site)?.key, 'c');
      expect(state.webHomeSourceForSite(items['a']!.site), isNull);

      await state.setWebHomeEnabled('c', false);
      expect(state.webHomeSourceForSite(items['c']!.site), isNull);
    });

    test('选择 HTML 站点不走 loadHome，不产生错误状态', () async {
      final state = AppState(paths: tempPaths(temp), log: LogService());
      addTearDown(state.dispose);
      final root = writeCandidates(temp);
      final report = await state.scanLocalSources(root.path);
      await state.importLocalSources(report.candidates);
      final item = state.siteItems.firstWhere((item) => item.site.key == 'c');

      await state.selectSite(item.site);

      expect(state.selectedSite?.key, 'c');
      expect(state.homeResult, isNull);
      expect(state.lastError, isNull);
    });
  });

  group('在线 HTML 首页', () {
    test('登记后立即出现在站点列表，重启后仍在', () async {
      final paths = tempPaths(temp);
      final state = AppState(paths: paths, log: LogService());
      await state.bootstrap();
      final source = await state.addOnlineWebHome(
        'https://example.com/index.html',
        name: '在线示例',
      );
      expect(source.key, isNotEmpty);
      expect(source.isRemote, isTrue);
      state.dispose();

      final second = AppState(paths: paths, log: LogService());
      addTearDown(second.dispose);
      await second.bootstrap();

      final items = {for (final item in second.siteItems) item.site.key: item};
      expect(items[source.key]!.site.api, 'web-home:${source.key}');
      expect(items[source.key]!.site.searchable, isFalse);
      expect(
        second.webHomeSourceForSite(items[source.key]!.site)?.key,
        source.key,
      );
    });

    test('非法网址抛异常，不产生半条记录', () async {
      final state = AppState(paths: tempPaths(temp), log: LogService());
      addTearDown(state.dispose);
      await expectLater(
        state.addOnlineWebHome('not-a-url'),
        throwsA(isA<ArgumentError>()),
      );
      expect(state.webHomeSources, isEmpty);
    });
  });

  group('HTML 登记表降级与缓存', () {
    test('登记路径非普通文件安全降级，保留目录与普通站点', () async {
      final paths = tempPaths(temp);
      final registry = sub(sub(Directory(paths.configDir), 'webhome'), 'registry.json')..createSync(recursive: true);
      final sentinel = File(join(registry, 'keep.txt'))..writeAsStringSync('keep');
      final state = AppState(paths: paths, log: LogService());
      addTearDown(state.dispose);
      await state.bootstrap();
      await crateConfig(state);
      expect(state.siteItems.map((item) => item.site.key), contains('base'));
      expect(state.webHomeLoadError, contains('FileSystemException'));
      expect(() => state.webHomeSources, throwsA(isA<FileSystemException>()));
      expect(sentinel.readAsStringSync(), 'keep');
    });

    test('坏登记表阻止跨空间导入写盘，不冒充空表；修复刷新后恢复', () async {
      final state = AppState(paths: tempPaths(temp), log: LogService());
      addTearDown(state.dispose);
      final registry = File(join(sub(Directory(state.paths.configDir), 'webhome')..createSync(recursive: true), 'registry.json'));
      registry.writeAsStringSync('broken');
      final report = await state.scanLocalSources(writeCandidates(temp).path);
      final result = await state.importLocalSources(report.candidates);
      expect(result.importedCount, 0);
      expect(result.rejectedCount, 3);
      expect(sub(Directory(state.spiderRoot), 'local').existsSync(), isFalse);
      expect(registry.readAsStringSync(), 'broken');
      await state.reloadLocalSources();
      expect(state.webHomeLoadError, isNotNull);
      registry.writeAsStringSync('{"items":[]}');
      await state.reloadLocalSources();
      expect(state.webHomeLoadError, isNull);
      expect((await state.importLocalSources(report.candidates)).importedCount, 3);
    });
    test('坏登记表不破坏普通站点，报告原因且原字节不变', () async {
      final paths = tempPaths(temp);
      final registry = File(
        join(sub(Directory(paths.configDir), 'webhome'), 'registry.json'),
      );
      registry.parent.createSync(recursive: true);
      const broken = '{"items":[';
      registry.writeAsStringSync(broken);
      final state = AppState(paths: paths, log: LogService());
      addTearDown(state.dispose);
      await state.bootstrap();
      await crateConfig(state);
      expect(state.siteItems.map((item) => item.site.key), contains('base'));
      expect(state.webHomeLoadError, contains('FormatException'));
      expect(() => state.webHomeSources, throwsFormatException);
      expect(registry.readAsStringSync(), broken);
    });

    test('内部读取仅刷新时失效，不在每站点和每次build重读磁盘', () async {
      final state = AppState(paths: tempPaths(temp), log: LogService());
      addTearDown(state.dispose);
      await state.importLocalSources(
        (await state.scanLocalSources(writeCandidates(temp).path)).candidates,
      );
      final html = state.siteItems
          .firstWhere((item) => item.site.key == 'c')
          .site;
      final registry = File(
        join(sub(Directory(state.paths.configDir), 'webhome'), 'registry.json'),
      );
      registry.writeAsStringSync('broken');
      expect(state.webHomeSourceForSite(html)?.key, 'c');
      expect(state.siteItems.map((item) => item.site.key), contains('c'));
      expect(state.webHomeLoadError, isNull);
      await state.reloadLocalSources();
      expect(state.webHomeSourceForSite(html), isNull);
      expect(
        state.siteItems.map((item) => item.site.key),
        isNot(contains('c')),
      );
      expect(state.webHomeLoadError, isNotNull);
      expect(registry.readAsStringSync(), 'broken');
    });
  });

  group('安全删除本地 Spider', () {
    test('真实运行中sidecar按manifest key拒绝删除，停止后可删', () async {
      final state = AppState(paths: tempPaths(temp), log: LogService());
      addTearDown(state.dispose);
      final source = sub(sub(Directory(state.spiderRoot), 'local'), 'running');
      writeManifest(source, 'running', runtime: 'node', entry: 'spider.js');
      File(join(source, 'spider.js')).writeAsStringSync('''
function init() { return {}; }
function homeContent() { return {class: [], list: []}; }
function categoryContent() { return {list: []}; }
function detailContent() { return {list: []}; }
function searchContent() { return {list: []}; }
function playerContent() { return {url: ""}; }
module.exports = {init, homeContent, categoryContent, detailContent, searchContent, playerContent};
''');
      await state.reloadLocalSources();
      final spider = state.spiderRegistry.byKey('running')!;
      final command = LocalSpiderCommand.resolve(
        spider: spider,
        hostPath: defaultSidecarHostPath(),
        jsHostPath: defaultJsSidecarHostPath(),
      )!;
      // 使用不同配置站点key证明不能仅按删除key检查运行时。
      try {
        await state.spiderSupervisor.ensureRunning(
          siteKey: 'configured-alias',
          executable: command.executable,
          arguments: command.arguments,
          manifest: spider.manifest,
        );
      } catch (error) {
        final logs = Directory(state.paths.cacheDir)
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .where((file) => file.path.endsWith('stderr.log'));
        fail(
          '$error\n${logs.map((file) => file.readAsStringSync()).join('\n')}',
        );
      }
      addTearDown(() => state.stopSpider('configured-alias'));
      expect(state.spiderSupervisor.isRunning('configured-alias'), isTrue);
      expect(await state.removeLocalSpider('running'), isFalse);
      expect(source.existsSync(), isTrue);
      expect(
        state.log.entries.any((entry) => entry.message.contains('仍在运行')),
        isTrue,
      );
      await state.stopSpider('configured-alias');
      expect(state.spiderSupervisor.isRunning('configured-alias'), isFalse);
      expect(await state.removeLocalSpider('running'), isTrue);
      expect(source.existsSync(), isFalse);
    });

    test('已注册源含子链接或local父目录是链接时拒绝，不部分删除', () async {
      final state = AppState(paths: tempPaths(temp), log: LogService());
      addTearDown(state.dispose);
      final local = sub(Directory(state.spiderRoot), 'local');
      final source = sub(local, 'nested');
      writeManifest(source, 'nested');
      final outside = sub(temp, 'outside')..createSync();
      File(join(outside, 'keep.txt')).writeAsStringSync('keep');
      final link = Link(join(source, 'resource'))..createSync(outside.path);
      await state.reloadLocalSources();
      final before = File(join(source, 'manifest.json')).readAsBytesSync();
      expect(await state.removeLocalSpider('nested'), isFalse);
      expect(File(join(source, 'manifest.json')).readAsBytesSync(), before);
      expect(File(join(outside, 'keep.txt')).readAsStringSync(), 'keep');
      link.deleteSync();
      expect(await state.removeLocalSpider('nested'), isTrue);
      // local根本身为链接，即使显式注册过也不允许删除外部目录。
      local.deleteSync();
      writeManifest(sub(outside, 'parentlinked'), 'parentlinked');
      Link(local.path).createSync(outside.path);
      await state.spiderRegistry.register(
        join(sub(local, 'parentlinked'), 'manifest.json'),
      );
      expect(await state.removeLocalSpider('parentlinked'), isFalse);
      expect(sub(outside, 'parentlinked').existsSync(), isTrue);
    });
    test('删除 py/js 后目录与站点消失，配置不变且可以再次导入', () async {
      final state = AppState(paths: tempPaths(temp), log: LogService());
      addTearDown(state.dispose);
      await state.bootstrap();
      await crateConfig(state);
      final original = jsonEncode(state.activeRecord!.json);
      final report = await state.scanLocalSources(writeCandidates(temp).path);
      await state.importLocalSources(report.candidates);
      for (final key in ['a', 'b']) {
        expect(await state.removeLocalSpider(key), isTrue);
        expect(
          sub(sub(Directory(state.spiderRoot), 'local'), key).existsSync(),
          isFalse,
        );
        expect(
          state.siteItems.map((item) => item.site.key),
          isNot(contains(key)),
        );
        expect(state.spiderRegistry.byKey(key), isNull);
      }
      expect(jsonEncode(state.activeRecord!.json), original);
      expect(
        (await state.importLocalSources(
          report.candidates.where((c) => c.key != 'c').toList(),
        )).importedCount,
        2,
      );
    });

    test('unknown/root/越界和链接一律拒绝，不删除真实目标', () async {
      final state = AppState(paths: tempPaths(temp), log: LogService());
      addTearDown(state.dispose);
      final root = Directory(state.spiderRoot);
      writeManifest(sub(root, 'root-source'), 'root-source');
      final local = sub(root, 'local')..createSync(recursive: true);
      final outside = sub(temp, 'outside');
      writeManifest(outside, 'linked');
      final link = Link(join(local, 'linked'))..createSync(outside.path);
      await state.reloadLocalSources();
      expect(
        await state.spiderRegistry.register(
          join(Directory(link.path), 'manifest.json'),
        ),
        isNotNull,
      );
      sub(local, 'unknown').createSync();
      for (final key in [
        'unknown',
        'root-source',
        '../outside',
        '..',
        'linked',
      ]) {
        expect(await state.removeLocalSpider(key), isFalse, reason: key);
      }
      expect(outside.existsSync(), isTrue);
      expect(sub(root, 'root-source').existsSync(), isTrue);
      expect(link.existsSync(), isTrue);
    });
  });

  group('原始配置', () {
    test('导入本地源不写回配置记录', () async {
      final state = AppState(paths: tempPaths(temp), log: LogService());
      addTearDown(state.dispose);
      await state.bootstrap();
      await crateConfig(state);
      final before = state.activeRecord!.json;
      final beforeText = jsonEncode(before);
      final root = writeCandidates(temp);
      final report = await state.scanLocalSources(root.path);
      await state.importLocalSources(report.candidates);

      expect(state.activeRecord!.json, before);
      expect(beforeText.contains('spider-local:'), isFalse);
      expect(beforeText.contains('web-home:'), isFalse);
    });
  });
}

// 不走真实环境的静态 _changing 锁：前序测试的后台准备不能使本探针被跳过，
// 再因 status=null 退回系统解释器。只保留 AppState 等待/应用环境结果的链路。
class LocalSourceTestPythonEnvironment extends PythonEnvironment {
  LocalSourceTestPythonEnvironment({
    required super.paths,
    this.probeDelay = Duration.zero,
  });

  final Duration probeDelay;
  Future<void>? _pendingProbe;

  @override
  Future<void> get idle => _pendingProbe ?? Future<void>.value();

  @override
  Future<void> refresh() => _pendingProbe ??= _probe();

  Future<void> _probe() async {
    busy = true;
    await Future<void>.delayed(probeDelay);
    status = const PythonEnvironmentStatus(
      error: 'local source contract: native runtime intentionally unavailable',
    );
    busy = false;
  }
}

/// 导入一份普通 JSON 配置（`key` 为其中的站点 key），模拟“用户已有配置”。
Future<void> crateConfig(AppState state, {String key = 'base'}) async {
  final ok = await state.importConfig(
    '{"name":"t","sites":[{"key":"$key","name":"$key","type":1,'
    '"api":"http://example.com/$key"}]}',
  );
  if (!ok) throw StateError('导入测试配置失败');
}