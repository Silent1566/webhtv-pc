/// 剧集/线路解析与播放决策（§7.4.8、§8.3、§10.2）。
///
/// 这里是“把 Result 变成可播放请求”的纯逻辑层，不执行网络请求，方便用固定
/// fixture 做冲突组合测试。
library;

import 'app_error.dart';
import 'protocol.dart';

/// 解析 `vod_play_from` / `vod_play_url`。
///
/// - `$$$` 分隔线路；
/// - `#` 分隔剧集；
/// - `剧集名$地址` 组成一个剧集，使用第一个 `$` 切分，避免地址中含 `$` 时被截断；
/// - 线路名缺失或数量不足时补默认名，保证 UI 不出现空线路。
List<VodPlayLine> parsePlayLines(String? vodPlayFrom, String? vodPlayUrl) {
  final urlText = vodPlayUrl?.trim() ?? '';
  if (urlText.isEmpty) return const [];

  final lineTexts = urlText
      .split(r'$$$')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  final flags = (vodPlayFrom ?? '')
      .split(r'$$$')
      .map((flag) => flag.trim())
      .where((flag) => flag.isNotEmpty)
      .toList();

  final lines = <VodPlayLine>[];
  for (var index = 0; index < lineTexts.length; index++) {
    final flag = index < flags.length && flags[index].isNotEmpty
        ? flags[index]
        : '线路${index + 1}';
    final episodes = <VodEpisode>[];
    final parts = lineTexts[index]
        .split('#')
        .map((episode) => episode.trim())
        .where((episode) => episode.isNotEmpty)
        .toList();
    for (var position = 0; position < parts.length; position++) {
      final separator = parts[position].indexOf(r'$');
      if (separator <= 0 || separator == parts[position].length - 1) {
        // 没有 `$` 的条目按“地址即条目”处理，属于协议常见省略写法。
        episodes.add(
          VodEpisode(name: '第 ${position + 1} 集', url: parts[position]),
        );
        continue;
      }
      episodes.add(
        VodEpisode(
          name: parts[position].substring(0, separator).trim(),
          url: parts[position].substring(separator + 1).trim(),
        ),
      );
    }
    if (episodes.isNotEmpty) {
      lines.add(VodPlayLine(flag: flag, episodes: episodes));
    }
  }
  return lines;
}

/// 合并目录资源时记录「显示线路 → 原始播放 flag」，随 Vod.extra 保留。
const bridgePlaybackFlagsKey = 'bridge_playback_flags';

/// 普通站点和桥接站点共用的线路模型。
List<VodPlayLine> parseVodPlayLines(Vod vod) {
  final originals = asMap(vod.extra[bridgePlaybackFlagsKey]);
  return [
    for (final line in parsePlayLines(vod.vodPlayFrom, vod.vodPlayUrl))
      VodPlayLine(
        flag: line.flag,
        episodes: line.episodes,
        sourceFlag: asNonEmptyString(originals[line.flag]),
      ),
  ];
}

const _mediaSchemes = {'http', 'https', 'rtsp', 'rtmp', 'rtmps', 'file'};

/// 目标是否是可以直接交给播放器的绝对地址。
bool looksLikeMediaUrl(String target) {
  final trimmed = target.trim();
  if (trimmed.isEmpty) return false;
  if (trimmed.startsWith('//')) return true;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return false;
  return uri.hasScheme && _mediaSchemes.contains(uri.scheme.toLowerCase());
}

/// 相对路径解析：相对到站点 api 的 origin（§8.4 “相对路径解析”）。
String resolveRelative(String target, Uri base) {
  final trimmed = target.trim();
  if (trimmed.startsWith('//')) {
    return '${base.scheme}:$trimmed';
  }
  return base.resolve(trimmed).toString();
}

/// 站点 `playUrl` 是前缀形态时的拼接（§7.4.8）。
String joinPlayUrlPrefix(String prefix, String target) {
  if (prefix.contains('{id}')) {
    return prefix.replaceAll('{id}', target);
  }
  return '$prefix$target';
}

/// 播放决策所需的输入，全部来自配置与 Result，便于测试构造。
class PlaybackResolutionInput {
  const PlaybackResolutionInput({
    required this.site,
    required this.episodeTarget,
    this.flag,
    this.parse,
    this.jx,
    this.resultHeader,
    this.globalHeaders = const [],
    this.subs = const [],
    this.danmaku = const [],
    this.qualities = const [],
    this.qualityIndex = 0,
  });

  final Site site;
  final String episodeTarget;
  final String? flag;
  final int? parse;
  final int? jx;

  /// 播放结果自带的 Header（优先级最高，§7.4.6）。
  final HeaderMap? resultHeader;

  /// 顶层 `headers` 规则，用于在媒体请求上按 host 注入（§7.4.6 步骤 2）。
  final List<HeaderRule> globalHeaders;

  /// 播放结果携带的外挂字幕（§10.3），原样透传到决策。
  final List<SubtitleInfo> subs;

  /// 播放结果携带的弹幕源（§21 Phase 3），原样透传到决策。
  final List<DanmakuSource> danmaku;
  final List<PlaybackQuality> qualities;
  final int qualityIndex;
}

/// 播放决策器：只根据输入决定动作，不执行网络。
abstract final class PlaybackResolver {
  /// 返回直接播放决策，或返回 [PlaybackAction.needParser]（§12）供上层调用解析器，
  /// 或抛出 [AppErrorKind.playbackParserRequired]（目标既非直链也无法解析）。
  ///
  /// 规则（§7.4.8）：
  /// 1. `parse=1` 或 `jx=1` → 需要解析器，MVP-A 明确报错；
  /// 2. 绝对媒体地址 → 直接播放；
  /// 3. 相对路径 → 相对站点 api 解析后判断；
  /// 4. 站点 `playUrl` 前缀形态 → 拼接后判断；
  /// 5. 其余非 URL 目标 → 需要解析器/Spider，明确报错。
  static PlaybackDecision decide(PlaybackResolutionInput input) {
    final qualityIndex =
        input.qualityIndex >= 0 && input.qualityIndex < input.qualities.length
        ? input.qualityIndex
        : 0;
    final selectedTarget = input.qualities.isEmpty
        ? input.episodeTarget
        : input.qualities[qualityIndex].url;
    final parseRequested = (input.parse ?? 0) == 1 || (input.jx ?? 0) == 1;
    if (parseRequested) {
      // §12.2：parse=1/jx=1 → 走解析器。此处返回待解析决策（保留目标与触发原因），
      // 由 site_service 调 ParseService 解析后再次 decide。不再抛错。
      return PlaybackDecision(
        action: PlaybackAction.needParser,
        url: selectedTarget,
        headers: _mediaHeaders(input, selectedTarget),
        subs: input.subs,
        danmaku: input.danmaku,
        flag: input.flag,
        qualities: input.qualities,
        qualityIndex: qualityIndex,
        parse: input.parse,
        jx: input.jx,
      );
    }

    final target = selectedTarget.trim();
    if (target.isEmpty) {
      throw AppError(
        AppErrorKind.playbackUrlMissing,
        '剧集 ${input.flag ?? ""} 缺少播放地址',
        detail: '站点=${input.site.key}',
      );
    }

    final headers = _mediaHeaders(input, target);

    if (looksLikeMediaUrl(target)) {
      return PlaybackDecision(
        action: PlaybackAction.direct,
        url: target,
        headers: headers,
        flag: input.flag,
        qualities: input.qualities,
        qualityIndex: qualityIndex,
        subs: input.subs,
        danmaku: input.danmaku,
      );
    }

    final base = Uri.tryParse(input.site.api);
    if (target.startsWith('/') && base != null && base.hasScheme) {
      final resolved = resolveRelative(target, base);
      return PlaybackDecision(
        action: PlaybackAction.direct,
        url: resolved,
        headers: headers,
        flag: input.flag,
        qualities: input.qualities,
        qualityIndex: qualityIndex,
        subs: input.subs,
        danmaku: input.danmaku,
      );
    }

    final playUrl =
        asNonEmptyString(input.site.extra['playUrl']) ??
        asNonEmptyString(input.site.extra['playurl']);
    if (playUrl != null &&
        (playUrl.endsWith('=') || playUrl.contains('{id}'))) {
      final joined = joinPlayUrlPrefix(playUrl, target);
      if (looksLikeMediaUrl(joined)) {
        return PlaybackDecision(
          action: PlaybackAction.direct,
          url: joined,
          headers: headers,
          flag: input.flag,
          qualities: input.qualities,
          qualityIndex: qualityIndex,
          subs: input.subs,
          danmaku: input.danmaku,
        );
      }
      throw AppError(
        AppErrorKind.playbackUrlMissing,
        '站点 ${input.site.key} 的 playUrl 前缀拼接结果不是有效地址',
        detail: redactUrl(joined),
      );
    }

    throw AppError(
      AppErrorKind.playbackParserRequired,
      '剧集目标不是直链，且站点未声明 playUrl 前缀',
      detail: '站点=${input.site.key} 目标=${redactUrl(target)}',
    );
  }

  /// 媒体请求 Header：全局 headers 规则（按目标 host 匹配）+ 站点 header，
  /// 最后是播放结果 header（最高优先级，§7.4.6 步骤 4）。
  static HeaderMap _mediaHeaders(PlaybackResolutionInput input, String url) {
    final MediaRequestTarget target = MediaRequestTarget.of(url);
    return HeaderMap.merge([
      target.host.isEmpty
          ? HeaderMap()
          : globalHeadersFor(input.globalHeaders, target.host),
      input.site.header,
      input.resultHeader,
    ]);
  }
}

/// 媒体请求目标解析结果，便于测试与诊断。
class MediaRequestTarget {
  const MediaRequestTarget({required this.host, required this.scheme});

  final String host;
  final String scheme;

  static MediaRequestTarget of(String url) {
    final uri = Uri.tryParse(url.trim());
    return MediaRequestTarget(host: uri?.host ?? '', scheme: uri?.scheme ?? '');
  }
}

// ---------------------------------------------------------------------------
// 真播完判定（`docs/phase7/design/03` §4.1/§4.2）
// ---------------------------------------------------------------------------

/// 判定「真播完」的尾部余量（毫秒）。
///
/// 与 `SyncHistoryItem.completed`（`lib/core/android_sync.dart`）的 5000 一致：
/// 同一份语义在三个地方（本地落库、跨端同步、播放器闸门）必须同值，
/// 否则会出现「同步说播完、播放器说不播完」的错位（`design/03` §4.2）。
const int genuineEndMarginMs = 5000;

/// 「真播完」判定（`design/03` §4.1 的 `_isGenuineEnd`）。
///
/// **为什么不能直接采信播放器的 `completed`**：缓存耗尽时提前 EOF 会被
/// media_kit 报成 `completed=true`，而那时 `duration` 往往还没取到（为 0）。
/// 直接连播就会「跳下一集」——这正是用户实测的痛点（D2）。
///
/// 判定规则：
/// - `durationMs <= 0` → **false**（时长未知不等于播完）；
/// - `positionMs >= durationMs - [genuineEndMarginMs]` → true；
/// - 其余 → false。
///
/// 三个调用点共用本函数：播放器连播闸门、同步合并、安卓 `completed` 重算。
bool isGenuineEnd({
  required int durationMs,
  required int positionMs,
  int marginMs = genuineEndMarginMs,
}) {
  if (durationMs <= 0) return false;
  return positionMs >= durationMs - marginMs;
}

/// 跨端 `completed` 重算（`design/03` §4.2）。
///
/// **PC 一律不采信同步来的 `completed` 字段**：安卓用
/// `position >= duration || progress >= 0.95`，对 45 分钟的剧集意味着
/// 剩 135 s 就算播完，与 PC 的 5 s 余量**不等价**。采信它会让 PC 把
/// 「其实还剩两分多钟」的记录标记为已看完，进而让续播失效。
bool recomputeCompleted({required int durationMs, required int positionMs}) =>
    isGenuineEnd(durationMs: durationMs, positionMs: positionMs);

/// media_kit 的 `Duration` 形态入口（播放器调用点用）。
bool isGenuineEndDuration({
  required Duration duration,
  required Duration position,
  Duration margin = const Duration(milliseconds: genuineEndMarginMs),
}) => isGenuineEnd(
  durationMs: duration.inMilliseconds,
  positionMs: position.inMilliseconds,
  marginMs: margin.inMilliseconds,
);
