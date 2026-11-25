/// 顶栏 / 推送对话框的视觉证据采集（Before/After 同一视口、同一主题）。
///
/// 只在设置了 PUSH_CAPTURE_PHASE 时写文件（默认不产出图片），输出到
/// docs/phase9/evidence/screenshots/push-receive/`phase-scenario`.png。
///
/// 为什么单独成文件：验收要求"顶栏换入口"的前后对比，而 Before 必须来自
/// 改动前的提交——用同一个采集脚本在两个工作树上跑，视口与主题才可比。
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

import 'local_source_sites_test.dart' show deleteTempWhenReleased;

import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/startup_arguments.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/detail_test_seams.dart';
import 'support/test_fonts.dart';
import 'support/widget_settle.dart';

/// 采集用状态：给一份空配置，让推送走"合成推送站点详情"（普通详情页）。
class _CapturePushState extends AppState with ExternalMetaOff {
  _CapturePushState({super.paths, super.log});

  static final AppConfig fixtureConfig = AppConfig(name: '采集配置');
  static final ConfigRecord fixtureRecord = ConfigRecord(
    id: 1,
    name: '采集配置',
    origin: 'local:capture',
    updatedAt: DateTime(2026, 11, 21),
    siteCount: 0,
    liveCount: 0,
    isActive: true,
    sourceKey: 'local|capture',
  );

  @override
  AppConfig? get effectiveConfig => fixtureConfig;

  @override
  ConfigRecord? get activeRecord => fixtureRecord;

  @override
  Site? siteInActiveSource(String siteKey) => null;
}

void main() {
  final phase = Platform.environment['PUSH_CAPTURE_PHASE'];
  final evidenceRoot =
      Platform.environment['PUSH_CAPTURE_ROOT'] ??
      '../../docs/phase9/evidence/screenshots/push-receive';

  setUpAll(() async {
    final cjk = firstExisting(cjkFontCandidates());
    if (cjk != null) {
      // 'Roboto' 也要挂：按钮/输入框这类组件主题里写死的字体不会跟 textTheme
      // 的 fontFamily 走，测试环境没有系统字体，不挂就会渲成豆腐块（真实桌面
      // 走系统字体回落，不存在这个问题）。
      for (final family in [
        'FixtureCJK',
        'Roboto',
        // 地址行用 monospace：测试环境没有系统等宽字体，不挂就会渲成豆腐块。
        'monospace',
        'Microsoft YaHei UI',
        'Noto Sans CJK SC',
      ]) {
        await (FontLoader(
          family,
        )..addFont(cjk.readAsBytes().then(ByteData.sublistView))).load();
      }
    }
    final icons = firstExisting(iconFontCandidates());
    if (icons != null) {
      await (FontLoader(
        'MaterialIcons',
      )..addFont(icons.readAsBytes().then(ByteData.sublistView))).load();
    }
  });

  late Directory tempDir;
  late AppState state;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-push-capture');
    state = _CapturePushState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${tempDir.path}/webhtv-pc',
          'data': '${tempDir.path}/webhtv-pc',
          'cache': '${tempDir.path}/webhtv-pc/cache',
          'state': '${tempDir.path}/webhtv-pc/logs',
        },
      ),
      // 内存日志 + 关掉外部元数据补全：详情页不再留下 flush/排队定时器。
      log: MemoryOnlyLogService(),
    );
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    try {
      await deleteTempWhenReleased(tempDir);
    } catch (_) {}
  });

  testWidgets('顶栏与推送对话框截图', (tester) async {
    final boundary = GlobalKey();
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final theme = buildAppTheme(Brightness.dark);
    await tester.pumpWidget(
      // 边界必须包住整个 MaterialApp：对话框挂在 app 的 overlay 上，只包 home
      // 的话拍到的永远是没有对话框的壳层（两次截图字节数一样就是这个问题）。
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          theme: theme.copyWith(
            textTheme: theme.textTheme.apply(fontFamily: 'FixtureCJK'),
            primaryTextTheme: theme.primaryTextTheme.apply(
              fontFamily: 'FixtureCJK',
            ),
            listTileTheme: theme.listTileTheme.copyWith(
              titleTextStyle: theme.listTileTheme.titleTextStyle?.copyWith(
                fontFamily: 'FixtureCJK',
              ),
              subtitleTextStyle: theme.listTileTheme.subtitleTextStyle
                  ?.copyWith(fontFamily: 'FixtureCJK'),
            ),
          ),
          home: AppShell(state: state, startup: const StartupArguments()),
        ),
      ),
    );
    // 首次启动的使用边界弹窗要等它真的出现再关：只 settle 一次时它可能还没
    // 读盘完成，截图上就会糊着一层遮罩，把要对比的界面挡住。
    // 关掉之后还要给「写标记文件」的真实 IO 一次机会：只 pumpAndSettle 时
    // 标记没落盘，壳层会立刻把弹窗再弹回来（截图里就一直是遮罩）。
    for (var attempt = 0; attempt < 10; attempt++) {
      final accept = find.text('我已了解并继续');
      if (accept.evaluate().isNotEmpty) await tester.tap(accept);
      await settle(tester);
      if (find.text('我已了解并继续').evaluate().isEmpty) break;
    }
    expect(find.text('我已了解并继续'), findsNothing, reason: '边界弹窗必须先关掉');
    expect(tester.takeException(), isNull);

    Future<void> capture(String scenario) async {
      if (phase == null) return;
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('$evidenceRoot/$phase-$scenario.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
        // ignore: avoid_print
        print('captured ${file.path} (${bytes.lengthInBytes} bytes)');
      });
    }

    await capture('topbar');

    // 改动后才存在的入口：Before 采集里没有它，跳过即可（对比的是顶栏本身）。
    final push = find.byKey(const ValueKey('topbar-push'));
    if (push.evaluate().isNotEmpty) {
      await tester.tap(push);
      await settle(tester);
      await capture('dialog');
      final close = find.byKey(const ValueKey('push-dialog-close'));
      if (close.evaluate().isNotEmpty) {
        await tester.tap(close);
        await settle(tester);
      }
      // 推送落点现在是详情页：这张图是"先详情后播放"的视觉证据。
      await tester.runAsync(
        () => state.submitPush(
          url: 'https://pan.baidu.com/s/16oztu4ZXEg6ZbN586Ji_Yw?pwd=wnsu',
          title: '菲蓝之路',
        ),
      );
      await settle(tester);
      await capture('detail');
      // 有配置时推送落到普通详情页（合成推送站点），不是兜底页。
      expect(find.byType(DetailPage), findsOneWidget);
    }
    // Before 采集必须落在旧入口还在的提交上；After 采集必须拍到它已消失。
    final oldEntry = find.byKey(const ValueKey('topbar-open-local-file'));
    if (phase == 'before') {
      expect(oldEntry, findsOneWidget, reason: 'Before 采集要拍旧入口');
    } else if (phase != null) {
      expect(oldEntry, findsNothing, reason: '验收点：旧入口已移除');
    }

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
