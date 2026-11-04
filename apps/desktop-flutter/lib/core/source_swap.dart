/// 换源合并助手：把**外部站点**的线路并入当前详情页线路时需要的两件纯函数。
///
/// 为什么要单独一层：并入后的 [VodPlayLine.flag] 必须**页面内唯一**（详情页
/// 线路 chip 的 key、最近播放标记、外部来源色点都按 flag 索引），而
/// [VodPlayLine.playbackFlag] 又必须**仍然指向目标站点自己的线路标识**——播放
/// 时要拿它回站源解析真实地址。两件事必须分开做，混在一起就会出现
/// 「并入后点播放，站源告诉你没有这条线路」。
///
/// 本文件只依赖协议层，不碰 UI、不做网络请求：
/// 合并规则要能被单测逐条钉住，而不是在浮层里顺手拼字符串。
library;

import 'protocol.dart';

/// 外部线路并入后的显示 flag：`站点名 · 原线路名`。
///
/// [taken] 是页面内已占用的 flag 集合（只读语义，本函数**不**修改它）。
/// 重名时依次追加 ` (2)`、` (3)`……直到不冲突——**不是**无限追加随机串：
/// 后缀必须是可预测的序号，否则用户每次并入看到的名字都不一样。
String externalLineFlag({
  required String siteName,
  required String lineFlag,
  required Set<String> taken,
}) {
  // 空线路名没有可读的"原线路名"，与 [VodPlayLine.displayName] 保持同一个
  // 回落（`线路`），避免并入后出现「A 站 · 」这种悬空的中点。
  final original = lineFlag.trim().isEmpty ? '线路' : lineFlag;
  final base = '$siteName · $original';
  if (!taken.contains(base)) return base;
  var suffix = 2;
  while (taken.contains('$base ($suffix)')) {
    suffix += 1;
  }
  return '$base ($suffix)';
}

/// 把一条外部站点的线路包装成详情页可直接渲染的线路。
///
/// - `flag` 走 [externalLineFlag]，保证页面内唯一；
/// - `sourceFlag` **保留**原 `line.playbackFlag`——播放时靠它定向解析到目标
///   站点自己的线路，而不是回报文里的展示名；
/// - 新 flag 写回 [taken]，让后续并入的行接上序号。
VodPlayLine externalPlayLine({
  required String siteName,
  required VodPlayLine line,
  required Set<String> taken,
}) {
  final flag = externalLineFlag(
    siteName: siteName,
    lineFlag: line.flag,
    taken: taken,
  );
  taken.add(flag);
  return VodPlayLine(
    flag: flag,
    episodes: line.episodes,
    sourceFlag: line.playbackFlag,
  );
}

/// 一条外部线路的**来源路由**：播放时必须按它定向解析到这一个站点。
///
/// 键是并入后的页面内 flag（见 [externalLineFlag]），值是来源站点与它自己的
/// `vod_id`——两者都不是当前全局站源，也绝不能写回全局站源。
class SwapLineRoute {
  const SwapLineRoute({
    required this.siteKey,
    required this.siteName,
    required this.vodId,
  });

  final String siteKey;
  final String siteName;
  final String vodId;
}
