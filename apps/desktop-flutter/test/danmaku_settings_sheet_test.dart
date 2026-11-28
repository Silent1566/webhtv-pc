/// 播放器内的「页签式弹幕设置弹层」：四个页签、即改即生效、源就地切换。
///
/// ## 这一组用例锁什么
///
/// 1. 四个页签各自只渲染自己的控件——弹层高度有限，同时铺开会把底部按钮
///    挤出屏幕；
/// 2. 显示项的每次变化都以新值回调 onChanged；恢复默认回 DanmakuStyle.defaults；
/// 3. 弹幕源页签按 sources 渲染、标出当前项，点非当前项才回调 onSelectSource，
///    并用 outcome 刷新当前项/条数/错误；点当前项不发请求；
/// 4. 当前地址不在 sources 里时合成「当前在用 · 弹幕库」一行；空状态的两个
///    入口和顶部摘要都落到正确的三态动作上。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/danmaku_style.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/ui/danmaku_settings_sheet.dart';
import 'package:webhtv_pc/ui/player_overlay.dart';
import 'package:webhtv_pc/ui/theme.dart';

const _sourceAUrl = 'https://a.test/danmaku/ep1.xml';
const _sourceBUrl = 'wss://live.test/room/42';
const _libraryUrl = 'https://lib.test/api/danmaku';
const _sourceA = DanmakuSource(url: _sourceAUrl, name: '星河');
const _sourceB = DanmakuSource(url: _sourceBUrl, name: '直播房');
const _sourceCUrl = 'https://c.test/danmaku/ep3.xml';
const _sourceC = DanmakuSource(url: _sourceCUrl, name: '第三集');
const _sources = <DanmakuSource>[_sourceA, _sourceB];
const _pointSourceView = DanmakuSourceView(
  sources: [_sourceA, _sourceC],
  currentUrl: _sourceAUrl,
  itemCount: 12,
  libraryUrl: _libraryUrl,
  libraryTotal: 2,
);
const _sourceView = DanmakuSourceView(
  sources: _sources,
  currentUrl: _sourceAUrl,
  itemCount: 12,
  libraryUrl: _libraryUrl,
  libraryTotal: 2,
);
const _syntheticUrl = 'https://library.test/d/1.xml';

/// 弹层返回的三态；每次展示追加一条。
final List<DanmakuSheetAction> _actions = <DanmakuSheetAction>[];

Future<DanmakuSourceLoadOutcome> _defaultSelect(DanmakuSource source) async =>
    DanmakuSourceLoadOutcome(ok: true, currentUrl: source.url);

Future<void> _openSheet(
  WidgetTester tester, {
  DanmakuStyle style = const DanmakuStyle(),
  Size size = const Size(1024, 800),
  DanmakuSourceView sourceView = const DanmakuSourceView(),
  required ValueChanged<DanmakuStyle> onChanged,
  Future<DanmakuSourceLoadOutcome> Function(DanmakuSource)? onSelectSource,
}) async {
  _actions.clear();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              key: const ValueKey('open-danmaku-sheet'),
              onPressed: () async {
                final action = await showDanmakuSettingsSheet(
                  context,
                  style: style,
                  onChanged: onChanged,
                  sourceView: sourceView,
                  onSelectSource: onSelectSource ?? _defaultSelect,
                );
                _actions.add(action);
              },
              child: const Text('打开弹幕设置'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open-danmaku-sheet')));
  await tester.pumpAndSettle();
  expect(
    find.byKey(const ValueKey('player-danmaku-sheet')),
    findsOneWidget,
    reason: '点击入口必须弹出弹层',
  );
}

Future<void> _showSourcesTab(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('player-danmaku-tab-sources')));
  await tester.pumpAndSettle();
  expect(
    find.byKey(const ValueKey('player-danmaku-tab-sources-body')),
    findsOneWidget,
  );
}

void main() {
  testWidgets('四个页签各自显示自己的控件', (tester) async {
    await _openSheet(tester, onChanged: (_) {});

    expect(
      find.byKey(const ValueKey('player-danmaku-enabled')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('player-danmaku-opacity')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('player-danmaku-textScale')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('player-danmaku-strokeWidth')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('player-danmaku-scrollDurationMs')),
      findsNothing,
      reason: '未选中的页签不应同时铺开，否则弹层高度不够',
    );

    await tester.tap(find.byKey(const ValueKey('player-danmaku-tab-timing')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('player-danmaku-scrollDurationMs')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('player-danmaku-fixedDurationMs')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('player-danmaku-timeOffsetMs')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('player-danmaku-tab-tracks')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('player-danmaku-areaRatio')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('player-danmaku-maxTracks')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('player-danmaku-showScroll')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('player-danmaku-showTop')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('player-danmaku-showBottom')),
      findsOneWidget,
    );

    await _showSourcesTab(tester);
    expect(find.text('本集没有弹幕地址'), findsOneWidget);
    expect(find.byKey(const ValueKey('player-danmaku-opacity')), findsNothing);
  });

  testWidgets('透明度与行数变化以新值回调，并同步弹层里的当前值', (tester) async {
    final changes = <DanmakuStyle>[];
    await _openSheet(
      tester,
      style: const DanmakuStyle(opacity: 0.5, maxTracks: 3),
      onChanged: changes.add,
    );

    tester
        .widget<Slider>(find.byKey(const ValueKey('player-danmaku-opacity')))
        .onChanged!(0.7);
    await tester.pumpAndSettle();
    expect(changes, hasLength(1));
    expect(changes.last.opacity, 0.7);
    expect(changes.last.maxTracks, 3, reason: '改一个字段不能顺手清掉别的字段');
    expect(
      tester
          .widget<Slider>(find.byKey(const ValueKey('player-danmaku-opacity')))
          .value,
      0.7,
      reason: '先 setState 再回调：滑块指的必须是刚改的新值',
    );

    await tester.tap(find.byKey(const ValueKey('player-danmaku-tab-tracks')));
    await tester.pumpAndSettle();
    tester
        .widget<PlayerGlassDropdown<int>>(
          find.byKey(const ValueKey('player-danmaku-maxTracks')),
        )
        .onChanged!(8);
    await tester.pumpAndSettle();
    expect(changes, hasLength(2));
    expect(changes.last.maxTracks, 8);
    expect(changes.last.opacity, 0.7, reason: '行数变化必须保留刚才的透明度');
  });

  testWidgets('时间偏移文案沿用整页口径：+1.5s', (tester) async {
    await _openSheet(
      tester,
      style: const DanmakuStyle(timeOffsetMs: 1500),
      onChanged: (_) {},
    );
    await tester.tap(find.byKey(const ValueKey('player-danmaku-tab-timing')));
    await tester.pumpAndSettle();
    expect(find.text('+1.5s'), findsOneWidget);
  });

  testWidgets('恢复默认回 DanmakuStyle.defaults', (tester) async {
    final changes = <DanmakuStyle>[];
    await _openSheet(
      tester,
      style: const DanmakuStyle(
        enabled: false,
        opacity: 0.4,
        textScale: 1.8,
        maxTracks: 8,
        timeOffsetMs: -2500,
      ),
      onChanged: changes.add,
    );

    await tester.tap(find.byKey(const ValueKey('player-danmaku-reset')));
    await tester.pumpAndSettle();
    expect(changes, hasLength(1));
    expect(changes.single, DanmakuStyle.defaults);
    expect(
      tester
          .widget<Slider>(find.byKey(const ValueKey('player-danmaku-opacity')))
          .value,
      DanmakuStyle.defaults.opacity,
    );
  });

  testWidgets('高度受限时内部滚动且不出现 RenderFlex overflow', (tester) async {
    await _openSheet(
      tester,
      size: const Size(560, 360),
      sourceView: _sourceView,
      onChanged: (_) {},
    );
    expect(tester.takeException(), isNull, reason: '低矮窗口下弹层不得溢出');

    await _showSourcesTab(tester);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(
      find.byKey(const ValueKey('player-danmaku-source-search')),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('player-danmaku-full-page')),
      findsOneWidget,
      reason: '底部按钮行必须仍然存在',
    );
  });

  testWidgets('完整设置页返回 openFullPage，点遮罩关闭返回 closed', (tester) async {
    await _openSheet(tester, onChanged: (_) {});
    await tester.tap(find.byKey(const ValueKey('player-danmaku-full-page')));
    await tester.pumpAndSettle();
    expect(_actions, [DanmakuSheetAction.openFullPage]);
    expect(find.byKey(const ValueKey('player-danmaku-sheet')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('open-danmaku-sheet')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(_actions, [
      DanmakuSheetAction.openFullPage,
      DanmakuSheetAction.closed,
    ]);
  });

  testWidgets('顶部摘要显示当前源与条数，点击跳到弹幕源页签', (tester) async {
    await _openSheet(tester, sourceView: _sourceView, onChanged: (_) {});
    expect(find.textContaining('当前弹幕：星河'), findsOneWidget);
    expect(find.textContaining('a.test'), findsWidgets);
    expect(find.textContaining('共 2 条地址'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('player-danmaku-summary')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('player-danmaku-tab-sources-body')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('player-danmaku-source-search')),
    );
    await tester.pumpAndSettle();
    expect(_actions, [DanmakuSheetAction.openSearch]);
  });

  testWidgets('没有当前弹幕时摘要写未加载', (tester) async {
    await _openSheet(
      tester,
      sourceView: const DanmakuSourceView(
        sources: _sources,
        libraryUrl: _libraryUrl,
      ),
      onChanged: (_) {},
    );
    expect(find.text('当前弹幕：未加载'), findsOneWidget);
  });

  testWidgets('弹幕源列表按 sources 渲染，当前项与直播标记都在', (tester) async {
    await _openSheet(tester, sourceView: _sourceView, onChanged: (_) {});
    await _showSourcesTab(tester);

    expect(
      find.byKey(const ValueKey('player-danmaku-source-$_sourceAUrl')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('player-danmaku-source-$_sourceBUrl')),
      findsOneWidget,
    );
    expect(find.text('星河'), findsOneWidget);
    expect(find.text('直播房'), findsOneWidget);
    expect(find.text('直播'), findsOneWidget);
    expect(find.text('当前在用'), findsOneWidget);
    expect(find.text('已载入 12 条'), findsOneWidget);
    expect(find.text('弹幕库：'), findsOneWidget);
    expect(find.textContaining('lib.test'), findsOneWidget);
  });

  testWidgets('点非当前项回调 onSelectSource，转圈后用 outcome 刷当前项与条数', (tester) async {
    final calls = <DanmakuSource>[];
    final pending = Completer<DanmakuSourceLoadOutcome>();
    await _openSheet(
      tester,
      sourceView: _pointSourceView,
      onChanged: (_) {},
      onSelectSource: (source) {
        calls.add(source);
        return pending.future;
      },
    );
    await _showSourcesTab(tester);

    await tester.tap(
      find.byKey(const ValueKey('player-danmaku-source-$_sourceCUrl')),
    );
    await tester.pump();
    expect(calls, [_sourceC]);
    expect(
      find.byKey(const ValueKey('player-danmaku-source-loading')),
      findsOneWidget,
    );

    pending.complete(
      const DanmakuSourceLoadOutcome(
        ok: true,
        currentUrl: _sourceCUrl,
        itemCount: 5,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('player-danmaku-source-loading')),
      findsNothing,
    );
    expect(find.text('当前在用'), findsOneWidget);
    expect(find.text('已载入 5 条'), findsOneWidget);
    expect(find.textContaining('当前弹幕：第三集'), findsOneWidget);
  });

  testWidgets('加载失败时把原因显示在被点的那一行', (tester) async {
    await _openSheet(
      tester,
      sourceView: _pointSourceView,
      onChanged: (_) {},
      onSelectSource: (_) async =>
          const DanmakuSourceLoadOutcome(ok: false, error: '网络断了'),
    );
    await _showSourcesTab(tester);

    await tester.tap(
      find.byKey(const ValueKey('player-danmaku-source-$_sourceCUrl')),
    );
    await tester.pumpAndSettle();
    expect(find.text('加载失败：网络断了'), findsOneWidget);
    expect(find.text('当前在用'), findsNothing);
  });

  testWidgets('点已经是当前项的行不发请求', (tester) async {
    final calls = <DanmakuSource>[];
    await _openSheet(
      tester,
      sourceView: _sourceView,
      onChanged: (_) {},
      onSelectSource: (source) {
        calls.add(source);
        return Future.value(
          DanmakuSourceLoadOutcome(ok: true, currentUrl: source.url),
        );
      },
    );
    await _showSourcesTab(tester);

    await tester.tap(
      find.byKey(const ValueKey('player-danmaku-source-$_sourceAUrl')),
    );
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    expect(find.byKey(const ValueKey('player-danmaku-sheet')), findsOneWidget);
  });

  testWidgets('当前地址不在 sources 里时合成「当前在用 · 弹幕库」一行', (tester) async {
    await _openSheet(
      tester,
      sourceView: const DanmakuSourceView(
        sources: _sources,
        currentUrl: _syntheticUrl,
        itemCount: 4,
        libraryUrl: _libraryUrl,
      ),
      onChanged: (_) {},
    );
    expect(find.textContaining('当前弹幕：弹幕库'), findsOneWidget);
    // 合成行不是本集地址：摘要只能数 sources，不能把 3 行都算进去。
    expect(find.textContaining('共 2 条地址'), findsOneWidget);

    await _showSourcesTab(tester);
    expect(find.text('当前在用 · 弹幕库'), findsOneWidget);
    expect(find.textContaining('library.test'), findsWidgets);
    expect(find.text('当前在用'), findsOneWidget);
    expect(find.text('已载入 4 条'), findsOneWidget);
  });

  testWidgets('两条只差 query 的源显示不同地址', (tester) async {
    const url1 = 'https://q.test/api?title=star&episode=1';
    const url2 = 'https://q.test/api?title=star&episode=2';
    await _openSheet(
      tester,
      sourceView: const DanmakuSourceView(
        sources: [
          DanmakuSource(url: url1, name: '源一'),
          DanmakuSource(url: url2, name: '源二'),
        ],
        currentUrl: url1,
        itemCount: 1,
        libraryUrl: _libraryUrl,
      ),
      onChanged: (_) {},
    );
    await _showSourcesTab(tester);
    expect(find.text(url1), findsOneWidget);
    expect(find.text(url2), findsOneWidget);
  });

  testWidgets('同 host 不同端口显示不同地址', (tester) async {
    const url1 = 'http://relay.test:9321/danmaku?title=star&episode=1';
    const url2 = 'http://relay.test:9322/danmaku?title=star&episode=1';
    await _openSheet(
      tester,
      sourceView: const DanmakuSourceView(
        sources: [
          DanmakuSource(url: url1, name: '中转 A'),
          DanmakuSource(url: url2, name: '中转 B'),
        ],
        currentUrl: url1,
        itemCount: 1,
        libraryUrl: _libraryUrl,
      ),
      onChanged: (_) {},
    );
    await _showSourcesTab(tester);
    expect(find.text(url1), findsOneWidget);
    expect(find.text(url2), findsOneWidget);
  });

  testWidgets('超长地址的列表行与摘要都带完整 URL Tooltip', (tester) async {
    const longUrl =
        'https://tooltip.test/danmaku/this/is/a/very/long/path/that/exceeds/'
        'sixty-four/characters/sample.xml';
    await _openSheet(
      tester,
      sourceView: const DanmakuSourceView(
        sources: [DanmakuSource(url: longUrl, name: '长地址')],
        currentUrl: longUrl,
        itemCount: 1,
        libraryUrl: _libraryUrl,
      ),
      onChanged: (_) {},
    );
    await _showSourcesTab(tester);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Tooltip && widget.message == longUrl,
      ),
      findsNWidgets(2),
      reason: '摘要与列表行各一份；悬停必须能读到被省略的完整地址',
    );
  });

  testWidgets('直播 outcome 带 statusText 时显示已连接', (tester) async {
    await _openSheet(
      tester,
      sourceView: _sourceView,
      onChanged: (_) {},
      onSelectSource: (_) async => const DanmakuSourceLoadOutcome(
        ok: true,
        currentUrl: _sourceBUrl,
        statusText: '已连接',
      ),
    );
    await _showSourcesTab(tester);
    final liveRow = find.byKey(
      const ValueKey('player-danmaku-source-$_sourceBUrl'),
    );
    await tester.tap(liveRow);
    await tester.pumpAndSettle();
    expect(find.text('当前在用 · 已连接'), findsOneWidget);
    expect(
      find.descendant(of: liveRow, matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
  });

  testWidgets('直播 outcome 带 error 时显示连接失败且没有对勾', (tester) async {
    await _openSheet(
      tester,
      sourceView: _sourceView,
      onChanged: (_) {},
      onSelectSource: (_) async => const DanmakuSourceLoadOutcome(
        ok: false,
        currentUrl: _sourceBUrl,
        error: '握手被拒',
        statusText: '连接失败',
      ),
    );
    await _showSourcesTab(tester);
    final liveRow = find.byKey(
      const ValueKey('player-danmaku-source-$_sourceBUrl'),
    );
    await tester.tap(liveRow);
    await tester.pumpAndSettle();
    expect(find.text('连接失败：握手被拒'), findsOneWidget);
    expect(
      find.descendant(of: liveRow, matching: find.text('当前在用')),
      findsNothing,
    );
    expect(
      find.descendant(of: liveRow, matching: find.byIcon(Icons.check)),
      findsNothing,
    );
  });

  testWidgets('成功但 0 条的源显示该源没有弹幕', (tester) async {
    await _openSheet(
      tester,
      sourceView: _sourceView,
      onChanged: (_) {},
      onSelectSource: (_) async => const DanmakuSourceLoadOutcome(ok: false),
    );
    await _showSourcesTab(tester);
    final pointRow = find.byKey(
      const ValueKey('player-danmaku-source-$_sourceBUrl'),
    );
    await tester.tap(pointRow);
    await tester.pumpAndSettle();
    expect(find.text('该源没有弹幕'), findsOneWidget);
    expect(
      find.descendant(of: pointRow, matching: find.byIcon(Icons.check)),
      findsNothing,
    );
  });

  testWidgets('弹幕库行显示共 N 条', (tester) async {
    await _openSheet(
      tester,
      sourceView: const DanmakuSourceView(
        sources: _sources,
        currentUrl: _sourceAUrl,
        itemCount: 12,
        libraryUrl: _libraryUrl,
        libraryTotal: 3,
      ),
      onChanged: (_) {},
    );
    await _showSourcesTab(tester);
    expect(find.text('（共 3 条）'), findsOneWidget);
    expect(find.textContaining('lib.test'), findsOneWidget);
  });

  testWidgets('空状态显示提示、搜索弹幕与弹幕库设置两个入口', (tester) async {
    await _openSheet(tester, onChanged: (_) {});
    await _showSourcesTab(tester);

    expect(find.text('本集没有弹幕地址'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('player-danmaku-source-search')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('player-danmaku-source-empty-full-page')),
      findsOneWidget,
    );
    expect(find.text('未配置'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('player-danmaku-source-search')),
    );
    await tester.pumpAndSettle();
    expect(_actions, [DanmakuSheetAction.openSearch]);
  });

  testWidgets('空状态的「弹幕库设置…」与只读库行都返回 openFullPage', (tester) async {
    await _openSheet(tester, onChanged: (_) {});
    await _showSourcesTab(tester);
    await tester.tap(
      find.byKey(const ValueKey('player-danmaku-source-empty-full-page')),
    );
    await tester.pumpAndSettle();
    expect(_actions, [DanmakuSheetAction.openFullPage]);

    await _openSheet(
      tester,
      sourceView: const DanmakuSourceView(libraryUrl: _libraryUrl),
      onChanged: (_) {},
    );
    await _showSourcesTab(tester);
    await tester.tap(find.byKey(const ValueKey('player-danmaku-library')));
    await tester.pumpAndSettle();
    expect(_actions, [DanmakuSheetAction.openFullPage]);
  });
}
