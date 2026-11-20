/// 本地源启用状态：py/js 的 `local_sources.json` 与 HTML 的 `registry.json` 统一接缝。
///
/// 覆盖的关键行为：
/// - 默认启用、只记停用；写入是原子的，读坏的文件不会写回；
/// - 停用即从 `siteItems`/`effectiveConfig` 消失，再启用恢复；
/// - 停用会真的停掉仍在运行的 sidecar（不能只隐藏界面）；
/// - 批量接口逐 key 报告成败；删除源时清掉残留的停用状态；
/// - 重启（新 AppState）后停用状态仍在。
///
/// 纪律：每个用例都在 `Directory.systemTemp` 下建真实目录，所有 `AppPaths`
/// 都指向 temp，绝不读写用户真实配置目录。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/ipc_protocol.dart';
import 'package:webhtv_pc/services/local_source_enable_store.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/spider_registry.dart';
import 'package:webhtv_pc/state/app_state.dart';

import 'local_source_sites_test.dart'
    show
        crateConfig,
        deleteTempWhenReleased,
        tempPaths,
        writeCandidates,
        writeManifest;

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('webhtv_local_enable_');
    LogService.logDirectoryOverride = p.join(temp.path, 'logs');
  });

  tearDown(() async {
    LogService.logDirectoryOverride = null;
    await deleteTempWhenReleased(temp);
  });

  File enableFile(Directory dir) =>
      File(p.join(dir.path, 'local_sources.json'));

  group('持久化', () {
    test('默认启用；停用写入后新实例可读；再启用从文件移除', () {
      final store = LocalSourceEnableStore(path: enableFile(temp).path);
      expect(store.isEnabled('a'), isTrue);
      expect(enableFile(temp).existsSync(), isFalse, reason: '未改动不落盘');

      expect(store.setEnabled('a', false), isTrue);
      expect(store.isEnabled('a'), isFalse);
      final decoded = jsonDecode(enableFile(temp).readAsStringSync()) as Map;
      expect(decoded['disabled'], ['a']);

      final reopened = LocalSourceEnableStore(path: enableFile(temp).path);
      expect(reopened.isEnabled('a'), isFalse);
      expect(reopened.isEnabled('b'), isTrue);

      expect(reopened.setEnabled('a', true), isTrue);
      expect(reopened.isEnabled('a'), isTrue);
      expect(
        (jsonDecode(enableFile(temp).readAsStringSync()) as Map)['disabled'],
        isEmpty,
      );
    });

    test('批量写入一次落盘；forget 清残留', () {
      final store = LocalSourceEnableStore(path: enableFile(temp).path);
      expect(store.setEnabledAll(['a', 'b', 'c'], false), isTrue);
      expect(store.disabledKeys, {'a', 'b', 'c'});
      expect(store.forget('b'), isTrue);
      expect(store.disabledKeys, {'a', 'c'});
      // 空白 key 不写进文件（否则会出现永远匹配不上的条目）。
      expect(store.setEnabledAll(['  ', ''], false), isTrue);
      expect(store.disabledKeys, {'a', 'c'});
    });

    test('读坏的文件降级为全部启用、保留原因且不写回', () {
      final file = enableFile(temp)..writeAsStringSync('not json');
      final store = LocalSourceEnableStore(path: file.path);
      expect(store.isEnabled('a'), isTrue);
      expect(store.loadError, contains('合法 JSON'));
      expect(file.readAsStringSync(), 'not json', reason: '读取失败不得改写文件');
    });

    test('disabled 不是列表时同样降级并保留原因', () {
      final file = enableFile(temp)
        ..writeAsStringSync(jsonEncode({'version': 1, 'disabled': 'a'}));
      final store = LocalSourceEnableStore(path: file.path);
      expect(store.isEnabled('a'), isTrue);
      expect(store.loadError, contains('列表'));
    });
  });

  group('写入失败与文件安全', () {
    test('保存失败不改变内存里的启用状态', () {
      final path = p.join(temp.path, 'blocked.json');
      final store = LocalSourceEnableStore(path: path);
      expect(store.isEnabled('a'), isTrue);
      Directory(path).createSync();
      expect(store.setEnabled('a', false), isFalse);
      expect(store.isEnabled('a'), isTrue);
      expect(store.setEnabled('a', false), isFalse);
    });

    test('损坏的登记不允许写回覆盖', () {
      final file = enableFile(temp)..writeAsStringSync('not json');
      final store = LocalSourceEnableStore(path: file.path);
      expect(store.setEnabled('a', false), isFalse);
      expect(file.readAsStringSync(), 'not json');
      expect(store.loadError, isNotNull);
    });

    test('临时文件同名链接不会覆盖链接目标', () {
      final path = enableFile(temp).path;
      final outside = File(p.join(temp.path, 'keep.txt'))
        ..writeAsStringSync('keep');
      final link = Link('$path.tmp')..createSync(outside.path);
      final store = LocalSourceEnableStore(path: path);
      expect(store.setEnabled('a', false), isTrue);
      expect(outside.readAsStringSync(), 'keep');
      expect(link.existsSync(), isTrue);
    });
  });

  group('AppState 接缝', () {
    test('停用 py/js 源即从站点列表与配置消失，再启用恢复', () async {
      final state = AppState(paths: tempPaths(temp), log: LogService());
      addTearDown(() async {
        state.dispose();
        await state.pythonEnvironmentIdle;
      });
      await state.bootstrap();
      await crateConfig(state);
      writeManifest(
        Directory(p.join(state.spiderRoot, 'local', 'a')),
        'a',
        name: '源a',
      );
      await state.reloadLocalSources();

      Set<String> siteKeys() => {
        for (final item in state.siteItems) item.site.key,
      };
      expect(siteKeys(), contains('a'));
      expect(
        state.effectiveConfig!.sites.map((site) => site.key),
        contains('a'),
      );
      expect(state.localSourceEnabled('a'), isTrue);

      expect(await state.setLocalSourceEnabled('a', false), isTrue);
      expect(state.localSourceEnabled('a'), isFalse);
      expect(siteKeys(), isNot(contains('a')));
      expect(
        state.effectiveConfig!.sites.map((site) => site.key),
        isNot(contains('a')),
      );

      expect(await state.setLocalSourceEnabled('a', true), isTrue);
      expect(siteKeys(), contains('a'));
    });

    test('停用状态跨重启保留；删除源时清掉残留', () async {
      final paths = tempPaths(temp);
      final first = AppState(paths: paths, log: LogService());
      await first.bootstrap();
      writeManifest(Directory(p.join(first.spiderRoot, 'local', 'a')), 'a');
      await first.reloadLocalSources();
      expect(await first.setLocalSourceEnabled('a', false), isTrue);
      first.dispose();
      await first.pythonEnvironmentIdle;

      final second = AppState(paths: paths, log: LogService());
      addTearDown(() async {
        second.dispose();
        await second.pythonEnvironmentIdle;
      });
      await second.bootstrap();
      await second.reloadLocalSources();
      expect(second.spiderRegistry.byKey('a'), isNotNull);
      expect(second.localSourceEnabled('a'), isFalse);
      expect(
        second.siteItems.map((item) => item.site.key),
        isNot(contains('a')),
      );

      // 删除后同 key 重新导入不得继承旧的停用状态。
      expect(await second.removeLocalSpider('a'), isTrue);
      writeManifest(Directory(p.join(second.spiderRoot, 'local', 'a')), 'a');
      await second.reloadLocalSources();
      expect(second.localSourceEnabled('a'), isTrue);
      expect(second.siteItems.map((item) => item.site.key), contains('a'));
    });

    test('HTML 源与 py/js 走同一个开关接缝，互不干扰', () async {
      final state = AppState(paths: tempPaths(temp), log: LogService());
      addTearDown(() async {
        state.dispose();
        await state.pythonEnvironmentIdle;
      });
      await state.bootstrap();
      final report = await state.scanLocalSources(writeCandidates(temp).path);
      await state.importLocalSources(report.candidates);

      expect(state.localSourceEnabled('c'), isTrue, reason: 'HTML 源默认启用');
      expect(await state.setLocalSourceEnabled('c', false), isTrue);
      expect(state.localSourceEnabled('c'), isFalse);
      expect(
        state.siteItems.map((item) => item.site.key),
        isNot(contains('c')),
      );
      expect(await state.setLocalSourceEnabled('c', true), isTrue);
      expect(state.siteItems.map((item) => item.site.key), contains('c'));
      // 只动 HTML 的 key，py/js 的启用状态不受影响。
      expect(state.localSourceEnabled('a'), isTrue);
    });

    test('批量接口逐 key 返回成败，混合 HTML 与 py/js', () async {
      final state = AppState(paths: tempPaths(temp), log: LogService());
      addTearDown(() async {
        state.dispose();
        await state.pythonEnvironmentIdle;
      });
      await state.bootstrap();
      final report = await state.scanLocalSources(writeCandidates(temp).path);
      await state.importLocalSources(report.candidates);

      final outcome = await state.setLocalSourcesEnabled([
        'a',
        'b',
        'c',
        'missing',
      ], false);
      expect(outcome.results.keys, containsAll(['a', 'b', 'c', 'missing']));
      expect(outcome.results['missing'], isFalse);
      expect(outcome.allOk, isFalse, reason: '不存在的源必须报告失败');
      expect(outcome.okCount, 3);
      expect(outcome.failedKeys, ['missing']);
      for (final key in ['a', 'b', 'c']) {
        expect(state.localSourceEnabled(key), isFalse, reason: key);
      }
      final remaining = state.siteItems.map((item) => item.site.key).toSet();
      expect(remaining.intersection({'a', 'b', 'c'}), isEmpty);

      final restored = await state.setLocalSourcesEnabled(['a', 'c'], true);
      expect(restored.allOk, isTrue);
      expect(state.localSourceEnabled('a'), isTrue);
      expect(state.localSourceEnabled('c'), isTrue);
      expect(state.localSourceEnabled('b'), isFalse);
    });

    test('启用状态读坏时如实暴露原因，不静默当成全部启用', () async {
      final paths = tempPaths(temp);
      await paths.ensureDirectories();
      File(p.join(paths.configDir, 'local_sources.json'))
          .writeAsStringSync('broken');
      final state = AppState(paths: paths, log: LogService());
      addTearDown(() async {
        state.dispose();
        await state.pythonEnvironmentIdle;
      });
      writeManifest(Directory(p.join(state.spiderRoot, 'local', 'a')), 'a');
      await state.reloadLocalSources();
      expect(state.localSourceEnableError, contains('合法 JSON'));
      expect(state.localSourceEnabled('a'), isTrue, reason: '降级为启用，但原因已暴露');
    });

    test('Spider 停用残留不隐藏已启用的 HTML 源', () async {
      final paths = tempPaths(temp);
      await paths.ensureDirectories();
      File(p.join(paths.configDir, 'local_sources.json')).writeAsStringSync(
        jsonEncode({
          'version': 1,
          'disabled': ['c'],
        }),
      );
      final state = AppState(paths: paths, log: LogService());
      addTearDown(() async {
        state.dispose();
        await state.pythonEnvironmentIdle;
      });
      final html = (await state.scanLocalSources(writeCandidates(temp).path))
          .candidates
          .where((item) => item.key == 'c')
          .toList();
      await state.importLocalSources(html);
      expect(state.localSourceEnabled('c'), isTrue);
      expect(state.siteItems.map((item) => item.site.key), contains('c'));
    });

    test('握手期间停用会立即取消正在启动的 Python 进程', () async {
      final state = AppState(paths: tempPaths(temp), log: LogService());
      addTearDown(() async {
        state.dispose();
        await state.pythonEnvironmentIdle;
      });
      final source = Directory(p.join(state.spiderRoot, 'local', 'starting'));
      writeManifest(source, 'starting');
      final marker = File(p.join(temp.path, 'initializing'));
      final release = File(p.join(temp.path, 'release'));
      File(p.join(source.path, 'spider.py')).writeAsStringSync(
        '''
import pathlib
import time
class Spider:
    def __init__(self, manifest=None): pass
    def init(self, extend):
        pathlib.Path(${jsonEncode(marker.path)}).write_text('started')
        while not pathlib.Path(${jsonEncode(release.path)}).exists():
            time.sleep(0.01)
        return {}
    def capabilities(self): return ['home', 'category', 'detail', 'search', 'play']
    def home(self, params, context): return {'list': []}
    category = detail = search = play = home
    def close(self): pass
'''
            .replaceAll('\\', '/'),
      );
      await state.reloadLocalSources();
      final spider = state.spiderRegistry.byKey('starting')!;
      await state.pythonEnvironmentIdle;
      LocalSpiderCommand.preferPythonExecutable(null);
      addTearDown(() => LocalSpiderCommand.preferPythonExecutable(null));
      final command = LocalSpiderCommand.resolve(
        spider: spider,
        hostPath: defaultSidecarHostPath(),
      )!;
      Object? startupError;
      final starting = state.spiderSupervisor
          .ensureRunning(
            siteKey: 'starting-alias',
            executable: command.executable,
            arguments: command.arguments,
            manifest: spider.manifest,
          )
          .then<Object>(
            (host) => host,
            onError: (Object error) {
              startupError = error;
              return error;
            },
          );
      try {
        // 等真实 Python 进程起来并跑完 init() 写下 marker：慢 runner 上 spawn + import
        // 可能超过 2s，固定 200×10ms 的预算会把"还没起来"误判成"从没起来过"
        // （CI 上这条曾这样红过一次）。正常情况 100-300ms 就会跳出。
        final markerDeadline = DateTime.now().add(const Duration(seconds: 15));
        while (!marker.existsSync() && DateTime.now().isBefore(markerDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        final diagnostics = Directory(state.paths.cacheDir).existsSync()
            ? Directory(state.paths.cacheDir)
                  .listSync(recursive: true)
                  .whereType<File>()
                  .where((file) => file.path.endsWith('stderr.log'))
                  .map((file) => file.readAsStringSync())
                  .join('\n')
            : '';
        expect(
          marker.existsSync(),
          isTrue,
          reason: 'initialize: $startupError\n$diagnostics',
        );
        expect(
          await state.removeLocalSpider('starting'),
          isFalse,
          reason: '初始化中的进程也必须先停止，不能删除仍被使用的源',
        );
        expect(await state.setLocalSourceEnabled('starting', false), isTrue);
        final result = await starting.timeout(const Duration(seconds: 1));
        expect(result, isA<SpiderError>());
        expect(state.spiderSupervisor.isRunning('starting-alias'), isFalse);
        expect(state.spiderRuntimeStatuses().single.failureCount, 0);
      } finally {
        release.writeAsStringSync('release');
        await starting.timeout(const Duration(seconds: 5));
        await state.stopSpider('starting-alias');
      }
    });

    test('停用运行中的本地源会立刻停掉它的 sidecar', () async {
      final state = AppState(paths: tempPaths(temp), log: LogService());
      addTearDown(() async {
        state.dispose();
        await state.pythonEnvironmentIdle;
      });
      await state.bootstrap();
      final source = Directory(p.join(state.spiderRoot, 'local', 'running'));
      writeManifest(source, 'running', runtime: 'node', entry: 'spider.js');
      File(p.join(source.path, 'spider.js')).writeAsStringSync('''
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
      // 站点 key 与 manifest key 不同：停用必须两种 key 都能命中运行时。
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
          '$error\n${logs.map((file) => file.readAsStringSync()).join("\n")}',
        );
      }
      addTearDown(() => state.stopSpider('configured-alias'));
      expect(state.spiderSupervisor.isRunning('configured-alias'), isTrue);

      expect(await state.setLocalSourceEnabled('running', false), isTrue);
      expect(state.spiderSupervisor.isRunning('configured-alias'), isFalse);
      await expectLater(
        state.spiderSupervisor.ensureRunning(
          siteKey: 'configured-alias',
          executable: command.executable,
          arguments: command.arguments,
          manifest: spider.manifest,
        ),
        throwsA(
          isA<SpiderError>().having(
            (error) => error.message,
            '停用原因',
            contains('停用'),
          ),
        ),
      );
      expect(state.spiderSupervisor.isRunning('configured-alias'), isFalse);

      // 启用**不**自动拉起运行时：启动时机仍由用户打开站点决定。
      expect(await state.setLocalSourceEnabled('running', true), isTrue);
      expect(state.spiderSupervisor.isRunning('configured-alias'), isFalse);
    });
  });
}
