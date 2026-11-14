/// 换源浮层的行为契约。
///
/// 这里的假站点是刻意的：浮层本身不发请求、也不持有站点表，一切数据经
/// onSearch / outcomeOf / onProbe 进来，所以「流式到达」「搜索失败」
/// 「部分解析成功」「重试」这些分支都能在测试里稳定复现——不需要真站点，
/// 也不会因为网络抖动变红。
///
/// 特别注意两件事：
/// 1. 用一个假的 `ValueNotifier<MultiSiteSearchOutcome?>` 充当全局搜索状态，
///    每次给它赋新快照就等于「又有站点返回了」；
/// 2. **不要** import browse_pages.dart：它只是接线方，浮层自己的行为
///    必须能脱开它单独验证。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/state/search_state.dart';
import 'package:webhtv_pc/ui/app.dart' show PosterImage;
import 'package:webhtv_pc/ui/common.dart';
import 'package:webhtv_pc/ui/source_field.dart';
import 'package:webhtv_pc/ui/source_swap_sheet.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tokens.dart';

VodPlayLine _line(String flag, {int episodes = 1}) {
  return VodPlayLine(
    flag: flag,
    episodes: [
      for (var i = 1; i <= episodes; i += 1)
        VodEpisode(name: '第$i集', url: 'https://example.test/$flag/$i'),
    ],
  );
}

SwapCandidate _candidate(String siteKey, String vodId) {
  return SwapCandidate(
    siteKey: siteKey,
    siteName: '$siteKey 站',
    vodId: vodId,
    vodName: '示例剧',
    vodYear: '2026',
  );
}

Vod _vod(String vodId, {String? pic = '', String name = '示例剧'}) {
  return Vod(vodId: vodId, vodName: name, vodPic: pic, vodYear: '2026');
}

/// 一个站点条目。groups 是刻意的「站点给它的归类」，浮层的分组 chip 只能
/// 从这些值里派生出来。
SiteSearchEntry _entry(
  String siteKey, {
  List<String> groups = const <String>[],
  List<Vod> vods = const <Vod>[],
  AppError? error,
}) {
  return SiteSearchEntry(
    siteKey: siteKey,
    siteName: '$siteKey 站',
    groups: groups,
    result: SiteResult(list: vods),
    error: error,
  );
}

MultiSiteSearchOutcome _outcome({
  required List<SiteSearchEntry> entries,
  bool finished = false,
  String keyword = '示例剧',
}) {
  final outcome = MultiSiteSearchOutcome(
    runId: 1,
    keyword: keyword,
    results: entries,
  );
  outcome.finished = finished;
  return outcome;
}

/// 默认快照：两个站点各一条候选，且都搜完了。
ValueNotifier<MultiSiteSearchOutcome?> _twoEntriesSnapshot() {
  return ValueNotifier<MultiSiteSearchOutcome?>(
    _outcome(
      entries: <SiteSearchEntry>[
        _entry('site-a', groups: const ['电影'], vods: [_vod('100')]),
        _entry('site-b', groups: const ['剧集'], vods: [_vod('200')]),
      ],
      finished: true,
    ),
  );
}

void _useViewport(WidgetTester tester, double width, double height) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void _useTallViewport(WidgetTester tester) => _useViewport(tester, 1400, 1200);

/// 打开浮层，并把它 pop 出来的 Future 交回给测试。
///
/// searchListenable 就是 [snapshot] 本身：测试给 snapshot.value 赋新快照，
/// 浮层就当作「又有站点返回了」重建一次。
Future<Future<List<SwapRow>?>> _openSheet(
  WidgetTester tester, {
  ValueNotifier<MultiSiteSearchOutcome?>? snapshot,
  required SourceSwapProbe onProbe,
  SourceSwapSearch? onSearch,
  List<String>? calls,
  String keyword = '示例剧',
  SourceStatus Function(String siteKey)? statusOf,
  // 加载态里有一个无限循环的 spinner，pumpAndSettle 永远等不到静止，
  // 需要观察加载态的用例改成显式推帧走完入场动画。
  bool settle = true,
}) async {
  final listenable = snapshot ?? ValueNotifier<MultiSiteSearchOutcome?>(null);
  late Future<List<SwapRow>?> popped;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              key: const ValueKey('open-swap-sheet'),
              onPressed: () {
                popped = showSourceSwapSheet(
                  context,
                  keyword: keyword,
                  searchListenable: listenable,
                  outcomeOf: () => listenable.value,
                  onSearch: (text) {
                    calls?.add(text);
                    return onSearch == null
                        ? Future<void>.value()
                        : onSearch(text);
                  },
                  onProbe: onProbe,
                  statusOf: statusOf,
                );
              },
              child: const Text('换源'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open-swap-sheet')));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
  return popped;
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pump();
}

bool _checked(WidgetTester tester, String key) {
  return tester.widget<Checkbox>(find.byKey(ValueKey(key))).value ?? false;
}

void main() {
  group('SwapRow', () {
    test('episodeCount 累加所有线路的分集', () {
      final row = SwapRow(
        candidate: _candidate('a', '1'),
        stage: SwapStage.ready,
        lines: [_line('A', episodes: 3), _line('B', episodes: 2)],
      );
      expect(row.episodeCount, 5);
      expect(row.ready, isTrue);
    });

    test('ready 要求解析完成且确实有线路', () {
      expect(SwapRow(candidate: _candidate('a', '1')).ready, isFalse);
      expect(
        SwapRow(candidate: _candidate('a', '1'), stage: SwapStage.ready).ready,
        isFalse,
      );
      expect(
        SwapRow(
          candidate: _candidate('a', '1'),
          stage: SwapStage.ready,
          lines: [_line('A')],
        ).ready,
        isTrue,
      );
      expect(
        SwapRow(
          candidate: _candidate('a', '1'),
          stage: SwapStage.failed,
          lines: [_line('A')],
        ).ready,
        isFalse,
      );
    });

    test('copyWith 只改传入字段', () {
      final row = SwapRow(
        candidate: _candidate('a', '1'),
        stage: SwapStage.probing,
        lines: [_line('A')],
        error: '旧错误',
        selected: true,
      );
      final patched = row.copyWith(stage: SwapStage.ready);
      expect(patched.stage, SwapStage.ready);
      expect(patched.lines, row.lines);
      expect(patched.error, '旧错误');
      expect(patched.selected, isTrue);
      expect(patched.candidate, same(row.candidate));
    });
  });

  group('showSourceSwapSheet', () {
    testWidgets('打开就发起一次全局搜索，不等它返回', (tester) async {
      _useTallViewport(tester);
      final calls = <String>[];
      // 永不完成的 onSearch：浮层不能因为「搜索没回来」就卡住不显示。
      final pending = Completer<void>();
      await _openSheet(
        tester,
        onProbe: (candidate) async => [_line('线路')],
        onSearch: (keyword) => pending.future,
        calls: calls,
        settle: false,
      );

      expect(calls, <String>['示例剧']);
      // 首次搜索还没建批次 → 整块加载态。
      expect(find.byType(LoadingBlock), findsOneWidget);
      expect(find.byKey(const ValueKey('source-swap-empty')), findsNothing);
    });

    testWidgets('宽度自适应窗口（1120 封顶，不再被 640 夹住）', (tester) async {
      _useTallViewport(tester);
      await _openSheet(
        tester,
        snapshot: _twoEntriesSnapshot(),
        onProbe: (candidate) async => [_line('线路')],
      );
      final size = tester.getSize(
        find.byKey(const ValueKey('source-swap-sheet')),
      );
      // min(1400 - 32 * 2, 1120) = 1120：旧实现被 Material 的 640 上限夹住。
      expect(size.width, 1120);
      expect(size.height, 820);
    });

    testWidgets('窄窗口按可用宽度收窄', (tester) async {
      _useViewport(tester, 700, 1000);
      await _openSheet(
        tester,
        snapshot: _twoEntriesSnapshot(),
        onProbe: (candidate) async => [_line('线路')],
      );
      final size = tester.getSize(
        find.byKey(const ValueKey('source-swap-sheet')),
      );
      expect(size.width, 700 - AppSpace.xxl * 2);
    });

    testWidgets('高度取 min(可用高度 * 0.86, 820)', (tester) async {
      _useTallViewport(tester);
      await _openSheet(
        tester,
        snapshot: _twoEntriesSnapshot(),
        onProbe: (candidate) async => [_line('线路')],
      );
      final size = tester.getSize(
        find.byKey(const ValueKey('source-swap-sheet')),
      );
      // 1200 * 0.86 = 1032，被 820 夹住。
      expect(size.height, 820);
    });

    testWidgets('表面色 night-surface-1、顶圆角 14、顶部一条发丝线', (tester) async {
      _useTallViewport(tester);
      await _openSheet(
        tester,
        snapshot: _twoEntriesSnapshot(),
        onProbe: (candidate) async => [_line('线路')],
      );

      final sheet = find.byKey(const ValueKey('source-swap-sheet'));
      final container = tester.widget<Container>(sheet);
      final decoration = container.decoration! as BoxDecoration;
      // 默认暗色主题下 surfaceContainerLow 就是 night-surface-1。
      expect(decoration.color, AppPalette.nightSurface1);
      expect(
        decoration.borderRadius,
        const BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      );

      final hairline = tester
          .widgetList<Container>(
            find.descendant(of: sheet, matching: find.byType(Container)),
          )
          .first;
      expect(hairline.color, AppPalette.nightLine.withValues(alpha: 0.72));
      expect(tester.getSize(find.byWidget(hairline)).height, 1);
    });

    testWidgets('矮窗口按 0.86 缩放', (tester) async {
      _useViewport(tester, 900, 500);
      await _openSheet(
        tester,
        snapshot: _twoEntriesSnapshot(),
        onProbe: (candidate) async => [_line('线路')],
      );
      final size = tester.getSize(
        find.byKey(const ValueKey('source-swap-sheet')),
      );
      expect(size.height, closeTo(500 * 0.86, 0.01));
    });

    testWidgets('流式到达：先 A 后 A+B，已勾选的 A 不被冲掉', (tester) async {
      _useTallViewport(tester);
      final snapshot = ValueNotifier<MultiSiteSearchOutcome?>(
        _outcome(
          entries: <SiteSearchEntry>[
            _entry('site-a', groups: const ['电影'], vods: [_vod('100')]),
          ],
        ),
      );
      await _openSheet(
        tester,
        snapshot: snapshot,
        onProbe: (candidate) async => [_line('线路')],
      );

      // 只有 A 到货：A 的行立刻可见，且没有遮罩挡住它。
      expect(
        find.byKey(const ValueKey('source-swap-row-site-a-100')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('source-swap-row-site-b-200')),
        findsNothing,
      );
      expect(find.byType(LoadingBlock), findsNothing);
      // 进行中提示只是一行，不是遮罩。
      expect(find.byKey(const ValueKey('source-swap-loading')), findsOneWidget);
      expect(find.text('还在搜索，返回一个站点就显示一个站点'), findsOneWidget);

      // 用户先把 A 勾上。
      await _tapKey(tester, 'source-swap-check-site-a-100');
      expect(_checked(tester, 'source-swap-check-site-a-100'), isTrue);

      // B 到货并整体搜完。
      snapshot.value = _outcome(
        entries: <SiteSearchEntry>[
          _entry('site-a', groups: const ['电影'], vods: [_vod('100')]),
          _entry('site-b', groups: const ['剧集'], vods: [_vod('200')]),
        ],
        finished: true,
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('source-swap-row-site-b-200')),
        findsOneWidget,
      );
      // 关键：A 的状态按 (siteKey, vodId) 复用了，没有被新快照重置。
      expect(_checked(tester, 'source-swap-check-site-a-100'), isTrue);
      expect(find.byKey(const ValueKey('source-swap-loading')), findsNothing);
    });

    testWidgets('流式到达：已解析好的行也保持 ready', (tester) async {
      _useTallViewport(tester);
      final snapshot = ValueNotifier<MultiSiteSearchOutcome?>(
        _outcome(
          entries: <SiteSearchEntry>[
            _entry('site-a', groups: const ['电影'], vods: [_vod('100')]),
          ],
          finished: true,
        ),
      );
      await _openSheet(
        tester,
        snapshot: snapshot,
        onProbe: (candidate) async => [_line('线路', episodes: 4)],
      );
      await _tapKey(tester, 'source-swap-check-site-a-100');
      await _tapKey(tester, 'source-swap-commit');
      await tester.pumpAndSettle();
      expect(find.text('4 集'), findsOneWidget);

      // 第二个站点到货后，A 的解析结果与勾选都还在。
      snapshot.value = _outcome(
        entries: <SiteSearchEntry>[
          _entry('site-a', groups: const ['电影'], vods: [_vod('100')]),
          _entry('site-b', groups: const ['剧集'], vods: [_vod('200')]),
        ],
        finished: true,
      );
      await tester.pump();
      expect(find.text('4 集'), findsOneWidget);
      expect(_checked(tester, 'source-swap-check-site-a-100'), isTrue);
      expect(find.text('并入 1 条线路'), findsOneWidget);
    });

    testWidgets('点分组 chip 只做本地筛选，绝不重新搜索', (tester) async {
      _useTallViewport(tester);
      final calls = <String>[];
      await _openSheet(
        tester,
        snapshot: _twoEntriesSnapshot(),
        onProbe: (candidate) async => [_line('线路')],
        calls: calls,
      );
      expect(calls, <String>['示例剧']);

      await _tapKey(tester, 'source-swap-group-电影');
      await tester.pumpAndSettle();
      // 这次修复的核心证据：切换分组一次请求都不该发。
      expect(calls.length, 1);
      expect(
        find.byKey(const ValueKey('source-swap-row-site-a-100')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('source-swap-row-site-b-200')),
        findsNothing,
      );

      await _tapKey(tester, 'source-swap-group-all');
      await tester.pumpAndSettle();
      expect(calls.length, 1);
      expect(
        find.byKey(const ValueKey('source-swap-row-site-b-200')),
        findsOneWidget,
      );
    });

    testWidgets('分组 chip 从结果里派生，不是外部传入的全集', (tester) async {
      _useTallViewport(tester);
      await _openSheet(
        tester,
        snapshot: ValueNotifier<MultiSiteSearchOutcome?>(
          _outcome(
            entries: <SiteSearchEntry>[
              _entry('site-a', groups: const ['电影'], vods: [_vod('100')]),
            ],
            finished: true,
          ),
        ),
        onProbe: (candidate) async => [_line('线路')],
      );

      expect(
        find.byKey(const ValueKey('source-swap-group-all')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('source-swap-group-电影')),
        findsOneWidget,
      );
      // 结果里没有剧集 → 不该凭空出现一个空分区。
      expect(find.byKey(const ValueKey('source-swap-group-剧集')), findsNothing);
    });

    testWidgets('分组筛选后没有行 → 空态区分「这个分组没有结果」', (tester) async {
      _useTallViewport(tester);
      final snapshot = _twoEntriesSnapshot();
      await _openSheet(
        tester,
        snapshot: snapshot,
        onProbe: (candidate) async => [_line('线路')],
      );
      await _tapKey(tester, 'source-swap-group-电影');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('source-swap-empty')), findsNothing);

      // 新一批结果里电影分组消失了，但用户选中的分组还留着 → 明确的空态，
      // 而不是静默显示一个空列表。
      snapshot.value = _outcome(
        entries: <SiteSearchEntry>[
          _entry('site-b', groups: const ['剧集'], vods: [_vod('200')]),
        ],
        finished: true,
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('source-swap-empty')), findsOneWidget);
      expect(find.text('这个分组没有结果'), findsOneWidget);
    });

    testWidgets('搜完 0 条显示空态', (tester) async {
      _useTallViewport(tester);
      await _openSheet(
        tester,
        snapshot: ValueNotifier<MultiSiteSearchOutcome?>(
          _outcome(entries: const <SiteSearchEntry>[], finished: true),
        ),
        onProbe: (candidate) async => [_line('线路')],
      );
      expect(find.byKey(const ValueKey('source-swap-empty')), findsOneWidget);
      expect(find.text('没有找到其它来源'), findsOneWidget);
    });

    testWidgets('失败站点如实计数，不静默丢弃', (tester) async {
      _useTallViewport(tester);
      await _openSheet(
        tester,
        snapshot: ValueNotifier<MultiSiteSearchOutcome?>(
          _outcome(
            entries: <SiteSearchEntry>[
              _entry('site-a', groups: const ['电影'], vods: [_vod('100')]),
              _entry('site-b', error: AppError(AppErrorKind.siteHttp, '连接超时')),
              _entry('site-c', error: AppError(AppErrorKind.siteHttp, '证书无效')),
              _entry('site-d', groups: const ['剧集']),
            ],
            finished: true,
          ),
        ),
        onProbe: (candidate) async => [_line('线路')],
      );

      expect(
        find.byKey(const ValueKey('source-swap-search-failures')),
        findsOneWidget,
      );
      // site-b / site-c 是真失败；site-d 成功但 0 条，不算失败。
      expect(find.text('另有 2 个站点搜索失败'), findsOneWidget);
    });

    testWidgets('全站失败时仍然显示失败计数而不是「没有找到」', (tester) async {
      _useTallViewport(tester);
      await _openSheet(
        tester,
        snapshot: ValueNotifier<MultiSiteSearchOutcome?>(
          _outcome(
            entries: <SiteSearchEntry>[
              _entry('site-a', error: AppError(AppErrorKind.siteHttp, '连接超时')),
            ],
            finished: true,
          ),
        ),
        onProbe: (candidate) async => [_line('线路')],
      );
      expect(find.text('另有 1 个站点搜索失败'), findsOneWidget);
      expect(find.byKey(const ValueKey('source-swap-empty')), findsOneWidget);
    });

    testWidgets('候选行显示标准海报卡，url 取自候选 vodPic', (tester) async {
      _useTallViewport(tester);
      await _openSheet(
        tester,
        snapshot: ValueNotifier<MultiSiteSearchOutcome?>(
          _outcome(
            entries: <SiteSearchEntry>[
              _entry(
                'site-a',
                groups: const ['电影'],
                vods: [
                  _vod('100', pic: ' https://img.test/a.jpg '),
                  _vod('101', pic: ''),
                ],
              ),
            ],
            finished: true,
          ),
        ),
        onProbe: (candidate) async => [_line('线路')],
      );

      final poster = find.byKey(
        const ValueKey('source-swap-poster-site-a-100'),
      );
      expect(poster, findsOneWidget);
      final image = tester.widget<PosterImage>(
        find.descendant(of: poster, matching: find.byType(PosterImage)),
      );
      // 候选里带着首尾空格也算同一张图，但要 trim 过再交给 PosterImage。
      expect(image.url, 'https://img.test/a.jpg');
      // 与搜索页结果区同一张标准卡：140×190 竖版海报。
      expect(image.width, 140);
      expect(image.height, 190);
      final box = tester.getSize(poster);
      expect(box.width, 140);
      expect(box.height, 190);
      expect(box.width / box.height, closeTo(140 / 190, 0.001));

      // 没有海报的候选画占位，不拼一个空字符串 URL。
      final placeholder = tester.widget<PosterImage>(
        find.descendant(
          of: find.byKey(const ValueKey('source-swap-poster-site-a-101')),
          matching: find.byType(PosterImage),
        ),
      );
      expect(placeholder.url, isNull);
    });

    testWidgets('勾选后才出现动作条，文案带条数', (tester) async {
      _useTallViewport(tester);
      await _openSheet(
        tester,
        snapshot: _twoEntriesSnapshot(),
        onProbe: (candidate) async => [_line('线路')],
      );
      expect(find.byKey(const ValueKey('source-swap-commit')), findsNothing);

      await _tapKey(tester, 'source-swap-check-site-a-100');
      expect(find.text('已选 1 条候选'), findsOneWidget);
      expect(find.text('解析所选 · 1 条'), findsOneWidget);

      await _tapKey(tester, 'source-swap-check-site-a-100');
      expect(find.text('已选 1 条候选'), findsNothing);
    });

    testWidgets('解析期间行内显示「解析中…」', (tester) async {
      _useTallViewport(tester);
      final gate = Completer<List<VodPlayLine>>();
      await _openSheet(
        tester,
        snapshot: _twoEntriesSnapshot(),
        onProbe: (candidate) => gate.future,
      );
      await _tapKey(tester, 'source-swap-check-site-a-100');
      await _tapKey(tester, 'source-swap-commit');
      expect(find.text('解析中…'), findsOneWidget);

      gate.complete([_line('线路')]);
      await tester.pumpAndSettle();
      expect(find.text('解析中…'), findsNothing);
      expect(find.text('1 集'), findsOneWidget);
    });

    testWidgets('解析返回空线路按失败处理，不冒充 ready', (tester) async {
      _useTallViewport(tester);
      await _openSheet(
        tester,
        snapshot: _twoEntriesSnapshot(),
        onProbe: (candidate) async => const <VodPlayLine>[],
      );
      await _tapKey(tester, 'source-swap-check-site-a-100');
      await _tapKey(tester, 'source-swap-commit');
      await tester.pumpAndSettle();

      expect(find.text('无分集'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('source-swap-retry-site-a-100')),
        findsOneWidget,
      );
      // 还没 ready，所以按钮不能变成「并入」。
      expect(find.text('解析所选 · 1 条'), findsOneWidget);
    });

    testWidgets('全流程：一条成功一条失败 → 重试失败行 → 并入，返回行集正确', (tester) async {
      _useTallViewport(tester);
      var siteBFails = true;
      final popped = await _openSheet(
        tester,
        snapshot: _twoEntriesSnapshot(),
        onProbe: (candidate) async {
          if (candidate.siteKey == 'site-b' && siteBFails) {
            throw AppError(AppErrorKind.siteHttp, '目标站返回 500');
          }
          return [
            _line(
              '${candidate.siteKey} 线路',
              episodes: candidate.siteKey == 'site-a' ? 2 : 3,
            ),
          ];
        },
      );

      await _tapKey(tester, 'source-swap-check-site-a-100');
      await _tapKey(tester, 'source-swap-check-site-b-200');
      await _tapKey(tester, 'source-swap-commit');
      await tester.pumpAndSettle();

      // 部分成功：成功的行留在 ready，失败的行各自失败。
      expect(find.text('2 集'), findsOneWidget);
      expect(find.text('无分集'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('source-swap-retry-site-b-200')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('source-swap-retry-site-a-100')),
        findsNothing,
      );
      expect(find.text('解析所选 · 2 条'), findsOneWidget);

      // 失败原因进 tooltip（AppError 取 userMessage）。
      final tooltips = tester
          .widgetList<Tooltip>(find.byType(Tooltip))
          .map((tooltip) => tooltip.message ?? '')
          .toList();
      expect(tooltips.any((message) => message.contains('目标站返回 500')), isTrue);

      // 单行重试：只重跑失败那一行。
      siteBFails = false;
      await _tapKey(tester, 'source-swap-retry-site-b-200');
      await tester.pumpAndSettle();
      expect(find.text('无分集'), findsNothing);
      expect(find.text('3 集'), findsOneWidget);
      expect(find.text('并入 2 条线路'), findsOneWidget);

      await _tapKey(tester, 'source-swap-commit');
      await tester.pumpAndSettle();

      final rows = await popped;
      expect(rows, isNotNull);
      expect(rows!.length, 2);
      expect(rows.every((row) => row.ready), isTrue);
      expect(rows.every((row) => row.selected), isTrue);
      expect(
        rows
            .map((row) => '${row.candidate.siteKey}-${row.candidate.vodId}')
            .toSet(),
        <String>{'site-a-100', 'site-b-200'},
      );
      expect(rows.map((row) => row.candidate.vodName).toSet(), <String>{'示例剧'});
      // 线路 flag 原样交回，调用方才能用它做外部线路的 key。
      expect(
        rows.expand((row) => row.lines).map((line) => line.flag).toSet(),
        <String>{'site-a 线路', 'site-b 线路'},
      );
      // 浮层已关闭，且没有留下未解析的行。
      expect(find.byKey(const ValueKey('source-swap-sheet')), findsNothing);
    });

    testWidgets('关闭按钮 pop(null)，不返回空列表', (tester) async {
      _useTallViewport(tester);
      final popped = await _openSheet(
        tester,
        snapshot: _twoEntriesSnapshot(),
        onProbe: (candidate) async => [_line('线路')],
      );
      await _tapKey(tester, 'source-swap-close');
      await tester.pumpAndSettle();
      expect(await popped, isNull);
    });

    testWidgets('点遮罩 pop(null)', (tester) async {
      _useTallViewport(tester);
      final popped = await _openSheet(
        tester,
        snapshot: _twoEntriesSnapshot(),
        onProbe: (candidate) async => [_line('线路')],
      );
      // 浮层必须贴底：底边贴着视口底、高度 = min(视口 * 0.86, 820)。
      // 之前用 Center 包浮层，Center 撑满整个路由区域，浮层被竖直居中悬在
      // 屏幕中间，它的透明区域盖住了遮罩——点遮罩根本关不掉。这条断言就是
      // 那次回归的护栏。
      final rect = tester.getRect(
        find.byKey(const ValueKey('source-swap-sheet')),
      );
      expect(rect.bottom, moreOrLessEquals(1200));
      expect(rect.top, moreOrLessEquals(1200 - 820));
      // 浮层上方就是遮罩。
      await tester.tapAt(Offset(rect.center.dx, rect.top - 40));
      await tester.pumpAndSettle();
      expect(await popped, isNull);
      expect(find.byKey(const ValueKey('source-swap-sheet')), findsNothing);
    });

    testWidgets('Esc pop(null)', (tester) async {
      _useTallViewport(tester);
      final popped = await _openSheet(
        tester,
        snapshot: _twoEntriesSnapshot(),
        onProbe: (candidate) async => [_line('线路')],
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(await popped, isNull);
    });

    testWidgets('回车换关键词才重新搜索，并清空分组筛选', (tester) async {
      _useTallViewport(tester);
      final calls = <String>[];
      final snapshot = _twoEntriesSnapshot();
      await _openSheet(
        tester,
        snapshot: snapshot,
        onProbe: (candidate) async => [_line('线路')],
        calls: calls,
      );
      await _tapKey(tester, 'source-swap-group-电影');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('source-swap-row-site-b-200')),
        findsNothing,
      );

      // 用户主动改关键词回车：这一次才允许发请求。
      await tester.enterText(
        find.byKey(const ValueKey('source-swap-query')),
        '另一个片名',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(calls, <String>['示例剧', '另一个片名']);
      // 新关键词 = 新一批结果，旧的本地筛选被清掉（回到「全部」）。
      expect(
        find.byKey(const ValueKey('source-swap-row-site-b-200')),
        findsOneWidget,
      );
    });

    testWidgets('行尾状态点用 statusOf 的来源色', (tester) async {
      _useTallViewport(tester);
      await _openSheet(
        tester,
        snapshot: _twoEntriesSnapshot(),
        onProbe: (candidate) async => [_line('线路')],
        statusOf: (siteKey) =>
            siteKey == 'site-a' ? SourceStatus.ok : SourceStatus.failed,
      );

      final row = find.byKey(const ValueKey('source-swap-row-site-a-100'));
      final dot = tester
          .widgetList<Container>(
            find.descendant(of: row, matching: find.byType(Container)),
          )
          .firstWhere((container) {
            final constraints = container.constraints;
            return constraints != null &&
                constraints.maxWidth == 6 &&
                constraints.maxHeight == 6;
          });
      final decoration = dot.decoration! as BoxDecoration;
      expect(decoration.borderRadius, BorderRadius.circular(2));

      final context = tester.element(row);
      expect(decoration.color, sourceStatusColor(context, SourceStatus.ok));
      expect(
        decoration.color,
        isNot(sourceStatusColor(context, SourceStatus.failed)),
      );
    });

  });
}
