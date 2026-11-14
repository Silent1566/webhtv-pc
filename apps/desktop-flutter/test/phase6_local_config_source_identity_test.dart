/// 本机配置的**来源身份**回归（用户 2026-11 真实缺陷）。
///
/// ## 缺陷现场
///
/// 用户导入本机 T4 配置（日志：`恢复配置：AT-不夜-T4-内网
/// origin=http://192.168.50.50:4567/t4/2024/buye-0`）。历史行的 `source_key`
/// 一直按「本机源 = `local|<origin>`」写入，但早期 `importConfig` 保存配置记录
/// 时**没有写 `source_key`**（那一列是后加的）。两边对不上，表现为：
///
/// - 历史卡片来源显示成「其他来源」；
/// - 点历史想用原配置播放，提示「原播放源已删除或无法读取」，回退到当前源
///   重新匹配——而那个配置明明是好的，切过去就能播。
///
/// 本文件锁住两条修复路径，缺一不可：
///
/// 1. **写入侧**：新导入的本机配置带 `source_key`，且与历史行用的是同一个推导；
/// 2. **读取侧**：老记录（`source_key` 为空）按 `local|<origin>` 兜底仍能查到。
///
/// 同时锁住两条最容易踩的回归：桥接源不按 origin 兜底、重新导入不新增记录。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/source_key.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

/// 用户实际用的那类本机 T4 配置地址（按地址导入时 `origin` 就是它）。
const String localOrigin = 'http://192.168.50.50:4567/t4/2024/buye-0';

class _NoNetworkClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    throw StateError('本测试不应发起网络请求');
  }
}

void main() {
  late Directory tempDir;
  late AppState state;

  Map<String, Object?> configMap() => {
    'name': 'AT-不夜-T4-内网',
    'sites': [
      {
        'key': 'csp_labi',
        'name': '蜡笔[盘]',
        'type': 4,
        'api': '$localOrigin?key=csp_labi',
        'searchable': 1,
      },
    ],
  };

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-local-source');
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
      httpClient: _NoNetworkClient(),
    );
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  /// 模拟**旧版本**写下的本机配置记录：`source_key` 为空串。
  int seedLegacyConfig({String origin = localOrigin}) =>
      state.database!.saveConfig(
        name: 'AT-不夜-T4-内网',
        origin: origin,
        json: configMap(),
        siteCount: 1,
        makeActive: true,
      );

  testWidgets('导入本机配置后，记录身份与历史行的来源推导一致', (tester) async {
    await tester.runAsync(() async {
      await state.importConfig(jsonEncode(configMap()));

      final active = state.activeSourceKey;
      expect(active, isNotEmpty, reason: '生效源必须有身份');

      final record = state.database!.activeConfig();
      expect(record, isNotNull);
      expect(
        record!.sourceKey,
        active,
        reason:
            '配置记录必须带与历史行**同一个**来源身份；'
            '留空的话「按来源查配置」永远落空',
      );

      // 这三处正是缺陷里表现错的地方，全部依赖同一个查询成立。
      expect(
        state.database!.configBySourceKey(active),
        isNotNull,
        reason: '按来源查得到配置，历史才不会显示成「其他来源」',
      );
      expect(
        state.playbackContextFor(active),
        isNotNull,
        reason: '拿得到上下文，才可能「用原配置播放」',
      );
    });
  });

  testWidgets('老记录（source_key 为空）按 local|<origin> 兜底仍能查到', (tester) async {
    await tester.runAsync(() async {
      final id = seedLegacyConfig();
      final legacy = state.database!.listConfigs().single;
      expect(legacy.id, id);
      expect(legacy.sourceKey, isEmpty, reason: '前提：老记录没有身份');

      final found = state.database!.configBySourceKey(
        LocalSourceKey.of(localOrigin),
      );
      expect(
        found,
        isNotNull,
        reason:
            '老数据 source_key 是空串，必须按 origin 兜底——'
            '否则用户看到的就是「其他来源」+「原播放源已删除」',
      );
      expect(found!.id, id);
      expect(found.name, 'AT-不夜-T4-内网');
    });
  });

  testWidgets('兜底也能支撑「用原配置播放」的上下文', (tester) async {
    await tester.runAsync(() async {
      seedLegacyConfig();
      final context = state.playbackContextFor(LocalSourceKey.of(localOrigin));
      expect(context, isNotNull, reason: '缺陷里「提示原播放源已删除」就是因为这一步返回了 null');
      expect(context!.siteByKey('csp_labi'), isNotNull);
    });
  });

  testWidgets('桥接源不按 origin 兜底：同一设备多个源不会互相顶替', (tester) async {
    await tester.runAsync(() async {
      const device = 'dev-uuid-0001';
      const gateway = 'http://192.168.50.9:9978';
      for (final interfaceKey in ['a', 'b']) {
        state.database!.saveConfig(
          name: '源$interfaceKey',
          origin: gateway,
          json: const {'sites': <Object?>[]},
          makeActive: false,
          sourceKey: BridgeSourceKey.of(
            deviceUuid: device,
            interfaceKey: interfaceKey,
          ),
          bridgeDevice: device,
          bridgeInterfaceKey: interfaceKey,
        );
      }
      expect(
        state.database!.listConfigs(),
        hasLength(2),
        reason: '两个源必须是两条记录（按 origin 去重会并成一条）',
      );

      expect(
        state.database!.configBySourceKey(
          BridgeSourceKey.of(deviceUuid: device, interfaceKey: 'missing'),
        ),
        isNull,
        reason: '桥接源共用设备 origin，兜底会让「别人的源」被当成本源',
      );
    });
  });

  testWidgets('重新导入同一份配置只更新，不新增记录', (tester) async {
    await tester.runAsync(() async {
      await state.importConfig(jsonEncode(configMap()));
      await state.importConfig(jsonEncode(configMap()));
      expect(
        state.database!.listConfigs(),
        hasLength(1),
        reason: '补写来源身份不能把「重新导入」变成新增一条配置',
      );
    });
  });

  testWidgets('老记录被重新导入后，身份被补上', (tester) async {
    await tester.runAsync(() async {
      final file = File('${tempDir.path}/config.json');
      await file.writeAsString(jsonEncode(configMap()));
      final id = seedLegacyConfig(origin: file.absolute.path);
      expect(await state.importConfig(file.path), isTrue);

      final records = state.database!.listConfigs();
      expect(records, hasLength(1), reason: '不得因为补身份而多出一条记录');
      expect(records.single.id, id, reason: '重新导入必须更新原记录');
      expect(
        records.single.sourceKey,
        state.activeSourceKey,
        reason: '重新导入应把旧记录的身份补齐',
      );
    });
  });
}
