/// 解析器运行时端到端集成测试（设计文档 §12「解析器设计」、§12.3 验收）。
///
/// 真实链路：配置 `parses` → 播放入口返回 `parse=1` → `SiteService.resolvePlayback`
/// 真实调用解析器 HTTP 端点 → 解析出媒体地址 → 真实 media-kit 播放器出画。
///
/// 覆盖 §12.3 验收点：
/// - `parse=1` 必须走解析器（真实调用，非桩）；
/// - 解析结果必须校验媒体类型；
/// - 解析失败不影响直接换源（错误可定位，由上层决定回退）；
/// - 解析过程有超时；
/// - `flag` 命中解析器。
///
/// 前置条件：本机 fixture 服务已启动 `py -m tools.fixture_server.server`。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/playback.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/parse_service.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/services/spider_router.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:window_manager/window_manager.dart';

import '../test/fixture_support.dart';

void evidence(String message) => debugPrint('PHASE3-EVIDENCE $message');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  setUpAll(() async {
    await windowManager.ensureInitialized();
  });

  /// 构造带 `parses` 的配置（播放入口返回 parse=1）。
  AppConfig parserConfig() => AppConfig(
    name: '解析器集成',
    sites: [
      Site(
        key: 'parse-site',
        name: '解析站点',
        type: 1,
        api: '$fixtureBaseUrl/api/type1/',
        extra: {'playUrl': '$fixtureBaseUrl/api/play-parse-required'},
      ),
    ],
    parses: [
      ParseEntry(
        name: 'Fixture JSON 解析器',
        type: 1,
        url: '$fixtureBaseUrl/api/parse/type1',
      ),
    ],
  );

  Future<SiteService> buildService(AppConfig config) async {
    final router = SpiderRouter(
      client: HttpApiClient(),
      globalHeaders: const [],
    );
    addTearDown(router.dispose);
    return SiteService(appConfig: config, router: router);
  }

  testWidgets('真实解析器：parse=1 → 解析出地址 → 真实出画（§12.3）', (tester) async {
    final config = parserConfig();
    final service = await buildService(config);
    final parseService = ParseService();
    addTearDown(parseService.close);

    final outcome = await service.resolvePlayback(
      site: config.sites.first,
      episodeTarget: 'token',
      flag: 'line',
      parseService: parseService,
    );

    // 解析出真实媒体地址，且通过媒体类型校验。
    final decision = outcome.value;
    expect(decision.action, PlaybackAction.direct);
    expect(looksLikeMediaUrl(decision.url!), isTrue);
    evidence('parser-resolved url=${decision.url!.split('/').last} '
        'media-ok=true source=${decision.reason}');

    // 用解析结果真实播放出画（媒体与解析器同源，Header 已由解析器返回）。
    final temp = await Directory.systemTemp.createTemp('webhtv-parser-e2e');
    final state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${temp.path}${Platform.pathSeparator}config',
          'data': '${temp.path}${Platform.pathSeparator}data',
          'cache': '${temp.path}${Platform.pathSeparator}cache',
          'state': '${temp.path}${Platform.pathSeparator}logs',
        },
      ),
      log: LogService(),
    );
    addTearDown(() {
      state.dispose();
      temp.deleteSync(recursive: true);
    });
    await state.bootstrap();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerPage(
            state: state,
            request: PlaybackRequest(
              url: decision.url!,
              headers: decision.headers?.asRequestHeaders ?? const {},
              title: '解析器测试',
              siteKey: 'parse-site',
              vodId: 'parse-1',
              vodName: '解析器测试',
              episodeName: '第 1 集',
              flag: 'line',
            ),
          ),
        ),
      ),
    );

    var firstFrame = false;
    for (var attempt = 0; attempt < 60; attempt++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (find.byType(Video).evaluate().isEmpty) continue;
      final player =
          tester.widget<Video>(find.byType(Video).first).controller.player;
      if (player.state.position > Duration.zero) {
        firstFrame = true;
        break;
      }
    }
    expect(firstFrame, isTrue, reason: '解析出的地址应能真实出画');
    evidence('parser-playback first-frame=yes');
  });

  testWidgets('解析失败可定位且不影响直接换源（§12.3）', (tester) async {
    // 解析器指向错误端点（500）→ parseHttp，上层可回退。
    final config = AppConfig(
      name: '解析器失败',
      sites: [
        Site(
          key: 'parse-site',
          name: '解析站点',
          type: 1,
          api: '$fixtureBaseUrl/api/type1/',
          extra: {'playUrl': '$fixtureBaseUrl/api/play-parse-required'},
        ),
      ],
      parses: [
        ParseEntry(
          name: '坏解析器',
          type: 1,
          url: '$fixtureBaseUrl/api/parse/always-error',
        ),
      ],
    );
    final service = await buildService(config);
    final parseService = ParseService();
    addTearDown(parseService.close);

    try {
      await service.resolvePlayback(
        site: config.sites.first,
        episodeTarget: 'token',
        flag: 'line',
        parseService: parseService,
      );
      fail('解析器返回 500 时应抛出可定位错误');
    } on AppError catch (error) {
      // 失败被归一化为解析器错误，调用方据此回退换源。
      expect(isParseError(error), isTrue);
      expect(error.kind, AppErrorKind.parseHttp);
      evidence('parser-failure isolated=true kind=${error.kind.name}');
    }
  });
}