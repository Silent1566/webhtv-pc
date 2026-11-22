/// 启动后台增量刷新配置（用户反馈：每次启动应用应该自动刷新各个配置）。
///
/// ## 为什么要单开一个文件
///
/// 这批断言全部落在「状态层 + 存储层 + 真网络」：增量刷新要证明的是
/// **没变就不写库**、**远端失败时本地照旧可用**，打桩只能证明「调用过一次」。
///
/// ## 锁定的用户可见行为
///
/// 1. 内容真的变了才写库：更新时间只表达内容变化，检查时间另记一列；
/// 2. 第二轮拉到的内容与库里摘要一致 → 不写库、不改更新时间；
/// 3. 服务端给 ETag 时第二轮发条件请求，304 连解析都省掉；
/// 4. 远端失败时本地内容、站点数原样保留，只记检查失败（静默，不写全局错误位）；
/// 5. 猫源 / 桥接 / 粘贴 JSON 不参与启动刷新，本地文件源参与；
/// 6. 用户已经走进详情页时，当前配置的后台更新不打断页面。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/config_loader.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/state/app_state.dart';

import 'support/test_fixture_server.dart';

void main() {
  group('存储层：检查状态与内容摘要', () {
    test('保存即写内容摘要；检查只记时间与失败原因，不碰 updated_at', () {
      final database = AppDatabase.inMemory();
      addTearDown(database.dispose);
      final id = database.saveConfig(
        name: '源A',
        origin: 'https://example.test/a.json',
        json: const {
          'sites': [
            {
              'key': 'a',
              'name': 'A',
              'type': 0,
              'api': 'https://example.test/a/',
            },
          ],
        },
        siteCount: 1,
        liveCount: 0,
      );
      final before = database.listConfigs().single;
      expect(before.contentHash, isNotEmpty, reason: '保存时就该有摘要');
      expect(before.lastCheckedAt, isNull);
      expect(before.lastCheckError, isNull);

      database.markConfigChecked(id, error: 'HTTP 500');
      final failed = database.listConfigs().single;
      expect(failed.lastCheckError, 'HTTP 500');
      expect(failed.updatedAt, before.updatedAt, reason: '检查不是内容变化');
      expect(failed.lastCheckedAt, isNotNull);
      expect(failed.json, before.json);

      database.markConfigChecked(id);
      final ok = database.listConfigs().single;
      expect(ok.lastCheckError, isNull, reason: '检查成功要清掉上一轮的错误');
      expect(ok.contentHash, before.contentHash);
      expect(ok.updatedAt, before.updatedAt);
    });
  });

  group('导入层：条件请求', () {
    late HttpServer server;
    final seenIfNoneMatch = <String?>[];

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final inm = request.headers.value(HttpHeaders.ifNoneMatchHeader);
        seenIfNoneMatch.add(inm);
        if (inm == '"v1"') {
          request.response.statusCode = HttpStatus.notModified;
        } else {
          request.response.headers.set(HttpHeaders.etagHeader, '"v1"');
          request.response.write('{"sites":[]}');
        }
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('304 是一等结果：内容为空、校验值照样带回', () async {
      final loader = ConfigLoader();
      addTearDown(loader.close);
      final source = ConfigSource.parse(
        'http://127.0.0.1:${server.port}/config.json',
      );

      final first = await loader.fetch(source);
      expect(first.notModified, isFalse);
      expect(first.etag, '"v1"');

      final second = await loader.fetch(
        source,
        validators: ConfigValidators(etag: first.etag),
      );
      expect(second.notModified, isTrue, reason: '304 不能被当成下载错误');
      expect(second.text, isEmpty);
      expect(second.etag, '"v1"', reason: '304 也要能带回校验值做下一轮');
      expect(seenIfNoneMatch, [null, '"v1"']);
    });
  });

  group('状态层：启动后台刷新', () {
    late Directory tempDir;
    late TestFixtureServer server;
    late AppState state;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('webhtv-startup-refresh');
      server = await TestFixtureServer.start();
      state = AppState(
        paths: AppPaths.resolve(
          overrides: {
            'config': '${tempDir.path}/webhtv-pc',
            'data': '${tempDir.path}/webhtv-pc',
            'cache': '${tempDir.path}/webhtv-pc/cache',
            'state': '${tempDir.path}/webhtv-pc/logs',
          },
        ),
        log: LogService(),
      );
      await state.bootstrap();
    });

    tearDown(() async {
      state.dispose();
      await server.stop();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    String configUrl() => '${server.baseUrl}/api/type1/config.json';

    /// 直接落一条记录（不走网络）：内容刻意与来源不一致，好观察「刷新有没有真的
    /// 换来新内容」。
    int seedRecord({
      required String name,
      required String origin,
      int siteCount = 1,
      bool makeActive = false,
      String contentType = 'application/json',
      String sourceKey = '',
      String bridgeInterfaceKey = '',
    }) {
      final json = {
        'name': name,
        'sites': [
          {
            'key': 'seed-site',
            'name': '种子站点',
            'type': 1,
            'api': '${server.baseUrl}/api/type1/',
            'searchable': 1,
          },
        ],
      };
      return state.database!.saveConfig(
        name: name,
        origin: origin,
        json: json,
        siteCount: siteCount,
        liveCount: 0,
        makeActive: makeActive,
        contentType: contentType,
        sourceKey: sourceKey,
        bridgeInterfaceKey: bridgeInterfaceKey,
      );
    }

    test('内容变了：原地更新同一条记录，摘要与检查时间一起落库', () async {
      final id = seedRecord(name: '要刷新', origin: configUrl());
      final before = state.database!.listConfigs().single;

      await state.refreshConfigsInBackground();

      final after = state.database!.listConfigs().single;
      expect(after.id, id, reason: '刷新不是新增一条');
      expect(
        after.siteCount,
        greaterThan(before.siteCount),
        reason: state.lastError?.logLine,
      );
      expect(after.contentHash, isNot(before.contentHash));
      expect(after.lastCheckedAt, isNotNull);
      expect(after.lastCheckError, isNull);
      expect(after.updatedAt.isAfter(before.updatedAt), isTrue);
      expect(state.lastError, isNull, reason: '后台刷新不占用全局错误位');
    });

    test('第二轮内容一致：不写库，只把检查时间往后推', () async {
      final id = seedRecord(name: '没变的源', origin: configUrl());
      await state.refreshConfigsInBackground();
      final first = state.database!.listConfigs().single;
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await state.refreshConfigsInBackground();

      final second = state.database!.listConfigs().single;
      expect(second.id, id);
      expect(second.updatedAt, first.updatedAt, reason: '内容没变不该动更新时间');
      expect(second.contentHash, first.contentHash);
      expect(second.lastCheckedAt!.isAfter(first.lastCheckedAt!), isTrue);
    });

    test('服务端给 ETag：第二轮发条件请求，304 直接跳过', () async {
      final conditional = <String?>[];
      final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => httpServer.close(force: true));
      httpServer.listen((request) async {
        final inm = request.headers.value(HttpHeaders.ifNoneMatchHeader);
        conditional.add(inm);
        if (inm == '"config-v1"') {
          request.response.statusCode = HttpStatus.notModified;
        } else {
          request.response.headers.set(HttpHeaders.etagHeader, '"config-v1"');
          request.response.write(
            '{"sites":[{"key":"etag-site","name":"ETag 站点","type":1,'
            '"api":"http://127.0.0.1:18080/api/type1/"}]}',
          );
        }
        await request.response.close();
      });
      final id = seedRecord(
        name: '带 ETag 的源',
        origin: 'http://127.0.0.1:${httpServer.port}/config.json',
      );

      await state.refreshConfigsInBackground();
      final first = state.database!.listConfigs().single;
      expect(first.siteCount, 1);
      expect(first.etag, '"config-v1"', reason: '校验值要落库，下一轮才有条件请求');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await state.refreshConfigsInBackground();

      final second = state.database!.listConfigs().single;
      expect(second.id, id);
      expect(
        conditional,
        [null, '"config-v1"'],
        reason: '第二轮必须带 If-None-Match',
      );
      expect(second.updatedAt, first.updatedAt, reason: '304 不该写库');
    });

    test('远端失败：本地内容与站点数原样保留，只记检查失败', () async {
      final id = seedRecord(
        name: '坏源',
        origin: '${server.baseUrl}/api/does-not-exist.json',
        siteCount: 7,
      );
      final before = state.database!.listConfigs().single;

      await state.refreshConfigsInBackground();

      final after = state.database!.listConfigs().single;
      expect(after.id, id);
      expect(after.json, before.json, reason: '拉不下来时本地缓存必须完好');
      expect(after.siteCount, 7);
      expect(after.updatedAt, before.updatedAt);
      expect(after.lastCheckError, isNotNull);
      expect(state.lastError, isNull, reason: '静默：后台失败不进全局错误位');
    });

    test('猫源 / 桥接 / 粘贴 JSON 不参与，本地文件源参与', () async {
      final localPath = '${tempDir.path}/local-config.json';
      File(localPath).writeAsStringSync(
        '{"sites":['
        '{"key":"f1","name":"F1","type":1,"api":"${server.baseUrl}/api/type1/"},'
        '{"key":"f2","name":"F2","type":1,"api":"${server.baseUrl}/api/type1/"}'
        ']}',
      );
      final fileId = seedRecord(name: '本地文件', origin: localPath);
      final catId = seedRecord(
        name: '猫源',
        origin: 'https://example.test/cat/index.js.md5',
      );
      final bridgeId = seedRecord(
        name: '桥接源',
        origin: configUrl(),
        contentType: 'android-t4-gateway',
        bridgeInterfaceKey: 'android-key',
      );
      final inlineId = seedRecord(name: '粘贴 JSON', origin: 'inline://json');

      await state.refreshConfigsInBackground();

      final byId = {
        for (final record in state.database!.listConfigs()) record.id: record,
      };
      expect(byId[fileId]!.siteCount, 2, reason: '本地文件源要按最新文件内容刷新');
      expect(byId[fileId]!.lastCheckedAt, isNotNull);
      expect(byId[catId]!.lastCheckedAt, isNull, reason: '猫源重拉会停掉正在用的运行时');
      expect(byId[bridgeId]!.lastCheckedAt, isNull, reason: '桥接源由启动恢复路径负责');
      expect(byId[inlineId]!.lastCheckedAt, isNull, reason: '粘贴的 JSON 没有来源可刷新');
    });

    test('用户已进详情：当前配置后台更新不打断页面', () async {
      final id = seedRecord(name: '在用的源', origin: configUrl());
      expect(
        await state.activateConfigRecord(id),
        isTrue,
        reason: state.lastError?.logLine,
      );
      final staleSites = state.config!.sites.length;
      state.seedDetailForTest(vod: Vod(vodId: 'v1', vodName: '测试剧'));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await state.refreshConfigsInBackground();

      expect(state.selectedVod, isNotNull, reason: '后台刷新不得收起正在看的详情');
      expect(
        state.config!.sites.length,
        staleSites,
        reason: '内存里的站点列表等下次切换配置或重启再换',
      );
      final stored = state.database!.listConfigs().firstWhere((r) => r.id == id);
      expect(stored.siteCount, greaterThan(staleSites), reason: '库里已经是新内容');
    });

    test('还停在首页：当前配置后台更新立即换新', () async {
      final id = seedRecord(name: '在用的源', origin: configUrl());
      expect(
        await state.activateConfigRecord(id),
        isTrue,
        reason: state.lastError?.logLine,
      );
      final staleSites = state.config!.sites.length;
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await state.refreshConfigsInBackground();

      expect(state.config!.sites.length, greaterThan(staleSites));
    });

    test('启动入口同一进程只跑一轮', () {
      final first = state.startupConfigRefresh();
      final second = state.startupConfigRefresh();
      expect(identical(first, second), isTrue);
      expect(identical(second, state.startupConfigRefreshDone), isTrue);
    });
  });
}
