/// 弹幕搜索大对话框的离屏行为测试（`lib/ui/danmaku_search_dialog.dart`）。
///
/// 覆盖多弹幕源 S3 的九条：打开即搜、来源筛选、渠道筛选、倒序、仅本集
/// （含「解析不出集号不排除」）、分组折叠、选中返回、无源提示、runner 抛错；
/// 外加 S4 的视觉层级断言（分组头/渠道徽章/筛选标签/各状态）。
///
/// **不触网**：搜索函数（`DanmakuSearchRunner`）是注入的假实现——窗口把
/// 搜索做成参数，唯一理由就是这条测试能在没有网络、没有 mpv 的环境里跑。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/danmaku_match.dart';
import 'package:webhtv_pc/core/danmaku_settings.dart';
import 'package:webhtv_pc/services/danmaku_library_service.dart';
import 'package:webhtv_pc/ui/danmaku_search_dialog.dart';
import 'package:webhtv_pc/ui/theme.dart';

const DanmakuQuery _query = DanmakuQuery(
  title: '灵笼 第二季',
  episode: '第3集',
  siteKey: 'demo',
  vodId: 'vod-1',
  episodeName: '第3集',
);

const List<DanmakuSourceConfig> _twoSources = [
  DanmakuSourceConfig(id: 's1', name: '中转A', url: 'http://a.test/danmaku'),
  DanmakuSourceConfig(id: 's2', name: '中转B', url: 'http://b.test/danmaku'),
];

DanmakuLibraryEntry _entry({
  required String title,
  required String episode,
  String libraryId = 's1',
  String libraryName = '中转A',
  String channel = 'bilibili',
}) => DanmakuLibraryEntry(
  providerId: 'relay',
  id: '$libraryId|$title|$episode',
  title: title,
  episode: episode,
  url: 'https://example.test/$libraryId/$title/$episode',
  count: 12,
  libraryId: libraryId,
  libraryName: libraryName,
  channel: channel,
);

/// 「一马当先」两个年份的候选：组间排序的对照组。
DanmakuLibraryEntry _yimaEntry(String year, String episode) =>
    DanmakuLibraryEntry(
      providerId: 'relay',
      id: 'yima|$year|$episode',
      title: '一马当先($year)【电视剧】from tencent',
      episode: episode,
      url: 'https://example.test/yima/$year/$episode',
      count: 8,
      libraryId: 's1',
      libraryName: '中转A',
      channel: 'bilibili',
    );

/// 带年份的查询：年份来自详情页的结构化字段，标题里没有括注。
const DanmakuQuery _query2026 = DanmakuQuery(
  title: '一马当先',
  episode: '第1集',
  year: 2026,
  siteKey: 'demo',
  vodId: 'vod-2',
  episodeName: '第1集',
);

/// 同一条查询但年份未知：组间只能靠名称/条目数/剧名裁决。
const DanmakuQuery _queryNoYear = DanmakuQuery(
  title: '一马当先',
  episode: '第1集',
  siteKey: 'demo',
  vodId: 'vod-2',
  episodeName: '第1集',
);

/// 逐源记账：按条目归属统计条数，未出现在结果里的源记 0 条。
DanmakuLibraryQueryResult _result(
  List<DanmakuLibraryEntry> entries, {
  Map<String, String> failures = const {},
}) {
  return DanmakuLibraryQueryResult(
    entries: entries,
    sources: [
      for (final source in _twoSources)
        DanmakuLibrarySourceResult(
          id: source.id,
          name: source.name,
          ok: !failures.containsKey(source.id),
          count: entries.where((e) => e.libraryId == source.id).length,
          elapsedMs: 12,
          error: failures[source.id],
        ),
    ],
  );
}

/// 打开对话框并把返回值收进 [results]（取消时收到 null）。
Future<void> _open(
  WidgetTester tester, {
  required DanmakuSearchRunner runner,
  List<DanmakuSourceConfig> sources = _twoSources,
  List<DanmakuLibraryEntry?>? results,
  String? initialKeyword,
  String? currentUrl,
  DanmakuQuery query = _query,
  bool settle = true,
  Size size = const Size(1280, 800),
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
                final result = await showDanmakuSearchDialog(
                  context: context,
                  sources: sources,
                  query: query,
                  initialKeyword: initialKeyword,
                  runner: runner,
                  currentUrl: currentUrl,
                );
                results?.add(result);
              },
              child: const Text('打开搜索'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开搜索'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

/// 结果行：`danmaku-search-entry-<index>`（索引跨组连续）。
Finder _rows() => find.byWidgetPredicate(
  (widget) =>
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith(
        'danmaku-search-entry-',
      ),
);

Finder _row(int index) => find.byKey(ValueKey('danmaku-search-entry-$index'));

/// 某一行里的某段文案（行是两行布局，集名与元信息分开断言更稳）。
Finder _rowText(int index, String text) =>
    find.descendant(of: _row(index), matching: find.text(text));

/// 全部结果行里的某段文案（跨行断言「某个来源库一条都没有」）。
Finder _rowsText(String text) =>
    find.descendant(of: _rows(), matching: find.text(text));

/// 分组头：标题与尾部计数现在是两段独立文案（标题加粗、计数做淡）。
Finder _group(int index) =>
    find.byKey(ValueKey('danmaku-search-group-$index'));

Finder _groupText(int index, String text) =>
    find.descendant(of: _group(index), matching: find.text(text));

void main() {
  testWidgets('打开即自动搜索一次：关键词预填、分组头与行都渲染', (tester) async {
    final queries = <String>[];
    await _open(
      tester,
      initialKeyword: '灵笼 第二季 2025',
      runner: ({required sources, required title, episode, onSourceResult}) async {
        queries.add(title);
        expect(sources, hasLength(2), reason: '窗口应把全部源交给 runner');
        expect(episode, '第3集');
        return _result([
          _entry(title: '灵笼 第二季', episode: '第1集 末世桃源'),
          _entry(title: '灵笼 第二季', episode: '第3集 归途'),
          _entry(
            title: '凡人修仙传',
            episode: '第3集',
            libraryId: 's2',
            libraryName: '中转B',
            channel: 'dandan',
          ),
        ]);
      },
    );

    expect(queries, ['灵笼 第二季 2025'], reason: '打开即按 initialKeyword 搜一次');

    final keyword = tester.widget<TextField>(
      find.byKey(const ValueKey('danmaku-search-keyword')),
    );
    expect(keyword.controller?.text, '灵笼 第二季 2025');

    // 组间：最高分降序 + 剧名升序，所以本集命中的「灵笼 第二季」在第一位。
    // 分组头：标题与「· N 集」是两段独立文案，标题不再是「灵笼 第二季 (2集)」。
    expect(_groupText(0, '灵笼 第二季'), findsOneWidget);
    expect(_groupText(0, '· 2 集'), findsOneWidget);
    expect(_groupText(1, '凡人修仙传'), findsOneWidget);
    expect(_groupText(1, '· 1 集'), findsOneWidget);
    expect(_rows(), findsNWidgets(3));
    // 组内按集号升序。
    expect(_rowText(0, '第1集 末世桃源'), findsOneWidget);
    expect(_rowText(1, '第3集 归途'), findsOneWidget);
    // 行内元信息拆成三段：渠道徽章、来源库名、条数（分数单独右对齐）。
    expect(_rowText(0, 'bilibili'), findsOneWidget);
    expect(_rowText(1, 'bilibili'), findsOneWidget);
    expect(_rowText(2, 'dandan'), findsOneWidget);
    expect(_rowText(0, '中转A'), findsOneWidget);
    expect(_rowText(2, '中转B'), findsOneWidget);
    expect(find.textContaining('12 条'), findsNWidgets(3));
    // 标题栏右侧的规模概览。
    expect(find.text('2 个源 · 3 条结果'), findsOneWidget);
  });

  testWidgets('来源 chip 显示各源条数，选中后只显示该源的条目', (tester) async {
    await _open(
      tester,
      runner: ({required sources, required title, episode, onSourceResult}) async => _result([
        _entry(title: '灵笼 第二季', episode: '第1集'),
        _entry(
          title: '灵笼 第二季',
          episode: '第2集',
          libraryId: 's2',
          libraryName: '中转B',
        ),
        _entry(
          title: '灵笼 第二季',
          episode: '第4集',
          libraryId: 's2',
          libraryName: '中转B',
        ),
      ]),
    );

    expect(find.text('中转A · 1'), findsOneWidget);
    expect(find.text('中转B · 2'), findsOneWidget);
    expect(_rows(), findsNWidgets(3));

    await tester.tap(find.byKey(const ValueKey('danmaku-search-source-s2')));
    await tester.pumpAndSettle();

    expect(_rows(), findsNWidgets(2));
    expect(_rowText(0, '第2集'), findsOneWidget);
    expect(_rowText(1, '第4集'), findsOneWidget);
    expect(_rowsText('中转A'), findsNothing, reason: '只剩 s2 的条目');

    await tester.tap(find.byKey(const ValueKey('danmaku-search-source-all')));
    await tester.pumpAndSettle();
    expect(_rows(), findsNWidgets(3));
  });

  testWidgets('渠道 chip 按 entry.channel 过滤，「全部渠道」复位', (tester) async {
    await _open(
      tester,
      runner: ({required sources, required title, episode, onSourceResult}) async => _result([
        _entry(title: '灵笼 第二季', episode: '第1集', channel: 'bilibili'),
        _entry(
          title: '灵笼 第二季',
          episode: '第2集',
          libraryId: 's2',
          libraryName: '中转B',
          channel: 'dandan',
        ),
        _entry(
          title: '灵笼 第二季',
          episode: '第4集',
          libraryId: 's2',
          libraryName: '中转B',
          channel: 'qq',
        ),
      ]),
    );

    expect(_rows(), findsNWidgets(3));

    await tester.tap(find.byKey(const ValueKey('danmaku-search-channel-qq')));
    await tester.pumpAndSettle();
    expect(_rows(), findsOneWidget);
    expect(_rowText(0, 'qq'), findsOneWidget);
    expect(_rowText(0, '中转B'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('danmaku-search-channel-all')));
    await tester.pumpAndSettle();
    expect(_rows(), findsNWidgets(3));
  });

  testWidgets('倒序切换改变组内集号顺序，chip 文案在集数 ↑/↓ 间切换', (tester) async {
    await _open(
      tester,
      runner: ({required sources, required title, episode, onSourceResult}) async => _result([
        _entry(title: '灵笼 第二季', episode: '第1集'),
        _entry(title: '灵笼 第二季', episode: '第3集'),
        _entry(title: '灵笼 第二季', episode: '第5集'),
      ]),
    );

    // 文案直接写「集数 ↑」：默认排序是显式可见的，不需要用户猜「正序」排什么。
    expect(find.text('集数 ↑'), findsOneWidget);
    expect(_rowText(0, '第1集'), findsOneWidget);
    expect(_rowText(2, '第5集'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('danmaku-search-order')));
    await tester.pumpAndSettle();

    expect(find.text('集数 ↓'), findsOneWidget);
    expect(_rowText(0, '第5集'), findsOneWidget);
    expect(_rowText(2, '第1集'), findsOneWidget);
  });

  testWidgets('仅本集：只留当前集号，解析不出集号的条目不排除', (tester) async {
    await _open(
      tester,
      runner: ({required sources, required title, episode, onSourceResult}) async => _result([
        _entry(title: '灵笼 第二季', episode: '第1集'),
        _entry(title: '灵笼 第二季', episode: '第3集'),
        // 解析不出集号：既不能当成「本集」，也不能被当成「不是本集」丢掉。
        _entry(title: '灵笼 第二季', episode: '幕后花絮'),
        _entry(title: '灵笼 第二季', episode: '第10集'),
      ]),
    );

    expect(_rows(), findsNWidgets(4));

    await tester.tap(find.byKey(const ValueKey('danmaku-search-current-only')));
    await tester.pumpAndSettle();

    expect(_rows(), findsNWidgets(2));
    expect(find.text('第3集'), findsOneWidget);
    expect(find.text('幕后花絮'), findsOneWidget);
    expect(find.text('第1集'), findsNothing);
    expect(find.text('第10集'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('danmaku-search-current-only')));
    await tester.pumpAndSettle();
    expect(_rows(), findsNWidgets(4), reason: '再点一次回到全部集');
  });

  testWidgets('分组折叠：点组标题隐藏该组行，再点恢复', (tester) async {
    await _open(
      tester,
      runner: ({required sources, required title, episode, onSourceResult}) async => _result([
        _entry(title: '灵笼 第二季', episode: '第1集'),
        _entry(title: '灵笼 第二季', episode: '第3集'),
        _entry(
          title: '凡人修仙传',
          episode: '第3集',
          libraryId: 's2',
          libraryName: '中转B',
          channel: 'dandan',
        ),
      ]),
    );

    expect(_rows(), findsNWidgets(3));
    expect(_groupText(0, '灵笼 第二季'), findsOneWidget);
    expect(_groupText(0, '· 2 集'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('danmaku-search-group-0')));
    await tester.pumpAndSettle();

    expect(_groupText(0, '灵笼 第二季'), findsOneWidget, reason: '组标题本身还在');
    expect(find.text('第1集'), findsNothing);
    expect(_rows(), findsOneWidget, reason: '只剩另一组的行');

    await tester.tap(find.byKey(const ValueKey('danmaku-search-group-0')));
    await tester.pumpAndSettle();
    expect(_rows(), findsNWidgets(3));
    expect(find.text('第1集'), findsOneWidget);
  });

  testWidgets('点击结果行把该条目 pop 出去并关闭窗口', (tester) async {
    final results = <DanmakuLibraryEntry?>[];
    await _open(
      tester,
      results: results,
      runner: ({required sources, required title, episode, onSourceResult}) async => _result([
        _entry(title: '灵笼 第二季', episode: '第3集'),
        _entry(
          title: '灵笼 第二季',
          episode: '第4集',
          libraryId: 's2',
          libraryName: '中转B',
        ),
      ]),
    );

    await tester.tap(_row(1));
    await tester.pumpAndSettle();

    expect(results, hasLength(1));
    expect(results.single?.episode, '第4集');
    expect(results.single?.libraryId, 's2');
    expect(find.text('搜索弹幕'), findsNothing, reason: '选中后窗口应关闭');
  });

  testWidgets('没有可用源：显示「未配置弹幕源」且不调用 runner', (tester) async {
    var calls = 0;
    await _open(
      tester,
      sources: const [],
      runner: ({required sources, required title, episode, onSourceResult}) async {
        calls++;
        return _result(const []);
      },
    );

    expect(calls, 0, reason: '没有源就没有可发的请求');
    expect(find.text('未配置弹幕源'), findsOneWidget);
    expect(find.byKey(const ValueKey('danmaku-search-submit')), findsOneWidget);
  });

  testWidgets('runner 抛错时落到可见错误态，不崩也不卡在 loading', (tester) async {
    await _open(
      tester,
      runner: ({required sources, required title, episode, onSourceResult}) async {
        throw StateError('boom');
      },
    );

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('danmaku-search-loading')), findsNothing);
    expect(find.text('搜索失败，请稍后重试'), findsOneWidget);
    expect(find.textContaining('boom'), findsOneWidget);
  });

  testWidgets('搜索中显示 loading 态与源数量，完成后换成结果', (tester) async {
    final completer = Completer<DanmakuLibraryQueryResult>();
    await _open(
      tester,
      settle: false,
      runner: ({required sources, required title, episode, onSourceResult}) => completer.future,
    );

    expect(find.byKey(const ValueKey('danmaku-search-loading')), findsOneWidget);
    expect(find.textContaining('正在搜索 2 个源'), findsOneWidget);

    completer.complete(
      _result([_entry(title: '灵笼 第二季', episode: '第3集')]),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('danmaku-search-loading')), findsNothing);
    expect(_rows(), findsOneWidget);
  });

  testWidgets('小屏（640×480）不溢出', (tester) async {
    await _open(
      tester,
      size: const Size(640, 480),
      runner: ({required sources, required title, episode, onSourceResult}) async => _result([
        _entry(title: '一个很长很长很长很长很长很长的剧名 第二季', episode: '第1集'),
        _entry(title: '灵笼 第二季', episode: '第3集'),
        _entry(title: '凡人修仙传', episode: '第3集', libraryId: 's2'),
      ]),
    );

    expect(tester.takeException(), isNull);
    expect(_rows(), findsNWidgets(3));
  });

  // ---- S5：默认排序、年份分组、控件尺寸 ----

  testWidgets('默认按集号数值升序：渲染顺序是 第1集 / 第2集 / 第10集', (tester) async {
    await _open(
      tester,
      runner: ({required sources, required title, episode, onSourceResult}) async => _result([
        _entry(title: '灵笼 第二季', episode: '第10集'),
        _entry(title: '灵笼 第二季', episode: '第1集'),
        _entry(title: '灵笼 第二季', episode: '第2集'),
      ]),
    );

    // 输入顺序是 10/1/2：按字符串比会排成 1,10,2，按数值比才是 1,2,10。
    expect(_rowText(0, '第1集'), findsOneWidget);
    expect(_rowText(1, '第2集'), findsOneWidget);
    expect(_rowText(2, '第10集'), findsOneWidget);
    expect(find.text('集数 ↑'), findsOneWidget, reason: '默认就是集数升序');
  });

  testWidgets('同名不同年份的两部剧不混组，各自组内按集号排', (tester) async {
    await _open(
      tester,
      runner: ({required sources, required title, episode, onSourceResult}) async => _result([
        _entry(
          title: '一马当先(2026)【电视剧】from tencent',
          episode: '一马当先 第1集',
        ),
        _entry(
          title: '一马当先(2026)【电视剧】from bilibili',
          episode: '一马当先 第2集',
        ),
        _entry(
          title: '一马当先(2023)【短剧】from hongguo',
          episode: '第1集',
          libraryId: 's2',
          libraryName: '中转B',
          channel: 'hongguo',
        ),
      ]),
    );

    // 两个年份各自成组：混成一组的话只会有一个分组头、行数还会多一行「第2集」。
    expect(find.text('一马当先(2026)'), findsOneWidget);
    expect(find.text('一马当先(2023)'), findsOneWidget);
    expect(find.text('· 2 集'), findsOneWidget);
    expect(find.text('· 1 集'), findsOneWidget);
    expect(_rows(), findsNWidgets(3));
  });

  testWidgets('集名去掉重复的剧名前缀（年份括注不算剧名的一部分）', (tester) async {
    await _open(
      tester,
      runner: ({required sources, required title, episode, onSourceResult}) async => _result([
        _entry(
          title: '一马当先(2026)【电视剧】from tencent',
          episode: '一马当先 第1集',
        ),
        _entry(
          title: '一马当先(2026)【电视剧】from bilibili',
          episode: '一马当先行大运01',
        ),
      ]),
    );

    // 剧名已经在分组头上出现过：行里再念一遍只是噪声。
    expect(_rowsText('第1集'), findsOneWidget);
    expect(_rowsText('一马当先 第1集'), findsNothing);
    // 剧名之后是一段集名时，从集号数字处保留。
    expect(_rowsText('01'), findsOneWidget);
    expect(_rowsText('一马当先行大运01'), findsNothing);
  });

  testWidgets('查询行三个控件同高 32（搜索 / 集数排序 / 仅本集）', (tester) async {
    await _open(
      tester,
      runner: ({required sources, required title, episode, onSourceResult}) async => _result([
        _entry(title: '灵笼 第二季', episode: '第1集'),
      ]),
    );

    for (final key in const [
      'danmaku-search-submit',
      'danmaku-search-order',
      'danmaku-search-current-only',
    ]) {
      expect(
        tester.getSize(find.byKey(ValueKey(key))).height,
        32,
        reason: '$key 与同一行的其它控件同高',
      );
    }
    // 输入框也收到同一档，底边才对得齐。
    expect(
      tester.getSize(find.byKey(const ValueKey('danmaku-search-keyword'))).height,
      32,
    );
  });

  testWidgets('组内一条集号都解析不出来时标出「· 未识别集号」', (tester) async {
    await _open(
      tester,
      runner: ({required sources, required title, episode, onSourceResult}) async => _result([
        _entry(title: '灵笼 第二季', episode: '幕后花絮'),
        _entry(title: '灵笼 第二季', episode: '先导预告'),
      ]),
    );

    // 静默按原顺序摆会被读成「排序坏了」，所以明说一句。
    expect(_groupText(0, '· 未识别集号'), findsOneWidget);
    expect(find.text('· 未识别集号'), findsOneWidget);
  });

  // ---- S4：视觉与信息层级 ----

  testWidgets('筛选区带「来源」「渠道」语义标签', (tester) async {
    await _open(
      tester,
      runner: ({required sources, required title, episode, onSourceResult}) async => _result([
        _entry(title: '灵笼 第二季', episode: '第3集'),
      ]),
    );

    expect(find.text('来源'), findsOneWidget);
    expect(find.text('渠道'), findsOneWidget);
    expect(find.text('全部来源'), findsOneWidget);
    expect(find.text('全部渠道'), findsOneWidget);
  });

  // ---- S6：逐源增量渲染 + 「当前」标记 ----

  testWidgets('渐进渲染：先回来的源立刻出行，进度条显示 x/N 完成数', (tester) async {
    final gate = Completer<void>();
    final fast = [_entry(title: '灵笼 第二季', episode: '第1集')];
    final slow = [
      _entry(
        title: '凡人修仙传',
        episode: '第3集',
        libraryId: 's2',
        libraryName: '中转B',
        channel: 'dandan',
      ),
    ];
    await _open(
      tester,
      settle: false,
      runner:
          ({required sources, required title, episode, onSourceResult}) async {
            // 窗口总会传 onSourceResult；取一次非空引用，省掉两处重复判空。
            final report = onSourceResult!;
            // 真实 runner 不会在构建期同步回调；先让出一拍，时序才和「网络回来」一致。
            await Future<void>.value();
            report(
              const DanmakuLibrarySourceResult(
                id: 's1',
                name: '中转A',
                ok: true,
                count: 1,
                elapsedMs: 5,
              ),
              fast,
            );
            await gate.future;
            report(
              const DanmakuLibrarySourceResult(
                id: 's2',
                name: '中转B',
                ok: true,
                count: 1,
                elapsedMs: 60,
              ),
              slow,
            );
            return DanmakuLibraryQueryResult(
              entries: [...fast, ...slow],
              sources: const [
                DanmakuLibrarySourceResult(
                  id: 's1',
                  name: '中转A',
                  ok: true,
                  count: 1,
                  elapsedMs: 5,
                ),
                DanmakuLibrarySourceResult(
                  id: 's2',
                  name: '中转B',
                  ok: true,
                  count: 1,
                  elapsedMs: 60,
                ),
              ],
            );
          },
    );

    // 只有 A 回来了：A 的行要立刻可见，B 的半行都不能有，进度条仍要在。
    await tester.pump();
    expect(_rows(), findsOneWidget);
    expect(_rowText(0, '第1集'), findsOneWidget);
    expect(find.text('凡人修仙传'), findsNothing);
    expect(
      find.byKey(const ValueKey('danmaku-search-loading')),
      findsOneWidget,
      reason: '还有源在路上，进度条不能提前消失',
    );
    expect(find.textContaining('1/2 已完成'), findsOneWidget);
    expect(find.text('2 个源 · 1 条结果'), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('danmaku-search-loading')), findsNothing);
    expect(_rows(), findsNWidgets(2));
    expect(find.text('凡人修仙传'), findsOneWidget);
    expect(find.text('2 个源 · 2 条结果'), findsOneWidget);
  });

  testWidgets('currentUrl 命中：命中行标「当前」、该源 chip 带「· 当前」，其它行不标', (
    tester,
  ) async {
    final current = _entry(title: '灵笼 第二季', episode: '第3集');
    await _open(
      tester,
      currentUrl: current.url,
      runner: ({required sources, required title, episode, onSourceResult}) async =>
          _result([
            current,
            _entry(
              title: '凡人修仙传',
              episode: '第3集',
              libraryId: 's2',
              libraryName: '中转B',
              channel: 'dandan',
            ),
          ]),
    );

    // 行 0 是「灵笼 第二季」（剧名 + 本集都命中，分数最高），当前那条就在这。
    expect(
      find.byKey(const ValueKey('danmaku-search-current-0')),
      findsOneWidget,
    );
    expect(_rowText(0, '当前'), findsOneWidget);
    expect(_rowText(1, '当前'), findsNothing, reason: '没命中的行不能标');
    expect(find.text('中转A · 1 · 当前'), findsOneWidget);
    expect(find.text('中转B · 1'), findsOneWidget);
    // 「当前」可以被点：同一条重载是无害操作，不做禁用。
    expect(tester.widget<InkWell>(_row(0)).onTap, isNotNull);
  });

  testWidgets('currentUrl 为空：一处「当前」都不渲染', (tester) async {
    await _open(
      tester,
      runner: ({required sources, required title, episode, onSourceResult}) async =>
          _result([_entry(title: '灵笼 第二季', episode: '第3集')]),
    );

    expect(find.textContaining('当前'), findsNothing);
    expect(find.text('中转A · 1'), findsOneWidget);
  });

  testWidgets('重新搜索清空上一次的累计结果', (tester) async {
    var round = 0;
    await _open(
      tester,
      runner: ({required sources, required title, episode, onSourceResult}) async {
        round++;
        return round == 1
            ? _result([_entry(title: '灵笼 第二季', episode: '第1集')])
            : _result([_entry(title: '灵笼 第二季', episode: '第5集')]);
      },
    );

    expect(_rowText(0, '第1集'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('danmaku-search-submit')));
    await tester.pumpAndSettle();

    expect(_rowText(0, '第5集'), findsOneWidget);
    expect(find.text('第1集'), findsNothing, reason: '上一次的条目不能混进新结果');
    expect(_rows(), findsOneWidget);
    expect(find.text('2 个源 · 1 条结果'), findsOneWidget);
  });

  testWidgets('条目标题去掉【渠道】/[渠道] 前缀，整行都是标签时回退原值', (tester) async {
    await _open(
      tester,
      runner: ({required sources, required title, episode, onSourceResult}) async => _result([
        _entry(title: '灵笼 第二季', episode: '【bilibili1】 第001话'),
        _entry(title: '灵笼 第二季', episode: '[dandan]第002话'),
        _entry(title: '灵笼 第二季', episode: '【只有标签】'),
      ]),
    );

    expect(_rowsText('第001话'), findsOneWidget);
    expect(_rowsText('【bilibili1】'), findsNothing);
    expect(_rowsText('第002话'), findsOneWidget);
    expect(_rowsText('[dandan]'), findsNothing);
    // 清洗后为空说明整行都是标签：宁可重复，也不要一行空白。
    expect(_rowsText('【只有标签】'), findsOneWidget);
  });

  testWidgets('空结果：search_off 图标 + 换词提示', (tester) async {
    await _open(
      tester,
      runner: ({required sources, required title, episode, onSourceResult}) async =>
          _result(const []),
    );

    expect(find.byKey(const ValueKey('danmaku-search-empty')), findsOneWidget);
    expect(find.byIcon(Icons.search_off), findsOneWidget);
    expect(find.text('没有找到弹幕'), findsOneWidget);
    expect(find.text('换个关键词，或检查弹幕源配置'), findsOneWidget);
  });

  testWidgets('全部源失败：cloud_off + 逐源原因，不说成「没有弹幕」', (tester) async {
    await _open(
      tester,
      runner: ({required sources, required title, episode, onSourceResult}) async =>
          _result(const [], failures: {'s1': '超时', 's2': 'HTTP 502'}),
    );

    expect(find.byIcon(Icons.cloud_off), findsOneWidget);
    expect(find.text('所有弹幕源都失败了'), findsOneWidget);
    expect(find.text('中转A：超时'), findsOneWidget);
    expect(find.text('中转B：HTTP 502'), findsOneWidget);
    expect(find.text('没有找到弹幕'), findsNothing);
  });

  testWidgets('部分源失败：结果上方提示带，成功结果照常', (tester) async {
    await _open(
      tester,
      runner: ({required sources, required title, episode, onSourceResult}) async => _result(
        [_entry(title: '灵笼 第二季', episode: '第3集')],
        failures: {'s2': 'HTTP 500'},
      ),
    );

    expect(find.text('1 个源失败：中转B'), findsOneWidget);
    expect(_rows(), findsOneWidget);
    expect(_rowText(0, '第3集'), findsOneWidget);
    expect(find.byKey(const ValueKey('danmaku-search-empty')), findsNothing);
    // 提示带高 28，压在结果上方而不顶掉结果。
    final banner = find.byKey(const ValueKey('danmaku-search-failures'));
    expect(banner, findsOneWidget);
    expect(tester.getSize(banner).height, 28);
  });

  testWidgets('视觉规格：分组头 36 / 条目 56 / 渠道徽章 18 / 筛选标签 32 / 行间距 1', (
    tester,
  ) async {
    await _open(
      tester,
      runner: ({required sources, required title, episode, onSourceResult}) async => _result([
        _entry(title: '灵笼 第二季', episode: '第1集'),
        _entry(title: '灵笼 第二季', episode: '第2集'),
      ]),
    );

    final scheme = Theme.of(tester.element(_group(0))).colorScheme;

    // 折叠头：36 高的整行底色，与 56 高的条目拉出档差。
    expect(tester.getSize(_group(0)).height, 36);
    final headerInk = tester.widget<Ink>(
      find.descendant(of: _group(0), matching: find.byType(Ink)).first,
    );
    expect(
      (headerInk.decoration as BoxDecoration).color,
      scheme.surfaceContainerHigh,
      reason: '折叠头靠整块底色区别于条目行',
    );

    // 条目行：56 高、悬停用最深一档表面色。
    expect(tester.getSize(_row(0)).height, 56);
    expect(tester.getSize(_row(1)).height, 56);
    expect(tester.widget<InkWell>(_row(0)).hoverColor, scheme.surfaceContainerHighest);

    // 去掉装饰线，保留原来 1px 行间距。
    expect(tester.getRect(_row(1)).top - tester.getRect(_row(0)).bottom, 1);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('danmaku-search-results')),
        matching: find.byType(Divider),
      ),
      findsNothing,
    );

    // 渠道徽章：18 高、胶囊圆角 9。
    final badge = find.byWidgetPredicate(
      (widget) =>
          widget is Container &&
          widget.decoration is BoxDecoration &&
          (widget.decoration! as BoxDecoration).borderRadius ==
              BorderRadius.circular(9),
    );
    expect(badge, findsNWidgets(2));
    expect(tester.getSize(badge.first).height, 18);

    // 筛选行左侧标签固定 32 宽，两行 chip 起点对齐。
    expect(tester.getSize(find.text('来源')).width, 32);
    expect(tester.getSize(find.text('渠道')).width, 32);
  });

  // ---- S7b：组间相似度排序、默认展开「当前」、一键展开/折叠 ----

  testWidgets('分组按多维相似度排序：query 年份命中 2026 时 2026 组在前', (tester) async {
    await _open(
      tester,
      query: _query2026,
      runner: ({required sources, required title, episode, onSourceResult}) async =>
          _result([
            _yimaEntry('2023', '第1集'),
            _yimaEntry('2026', '第1集'),
          ]),
    );

    // 输入顺序是 2023 在前；两组的名称分相同，是年份把它们分开的。
    expect(_groupText(0, '一马当先(2026)'), findsOneWidget);
    expect(_groupText(1, '一马当先(2023)'), findsOneWidget);
    expect(_rows(), findsNWidgets(2));
  });

  testWidgets('对照：query 年份未知时两组照样出行，同分同条数下按剧名升序', (tester) async {
    await _open(
      tester,
      query: _queryNoYear,
      runner: ({required sources, required title, episode, onSourceResult}) async =>
          _result([
            _yimaEntry('2026', '第1集'),
            _yimaEntry('2023', '第1集'),
          ]),
    );

    // 年份两侧都缺 → 中性分；两组同分同条数，落到剧名升序。
    // 有排序不稳定/不工作的实现会在这里抖动或整组消失。
    expect(_groupText(0, '一马当先(2023)'), findsOneWidget);
    expect(_groupText(1, '一马当先(2026)'), findsOneWidget);
    expect(_rows(), findsNWidgets(2));
  });

  testWidgets('默认只展开「当前」所在组：其余组折叠，点组头才展开', (tester) async {
    final current = _yimaEntry('2023', '第3集');
    await _open(
      tester,
      query: _query2026,
      currentUrl: current.url,
      runner: ({required sources, required title, episode, onSourceResult}) async =>
          _result([_yimaEntry('2026', '第5集'), current]),
    );

    // 排序把 2026 组摆在前面，但「当前」那条在 2023 组：默认展开的是后者。
    expect(_groupText(0, '一马当先(2026)'), findsOneWidget);
    expect(_groupText(1, '一马当先(2023)'), findsOneWidget);
    expect(_rows(), findsOneWidget, reason: '只展开当前那条所在的 2023 组');
    expect(find.text('第3集'), findsOneWidget);
    expect(find.text('第5集'), findsNothing, reason: '2026 组的行默认折叠');
    expect(find.text('当前'), findsOneWidget);

    await tester.tap(_group(0));
    await tester.pumpAndSettle();

    expect(find.text('第5集'), findsOneWidget, reason: '点组头后该组展开');
    expect(_rows(), findsNWidgets(2));
  });

  testWidgets('没有「当前」条目时全部展开', (tester) async {
    await _open(
      tester,
      query: _query2026,
      runner: ({required sources, required title, episode, onSourceResult}) async =>
          _result([_yimaEntry('2026', '第5集'), _yimaEntry('2023', '第1集')]),
    );

    expect(_rows(), findsNWidgets(2));
    expect(find.text('第5集'), findsOneWidget);
    expect(find.text('第1集'), findsOneWidget);
  });

  testWidgets('一键展开/折叠全部：点一次只剩组头，再点一次全部展开', (tester) async {
    await _open(
      tester,
      query: _query2026,
      runner: ({required sources, required title, episode, onSourceResult}) async =>
          _result([_yimaEntry('2026', '第5集'), _yimaEntry('2023', '第1集')]),
    );

    final toggle = find.byKey(const ValueKey('danmaku-search-toggle-all'));
    expect(toggle, findsOneWidget);
    expect(_rows(), findsNWidgets(2));
    expect(find.byTooltip('折叠全部'), findsOneWidget);

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(_rows(), findsNothing, reason: '全部折叠后一行都不剩');
    expect(_group(0), findsOneWidget, reason: '组头仍在');
    expect(_group(1), findsOneWidget);
    expect(find.byTooltip('展开全部'), findsOneWidget);

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(_rows(), findsNWidgets(2));
    expect(find.text('第5集'), findsOneWidget);
    expect(find.text('第1集'), findsOneWidget);
    expect(find.byTooltip('折叠全部'), findsOneWidget);
  });
}
