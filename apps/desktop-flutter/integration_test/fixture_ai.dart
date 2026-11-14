/// 假 AI 服务端（`docs/phase6/design/05` §5.1）。
///
/// 只服务 AI 请求，**按路径**返回对应协议的响应形态：
///
/// | 路径 | 行为 |
/// | --- | --- |
/// | `/v1/chat/completions` | OpenAI chat 形态 |
/// | `/v1/responses` | OpenAI responses 形态 |
/// | `/v1/messages` | Anthropic 形态 |
/// | `/v1beta/models/<m>:generateContent` | Gemini 形态 |
/// | `/v1/models` | 模型列表 |
/// | 任意 + `?fail=1` | 500 |
///
/// **为什么不在这里兼做假 TMDB**（计划 Task 9 Step 1 的那个写法）：
/// L3 的 TMDB 依赖已经有既成的本地 fixture 服务
/// （`tools/fixture_server` + `packages/test-fixtures/tmdb`，
/// `design/05` §3 与全部 `integration_test/tmdb_*` 都在用），它的匹配数据
/// （`示例剧集` → S0 3 / S1 12 / S2 10）与真实客户端已经对齐过。
/// 另造一份最小 TMDB 必须补齐 `/configuration`、`/tv/<id>`、
/// `/tv/<id>/season/<n>` 等一整串路由才不会让客户端走进异常分支，
/// 那正是「与真实实现悄悄漂移」的温床。AI 侧才是本轮新增的东西，
/// 所以这个 server 只管 AI。
library;

import 'dart:convert';
import 'dart:io';

/// 预置响应（`design/05` §5.1：4 种 mode + 5 类失败各一份）。
///
/// 只放「内容」文本；协议外形由路径决定，与内容正交。
abstract final class FakeAiPreset {
  /// `SINGLE_SEASON` —— 配合「线路二 8 集 / 该季 10 集」才是合法的。
  static const String singleSeason = 'single_season';
  static const String flatByCounts = 'flat_by_counts';
  static const String keepOriginal = 'keep_original';
  static const String explicitMapping = 'explicit_mapping';

  /// 5 类硬校验失败（`design/04` §6.4）。
  static const String invalidJson = 'invalid_json';
  static const String invalidMode = 'invalid_mode';
  static const String invalidSeason = 'invalid_season';
  static const String unsafeFlatMapping = 'unsafe_flat_mapping';
  static const String invalidMapping = 'invalid_mapping';

  /// `EXPLICIT_MAPPING` 的逐集映射：线路一共 22 集，正好填满 TMDB 的
  /// S1（12 集）+ S2（10 集），且 `(season, episode)` 按 `sourceIndex`
  /// **严格递增**——这是 `design/04` §6.4 对逐集映射的硬要求。
  ///
  /// 为什么必须真的合法：这个预置要用来验证「合法逐集映射 → 只预览不落盘」，
  /// 若映射本身不合法，`parseAiSeasonResponse` 会先返回 `invalidMapping`，
  /// 用例会看起来「通过」但实际一行预览都没走到。
  static final String _explicitMappingJson = _buildExplicitMapping();

  static String _buildExplicitMapping() {
    final mappings = <Map<String, Object?>>[];
    var index = 0;
    for (final (season, count) in const [(1, 12), (2, 10)]) {
      for (var episode = 1; episode <= count; episode++) {
        mappings.add({
          'sourceIndex': index++,
          'seasonNumber': season,
          'episodeNumber': episode,
        });
      }
    }
    return '{"mode":"EXPLICIT_MAPPING","seasonNumber":-1,"confidence":0.95,'
        '"summary":"逐集映射","warnings":[],"mappings":'
        '${jsonEncode(mappings)}}';
  }

  static final Map<String, String> values = {
    singleSeason:
        '{"mode":"SINGLE_SEASON","seasonNumber":2,"confidence":0.9,'
        '"summary":"看起来是第 2 季","warnings":[],"mappings":[]}',
    flatByCounts:
        '{"mode":"FLAT_BY_COUNTS","seasonNumber":-1,"confidence":0.8,'
        '"summary":"按集数切片","warnings":[],"mappings":[]}',
    keepOriginal:
        '{"mode":"KEEP_ORIGINAL","seasonNumber":-1,"confidence":0.7,'
        '"summary":"保持原始集列表","warnings":[],"mappings":[]}',
    explicitMapping: _explicitMappingJson,
    invalidJson: '这不是 JSON',
    invalidMode:
        '{"mode":"GUESS","seasonNumber":-1,"confidence":0.5,"summary":""}',
    invalidSeason:
        '{"mode":"SINGLE_SEASON","seasonNumber":99,"confidence":0.9,'
        '"summary":""}',
    unsafeFlatMapping:
        '{"mode":"FLAT_BY_COUNTS","seasonNumber":-1,"confidence":0.9,'
        '"summary":""}',
    invalidMapping:
        '{"mode":"EXPLICIT_MAPPING","seasonNumber":-1,"confidence":0.9,'
        '"summary":"","mappings":[]}',
  };
}

/// 本地假 AI 服务端。一个实例一个随机端口，测试之间互不干扰。
class FakeAiServer {
  FakeAiServer._(this._server);

  final HttpServer _server;

  int get port => _server.port;
  String get baseUrl => 'http://127.0.0.1:$port';

  /// 下一次响应里 AI 输出文本（默认 `KEEP_ORIGINAL` 预置）。
  String aiText = FakeAiPreset.values[FakeAiPreset.keepOriginal]!;

  /// 下一次响应改回 500（传输层失败）。
  bool failNext = false;

  /// 响应前的人为延迟（用来让进度框停在屏幕上，测「在途取消」）。
  Duration delay = Duration.zero;

  /// 收到的请求路径（证据用）。
  final List<String> requestPaths = [];

  static Future<FakeAiServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeAiServer._(server);
    fake._listen();
    return fake;
  }

  /// 用预置名装载下一次响应。
  void usePreset(String name) {
    final text = FakeAiPreset.values[name];
    if (text == null) throw ArgumentError.value(name, 'name', '未知预置响应');
    aiText = text;
  }

  void _listen() {
    _server.listen((request) async {
      final path = request.uri.path;
      requestPaths.add(path);

      if (delay > Duration.zero) await Future<void>.delayed(delay);

      // `design/05` §5.1：任意路径 + `?fail=1` → 500。
      if (failNext || request.uri.queryParameters['fail'] == '1') {
        await request.drain<void>();
        request.response.statusCode = 500;
        request.response.write('boom');
        await request.response.close();
        return;
      }

      if (request.method == 'GET' && path.endsWith('/models')) {
        await _json(request, {
          'data': [
            {'id': 'fake-model-a', 'owned_by': 'test'},
            {'id': 'fake-model-b', 'owned_by': 'test'},
          ],
        });
        return;
      }

      await _json(request, _shapeFor(path));
    });
  }

  /// 按路径决定协议外形（内容都是 [aiText]）。
  Map<String, Object?> _shapeFor(String path) {
    if (path.endsWith('/responses')) return {'output_text': aiText};
    if (path.endsWith('/messages')) {
      return {
        'content': [
          {'text': aiText},
        ],
      };
    }
    if (path.contains(':generateContent')) {
      return {
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': aiText},
              ],
            },
          },
        ],
      };
    }
    return {
      'choices': [
        {
          'message': {'content': aiText},
        },
      ],
    };
  }

  Future<void> _json(HttpRequest request, Object body) async {
    await request.drain<void>();
    request.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await request.response.close();
  }

  Future<void> stop() => _server.close(force: true);
}
