/// 解析接口失败切换（`docs/phase9/README.md` P1-4）。
///
/// 只做「当前接口失败后按配置顺序尝试其他接口」：
/// - 默认关闭，行为与 Phase 3–8 完全一致；
/// - 不做用户自定义排序：没有排序 UI 的配置等于假功能，等有界面再加；
/// - 候选包含 `type=0`（Web 嗅探）与 `type=4`（Super）——它们现在可执行，
///   不再被当成「不支持」跳过。
///
/// # 候选排序规则（与纯配置顺序的唯一差异）
///
/// 1. 首选接口永远第一个跑（调用方直接传入，不参与本文件的排序）；
/// 2. 其余候选中**先 JSON 类（`type=1/2/3`），后嗅探类（`type=0/4`）**；
/// 3. 两类**内部各自保持配置顺序**；`maxAttempts` 的截断在排完序之后做，
///    所以「前几个候选」= JSON 类优先的那几个。
///
/// 为什么这样排：JSON 类是一次 HTTP 请求（安卓 `TIMEOUT_PARSE_DEF` 15s 量级），
/// 嗅探类必须开浏览器（`type=0` 30s、`type=4` 90s）。若按纯配置顺序，一条排在
/// 前面的嗅探条目就能把「几秒内可完成的回退」拖成分钟级等待——失败切换的本意
/// 是尽快拿到可播地址，而不是把配置逐条试完。代价只有这一处与配置顺序不同。
library;

import 'parse_runtime.dart';
import 'protocol.dart';

class ParseFailoverSettings {
  const ParseFailoverSettings({this.enabled = false, this.maxAttempts = 2});

  const ParseFailoverSettings.defaults() : this();

  /// 是否允许失败后尝试其他接口。
  final bool enabled;

  /// 单次播放最多尝试几个接口（含首选）；至少 1。
  final int maxAttempts;

  ParseFailoverSettings normalized() =>
      ParseFailoverSettings(enabled: enabled, maxAttempts: _clamp(maxAttempts));

  ParseFailoverSettings copyWith({bool? enabled, int? maxAttempts}) =>
      ParseFailoverSettings(
        enabled: enabled ?? this.enabled,
        maxAttempts: _clamp(maxAttempts ?? this.maxAttempts),
      );

  static int _clamp(int value) => value < 1 ? 1 : (value > 5 ? 5 : value);

  Map<String, Object?> toJson() => <String, Object?>{
    'enabled': enabled,
    'maxAttempts': maxAttempts,
  };

  factory ParseFailoverSettings.fromJson(Object? raw) {
    final map = raw is Map ? raw : const {};
    final attempts = map['maxAttempts'];
    return ParseFailoverSettings(
      enabled: map['enabled'] is bool ? map['enabled'] as bool : false,
      maxAttempts: attempts is num ? _clamp(attempts.toInt()) : 2,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ParseFailoverSettings &&
      other.enabled == enabled &&
      other.maxAttempts == maxAttempts;

  @override
  int get hashCode => Object.hash(enabled, maxAttempts);

  @override
  String toString() =>
      'ParseFailoverSettings(enabled=$enabled, maxAttempts=$maxAttempts)';
}

/// 构造失败切换的候选列表（不含首选）：先 JSON 类、后嗅探类，各自内部保持
/// 配置顺序（排序规则与原因见文件头）。
///
/// 规则：
/// - `enabled == false` 或 `maxAttempts <= 1` → 空表；
/// - 收 `type=0/1/2/3/4`；类型未知的跳过；
/// - 需要 `url` 的类型（`0/1/2/3`）要求 `url` 非空；`type=4` 不需要
///   （安卓 `Parse.god()` 就是 type=4 + 空 url：Super 自己挑解析器）；
/// - 先 JSON 类（`1/2/3`）再嗅探类（`0/4`），各自内部保持配置顺序；
/// - 按 `name + url` 去重，避免同一条目被重复尝试；
/// - 总数不超过 `maxAttempts - 1`。
List<ParseSelection> parseFailoverSelections({
  required ParseSelection primary,
  required List<ParseEntry> entries,
  required ParseFailoverSettings settings,
}) {
  if (!settings.enabled || settings.maxAttempts <= 1) return const [];
  final normalized = settings.normalized();
  final seen = <String>{_key(primary.entry)};
  final jsonLike = <ParseSelection>[];
  final sniffLike = <ParseSelection>[];
  for (final entry in entries) {
    final kind = parseKindOf(entry.type);
    if (!parseKindSupported(kind)) continue;
    final url = entry.url?.trim() ?? '';
    if (url.isEmpty && kind != ParseKind.superParse) continue;
    if (!seen.add(_key(entry))) continue;
    final selection = ParseSelection(entry: entry, kind: kind);
    if (kind == ParseKind.webSniff || kind == ParseKind.superParse) {
      sniffLike.add(selection);
    } else {
      jsonLike.add(selection);
    }
  }
  return [
    ...jsonLike,
    ...sniffLike,
  ].take(normalized.maxAttempts - 1).toList(growable: false);
}

String _key(ParseEntry entry) => '${entry.name}\u0000${entry.url ?? ''}';
