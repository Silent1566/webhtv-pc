import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/web_home_bridge.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/web_home_page.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/local_source_import.dart';
import 'package:webhtv_pc/services/local_spider_scanner.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/spider_registry.dart';
import 'package:webhtv_pc/services/web_home_store.dart';

WebHomeSource localSource(String key) => WebHomeSource(
  key: key,
  name: '本地页面',
  entry: 'index.html',
  importedAt: '2020-01-02T03:04:05.000Z',
  entrySha256: 'existing-digest',
);

LocalSourceCandidate changeCandidate(
  LocalSourceCandidate source, {
  String? name,
  String? entryName,
}) => LocalSourceCandidate(
  kind: source.kind,
  absPath: source.absPath,
  sourceDir: source.sourceDir,
  entryName: entryName ?? source.entryName,
  key: source.key,
  name: name ?? source.name,
  bytes: source.bytes,
  sha256: source.sha256,
  modified: source.modified,
  warnings: source.warnings,
  looksCatVod: source.looksCatVod,
);

class RegistrationHookRegistry extends SpiderManifestRegistry {
  RegistrationHookRegistry({required super.root, required this.afterRegister})
    : super(log: LogService());

  final Future<void> Function(String path) afterRegister;

  @override
  Future<LocalSpider?> register(String manifestPath) async {
    final result = await super.register(manifestPath);
    await afterRegister(manifestPath);
    return result;
  }
}

void main() {
  late Directory temp;
  late WebHomeStore store;
  late LocalSourceImporter importer;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('webhtv_online_home_');
    store = WebHomeStore(root: p.join(temp.path, 'webhome'));
    final spiderRoot = p.join(temp.path, 'spiders');
    importer = LocalSourceImporter(
      spiderRoot: spiderRoot,
      registry: SpiderManifestRegistry(root: spiderRoot, log: LogService()),
      webHomeStore: store,
    );
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<LocalSourceCandidate> scanFile(String name, String body) async {
    final file = File(p.join(temp.path, 'input', name));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(body);
    file.setLastModifiedSync(DateTime.utc(2018, 2, 3, 4, 5, 6));
    final report = await const LocalSpiderScanner().scan(file.parent.path);
    return report.candidates.single;
  }

  WebHomeSource addRemote(String url, {String? name}) {
    WebHomeSource? added;
    expect(() {
      added = store.addRemote(url, name: name);
    }, returnsNormally);
    return added!;
  }

  test('addRemote 保存原 URL 且重读一致，不创建离线副本', () {
    final source = addRemote(
      '  https://example.invalid/page?q=%E4%B8%AD#home  ',
      name: '在线页面',
    );
    expect(source.remoteUrl, 'https://example.invalid/page?q=%E4%B8%AD#home');
    expect(source.name, '在线页面');
    expect(source.isRemote, isTrue);
    expect(source.modifiedAt, '');
    expect(source.entrySha256, '');
    final reread = WebHomeStore(root: store.root).byKey(source.key)!;
    expect(reread.toJson(), source.toJson());
    expect(Directory(store.directoryFor(source.key)).existsSync(), isFalse);
    expect(
      Directory(store.root).listSync().map((entry) => p.basename(entry.path)),
      ['registry.json'],
    );
  });

  for (final url in [
    'http://localhost:8080/page',
    'https://[2001:db8::1]/page',
    'HTTPS://EXAMPLE.INVALID/page',
  ]) {
    test('接受有 host 的合法 http(s) 地址 $url', () {
      expect(addRemote(url).remoteUrl, url);
    });
  }

  for (final url in [
    '',
    'javascript:alert(1)',
    'file:///tmp/a.html',
    'ftp://example.invalid/page',
    'https:///page',
    '//example.invalid',
    'https://',
    'https://user:secret@example.invalid/page',
    'https://@example.invalid/page',
    r'https://example.invalid\evil',
    'https://exa mple.invalid/page',
    'https://example.invalid/a\nb',
    'https://example.invalid:65536/page',
    'https://example.invalid:0/page',
    'https://example.invalid/%zz',
    'https://%65xample.invalid/page',
    'https://.invalid/page',
    'https://-bad.invalid/page',
  ]) {
    test('拒绝非法或危险 URL $url 且不登记', () {
      store.save([localSource('existing')]);
      final before = File(store.registryPath).readAsStringSync();
      expect(() => store.addRemote(url), throwsArgumentError);
      expect(File(store.registryPath).readAsStringSync(), before);
    });
  }

  test('重复 URL 明确拒绝且不替换记录', () {
    final source = addRemote('https://example.invalid/page', name: '原名');
    final before = File(store.registryPath).readAsStringSync();
    expect(
      () => store.addRemote(' https://example.invalid/page ', name: '替换名'),
      throwsStateError,
    );
    expect(store.byKey(source.key)!.name, '原名');
    expect(File(store.registryPath).readAsStringSync(), before);
  });

  test('同一 URL key 稳定但本地 key 冲突时不覆盖', () {
    const url = 'https://example.invalid/page';
    final source = addRemote(url);
    final other = WebHomeStore(root: p.join(temp.path, 'other'));
    final repeated = other.addRemote(url);
    expect(repeated.key, source.key);
    store.save([localSource(source.key)]);
    expect(() => store.addRemote(url), throwsStateError);
    expect(store.byKey(source.key)!.entrySha256, 'existing-digest');
    expect(store.byKey(source.key)!.isRemote, isFalse);
  });

  test('URL 大小写等价变体也视为重复，不覆盖原始网址', () {
    final source = addRemote('https://example.invalid/page');
    expect(
      () => store.addRemote('HTTPS://EXAMPLE.INVALID/page'),
      throwsStateError,
    );
    expect(store.list().length, 1);
    expect(store.byKey(source.key)!.remoteUrl, 'https://example.invalid/page');
  });

  test('拒绝空端口和越界或畸形的 IPv4 host', () {
    for (final url in [
      'https://example.invalid:/page',
      'http://999.1.2.3/page',
      'http://1.2.3.4.5/page',
    ]) {
      expect(() => store.addRemote(url), throwsArgumentError, reason: url);
    }
    expect(store.list(), isEmpty);
  });
  test('派生 key 已占用磁盘目录时也拒绝登记', () {
    const url = 'https://example.invalid/page';
    final source = addRemote(url);
    store.save([]);
    final marker = File(p.join(store.directoryFor(source.key), 'keep.txt'));
    marker.parent.createSync(recursive: true);
    marker.writeAsStringSync('original');
    expect(() => store.addRemote(url), throwsStateError);
    expect(store.list(), isEmpty);
    expect(marker.readAsStringSync(), 'original');
  });

  test('远端删除只删登记，不删除同 key 无关目录', () {
    final source = WebHomeSource.fromJson({
      'key': 'remote',
      'remoteUrl': 'https://example.invalid/page',
    });
    store.save([source, localSource('local')]);
    final marker = File(p.join(store.directoryFor(source.key), 'keep.txt'));
    marker.parent.createSync(recursive: true);
    marker.writeAsStringSync('original');
    expect(store.remove(source.key), isTrue);
    expect(store.byKey(source.key), isNull);
    expect(store.byKey('local'), isNotNull);
    expect(marker.readAsStringSync(), 'original');
  });

  test('JSON 重读和 enable/copy 保留网址与已知修改时间', () {
    final source = WebHomeSource.fromJson({
      'key': 'remote-fixture',
      'name': '在线页面',
      'remoteUrl': 'https://example.invalid/index.html?q=1#home',
      'modifiedAt': '2018-02-03T04:05:06.000Z',
    });
    store.upsert(source);
    expect(store.setEnabled(source.key, false), isTrue);
    final saved = WebHomeStore(root: store.root).byKey(source.key)!;
    expect(
      saved.toJson()['remoteUrl'],
      'https://example.invalid/index.html?q=1#home',
    );
    expect(
      saved.copyWith(name: '改名').toJson()['modifiedAt'],
      '2018-02-03T04:05:06.000Z',
    );
    expect(saved.enabled, isFalse);
  });

  test('旧 HTML 记录保持入口且新增字段默认空值', () {
    final source = WebHomeSource.fromJson({
      'key': 'legacy',
      'name': '旧页面',
      'entry': 'old.html',
      'entrySha256': 'old-hash',
    });
    expect(source.entry, 'old.html');
    expect(source.toJson()['remoteUrl'], '');
    expect(source.toJson()['modifiedAt'], '');
  });

  test('HTML 导入保存扫描到的原文件修改时间', () async {
    final candidate = await scanFile('page.html', '<html>local</html>');
    final result = await importer.importSelected([candidate]);
    expect(result.importedCount, 1);
    expect(
      store.byKey(candidate.key)!.toJson()['modifiedAt'],
      candidate.modified.toIso8601String(),
    );
  });

  for (final entry in {
    'a.py': 'class Spider:\n    pass\n',
    'b.js': 'function init(){}',
  }.entries) {
    test('${entry.key} manifest 保存扫描到的原文件修改时间', () async {
      final candidate = await scanFile(entry.key, entry.value);
      final result = await importer.importSelected([candidate]);
      expect(result.importedCount, 1);
      final manifest = jsonDecode(
        File(p.join(result.imported.single.targetDir, 'manifest.json'))
            .readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(
        manifest['localSource']['modifiedAt'],
        candidate.modified.toIso8601String(),
      );
    });
  }

  test('删除未知 key 不删除没有登记的目录', () {
    final marker = File(p.join(store.root, 'unregistered', 'keep.txt'));
    marker.parent.createSync(recursive: true);
    marker.writeAsStringSync('keep');
    expect(store.remove('unregistered'), isFalse);
    expect(marker.readAsStringSync(), 'keep');
  });

  for (final key in [
    '',
    '.',
    '..',
    '../outside',
    r'..\outside',
    '/outside',
    r'C:\outside',
    'bad:key',
    'CON',
    'tail.',
  ]) {
    test('非法 key $key 不修改登记或删除根目录', () {
      store.save([localSource('safe')]);
      final before = File(store.registryPath).readAsStringSync();
      final marker = File(p.join(store.root, 'keep.txt'))
        ..writeAsStringSync('keep');
      expect(store.remove(key), isFalse);
      expect(marker.readAsStringSync(), 'keep');
      expect(File(store.registryPath).readAsStringSync(), before);
    });
  }

  for (final kind in LocalSourceKind.values) {
    test('导入 ${kind.name} 拒绝越界 candidate key', () async {
      final scanned = await scanFile('page.html', '<html>local</html>');
      final malicious = LocalSourceCandidate(
        kind: kind,
        absPath: scanned.absPath,
        sourceDir: scanned.sourceDir,
        entryName: scanned.entryName,
        key: '../../escaped',
        name: 'malicious',
        bytes: scanned.bytes,
        sha256: scanned.sha256,
        modified: scanned.modified,
      );
      final result = await importer.importSelected([malicious]);
      expect(result.rejectedCount, 1);
      expect(Directory(p.join(temp.path, 'escaped')).existsSync(), isFalse);
      expect(store.list(), isEmpty);
    });
  }

  test('删除本地符号链接不影响登记根外目录', () {
    final outside = Directory(p.join(temp.path, 'outside'))..createSync();
    final marker = File(p.join(outside.path, 'keep.txt'))
      ..writeAsStringSync('original');
    Directory(store.root).createSync();
    try {
      Link(p.join(store.root, 'linked')).createSync(outside.path);
    } on FileSystemException catch (error) {
      markTestSkipped('当前系统不支持测试目录符号链接：$error');
      return;
    }
    store.save([localSource('linked')]);
    expect(store.remove('linked'), isFalse);
    expect(marker.readAsStringSync(), 'original');
    expect(store.byKey('linked'), isNotNull);
  });
  test('真实 manifest 拒绝后撤回本次目录，同 key 可再次导入', () async {
    final candidate = await scanFile('reject.py', 'class Spider:\n    pass\n');
    final rejected = await importer.importSelected([
      changeCandidate(candidate, name: ''),
    ]);
    expect(rejected.rejectedCount, 1);
    expect(rejected.rejected.single.message, contains('manifest 校验未通过'));
    final target = p.join(importer.localRoot, candidate.key);
    expect(Directory(target).existsSync(), isFalse);
    expect(importer.registry.byKey(candidate.key), isNull);
    final retry = await importer.importSelected([candidate]);
    expect(retry.importedCount, 1);
    expect(importer.registry.byKey(candidate.key), isNotNull);
  });

  for (final entry in {
    'gone.py': 'class Spider:\n    pass\n',
    'gone.js': 'function init(){}',
  }.entries) {
    test('${entry.key} 本次创建后源文件读取失败，不残留且可重试', () async {
      final candidate = await scanFile(entry.key, entry.value);
      final input = File(candidate.absPath);
      expect(p.isWithin(temp.path, input.path), isTrue);
      input.deleteSync();
      final rejected = await importer.importSelected([candidate]);
      expect(rejected.rejectedCount, 1);
      expect(
        Directory(p.join(importer.localRoot, candidate.key)).existsSync(),
        isFalse,
      );
      input.writeAsStringSync(entry.value);
      final retry = await importer.importSelected([candidate]);
      expect(retry.importedCount, 1);
    });
  }

  test('HTML 复制后入口校验失败，撤回目录并允许重试', () async {
    final candidate = await scanFile('page.html', '<html>local</html>');
    final rejected = await importer.importSelected([
      changeCandidate(candidate, entryName: 'missing.html'),
    ]);
    expect(rejected.rejectedCount, 1);
    expect(Directory(store.directoryFor(candidate.key)).existsSync(), isFalse);
    expect(store.list(), isEmpty);
    expect(File(candidate.absPath).readAsStringSync(), '<html>local</html>');
    final retry = await importer.importSelected([candidate]);
    expect(retry.importedCount, 1);
  });

  test('HTML 登记写入失败撤回复制目录，保留原冲突登记路径', () async {
    final candidate = await scanFile('page.html', '<html>local</html>');
    final blocker = Directory(store.registryPath)..createSync(recursive: true);
    final marker = File(p.join(blocker.path, 'keep.txt'))
      ..writeAsStringSync('original');
    final rejected = await importer.importSelected([candidate]);
    expect(rejected.rejectedCount, 1);
    expect(Directory(store.directoryFor(candidate.key)).existsSync(), isFalse);
    expect(marker.readAsStringSync(), 'original');
    expect(p.isWithin(temp.path, blocker.path), isTrue);
    blocker.deleteSync(recursive: true);
    final retry = await importer.importSelected([candidate]);
    expect(retry.importedCount, 1);
  });

  test('Spider 原目标目录冲突不参与回滚或删除', () async {
    final candidate = await scanFile(
      'existing.py',
      'class Spider:\n    pass\n',
    );
    final marker = File(p.join(importer.localRoot, candidate.key, 'keep.txt'));
    marker.parent.createSync(recursive: true);
    marker.writeAsStringSync('original');
    final rejected = await importer.importSelected([candidate]);
    expect(rejected.rejectedCount, 1);
    expect(marker.readAsStringSync(), 'original');
  });
  test('回滚时目标被替换为链接，保留无关目录并如实报告残留', () async {
    final candidate = await scanFile('reject.py', 'class Spider:\n    pass\n');
    final outside = Directory(p.join(temp.path, 'unrelated'))..createSync();
    final marker = File(p.join(outside.path, 'keep.txt'))
      ..writeAsStringSync('original');
    final registry = RegistrationHookRegistry(
      root: importer.spiderRoot,
      afterRegister: (manifestPath) async {
        final target = Directory(p.dirname(manifestPath));
        final moved = p.join(temp.path, 'moved-owned-directory');
        expect(p.isWithin(importer.localRoot, target.path), isTrue);
        expect(p.isWithin(temp.path, moved), isTrue);
        target.renameSync(moved);
        Link(target.path).createSync(outside.path);
      },
    );
    final hookedImporter = LocalSourceImporter(
      spiderRoot: importer.spiderRoot,
      registry: registry,
      webHomeStore: store,
    );
    final rejected = await hookedImporter.importSelected([
      changeCandidate(candidate, name: ''),
    ]);
    expect(rejected.rejectedCount, 1);
    expect(rejected.rejected.single.message, contains('未撤回'));
    expect(rejected.rejected.single.message, contains('残留目录'));
    expect(rejected.rejected.single.message, isNot(contains('已撤回')));
    expect(marker.readAsStringSync(), 'original');
    expect(
      FileSystemEntity.typeSync(
        p.join(importer.localRoot, candidate.key),
        followLinks: false,
      ),
      FileSystemEntityType.link,
    );
  });
  test('回滚时同路径被正常目录替换，不删另一方新建的目录', () async {
    final candidate = await scanFile('reject.py', 'class Spider:\n    pass\n');
    late File marker;
    final registry = RegistrationHookRegistry(
      root: importer.spiderRoot,
      afterRegister: (manifestPath) async {
        final target = Directory(p.dirname(manifestPath));
        final moved = p.join(temp.path, 'moved-owned-directory');
        expect(p.isWithin(importer.localRoot, target.path), isTrue);
        expect(p.isWithin(temp.path, moved), isTrue);
        target.renameSync(moved);
        target.createSync();
        marker = File(p.join(target.path, 'foreign.txt'))
          ..writeAsStringSync('foreign');
      },
    );
    final hookedImporter = LocalSourceImporter(
      spiderRoot: importer.spiderRoot,
      registry: registry,
      webHomeStore: store,
    );
    final rejected = await hookedImporter.importSelected([
      changeCandidate(candidate, name: ''),
    ]);
    expect(rejected.rejectedCount, 1);
    expect(rejected.rejected.single.message, contains('未撤回'));
    expect(marker.readAsStringSync(), 'foreign');
  });
  test('F1 转移旧所有权标记也不能让回滚删除替换目录', () async {
    final candidate = await scanFile('reject.py', 'class Spider:\n    pass\n');
    late File foreign;
    final hooked = RegistrationHookRegistry(
      root: importer.spiderRoot,
      afterRegister: (manifestPath) async {
        final target = Directory(p.dirname(manifestPath));
        final moved = p.join(temp.path, 'original-moved');
        expect(p.isWithin(importer.localRoot, target.path), isTrue);
        expect(p.isWithin(temp.path, moved), isTrue);
        target.renameSync(moved);
        target.createSync();
        for (final marker in Directory(
          moved,
        ).listSync().whereType<Directory>()) {
          if (p.basename(marker.path).startsWith('.import-owner-')) {
            final destination = p.join(target.path, p.basename(marker.path));
            expect(p.isWithin(target.path, destination), isTrue);
            marker.renameSync(destination);
          }
        }
        foreign = File(p.join(target.path, 'foreign.txt'))
          ..writeAsStringSync('foreign');
      },
    );
    final result = await LocalSourceImporter(
      spiderRoot: importer.spiderRoot,
      registry: hooked,
      webHomeStore: store,
    ).importSelected([changeCandidate(candidate, name: '')]);
    expect(result.rejectedCount, 1);
    expect(result.rejected.single.message, contains('未撤回'));
    expect(result.rejected.single.message, contains('original-moved'));
    expect(foreign.readAsStringSync(), 'foreign');
  });

  for (final data in ['{', '{"items":{}}', '{"items":null}', '[]truncated']) {
    test('F5 损坏登记 $data 拒绝在线新增且保留原字节', () {
      Directory(store.root).createSync();
      File(store.registryPath).writeAsStringSync(data);
      expect(
        () => store.addRemote('https://example.invalid/page'),
        throwsA(isA<FormatException>()),
      );
      expect(File(store.registryPath).readAsStringSync(), data);
    });
    test('F5 损坏登记 $data 拒绝HTML导入且保留原字节', () async {
      final candidate = await scanFile('page.html', '<html>local</html>');
      Directory(store.root).createSync();
      File(store.registryPath).writeAsStringSync(data);
      final result = await importer.importSelected([candidate]);
      expect(result.rejectedCount, 1);
      expect(File(store.registryPath).readAsStringSync(), data);
      expect(
        Directory(store.directoryFor(candidate.key)).existsSync(),
        isFalse,
      );
    });
  }

  test('F5 空表和旧 list 登记仍可以追加网址', () {
    Directory(store.root).createSync();
    File(store.registryPath).writeAsStringSync('[]');
    store.addRemote('https://example.invalid/first');
    File(store.registryPath)
        .writeAsStringSync(jsonEncode([localSource('old').toJson()]));
    store.addRemote('https://example.invalid/second');
    expect(store.list().map((item) => item.key), contains('old'));
    expect(store.list().length, 2);
  });
  group('WebHomePage 真实原生通道边界', () {
    const plugin = MethodChannel('io.jns.webview.win');
    const controller = MethodChannel('io.jns.webview.win/71');
    const events = MethodChannel('io.jns.webview.win/71/events');
    late AppState state;
    late List<MethodCall> calls;

    setUp(() {
      final paths = AppPaths.resolve(
        overrides: {
          'config': p.join(temp.path, 'config'),
          'data': p.join(temp.path, 'data'),
          'cache': p.join(temp.path, 'cache'),
          'state': p.join(temp.path, 'logs'),
        },
      );
      state = AppState(paths: paths, log: LogService());
      calls = [];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(plugin, (call) async {
        calls.add(call);
        if (call.method == 'initialize') return {'textureId': 71};
        return null;
      });
      messenger.setMockMethodCallHandler(controller, (call) async {
        if (call.method != 'setSize') calls.add(call);
        if (call.method == 'addScriptToExecuteOnDocumentCreated') {
          return 'bridge';
        }
        return null;
      });
      messenger.setMockMethodCallHandler(events, (call) async {
        return null;
      });
    });

    tearDown(() {
      state.dispose();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final channel in [plugin, controller, events]) {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });

    Future<void> open(WidgetTester tester, WebHomeSource source) async {
      await tester.pumpWidget(
        MaterialApp(
          home: WebHomePage(state: state, source: source),
        ),
      );
      await tester.pump();
      tester.binding.channelBuffers.push(
        events.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'type': 'loadingStateChanged',
          'value': 2,
        }),
        (_) {},
      );
      await tester.pumpAndSettle();
    }

    Future<void> emit(WidgetTester tester, String type, int value) async {
      tester.binding.channelBuffers.push(
        events.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'type': type,
          'value': value,
        }),
        (_) {},
      );
      await tester.pump();
      await tester.pump();
    }

    for (final code in [5, 12, 13]) {
      testWidgets('F2 原生导航错误 $code 显示错误而非把提交当完成', (tester) async {
        await open(
          tester,
          WebHomeSource.fromJson({
            'key': 'online',
            'remoteUrl': 'https://example.invalid/page',
          }),
        );
        await emit(tester, 'loadingStateChanged', 1);
        await emit(tester, 'onLoadError', code);
        await emit(tester, 'loadingStateChanged', 2);
        expect(find.text('HTML 源无法显示'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });
    }

    testWidgets('F2 loadUrl成功只是提交，原生完成前仍等待', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: WebHomePage(
            state: state,
            source: WebHomeSource.fromJson({
              'key': 'online',
              'remoteUrl': 'https://example.invalid/page',
            }),
          ),
        ),
      );
      await tester.pump();
      expect(calls.any((call) => call.method == 'loadUrl'), isTrue);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await emit(tester, 'loadingStateChanged', 2);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
    testWidgets('F2 原生loading到completed显示等待并完成', (tester) async {
      await open(
        tester,
        WebHomeSource.fromJson({
          'key': 'online',
          'remoteUrl': 'https://example.invalid/page',
        }),
      );
      await emit(tester, 'loadingStateChanged', 1);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await emit(tester, 'loadingStateChanged', 2);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    for (final stage in [
      'setVirtualHostNameMapping',
      'addScriptToExecuteOnDocumentCreated',
    ]) {
      testWidgets('F3 延迟 $stage 后卸载不再订阅或导航', (tester) async {
        final gate = Completer<void>();
        late Completer<void> disposed;
        await tester.runAsync(() async {
          disposed = Completer<void>();
        });
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(plugin, (call) async {
              calls.add(call);
              if (call.method == 'initialize') return {'textureId': 71};
              if (call.method == 'dispose') disposed.complete();
              return null;
            });
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(controller, (call) async {
              if (call.method != 'setSize') calls.add(call);
              if (call.method == stage) await gate.future;
              if (call.method == 'addScriptToExecuteOnDocumentCreated') {
                return 'bridge';
              }
              return null;
            });
        await tester.pumpWidget(
          MaterialApp(
            home: WebHomePage(state: state, source: localSource('local')),
          ),
        );
        await tester.pump();
        expect(calls.any((call) => call.method == stage), isTrue);
        await tester.pumpWidget(const SizedBox());
        gate.complete();
        await tester.pump();
        await tester.pump();
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => disposed.future.timeout(const Duration(seconds: 3)),
        );
        expect(calls.where((call) => call.method == 'loadUrl'), isEmpty);
        expect(calls.where((call) => call.method == 'dispose').length, 1);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('F4 初始化未完成时刷新和开发者工具禁用', (tester) async {
      final gate = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(plugin, (call) async {
            calls.add(call);
            if (call.method == 'initialize') {
              await gate.future;
              return {'textureId': 71};
            }
            return null;
          });
      await tester.pumpWidget(
        MaterialApp(
          home: WebHomePage(state: state, source: localSource('local')),
        ),
      );
      final reload = find.byKey(const ValueKey('webhome-reload'));
      final devtools = find.byKey(const ValueKey('webhome-devtools'));
      expect(tester.widget<IconButton>(reload).onPressed, isNull);
      expect(tester.widget<IconButton>(devtools).onPressed, isNull);
      await tester.tap(reload);
      await tester.tap(devtools);
      expect(
        calls.where((call) => ['reload', 'openDevTools'].contains(call.method)),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
      gate.complete();
      await tester.pump();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('F4 已初始化的工具Future失败进入错误反馈', (tester) async {
      await open(
        tester,
        WebHomeSource.fromJson({
          'key': 'online',
          'remoteUrl': 'https://example.invalid/page',
        }),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(controller, (call) async {
            if (call.method == 'openDevTools') {
              throw PlatformException(code: 'devtools_failed');
            }
            return null;
          });
      await tester.tap(find.byKey(const ValueKey('webhome-devtools')));
      await tester.pump();
      expect(find.text('HTML 源无法显示'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
    testWidgets('在线只 loadUrl 原网址，桥在加载前且不映射本地目录', (tester) async {
      final source = WebHomeSource.fromJson({
        'key': 'online',
        'name': '在线页面',
        'remoteUrl': 'https://example.invalid/page?q=1#home',
      });
      await open(tester, source);
      expect(calls.map((call) => call.method), [
        'initialize',
        'addScriptToExecuteOnDocumentCreated',
        'loadUrl',
      ]);
      expect(calls[1].arguments, webHomeBridgeScript);
      expect(calls.last.arguments, 'https://example.invalid/page?q=1#home');
      expect(find.text('HTML 源无法显示'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('旧 HTML 入口沿用虚拟映射，桥在加载前', (tester) async {
      final source = WebHomeSource.fromJson({
        'key': 'legacy',
        'name': '旧页面',
        'entry': 'old.html',
      });
      await open(tester, source);
      expect(calls.map((call) => call.method), [
        'initialize',
        'setVirtualHostNameMapping',
        'addScriptToExecuteOnDocumentCreated',
        'loadUrl',
      ]);
      expect((calls[1].arguments as List).take(2), [
        'webhome.local',
        p.join(temp.path, 'config', 'webhome', 'legacy'),
      ]);
      expect(calls[2].arguments, webHomeBridgeScript);
      expect(calls.last.arguments, 'https://webhome.local/old.html');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });

    testWidgets('加载失败后重试复用已初始化控制器和桥订阅', (tester) async {
      var attempts = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(controller, (call) async {
            if (call.method != 'setSize') calls.add(call);
            if (call.method == 'addScriptToExecuteOnDocumentCreated') {
              return 'bridge';
            }
            if (call.method == 'loadUrl' && attempts++ == 0) {
              throw PlatformException(
                code: 'load_failed',
                message: 'temporary',
              );
            }
            return null;
          });
      await open(
        tester,
        WebHomeSource.fromJson({
          'key': 'online',
          'remoteUrl': 'https://example.invalid/page',
        }),
      );
      expect(find.text('HTML 源无法显示'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('webhome-retry')));
      await tester.pump();
      await emit(tester, 'loadingStateChanged', 2);
      await tester.pumpAndSettle();
      expect(find.text('HTML 源无法显示'), findsNothing);
      expect(calls.where((call) => call.method == 'initialize').length, 1);
      expect(
        calls
            .where(
              (call) => call.method == 'addScriptToExecuteOnDocumentCreated',
            )
            .length,
        1,
      );
      expect(calls.where((call) => call.method == 'loadUrl').length, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
    testWidgets('缺少 WebView2 显示报错，不转离线或打开外部浏览器', (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(plugin, (call) async {
            calls.add(call);
            throw PlatformException(
              code: 'webview2_not_found',
              message: 'WebView2 runtime is missing',
            );
          });
      final source = WebHomeSource.fromJson({
        'key': 'online',
        'remoteUrl': 'https://example.invalid/page',
      });
      await open(tester, source);
      expect(find.text('HTML 源无法显示'), findsOneWidget);
      expect(
        find.textContaining('请安装 Microsoft Edge WebView2 Runtime'),
        findsOneWidget,
      );
      expect(calls.map((call) => call.method), ['initialize']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  test('HTML 导入拒绝覆盖未登记的既有目录', () async {
    final candidate = await scanFile('page.html', '<html>new</html>');
    final marker = File(p.join(store.directoryFor(candidate.key), 'keep.txt'));
    marker.parent.createSync(recursive: true);
    marker.writeAsStringSync('original');
    final result = await importer.importSelected([candidate]);
    expect(result.rejectedCount, 1);
    expect(marker.readAsStringSync(), 'original');
    expect(store.list(), isEmpty);
  });
}
