/// 播放源（source）的稳定标识。
///
/// 桥接重构后 PC 同时持有两类源：
/// - **本地源**：用户在 PC 上导入的配置，坐标是它的 `origin`；
/// - **安卓源**：安卓设备上的某一个点播配置，坐标是设备 uuid + 该配置的
///   `interfaceKey`（安卓 `Config.ensureInterfaceKey()` 生成的稳定 UUID）。
///
/// 为什么用 `interfaceKey` 而不是设备地址或配置名：设备地址会随
/// `adb forward` 端口与 DHCP 变化，配置名用户可以随时改；只有 `interfaceKey`
/// 是安卓侧主动持久化、改名与换地址都不变的身份。
///
/// 纯逻辑层：不依赖 Flutter、不依赖 `dart:io`、不依赖 `services/`。理由与
/// `history_view.dart`、`playback_identity.dart` 一致——这个字符串会被写进
/// 历史表的唯一键，构造规则一旦漂移，历史就会在用户毫无察觉的情况下
/// "分裂"成两份，必须在无窗口环境下可单测。
library;

/// 本地源标识的类型前缀。
const String sourceKeyKindLocal = 'local';

/// 安卓源标识的类型前缀。
const String sourceKeyKindBridge = 'bridge';

/// 无法识别的标识。
///
/// 刻意不是"猜成 local"：把陌生标识当本地源会让两条不同来源的历史合并到
/// 同一分区，那是**数据损坏**而不是显示问题（P5"不猜"）。
const String sourceKeyKindUnknown = 'unknown';

/// 分段分隔符。`interfaceKey` 是 UUID、设备 uuid 与 origin 都不含它，
/// 但仍然按"出现即替换"处理，保证 [parseSourceKey] 的分段永远可靠。
const String _separator = '|';

/// 把任意分量清洗成不含分隔符的形式。
String _sanitize(String value) => value.trim().replaceAll(_separator, '_');

/// 本地源标识：`local|<origin>`。
///
/// `origin` 会做最小规范化（去首尾空白、去掉结尾的 `/`）：`https://a.com/`
/// 与 `https://a.com` 指向同一份配置，若当成两个源，用户每次改动地址都会
/// 丢掉此前的历史。
abstract final class LocalSourceKey {
  /// 由配置的 origin 构造本地源标识。
  static String of(String origin) {
    final normalized = normalizeOrigin(origin);
    return '$sourceKeyKindLocal$_separator$normalized';
  }

  /// 规范化 origin：只做**不改变语义**的处理。
  ///
  /// 不做小写化：`host` 大小写不敏感但 `path` 敏感，而 PC 侧的 origin 一律由
  /// `normalizeBase`/`Uri` 产出，已经足够稳定；额外小写化反而会让已经入库的
  /// 旧键全部失配。
  static String normalizeOrigin(String origin) {
    var text = origin.trim();
    while (text.length > 1 && text.endsWith('/')) {
      text = text.substring(0, text.length - 1);
    }
    return text;
  }
}

/// 安卓源标识：`bridge|<deviceUuid>|<interfaceKey>`。
abstract final class BridgeSourceKey {
  /// 由设备 uuid 与该配置的 `interfaceKey` 构造安卓源标识。
  ///
  /// 任一为空则返回空串——**不**退化成 `bridge||`：那会让"不知道是哪个源"
  /// 变成一个真实分区，把所有取值失败的记录都塞进去。
  static String of({required String deviceUuid, required String interfaceKey}) {
    final device = _sanitize(deviceUuid);
    final key = _sanitize(interfaceKey);
    if (device.isEmpty || key.isEmpty) return '';
    return '$sourceKeyKindBridge$_separator$device$_separator$key';
  }
}

/// 解析后的源标识。
class SourceKey {
  const SourceKey._({
    required this.raw,
    required this.kind,
    this.origin = '',
    this.deviceUuid = '',
    this.interfaceKey = '',
  });

  /// 原始字符串（`trim` 之后）。
  final String raw;

  /// [sourceKeyKindLocal] / [sourceKeyKindBridge] / [sourceKeyKindUnknown]。
  final String kind;

  /// 本地源的 origin；非本地源为空串。
  final String origin;

  /// 安卓源的设备 uuid；非安卓源为空串。
  final String deviceUuid;

  /// 安卓源的 `interfaceKey`；非安卓源为空串。
  final String interfaceKey;

  bool get isLocal => kind == sourceKeyKindLocal;

  bool get isBridge => kind == sourceKeyKindBridge;

  /// 是否为可识别的源。未知源只用于**展示与诊断**，不得参与历史分区决策。
  bool get isKnown => isLocal || isBridge;

  /// 用于日志与 UI 副标题的短标签。
  String get shortLabel {
    if (isLocal) return origin;
    if (isBridge) {
      final tail = interfaceKey.length > 8
          ? interfaceKey.substring(0, 8)
          : interfaceKey;
      return '$deviceUuid/$tail';
    }
    return raw;
  }

  @override
  bool operator ==(Object other) => other is SourceKey && other.raw == raw;

  @override
  int get hashCode => raw.hashCode;

  @override
  String toString() => raw;
}

/// 解析源标识；任何无法识别的输入都回落到 [sourceKeyKindUnknown]。
///
/// 未知输入**不抛异常**：历史表里可能残留旧版本写下的键，读出时崩掉会让
/// 整个历史页不可用，而"显示为未知源"是可接受的降级。
SourceKey parseSourceKey(String? raw) {
  final text = (raw ?? '').trim();
  if (text.isEmpty) {
    return const SourceKey._(raw: '', kind: sourceKeyKindUnknown);
  }
  final parts = text.split(_separator);
  if (parts.length >= 2 && parts.first == sourceKeyKindLocal) {
    final origin = parts.sublist(1).join(_separator);
    if (origin.isEmpty) {
      return SourceKey._(raw: text, kind: sourceKeyKindUnknown);
    }
    return SourceKey._(raw: text, kind: sourceKeyKindLocal, origin: origin);
  }
  if (parts.length >= 3 && parts.first == sourceKeyKindBridge) {
    final device = parts[1];
    final key = parts.sublist(2).join(_separator);
    if (device.isEmpty || key.isEmpty) {
      return SourceKey._(raw: text, kind: sourceKeyKindUnknown);
    }
    return SourceKey._(
      raw: text,
      kind: sourceKeyKindBridge,
      deviceUuid: device,
      interfaceKey: key,
    );
  }
  return SourceKey._(raw: text, kind: sourceKeyKindUnknown);
}
