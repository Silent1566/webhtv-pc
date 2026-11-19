/// 失败回退阶梯的纯策略（迭代 3-C）：一次开播失败之后「下一步做什么」。
///
/// 为什么单独一层：`PlayerOptions.failureFallback` 此前只出现在设置页，播放页
/// 失败后只提示一句就停住。把「走哪一档」的判断从页面里提出来，页面只剩
/// 「按结论执行」：换线路、换解析源、原地重试，或者按原样报错。
///
/// 三条硬规则都是产品决定，不是实现细节：
/// 1. **默认 off**：没有显式开启过的用户，失败就停在这里——在用户没有预期时
///    被换到别的线路/解析源，比看到一句错误更糟；
/// 2. **不可回退的失败一律放弃**：格式不支持、加载失败换多少条线路都一样，
///    硬试只会把黑屏时间拉长；
/// 3. **总次数有上限**（[maxPlaybackFallbackAttempts]）：每一轮都要先等引擎
///    自己的超时，没有上限时一个坏站点能把一次播放拖成几分钟的自动重试。
///
/// 依赖方向：本文件只依赖 `player_options.dart` 与 `playback_open_policy.dart`
/// 的值类型；不依赖 Flutter、不做 IO、不读设置存储。输入是值对象，输出是
/// [FallbackDecision]，因此「这一档在这个位置给哪一步」可以逐条断言。
library;

import 'playback_open_policy.dart';
import 'player_options.dart';

/// 失败回退的下一步。
enum FallbackStep {
  /// 同一线路、同一解析源再开一次。
  ///
  /// 只在「已经没有可切换的候选」时给出：这时再换就是重复试同一个地址的
  /// 同义反复，原地重试反而是唯一还可能有变化的一步（线路抖动、瞬时 5xx）。
  retrySame('retry_same', '原地重试'),

  /// 换下一条线路（`playLines` 的下一个）。
  nextLine('next_line', '换线路'),

  /// 换下一个解析源（`parseSources` 的下一个）。
  nextParseSource('next_parse_source', '换解析源'),

  /// 不再自动回退：把错误原样交给 UI。
  giveUp('give_up', '放弃回退');

  const FallbackStep(this.id, this.label);

  /// 日志用的稳定标识，**不得改名**。
  final String id;

  final String label;
}

/// 一次播放里自动回退的总次数上限（含原地重试）。
///
/// 3 = 一次原地重试 + 一次换线路 + 一次换解析源，正好走完一个完整阶梯。
/// 为什么不再给更多：每一轮失败都要先等引擎自己的超时（预取探测上限默认
/// 8 秒，加载超时同量级），第 4 轮就是「点一下播放、黑屏半分钟」；而用户真正
/// 想看的片子，通常也不在第 4 个候选里。超过上限时交给失败态的三个出口
/// （重试 / 续播 / 下一集），把选择权还给用户。
const int maxPlaybackFallbackAttempts = 3;

/// 一次回退判定的输入：失败性质 + 当前位置 + 设置 + 已回退次数。
///
/// 位置用「下标 + 长度」而不是列表本身：策略只需要知道「后面还有没有」，
/// 传列表会让这个文件凭空依赖 `VodPlayLine` / 站点协议里的类型。
class PlaybackFallbackRequest {
  const PlaybackFallbackRequest({
    required this.failure,
    required this.mode,
    required this.lineIndex,
    required this.lineCount,
    required this.parseSourceIndex,
    required this.parseSourceCount,
    this.attempts = 0,
  });

  /// 失败性质：可回退 / 不可回退（见 [classifyPlaybackFailureClass]）。
  final PlaybackFailureClass failure;

  /// 用户设置的回退档位（`PlayerOptions.failureFallback`）。
  final PlayerFailureFallback mode;

  /// 当前线路在 `playLines` 里的下标；不在列表里（直链、位置未知）时为 -1。
  final int lineIndex;

  /// `playLines` 的条数。
  final int lineCount;

  /// 当前解析源在 `parseSources` 里的下标；不在列表里时为 -1。
  final int parseSourceIndex;

  /// `parseSources` 的条数。
  final int parseSourceCount;

  /// 本次播放已经自动回退过的次数（不含用户手动点重试）。
  final int attempts;
}

/// 一次回退判定的结果：下一步 + 一句能直接进日志的理由。
class FallbackDecision {
  const FallbackDecision(this.step, this.reason, {this.targetIndex});

  /// 不再回退时用它，免得调用点到处写 `targetIndex: null`。
  const FallbackDecision.giveUp(this.reason)
    : step = FallbackStep.giveUp,
      targetIndex = null;

  final FallbackStep step;

  /// 为什么给这一步：日志/诊断用，**不得**用来拼用户提示。
  final String reason;

  /// [FallbackStep.nextLine] / [FallbackStep.nextParseSource] 的目标下标；
  /// 其余步骤为 null。
  final int? targetIndex;

  /// 有没有「可以执行」的下一步。
  bool get hasNext => step != FallbackStep.giveUp;

  /// 一行日志：步骤、目标、理由三件事齐全，排查时不用再看别处。
  String get logLine =>
      '${step.id} target=${targetIndex ?? '-'} reason=$reason';

  @override
  String toString() => 'FallbackDecision($logLine)';
}

/// 判定下一步。
///
/// 判定顺序本身就是优先级，改顺序会改变行为：
/// 1. 次数用完 → 放弃（上限必须在最前面，否则后面的分支会再开一轮）；
/// 2. 档位 off → 放弃（产品默认值，未显式开启就零行为）；
/// 3. 不可回退的失败 → 放弃（换线路浪费时间，且会掩盖真正的原因）；
/// 4. 还有下一条线路 → 换线路（最便宜的换法：同一集、换一条线路重解析）；
/// 5. 档位允许且还有下一个解析源 → 换解析源（同一线路、换一种拿地址的方式）；
/// 6. 都没有、且这是第一次回退 → 原地重试一次；
/// 7. 其余 → 放弃。
///
/// `lineAndParseAndSource` 的「换源」不产生回退步骤：换源是详情页的动作，
/// 播放页没有 VOD 换源入口（只有直播有），所以阶梯在这里到解析源为止——
/// 宁可少走一步，也不在播放页里凭空造一个用户没见过的入口。
FallbackDecision decidePlaybackFallback(PlaybackFallbackRequest request) {
  if (request.attempts >= maxPlaybackFallbackAttempts) {
    return FallbackDecision.giveUp(
      '已达自动回退上限 $maxPlaybackFallbackAttempts 次',
    );
  }
  if (request.mode == PlayerFailureFallback.off) {
    return const FallbackDecision.giveUp('回退档位为 off，不自动换线路/解析源');
  }
  if (request.failure == PlaybackFailureClass.nonRecoverable) {
    return const FallbackDecision.giveUp(
      '不可回退的失败（格式不支持/加载失败），换线路只会浪费时间',
    );
  }
  final nextLine = _nextFallbackIndex(request.lineIndex, request.lineCount);
  if (nextLine != null) {
    return FallbackDecision(
      FallbackStep.nextLine,
      '当前线路已失败，换下一条线路',
      targetIndex: nextLine,
    );
  }
  if (request.mode.allowsParse) {
    final nextParse = _nextFallbackIndex(
      request.parseSourceIndex,
      request.parseSourceCount,
    );
    if (nextParse != null) {
      return FallbackDecision(
        FallbackStep.nextParseSource,
        '线路已用尽，换下一个解析源',
        targetIndex: nextParse,
      );
    }
  }
  if (request.attempts == 0) {
    return const FallbackDecision(
      FallbackStep.retrySame,
      '没有可切换的线路/解析源，原地重试一次',
    );
  }
  return FallbackDecision.giveUp(
    '可切换的线路/解析源已用尽（本次已回退 ${request.attempts} 次）',
  );
}

/// 下一个候选下标；没有时返回 null。
///
/// 位置未知（-1）时**不猜**：不知道当前用的是哪一个，就无法保证「下一个」不是
/// 已经失败过的那个，重复试同一条线路正是要避免的事。数量为 0 同理。
int? _nextFallbackIndex(int current, int count) {
  if (count <= 0 || current < 0) return null;
  final next = current + 1;
  return next < count ? next : null;
}
