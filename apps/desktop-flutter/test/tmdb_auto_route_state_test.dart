/// 自动线路在 AppState 层的解析与失败切换（`docs/phase4/design/03` §5.7）。
///
/// 钉住三件事：
/// 1. 配置里存的是 `auto`，**读出来**的海报/后景地址是具体线路（消费者不必认识自动）；
/// 2. 设置页看到的「当前实际线路」来自同一个解析结果；
/// 3. 图片连续失败会换线，单张失败不会。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

class _ImageHostClient extends http.BaseClient {
  _ImageHostClient({this.broken = const {}});

  final Set<String> broken;
  final List<Uri> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    if (broken.contains(request.url.host)) {
      throw const SocketException('route down');
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(List<int>.filled(1024, 1)),
      200,
      request: request,
    );
  }
}

Future<AppState> _boot(
  WidgetTester tester, {
  Set<String> broken = const {},
  String apiBase = 'auto',
  String imageBase = 'auto',
}) async {
  final temp = Directory.systemTemp.createTempSync('tmdb-auto-state-');
  final paths = AppPaths.resolve(
    overrides: {
      'config': '${temp.path}/config',
      'data': '${temp.path}/data',
      'cache': '${temp.path}/cache',
      'state': '${temp.path}/logs',
    },
  );
  Directory(paths.configDir).createSync(recursive: true);
  File(paths.settingsPath).writeAsStringSync(
    jsonEncode({
      'tmdb': {
        'enabled': true,
        'apiBase': apiBase,
        'apiKey': 'key',
        'imageBase': imageBase,
        'backdropBase': imageBase,
        'language': 'zh-CN',
      },
    }),
  );
  final state = AppState(
    paths: paths,
    log: LogService(),
    externalPlayerDetector: () => const [],
    warmAutoRoutes: false,
    tmdbService: TmdbService(
      config: () => const TmdbConfig(apiKey: 'key'),
      client: _ImageHostClient(broken: broken),
    ),
  );
  addTearDown(() {
    state.dispose();
    temp.deleteSync(recursive: true);
  });
  await tester.runAsync(state.bootstrap);
  return state;
}

void main() {
  testWidgets('自动图片线路：配置存 auto，读出来是具体地址', (tester) async {
    final state = await _boot(tester);

    expect(state.tmdbUserConfig.imageBase, 'auto');
    expect(state.tmdbUserConfig.apiBase, 'auto');
    expect(state.tmdbConfig.imageBase, 'https://images.tmdb.org/t/p/w342');
    expect(state.tmdbConfig.backdropBase, 'https://images.tmdb.org/t/p/w1280');

    final status = state.tmdbRouteStatus();
    expect(status.imageAuto, isTrue);
    expect(status.apiAuto, isTrue);
    expect(status.imageHost, 'images.tmdb.org');
    expect(status.imageLabel, contains('自动'));
    expect(status.apiLabel, contains('自动'));
  });

  testWidgets('非自动配置原样透传（不会被解析改写）', (tester) async {
    final state = await _boot(
      tester,
      apiBase: 'https://api.tmdb.org',
      imageBase: 'https://jsnzkpg4.pages.dev/https://image.tmdb.org',
    );
    expect(
      state.tmdbConfig.imageBase,
      'https://jsnzkpg4.pages.dev/https://image.tmdb.org/t/p/w342',
    );
    final status = state.tmdbRouteStatus();
    expect(status.imageAuto, isFalse);
    expect(status.imageLabel, isNot(contains('自动')));
  });

  testWidgets('单张图片失败不换线，连续两张才换', (tester) async {
    final state = await _boot(tester, broken: {'images.tmdb.org'});

    state.reportTmdbImageFailure(
      'https://images.tmdb.org/t/p/w342/one.jpg',
    );
    expect(state.tmdbConfig.imageBase, 'https://images.tmdb.org/t/p/w342');

    state.reportTmdbImageFailure(
      'https://images.tmdb.org/t/p/w342/two.jpg',
    );
    // 换线后异步重测一次：图片主机必须不再是坏掉的那条。
    await tester.runAsync(pumpEventQueue);
    expect(
      state.tmdbRouteStatus().imageHost,
      isNot('images.tmdb.org'),
    );
    expect(
      state.tmdbConfig.imageBase,
      isNot(startsWith('https://images.tmdb.org')),
    );
  });

  testWidgets('重新测速返回人话并避开坏线路', (tester) async {
    final state = await _boot(tester, broken: {'images.tmdb.org'});
    final sentence = await tester.runAsync(state.refreshTmdbAutoRoutes);
    expect(sentence, contains('自动线路已测速'));
    expect(state.tmdbRouteStatus().imageHost, isNot('images.tmdb.org'));
  });

  testWidgets('图片不是自动时，重新测速什么都不做', (tester) async {
    final state = await _boot(tester, imageBase: 'https://images.tmdb.org');
    final sentence = await tester.runAsync(state.refreshTmdbAutoRoutes);
    expect(sentence, '当前不是自动线路');
  });
}
