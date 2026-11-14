/// 播放定向站点测试：`resolvePlayback(siteOverride:)` 只影响这一次调用。
///
/// 用**两个真实 fixture 服务**分别当甲站/乙站的 `api`：靠「哪一个服务收到了
/// 播放入口请求」判定本次解析实际用了谁——这是不读私有字段就能证明「请求真的
/// 打到覆盖站点」的证据（`SiteService` 不打桩，走真实 HTTP）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

import 'support/test_fixture_server.dart';

void main() {
  late TestFixtureServer serverA;
  late TestFixtureServer serverB;
  late Directory tempDir;
  late AppState state;

  setUp(() async {
    serverA = await TestFixtureServer.start();
    serverB = await TestFixtureServer.start();
    tempDir = await Directory.systemTemp.createTemp('webhtv-site-override');
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
    // `type=4`（HTTP API + Base64 ext）是「剧集目标必须先送播放入口」的形态：
    // 解析一定会发出 `<api>?play=<剧集目标>` 请求。两个站点各指向一个 fixture
    // 服务，「谁被请求」就是「谁被选中」的直接证据。
    final ok = await state.importConfig(
      jsonEncode({
        'name': '定向站点测试',
        'sites': [
          {
            'key': 'site-a',
            'name': '甲站',
            'type': 4,
            'api': '${serverA.baseUrl}/api/type4',
          },
          {
            'key': 'site-b',
            'name': '乙站',
            'type': 4,
            'api': '${serverB.baseUrl}/api/type4',
          },
        ],
      }),
    );
    expect(ok, isTrue, reason: '配置导入应成功');
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
    await serverA.stop();
    await serverB.stop();
  });

  /// 某个服务收到的播放入口请求数。
  int playCallsOf(TestFixtureServer server) => server.captured
      .where((item) => item.path.endsWith('/api/type4'))
      .length;

  test('siteOverride 指向乙站：请求打到乙站，当前站点仍是甲站', () async {
    final siteA = state.config!.sites.firstWhere((s) => s.key == 'site-a');
    final siteB = state.config!.sites.firstWhere((s) => s.key == 'site-b');
    await state.selectSite(siteA);
    expect(state.selectedSite?.key, 'site-a');

    // 每次通知都记下「当时」的当前站点：站源若被悄悄改过，这里会留下痕迹。
    final notifiedSiteKeys = <String?>[];
    state.addListener(() => notifiedSiteKeys.add(state.selectedSite?.key));

    serverA.captured.clear();
    serverB.captured.clear();

    final decision = await state.resolvePlayback(
      episodeTarget: 't4-direct',
      flag: 'line',
      siteOverride: siteB,
    );

    // 1) 解析成功，地址来自乙站播放入口的 fixture。
    expect(decision, isNotNull);
    expect(decision!.url, endsWith('/media/sample.mp4'));

    // 2) 请求真的打到乙站；甲站一次都没被碰过。
    expect(playCallsOf(serverB), greaterThan(0), reason: '覆盖站点必须真的被请求');
    final lastOnB = serverB.captured.lastWhere(
      (item) => item.path.endsWith('/api/type4'),
    );
    expect(lastOnB.query['play'] ?? lastOnB.form['play'], 't4-direct');
    expect(
      serverA.captured,
      isEmpty,
      reason: '传了 siteOverride 就不能向当前选中站点发任何请求',
    );

    // 3) 全局当前站点没被改动，且每次通知时都还是甲站。
    expect(state.selectedSite?.key, 'site-a');
    expect(identical(state.selectedSite, siteA), isTrue, reason: '选中站点对象不能被换掉');
    expect(notifiedSiteKeys, isNotEmpty, reason: '解析结束仍应通知一次（既有行为）');
    expect(
      notifiedSiteKeys.every((key) => key == 'site-a'),
      isTrue,
      reason: '过程中不得出现「站源已变更」的通知',
    );

    // 4) 覆盖只对这一次调用生效：紧接着不传参数的调用回到甲站。
    serverA.captured.clear();
    serverB.captured.clear();
    final plain = await state.resolvePlayback(
      episodeTarget: 't4-direct',
      flag: 'line',
    );
    expect(plain, isNotNull);
    expect(
      playCallsOf(serverA),
      greaterThan(0),
      reason: '不传 siteOverride 时必须回到当前选中站点',
    );
    expect(serverB.captured, isEmpty, reason: '覆盖不得泄漏到后续调用');
    expect(state.selectedSite?.key, 'site-a');
  });

  test('siteOverride 为 null 时行为不变：走当前选中站点', () async {
    final siteA = state.config!.sites.firstWhere((s) => s.key == 'site-a');
    await state.selectSite(siteA);
    serverA.captured.clear();
    serverB.captured.clear();

    final decision = await state.resolvePlayback(
      episodeTarget: 't4-direct',
      flag: 'line',
    );

    expect(decision, isNotNull);
    expect(decision!.url, endsWith('/media/sample.mp4'));
    expect(playCallsOf(serverA), greaterThan(0), reason: 'null 等价于今天的 _selectedSite 分支');
    final lastOnA = serverA.captured.lastWhere(
      (item) => item.path.endsWith('/api/type4'),
    );
    expect(lastOnA.query['play'] ?? lastOnA.form['play'], 't4-direct');
    expect(serverB.captured, isEmpty);
    expect(state.selectedSite?.key, 'site-a');
  });

  test('siteOverride 与当前站点相同也不改变结果', () async {
    final siteA = state.config!.sites.firstWhere((s) => s.key == 'site-a');
    await state.selectSite(siteA);
    serverA.captured.clear();
    serverB.captured.clear();

    final decision = await state.resolvePlayback(
      episodeTarget: 't4-direct',
      flag: 'line',
      siteOverride: siteA,
    );

    expect(decision, isNotNull);
    expect(decision!.url, endsWith('/media/sample.mp4'));
    expect(playCallsOf(serverA), greaterThan(0));
    expect(serverB.captured, isEmpty);
    expect(state.selectedSite?.key, 'site-a');
  });
}
