/// 打开一条历史记录对应的**详情页**（不是续播）：一处实现，多处调用。
///
/// 调用点：历史页的整卡点击（设置 = 进详情时）、首页「查看详情」按钮。
///
/// 语义约束：
/// - **优先用这条记录自己的站点**（= 用户上次看这部片用的播放源）：先切站点，
///   再带着线路 / 集 / 进度进详情，于是详情页里的线路与选集默认停在原处；
/// - 记录来自**别的配置源**时，交给既有的跨源流程（它自己会先试原配置，再在
///   当前源里找替代站点），这里只声明「我要详情」，不让用户设置把它变成起播；
/// - 站点已不在当前配置中时**不静默失败**：历史可能来自旧配置或安卓推送，
///   用户需要知道为什么没反应。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_error.dart';
import '../core/playback_request.dart';
import '../core/protocol.dart';
import '../core/push_parser.dart';
import '../services/storage.dart';
import '../state/app_state.dart';
import 'async_action_feedback.dart';
import 'browse_pages.dart';
import 'history_cross_source.dart';
import 'history_resume_seed.dart';
import 'push_detail_page.dart';
import 'toast.dart';

Future<void> openHistoryDetail(
  BuildContext context,
  AppState state,
  PlaybackHistory item,
) async {
  if (!context.mounted || ModalRoute.of(context)?.isCurrent == false) return;
  if (state.isHistoryFromOtherSource(item)) {
    await openHistoryFromOtherSource(
      context,
      state,
      item,
      // 按钮上写着「查看详情」，就不能因为用户把整卡点击设成「直接播」而起播。
      wantsPlayOverride: false,
    );
    return;
  }
  // 推送记录不属于任何配置站点（合成站点键 [pushSiteKey]）：它没有详情页可进，
  // 「这条片子是什么」只能靠手动指定元数据，所以别掉进下面的「站点已不在」。
  // 推送源还在配置里时，这条记录就是一条普通站点记录：走下面的标准路径
  // （选中站点 → 普通详情页）。只有源被删掉/改名了，才需要兜底页。
  if (item.siteKey == pushSiteKey) {
    // 推送记录没有站点详情可进：它的"详情页"就是推送详情（剧名/元数据/地址/
    // 播放与再匹配都在那里），与刚推送时进入的是同一页。
    final resumed = item.positionMs > 5000 && !item.completed
        ? Duration(milliseconds: item.positionMs)
        : null;
    final target = item.episodeId.trim().isEmpty
        ? item.vodId
        : item.episodeId;
    await openPushLanding(
      context,
      state,
      PlaybackRequest(
        url: target,
        title: item.vodName,
        siteKey: pushSiteKey,
        vodId: item.vodId,
        vodName: item.vodName,
        episodeName: item.episodeName.isEmpty ? item.vodName : item.episodeName,
        flag: item.flag.isEmpty ? pushSourceName : item.flag,
        startPosition: resumed,
      ),
      // 历史记录的片名就是当初的剧名：带进详情页，别让推送源的英文名/URL 覆盖它。
      parsed: parsePushFields(url: target, title: item.vodName),
    );
    return;
  }
  // 查**合并后**的站点集合：本地爬虫源只在那里，用 state.config 会让一条本地源
  // 播出来的记录直接落进「站点已不在当前配置中」。
  final site = state.siteInActiveSource(item.siteKey);
  if (site == null) {
    showToast('该记录所属站点已不在当前配置中：${item.siteKey}', kind: ToastKind.error);
    return;
  }
  final feedback = AsyncActionFeedback.begin(context, '正在打开详情：${item.vodName}');
  if (feedback == null) return;
  try {
    await state.selectSite(site);
    if (!context.mounted || !feedback.isCurrent) return;
    feedback.dismiss();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailPage(
          state: state,
          vod: Vod(
            vodId: item.vodId,
            vodName: item.vodName,
            vodPic: item.vodPic,
          ),
          // **必须传用户点的那一条**的线路与集入口：同一部剧有多条历史时，
          // 点旧记录却续新记录是错的（`docs/phase6/design/02` §7.1）。
          historyFlag: item.flag,
          historyEpisodeId: item.episodeId,
          // 进度也要传：`_play` 里那条「查本机历史」的路子依赖当前站点，
          // 站点被换过（同 url 不同 key、或配置重导入）就落空 → 从头播。
          resumeSeed: resumeSeedOf(item),
        ),
      ),
    );
  } catch (error) {
    if (context.mounted && feedback.isCurrent) {
      feedback.dismiss();
      showToast(
        error is AppError ? error.userMessage : '$error',
        kind: ToastKind.error,
      );
    }
  } finally {
    feedback.close();
  }
}
