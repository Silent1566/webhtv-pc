/// 手动网盘账号：已证明的 provider、条目标记与全局共享语义。
///
/// 标记只由 JVM 适配器加在真实 PanConfig 源条目上；Dart 只接受
/// [VodAccountActionKey] 里的结构化 map，并且只认四个精确的
/// ID/操作组合。未知、伪造或 schema 不符的标记一律按普通条目处理，
/// 因此远端 Vod 无法借标记写出任意偏好键。
library;

import 'protocol.dart';

/// 条目标记的字段名（JVM 生成，Dart 只读）。
///
/// 名称与 JVM 侧字段保持一致，作为跨语言契约常量导出。
// ignore: constant_identifier_names
const String VodAccountActionKey = '_webhtv_accountAction';

/// 支持的账号操作：进入手动编辑，或显式清除全局共享值。
enum SpiderAccountOperation { edit, clear }

/// 已证明可用的网盘 provider。
///
/// [preferenceKey] 是站源读取的偏好键，任何入口都不接受调用方传入键名。
enum SpiderAccountProvider {
  quark(label: '夸克', preferenceKey: 'Wex_quark_cookie'),
  baidu(label: '百度网盘', preferenceKey: 'Wex_baidu_cookie');

  const SpiderAccountProvider({
    required this.label,
    required this.preferenceKey,
  });

  final String label;
  final String preferenceKey;
}

/// 账号已保存，但随后的分类刷新没有完成。
///
/// 只有「源与分类仍是发起刷新时那一个」才会抛出；UI 据此提示
/// 「保存成功，刷新未完成」并提供重试，而不是谎称已刷新。
/// 异常不带任何站点/账号内容，只用于区分「刷新失败」这一事实。
class SpiderAccountRefreshException implements Exception {
  const SpiderAccountRefreshException();

  /// 固定脱敏文案常量：不含站点 key、Cookie 值、响应体或客户端错误文本。
  static const String fixedMessage = '账号已保存，分类刷新未完成';

  /// 实例可读的固定文案；任何调用方都可直接 `error.message`。
  String get message => fixedMessage;

  @override
  String toString() => 'SpiderAccountRefreshException: $message';
}

/// 一个通过校验的账号操作。
class SpiderAccountAction {
  const SpiderAccountAction({
    required this.provider,
    required this.operation,
    this.scanOnly = false,
  });

  final SpiderAccountProvider provider;
  final SpiderAccountOperation operation;

  /// 该条目在桌面端只能手动填写 Cookie：扫码/注册动作无法在 Playwright
  /// 之外的宿主里完成，UI 需要据此解释而不是打开普通详情页。
  final bool scanOnly;

  /// 四个精确组合：ID 必须与标记里的 provider/operation 同时吻合。
  static const Map<String, SpiderAccountAction> _byVodId = {
    'quarkmanual': SpiderAccountAction(
      provider: SpiderAccountProvider.quark,
      operation: SpiderAccountOperation.edit,
    ),
    'quarkclear': SpiderAccountAction(
      provider: SpiderAccountProvider.quark,
      operation: SpiderAccountOperation.clear,
    ),
    'baidumanual': SpiderAccountAction(
      provider: SpiderAccountProvider.baidu,
      operation: SpiderAccountOperation.edit,
    ),
    'baiduclear': SpiderAccountAction(
      provider: SpiderAccountProvider.baidu,
      operation: SpiderAccountOperation.clear,
    ),
    // 扫码/注册条目：同一 provider 的 edit，但桌面端只能手动填 Cookie。
    'quark': SpiderAccountAction(
      provider: SpiderAccountProvider.quark,
      operation: SpiderAccountOperation.edit,
      scanOnly: true,
    ),
    'qkregister': SpiderAccountAction(
      provider: SpiderAccountProvider.quark,
      operation: SpiderAccountOperation.edit,
      scanOnly: true,
    ),
    'baidu': SpiderAccountAction(
      provider: SpiderAccountProvider.baidu,
      operation: SpiderAccountOperation.edit,
      scanOnly: true,
    ),
    'baiduregister': SpiderAccountAction(
      provider: SpiderAccountProvider.baidu,
      operation: SpiderAccountOperation.edit,
      scanOnly: true,
    ),
  };

  static const Set<String> _markerFields = {
    'version',
    'provider',
    'operation',
  };

  /// 解析条目上的账号标记；不合法时返回 null（条目继续按普通媒体处理）。
  ///
  /// 不做标题/URL 启发式判断：只有 JVM 写入的结构化标记才算数。
  static SpiderAccountAction? fromVod(Vod vod) {
    final raw = vod.extra[VodAccountActionKey];
    if (raw is! Map) return null;
    if (raw.length != _markerFields.length) return null;
    if (!_markerFields.every(raw.containsKey)) return null;
    final version = raw['version'];
    if (version is! int || version != 1) return null;

    final expected = _byVodId[vod.vodId];
    if (expected == null) return null;
    if (raw['provider'] is! String || raw['operation'] is! String) return null;
    if (raw['provider'] != expected.provider.name) return null;
    if (raw['operation'] != expected.operation.name) return null;
    return expected;
  }
}
