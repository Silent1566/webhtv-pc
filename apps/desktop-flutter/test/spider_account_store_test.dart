/// 全局账号存储：严格 JSON、原子写、跨实例可见性与隐私边界。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/spider_account.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/spider_account_store.dart';
import 'package:webhtv_pc/state/app_state.dart';

/// 可脚本化的 HTTP 客户端：测试不发真实网络。
class _ScriptedClient extends http.BaseClient {
  _ScriptedClient(this.onSend);

  final Future<http.StreamedResponse> Function(http.BaseRequest request) onSend;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      onSend(request);
}

Map<String, Object?> _payload({required bool category}) => {
  'class': [
    {'type_id': '1', 'type_name': '电影'},
  ],
  'list': [
    {'vod_id': category ? 'c1' : 'h1', 'vod_name': category ? '分类片' : '首页片'},
  ],
  'page': 1,
  'pagecount': 1,
  'total': 1,
};

void main() {
  late Directory root;
  late String path;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('webhtv-account-store');
    path = p.join(root.path, 'spiders', 'accounts.json');
  });

  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  File accountFile() => File(path);

  Map<String, Object?> readJson() =>
      jsonDecode(accountFile().readAsStringSync()) as Map<String, Object?>;

  List<String> siblingNames() => Directory(p.dirname(path))
      .listSync()
      .map((entity) => p.basename(entity.path))
      .toList();

  test('文件/键缺失时返回 null 且不写文件', () async {
    final store = SpiderAccountStore(path: path);
    expect(await store.read(SpiderAccountProvider.quark), isNull);
    expect(await store.read(SpiderAccountProvider.baidu), isNull);
    expect(accountFile().existsSync(), isFalse);
    expect(Directory(p.dirname(path)).existsSync(), isFalse);
  });

  test('保存后可跨实例读到规范化值，并保留另一个 provider', () async {
    final first = SpiderAccountStore(path: path);
    final second = SpiderAccountStore(path: path);
    await first.save(SpiderAccountProvider.quark, '  Cookie: SESSDATA=abc  ');
    expect(await second.read(SpiderAccountProvider.quark), 'SESSDATA=abc');

    await second.save(SpiderAccountProvider.baidu, 'BDUSS=xyz');
    expect(await first.read(SpiderAccountProvider.quark), 'SESSDATA=abc');
    expect(await first.read(SpiderAccountProvider.baidu), 'BDUSS=xyz');

    final json = readJson();
    expect(json['version'], 1);
    expect(json['values'], {
      'Wex_quark_cookie': 'SESSDATA=abc',
      'Wex_baidu_cookie': 'BDUSS=xyz',
    });
  });

  test('清理写入空墓碑而不是删除键，另一 provider 保留', () async {
    final store = SpiderAccountStore(path: path);
    await store.save(SpiderAccountProvider.quark, 'SESSDATA=abc');
    await store.save(SpiderAccountProvider.baidu, 'BDUSS=xyz');
    await store.clear(SpiderAccountProvider.baidu);

    expect(await store.read(SpiderAccountProvider.baidu), '');
    expect(await store.read(SpiderAccountProvider.quark), 'SESSDATA=abc');
    expect(accountFile().existsSync(), isTrue);
    final values = readJson()['values'] as Map<String, Object?>;
    expect(values.containsKey('Wex_baidu_cookie'), isTrue);
    expect(values['Wex_baidu_cookie'], '');
  });

  test('空值/纯 Cookie 前缀不作为保存内容', () async {
    final store = SpiderAccountStore(path: path);
    for (final invalid in ['', '   ', 'Cookie:', '  cookie:   ']) {
      await expectLater(
        store.save(SpiderAccountProvider.quark, invalid),
        throwsA(isA<SpiderAccountStoreException>()),
      );
    }
    expect(accountFile().existsSync(), isFalse);
  });

  test('拒绝内嵌 CR/LF 与超长值，错误信息不含秘密值', () async {
    final store = SpiderAccountStore(path: path);
    await expectLater(
      store.save(SpiderAccountProvider.quark, 'a\r\nb'),
      throwsA(isA<SpiderAccountStoreException>()),
    );
    await expectLater(
      store.save(SpiderAccountProvider.quark, 'a\nb'),
      throwsA(isA<SpiderAccountStoreException>()),
    );

    final secret = 'S' * (SpiderAccountStore.maxValueBytes + 1);
    var message = '';
    try {
      await store.save(SpiderAccountProvider.quark, secret);
      fail('超长值必须被拒绝');
    } on SpiderAccountStoreException catch (error) {
      message = error.message;
    }
    expect(message.contains('SSSS'), isFalse);
    expect(message.contains('Wex_quark_cookie'), isFalse);
  });

  test('超大文件在分配前被拒绝，错误不回显文件内容', () async {
    Directory(p.dirname(path)).createSync(recursive: true);
    final handle = accountFile().openSync(mode: FileMode.write);
    try {
      final chunk = utf8.encode('SECRET-'.padRight(8192, 'x'));
      for (var i = 0; i < 40; i++) {
        handle.writeFromSync(chunk);
      }
    } finally {
      handle.closeSync();
    }
    expect(
      accountFile().lengthSync(),
      greaterThan(SpiderAccountStore.maxDocumentBytes),
    );
    var message = '';
    try {
      await SpiderAccountStore(path: path).read(SpiderAccountProvider.quark);
      fail('超大文件必须被拒绝');
    } on SpiderAccountStoreException catch (error) {
      message = error.message;
    }
    expect(message, '账号文件超过大小上限');
    expect(message.contains('SECRET'), isFalse);
    // 只读失败路径不得创建锁文件或 staging 临时文件。
    expect(siblingNames(), ['accounts.json']);
  });

  test('远超上限的文件按 stat 拒绝，不整份分配内存', () async {
    Directory(p.dirname(path)).createSync(recursive: true);
    const oversizedBytes = 160 * 1024 * 1024;
    final handle = accountFile().openSync(mode: FileMode.write);
    try {
      // 只扩展长度，不写入内容：若实现先 readAsBytes，本次调用会真的分配 160 MiB。
      handle.truncateSync(oversizedBytes);
    } finally {
      handle.closeSync();
    }
    expect(accountFile().lengthSync(), oversizedBytes);

    final rssBefore = ProcessInfo.currentRss;
    final stopwatch = Stopwatch()..start();
    var message = '';
    await expectLater(
      SpiderAccountStore(path: path)
          .read(SpiderAccountProvider.quark)
          .catchError((Object error) {
            if (error is SpiderAccountStoreException) message = error.message;
            throw error;
          }),
      throwsA(isA<SpiderAccountStoreException>()),
    );
    stopwatch.stop();
    final rssGrowth = ProcessInfo.currentRss - rssBefore;

    expect(message, '账号文件超过大小上限');
    expect(
      rssGrowth,
      lessThan(64 * 1024 * 1024),
      reason: '超过上限必须在 stat/流式读取阶段中止，不能先分配整份文件',
    );
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 10)));
    expect(siblingNames(), ['accounts.json']);
  });

  test('文档未超限但单值超 32KiB 仍被拒绝', () async {
    Directory(p.dirname(path)).createSync(recursive: true);
    accountFile().writeAsStringSync(
      jsonEncode({
        'version': 1,
        'values': {'Wex_quark_cookie': 'y' * (SpiderAccountStore.maxValueBytes + 1)},
      }),
    );
    expect(
      accountFile().lengthSync(),
      lessThan(SpiderAccountStore.maxDocumentBytes),
    );
    await expectLater(
      SpiderAccountStore(path: path).read(SpiderAccountProvider.quark),
      throwsA(
        isA<SpiderAccountStoreException>().having(
          (error) => error.message,
          'message',
          '账号值类型或大小不符',
        ),
      ),
    );
  });

  test('读取拒绝 schema 不符、未知键与超限文档，且不泄漏值', () async {
    Directory(p.dirname(path)).createSync(recursive: true);
    accountFile().writeAsStringSync(
      jsonEncode({
        'version': 1,
        'values': {'Wex_quark_cookie': 'SECRET-QUARK', 'unknown': 'x'},
      }),
    );
    await expectLater(
      SpiderAccountStore(path: path).read(SpiderAccountProvider.quark),
      throwsA(isA<SpiderAccountStoreException>()),
    );

    accountFile().writeAsStringSync(
      jsonEncode({
        'version': 2,
        'values': {'Wex_quark_cookie': 'SECRET-QUARK'},
      }),
    );
    await expectLater(
      SpiderAccountStore(path: path).read(SpiderAccountProvider.quark),
      throwsA(isA<SpiderAccountStoreException>()),
    );

    accountFile().writeAsStringSync(
      jsonEncode({
        'version': 1,
        'values': {'Wex_quark_cookie': 42},
      }),
    );
    await expectLater(
      SpiderAccountStore(path: path).read(SpiderAccountProvider.quark),
      throwsA(isA<SpiderAccountStoreException>()),
    );

    final big = jsonEncode({
      'version': 1,
      'values': {'Wex_quark_cookie': 'x' * (SpiderAccountStore.maxDocumentBytes)},
    });
    accountFile().writeAsStringSync(big);
    await expectLater(
      SpiderAccountStore(path: path).read(SpiderAccountProvider.quark),
      throwsA(isA<SpiderAccountStoreException>()),
    );

    accountFile().writeAsBytesSync([0xff, 0xfe, 0xfd]);
    var message = '';
    try {
      await SpiderAccountStore(path: path).read(SpiderAccountProvider.quark);
      fail('非法 UTF-8 必须被拒绝');
    } on SpiderAccountStoreException catch (error) {
      message = error.message;
    }
    expect(message.contains('SECRET'), isFalse);
    expect(message.contains('xff'), isFalse);
  });

  test('脏文件不会被 save 静默覆盖（失败时文件保持原样）', () async {
    Directory(p.dirname(path)).createSync(recursive: true);
    const dirty = '{"version":2,"values":{}}';
    accountFile().writeAsStringSync(dirty);
    await expectLater(
      SpiderAccountStore(path: path).save(SpiderAccountProvider.quark, 'SESS=1'),
      throwsA(isA<SpiderAccountStoreException>()),
    );
    expect(accountFile().readAsStringSync(), dirty);
  });

  test('并发写入两个 provider 都保留且不留下临时文件', () async {
    final a = SpiderAccountStore(path: path);
    final b = SpiderAccountStore(path: path);
    final c = SpiderAccountStore(path: path);
    await Future.wait([
      a.save(SpiderAccountProvider.quark, 'SESSDATA=abc'),
      b.save(SpiderAccountProvider.baidu, 'BDUSS=xyz'),
      c.clear(SpiderAccountProvider.quark),
      a.save(SpiderAccountProvider.quark, 'SESSDATA=abc2'),
    ]);

    expect(await a.read(SpiderAccountProvider.quark), 'SESSDATA=abc2');
    expect(await b.read(SpiderAccountProvider.baidu), 'BDUSS=xyz');
    final leftovers = siblingNames().where(
      (name) => name != 'accounts.json' && name != 'accounts.json.lock',
    );
    expect(leftovers, isEmpty);
  });

  test('已存在实例读取最新一次写入的值（无缓存）', () async {
    final writer = SpiderAccountStore(path: path);
    final reader = SpiderAccountStore(path: path);
    expect(await reader.read(SpiderAccountProvider.quark), isNull);
    await writer.save(SpiderAccountProvider.quark, 'SESSDATA=old');
    expect(await reader.read(SpiderAccountProvider.quark), 'SESSDATA=old');
    await writer.save(SpiderAccountProvider.quark, 'SESSDATA=new');
    expect(await reader.read(SpiderAccountProvider.quark), 'SESSDATA=new');
  });

  test('清空后再次保存恢复正常值', () async {
    final store = SpiderAccountStore(path: path);
    await store.save(SpiderAccountProvider.baidu, 'BDUSS=1');
    await store.clear(SpiderAccountProvider.baidu);
    expect(await store.read(SpiderAccountProvider.baidu), '');
    await store.save(SpiderAccountProvider.baidu, 'BDUSS=2');
    expect(await store.read(SpiderAccountProvider.baidu), 'BDUSS=2');
  });


  group('AppState 全局账号接线', () {
    late Directory temp;
    late AppState state;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('webhtv-account-state');
      state = AppState(
        paths: AppPaths.resolve(
          overrides: {
            'config': p.join(temp.path, 'config'),
            'data': p.join(temp.path, 'data'),
            'cache': p.join(temp.path, 'cache'),
            'state': p.join(temp.path, 'logs'),
          },
        ),
        log: LogService(),
      );
    });

    tearDown(() {
      state.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('spiderAccounts 指向 <configDir>/spiders/accounts.json', () {
      expect(
        state.spiderAccounts.path,
        p.normalize(
          p.absolute(p.join(temp.path, 'config', 'spiders', 'accounts.json')),
        ),
      );
    });

    test('无选中分类时刷新不改上下文、不进入详情', () async {
      final siteBefore = state.selectedSite;
      final typeBefore = state.selectedTypeId;
      final vodBefore = state.selectedVod;
      final detailIdBefore = state.detailRequestVodId;
      final detailBefore = state.detailResult;
      await state.refreshSpiderAccountCategory();
      expect(state.selectedSite, same(siteBefore));
      expect(state.selectedTypeId, typeBefore);
      expect(state.selectedVod, same(vodBefore));
      expect(state.detailResult, same(detailBefore));
      expect(state.detailRequestVodId, detailIdBefore);
      expect(state.categoryResult, isNull);
    });

    test('经 AppState 保存的值可被另一实例读到', () async {
      await state.spiderAccounts.save(
        SpiderAccountProvider.quark,
        'Cookie: SESS=1',
      );
      final other = SpiderAccountStore(path: state.spiderAccounts.path);
      expect(await other.read(SpiderAccountProvider.quark), 'SESS=1');
      expect(
        File(state.spiderAccounts.path).existsSync(),
        isTrue,
      );
    });
  });


  group('AppState 账号刷新失败', () {
    late Directory temp;
    late AppState refreshState;
    late bool failCategory;
    Completer<void>? categoryGate;
    Completer<void>? categoryStarted;

    Future<void> boot() async {
      temp = await Directory.systemTemp.createTemp('webhtv-account-refresh');
      failCategory = false;
      categoryGate = null;
      categoryStarted = null;
      var categoryCount = 0;
      final client = _ScriptedClient((request) async {
        final uri = request.url;
        final isCategory = uri.queryParameters.containsKey('t');
        if (!isCategory) {
          return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode(_payload(category: false)))),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        categoryCount++;
        final started = categoryStarted;
        if (started != null && !started.isCompleted) started.complete();
        final gate = categoryGate;
        if (gate != null) await gate.future;
        if (failCategory) {
          return http.StreamedResponse(
            Stream.value(utf8.encode('{"error":"分类不可用"}')),
            500,
          );
        }
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(jsonEncode(_payload(category: categoryCount > 0))),
          ),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      refreshState = AppState(
        paths: AppPaths.resolve(
          overrides: {
            'config': p.join(temp.path, 'config'),
            'data': p.join(temp.path, 'data'),
            'cache': p.join(temp.path, 'cache'),
            'state': p.join(temp.path, 'logs'),
          },
        ),
        log: LogService(),
        httpClient: client,
      );
      await refreshState.bootstrap();
      await refreshState.importConfig(
        jsonEncode({
          'name': '账号刷新测试配置',
          'sites': [
            {
              'key': 'account_site_a',
              'name': '账号源 A',
              'type': 4,
              'api': 'http://127.0.0.1:19979/a/vod?key=account_site_a',
            },
            {
              'key': 'account_site_b',
              'name': '账号源 B',
              'type': 4,
              'api': 'http://127.0.0.1:19979/b/vod?key=account_site_b',
            },
          ],
        }),
        displayName: '账号刷新测试配置',
      );
      expect(refreshState.selectedSite?.key, 'account_site_a');
    }

    tearDown(() {
      refreshState.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('分类刷新失败对调用方是真失败，且不改源/配置/详情', () async {
      await boot();
      await refreshState.loadCategory('1');
      expect(refreshState.contentPhase, LoadPhase.ready);

      failCategory = true;
      final configBefore = refreshState.config;
      final siteBefore = refreshState.selectedSite;
      final detailIdBefore = refreshState.detailRequestVodId;
      final detailBefore = refreshState.detailResult;
      final vodBefore = refreshState.selectedVod;

      Object? thrown;
      try {
        await refreshState.refreshSpiderAccountCategory();
        fail('分类刷新失败必须对调用方是真失败');
      } on SpiderAccountRefreshException catch (error) {
        thrown = error;
      }
      expect(thrown, isA<SpiderAccountRefreshException>());
      final error = thrown as SpiderAccountRefreshException;
      // 固定脱敏文案：不带站点 key、Cookie、响应体或客户端错误文本。
      expect(error.message, SpiderAccountRefreshException.fixedMessage);
      expect(
        error.toString(),
        'SpiderAccountRefreshException: ${SpiderAccountRefreshException.fixedMessage}',
      );
      expect(error.toString().contains('account_site_a'), isFalse);
      expect(error.toString().contains('分类不可用'), isFalse);
      expect(error.toString().contains('Wex_quark_cookie'), isFalse);

      expect(refreshState.config, same(configBefore));
      expect(refreshState.selectedSite, same(siteBefore));
      expect(refreshState.selectedTypeId, '1');
      expect(refreshState.detailRequestVodId, detailIdBefore);
      expect(refreshState.detailResult, same(detailBefore));
      expect(refreshState.selectedVod, same(vodBefore));
      // 普通分类页的错误横幅语义保持不变：失败仍写入 contentPhase。
      expect(refreshState.contentPhase, LoadPhase.failed);
    });

    test('刷新期间切换站点：迟到失败静默返回，不覆盖新上下文', () async {
      await boot();
      await refreshState.loadCategory('1');
      expect(refreshState.selectedTypeId, '1');

      failCategory = true;
      categoryGate = Completer<void>();
      categoryStarted = Completer<void>();
      final refresh = refreshState.refreshSpiderAccountCategory();
      await categoryStarted!.future.timeout(const Duration(seconds: 5));

      final other = refreshState.config!.sites[1];
      await refreshState.selectSite(other);
      categoryGate!.complete();

      await refresh; // 过期刷新不得把旧失败抛给新页面
      expect(refreshState.selectedSite?.key, other.key);
      expect(refreshState.selectedTypeId, isNull);
    });
  });

  test('保存的文档为严格 UTF-8 JSON 且以 version 1 开头', () async {
    final store = SpiderAccountStore(path: path);
    await store.save(SpiderAccountProvider.quark, 'SESS=1');
    final bytes = accountFile().readAsBytesSync();
    final text = utf8.decode(bytes);
    expect(text.startsWith('{'), isTrue);
    final json = jsonDecode(text) as Map<String, Object?>;
    expect(json.keys.toSet(), {'version', 'values'});
    expect(json['version'], 1);
    // 锁文件与账号文件同目录是有意保留的（进程间互斥需要稳定 inode）。
    expect(siblingNames(), contains('accounts.json.lock'));
  });
}
