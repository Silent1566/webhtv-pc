import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/state/search_state.dart';
import 'package:webhtv_pc/ui/common.dart';
import 'package:webhtv_pc/ui/glass_chrome.dart';
import 'package:webhtv_pc/ui/glass_widgets.dart';
import 'package:webhtv_pc/ui/search_result_view.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/wallpaper_backdrop.dart';

import 'support/test_fonts.dart';

const _font = 'FixtureCJK';
const _prefix = 'unframed-search';
final _root = GlobalKey();

MultiSiteSearchOutcome _outcome({
  bool empty = false,
  bool loading = false,
  bool failed = false,
  bool loadingMore = false,
}) {
  final result = MultiSiteSearchOutcome(
    runId: 1,
    keyword: '繁花',
    totalSites: 2,
    results: [
      if (failed)
        SiteSearchEntry(
          siteKey: 'a',
          siteName: '甲站',
          error: AppError(AppErrorKind.siteNetwork, '连接失败'),
        )
      else if (!loading) ...[
        SiteSearchEntry(
          siteKey: 'a',
          siteName: '甲站',
          groups: const ['影视'],
          hasMore: !empty,
          loadingMore: loadingMore,
          result: SiteResult(
            list: empty
                ? const []
                : [
                    Vod(vodId: 'a1', vodName: '繁花', vodRemarks: '全30集'),
                    for (var i = 2; i <= 10; i++)
                      Vod(vodId: 'a$i', vodName: '春日故事 $i', vodRemarks: '高清'),
                  ],
          ),
        ),
        SiteSearchEntry(
          siteKey: 'b',
          siteName: '乙站',
          groups: const ['精选'],
          result: SiteResult(
            list: empty ? const [] : [Vod(vodId: 'b1', vodName: '繁花纪录片')],
          ),
        ),
      ],
    ],
  );
  result.finished = !loading;
  return result;
}

Future<void> _mount(
  WidgetTester tester, {
  MultiSiteSearchOutcome? outcome,
  Size size = const Size(1024, 640),
  Brightness brightness = Brightness.dark,
  String group = '',
  int similarity = 0,
  Widget? emptyState,
  ValueChanged<String>? onGroupChanged,
  Future<void> Function(int)? onSimilarityChanged,
  void Function(String, Vod)? onTapItem,
  Future<bool> Function(String)? onLoadMore,
  double? underlapViewportBottom,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final theme = buildAppTheme(brightness);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme.copyWith(
        platform: TargetPlatform.windows,
        textTheme: theme.textTheme.apply(fontFamily: _font),
        primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: _font),
        listTileTheme: theme.listTileTheme.copyWith(
          titleTextStyle: theme.listTileTheme.titleTextStyle?.copyWith(
            fontFamily: _font,
          ),
          subtitleTextStyle: theme.listTileTheme.subtitleTextStyle?.copyWith(
            fontFamily: _font,
          ),
        ),
      ),
      home: RepaintBoundary(
        key: _root,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const DefaultGlassBackdrop(),
            Material(
              type: MaterialType.transparency,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SearchResultView(
                  key: UniqueKey(),
                  outcome: outcome ?? _outcome(),
                  keyPrefix: _prefix,
                  itemKeyOf: (site, id) => 'result-$site-$id',
                  onTapItem: onTapItem ?? (_, _) {},
                  group: group,
                  initialSimilarity: similarity,
                  emptyState: emptyState,
                  onGroupChanged: onGroupChanged,
                  onSimilarityChanged: onSimilarityChanged,
                  onLoadMore: onLoadMore,
                  contentPadding: const EdgeInsets.all(8),
                  underlapViewportBottom: underlapViewportBottom,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

void _expectUnframed() {
  expect(
    find.descendant(
      of: find.byType(SearchResultView),
      matching: find.byType(GlassPane),
    ),
    findsNothing,
    reason: 'Search filters, site/result columns and empty bodies share the backdrop',
  );
  expect(find.byType(Material), findsWidgets);
}

Future<void> _capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['SEARCH_UNFRAMED_CAPTURE'];
  if (directory == null) return;
  expectFontsAvailableOrSkip();
  expect(firstExisting(iconFontCandidates()), isNotNull);
  final phase = Platform.environment['SEARCH_UNFRAMED_PHASE'];
  await tester.runAsync(() async {
    final boundary =
        _root.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      File('$directory/$name-$phase.png').writeAsBytesSync(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() => loadFixtureFonts(cjkFamily: _font));

  testWidgets('aggregate and site results have no page surface', (
    tester,
  ) async {
    await _mount(tester);
    expect(find.byType(PosterCard), findsNWidgets(11));
    _expectUnframed();
    await tester.tap(find.byKey(const ValueKey('$_prefix-site-b')));
    await tester.pump();
    expect(find.byType(PosterCard), findsOneWidget);
    expect(find.text('繁花纪录片'), findsOneWidget);
    _expectUnframed();
  });

  testWidgets(
    'empty, grouped-out and similarity-filtered bodies are unframed',
    (tester) async {
      await _mount(tester, outcome: _outcome(empty: true));
      expect(find.text('没有搜索结果'), findsOneWidget);
      _expectUnframed();
      await _mount(tester, group: '不存在的分组');
      expect(find.text('当前筛选下没有可见结果'), findsOneWidget);
      _expectUnframed();
      await _mount(tester, similarity: 100);
      await tester.tap(find.byKey(const ValueKey('$_prefix-site-b')));
      await tester.pump();
      expect(find.text('该站点当前筛选下没有可见结果'), findsOneWidget);
      _expectUnframed();
    },
  );

  testWidgets(
    'loading and failure preserve summary and custom recovery without a page surface',
    (tester) async {
      await _mount(tester, outcome: _outcome(loading: true));
      expect(find.textContaining('搜索中…'), findsOneWidget);
      _expectUnframed();
      await _mount(
        tester,
        outcome: _outcome(failed: true),
        emptyState: const EmptyState(
          title: '连接失败',
          message: '请检查站点后重试',
          action: TextButton(onPressed: null, child: Text('重试')),
        ),
      );
      expect(find.textContaining('失败 1'), findsOneWidget);
      expect(find.text('请检查站点后重试'), findsOneWidget);
      _expectUnframed();
    },
  );

  testWidgets('filter chips retain selection, mouse and keyboard callbacks', (
    tester,
  ) async {
    String? group;
    int? similarity;
    await _mount(
      tester,
      onGroupChanged: (value) => group = value,
      onSimilarityChanged: (value) async => similarity = value,
    );
    await tester.tap(find.byKey(const ValueKey('$_prefix-group-精选')));
    await tester.pump();
    expect(group, '精选');
    await tester.tap(find.byKey(const ValueKey('$_prefix-similarity-100')));
    await tester.pump();
    expect(similarity, 100);
    expect(
      tester
          .widget<TagChip>(
            find.byKey(const ValueKey('$_prefix-similarity-100')),
          )
          .selected,
      isTrue,
    );
    final target = find.descendant(
      of: find.byKey(const ValueKey('$_prefix-similarity-0')),
      matching: find.byType(InkWell),
    );
    final focusContext = tester.element(
      find.descendant(of: target, matching: find.byType(MouseRegion)).first,
    );
    Focus.of(focusContext).requestFocus();
    await tester.pump();
    expect(Focus.of(focusContext).hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(similarity, 0);
  });

  testWidgets('site selection, item opening and paging retain actions', (
    tester,
  ) async {
    String? opened;
    String? loaded;
    await _mount(
      tester,
      onTapItem: (site, vod) => opened = '$site/${vod.vodId}',
      onLoadMore: (site) async {
        loaded = site;
        return false;
      },
    );
    await tester.tap(find.byKey(const ValueKey('$_prefix-site-b')));
    await tester.pump();
    expect(
      tester
          .widget<ListTile>(find.byKey(const ValueKey('$_prefix-site-b')))
          .selected,
      isTrue,
    );
    await tester.tap(find.byKey(const ValueKey('result-b-b1')));
    expect(opened, 'b/b1');
    await tester.tap(find.byKey(const ValueKey('$_prefix-site-a')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('$_prefix-load-more')));
    await tester.pump();
    expect(loaded, 'a');
    await tester.tap(find.byKey(const ValueKey('$_prefix-site-all')));
    await tester.pump();
    expect(find.byType(PosterCard), findsNWidgets(11));
  });

  testWidgets('scrolling and shell underlap survive without viewport panels', (
    tester,
  ) async {
    await _mount(tester, underlapViewportBottom: 608);
    expect(find.byType(ShellScrollUnderlap), findsNWidgets(2));
    final list = find.byKey(const ValueKey('$_prefix-result-list'));
    final scrollable = find.descendant(
      of: list,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.pixels, 0);
    await tester.drag(list, const Offset(0, -280));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
    await tester.tap(find.byKey(const ValueKey('$_prefix-site-b')));
    await tester.pump();
    expect(position.pixels, 0);
    _expectUnframed();
  });

  testWidgets('loading-more footer stays visible and unframed', (tester) async {
    await _mount(
      tester,
      outcome: _outcome(loadingMore: true),
      onLoadMore: (_) async => false,
    );
    await tester.tap(find.byKey(const ValueKey('$_prefix-site-a')));
    await tester.pump();
    expect(find.text('正在加载第 2 页…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    _expectUnframed();
  });

  for (final brightness in Brightness.values) {
    for (final size in [const Size(1024, 640), const Size(720, 600)]) {
      final name =
          '${brightness.name}-${size.width.toInt()}x${size.height.toInt()}';
      testWidgets('capture populated and empty $name', (tester) async {
        await _mount(tester, brightness: brightness, size: size);
        expect(find.byType(PosterCard), findsNWidgets(11));
        expect(tester.takeException(), isNull);
        await _capture(tester, 'populated-$name');
        await _mount(
          tester,
          outcome: _outcome(empty: true),
          brightness: brightness,
          size: size,
        );
        expect(find.text('没有搜索结果'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _capture(tester, 'empty-$name');
      });
    }
  }
}
