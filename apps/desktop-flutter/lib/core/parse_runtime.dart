/// 解析器运行时核心（设计文档 §12「解析器设计」）。
///
/// 本层是纯逻辑：解析器选择、类型策略、错误分类，不执行网络请求。
/// 网络执行在 `lib/services/parse_service.dart`。
///
/// # 类型语义（对齐 Android `Parse.bean` 与 `ParseJob`）
///
/// | type | 名称 | PC 端 | 说明 |
/// |---|---|---|---|
/// | 0 | Web 嗅探 | ✅ | 用本机浏览器内核打开「解析器 url + 目标」，从页面请求里
///   抓媒体地址（对齐 `ParseJob.doInBackground` 的 `startWeb`）。缺浏览器内核时
///   抛 `parseSniffUnavailable`，不静默降级成直链。 |
/// | 1 | JSON 解析 | ✅ | `GET 解析器url + 目标url`，从响应 JSON 的
///   `url`/`data.url` 取媒体地址（对齐 Android `ParseJob.jsonParse`）。 |
/// | 2 | JSON 扩展 | ✅ | 携带全部 **type=1** 解析器为查找表，一次请求产出
///   url（对齐 `jsonExt`）。 |
/// | 3 | JSON Mix | ✅ | 携带 flag 与**全部**解析器 `ext`，一次请求产出 url
///   （对齐 `jsonExtMix`）。 |
/// | 4 | Super | ✅ | `type=1` 解析器并发 + `type=0` 解析器按优先级串行，
///   第一个成功即胜出（对齐 `ParseJob.superParse`）。 |
/// | 其它 | 未知 | ❌ | 未知类型无法执行，选择时给出可诊断错误。 |
///
/// # 选择规则（设计 §12.2）
///
/// 1. 显式名称（`parse:<name>` 前缀或用户选择的 `preferName`）；
/// 2. 显式 flag 匹配：解析器 `ext.flag` 含该 flag 的优先（对齐 Android
///    `VodConfig.getParses(type, flag)`）；
/// 3. 否则第一个已知类型的解析器（Android 默认取配置里选中的那条）；
/// 4. 类型未知的解析器不参与选择；若只剩它，抛出可诊断错误，不静默跳过。
library;

import 'protocol.dart';

/// 解析器类型（对齐 Android `Parse.type`）。
enum ParseKind {
  /// `type=0`：Web 嗅探。需要本机浏览器内核（`lib/core/sniff/`）。
  webSniff,

  /// `type=1`：JSON 解析。`GET url+target`，取 `url`/`data.url`。
  json,

  /// `type=2`：JSON 扩展。携带全部 type=1 解析器为查找表。
  jsonExtend,

  /// `type=3`：JSON Mix。携带 flag 与全部解析器。
  jsonMix,

  /// `type=4`：Super。JSON 解析器并发 + Web 嗅探串行竞速。
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
///
/// 0/4 已与安卓对齐可执行：它们的浏览器依赖由
/// `lib/core/sniff/sniff_engine_factory.dart` 提供，缺引擎时在执行期抛
/// `parseSniffUnavailable`（而不是在选择期假装「不支持」）。
bool parseKindSupported(ParseKind kind) => switch (kind) {
  ParseKind.webSniff ||
  ParseKind.json ||
  ParseKind.jsonExtend ||
  ParseKind.jsonMix ||
  ParseKind.superParse => true,
  ParseKind.unknown => false,
};

/// 已知类型清单（错误文案用）。
const String knownParseKinds = 'type=0/1/2/3/4';

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

  /// 有解析器，但类型全部未知（无法执行）。
  unsupportedOnly,

  /// 该 flag 没有匹配的解析器。
  noFlagMatch,

  /// 选中的解析器类型未知。
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
  /// [flag] 为当前播放结果的 `flag`（线路标识）；[preferName] 为
  /// `parse:<name>` 前缀指定或用户显式选择的解析器名称。
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

    // 1) 显式指定名称（`parse:<name>` / 用户显式选择的解析器）。
    if (preferName != null) {
      for (final entry in parses) {
        if (entry.name == preferName) return _seal(entry, flag);
      }
    }

    // 2) 显式 flag 匹配。
    if (flag != null) {
      final byFlag = _matchFlag(parses, flag);
      if (byFlag.isNotEmpty) return _seal(byFlag.first, flag);
    }

    final supported = parses
        .where((entry) => parseKindSupported(parseKindOf(entry.type)))
        .toList();

    // 3) 第一个已知类型的解析器（安卓默认取配置里选中的那条）。
    if (supported.isNotEmpty) return _seal(supported.first, flag);

    // 4) 只剩未知类型的：如实报错，不静默跳过。
    final unknown = parses.firstWhere(
      (entry) => !parseKindSupported(parseKindOf(entry.type)),
    );
    throw ParseSelectionException(
      ParseSelectionError.unsupportedOnly,
      '配置的解析器类型未知，无法执行'
      '（${unknown.name} type=${unknown.type}；已知类型：$knownParseKinds）',
    );
  }

  static ParseSelection _seal(ParseEntry entry, String? flag) {
    final kind = parseKindOf(entry.type);
    if (!parseKindSupported(kind)) {
      throw ParseSelectionException(
        ParseSelectionError.selectedUnsupported,
        '选中解析器 ${entry.name} 的类型未知（type=${entry.type}），无法执行；'
        '已知类型：$knownParseKinds',
      );
    }
    final flags = _entryFlags(entry);
    return ParseSelection(
      entry: entry,
      kind: kind,
      matched: flag != null && flags.contains(flag) ? flag : null,
    );
  }

  /// 解析器 `ext.flag`（Android `Parse.Ext.flag`：`List<String>`）。
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
