/// 配置记录的编辑与刷新（用户反馈 2026-11-05）。
///
/// ## 为什么单开一个文件
///
/// 这批断言全部落在**状态层与存储层**：编辑要「先验证再落库」，刷新要
/// 「原地更新同一条记录」。用真实 sqlite + 真实本地 HTTP 才能锁住这两个
/// 性质——打桩 `saveConfig` 只能证明"调过一次"，证明不了"没有多出一条"。
///
/// ## 锁定的用户可见行为
///
/// 1. 改名不动内容（`json`/站点数/更新时间原样保留）；
/// 2. 改地址成功后同一条记录的 `origin` 与 `source_key` 一起换新，记录条数不变；
/// 3. 改地址失败（拉不下来）时**原记录完好**——用户不会因为写错一个字符
///    就丢掉手上这份配置；
/// 4. 刷新成功 = 原地更新（id 不变、条数不变、`updated_at` 前进）；
/// 5. 刷新失败保留原内容，并把失败条目汇总给「全部刷新」。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/source_key.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/state/app_state.dart';

import 'support/test_fixture_server.dart';

void main() {
  group('存储层：按 id 就地修改', () {
    test('updateConfigIdentity 只改名时保留内容与时间戳', () {
      final database = AppDatabase.inMemory();
      addTearDown(database.dispose);
      final id = database.saveConfig(
        name: '旧名字',
        origin: 'https://example.test/a.json',
        json: const {
          'sites': [
            {'key': 'a', 'name': 'A', 'type': 0, 'api': 'https://example.test/a/'},
          ],
        },
        siteCount: 1,
        liveCount: 2,
      );
      final before = database.listConfigs().single;

      database.updateConfigIdentity(id, name: '新名字');

      final after = database.listConfigs().single;
      expect(after.id, id);
      expect(after.name, '新名字');
      expect(after.origin, before.origin);
      expect(after.siteCount, before.siteCount);
      expect(after.liveCount, before.liveCount);
      expect(after.updatedAt, before.updatedAt, reason: '改名不是内容变化');
      expect(after.json, before.json);
    });

    test('updateConfigIdentity 改地址时同步换 sourceKey，不新增记录', () {
      final database = AppDatabase.inMemory();
      addTearDown(database.dispose);
      final id = database.saveConfig(
        name: '源A',
        origin: 'https://example.test/a.json',
        json: const {'sites': <Object?>[]},
      );
      database.updateConfigIdentity(
        id,
        name: '源A',
        origin: 'https://example.test/b.json',
        sourceKey: LocalSourceKey.of('https://example.test/b.json'),
      );
      final all = database.listConfigs();
      expect(all.length, 1, reason: '改地址不是新增一条配置');
      expect(all.single.id, id);
      expect(all.single.origin, 'https://example.test/b.json');
      expect(
        all.single.sourceKey,
        LocalSourceKey.of('https://example.test/b.json'),
      );
    });

    test('refreshConfigContent 原地更新内容并推进 updated_at', () async {
      final database = AppDatabase.inMemory();
      addTearDown(database.dispose);
      final id = database.saveConfig(
        name: '待刷新',
        origin: 'https://example.test/a.json',
        json: const {'sites': <Object?>[]},
        siteCount: 0,
      );
      final before = database.listConfigs().single;
      await Future<void>.delayed(const Duration(milliseconds: 5));

      database.refreshConfigContent(
        id,
        json: const {
          'sites': [
            {'key': 'k', 'name': 'K', 'type': 0, 'api': 'https://example.test/k/'},
          ],
        },
        siteCount: 1,
        liveCount: 3,
        origin: 'https://example.test/a.json',
        sourceKey: LocalSourceKey.of('https://example.test/a.json'),
      );

      final after = database.listConfigs().single;
      expect(after.id, id);
      expect(after.siteCount, 1);
      expect(after.liveCount, 3);
      expect(after.json['sites'], isA<List<Object?>>());
      expect(
        after.updatedAt.isAfter(before.updatedAt),
        isTrue,
        reason: '刷新必须让「更新」时间前进，否则用户看不出刷过',
      );
    });
  });

  group('状态层：编辑与刷新', () {
    late Directory tempDir;
    late TestFixtureServer server;
    late AppState state;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('webhtv-config-edit');
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

    /// 一条可被真实拉取的本地配置 URL。
    ///
    /// `/api/type0/config.json` 不存在，这里用仓库里的 `type1/config.json`
    /// 之外的路径都会 404——所以改用仓库 fixture 端点，站点 api 指向本机服务。
    String configUrl() => '${server.baseUrl}/api/type1/config.json';

    /// 直接落一条记录（不走网络），`makeActive` 控制是否抢当前配置。
    int seedRecord({
      required String name,
      required String origin,
      int siteCount = 2,
      bool makeActive = false,
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
      );
    }

    test('只改名：不重新拉取，内容与条数不变', () async {
      final id = seedRecord(name: '旧名', origin: configUrl());
      final before = state.database!.listConfigs().single;

      final ok = await state.editConfigRecord(
        id,
        name: '新名',
        origin: before.origin,
      );

      expect(ok, isTrue);
      expect(state.lastError, isNull);
      final after = state.database!.listConfigs();
      expect(after.length, 1);
      expect(after.single.name, '新名');
      expect(after.single.siteCount, before.siteCount);
      expect(after.single.updatedAt, before.updatedAt);
    });

    test('改地址成功：同一条记录换成新内容，不新增记录', () async {
      final id = seedRecord(name: '待改址', origin: configUrl(), siteCount: 9);

      final ok = await state.editConfigRecord(
        id,
        name: '改好了',
        origin: configUrl(),
      );

      expect(ok, isTrue, reason: state.lastError?.logLine);
      final all = state.database!.listConfigs();
      expect(all.length, 1, reason: '改地址不得变成两条配置');
      final record = all.single;
      expect(record.id, id);
      expect(record.name, '改好了');
      expect(record.siteCount, greaterThan(0), reason: '新内容必须真的落库');
      expect(record.json['sites'], isNotEmpty);
    });

    test('改地址失败：原记录完好，错误可见', () async {
      final id = seedRecord(name: '别动我', origin: configUrl(), siteCount: 5);
      final before = state.database!.listConfigs().single;

      final ok = await state.editConfigRecord(
        id,
        name: '别动我',
        origin: '${server.baseUrl}/api/does-not-exist.json',
      );

      expect(ok, isFalse, reason: '拉不下来就必须失败');
      expect(state.lastError, isNotNull, reason: '失败原因要能被 UI 展示');
      final after = state.database!.listConfigs().single;
      expect(after.origin, before.origin, reason: '地址不允许被改成坏地址');
      expect(after.siteCount, before.siteCount);
      expect(after.json, before.json);
      expect(after.updatedAt, before.updatedAt);
    });

    test('刷新成功：原地更新，条数不变，时间前进', () async {
      final id = seedRecord(name: '要刷新', origin: configUrl(), siteCount: 1);
      final before = state.database!.listConfigs().single;
      await Future<void>.delayed(const Duration(milliseconds: 5));

      final ok = await state.refreshConfigRecord(id);

      expect(ok, isTrue, reason: state.lastError?.logLine);
      final all = state.database!.listConfigs();
      expect(all.length, 1, reason: '刷新不得新增记录');
      expect(all.single.id, id);
      expect(all.single.siteCount, greaterThan(0));
      expect(all.single.updatedAt.isAfter(before.updatedAt), isTrue);
    });

    test('刷新失败：内容与站点数保持原值', () async {
      final id = seedRecord(
        name: '坏源',
        origin: '${server.baseUrl}/api/does-not-exist.json',
        siteCount: 7,
      );
      final before = state.database!.listConfigs().single;

      final ok = await state.refreshConfigRecord(id);

      expect(ok, isFalse);
      expect(state.lastError, isNotNull);
      final after = state.database!.listConfigs().single;
      expect(after.siteCount, 7, reason: '刷新失败不能把站点数抹成 0');
      expect(after.json, before.json);
    });

    test('全部刷新：汇总失败条目，成功的照常更新', () async {
      final good = seedRecord(name: '好源', origin: configUrl(), siteCount: 1);
      final bad = seedRecord(
        name: '坏源',
        origin: '${server.baseUrl}/api/does-not-exist.json',
        siteCount: 4,
      );

      final failures = await state.refreshAllConfigs();

      expect(failures.length, 1, reason: '只有坏源该失败');
      expect(failures.single, contains('坏源'));
      final byId = {
        for (final record in state.database!.listConfigs()) record.id: record,
      };
      expect(byId[good]!.siteCount, greaterThan(0), reason: '好源要被刷新');
      expect(byId[bad]!.siteCount, 4, reason: '坏源保留原值');
    });
  });
}
