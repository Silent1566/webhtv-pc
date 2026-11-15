/// P0-6b 视觉证据：PotPlayer 式在线字幕搜索窗口。
///
/// ## 口径
///
/// 与 `test/p1_4_menu_visual_capture_test.dart` 完全一致：1280×720、dPR 1.0、
/// `buildAppTheme(Brightness.dark)`、注册 CJK 字体。放在 `test/` 而不是
/// `integration_test/`：本用例只需要离屏光栅化，走 `integration_test/` 会触发
/// 原生构建。
///
/// ## 为什么要独立的假数据
///
/// 结果列表是这一屏的主体，用真实网络截图会随源的可用性漂移。这里固定一份
/// 3 源 5 条的 `SubtitleSearchReport`，同一份数据既用于取证也用于 `README`
/// 的场景表——图和文字描述的是同一次点击。
///
/// ## Before / After
///
/// 本文件只产出 **After**。Before（改动前的「关键词对话框 + 结果底部弹窗」
/// 两步流程）由 dispatcher 在 HEAD 的独立 worktree 上用同一场景生成——
/// 旧流程是一个对话框加一个底部弹窗，无法在本用例里复现成同一张图，
/// 自己伪造一张对比图会把证据变成断言。
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/subtitle_provider.dart';
import 'package:webhtv_pc/services/subtitle_match_service.dart';
import 'package:webhtv_pc/ui/subtitle_search_dialog.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tokens.dart';

import 'support/test_fonts.dart';

void evidence(String message) => debugPrint('P0-6B-VISUAL-EVIDENCE $message');

/// 只有显式要求时才写图：默认 `flutter test` 会跑 test/ 下所有用例，
/// 让它每跑一次就改一遍 `docs/` 下的证据文件是污染。
/// 与 `test/p1_4_menu_visual_capture_test.dart:46` 同一口径：
/// `P0_6B_CAPTURE=1 flutter test test/p0_6b_search_capture_test.dart`。
final bool _captureEnabled = Platform.environment['P0_6B_CAPTURE'] == '1';

const Key _rootKey = ValueKey<String>('p0-6b-search-capture-root');

const SubtitleQuery _query = SubtitleQuery(
  title: '某剧 第二季',
  year: 2024,
  season: 2,
  episode: 3,
  siteKey: 'demo',
  vodId: 'vod-1',
  episodeName: '第03集',
);

/// 固定的假报告：ASSRT 2 条（简中 srt/ass）、迅雷 2 条、射手 1 条，已按分排序。
const SubtitleSearchReport _report = SubtitleSearchReport(
  candidates: [
    SubtitleCandidate(
      providerId: 'assrt',
      assetId: 'a-3021',
      title: '某剧 第二季 第03集 简中 ASS',
      language: 'zh-Hans',
      format: 'ass',
      url: 'https://example.test/a-3021.ass',
      score: 0.94,
      season: 2,
      episode: 3,
      requiresResolve: true,
    ),
    SubtitleCandidate(
      providerId: 'assrt',
      assetId: 'a-3108',
      title: '某剧 S02E03 简体中文',
      language: 'zh-Hans',
      format: 'srt',
      url: 'https://example.test/a-3108.srt',
      score: 0.89,
      season: 2,
      episode: 3,
      requiresResolve: true,
    ),
    SubtitleCandidate(
      providerId: 'xunlei',
      assetId: 'x-7710',
      title: '某剧.第3集.1080p.繁体',
      language: 'zh-Hant',
      format: 'srt',
      url: 'https://example.test/x-7710.srt',
      score: 0.83,
      season: 2,
      episode: 3,
      requiresResolve: true,
    ),
    SubtitleCandidate(
      providerId: 'xunlei',
      assetId: 'x-7711',
      title: '某剧 S02 第3集 中字',
      language: 'zh-Hans',
      format: 'srt',
      url: 'https://example.test/x-7711.srt',
      score: 0.80,
      season: 2,
      episode: 3,
      requiresResolve: true,
    ),
    SubtitleCandidate(
      providerId: 'shooter',
      assetId: 's-0042',
      title: '某剧.S02E03.ass',
      language: '',
      format: 'ass',
      url: 'https://example.test/s-0042.ass',
      score: 0.64,
      season: 2,
      episode: 3,
      requiresResolve: true,
    ),
  ],
);

Directory repoRootOf(Directory start) {
  var current = start;
  for (var hop = 0; hop < 6; hop++) {
    if (Directory('${current.path}/docs').existsSync()) return current;
    final parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }
  return start;
}

/// 把当前树拍成 PNG 写进仓库。
///
/// **必须在 `tester.runAsync` 里跑**：`toImage` / `toByteData` 的 Future 由引擎
/// 在真实 zone 完成，落在 FakeAsync 里会卡住整个用例。
Future<void> capture(WidgetTester tester, {required String relativePath}) async {
  if (!_captureEnabled) {
    evidence('screenshot-skip reason=capture-disabled path=$relativePath');
    return;
  }
  final bytes = await tester.runAsync(() async {
    final object = find.byKey(_rootKey).evaluate().first.renderObject;
    if (object is! RenderRepaintBoundary) return null;
    final image = await object.toImage(pixelRatio: 1.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data == null ? null : Uint8List.sublistView(data);
  });
  if (bytes == null) {
    evidence('screenshot-skip reason=no-bytes path=$relativePath');
    return;
  }
  final output = File('${repoRootOf(Directory.current).path}/$relativePath');
  output.parent.createSync(recursive: true);
  output.writeAsBytesSync(bytes);
  evidence('screenshot path=$relativePath bytes=${bytes.length}');
}

/// 注册的字体族名（`test/support/test_fonts.dart` 的 `cjkFamily`）。
const String _cjkFamily = 'Noto Sans CJK SC';

/// 取证专用主题：把 CJK 字体设成**主**字体族。
///
/// 只注册字体是不够的：`flutter test` 的默认字体是 FlutterTest——它覆盖拉丁
/// 字母与数字（每个字形画成一个方块），所以「ASSRT · zh-Hans · 0.94」这行
/// 副标题会整片变成方块，而中文因为落在 `theme.dart` 的 fontFamilyFallback 上
/// 反而正常。证据图里恰恰是分数与源名要证明，必须让主字体族也是真字体。
/// 主题本身（颜色/间距/形状）仍是 `buildAppTheme(Brightness.dark)` 原样。
ThemeData captureTheme() {
  final base = buildAppTheme(Brightness.dark);
  final text = base.textTheme.apply(fontFamily: _cjkFamily);
  final label = base.textTheme.labelLarge?.copyWith(fontFamily: _cjkFamily);
  // 按钮与芯片的文字样式是 buildAppTheme 时从旧 textTheme 捕获的副本，
  // 不会跟着 apply 走；漏掉它们，底栏那颗按钮就会退回测试默认字体。
  return base.copyWith(
    textTheme: text,
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: _cjkFamily),
    textButtonTheme: TextButtonThemeData(
      style: base.textButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll(label),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: base.filledButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll(
          label?.copyWith(fontWeight: AppWeight.title),
        ),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      labelStyle: base.chipTheme.labelStyle?.copyWith(
        fontFamily: _cjkFamily,
      ),
      secondaryLabelStyle: base.chipTheme.secondaryLabelStyle?.copyWith(
        fontFamily: _cjkFamily,
      ),
    ),
  );
}

void main() {
  // 没注册 CJK 字体时中文全是豆腐块，截图就成了「看不出文案」的假证据。
  setUpAll(() async {
    await loadFixtureFonts(cjkFamily: _cjkFamily);
    reportFixtureFonts();
  });

  testWidgets('After：点击「搜索」后的结果窗口', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      RepaintBoundary(
        key: _rootKey,
        child: MaterialApp(
          // 主题与 release 一致：取证图里的颜色就是用户看到的颜色。
          theme: captureTheme(),
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showSubtitleSearchDialog(
                    context: context,
                    initialQuery: _query,
                    search: (_) async => _report,
                    pickLocalFile: () async => null,
                  ),
                  child: const Text('搜索字幕'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('搜索字幕'));
    await tester.pumpAndSettle();

    // 同一次点击：只点一次「搜索」，只拍这一态。
    await tester.tap(
      find.byKey(const ValueKey<String>('subtitle-search-submit')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('subtitle-search-row-assrt-a-3021')),
      findsOneWidget,
      reason: '取证图必须真的走到结果态',
    );

    // 收起输入焦点：焦点态会在关键词框下方留下文本选择手柄，那是测试环境的
    // 光标，不是用户看到的窗口形态。
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    await capture(
      tester,
      relativePath: 'docs/reference/evidence/p0-6b-search/after-search-window.png',
    );

    // 收尾：把树换成一个空 SizedBox 再 settle，让本用例的 element/ticker 全部释放。
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
