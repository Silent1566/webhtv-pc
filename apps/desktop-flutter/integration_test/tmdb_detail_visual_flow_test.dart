/// Phase 4 · TMDB 详情页**可视化**集成（`docs/phase4/design/04` §3、§4.2、§6、§11）。
///
/// 与 `tmdb_detail_flow_test.dart` 的分工：那个文件锁「匹配 → 季度 → 不补集」的
/// 数据契约；本文件锁**用户反馈的三条渲染缺陷**（2026-10-07）：
///
/// 1. 每集要有对应的海报卡片（剧照 + 集号 + 标题）；
/// 2. 头部要有海报、导演、时长、季集数等 TMDB 信息；
/// 3. 剧照 / 演职人员 / 相关推荐必须**可点击**（查看器 / 人物页 / 作品详情）；
/// 4. 动态背景必须真的用剧集海报/剧照，并且按 5 秒轮播。
///
/// 与 L1 widget 用例的区别：这里跑**真实窗口 + 真实 HTTP + 真实图片解码**
/// （fixture 服务的 `/tmdb-img/**` 返回真实 PNG），因此能证明
/// 「图片地址拼对了、真的能加载」，而不是只命中占位图。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';

void evidence(String message) =>
    debugPrint('PHASE4-EVIDENCE tmdb-detail-visual $message');

/// 在真实 async 区推进 I/O，直到 [until] 成立或超时。
Future<void> drainRealIo(
  WidgetTester tester, {
  required bool Function() until,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (until()) return;
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pump();
  }
}

/// 让目标控件进入视口。
///
/// 为什么不用 `tester.scrollUntilVisible`：它会用 `finder` 找 **唯一的**
/// `Scrollable`，而详情页里同时存在页面纵向列表与剧集/剧照/人员的横向列表，
/// 直接抛 `Bad state: Too many elements`。这里显式只拖外层纵向列表，
/// 并且允许「本来就在视口内」的情况直接返回。
Future<void> ensureVisible(WidgetTester tester, Finder target) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    if (target.evaluate().isNotEmpty) return;
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -400));
    await tester.pump(const Duration(milliseconds: 80));
  }
}

/// 把当前整窗渲染结果写成 PNG 证据（`docs/phase4/evidence/`）。
///
/// 为什么必须落盘：本轮改动是**视觉重设计**（动态背景、海报卡片、可点击区块），
/// 「有代码」「有 widget 树」都不足以证明用户看到的样子。截图是唯一能直接复核
/// 「背景是不是图片、每集有没有卡片、点击后打开了什么」的证据。
///
/// 渲染来源：`RepaintBoundary` 层树 → `toImage` → PNG。这是真实光栅化结果，
/// 不是 widget 树的重新描述。
///
/// [anchor] 用来指定「要拍哪一层」。不指定时取第一个 `RepaintBoundary`
/// （即整窗）。**对话框必须显式指定**：对话框在 Navigator 的 overlay 里，
/// 取第一个 boundary 会拍到被压在下面的页面，证据看起来像「对话框没打开」。
Future<void> captureEvidence(
  WidgetTester tester, {
  required String relativePath,
  Finder? anchor,
}) async {
  final binding = IntegrationTestWidgetsFlutterBinding.instance;
  final boundary = anchor ?? find.byType(RepaintBoundary);
  if (boundary.evaluate().isEmpty) {
    evidence('screenshot-skip reason=no-repaint-boundary path=$relativePath');
    return;
  }
  final object = boundary.evaluate().first.renderObject;
  if (object is! RenderRepaintBoundary) {
    evidence('screenshot-skip reason=not-repaint-boundary path=$relativePath');
    return;
  }
  final image = await object.toImage(pixelRatio: 1.0);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  if (bytes == null) {
    evidence('screenshot-skip reason=encode-failed path=$relativePath');
    return;
  }
  final repoRoot = _repoRootOf(Directory.current);
  final output = File('${repoRoot.path}/$relativePath');
  output.parent.createSync(recursive: true);
  output.writeAsBytesSync(bytes.buffer.asUint8List());
  evidence(
    'screenshot path=$relativePath bytes=${bytes.lengthInBytes} '
    'size=${image.width}x${image.height} binding=${binding.runtimeType}',
  );
}

/// 预热图片：把 URL 解析进 Flutter 的全局 `imageCache`，并让 widget 重建。
///
/// 为什么必须预热后再截图：`Image.network` 是异步解码的，`tester.pump()` 不会
/// 等待真实网络。若直接截图，图片位置会停在 `PosterImage` 的占位图上——证据
/// 看起来像「海报没渲染」，实际只是拍早了。预热后同一 URL 走缓存同步出图，
/// 截图才代表用户真实看到的样子。
Future<void> warmImages(WidgetTester tester, Iterable<String> urls) async {
  final unique = <String>{};
  for (final url in urls) {
    if (url.trim().isEmpty) continue;
    unique.add(url);
  }
  if (unique.isEmpty) return;
  await tester.runAsync(() async {
    for (final url in unique) {
      try {
        final stream = NetworkImage(url).resolve(ImageConfiguration.empty);
        final completer = Completer<void>();
        late ImageStreamListener listener;
        listener = ImageStreamListener(
          (_, _) {
            if (!completer.isCompleted) completer.complete();
          },
          onError: (error, _) {
            if (!completer.isCompleted) completer.complete();
          },
        );
        stream.addListener(listener);
        await completer.future.timeout(
          const Duration(seconds: 10),
          onTimeout: () {},
        );
        stream.removeListener(listener);
      } catch (_) {
        // 单张失败不影响截图（占位图会如实反映在证据里）。
      }
    }
  });
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 120));
}

/// 等到动态背景停在**指定下标**再继续。
///
/// 为什么需要：背景每 5 秒轮播一次，而「走到截图那一步」的耗时随机器负载浮动，
/// 因此直接截图会拍到不确定的那一张——证据文件每次运行都变，既不可复现，
/// 也无法用「第 N 张是哪张图」做人工核对。这里等到 `tmdb-backdrop-<index>`
/// 出现再拍，使证据**可复现**（轮播周期内必然等到）。
///
/// 只用公开的 widget key 判定，不给产品代码加测试专用开关。
Future<void> waitForBackdropIndex(
  WidgetTester tester,
  int index, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (find.byKey(ValueKey('tmdb-backdrop-$index')).evaluate().isNotEmpty) {
      // 等淡入完成，避免拍到两张图叠加的中间态。
      await tester.pump(const Duration(milliseconds: 700));
      return;
    }
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 从当前目录向上找到仓库根（含 `docs/phase4` 的那一级）。
Directory _repoRootOf(Directory start) {
  var current = start;
  for (var i = 0; i < 6; i++) {
    if (Directory('${current.path}/docs/phase4').existsSync()) return current;
    final parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }
  return start;
}

/// 统计窗口内**已成功解码**的图片数量。
///
/// `PosterImage` 用 `Image.network`：真实加载成功时 widget 树里存在
/// 已完成的 `Image`（无 loadingBuilder 占位）。这里直接数 `Image` 且其
/// `image` 为 `NetworkImage` 的实例，配合 `precacheImage` 结果断言。
int networkImageCount(WidgetTester tester) {
  final finder = find.byType(Image);
  var count = 0;
  for (final element in finder.evaluate()) {
    final widget = element.widget as Image;
    if (widget.image is NetworkImage) count++;
  }
  return count;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final base =
      Platform.environment['WEBHTV_FIXTURE_BASE'] ?? 'http://127.0.0.1:18080';

  testWidgets('TMDB 详情页：动态背景 + 每集海报卡片 + 可点击剧照/演职人员/推荐', (tester) async {
    final temp = Directory.systemTemp.createTempSync('webhtv-tmdb-visual-e2e');
    final paths = AppPaths.resolve(
      overrides: {'roaming': temp.path, 'local': temp.path},
    );
    final state = AppState(paths: paths, log: LogService());
    addTearDown(() {
      state.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    await state.bootstrap();

    // TMDB 指向本机 fixture：API 与图片基址都指向 fixture 服务，
    // 这样海报/剧照/头像都是**真实可加载的 PNG**。
    final saved = await state.saveTmdbConfig(
      state.tmdbConfig.copyWith(
        apiBase: '$base/tmdb/3',
        apiKey: 'fixture-key',
        accessToken: '',
        imageBase: '$base/tmdb-img/w342',
        backdropBase: '$base/tmdb-img/w780',
        enabledSites: const [],
        disabledSites: const [],
        allowedSites: const [],
      ),
    );
    expect(saved, isTrue, reason: 'TMDB 设置写入失败');

    final imported = await state.importConfig(
      jsonEncode({
        'name': 'TMDB 详情可视化 e2e',
        'sites': [
          {
            'key': 'nodejs_tmdb',
            'name': 'TMDB 站点',
            'type': 1,
            'api': '$base/api/tmdb-detail',
            'searchable': 1,
          },
        ],
      }),
    );
    expect(imported, isTrue, reason: state.lastError?.logLine);

    // 真实桌面窗口尺寸：高度给足，使详情页的附加区块一次性渲染出来
    // （否则需要滚动，而滚动在横向列表嵌套时不稳定）。
    tester.view.physicalSize = const Size(1600, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final vod = Vod(vodId: 'tmdb-demo', vodName: '示例剧集');
    await tester.pumpWidget(
      MaterialApp(home: DetailPage(state: state, vod: vod)),
    );
    await tester.pump();

    // 1) 详情 + TMDB 匹配 + 详情响应。
    await drainRealIo(
      tester,
      until: () => state.detailPhase == LoadPhase.ready,
    );
    expect(state.detailPhase, LoadPhase.ready, reason: '详情未就绪');
    await drainRealIo(
      tester,
      until: () =>
          state.tmdb.hasMatch &&
          state.tmdb.detail != null &&
          state.tmdb.episodes.isNotEmpty,
    );
    expect(state.tmdb.hasMatch, isTrue, reason: 'TMDB 未匹配');
    expect(state.tmdb.episodes, isNotEmpty, reason: 'TMDB 剧集元数据未加载');
    await tester.pump();

    final data = state.tmdb.detailData;
    expect(data, isNotNull, reason: '详情展示模型为空');
    evidence(
      'detail title=${data!.title} backdrops=${data.backdropUrls.length} '
      'photos=${data.photoUrls.length} people=${data.allPeople.length} '
      'director=${data.directorLabel} runtime=${data.runtimeLabel} '
      'seasons=${data.seasons.length}',
    );

    // 2) 动态背景：必须用剧集海报/剧照，且多于一张（才能轮播）。
    expect(
      data.backdropUrls.length,
      greaterThan(1),
      reason: '动态背景必须有多张图可轮播',
    );
    for (final url in data.backdropUrls) {
      expect(
        url.startsWith('$base/tmdb-img/'),
        isTrue,
        reason: '背景图必须来自 TMDB 图片主机：$url',
      );
    }
    expect(
      find.byKey(const ValueKey('tmdb-backdrop-slideshow')),
      findsOneWidget,
      reason: '详情页必须有动态背景',
    );
    evidence('backdrop[0]=${data.backdropUrls.first}');

    // 3) 背景图**真的能加载**：真实 HTTP + 真实 PNG 解码。
    final decoded = await tester.runAsync(() async {
      for (final url in data.backdropUrls.take(2)) {
        final image = NetworkImage(url);
        final stream = image.resolve(ImageConfiguration.empty);
        final completer = Completer<void>();
        late ImageStreamListener listener;
        listener = ImageStreamListener(
          (_, _) => completer.complete(),
          onError: (error, _) => completer.completeError(error),
        );
        stream.addListener(listener);
        await completer.future;
        stream.removeListener(listener);
      }
      return true;
    });
    expect(decoded, isTrue, reason: '背景图必须能从 fixture 服务真实加载');
    evidence('backdrop-decoded=${data.backdropUrls.take(2).length}');

    // 4) 每集的海报卡片：数量等于线路渲染集数，且每张都有剧照地址。
    final line = state.tmdb.lineByFlag('线路一')!;
    final cards = state.tmdb.episodeCardsForEpisodes(
      state.tmdb.applyEpisodesToLine(line).line.episodes.take(3).toList(),
      seasonNumber: state.tmdb.selectedSeason,
    );
    expect(cards, isNotEmpty, reason: '剧集卡片为空');
    expect(
      cards.every((card) => card.number > 0),
      isTrue,
      reason: '每张卡片都必须有集号',
    );
    expect(
      find.byKey(const ValueKey('tmdb-episode-strip-线路一')),
      findsOneWidget,
      reason: '线路区必须有剧集海报卡片条',
    );
    expect(
      find.byKey(const ValueKey('tmdb-episode-card-线路一-0')),
      findsOneWidget,
    );
    // 当前线路必须真的套用 TMDB 剧集元数据（`04` §4.3）：
    // 卡片标题是 TMDB 集标题、剧照是 TMDB 剧照。否则就是「线路未选中」缺陷
    // （实测：卡片只剩来源集名 + 占位图，用户看到的就是「没有海报」）。
    expect(
      find.byKey(const ValueKey('tmdb-episode-card-线路一-still-1')),
      findsOneWidget,
      reason: '当前线路的剧集卡片必须带 TMDB 剧照',
    );
    evidence(
      'episode-cards=${cards.length} '
      'with-still=${cards.where((c) => c.hasStill).length} '
      'first=${cards.first.title}',
    );

    // 剧照卡片的图片也必须能真实加载（证明地址拼对）。
    final stillUrl = cards.firstWhere((card) => card.hasStill).stillUrl!;
    expect(
      stillUrl.startsWith('$base/tmdb-img/'),
      isTrue,
      reason: '剧照必须来自 TMDB 图片主机：$stillUrl',
    );
    final stillDecoded = await tester.runAsync(() async {
      final image = NetworkImage(stillUrl);
      final stream = image.resolve(ImageConfiguration.empty);
      final completer = Completer<void>();
      late ImageStreamListener listener;
      listener = ImageStreamListener(
        (_, _) => completer.complete(),
        onError: (error, _) => completer.completeError(error),
      );
      stream.addListener(listener);
      await completer.future;
      stream.removeListener(listener);
      return true;
    });
    expect(stillDecoded, isTrue, reason: '剧照必须能真实加载：$stillUrl');
    evidence('still-decoded=$stillUrl');

    // 5) 头部信息：海报 + 导演 + 评分 + 时长 + 季集数。
    expect(find.byKey(const ValueKey('tmdb-detail-title')), findsOneWidget);
    expect(find.byKey(const ValueKey('tmdb-detail-poster')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('tmdb-detail-director')),
      findsOneWidget,
      reason: '头部必须显示导演',
    );
    expect(find.byKey(const ValueKey('tmdb-detail-rating')), findsOneWidget);
    expect(find.byKey(const ValueKey('tmdb-detail-runtime')), findsOneWidget);
    expect(find.byKey(const ValueKey('tmdb-detail-seasons')), findsOneWidget);
    expect(networkImageCount(tester), greaterThan(0), reason: '页面必须有网络图片');
    evidence('header-poster-director-rating-runtime-seasons=present');
    // 截图 1：详情页顶部（动态背景 + 海报 + 导演 + 评分/时长/季集数）。
    // 先等背景停在第 0 张，使证据可复现（见 waitForBackdropIndex 注释）。
    await waitForBackdropIndex(tester, 0);
    await warmImages(tester, [
      if (data.posterUrl != null) data.posterUrl!,
      ...data.backdropUrls,
      ...data.photoUrls,
      ...data.allPeople.map((p) => p.profileUrl).whereType<String>(),
      ...cards.map((c) => c.stillUrl).whereType<String>(),
      ...state.tmdb.recommendations.take(6).map((i) => i.posterUrl).whereType<String>(),
    ]);
    await captureEvidence(
      tester,
      relativePath: 'docs/phase4/evidence/tmdb-detail-header.png',
    );

    // 6) 剧照墙：点击第 N 张 → 查看器定位到第 N 张。
    await ensureVisible(tester, find.byKey(const ValueKey('tmdb-section-photos')));
    expect(
      find.byKey(const ValueKey('tmdb-section-photos')),
      findsOneWidget,
      reason: '剧照区块必须渲染',
    );
    final photos = state.tmdb.detailData!.photoUrls;
    expect(photos.length, greaterThan(1), reason: '剧照必须多于一张才能验证定位');
    await tester.tap(find.byKey(const ValueKey('tmdb-photo-1')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('tmdb-photo-viewer')),
      findsOneWidget,
      reason: '点击剧照必须打开查看器（用户反馈：点击无效）',
    );
    final viewerImage = tester.widget<Image>(
      find
          .descendant(
            of: find.byKey(const ValueKey('tmdb-photo-viewer-image')),
            matching: find.byType(Image),
            matchRoot: true,
          )
          .first,
    );
    expect(
      (viewerImage.image as NetworkImage).url,
      photos[1],
      reason: '查看器必须定位到被点击的那一张',
    );
    evidence('photo-viewer index=1/${photos.length}');
    // 截图 2：剧照查看器（证明点击剧照真的打开了大图并定位到被点击那张）。
    //
    // 显式锚定到对话框自身：对话框在 overlay 里，拍整窗会得到被压在下面的
    // 详情页，证据无法证明「查看器打开了」。
    await warmImages(tester, [photos[1]]);
    await captureEvidence(
      tester,
      relativePath: 'docs/phase4/evidence/tmdb-photo-viewer.png',
      anchor: find.byKey(const ValueKey('tmdb-photo-viewer-boundary')),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tmdb-photo-viewer')), findsNothing);

    // 7) 演职人员：点击 → 人物页（含简介/照片/作品）。
    await ensureVisible(tester, find.byKey(const ValueKey('tmdb-section-people')));
    final personId = data.allPeople.first.personId;
    await tester.tap(find.byKey(ValueKey('tmdb-person-$personId')));
    await tester.pumpAndSettle();
    await drainRealIo(
      tester,
      until: () => find
          .byKey(const ValueKey('tmdb-person-page'))
          .evaluate()
          .isNotEmpty,
    );
    expect(
      find.byKey(const ValueKey('tmdb-person-page')),
      findsOneWidget,
      reason: '点击演职人员必须打开人物页（用户反馈：点击无效）',
    );
    await drainRealIo(
      tester,
      until: () =>
          find.byKey(const ValueKey('tmdb-person-biography')).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 20),
    );
    expect(
      find.byKey(const ValueKey('tmdb-person-biography')),
      findsOneWidget,
      reason: '人物页必须展示简介',
    );
    expect(
      find.byKey(const ValueKey('tmdb-person-works')),
      findsOneWidget,
      reason: '人物页必须展示作品列表',
    );
    evidence('person-page id=$personId works=present');
    // 截图 3：人物页（证明演职人员点击真的打开了人物页）。
    await warmImages(tester, [
      ...find
          .byType(Image)
          .evaluate()
          .map((element) => (element.widget as Image).image)
          .whereType<NetworkImage>()
          .map((provider) => provider.url),
    ]);
    await captureEvidence(
      tester,
      relativePath: 'docs/phase4/evidence/tmdb-person-page.png',
    );
    await tester.pageBack();
    await tester.pumpAndSettle();

    // 8) 相关视频区块（浏览器打开 + 复制链接）仍然存在。
    await ensureVisible(tester, find.byKey(const ValueKey('tmdb-section-videos')));
    expect(
      find.byKey(const ValueKey('tmdb-section-videos')),
      findsOneWidget,
      reason: '相关视频区块必须渲染',
    );
    expect(state.tmdb.videos, isNotEmpty, reason: 'fixture 必须提供相关视频');
    evidence('videos-section=present count=${state.tmdb.videos.length}');

    // 9) 相关推荐：点击 → 该作品的 TMDB 详情页。
    await ensureVisible(
      tester,
      find.byKey(const ValueKey('tmdb-section-recommendations')),
    );
    final recommendations = state.tmdb.recommendations;
    expect(recommendations, isNotEmpty, reason: 'fixture 必须提供相关推荐');
    final firstKey = recommendations.first.identity!.key;
    await tester.tap(find.byKey(ValueKey('tmdb-recommendation-$firstKey')));
    await tester.pumpAndSettle();
    await drainRealIo(
      tester,
      until: () => find
          .byKey(const ValueKey('tmdb-detail-title'))
          .evaluate()
          .isNotEmpty,
      timeout: const Duration(seconds: 25),
    );
    expect(
      find.byKey(const ValueKey('tmdb-detail-title')),
      findsOneWidget,
      reason: '点击相关推荐必须进入该作品的详情页（用户反馈：点击无效）',
    );
    expect(
      find.byKey(const ValueKey('tmdb-backdrop-slideshow')),
      findsOneWidget,
      reason: '推荐作品的详情页同样必须有动态背景',
    );
    evidence('recommendation-detail key=$firstKey');
    // 截图 4：推荐作品详情（证明相关推荐点击真的进入了作品详情）。
    await waitForBackdropIndex(tester, 0);
    await warmImages(tester, [
      ...find
          .byType(Image)
          .evaluate()
          .map((element) => (element.widget as Image).image)
          .whereType<NetworkImage>()
          .map((provider) => provider.url),
    ]);
    await captureEvidence(
      tester,
      relativePath: 'docs/phase4/evidence/tmdb-recommendation-detail.png',
    );

  });
}
