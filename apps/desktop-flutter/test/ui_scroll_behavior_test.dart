/// 桌面端「鼠标左右拖横向条」回归锁（`docs/webhtv-pc-design.md` §17.4）。
///
/// 背景（用户反馈 2026-10-20）：「列表模式的集数卡片，剧照，包含等卡片都
/// 没办法左右拖拽显示更多内容」。
///
/// 根因：Flutter 的 `ScrollBehavior.dragDevices` 默认**不含**
/// `PointerDeviceKind.mouse`（`scroll_configuration.dart` 的
/// `_kTouchLikeDeviceTypes` 只有 touch / stylus / invertedStylus / trackpad /
/// unknown），桌面端横向条因此收不到鼠标拖拽。
///
/// 修复：`HorizontalMouseDrag` 只给横向容器套 `AppScrollBehavior`
/// （`lib/ui/scroll_behavior.dart`）。这里锁三件事：
/// 1. 行为集合确实含鼠标（否则后面全是空转）；
/// 2. 用户真实看到的横向条（集数卡片条 / 剧照墙）真的能被鼠标拖出滚动；
/// 3. **作用域不外泄**：外层竖直列表与 `SelectableText` 的鼠标手势保持
///    框架默认——这是「为什么不用全局 `MaterialApp.scrollBehavior`」的锁。
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/tmdb_detail_model.dart';
import 'package:webhtv_pc/ui/scroll_behavior.dart';
import 'package:webhtv_pc/ui/tmdb_detail_view.dart';

const String _imageBase = 'https://images.tmdb.org/t/p/w342';
const String _backdropBase = 'https://images.tmdb.org/t/p/w780';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

/// 读某个滚动容器的偏移。
///
/// 用 widget 的 key 定位（`ListView` 的 key 落在 `BoxScrollView` 上，
/// `Scrollable` 是它的后代），避免 `find.byType(Scrollable)` 在嵌套滚动里
/// 命中错的那一个。
double _offsetOf(WidgetTester tester, Key key) {
  final scrollable = find
      .descendant(of: find.byKey(key), matching: find.byType(Scrollable))
      .first;
  return tester.state<ScrollableState>(scrollable).position.pixels;
}

/// 鼠标按住 [key] 往左拖 [dx]（不经过触摸路径）。
Future<void> _mouseDragLeft(
  WidgetTester tester,
  Key key, {
  double dx = 240,
}) async {
  await tester.drag(
    find.byKey(key),
    Offset(-dx, 0),
    kind: PointerDeviceKind.mouse,
  );
  await tester.pumpAndSettle();
}

/// 带 8 张剧照的详情数据（用于剧照墙溢出）。
TmdbDetailData _photoData() => TmdbDetailData.fromDetail(
  {
    'id': 1399,
    'name': '示例剧集',
    'images': {
      'stills': [
        for (var i = 0; i < 8; i++)
          {'file_path': '/still$i.jpg', 'width': 1920, 'height': 1080},
      ],
    },
  },
  imageBase: _imageBase,
  backdropBase: _backdropBase,
);

void main() {
  group('滚动行为集合', () {
    test('把鼠标补进可拖拽设备，其余沿用框架默认', () {
      const behavior = AppScrollBehavior();
      for (final kind in <PointerDeviceKind>[
        PointerDeviceKind.touch,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.mouse,
        PointerDeviceKind.unknown,
      ]) {
        expect(
          behavior.dragDevices,
          contains(kind),
          reason: '缺 $kind 会让对应的指针拖不动滚动容器',
        );
      }
    });
  });

  group('横向条能被鼠标拖出滚动', () {
    testWidgets('HorizontalMouseDrag：鼠标按住横向列表往左拖，内容真的滚动', (
      tester,
    ) async {
      const key = ValueKey('probe-strip');
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 420,
            height: 100,
            child: HorizontalMouseDrag(
              child: ListView.builder(
                key: key,
                scrollDirection: Axis.horizontal,
                itemCount: 20,
                itemBuilder: (context, index) =>
                    SizedBox(width: 100, child: Text('第$index项')),
              ),
            ),
          ),
        ),
      );

      expect(_offsetOf(tester, key), 0, reason: '初始应在最左端');
      await _mouseDragLeft(tester, key);
      expect(
        _offsetOf(tester, key),
        greaterThan(200),
        reason: '鼠标拖拽必须真的滚到右侧内容，而不是让页面滚',
      );
    });

    testWidgets('列表模式的集数卡片条：鼠标拖拽能看到右侧更多集', (tester) async {
      const key = ValueKey('tmdb-episode-card-strip');
      final cards = [
        for (var i = 1; i <= 12; i++)
          TmdbEpisodeCard(number: i, title: '第$i集'),
      ];
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 700,
            child: TmdbEpisodeStrip(cards: cards),
          ),
        ),
      );

      expect(_offsetOf(tester, key), 0);
      await _mouseDragLeft(tester, key, dx: 400);
      expect(
        _offsetOf(tester, key),
        greaterThan(300),
        reason: '用户反馈的正是这一条：集数卡片拖不动',
      );
    });

    testWidgets('剧照墙：鼠标拖拽能看到后面的剧照', (tester) async {
      const key = ValueKey('tmdb-photo-wall');
      final data = _photoData();
      expect(data.photoUrls.length, greaterThan(4), reason: '夹具必须真的溢出');
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 520,
            child: SizedBox(
              height: 400,
              child: SingleChildScrollView(
                child: TmdbDetailSections(data: data),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(_offsetOf(tester, key), 0);
      await _mouseDragLeft(tester, key, dx: 300);
      expect(
        _offsetOf(tester, key),
        greaterThan(200),
        reason: '用户反馈的「剧照也拖不动」',
      );
    });
  });

  group('作用域：只给横向条，不污染竖直滚动与文字选中', () {
    testWidgets('横向条拖拽不会带动外层竖直列表；SelectableText 上的鼠标拖拽不滚页', (
      tester,
    ) async {
      const outerKey = ValueKey('outer-list');
      const innerKey = ValueKey('inner-strip');
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 500,
            height: 300,
            child: ListView(
              key: outerKey,
              children: [
                SizedBox(
                  height: 60,
                  child: SelectableText('可选中文字 ' * 40),
                ),
                SizedBox(
                  height: 100,
                  child: HorizontalMouseDrag(
                    child: ListView.builder(
                      key: innerKey,
                      scrollDirection: Axis.horizontal,
                      itemCount: 20,
                      itemBuilder: (context, index) =>
                          SizedBox(width: 100, child: Text('$index')),
                    ),
                  ),
                ),
                for (var i = 0; i < 30; i++)
                  SizedBox(height: 40, child: Text('更多内容 $i')),
              ],
            ),
          ),
        ),
      );

      // ① 横向拖：内层滚，外层不滚。
      await _mouseDragLeft(tester, innerKey);
      expect(_offsetOf(tester, innerKey), greaterThan(150));
      expect(_offsetOf(tester, outerKey), 0, reason: '横向拖拽不应泄漏给外层竖列表');

      // ② 在可选文字上竖拖：文字选中吃掉手势，页面不滚。
      //    如果哪天把 `AppScrollBehavior` 挂到 `MaterialApp.scrollBehavior`，
      //    这里会变成 >0 —— 配置页/日志页的文字选中就没了。
      await tester.drag(
        find.byType(SelectableText),
        const Offset(0, -120),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(
        _offsetOf(tester, outerKey),
        0,
        reason: '鼠标拖拽必须是局部启用：竖直滚动仍归框架默认（否则抢走文字选中）',
      );
    });
  });
}
