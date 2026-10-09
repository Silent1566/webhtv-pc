/// 海报角标（年份 / 评分）门禁。
///
/// 参考实现（用户提供截图 2026-10-09）：海报**左上角年份**、**右下角评分**，
/// 标题在图片下方。webhtv-pc 原先只在标题下渲染一行 `vod_remarks` 纯文本。
///
/// **本文件锁定的核心约束：`vod_remarks` 不一定是评分。**
/// 实测同一批桥接站点里它是两类完全不同的东西：
/// - 豆瓣类站点（`片单导航[导]`）：`7.2` / `8.7` → 是**评分**；
/// - 网盘聚合类站点（`木偶[盘]`）：`全29集` / `已完结` / `更新至第10集` → 是**更新状态**。
///
/// 若把后者也当评分画成角标，界面上会出现「全29集」被当成分数这种荒谬结果。
/// 因此评分角标只在 remarks 确实解析为 0~10 数值时才渲染；否则保持原来的文字备注
/// （它本身是有用信息，不能丢）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/poster_badge.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';

Vod _vod({String? year, String? remarks}) =>
    Vod(vodId: 'v', vodName: '测试影片', vodYear: year, vodRemarks: remarks);

void main() {
  group('年份角标（poster_badge.dart）', () {
    test('标准 4 位年份', () {
      expect(PosterBadge.yearOf(_vod(year: '2024')), '2024');
    });

    test('带后缀 / 完整日期都能取出年份', () {
      expect(PosterBadge.yearOf(_vod(year: '2024年')), '2024');
      expect(PosterBadge.yearOf(_vod(year: '2024-01-01')), '2024');
      expect(PosterBadge.yearOf(_vod(year: '  2024  ')), '2024');
    });

    test('缺失或非年份 → null（不画角标）', () {
      expect(PosterBadge.yearOf(_vod()), isNull);
      expect(PosterBadge.yearOf(_vod(year: '')), isNull);
      expect(PosterBadge.yearOf(_vod(year: '待定')), isNull);
    });
  });

  group('评分角标：真实数据的两类 remarks', () {
    test('豆瓣类站点的评分被识别（真实取值）', () {
      // 真机实测（片单导航[导]）：7.2 / 7.5 / 6.6 / 8.7 / 7.3
      for (final score in const ['7.2', '7.5', '6.6', '8.7', '7.3']) {
        expect(
          PosterBadge.scoreOf(_vod(remarks: score)),
          score,
          reason: '$score 是豆瓣评分，应画评分角标',
        );
      }
    });

    test('网盘聚合站点的更新状态**不得**被当成评分（真实取值）', () {
      // 真机实测（木偶[盘]）：全29集 / 全40集 / 已完结 / 更新至第10集
      for (final remark in const [
        '全29集',
        '全40集',
        '已完结',
        '更新至第10集',
        '第 1 集',
      ]) {
        expect(
          PosterBadge.scoreOf(_vod(remarks: remark)),
          isNull,
          reason: '「$remark」是更新状态而不是评分，画成评分角标会荒谬',
        );
        expect(
          PosterBadge.textRemarkOf(_vod(remarks: remark)),
          remark,
          reason: '非评分的 remarks 必须保留为文字备注（信息不能丢）',
        );
      }
    });

    test('统一一位小数（避免同屏两种精度）', () {
      expect(PosterBadge.scoreOf(_vod(remarks: '8')), '8.0');
      expect(PosterBadge.scoreOf(_vod(remarks: '9.25')), '9.3');
    });

    test('边界：0 与 10 合法；越界 / 年份误入 → null', () {
      expect(PosterBadge.scoreOf(_vod(remarks: '0')), '0.0');
      expect(PosterBadge.scoreOf(_vod(remarks: '10')), '10.0');
      expect(PosterBadge.scoreOf(_vod(remarks: '10.1')), isNull);
      expect(
        PosterBadge.scoreOf(_vod(remarks: '2024')),
        isNull,
        reason: '2024 超过 10 分上限，是年份误入 remarks，不是评分',
      );
      expect(PosterBadge.scoreOf(_vod(remarks: '-1')), isNull);
    });

    test('只接受「纯十进制数值」：科学计数 / 前导点 / 正号都不得当评分', () {
      // 为什么需要这条：若只靠 `double.tryParse` + 0~10 范围，下面这些会被
      // 误判为评分（实测 `1e1` → 10.0、`.5` → 0.5）。真实站点不会给出这些形态，
      // 但它们一旦出现就会被画成一个荒谬的「评分」角标，因此必须按纯数值形态收窄。
      expect(
        PosterBadge.scoreOf(_vod(remarks: '1e1')),
        isNull,
        reason: '1e1 会被 double.tryParse 解析为 10.0，不是站点评分写法',
      );
      expect(PosterBadge.scoreOf(_vod(remarks: '.5')), isNull);
      expect(PosterBadge.scoreOf(_vod(remarks: '+7.2')), isNull);
      expect(PosterBadge.scoreOf(_vod(remarks: '7.')), isNull);
      expect(PosterBadge.scoreOf(_vod(remarks: '1_0')), isNull);
      // 正常形态仍应通过（防止收窄过度）。
      expect(PosterBadge.scoreOf(_vod(remarks: '7.2')), '7.2');
      expect(PosterBadge.scoreOf(_vod(remarks: '10')), '10.0');
      expect(PosterBadge.scoreOf(_vod(remarks: '0')), '0.0');
    });

    test('评分不再重复渲染为文字备注（避免角标与文字重复）', () {
      expect(PosterBadge.textRemarkOf(_vod(remarks: '7.2')), isNull);
    });

    test('缺失 remarks → 既无评分也无文字', () {
      expect(PosterBadge.scoreOf(_vod()), isNull);
      expect(PosterBadge.textRemarkOf(_vod()), isNull);
      expect(PosterBadge.textRemarkOf(_vod(remarks: '   ')), isNull);
    });
  });

  group('海报卡片真的把角标渲染出来（widget 级）', () {
    late Directory temp;
    late AppState state;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('webhtv-poster-badge');
      state = AppState(
        paths: AppPaths.resolve(
          overrides: {'roaming': temp.path, 'local': temp.path},
        ),
        log: LogService(),
      );
      await state.bootstrap();
      // `BrowsePage` 在没有配置时只渲染空态提示（无配置/未选站点/站点不可用），
      // 必须先导入一份配置（内联 JSON，不走网络）才能进到海报网格。
      final imported = await state.importConfig(
        jsonEncode({
          'name': '角标测试配置',
          'sites': [
            {
              'key': 'poster_site',
              'name': '角标测试站点',
              'type': 4,
              'api': 'http://127.0.0.1:19978/vod/api?key=poster_site',
            },
          ],
        }),
        displayName: '角标测试配置',
      );
      expect(imported, isTrue, reason: state.lastError?.logLine);
    });

    tearDown(() async {
      state.dispose();
      try {
        await temp.delete(recursive: true);
      } catch (_) {}
    });

    Future<void> pumpGrid(WidgetTester tester, List<Vod> list) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      // 注入列表（会覆盖导入时拉到的首页结果）。
      state.seedListingForTest(list);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: BrowsePage(state: state))),
      );
      await tester.pump();
    }

    testWidgets('豆瓣类站点：年份 + 评分角标同时出现', (tester) async {
      await pumpGrid(tester, [
        _vod(year: '2026', remarks: '7.2'),
      ]);

      expect(
        find.byKey(const ValueKey('poster-badge-year')),
        findsOneWidget,
        reason: '有年份时应渲染年份角标',
      );
      expect(
        find.byKey(const ValueKey('poster-badge-score')),
        findsOneWidget,
        reason: 'remarks 是 0~10 数值时应渲染评分角标',
      );
      expect(find.text('2026'), findsWidgets);
      expect(find.text('7.2'), findsWidgets);
      // 评分已由角标呈现，不应在标题下再重复一行文字。
      expect(
        find.text('7.2'),
        findsOneWidget,
        reason: '评分不应同时出现在角标和文字备注两处',
      );
    });

    testWidgets('网盘聚合站点：只有年份角标，更新状态作为文字备注保留', (tester) async {
      await pumpGrid(tester, [
        _vod(year: '2024', remarks: '全29集'),
      ]);

      expect(find.byKey(const ValueKey('poster-badge-year')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('poster-badge-score')),
        findsNothing,
        reason: '「全29集」是更新状态而不是评分，不得画评分角标',
      );
      expect(
        find.text('全29集'),
        findsWidgets,
        reason: '非评分的 remarks 必须保留为文字备注（信息不能丢）',
      );
    });

    testWidgets('无年份无评分：两个角标都不渲染（不画空角标）', (tester) async {
      await pumpGrid(tester, [Vod(vodId: 'v', vodName: '裸条目')]);

      expect(find.byKey(const ValueKey('poster-badge-year')), findsNothing);
      expect(find.byKey(const ValueKey('poster-badge-score')), findsNothing);
    });
  });
}
