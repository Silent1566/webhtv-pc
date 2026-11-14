/// 源场（星等星表的 signature move）的回归测试。
///
/// 为什么单独一个文件、且值得存在：
///
/// 1. **星等判级是产品判断，不是物理常数。** "一次失败不足以判死一个源"
///    （见 [kMinSamplesForFailed]）这条规则必须被测试钉住——否则以后有人
///    把阈值改松，界面就会开始对用户谎报"这个源失效了"。
/// 2. **主题扩展在裸 `MaterialApp` 下的回落是真实踩过的崩溃点。**
///    改造过程中 `_LegendCount` 因为 `context.semanticColors` 用了 `!`
///    而抛 `Null check operator used on a null value`，导致
///    `test/phase3_poster_badge_test.dart` 全线挂掉（那些测试用裸
///    `MaterialApp` pump 页面、不传 `theme:`）。回落行为必须被钉住。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/spider_router.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/source_field.dart';
import 'package:webhtv_pc/ui/theme.dart';

Site _site(String key, String name) =>
    Site(key: key, name: name, type: 1, api: 'https://example.test/$key');

SiteListItem _item(
  String key,
  String name, {
  bool available = true,
  String? reason,
}) => SiteListItem(
  site: _site(key, name),
  availability: SiteAvailability(
    available: available,
    runtimeName: 'http',
    reason: reason,
  ),
);

/// 构造一条实测健康记录：四个动作里只填 `home`，其余为 0。
SiteHealth _health(String key, {required int ok, required int total}) =>
    SiteHealth(
      siteKey: key,
      homeOk: ok,
      homeTotal: total,
      categoryOk: 0,
      categoryTotal: 0,
      detailOk: 0,
      detailTotal: 0,
      playOk: 0,
      playTotal: 0,
      avgLatencyMs: 120,
      lastError: null,
      updatedAt: DateTime(2026, 1, 1),
    );

SiteMagnitude _magnitudeOf(String key, List<SiteMagnitude> list) =>
    list.firstWhere((item) => item.siteKey == key);

void main() {
  group('星等判级（源场的语义核心）', () {
    test('成功率达标的源是「可用」', () {
      final result = buildMagnitudes(
        items: [_item('a', '甲')],
        health: {'a': _health('a', ok: 9, total: 10)},
      );
      expect(_magnitudeOf('a', result).status, SourceStatus.ok);
      expect(_magnitudeOf('a', result).rate, closeTo(0.9, 1e-9));
    });

    test('成功率偏低但有成功的是「降级」，不是「失效」', () {
      final result = buildMagnitudes(
        items: [_item('a', '甲')],
        health: {'a': _health('a', ok: 4, total: 10)},
      );
      expect(_magnitudeOf('a', result).status, SourceStatus.degraded);
    });

    test('样本足够且一次都没成功才是「失效」', () {
      final result = buildMagnitudes(
        items: [_item('a', '甲')],
        health: {'a': _health('a', ok: 0, total: 5)},
      );
      expect(_magnitudeOf('a', result).status, SourceStatus.failed);
    });

    test('样本不足时即使 0 成功也只算「降级」——一次失败不足以判死一个源', () {
      final result = buildMagnitudes(
        items: [_item('a', '甲')],
        health: {'a': _health('a', ok: 0, total: 1)},
      );
      expect(
        _magnitudeOf('a', result).status,
        SourceStatus.degraded,
        reason: '1 次采样不构成"这个源死了"的证据',
      );
    });

    test('没有实测记录是「未知」，绝不并入「可用」', () {
      final result = buildMagnitudes(
        items: [_item('a', '甲')],
        health: const {},
      );
      final magnitude = _magnitudeOf('a', result);
      expect(magnitude.status, SourceStatus.unknown);
      expect(magnitude.rate, isNull, reason: '无样本必须是 null，不是 0');
    });

    test('运行时不支持的源是「失效」并带上原因', () {
      final result = buildMagnitudes(
        items: [_item('a', '甲', available: false, reason: '运行时未安装')],
        health: const {},
      );
      final magnitude = _magnitudeOf('a', result);
      expect(magnitude.status, SourceStatus.failed);
      expect(magnitude.note, '运行时未安装');
    });

    test('按星等降序排列：最可用的一眼在左上', () {
      final result = buildMagnitudes(
        items: [
          _item('dark', '暗星'),
          _item('bright', '亮星'),
          _item('mid', '中星'),
        ],
        health: {
          'dark': _health('dark', ok: 0, total: 1),
          'bright': _health('bright', ok: 10, total: 10),
          'mid': _health('mid', ok: 7, total: 10),
        },
      );
      expect(result.map((item) => item.siteKey).toList(), [
        'bright',
        'mid',
        'dark',
      ]);
    });

    test('星等越大点越大；未知点最小但可见', () {
      final result = buildMagnitudes(
        items: [_item('full', '满星'), _item('half', '半星'), _item('none', '未知')],
        health: {
          'full': _health('full', ok: 10, total: 10),
          'half': _health('half', ok: 5, total: 10),
        },
      );
      final full = _magnitudeOf('full', result).diameter;
      final half = _magnitudeOf('half', result).diameter;
      final none = _magnitudeOf('none', result).diameter;

      // 断言关系而不是具体像素：尺度会随视觉复核调整，
      // 但"星等决定点径、未知最小且仍可见"这条语义不能变。
      expect(full, greaterThan(half));
      expect(half, greaterThan(none));
      expect(none, greaterThan(0));
    });
  });

  group('源场渲染', () {
    testWidgets('裸 MaterialApp（无主题扩展）下不崩，并回落到默认语义色', (tester) async {
      final magnitudes = buildMagnitudes(
        items: [
          _item('a', '甲'),
          _item('b', '乙'),
          _item('c', '丙', available: false, reason: '运行时未安装'),
        ],
        health: {
          'a': _health('a', ok: 10, total: 10),
          'b': _health('b', ok: 0, total: 5),
        },
      );

      // 关键：**不传 `theme:`**。改造过程中这个组合抛过
      // `Null check operator used on a null value`。
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SourceField(magnitudes: magnitudes),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(SourceField), findsOneWidget);
    });

    testWidgets('图例计数与状态一一对应', (tester) async {
      final magnitudes = buildMagnitudes(
        items: [
          _item('ok', '可用源'),
          _item('degraded', '降级源'),
          _item('failed', '失效源'),
          _item('unknown', '未知源'),
          _item('unsupported', '不支持的源', available: false, reason: '运行时未安装'),
        ],
        health: {
          'ok': _health('ok', ok: 10, total: 10),
          'degraded': _health('degraded', ok: 5, total: 10),
          'failed': _health('failed', ok: 0, total: 5),
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(body: SourceField(magnitudes: magnitudes)),
        ),
      );

      expect(tester.takeException(), isNull);
      // 四个状态名都在图例里出现。
      for (final label in ['可用', '降级', '失效', '未知']) {
        expect(find.text(label), findsOneWidget, reason: '图例缺少「$label」');
      }
      // 失效 2 个（实测失效 + 运行时不支持），可用/降级/未知 各 1 个。
      expect(find.text('2'), findsOneWidget);
      expect(find.text('1'), findsNWidgets(3));
    });

    testWidgets('空清单不渲染点阵，也不抛异常', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const Scaffold(body: SourceField(magnitudes: [])),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('当前配置没有可用站点'), findsOneWidget);
    });
  });
}
