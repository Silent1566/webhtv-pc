/// 字幕能力（§10.3「字幕轨选择」「外挂字幕」、§13.3「字幕可开启和关闭」）。
///
/// 这一层是纯逻辑：格式推断、外挂/内嵌候选构建、默认轨选择、错误隔离判定。
/// 不执行任何网络或播放器调用，便于用固定 fixture 做选择规则测试。
library;

import 'app_error.dart';
import 'protocol.dart';

/// 字幕来源：内嵌轨道（容器自带）或外挂字幕（`subs` / 用户指定地址）。
enum SubtitleSourceKind {
  /// 播放容器内的字幕轨（mkv/mp4/m3u8 自带）。
  embedded,

  /// 外挂字幕文件（SRT/ASS/SSA/VTT/SUB）。
  external,
}

/// 一条可选字幕轨（播放器菜单条目）。
class SubtitleOption {
  const SubtitleOption({
    required this.id,
    required this.label,
    required this.kind,
    this.language = '',
    this.isForced = false,
    this.isDefault = false,
    this.format = '',
    this.url,
  });

  /// 播放器内唯一标识：外挂为 `external:<index>`，内嵌为 `embedded:<trackId>`。
  final String id;
  final String label;
  final SubtitleSourceKind kind;
  final String language;
  final bool isForced;
  final bool isDefault;
  final String format;

  /// 仅外挂字幕有地址。
  final String? url;

  bool get isExternal => kind == SubtitleSourceKind.external;

  static const String offId = 'off';

  /// 关闭字幕的固定条目（§13.3「字幕可开启和关闭」）。
  static const SubtitleOption off = SubtitleOption(
    id: offId,
    label: '关闭字幕',
    kind: SubtitleSourceKind.embedded,
  );

  @override
  bool operator ==(Object other) => other is SubtitleOption && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'SubtitleOption(id=$id label=$label kind=${kind.name} '
      'forced=$isForced default=$isDefault format=$format url=${redactUrl(url)})';
}

/// 字幕相关错误分类（§10.4「解析失败」「格式不支持」在字幕上的对应语义）。
///
/// 设计文档要求字幕失败**不影响视频播放**，因此这里的错误只用于提示与日志，
/// 不允许升级为播放失败。
const Set<AppErrorKind> subtitleErrorKinds = {
  AppErrorKind.subtitleNetwork,
  AppErrorKind.subtitleHttp,
  AppErrorKind.subtitleTooLarge,
  AppErrorKind.subtitleDecode,
  AppErrorKind.subtitleUnsupported,
  AppErrorKind.subtitleEmpty,
};

/// 字幕失败的用户提示文案。
///
/// 字幕失败不是播放失败：文案必须显式说明“不影响播放”，否则用户会以为视频坏了
/// （§10.4 错误策略 + §13.3「字幕可开启和关闭」）。
String describeSubtitleFailure(Object? error) {
  if (error is AppError) {
    final message = describeErrorKind(error.kind);
    return '字幕加载失败：$message';
  }
  final text = error?.toString() ?? '未知错误';
  return '字幕加载失败：$text（不影响视频播放）';
}

/// 判断一个错误是否为字幕错误（用于“字幕失败不阻断播放”的隔离判定）。
bool isSubtitleError(Object? error) =>
    error is AppError && subtitleErrorKinds.contains(error.kind);

/// 支持的文本字幕扩展名（mpv/libass 可渲染）。
const Set<String> supportedSubtitleExtensions = {
  'srt',
  'ass',
  'ssa',
  'vtt',
  'sub',
  'txt',
};

/// 字幕 MIME 类型（与 Android 侧 `PlayerHelper.getSubtitleMimeType` 语义对齐）。
String subtitleMimeType(String path) {
  final extension = subtitleExtension(path);
  switch (extension) {
    case 'srt':
      return 'application/x-subrip';
    case 'ass':
    case 'ssa':
      return 'text/x-ssa';
    case 'vtt':
      return 'text/vtt';
    case 'sub':
      return 'text/x-microdvd';
    case 'txt':
      return 'text/plain';
    default:
      return '';
  }
}

/// 取地址末段的扩展名（小写，不含点）。无扩展名返回空串。
String subtitleExtension(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return '';
  // 地址可能带 query/fragment，先剥离再取扩展名。
  var candidate = trimmed;
  final question = candidate.indexOf('?');
  if (question >= 0) candidate = candidate.substring(0, question);
  final hash = candidate.indexOf('#');
  if (hash >= 0) candidate = candidate.substring(0, hash);
  final slash = candidate.lastIndexOf('/');
  final name = slash >= 0 ? candidate.substring(slash + 1) : candidate;
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

/// 从地址推断字幕格式：优先取扩展名，其次用声明值，最后退回 `srt`。
///
/// 返回空串表示无法判定（调用方应报 [AppErrorKind.subtitleUnsupported]）。
String inferSubtitleFormat(String url, {String declared = ''}) {
  final extension = subtitleExtension(url);
  if (extension.isNotEmpty && supportedSubtitleExtensions.contains(extension)) {
    return extension == 'txt' ? 'srt' : extension;
  }
  final normalized = declared.trim().toLowerCase();
  if (normalized.isEmpty) return '';
  // 声明值可能是 `application/x-subrip` 这类 MIME，取最后一段。
  final slash = normalized.lastIndexOf('/');
  final tail = slash >= 0 ? normalized.substring(slash + 1) : normalized;
  final stripped = tail.replaceFirst('x-', '');
  switch (stripped) {
    case 'subrip':
    case 'srt':
      return 'srt';
    case 'ssa':
    case 'ass':
      return stripped;
    case 'vtt':
      return 'vtt';
    case 'microdvd':
    case 'sub':
      return 'sub';
    case 'plain':
      return 'srt';
    default:
      return '';
  }
}

/// 由播放结果里的 `subs` 构建外挂字幕候选（缺失地址或格式不支持的条目丢弃）。
///
/// 丢弃时通过 [onDiscard] 上报，便于调用方记诊断而不是静默吞掉。
List<SubtitleOption> externalSubtitleOptions(
  List<SubtitleInfo> subs, {
  void Function(SubtitleInfo sub, String reason)? onDiscard,
}) {
  final options = <SubtitleOption>[];
  for (var index = 0; index < subs.length; index++) {
    final sub = subs[index];
    final url = sub.url.trim();
    if (url.isEmpty) {
      onDiscard?.call(sub, '缺少字幕地址');
      continue;
    }
    final format = inferSubtitleFormat(url, declared: sub.format);
    if (format.isEmpty) {
      onDiscard?.call(sub, '字幕格式不受支持：${sub.format.isEmpty ? url : sub.format}');
      continue;
    }
    options.add(
      SubtitleOption(
        id: 'external:$index',
        label: _labelFor(sub),
        kind: SubtitleSourceKind.external,
        language: sub.lang,
        isForced: sub.isForced,
        isDefault: sub.isDefault,
        format: format,
        url: url,
      ),
    );
  }
  return options;
}

String _labelFor(SubtitleInfo sub) {
  final base = sub.displayName;
  if (sub.lang.isNotEmpty && sub.name.isNotEmpty && sub.lang != sub.name) {
    return '$base（${sub.lang}）';
  }
  return base;
}

/// 由播放器上报的内嵌字幕轨构建候选。
///
/// [tracks] 为 `(id, title, language, isDefault)` 四元组，顺序即播放器给出的顺序。
/// media-kit 的 `Tracks.subtitle` 永远包含 `auto`/`no` 两个伪轨（§track.dart），
/// 这里统一过滤，避免菜单里出现无意义的条目。
/// 注意：media-kit 未暴露 `forced` 位，内嵌轨只有 `isDefault` 可用。
List<SubtitleOption> embeddedSubtitleOptions(
  Iterable<({String id, String title, String language, bool isDefault})> tracks,
) {
  final options = <SubtitleOption>[];
  for (final track in tracks) {
    if (!isRealSubtitleTrackId(track.id)) continue;
    final label = track.title.isNotEmpty
        ? track.title
        : (track.language.isNotEmpty ? track.language : '内嵌字幕 ${track.id}');
    options.add(
      SubtitleOption(
        id: 'embedded:${track.id}',
        label: track.language.isNotEmpty && track.title.isNotEmpty
            ? '$label（${track.language}）'
            : label,
        kind: SubtitleSourceKind.embedded,
        language: track.language,
        isDefault: track.isDefault,
      ),
    );
  }
  return options;
}

/// media-kit 为“自动/关闭”预留的伪轨 id，不是真实字幕轨。
const Set<String> pseudoSubtitleTrackIds = {'auto', 'no'};

/// 判断一个播放器字幕轨 id 是否为真实字幕轨（排除 `auto`/`no` 伪轨）。
bool isRealSubtitleTrackId(String id) =>
    id.trim().isNotEmpty && !pseudoSubtitleTrackIds.contains(id.trim());

/// 合并候选：外挂在前（用户/结果显式提供，优先级高），内嵌在后，末尾固定「关闭」。
List<SubtitleOption> subtitleMenu(
  List<SubtitleOption> external,
  List<SubtitleOption> embedded, {
  bool includeOff = true,
}) {
  final merged = <SubtitleOption>[
    ...external,
    ...embedded,
    if (includeOff) SubtitleOption.off,
  ];
  // 去重：同 id 只保留第一次出现（外挂优先）。
  final seen = <String>{};
  final result = <SubtitleOption>[];
  for (final option in merged) {
    if (seen.add(option.id)) result.add(option);
  }
  return result;
}

/// 默认字幕选择（§10.3）。
///
/// 规则（与媒体生态惯例一致，保证“进来就有字幕”但不强加）：
/// 1. 标记 `flag` 默认位（含 `flag == 0`）的外挂字幕优先；
/// 2. 其次标记默认位的内嵌轨；
/// 3. 再次 `forced` 轨（强制字幕）；
/// 4. 都没有时返回 `null`：不自动开字幕，避免给无需字幕的用户添噪。
SubtitleOption? defaultSubtitleOption(List<SubtitleOption> options) {
  for (final option in options) {
    if (option.isExternal && option.isDefault) return option;
  }
  for (final option in options) {
    if (!option.isExternal && option.isDefault) return option;
  }
  for (final option in options) {
    if (option.isForced) return option;
  }
  return null;
}

/// 选择是否跨集沿用（§10.3「字幕轨选择」在上下集切换后的行为）。
///
/// 外挂字幕跟随集数变化（地址不同），因此只在同一集内沿用；内嵌轨按
/// `language/forced` 语义沿用，找不到对应轨则回退默认选择。
SubtitleOption? resolveSelectionAfterSwitch({
  required SubtitleOption? previous,
  required List<SubtitleOption> options,
}) {
  if (previous == null) return null;
  if (previous.id == SubtitleOption.offId) return SubtitleOption.off;
  if (!previous.isExternal) {
    for (final option in options) {
      if (option.isExternal) continue;
      if (option.language == previous.language &&
          option.isForced == previous.isForced) {
        return option;
      }
    }
  }
  return defaultSubtitleOption(options);
}

/// 字幕地址是否能用播放器直接加载（http/https/本地文件）。
bool looksLikeSubtitleUrl(String target) {
  final trimmed = target.trim();
  if (trimmed.isEmpty) return false;
  final uri = Uri.tryParse(trimmed);
  if (uri != null && uri.hasScheme) {
    const schemes = {'http', 'https', 'file'};
    return schemes.contains(uri.scheme.toLowerCase());
  }
  // Windows 盘符路径（`C:\...`）会被误判为 scheme，按本地文件处理。
  return RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(trimmed);
}

/// 字节大小上限（5 MiB）：字幕是文本，超限说明地址很可能不是字幕文件。
const int maxSubtitleBytes = 5 * 1024 * 1024;
