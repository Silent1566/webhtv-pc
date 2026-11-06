/// 配置管理页的切换交互（用户反馈 2026-11-05）。
///
/// ## 为什么单开一个文件
///
/// 这批断言全部是**交互契约**：整行点击即切换、当前项不可再点、删除要二次
/// 确认、编辑弹窗的地址字段在桥接源上只读。它们落不到状态层（状态层管不到
/// 「用户点了哪一行」），混进 `config_record_edit_refresh_test.dart` 会让那个
/// 文件从「编辑与刷新语义」跑偏。
///
/// 站点 api 指向本机不存在的地址是**故意的**：这些用例只关心点击与弹窗，
/// 不希望 `loadHome` 真的打到网上去。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/config_pages.dart';
import 'package:webhtv_pc/ui/theme.dart';

void main() {
  late Directory tempDir;
  late AppState state;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-config-ui');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {'roaming': tempDir.path, 'local': tempDir.path},
      ),
      log: LogService(),
    );
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  /// 落一条本地配置记录（不走网络）。
  int seed(String name) => state.database!.saveConfig(
    name: name,
    origin: 'https://example.test/$name.json',
    json: {
      'sites': [
        {
          'key': 'k-$name',
          'name': '站点',
          'type': 0,
          'api': 'https://example.test/$name/',
        },
      ],
    },
    siteCount: 1,
  );

  int seedBridge(String name) => state.database!.saveConfig(
    name: name,
    origin: 'http://192.168.50.50:4567/sub/2024/0',
    json: const {'sites': <Object?>[]},
    sourceKey: 'bridge|dev-uuid|iface-$name',
    bridgeDevice: 'dev-uuid',
    bridgeInterfaceKey: 'iface-$name',
  );

  Future<void> openPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: ConfigPage(state: state),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('列表项不再有装饰性单选图标', (tester) async {
    seed('甲');
    seed('乙');
    await openPage(tester);

    expect(
      find.byIcon(Icons.radio_button_checked),
      findsNothing,
      reason: '只有「启用」按钮生效时，单选图标是纯装饰，容易误点',
    );
    expect(find.byIcon(Icons.circle_outlined), findsNothing);
  });

  testWidgets('点击非当前行即切换，当前行显示「使用中」', (tester) async {
    final first = seed('甲');
    final second = seed('乙');
    await openPage(tester);

    expect(find.byKey(ValueKey('config-active-badge-$first')), findsNothing);

    await tester.tap(find.byKey(ValueKey('config-row-$first')));
    await tester.pumpAndSettle();

    expect(state.activeRecord?.id, first, reason: '整行点击就该切换');
    expect(
      find.byKey(ValueKey('config-active-badge-$first')),
      findsOneWidget,
      reason: '当前生效项要有明确标识',
    );

    await tester.tap(find.byKey(ValueKey('config-row-$second')));
    await tester.pumpAndSettle();

    expect(state.activeRecord?.id, second);
    expect(find.byKey(ValueKey('config-active-badge-$second')), findsOneWidget);
    expect(find.byKey(ValueKey('config-active-badge-$first')), findsNothing);
  });

  testWidgets('删除必须二次确认，取消则不删', (tester) async {
    final id = seed('留下我');
    await openPage(tester);

    await tester.tap(find.byKey(ValueKey('config-menu-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('config-delete-confirm')),
      findsOneWidget,
      reason: '删除是破坏性操作，必须先确认',
    );
    await tester.tap(find.byKey(const ValueKey('config-delete-cancel')));
    await tester.pumpAndSettle();
    expect(state.database!.listConfigs(), hasLength(1), reason: '取消不得删除');

    await tester.tap(find.byKey(ValueKey('config-menu-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('config-delete-ok')));
    await tester.pumpAndSettle();
    expect(state.database!.listConfigs(), isEmpty, reason: '确认后才删');
  });

  testWidgets('编辑弹窗：本地源地址可改', (tester) async {
    final local = seed('本地源');
    await openPage(tester);

    await tester.tap(find.byKey(ValueKey('config-edit-$local')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('config-edit-dialog')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('config-edit-origin')))
          .enabled,
      isTrue,
      reason: '本地源的地址是用户的，必须能改',
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('config-edit-dialog')), findsNothing);
  });

  testWidgets('编辑弹窗：桥接源地址只读', (tester) async {
    final bridge = seedBridge('桥接源');
    await openPage(tester);

    await tester.tap(find.byKey(ValueKey('config-edit-$bridge')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('config-edit-origin')))
          .enabled,
      isFalse,
      reason: '桥接源地址由安卓设备决定，PC 不应允许改写',
    );
    expect(find.textContaining('由安卓设备决定'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets('刷新入口：顶部「全部刷新」与每行单条刷新都在', (tester) async {
    final id = seed('甲');
    await openPage(tester);

    expect(find.byKey(const ValueKey('config-refresh-all')), findsOneWidget);
    expect(find.byKey(ValueKey('config-refresh-$id')), findsOneWidget);
    expect(find.text('全部刷新'), findsOneWidget);
  });

  testWidgets('已有配置时导入区默认收起，且不占用首屏', (tester) async {
    seed('甲');
    await openPage(tester);

    expect(
      find.byKey(const ValueKey('config-import-toggle')),
      findsOneWidget,
      reason: '收起的入口必须还在，否则用户找不到怎么导入',
    );
    expect(
      find.text('选择本地文件'),
      findsNothing,
      reason: '导入区收起后三个导入按钮都不该上屏',
    );
    expect(find.text('使用仓库 fixture'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('config-import-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('选择本地文件'), findsOneWidget);
    expect(find.text('使用仓库 fixture'), findsOneWidget);
  });

  testWidgets('点标题文字本身也能折叠展开（整行即开关）', (tester) async {
    seed('甲');
    await openPage(tester);

    // 点的是**文字**，不是右侧那个展开按钮：整行可点才是用户要的形态。
    await tester.tap(find.text('导入新配置'));
    await tester.pumpAndSettle();
    expect(
      find.text('选择本地文件'),
      findsOneWidget,
      reason: '点标题行任意位置都应展开导入区',
    );

    await tester.tap(find.text('导入新配置'));
    await tester.pumpAndSettle();
    expect(find.text('选择本地文件'), findsNothing, reason: '再点一次应收起');
  });

  testWidgets('两个区块标题左边缘对齐，导入区不是缩进的子菜单', (tester) async {
    seed('甲');
    await openPage(tester);

    final importTitle = tester.getRect(find.text('导入新配置'));
    final savedTitle = tester.getRect(find.text('已保存的配置'));
    expect(
      importTitle.left,
      moreOrLessEquals(savedTitle.left, epsilon: 0.5),
      reason: '「导入新配置」与「已保存的配置」是平级区块，左边缘必须同一条竖线',
    );
  });

  testWidgets('一条配置都没有时导入区默认展开', (tester) async {
    await openPage(tester);

    expect(
      find.text('选择本地文件'),
      findsOneWidget,
      reason: '没有配置时导入是唯一有意义的事，不能藏起来',
    );
    expect(find.text('还没有保存的配置。'), findsOneWidget);
  });

  group('换配置选择器（顶栏「配置：xxx」点开的那个）', () {
    /// 直接挂对话框：这个控件的契约就是「点一行返回它的 id」，
    /// 不需要真的走 AppShell（那还要处理首启公告，与本契约无关）。
    ///
    /// 数据取自数据库的**同步**接口，不重新 `bootstrap()`：那个调用有真实
    /// 文件 I/O，在 widget 测试的 fake-async 区里永远等不到完成。
    Future<void> openSwitcher(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showDialog<int>(
                context: context,
                builder: (_) => ConfigSwitcherDialog(
                  records: state.database!.listConfigs(),
                  activeId: state.database!.activeConfig()?.id,
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
    }

    testWidgets('列出全部配置并标出当前项，点非当前项才返回 id', (tester) async {
      final first = seed('甲');
      final second = seed('乙');
      state.database!.activateConfig(first);

      await openSwitcher(tester);
      expect(find.byKey(const ValueKey('config-switcher')), findsOneWidget);
      expect(
        find.byKey(ValueKey('config-switch-option-$first')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('config-switch-option-$second')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('config-switch-current-$first')),
        findsOneWidget,
        reason: '换配置时必须标出现在用的是哪个',
      );
      expect(
        find.byKey(ValueKey('config-switch-current-$second')),
        findsNothing,
      );

      await tester.tap(find.byKey(ValueKey('config-switch-option-$second')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('config-switcher')),
        findsNothing,
        reason: '选中非当前项后对话框应关闭并把 id 交给调用方',
      );
    });

    testWidgets('当前项不可点：点它不会关闭对话框', (tester) async {
      final only = seed('唯一');
      state.database!.activateConfig(only);

      await openSwitcher(tester);
      await tester.tap(find.byKey(ValueKey('config-switch-option-$only')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('config-switcher')),
        findsOneWidget,
        reason: '点当前项应当无反应，而不是把对话框关掉',
      );
    });
  });
}
