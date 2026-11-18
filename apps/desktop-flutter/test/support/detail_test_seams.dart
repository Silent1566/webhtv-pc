/// 既有详情页 widget 用例的共用接缝。
///
/// 详情页自 2d748d0 起会在 build 里做两件会留下异步尾巴的事：
/// 1. 发起豆瓣/Bangumi 的外部元数据补全（默认开启，见
///    docs/phase9/design/12-external-metadata-fallback.md）；豆瓣按 spacing
///    定时器串行排队，请求还没排完用例就结束了。
/// 2. 打一行「剧照构成」诊断日志；日志服务按批落盘，会排一个 flush 定时器。
///
/// 两件事在线上都合理，但在 fake-async 用例里会变成 flutter_test 的
/// 「A Timer is still pending even after the widget tree was disposed」。这些用例
/// 钉的是 TMDB / 线路 / 历史 / 推荐等别的行为，元数据管线本身由
/// external_metadata_* 系列覆盖，所以在这里整片关掉，而不是靠多 pump 几百
/// 毫秒去赌队列排空。
library;

import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

/// 混进自建的 AppState 子类：详情页不再发外部补全请求。
mixin ExternalMetaOff on AppState {
  @override
  bool get externalMetaEnabled => false;
}

/// 日志只留内存、不落盘：不排 flush 定时器，用例结束时不欠账。
class MemoryOnlyLogService extends LogService {
  @override
  Future<void> open([String? directory]) async {}
}

/// 没有自建 AppState 子类时用：bootstrap 之后把外部元数据管线关掉。
///
/// 必须排在 bootstrap 之后——偏好未加载时 AppState.setExternalMetaEnabled
/// 会直接返回 false，闸门不生效。
Future<void> bootstrapWithoutExternalMeta(AppState state) async {
  await state.bootstrap();
  await state.setExternalMetaEnabled(false);
}
