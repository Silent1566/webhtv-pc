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
}

/// 播放决策器：只根据输入决定动作，不执行网络。
abstract final class PlaybackResolver {
  /// 返回直接播放决策，或抛出 [AppErrorKind.playbackParserRequired]。
  ///
  /// 规则（§7.4.8）：
  /// 1. `parse=1` 或 `jx=1` → 需要解析器，MVP-A 明确报错；
  /// 2. 绝对媒体地址 → 直接播放；
  /// 3. 相对路径 → 相对站点 api 解析后判断；
  /// 4. 站点 `playUrl` 前缀形态 → 拼接后判断；
  /// 5. 其余非 URL 目标 → 需要解析器/Spider，明确报错。
  static PlaybackDecision decide(PlaybackResolutionInput input) {
    final parseRequested = (input.parse ?? 0) == 1 || (input.jx ?? 0) == 1;
    if (parseRequested) {
      throw AppError(
        AppErrorKind.playbackParserRequired,
        '站点 ${input.site.key} 的剧集要求解析（parse=${input.parse} jx=${input.jx}）',
        detail: 'flag=${input.flag ?? ""}',
      );
    }

    final target = input.episodeTarget.trim();
    if (target.isEmpty) {
      throw AppError(
        AppErrorKind.playbackUrlMissing,
        '剧集 ${input.flag ?? ""} 缺少播放地址',
        detail: '站点=${input.site.key}',
      );
    }

    final headers = _mediaHeaders(input);

    if (looksLikeMediaUrl(target)) {
      return PlaybackDecision(
        action: PlaybackAction.direct,
        url: target,
        headers: headers,
        flag: input.flag,
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
      );
    }

    final playUrl = asNonEmptyString(input.site.extra['playUrl']) ??
        asNonEmptyString(input.site.extra['playurl']);
    if (playUrl != null && (playUrl.endsWith('=') || playUrl.contains('{id}'))) {
      final joined = joinPlayUrlPrefix(playUrl, target);
      if (looksLikeMediaUrl(joined)) {
        return PlaybackDecision(
          action: PlaybackAction.direct,
          url: joined,
          headers: headers,
          flag: input.flag,
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
  static HeaderMap _mediaHeaders(PlaybackResolutionInput input) {
    final MediaRequestTarget target = MediaRequestTarget.of(input.episodeTarget);
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
    return MediaRequestTarget(
      host: uri?.host ?? '',
      scheme: uri?.scheme ?? '',
    );
  }
}
