/// 可配置的假桥接服务：只做 `/manage/configs` + `/vod/api?ac=config` 的替身。
///
/// 为什么单独放到 `support/`：多源导入会先读配置清单、再按 `interfaceKey`
/// 逐个取站点，两段都要能独立成功或失败。`phase5_sync_ui_test.dart` 里的
/// `FakeBridge` 绑在 widget 测试的 setUp 上，状态层用例复用它会把两个套件
/// 耦在一起；这里只依赖 core + services，任何状态层测试都能直接用。
library;

import 'package:webhtv_pc/core/android_bridge.dart';
import 'package:webhtv_pc/core/android_sources.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/android_bridge_service.dart';
import 'package:webhtv_pc/services/log_service.dart';

/// 假桥接服务：不碰网络，行为由测试逐项设定。
class FakeSourcesBridge extends AndroidBridgeService {
  FakeSourcesBridge() : super(log: LogService());

  /// 探测结果（uuid 与 `importSites` 里落库的 `bridge_device` 必须一致）。
  AndroidDevice device = const AndroidDevice(
    uuid: 'dev-uuid-0001',
    name: '测试电视',
    reachableBase: 'http://192.168.50.9:9978',
    type: 0,
  );

  /// `/manage/configs` 的假返回。默认两个源，覆盖「同一设备多源」主路径。
  List<AndroidSource> sources = const [
    AndroidSource(
      interfaceKey: 'a',
      name: '源 A',
      url: 'https://sub.example/a.json',
      active: true,
    ),
    AndroidSource(
      interfaceKey: 'b',
      name: '源 B',
      url: 'https://sub.example/b.json',
    ),
  ];

  /// 覆写成 `false` 可模拟老安卓（没有 `/manage/configs`）。
  bool hasSourceCatalog = true;

  /// `/vod/api?ac=config` 每个源返回几个站点。
  int siteCount = 2;

  /// 非空时 `fetchGatewayConfig` 直接抛这个错误。
  AppError? fetchFailure;

  /// 非空时 `fetchSources` 直接抛这个错误（模拟非 404 的清单失败）。
  AppError? sourcesFailure;

  int probeCalls = 0;
  int sourcesCalls = 0;

  /// 实际取过站点清单的 `interfaceKey`（空串表示走「当前激活源」老路径）。
  final List<String> fetchedInterfaceKeys = <String>[];

  int get fetchCalls => fetchedInterfaceKeys.length;

  @override
  Future<AndroidDevice> probeDevice(String base) async {
    probeCalls++;
    return device;
  }

  @override
  Future<AndroidSourceCatalog> fetchSources(String base) async {
    sourcesCalls++;
    final failure = sourcesFailure;
    if (failure != null) throw failure;
    if (!hasSourceCatalog) {
      throw AppError(
        AppErrorKind.bridgeNoGateway,
        '安卓设备版本过旧：缺少配置清单接口（/manage/configs 不存在）',
      );
    }
    return AndroidSourceCatalog(sources: sources);
  }

  @override
  Future<BridgeConversion> fetchGatewayConfig(
    String base, {
    String? selfBase,
    String? interfaceKey,
    void Function(BridgeStage stage)? onStage,
  }) async {
    final failure = fetchFailure;
    if (failure != null) throw failure;
    fetchedInterfaceKeys.add((interfaceKey ?? '').trim());
    onStage?.call(BridgeStage.converting);
    return BridgeConversion(
      config: AppConfig(
        name: '安卓桥接（fixture）',
        sites: [
          for (var index = 0; index < siteCount; index++)
            Site(
              key: 'csp_${index}_${(interfaceKey ?? 'active').trim()}',
              name: '站点$index',
              type: SiteType.jsonApiBase64Ext,
              api: '$base/$index',
            ),
        ],
      ),
    );
  }

  @override
  Future<List<LiveSource>> fetchLiveSources(String base) async => const [];
}
