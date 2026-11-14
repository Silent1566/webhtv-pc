/// Phase 7 · 续播而非跳下一集（`docs/phase7/design/03` §6 第 8 条、`design/04` §3.4）。
///
/// 真实窗口 + 真实 SQLite + 真实播放器控件（`Video`），在 Windows 上跑。
///
/// 本套件锁定的是**用户实测痛点**：
/// 「缓存耗尽后跳下一集」与「失败后丢失续播上下文」。
///
/// 分两段：
///
/// **A 段（真实 UI 路径）**：真实壳层 → 分类 → 详情 → 播放页，
///   验证「进入播放页时带上了历史续播位置」且「未被连播切走」；
/// **B 段（闸门口径）**：在真实运行环境里验证 `isGenuineEnd` 的三条边界
///   （提前 EOF 形态必须拒绝连播）。
///
/// 提前 EOF 的**真实触发**需要人为截断媒体流（`design/03` §3.1 实验 A），
/// 那属于 `design/04` §7 的实测项 V5，结论落
/// `docs/phase7/evidence/03-resume-not-next.md`，不在本套件内伪造。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:webhtv_pc/core/playback.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:window_manager/window_manager.dart';

import '../test/fixture_support.dart';
import 'phase8_player_test_support.dart';

void evidence(String message) =>
    debugPrint('PHASE7-EVIDENCE resume-flow $message');

/// 删除测试临时目录：重试并容忍失败（与 `mvp_a_flow_test.dart` 同因：
/// `AppState.dispose()` 里有 `unawaited` 的异步句柄释放，Windows 上会
/// 短暂占用目录）。这是时序问题，不是产品缺陷。
void _deleteTempQuietly(Directory dir) {
  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      sleep(const Duration(milliseconds: 200));
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  setUpAll(() async {
    await windowManager.ensureInitialized();
  });

  testWidgets('提前 EOF 不跳集：续播位置与闸门口径（design/03 §4.1/§4.5）', (tester) async {
    final fixtureBase = fixtureBaseUrl;
    final configText = jsonEncode(
      jsonDecode(readFixture('config/config-e2e.json')),
    ).replaceAll('http://127.0.0.1:18080', fixtureBase);

    final temp = await Directory.systemTemp.createTemp('webhtv-resume-test');
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}${Platform.pathSeparator}config',
        'data': '${temp.path}${Platform.pathSeparator}data',
        'cache': '${temp.path}${Platform.pathSeparator}cache',
        'state': '${temp.path}${Platform.pathSeparator}logs',
      },
    );
    final state = AppState(paths: paths, log: LogService());
    addTearDown(() {
      state.dispose();
      _deleteTempQuietly(temp);
    });
    await state.bootstrap();

    final imported = await state.importConfig(configText, displayName: 'phase7-resume');
    expect(imported, isTrue, reason: state.lastError?.logLine);

    final home = state.homeResult!;
    await state.loadCategory(home.classes.first.typeId, page: 1);
    await state.loadDetail(state.categoryResult!.list.first);
    final vod = state.detailResult!.list.first;
    final line = state.playLinesOf(vod).first;
    final episode = line.episodes.first;
    final siteKey = state.selectedSite!.key;

    // 预置历史：进度停在**距结尾很远**的位置——这正是「提前 EOF」的形态。
    // 提前 EOF 时 duration 往往还没取到（或 position 远离片尾），
    // 因此 isGenuineEnd 必须返回 false，闸门不得放行连播。
    const farFromEnd = Duration(seconds: 30);
    state.recordProgress(
      vod: vod,
      flag: line.flag,
      episodeName: episode.name,
      episodeId: episode.url,
      position: farFromEnd,
      duration: const Duration(minutes: 40),
    );
    expect(
      state.resumePositionFor(
        siteKey: siteKey,
        vodId: vod.vodId,
        flag: line.flag,
        episodeId: episode.url,
      ),
      farFromEnd,
      reason: '预置历史必须可被续播查询命中',
    );

    // A 段：真实 UI 路径。先渲染壳层，再走详情页。
    await tester.pumpWidget(
      MaterialApp(home: AppShell(state: state, startup: const StartupArguments())),
    );
    await tester.pumpAndSettle(const Duration(seconds: 5));

    await tester.pumpWidget(
      MaterialApp(home: DetailPage(state: state, vod: vod)),
    );
    await tester.pumpAndSettle(const Duration(seconds: 5));

    final episodeCard = find.byKey(
      ValueKey('tmdb-episode-card-${line.flag}-0'),
    );
    for (var attempt = 0; attempt < 20; attempt++) {
      if (episodeCard.evaluate().isNotEmpty) {
        final rect = tester.getRect(episodeCard);
        if (rect.top >= 0 && rect.bottom <= tester.view.physicalSize.height) {
          break;
        }
      }
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
      await tester.pump();
    }
    expect(episodeCard, findsOneWidget, reason: '未找到剧集卡片入口');
    await tester.tap(episodeCard);
    // 点击剧集卡片后就落在 PlayerPage 上：屏显时钟每秒重绘，
    // 带时长的 `pumpAndSettle` 在这里永不 settle（见 phase8_player_test_support）。
    await settlePlayerPage(tester, total: const Duration(seconds: 10));

    final playerPage = tester.widget<PlayerPage>(find.byType(PlayerPage));
    expect(
      playerPage.request.startPosition,
      farFromEnd,
      reason: '进入播放页必须从历史位置续播（§15.2）',
    );
    expect(playerPage.request.episodeName, episode.name);
    evidence(
      'step=1 resume-ui episode=${episode.name} '
      'startPosition=${playerPage.request.startPosition?.inSeconds}s',
    );

    // 未被连播切走：页面仍停在原集（若连播误触发，集名会变成下一集）。
    expect(
      playerPage.request.episodeName,
      episode.name,
      reason: '进入播放页后仍应是原集（未被连播切走）',
    );
    evidence('step=2 stays-on-episode=${episode.name}');

    // B 段：闸门口径（在真实运行环境里验证）。
    // 提前 EOF 的形态 = position 远离片尾，此时即使播放器报 completed，
    // 闸门也必须拒绝连播。
    expect(
      isGenuineEndDuration(
        duration: const Duration(minutes: 40),
        position: farFromEnd,
      ),
      isFalse,
      reason: '远离片尾不得判为真播完（提前 EOF 的核心防线）',
    );
    evidence('step=3 genuine-end far-from-end=false');

    // duration 未知（缓存耗尽的典型形态）也必须拒绝。
    expect(
      isGenuineEndDuration(
        duration: Duration.zero,
        position: farFromEnd,
      ),
      isFalse,
      reason: 'duration<=0 不得判为真播完',
    );
    evidence('step=4 genuine-end duration-zero=false');

    // 真正播到片尾时才放行。
    expect(
      isGenuineEndDuration(
        duration: const Duration(minutes: 40),
        position: const Duration(minutes: 40) - const Duration(seconds: 5),
      ),
      isTrue,
      reason: '到达 5 s 余量内才允许连播',
    );
    evidence('step=5 genuine-end at-margin=true');

    // 释放播放器路由。
    final context = tester.element(find.byType(PlayerPage));
    Navigator.of(context).pop();
    // 路由退场动画期间播放器还在树里，ticker 也还在跑；
    // 带时长的 `pumpAndSettle` 会在这里挂到 10 分钟超时。
    await settlePlayerPage(tester, total: const Duration(seconds: 5));
    expect(find.byType(PlayerPage), findsNothing);
    evidence('step=6 player-released');
  });
}
