/// 导入摘要必须同时报「站点总数」与「可用站点数」。
///
/// 为什么单独一个文件：`TestWidgetsFlutterBinding` 会劫持 `HttpClient`（见
/// `source_swap_state_test.dart` 文件头），所以要真实 fixture 服务的用例不能和
/// `testWidgets` 混在同一个文件里。
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
    tempDir = await Directory.systemTemp.createTemp('webhtv-import-summary');
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
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
    await server.stop();
  });

  test('导入摘要同时报站点总数与可用站点数', () async {
    final ok = await state.importConfig(
      jsonEncode({
        'name': '可用性摘要',
        'sites': [
          {
            'key': 'summary-ok',
            'name': '可用站 A',
            'type': 1,
            'api': '${server.baseUrl}/api/type1/',
          },
          {
            'key': 'summary-ok2',
            'name': '可用站 B',
            'type': 1,
            'api': '${server.baseUrl}/api/type1/',
          },
          {
            'key': 'summary-jar',
            'name': '桌面 JVM 站源',
            // csp_ 站点没有本地 jar ⇒ 判定为不可用，正是「导入成功但用不了」的形态。
            'type': 3,
            'api': 'csp_SummaryDemo',
          },
        ],
      }),
    );

    expect(ok, isTrue, reason: '配置导入应成功');
    expect(state.usableSiteCount, 2);
    expect(
      state.notice,
      contains('3 个站点'),
      reason: '总数照旧要报，用户得知道这份配置声明了多少站',
    );
    expect(
      state.notice,
      contains('可用 2 个'),
      reason: '只有 2 个站点真能跑，摘要不得让用户以为 3 个都能用',
    );
  });
}
