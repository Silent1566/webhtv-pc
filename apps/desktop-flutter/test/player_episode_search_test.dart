import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/playback_queue.dart';
import 'package:webhtv_pc/core/playback_request.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_detail_model.dart';
import 'package:webhtv_pc/ui/player_episode_panel.dart';
import 'package:webhtv_pc/ui/player_queue_panel.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/test_fonts.dart';

const _episodeSearch = ValueKey('player-episode-search');
const _queueSearch = ValueKey('player-queue-search');

List<VodEpisode> _episodes(int count) => [
  for (var i = 1; i <= count; i++)
    VodEpisode(name: '第${i.toString().padLeft(2, '0')}集', url: 'episode-$i'),
];

PlayerEpisodePanel _episodesPanel({
  List<VodPlayLine>? lines,
  Map<String, List<TmdbEpisodeCard>> cards = const {},
  bool reversed = false,
  PlayerEpisodeTap? onSelect,
}) => PlayerEpisodePanel(
  title: '星空旅程',
  playLines: lines ?? [VodPlayLine(flag: '线路1', episodes: _episodes(45))],
  lineFlag: '线路1',
  episodeIndex: 0,
  episodeCardsByFlag: cards,
  reversed: reversed,
  onSelectEpisode: onSelect ?? (_, _) {},
);

class _Queue extends ChangeNotifier implements PlaybackQueue {
  _Queue({this.hasMore = true});

  final items = <PlaybackQueueItem>[
    const PlaybackQueueItem(key: 'opaque-a', title: '第01集 星空初遇.mkv'),
    const PlaybackQueueItem(key: 'opaque-b', title: '第02集 Moonlight.mkv'),
    const PlaybackQueueItem(key: 'opaque-c', title: '第03集 远方来信.mp4'),
  ];
  bool hasMore;
  bool failLoad = false;
  int loadCalls = 0;
  int resolveCalls = 0;

  @override
  PlaybackQueueSnapshot get snapshot =>
      PlaybackQueueSnapshot(items: items, hasMore: hasMore);

  @override
  Future<void> loadMore() async {
    loadCalls++;
    if (failLoad) throw StateError('目录读取失败');
    items.add(
      const PlaybackQueueItem(key: 'opaque-d', title: '第04集 Moonrise.mp4'),
    );
    hasMore = false;
    notifyListeners();
  }

  @override
  Future<PlaybackRequest> resolve(
    String itemKey, {
    bool Function()? isCurrent,
  }) {
    resolveCalls++;
    throw StateError('过滤不应解析播放地址');
  }
}

PlayerQueuePanel _queuePanel(_Queue queue, {ValueChanged<String>? onSelect}) =>
    PlayerQueuePanel(
      title: '星空旅程目录',
      queue: queue,
      currentKey: 'opaque-b',
      onSelect: onSelect ?? (_) {},
      playLines: const [],
      lineFlag: '',
      onSelectLine: (_) {},
    );

Future<void> _open(
  WidgetTester tester,
  Widget panel, {
  GlobalKey? capture,
  Brightness brightness = Brightness.dark,
}) async {
  await tester.pumpWidget(
    RepaintBoundary(
      key: capture,
      child: MaterialApp(
        theme: buildAppTheme(brightness),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () =>
                    showDialog<void>(context: context, builder: (_) => panel),
                child: const Text('打开选集'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开选集'));
  await tester.pumpAndSettle();
}

Future<void> _search(WidgetTester tester, Key key, String query) async {
  expect(find.byKey(key), findsOneWidget, reason: '选集面板需要可输入的搜索框');
  await tester.enterText(find.byKey(key), query);
  await tester.pumpAndSettle();
}

int _gridCount(WidgetTester tester) => tester
    .widget<GridView>(find.byKey(const ValueKey('player-episode-grid')))
    .childrenDelegate
    .estimatedChildCount!;

void main() {
  testWidgets('搜索跨全部区间过滤，清空后恢复原区间且不改变剧集顺序', (tester) async {
    final episodes = _episodes(45);
    await _open(
      tester,
      _episodesPanel(
        lines: [VodPlayLine(flag: '线路1', episodes: episodes)],
      ),
    );
    await tester.tap(find.byKey(const ValueKey('player-episode-range-1')));
    await tester.pumpAndSettle();
    await _search(tester, _episodeSearch, ' 43 ');
    expect(_gridCount(tester), 1);
    expect(
      find.byKey(const ValueKey('player-episode-card-42')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('player-episode-range-strip')),
      findsNothing,
    );
    await tester.tap(find.byTooltip('清空搜索'));
    await tester.pumpAndSettle();
    expect(_gridCount(tester), 20);
    expect(
      find.byKey(const ValueKey('player-episode-card-20')),
      findsOneWidget,
    );
    expect(episodes[42].name, '第43集');
  });

  testWidgets('倒序搜索匹配卡片标题并保持原始集号和线路回调', (tester) async {
    final selected = <(String, int)>[];
    await _open(
      tester,
      _episodesPanel(
        lines: [VodPlayLine(flag: '线路1', episodes: _episodes(3))],
        reversed: true,
        cards: {
          '线路1': const [
            TmdbEpisodeCard(number: 3, title: 'Moon 最终话'),
            TmdbEpisodeCard(number: 2, title: '中篇'),
            TmdbEpisodeCard(number: 1, title: 'Moon 首播集'),
          ],
        },
        onSelect: (flag, index) => selected.add((flag, index)),
      ),
    );
    await _search(tester, _episodeSearch, 'mOoN');
    expect(_gridCount(tester), 2);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('player-episode-card-2'))).dx,
      lessThan(
        tester
            .getTopLeft(find.byKey(const ValueKey('player-episode-card-0')))
            .dx,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('player-episode-card-2')));
    await tester.pumpAndSettle();
    expect(selected, [('线路1', 2)]);
    expect(find.byKey(const ValueKey('player-episode-panel')), findsNothing);
  });

  testWidgets('搜索匹配展示卡片的集数，卡片数量不符时不借用错误元数据', (tester) async {
    final lines = [
      VodPlayLine(
        flag: '线路1',
        episodes: [
          VodEpisode(name: '序章', url: 'intro'),
          VodEpisode(name: '终章', url: 'ending'),
        ],
      ),
    ];
    await _open(
      tester,
      _episodesPanel(
        lines: lines,
        cards: {
          '线路1': const [
            TmdbEpisodeCard(number: 5, title: '黎明'),
            TmdbEpisodeCard(number: 6, title: '夜色'),
          ],
        },
      ),
    );
    await _search(tester, _episodeSearch, '6');
    expect(_gridCount(tester), 1);
    expect(find.byKey(const ValueKey('player-episode-card-1')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await _open(
      tester,
      _episodesPanel(
        lines: lines,
        cards: {
          '线路1': const [TmdbEpisodeCard(number: 6, title: '错误标题')],
        },
      ),
    );
    await _search(tester, _episodeSearch, '错误标题');
    expect(find.text('没有匹配的选集'), findsOneWidget);
    await _search(tester, _episodeSearch, '终章');
    expect(_gridCount(tester), 1);
    expect(find.byKey(const ValueKey('player-episode-card-1')), findsOneWidget);
  });

  testWidgets('搜索词在预览线路间保留，预览不播放且点卡片使用新线路绝对下标', (tester) async {
    final selected = <(String, int)>[];
    await _open(
      tester,
      _episodesPanel(
        lines: [
          VodPlayLine(flag: '线路1', episodes: _episodes(45)),
          VodPlayLine(flag: '线路2', episodes: _episodes(5)),
        ],
        onSelect: (flag, index) => selected.add((flag, index)),
      ),
    );
    await _search(tester, _episodeSearch, '05');
    await tester.tap(find.byKey(const ValueKey('player-episode-line-1')));
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
    expect(
      tester.widget<TextField>(find.byKey(_episodeSearch)).controller!.text,
      '05',
    );
    expect(_gridCount(tester), 1);
    expect(find.byKey(const ValueKey('player-episode-card-4')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('player-episode-card-4')));
    await tester.pumpAndSettle();
    expect(selected, [('线路2', 4)]);
  });

  testWidgets('无匹配有空态，空白查询恢复全部且关闭不触发播放', (tester) async {
    final selected = <(String, int)>[];
    await _open(
      tester,
      _episodesPanel(
        lines: [VodPlayLine(flag: '线路1', episodes: _episodes(3))],
        onSelect: (flag, index) => selected.add((flag, index)),
      ),
    );
    await _search(tester, _episodeSearch, '不存在');
    expect(find.text('没有匹配的选集'), findsOneWidget);
    expect(find.byKey(const ValueKey('player-episode-card-0')), findsNothing);
    await _search(tester, _episodeSearch, '   ');
    expect(_gridCount(tester), 3);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
  });

  testWidgets('目录搜索不区分大小写，点击匹配项保留不透明文件key', (tester) async {
    final queue = _Queue(hasMore: false);
    addTearDown(queue.dispose);
    final selected = <String>[];
    await _open(tester, _queuePanel(queue, onSelect: selected.add));
    await _search(tester, _queueSearch, ' mOoN ');
    expect(
      find.byKey(const ValueKey('player-queue-item-opaque-a')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('player-queue-item-opaque-b')),
      findsOneWidget,
    );
    expect(queue.loadCalls, 0);
    expect(queue.resolveCalls, 0);
    await tester.tap(find.byKey(const ValueKey('player-queue-item-opaque-b')));
    await tester.pumpAndSettle();
    expect(selected, ['opaque-b']);
    expect(find.byKey(const ValueKey('player-queue-panel')), findsNothing);
  });

  testWidgets('目录仅过滤已加载项，手动加载后保持查询并纳入新增匹配', (tester) async {
    final queue = _Queue();
    addTearDown(queue.dispose);
    await _open(tester, _queuePanel(queue));
    await _search(tester, _queueSearch, 'Moon');
    expect(find.textContaining('仅搜索已加载'), findsOneWidget);
    expect(queue.loadCalls, 0);
    await tester.tap(find.byKey(const ValueKey('player-queue-load-more')));
    await tester.pumpAndSettle();
    expect(queue.loadCalls, 1);
    expect(
      find.byKey(const ValueKey('player-queue-item-opaque-b')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('player-queue-item-opaque-d')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('player-queue-item-opaque-a')),
      findsNothing,
    );
    expect(queue.resolveCalls, 0);
    await tester.tap(find.byTooltip('清空搜索'));
    await tester.pumpAndSettle();
    final grid = tester.widget<GridView>(find.byType(GridView));
    expect(grid.childrenDelegate.estimatedChildCount, 4);
    expect(queue.items.map((item) => item.key), [
      'opaque-a',
      'opaque-b',
      'opaque-c',
      'opaque-d',
    ]);
  });

  testWidgets('目录无匹配仍可加载，失败保留错误和重试出口', (tester) async {
    final queue = _Queue()..failLoad = true;
    addTearDown(queue.dispose);
    await _open(tester, _queuePanel(queue));
    await _search(tester, _queueSearch, '不存在');
    expect(find.text('没有匹配的选集'), findsOneWidget);
    expect(find.textContaining('仅搜索已加载'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('player-queue-load-more')));
    await tester.pumpAndSettle();
    expect(find.textContaining('目录读取失败'), findsOneWidget);
    expect(find.text('重试加载'), findsOneWidget);
    queue.failLoad = false;
    await tester.tap(find.byKey(const ValueKey('player-queue-load-more')));
    await tester.pumpAndSettle();
    expect(queue.loadCalls, 2);
    expect(find.textContaining('目录读取失败'), findsNothing);
    expect(find.text('没有匹配的选集'), findsOneWidget);
  });

  const capturePhase = String.fromEnvironment('EPISODE_SEARCH_CAPTURE');
  testWidgets('选集搜索视觉证据', (tester) async {
    await tester.runAsync(() async {
      await loadFixtureFonts();
      await loadFixtureFonts(cjkFamily: 'Roboto');
      await loadFixtureFonts(cjkFamily: 'Microsoft YaHei UI');
    });
    expectFontsAvailableOrSkip();
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final dir = Directory('../../.local/episode-search');
    await tester.runAsync(() => dir.create(recursive: true));
    for (final size in [const Size(1280, 800), const Size(640, 480)]) {
      tester.view.physicalSize = size;
      for (final queueMode in [false, true]) {
        final capture = GlobalKey();
        final queue = _Queue();
        final panel = queueMode ? _queuePanel(queue) : _episodesPanel();
        await _open(tester, panel, capture: capture);
        final label =
            '${queueMode ? 'queue' : 'episodes'}-${size.width.toInt()}x${size.height.toInt()}';
        Future<void> save(String suffix) async {
          final boundary =
              capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File('${dir.path}/$capturePhase-$label$suffix.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        await save('');
        if (capturePhase == 'after') {
          await _search(
            tester,
            queueMode ? _queueSearch : _episodeSearch,
            queueMode ? 'Moon' : '43',
          );
          await save('-filtered');
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        queue.dispose();
      }
    }
  }, skip: capturePhase.isEmpty);
}
