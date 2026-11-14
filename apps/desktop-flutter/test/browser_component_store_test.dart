/// 浏览器内核组件库（`BrowserComponentStore`）的安装语义测试。
///
/// 只覆盖副作用边界，不做 UI：目录/zip 安装、可执行文件发现、坏包拒收、
/// 原子性（不留半装目录）、卸载范围防护、同版本重装。
///
/// 全部用真实的 shell 脚本当「浏览器」：`probeChromiumBrowser` 与
/// `chromiumVersionOf` 走的是真子进程，用假脚本才能测到真实判定路径。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/sniff/sniff_types.dart';
import 'package:webhtv_pc/services/browser_component_store.dart';

void main() {
  late Directory temp;
  late String root;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('browser-component-');
    root = p.join(temp.path, 'components');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  /// 造一个能跑 `--version` 的假浏览器；[exitCode] 非 0 用来模拟坏包。
  File fakeBrowser(String name, {int exitCode = 0, String version = 'Chromium 154.0.8037.0'}) {
    final file = File(p.join(temp.path, name))
      ..writeAsStringSync('#!/bin/sh\necho "$version"\nexit $exitCode\n');
    if (!Platform.isWindows) {
      expect(Process.runSync('chmod', ['755', file.path]).exitCode, 0);
    }
    return file;
  }

  test('目录安装：复制到组件库、写清单、可列出与校验、可卸载', () async {
    if (Platform.isWindows) {
      markTestSkipped('用 POSIX 脚本模拟浏览器，Windows 不适用');
      return;
    }
    final source = Directory(p.join(temp.path, 'chrome-linux64'))..createSync();
    final browser = fakeBrowser('chrome-linux64/chrome');
    File(p.join(source.path, 'icudtl.dat')).writeAsStringSync('data');

    final store = BrowserComponentStore(rootDirectory: root);
    final component = await store.installFromDirectory(source);

    expect(component.id, 'chromium-154.0.8037.0');
    expect(component.label, 'Chromium');
    expect(component.version, '154.0.8037.0');
    expect(File(component.executablePath).existsSync(), isTrue);
    expect(File(p.join(component.directory, 'icudtl.dat')).existsSync(), isTrue);
    expect(File(p.join(component.directory, 'component.json')).existsSync(), isTrue);

    final installed = await store.installed();
    expect(installed.single.id, component.id);
    expect(await store.executablePaths(), [component.executablePath]);
    expect(await store.validate(component), isNull);
    expect(browser.existsSync(), isTrue, reason: '安装是复制，不动来源');

    await store.uninstall(component);
    expect(Directory(component.directory).existsSync(), isFalse);
    expect(await store.installed(), isEmpty);
  });

  test('坏包（--version 退出非 0）被拒收，且不留下半装目录', () async {
    if (Platform.isWindows) {
      markTestSkipped('用 POSIX 脚本模拟浏览器，Windows 不适用');
      return;
    }
    final source = Directory(p.join(temp.path, 'broken'))..createSync();
    fakeBrowser('broken/chrome', exitCode: 1);

    final store = BrowserComponentStore(rootDirectory: root);
    await expectLater(
      store.installFromDirectory(source),
      throwsA(isA<SniffException>().having((e) => e.message, 'message', contains('跑不起来'))),
    );
    final leftovers = Directory(root).existsSync()
        ? Directory(root)
            .listSync()
            .whereType<Directory>()
            .where((dir) => !p.basename(dir.path).startsWith('.'))
            .toList()
        : <Directory>[];
    expect(leftovers, isEmpty, reason: '失败必须回滚，不能留半装目录');
  });

  test('包里没有可执行文件时给出可诊断错误', () async {
    final source = Directory(p.join(temp.path, 'not-a-browser'))..createSync();
    File(p.join(source.path, 'readme.txt')).writeAsStringSync('no browser here');

    final store = BrowserComponentStore(rootDirectory: root);
    await expectLater(
      store.installFromDirectory(source),
      throwsA(
        isA<SniffException>().having(
          (error) => error.message,
          'message',
          contains('没有找到 Chromium 内核可执行文件'),
        ),
      ),
    );
  });

  test('zip 安装：解压后找到嵌套可执行文件；路径穿越条目被忽略', () async {
    if (Platform.isWindows) {
      markTestSkipped('用 POSIX 脚本模拟浏览器，Windows 不适用');
      return;
    }
    final script = utf8.encode('#!/bin/sh\necho "Google Chrome 154.0.8037.0"\nexit 0\n');
    final archive = Archive()
      ..addFile(ArchiveFile('chrome-win64/chrome', script.length, script))
      ..addFile(ArchiveFile('../escape.txt', 4, utf8.encode('evil')));
    final zip = File(p.join(temp.path, 'chrome.zip'))
      ..writeAsBytesSync(ZipEncoder().encodeBytes(archive));

    final store = BrowserComponentStore(rootDirectory: root);
    final component = await store.installFromZip(zip);

    expect(component.label, 'Google Chrome');
    expect(component.version, '154.0.8037.0');
    expect(File(component.executablePath).existsSync(), isTrue);
    expect(File(p.join(temp.path, 'escape.txt')).existsSync(), isFalse);
  });

  test('同版本重装是覆盖，不产生第二个目录', () async {
    if (Platform.isWindows) {
      markTestSkipped('用 POSIX 脚本模拟浏览器，Windows 不适用');
      return;
    }
    final source = Directory(p.join(temp.path, 'pack'))..createSync();
    fakeBrowser('pack/chrome');

    final store = BrowserComponentStore(rootDirectory: root);
    final first = await store.installFromDirectory(source);
    final second = await store.installFromDirectory(source);

    expect(second.id, first.id);
    expect(second.directory, first.directory);
    expect((await store.installed()).length, 1);
  });

  test('卸载拒绝组件库之外的目录', () async {
    final outside = Directory(p.join(temp.path, 'outside'))..createSync();
    final store = BrowserComponentStore(rootDirectory: root);
    final fake = BrowserComponent(
      id: 'x',
      label: 'x',
      version: '1',
      executablePath: p.join(outside.path, 'chrome'),
      directory: outside.path,
    );
    await expectLater(
      store.uninstall(fake),
      throwsA(isA<SniffException>().having((e) => e.message, 'message', contains('拒绝卸载'))),
    );
    expect(outside.existsSync(), isTrue);
  });
}
