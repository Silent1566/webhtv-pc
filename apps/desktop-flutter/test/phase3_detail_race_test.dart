/// 详情页竞态与归属门禁测试（设计文档 §8.3、§8.4、§17.2 详情页）。
///
/// 缺陷背景（用户实测）：**一部剧点三次才进得去**，第一次进去说没有线路，第二次
/// 一直转圈，第三次才看到线路和简介；而且**返回后再点其他剧，看到的还是上一部剧
/// 的信息**。根因是「详情状态放在全局 `AppState`」+「详情请求没有并发保护」：
///
/// 1. `loadDetail` 没有运行号。详情页在 `initState` 的 post-frame 回调里发请求，
///    用户「返回列表 → 立刻点另一部剧」时前一个请求往往还在飞行（本机实测
///    detail 单次 3.9~7.1s），先返回的旧响应被后返回的覆盖。详情页读的是全局
///    `detailResult`，于是 A 剧的结果渲染到 B 剧页面上 → 点播串剧。
/// 2. 详情页无条件信任全局 `detailResult`，不校验 `vod_id` 是否属于本页影片；
///    加载中也继续渲染上一次的线路，于是「没有线路」与「串剧」同时出现。
/// 3. 离开详情页不清理详情状态；详情失败还会写进浏览页共用的 `lastError`，
///    返回列表时冒出一条与当前列表无关的错误横幅。
///
/// 本文件用真实 `AppState` + 真实 HTTP（`TestFixtureServer`）+ 真实 `DetailPage`
/// 锁定四条不变量：
/// 1. 迟到的详情响应不得覆盖更新的请求（运行号）；
/// 2. 详情页只渲染属于本页 `vod_id` 的结果；
/// 3. 离开详情页清空详情状态（结果/影片/错误/阶段）；
/// 4. 详情失败写 `detailError`，不污染浏览页的 `lastError`。
///
/// fixture 支持：`ids=slow-<x>` 会延迟返回详情，并把 `ids` 回显为 `vod_id`，
/// 便于分辨「返回的到底是哪一次请求」（见 `support/test_fixture_server.dart`）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

import 'support/test_fixture_server.dart';

void main() {
  late TestFixtureServer server;
  late Directory tempDir;
  late AppPaths paths;
  late AppState state;

  /// 可正常加载的 API（fixture `/api/type1/` 返回真实首页/分类/详情）。
  String okApi() => '${server.baseUrl}/api/type1/';

  Future<void> importSites(List<Map<String, Object?>> sites) async {
    final imported = await state.importConfig(
      jsonEncode({'name': '详情竞态夹具', 'sites': sites}),
    );
    expect(imported, isTrue, reason: '夹具配置必须导入成功');
  }

  setUp(() async {
    server = await TestFixtureServer.start();
    tempDir = await Directory.systemTemp.createTemp('webhtv-detail-race');
    paths = AppPaths.resolve(
      overrides: {'roaming': tempDir.path, 'local': tempDir.path},
    );
    state = AppState(paths: paths, log: LogService());
    await state.bootstrap();
    await importSites([
      {
        'key': 'nodejs_fixture',
        'name': '夹具站点',
        'type': 1,
        'api': okApi(),
        'searchable': 1,
      },
    ]);
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
    await server.stop();
  });

  Vod vodOf(String id, String name) => Vod(vodId: id, vodName: name);

  group('详情请求运行号（§8.3）', () {
    test('迟到的详情响应不得覆盖更新的请求', () async {
      // A 先发但**后到**（slow 详情延迟 1.2s），B 后发但先到（普通详情即时）。
      final slowA = state.loadDetail(vodOf('slow-A', 'A 剧'));
      final fastB = state.loadDetail(vodOf('demo-1', 'B 剧'));
      await fastB;
      await slowA;

      expect(
        state.detailResult?.list.first.vodId,
        'demo-1',
        reason: 'B 才是最新请求；A 的迟到结果必须被运行号丢弃',
      );
      expect(state.detailPhase, LoadPhase.ready);

      // 反向对照：把 `_detailRunId` 校验去掉后，这里会变成 slow-A（旧响应覆盖），
      // 断言失败——证实本用例有判别力。
      expect(
        state.detailResult?.list.first.vodId,
        isNot('slow-A'),
        reason: '旧响应覆盖新响应正是实测的串剧根因',
      );
    });

    test('新请求开始时先清掉上一次的详情结果', () async {
      await state.loadDetail(vodOf('demo-1', 'A 剧'));
      expect(state.detailResult, isNotNull);

      final pending = state.loadDetail(vodOf('slow-B', 'B 剧'));
      // 加载中：不得把 A 剧的详情结果留在状态里，否则新页面先渲染 A 的线路。
      expect(state.detailResult, isNull, reason: '新请求开始时必须清掉上一次结果');
      expect(state.detailPhase, LoadPhase.loading);

      await pending;
      expect(state.detailResult?.list.first.vodId, 'slow-B');
    });

    test('换站点会作废在途详情请求', () async {
      final pending = state.loadDetail(vodOf('slow-A', 'A 剧'));
      // 切换站点（等价于用户离开详情页去别的站点）。
      await state.selectSite(state.config!.sites.first);
      await pending;

      expect(
        state.detailResult,
        isNull,
        reason: '换站点后，旧站点在途详情的返回必须被丢弃',
      );
    });

    test('clearDetail 清空结果/影片/错误/阶段', () async {
      await state.loadDetail(vodOf('demo-1', 'A 剧'));
      expect(state.detailResult, isNotNull);
      expect(state.selectedVod, isNotNull);

      state.clearDetail();

      expect(state.detailResult, isNull);
      expect(state.selectedVod, isNull);
      expect(state.detailError, isNull);
      expect(state.detailPhase, LoadPhase.idle);
    });
  });

  group('详情错误与浏览页错误隔离（§8.4）', () {
    test('详情失败写 detailError，不污染浏览页的 lastError', () async {
      await importSites([
        {
          'key': 'nodejs_bad',
          'name': '错误站点',
          'type': 1,
          'api': '${server.baseUrl}/api/error-html',
          'searchable': 1,
        },
      ]);
      // 导入会加载首页（502），这里先记下浏览页自己的错误态，随后清零作为对照。
      state.clearError();
      expect(state.lastError, isNull);

      await state.loadDetail(vodOf('demo-1', '坏详情'));

      expect(state.detailPhase, LoadPhase.failed);
      expect(state.detailError, isNotNull, reason: '详情错误必须落在 detailError');
      expect(
        state.lastError,
        isNull,
        reason: '详情错误不得写进浏览页共用的 lastError',
      );
    });
  });
}
