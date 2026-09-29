/// 直播页 UI 与播放接入测试（设计文档 §13、§17.2）。
///
/// 覆盖：
/// - 未配置直播源时的空态说明（不是空白页）；
/// - 直播源 → 分组 → 频道的渲染与多线路展示；
/// - 单源失败只影响该源，其他源仍可用（§14.3）；
/// - 点击频道进入播放器时使用直播直链（`directUrl`），并携带多线路；
/// - 频道无线路时不提供播放入口。
///
/// 说明：`testWidgets` 运行在 fake-async 区，真实 socket I/O 无法推进。
/// 因此这里注入一个**只读本地 fixture 文本**的 [LiveService] 子类；
/// 真实 HTTP 拉取与编码/缓存/错误路径由 `phase3_live_service_test.dart`
/// 在普通 async 区覆盖。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/live_playlist.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/live_service.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/live_page.dart';

import 'fixture_support.dart';

/// 只读本地 fixture 文本的直播服务：按 URL 中的文件名映射到 `packages/test-fixtures/live`。
class _FixtureLiveService extends LiveService {
  _FixtureLiveService();

  @override
  Future<LiveLoadResult> load(LiveSource source, {bool useCache = true}) async {
    final url = source.url ?? '';
    if (url.contains('nope')) {
      throw AppError(
        AppErrorKind.liveHttp,
        '直播清单下载返回 HTTP 404',
        statusCode: 404,
      );
    }
    final name = url.split('/').last;
    final text = readFixture('live/$name');
    final stopwatch = Stopwatch()..start();
    final playlist = parseLivePlaylist(
      source.name,
      text,
      declaredType: source.type,
    );
    return LiveLoadResult(
      playlist: playlist,
      source: source,
      latency: stopwatch.elapsed,
    );
  }

  @override
  void close() {}
}

void main() {
  late Directory tempDir;
  late AppState state;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-live-page');
    final paths = AppPaths.resolve(
      overrides: {'roaming': tempDir.path, 'local': tempDir.path},
    );
    state = AppState(
      paths: paths,
      log: LogService(),
      liveService: _FixtureLiveService(),
    );
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> wrap(WidgetTester tester, Widget child) async {
    // 足够大的窗口，避免频道列表项落在视口外而无法命中点击。
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  }

  /// 导入一份含直播源的配置：M3U（可用）+ 失效源（404）。
  Future<void> importLiveConfig() async {
    final config = jsonEncode({
      'name': 'live-fixture',
      'sites': [
        {
          'key': 'fixture-type1',
          'name': 'Fixture',
          'type': 1,
          'api': 'http://127.0.0.1:18080/api/type1/',
        },
      ],
      'lives': [
        {
          'name': 'M3U 直播',
          'type': 1,
          'url': 'http://127.0.0.1:18080/live/live.m3u',
        },
        {
          'name': '失效直播',
          'type': 1,
          'url': 'http://127.0.0.1:18080/live/nope.m3u',
        },
      ],
    });
    await state.importConfig(config, displayName: 'live-fixture');
  }

  testWidgets('未配置直播源时显示空态说明（§13）', (tester) async {
    await wrap(tester, LivePage(state: state));
    await tester.pump();

    expect(find.text('当前配置没有直播源'), findsOneWidget);
    expect(find.textContaining('lives'), findsOneWidget);
  });

  testWidgets('渲染直播源列表、分组与频道（M3U）', (tester) async {
    await importLiveConfig();
    await wrap(tester, LivePage(state: state));
    await tester.pumpAndSettle();

    // 左侧两个源都在列表里（含失败的源）。
    expect(find.text('M3U 直播'), findsWidgets);
    expect(find.text('失效直播'), findsWidgets);

    // 默认选中第一个源并渲染分组/频道。
    expect(find.textContaining('央视'), findsWidgets);
    expect(find.text('CCTV-1 综合'), findsOneWidget);
    expect(find.text('CCTV-5 体育'), findsOneWidget);
    // 未分组频道归入「未分组」。
    expect(find.textContaining('未分组'), findsWidgets);
  });

  testWidgets('单源失败只影响该源，其他源仍可用（§14.3）', (tester) async {
    await importLiveConfig();
    await wrap(tester, LivePage(state: state));
    await tester.pumpAndSettle();

    // 切到失效源：展示错误态与重试按钮。
    await tester.tap(find.text('失效直播').first);
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);

    // 切回可用源：频道仍然渲染（未被失败源拖垮）。
    await tester.tap(find.text('M3U 直播').first);
    await tester.pumpAndSettle();
    expect(find.text('CCTV-1 综合'), findsOneWidget);
  });

  testWidgets('多线路频道在列表中展示线路数，点击后列出全部线路（§13.3）', (tester) async {
    await importLiveConfig();
    await wrap(tester, LivePage(state: state));
    await tester.pumpAndSettle();

    // 湖南卫视有两条线路（M3U 同名合并）——列表项尾部直接展示线路数。
    expect(find.text('2 线路'), findsOneWidget);

    // 点击频道后，右侧线路面板列出两条线路的地址与序号。
    await tester.tap(find.text('湖南卫视'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('2 条线路'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(
      find.textContaining('media/sample.m3u8'),
      findsWidgets,
    );
    expect(
      find.textContaining('media/sample.mp4'),
      findsWidgets,
    );
  });

  test('直播播放请求构造：多线路映射 + 直链（§13.3）', () {
    final channel = LiveChannel.fromJson({
      'name': '湖南卫视',
      'urls': [
        'http://h/a.m3u8',
        'http://h/b.m3u8',
      ],
    });

    final request = LivePage.requestForChannel(
      channel,
      sourceName: 'M3U 直播',
      startLine: 1,
    );

    expect(request.directUrl, isTrue);
    expect(request.vodName, '湖南卫视');
    expect(request.siteKey, 'M3U 直播');
    expect(request.url, 'http://h/b.m3u8'); // startLine=1 选中线路 2
    expect(request.episodeIndex, 1);
    expect(request.playLines.single.episodes, hasLength(2));
    expect(request.playLines.single.episodes.first.url, 'http://h/a.m3u8');
  });

  test('直播播放请求构造：无线路频道仍安全（不越界）', () {
    final channel = LiveChannel.fromJson({'name': '空频道'});
    final request = LivePage.requestForChannel(
      channel,
      sourceName: 'src',
      startLine: 3,
    );
    expect(request.url, '');
    expect(request.playLines.single.episodes, isEmpty);
  });

  test('直播播放请求携带频道级 Header（§13.1 直播 Header）', () {
    // 频道 Header 来自 M3U #EXTVLCOPT / TXT url|header，必须随直链注入，
    // 否则需鉴权的直播线路会因缺 Header 播放失败。
    final channel = LiveChannel.fromJson({
      'name': '浙江卫视',
      'urls': ['http://h/a.m3u8'],
      'header': {
        'Referer': 'http://h/',
        'User-Agent': 'WebHTV-PC/0.1 (Windows)',
      },
    });
    final request = LivePage.requestForChannel(
      channel,
      sourceName: 'M3U 直播',
    );
    expect(request.headers['Referer'], 'http://h/');
    expect(request.headers['User-Agent'], 'WebHTV-PC/0.1 (Windows)');
  });
}
