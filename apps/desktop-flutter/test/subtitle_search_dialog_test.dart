/// 搜索窗口的离屏行为测试（`lib/ui/subtitle_search_dialog.dart`）。
///
/// 覆盖计划 Task 5 的七条：初始态、加载态（用 `Completer` 卡住）、空态的三类
/// 说明、语言筛选、选中返回、本地文件注入、搜索中禁用。
///
/// **不触网、不写盘**：`search` 与 `pickLocalFile` 都是构造好的假实现，
/// 这也是窗口把两者做成注入参数的唯一理由——窗口只搬运数据。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/subtitle_provider.dart';
import 'package:webhtv_pc/services/subtitle_match_service.dart';
import 'package:webhtv_pc/ui/subtitle_search_dialog.dart';
import 'package:webhtv_pc/ui/theme.dart';

const SubtitleQuery _query = SubtitleQuery(
  title: '某剧 第二季',
  year: 2024,
  season: 2,
  episode: 3,
  siteKey: 'demo',
  vodId: 'vod-1',
  episodeName: '第03集',
);

SubtitleCandidate _candidate({
  required String providerId,
  required String assetId,
  required String title,
  String language = 'zh-Hans',
  String format = 'srt',
  double score = 0.80,
}) => SubtitleCandidate(
  providerId: providerId,
  assetId: assetId,
  title: title,
  language: language,
  format: format,
  url: 'https://example.test/$assetId.$format',
  score: score,
);

const ValueKey<String> _keywordKey = ValueKey<String>(
  'subtitle-search-keyword',
);
const ValueKey<String> _submitKey = ValueKey<String>('subtitle-search-submit');
const ValueKey<String> _localKey = ValueKey<String>('subtitle-search-local');

/// 打开窗口并把返回结果收进 [results]（取消时收到 null）。
Future<void> _open(
  WidgetTester tester, {
  required Future<SubtitleSearchReport> Function(SubtitleQuery query) search,
  Future<String?> Function()? pickLocalFile,
  List<SubtitleCandidate?>? results,
  Size size = const Size(1280, 720),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      home: Scaffold(
        body: Center(
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                final result = await showSubtitleSearchDialog(
                  context: context,
                  initialQuery: _query,
                  search: search,
                  pickLocalFile: pickLocalFile,
                );
                results?.add(result);
              },
              child: const Text('打开搜索窗口'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开搜索窗口'));
  await tester.pumpAndSettle();
}

/// 结果行：`subtitle-search-row-<providerId>-<assetId>`。
Finder _rows() => find.byWidgetPredicate(
  (widget) =>
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith('subtitle-search-row-'),
);

/// 点「搜索」并只推一帧：加载态在等 Completer，不能 settle。
Future<void> _tapSearch(WidgetTester tester) async {
  await tester.tap(find.byKey(_submitKey));
  await tester.pump();
}

void main() {
  testWidgets('初始态：提示语出现，关键词与季集按 initialQuery 预填', (tester) async {
    await _open(tester, search: (_) async => const SubtitleSearchReport());

    expect(find.text('输入关键词开始搜索'), findsOneWidget);
    expect(find.text('搜索字幕'), findsOneWidget);

    final keyword = tester.widget<TextField>(find.byKey(_keywordKey));
    expect(keyword.controller?.text, '某剧 第二季');
    expect(keyword.autofocus, isTrue);

    final season = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('subtitle-search-season')),
    );
    expect(season.controller?.text, '2');
    final episode = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('subtitle-search-episode')),
    );
    expect(episode.controller?.text, '3');
  });

  testWidgets('点搜索进入加载态，完成后出现按源分组的结果与匹配分', (tester) async {
    final completer = Completer<SubtitleSearchReport>();
    var calls = 0;
    await _open(
      tester,
      search: (_) {
        calls++;
        return completer.future;
      },
    );
    expect(calls, 0, reason: '打开窗口不该自己发搜索');

    await _tapSearch(tester);
    expect(calls, 1);
    expect(find.textContaining('正在搜索'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    completer.complete(
      SubtitleSearchReport(
        candidates: [
          _candidate(
            providerId: 'assrt',
            assetId: 'a1',
            title: '某剧 第二季 第03集',
            format: 'ass',
            score: 0.92,
          ),
          _candidate(
            providerId: 'assrt',
            assetId: 'a2',
            title: '某剧 S02E03 简体',
            score: 0.88,
          ),
          _candidate(
            providerId: 'xunlei',
            assetId: 'x1',
            title: '某剧 第二季 第3集',
            language: 'zh-Hant',
            score: 0.71,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('ASSRT · 2 条'), findsOneWidget);
    expect(find.text('迅雷字幕 · 1 条'), findsOneWidget);
    expect(find.text('ASSRT · zh-Hans · ass · 0.92'), findsOneWidget);
    expect(find.text('迅雷字幕 · zh-Hant · srt · 0.71'), findsOneWidget);
    expect(find.textContaining('正在搜索'), findsNothing);
  });

  testWidgets('语言与格式为空时给出兜底文案', (tester) async {
    await _open(
      tester,
      search: (_) async => SubtitleSearchReport(
        candidates: [
          _candidate(
            providerId: 'local',
            assetId: 'l1',
            title: '本地字幕',
            language: '',
            format: '',
          ),
        ],
      ),
    );
    await _tapSearch(tester);
    await tester.pumpAndSettle();

    expect(find.text('本地目录 · 未知语言 · 未知格式 · 0.80'), findsOneWidget);
  });

  testWidgets('空结果：未启用源、失败原因与无结果兜底同时说明', (tester) async {
    await _open(
      tester,
      search: (_) async => const SubtitleSearchReport(
        failures: {'xunlei': '超时'},
        unavailable: ['assrt', 'shooter'],
      ),
    );
    await _tapSearch(tester);
    await tester.pumpAndSettle();

    expect(find.text('没有找到字幕，换个关键词试试'), findsOneWidget);
    expect(find.textContaining('未启用的源：ASSRT、射手字幕'), findsOneWidget);
    expect(find.textContaining('失败的源：迅雷字幕（超时）'), findsOneWidget);
  });

  testWidgets('空结果且没有失败/未启用来源时只给兜底一句', (tester) async {
    await _open(tester, search: (_) async => const SubtitleSearchReport());
    await _tapSearch(tester);
    await tester.pumpAndSettle();

    expect(find.text('没有找到字幕，换个关键词试试'), findsOneWidget);
    expect(find.textContaining('未启用的源'), findsNothing);
    expect(find.textContaining('失败的源'), findsNothing);
  });

  testWidgets('语言筛选：切到「简」只剩 zh-Hans，无匹配给「当前筛选无结果」', (tester) async {
    await _open(
      tester,
      search: (_) async => SubtitleSearchReport(
        candidates: [
          _candidate(providerId: 'assrt', assetId: 'a1', title: '简中一'),
          _candidate(providerId: 'assrt', assetId: 'a2', title: '简中二'),
          _candidate(
            providerId: 'xunlei',
            assetId: 'x1',
            title: '英文一',
            language: 'en',
          ),
        ],
      ),
    );
    await _tapSearch(tester);
    await tester.pumpAndSettle();
    expect(_rows(), findsNWidgets(3));

    await tester.tap(find.text('简'));
    await tester.pumpAndSettle();
    expect(find.textContaining('· zh-Hans ·'), findsNWidgets(2));
    expect(find.textContaining('· en ·'), findsNothing);

    // 报告里没有繁体条目：切「繁」必须给出说明而不是一块空白。
    await tester.tap(find.text('繁'));
    await tester.pumpAndSettle();
    expect(find.text('当前筛选无结果'), findsOneWidget);
    expect(_rows(), findsNothing);

    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    expect(_rows(), findsNWidgets(3));
  });

  testWidgets('选中一行后 Future 返回该候选', (tester) async {
    final results = <SubtitleCandidate?>[];
    await _open(
      tester,
      results: results,
      search: (_) async => SubtitleSearchReport(
        candidates: [
          _candidate(
            providerId: 'assrt',
            assetId: 'a1',
            title: '某剧 第03集',
            score: 0.9,
          ),
        ],
      ),
    );
    await _tapSearch(tester);
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('subtitle-search-row-assrt-a1')),
    );
    await tester.pumpAndSettle();
    await tester.pump();

    expect(results, hasLength(1));
    expect(results.single?.providerId, 'assrt');
    expect(results.single?.assetId, 'a1');
    expect(find.text('搜索字幕'), findsNothing, reason: '选中后窗口应关闭');
  });

  testWidgets('选择本地文件：调用注入函数一次，返回 null 不报错也不关窗', (tester) async {
    var picks = 0;
    var searches = 0;
    await _open(
      tester,
      search: (_) async {
        searches++;
        return const SubtitleSearchReport();
      },
      pickLocalFile: () async {
        picks++;
        return null;
      },
    );

    await tester.tap(find.byKey(_localKey));
    await tester.pumpAndSettle();

    expect(picks, 1);
    expect(searches, 0, reason: '选本地文件不该触发在线搜索');
    expect(tester.takeException(), isNull);
    expect(find.text('搜索字幕'), findsOneWidget, reason: 'null 是取消，窗口保持打开');
  });

  testWidgets('选择本地文件：返回路径时以 local 候选关闭窗口', (tester) async {
    final results = <SubtitleCandidate?>[];
    await _open(
      tester,
      results: results,
      search: (_) async => const SubtitleSearchReport(),
      pickLocalFile: () async => r'C:\subtitles\某剧.S02E03.ass',
    );

    await tester.tap(find.byKey(_localKey));
    await tester.pumpAndSettle();
    await tester.pump();

    expect(results.single?.providerId, 'local');
    expect(results.single?.title, '某剧.S02E03.ass');
    expect(results.single?.format, 'ass');
  });

  testWidgets('搜索中按钮禁用：连点只触发一次；改词重搜不关窗且季集随行', (tester) async {
    final completers = <Completer<SubtitleSearchReport>>[];
    final queries = <SubtitleQuery>[];
    await _open(
      tester,
      search: (query) {
        queries.add(query);
        final completer = Completer<SubtitleSearchReport>();
        completers.add(completer);
        return completer.future;
      },
    );

    await _tapSearch(tester);
    expect(queries, hasLength(1));

    final button = tester.widget<FilledButton>(find.byKey(_submitKey));
    expect(button.onPressed, isNull, reason: '搜索期间按钮必须禁用');

    await tester.tap(find.byKey(_submitKey));
    await tester.pump();
    expect(queries, hasLength(1), reason: '连点不能发第二次请求');

    completers.first.complete(
      SubtitleSearchReport(
        candidates: [_candidate(providerId: 'assrt', assetId: 'a1', title: '一')],
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('subtitle-search-row-assrt-a1')),
      findsOneWidget,
    );

    // 改季集后再搜：窗口不关，加载文案用上一次的源数（不编数字）。
    await tester.enterText(
      find.byKey(const ValueKey<String>('subtitle-search-season')),
      '5',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('subtitle-search-episode')),
      '8',
    );
    await _tapSearch(tester);
    expect(find.text('正在搜索 1 个源'), findsOneWidget);
    expect(queries, hasLength(2));
    expect(queries.last.season, 5);
    expect(queries.last.episode, 8);
    expect(queries.last.title, '某剧 第二季');

    completers.last.complete(const SubtitleSearchReport());
    await tester.pumpAndSettle();
    expect(find.text('没有找到字幕，换个关键词试试'), findsOneWidget);
    expect(find.text('搜索字幕'), findsOneWidget);
  });

  testWidgets('取消关闭窗口并返回 null', (tester) async {
    final results = <SubtitleCandidate?>[];
    await _open(
      tester,
      results: results,
      search: (_) async => const SubtitleSearchReport(),
    );

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pump();

    expect(results, [null]);
    expect(find.text('搜索字幕'), findsNothing);
  });

  testWidgets('小屏（640×480）不溢出', (tester) async {
    await _open(
      tester,
      size: const Size(640, 480),
      search: (_) async => SubtitleSearchReport(
        candidates: [
          _candidate(
            providerId: 'assrt',
            assetId: 'a1',
            title: '很长的一行标题很长的一行标题很长的一行标题',
          ),
        ],
      ),
    );
    await _tapSearch(tester);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey<String>('subtitle-search-row-assrt-a1')),
      findsOneWidget,
    );
  });
}
