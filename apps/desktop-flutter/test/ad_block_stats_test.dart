/// 去广告统计与日志（安卓 AdBlockStats/AdBlockStatsStore/AdBlockLog/AdBlockLogFilter 的 PC 化）。
///
/// 覆盖的关键行为：
/// - 纯模型：序列化往返、脏 JSON 逐字段降级、1000 条滚动、时间倒序导出；
/// - 落盘：原子写 read-back 一致、读坏文件降级为空统计并给 loadError；
/// - 入口：回退（abandoned）与未改动都不记账，四类计数各自累加、reset 可重入；
/// - 筛选：同列多值 OR、跨列 AND、大小写与空白不敏感。
///
/// 纪律：每个用例都在 Directory.systemTemp 下建真实目录，绝不碰用户状态目录。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/ad_block_stats.dart';
import 'package:webhtv_pc/core/ad_rules.dart';
import 'package:webhtv_pc/services/ad_block_stats_service.dart';
import 'package:webhtv_pc/services/ad_block_stats_store.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/ui/ad_block_stats_page.dart';

AdBlockLog blockLog(
  int blockedAt, {
  String siteKey = 'site-a',
  String siteName = 'A 站',
  String siteDomain = 'a.example.com',
  String pipeline = 'proxy',
  String adDomain = 'ads.example.com',
  String ruleId = 'r1',
  String vodName = '某剧',
  String lineName = '线路一',
  String episodeName = '第 1 集',
  double start = 0,
  double duration = 6,
}) => AdBlockLog(
  blockedAt: blockedAt,
  siteKey: siteKey,
  siteName: siteName,
  siteDomain: siteDomain,
  pipeline: pipeline,
  adDomain: adDomain,
  ruleId: ruleId,
  vodName: vodName,
  lineName: lineName,
  episodeName: episodeName,
  segmentStartSeconds: start,
  segmentDurationSeconds: duration,
);

const AdBlockContext context = AdBlockContext(
  siteKey: 'site-a',
  siteName: 'A 站',
  siteDomain: 'a.example.com',
  pipeline: 'proxy',
  vodName: '某剧',
  lineName: '线路一',
  episodeName: '第 1 集',
);

/// 一段被删广告的固定形状：60 秒处 6 秒。
HlsCleanResult cleanedResult({
  String ruleId = 'r1',
  String host = 'ads.example.com',
  double start = 60,
  double duration = 6,
  int segments = 1,
}) => HlsCleanResult(
  text: '#EXTM3U\n',
  removedSegments: segments,
  removedDurationSec: duration * segments,
  ruleCounts: {ruleId: segments},
  removed: [
    for (var i = 0; i < segments; i++)
      AdRemovedSegment(
        host: host,
        ruleId: ruleId,
        startSeconds: start + i * duration,
        durationSec: duration,
      ),
  ],
);

void main() {
  group('AdBlockLog 纯模型', () {
    test('序列化往返并派生 segmentEndSeconds', () {
      final log = blockLog(1700000000000, start: 12.5, duration: 4.25);
      final restored = AdBlockLog.fromJson(log.toJson());
      expect(restored.toJson(), log.toJson());
      expect(restored.segmentEndSeconds, closeTo(16.75, 1e-9));
      expect(
        log.toJson().keys,
        containsAll(<String>[
          'blockedAt',
          'siteKey',
          'siteName',
          'siteDomain',
          'pipeline',
          'adDomain',
          'ruleId',
          'vodName',
          'lineName',
          'episodeName',
          'segmentStartSeconds',
          'segmentDurationSeconds',
        ]),
      );
    });

    test('脏日志字段逐项降级为零值，不抛异常', () {
      final restored = AdBlockLog.fromJson({
        'blockedAt': '不是数字',
        'siteKey': 42,
        'siteName': null,
        'segmentStartSeconds': 'abc',
        'segmentDurationSeconds': double.nan,
        'unknown': true,
      });
      expect(restored.blockedAt, 0);
      expect(restored.siteKey, '');
      expect(restored.siteName, '');
      expect(restored.segmentStartSeconds, 0);
      expect(restored.segmentDurationSeconds, 0);
      expect(AdBlockLog.fromJson(null).blockedAt, 0);
    });
  });

  group('AdBlockStats 纯模型', () {
    test('序列化往返保留计数、日志与 lastResetAt', () {
      final stats = AdBlockStats.empty()
        ..addAll([blockLog(2000), blockLog(1000)]);
      stats.lastResetAt = 1234;
      final restored = AdBlockStats.fromJson(stats.toJson());
      expect(restored.totalBlocked, 2);
      expect(restored.siteBlocked, stats.siteBlocked);
      expect(restored.ruleCounts, stats.ruleCounts);
      expect(restored.pipelineCounts, stats.pipelineCounts);
      expect(restored.lastResetAt, 1234);
      expect(restored.blockLogs.map((log) => log.blockedAt), [2000, 1000]);
      expect(restored.blockedDurationSeconds, stats.blockedDurationSeconds);
    });

    test('脏统计 JSON 全字段降级，永不抛异常', () {
      final stats = AdBlockStats.fromJson({
        'totalBlocked': 'x',
        'siteBlocked': [1, 2, 3],
        'ruleCounts': {'r1': 'many', '': 5, 'r2': -1},
        'pipelineCounts': null,
        'blockLogs': ['不是对象', 7, null],
        'lastResetAt': double.infinity,
      });
      expect(stats.totalBlocked, 0);
      expect(stats.siteBlocked, isEmpty);
      expect(stats.ruleCounts, isEmpty);
      expect(stats.pipelineCounts, isEmpty);
      expect(stats.blockLogs, isEmpty);
      expect(stats.lastResetAt, 0);
      expect(AdBlockStats.fromJson(null).totalBlocked, 0);
      expect(AdBlockStats.fromJson('整个文档不是对象').blockLogs, isEmpty);
    });

    test('超过 1000 条逐出最旧，新记录排在最前', () {
      final stats = AdBlockStats.empty();
      for (var i = 0; i < AdBlockStats.maxLogs + 1; i++) {
        stats.addAll([blockLog(i)]);
      }
      expect(stats.blockLogs.length, AdBlockStats.maxLogs);
      expect(stats.blockLogs.first.blockedAt, AdBlockStats.maxLogs);
      expect(
        stats.blockLogs.any((log) => log.blockedAt == 0),
        isFalse,
        reason: '第 1 条是最旧的，应被逐出',
      );
      expect(stats.totalBlocked, AdBlockStats.maxLogs + 1);
    });

    test('logsByTimeDescending 纠正乱序，reset 清空并刷新时间戳', () {
      final stats = AdBlockStats.fromJson({
        'blockLogs': [
          blockLog(100).toJson(),
          blockLog(900).toJson(),
          blockLog(500).toJson(),
        ],
      });
      expect(stats.logsByTimeDescending.map((log) => log.blockedAt), [
        900,
        500,
        100,
      ]);
      stats.addAll([blockLog(4000, siteKey: 'site-b', ruleId: 'r2')]);
      expect(stats.topSites().first.key, 'site-b');
      final before = stats.lastResetAt;
      stats.reset();
      expect(stats.totalBlocked, 0);
      expect(stats.siteBlocked, isEmpty);
      expect(stats.ruleCounts, isEmpty);
      expect(stats.pipelineCounts, isEmpty);
      expect(stats.blockLogs, isEmpty);
      expect(stats.lastResetAt, greaterThanOrEqualTo(before));
    });
  });

  group('AdBlockStatsStore 落盘', () {
    late Directory temp;
    late String path;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('ad-block-stats-');
      path = p.join(temp.path, 'stats.json');
    });

    tearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } on FileSystemException {
        // 临时目录清理失败不影响断言结论。
      }
    });

    test('原子写：写完即可被新实例原样读回且不留临时目录', () {
      final store = AdBlockStatsStore(path: path, log: LogService());
      expect(store.record([blockLog(1000, start: 3, duration: 5)]), isTrue);
      expect(store.loadError, isNull);

      final raw = jsonDecode(File(path).readAsStringSync()) as Map;
      expect(raw['version'], 2);

      final reloaded = AdBlockStatsStore(path: path, log: LogService());
      expect(
        jsonEncode(reloaded.stats.toJson()),
        jsonEncode(store.stats.toJson()),
      );
      expect(
        temp.listSync().map((entity) => p.basename(entity.path)).toList(),
        ['stats.json'],
        reason: '临时目录必须已被 rename 消费并删除',
      );
    });

    test('读到坏文件时降级为空统计并给出 loadError', () {
      File(path).writeAsStringSync('{ 这不是 JSON');
      final store = AdBlockStatsStore(path: path, log: LogService());
      expect(store.stats.totalBlocked, 0);
      expect(store.stats.blockLogs, isEmpty);
      expect(store.loadError, isNotNull);
    });
  });

  group('AdBlockStatsService 入口', () {
    late Directory temp;
    late AdBlockStatsStore store;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('ad-block-stats-');
      store = AdBlockStatsStore(
        path: p.join(temp.path, 'stats.json'),
        log: LogService(),
      );
    });

    tearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } on FileSystemException {
        // 同上。
      }
    });

    test('abandoned 结果一条都不记（回退即没删）', () {
      final service = AdBlockStatsService(store: store);
      service.recordClean(
        result: HlsCleanResult(
          text: '#EXTM3U\n',
          abandonReason: '移除分片超过 35% 上限',
        ),
        context: context,
      );
      expect(service.stats.totalBlocked, 0);
      expect(service.stats.blockLogs, isEmpty);
    });

    test('未改动结果一条都不记', () {
      final service = AdBlockStatsService(store: store);
      service.recordClean(
        result: HlsCleanResult(text: '#EXTM3U\n'),
        context: context,
      );
      expect(service.stats.blockLogs, isEmpty);
    });

    test('四类计数按明细累加，明细字段取自 AdRemovedSegment', () {
      final service = AdBlockStatsService(
        store: store,
        ruleName: (ruleId) => ruleId == 'r1' ? '整点插播' : '',
      );
      service.recordClean(
        result: cleanedResult(segments: 2, start: 60, duration: 6),
        context: context,
      );
      service.recordClean(
        result: cleanedResult(
          ruleId: 'r2',
          host: 'track.example.net',
          segments: 1,
        ),
        context: const AdBlockContext(
          siteKey: 'site-b',
          siteName: 'B 站',
          siteDomain: 'b.example.com',
          pipeline: 'direct',
          vodName: '另一部',
          lineName: '线路二',
          episodeName: '第 3 集',
        ),
      );

      final stats = service.stats;
      expect(stats.totalBlocked, 3);
      expect(stats.siteBlocked, {'site-a': 2, 'site-b': 1});
      expect(stats.ruleCounts, {'r1': 2, 'r2': 1});
      expect(stats.pipelineCounts, {'proxy': 2, 'direct': 1});
      expect(stats.blockedDurationSeconds, closeTo(18, 1e-9));

      // 同一批清洗的明细时间戳相同、插入顺序就是清单顺序，所以按起始秒挑。
      final first =
          (stats.blockLogs.where((log) => log.ruleId == 'r1').toList()..sort(
                (a, b) =>
                    a.segmentStartSeconds.compareTo(b.segmentStartSeconds),
              ))
              .first;
      expect(first.adDomain, 'ads.example.com');
      expect(first.siteKey, 'site-a');
      expect(first.pipeline, 'proxy');
      expect(first.episodeName, '第 1 集');
      expect(first.segmentStartSeconds, 60);
      expect(first.segmentEndSeconds, 66);
      expect(first.segmentDurationSeconds, 6);
      expect(first.blockedAt, greaterThan(0));
      // ruleName 回调给中文名，未知规则 id 回退到 id 本身。
      expect(service.ruleLabel('r1'), '整点插播');
      expect(service.ruleLabel('r2'), 'r2');
    });

    test('reset 清空统计、刷新 lastResetAt 且落盘，可重入', () async {
      final service = AdBlockStatsService(store: store);
      service.recordClean(result: cleanedResult(segments: 2), context: context);
      expect(service.stats.totalBlocked, 2);

      expect(await service.reset(), isTrue);
      expect(service.stats.totalBlocked, 0);
      expect(service.stats.lastResetAt, greaterThan(0));
      final stamp = service.stats.lastResetAt;

      final reopened = AdBlockStatsStore(path: store.path, log: LogService());
      expect(reopened.stats.totalBlocked, 0);
      expect(reopened.stats.lastResetAt, stamp);

      // 清空后再次记录、再次清空仍然生效（按钮可重入）。
      service.recordClean(result: cleanedResult(segments: 1), context: context);
      expect(service.stats.totalBlocked, 1);
      expect(await service.reset(), isTrue);
      expect(service.stats.blockLogs, isEmpty);
    });
  });

  group('AdBlockLogFilter 筛选语义', () {
    final logs = [
      blockLog(3000, siteName: 'A 站番剧', siteDomain: 'V.QQ.COM', ruleId: 'r1'),
      blockLog(
        2000,
        siteName: 'B 站',
        siteDomain: 'b.example.com',
        ruleId: 'r2',
        adDomain: 'track.example.net',
        pipeline: 'direct',
        episodeName: '第 9 集',
      ),
      blockLog(
        1000,
        siteName: 'C 站',
        siteDomain: 'c.example.com',
        ruleId: 'r3',
      ),
    ];

    test('空筛选匹配全部', () {
      expect(AdBlockLogFilter.empty.isEmpty, isTrue);
      expect(AdBlockLogFilter.empty.apply(logs).length, 3);
      // 只有空白的列不得变成「把整表筛空」的条件。
      expect(const AdBlockLogFilter(siteName: ['   ']).apply(logs).length, 3);
    });

    test('同列多值 OR、大小写与首尾空白不敏感', () {
      final filter = AdBlockLogFilter.fromQuery(siteName: ' A 站 , b 站 ');
      expect(filter.siteName, ['a 站', 'b 站']);
      expect(filter.apply(logs).map((log) => log.siteName), ['A 站番剧', 'B 站']);

      final byDomain = AdBlockLogFilter.fromQuery(siteDomain: 'V.QQ');
      expect(byDomain.apply(logs).single.siteDomain, 'V.QQ.COM');
    });

    test('跨列 AND：任一条不命中即排除', () {
      final both = AdBlockLogFilter.fromQuery(
        siteName: 'b 站',
        adDomain: 'track',
      );
      expect(both.apply(logs).single.ruleId, 'r2');

      final miss = AdBlockLogFilter.fromQuery(
        siteName: 'b 站',
        pipeline: 'proxy',
      );
      expect(miss.apply(logs), isEmpty);
    });

    test('规则与分集列各自独立生效', () {
      expect(
        AdBlockLogFilter.fromQuery(rule: 'r2,r3')
            .apply(logs)
            .map((log) => log.ruleId),
        ['r2', 'r3'],
      );
      expect(
        AdBlockLogFilter.fromQuery(rule: 'r1', adDomain: 'track').apply(logs),
        isEmpty,
      );
      expect(
        AdBlockLogFilter.fromQuery(pipeline: 'direct')
            .apply(logs)
            .single
            .episodeName,
        '第 9 集',
      );
    });
  });

  group('AdBlockStatsPage 页面', () {
    late Directory temp;
    late AdBlockStatsService service;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('ad-block-stats-page-');
      service = AdBlockStatsService(
        store: AdBlockStatsStore(
          path: p.join(temp.path, 'stats.json'),
          log: LogService(),
        ),
        ruleName: (ruleId) => ruleId == 'r1' ? '整点插播' : '',
      );
      service.recordClean(result: cleanedResult(segments: 2), context: context);
      service.recordClean(
        result: cleanedResult(ruleId: 'r2', host: 'track.example.net'),
        context: const AdBlockContext(
          siteKey: 'site-b',
          siteName: 'B 站',
          siteDomain: 'b.example.com',
          pipeline: 'direct',
          vodName: '另一部',
          lineName: '线路二',
          episodeName: '第 9 集',
        ),
      );
    });

    tearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } on FileSystemException {
        // 同上。
      }
    });

    Future<void> pumpPage(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(home: AdBlockStatsPage(service: service)),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('摘要与表体先显示全部行，按站点筛选后只剩命中行', (tester) async {
      await pumpPage(tester);

      expect(
        find.byKey(const ValueKey('ad-block-stats-summary-total')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('ad-block-stats-top-sites')),
        findsOneWidget,
      );
      // ruleName 回调被页面用上了：规则列显示中文名而不是 id。
      expect(find.text('整点插播'), findsWidgets);
      expect(
        find.byKey(const ValueKey('ad-block-stats-row-2')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const ValueKey('ad-block-stats-filter-site')),
        'b 站',
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('ad-block-stats-row-0')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('ad-block-stats-row-1')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('ad-block-stats-row-0')),
          matching: find.text('track.example.net'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('清空需要二次确认，且可以反复重入', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.byKey(const ValueKey('ad-block-stats-clear')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('ad-block-stats-confirm')),
        findsOneWidget,
      );

      // 先取消：统计必须原封不动。
      await tester.tap(
        find.byKey(const ValueKey('ad-block-stats-confirm-cancel')),
      );
      await tester.pumpAndSettle();
      expect(service.stats.totalBlocked, 3);

      await tester.tap(find.byKey(const ValueKey('ad-block-stats-clear')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('ad-block-stats-confirm-clear')),
      );
      await tester.pumpAndSettle();
      expect(service.stats.totalBlocked, 0);
      expect(find.byKey(const ValueKey('ad-block-stats-row-0')), findsNothing);
      expect(find.text('没有匹配的拦截记录。'), findsOneWidget);

      // 等提示条退场，再点一次：清空按钮可重入。
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      await tester.tap(find.byKey(const ValueKey('ad-block-stats-clear')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('ad-block-stats-confirm-clear')),
      );
      await tester.pumpAndSettle();
      expect(service.stats.totalBlocked, 0);
      expect(service.stats.lastResetAt, greaterThan(0));
    });
  });

  group('R6 regressions', () {
    late Directory temp;
    late String path;
    setUp(() {
      temp = Directory.systemTemp.createTempSync('ad-block-r6-');
      path = p.join(temp.path, 'stats.json');
    });
    tearDown(() => temp.deleteSync(recursive: true));

    test('R6-1 nonfinite disk doubles cannot poison later recording', () {
      for (final value in ['NaN', 'Infinity', '-Infinity']) {
        final raw = blockLog(1).toJson();
        raw['segmentDurationSeconds'] = value;
        raw['segmentStartSeconds'] = value;
        File(path).writeAsStringSync(
          jsonEncode({
            'blockLogs': [raw],
          }),
        );
        final store = AdBlockStatsStore(path: path);
        expect(() => store.record([blockLog(2)]), returnsNormally);
        expect(store.record([blockLog(3)]), isTrue);
        final reread = AdBlockStatsStore(path: path).stats;
        expect(reread.blockLogs.length, 3);
        expect(reread.blockLogs.last.segmentDurationSeconds, 0);
        expect(reread.blockLogs.last.segmentStartSeconds, 0);
      }
    });

    test('R6-1 encoding failure returns false and sets loadError', () {
      final log = LogService();
      final store = AdBlockStatsStore(path: path, log: log);
      bool? saved;
      expect(
        () => saved = store.record([blockLog(1, duration: double.nan)]),
        returnsNormally,
      );
      expect(saved, isFalse);
      expect(store.loadError, contains('保存'));
      expect(log.entries.last.level, LogLevel.warning);
    });

    test('R6-2 failed record keeps memory and existing disk state', () {
      final store = AdBlockStatsStore(path: path);
      expect(store.record([blockLog(1)]), isTrue);
      final before = jsonEncode(store.stats.toJson());
      File(path).renameSync('$path.backup');
      Directory(path).createSync();
      expect(store.record([blockLog(2)]), isFalse);
      expect(jsonEncode(store.stats.toJson()), before);
      Directory(path).deleteSync();
      File('$path.backup').renameSync(path);
      expect(store.record([blockLog(3)]), isTrue);
      expect(AdBlockStatsStore(path: path).stats.totalBlocked, 2);
    });

    test('R6-2 failed reset rolls back memory including timestamp', () {
      final store = AdBlockStatsStore(path: path);
      expect(store.record([blockLog(1)]), isTrue);
      final before = jsonEncode(store.stats.toJson());
      File(path).renameSync('$path.backup');
      Directory(path).createSync();
      expect(store.reset(), isFalse);
      expect(jsonEncode(store.stats.toJson()), before);
      Directory(path).deleteSync();
      File('$path.backup').renameSync(path);
      expect(store.record([blockLog(2)]), isTrue);
      expect(AdBlockStatsStore(path: path).stats.totalBlocked, 2);
    });

    test('R6-3 lifetime duration survives rolling and disk roundtrip', () {
      final store = AdBlockStatsStore(path: path);
      expect(
        store.record([for (var i = 0; i < 1500; i++) blockLog(i)]),
        isTrue,
      );
      expect(store.stats.blockLogs.length, 1000);
      expect(store.stats.totalBlocked, 1500);
      expect(store.stats.blockedDurationSeconds, 9000);
      final reopened = AdBlockStatsStore(path: path);
      expect(reopened.stats.blockedDurationSeconds, 9000);
      expect(reopened.record([blockLog(1500)]), isTrue);
      expect(reopened.stats.blockedDurationSeconds, 9006);
      expect(reopened.reset(), isTrue);
      expect(reopened.stats.blockedDurationSeconds, 0);
    });

    Future<AdBlockStatsService> pumpPage(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final service = AdBlockStatsService(
        store: AdBlockStatsStore(path: path),
        ruleName: (_) => '整点插播',
      );
      service.recordClean(result: cleanedResult(), context: context);
      await tester.pumpWidget(
        MaterialApp(home: AdBlockStatsPage(service: service)),
      );
      await tester.pumpAndSettle();
      return service;
    }

    testWidgets('R6-4 rule filter accepts visible label and original id', (
      tester,
    ) async {
      await pumpPage(tester);
      for (final query in [' 整点插播 ', 'R1', 'absent,整点']) {
        await tester.enterText(
          find.byKey(const ValueKey('ad-block-stats-filter-rule')),
          query,
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('ad-block-stats-row-0')),
          findsOneWidget,
        );
      }
      await tester.enterText(
        find.byKey(const ValueKey('ad-block-stats-filter-pipeline')),
        'direct',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ad-block-stats-row-0')), findsNothing);
    });

    testWidgets('R6-5 write error banner shows store message verbatim', (
      tester,
    ) async {
      final service = await pumpPage(tester);
      File(path).renameSync('$path.backup');
      Directory(path).createSync();
      await tester.tap(find.byKey(const ValueKey('ad-block-stats-clear')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('ad-block-stats-confirm-clear')),
      );
      await tester.pumpAndSettle();
      expect(service.store.loadError, contains('保存'));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('ad-block-stats-load-error')),
          matching: find.text(service.store.loadError!),
        ),
        findsOneWidget,
      );
    });

    test('R6-6 load enforces cap and keeps newest timestamps', () {
      File(path).writeAsStringSync(
        jsonEncode({
          'blockLogs': [for (var i = 0; i < 1200; i++) blockLog(i).toJson()],
        }),
      );
      final stats = AdBlockStatsStore(path: path).stats;
      expect(stats.blockLogs.length, 1000);
      expect(stats.blockLogs.first.blockedAt, 1199);
      expect(stats.blockLogs.last.blockedAt, 200);
    });
  });
}
