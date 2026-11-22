/// 自动搜索弹幕时逐个试载候选（`docs/phase9/design/02` §2.3）。
///
/// 为什么需要这一层：中转对同一个片名会返回**多来源**候选，其中某些源是空的
/// （200 + 空 `<i></i>`，或解析后 0 条）。若只取分数最高的那一条，撞上空源就
/// 把整次播放判成「没有弹幕」，用户看到的是「弹幕不可用」——而同一批候选里
/// 往往还有上千条的完整源。
library;

import '../core/danmaku_match.dart';

/// 依次尝试候选；[load] 返回 true 即采用。最多尝试 [maxAttempts] 个。
///
/// [ranked] 必须是调用方已按相关度排好序的列表（`rankDanmakuEntries` 的输出），
/// 本函数不再排序、也不改分数：采用哪个候选是排序的结论，这里只负责「哪一条
/// 真的能用」。
///
/// 全部不可用或列表为空时返回 null；[maxAttempts] <= 0 时一次也不调用 [load]。
Future<DanmakuLibraryEntry?> autoLoadDanmakuCandidates({
  required Iterable<DanmakuLibraryEntry> ranked,
  required Future<bool> Function(DanmakuLibraryEntry entry) load,
  int maxAttempts = 3,
}) async {
  if (maxAttempts <= 0) return null;
  var attempts = 0;
  for (final entry in ranked) {
    if (attempts >= maxAttempts) break;
    attempts++;
    var loaded = false;
    try {
      loaded = await load(entry);
    } catch (_) {
      // 单个候选的失败（空文件、坏 XML、网络抖动）不能中断整条链：
      // 「换下一个源」正是本函数存在的理由。异常本身已由 load 记日志。
      loaded = false;
    }
    if (loaded) return entry;
  }
  return null;
}
