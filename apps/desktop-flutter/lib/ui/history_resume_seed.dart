/// 把一条历史记录转成纯逻辑层可用的[续播种子](ResumeSeed)。
///
/// 放在 UI 层而不是 `core/`：转换本身就是「`services/storage.dart` 的形状」，
/// 而 `core/history_view.dart` 刻意不依赖 `services/`（见该文件头部注释）。
/// 抽成顶层函数是为了能脱离窗口单测——字段映射写错的后果是「续播位置静默丢失」，
/// 这类错误不会抛异常，只能靠断言锁住。
library;

import '../core/history_view.dart';
import '../services/storage.dart';

/// [PlaybackHistory] → [ResumeSeed]。
///
/// [ResumeSeed.episodeId] 必须原样搬运：同步来的记录里它是安卓哈希
/// （`episodeUrl` 的 SHA-256），与本地站点入口不同源，能对上的只有集名，
/// 而集名要靠 [ResumeSeed.episodeName] 才能参与匹配。
ResumeSeed resumeSeedOf(PlaybackHistory item) => ResumeSeed(
  flag: item.flag,
  episodeId: item.episodeId,
  episodeName: item.episodeName,
  positionMs: item.positionMs,
  durationMs: item.durationMs,
  completed: item.completed,
);
