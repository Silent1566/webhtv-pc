import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/local_spider_scanner.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/local_sources_page.dart';

import 'local_source_sites_test.dart'
    show deleteTempWhenReleased, tempPaths, writeManifest;

class _PausedScanState extends AppState {
  _PausedScanState(Directory temp)
    : super(paths: tempPaths(temp), log: LogService());
  final release = Completer<void>();
  int scans = 0;

  @override
  Future<LocalScanReport> scanLocalSources(String folder) async {
    scans++;
    await release.future;
    return super.scanLocalSources(folder);
  }
}

void main() {
  late Directory temp;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('webhtv_boundaries_');
    LogService.logDirectoryOverride = p.join(temp.path, 'logs');
  });
  tearDown(() => deleteTempWhenReleased(temp));

  testWidgets('纯本地源浏览不被主配置门禁拦截', (tester) async {
    final state = AppState(paths: tempPaths(temp), log: LogService());
    addTearDown(state.dispose);
    await tester.runAsync(() async {
      writeManifest(
        Directory(p.join(state.spiderRoot, 'local', 'only')),
        'only',
      );
      await state.reloadLocalSources();
    });
    expect(state.hasConfig, isTrue);
    await tester.pumpWidget(MaterialApp(home: BrowsePage(state: state)));
    expect(find.text('还没有导入配置'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('纯本地源重启装配真实站点服务，不持久化合成配置', () async {
    final state = AppState(paths: tempPaths(temp), log: LogService());
    addTearDown(state.dispose);
    writeManifest(Directory(p.join(state.spiderRoot, 'local', 'only')), 'only');
    await state.bootstrap();
    expect(state.siteItems.map((item) => item.site.key), contains('only'));
    expect(state.siteService, isNotNull);
    expect(state.hasConfig, isTrue);
    expect(state.savedConfigs, isEmpty);
  });

  test('仅HTML与全部隐藏普通站点不误选爬虫首页，显式loadHome也不报假失败', () async {
    final state = AppState(paths: tempPaths(temp), log: LogService());
    addTearDown(state.dispose);
    await state.bootstrap();
    await state.addOnlineWebHome('https://example.com/index.html');
    expect(state.selectedSite, isNull);
    expect(
      await state.importConfig(
        jsonEncode({
          'sites': [
            {
              'key': 'hidden',
              'name': '隐藏源',
              'type': 1,
              'api': 'https://example.com/api',
              'hide': 1,
            },
          ],
        }),
      ),
      isTrue,
    );
    expect(state.selectedSite, isNull);
    final html = state.siteItems.single.site;
    await state.loadHome(html);
    expect(state.homeResult, isNull);
    expect(state.lastError, isNull);
  });

  test('混合只读资源拒绝删除前不得先删普通兄弟', () async {
    final state = AppState(paths: tempPaths(temp), log: LogService());
    addTearDown(state.dispose);
    final dir = Directory(p.join(state.spiderRoot, 'local', 'readonly'));
    writeManifest(dir, 'readonly');
    final locked = File(p.join(dir.path, 'manifest.json'));
    final ordinary = File(p.join(dir.path, 'last.txt'))
      ..writeAsStringSync('keep');
    await state.reloadLocalSources();
    final before = {
      for (final file in dir.listSync().whereType<File>())
        file.path: file.readAsBytesSync(),
    };
    final setAttributes = ffi.DynamicLibrary.open('kernel32.dll')
        .lookupFunction<
          ffi.Int32 Function(ffi.Pointer<Utf16>, ffi.Uint32),
          int Function(ffi.Pointer<Utf16>, int)
        >('SetFileAttributesW');
    final native = locked.path.toNativeUtf16(allocator: calloc);
    try {
      expect(setAttributes(native, 1), isNot(0));
      expect(await state.removeLocalSpider('readonly'), isFalse);
      expect(ordinary.existsSync(), isTrue);
      for (final entry in before.entries) {
        expect(File(entry.key).existsSync(), isTrue);
        expect(File(entry.key).readAsBytesSync(), entry.value);
      }
    } finally {
      setAttributes(native, 0x80);
      calloc.free(native);
    }
  });

  testWidgets('忙碌时路径框回车不重入扫描也不清掉忙碌状态', (tester) async {
    final state = _PausedScanState(temp);
    addTearDown(state.dispose);
    final root = Directory(p.join(temp.path, 'scan'))..createSync();
    File(p.join(root.path, 'a.py')).writeAsStringSync('class Spider: pass');
    await tester.pumpWidget(MaterialApp(home: LocalSourcesPage(state: state)));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('local-sources-folder'));
    await tester.enterText(field, root.path);
    await tester.tap(find.byKey(const ValueKey('local-sources-scan')));
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(state.scans, 1);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('local-sources-scan')),
          )
          .onPressed,
      isNull,
    );
    state.release.complete();
    final scanButton = find.byKey(const ValueKey('local-sources-scan'));
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
      if (tester.widget<FilledButton>(scanButton).onPressed != null) break;
    }
    expect(tester.widget<FilledButton>(scanButton).onPressed, isNotNull);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  test('并发跨形态同key导入至多成功一次，不留双记录', () async {
    final state = AppState(paths: tempPaths(temp), log: LogService());
    addTearDown(state.dispose);
    final htmlRoot = Directory(p.join(temp.path, 'html', 'same'))
      ..createSync(recursive: true);
    File(p.join(htmlRoot.path, 'index.html'))
        .writeAsStringSync('<html>same</html>');
    final pyRoot = Directory(p.join(temp.path, 'py'))..createSync();
    File(p.join(pyRoot.path, 'same.py'))
        .writeAsStringSync('class Spider: pass');
    final html = (await state.scanLocalSources(htmlRoot.path)).candidates;
    final py = (await state.scanLocalSources(pyRoot.path)).candidates;
    final outcomes = await Future.wait([
      state.importLocalSources(html),
      state.importLocalSources(py),
    ]);
    expect(
      outcomes.fold<int>(0, (sum, result) => sum + result.importedCount),
      1,
    );
    expect(state.localSourceConflicts, isEmpty);
    expect(
      state.siteItems.where((item) => item.site.key == 'same'),
      hasLength(1),
    );
  });
}
