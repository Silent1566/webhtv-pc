/// 详情页「同一个配置里、另一个爬虫源」的进度标记与续播选择（`design/02` §9）。
///
/// 用户实报（2026-11-29）：同一个配置下换一个爬虫源进同一部剧，详情页的选集
/// 卡片没有进度标记。根因是详情页只查「本站点 + 本剧 id」那一条历史，
/// 而记录落在另一个站点的 `site_key`/`vod_id` 上。
///
/// 本文件把三条用户可见语义钉住：
/// 1. **都标记、展示有差异**：别的源的记录用第三色角标 + 「其他源 N%」；
/// 2. **续播不替用户选**：两条以上可续播记录时，点首屏按钮先弹选择框，
///    取消就**不播**；
/// 3. **不猜集**：别的源的记录对不上当前剧集的任何一集时，既不标也不弹。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';

import 'support/detail_test_seams.dart';

void main() {
  late Directory tempDir;
  late AppState state;
  late String sourceKey;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-detail-cross-site');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${tempDir.path}/webhtv-pc',
          'data': '${tempDir.path}/webhtv-pc',
          'cache': '${tempDir.path}/webhtv-pc/cache',
          'state': '${tempDir.path}/webhtv-pc/logs',
        },
      ),
      log: MemoryOnlyLogService(),
      httpClient: MockClient(
        (request) async =>
            http.Response(jsonEncode(<String, Object?>{'list': []}), 200),
      ),
    );
    await bootstrapWithoutExternalMeta(state);
    final ok = await state.importConfig(
      jsonEncode(<String, Object?>{
        'sites': <Object?>[
          <String, Object?>{
            'key': 'site-a',
            'name': '甲站',
            'type': 3,
            'api': 'c1',
            'searchable': 1,
            'quickSearch': 1,
            'filter': 0,
          },
          <String, Object?>{
            'key': 'site-b',
            'name': '乙站',
            'type': 3,
            'api': 'c1',
            'searchable': 1,
            'quickSearch': 1,
            'filter': 0,
          },
        ],
      }),
      displayName: '测试源',
    );
    expect(ok, isTrue, reason: '前置：配置导入必须成功');
    await state.selectSite(state.siteByKey('site-a')!);
    sourceKey = state.activeSourceKey;
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  final vod = Vod(
    vodId: 'a-1',
    vodName: '剧集甲',
    vodPlayFrom: '线路一',
    vodPlayUrl: '第1集\$http://x/e1#第2集\$http://x/e2',
  );

  void seedOtherSourceEpisode({
    String episodeName = '第2集',
    String episodeId = 'http://b/e2',
    int updatedAt = 200,
  }) {
    state.database!.upsertHistory(
      siteKey: 'site-b',
      vodId: 'b-1',
      vodName: vod.vodName,
      flag: '乙站线路',
      episodeName: episodeName,
      episodeId: episodeId,
      positionMs: 600000,
      durationMs: 2400000,
      updatedAt: updatedAt,
      sourceKey: sourceKey,
    );
  }

  Future<void> pumpDetail(WidgetTester tester, {Vod? target}) async {
    final pageVod = target ?? vod;
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    state.seedDetailForTest(vod: pageVod);
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(state: state, vod: pageVod),
      ),
    );
    await tester.pump();
    // hero 占满首屏，选集区要滚进视口才会挂载。
    for (var attempt = 0; attempt < 20; attempt++) {
      if (find
              .byKey(const ValueKey('detail-hero-play'))
              .evaluate()
              .isNotEmpty &&
          find
              .byKey(const ValueKey('tmdb-episode-card-线路一-0'))
              .evaluate()
              .isNotEmpty) {
        break;
      }
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
      await tester.pump();
    }
  }

  /// 播放失败确认框里的集名：仓库既有的「播了哪一集」观测通道。
  Future<String?> playedEpisodeName(WidgetTester tester) async {
    final dialog = find.byKey(const ValueKey('detail-playback-failed'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (dialog.evaluate().isNotEmpty) break;
    }
    if (dialog.evaluate().isEmpty) return null;
    for (final text in tester.widgetList<Text>(
      find.descendant(of: dialog, matching: find.byType(Text)),
    )) {
      final data = text.data ?? '';
      if (data.startsWith('第')) return data;
    }
    return null;
  }

  testWidgets('别的源有记录、本站没有 → 卡片标出其他源，首屏从那一集续播', (tester) async {
    seedOtherSourceEpisode();
    await pumpDetail(tester);

    expect(
      find.byKey(const ValueKey('tmdb-episode-card-线路一-foreign-1')),
      findsOneWidget,
      reason: '别的源的记录要落在第 2 集那张卡上',
    );
    expect(find.textContaining('其他源'), findsWidgets);
    expect(
      find.textContaining('25%'),
      findsWidgets,
      reason: '600000/2400000 = 25%',
    );
    expect(find.text('继续播放 · 第2集'), findsOneWidget);
    // 默认续播目标用第三色底色；与没有记录的第 1 集保持可辨认。
    final activeCard = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('tmdb-episode-card-线路一-1')),
    );
    final plainCard = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('tmdb-episode-card-线路一-0')),
    );
    final theme = Theme.of(tester.element(find.byType(DetailPage)));
    expect(
      activeCard.style?.backgroundColor?.resolve(<WidgetState>{}),
      theme.colorScheme.tertiaryContainer,
      reason: '跨源续播目标用第三色底色，与本站主题色区分',
    );
    expect(
      plainCard.style?.backgroundColor?.resolve(<WidgetState>{}),
      isNull,
      reason: '没有记录的条目不能冒充续播目标',
    );
    expect(activeCard.style?.side?.resolve(<WidgetState>{}), isNull);

    await tester.tap(find.byKey(const ValueKey('detail-hero-play')));
    expect(await playedEpisodeName(tester), '第2集');
  });

  testWidgets('本站与别的源都有进度 → 点续播先选择，取消则不播', (tester) async {
    state.database!.upsertHistory(
      siteKey: 'site-a',
      vodId: vod.vodId,
      vodName: vod.vodName,
      flag: '线路一',
      episodeName: '第1集',
      episodeId: 'http://x/e1',
      positionMs: 30000,
      durationMs: 100000,
      updatedAt: 100,
      sourceKey: sourceKey,
    );
    seedOtherSourceEpisode(updatedAt: 200);
    await pumpDetail(tester);

    expect(find.text('继续播放（2 条记录）'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('detail-hero-play')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('history-progress-dialog')),
      findsOneWidget,
    );
    // 本站那条标「本站」，别的源写站点名：两种记录在弹框里也要能一眼分开。
    expect(find.text('本站'), findsWidgets);
    expect(find.text('乙站'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('history-progress-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('history-progress-dialog')), findsNothing);
    expect(
      find.byKey(const ValueKey('detail-playback-failed')),
      findsNothing,
      reason: '取消 = 不替用户选，也不播',
    );
  });

  testWidgets('选择别的源那条记录后，播的是它对应的那一集', (tester) async {
    state.database!.upsertHistory(
      siteKey: 'site-a',
      vodId: vod.vodId,
      vodName: vod.vodName,
      flag: '线路一',
      episodeName: '第1集',
      episodeId: 'http://x/e1',
      positionMs: 30000,
      durationMs: 100000,
      updatedAt: 100,
      sourceKey: sourceKey,
    );
    seedOtherSourceEpisode(updatedAt: 200);
    await pumpDetail(tester);

    await tester.tap(find.byKey(const ValueKey('detail-hero-play')));
    await tester.pumpAndSettle();
    // 选项按最近观看倒序：索引 0 是乙站（第2集），索引 1 是本站（第1集）。
    await tester.tap(find.byKey(const ValueKey('history-progress-option-0')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('history-progress-confirm')));
    await tester.pumpAndSettle();

    expect(await playedEpisodeName(tester), '第2集');
  });

  testWidgets('别的源记录对不上任何一集 → 不标也不弹', (tester) async {
    seedOtherSourceEpisode(episodeName: '第99集', episodeId: 'http://b/e99');
    await pumpDetail(tester);

    expect(
      find.byKey(const ValueKey('tmdb-episode-card-线路一-foreign-0')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('tmdb-episode-card-线路一-recent-0')),
      findsNothing,
    );
    expect(find.text('播放第一集'), findsOneWidget);
  });

  /// 两条线路、集名顺序不同：用来区分「按目标线路的原始下标」与「按当前线路的下标」。
  final multiLineVod = Vod(
    vodId: 'a-2',
    vodName: '剧集乙',
    vodPlayFrom: '线路一\$\$\$线路二',
    vodPlayUrl:
        '第1集\$http://x/e1#第2集\$http://x/e2'
        '\$\$\$'
        '第3集\$http://y/e3#第1集\$http://y/e1',
  );

  void seedMultiLine(Vod pageVod) {
    // 本站：线路二第 1 集；别的源：更新，映射到线路二第 3 集。
    state.database!.upsertHistory(
      siteKey: 'site-a',
      vodId: pageVod.vodId,
      vodName: pageVod.vodName,
      flag: '线路二',
      episodeName: '第1集',
      episodeId: 'http://y/e1',
      positionMs: 30000,
      durationMs: 100000,
      updatedAt: 100,
      sourceKey: sourceKey,
    );
    state.database!.upsertHistory(
      siteKey: 'site-b',
      vodId: 'b-2',
      vodName: pageVod.vodName,
      flag: '乙站线路',
      episodeName: '第2集',
      episodeId: 'http://b/e2',
      positionMs: 600000,
      durationMs: 2400000,
      updatedAt: 200,
      sourceKey: sourceKey,
    );
  }

  testWidgets('本站记录在第二条线路时，进详情仍自动选中那条线路', (tester) async {
    // 回归钉子：跨源目标恒映射到「当前线路」，若拿它做自动选线路，
    // `_selectedLineFlag` 会被钉死在线路一且不再重解析（§4 的既有语义丢失）。
    seedMultiLine(multiLineVod);
    await pumpDetail(tester, target: multiLineVod);

    final second = tester.widget<ChoiceChip>(
      find.byKey(const ValueKey('tmdb-line-线路二')),
    );
    expect(second.selected, isTrue, reason: '改造前就是回到本站上次那条线路');
    final first = tester.widget<ChoiceChip>(
      find.byKey(const ValueKey('tmdb-line-线路一')),
    );
    expect(first.selected, isFalse);
    // 线路 chip 的「最近播放」只标本站那条线路。
    expect(find.byKey(const ValueKey('tmdb-line-recent-线路二')), findsOneWidget);
    expect(find.byKey(const ValueKey('tmdb-line-recent-线路一')), findsNothing);
  });

  testWidgets('切到别的线路后，选择框里的本站记录仍按它自己的线路播放', (tester) async {
    // 关键形状：用户进页后**手动切走**到线路一，此时本站记录还在线路二。
    // 选择框里的「本站」下标是按线路二算的，若套用当前线路（线路一）的下标，
    // 「第1集」会播成线路一的第 2 集——线路与集同时错。
    seedMultiLine(multiLineVod);
    await pumpDetail(tester, target: multiLineVod);
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const ValueKey('tmdb-line-线路二')))
          .selected,
      isTrue,
    );

    // 切到线路一：别的源的第 2 集在这里才映射得上。
    await tester.tap(find.byKey(const ValueKey('tmdb-line-线路一')));
    await tester.pump();
    expect(find.text('继续播放（2 条记录）'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('detail-hero-play')));
    await tester.pumpAndSettle();
    // 默认目标是更新的别的源（第 0 行）；本站那条在它后面。
    await tester.tap(find.byKey(const ValueKey('history-progress-option-1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('history-progress-confirm')));
    await tester.pumpAndSettle();

    expect(
      await playedEpisodeName(tester),
      '第1集',
      reason: '本站记录在线路二的第 1 集；套用线路一的下标会播成第 2 集',
    );
  });

  testWidgets('本站记录已看完、别的源可续播时，默认用别的源直接续播', (tester) async {
    // 用户规则：只有一条**可续播**记录时直接续播。本站那条已看完，
    // 不能因为它更新/存在就把唯一的可续播记录藏起来。
    state.database!.upsertHistory(
      siteKey: 'site-a',
      vodId: vod.vodId,
      vodName: vod.vodName,
      flag: '线路一',
      episodeName: '第1集',
      episodeId: 'http://x/e1',
      positionMs: 100000,
      durationMs: 100000,
      updatedAt: 300,
      completed: true,
      sourceKey: sourceKey,
    );
    seedOtherSourceEpisode(updatedAt: 200);
    await pumpDetail(tester);

    expect(find.text('继续播放 · 第2集'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('detail-hero-play')));
    expect(await playedEpisodeName(tester), '第2集');
  });

  testWidgets('只有本站记录时，切到别的线路后点续播仍播它自己那条线路的集', (tester) async {
    // 与选择框分支同一个坑（既有问题）：目标下标是按线路二算的，拿当前线路
    // （用户手切的线路一）去播会播成另一集。
    state.database!.upsertHistory(
      siteKey: 'site-a',
      vodId: multiLineVod.vodId,
      vodName: multiLineVod.vodName,
      flag: '线路二',
      episodeName: '第1集',
      episodeId: 'http://y/e1',
      positionMs: 30000,
      durationMs: 100000,
      updatedAt: 100,
      sourceKey: sourceKey,
    );
    await pumpDetail(tester, target: multiLineVod);
    expect(find.text('继续播放 · 第1集'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tmdb-line-线路一')));
    await tester.pump();
    expect(find.text('继续播放 · 第1集'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('detail-hero-play')));
    expect(
      await playedEpisodeName(tester),
      '第1集',
      reason: '本站记录在线路二第 1 集；套线路一的下标会播成第 2 集',
    );
  });
}
