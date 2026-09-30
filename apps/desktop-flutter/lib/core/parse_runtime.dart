/// 解析器运行时核心（设计文档 §12「解析器设计」）。
///
/// 本层是纯逻辑：解析器选择、类型策略、错误分类，不执行网络请求。
/// 网络执行在 `lib/services/parse_service.dart`。
///
/// # 类型语义（对齐 Android `Parse.bean` 与 `ParseJob`）
///
/// | type | 名称 | PC 端支持 | 说明 |
/// |---|---|---|---|
/// | 0 | Web 嗅探 | **不支持** | 需要浏览器内核/WebView 嗅探页面加载（Android
///   用 `CustomWebView`），PC 端 media-kit/桌面环境无等价物；选择时不匹配并给出
///   明确错误。 |
/// | 1 | JSON 解析 | ✅ | `GET 解析器url + 目标url`，从响应 JSON 的
///   `url`/`data.url` 取媒体地址（对齐 Android `ParseJob.jsonParse`）。 |
/// | 2 | JSON 扩展 | ✅ | 携带全部 **type=1** 解析器为查找表，一次请求产出
///   url（对齐 `jsonExt`）。 |
/// | 3 | JSON Mix | ✅ | 携带 flag 与**全部**解析器 `ext`，一次请求产出 url
///   （对齐 `jsonExtMix`）。 |
/// | 4 | Super | **不支持** | 多解析器并发（JSON + Web 嗅探竞争），依赖
///   WebView；PC 端不支持并给出明确错误。 |
///
/// # 选择规则（设计 §12.2）
///
/// 1. 显式 flag 匹配：解析器 `ext.flag` 含该 flag 的优先（对齐 Android
///    `VodConfig.getParses(type, flag)`）；
/// 2. 否则用户选择的（`selected`）解析器；
/// 3. 否则第一个可用解析器；
/// 4. 任何被选中的解析器若类型不支持，抛出该类型的明确错误，不静默跳过。
library;

import 'protocol.dart';

/// 解析器类型（对齐 Android `Parse.type`）。
enum ParseKind {
  /// `type=0`：Web 嗅探。需浏览器内核，PC 端不支持。
  webSniff,

  /// `type=1`：JSON 解析。`GET url+target`，取 `url`/`data.url`。
  json,

  /// `type=2`：JSON 扩展。携带全部 type=1 解析器为查找表。
  jsonExtend,

  /// `type=3`：JSON Mix。携带 flag 与全部解析器。
  jsonMix,

  /// `type=4`：Super。多解析器并发，需 WebView，PC 端不支持。
  superParse,

  /// 未知类型（防御）。
  unknown,
}

/// 将配置里的解析器 type 数字映射为 [ParseKind]。
ParseKind parseKindOf(int type) => switch (type) {
  0 => ParseKind.webSniff,
  1 => ParseKind.json,
  2 => ParseKind.jsonExtend,
  3 => ParseKind.jsonMix,
  4 => ParseKind.superParse,
  _ => ParseKind.unknown,
};

/// 该类型在 PC 端可执行。
bool parseKindSupported(ParseKind kind) =>
    kind == ParseKind.json ||
    kind == ParseKind.jsonExtend ||
    kind == ParseKind.jsonMix;

/// 解析器选择结果。
class ParseSelection {
  const ParseSelection({required this.entry, required this.kind, this.matched});

  final ParseEntry entry;
  final ParseKind kind;

  /// 该解析器宣告支持的线路标识（`ext.flag`）；flag 匹配成功后为匹配到的原值。
  final String? matched;
}

/// 解析器选择错误分类。
enum ParseSelectionError {
  /// 配置里没有任何解析器。
  noneConfigured,

  /// 有解析器但没有支持 type=1/2/3 的（全部是 Web 嗅探/Super）。
  unsupportedOnly,

  /// 该 flag 没有匹配的解析器。
  noFlagMatch,

  /// 选中的解析器类型本身不支持（webSniff/superParse/unknown）。
  selectedUnsupported,
}

/// 解析器选择异常。
class ParseSelectionException implements Exception {
  const ParseSelectionException(this.kind, this.message);

  final ParseSelectionError kind;
  final String message;

  @override
  String toString() => message;
}

/// 解析器核心：选择解析器（纯逻辑，不联网）。
abstract final class ParseRuntime {
  /// 从配置的解析器列表按 §12.2 规则选择一个。
  ///
  /// [flag] 为当前播放结果的 `flag`（线路标识）；[preferFlag] 为是否优先 flag
  /// 匹配（Android 在 `jsonParses(flag)`/`superParse` 里优先 flag）。
  static ParseSelection select(
    List<ParseEntry> parses, {
    String? flag,
    String? preferName,
  }) {
    if (parses.isEmpty) {
      throw const ParseSelectionException(
        ParseSelectionError.noneConfigured,
        '配置没有声明任何解析器（parses 为空）',
      );
    }

    // 1) 用户显式选择（selected）。PC 端配置不持久化 selected 态，
    //    这里按「优先 flag 匹配 + preferName 指定」处理（对齐 Android
    //    `getSelected()` 的语义：用户显式选过一个解析器后优先它）。
    if (preferName != null) {
      final byName = parses.where((entry) => entry.name == preferName).toList();
      if (byName.isNotEmpty) return _seal(byName.first, flag);
    }

    // 2) 显式 flag 匹配。
    if (flag != null) {
      final byFlag = _matchFlag(parses, flag);
      if (byFlag.isNotEmpty) return _seal(byFlag.first, flag);
    }

    // 3) 优先支持的 JSON 类；其次任意。
    final supported = parses
        .where((entry) => parseKindSupported(parseKindOf(entry.type)))
        .toList();
    if (supported.isNotEmpty) return _seal(supported.first, flag);

    // 4) 只剩不支持的（Web 嗅探/Super）。
    final unsupported = parses
        .where((entry) => !parseKindSupported(parseKindOf(entry.type)))
        .toList();
    throw ParseSelectionException(
      ParseSelectionError.unsupportedOnly,
      '配置的解析器类型在 PC 端均不支持'
      '（${unsupported.first.name} type=${unsupported.first.type}，'
      '本版本支持 type=1/2/3 JSON 类）',
    );
  }

  static ParseSelection _seal(ParseEntry entry, String? flag) {
    final kind = parseKindOf(entry.type);
    if (!parseKindSupported(kind)) {
      throw ParseSelectionException(
        ParseSelectionError.selectedUnsupported,
        '选中解析器 ${entry.name} 类型不支持（type=${entry.type}；'
        'PC 端仅支持 JSON 类 type=1/2/3）',
      );
    }
    final flags = _entryFlags(entry);
    return ParseSelection(
      entry: entry,
      kind: kind,
      matched: flag != null && flags.contains(flag) ? flag : null,
    );
  }

  /// 解析器 `ext.flag`（Android `Parse.Ext.flag`：`List\<String\>`）。
  static List<String> _entryFlags(ParseEntry entry) {
    final ext = entry.ext;
    if (ext is Map) {
      final flags = ext['flag'];
      if (flags is List) return flags.whereType<String>().toList();
      if (flags is String) return [flags];
    }
    return const [];
  }

  static List<ParseEntry> _matchFlag(List<ParseEntry> entries, String? flag) {
    if (flag == null) return const [];
    return entries
        .where((entry) => _entryFlags(entry).contains(flag))
        .toList();
  }
}