/// 导入新配置时选中站点必须失效的门禁测试（§7.4.1 导入即切换）。
///
/// 缺陷背景：`AppState._attachSiteService` 曾用 `_selectedSite ??= config.defaultSite()`，
/// 只在选中站点为 null 时补默认值。于是**导入新配置**后仍然选中上一个配置里的站点：
/// 实测表现是导入猫源（57 个 catHttp 站点）后仍选中旧配置的 `csp_PianDan`（JVM Spider，
/// Phase 3 未实现），首页直接 `siteUnsupported`，用户看到「一个站点都加载不出数据」。
///
/// 这里用真实 `AppState` + 真实 HTTP（`TestFixtureServer`）驱动，锁住三条不变量：
/// 1. 选中站点必须属于当前配置（换配置即失效）；
/// 2. 选中站点变化时，上一个配置的首页/分类/详情结果不得残留；
/// 3. 选中站点仍属于新配置时保留（重新导入同一份配置不打断用户）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

import 'support/test_fixture_server.dart';

void main() {
  late TestFixtureServer server;
  late Directory tempDir;
  late AppState state;

  setUp(() async {
    server = await TestFixtureServer.start();
    tempDir = await Directory.systemTemp.createTemp('webhtv-cat-switch');
    state = AppState(
      paths: AppPaths.resolve(overrides: {'roaming': tempDir.path, 'local': tempDir.path}),
      log: LogService(),
    );
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
    await server.stop();
  });

  String configOf({
    required String name,
    required List<Map<String, Object?>> sites,
  }) => jsonEncode({'name': name, 'sites': sites});

  Map<String, Object?> siteOf(String key, String api) => {
    'key': key,
    'name': '站点 $key',
    'type': 1,
    'api': api,
    'searchable': 1,
  };

  /// 可真实加载的 API（fixture 的 `/api/type1/` 返回真实首页/分类/详情）。
  String okApi() => '${server.baseUrl}/api/type1/';

  /// 旧配置：只有一个 Phase 3 未实现的 `csp_` 站点（模拟用户截图里的 AT 配置）。
  /// 注意用函数而不是 `final` 字段：`server` 在 setUp 里才初始化，字段初始化会早于它。
  String oldConfig() => configOf(name: '旧配置', sites: [
        {'key': 'csp_PianDan', 'name': '片单', 'type': 3, 'api': 'csp_PianDan', 'searchable': 1},
      ]);

  /// 新配置：两个可加载的站点（模拟导入猫源后的站点集合）。
  String newConfig() => configOf(name: '新配置', sites: [
        siteOf('nodejs_a', okApi()),
        siteOf('nodejs_b', okApi()),
      ]);

  test('导入新配置后选中站点必须换成新配置的默认站点', () async {
    expect(await state.importConfig(oldConfig()), isTrue);
    expect(state.selectedSite?.key, 'csp_PianDan', reason: '旧配置只有一个站点，必然选中它');

    expect(await state.importConfig(newConfig()), isTrue);
    expect(
      state.selectedSite?.key,
      'nodejs_a',
      reason: '导入新配置后不得继续选中旧配置的 csp_PianDan',
    );
  });

  test('切回旧配置时选中站点同样跟着配置走', () async {
    await state.importConfig(newConfig());
    expect(state.selectedSite?.key, 'nodejs_a');

    await state.importConfig(oldConfig());
    expect(state.selectedSite?.key, 'csp_PianDan');
  });

  test('选中站点变化时清掉上一个配置的浏览结果', () async {
    await state.importConfig(newConfig());
    await state.loadHome(state.selectedSite!);
    expect(state.homeResult, isNotNull, reason: 'fixture 首页应能加载出内容');

    // 换到旧配置（选中站点必然改变）→ 旧首页结果必须丢弃。
    await state.importConfig(oldConfig());
    expect(state.selectedSite?.key, 'csp_PianDan');
    expect(state.homeResult, isNull, reason: '站点换了就不得复用旧首页结果');
    expect(state.categoryResult, isNull);
    expect(state.detailResult, isNull);
    expect(state.selectedTypeId, isNull);
  });

  test('选中站点仍属于新配置时保留（重复导入同一份配置不打断用户）', () async {
    await state.importConfig(newConfig());
    await state.selectSite(state.config!.sites[1]);
    expect(state.selectedSite?.key, 'nodejs_b');

    await state.importConfig(newConfig());
    expect(state.selectedSite?.key, 'nodejs_b', reason: 'nodejs_b 仍在新配置里，应保留选中');
    expect(state.homeResult, isNotNull, reason: '站点未变，首页结果不必清空');
  });
}
