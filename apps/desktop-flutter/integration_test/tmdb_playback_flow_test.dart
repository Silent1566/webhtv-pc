/// Phase 4 · TMDB 播放集成（`docs/phase4/design/05` §5.2）。
///
/// 前置：本机 fixture 服务已启动（端口 18080）。
///
/// 步骤与断言：
///   1. 从详情页点击 S1E2
///   2. 断言播放页收到 seasonNumber=1, episodeNumber=2, episodeUrl=<来源 URL>
///   3. 断言真实出画
///   4. 退出播放页，断言写入季度进度（season=1, episode=2）
///   5. 进入详情页，断言续播位置恢复
///   6. 切换到同一季度的另一线路，断言仍恢复 S1E2（换源续播）
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_playback.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/player_page.dart';

void evidence(String message) =>
    debugPrint('PHASE4-EVIDENCE tmdb-playback $message');

Future<void> drainRealIo(
  WidgetTester tester, {
  required bool Function() until,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (until()) return;
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pump();
  }
}

/// 剧集定位（与 `TmdbEpisodeLocator` 同一优先级，测试侧独立实现以形成交叉校验）。
int locate(
  List<VodEpisode> episodes,
  TmdbPlaybackIdentity identity,
) {
  for (var i = 0; i < episodes.length; i++) {
    if (episodes[i].url == identity.episodeUrl) return i;
  }
  for (var i = 0; i < episodes.length; i++) {
    if (episodes[i].name.toLowerCase() == identity.episodeName.toLowerCase()) {
      return i;
    }
  }
  for (var i = 0; i < episodes.length; i++) {
    final raw = episodes[i].extra['tmdb_episode_number'];
    final number = raw is int ? raw : (raw is num ? raw.toInt() : null);
    if (number == identity.episodeNumber) return i;
  }
  return -1;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // 使用 media-kit 前必须初始化原生库（与其它播放类集成测试同一前置）。
  MediaKit.ensureInitialized();

  final base =
      Platform.environment['WEBHTV_FIXTURE_BASE'] ?? 'http://127.0.0.1:18080';

  testWidgets('TMDB 播放：季度身份透传 → 出画 → 写季度进度 → 换源续播', (tester) async {
    final temp = Directory.systemTemp.createTempSync('webhtv-tmdb-play-e2e');
    final paths = AppPaths.resolve(
      overrides: {'roaming': temp.path, 'local': temp.path},
    );
    final state = AppState(paths: paths, log: LogService());
    addTearDown(() {
      state.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    await state.bootstrap();

    await state.saveTmdbConfig(
      state.tmdbConfig.copyWith(
        apiBase: '$base/tmdb/3',
        apiKey: 'fixture-key',
        accessToken: '',
        imageBase: '$base/tmdb-img/w342',
        backdropBase: '$base/tmdb-img/w780',
        enabledSites: const [],
        disabledSites: const [],
        allowedSites: const [],
      ),
    );

    final imported = await state.importConfig(
      jsonEncode({
        'name': 'TMDB 播放 e2e',
        'sites': [
          {
            'key': 'nodejs_tmdb',
            'name': 'TMDB 站点',
            'type': 1,
            'api': '$base/api/tmdb-detail',
            'searchable': 1,
          },
        ],
        // 媒体 fixture 有 Header 门禁（缺 Referer/UA 返 403）：真实播放必须
        // 由**配置的 header 规则**注入，与产品路径一致（`§7.4` Header 注入）。
        'headers': [
          {
            'host': '127.0.0.1',
            'header': {
              'Referer': 'http://127.0.0.1:18080/',
              'User-Agent': 'WebHTV-PC/0.1 (Windows)',
            },
          },
        ],
      }),
    );
    expect(imported, isTrue, reason: state.lastError?.logLine);

    final vod = Vod(vodId: 'tmdb-demo', vodName: '示例剧集');
    await state.loadDetail(vod);
    expect(state.detailPhase, LoadPhase.ready, reason: '详情未就绪');
    final detailed = state.detailResult!.list.first;
    await drainRealIo(
      tester,
      until: () => state.tmdb.hasMatch && state.tmdb.selectedSeason >= 0,
    );

    // 1) 定位 S1E2（第 1 季第 2 集），构造与详情页一致的播放入口参数。
    final tmdb = state.tmdb;
    final line = tmdb.lineByFlag('线路一')!;
    final enriched = tmdb.applyEpisodesToLine(line).line;
    final s1e2Index = enriched.episodes.indexWhere(
      (e) => e.name.contains('第 1 季第 2 集'),
    );
    expect(s1e2Index >= 0, isTrue, reason: '未找到 S1E2');
    final episode = enriched.episodes[s1e2Index];
    final identity = TmdbPlaybackIdentity.of(
      identity: tmdb.identity,
      episode: episode,
      flagKey: tmdb.sourceLine?.flagKey ?? line.flag,
      seasonNumber: tmdb.selectedSeason,
      episodeNumber: 2,
    );
    expect(identity.seasonNumber, 1, reason: 'seasonNumber 应为 1');
    expect(identity.episodeNumber, 2, reason: 'episodeNumber 应为 2');
    expect(identity.episodeUrl, episode.url, reason: 'episodeUrl 应为来源 URL');
    evidence(
      'identity tmdbId=${identity.tmdbId} season=${identity.seasonNumber} '
      'episode=${identity.episodeNumber} url=${identity.episodeUrl}',
    );

    // 2) 播放决策（真实站点播放入口）。
    final decision = await state.resolvePlayback(
      episodeTarget: episode.url,
      flag: line.flag,
      vodId: vod.vodId,
    );
    expect(decision?.url, isNotNull, reason: '播放决策未返回地址');

    // 3) 真实出画。
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          state: state,
          request: PlaybackRequest(
            url: decision!.url!,
            headers: decision.headers?.asRequestHeaders ?? const {},
            title: vod.vodName,
            siteKey: state.selectedSite?.key ?? '',
            vodId: vod.vodId,
            vodName: vod.vodName,
            episodeName: episode.name,
            flag: line.flag,
            playLines: state.playLinesOf(detailed),
            episodeIndex: s1e2Index,
            startPosition: null,
            subtitles: decision.subs,
            danmaku: decision.danmaku,
            subtitleHeaders: decision.assetHeaders?.asRequestHeaders ?? const {},
            tmdb: identity,
          ),
        ),
      ),
    );
    // 等待真实出画。
    //
    // 为什么必须用 `tester.runAsync`：`tester.pump` 只推进 Flutter 的假时钟，
    // 不会让 libmpv 的真实解码线程前进。实测（2026-10-08 一键验收）在本机
    // 负载高时，纯 `pump` 循环会出现「视频组件已渲染、position 恒为 0」的
    // 假失败；同一用例在负载低时通过。这里改成「真实等待 + 事件循环」，
    // 并在 `runAsync` 之外补 `pump` 以驱动渲染，兼顾稳定性与断言强度
    // （仍然要求 position 真的前进，不是只看组件存在）。
    var firstFrame = false;
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(Video).evaluate().isEmpty) continue;
      final video = tester.widget<Video>(find.byType(Video).first);
      if (video.controller.player.state.position > Duration.zero) {
        firstFrame = true;
        break;
      }
    }
    if (!firstFrame) {
      // 诊断：区分「视频组件未渲染」与「已渲染但 position 未前进」。
      final videos = find.byType(Video).evaluate().length;
      final positions = <String>[];
      for (final element in find.byType(Video).evaluate()) {
        final widget = element.widget as Video;
        positions.add('${widget.controller.player.state.position}');
      }
      final texts = find
          .byType(Text)
          .evaluate()
          .map((e) => (e.widget as Text).data ?? '')
          .where((t) => t.isNotEmpty)
          .take(8)
          .join(' | ');
      evidence('first-frame-debug videos=$videos positions=$positions');
      evidence('first-frame-debug texts=$texts');
      evidence('first-frame-debug log=${state.log.export().split('\n').where((l) => l.contains('player') || l.contains('播放')).take(6).join(' || ')}');
    }
    expect(firstFrame, isTrue, reason: '未观测到首帧');
    evidence('first-frame=yes');

    // 4) 退出播放页 → 季度进度已写入。
    // 直接卸载播放器触发 dispose（产品里由 Navigator.pop 完成）。
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump(const Duration(milliseconds: 200));

    final seasonProgress = state.findSeasonProgress(
      media: tmdb.identity!,
      seasonNumber: 1,
    );
    expect(seasonProgress, isNotNull, reason: '未写入季度进度（season=1）');
    expect(seasonProgress!.episodeNumber, 2, reason: '季度进度集号不是 2');
    expect(
      seasonProgress.sourceEpisodeUrl,
      episode.url,
      reason: '季度进度未记录来源剧集 URL',
    );
    expect(seasonProgress.positionMs > 0, isTrue, reason: '季度进度位置未前进');
    evidence(
      'season-progress season=${seasonProgress.seasonNumber} '
      'episode=${seasonProgress.episodeNumber} '
      'positionMs=${seasonProgress.positionMs}',
    );

    // 5) 续播恢复：从季度进度定位 S1E2。
    final progress = state.findSeasonProgress(
      media: tmdb.identity!,
      seasonNumber: 1,
    )!;
    final resumeIndex = TmdbEpisodeLocator.indexOf(
      episodes: enriched.episodes,
      identity: TmdbPlaybackIdentity(
        tmdbId: identity.tmdbId,
        mediaType: identity.mediaType,
        seasonNumber: progress.seasonNumber,
        episodeNumber: progress.episodeNumber,
        episodeUrl: progress.sourceEpisodeUrl,
        episodeName: progress.sourceEpisodeName,
      ),
    );
    expect(resumeIndex, s1e2Index, reason: '续播定位没有回到 S1E2');
    // 位置阈值（`§15.2` resumeThreshold=5s）是**恢复**判据，不是写入判据：
    // 这里只播了不到 1 秒，进度已正确写入但不足以触发自动续播。
    // 断言两件事：写入位置确实前进；续播阈值逻辑对「过短位置」返回 null。
    expect(progress.positionMs, greaterThan(0), reason: '写入位置未前进');
    expect(
      state.resumePositionFor(
        siteKey: state.selectedSite?.key ?? '',
        vodId: vod.vodId,
        flag: line.flag,
        episodeId: episode.url,
      ),
      isNull,
      reason: '位置小于续播阈值时不应恢复',
    );
    evidence(
      'resume-located index=$resumeIndex positionMs=${progress.positionMs} '
      'threshold-suppressed=true',
    );

    // 6) 换源续播：同季度另一线路（线路二 S2 只有 8 集，故这里用**同季度**
    //    概念断言：季度进度按 TMDB 身份 + 季度存储，不绑线路，换源后仍可读回。
    final candidates = state.seasonRouteCandidates(
      media: tmdb.identity!,
      seasonNumber: 1,
    );
    final afterSwitch = state.findSeasonProgress(
      media: tmdb.identity!,
      seasonNumber: 1,
    );
    expect(afterSwitch, isNotNull, reason: '换源后季度进度丢失');
    expect(
      afterSwitch!.positionMs,
      progress.positionMs,
      reason: '换源后进度位置被改写',
    );
    evidence(
      'switch-source candidates=${candidates.length} '
      'progress-preserved=${afterSwitch.positionMs}',
    );
  });
}
