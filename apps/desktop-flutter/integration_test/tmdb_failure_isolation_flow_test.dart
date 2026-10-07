/// Phase 4 · TMDB 失败隔离集成（`docs/phase4/design/05` §5.4）。
///
/// 前置：本机 fixture 服务已启动（端口 18080）。
///
/// 步骤与断言：
///   1. 注入「所有 TMDB 请求 401」
///   2. 打开详情页
///   3. 断言 TMDB 区块显示鉴权错误文案，且含「不影响站源浏览与播放」
///   4. 断言线路选择与选集**照常可用**
///   5. 断言能成功播放（TMDB 失败不阻塞播放）
///   6. 断言熔断生效：再次进入详情页时 `/tmdb/__stats` 计数不增加
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/tmdb_widgets.dart' show TmdbLoadPhase;

void evidence(String message) =>
    debugPrint('PHASE4-EVIDENCE tmdb-failure-isolation $message');

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

/// 读取 fixture 的 TMDB 命中计数（`05` §2.3）。
Future<int> tmdbTotalHits(String base) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse('$base/tmdb/__stats'));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    final decoded = jsonDecode(body) as Map<String, Object?>;
    return (decoded['total'] as num?)?.toInt() ?? 0;
  } finally {
    client.close(force: true);
  }
}

/// 设置故障注入模式（`/tmdb/__mode?auth=401|off`）。
Future<void> setTmdbMode(String base, String auth) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      Uri.parse('$base/tmdb/__mode?auth=$auth'),
    );
    final response = await request.close();
    await response.drain<void>();
  } finally {
    client.close(force: true);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final base =
      Platform.environment['WEBHTV_FIXTURE_BASE'] ?? 'http://127.0.0.1:18080';

  testWidgets('TMDB 401：不阻塞浏览与播放 + 熔断计数不增', (tester) async {
    final temp = Directory.systemTemp.createTempSync('webhtv-tmdb-fail-e2e');
    final paths = AppPaths.resolve(
      overrides: {'roaming': temp.path, 'local': temp.path},
    );
    final state = AppState(paths: paths, log: LogService());
    addTearDown(() async {
      state.dispose();
      // 无论断言结果如何都要恢复 fixture 模式，避免污染后续套件。
      await setTmdbMode(base, 'off');
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    await state.bootstrap();

    await state.saveTmdbConfig(
      state.tmdbConfig.copyWith(
        apiBase: '$base/tmdb/3',
        apiKey: 'fixture-key',
        accessToken: '',
        enabledSites: const [],
        disabledSites: const [],
        allowedSites: const [],
      ),
    );

    final imported = await state.importConfig(
      jsonEncode({
        'name': 'TMDB 失败隔离 e2e',
        'sites': [
          {
            'key': 'nodejs_tmdb',
            'name': 'TMDB 站点',
            'type': 1,
            'api': '$base/api/tmdb-detail',
            'searchable': 1,
          },
        ],
        'headers': [
          {
            'host': '127.0.0.1',
            'header': {
              'Referer': 'http://127.0.0.1:18080/',
              'User-Agent': 'WebHTV-PC/0.1 (Windows)',
            },
          },
        ],
      }),
    );
    expect(imported, isTrue, reason: state.lastError?.logLine);

    // 1) 注入 401：所有 `/tmdb/3/**` 返回鉴权失败。
    await setTmdbMode(base, '401');
    state.tmdb.clearError();
    state.clearAuthBlocksForTest();

    final vod = Vod(vodId: 'tmdb-demo', vodName: '示例剧集');
    await state.loadDetail(vod);
    expect(state.detailPhase, LoadPhase.ready, reason: '详情未就绪');

    // 2) TMDB 进入失败态。
    await drainRealIo(tester, until: () => state.tmdb.phase == TmdbLoadPhase.failed);
    expect(state.tmdb.phase, TmdbLoadPhase.failed, reason: 'TMDB 未进入失败态');
    final error = state.tmdb.error;
    expect(error, isNotNull, reason: '失败态缺少错误对象');
    expect(error!.kind, AppErrorKind.tmdbAuth, reason: '错误类别不是 tmdbAuth');
    // 3) 文案必须含「不影响站源浏览与播放」（`04` §3.4 强制）。
    expect(
      error.userMessage,
      contains('不影响站源浏览与播放'),
      reason: '错误文案缺少失败隔离声明：${error.userMessage}',
    );
    evidence('tmdb-error kind=${error.kind.name} message=${error.userMessage}');

    // 4) 线路与选集照常可用。
    final lines = state.playLinesOf(state.detailResult!.list.first);
    expect(lines, isNotEmpty, reason: 'TMDB 失败后线路丢失');
    expect(lines.first.episodes, isNotEmpty, reason: 'TMDB 失败后选集丢失');
    evidence('lines=${lines.length} episodes=${lines.first.episodes.length}');

    // 5) 播放照常成功（TMDB 失败不阻塞播放）。
    final episode = lines.first.episodes.first;
    final decision = await state.resolvePlayback(
      episodeTarget: episode.url,
      flag: lines.first.flag,
      vodId: vod.vodId,
    );
    expect(decision?.url, isNotNull, reason: 'TMDB 失败后播放决策失败');

    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          state: state,
          request: PlaybackRequest(
            url: decision!.url!,
            headers: decision.headers?.asRequestHeaders ?? const {},
            title: vod.vodName,
            siteKey: state.selectedSite?.key ?? '',
            vodId: vod.vodId,
            vodName: vod.vodName,
            episodeName: episode.name,
            flag: lines.first.flag,
            playLines: lines,
            episodeIndex: 0,
            subtitles: decision.subs,
            danmaku: decision.danmaku,
            subtitleHeaders: decision.assetHeaders?.asRequestHeaders ?? const {},
          ),
        ),
      ),
    );
    var firstFrame = false;
    for (var attempt = 0; attempt < 80; attempt++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (find.byType(Video).evaluate().isEmpty) continue;
      final video = tester.widget<Video>(find.byType(Video).first);
      if (video.controller.player.state.position > Duration.zero) {
        firstFrame = true;
        break;
      }
    }
    expect(firstFrame, isTrue, reason: 'TMDB 401 时播放未出画（不应阻塞播放）');
    evidence('playback first-frame=yes tmdb-failed=true');

    // 6) 熔断：再次进入详情页时 TMDB 请求计数不增加。
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump(const Duration(milliseconds: 200));
    final before = await tmdbTotalHits(base);
    await state.loadDetail(vod);
    await drainRealIo(
      tester,
      until: () => state.tmdb.phase == TmdbLoadPhase.failed,
      timeout: const Duration(seconds: 8),
    );
    final after = await tmdbTotalHits(base);
    expect(
      after,
      before,
      reason: '熔断期仍发起了 TMDB 请求（before=$before after=$after）',
    );
    evidence('circuit-breaker before=$before after=$after delta=0');
  });
}
